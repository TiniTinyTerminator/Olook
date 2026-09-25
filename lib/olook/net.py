"""HTTP requests that carry a credential.

urllib follows a redirect by copying the request's headers to the new URL,
Authorization included, whatever host that URL names and even from https
down to http. So a bearer token or a CalDAV password would go wherever a
server -- or anything able to answer in its place -- pointed it. This is the
opener every credentialed request goes through instead.

A redirect keeps the credential only when it stays with the same origin --
the same host and port, and https unless it was http already (an upgrade to
https on the same host is fine). "The same site" is not good enough: on
shared hosting like github.io, alice.github.io and attacker.github.io are
different owners, and telling them apart needs the public suffix list,
which this client does not carry. The one exception is a short list of
providers known to hand a request between their own hosts, spelled out:
iCloud answers /.well-known/caldav on caldav.icloud.com and serves the
calendars from p12-caldav.icloud.com.

Any other redirect is followed without the credential, which is what a
browser does with a password it was only given for one origin. The method is
kept, because a PROPFIND that turns into a GET on the way is not the request
that was made.
"""

import urllib.parse
import urllib.request

# Providers whose own hosts pass a credentialed request between them, over
# https on the default port. Each entry is a domain only that provider can
# have hosts under.
_PROVIDER_DOMAINS = ("icloud.com",)


def _origin(url):
    parts = urllib.parse.urlsplit(url)
    scheme = (parts.scheme or "").lower()
    try:
        port = parts.port
    except ValueError:
        port = None
    if port is None:
        port = {"https": 443, "http": 80}.get(scheme)
    return scheme, (parts.hostname or "").lower(), port


def _provider_domain(host):
    for domain in _PROVIDER_DOMAINS:
        if host == domain or host.endswith("." + domain):
            return domain
    return ""


def keeps_credentials(old_url, new_url):
    """Whether a request to new_url may carry what old_url was given."""
    old_scheme, old_host, old_port = _origin(old_url)
    new_scheme, new_host, new_port = _origin(new_url)
    if not old_host or not new_host:
        return False
    if new_scheme not in ("http", "https"):
        return False
    if new_scheme == "http":
        # Never onto plain http -- only staying where an http server already
        # was (a local one; see caldav.add_server).
        return (old_scheme, old_host, old_port) == (new_scheme, new_host, new_port)
    if new_host == old_host:
        if (new_scheme, new_port) == (old_scheme, old_port):
            return True
        # http -> https on the same host, default ports: an upgrade.
        return (old_scheme, old_port, new_scheme, new_port) == ("http", 80, "https", 443)
    provider = _provider_domain(old_host)
    return bool(provider) and provider == _provider_domain(new_host) \
        and old_scheme == new_scheme == "https" and old_port == new_port == 443


class _Redirect(urllib.request.HTTPRedirectHandler):

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if code not in (301, 302, 303, 307, 308):
            return None
        method = req.get_method()
        data = req.data
        # 303, and a POST answered with 301 or 302, is a GET afterwards, as
        # every HTTP client has it. Everything else is asked again as it was.
        if code == 303 or (code in (301, 302) and method == "POST"):
            method, data = "GET", None
        kept = {}
        for name, value in req.header_items():
            lowered = name.lower()
            if lowered in ("authorization", "cookie") and \
                    not keeps_credentials(req.full_url, newurl):
                continue
            if data is None and lowered in ("content-type", "content-length"):
                continue
            kept[name] = value
        return urllib.request.Request(newurl, data=data, method=method, headers=kept)


_opener = urllib.request.build_opener(_Redirect)


def urlopen(request, timeout=45):
    """urllib.request.urlopen, for a request that carries a credential."""
    return _opener.open(request, timeout=timeout)
