"""Turning a fetched RFC822 message into what the reading pane shows."""

import os
import re
from pathlib import Path

from . import config, htmltext, mailbox, net


def _decode_part(part):
    try:
        payload = part.get_payload(decode=True)
    except Exception:
        return ""
    if payload is None:
        return ""
    charset = part.get_content_charset() or "utf-8"
    for encoding in (charset, "utf-8", "latin-1"):
        try:
            return payload.decode(encoding, "strict")
        except (UnicodeDecodeError, LookupError):
            continue
    return payload.decode("utf-8", "replace")


def _is_attachment(part):
    disposition = (part.get_content_disposition() or "").lower()
    if disposition == "attachment":
        return True
    if disposition == "inline" and part.get_filename():
        return True
    return bool(part.get_filename())


def extract(msg):
    """Split a message into display text, HTML, attachment list, and headers."""
    text_parts = []
    html_parts = []
    attachments = []

    for index, part in enumerate(msg.walk()):
        if part.get_content_maintype() == "multipart":
            continue
        content_type = part.get_content_type()
        if _is_attachment(part):
            payload = part.get_payload(decode=True) or b""
            attachments.append({
                "index": index,
                "filename": mailbox.decode_mime(part.get_filename() or f"part-{index}"),
                "mime": content_type,
                "size": len(payload),
                "inline": (part.get_content_disposition() or "") == "inline",
                "cid": (part.get("Content-ID") or "").strip("<>"),
            })
            continue
        if content_type == "text/plain":
            text_parts.append(_decode_part(part))
        elif content_type == "text/html":
            html_parts.append(_decode_part(part))

    html = "\n".join(p for p in html_parts if p).strip()
    text = "\n".join(p for p in text_parts if p).strip()
    if not text and html:
        text = htmltext.to_text(html)

    headers = {}
    for name in ("From", "To", "Cc", "Bcc", "Subject", "Date", "Message-ID",
                 "Reply-To", "In-Reply-To", "References", "List-Id"):
        value = msg.get(name)
        if value:
            headers[name] = mailbox.decode_mime(value)

    # Kept raw: these are machine-written and decoding them as display text
    # would only damage them.
    for name in ("Authentication-Results", "DKIM-Signature", "Received-SPF"):
        value = msg.get(name)
        if value:
            headers[name] = str(value)

    return {
        "text": _tidy(text),
        "html": html,
        "parts": attachments,
        "headers": headers,
        "authentication": authentication(headers),
    }


def authentication(headers, account=None):
    """What the receiving server made of the sender's identity.

    DKIM says the message really came from the domain that signed it and has
    not been altered since. SPF says the machine that handed it over was
    allowed to. DMARC says the domain in the From line is the one that passed.

    None of it says the sender is honest -- a spammer signs their own mail
    correctly -- so this is an answer to "who is this", not "is this safe".

    Two things keep it from being an answer the sender wrote themselves:

    - The Authentication-Results header counts only when the account's own
      provider wrote it. Anyone can put one in a message; the receiving
      server adds its own on top, and this reads the topmost -- but a server
      that adds none would leave the sender's forgery on top. So Gmail's has
      to say mx.google.com, and a server Olook knows nothing about has to
      name a host of its own domain.
    - "Verified" means the From line is vouched for: DMARC passed, which
      tests exactly that, or DKIM passed for the From address's own domain.
      A valid signature from some other domain vouches for that domain only.
    """
    line = str(headers.get("Authentication-Results") or "")
    signed = bool(headers.get("DKIM-Signature"))
    if line and account is not None and not _written_by_provider(line, account):
        line = ""
    lowered = line.lower()

    def verdict(name):
        found = re.search(r"\b" + name + r"=(\w+)", lowered)
        return found.group(1) if found else ""

    domain = ""
    signer = re.search(r"header\.d=([\w.-]+)", lowered) or \
        re.search(r"header\.i=[^@\s;]*@([\w.-]+)", lowered)
    if signer:
        domain = signer.group(1).rstrip(".")

    sender = _from_domain(headers.get("From"))
    dkim, dmarc = verdict("dkim"), verdict("dmarc")
    aligned = bool(domain and sender and net.site(domain) == net.site(sender))
    return {
        "dkim": dkim, "spf": verdict("spf"), "dmarc": dmarc,
        "signedBy": domain,
        "checked": bool(line) or signed,
        "verified": dmarc == "pass" or (dkim == "pass" and aligned),
    }


# Where each provider's receiving servers sign their verdict.
_PROVIDER_AUTHSERV = {
    "gmail": ("mx.google.com",),
    "icloud": ("mx.icloud.com", "icloud.com"),
    "yahoo": ("atlas", "yahoo.com"),
    "fastmail": ("mx.messagingengine.com", "messagingengine.com", "fastmail.com"),
    "zoho": ("mx.zohomail.com", "zohomail.com", "zoho.com"),
}


def _written_by_provider(line, account):
    provider = str(account.get("provider") or "")
    if provider == "demo":
        return True
    # Exchange Online writes its verdict without an authserv-id, and on top
    # of whatever arrived with the message; the topmost is its own.
    if provider == "microsoft":
        return True
    first = line.split(";", 1)[0].strip().lower()
    if not first or "=" in first:
        return False
    authserv = first.split()[0]
    known = _PROVIDER_AUTHSERV.get(provider)
    if known:
        return any(authserv == k or authserv.endswith("." + k) for k in known)
    host = str((account.get("imap") or {}).get("host") or "")
    return bool(host) and net.site(authserv) == net.site(host)


def _from_domain(value):
    found = mailbox.split_addresses(value)
    address = found[0]["address"] if found else ""
    return address.rsplit("@", 1)[1].lower() if "@" in address else ""


def _tidy(text):
    text = str(text or "").replace("\r\n", "\n").replace("\r", "\n")
    text = re.sub(r"[ \t]+\n", "\n", text)
    return re.sub(r"\n{4,}", "\n\n\n", text).strip()


def save_part(msg, index, dest_dir=None, filename=None):
    """Write attachment `index` to disk and return its path."""
    dest_dir = Path(dest_dir or config.ATTACHMENT_DIR)
    dest_dir.mkdir(parents=True, exist_ok=True)
    for position, part in enumerate(msg.walk()):
        if position != int(index):
            continue
        payload = part.get_payload(decode=True) or b""
        name = filename or mailbox.decode_mime(part.get_filename() or f"part-{index}")
        name = os.path.basename(name).replace("/", "_") or f"part-{index}"
        target = dest_dir / name
        counter = 1
        while target.exists():
            stem, suffix = os.path.splitext(name)
            target = dest_dir / f"{stem}-{counter}{suffix}"
            counter += 1
        target.write_bytes(payload)
        return str(target)
    raise ValueError(f"No part at index {index}")


def address_list(headers, field):
    return mailbox.split_addresses(headers.get(field, ""))


def quote_for_reply(body):
    lines = str(body or "").splitlines()
    return "\n".join("> " + line for line in lines)
