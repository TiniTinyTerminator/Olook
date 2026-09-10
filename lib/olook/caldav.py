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

import datetime
import re
import urllib.error
import urllib.parse
import urllib.request
from xml.etree import ElementTree

from . import addressbook, oauth

DAV_NS = "DAV:"
CALDAV_NS = "urn:ietf:params:xml:ns:caldav"
APPLE_NS = "http://apple.com/ns/ical/"

# Google's CalDAV lives off the main API host and wants the account's own
# address in the path. Other providers are found by asking them.
GOOGLE_CALDAV = "https://apidata.googleusercontent.com/caldav/v2/"


class CalendarError(Exception):
    pass


def supports(account):
    """Whether this account has a calendar we know how to read.

    Google only, for now, and on the same grant the address book uses: the
    contacts application asks for the calendar scope alongside, so a client
    that can read one can usually read the other.
    """
    return (account.get("provider") == "gmail"
            and account.get("auth") == "oauth2"
            and not account.get("demo"))


def configured(account):
    return supports(account) and addressbook.configured(account)


def _root(account):
    return GOOGLE_CALDAV + urllib.parse.quote(account.get("email", "")) + "/"


# ------------------------------------------------------------------ requests

def _request(account, method, url, body=None, depth="0"):
    token = oauth.access_token(addressbook.grant(account))
    headers = {
        "Authorization": "Bearer " + token,
        "Depth": depth,
    }
    data = None
    if body is not None:
        data = body.encode("utf-8")
        headers["Content-Type"] = "application/xml; charset=utf-8"
    request = urllib.request.Request(url, data=data, method=method,
                                     headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=45) as response:
            return response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        if "caldav.googleapis.com" in detail or "accessNotConfigured" in detail:
            raise CalendarError(
                "The CalDAV API is not switched on for your Google project. "
                "Enable it once at "
                "https://console.cloud.google.com/apis/library/caldav.googleapis.com "
                "and try again.") from exc
        if exc.code in (401, 403):
            raise CalendarError(
                "Your application has not been given the calendar. Ask for it "
                "and sign in again: olook set " + str(account.get("id", ""))
                + " --contacts-scopes \"contacts calendar\", "
                "then olook contacts-auth.") from exc
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
            "id": url.rstrip("/").rsplit("/", 1)[-1],
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


def _split(line):
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


def _text(value):
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
        name, params, value = _split(line)
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
            current["summary"] = _text(value)
        elif name == "LOCATION":
            current["location"] = _text(value)
        elif name == "DESCRIPTION":
            current["description"] = _text(value)
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
