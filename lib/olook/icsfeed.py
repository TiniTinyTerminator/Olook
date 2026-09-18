"""Calendars that live in a file rather than on an account.

A university timetable is published as an .ics, either a file you download or
a link that keeps itself up to date, and it belongs to nobody's mailbox. This
reads both and hands back the same records the account calendars do, so the
month grid and the time grid never learn where a calendar came from.

The one thing this has to do that the account calendars do not is work out
recurrences. CalDAV and Graph are asked to expand a range and do it on the
server; a file is just a file, and a timetable is almost entirely rules --
"every Tuesday until January" -- so without expansion a term's teaching shows
up as one lecture in the first week.
"""

import datetime
import json
import os
import urllib.error
import urllib.parse
import urllib.request

from . import caldav, config

WEEKDAYS = {"MO": 0, "TU": 1, "WE": 2, "TH": 3, "FR": 4, "SA": 5, "SU": 6}

# A rule with no COUNT and no UNTIL repeats for ever. The window asked for
# ends it in practice, but a malformed rule should not spin.
MAX_OCCURRENCES = 2000


class FeedError(Exception):
    pass


# ------------------------------------------------------------------- sources

def sources(doc=None):
    """Every calendar kept in a file, as stored."""
    document = doc if doc is not None else config.load()
    found = document.get("calendars")
    return [entry for entry in found if isinstance(entry, dict)] if found else []


def add(name, source, colour=""):
    """Remember a calendar file or link."""
    source = str(source or "").strip()
    if not source:
        raise FeedError("A calendar needs a file or a link to read.")
    # webcal:// is an https link wearing a hat.
    if source.lower().startswith("webcal://"):
        source = "https://" + source[9:]
    if not source.lower().startswith(("http://", "https://")):
        source = os.path.abspath(os.path.expanduser(source))
        if not os.path.exists(source):
            raise FeedError(f"No such file: {source}")

    doc = config.load()
    found = sources(doc)
    entry = {
        "id": _identifier(name, source, found),
        "name": str(name or "").strip() or os.path.basename(source) or "Calendar",
        "source": source,
        "colour": str(colour or ""),
    }
    found.append(entry)
    doc["calendars"] = found
    config.save(doc)
    return entry


def remove(calendar_id):
    doc = config.load()
    found = sources(doc)
    kept = [entry for entry in found if entry.get("id") != str(calendar_id)]
    if len(kept) == len(found):
        raise FeedError(f"No calendar here called {calendar_id}.")
    doc["calendars"] = kept
    config.save(doc)
    return calendar_id


def _identifier(name, source, existing):
    base = "".join(ch if ch.isalnum() else "-"
                   for ch in (str(name or "") or os.path.basename(source)).lower())
    base = "-".join(part for part in base.split("-") if part) or "calendar"
    taken = {entry.get("id") for entry in existing}
    if base not in taken:
        return base
    for suffix in range(2, 99):
        candidate = f"{base}-{suffix}"
        if candidate not in taken:
            return candidate
    raise FeedError("Too many calendars by that name.")


def describe(entry):
    """One calendar, in the shape the client expects of any other."""
    return {
        "id": str(entry.get("id") or ""),
        "url": str(entry.get("source") or ""),
        "name": str(entry.get("name") or "Calendar"),
        "colour": str(entry.get("colour") or ""),
        # A file is read, never written back to.
        "readOnly": True,
    }


# -------------------------------------------------------------------- reading

def read(entry):
    source = str(entry.get("source") or "")
    if source.lower().startswith(("http://", "https://")):
        request = urllib.request.Request(
            source, headers={"User-Agent": "olook/1.0",
                             "Accept": "text/calendar, */*"})
        try:
            with urllib.request.urlopen(request, timeout=45) as response:
                return response.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as exc:
            raise FeedError(
                f"{entry.get('name')}: the link answered {exc.code}.") from exc
        except urllib.error.URLError as exc:
            raise FeedError(
                f"{entry.get('name')}: cannot reach the link — {exc.reason}") from exc
    try:
        with open(source, "r", encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError as exc:
        raise FeedError(f"{entry.get('name')}: cannot read {source} — {exc}") from exc


def events(entry, start, end):
    """Everything in this calendar that falls between two datetimes."""
    text = read(entry)
    if "BEGIN:VEVENT" not in text.upper():
        raise FeedError(f"{entry.get('name')}: that is not a calendar file.")

    described = describe(entry)
    begins = int(start.timestamp())
    finishes = int(end.timestamp())

    out = []
    for event in parse(text):
        for occurrence in expand(event, begins, finishes):
            occurrence["calendar"] = described["id"]
            occurrence["calendarName"] = described["name"]
            occurrence["colour"] = described["colour"]
            occurrence["url"] = ""
            occurrence["etag"] = ""
            occurrence["readOnly"] = True
            out.append(occurrence)
    out.sort(key=lambda e: (e["start"], e["summary"].lower()))
    return out


def parse(text):
    """The events in a document, each keeping the rule that repeats it.

    caldav.parse_events reads everything else; this only has to pick the
    recurrence out, which the server would otherwise have applied already.

    A series that had one occurrence moved or renamed carries it as a second
    VEVENT with the same UID and a RECURRENCE-ID naming the occurrence it
    replaces. That one stands on its own, and the series skips the slot.
    """
    base = caldav.parse_events(text)
    extras = _recurrence(text)
    if len(extras) != len(base):
        # Not the same VEVENTs in the same order: read nothing rather than
        # pin a rule on the wrong event.
        extras = [{"rrule": "", "exdates": [], "recurrenceId": 0}] * len(base)

    replaced = {}
    for event, extra in zip(base, extras):
        if extra["recurrenceId"] and event.get("uid"):
            replaced.setdefault(event["uid"], []).append(extra["recurrenceId"])

    out = []
    for event, extra in zip(base, extras):
        if extra["recurrenceId"]:
            if event.get("status") == "cancelled":
                continue
            event["rrule"], event["exdates"] = "", []
            event["recurring"] = True
        else:
            event["rrule"] = extra["rrule"]
            event["exdates"] = extra["exdates"] + replaced.get(event.get("uid"), [])
        out.append(event)
    return out


def _recurrence(text):
    """RRULE, EXDATE and RECURRENCE-ID for each VEVENT, in document order."""
    out = []
    current = None
    depth_other = 0
    for line in caldav.unfold(text):
        name, params, value = caldav.split_line(line)
        if not name:
            continue
        if name == "BEGIN" and value.upper() == "VEVENT":
            current = {"rrule": "", "exdates": [], "recurrenceId": 0}
            continue
        if current is None:
            continue
        if name == "BEGIN":
            depth_other += 1
            continue
        if name == "END" and depth_other:
            depth_other -= 1
            continue
        if name == "END" and value.upper() == "VEVENT":
            out.append(current)
            current = None
            continue
        if depth_other:
            continue
        if name == "RRULE":
            current["rrule"] = value.strip()
        elif name == "EXDATE":
            for part in value.split(","):
                when, _ = caldav._when(part.strip(), params)
                if when:
                    current["exdates"].append(when)
        elif name == "RECURRENCE-ID":
            current["recurrenceId"], _ = caldav._when(value.strip(), params)
    return out


# ---------------------------------------------------------------- recurrence

def expand(event, window_start, window_end):
    """One event as every occurrence of it inside the window."""
    length = max(0, int(event.get("end", 0)) - int(event.get("start", 0)))
    rule = parse_rule(event.get("rrule") or "")
    skip = set(event.get("exdates") or [])

    def shaped(start):
        out = dict(event)
        out.pop("rrule", None)
        out.pop("exdates", None)
        out["start"] = start
        out["end"] = start + length
        out["recurring"] = bool(rule)
        when = datetime.datetime.fromtimestamp(
            start, datetime.timezone.utc if event.get("allDay") else None)
        out["day"] = when.strftime("%Y-%m-%d")
        return out

    first = int(event.get("start", 0))
    if not rule:
        if first + length > window_start and first < window_end:
            return [shaped(first)]
        return []

    out = []
    for start in _occurrences(first, rule, window_end):
        if start in skip:
            continue
        if start + length <= window_start:
            continue
        if start >= window_end:
            break
        out.append(shaped(start))
    return out


def parse_rule(text):
    """FREQ=WEEKLY;BYDAY=TU,TH;UNTIL=... as a dictionary, or nothing."""
    if not text:
        return None
    rule = {}
    for part in str(text).split(";"):
        if "=" not in part:
            continue
        key, value = part.split("=", 1)
        rule[key.strip().upper()] = value.strip()
    if "FREQ" not in rule:
        return None
    return rule


def _occurrences(first, rule, window_end):
    """The start of each occurrence, earliest first.

    A subset of RFC 5545: the frequencies, INTERVAL, COUNT, UNTIL, BYDAY for
    weekly rules, and for monthly and yearly ones BYMONTHDAY, BYDAY with or
    without a position ("2TU", "-1FR"), BYMONTH and BYSETPOS. That covers a
    timetable and the usual "second Tuesday of the month". Anything else in
    the rule is ignored rather than guessed at, which yields the plain
    repetition instead of the wrong one.
    """
    freq = rule.get("FREQ", "").upper()
    try:
        interval = max(1, int(rule.get("INTERVAL", "1")))
    except ValueError:
        interval = 1
    count = None
    if rule.get("COUNT"):
        try:
            count = int(rule["COUNT"])
        except ValueError:
            count = None
    until = None
    if rule.get("UNTIL"):
        until, _ = caldav._when(rule["UNTIL"], {})
        if not until:
            until = None

    start = datetime.datetime.fromtimestamp(first)
    days = []
    if freq == "WEEKLY" and rule.get("BYDAY"):
        for token in rule["BYDAY"].split(","):
            token = token.strip().upper()[-2:]
            if token in WEEKDAYS:
                days.append(WEEKDAYS[token])
    if freq == "WEEKLY" and not days:
        days = [start.weekday()]

    produced = 0
    yielded = 0
    cursor = start
    while produced < MAX_OCCURRENCES:
        produced += 1
        moments = []
        if freq == "WEEKLY":
            # The Monday of the cursor's week, then each wanted weekday in it.
            monday = cursor - datetime.timedelta(days=cursor.weekday())
            for day in sorted(days):
                moments.append(monday + datetime.timedelta(days=day))
        elif freq in ("MONTHLY", "YEARLY") and (rule.get("BYMONTHDAY")
                                                 or rule.get("BYDAY")):
            months = [cursor.month]
            if freq == "YEARLY" and rule.get("BYMONTH"):
                months = sorted(_numbers(rule["BYMONTH"], 1, 12))
            for month in months:
                moments.extend(_month_moments(cursor.year, month, rule, start))
        else:
            moments.append(cursor)

        for moment in moments:
            when = int(moment.timestamp())
            if when < first:
                continue
            if until is not None and when > until:
                return
            yield when
            yielded += 1
            if count is not None and yielded >= count:
                return
            if when >= window_end:
                return

        if freq == "DAILY":
            cursor += datetime.timedelta(days=interval)
        elif freq == "WEEKLY":
            cursor += datetime.timedelta(weeks=interval)
        elif freq == "MONTHLY":
            cursor = _add_months(cursor, interval)
        elif freq == "YEARLY":
            cursor = _add_months(cursor, 12 * interval)
        else:
            return


def _numbers(text, low, high):
    """A comma list of integers, keeping those whose size is in range."""
    out = []
    for token in str(text).split(","):
        try:
            value = int(token)
        except ValueError:
            continue
        if low <= abs(value) <= high:
            out.append(value)
    return out


def _month_moments(year, month, rule, start):
    """Every day in one month a BYMONTHDAY / BYDAY / BYSETPOS rule picks.

    Days named both ways must satisfy both, as RFC 5545 has it. The time of
    day is the first occurrence's.
    """
    length = _days_in(year, month)
    chosen = None
    if rule.get("BYMONTHDAY"):
        chosen = set()
        for value in _numbers(rule["BYMONTHDAY"], 1, 31):
            day = value if value > 0 else length + 1 + value
            if 1 <= day <= length:
                chosen.add(day)
    if rule.get("BYDAY"):
        picked = set()
        for token in rule["BYDAY"].split(","):
            token = token.strip().upper()
            name, position = token[-2:], token[:-2]
            if name not in WEEKDAYS:
                continue
            matching = [d for d in range(1, length + 1)
                        if datetime.date(year, month, d).weekday() == WEEKDAYS[name]]
            if position:
                try:
                    index = int(position)
                except ValueError:
                    continue
                if index > 0 and index <= len(matching):
                    picked.add(matching[index - 1])
                elif index < 0 and -index <= len(matching):
                    picked.add(matching[index])
            else:
                picked.update(matching)
        chosen = picked if chosen is None else (chosen & picked)
    days = sorted(chosen or [])
    if rule.get("BYSETPOS") and days:
        kept = set()
        for position in _numbers(rule["BYSETPOS"], 1, 366):
            if position > 0 and position <= len(days):
                kept.add(days[position - 1])
            elif position < 0 and -position <= len(days):
                kept.add(days[position])
        days = sorted(kept)
    return [start.replace(year=year, month=month, day=day) for day in days]


def _add_months(when, months):
    """The same day in a later month, or the last day if it is shorter."""
    month = when.month - 1 + months
    year = when.year + month // 12
    month = month % 12 + 1
    day = min(when.day, _days_in(year, month))
    return when.replace(year=year, month=month, day=day)


def _days_in(year, month):
    if month == 12:
        return 31
    return (datetime.date(year + month // 12, month % 12 + 1, 1)
            - datetime.timedelta(days=1)).day
