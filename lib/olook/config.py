"""Account configuration and XDG paths.

One JSON file holds every account; secrets never live in it — passwords and
OAuth refresh tokens go to the keyring (see keyring.py). The file is written
0600 anyway, because the mail addresses and server names in it are still
worth keeping to the user.
"""

import json
import os
from pathlib import Path


APP = "olook"


def _xdg(var, default):
    value = os.environ.get(var, "").strip()
    return Path(value) if value else Path.home() / default


CONFIG_DIR = _xdg("XDG_CONFIG_HOME", ".config") / APP
STATE_DIR = _xdg("XDG_STATE_HOME", ".local/state") / APP
CACHE_DIR = _xdg("XDG_CACHE_HOME", ".cache") / APP

CONFIG_PATH = CONFIG_DIR / "accounts.json"
DB_PATH = STATE_DIR / "mail.db"
ATTACHMENT_DIR = CACHE_DIR / "attachments"
# Messages written while the machine could not reach a server. They wait here
# rather than being lost with the window they were typed in.
OUTBOX_DIR = STATE_DIR / "outbox"

DEFAULT_FOLDERS = {
    "inbox": "INBOX",
    "archive": "Archive",
    "sent": "Sent",
    "drafts": "Drafts",
    "trash": "Trash",
    "junk": "Junk",
}


class ConfigError(Exception):
    pass


def ensure_dirs():
    for path in (CONFIG_DIR, STATE_DIR, ATTACHMENT_DIR, OUTBOX_DIR):
        path.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(CONFIG_DIR, 0o700)
        os.chmod(STATE_DIR, 0o700)
    except OSError:
        pass


def load():
    """Return the whole config document, defaulted when absent."""
    if not CONFIG_PATH.exists():
        return {"version": 1, "accounts": []}
    try:
        with CONFIG_PATH.open("r", encoding="utf-8") as handle:
            doc = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise ConfigError(f"Cannot read {CONFIG_PATH}: {exc}") from exc
    if not isinstance(doc, dict):
        raise ConfigError(f"{CONFIG_PATH} is not a JSON object")
    doc.setdefault("version", 1)
    accounts = doc.get("accounts")
    doc["accounts"] = accounts if isinstance(accounts, list) else []
    return doc


def save(doc):
    ensure_dirs()
    tmp = CONFIG_PATH.with_suffix(".json.tmp")
    with tmp.open("w", encoding="utf-8") as handle:
        json.dump(doc, handle, indent=2, sort_keys=False)
        handle.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, CONFIG_PATH)


def accounts():
    return [normalize(a) for a in load()["accounts"] if isinstance(a, dict)]


def account(account_id):
    """Look an account up by id, then by email, then fall back to the first."""
    found = accounts()
    if not found:
        raise ConfigError("No accounts configured. Run: olook setup")
    if not account_id:
        return found[0]
    for entry in found:
        if entry["id"] == account_id:
            return entry
    for entry in found:
        if entry["email"].lower() == str(account_id).lower():
            return entry
    raise ConfigError(f"Unknown account: {account_id}")


def upsert(entry):
    doc = load()
    entry = normalize(entry)
    for index, existing in enumerate(doc["accounts"]):
        if isinstance(existing, dict) and existing.get("id") == entry["id"]:
            doc["accounts"][index] = entry
            break
    else:
        doc["accounts"].append(entry)
    save(doc)
    return entry


def reorder(ids):
    """Put the accounts in the given order.

    The order accounts are stored in is the order they are shown in, so
    reordering the list is the whole of it. Anything the caller leaves out
    keeps its place at the end rather than disappearing -- a stale list from
    a client that has not caught up should not delete an account.
    """
    doc = load()
    wanted = [str(i) for i in (ids or [])]
    by_id = {}
    for entry in doc["accounts"]:
        if isinstance(entry, dict) and entry.get("id"):
            by_id[str(entry["id"])] = entry

    ordered = [by_id.pop(i) for i in wanted if i in by_id]
    ordered.extend(entry for entry in doc["accounts"]
                   if isinstance(entry, dict) and str(entry.get("id")) in by_id)
    doc["accounts"] = ordered
    save(doc)
    return [str(a.get("id")) for a in ordered]


def set_folder_order(account_id, names):
    """Remember the order this account's folders are shown in."""
    entry = account(account_id)
    entry = dict(entry)
    entry["folderOrder"] = [str(n) for n in (names or []) if str(n)]
    upsert(entry)
    return entry["folderOrder"]


def set_folder_kind(account_id, name, kind):
    """Overrule the guess at whether a folder holds mail.

    "mail" shows it, "other" leaves it out of the folder tree, and "auto"
    forgets the choice so the name decides again.
    """
    entry = dict(account(account_id))
    kinds = dict(entry.get("folderKinds") or {})
    if kind == "auto":
        kinds.pop(name, None)
    else:
        kinds[name] = kind
    entry["folderKinds"] = kinds
    upsert(entry)
    return kinds


def remove(account_id):
    doc = load()
    before = len(doc["accounts"])
    doc["accounts"] = [
        a for a in doc["accounts"]
        if not (isinstance(a, dict) and a.get("id") == account_id)
    ]
    save(doc)
    return before != len(doc["accounts"])


# When a message's pictures may load without being asked.
#
#   verified  the server vouched for the sender, or you did
#   trusted   only senders you put on the list yourself
#   never     always ask
#
# "verified" is the default because a signed message is one whose sender is
# known, and asking about every one of those was noise. It does mean a
# tracking pixel in authenticated mail loads: signing proves who sent it, not
# that they mean you well.
IMAGE_POLICIES = ("verified", "trusted", "never")


def image_policy(doc=None):
    doc = doc if doc is not None else load()
    value = str(doc.get("imagePolicy") or "verified").lower()
    return value if value in IMAGE_POLICIES else "verified"


def set_image_policy(value):
    value = str(value or "").lower()
    if value not in IMAGE_POLICIES:
        raise ConfigError("Pick one of: " + ", ".join(IMAGE_POLICIES))
    doc = load()
    doc["imagePolicy"] = value
    save(doc)
    return value


def trusted_senders(doc=None):
    """Addresses whose pictures may load without being asked about.

    A list of addresses rather than of domains: trusting "amazon.nl" would
    trust everyone who can send as it, and the point of the list is that you
    put people on it one at a time.
    """
    doc = doc if doc is not None else load()
    return {str(a).strip().lower() for a in (doc.get("trustedSenders") or []) if a}


def set_trusted(address, trusted=True):
    doc = load()
    current = trusted_senders(doc)
    address = str(address or "").strip().lower()
    if not address:
        return sorted(current)
    if trusted:
        current.add(address)
    else:
        current.discard(address)
    doc["trustedSenders"] = sorted(current)
    save(doc)
    return doc["trustedSenders"]


def normalize(entry):
    """Fill in every field the rest of the code expects to be present."""
    email = str(entry.get("email", "")).strip()
    out = dict(entry)
    out["email"] = email
    out["id"] = str(entry.get("id") or default_id(email))
    out["name"] = str(entry.get("name") or "")
    out["provider"] = str(entry.get("provider") or "generic")
    out["auth"] = str(entry.get("auth") or "password")
    out["username"] = str(entry.get("username") or email)
    out["signature"] = str(entry.get("signature") or "")
    out["enabled"] = entry.get("enabled", True) is not False
    out["demo"] = entry.get("demo", False) is True

    imap = dict(entry.get("imap") or {})
    imap.setdefault("host", "")
    imap.setdefault("port", 993)
    imap.setdefault("ssl", True)
    imap.setdefault("starttls", False)
    out["imap"] = imap

    smtp = dict(entry.get("smtp") or {})
    smtp.setdefault("host", "")
    smtp.setdefault("port", 587)
    smtp.setdefault("ssl", smtp.get("port") == 465)
    smtp.setdefault("starttls", not smtp["ssl"])
    out["smtp"] = smtp

    folders = dict(DEFAULT_FOLDERS)
    folders.update({k: v for k, v in (entry.get("folders") or {}).items() if v})
    out["folders"] = folders

    oauth = dict(entry.get("oauth") or {})
    out["oauth"] = oauth
    return out


def default_id(email):
    """A stable, filesystem- and IPC-safe id derived from the address."""
    safe = "".join(c if c.isalnum() or c in "-_." else "-" for c in email.lower())
    return safe.strip("-") or "account"
