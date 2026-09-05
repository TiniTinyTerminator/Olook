"""Local message cache.

The panel has to paint in a few milliseconds when it opens, and IMAP round
trips are nowhere near that fast, so every header the sync pulls lands in
SQLite and the UI only ever reads from here. Bodies are cached on first open.

UIDVALIDITY is honored: when a server resets it, the folder's rows are dropped
rather than silently mismatched against new messages.
"""

import json
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

CREATE TABLE IF NOT EXISTS state (
  key   TEXT PRIMARY KEY,
  value TEXT
);
"""

MESSAGE_COLUMNS = (
    "account, folder, uid, message_id, subject, from_name, from_addr, to_addrs, "
    "cc_addrs, reply_to, date, size, seen, flagged, answered, draft, attachments, preview"
)


def connect():
    config.ensure_dirs()
    conn = sqlite3.connect(str(config.DB_PATH), timeout=15)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.executescript(SCHEMA)
    return conn


def row_to_message(row):
    return {
        "account": row["account"],
        "folder": row["folder"],
        "uid": row["uid"],
        "messageId": row["message_id"],
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
    placeholders = ", ".join(["?"] * 18)
    conn.executemany(
        f"INSERT OR REPLACE INTO messages ({MESSAGE_COLUMNS}) VALUES ({placeholders})",
        [(
            r["account"], r["folder"], r["uid"], r.get("message_id", ""),
            r.get("subject", ""), r.get("from_name", ""), r.get("from_addr", ""),
            json.dumps(r.get("to_addrs", [])), json.dumps(r.get("cc_addrs", [])),
            r.get("reply_to", ""), int(r.get("date", 0)), int(r.get("size", 0)),
            int(bool(r.get("seen"))), int(bool(r.get("flagged"))),
            int(bool(r.get("answered"))), int(bool(r.get("draft"))),
            int(r.get("attachments", 0)), r.get("preview", ""),
        ) for r in rows])
    conn.commit()
    return len(rows)


def list_messages(conn, account, folder=None, limit=100, offset=0,
                  unread_only=False, flagged_only=False, query=""):
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
        where.append("(subject LIKE ? OR from_name LIKE ? OR from_addr LIKE ? OR preview LIKE ?)")
        like = f"%{query}%"
        params.extend([like, like, like, like])
    sql = (f"SELECT * FROM messages WHERE {' AND '.join(where)} "
           f"ORDER BY date DESC, uid DESC LIMIT ? OFFSET ?")
    params.extend([int(limit), int(offset)])
    return [row_to_message(row) for row in conn.execute(sql, params)]


def get_message(conn, account, folder, uid):
    row = conn.execute(
        "SELECT * FROM messages WHERE account = ? AND folder = ? AND uid = ?",
        (account, folder, int(uid))).fetchone()
    return row_to_message(row) if row else None


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


# ---------------------------------------------------------------------- bodies

def save_body(conn, account, folder, uid, text, html, parts, headers):
    conn.execute(
        "INSERT OR REPLACE INTO bodies (account, folder, uid, text, html, parts, "
        "headers, fetched_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        (account, folder, int(uid), text, html, json.dumps(parts),
         json.dumps(headers), int(time.time())))
    conn.commit()


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
