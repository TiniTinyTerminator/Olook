"""IMAP: connect, discover folders, sync headers, fetch bodies, change flags.

Everything the UI needs from a server goes through Session. Password and
XOAUTH2 authentication look the same to callers; so do Gmail's odd `[Gmail]/`
folders and Exchange's `Deleted Items`, because folder roles are resolved from
RFC 6154 SPECIAL-USE flags first and only fall back to configured names.
"""

import email
import email.policy
import email.utils
import imaplib
import re
import ssl
import time
from email.header import decode_header, make_header

from . import htmltext, keyring, oauth, store

imaplib._MAXLINE = 10_000_000  # some servers send very long BODYSTRUCTURE lines

SPECIAL_FLAGS = {
    b"\\all": "all",
    b"\\archive": "archive",
    b"\\drafts": "drafts",
    b"\\sent": "sent",
    b"\\trash": "trash",
    b"\\junk": "junk",
    b"\\flagged": "flagged",
    b"\\important": "important",
}


class MailError(Exception):
    pass


# --------------------------------------------------------------- IMAP UTF-7

def encode_folder(name):
    """Python str -> modified UTF-7 as used for IMAP mailbox names (RFC 3501)."""
    out = []
    buffer = []

    def flush():
        if not buffer:
            return
        raw = "".join(buffer).encode("utf-16-be")
        encoded = _b64(raw).replace("/", ",")
        out.append("&" + encoded + "-")
        buffer.clear()

    for char in name:
        if char == "&":
            flush()
            out.append("&-")
        elif "\x20" <= char <= "\x7e":
            flush()
            out.append(char)
        else:
            buffer.append(char)
    flush()
    return "".join(out)


def decode_folder(name):
    """Modified UTF-7 -> Python str."""
    if isinstance(name, bytes):
        name = name.decode("ascii", "replace")
    if "&" not in name:
        return name
    out = []
    index = 0
    while index < len(name):
        char = name[index]
        if char != "&":
            out.append(char)
            index += 1
            continue
        end = name.find("-", index + 1)
        if end == -1:
            out.append(char)
            index += 1
            continue
        chunk = name[index + 1:end]
        if chunk == "":
            out.append("&")
        else:
            try:
                padded = chunk.replace(",", "/")
                padded += "=" * (-len(padded) % 4)
                out.append(__import__("base64").b64decode(padded).decode("utf-16-be"))
            except Exception:
                out.append(name[index:end + 1])
        index = end + 1
    return "".join(out)


def _b64(raw):
    import base64
    return base64.b64encode(raw).decode("ascii").rstrip("=")


def quote(name):
    escaped = encode_folder(name).replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


# ------------------------------------------------------------------ helpers

def decode_mime(value):
    if not value:
        return ""
    try:
        return str(make_header(decode_header(str(value)))).strip()
    except Exception:
        return str(value).strip()


def split_addresses(value):
    if not value:
        return []
    out = []
    for name, addr in email.utils.getaddresses([str(value)]):
        addr = addr.strip()
        if not addr:
            continue
        name = decode_mime(name)
        out.append({"name": name or addr.split("@")[0], "address": addr})
    return out


def parse_date(value):
    try:
        parsed = email.utils.parsedate_to_datetime(str(value))
    except (TypeError, ValueError):
        return 0
    if parsed is None:
        return 0
    try:
        return int(parsed.timestamp())
    except (OverflowError, ValueError, OSError):
        return 0


def _group_fetch(data):
    """Group a raw imaplib FETCH response into one blob per message."""
    groups = []
    current = None
    for item in data or []:
        if item is None:
            continue
        head = item[0] if isinstance(item, tuple) else item
        if isinstance(head, bytes) and re.match(rb"^\s*\*?\s*\d+\s+FETCH", head, re.I):
            if current:
                groups.append(current)
            current = {"raw": b"", "literals": []}
        if current is None:
            current = {"raw": b"", "literals": []}
        if isinstance(item, tuple):
            current["raw"] += b" " + item[0]
            current["literals"].append(item[1] if len(item) > 1 else b"")
        elif isinstance(item, bytes):
            current["raw"] += b" " + item
    if current:
        groups.append(current)
    return groups


def _uid_of(blob):
    match = re.search(rb"\bUID\s+(\d+)", blob, re.I)
    return int(match.group(1)) if match else 0


def _flags_of(blob):
    match = re.search(rb"\bFLAGS\s+\(([^)]*)\)", blob, re.I)
    if not match:
        return set()
    return {flag.lower() for flag in match.group(1).split()}


def _size_of(blob):
    match = re.search(rb"\bRFC822\.SIZE\s+(\d+)", blob, re.I)
    return int(match.group(1)) if match else 0


def _has_attachment(blob):
    lowered = blob.lower()
    if b'"attachment"' in lowered:
        return 1
    # A filename parameter on any part is the other reliable tell.
    return 1 if re.search(rb'"(name|filename)"\s+"', lowered) else 0


def uid_ranges(uids):
    """Compact a uid list into IMAP set notation: 1,3:7,10."""
    numbers = sorted({int(u) for u in uids})
    if not numbers:
        return ""
    parts = []
    start = previous = numbers[0]
    for value in numbers[1:]:
        if value == previous + 1:
            previous = value
            continue
        parts.append(str(start) if start == previous else f"{start}:{previous}")
        start = previous = value
    parts.append(str(start) if start == previous else f"{start}:{previous}")
    return ",".join(parts)


# ------------------------------------------------------------------- session

class Session:
    def __init__(self, account, timeout=45):
        self.account = account
        self.timeout = timeout
        self.imap = None
        self.capabilities = set()
        self.selected = None

    # -- lifecycle ---------------------------------------------------------
    def __enter__(self):
        self.connect()
        return self

    def __exit__(self, *exc):
        self.close()
        return False

    def connect(self):
        settings = self.account["imap"]
        host, port = settings["host"], int(settings["port"])
        if not host:
            raise MailError("No IMAP host configured for this account.")
        context = ssl.create_default_context()
        try:
            if settings.get("ssl", True):
                self.imap = imaplib.IMAP4_SSL(host, port, ssl_context=context,
                                              timeout=self.timeout)
            else:
                self.imap = imaplib.IMAP4(host, port, timeout=self.timeout)
                if settings.get("starttls", True):
                    self.imap.starttls(context)
        except (OSError, ssl.SSLError, imaplib.IMAP4.error) as exc:
            raise MailError(f"Cannot reach {host}:{port} — {exc}") from exc

        self._authenticate()
        self._read_capabilities()
        return self

    def _authenticate(self):
        account = self.account
        username = account.get("username") or account["email"]
        if account.get("auth") == "oauth2":
            token = oauth.access_token(account)
            try:
                self._auth_xoauth2(username, token)
            except imaplib.IMAP4.error:
                # An access token can be rejected while still inside its stated
                # lifetime (password change, revoked consent). One forced
                # refresh distinguishes a stale cache from a dead grant.
                token = oauth.access_token(account, force_refresh=True)
                try:
                    self._auth_xoauth2(username, token)
                except imaplib.IMAP4.error as exc:
                    raise MailError(
                        f"IMAP rejected the OAuth token for {account['email']}: {exc}") from exc
            return

        password = keyring.get_secret(account["id"], "password")
        if not password:
            raise MailError(
                f"No password stored for {account['email']}. "
                f"Run: olook auth {account['id']}")
        try:
            self.imap.login(username, password)
        except imaplib.IMAP4.error as exc:
            raise MailError(f"IMAP login failed for {account['email']}: {exc}") from exc

    def _auth_xoauth2(self, username, token):
        payload = oauth.xoauth2_raw(username, token).encode("utf-8")
        self.imap.authenticate("XOAUTH2", lambda _challenge: payload)

    def _read_capabilities(self):
        try:
            self.capabilities = {c.decode().upper() for c in (self.imap.capabilities or ())}
        except Exception:
            self.capabilities = set()

    def close(self):
        if not self.imap:
            return
        try:
            if self.selected:
                self.imap.close()
        except Exception:
            pass
        try:
            self.imap.logout()
        except Exception:
            pass
        self.imap = None

    def _ok(self, result, message):
        status, data = result
        if status != "OK":
            detail = b" ".join(x for x in data if isinstance(x, bytes)).decode("utf-8", "replace")
            raise MailError(f"{message}: {detail or status}")
        return data

    # -- folders -----------------------------------------------------------
    def list_folders(self):
        data = self._ok(self.imap.list(), "Could not list folders")
        folders = []
        for line in data:
            if isinstance(line, tuple):
                line = b" ".join(part for part in line if isinstance(part, bytes))
            if not isinstance(line, bytes):
                continue
            match = re.match(rb'^\((?P<flags>[^)]*)\)\s+"?(?P<delim>[^" ]*)"?\s+(?P<name>.*)$',
                             line.strip())
            if not match:
                continue
            flags = {f.lower() for f in match.group("flags").split()}
            if b"\\noselect" in flags or b"\\nonexistent" in flags:
                continue
            raw_name = match.group("name").strip()
            if raw_name.startswith(b'"') and raw_name.endswith(b'"'):
                raw_name = raw_name[1:-1]
            name = decode_folder(raw_name.replace(b'\\"', b'"'))
            special = ""
            for flag, role in SPECIAL_FLAGS.items():
                if flag in flags:
                    special = role
                    break
            if name.upper() == "INBOX":
                name = "INBOX"
                special = "inbox"
            folders.append({
                "name": name,
                "delimiter": (match.group("delim") or b"/").decode("ascii", "replace"),
                "special": special,
            })
        return folders

    def status(self, folder):
        result = self.imap.status(quote(folder), "(MESSAGES UNSEEN UIDNEXT UIDVALIDITY)")
        data = self._ok(result, f"Could not read status of {folder}")
        blob = b" ".join(x for x in data if isinstance(x, bytes))
        def field(key):
            match = re.search(rb"\b" + key + rb"\s+(\d+)", blob, re.I)
            return int(match.group(1)) if match else 0
        return {
            "total": field(b"MESSAGES"),
            "unseen": field(b"UNSEEN"),
            "uidnext": field(b"UIDNEXT"),
            "uidvalidity": field(b"UIDVALIDITY"),
        }

    def select(self, folder, readonly=False):
        if self.selected == (folder, readonly):
            return
        status, data = self.imap.select(quote(folder), readonly=readonly)
        if status != "OK":
            detail = b" ".join(x for x in data if isinstance(x, bytes)).decode("utf-8", "replace")
            raise MailError(f"Cannot open folder {folder}: {detail}")
        self.selected = (folder, readonly)

    def resolve_role(self, role, folders=None):
        """Find the real folder name for 'sent', 'trash', 'archive', ..."""
        role = str(role or "").lower()
        if role in ("", "inbox"):
            return "INBOX"
        folders = folders if folders is not None else self.list_folders()
        wanted = {role}
        if role == "archive":
            wanted.add("all")  # Gmail archives into All Mail
        for entry in folders:
            if entry.get("special") in wanted:
                return entry["name"]
        configured = (self.account.get("folders") or {}).get(role)
        if configured:
            for entry in folders:
                if entry["name"].lower() == configured.lower():
                    return entry["name"]
        names = {entry["name"].lower(): entry["name"] for entry in folders}
        for candidate in _ROLE_GUESSES.get(role, []):
            if candidate.lower() in names:
                return names[candidate.lower()]
        return configured or ""

    # -- reading -----------------------------------------------------------
    def search_uids(self, criteria="ALL", limit=0):
        status, data = self.imap.uid("SEARCH", None, criteria)
        if status != "OK":
            return []
        uids = [int(x) for x in (data[0] or b"").split()]
        uids.sort()
        return uids[-limit:] if limit else uids

    def fetch_flags(self, uids):
        if not uids:
            return {}
        data = self._ok(self.imap.uid("FETCH", uid_ranges(uids), "(UID FLAGS)"),
                        "Could not read flags")
        out = {}
        for group in _group_fetch(data):
            uid = _uid_of(group["raw"])
            if uid:
                out[uid] = _flags_of(group["raw"])
        return out

    def fetch_headers(self, uids):
        """Return [{uid, flags, size, attachments, headers}] for `uids`."""
        if not uids:
            return []
        ranges = uid_ranges(uids)
        summary = {}

        data = self._ok(
            self.imap.uid("FETCH", ranges, "(UID FLAGS RFC822.SIZE BODYSTRUCTURE)"),
            "Could not read message summaries")
        for group in _group_fetch(data):
            uid = _uid_of(group["raw"])
            if not uid:
                continue
            summary[uid] = {
                "uid": uid,
                "flags": _flags_of(group["raw"]),
                "size": _size_of(group["raw"]),
                "attachments": _has_attachment(group["raw"]),
                "headers": {},
                "preview": "",
            }

        fields = "(UID BODY.PEEK[HEADER.FIELDS (FROM TO CC SUBJECT DATE MESSAGE-ID REPLY-TO LIST-ID)])"
        data = self._ok(self.imap.uid("FETCH", ranges, fields),
                        "Could not read message headers")
        for group in _group_fetch(data):
            uid = _uid_of(group["raw"])
            if uid not in summary or not group["literals"]:
                continue
            parsed = email.message_from_bytes(group["literals"][0],
                                              policy=email.policy.default)
            summary[uid]["headers"] = parsed

        # A cheap snippet for the list rows. Part 1 is the text part on the
        # overwhelming majority of messages; when it isn't, the row just shows
        # no preview rather than paying for a full body fetch during sync.
        try:
            data = self.imap.uid("FETCH", ranges, "(UID BODY.PEEK[1]<0.400>)")
            if data[0] == "OK":
                for group in _group_fetch(data[1]):
                    uid = _uid_of(group["raw"])
                    if uid in summary and group["literals"]:
                        summary[uid]["preview"] = htmltext.preview(
                            _decode_snippet(group["literals"][0]))
        except imaplib.IMAP4.error:
            pass

        return [summary[uid] for uid in sorted(summary)]

    def fetch_message(self, uid):
        data = self._ok(self.imap.uid("FETCH", str(int(uid)), "(RFC822)"),
                        f"Could not fetch message {uid}")
        for group in _group_fetch(data):
            if group["literals"]:
                return email.message_from_bytes(group["literals"][0],
                                                policy=email.policy.default)
        raise MailError(f"Message {uid} returned no content")

    # -- writing -----------------------------------------------------------
    def store_flags(self, uids, flags, add=True):
        if not uids:
            return
        command = "+FLAGS.SILENT" if add else "-FLAGS.SILENT"
        self._ok(self.imap.uid("STORE", uid_ranges(uids), command,
                               "(" + " ".join(flags) + ")"),
                 "Could not update flags")

    def move(self, uids, target):
        if not uids or not target:
            return
        ranges = uid_ranges(uids)
        if "MOVE" in self.capabilities:
            self._ok(self.imap.uid("MOVE", ranges, quote(target)),
                     f"Could not move messages to {target}")
            return
        self._ok(self.imap.uid("COPY", ranges, quote(target)),
                 f"Could not copy messages to {target}")
        self.store_flags(uids, ["\\Deleted"], add=True)
        self.expunge(uids)

    def expunge(self, uids=None):
        if uids and "UIDPLUS" in self.capabilities:
            self.imap.uid("EXPUNGE", uid_ranges(uids))
        else:
            self.imap.expunge()

    def append(self, folder, raw_bytes, flags="(\\Seen)"):
        if not folder:
            return
        self.imap.append(quote(folder), flags,
                         imaplib.Time2Internaldate(time.time()), raw_bytes)

    def idle(self, seconds):
        """Block until the server reports activity or `seconds` elapse."""
        events = []
        try:
            with self.imap.idle(duration=seconds) as idler:
                for typ, data in idler:
                    events.append((typ, data))
                    if typ in ("EXISTS", "EXPUNGE", "FETCH"):
                        break
        except (imaplib.IMAP4.error, OSError, AttributeError) as exc:
            raise MailError(f"IDLE failed: {exc}") from exc
        return events


_ROLE_GUESSES = {
    "sent": ["Sent", "Sent Items", "Sent Mail", "[Gmail]/Sent Mail", "INBOX.Sent"],
    "drafts": ["Drafts", "[Gmail]/Drafts", "INBOX.Drafts"],
    "trash": ["Trash", "Deleted Items", "Deleted", "[Gmail]/Trash", "INBOX.Trash"],
    "archive": ["Archive", "Archives", "All Mail", "[Gmail]/All Mail"],
    "junk": ["Junk", "Junk Email", "Spam", "[Gmail]/Spam", "INBOX.Junk"],
}


def _decode_snippet(raw):
    for encoding in ("utf-8", "latin-1"):
        try:
            text = raw.decode(encoding)
            break
        except UnicodeDecodeError:
            continue
    else:
        return ""
    if "<" in text and ">" in text:
        text = htmltext.to_text(text)
    return text


# ------------------------------------------------------------------ syncing

def header_row(account_id, folder, item):
    headers = item["headers"]
    def get(name):
        try:
            return decode_mime(headers.get(name, "")) if headers else ""
        except Exception:
            return ""
    senders = split_addresses(get("From"))
    sender = senders[0] if senders else {"name": "", "address": ""}
    flags = item["flags"]
    return {
        "account": account_id,
        "folder": folder,
        "uid": item["uid"],
        "message_id": get("Message-ID"),
        "subject": get("Subject"),
        "from_name": sender["name"],
        "from_addr": sender["address"],
        "to_addrs": [a["address"] for a in split_addresses(get("To"))],
        "cc_addrs": [a["address"] for a in split_addresses(get("Cc"))],
        "reply_to": (split_addresses(get("Reply-To")) or [{}])[0].get("address", ""),
        "date": parse_date(get("Date")) or int(time.time()),
        "size": item["size"],
        "seen": b"\\seen" in flags,
        "flagged": b"\\flagged" in flags,
        "answered": b"\\answered" in flags,
        "draft": b"\\draft" in flags,
        "attachments": item["attachments"],
        "preview": item.get("preview", ""),
    }


def sync_folder(session, conn, folder, limit=200, full=False):
    """Bring one folder's cached headers in line with the server."""
    account_id = session.account["id"]
    info = session.status(folder)
    known_validity, _ = store.folder_state(conn, account_id, folder)
    if known_validity and known_validity != info["uidvalidity"]:
        store.drop_folder(conn, account_id, folder)
    if full:
        store.drop_folder(conn, account_id, folder)

    session.select(folder, readonly=False)
    server_uids = session.search_uids("ALL", limit=limit)
    cached = store.known_uids(conn, account_id, folder)

    gone = cached - set(server_uids)
    # Only prune inside the window we actually looked at, so a limited sync
    # never deletes older cached mail it simply didn't ask about.
    if server_uids:
        window_floor = min(server_uids)
        gone = {uid for uid in gone if uid >= window_floor}
    if gone:
        store.delete_messages(conn, account_id, folder, gone)

    fresh = [uid for uid in server_uids if uid not in cached]
    added = 0
    for chunk in _chunks(fresh, 100):
        rows = [header_row(account_id, folder, item)
                for item in session.fetch_headers(chunk)]
        added += store.upsert_messages(conn, rows)

    # Flags change on messages we already have; refresh them for the window.
    existing = [uid for uid in server_uids if uid in cached]
    for chunk in _chunks(existing, 500):
        for uid, flags in session.fetch_flags(chunk).items():
            store.set_flags(conn, account_id, folder, [uid],
                            seen=b"\\seen" in flags,
                            flagged=b"\\flagged" in flags,
                            answered=b"\\answered" in flags)

    store.save_folders(conn, account_id, [{
        "name": folder,
        "special": "inbox" if folder.upper() == "INBOX" else "",
        "uidvalidity": info["uidvalidity"],
        "uidnext": info["uidnext"],
        "total": info["total"],
        "unseen": info["unseen"],
    }])
    return {"folder": folder, "added": added, "removed": len(gone),
            "total": info["total"], "unseen": info["unseen"]}


def _chunks(items, size):
    for start in range(0, len(items), size):
        yield items[start:start + size]
