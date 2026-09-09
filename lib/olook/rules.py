"""Rules: what to do with a message before you ever see it.

Outlook's rules are a small programming language with a wizard in front of
them. This is the part people actually use -- mail from this sender, or with
this in the subject, goes to that folder, or gets a category, or is already
read -- and nothing else. A rule that cannot be explained in one line is a
rule nobody will remember writing.

Rules run over messages a sync has just brought in, so they never touch mail
that was already sitting there.
"""

from . import store


def load(doc):
    return list(doc.get("rules") or [])


def matches(rule, row):
    """Every stated condition has to hold; an empty rule matches nothing.

    `row` is a freshly built header row -- the physical column names, which is
    what a sync has in hand at the moment rules run.
    """
    when = rule.get("when") or {}
    tests = []

    sender = str(when.get("from") or "").strip().lower()
    if sender:
        haystack = (str(row.get("from_addr") or "") + " "
                    + str(row.get("from_name") or "")).lower()
        tests.append(sender in haystack)

    subject = str(when.get("subject") or "").strip().lower()
    if subject:
        tests.append(subject in str(row.get("subject") or "").lower())

    recipient = str(when.get("to") or "").strip().lower()
    if recipient:
        addresses = " ".join(row.get("to_addrs") or []).lower()
        tests.append(recipient in addresses)

    return bool(tests) and all(tests)


def describe(rule):
    when, then = rule.get("when") or {}, rule.get("then") or {}
    said = [f"{name} contains {value!r}" for name, value in when.items() if value]
    does = []
    if then.get("move"):
        does.append(f"move to {then['move']}")
    if then.get("category"):
        does.append(f"category {then['category']}")
    if then.get("read"):
        does.append("mark read")
    return " and ".join(said) + " → " + (", ".join(does) or "do nothing")


def apply(conn, session, account_id, folder, rows, wanted):
    """Run the rules over freshly synced rows. Returns what was done."""
    done = []
    for rule in wanted:
        hits = [m for m in rows if matches(rule, m)]
        if not hits:
            continue
        then = rule.get("then") or {}
        uids = [int(m["uid"]) for m in hits]

        if then.get("read"):
            session.store_flags(uids, ["\\Seen"], add=True)
            store.set_flags(conn, account_id, folder, uids, seen=True)

        if then.get("category"):
            session.store_flags(uids, [str(then["category"])], add=True)
            store.set_keywords(conn, account_id, folder, uids,
                               add=(str(then["category"]),))

        # Moving last: once they are gone from this folder the uids mean
        # nothing here, so anything else the rule asks for happens first.
        if then.get("move"):
            target = session.resolve_role(then["move"]) or then["move"]
            session.move(uids, target)
            store.delete_messages(conn, account_id, folder, uids)

        done.append({"rule": describe(rule), "messages": len(uids)})
    return done
