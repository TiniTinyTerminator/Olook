"""Interactive account setup: the `olook setup` wizard.

Uses gum when it is there (it ships with Omarchy) so the wizard matches the
rest of the system's prompts, and falls back to plain input() when it isn't.
"""

import shutil
import subprocess
import sys

from . import config, keyring, mailbox, oauth, providers

GUM = shutil.which("gum")


def _input(prompt, placeholder="", password=False):
    if GUM:
        command = [GUM, "input", "--prompt", prompt + " "]
        if placeholder:
            command += ["--placeholder", placeholder]
        if password:
            command.append("--password")
        done = subprocess.run(command, text=True, capture_output=True)
        if done.returncode != 0:
            raise KeyboardInterrupt
        return done.stdout.strip()
    if password:
        import getpass
        return getpass.getpass(prompt + " ")
    return input(prompt + " ").strip()


def _confirm(question, default=True):
    if GUM:
        command = [GUM, "confirm", question]
        if not default:
            command.append("--default=false")
        return subprocess.run(command).returncode == 0
    answer = input(f"{question} [{'Y/n' if default else 'y/N'}] ").strip().lower()
    if not answer:
        return default
    return answer.startswith("y")


def _say(text):
    if GUM:
        subprocess.run([GUM, "style", "--foreground", "212", text])
    else:
        print(text)


def run_setup(args):
    print()
    _say("Olook — add an account")
    print()

    email = args.email or _input("Email address:", "you@example.com")
    if "@" not in email:
        print("That does not look like an email address.")
        sys.exit(1)

    print("Looking up server settings…")
    found = providers.discover(email)
    label = {"gmail": "Google", "microsoft": "Microsoft 365 / Outlook",
             "icloud": "iCloud", "yahoo": "Yahoo", "fastmail": "Fastmail",
             "proton": "Proton", "zoho": "Zoho"}.get(found["provider"], "Generic IMAP")
    print(f"\n  Provider : {label}  (detected via {found['source']})")
    print(f"  IMAP     : {found['imap']['host']}:{found['imap']['port']}")
    print(f"  SMTP     : {found['smtp']['host']}:{found['smtp']['port']}")
    print(f"  Sign-in  : {'Microsoft/Google sign-in (OAuth2)' if found['auth'] == 'oauth2' else 'password'}")
    if found.get("note"):
        print(f"  Note     : {found['note']}")
    print()

    if not _confirm("Use these settings?", default=True):
        found["imap"]["host"] = _input("IMAP host:", found["imap"]["host"]) or found["imap"]["host"]
        found["imap"]["port"] = int(_input("IMAP port:", str(found["imap"]["port"])) or found["imap"]["port"])
        found["imap"]["ssl"] = found["imap"]["port"] == 993
        found["imap"]["starttls"] = found["imap"]["port"] != 993
        found["smtp"]["host"] = _input("SMTP host:", found["smtp"]["host"]) or found["smtp"]["host"]
        found["smtp"]["port"] = int(_input("SMTP port:", str(found["smtp"]["port"])) or found["smtp"]["port"])
        found["smtp"]["ssl"] = found["smtp"]["port"] == 465
        found["smtp"]["starttls"] = found["smtp"]["port"] != 465

    display_name = args.name or _input("Your name (shown as the sender):", email.split("@")[0])

    entry = config.upsert({
        "email": email,
        "name": display_name,
        "provider": found["provider"],
        "auth": found["auth"],
        "username": email,
        "imap": found["imap"],
        "smtp": found["smtp"],
        "folders": found.get("folders") or {},
        "oauth": found.get("oauth") or {},
    })

    print()
    if entry["auth"] == "oauth2":
        _say("Signing in with " + ("Google" if entry["provider"] == "gmail" else "Microsoft"))

        def report(event):
            if event.get("event") == "device_code":
                print(f"\n  1. Open {event['verification_uri']}")
                print(f"  2. Enter the code: {event['user_code']}\n")
                _open(event["verification_uri"])
                _clip(event["user_code"])
                print("  (the code is on your clipboard)")
            elif event.get("event") == "open_url":
                print("  Opening your browser…")
                _open(event["url"])
            elif event.get("event") == "authorized":
                _say("  Signed in.")

        try:
            oauth.authorize(entry, report)
        except oauth.OAuthError as exc:
            print(f"\nSign-in failed: {exc}")
            print("You can retry with: olook auth " + entry["id"])
            sys.exit(1)
    else:
        password = _input("Password (or app password):", password=True)
        if not password:
            print("No password given; run `olook auth " + entry["id"] + "` later.")
        else:
            keyring.set_secret(entry["id"], "password", password)

    print("\nTesting the connection…")
    try:
        with mailbox.Session(entry) as session:
            info = session.status("INBOX")
        _say(f"  INBOX: {info['total']} messages, {info['unseen']} unread.")
    except Exception as exc:
        print(f"  Could not open the mailbox: {exc}")
        print("  Fix the settings in ~/.config/olook/accounts.json and run:")
        print(f"    olook test {entry['id']}")
        sys.exit(1)

    print("\nFetching your inbox…")
    subprocess.run(["olook", "sync", "--account", entry["id"]], check=False)
    print()
    _say(f"{email} is ready. Open the mail client with SUPER+M.")


def _open(url):
    for command in (["omarchy-launch-browser", url], ["xdg-open", url]):
        if shutil.which(command[0]):
            subprocess.Popen(command, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True)
            return


def _clip(text):
    if shutil.which("wl-copy"):
        subprocess.run(["wl-copy"], input=text, text=True, check=False)
