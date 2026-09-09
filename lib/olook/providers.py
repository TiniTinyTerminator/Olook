"""Server autodiscovery.

Given only an email address, work out IMAP/SMTP hosts and which
authentication a provider will actually accept. The chain, in order:

  1. a built-in table of the providers people actually use
  2. the domain's MX records — this is what catches Google Workspace and
     Microsoft 365 business domains, which look like any other custom domain
     until you notice the mail lands at Google or Microsoft
  3. Thunderbird's ISPDB, then the domain's own autoconfig XML
  4. a plain guess at imap./smtp. subdomains

Only step 3 talks to the network beyond DNS, and only for domains the first
two steps could not resolve.
"""

import re
import socket
import ssl
import struct
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

TIMEOUT = 6

# Public client identifiers shipped by Thunderbird. Mail providers hand these
# out for desktop clients, which cannot keep a secret; they identify the app,
# they do not authorize it — the user's own consent does. Override per account
# with oauth.client_id / oauth.client_secret to use your own registration.
GOOGLE_CLIENT_ID = "406964657835-aq8lmia8j95dhl1a2bvharmfk3t1hgqj.apps.googleusercontent.com"
GOOGLE_CLIENT_SECRET = "kSmqreRr0qwBWJgbf5Y-PjSU"
MICROSOFT_CLIENT_ID = "9e5f94bc-e8a4-4e73-b8be-63364c29d753"

GMAIL = {
    "provider": "gmail",
    "auth": "oauth2",
    "imap": {"host": "imap.gmail.com", "port": 993, "ssl": True, "starttls": False},
    "smtp": {"host": "smtp.gmail.com", "port": 587, "ssl": False, "starttls": True},
    "folders": {
        "archive": "[Gmail]/All Mail",
        "sent": "[Gmail]/Sent Mail",
        "drafts": "[Gmail]/Drafts",
        "trash": "[Gmail]/Trash",
        "junk": "[Gmail]/Spam",
    },
    "oauth": {"flavor": "google", "client_id": GOOGLE_CLIENT_ID,
              "client_secret": GOOGLE_CLIENT_SECRET,
              # Contacts as well as mail: the People tab reads the address
              # book the phone syncs, and read-only is all it ever wants.
              "scope": ("https://mail.google.com/ "
                        "https://www.googleapis.com/auth/contacts.readonly")},
}

MICROSOFT_CONSUMER = {
    "provider": "microsoft",
    "auth": "oauth2",
    "imap": {"host": "outlook.office365.com", "port": 993, "ssl": True, "starttls": False},
    "smtp": {"host": "smtp-mail.outlook.com", "port": 587, "ssl": False, "starttls": True},
    "folders": {"archive": "Archive", "sent": "Sent", "drafts": "Drafts",
                "trash": "Deleted", "junk": "Junk"},
    "oauth": {"flavor": "microsoft", "client_id": MICROSOFT_CLIENT_ID,
              "tenant": "common",
              "scope": ("offline_access "
                        "https://outlook.office.com/IMAP.AccessAsUser.All "
                        "https://outlook.office.com/SMTP.Send")},
}

MICROSOFT_BUSINESS = {
    "provider": "microsoft",
    "auth": "oauth2",
    "imap": {"host": "outlook.office365.com", "port": 993, "ssl": True, "starttls": False},
    "smtp": {"host": "smtp.office365.com", "port": 587, "ssl": False, "starttls": True},
    "folders": {"archive": "Archive", "sent": "Sent Items", "drafts": "Drafts",
                "trash": "Deleted Items", "junk": "Junk Email"},
    "oauth": {"flavor": "microsoft", "client_id": MICROSOFT_CLIENT_ID,
              "tenant": "common",
              "scope": ("offline_access "
                        "https://outlook.office.com/IMAP.AccessAsUser.All "
                        "https://outlook.office.com/SMTP.Send")},
}

BUILTIN = {
    "gmail.com": GMAIL,
    "googlemail.com": GMAIL,
    "outlook.com": MICROSOFT_CONSUMER,
    "hotmail.com": MICROSOFT_CONSUMER,
    "hotmail.co.uk": MICROSOFT_CONSUMER,
    "live.com": MICROSOFT_CONSUMER,
    "live.nl": MICROSOFT_CONSUMER,
    "msn.com": MICROSOFT_CONSUMER,
    "outlook.office365.com": MICROSOFT_BUSINESS,
    "icloud.com": {
        "provider": "icloud", "auth": "password",
        "imap": {"host": "imap.mail.me.com", "port": 993, "ssl": True, "starttls": False},
        "smtp": {"host": "smtp.mail.me.com", "port": 587, "ssl": False, "starttls": True},
        "note": "iCloud requires an app-specific password from appleid.apple.com.",
    },
    "me.com": None,   # filled in below
    "mac.com": None,
    "yahoo.com": {
        "provider": "yahoo", "auth": "password",
        "imap": {"host": "imap.mail.yahoo.com", "port": 993, "ssl": True, "starttls": False},
        "smtp": {"host": "smtp.mail.yahoo.com", "port": 465, "ssl": True, "starttls": False},
        "note": "Yahoo requires an app password from account security settings.",
    },
    "fastmail.com": {
        "provider": "fastmail", "auth": "password",
        "imap": {"host": "imap.fastmail.com", "port": 993, "ssl": True, "starttls": False},
        "smtp": {"host": "smtp.fastmail.com", "port": 465, "ssl": True, "starttls": False},
        "note": "Fastmail requires an app password with IMAP/SMTP access.",
    },
    "proton.me": {
        "provider": "proton", "auth": "password",
        "imap": {"host": "127.0.0.1", "port": 1143, "ssl": False, "starttls": True},
        "smtp": {"host": "127.0.0.1", "port": 1025, "ssl": False, "starttls": True},
        "note": "Proton needs Proton Mail Bridge running locally.",
    },
    "zoho.com": {
        "provider": "zoho", "auth": "password",
        "imap": {"host": "imap.zoho.com", "port": 993, "ssl": True, "starttls": False},
        "smtp": {"host": "smtp.zoho.com", "port": 465, "ssl": True, "starttls": False},
    },
}
BUILTIN["me.com"] = BUILTIN["icloud.com"]
BUILTIN["mac.com"] = BUILTIN["icloud.com"]

# MX suffix -> settings. Matched against the lowercased MX target.
MX_MAP = [
    ("mail.protection.outlook.com", MICROSOFT_BUSINESS),
    ("outlook.com", MICROSOFT_BUSINESS),
    ("google.com", GMAIL),
    ("googlemail.com", GMAIL),
    ("messagingengine.com", BUILTIN["fastmail.com"]),
    ("icloud.com", BUILTIN["icloud.com"]),
    ("zoho.com", BUILTIN["zoho.com"]),
    ("protonmail.ch", BUILTIN["proton.me"]),
]


def domain_of(email):
    return str(email).split("@")[-1].strip().lower()


def discover(email, offline=False):
    """Return a settings dict for `email`, always with a `source` field."""
    domain = domain_of(email)
    if not domain:
        return _fallback(domain, "invalid")

    builtin = BUILTIN.get(domain)
    if builtin:
        return _finish(builtin, domain, "builtin")

    if not offline:
        mx = mx_hosts(domain)
        for host in mx:
            for suffix, settings in MX_MAP:
                if host == suffix or host.endswith("." + suffix):
                    return _finish(settings, domain, f"mx:{host}")

        for fetched in (_ispdb(domain), _domain_autoconfig(domain)):
            if fetched:
                return _finish(fetched, domain, fetched.pop("_source"))

    return _fallback(domain, "guess")


def _finish(settings, domain, source):
    out = {
        "provider": settings.get("provider", "generic"),
        "auth": settings.get("auth", "password"),
        "imap": dict(settings["imap"]),
        "smtp": dict(settings["smtp"]),
        "folders": dict(settings.get("folders") or {}),
        "oauth": dict(settings.get("oauth") or {}),
        "source": source,
        "domain": domain,
    }
    if settings.get("note"):
        out["note"] = settings["note"]
    return out


def _fallback(domain, source):
    return {
        "provider": "generic",
        "auth": "password",
        "imap": {"host": f"imap.{domain}", "port": 993, "ssl": True, "starttls": False},
        "smtp": {"host": f"smtp.{domain}", "port": 587, "ssl": False, "starttls": True},
        "folders": {},
        "oauth": {},
        "source": source,
        "domain": domain,
        "note": "Guessed from the domain name — check the server settings.",
    }


# ------------------------------------------------------------------- autoconfig

def _get(url):
    request = urllib.request.Request(url, headers={"User-Agent": "olook/1.0"})
    context = ssl.create_default_context()
    with urllib.request.urlopen(request, timeout=TIMEOUT, context=context) as response:
        if response.status != 200:
            return None
        return response.read()


def _ispdb(domain):
    try:
        raw = _get(f"https://autoconfig.thunderbird.net/v1.1/{domain}")
    except (urllib.error.URLError, OSError, ValueError):
        return None
    parsed = _parse_autoconfig(raw)
    if parsed:
        parsed["_source"] = "ispdb"
    return parsed


def _domain_autoconfig(domain):
    urls = [
        f"https://autoconfig.{domain}/mail/config-v1.1.xml",
        f"https://{domain}/.well-known/autoconfig/mail/config-v1.1.xml",
    ]
    for url in urls:
        try:
            raw = _get(url)
        except (urllib.error.URLError, OSError, ValueError):
            continue
        parsed = _parse_autoconfig(raw)
        if parsed:
            parsed["_source"] = "autoconfig"
            return parsed
    return None


def _parse_autoconfig(raw):
    """Pull the first IMAP and first SMTP server out of an autoconfig XML."""
    if not raw:
        return None
    try:
        root = ET.fromstring(raw)
    except ET.ParseError:
        return None

    imap = smtp = None
    for node in root.iter("incomingServer"):
        if node.get("type") == "imap" and imap is None:
            imap = _server_node(node)
    for node in root.iter("outgoingServer"):
        if smtp is None:
            smtp = _server_node(node)
    if not imap or not smtp:
        return None

    auth = "oauth2" if _wants_oauth(root) else "password"
    return {"provider": "generic", "auth": auth, "imap": imap, "smtp": smtp,
            "folders": {}, "oauth": {}}


def _server_node(node):
    host = (node.findtext("hostname") or "").strip()
    try:
        port = int((node.findtext("port") or "0").strip())
    except ValueError:
        port = 0
    socket_type = (node.findtext("socketType") or "").strip().upper()
    use_ssl = socket_type == "SSL"
    starttls = socket_type == "STARTTLS"
    if not port:
        port = 993 if use_ssl else 143
    return {"host": host, "port": port, "ssl": use_ssl, "starttls": starttls}


def _wants_oauth(root):
    for node in root.iter("authentication"):
        if (node.text or "").strip().upper() in ("OAUTH2", "XOAUTH2"):
            return True
    return False


# -------------------------------------------------------------------- DNS (MX)
#
# No third-party resolver here: a 60-line UDP query against the system's own
# nameservers keeps autodiscovery dependency-free and keeps the lookup on the
# user's configured resolver instead of a public DNS-over-HTTPS endpoint.

def nameservers():
    servers = []
    try:
        with open("/etc/resolv.conf", "r", encoding="utf-8") as handle:
            for line in handle:
                match = re.match(r"\s*nameserver\s+(\S+)", line)
                if match:
                    servers.append(match.group(1))
    except OSError:
        pass
    return servers or ["127.0.0.53", "1.1.1.1"]


def mx_hosts(domain):
    """Return MX targets for `domain`, lowest preference first. [] on failure."""
    query = _dns_query(domain, qtype=15)
    for server in nameservers()[:3]:
        try:
            sock = socket.socket(socket.AF_INET6 if ":" in server else socket.AF_INET,
                                 socket.SOCK_DGRAM)
        except OSError:
            continue
        try:
            sock.settimeout(TIMEOUT / 2)
            sock.sendto(query, (server, 53))
            data, _ = sock.recvfrom(4096)
            hosts = _dns_parse_mx(data)
            if hosts:
                return hosts
        except OSError:
            continue
        finally:
            sock.close()
    return []


def _dns_query(name, qtype):
    header = struct.pack(">HHHHHH", 0x4d41, 0x0100, 1, 0, 0, 0)
    body = b"".join(bytes([len(p)]) + p.encode("idna" if not p.isascii() else "ascii")
                    for p in name.split(".") if p) + b"\x00"
    return header + body + struct.pack(">HH", qtype, 1)


def _dns_name(data, offset):
    """Read a (possibly compressed) DNS name. Returns (labels, next_offset)."""
    labels = []
    jumped = False
    end = offset
    guard = 0
    while offset < len(data) and guard < 64:
        guard += 1
        length = data[offset]
        if length == 0:
            offset += 1
            if not jumped:
                end = offset
            break
        if length & 0xC0 == 0xC0:
            pointer = struct.unpack(">H", data[offset:offset + 2])[0] & 0x3FFF
            if not jumped:
                end = offset + 2
            jumped = True
            offset = pointer
            continue
        offset += 1
        labels.append(data[offset:offset + length].decode("ascii", "replace"))
        offset += length
        if not jumped:
            end = offset
    return ".".join(labels), end


def _dns_parse_mx(data):
    if len(data) < 12:
        return []
    _, flags, questions, answers, _, _ = struct.unpack(">HHHHHH", data[:12])
    if flags & 0x000F:  # RCODE != 0
        return []
    offset = 12
    for _ in range(questions):
        _, offset = _dns_name(data, offset)
        offset += 4
    found = []
    for _ in range(answers):
        _, offset = _dns_name(data, offset)
        if offset + 10 > len(data):
            break
        rtype, _, _, rdlength = struct.unpack(">HHIH", data[offset:offset + 10])
        offset += 10
        if rtype == 15 and offset + 2 <= len(data):
            preference = struct.unpack(">H", data[offset:offset + 2])[0]
            host, _ = _dns_name(data, offset + 2)
            found.append((preference, host.rstrip(".").lower()))
        offset += rdlength
    found.sort(key=lambda item: item[0])
    return [host for _, host in found if host]
