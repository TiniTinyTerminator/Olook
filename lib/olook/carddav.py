"""The address book over CardDAV.

The same trade the calendar makes: Thunderbird's application is approved for
auth/carddav, so borrowing it means an account needs no application of its
own to reach its contacts -- no Google Cloud project, and no seven-day token
from an unpublished one.

It is a different door to the same address book the People API opens, and the
one this may knock on. auth/contacts is the scope that came back blocked;
auth/carddav is on the list. Both end up editing the contacts that sync to
the phone.

CardDAV is WebDAV carrying vCards, which share their line syntax with the
iCalendar the calendar reads -- the folding, the escaping and the
parameters are all the same -- so the reader lives in caldav and is used from
here.
"""

import html
import re
import urllib.error
import urllib.parse
import urllib.request
import uuid
from xml.etree import ElementTree

from . import caldav, net, oauth

DAV_NS = "DAV:"
CARDDAV_NS = "urn:ietf:params:xml:ns:carddav"

# Google publishes this as the address book's address; there is no discovery
# hop to make, unlike the calendar.
GOOGLE_CARDDAV = "https://www.googleapis.com/carddav/v1/principals/%s/lists/default/"


class AddressBookError(Exception):
    pass


def supports(account):
    return (account.get("provider") == "gmail"
            and account.get("auth") == "oauth2"
            and not account.get("demo"))


def configured(account):
    """Nothing to configure: the mail client id may ask for CardDAV itself."""
    return supports(account)


def grant(account):
    """The DAV grant, shared with the calendar: one sign-in covers both.

    Only the instruction differs. Either command authorises the same grant,
    and being told to sign in for the calendar when you asked for contacts
    reads like an answer to a different question.
    """
    shared = dict(caldav.grant(account))
    shared["reauth"] = "olook contacts-auth --account " + account["id"]
    return shared


def _collection(account):
    return GOOGLE_CARDDAV % urllib.parse.quote(account.get("email", ""))


# ------------------------------------------------------------------ requests

def _request(account, method, url, body=None, depth="0", headers=None,
             content_type="application/xml; charset=utf-8"):
    token = oauth.access_token(grant(account))
    sending = {"Authorization": "Bearer " + token, "Depth": depth}
    if headers:
        sending.update(headers)
    data = None
    if body is not None:
        data = body.encode("utf-8")
        sending["Content-Type"] = content_type

    request = urllib.request.Request(url, data=data, method=method,
                                     headers=sending)
    try:
        with net.urlopen(request, timeout=45) as response:
            return (response.read().decode("utf-8", "replace"),
                    dict(response.headers))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        if "carddav.googleapis.com" in detail or "accessNotConfigured" in detail:
            raise AddressBookError(
                "The CardDAV API is not switched on for the application this "
                "account signs in with. If that is one of your own, enable it "
                "once at https://console.cloud.google.com/apis/library/"
                "carddav.googleapis.com and try again.") from exc
        if exc.code in (401, 403):
            raise AddressBookError(
                "This account has not been given its address book yet. Sign "
                "in for it: olook contacts-auth --account "
                + str(account.get("id", ""))) from exc
        if exc.code in (412, 409):
            raise AddressBookError(
                "That contact changed somewhere else since it was fetched. "
                "Refresh the list and try again.") from exc
        raise AddressBookError(
            "Contacts request failed: %d %s" % (exc.code, _tidy(detail))) from exc
    except urllib.error.URLError as exc:
        raise AddressBookError(f"Cannot reach the address book: {exc.reason}") from exc


def _tidy(detail):
    return " ".join(re.sub(r"<[^>]+>", " ", detail or "").split())[:200]


QUERY = """<?xml version="1.0" encoding="utf-8"?>
<card:addressbook-query xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">
  <d:prop>
    <d:getetag/>
    <card:address-data/>
  </d:prop>
  <card:filter/>
</card:addressbook-query>"""


LIST = """<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:">
  <d:prop><d:getetag/><d:resourcetype/></d:prop>
</d:propfind>"""

MULTIGET = """<?xml version="1.0" encoding="utf-8"?>
<card:addressbook-multiget xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">
  <d:prop>
    <d:getetag/>
    <card:address-data/>
  </d:prop>
%s
</card:addressbook-multiget>"""

# Cards asked for per multiget: small enough for any server's request limit.
BATCH = 100


def fetch(account, limit=5000):
    """Every contact in the account's address book, as flat records.

    One addressbook-query first, which returns every card in one answer
    where a server supports it. Google stopped answering it in September
    2026 -- an empty multistatus, no error -- so when it comes back empty
    the cards are listed and fetched by address instead, the way any CardDAV
    server has to allow.
    """
    if not configured(account):
        raise AddressBookError("That account has no address book here.")
    url = _collection(account)
    xml, _ = _request(account, "REPORT", url, QUERY, depth="1")
    out = _cards(url, _parse(xml), limit)
    if out:
        return out

    listed, _ = _request(account, "PROPFIND", url, LIST, depth="1")
    hrefs = []
    for response in _parse(listed).findall("{%s}response" % DAV_NS):
        href = response.findtext("{%s}href" % DAV_NS) or ""
        if href and urllib.parse.urljoin(url, href).rstrip("/") != url.rstrip("/"):
            hrefs.append(href)
    for start in range(0, min(len(hrefs), limit), BATCH):
        batch = hrefs[start:start + BATCH]
        body = MULTIGET % "\n".join(
            "  <d:href>%s</d:href>" % html.escape(href) for href in batch)
        xml, _ = _request(account, "REPORT", url, body, depth="1")
        out.extend(_cards(url, _parse(xml), limit - len(out)))
        if len(out) >= limit:
            break
    return out


def _parse(xml):
    try:
        return ElementTree.fromstring(xml)
    except ElementTree.ParseError as exc:
        raise AddressBookError(
            "The address book sent back something unreadable.") from exc


def _cards(url, tree, limit):
    """The contacts in a multistatus answer carrying address-data."""
    out = []
    for response in tree.findall("{%s}response" % DAV_NS):
        href = response.findtext("{%s}href" % DAV_NS) or ""
        card, etag = "", ""
        for propstat in response.findall("{%s}propstat" % DAV_NS):
            status = propstat.findtext("{%s}status" % DAV_NS) or ""
            if " 200 " not in status:
                continue
            prop = propstat.find("{%s}prop" % DAV_NS)
            if prop is None:
                continue
            data = prop.find("{%s}address-data" % CARDDAV_NS)
            if data is not None and data.text:
                card = data.text
            tag = prop.find("{%s}getetag" % DAV_NS)
            if tag is not None and tag.text:
                etag = tag.text.strip()
        if not card:
            continue
        person = parse_card(card)
        if not person["name"] and not person["emails"] and not person["phones"]:
            continue
        person["resource"] = urllib.parse.urljoin(url, href)
        person["etag"] = etag
        out.append(person)
        if len(out) >= limit:
            break
    return out


# --------------------------------------------------------------------- vCard

def parse_card(text):
    """One vCard as the flat record the rest of the client passes around."""
    person = {"resource": "", "etag": "", "name": "", "emails": [],
              "phones": [], "organisation": "", "photo": "", "uid": ""}
    structured = ""
    for line in caldav.unfold(text):
        name, params, value = caldav.split_line(line)
        if not name:
            continue
        # A property can be group-prefixed: item1.EMAIL is still an EMAIL.
        if "." in name:
            name = name.rsplit(".", 1)[-1]
        if name == "FN":
            person["name"] = caldav.unescape(value).strip()
        elif name == "N" and not structured:
            structured = value
        elif name == "EMAIL":
            address = caldav.unescape(value).strip().lower()
            if address and address not in person["emails"]:
                person["emails"].append(address)
        elif name == "TEL":
            number = caldav.unescape(value).strip()
            if number and number not in person["phones"]:
                person["phones"].append(number)
        elif name == "ORG":
            # ORG is semicolon-separated: company;department;team.
            person["organisation"] = caldav.unescape(
                value.split(";")[0]).strip()
        elif name == "UID":
            person["uid"] = value.strip()
        elif name == "PHOTO":
            person["photo"] = _photo(params, value)

    if not person["name"] and structured:
        # N is Family;Given;Middle;Prefix;Suffix, written the way it reads.
        parts = [caldav.unescape(p).strip() for p in structured.split(";")]
        while len(parts) < 5:
            parts.append("")
        person["name"] = " ".join(
            p for p in (parts[3], parts[1], parts[2], parts[0], parts[4]) if p)
    return person


def _photo(params, value):
    """A vCard photo as something an image element can be handed.

    Two shapes in the wild: the bytes inline, base64, which become a data URI
    without a second request; and a URL, which is already one. A card with
    neither is a card with no picture.
    """
    value = value.strip()
    # A URL is fetched when the contact is looked at, so only over https;
    # inline data only as an image.
    if value.lower().startswith(("https://", "data:image/")):
        return value
    if value.lower().startswith(("http://", "data:")):
        return ""
    encoding = (params.get("ENCODING") or "").upper()
    if encoding not in ("B", "BASE64") and not params.get("TYPE"):
        return ""
    kind = str(params.get("TYPE") or "JPEG").split(",")[0].lower()
    if kind.startswith("image/"):
        kind = kind.split("/", 1)[1]
    return "data:image/%s;base64,%s" % (kind or "jpeg", value)


def _escape(value):
    return (str(value or "").replace("\\", "\\\\").replace(";", "\\;")
            .replace(",", "\\,").replace("\n", "\\n"))


def build_card(contact, uid):
    """A vCard 3.0, which is what Google's CardDAV wants written to it."""
    name = str(contact.get("name") or "").strip()
    parts = name.split()
    given = parts[0] if parts else ""
    family = " ".join(parts[1:]) if len(parts) > 1 else ""

    lines = ["BEGIN:VCARD", "VERSION:3.0", "UID:" + uid]
    lines.append("FN:" + _escape(name))
    lines.append("N:%s;%s;;;" % (_escape(family), _escape(given)))
    for address in contact.get("emails") or []:
        address = str(address or "").strip()
        if address:
            lines.append("EMAIL;TYPE=INTERNET:" + _escape(address))
    for index, number in enumerate(contact.get("phones") or []):
        number = str(number or "").strip()
        if number:
            # The first number is the one a phone should ring.
            kind = "CELL" if index == 0 else "VOICE"
            lines.append("TEL;TYPE=%s:%s" % (kind, _escape(number)))
    organisation = str(contact.get("organisation") or "").strip()
    if organisation:
        lines.append("ORG:" + _escape(organisation))
    lines.append("END:VCARD")
    return "\r\n".join(lines) + "\r\n"


# ------------------------------------------------------------------- writing

def create(account, contact):
    if not str(contact.get("name") or "").strip():
        raise AddressBookError("A contact needs at least a name.")
    uid = str(uuid.uuid4())
    url = _collection(account) + uid + ".vcf"
    _, headers = _request(account, "PUT", url, build_card(contact, uid),
                          headers={"If-None-Match": "*"},
                          content_type="text/vcard; charset=utf-8")
    return _saved(account, url, headers, contact, uid)


def update(account, resource, etag, contact):
    if not resource:
        raise AddressBookError("That contact has no address-book entry to edit.")
    # The UID has to survive the edit: a vCard written back under a new one
    # is a new contact to every device that syncs this book, leaving the old
    # one behind. It is read off the card being replaced rather than guessed
    # from the URL, because the two only look alike.
    uid = str(contact.get("uid") or "")
    if not uid:
        try:
            existing, _ = _request(account, "GET", resource)
            uid = parse_card(existing).get("uid") or ""
        except AddressBookError:
            uid = ""
    if not uid:
        uid = resource.rstrip("/").rsplit("/", 1)[-1]
        if uid.endswith(".vcf"):
            uid = uid[:-4]

    # The etag is the guard against two edits crossing; without one the write
    # would silently win over whatever else had changed the contact.
    headers = {"If-Match": etag} if etag else None
    _, response_headers = _request(account, "PUT", resource,
                                   build_card(contact, uid), headers=headers,
                                   content_type="text/vcard; charset=utf-8")
    return _saved(account, resource, response_headers, contact, uid)


def remove(account, resource):
    if not resource:
        raise AddressBookError("That contact has no address-book entry to delete.")
    _request(account, "DELETE", resource)
    return resource


def _saved(account, url, headers, contact, uid):
    """What the contact looks like now, from the write's own answer.

    A server that returns the new etag saves a round trip; one that does not
    -- which is allowed -- leaves the etag blank, and the next refresh fills
    it in. Blank is honest: an edit made against no etag is refused rather
    than risking a silent overwrite.
    """
    return {
        "resource": url,
        "etag": str(headers.get("ETag") or headers.get("Etag") or "").strip(),
        "uid": uid,
        "name": str(contact.get("name") or "").strip(),
        "emails": [str(a).strip().lower() for a in (contact.get("emails") or []) if a],
        "phones": [str(p).strip() for p in (contact.get("phones") or []) if p],
        "organisation": str(contact.get("organisation") or "").strip(),
        "photo": "",
    }
