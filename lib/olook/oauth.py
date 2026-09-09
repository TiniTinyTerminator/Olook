"""OAuth2 for IMAP/SMTP (XOAUTH2).

Microsoft killed basic auth for IMAP on both Outlook.com and Microsoft 365, and
Google only allows password auth through app passwords, so OAuth is the real
path for the two providers most people are on.

Two grant types are implemented:

  device code  — Microsoft only. The user reads a short code off the panel and
                 types it on another screen; nothing has to listen on a port.
  loopback     — Google, and Microsoft when a tenant's conditional-access
                 policy blocks device code. Authorization-code + PKCE against
                 a throwaway http://127.0.0.1:<port> listener.

Refresh tokens live in the keyring; access tokens are cached beside them with
their expiry and refreshed on demand.
"""

import base64
import hashlib
import http.server
import json
import secrets
import socket
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

from . import keyring, providers

TIMEOUT = 30
REFRESH_MARGIN = 120  # refresh this many seconds before actual expiry


class OAuthError(Exception):
    pass


def endpoints(account):
    """Resolve the authorization/token endpoints for an account."""
    oauth = account.get("oauth") or {}
    flavor = oauth.get("flavor") or ("google" if account.get("provider") == "gmail"
                                     else "microsoft")
    if flavor == "google":
        return {
            "flavor": "google",
            "auth": "https://accounts.google.com/o/oauth2/v2/auth",
            "token": "https://oauth2.googleapis.com/token",
            "device": "",
            # Whose application is asking decides what may be asked for.
            "scope": providers.scope_for(account),
            "client_id": oauth.get("client_id", ""),
            "client_secret": oauth.get("client_secret", ""),
        }
    tenant = oauth.get("tenant") or "common"
    base = f"https://login.microsoftonline.com/{urllib.parse.quote(tenant)}/oauth2/v2.0"
    return {
        "flavor": "microsoft",
        "auth": f"{base}/authorize",
        "token": f"{base}/token",
        "device": f"{base}/devicecode",
        "scope": oauth.get("scope") or (
            "offline_access https://outlook.office.com/IMAP.AccessAsUser.All "
            "https://outlook.office.com/SMTP.Send"),
        "client_id": oauth.get("client_id", ""),
        "client_secret": oauth.get("client_secret", ""),
    }


def _post(url, fields):
    data = urllib.parse.urlencode(fields).encode("utf-8")
    request = urllib.request.Request(
        url, data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded",
                 "Accept": "application/json",
                 "User-Agent": "olook/1.0"})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            return json.loads(response.read().decode("utf-8")), 200
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")
        try:
            return json.loads(body), exc.code
        except json.JSONDecodeError:
            return {"error": "http_error", "error_description": body}, exc.code
    except (urllib.error.URLError, OSError) as exc:
        raise OAuthError(f"Network error talking to {url}: {exc}") from exc


# ----------------------------------------------------------------- token cache

def _cache_key(account_id):
    return account_id


def store_tokens(account_id, payload):
    """Persist refresh + access tokens returned by a token endpoint."""
    refresh = payload.get("refresh_token")
    if refresh:
        keyring.set_secret(account_id, "refresh_token", refresh)
    access = payload.get("access_token")
    if access:
        expires_in = int(payload.get("expires_in") or 3600)
        keyring.set_secret(account_id, "access_token", json.dumps({
            "token": access,
            "expires_at": int(time.time()) + expires_in,
        }))
    return bool(refresh)


def cached_access_token(account_id):
    raw = keyring.get_secret(account_id, "access_token")
    if not raw:
        return None
    try:
        data = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return None
    if int(data.get("expires_at", 0)) - REFRESH_MARGIN <= time.time():
        return None
    return data.get("token")


def access_token(account, force_refresh=False):
    """Return a usable access token, refreshing when the cached one is stale."""
    account_id = account["id"]
    if not force_refresh:
        cached = cached_access_token(account_id)
        if cached:
            return cached

    refresh = keyring.get_secret(account_id, "refresh_token")
    if not refresh:
        raise OAuthError(
            f"No OAuth token for {account['email']}. Run: olook auth {account_id}")

    config = endpoints(account)
    fields = {
        "client_id": config["client_id"],
        "grant_type": "refresh_token",
        "refresh_token": refresh,
        "scope": config["scope"],
    }
    if config["client_secret"]:
        fields["client_secret"] = config["client_secret"]

    payload, status = _post(config["token"], fields)
    if status != 200 or "access_token" not in payload:
        detail = payload.get("error_description") or payload.get("error") or "unknown error"
        if payload.get("error") in ("invalid_grant", "invalid_request"):
            keyring.clear_secret(account_id, "refresh_token")
            raise OAuthError(
                f"Authorization for {account['email']} expired ({detail}). "
                f"Run: olook auth {account_id}")
        raise OAuthError(f"Token refresh failed: {detail}")

    store_tokens(account_id, payload)
    return payload["access_token"]


def xoauth2(username, token):
    """The SASL XOAUTH2 initial client response, base64-encoded."""
    raw = f"user={username}\x01auth=Bearer {token}\x01\x01".encode("utf-8")
    return base64.b64encode(raw).decode("ascii")


def xoauth2_raw(username, token):
    return f"user={username}\x01auth=Bearer {token}\x01\x01"


# ---------------------------------------------------------------- device code

def device_flow(account, emit, poll_deadline=600):
    """Microsoft device-code grant. `emit(event_dict)` reports progress."""
    config = endpoints(account)
    if not config["device"]:
        raise OAuthError("This provider does not support the device code flow.")

    payload, status = _post(config["device"], {
        "client_id": config["client_id"],
        "scope": config["scope"],
    })
    if status != 200 or "device_code" not in payload:
        detail = payload.get("error_description") or payload.get("error") or "unknown error"
        raise OAuthError(f"Could not start device login: {detail}")

    emit({
        "event": "device_code",
        "user_code": payload.get("user_code", ""),
        "verification_uri": payload.get("verification_uri", "https://microsoft.com/devicelogin"),
        "message": payload.get("message", ""),
        "expires_in": int(payload.get("expires_in") or 900),
    })

    interval = max(2, int(payload.get("interval") or 5))
    deadline = time.time() + min(poll_deadline, int(payload.get("expires_in") or 900))
    while time.time() < deadline:
        time.sleep(interval)
        result, status = _post(config["token"], {
            "client_id": config["client_id"],
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "device_code": payload["device_code"],
        })
        if status == 200 and "access_token" in result:
            store_tokens(account["id"], result)
            emit({"event": "authorized"})
            return result
        error = result.get("error", "")
        if error == "authorization_pending":
            continue
        if error == "slow_down":
            interval += 5
            continue
        detail = result.get("error_description") or error or "unknown error"
        raise OAuthError(f"Device login failed: {detail}")
    raise OAuthError("Device login timed out before it was approved.")


# ------------------------------------------------------------------- loopback

class _CodeHandler(http.server.BaseHTTPRequestHandler):
    result = {}

    def do_GET(self):  # noqa: N802 - http.server API
        query = urllib.parse.urlparse(self.path).query
        params = {k: v[0] for k, v in urllib.parse.parse_qs(query).items()}
        ok = "code" in params
        # Browsers also ask this port for /favicon.ico the moment the page
        # renders. Only a request that actually carries the grant may be
        # recorded, or that stray one overwrites the code with nothing and
        # the flow reports a timeout it never had.
        if ok or "error" in params:
            _CodeHandler.result = params
        body = _RESULT_PAGE_OK if ok else _RESULT_PAGE_FAIL
        encoded = body.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, *args):
        pass


_RESULT_PAGE_OK = """<!doctype html><meta charset="utf-8"><title>Olook</title>
<body style="font-family:system-ui;background:#101315;color:#cacccc;display:grid;
place-items:center;height:100vh;margin:0">
<div style="text-align:center"><h1>Account connected</h1>
<p>You can close this tab and go back to Olook.</p></div>"""

_RESULT_PAGE_FAIL = """<!doctype html><meta charset="utf-8"><title>Olook</title>
<body style="font-family:system-ui;background:#101315;color:#cacccc;display:grid;
place-items:center;height:100vh;margin:0">
<div style="text-align:center"><h1>Authorization failed</h1>
<p>Nothing was saved. Try again from Olook.</p></div>"""


def _free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def loopback_flow(account, emit, wait=300):
    """Authorization-code + PKCE against a local one-shot HTTP listener."""
    config = endpoints(account)
    verifier = base64.urlsafe_b64encode(secrets.token_bytes(48)).rstrip(b"=").decode()
    challenge = base64.urlsafe_b64encode(
        hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    state = secrets.token_urlsafe(16)

    port = _free_port()
    redirect_uri = f"http://127.0.0.1:{port}/"
    params = {
        "client_id": config["client_id"],
        "response_type": "code",
        "redirect_uri": redirect_uri,
        "scope": config["scope"],
        "state": state,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "login_hint": account.get("email", ""),
    }
    if config["flavor"] == "google":
        params["access_type"] = "offline"
        params["prompt"] = "consent"
    url = config["auth"] + "?" + urllib.parse.urlencode(params)

    _CodeHandler.result = {}
    server = http.server.HTTPServer(("127.0.0.1", port), _CodeHandler)
    thread = threading.Thread(target=_serve_until, args=(server,), daemon=True)
    thread.start()

    emit({"event": "open_url", "url": url, "redirect_uri": redirect_uri})

    deadline = time.time() + wait
    while time.time() < deadline and not _CodeHandler.result:
        time.sleep(0.25)
    server.shutdown()
    thread.join(timeout=5)
    server.server_close()

    result = _CodeHandler.result
    if not result:
        raise OAuthError("Timed out waiting for the browser to come back.")
    if result.get("state") != state:
        raise OAuthError("Authorization response did not match this request.")
    if "code" not in result:
        detail = result.get("error_description") or result.get("error") or "no code returned"
        raise OAuthError(f"Authorization failed: {detail}")

    fields = {
        "client_id": config["client_id"],
        "grant_type": "authorization_code",
        "code": result["code"],
        "redirect_uri": redirect_uri,
        "code_verifier": verifier,
    }
    if config["client_secret"]:
        fields["client_secret"] = config["client_secret"]

    payload, status = _post(config["token"], fields)
    if status != 200 or "access_token" not in payload:
        detail = payload.get("error_description") or payload.get("error") or "unknown error"
        raise OAuthError(f"Token exchange failed: {detail}")
    if not store_tokens(account["id"], payload):
        raise OAuthError("Provider returned no refresh token; authorization would not persist.")
    emit({"event": "authorized"})
    return payload


def _serve_until(server):
    """Run the listener until the main thread stops it.

    It has to be `serve_forever`: that is the loop `shutdown()` knows how to
    stop. Pairing `shutdown()` with a `handle_request()` loop deadlocks the
    moment the redirect lands — which took the Google sign-in down without
    ever reporting an error, because Microsoft uses the device flow and never
    reaches this code.
    """
    server.serve_forever(poll_interval=0.2)


def authorize(account, emit, flow=None):
    """Run whichever grant fits the provider, honoring an explicit override."""
    config = endpoints(account)
    if not config["client_id"]:
        raise OAuthError(
            "No OAuth client id configured for this account. Set oauth.client_id "
            "in ~/.config/olook/accounts.json.")
    chosen = flow or ("device" if config["flavor"] == "microsoft" else "loopback")
    if chosen == "device":
        return device_flow(account, emit)
    return loopback_flow(account, emit)
