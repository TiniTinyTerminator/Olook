"""Composing and sending mail.

Builds the MIME message, sends it over SMTP (password or XOAUTH2), and
appends a copy to the account's Sent folder — the servers that would do that
for us are the exception, not the rule.
"""

import email.utils
import mimetypes
import os
import smtplib
import ssl
from email.message import EmailMessage
from pathlib import Path

from . import keyring, mailbox, oauth


class SendError(Exception):
    pass


def build(account, draft):
    """draft: {to, cc, bcc, subject, body, attachments[], inReplyTo, references}"""
    msg = EmailMessage()
    sender = account.get("email", "")
    name = account.get("name", "")
    msg["From"] = email.utils.formataddr((name, sender)) if name else sender

    for field in ("to", "cc", "bcc"):
        values = draft.get(field) or []
        if isinstance(values, str):
            values = [v.strip() for v in values.replace(";", ",").split(",") if v.strip()]
        if values:
            msg[field.capitalize()] = ", ".join(values)

    msg["Subject"] = str(draft.get("subject") or "")
    msg["Date"] = email.utils.formatdate(localtime=True)
    msg["Message-ID"] = email.utils.make_msgid(domain=sender.split("@")[-1] or None)

    if draft.get("inReplyTo"):
        msg["In-Reply-To"] = draft["inReplyTo"]
        references = draft.get("references") or draft["inReplyTo"]
        msg["References"] = references

    body = str(draft.get("body") or "")
    signature = account.get("signature") or ""
    if signature and signature not in body:
        body = f"{body}\n\n-- \n{signature}"
    msg.set_content(body)

    if draft.get("html"):
        msg.add_alternative(str(draft["html"]), subtype="html")

    for path in draft.get("attachments") or []:
        _attach(msg, path)
    return msg


def _attach(msg, path):
    file_path = Path(os.path.expanduser(str(path)))
    if not file_path.is_file():
        raise SendError(f"Attachment not found: {file_path}")
    guessed, _ = mimetypes.guess_type(file_path.name)
    maintype, _, subtype = (guessed or "application/octet-stream").partition("/")
    msg.add_attachment(file_path.read_bytes(), maintype=maintype,
                       subtype=subtype or "octet-stream", filename=file_path.name)


def recipients(msg):
    out = []
    for field in ("To", "Cc", "Bcc"):
        out.extend(address["address"] for address in mailbox.split_addresses(msg.get(field, "")))
    return [address for address in out if address]


def send(account, draft, save_to_sent=True):
    msg = build(account, draft)
    targets = recipients(msg)
    if not targets:
        raise SendError("No recipients.")

    settings = account["smtp"]
    host, port = settings["host"], int(settings["port"])
    if not host:
        raise SendError("No SMTP host configured for this account.")
    context = ssl.create_default_context()
    username = account.get("username") or account["email"]

    try:
        if settings.get("ssl"):
            server = smtplib.SMTP_SSL(host, port, context=context, timeout=45)
        else:
            server = smtplib.SMTP(host, port, timeout=45)
    except (OSError, smtplib.SMTPException) as exc:
        raise SendError(f"Cannot reach {host}:{port} — {exc}") from exc

    try:
        server.ehlo()
        if not settings.get("ssl") and settings.get("starttls", True):
            server.starttls(context=context)
            server.ehlo()

        if account.get("auth") == "oauth2":
            token = oauth.access_token(account)
            try:
                _smtp_xoauth2(server, username, token)
            except smtplib.SMTPAuthenticationError:
                token = oauth.access_token(account, force_refresh=True)
                _smtp_xoauth2(server, username, token)
        else:
            password = keyring.get_secret(account["id"], "password")
            if not password:
                raise SendError(f"No password stored for {account['email']}.")
            server.login(username, password)

        # Bcc must not travel with the message; it is an envelope recipient only.
        del msg["Bcc"]
        server.send_message(msg, from_addr=account["email"], to_addrs=targets)
    except smtplib.SMTPException as exc:
        raise SendError(f"Sending failed: {exc}") from exc
    finally:
        try:
            server.quit()
        except Exception:
            pass

    stored = ""
    if save_to_sent:
        stored = _append_to_sent(account, msg)
    return {"messageId": msg["Message-ID"], "recipients": targets, "sentFolder": stored}


def _smtp_xoauth2(server, username, token):
    server.auth("XOAUTH2", lambda challenge=None: oauth.xoauth2_raw(username, token))


def _append_to_sent(account, msg):
    try:
        with mailbox.Session(account) as session:
            folder = session.resolve_role("sent")
            if not folder:
                return ""
            session.append(folder, msg.as_bytes(), flags="(\\Seen)")
            return folder
    except Exception:
        # A message that went out is sent, whether or not the copy landed.
        return ""


def reply_draft(account, original, body_text, reply_all=False):
    """Prefill a reply from a fetched message's headers and body."""
    headers = original.get("headers", {})
    to_field = headers.get("Reply-To") or headers.get("From", "")
    to = [a["address"] for a in mailbox.split_addresses(to_field)]
    cc = []
    if reply_all:
        mine = {account["email"].lower()}
        for field in ("To", "Cc"):
            for address in mailbox.split_addresses(headers.get(field, "")):
                if address["address"].lower() not in mine and address["address"] not in to:
                    cc.append(address["address"])

    subject = headers.get("Subject", "")
    if not subject.lower().startswith("re:"):
        subject = f"Re: {subject}"

    sender = headers.get("From", "")
    date = headers.get("Date", "")
    quoted = "\n".join("> " + line for line in str(body_text or "").splitlines())
    body = f"\n\nOn {date}, {sender} wrote:\n{quoted}"

    return {
        "to": to,
        "cc": cc,
        "subject": subject,
        "body": body,
        "inReplyTo": headers.get("Message-ID", ""),
        "references": " ".join(filter(None, [headers.get("References", ""),
                                             headers.get("Message-ID", "")])).strip(),
    }


def forward_draft(account, original, body_text):
    headers = original.get("headers", {})
    subject = headers.get("Subject", "")
    if not subject.lower().startswith("fwd:"):
        subject = f"Fwd: {subject}"
    lines = [
        "", "", "---------- Forwarded message ----------",
        f"From: {headers.get('From', '')}",
        f"Date: {headers.get('Date', '')}",
        f"Subject: {headers.get('Subject', '')}",
        f"To: {headers.get('To', '')}",
        "", str(body_text or ""),
    ]
    return {"to": [], "cc": [], "subject": subject, "body": "\n".join(lines),
            "inReplyTo": "", "references": ""}
