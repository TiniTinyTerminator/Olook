"""The calendar, read over CalDAV.

CalDAV rather than Google's own calendar API, because CalDAV is what every
other calendar speaks too -- Nextcloud, Fastmail, iCloud, a university's
Zimbra -- and the account that has one is rarely the account that has the
mail. The protocol is WebDAV with two extra verbs, and this uses the smallest
part of it that answers "what is on my calendar between these two dates".

Recurrence is left to the server. A weekly stand-up is one event with an
RRULE, and working out which Mondays it falls on -- through daylight saving,
through exceptions, through an occurrence someone moved -- is a great deal of
calendar arithmetic that CalDAV will do for you if you ask for the range
expanded. So this asks.
"""

import base64
import datetime
import re
import urllib.error
import urllib.parse
import urllib.request
from xml.etree import ElementTree

from . import config, keyring, net, oauth

DAV_NS = "DAV:"
CALDAV_NS = "urn:ietf:params:xml:ns:caldav"
APPLE_NS = "http://apple.com/ns/ical/"

# Google's CalDAV lives off the main API host and wants the account's own
# address in the path. Other providers are found by asking them.
GOOGLE_CALDAV = "https://apidata.googleusercontent.com/caldav/v2/"


class CalendarError(Exception):
    pass


# What the mail client's own application is allowed to ask Google for beyond
# the mail itself. Both are scopes Thunderbird's application is approved for
# -- it reaches Google contacts and calendars the same way, over DAV -- and
# borrowing them is what spares this from needing an application of its own.
#
# The People API scope is the one that is *not* on that list, which is what
# "app is blocked" meant the first time contacts were tried: auth/contacts
# and auth/carddav both reach the address book, and only the second is ours
# to ask for here.
DAV_SCOPES = ("https://www.googleapis.com/auth/carddav "
              "https://www.googleapis.com/auth/calendar")


def supports(account):
    """Whether this account has a calendar we know how to read."""
    if account.get("caldav"):
        return True
    return (account.get("provider") == "gmail"
            and account.get("auth") == "oauth2"
            and not account.get("demo"))


def configured(account):
    """Nothing to configure: the mail client id may ask for DAV itself."""
    return supports(account)


def grant(account):
    """A stand-in account for the DAV grant.

    Its own grant rather than the mail one because a scope cannot be widened
    after the fact -- an account signed in for mail alone holds a refresh
    token good for mail alone, and asking the token endpoint for more with it
    is refused. So the calendar asks separately, and the two tokens sit side
    by side.
    """
    oauth_config = account.get("oauth") or {}
    return {
        "id": account["id"] + "#dav",
        "reauth": "olook calendar-auth --account " + account["id"],
        "email": account.get("email", ""),
        "provider": "gmail",
        "auth": "oauth2",
        "oauth": {
            "flavor": "google",
            "client_id": oauth_config.get("client_id", ""),
            "client_secret": oauth_config.get("client_secret", ""),
            "scope": DAV_SCOPES,
            "exact": True,
        },
    }


# --------------------------------------------------------- any other server
#
# Nextcloud, Fastmail, iCloud, a university's Zimbra: a URL, a user name and
# a password (an app password, for the ones with two-factor sign-in). Each is
# kept as a calendar server of its own rather than hung off a mail account,
# because the account that has the calendar is rarely the one with the mail.
# Everything past the sign-in is the same CalDAV the Google path speaks.

SERVER_PREFIX = "dav-"


def servers(doc=None):
    document = doc if doc is not None else config.load()
    found = document.get("calendarServers")
    return [entry for entry in found if isinstance(entry, dict)] if found else []


def server_account(entry):
    """A calendar server in the shape the calendar commands take an account."""
    return {
        "id": str(entry.get("id")),
        "name": str(entry.get("name") or "Calendar"),
        "email": str(entry.get("username") or ""),
        "enabled": True,
        "provider": "caldav",
        "caldav": {"url": str(entry.get("url") or ""),
                   "username": str(entry.get("username") or "")},
    }


def add_server(name, url, username, password):
    """Remember a CalDAV server, once it has answered with its calendars."""
    url = str(url or "").strip()
    if not url.lower().startswith(("http://", "https://")):
        url = "https://" + url
    # The password goes with every request, as Basic auth.
    if url.lower().startswith("http://") and \
            not config.is_loopback(urllib.parse.urlparse(url).hostname):
        raise CalendarError("That server address is not https: the password would "
                            "travel unencrypted. Use its https:// address.")
    doc = config.load()
    existing = {str(e.get("id")) for e in servers(doc)}
    host = urllib.parse.urlparse(url).hostname or "calendar"
    base = SERVER_PREFIX + re.sub(r"[^a-z0-9]+", "-", host.lower()).strip("-")
    ident, n = base, 2
    while ident in existing:
        ident, n = f"{base}-{n}", n + 1
    entry = {"id": ident, "name": str(name or "").strip() or host,
             "url": url, "username": str(username or "").strip()}

    keyring.set_secret(ident, "password", password)
    try:
        found = calendars(server_account(entry))
    except CalendarError:
        keyring.clear_secret(ident, "password")
        raise
    doc.setdefault("calendarServers", []).append(entry)
    config.save(doc)
    return entry, found


def remove_server(ident):
    doc = config.load()
    before = servers(doc)
    doc["calendarServers"] = [e for e in before if str(e.get("id")) != ident]
    if len(doc["calendarServers"]) == len(before):
        raise CalendarError(f"No calendar server called {ident}.")
    config.save(doc)
    keyring.clear_secret(ident, "password")


def _root(account):
    return GOOGLE_CALDAV + urllib.parse.quote(account.get("email", "")) + "/"


def _check_target(account, url):
    """A server added by hand gets its password sent only to itself.

    The addresses of calendars and appointments come from the server, and it
    may name absolute ones. An address on another site, or plain http from an
    https server, would take the password somewhere it was never given.
    """
    generic = account.get("caldav")
    if generic and not net.keeps_credentials(generic.get("url") or "", url):
        raise CalendarError(f"The calendar server pointed at {url}, which is not "
                            "part of it; not sending it the password.")


def _authorization(account):
    generic = account.get("caldav")
    if generic:
        password = keyring.get_secret(account["id"], "password") or ""
        pair = f"{generic.get('username', '')}:{password}".encode("utf-8")
        return "Basic " + base64.b64encode(pair).decode("ascii")
    return "Bearer " + oauth.access_token(grant(account))


# ------------------------------------------------------------------ requests

def _request(account, method, url, body=None, depth="0"):
    _check_target(account, url)
    headers = {
        "Authorization": _authorization(account),
        "Depth": depth,
    }
    data = None
    if body is not None:
        data = body.encode("utf-8")
        headers["Content-Type"] = "application/xml; charset=utf-8"
    request = urllib.request.Request(url, data=data, method=method,
                                     headers=headers)
    try:
        with net.urlopen(request, timeout=45) as response:
            return response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        if account.get("caldav") and exc.code in (401, 403):
            raise CalendarError(
                "The server did not accept that user name and password. A "
                "server with two-step sign-in wants an app password.") from exc
        if "caldav.googleapis.com" in detail or "accessNotConfigured" in detail:
            raise CalendarError(
                "The CalDAV API is not switched on for the application this "
                "account signs in with. If that is one of your own, enable it "
                "once at https://console.cloud.google.com/apis/library/"
                "caldav.googleapis.com and try again.") from exc
        if exc.code in (401, 403):
            raise CalendarError(
                "This account has not been given its calendar yet. Sign in "
                "for it: olook calendar-auth --account "
                + str(account.get("id", ""))) from exc
        raise CalendarError(
            "Calendar request failed: %d %s" % (exc.code, _tidy(detail))) from exc
    except urllib.error.URLError as exc:
        raise CalendarError(f"Cannot reach the calendar: {exc.reason}") from exc


def _tidy(detail):
    text = re.sub(r"<[^>]+>", " ", detail or "")
    return " ".join(text.split())[:200]


def _multistatus(xml):
    """The <response> elements of a WebDAV multistatus, as (href, props)."""
    try:
        tree = ElementTree.fromstring(xml)
    except ElementTree.ParseError as exc:
        raise CalendarError("The calendar sent back something unreadable.") from exc
    out = []
    for response in tree.findall("{%s}response" % DAV_NS):
        href = response.findtext("{%s}href" % DAV_NS) or ""
        props = {}
        for propstat in response.findall("{%s}propstat" % DAV_NS):
            status = propstat.findtext("{%s}status" % DAV_NS) or ""
            if " 200 " not in status:
                continue
            prop = propstat.find("{%s}prop" % DAV_NS)
            if prop is not None:
                for child in prop:
                    props[child.tag] = child
        out.append((href, props))
    return out


def _absolute(url, href):
    return urllib.parse.urljoin(url, href)


def _prop_text(props, namespace, name):
    node = props.get("{%s}%s" % (namespace, name))
    return (node.text or "").strip() if node is not None else ""


def calendar_id(url):
    """A name for a calendar that is its own and not its neighbour's.

    Google ends every calendar with the same segment -- both the primary and
    a shared one live at .../<something>/events/ -- so the last segment
    called them both "events" and the second overwrote the first in a table
    keyed on it. The identity is the segment in front of that.
    """
    parts = [p for p in urllib.parse.urlparse(url).path.split("/") if p]
    while parts and parts[-1] in ("events", "calendar"):
        parts.pop()
    if not parts:
        return "calendar"
    return urllib.parse.unquote(parts[-1])


# ----------------------------------------------------------------- discovery

CALENDAR_PROPS = """<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"
            xmlns:a="http://apple.com/ns/ical/">
  <d:prop>
    <d:displayname/>
    <d:resourcetype/>
    <d:current-user-privilege-set/>
    <c:supported-calendar-component-set/>
    <a:calendar-color/>
  </d:prop>
</d:propfind>"""

HOME_PROPS = """<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:prop><c:calendar-home-set/></d:prop>
</d:propfind>"""

PRINCIPAL_PROPS = """<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:">
  <d:prop><d:current-user-principal/></d:prop>
</d:propfind>"""


def calendars(account):
    """Every calendar on the account, the writable ones marked as such."""
    if not configured(account):
        raise CalendarError("That account has no calendar configured.")

    if account.get("caldav"):
        # Ask where the calendars are rather than being told: a bare host
        # goes through /.well-known/caldav, and a URL with a path is taken
        # to be somewhere on the server that can say who we are.
        user_url = account["caldav"]["url"]
        if urllib.parse.urlparse(user_url).path in ("", "/"):
            user_url = user_url.rstrip("/") + "/.well-known/caldav"
    else:
        user_url = _root(account) + "user"
    principal = ""
    for href, props in _multistatus(
            _request(account, "PROPFIND", user_url, PRINCIPAL_PROPS)):
        node = props.get("{%s}current-user-principal" % DAV_NS)
        if node is not None:
            principal = _absolute(user_url, node.findtext("{%s}href" % DAV_NS) or "")
    if not principal:
        principal = user_url

    home = ""
    for href, props in _multistatus(
            _request(account, "PROPFIND", principal, HOME_PROPS)):
        node = props.get("{%s}calendar-home-set" % CALDAV_NS)
        if node is not None:
            home = _absolute(principal, node.findtext("{%s}href" % DAV_NS) or "")
    if not home:
        raise CalendarError("The account did not say where its calendars are.")

    found = []
    for href, props in _multistatus(
            _request(account, "PROPFIND", home, CALENDAR_PROPS, depth="1")):
        kind = props.get("{%s}resourcetype" % DAV_NS)
        if kind is None or kind.find("{%s}calendar" % CALDAV_NS) is None:
            continue
        # A calendar that holds only to-dos is not one to show as a calendar.
        components = props.get("{%s}supported-calendar-component-set" % CALDAV_NS)
        if components is not None:
            names = {c.get("name") for c in components}
            if names and "VEVENT" not in names:
                continue

        privileges = props.get("{%s}current-user-privilege-set" % DAV_NS)
        writable = False
        if privileges is not None:
            for privilege in privileges.iter("{%s}privilege" % DAV_NS):
                if privilege.find("{%s}write-content" % DAV_NS) is not None:
                    writable = True
        colour = _prop_text(props, APPLE_NS, "calendar-color")[:7]

        url = _absolute(home, href)
        found.append({
            "id": calendar_id(url),
            "url": url,
            "name": _prop_text(props, DAV_NS, "displayname") or "Calendar",
            "colour": colour,
            "readOnly": not writable,
        })
    found.sort(key=lambda c: c["name"].lower())
    return found


# -------------------------------------------------------------------- events

QUERY = """<?xml version="1.0" encoding="utf-8"?>
<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:prop>
    <d:getetag/>
    <c:calendar-data>
      <c:expand start="%(start)s" end="%(end)s"/>
    </c:calendar-data>
  </d:prop>
  <c:filter>
    <c:comp-filter name="VCALENDAR">
      <c:comp-filter name="VEVENT">
        <c:time-range start="%(start)s" end="%(end)s"/>
      </c:comp-filter>
    </c:comp-filter>
  </c:filter>
</c:calendar-query>"""


def _stamp(when):
    return when.astimezone(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def events(account, calendar, start, end):
    """Every occurrence in one calendar between two datetimes.

    The server expands recurrences into the range, so a weekly meeting comes
    back as one event per week rather than a rule to work out here.
    """
    body = QUERY % {"start": _stamp(start), "end": _stamp(end)}
    xml = _request(account, "REPORT", calendar["url"], body, depth="1")

    out = []
    for href, props in _multistatus(xml):
        node = props.get("{%s}calendar-data" % CALDAV_NS)
        if node is None or not node.text:
            continue
        etag = ""
        tag = props.get("{%s}getetag" % DAV_NS)
        if tag is not None and tag.text:
            etag = tag.text.strip()
        for event in parse_events(node.text):
            event["calendar"] = calendar["id"]
            event["calendarName"] = calendar["name"]
            event["colour"] = calendar["colour"]
            event["url"] = _absolute(calendar["url"], href)
            event["etag"] = etag
            event["readOnly"] = calendar["readOnly"]
            out.append(event)
    out.sort(key=lambda e: (e["start"], e["summary"].lower()))
    return out


# -------------------------------------------------------------- iCalendar

def unfold(text):
    """iCalendar wraps long lines; a leading space means "still the last one"."""
    lines = []
    for raw in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if raw[:1] in (" ", "\t") and lines:
            lines[-1] += raw[1:]
        else:
            lines.append(raw)
    return lines


def split_line(line):
    """NAME;PARAM=value:the value -- minding a colon inside a quoted param."""
    quoted = False
    for index, char in enumerate(line):
        if char == '"':
            quoted = not quoted
        elif char == ":" and not quoted:
            head, value = line[:index], line[index + 1:]
            break
    else:
        return "", {}, ""
    parts = head.split(";")
    name = parts[0].upper()
    params = {}
    for part in parts[1:]:
        if "=" in part:
            key, val = part.split("=", 1)
            params[key.upper()] = val.strip('"')
    return name, params, value


def unescape(value):
    """Undo the escaping iCalendar puts on free text."""
    out = []
    index = 0
    while index < len(value):
        char = value[index]
        if char == "\\" and index + 1 < len(value):
            nxt = value[index + 1]
            out.append({"n": "\n", "N": "\n"}.get(nxt, nxt))
            index += 2
            continue
        out.append(char)
        index += 1
    return "".join(out)


def _when(value, params):
    """A DTSTART or DTEND as (epoch seconds, all-day).

    Three shapes: a bare date for an all-day event, a UTC stamp ending in Z,
    and a local stamp carrying the zone it was written in.
    """
    value = value.strip()
    if params.get("VALUE", "").upper() == "DATE" or len(value) == 8:
        try:
            day = datetime.datetime.strptime(value, "%Y%m%d")
        except ValueError:
            return 0, True
        return int(day.replace(tzinfo=datetime.timezone.utc).timestamp()), True

    zone = datetime.timezone.utc
    stamp = value
    if stamp.endswith("Z"):
        stamp = stamp[:-1]
    elif params.get("TZID"):
        zone = _zone(params["TZID"])
    try:
        naive = datetime.datetime.strptime(stamp, "%Y%m%dT%H%M%S")
    except ValueError:
        return 0, False
    return int(naive.replace(tzinfo=zone).timestamp()), False


def _zone(name):
    try:
        from zoneinfo import ZoneInfo
        return ZoneInfo(name)
    except Exception:
        # An unknown zone is better read as UTC than not read at all.
        return datetime.timezone.utc


DURATION = re.compile(
    r"^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$")


def _duration(value):
    """An iCalendar DURATION -- P1DT2H30M and friends -- in seconds."""
    match = DURATION.match(value.strip().upper())
    if not match:
        return 0
    sign, weeks, days, hours, minutes, seconds = match.groups()
    total = (int(weeks or 0) * 604800 + int(days or 0) * 86400
             + int(hours or 0) * 3600 + int(minutes or 0) * 60 + int(seconds or 0))
    return -total if sign == "-" else total


def _day(start, all_day):
    when = datetime.datetime.fromtimestamp(
        start, datetime.timezone.utc if all_day else None)
    return when.strftime("%Y-%m-%d")


def parse_events(text):
    """The VEVENTs in an iCalendar document, as flat records."""
    out = []
    current = None
    depth_other = 0
    for line in unfold(text):
        name, params, value = split_line(line)
        if not name:
            continue
        if name == "BEGIN" and value.upper() == "VEVENT":
            current = {
                "uid": "", "summary": "", "location": "", "description": "",
                "organiser": "", "status": "", "start": 0, "end": 0,
                "allDay": False, "recurring": False,
            }
            continue
        if current is None:
            continue
        # A VALARM inside the event has its own TRIGGER and DESCRIPTION.
        if name == "BEGIN":
            depth_other += 1
            continue
        if name == "END" and depth_other:
            depth_other -= 1
            continue
        if name == "END" and value.upper() == "VEVENT":
            if current["end"] <= current["start"]:
                length = current.pop("duration", 0)
                current["end"] = current["start"] + (
                    length or (86400 if current["allDay"] else 3600))
            current.pop("duration", None)
            # The day it belongs on, worked out here so nothing downstream
            # has to know that an all-day event is stored as UTC midnight
            # and would slide into the day before if read as a local time.
            current["day"] = _day(current["start"], current["allDay"])
            out.append(current)
            current = None
            continue
        if depth_other:
            continue

        if name == "UID":
            current["uid"] = value.strip()
        elif name == "SUMMARY":
            current["summary"] = unescape(value)
        elif name == "LOCATION":
            current["location"] = unescape(value)
        elif name == "DESCRIPTION":
            current["description"] = unescape(value)
        elif name == "ORGANIZER":
            current["organiser"] = value.replace("mailto:", "").strip()
        elif name == "STATUS":
            current["status"] = value.strip().lower()
        elif name == "DTSTART":
            current["start"], current["allDay"] = _when(value, params)
        elif name == "DTEND":
            current["end"], _ = _when(value, params)
        elif name == "DURATION":
            current["duration"] = _duration(value)
        elif name in ("RRULE", "RECURRENCE-ID"):
            current["recurring"] = True
    return out


# -------------------------------------------------------------------- writing

def _ical_text(value):
    """Escape free text the way iCalendar wants it."""
    return (str(value or "").replace("\\", "\\\\").replace(";", "\\;")
            .replace(",", "\\,").replace("\r\n", "\\n").replace("\n", "\\n"))


def _fold(line):
    """Lines longer than 75 octets continue on the next, after a space."""
    raw = line.encode("utf-8")
    if len(raw) <= 75:
        return line
    pieces, current = [], b""
    for char in line:
        encoded = char.encode("utf-8")
        if len(current) + len(encoded) > (75 if not pieces else 74):
            pieces.append(current.decode("utf-8"))
            current = b""
        current += encoded
    pieces.append(current.decode("utf-8"))
    return "\r\n ".join(pieces)


def build_event(uid, fields):
    """One appointment as the iCalendar document a CalDAV server stores."""
    start, end = int(fields["start"]), int(fields["end"])
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Olook//Calendar//EN",
             "CALSCALE:GREGORIAN", "BEGIN:VEVENT", "UID:" + uid, "DTSTAMP:" + stamp]
    if fields.get("allDay"):
        # A date and nothing else, which floats: the same day wherever it is
        # read, rather than midnight somewhere that is the day before here.
        first = datetime.datetime.fromtimestamp(start, datetime.timezone.utc).date()
        last = datetime.datetime.fromtimestamp(end, datetime.timezone.utc).date()
        if last <= first:
            last = first + datetime.timedelta(days=1)
        lines.append("DTSTART;VALUE=DATE:" + first.strftime("%Y%m%d"))
        lines.append("DTEND;VALUE=DATE:" + last.strftime("%Y%m%d"))
    else:
        lines.append("DTSTART:" + datetime.datetime.fromtimestamp(
            start, datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ"))
        lines.append("DTEND:" + datetime.datetime.fromtimestamp(
            end, datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ"))
    lines.append("SUMMARY:" + _ical_text(fields.get("summary") or "New appointment"))
    if fields.get("location"):
        lines.append("LOCATION:" + _ical_text(fields["location"]))
    if fields.get("description"):
        lines.append("DESCRIPTION:" + _ical_text(fields["description"]))
    lines += ["END:VEVENT", "END:VCALENDAR"]
    return "\r\n".join(_fold(line) for line in lines) + "\r\n"


def _put(account, url, body, headers):
    _check_target(account, url)
    sending = {"Authorization": _authorization(account),
               "Content-Type": "text/calendar; charset=utf-8"}
    sending.update(headers or {})
    request = urllib.request.Request(url, data=body.encode("utf-8"),
                                     method="PUT", headers=sending)
    try:
        with net.urlopen(request, timeout=45) as response:
            return dict(response.headers)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        if exc.code in (401, 403):
            raise CalendarError(
                "This calendar will not take new appointments from here. "
                "It may be read-only, or the sign-in may only cover reading: "
                "olook calendar-auth --account " + str(account.get("id", ""))) from exc
        raise CalendarError(
            "Could not save the appointment: %d %s" % (exc.code, _tidy(detail))) from exc
    except urllib.error.URLError as exc:
        raise CalendarError(f"Cannot reach the calendar: {exc.reason}") from exc


def create_event(account, calendar, fields):
    """Add an appointment to one of the account's calendars."""
    import uuid as uuidlib
    uid = str(uuidlib.uuid4()) + "@olook"
    url = calendar["url"].rstrip("/") + "/" + urllib.parse.quote(uid) + ".ics"
    # If-None-Match stops a new appointment quietly replacing an old one that
    # happened to have the same name on the server.
    _put(account, url, build_event(uid, fields), {"If-None-Match": "*"})
    return uid


def delete_event(account, url):
    _check_target(account, url)
    request = urllib.request.Request(url, method="DELETE",
                                     headers={"Authorization": _authorization(account)})
    try:
        with net.urlopen(request, timeout=45):
            return True
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return True
        raise CalendarError(f"Could not delete the appointment: {exc.code}") from exc
    except urllib.error.URLError as exc:
        raise CalendarError(f"Cannot reach the calendar: {exc.reason}") from exc


def update_event(account, url, etag, uid, fields):
    """Rewrite one appointment in place.

    The etag is the guard against two edits crossing: the write is refused if
    the appointment moved on since it was read. The UID stays the same, or
    every device that syncs the calendar would see a new appointment and keep
    the old one.
    """
    headers = {"If-Match": etag} if etag else {}
    try:
        _put(account, url, build_event(uid, fields), headers)
    except CalendarError as exc:
        if "412" in str(exc):
            raise CalendarError("That appointment changed somewhere else since "
                                "it was fetched. Refresh and try again.") from exc
        raise
    return uid
