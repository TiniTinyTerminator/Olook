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

from . import (config, htmltext, keyring, mailbox, message, oauth, providers,
               send, store)

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


def cmd_list(args):
    account = config.account(args.account)
    conn = store.connect()
    folder = args.folder
    if folder in ("archive", "sent", "trash", "drafts", "junk"):
        folder = _role_folder(conn, account, folder)
    messages = store.list_messages(
        conn, account["id"], folder=folder, limit=args.limit, offset=args.offset,
        unread_only=args.unread, flagged_only=args.flagged, query=args.query or "")
    emit({"ok": True, "account": account["id"], "folder": folder or "",
          "messages": messages, "count": len(messages)},
         lambda d: "\n".join(
             f"{'●' if not m['seen'] else ' '} {when(m['date']):>10}  "
             f"{(m['fromName'] or m['fromAddr'])[:22]:22}  {m['subject'][:60]}"
             for m in d["messages"]) or "No messages cached. Run: olook sync")


def _role_folder(conn, account, role):
    for entry in store.list_folders(conn, account["id"]):
        if entry["special"] == role or (role == "archive" and entry["special"] == "all"):
            return entry["name"]
    return (account.get("folders") or {}).get(role, role)


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
        emit({"ok": True, "message": summary, "body": cached},
             lambda d: d["body"]["text"])
        return

    if not cached:
        with mailbox.Session(account) as session:
            session.select(folder, readonly=True)
            raw = session.fetch_message(args.uid)
            extracted = message.extract(raw)
            store.save_body(conn, account["id"], folder, args.uid, extracted["text"],
                            extracted["html"], extracted["parts"], extracted["headers"])
            if args.mark_read:
                session.store_flags([args.uid], ["\\Seen"], add=True)
                store.set_flags(conn, account["id"], folder, [args.uid], seen=True)
        cached = store.get_body(conn, account["id"], folder, args.uid)
    elif args.mark_read:
        _mark_seen(account, conn, folder, [args.uid], True)

    summary = store.get_message(conn, account["id"], folder, args.uid) or {}
    emit({"ok": True, "message": summary, "body": cached},
         lambda d: f"{d['message'].get('subject','')}\n"
                   f"From: {d['message'].get('fromName','')} <{d['message'].get('fromAddr','')}>\n"
                   f"{'-' * 60}\n{d['body']['text'][:4000]}")


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
    result = send.send(account, draft, save_to_sent=not args.no_save)
    emit({"ok": True, **result}, lambda d: f"Sent to {', '.join(d['recipients'])}")


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
        draft = send.forward_draft(account, original, body["text"])
    else:
        draft = send.reply_draft(account, original, body["text"],
                                 reply_all=(args.kind == "reply-all"))
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


def cmd_demo(args):
    """Seed the cache with sample mail so the UI can be driven without a server."""
    conn = store.connect()
    account_id = "demo"
    if args.clear:
        store.purge_account(conn, account_id)
        config.remove(account_id)
        emit({"ok": True, "cleared": True}, lambda d: "Demo data cleared.")
        return

    config.upsert({
        "id": account_id, "email": "you@example.com", "name": "Demo",
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
        store.save_body(conn, account_id, "INBOX", row["uid"],
                        row["preview"] + "\n\n-- \nSent from Olook", "",
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
    store.set_state(conn, "last_sync", now)
    emit({"ok": True, "seeded": len(rows)},
         lambda d: f"Seeded {d['seeded']} demo messages under account 'demo'.")


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
    p.set_defaults(func=cmd_list)

    p = sub.add_parser("body", help="fetch one message body")
    p.add_argument("--account"), p.add_argument("--folder", default="INBOX")
    p.add_argument("--uid", type=int, required=True)
    p.add_argument("--refresh", action="store_true")
    p.add_argument("--mark-read", action="store_true")
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
    p.set_defaults(func=cmd_send)

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
