"""Local message cache.

The panel has to paint in a few milliseconds when it opens, and IMAP round
trips are nowhere near that fast, so every header the sync pulls lands in
SQLite and the UI only ever reads from here. Bodies are cached on first open.

UIDVALIDITY is honored: when a server resets it, the folder's rows are dropped
rather than silently mismatched against new messages.
"""

import datetime
import json
import re
import sqlite3
import time

from . import config

SCHEMA = """
CREATE TABLE IF NOT EXISTS folders (
  account   TEXT NOT NULL,
  name      TEXT NOT NULL,
  delimiter TEXT DEFAULT '/',
  special   TEXT DEFAULT '',
  uidvalidity INTEGER DEFAULT 0,
  uidnext     INTEGER DEFAULT 0,
  total       INTEGER DEFAULT 0,
  unseen      INTEGER DEFAULT 0,
  synced_at   INTEGER DEFAULT 0,
  PRIMARY KEY (account, name)
);

CREATE TABLE IF NOT EXISTS messages (
  account    TEXT NOT NULL,
  folder     TEXT NOT NULL,
  uid        INTEGER NOT NULL,
  message_id TEXT DEFAULT '',
  refs       TEXT DEFAULT '',
  in_reply_to TEXT DEFAULT '',
  keywords   TEXT DEFAULT '',
  subject    TEXT DEFAULT '',
  from_name  TEXT DEFAULT '',
  from_addr  TEXT DEFAULT '',
  to_addrs   TEXT DEFAULT '',
  cc_addrs   TEXT DEFAULT '',
  reply_to   TEXT DEFAULT '',
  date       INTEGER DEFAULT 0,
  size       INTEGER DEFAULT 0,
  seen       INTEGER DEFAULT 0,
  flagged    INTEGER DEFAULT 0,
  answered   INTEGER DEFAULT 0,
  draft      INTEGER DEFAULT 0,
  attachments INTEGER DEFAULT 0,
  preview    TEXT DEFAULT '',
  PRIMARY KEY (account, folder, uid)
);

CREATE INDEX IF NOT EXISTS messages_by_date
  ON messages (account, folder, date DESC);
CREATE INDEX IF NOT EXISTS messages_unseen
  ON messages (account, seen, date DESC);

CREATE TABLE IF NOT EXISTS bodies (
  account TEXT NOT NULL,
  folder  TEXT NOT NULL,
  uid     INTEGER NOT NULL,
  text    TEXT DEFAULT '',
  html    TEXT DEFAULT '',
  parts   TEXT DEFAULT '[]',
  headers TEXT DEFAULT '{}',
  fetched_at INTEGER DEFAULT 0,
  PRIMARY KEY (account, folder, uid)
);

CREATE TABLE IF NOT EXISTS address_book (
  account   TEXT NOT NULL,
  resource  TEXT NOT NULL,
  name      TEXT DEFAULT '',
  emails    TEXT DEFAULT '[]',
  phones    TEXT DEFAULT '[]',
  organisation TEXT DEFAULT '',
  photo     TEXT DEFAULT '',
  etag      TEXT DEFAULT '',
  PRIMARY KEY (account, resource)
);

CREATE TABLE IF NOT EXISTS events (
  account   TEXT NOT NULL,
  calendar  TEXT NOT NULL,
  uid       TEXT NOT NULL,
  start     INTEGER NOT NULL,
  end       INTEGER DEFAULT 0,
  day       TEXT DEFAULT '',
  all_day   INTEGER DEFAULT 0,
  summary   TEXT DEFAULT '',
  location  TEXT DEFAULT '',
  description TEXT DEFAULT '',
  organiser TEXT DEFAULT '',
  status    TEXT DEFAULT '',
  colour    TEXT DEFAULT '',
  calendar_name TEXT DEFAULT '',
  recurring INTEGER DEFAULT 0,
  read_only INTEGER DEFAULT 0,
  url       TEXT DEFAULT '',
  etag      TEXT DEFAULT '',
  -- An expanded recurrence repeats the uid, so the occurrence needs the
  -- start in the key to be a row of its own.
  PRIMARY KEY (account, calendar, uid, start)
);

CREATE INDEX IF NOT EXISTS events_by_day ON events (day);

CREATE TABLE IF NOT EXISTS calendars (
  account   TEXT NOT NULL,
  id        TEXT NOT NULL,
  name      TEXT DEFAULT '',
  colour    TEXT DEFAULT '',
  url       TEXT DEFAULT '',
  read_only INTEGER DEFAULT 0,
  hidden    INTEGER DEFAULT 0,
  PRIMARY KEY (account, id)
);

CREATE TABLE IF NOT EXISTS state (
  key   TEXT PRIMARY KEY,
  value TEXT
);
"""

MESSAGE_COLUMNS = (
    "account, folder, uid, message_id, refs, in_reply_to, keywords, subject, "
    "from_name, from_addr, to_addrs, cc_addrs, reply_to, date, size, seen, "
    "flagged, answered, draft, attachments, preview"
)


def connect():
    config.ensure_dirs()
    conn = sqlite3.connect(str(config.DB_PATH), timeout=15)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.executescript(SCHEMA)
    _add_missing_columns(conn)
    return conn


# Columns added after the first version of the schema. CREATE TABLE IF NOT
# EXISTS does nothing for a table that already exists, so a cache made before
# these were thought of needs them put on by hand.
LATER_COLUMNS = {
    "address_book": [
        ("etag", "TEXT DEFAULT ''"),
    ],
    "messages": [
        ("refs", "TEXT DEFAULT ''"),
        ("in_reply_to", "TEXT DEFAULT ''"),
        ("keywords", "TEXT DEFAULT ''"),
    ],
}


def _add_missing_columns(conn):
    for table, columns in LATER_COLUMNS.items():
        have = {row["name"] for row in conn.execute(f"PRAGMA table_info({table})")}
        for name, kind in columns:
            if name not in have:
                conn.execute(f"ALTER TABLE {table} ADD COLUMN {name} {kind}")
    conn.commit()


def row_to_message(row):
    return {
        "account": row["account"],
        "folder": row["folder"],
        "uid": row["uid"],
        "messageId": row["message_id"],
        "references": row["refs"] if "refs" in row.keys() else "",
        "inReplyTo": row["in_reply_to"] if "in_reply_to" in row.keys() else "",
        "categories": (row["keywords"] if "keywords" in row.keys() else "").split(),
        "subject": row["subject"] or "(no subject)",
        "fromName": row["from_name"],
        "fromAddr": row["from_addr"],
        "to": json.loads(row["to_addrs"] or "[]"),
        "cc": json.loads(row["cc_addrs"] or "[]"),
        "replyTo": row["reply_to"],
        "date": row["date"],
        "size": row["size"],
        "seen": bool(row["seen"]),
        "flagged": bool(row["flagged"]),
        "answered": bool(row["answered"]),
        "draft": bool(row["draft"]),
        "attachments": row["attachments"],
        "preview": row["preview"] or "",
    }


def upsert_messages(conn, rows):
    """rows: list of dicts using the physical column names."""
    if not rows:
        return 0
    placeholders = ", ".join(["?"] * 21)
    conn.executemany(
        f"INSERT OR REPLACE INTO messages ({MESSAGE_COLUMNS}) VALUES ({placeholders})",
        [(
            r["account"], r["folder"], r["uid"], r.get("message_id", ""),
            r.get("refs", ""), r.get("in_reply_to", ""), r.get("keywords", ""),
            r.get("subject", ""), r.get("from_name", ""), r.get("from_addr", ""),
            json.dumps(r.get("to_addrs", [])), json.dumps(r.get("cc_addrs", [])),
            r.get("reply_to", ""), int(r.get("date", 0)), int(r.get("size", 0)),
            int(bool(r.get("seen"))), int(bool(r.get("flagged"))),
            int(bool(r.get("answered"))), int(bool(r.get("draft"))),
            int(r.get("attachments", 0)), r.get("preview", ""),
        ) for r in rows])
    conn.commit()
    return len(rows)


# What "sorted" can mean, and the SQL behind each. Date, newest first, is the
# only thing a mail client can sensibly default to; the rest are for finding
# something half remembered.
ORDERINGS = {
    "date": "date DESC, uid DESC",
    "sender": "LOWER(COALESCE(NULLIF(from_name, ''), from_addr)) ASC, date DESC",
    "subject": "LOWER(subject) ASC, date DESC",
    "size": "size DESC, date DESC",
    "unread": "seen ASC, date DESC",
}


def ordering(name):
    return ORDERINGS.get(str(name or "date"), ORDERINGS["date"])


# Search terms that mean something more particular than "these words appear
# somewhere". Outlook has a panel of refiners; the same work is done here by
# typing, which costs no screen and is faster once known.
TERM = re.compile(r"""(\w+):("[^"]*"|\S*)""")


def parse_query(text):
    """Split a search box into its terms and whatever is left as free text.

    Understood: from:, to:, subject:, has:attachment, is:unread, is:read,
    is:flagged. Anything else is left in the free text, so a colon in an
    ordinary search is not quietly eaten.
    """
    filters = {"from": [], "to": [], "subject": [], "category": [],
               "before": None, "after": None,
               "unread": None, "flagged": None, "attachment": None}
    rest = []
    position = 0
    for match in TERM.finditer(str(text or "")):
        field = match.group(1).lower()
        value = match.group(2).strip('"')
        claimed = True
        if field in ("category", "label", "tag") and value:
            filters["category"].append(value)
        elif field in ("from", "to", "subject") and value:
            filters[field].append(value)
        elif field == "is" and value.lower() in ("unread", "read"):
            filters["unread"] = value.lower() == "unread"
        elif field == "is" and value.lower() == "flagged":
            filters["flagged"] = True
        elif field == "has" and value.lower() in ("attachment", "attachments"):
            filters["attachment"] = True
        elif field in ("before", "after", "since", "until"):
            when = _as_epoch(value)
            if when is None:
                claimed = False
            else:
                filters["after" if field in ("after", "since") else "before"] = when
        else:
            claimed = False
        if claimed:
            rest.append(text[position:match.start()])
            position = match.end()
    rest.append(text[position:])
    return " ".join(" ".join(rest).split()), filters


def _as_epoch(value):
    """A date in a search box: 2026-09-01, or 7d / 2w / 3m back from now."""
    text = str(value or "").strip()
    if not text:
        return None
    relative = re.fullmatch(r"(\d+)([dwmy])", text, re.IGNORECASE)
    if relative:
        span = int(relative.group(1))
        days = {"d": 1, "w": 7, "m": 30, "y": 365}[relative.group(2).lower()]
        return int(time.time()) - span * days * 86400
    for shape in ("%Y-%m-%d", "%d-%m-%Y", "%Y/%m/%d"):
        try:
            return int(datetime.datetime.strptime(text, shape).timestamp())
        except ValueError:
            continue
    return None


def query_clauses(text):
    """Turn a search box into SQL conditions and their parameters."""
    free, filters = parse_query(text)
    where, params = [], []

    def like(column, values):
        for value in values:
            where.append(f"{column} LIKE ?")
            params.append(f"%{value}%")

    like("(from_name || ' ' || from_addr)", filters["from"])
    like("to_addrs", filters["to"])
    like("subject", filters["subject"])
    like("keywords", filters["category"])
    if filters["unread"] is not None:
        where.append("seen = ?")
        params.append(0 if filters["unread"] else 1)
    if filters["flagged"]:
        where.append("flagged = 1")
    if filters["attachment"]:
        where.append("attachments > 0")
    if filters["after"] is not None:
        where.append("date >= ?")
        params.append(filters["after"])
    if filters["before"] is not None:
        where.append("date <= ?")
        params.append(filters["before"])
    if free:
        where.append("(subject LIKE ? OR from_name LIKE ? OR from_addr LIKE ? "
                     "OR preview LIKE ?)")
        params.extend([f"%{free}%"] * 4)
    return where, params


def list_messages(conn, account, folder=None, limit=100, offset=0,
                  unread_only=False, flagged_only=False, query="", sort="date"):
    where = ["account = ?"]
    params = [account]
    if folder:
        where.append("folder = ?")
        params.append(folder)
    if unread_only:
        where.append("seen = 0")
    if flagged_only:
        where.append("flagged = 1")
    if query:
        extra_where, extra_params = query_clauses(query)
        where.extend(extra_where)
        params.extend(extra_params)
    sql = (f"SELECT * FROM messages WHERE {' AND '.join(where)} "
           f"ORDER BY {ordering(sort)} LIMIT ? OFFSET ?")
    params.extend([int(limit), int(offset)])
    return [row_to_message(row) for row in conn.execute(sql, params)]


def list_across(conn, pairs, limit=100, offset=0, unread_only=False,
                flagged_only=False, query="", sort="date"):
    """List messages from several (account, folder) mailboxes at once.

    One query rather than one per account, so the merged list is sorted by
    date across all of them instead of being stitched together afterwards and
    truncated in the wrong place.
    """
    if not pairs:
        return []
    where = ["(" + " OR ".join(["(account = ? AND folder = ?)"] * len(pairs)) + ")"]
    params = []
    for account, folder in pairs:
        params.extend([account, folder])
    if unread_only:
        where.append("seen = 0")
    if flagged_only:
        where.append("flagged = 1")
    if query:
        extra_where, extra_params = query_clauses(query)
        where.extend(extra_where)
        params.extend(extra_params)
    sql = (f"SELECT * FROM messages WHERE {' AND '.join(where)} "
           f"ORDER BY {ordering(sort)} LIMIT ? OFFSET ?")
    params.extend([int(limit), int(offset)])
    return [row_to_message(row) for row in conn.execute(sql, params)]


def contacts(conn, accounts=None, mine=(), query="", limit=500):
    """Everyone the cached mail has been to or from, most written-to first.

    Built from what is already on disk rather than from an address book: the
    people worth showing are the ones actually corresponded with, and the
    ranking that matters is how often and how recently.
    """
    where, params = [], []
    if accounts:
        where.append("account IN (%s)" % ",".join("?" * len(accounts)))
        params.extend(accounts)
    sql = ("SELECT account, folder, from_name, from_addr, to_addrs, cc_addrs, date "
           "FROM messages")
    if where:
        sql += " WHERE " + " AND ".join(where)

    # Your own addresses are on nearly every message and are not people you
    # correspond with; they would take the top of the list and stay there.
    own = {str(address or "").strip().lower() for address in (mine or ())}
    people = {}

    def note(name, address, date, account, outgoing):
        address = str(address or "").strip().lower()
        if not address or "@" not in address or address in own:
            return
        entry = people.get(address)
        if entry is None:
            entry = people[address] = {
                "address": address, "name": "", "messages": 0,
                "received": 0, "sent": 0, "lastSeen": 0, "accounts": [],
            }
        # The prettiest name wins: senders give one, recipient lists rarely do.
        name = str(name or "").strip()
        if name and (not entry["name"] or len(name) > len(entry["name"])):
            entry["name"] = name
        entry["messages"] += 1
        entry["sent" if outgoing else "received"] += 1
        entry["lastSeen"] = max(entry["lastSeen"], int(date or 0))
        if account not in entry["accounts"]:
            entry["accounts"].append(account)

    def listed(value):
        # Stored as a JSON array; older rows may still be a plain string.
        try:
            parsed = json.loads(value or "[]")
        except ValueError:
            return [part for part in str(value or "").split(",") if part.strip()]
        return parsed if isinstance(parsed, list) else [parsed]

    for row in conn.execute(sql, params):
        outgoing = "sent" in str(row["folder"] or "").lower()
        note(row["from_name"], row["from_addr"], row["date"], row["account"], False)
        for field in ("to_addrs", "cc_addrs"):
            for address in listed(row[field]):
                note("", address, row["date"], row["account"], outgoing)

    # The address book comes in on top: a real name beats a From line, a
    # phone number has no other source, and someone you have a number for but
    # have never written to belongs in the list even with no mail behind them.
    for person in address_book(conn, accounts):
        addresses = [a for a in person["emails"] if a]
        for address in addresses:
            entry = people.get(address)
            if entry is None:
                entry = people[address] = {
                    "address": address, "name": "", "messages": 0,
                    "received": 0, "sent": 0, "lastSeen": 0, "accounts": [],
                }
            if person["name"]:
                entry["name"] = person["name"]
            entry["phones"] = person["phones"]
            entry["organisation"] = person["organisation"]
            entry["inAddressBook"] = True
            # Which row in which account's book this came from, so an edit
            # knows what it is editing and an edit knows its etag.
            entry["resource"] = person["resource"]
            entry["etag"] = person["etag"]
            entry["bookAccount"] = person["account"]
            entry["bookEmails"] = person["emails"]
            if person.get("photo"):
                entry["photo"] = person["photo"]
        if not addresses and person["name"]:
            # A contact with a number and no address still belongs here.
            key = "book:" + person["name"].lower()
            people.setdefault(key, {
                "address": "", "name": person["name"], "messages": 0,
                "received": 0, "sent": 0, "lastSeen": 0,
                "accounts": [person["account"]],
                "phones": person["phones"],
                "organisation": person["organisation"],
                "inAddressBook": True,
                "resource": person["resource"],
                "etag": person["etag"],
                "bookAccount": person["account"],
                "bookEmails": person["emails"],
                "photo": person.get("photo", ""),
            })

    found = list(people.values())
    for entry in found:
        entry.setdefault("phones", [])
        entry.setdefault("organisation", "")
        entry.setdefault("inAddressBook", False)
        entry.setdefault("resource", "")
        entry.setdefault("etag", "")
        entry.setdefault("bookAccount", "")
        entry.setdefault("bookEmails", [])
        entry.setdefault("photo", "")
    if query:
        needle = query.strip().lower()
        found = [p for p in found
                 if needle in p["address"] or needle in p["name"].lower()
                 or any(needle in phone for phone in p["phones"])]
    # Correspondents first, then the rest of the book by name: someone you
    # write to weekly should not be below someone whose number you once saved.
    found.sort(key=lambda p: (-p["messages"], -p["lastSeen"],
                              p["name"].lower() or p["address"]))
    return found[:int(limit)]


# "Re:", "Fwd:", and the ones other languages put in front of the same thing.
REPLY_PREFIX = re.compile(r"^\s*((re|fwd|fw|aw|antw|sv|vs|rif)\s*(\[\d+\])?\s*:\s*)+",
                          re.IGNORECASE)


def subject_key(message):
    """The fallback: subject with the reply prefixes stripped.

    Used only for messages that carry no threading headers at all. A message
    with no subject either is its own conversation rather than joining a pile
    of every other blank one.
    """
    subject = REPLY_PREFIX.sub("", str(message.get("subject") or "")).strip().lower()
    if not subject:
        return "uid:%s:%s:%s" % (message.get("account"), message.get("folder"),
                                 message.get("uid"))
    return "subject:" + subject


def message_ids(message):
    """Every id this message ties itself to, its own included."""
    ids = []
    own = str(message.get("messageId") or "").strip()
    if own:
        ids.append(own)
    parent = str(message.get("inReplyTo") or "").strip()
    if parent:
        ids.append(parent)
    ids.extend(str(message.get("references") or "").split())
    return ids


class _Threads:
    """Union-find over message ids.

    A reply names the message it answers and usually the whole chain behind
    it; the first message of a thread names nothing and is named by everyone
    after it. Neither is enough on its own, so ids that appear together are
    merged and the thread is whatever ends up in the same set.
    """

    def __init__(self):
        self.parent = {}

    def find(self, key):
        self.parent.setdefault(key, key)
        while self.parent[key] != key:
            self.parent[key] = self.parent[self.parent[key]]
            key = self.parent[key]
        return key

    def union(self, left, right):
        a, b = self.find(left), self.find(right)
        if a != b:
            self.parent[a] = b


def as_conversations(messages):
    """Collapse a list to one row per conversation, newest first.

    The row is the newest message of the thread, carrying the count and the
    others' uids so the reading pane can offer them.
    """
    sets = _Threads()
    for message in messages:
        ids = message_ids(message)
        if not ids:
            continue
        for other in ids[1:]:
            sets.union(ids[0], other)

    threads = {}
    order = []
    for message in messages:
        ids = message_ids(message)
        key = sets.find(ids[0]) if ids else subject_key(message)
        if key not in threads:
            threads[key] = []
            order.append(key)
        threads[key].append(message)

    out = []
    for key in order:
        members = sorted(threads[key], key=lambda m: m.get("date") or 0, reverse=True)
        newest = dict(members[0])
        newest["threadKey"] = key
        newest["threadCount"] = len(members)
        newest["threadUnread"] = sum(1 for m in members if not m.get("seen"))
        newest["thread"] = [
            {"account": m.get("account"), "folder": m.get("folder"),
             "uid": m.get("uid"), "subject": m.get("subject"),
             "fromName": m.get("fromName"), "fromAddr": m.get("fromAddr"),
             "date": m.get("date"), "seen": m.get("seen")}
            for m in members[1:]
        ]
        out.append(newest)
    return out


def get_message(conn, account, folder, uid):
    row = conn.execute(
        "SELECT * FROM messages WHERE account = ? AND folder = ? AND uid = ?",
        (account, folder, int(uid))).fetchone()
    return row_to_message(row) if row else None


def replace_address_book(conn, account, people):
    """One account's contacts, wholesale. A book is a snapshot, not a log."""
    conn.execute("DELETE FROM address_book WHERE account = ?", (account,))
    conn.executemany(
        "INSERT OR REPLACE INTO address_book "
        "(account, resource, name, emails, phones, organisation, photo, etag) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        [(account, p.get("resource", ""), p.get("name", ""),
          json.dumps(p.get("emails") or []), json.dumps(p.get("phones") or []),
          p.get("organisation", ""), p.get("photo", ""), p.get("etag", ""))
         for p in people])
    conn.commit()


def save_contact(conn, account, person):
    """One contact, in place. Used after the provider has accepted an edit."""
    conn.execute(
        "INSERT OR REPLACE INTO address_book "
        "(account, resource, name, emails, phones, organisation, photo, etag) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        (account, person.get("resource", ""), person.get("name", ""),
         json.dumps(person.get("emails") or []),
         json.dumps(person.get("phones") or []),
         person.get("organisation", ""), person.get("photo", ""),
         person.get("etag", "")))
    conn.commit()


def forget_contact(conn, account, resource):
    """Drop one contact from the cached book."""
    conn.execute("DELETE FROM address_book WHERE account = ? AND resource = ?",
                 (account, resource))
    conn.commit()


def contact(conn, account, resource):
    """One cached contact, or None. The etag on it is what an edit needs."""
    row = conn.execute(
        "SELECT * FROM address_book WHERE account = ? AND resource = ?",
        (account, resource)).fetchone()
    return _address_book_row(row) if row else None


def _address_book_row(row):
    return {
        "account": row["account"],
        "resource": row["resource"],
        "name": row["name"],
        "emails": json.loads(row["emails"] or "[]"),
        "phones": json.loads(row["phones"] or "[]"),
        "organisation": row["organisation"],
        "photo": row["photo"],
        "etag": (row["etag"] if "etag" in row.keys() else "") or "",
    }


def address_book(conn, accounts=None):
    sql = "SELECT * FROM address_book"
    params = []
    if accounts:
        sql += " WHERE account IN (%s)" % ",".join("?" * len(accounts))
        params.extend(accounts)
    return [_address_book_row(row) for row in conn.execute(sql, params)]


# ------------------------------------------------------------------ calendar

EVENT_COLUMNS = ("account, calendar, uid, start, end, day, all_day, summary, "
                 "location, description, organiser, status, colour, "
                 "calendar_name, recurring, read_only, url, etag")


def replace_events(conn, account, start, end, events):
    """One window of one account's calendar, wholesale.

    Deleting the window first is what makes a cancelled meeting disappear:
    an event that is no longer sent back is one that is no longer there.
    """
    conn.execute("DELETE FROM events WHERE account = ? AND start >= ? AND start < ?",
                 (account, int(start), int(end)))
    conn.executemany(
        "INSERT OR REPLACE INTO events (%s) VALUES (%s)"
        % (EVENT_COLUMNS, ",".join("?" * 18)),
        [(account, e.get("calendar", ""), e.get("uid", ""), int(e.get("start", 0)),
          int(e.get("end", 0)), e.get("day", ""), 1 if e.get("allDay") else 0,
          e.get("summary", ""), e.get("location", ""), e.get("description", ""),
          e.get("organiser", ""), e.get("status", ""), e.get("colour", ""),
          e.get("calendarName", ""), 1 if e.get("recurring") else 0,
          1 if e.get("readOnly") else 0, e.get("url", ""), e.get("etag", ""))
         for e in events])
    conn.commit()


def events(conn, accounts=None, start=None, end=None, calendars=None):
    """What is on the calendar, earliest first."""
    where, params = [], []
    if accounts:
        where.append("account IN (%s)" % ",".join("?" * len(accounts)))
        params.extend(accounts)
    if calendars:
        where.append("calendar IN (%s)" % ",".join("?" * len(calendars)))
        params.extend(calendars)
    if start is not None:
        where.append("end > ?")
        params.append(int(start))
    if end is not None:
        where.append("start < ?")
        params.append(int(end))
    sql = "SELECT * FROM events"
    if where:
        sql += " WHERE " + " AND ".join(where)
    sql += " ORDER BY start, summary"
    return [_event_row(row) for row in conn.execute(sql, params)]


def _event_row(row):
    return {
        "account": row["account"],
        "calendar": row["calendar"],
        "calendarName": row["calendar_name"],
        "uid": row["uid"],
        "start": row["start"],
        "end": row["end"],
        "day": row["day"],
        "allDay": bool(row["all_day"]),
        "summary": row["summary"],
        "location": row["location"],
        "description": row["description"],
        "organiser": row["organiser"],
        "status": row["status"],
        "colour": row["colour"],
        "recurring": bool(row["recurring"]),
        "readOnly": bool(row["read_only"]),
        "url": row["url"],
        "etag": row["etag"],
    }


def replace_calendars(conn, account, found):
    """The account's calendars, keeping whichever the user has hidden.

    Nothing back means nothing is written. A fetch that returns no calendars
    at all is far likelier to be a blip than an account that has genuinely
    lost every one of them, and the wholesale delete below would take the
    list off the screen until the next good sync put it back.
    """
    if not found:
        return
    hidden = {row["id"] for row in conn.execute(
        "SELECT id FROM calendars WHERE account = ? AND hidden = 1", (account,))}
    conn.execute("DELETE FROM calendars WHERE account = ?", (account,))
    conn.executemany(
        "INSERT OR REPLACE INTO calendars "
        "(account, id, name, colour, url, read_only, hidden) "
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        [(account, c.get("id", ""), c.get("name", ""), c.get("colour", ""),
          c.get("url", ""), 1 if c.get("readOnly") else 0,
          1 if c.get("id") in hidden else 0) for c in found])
    conn.commit()


def calendars(conn, accounts=None):
    sql = "SELECT * FROM calendars"
    params = []
    if accounts:
        sql += " WHERE account IN (%s)" % ",".join("?" * len(accounts))
        params.extend(accounts)
    sql += " ORDER BY name"
    return [{"account": row["account"], "id": row["id"], "name": row["name"],
             "colour": row["colour"], "url": row["url"],
             "readOnly": bool(row["read_only"]), "hidden": bool(row["hidden"])}
            for row in conn.execute(sql, params)]


def hide_calendar(conn, account, calendar_id, hidden):
    conn.execute("UPDATE calendars SET hidden = ? WHERE account = ? AND id = ?",
                 (1 if hidden else 0, account, calendar_id))
    conn.commit()


def set_keywords(conn, account, folder, uids, add=(), remove=()):
    """Update the cached keywords for messages the server has just been told."""
    if not uids:
        return
    for uid in uids:
        row = conn.execute(
            "SELECT keywords FROM messages WHERE account = ? AND folder = ? AND uid = ?",
            (account, folder, int(uid))).fetchone()
        if row is None:
            continue
        words = [w for w in (row["keywords"] or "").split()]
        for word in remove:
            words = [w for w in words if w.lower() != str(word).lower()]
        for word in add:
            if not any(w.lower() == str(word).lower() for w in words):
                words.append(str(word))
        conn.execute(
            "UPDATE messages SET keywords = ? WHERE account = ? AND folder = ? AND uid = ?",
            (" ".join(sorted(words)), account, folder, int(uid)))
    conn.commit()


def delete_messages(conn, account, folder, uids):
    if not uids:
        return
    marks = ",".join("?" * len(uids))
    conn.execute(
        f"DELETE FROM messages WHERE account = ? AND folder = ? AND uid IN ({marks})",
        (account, folder, *[int(u) for u in uids]))
    conn.execute(
        f"DELETE FROM bodies WHERE account = ? AND folder = ? AND uid IN ({marks})",
        (account, folder, *[int(u) for u in uids]))
    conn.commit()


def set_flags(conn, account, folder, uids, **flags):
    if not uids or not flags:
        return
    assignments = ", ".join(f"{name} = ?" for name in flags)
    marks = ",".join("?" * len(uids))
    conn.execute(
        f"UPDATE messages SET {assignments} WHERE account = ? AND folder = ? "
        f"AND uid IN ({marks})",
        (*[int(bool(v)) for v in flags.values()], account, folder,
         *[int(u) for u in uids]))
    conn.commit()


def unread_counts(conn, account=None):
    sql = ("SELECT account, folder, COUNT(*) AS n FROM messages "
           "WHERE seen = 0 AND draft = 0")
    params = []
    if account:
        sql += " AND account = ?"
        params.append(account)
    sql += " GROUP BY account, folder"
    out = {}
    for row in conn.execute(sql, params):
        out.setdefault(row["account"], {})[row["folder"]] = row["n"]
    return out


def newest_uid(conn, account, folder="INBOX"):
    row = conn.execute("SELECT MAX(uid) AS uid FROM messages WHERE account = ? "
                       "AND folder = ?", (account, folder)).fetchone()
    return int(row["uid"] or 0) if row else 0


def unread_above(conn, account, uid, folder="INBOX"):
    """Unread messages that arrived after the one numbered `uid`."""
    row = conn.execute("SELECT COUNT(*) AS n FROM messages WHERE account = ? "
                       "AND folder = ? AND seen = 0 AND draft = 0 AND uid > ?",
                       (account, folder, int(uid))).fetchone()
    return int(row["n"] or 0) if row else 0


# ---------------------------------------------------------------------- bodies

def save_body(conn, account, folder, uid, text, html, parts, headers):
    conn.execute(
        "INSERT OR REPLACE INTO bodies (account, folder, uid, text, html, parts, "
        "headers, fetched_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        (account, folder, int(uid), text, html, json.dumps(parts),
         json.dumps(headers), int(time.time())))
    conn.commit()


def uncached_bodies(conn, account, folder, uids):
    """Which of these messages have no body on disk yet."""
    wanted = [int(u) for u in uids]
    if not wanted:
        return []
    have = {row["uid"] for row in conn.execute(
        "SELECT uid FROM bodies WHERE account = ? AND folder = ? AND uid IN (%s)"
        % ",".join("?" * len(wanted)), [account, folder] + wanted)}
    return [u for u in wanted if u not in have]


def get_body(conn, account, folder, uid):
    row = conn.execute(
        "SELECT * FROM bodies WHERE account = ? AND folder = ? AND uid = ?",
        (account, folder, int(uid))).fetchone()
    if not row:
        return None
    return {
        "text": row["text"] or "",
        "html": row["html"] or "",
        "parts": json.loads(row["parts"] or "[]"),
        "headers": json.loads(row["headers"] or "{}"),
        "fetchedAt": row["fetched_at"],
    }


# --------------------------------------------------------------------- folders

def save_folders(conn, account, folders):
    now = int(time.time())
    conn.executemany(
        "INSERT INTO folders (account, name, delimiter, special, uidvalidity, "
        "uidnext, total, unseen, synced_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) "
        "ON CONFLICT(account, name) DO UPDATE SET delimiter = excluded.delimiter, "
        "special = excluded.special, uidvalidity = excluded.uidvalidity, "
        "uidnext = excluded.uidnext, total = excluded.total, unseen = excluded.unseen, "
        "synced_at = excluded.synced_at",
        [(account, f["name"], f.get("delimiter", "/"), f.get("special", ""),
          int(f.get("uidvalidity", 0)), int(f.get("uidnext", 0)),
          int(f.get("total", 0)), int(f.get("unseen", 0)), now) for f in folders])
    conn.commit()


def list_folders(conn, account):
    rows = conn.execute(
        "SELECT * FROM folders WHERE account = ? ORDER BY "
        "CASE WHEN name = 'INBOX' THEN 0 WHEN special != '' THEN 1 ELSE 2 END, name",
        (account,))
    return [{
        "name": row["name"],
        "delimiter": row["delimiter"],
        "special": row["special"],
        "uidvalidity": row["uidvalidity"],
        "uidnext": row["uidnext"],
        "total": row["total"],
        "unseen": row["unseen"],
    } for row in rows]


def folder_state(conn, account, name):
    row = conn.execute(
        "SELECT uidvalidity, uidnext FROM folders WHERE account = ? AND name = ?",
        (account, name)).fetchone()
    return (row["uidvalidity"], row["uidnext"]) if row else (0, 0)


def drop_folder(conn, account, name):
    conn.execute("DELETE FROM messages WHERE account = ? AND folder = ?", (account, name))
    conn.execute("DELETE FROM bodies WHERE account = ? AND folder = ?", (account, name))
    conn.commit()


def max_uid(conn, account, folder):
    row = conn.execute(
        "SELECT MAX(uid) AS m FROM messages WHERE account = ? AND folder = ?",
        (account, folder)).fetchone()
    return int(row["m"] or 0)


def known_uids(conn, account, folder):
    return {int(row["uid"]) for row in conn.execute(
        "SELECT uid FROM messages WHERE account = ? AND folder = ?", (account, folder))}


def unthreaded_replies(conn, account, folder):
    """UIDs cached before threading headers were kept that look like replies.

    Only replies need them: a message that starts a conversation has nothing
    to point back to, and refetching every newsletter would find nothing.
    """
    return [int(row["uid"]) for row in conn.execute(
        "SELECT uid FROM messages WHERE account = ? AND folder = ? "
        "AND refs = '' AND in_reply_to = '' AND ("
        "lower(subject) LIKE 're:%' OR lower(subject) LIKE 'aw:%' OR "
        "lower(subject) LIKE 'antw:%' OR lower(subject) LIKE 'sv:%')",
        (account, folder))]


def set_thread_headers(conn, account, folder, found):
    conn.executemany(
        "UPDATE messages SET refs = ?, in_reply_to = ? "
        "WHERE account = ? AND folder = ? AND uid = ?",
        [(refs, parent, account, folder, uid)
         for uid, (refs, parent) in found.items()])
    conn.commit()


def set_state(conn, key, value):
    conn.execute("INSERT OR REPLACE INTO state (key, value) VALUES (?, ?)",
                 (key, str(value)))
    conn.commit()


def get_state(conn, key, default=None):
    row = conn.execute("SELECT value FROM state WHERE key = ?", (key,)).fetchone()
    return row["value"] if row else default


def purge_account(conn, account):
    for table in ("messages", "bodies", "folders"):
        conn.execute(f"DELETE FROM {table} WHERE account = ?", (account,))
    conn.commit()
