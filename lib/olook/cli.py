"""Command line surface.

Every subcommand prints JSON when stdout is a pipe (which is how the Quickshell
plugin always calls it) and a readable table when a human runs it in a
terminal. Failures print {"ok": false, "error": ...} and exit non-zero, so the
UI can show the reason instead of a blank panel.
"""

import argparse
import datetime
import json
import os
import shutil
import subprocess
import sys
import time

from . import (addressbook, config, htmldoc, htmlrich, htmltext, keyring,
               mailbox, markdown, message, oauth, providers, rules, send, store)

JSON_OUT = False


class CliError(Exception):
    pass


# --------------------------------------------------------------------- output

def emit(payload, human=None):
    if JSON_OUT or not sys.stdout.isatty():
        json.dump(payload, sys.stdout, ensure_ascii=False)
        sys.stdout.write("\n")
    elif human is not None:
        print(human(payload) if callable(human) else human)
    else:
        json.dump(payload, sys.stdout, ensure_ascii=False, indent=2)
        sys.stdout.write("\n")
    sys.stdout.flush()


def emit_event(payload):
    """One JSON object per line, for streaming commands (auth, watch)."""
    json.dump(payload, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    sys.stdout.flush()


def fail(text, code=1):
    json.dump({"ok": False, "error": str(text)}, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    sys.stdout.flush()
    sys.exit(code)


def when(timestamp):
    if not timestamp:
        return ""
    moment = datetime.datetime.fromtimestamp(int(timestamp))
    today = datetime.date.today()
    if moment.date() == today:
        return moment.strftime("%H:%M")
    if moment.date().year == today.year:
        return moment.strftime("%d %b")
    return moment.strftime("%d %b %Y")


# ------------------------------------------------------------------- accounts

def cmd_accounts(args):
    conn = store.connect()
    counts = store.unread_counts(conn)
    out = []
    for account in config.accounts():
        folders = counts.get(account["id"], {})
        out.append({
            "id": account["id"],
            "email": account["email"],
            "name": account["name"],
            "provider": account["provider"],
            "auth": account["auth"],
            "enabled": account["enabled"],
            "signature": account["signature"],
            "imapHost": account["imap"]["host"],
            "smtpHost": account["smtp"]["host"],
            "unread": folders.get("INBOX", 0),
            "unreadTotal": sum(folders.values()),
            "authorized": bool(account.get("demo")
                               or keyring.get_secret(account["id"], "refresh_token")
                               or keyring.get_secret(account["id"], "password")),
            "demo": bool(account.get("demo")),
        })
    emit({"ok": True, "accounts": out},
         lambda d: "\n".join(
             f"{a['id']:24} {a['email']:34} {a['provider']:10} "
             f"{'ok' if a['authorized'] else 'NEEDS AUTH':11} {a['unread']} unread"
             for a in d["accounts"]) or "No accounts. Run: olook setup")


def cmd_discover(args):
    found = providers.discover(args.email, offline=args.offline)
    emit({"ok": True, **found},
         lambda d: (f"{args.email}\n  provider : {d['provider']} ({d['source']})\n"
                    f"  auth     : {d['auth']}\n"
                    f"  imap     : {d['imap']['host']}:{d['imap']['port']}\n"
                    f"  smtp     : {d['smtp']['host']}:{d['smtp']['port']}"
                    + (f"\n  note     : {d['note']}" if d.get("note") else "")))


def cmd_add(args):
    email_address = args.email.strip()
    if "@" not in email_address:
        raise CliError(f"Not an email address: {email_address}")
    found = providers.discover(email_address, offline=args.offline)

    entry = {
        "id": args.id or config.default_id(email_address),
        "email": email_address,
        "name": args.name or "",
        "provider": found["provider"],
        "auth": args.auth or found["auth"],
        "username": args.username or email_address,
        "imap": dict(found["imap"]),
        "smtp": dict(found["smtp"]),
        "folders": dict(found.get("folders") or {}),
        "oauth": dict(found.get("oauth") or {}),
    }
    if args.imap_host:
        entry["imap"]["host"] = args.imap_host
    if args.imap_port:
        entry["imap"]["port"] = args.imap_port
        entry["imap"]["ssl"] = args.imap_port == 993
        entry["imap"]["starttls"] = args.imap_port != 993
    if args.smtp_host:
        entry["smtp"]["host"] = args.smtp_host
    if args.smtp_port:
        entry["smtp"]["port"] = args.smtp_port
        entry["smtp"]["ssl"] = args.smtp_port == 465
        entry["smtp"]["starttls"] = args.smtp_port != 465
    if args.tenant:
        entry["oauth"]["tenant"] = args.tenant
    if args.client_id:
        entry["oauth"]["client_id"] = args.client_id

    saved = config.upsert(entry)
    if args.password_stdin:
        password = sys.stdin.read().rstrip("\n")
        if password:
            keyring.set_secret(saved["id"], "password", password)
    emit({"ok": True, "account": saved, "note": found.get("note", "")},
         lambda d: f"Added {d['account']['email']} as '{d['account']['id']}'"
                   + (f"\n{d['note']}" if d.get("note") else ""))


def cmd_set(args):
    """Edit one account in place — what the settings panel writes through."""
    account = config.account(args.account)
    changed = []

    def put(key, value):
        account[key] = value
        changed.append(key)

    if args.name is not None:
        put("name", args.name)
    if args.username:
        put("username", args.username)
    if args.signature_stdin:
        put("signature", sys.stdin.read().rstrip("\n"))
    elif args.signature is not None:
        put("signature", args.signature)
    if args.enabled is not None:
        put("enabled", args.enabled)
    if args.imap_host:
        account["imap"]["host"] = args.imap_host
        changed.append("imap.host")
    if args.imap_port:
        account["imap"]["port"] = args.imap_port
        account["imap"]["ssl"] = args.imap_port == 993
        account["imap"]["starttls"] = args.imap_port != 993
        changed.append("imap.port")
    if args.smtp_host:
        account["smtp"]["host"] = args.smtp_host
        changed.append("smtp.host")
    if args.smtp_port:
        account["smtp"]["port"] = args.smtp_port
        account["smtp"]["ssl"] = args.smtp_port == 465
        account["smtp"]["starttls"] = args.smtp_port != 465
        changed.append("smtp.port")
    # Your own OAuth application, which is the only way to ask Google for
    # anything beyond mail. See docs/CONTACTS.md.
    if args.client_id is not None:
        account.setdefault("oauth", {})["client_id"] = args.client_id
        changed.append("oauth.client_id")
    if args.client_secret is not None:
        account.setdefault("oauth", {})["client_secret"] = args.client_secret
        changed.append("oauth.client_secret")
    if args.contacts_client_id is not None:
        account.setdefault("contactsOauth", {})["client_id"] = args.contacts_client_id
        changed.append("contactsOauth.client_id")
    if args.contacts_client_secret is not None:
        account.setdefault("contactsOauth", {})["client_secret"] = \
            args.contacts_client_secret
        changed.append("contactsOauth.client_secret")
    if args.contacts_scopes is not None:
        account.setdefault("contactsOauth", {})["scopes"] = \
            providers.expand_scope(args.contacts_scopes)
        changed.append("contactsOauth.scopes")

    saved = config.upsert(account)
    emit({"ok": True, "account": saved, "changed": changed},
         lambda d: f"Updated {d['account']['id']}: " + (", ".join(d["changed"]) or "nothing"))


def cmd_remove(args):
    account = config.account(args.account)
    conn = store.connect()
    store.purge_account(conn, account["id"])
    keyring.clear_account(account["id"])
    removed = config.remove(account["id"])
    emit({"ok": removed, "id": account["id"]},
         lambda d: f"Removed {d['id']}" if d["ok"] else "Nothing removed")


def cmd_auth(args):
    account = config.account(args.account)

    if args.password_stdin or account["auth"] == "password":
        password = sys.stdin.read().rstrip("\n") if not sys.stdin.isatty() else ""
        if not password:
            import getpass
            password = getpass.getpass(f"Password for {account['email']}: ")
        keyring.set_secret(account["id"], "password", password)
        if args.stream:
            emit_event({"event": "authorized"})
            return
        emit({"ok": True, "stored": "password"}, lambda d: "Password stored.")
        return

    def report(event):
        if args.stream:
            emit_event(event)
            return
        if event.get("event") == "device_code":
            print(f"\n  Go to {event['verification_uri']}\n"
                  f"  and enter the code:  {event['user_code']}\n")
        elif event.get("event") == "open_url":
            print("  Opening your browser to finish sign-in…")
        elif event.get("event") == "authorized":
            print("  Authorized.")

    def opener(event):
        report(event)
        url = event.get("verification_uri") if event.get("event") == "device_code" \
            else event.get("url")
        if url and not args.no_browser:
            _open_url(url)
        if event.get("event") == "device_code" and event.get("user_code"):
            _copy_clipboard(event["user_code"])

    try:
        oauth.authorize(account, opener, flow=args.flow)
    except oauth.OAuthError as exc:
        if args.stream:
            emit_event({"event": "error", "error": str(exc)})
            sys.exit(1)
        raise CliError(str(exc)) from exc

    if not args.stream:
        emit({"ok": True, "stored": "oauth2"}, lambda d: "Account authorized.")


def _open_url(url):
    for command in (["omarchy-launch-browser", url], ["xdg-open", url]):
        if shutil.which(command[0]):
            try:
                subprocess.Popen(command, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, start_new_session=True)
                return True
            except OSError:
                continue
    return False


def _copy_clipboard(text):
    if not shutil.which("wl-copy"):
        return False
    try:
        subprocess.run(["wl-copy"], input=text, text=True, timeout=5, check=False)
        return True
    except (OSError, subprocess.SubprocessError):
        return False


# ----------------------------------------------------------------- mail: read

def cmd_folders(args):
    account = config.account(args.account)
    conn = store.connect()
    if args.refresh:
        with mailbox.Session(account) as session:
            folders = session.list_folders()
            enriched = []
            for folder in folders:
                info = {"name": folder["name"], "delimiter": folder["delimiter"],
                        "special": folder["special"]}
                try:
                    info.update(session.status(folder["name"]))
                except mailbox.MailError:
                    pass
                enriched.append(info)
            store.save_folders(conn, account["id"], enriched)
    emit({"ok": True, "account": account["id"],
          "folders": store.list_folders(conn, account["id"])},
         lambda d: "\n".join(f"{f['name']:34} {f['unseen']:>5} unread  {f['total']:>6} total"
                             for f in d["folders"]) or "No folders cached yet.")


def cmd_sync(args):
    targets = ([config.account(args.account)] if args.account
               else [a for a in config.accounts() if a["enabled"]])
    targets = [a for a in targets if not a.get("demo")]
    if not targets:
        raise CliError("No accounts configured. Run: olook setup")

    conn = store.connect()
    results = []
    for account in targets:
        try:
            with mailbox.Session(account) as session:
                folders = session.list_folders()
                folder = args.folder or "INBOX"
                if folder in ("archive", "sent", "trash", "drafts", "junk"):
                    folder = session.resolve_role(folder, folders) or "INBOX"

                summary = mailbox.sync_folder(session, conn, folder,
                                              limit=args.limit, full=args.full)
                # Folder pane counts come from STATUS, which is cheap enough to
                # refresh for every folder on each sync.
                enriched = []
                for entry in folders:
                    info = dict(entry)
                    try:
                        info.update(session.status(entry["name"]))
                    except mailbox.MailError:
                        continue
                    enriched.append(info)
                if enriched:
                    store.save_folders(conn, account["id"], enriched)
                summary["account"] = account["id"]
                summary["ok"] = True
                results.append(summary)
        except (mailbox.MailError, oauth.OAuthError, config.ConfigError) as exc:
            results.append({"ok": False, "account": account["id"], "error": str(exc)})

    store.set_state(conn, "last_sync", int(time.time()))
    ok = any(r.get("ok") for r in results)
    emit({"ok": ok, "results": results, "syncedAt": int(time.time())},
         lambda d: "\n".join(
             f"{r['account']}: " + (f"+{r['added']} new, {r['unseen']} unread in {r['folder']}"
                                    if r.get("ok") else f"FAILED — {r['error']}")
             for r in d["results"]))


# The virtual folder that merges every account's inbox. Matches ALL_FOLDER in
# ui/Model.js; no server has a folder by this name and nothing is moved into it.
ALL_FOLDER = "__all__"


def cmd_list(args):
    conn = store.connect()
    if args.all_accounts:
        cmd_list_all(args, conn)
        return
    account = config.account(args.account)
    folder = args.folder
    if folder in ("archive", "sent", "trash", "drafts", "junk"):
        folder = _role_folder(conn, account, folder)
    messages = store.list_messages(
        conn, account["id"], folder=folder, limit=args.limit, offset=args.offset,
        unread_only=args.unread, flagged_only=args.flagged,
        query=args.query or "", sort=args.sort)
    if args.conversations:
        messages = store.as_conversations(messages)
    emit({"ok": True, "account": account["id"], "folder": folder or "",
          "messages": messages, "count": len(messages)},
         lambda d: "\n".join(
             f"{'●' if not m['seen'] else ' '} {when(m['date']):>10}  "
             f"{(m['fromName'] or m['fromAddr'])[:22]:22}  {m['subject'][:60]}"
             for m in d["messages"]) or "No messages cached. Run: olook sync")


def cmd_list_all(args, conn):
    """Every account's inbox in one list, newest first.

    Deliberately the inboxes and nothing else: a view that also mixed in Sent,
    Trash and Junk would not be "all my mail", it would be unusable. Each row
    carries the account it came from, which is what the reading pane shows and
    what a reply is sent from.
    """
    pairs = []
    for entry in config.accounts():
        if entry.get("enabled") is False:
            continue
        pairs.append((entry["id"], _inbox_folder(conn, entry)))
    messages = store.list_across(
        conn, pairs, limit=args.limit, offset=args.offset,
        unread_only=args.unread, flagged_only=args.flagged,
        query=args.query or "", sort=args.sort)
    if args.conversations:
        messages = store.as_conversations(messages)
    emit({"ok": True, "account": "", "folder": ALL_FOLDER,
          "messages": messages, "count": len(messages)},
         lambda d: "\n".join(
             f"{'●' if not m['seen'] else ' '} {when(m['date']):>10}  "
             f"{(m['fromName'] or m['fromAddr'])[:22]:22}  {m['subject'][:60]}"
             for m in d["messages"]) or "No messages cached. Run: olook sync")


def _inbox_folder(conn, account):
    for entry in store.list_folders(conn, account["id"]):
        if entry["special"] == "inbox":
            return entry["name"]
    return "INBOX"


def _role_folder(conn, account, role):
    for entry in store.list_folders(conn, account["id"]):
        if entry["special"] == role or (role == "archive" and entry["special"] == "all"):
            return entry["name"]
    return (account.get("folders") or {}).get(role, role)


def cmd_markdown(args):
    """Render markdown to HTML, the same way sending it would.

    The composer's preview calls this rather than rendering it itself, so
    what is shown while writing is what actually goes out. A preview with its
    own opinion of markdown would be worse than none.
    """
    source = sys.stdin.read()
    emit({"ok": True, "html": markdown.to_html(source)},
         lambda d: d["html"])


def cmd_contacts_auth(args):
    """Grant the contacts application access, once."""
    account = config.account(args.account)
    if not addressbook.supports(account):
        raise CliError("That account has no address book to read.")
    grant = addressbook.grant(account)

    def report(event):
        emit_event(event)

    payload = oauth.authorize(grant, report, flow=args.flow or None)
    oauth.store_tokens(grant["id"], payload)
    emit_event({"ok": True, "event": "done", "account": account["id"]})


def cmd_contacts_sync(args, conn):
    """Pull each account's address book down, where it has one."""
    results = []
    for entry in config.accounts():
        if not entry.get("enabled") or entry.get("demo"):
            continue
        if not addressbook.supports(entry):
            continue
        if args.account and entry["id"] != config.account(args.account)["id"]:
            continue
        try:
            people = addressbook.fetch(entry)
        except addressbook.AddressBookError as exc:
            results.append({"account": entry["id"], "ok": False, "error": str(exc)})
            continue
        addressbook.save(conn, entry["id"], people)
        results.append({"account": entry["id"], "ok": True, "contacts": len(people)})

    emit({"ok": any(r["ok"] for r in results) or not results,
          "results": results},
         lambda d: "\n".join(
             f"{r['account']}: " + (f"{r['contacts']} contacts"
                                    if r["ok"] else r["error"])
             for r in d["results"]) or "No account here keeps an address book.")


def cmd_contacts(args):
    """Everyone the cached mail has been to or from, and the address book."""
    conn = store.connect()
    if args.sync:
        cmd_contacts_sync(args, conn)
        return
    accounts = None
    if args.account:
        accounts = [config.account(args.account)["id"]]
    mine = [entry["email"] for entry in config.accounts()
            if not accounts or entry["id"] in accounts]
    people = store.contacts(conn, accounts=accounts, mine=mine,
                            query=args.query or "", limit=args.limit)
    emit({"ok": True, "contacts": people, "count": len(people)},
         lambda d: "\n".join(
             f"{(c['name'] or c['address'])[:28]:28}  {c['address'][:34]:34}  "
             f"{c['messages']:4d}"
             for c in d["contacts"]) or "No contacts yet. Run: olook sync")


def cmd_body(args):
    account = config.account(args.account)
    conn = store.connect()
    folder = args.folder
    cached = None if args.refresh else store.get_body(conn, account["id"], folder, args.uid)

    if account.get("demo"):
        if not cached:
            raise CliError("The demo account has no server to fetch from.")
        if args.mark_read:
            store.set_flags(conn, account["id"], folder, [args.uid], seen=True)
        summary = store.get_message(conn, account["id"], folder, args.uid) or {}
        emit({"ok": True, "message": summary,
              "body": _body_payload(cached, summary, args.remote_images)},
             lambda d: d["body"]["text"])
        return

    if not cached:
        with mailbox.Session(account) as session:
            # Read-write when the message is about to be marked read: STORE
            # against a folder opened read-only is an error, and it used to
            # take the whole message down with it — you asked to read a mail
            # and got "could not be loaded" instead.
            session.select(folder, readonly=not args.mark_read)
            raw = session.fetch_message(args.uid)
            extracted = message.extract(raw)
            _save_inline_images(raw, extracted, account["id"], folder, args.uid)
            store.save_body(conn, account["id"], folder, args.uid, extracted["text"],
                            extracted["html"], extracted["parts"], extracted["headers"])
            if args.mark_read:
                # The body is already in hand; a server that will not take
                # the flag is not a reason to withhold it.
                try:
                    session.store_flags([args.uid], ["\\Seen"], add=True)
                except mailbox.MailError:
                    pass
                else:
                    store.set_flags(conn, account["id"], folder, [args.uid], seen=True)
        cached = store.get_body(conn, account["id"], folder, args.uid)
    elif args.mark_read:
        _mark_seen(account, conn, folder, [args.uid], True)

    summary = store.get_message(conn, account["id"], folder, args.uid) or {}
    emit({"ok": True, "message": summary,
          "body": _body_payload(cached, summary, args.remote_images)},
         lambda d: f"{d['message'].get('subject','')}\n"
                   f"From: {d['message'].get('fromName','')} <{d['message'].get('fromAddr','')}>\n"
                   f"{'-' * 60}\n{d['body']['text'][:4000]}")


def _save_inline_images(raw, extracted, account_id, folder, uid):
    """Write the images an HTML message references by cid: next to the cache.

    They are what makes a newsletter look like itself; everything remote stays
    unfetched, so this is the only picture the reading pane ever shows.
    """
    if not extracted.get("html"):
        return
    target = config.ATTACHMENT_DIR / "inline" / f"{account_id}-{_safe(folder)}-{uid}"
    for part in extracted.get("parts") or []:
        if not part.get("cid") or not str(part.get("mime", "")).startswith("image/"):
            continue
        if int(part.get("size") or 0) > 8_000_000:
            continue
        try:
            part["path"] = message.save_part(raw, part["index"], dest_dir=target,
                                             filename=part.get("filename"))
        except (OSError, ValueError):
            continue


def _safe(name):
    return "".join(c if c.isalnum() or c in "-_." else "-" for c in str(name))[:40]


def _body_payload(body, summary, forced_remote):
    """The body as the reading pane wants it, trust decided first."""
    trust = _auto_images(body, summary)
    rendered = _with_rich(body, forced_remote or trust["autoImages"])
    rendered.update(trust)
    return rendered


def _auto_images(body, summary):
    """Whether this message's pictures may load without being asked.

    Two things have to hold: the sender is one you have said yes to, and the
    message really is from them. DKIM or DMARC passing is what makes the
    second true, and is the whole reason the list is safe to keep. Without it,
    anyone could put your bank's address in a From line and inherit the
    permission you gave your bank.
    """
    auth = message.authentication((body or {}).get("headers") or {})
    sender = str((summary or {}).get("fromAddr") or "").strip().lower()
    trusted = bool(sender) and sender in config.trusted_senders()
    policy = config.image_policy()

    if policy == "never":
        auto = False
    elif policy == "trusted":
        auto = trusted
    else:
        # Signed mail, or a sender you named. The list still matters: it is
        # how a sender whose server says nothing about them gets through.
        auto = trusted or auth["verified"]

    return {
        "authentication": auth,
        "senderTrusted": trusted,
        "imagePolicy": policy,
        "autoImages": auto,
    }


def _with_rich(body, allow_remote=False):
    """Add the two renderings the reading pane can display.

    `document` is the whole message for the web view, which lays out the
    stylesheet the message came with. `rich` is the same message flattened for
    Qt's rich text, and is what a shell without the web renderer shows.
    """
    if not body:
        return body
    images = {}
    for part in body.get("parts") or []:
        if part.get("cid") and part.get("path"):
            images[part["cid"]] = part["path"]
    source = body.get("html", "")
    rendered = htmlrich.to_rich(source, images)
    body["rich"] = rendered["html"]
    body["blockedImages"] = rendered["blockedImages"]
    document = htmldoc.to_document(source, images, allow_remote)
    body["document"] = document["html"]
    if allow_remote:
        # Nothing is being withheld any more, so the reading pane has nothing
        # left to offer to load.
        body["blockedImages"] = 0
    return body


def cmd_attachment(args):
    account = config.account(args.account)
    with mailbox.Session(account) as session:
        session.select(args.folder, readonly=True)
        raw = session.fetch_message(args.uid)
        path = message.save_part(raw, args.index, args.dest)
    if args.open:
        _open_url(path)
    emit({"ok": True, "path": path}, lambda d: d["path"])


def cmd_flag(args):
    account = config.account(args.account)
    conn = store.connect()
    uids = [int(u) for u in args.uid]
    flag_map = {
        "seen": ("\\Seen", True, {"seen": True}),
        "unseen": ("\\Seen", False, {"seen": False}),
        "flagged": ("\\Flagged", True, {"flagged": True}),
        "unflagged": ("\\Flagged", False, {"flagged": False}),
        "answered": ("\\Answered", True, {"answered": True}),
    }
    if args.set not in flag_map:
        raise CliError(f"Unknown flag: {args.set}")
    flag, add, local = flag_map[args.set]
    if not account.get("demo"):
        with mailbox.Session(account) as session:
            session.select(args.folder, readonly=False)
            session.store_flags(uids, [flag], add=add)
    store.set_flags(conn, account["id"], args.folder, uids, **local)
    emit({"ok": True, "uids": uids, "set": args.set}, lambda d: "Updated.")


def _mark_seen(account, conn, folder, uids, seen):
    with mailbox.Session(account) as session:
        session.select(folder, readonly=False)
        session.store_flags(uids, ["\\Seen"], add=seen)
    store.set_flags(conn, account["id"], folder, uids, seen=seen)


def cmd_move(args):
    account = config.account(args.account)
    conn = store.connect()
    uids = [int(u) for u in args.uid]
    if account.get("demo"):
        store.delete_messages(conn, account["id"], args.folder, uids)
        emit({"ok": True, "moved": uids, "to": args.to},
             lambda d: f"Moved {len(d['moved'])} to {d['to']}")
        return
    with mailbox.Session(account) as session:
        folders = session.list_folders()
        target = session.resolve_role(args.to, folders) if args.to in (
            "archive", "sent", "trash", "drafts", "junk") else args.to
        if not target:
            raise CliError(f"No folder for '{args.to}' on this account")
        session.select(args.folder, readonly=False)
        session.move(uids, target)
    store.delete_messages(conn, account["id"], args.folder, uids)
    emit({"ok": True, "moved": uids, "to": target},
         lambda d: f"Moved {len(d['moved'])} to {d['to']}")


def cmd_images(args):
    """When pictures in a message may load without being asked."""
    if not args.policy:
        emit({"ok": True, "policy": config.image_policy(),
              "choices": list(config.IMAGE_POLICIES)},
             lambda d: f"{d['policy']}  (of {', '.join(d['choices'])})")
        return
    emit({"ok": True, "policy": config.set_image_policy(args.policy)},
         lambda d: f"Images now load when: {d['policy']}")


def cmd_trust(args):
    """Senders whose pictures load without being asked about."""
    if args.action == "list":
        emit({"ok": True, "senders": sorted(config.trusted_senders())},
             lambda d: "\n".join(d["senders"]) or "Nobody trusted yet.")
        return
    senders = config.set_trusted(args.address, args.action == "add")
    emit({"ok": True, "senders": senders, "address": args.address},
         lambda d: ("Trusting " if args.action == "add" else "No longer trusting ")
                   + d["address"])


def cmd_rule(args):
    """List, add and remove the rules that run over newly synced mail."""
    doc = config.load()
    current = list(doc.get("rules") or [])

    if args.action == "list":
        emit({"ok": True, "rules": [
                {"index": i, "rule": r, "says": rules.describe(r)}
                for i, r in enumerate(current)]},
             lambda d: "\n".join(f"{r['index']}: {r['says']}" for r in d["rules"])
                       or "No rules yet.")
        return

    if args.action == "remove":
        if args.index is None or not 0 <= args.index < len(current):
            raise CliError("Which rule? Run: olook rule list")
        dropped = current.pop(args.index)
        doc["rules"] = current
        config.save(doc)
        emit({"ok": True, "removed": rules.describe(dropped)},
             lambda d: f"Removed: {d['removed']}")
        return

    when = {name: value for name, value in
            (("from", args.sender), ("to", args.to), ("subject", args.subject))
            if value}
    then = {}
    if args.move:
        then["move"] = args.move
    if args.category:
        then["category"] = args.category
    if args.read:
        then["read"] = True
    if not when:
        raise CliError("A rule needs something to match on.")
    if not then:
        raise CliError("A rule needs something to do.")

    rule = {"when": when, "then": then}
    current.append(rule)
    doc["rules"] = current
    config.save(doc)
    emit({"ok": True, "added": rules.describe(rule)},
         lambda d: f"Added: {d['added']}")


def cmd_category(args):
    """Put a category on messages, or take one off.

    Categories are IMAP keywords: ordinary flags that are not one of the five
    the protocol defines. Most servers keep them; Gmail shows them as labels,
    which means a category set here appears on the phone as well.
    """
    account = config.account(args.account)
    conn = store.connect()
    uids = [int(u) for u in args.uid]
    name = args.name.strip()
    if not name:
        raise CliError("A category needs a name.")
    if not account.get("demo"):
        with mailbox.Session(account) as session:
            session.select(args.folder, readonly=False)
            session.store_flags(uids, [name], add=not args.remove)
    store.set_keywords(conn, account["id"], args.folder, uids,
                       add=() if args.remove else (name,),
                       remove=(name,) if args.remove else ())
    emit({"ok": True, "uids": uids, "category": name, "removed": args.remove},
         lambda d: ("Removed " if d["removed"] else "Added ")
                   + f"{d['category']} on {len(d['uids'])} message(s)")


def cmd_unmove(args):
    """Put messages back where they came from, found by Message-ID.

    A move is a copy followed by a delete, so the uid we knew is gone the
    moment the message lands somewhere else. The id it carries is the only
    handle that survives the trip, which is what makes undo possible at all.
    """
    account = config.account(args.account)
    if account.get("demo"):
        raise CliError("The demo account has no server to put anything back on.")
    restored = []
    missing = []
    with mailbox.Session(account) as session:
        session.select(args.folder, readonly=False)
        for message_id in args.message_id:
            found = session.search_uids(f'HEADER Message-ID "{message_id}"')
            if not found:
                missing.append(message_id)
                continue
            session.move(found, args.to)
            restored.extend(found)
    emit({"ok": True, "restored": restored, "missing": missing, "to": args.to},
         lambda d: f"Put {len(d['restored'])} back in {d['to']}")


def cmd_delete(args):
    account = config.account(args.account)
    conn = store.connect()
    uids = [int(u) for u in args.uid]
    if account.get("demo"):
        store.delete_messages(conn, account["id"], args.folder, uids)
        emit({"ok": True, "deleted": uids, "to": "Deleted Items"},
             lambda d: f"Deleted {len(d['deleted'])}")
        return
    with mailbox.Session(account) as session:
        folders = session.list_folders()
        trash = session.resolve_role("trash", folders)
        session.select(args.folder, readonly=False)
        if args.purge or (trash and args.folder == trash) or not trash:
            session.store_flags(uids, ["\\Deleted"], add=True)
            session.expunge(uids)
            target = "(expunged)"
        else:
            session.move(uids, trash)
            target = trash
    store.delete_messages(conn, account["id"], args.folder, uids)
    emit({"ok": True, "deleted": uids, "to": target},
         lambda d: f"Deleted {len(d['deleted'])} → {d['to']}")


def cmd_search(args):
    account = config.account(args.account)
    conn = store.connect()
    if not args.server:
        messages = store.list_messages(conn, account["id"], folder=args.folder,
                                       limit=args.limit, query=args.query)
        emit({"ok": True, "messages": messages, "scope": "cache"},
             lambda d: "\n".join(f"{when(m['date']):>10}  {m['subject'][:70]}"
                                 for m in d["messages"]))
        return
    with mailbox.Session(account) as session:
        session.select(args.folder or "INBOX", readonly=True)
        escaped = args.query.replace('"', '\\"')
        uids = session.search_uids(f'TEXT "{escaped}"', limit=args.limit)
        rows = [mailbox.header_row(account["id"], args.folder or "INBOX", item)
                for item in session.fetch_headers(uids)]
    store.upsert_messages(conn, rows)
    messages = [m for m in (store.get_message(conn, account["id"], row["folder"], row["uid"])
                            for row in rows) if m]
    messages.sort(key=lambda m: m["date"], reverse=True)
    emit({"ok": True, "messages": messages, "scope": "server", "count": len(messages)},
         lambda d: "\n".join(f"{when(m['date']):>10}  {m['subject'][:70]}"
                             for m in d["messages"]))


# ---------------------------------------------------------------- mail: write

def cmd_send(args):
    account = config.account(args.account)
    if args.draft == "-":
        draft = json.loads(sys.stdin.read() or "{}")
    else:
        with open(args.draft, "r", encoding="utf-8") as handle:
            draft = json.load(handle)
    try:
        result = send.send(account, draft, save_to_sent=not args.no_save)
    except send.SendError as exc:
        # A server that cannot be reached is a message that has not been sent
        # yet; a server that refuses it is a message that will never go. Only
        # the first is worth keeping to try again.
        if not args.queue or not _looks_unreachable(exc):
            raise
        path = _queue_message(account["id"], draft)
        emit({"ok": True, "queued": True, "path": str(path),
              "reason": str(exc)},
             lambda d: "No connection — kept in the outbox to send later.")
        return
    emit({"ok": True, "queued": False, **result},
         lambda d: f"Sent to {', '.join(d['recipients'])}")


def _looks_unreachable(error):
    text = str(error).lower()
    return ("cannot reach" in text or "temporary failure" in text
            or "name or service not known" in text or "network" in text
            or "timed out" in text)


def _queue_message(account_id, draft):
    config.ensure_dirs()
    stamp = f"{int(time.time() * 1000)}-{account_id}"
    path = config.OUTBOX_DIR / f"{_safe(stamp)}.json"
    path.write_text(json.dumps({"account": account_id, "draft": draft}),
                    encoding="utf-8")
    return path


def cmd_outbox(args):
    """What is waiting to go out, and a nudge to try again."""
    config.ensure_dirs()
    waiting = sorted(config.OUTBOX_DIR.glob("*.json"))
    if not args.flush:
        items = []
        for path in waiting:
            try:
                held = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            items.append({"path": str(path), "account": held.get("account", ""),
                          "subject": (held.get("draft") or {}).get("subject", "")})
        emit({"ok": True, "waiting": len(items), "messages": items},
             lambda d: f"{d['waiting']} waiting to send")
        return

    sent, failed = [], []
    for path in waiting:
        try:
            held = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            path.unlink(missing_ok=True)
            continue
        try:
            account = config.account(held.get("account"))
            send.send(account, held.get("draft") or {})
        except Exception as exc:
            # Still no connection, or an account that has since gone: leave it.
            failed.append({"path": str(path), "error": str(exc)})
            continue
        path.unlink(missing_ok=True)
        sent.append(str(path))
    emit({"ok": True, "sent": len(sent), "failed": len(failed),
          "errors": failed},
         lambda d: f"Sent {d['sent']}, {d['failed']} still waiting")


def cmd_draft_save(args):
    """Store a JSON draft in the Drafts folder so it survives being closed."""
    account = config.account(args.account)
    if account.get("demo"):
        raise CliError("Demo accounts have no server to store drafts on.")
    draft = json.loads(sys.stdin.read() or "{}")
    result = send.save_draft(account, draft, replace_uid=args.replace)
    emit({"ok": True, **result},
         lambda d: f"Draft saved to {d['folder']} as uid {d['uid']}")


def cmd_draft_discard(args):
    """Drop a stored draft — what sending one, or discarding it, ends with."""
    account = config.account(args.account)
    if account.get("demo"):
        raise CliError("Demo accounts have no server to store drafts on.")
    result = send.discard_draft(account, args.uid)
    emit({"ok": True, **result}, lambda d: "Draft discarded.")


def cmd_draft(args):
    """Build a reply/forward draft from a cached message."""
    account = config.account(args.account)
    conn = store.connect()
    body = store.get_body(conn, account["id"], args.folder, args.uid)
    if not body:
        with mailbox.Session(account) as session:
            session.select(args.folder, readonly=True)
            raw = session.fetch_message(args.uid)
            extracted = message.extract(raw)
            store.save_body(conn, account["id"], args.folder, args.uid,
                            extracted["text"], extracted["html"],
                            extracted["parts"], extracted["headers"])
        body = store.get_body(conn, account["id"], args.folder, args.uid)

    original = {"headers": body["headers"]}
    if args.kind == "forward":
        draft = send.forward_draft(account, original, body["text"],
                                   body_html=body.get("html", ""))
    else:
        draft = send.reply_draft(account, original, body["text"],
                                 reply_all=(args.kind == "reply-all"),
                                 body_html=body.get("html", ""))
    emit({"ok": True, "draft": draft}, lambda d: json.dumps(d["draft"], indent=2))


# --------------------------------------------------------------------- status

def cmd_status(args):
    conn = store.connect()
    counts = store.unread_counts(conn)
    accounts = []
    total = 0
    for account in config.accounts():
        if not account["enabled"]:
            continue
        folders = counts.get(account["id"], {})
        inbox_unread = folders.get("INBOX", 0)
        total += inbox_unread
        accounts.append({
            "id": account["id"],
            "email": account["email"],
            "name": account["name"],
            "provider": account["provider"],
            "unread": inbox_unread,
            "authorized": bool(account.get("demo")
                               or keyring.get_secret(account["id"], "refresh_token")
                               or keyring.get_secret(account["id"], "password")),
            "demo": bool(account.get("demo")),
        })
    latest = []
    for account in accounts:
        latest.extend(store.list_messages(conn, account["id"], folder="INBOX",
                                          limit=args.limit, unread_only=args.unread))
    latest.sort(key=lambda m: m["date"], reverse=True)
    emit({"ok": True, "unread": total, "accounts": accounts,
          "messages": latest[:args.limit],
          "lastSync": int(store.get_state(conn, "last_sync", 0) or 0),
          "configured": bool(accounts)},
         lambda d: f"{d['unread']} unread across {len(d['accounts'])} account(s)")


def cmd_watch(args):
    """Long-lived IDLE loop; prints one JSON line per event."""
    account = config.account(args.account)
    conn = store.connect()
    folder = args.folder or "INBOX"
    backoff = 5
    while True:
        try:
            with mailbox.Session(account) as session:
                summary = mailbox.sync_folder(session, conn, folder, limit=args.limit)
                emit_event({"event": "sync", **summary})
                backoff = 5
                while True:
                    session.select(folder, readonly=False)
                    events = session.idle(args.interval)
                    if events:
                        summary = mailbox.sync_folder(session, conn, folder,
                                                      limit=args.limit)
                        emit_event({"event": "sync", **summary})
        except KeyboardInterrupt:
            return
        except Exception as exc:  # keep watching across network hiccups
            emit_event({"event": "error", "error": str(exc)})
            time.sleep(backoff)
            backoff = min(backoff * 2, 300)


def cmd_test(args):
    """Verify IMAP and SMTP both accept the stored credentials."""
    account = config.account(args.account)
    if account.get("demo"):
        emit({"ok": True, "account": account["id"],
              "imap": "skipped — demo account has no server",
              "smtp": "skipped — demo account has no server"},
             lambda d: "Demo account: nothing to connect to.")
        return
    result = {"ok": True, "account": account["id"], "imap": "", "smtp": ""}
    try:
        with mailbox.Session(account) as session:
            info = session.status("INBOX")
            result["imap"] = f"ok — INBOX has {info['total']} messages, {info['unseen']} unread"
    except Exception as exc:
        result["ok"] = False
        result["imap"] = f"failed — {exc}"
    try:
        import smtplib
        import ssl as ssl_module
        settings = account["smtp"]
        context = ssl_module.create_default_context()
        if settings.get("ssl"):
            server = smtplib.SMTP_SSL(settings["host"], int(settings["port"]),
                                      context=context, timeout=20)
        else:
            server = smtplib.SMTP(settings["host"], int(settings["port"]), timeout=20)
            server.ehlo()
            if settings.get("starttls", True):
                server.starttls(context=context)
        server.ehlo()
        username = account.get("username") or account["email"]
        if account["auth"] == "oauth2":
            send._smtp_xoauth2(server, username, oauth.access_token(account))
        else:
            server.login(username, keyring.get_secret(account["id"], "password") or "")
        server.quit()
        result["smtp"] = "ok — authenticated"
    except Exception as exc:
        result["ok"] = False
        result["smtp"] = f"failed — {exc}"
    emit(result, lambda d: f"IMAP: {d['imap']}\nSMTP: {d['smtp']}")


DEMO_HTML = """<html><body style="font-family:sans-serif">
<h2>Omarchy 4.0 is out</h2>
<p>Quickshell now hosts the <b>bar</b>, notifications, and every panel in one
process. Highlights of this release:</p>
<ul>
  <li>One shell process instead of five</li>
  <li>A plugin registry with <i>hot reload</i></li>
  <li>Lua dispatchers for Hyprland</li>
</ul>
<blockquote>Upgrading is a single <code>omarchy update</code>.</blockquote>
<table border="1" cellpadding="6">
  <tr><th>Component</th><th>Status</th></tr>
  <tr><td>Bar</td><td>Rewritten</td></tr>
  <tr><td>Notifications</td><td>Rewritten</td></tr>
</table>
<p><a href="https://omarchy.org/release-notes">Read the release notes</a></p>
<img src="https://tracking.example.com/open.gif?id=42" width="1" height="1" alt="">
</body></html>"""


def cmd_demo(args):
    """Seed the cache with sample mail so the UI can be driven without a server.

    Two accounts, because that is the shape most people are in — a personal
    address and a work one — and the folder tree only makes sense with both.
    """
    conn = store.connect()
    account_id = "demo"
    work_id = "demo-work"
    if args.clear:
        for target in (account_id, work_id):
            store.purge_account(conn, target)
            config.remove(target)
        emit({"ok": True, "cleared": True}, lambda d: "Demo data cleared.")
        return

    config.upsert({
        "id": account_id, "email": "you@gmail.com", "name": "Personal",
        "provider": "demo", "auth": "none", "demo": True,
        "imap": {"host": ""}, "smtp": {"host": ""},
    })
    config.upsert({
        "id": work_id, "email": "you@company.com", "name": "Work",
        "provider": "demo", "auth": "none", "demo": True,
        "imap": {"host": ""}, "smtp": {"host": ""},
    })

    now = int(time.time())
    samples = [
        ("Ada Lovelace", "ada@analytical.engine", "Notes on the Analytical Engine",
         "The engine can arrange and combine numerical quantities as if they were letters.", 0, 0),
        ("Omarchy", "hello@omarchy.org", "Omarchy 4.0 is out",
         "Quickshell now hosts the bar, notifications, and every panel in one process.", 1, 0),
        ("Finance", "billing@example.com", "Your invoice for August",
         "Attached is the invoice for August. No action needed if already paid.", 3, 1),
        ("Kim de Vries", "kim@studio.nl", "Re: Friday's review",
         "Works for me — let's do 14:00 and keep it to half an hour.", 8, 0),
        ("GitHub", "noreply@github.com", "[omarchy/omarchy] New release 4.0.2",
         "A new release is available with fixes to the shell plugin registry.", 26, 0),
    ]
    rows = []
    for index, (name, address, subject, preview, hours, attachments) in enumerate(samples):
        rows.append({
            "account": account_id, "folder": "INBOX", "uid": 1000 + index,
            "message_id": f"<demo-{index}@omarchy>", "subject": subject,
            "from_name": name, "from_addr": address,
            "to_addrs": ["you@example.com"], "cc_addrs": [],
            "date": now - hours * 3600, "size": 4096 + index * 900,
            "seen": index > 1, "flagged": index == 3, "answered": False,
            "draft": False, "attachments": attachments, "preview": preview,
        })
    store.upsert_messages(conn, rows)
    for row in rows:
        # One HTML message, so the reading pane's formatted view and its
        # remote-image blocking have something to show.
        html_body = DEMO_HTML if row["uid"] == 1001 else ""
        store.save_body(conn, account_id, "INBOX", row["uid"],
                        htmltext.to_text(html_body) if html_body
                        else row["preview"] + "\n\n-- \nSent from Olook",
                        html_body,
                        [], {"From": f"{row['from_name']} <{row['from_addr']}>",
                             "Subject": row["subject"], "To": "you@example.com"})
    store.save_folders(conn, account_id, [
        {"name": "INBOX", "special": "inbox", "total": len(rows), "unseen": 2},
        {"name": "Archive", "special": "archive", "total": 128, "unseen": 0},
        {"name": "Sent", "special": "sent", "total": 64, "unseen": 0},
        {"name": "Drafts", "special": "drafts", "total": 2, "unseen": 0},
        {"name": "Deleted Items", "special": "trash", "total": 9, "unseen": 0},
        {"name": "Junk Email", "special": "junk", "total": 4, "unseen": 1},
    ])
    work_samples = [
        ("Priya Raman", "priya@company.com", "Q3 roadmap review",
         "Sending the deck ahead of Thursday so you can comment in advance.", 2, 1),
        ("IT Service Desk", "it@company.com", "Scheduled maintenance this weekend",
         "Mailboxes stay online; the VPN gateway restarts at 02:00 Saturday.", 5, 0),
        ("Tom Verhoeven", "tom@company.com", "Re: contract renewal",
         "Legal signed off. I'll forward the countersigned copy tomorrow.", 20, 0),
    ]
    work_rows = []
    for index, (name, address, subject, preview, hours, attachments) in enumerate(work_samples):
        work_rows.append({
            "account": work_id, "folder": "INBOX", "uid": 2000 + index,
            "message_id": f"<demo-work-{index}@omarchy>", "subject": subject,
            "from_name": name, "from_addr": address,
            "to_addrs": ["you@company.com"], "cc_addrs": [],
            "date": now - hours * 3600, "size": 7000 + index * 1200,
            "seen": index > 0, "flagged": False, "answered": index == 2,
            "draft": False, "attachments": attachments, "preview": preview,
        })
    store.upsert_messages(conn, work_rows)
    for row in work_rows:
        store.save_body(conn, work_id, "INBOX", row["uid"],
                        row["preview"] + "\n\n-- \nSent from Olook", "",
                        [], {"From": f"{row['from_name']} <{row['from_addr']}>",
                             "Subject": row["subject"], "To": "you@company.com"})
    store.save_folders(conn, work_id, [
        {"name": "INBOX", "special": "inbox", "total": len(work_rows), "unseen": 1},
        {"name": "Archive", "special": "archive", "total": 412, "unseen": 0},
        {"name": "Sent Items", "special": "sent", "total": 233, "unseen": 0},
        {"name": "Drafts", "special": "drafts", "total": 1, "unseen": 0},
        {"name": "Deleted Items", "special": "trash", "total": 27, "unseen": 0},
        {"name": "Junk Email", "special": "junk", "total": 6, "unseen": 0},
        {"name": "Projects", "special": "", "total": 88, "unseen": 0},
    ])

    store.set_state(conn, "last_sync", now)
    total = len(rows) + len(work_rows)
    emit({"ok": True, "seeded": total},
         lambda d: f"Seeded {d['seeded']} demo messages across two accounts.")


# ---------------------------------------------------------------------- setup

def cmd_setup(args):
    from .setup import run_setup
    run_setup(args)


# ---------------------------------------------------------------------- parser

def build_parser():
    parser = argparse.ArgumentParser(
        prog="olook",
        description="Mail engine for the Omarchy Quickshell mail client.")
    parser.add_argument("--json", action="store_true", help="always print JSON")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("accounts", help="list configured accounts")
    p.set_defaults(func=cmd_accounts)

    p = sub.add_parser("discover", help="show autodetected server settings")
    p.add_argument("email")
    p.add_argument("--offline", action="store_true")
    p.set_defaults(func=cmd_discover)

    p = sub.add_parser("add", help="add an account")
    p.add_argument("email")
    p.add_argument("--id"), p.add_argument("--name"), p.add_argument("--username")
    p.add_argument("--auth", choices=["password", "oauth2"])
    p.add_argument("--imap-host"), p.add_argument("--imap-port", type=int)
    p.add_argument("--smtp-host"), p.add_argument("--smtp-port", type=int)
    p.add_argument("--tenant", help="Microsoft tenant id (default: common)")
    p.add_argument("--client-id", help="your own OAuth client id")
    p.add_argument("--password-stdin", action="store_true")
    p.add_argument("--offline", action="store_true")
    p.set_defaults(func=cmd_add)

    p = sub.add_parser("auth", help="authorize an account (OAuth or password)")
    p.add_argument("account", nargs="?")
    p.add_argument("--flow", choices=["device", "loopback"])
    p.add_argument("--password-stdin", action="store_true")
    p.add_argument("--stream", action="store_true", help="emit JSON events per line")
    p.add_argument("--no-browser", action="store_true")
    p.set_defaults(func=cmd_auth)

    p = sub.add_parser("remove", help="remove an account and its cache")
    p.add_argument("account")
    p.set_defaults(func=cmd_remove)

    p = sub.add_parser("set", help="change settings on an existing account")
    p.add_argument("account")
    p.add_argument("--name"), p.add_argument("--username")
    p.add_argument("--client-id", help="your own OAuth application")
    p.add_argument("--client-secret")
    p.add_argument("--contacts-client-id",
                   help="an OAuth application of your own, for contacts only")
    p.add_argument("--contacts-client-secret")
    p.add_argument("--contacts-scopes",
                   help="what your application may do: contacts, "
                        "contacts.readonly, calendar, calendar.readonly")
    p.add_argument("--signature")
    p.add_argument("--signature-stdin", action="store_true",
                   help="read the signature from stdin")
    p.add_argument("--enable", dest="enabled", action="store_true", default=None,
                   help="include this account when syncing")
    p.add_argument("--disable", dest="enabled", action="store_false",
                   help="leave this account out of syncs")
    p.add_argument("--imap-host"), p.add_argument("--imap-port", type=int)
    p.add_argument("--smtp-host"), p.add_argument("--smtp-port", type=int)
    p.set_defaults(func=cmd_set)

    p = sub.add_parser("test", help="check IMAP and SMTP credentials")
    p.add_argument("account", nargs="?")
    p.set_defaults(func=cmd_test)

    p = sub.add_parser("folders", help="list folders")
    p.add_argument("--account"), p.add_argument("--refresh", action="store_true")
    p.set_defaults(func=cmd_folders)

    p = sub.add_parser("sync", help="fetch new mail into the local cache")
    p.add_argument("--account"), p.add_argument("--folder", default="INBOX")
    p.add_argument("--limit", type=int, default=200)
    p.add_argument("--full", action="store_true", help="re-fetch the whole window")
    p.set_defaults(func=cmd_sync)

    p = sub.add_parser("list", help="list cached messages")
    p.add_argument("--account"), p.add_argument("--folder", default="INBOX")
    p.add_argument("--limit", type=int, default=50)
    p.add_argument("--offset", type=int, default=0)
    p.add_argument("--unread", action="store_true")
    p.add_argument("--flagged", action="store_true")
    p.add_argument("--query", default="")
    p.add_argument("--all-accounts", action="store_true",
                   help="every account's inbox in one list")
    p.add_argument("--sort", default="date",
                   choices=["date", "sender", "subject", "size", "unread"])
    p.add_argument("--conversations", action="store_true",
                   help="one row per conversation, newest of each")
    p.set_defaults(func=cmd_list)

    p = sub.add_parser("outbox", help="messages waiting for a connection")
    p.add_argument("--flush", action="store_true", help="try sending them now")
    p.set_defaults(func=cmd_outbox)

    p = sub.add_parser("markdown", help="render markdown from stdin to HTML")
    p.set_defaults(func=cmd_markdown)

    p = sub.add_parser("contacts-auth",
                       help="let your contacts application read the address book")
    p.add_argument("--account")
    p.add_argument("--flow", choices=["loopback", "device"], default="")
    p.set_defaults(func=cmd_contacts_auth)

    p = sub.add_parser("contacts", help="people from your cached mail")
    p.add_argument("--account")
    p.add_argument("--query", default="")
    p.add_argument("--limit", type=int, default=500)
    p.add_argument("--sync", action="store_true",
                   help="fetch the account's address book first")
    p.set_defaults(func=cmd_contacts)

    p = sub.add_parser("body", help="fetch one message body")
    p.add_argument("--account"), p.add_argument("--folder", default="INBOX")
    p.add_argument("--uid", type=int, required=True)
    p.add_argument("--refresh", action="store_true")
    p.add_argument("--mark-read", action="store_true")
    p.add_argument("--remote-images", action="store_true",
                   help="keep the images the message points at over the network")
    p.set_defaults(func=cmd_body)

    p = sub.add_parser("attachment", help="save an attachment to disk")
    p.add_argument("--account"), p.add_argument("--folder", default="INBOX")
    p.add_argument("--uid", type=int, required=True)
    p.add_argument("--index", type=int, required=True)
    p.add_argument("--dest"), p.add_argument("--open", action="store_true")
    p.set_defaults(func=cmd_attachment)

    p = sub.add_parser("flag", help="set or clear a flag")
    p.add_argument("--account"), p.add_argument("--folder", default="INBOX")
    p.add_argument("--uid", nargs="+", required=True)
    p.add_argument("--set", required=True,
                   choices=["seen", "unseen", "flagged", "unflagged", "answered"])
    p.set_defaults(func=cmd_flag)

    p = sub.add_parser("move", help="move messages to another folder")
    p.add_argument("--account"), p.add_argument("--folder", default="INBOX")
    p.add_argument("--uid", nargs="+", required=True)
    p.add_argument("--to", required=True, help="folder name or role (archive/junk/…)")
    p.set_defaults(func=cmd_move)

    p = sub.add_parser("images", help="when pictures may load by themselves")
    p.add_argument("policy", nargs="?", default="",
                   help="verified | trusted | never")
    p.set_defaults(func=cmd_images)

    p = sub.add_parser("trust", help="senders whose images load by themselves")
    p.add_argument("action", choices=["list", "add", "remove"])
    p.add_argument("address", nargs="?", default="")
    p.set_defaults(func=cmd_trust)

    p = sub.add_parser("rule", help="what to do with mail as it arrives")
    p.add_argument("action", choices=["list", "add", "remove"])
    p.add_argument("--index", type=int, help="which rule, for remove")
    p.add_argument("--from", dest="sender", help="match the sender")
    p.add_argument("--to", help="match a recipient")
    p.add_argument("--subject", help="match the subject")
    p.add_argument("--move", help="move it to this folder or role")
    p.add_argument("--category", help="put this category on it")
    p.add_argument("--read", action="store_true", help="mark it read")
    p.set_defaults(func=cmd_rule)

    p = sub.add_parser("category", help="add or remove a category (IMAP keyword)")
    p.add_argument("--account"), p.add_argument("--folder", default="INBOX")
    p.add_argument("--uid", nargs="+", required=True)
    p.add_argument("--name", required=True)
    p.add_argument("--remove", action="store_true")
    p.set_defaults(func=cmd_category)

    p = sub.add_parser("unmove", help="put moved messages back, by Message-ID")
    p.add_argument("--account")
    p.add_argument("--folder", required=True, help="where they are now")
    p.add_argument("--to", required=True, help="where they should go back to")
    p.add_argument("--message-id", nargs="+", required=True)
    p.set_defaults(func=cmd_unmove)

    p = sub.add_parser("delete", help="move messages to trash (or purge)")
    p.add_argument("--account"), p.add_argument("--folder", default="INBOX")
    p.add_argument("--uid", nargs="+", required=True)
    p.add_argument("--purge", action="store_true")
    p.set_defaults(func=cmd_delete)

    p = sub.add_parser("search", help="search cached mail, or the server")
    p.add_argument("--account"), p.add_argument("--folder", default="INBOX")
    p.add_argument("--query", required=True)
    p.add_argument("--limit", type=int, default=50)
    p.add_argument("--server", action="store_true")
    p.set_defaults(func=cmd_search)

    p = sub.add_parser("send", help="send a JSON draft")
    p.add_argument("--account")
    p.add_argument("--draft", default="-", help="draft JSON file, or - for stdin")
    p.add_argument("--no-save", action="store_true", help="skip the Sent copy")
    p.add_argument("--queue", action="store_true",
                   help="keep it in the outbox if the server cannot be reached")
    p.set_defaults(func=cmd_send)

    p = sub.add_parser("draft-save", help="store a JSON draft in Drafts")
    p.add_argument("--account")
    p.add_argument("--replace", type=int, default=0,
                   help="uid of the earlier copy this one supersedes")
    p.set_defaults(func=cmd_draft_save)

    p = sub.add_parser("draft-discard", help="remove a stored draft")
    p.add_argument("--account")
    p.add_argument("--uid", type=int, required=True)
    p.set_defaults(func=cmd_draft_discard)

    p = sub.add_parser("draft", help="build a reply or forward draft")
    p.add_argument("--account"), p.add_argument("--folder", default="INBOX")
    p.add_argument("--uid", type=int, required=True)
    p.add_argument("--kind", choices=["reply", "reply-all", "forward"], default="reply")
    p.set_defaults(func=cmd_draft)

    p = sub.add_parser("status", help="unread counts and recent mail")
    p.add_argument("--limit", type=int, default=10)
    p.add_argument("--unread", action="store_true")
    p.set_defaults(func=cmd_status)

    p = sub.add_parser("watch", help="IDLE and print events as mail arrives")
    p.add_argument("--account"), p.add_argument("--folder", default="INBOX")
    p.add_argument("--limit", type=int, default=200)
    p.add_argument("--interval", type=int, default=1500)
    p.set_defaults(func=cmd_watch)

    p = sub.add_parser("demo", help="seed sample mail for trying the UI")
    p.add_argument("--clear", action="store_true")
    p.set_defaults(func=cmd_demo)

    p = sub.add_parser("setup", help="interactive account setup")
    p.add_argument("--email"), p.add_argument("--name")
    p.set_defaults(func=cmd_setup)
    return parser


def main(argv=None):
    global JSON_OUT
    parser = build_parser()
    args = parser.parse_args(argv)
    JSON_OUT = bool(getattr(args, "json", False))
    os.umask(0o077)
    try:
        args.func(args)
    except (CliError, config.ConfigError, mailbox.MailError, oauth.OAuthError,
            send.SendError) as exc:
        fail(exc)
    except KeyboardInterrupt:
        sys.exit(130)
    except BrokenPipeError:
        sys.exit(0)
