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

from . import htmldoc, htmltext, keyring, mailbox, markdown, oauth


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

    # The chain being replied to travels separately from what was written, so
    # each can be rendered the way it should be: the reply as it was typed,
    # the original as the markup it arrived in.
    quoted_text = str(draft.get("quoted") or "")
    quoted_html = str(draft.get("quotedHtml") or "")
    plain = body + (f"\n\n{quoted_text}" if quoted_text else "")

    # How the body was written decides what goes on the wire: plain text on
    # its own, or text plus an HTML alternative for clients that render it.
    fmt = str(draft.get("format") or "plain").lower()
    if fmt == "markdown":
        written_html = markdown.to_html(body)
    elif fmt == "html":
        written_html = body
    else:
        written_html = _paragraphs(body)

    msg.set_content(plain if fmt != "html" else (htmltext.to_text(plain) or plain))

    if quoted_html:
        # An HTML alternative even for a plain-text reply: the quoted original
        # is HTML, and dropping it back to "> " lines would undo the point.
        msg.add_alternative(markdown.document(written_html + "<br>" + quoted_html),
                            subtype="html")
    elif fmt == "markdown":
        msg.add_alternative(markdown.document(written_html), subtype="html")
    elif fmt == "html":
        msg.add_alternative(_html_document(body), subtype="html")
    elif draft.get("html"):
        msg.add_alternative(str(draft["html"]), subtype="html")

    for path in draft.get("attachments") or []:
        _attach(msg, path)
    return msg


def _paragraphs(text):
    """Plain typing as HTML: blank lines part paragraphs, single ones break."""
    blocks = [block for block in str(text or "").split("\n\n")]
    out = []
    for block in blocks:
        if not block.strip():
            continue
        out.append("<p>" + "<br>".join(html_escape(line)
                                       for line in block.splitlines()) + "</p>")
    return "".join(out)


def _html_document(body):
    """Wrap hand-written HTML only when it isn't already a whole document."""
    lowered = str(body).lower()
    if "<html" in lowered or "<!doctype" in lowered:
        return str(body)
    return markdown.document(str(body))


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


def save_draft(account, draft, replace_uid=0):
    """Put a draft in the account's Drafts folder, replacing an earlier copy.

    IMAP cannot update a message in place, so re-saving is an append followed
    by a delete of the copy it supersedes — in that order, because ending up
    with two copies is recoverable and ending up with none is not.
    """
    msg = build(account, draft)
    with mailbox.Session(account) as session:
        folder = session.resolve_role("drafts")
        if not folder:
            raise SendError("This account has no Drafts folder to save into.")
        session.append(folder, msg.as_bytes(), flags="(\\Draft \\Seen)")
        session.select(folder, readonly=False)
        # The APPEND response only carries the new uid on servers with
        # UIDPLUS, so find it the way any server can answer.
        uids = session.search_uids(f'HEADER Message-ID "{msg["Message-ID"]}"')
        uid = uids[-1] if uids else 0
        if replace_uid and int(replace_uid) != uid:
            _remove_draft(session, int(replace_uid))
        return {"uid": uid, "folder": folder, "messageId": msg["Message-ID"]}


def discard_draft(account, uid):
    """Delete one stored draft — used once its message has actually gone out."""
    with mailbox.Session(account) as session:
        folder = session.resolve_role("drafts")
        if not folder:
            return {"folder": ""}
        session.select(folder, readonly=False)
        _remove_draft(session, int(uid))
        return {"folder": folder}


def _remove_draft(session, uid):
    if uid <= 0:
        return
    session.store_flags([uid], ["\\Deleted"], add=True)
    session.expunge([uid])


def reply_draft(account, original, body_text, reply_all=False, body_html=""):
    """Prefill a reply from a fetched message's headers and body.

    When the original was HTML, the quoted block keeps it. A mail that
    arrived as a designed page should be quoted as one, the way Outlook
    quotes it -- flattening it to "> " lines throws away the table it was
    laid out in and every colour it chose.
    """
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

    return {
        "to": to,
        "cc": cc,
        "subject": subject,
        # The reply is what you write; the chain underneath it is separate so
        # the composer can fold it away and hand back an empty page to write
        # on. They are joined again when the message is sent.
        "body": "",
        "quoted": f"On {date}, {sender} wrote:\n{quoted}",
        "quotedHtml": _quoted_html(f"On {date}, {sender} wrote:", body_html),
        "inReplyTo": headers.get("Message-ID", ""),
        "references": " ".join(filter(None, [headers.get("References", ""),
                                             headers.get("Message-ID", "")])).strip(),
    }


def _quoted_html(intro, body_html, headers=None):
    """The original as an HTML block, under the line that says whose it is."""
    fragment = htmldoc.to_fragment(body_html)
    if not fragment:
        return ""
    lines = [f"<p>{html_escape(intro)}</p>"]
    for name in ("From", "Date", "Subject", "To"):
        value = (headers or {}).get(name, "")
        if value:
            lines.append(f"<div>{html_escape(name)}: {html_escape(str(value))}</div>")
    # The bar down the left is how every client marks quoted mail.
    return ("".join(lines)
            + '<blockquote style="margin:0 0 0 0.8em;padding-left:0.8em;'
              'border-left:2px solid #c8ccd4">' + fragment + "</blockquote>")


def html_escape(value):
    return (str(value).replace("&", "&amp;").replace("<", "&lt;")
            .replace(">", "&gt;").replace('"', "&quot;"))


def forward_draft(account, original, body_text, body_html=""):
    headers = original.get("headers", {})
    subject = headers.get("Subject", "")
    if not subject.lower().startswith("fwd:"):
        subject = f"Fwd: {subject}"
    lines = [
        "---------- Forwarded message ----------",
        f"From: {headers.get('From', '')}",
        f"Date: {headers.get('Date', '')}",
        f"Subject: {headers.get('Subject', '')}",
        f"To: {headers.get('To', '')}",
        "", str(body_text or ""),
    ]
    intro = "---------- Forwarded message ----------"
    return {"to": [], "cc": [], "subject": subject, "body": "",
            "quoted": "\n".join(lines),
            "quotedHtml": _quoted_html(intro, body_html, headers),
            "inReplyTo": "", "references": ""}
