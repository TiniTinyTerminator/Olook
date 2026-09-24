"""OAuth2 for IMAP/SMTP (XOAUTH2).

Microsoft killed basic auth for IMAP on both Outlook.com and Microsoft 365, and
Google only allows password auth through app passwords, so OAuth is the real
path for the two providers most people are on.

Two grant types are implemented:

  loopback     — the way in for both providers. Authorization-code + PKCE
                 against a throwaway http://127.0.0.1:<port> listener: the
                 browser opens, you sign in, and it comes back on its own.
  device code  — Microsoft's fallback, used when the application is not
                 allowed to send the browser back to a local port or a tenant
                 forbids the hop. You read a short code off the panel and type
                 it on another screen; nothing has to listen on a port.

Refresh tokens live in the keyring; access tokens are cached beside them with
their expiry and refreshed on demand.
"""

import base64
import hashlib
import http.server
import json
import re
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


def _reauth(account):
    """How to sign this grant in again, in the user's terms.

    A side grant is a stand-in account with a name of its own, and telling
    someone to run `olook auth someone@outlook.com#contacts` is telling
    them about the plumbing.
    """
    return account.get("reauth") or ("olook auth " + str(account.get("id", "")))


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
            f"No OAuth token for {account['email']}. Run: {_reauth(account)}")

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
            # The token is left where it is. Google answers invalid_grant for a
            # revoked token, but also for a scope the client is not approved for
            # and for an app its own policy has blocked — cases the token would
            # survive once the configuration is put back. Signing in again
            # overwrites it, so keeping a dead token costs nothing and throwing
            # away a live one costs a sign-in.
            raise OAuthError(
                f"Authorization for {account['email']} was refused ({detail}). "
                f"Run: {_reauth(account)}")
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
    # Any program on this machine can reach the port. Only an answer carrying
    # the state this sign-in sent counts; anything else could end the wait
    # with a made-up error.
    expected_state = ""

    def do_GET(self):  # noqa: N802 - http.server API
        query = urllib.parse.urlparse(self.path).query
        params = {k: v[0] for k, v in urllib.parse.parse_qs(query).items()}
        ok = "code" in params and params.get("state") == _CodeHandler.expected_state
        if params.get("state") != _CodeHandler.expected_state:
            params = {}
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
    _CodeHandler.expected_state = state
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
        raise OAuthError(
            "Timed out waiting for the browser to come back. If it showed an "
            "error instead of a sign-in, this account can be signed in by "
            "typing a code instead: olook auth "
            + str(account.get("id", "")) + " --flow device")
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


# What Microsoft says when the application is not allowed to send the browser
# back to a local port. A tenant can also refuse the whole hop.
# Only the error code counts. The sign-in page quotes the request back at
# you, "redirect_uri" and all, so matching on the words alone calls every
# successful page a refusal.
REDIRECT_REFUSED = ("AADSTS50011",)

# The preflight below asks for a sign-in page, which is not served to a
# caller that announces itself as a script.
BROWSER_AGENT = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
                 "(KHTML, like Gecko) Chrome/128.0 Safari/537.36")


def authorize(account, emit, flow=None):
    """Run whichever grant fits the provider, honoring an explicit override."""
    config = endpoints(account)
    if not config["client_id"]:
        raise OAuthError(
            "No OAuth client id configured for this account. Set oauth.client_id "
            "in ~/.config/olook/accounts.json.")

    chosen = flow or "loopback"
    if chosen == "device":
        return device_flow(account, emit)

    # Signing in through the browser is the better way round when it works,
    # and it is not this client's place to assume it does: an application may
    # not be registered for a loopback address, and a tenant may forbid the
    # hop. Microsoft says so on the page rather than by redirecting, so a
    # browser sent there would sit on an error while this waited out its
    # timeout. Asking first costs one request and turns the clearest of those
    # refusals into a code the user can still type. It is a shortcut, not a
    # gate: anything it does not recognise falls through to the real attempt,
    # whose own timeout says how to sign in by code.
    if not flow and config["flavor"] == "microsoft" and config["device"]:
        refusal = _redirect_refused(config)
        if refusal:
            emit({"event": "fallback", "reason": refusal, "flow": "device"})
            return device_flow(account, emit)

    return loopback_flow(account, emit)


def _redirect_refused(config):
    """Whether the provider will turn a loopback redirect away, and why.

    Any free port stands in for the real one: a registration that allows the
    loopback address allows it on whichever port the listener lands on.
    """
    params = {
        "client_id": config["client_id"],
        "response_type": "code",
        "redirect_uri": "http://127.0.0.1:%d/" % _free_port(),
        "scope": config["scope"],
        "state": "preflight",
        "code_challenge": "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
        "code_challenge_method": "S256",
    }
    url = config["auth"] + "?" + urllib.parse.urlencode(params)
    try:
        request = urllib.request.Request(url, headers={"User-Agent": BROWSER_AGENT})
        with urllib.request.urlopen(request, timeout=15) as response:
            body = response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")
    except urllib.error.URLError:
        # Unreachable is not the same as refused; let the real attempt say so.
        return ""
    for mark in REDIRECT_REFUSED:
        if mark.lower() in body.lower():
            found = re.search(r"AADSTS\d+[^\"<\\]{0,160}", body)
            return found.group(0) if found else "the provider refused a local redirect"
    return ""
