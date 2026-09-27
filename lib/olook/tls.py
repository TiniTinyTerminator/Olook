"""TLS for mail servers, with a pinned certificate where the account has one.

Ordinary servers are checked the ordinary way: a certificate signed by an
authority the system trusts, for the host name being connected to.

Some servers cannot pass that check and are still the right server. Proton
Mail Bridge runs on this machine and signs its own certificate, and a
self-hosted server may do the same. Turning the check off for them would let
anything that answers on that port -- another program on the machine, or
anything in the path to a remote server -- collect the password. So instead
the account can pin one certificate: that exact certificate, by its SHA-256
fingerprint, is accepted and no other, and the ordinary check is not used for
that server.

A pin comes from the certificate file (`olook set ACCOUNT --tls-cert
cert.pem`; Bridge exports its own from Settings -> Advanced settings ->
Export TLS certificates), or -- for a server on this machine only -- from what
the server presents, after the user has seen the fingerprint and said yes
(`olook trust-cert`).
"""

import hashlib
import imaplib
import smtplib
import ssl

from . import config


class PinMismatch(ssl.SSLError):
    def __str__(self):
        return str(self.args[0]) if self.args else "certificate mismatch"


def fingerprint(der):
    """SHA-256 of a certificate in DER form, as lowercase hex."""
    return hashlib.sha256(der).hexdigest()


def pretty(pin):
    """A fingerprint the way Bridge and browsers show one: AB:CD:..."""
    pin = str(pin or "").upper()
    return ":".join(pin[i:i + 2] for i in range(0, len(pin), 2))


def fingerprint_of_file(path):
    """The fingerprint of the first certificate in a PEM file."""
    with open(path, "r", encoding="ascii", errors="replace") as handle:
        text = handle.read()
    begin = text.find("-----BEGIN CERTIFICATE-----")
    end = text.find("-----END CERTIFICATE-----", begin)
    if begin == -1 or end == -1:
        raise ValueError(f"{path} holds no certificate (no BEGIN CERTIFICATE block).")
    block = text[begin:end + len("-----END CERTIFICATE-----")]
    return fingerprint(ssl.PEM_cert_to_DER_cert(block))


def context(account):
    """The SSL context for this account's servers, and the pin to check.

    With a pin, the context verifies nothing by itself -- the certificate is
    self-signed -- and check() must be called on the socket before anything
    else is sent. Without one, it is the system's ordinary verifying context
    and the pin is "".
    """
    pin = str(account.get("tlsPin") or "").lower()
    if not pin:
        return ssl.create_default_context(), ""
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx, pin


def check(sock, pin):
    """Refuse the connection unless the server presented the pinned certificate."""
    if not pin:
        return
    try:
        der = sock.getpeercert(binary_form=True)
    except (AttributeError, ValueError):
        der = None
    if not der or fingerprint(der) != pin:
        raise PinMismatch(
            "the server presented a different certificate from the one pinned for "
            "this account; not sending it the password")


def explain(host, account, error):
    """A certificate failure, said in a way that says what to do about it."""
    text = str(error)
    if "CERTIFICATE_VERIFY_FAILED" not in text and "certificate verify failed" not in text:
        return text
    ident = str(account.get("id") or "ACCOUNT")
    if config.is_loopback(host):
        return (f"The server on this machine ({host}) uses its own certificate, which "
                "is normal for Proton Mail Bridge. Trust it from Settings -> this "
                "account -> Trust this certificate, or pin the file Bridge exports "
                "(Settings -> Advanced settings -> Export TLS certificates): "
                f"olook set {ident} --tls-cert /path/to/cert.pem")
    return (f"{host}'s certificate could not be verified ({text}). If this server "
            "signs its own certificate, pin that certificate's file: "
            f"olook set {ident} --tls-cert /path/to/cert.pem")


def presented(host, port, kind, use_ssl, starttls, timeout=20):
    """The fingerprint of the certificate a server presents, verified by nothing.

    Only for showing the user what they would be trusting; nothing is sent to
    the server beyond what it takes to reach the TLS handshake.
    """
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    if kind == "imap":
        if use_ssl:
            conn = imaplib.IMAP4_SSL(host, port, ssl_context=ctx, timeout=timeout)
        else:
            conn = imaplib.IMAP4(host, port, timeout=timeout)
            if not starttls:
                raise ssl.SSLError("the server offers no encryption at all")
            conn.starttls(ctx)
        try:
            return fingerprint(conn.sock.getpeercert(binary_form=True))
        finally:
            try:
                conn.shutdown()
            except OSError:
                pass
    if use_ssl:
        conn = smtplib.SMTP_SSL(host, port, context=ctx, timeout=timeout)
    else:
        conn = smtplib.SMTP(host, port, timeout=timeout)
        conn.ehlo()
        if not starttls:
            raise ssl.SSLError("the server offers no encryption at all")
        conn.starttls(context=ctx)
    try:
        return fingerprint(conn.sock.getpeercert(binary_form=True))
    finally:
        try:
            conn.quit()
        except (OSError, smtplib.SMTPException):
            pass
