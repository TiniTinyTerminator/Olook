"""HTTP requests that carry a credential.

urllib follows a redirect by copying the request's headers to the new URL,
Authorization included, whatever host that URL names and even from https
down to http. So a bearer token or a CalDAV password would go wherever a
server -- or anything able to answer in its place -- pointed it. This is the
opener every credentialed request goes through instead.

A redirect keeps the credential only when it stays with the same site: the
same host, or a host under the same registrable domain (iCloud answers
/.well-known/caldav on caldav.icloud.com and serves the calendars from
p12-caldav.icloud.com), and never from https to http. Any other redirect is
followed without it, which is what a browser does with a password it was
only given for one site. The method is kept, because a PROPFIND that turns
into a GET on the way is not the request that was made.
"""

import urllib.parse
import urllib.request

# The last label here is a country code and the one before it a generic
# second level -- co.uk, com.au, ac.nz -- so the registrable domain is one
# label longer. Not the public suffix list, but it is the shape that matters
# for mail and calendar hosts, and the error it can make is the safe one:
# treating two sites as different.
_SECOND_LEVEL = {"co", "com", "net", "org", "ac", "gov", "edu", "ne", "or", "go"}


def site(host):
    """The registrable domain of a host, as well as can be told without the
    public suffix list."""
    labels = [part for part in str(host or "").lower().rstrip(".").split(".") if part]
    if len(labels) <= 2:
        return ".".join(labels)
    if len(labels[-1]) == 2 and labels[-2] in _SECOND_LEVEL:
        return ".".join(labels[-3:])
    return ".".join(labels[-2:])


def _loopback(host):
    return str(host or "").lower() in ("127.0.0.1", "::1", "localhost")


def keeps_credentials(old_url, new_url):
    """Whether a redirect from one URL to another may take the credential."""
    old = urllib.parse.urlsplit(old_url)
    new = urllib.parse.urlsplit(new_url)
    if old.scheme == "https" and new.scheme != "https" and not _loopback(new.hostname):
        return False
    if (old.hostname or "") == (new.hostname or ""):
        return True
    return bool(site(old.hostname)) and site(old.hostname) == site(new.hostname)


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
