"""Contacts and the calendar on a Microsoft account, over Graph.

Microsoft does not speak CalDAV or CardDAV, so the address book and the
calendar that Google reaches through open protocols are reached here through
Graph instead. The shapes handed back match the other backends exactly, so
the client and the cache never learn which provider an account is on.

Unlike Google, no application of your own is needed. Google gates its
sensitive scopes on a reviewed application, which is why contacts there run
on a client id you register; Microsoft consents to delegated Graph
permissions at sign-in, so the same client that reads the mail can ask for
the address book as well. It does have to ask separately: an access token is
issued for one resource, and IMAP and Graph are two.
"""

import base64
import datetime
import json
import urllib.error
import urllib.parse
import urllib.request

from . import net, oauth

GRAPH = "https://graph.microsoft.com/v1.0"

# Mail.Send is here because a tenant can switch SMTP off entirely -- TU
# Delft has -- and then the only way out of the account is Graph. It is a
# different door to the same mailbox, and not the one the SMTP switch closes.
GRAPH_SCOPES = ("offline_access "
                "https://graph.microsoft.com/Contacts.ReadWrite "
                "https://graph.microsoft.com/Calendars.ReadWrite "
                "https://graph.microsoft.com/Mail.Send")

# The same thing with nothing that writes. A tenant can require an
# administrator to approve the set above while letting people consent to this
# one themselves, which is the difference between a read-only calendar and no
# calendar at all. Asking for less is the honest way past that; borrowing an
# application the tenant has already trusted, to get permissions it withheld,
# is not.
READ_SCOPES = ("offline_access "
               "https://graph.microsoft.com/Contacts.Read "
               "https://graph.microsoft.com/Calendars.Read")

# The old name, kept so nothing that imports it breaks.
CONTACT_SCOPES = GRAPH_SCOPES

# Only the fields the client shows, so a large book stays one round trip.
CONTACT_FIELDS = ("id,displayName,emailAddresses,mobilePhone,businessPhones,"
                  "homePhones,companyName")
EVENT_FIELDS = ("id,subject,bodyPreview,start,end,isAllDay,location,organizer,"
                "showAs,isCancelled,type,seriesMasterId")


class GraphError(Exception):
    pass


def supports(account):
    return (account.get("provider") == "microsoft"
            and account.get("auth") == "oauth2"
            and not account.get("demo"))


def configured(account):
    """Nothing to configure: the mail client id can ask for Graph itself."""
    return supports(account)


def grant(account):
    """A stand-in account for the Graph grant.

    Microsoft issues an access token for one resource at a time, so the token
    that opens IMAP cannot also read the address book however the scopes are
    written -- asking for both at once is refused outright. Graph therefore
    gets its own grant under its own name, the way Google's contacts do, and
    the two refresh tokens sit side by side without disturbing each other.
    """
    oauth_config = account.get("oauth") or {}
    # Which set was consented to has to be remembered: a refresh asks for the
    # scope again, and asking for more than was granted is refused.
    scope = READ_SCOPES if account.get("graphReadOnly") else GRAPH_SCOPES
    return {
        # Named for contacts because that is what it first carried; it now
        # covers the calendar and sending too. Renaming it would orphan the
        # token already stored under this name for no gain.
        "id": account["id"] + "#contacts",
        "reauth": "olook contacts-auth --account " + account["id"],
        "email": account.get("email", ""),
        "provider": "microsoft",
        "auth": "oauth2",
        "oauth": {
            "flavor": "microsoft",
            "client_id": oauth_config.get("client_id", ""),
            "client_secret": oauth_config.get("client_secret", ""),
            "tenant": oauth_config.get("tenant") or "common",
            "scope": scope,
            "exact": True,
        },
    }


def _call(account, method, path, body=None, params=None, headers=None):
    token = oauth.access_token(grant(account))
    url = GRAPH + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    sending = {
        "Authorization": "Bearer " + token,
        "Accept": "application/json",
    }
    if headers:
        sending.update(headers)
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        sending["Content-Type"] = "application/json"

    request = urllib.request.Request(url, data=data, method=method,
                                     headers=sending)
    try:
        with net.urlopen(request, timeout=45) as response:
            raw = response.read().decode("utf-8", "replace")
            return json.loads(raw) if raw.strip() else {}
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        try:
            detail = json.loads(detail)["error"]["message"]
        except (ValueError, KeyError, TypeError):
            detail = detail[:200]
        if exc.code in (401, 403):
            raise GraphError(
                "This account has not been given its address book and calendar. "
                "Sign in again to ask for them: olook contacts-auth --account "
                + str(account.get("id", "")) + " (" + detail + ")") from exc
        if exc.code == 412:
            raise GraphError(
                "That entry changed somewhere else since it was fetched. "
                "Refresh the list and try again.") from exc
        raise GraphError(f"Graph request failed: {exc.code} {detail}") from exc
    except urllib.error.URLError as exc:
        raise GraphError(f"Cannot reach Microsoft: {exc.reason}") from exc


def _pages(account, path, params, limit):
    """Follow @odata.nextLink until the list runs out or the limit is hit."""
    out = []
    query = dict(params)
    while len(out) < limit:
        payload = _call(account, "GET", path, params=query)
        out.extend(payload.get("value") or [])
        link = payload.get("@odata.nextLink") or ""
        if not link:
            break
        # The next link is a whole URL; keep only what goes after the version.
        split = link.split("/v1.0", 1)
        if len(split) != 2:
            break
        path, _, raw = split[1].partition("?")
        query = dict(urllib.parse.parse_qsl(raw))
    return out[:limit]


# ------------------------------------------------------------------ contacts

def _flatten_contact(entry):
    emails = [str((e or {}).get("address") or "").strip().lower()
              for e in (entry.get("emailAddresses") or [])]
    phones = []
    if entry.get("mobilePhone"):
        phones.append(str(entry["mobilePhone"]).strip())
    for key in ("businessPhones", "homePhones"):
        for number in (entry.get(key) or []):
            if number:
                phones.append(str(number).strip())
    return {
        "resource": str(entry.get("id") or ""),
        "etag": str(entry.get("@odata.etag") or ""),
        "name": str(entry.get("displayName") or "").strip(),
        "emails": [a for a in emails if a],
        "phones": phones,
        "organisation": str(entry.get("companyName") or "").strip(),
        "photo": "",
    }


def fetch(account, limit=2000):
    entries = _pages(account, "/me/contacts",
                     {"$select": CONTACT_FIELDS, "$top": "100"}, limit)
    return [_flatten_contact(e) for e in entries]


def _contact_body(contact):
    name = str(contact.get("name") or "").strip()
    emails = [a for a in (str(e or "").strip() for e in contact.get("emails") or []) if a]
    phones = [p for p in (str(n or "").strip() for n in contact.get("phones") or []) if p]
    body = {
        "displayName": name,
        "emailAddresses": [{"address": a, "name": name or a} for a in emails],
        "companyName": str(contact.get("organisation") or "").strip(),
        # The first number is the mobile because that is the one a phone
        # dials; the rest are business numbers, which is where Outlook keeps
        # anything it has no better home for.
        "mobilePhone": phones[0] if phones else None,
        "businessPhones": phones[1:4],
    }
    if name:
        parts = name.split()
        body["givenName"] = parts[0]
        body["surname"] = " ".join(parts[1:])
    return body


def _refuse_if_read_only(account, what):
    if account.get("graphReadOnly"):
        raise GraphError(
            "This account was signed in for reading only, so " + what
            + " is not possible. Signing in for the wider permissions needs "
            "your administrator to approve the application first.")


def create(account, contact):
    _refuse_if_read_only(account, "adding a contact")
    if not str(contact.get("name") or "").strip():
        raise GraphError("A contact needs at least a name.")
    return _flatten_contact(
        _call(account, "POST", "/me/contacts", body=_contact_body(contact)))


def update(account, resource, etag, contact):
    _refuse_if_read_only(account, "editing a contact")
    if not resource:
        raise GraphError("That contact has no address-book entry to edit.")
    headers = {"If-Match": etag} if etag else None
    return _flatten_contact(_call(
        account, "PATCH", "/me/contacts/" + urllib.parse.quote(resource),
        body=_contact_body(contact), headers=headers))


def remove(account, resource):
    _refuse_if_read_only(account, "deleting a contact")
    if not resource:
        raise GraphError("That contact has no address-book entry to delete.")
    _call(account, "DELETE", "/me/contacts/" + urllib.parse.quote(resource))
    return resource


# ------------------------------------------------------------------ calendar

def calendars(account):
    entries = _pages(account, "/me/calendars",
                     {"$select": "id,name,canEdit,hexColor", "$top": "50"}, 200)
    found = []
    for entry in entries:
        colour = str(entry.get("hexColor") or "")
        found.append({
            "id": str(entry.get("id") or ""),
            "url": "/me/calendars/" + str(entry.get("id") or ""),
            "name": str(entry.get("name") or "Calendar"),
            "colour": colour if colour.startswith("#") else "",
            "readOnly": not entry.get("canEdit", False),
        })
    found.sort(key=lambda c: c["name"].lower())
    return found


def _graph_time(value, all_day):
    """A Graph dateTime, asked for in UTC, as epoch seconds.

    An all-day event is midnight in the calendar's own zone, and stored here
    as UTC midnight, matching how the CalDAV side keeps them so that both end
    up on the same day whatever the reader's clock says.
    """
    stamp = str((value or {}).get("dateTime") or "")
    if not stamp:
        return 0
    stamp = stamp.split(".")[0]
    try:
        naive = datetime.datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        return 0
    if all_day:
        naive = naive.replace(hour=0, minute=0, second=0)
    return int(naive.replace(tzinfo=datetime.timezone.utc).timestamp())


def events(account, calendar, start, end):
    """Every occurrence in one calendar between two datetimes.

    calendarView is the expanded view: a weekly meeting comes back once per
    week rather than as a rule to work out here, which is what the CalDAV
    side gets by asking the server to expand.
    """
    params = {
        "startDateTime": start.astimezone(datetime.timezone.utc).strftime(
            "%Y-%m-%dT%H:%M:%SZ"),
        "endDateTime": end.astimezone(datetime.timezone.utc).strftime(
            "%Y-%m-%dT%H:%M:%SZ"),
        "$select": EVENT_FIELDS,
        "$top": "100",
        "$orderby": "start/dateTime",
    }
    path = "/me/calendars/" + urllib.parse.quote(calendar["id"]) + "/calendarView"

    # Asking for UTC means the times need no zone table on this side.
    token = oauth.access_token(grant(account))
    out = []
    query = dict(params)
    while len(out) < 2000:
        url = GRAPH + path + "?" + urllib.parse.urlencode(query)
        request = urllib.request.Request(url, headers={
            "Authorization": "Bearer " + token,
            "Accept": "application/json",
            "Prefer": 'outlook.timezone="UTC"',
        })
        try:
            with net.urlopen(request, timeout=45) as response:
                payload = json.loads(response.read().decode("utf-8", "replace"))
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")[:200]
            raise GraphError(f"Calendar request failed: {exc.code} {detail}") from exc
        except urllib.error.URLError as exc:
            raise GraphError(f"Cannot reach Microsoft: {exc.reason}") from exc

        for entry in payload.get("value") or []:
            if entry.get("isCancelled"):
                continue
            all_day = bool(entry.get("isAllDay"))
            begins = _graph_time(entry.get("start"), all_day)
            finishes = _graph_time(entry.get("end"), all_day)
            if finishes <= begins:
                finishes = begins + (86400 if all_day else 3600)
            when = datetime.datetime.fromtimestamp(
                begins, datetime.timezone.utc if all_day else None)
            out.append({
                "uid": str(entry.get("id") or ""),
                "summary": str(entry.get("subject") or ""),
                "location": str((entry.get("location") or {}).get("displayName") or ""),
                "description": str(entry.get("bodyPreview") or ""),
                "organiser": str(((entry.get("organizer") or {}).get("emailAddress")
                                  or {}).get("address") or ""),
                "status": str(entry.get("showAs") or ""),
                "start": begins,
                "end": finishes,
                "day": when.strftime("%Y-%m-%d"),
                "allDay": all_day,
                "recurring": str(entry.get("type") or "") in ("occurrence",
                                                              "exception"),
                "calendar": calendar["id"],
                "calendarName": calendar["name"],
                "colour": calendar["colour"],
                "url": "",
                "etag": "",
                "readOnly": calendar["readOnly"],
            })

        link = payload.get("@odata.nextLink") or ""
        if not link or "/v1.0" not in link:
            break
        path, _, raw = link.split("/v1.0", 1)[1].partition("?")
        query = dict(urllib.parse.parse_qsl(raw))
    return out


# ------------------------------------------------------------ writing events

def create_event(account, calendar, fields):
    """Add an appointment to one of the account's calendars."""
    _refuse_if_read_only(account, "adding an appointment")
    start, end = int(fields["start"]), int(fields["end"])
    body = {
        "subject": str(fields.get("summary") or "New appointment"),
        "isAllDay": bool(fields.get("allDay")),
    }
    if fields.get("allDay"):
        # Graph wants an all-day appointment as whole days at midnight, and
        # the end is the day after it finishes rather than the day it does.
        first = datetime.datetime.fromtimestamp(start, datetime.timezone.utc).date()
        last = datetime.datetime.fromtimestamp(end, datetime.timezone.utc).date()
        if last <= first:
            last = first + datetime.timedelta(days=1)
        body["start"] = {"dateTime": first.isoformat() + "T00:00:00", "timeZone": "UTC"}
        body["end"] = {"dateTime": last.isoformat() + "T00:00:00", "timeZone": "UTC"}
    else:
        stamp = "%Y-%m-%dT%H:%M:%S"
        body["start"] = {"dateTime": datetime.datetime.fromtimestamp(
            start, datetime.timezone.utc).strftime(stamp), "timeZone": "UTC"}
        body["end"] = {"dateTime": datetime.datetime.fromtimestamp(
            end, datetime.timezone.utc).strftime(stamp), "timeZone": "UTC"}
    if fields.get("location"):
        body["location"] = {"displayName": str(fields["location"])}
    if fields.get("description"):
        body["body"] = {"contentType": "text", "content": str(fields["description"])}

    made = _call(account, "POST",
                 "/me/calendars/" + urllib.parse.quote(calendar["id"]) + "/events",
                 body=body)
    return str(made.get("id") or "")


def update_event(account, event_id, fields):
    """Change one appointment. An occurrence of a series changes alone."""
    _refuse_if_read_only(account, "changing an appointment")
    start, end = int(fields["start"]), int(fields["end"])
    body = {"subject": str(fields.get("summary") or "Appointment"),
            "isAllDay": bool(fields.get("allDay"))}
    if fields.get("allDay"):
        first = datetime.datetime.fromtimestamp(start, datetime.timezone.utc).date()
        last = datetime.datetime.fromtimestamp(end, datetime.timezone.utc).date()
        if last <= first:
            last = first + datetime.timedelta(days=1)
        body["start"] = {"dateTime": first.isoformat() + "T00:00:00", "timeZone": "UTC"}
        body["end"] = {"dateTime": last.isoformat() + "T00:00:00", "timeZone": "UTC"}
    else:
        stamp = "%Y-%m-%dT%H:%M:%S"
        body["start"] = {"dateTime": datetime.datetime.fromtimestamp(
            start, datetime.timezone.utc).strftime(stamp), "timeZone": "UTC"}
        body["end"] = {"dateTime": datetime.datetime.fromtimestamp(
            end, datetime.timezone.utc).strftime(stamp), "timeZone": "UTC"}
    body["location"] = {"displayName": str(fields.get("location") or "")}
    if fields.get("description") is not None:
        body["body"] = {"contentType": "text", "content": str(fields.get("description") or "")}
    _call(account, "PATCH", "/me/events/" + urllib.parse.quote(event_id), body=body)
    return event_id


def delete_event(account, event_id):
    _refuse_if_read_only(account, "deleting an appointment")
    try:
        _call(account, "DELETE", "/me/events/" + urllib.parse.quote(event_id))
    except GraphError as exc:
        if "404" in str(exc):
            return True
        raise
    return True


# ----------------------------------------------------------------- picture

def account_photo(account, size="96x96"):
    """The account's own picture, as a data URI, or nothing.

    One request per account rather than one per contact: a mailbox has a
    single picture and five hundred contacts, and fetching each contact's
    would be five hundred round trips for a list that is mostly initials
    anyway.
    """
    token = oauth.access_token(grant(account))
    # The sized endpoint is not on every mailbox; the plain one always is.
    for path in ("/me/photos/%s/$value" % size, "/me/photo/$value"):
        request = urllib.request.Request(GRAPH + path, headers={
            "Authorization": "Bearer " + token})
        try:
            with net.urlopen(request, timeout=30) as response:
                kind = response.headers.get("Content-Type") or "image/jpeg"
                raw = response.read()
        except urllib.error.HTTPError as exc:
            # 404 is a mailbox with no picture set, which is not a failure.
            if exc.code in (401, 403):
                return ""
            continue
        except urllib.error.URLError:
            return ""
        if raw:
            return "data:%s;base64,%s" % (
                kind.split(";")[0], base64.b64encode(raw).decode("ascii"))
    return ""


# ---------------------------------------------------------------- sending

def send_mime(account, raw):
    """Send a built message through Graph rather than SMTP.

    A tenant can disable SMTP authentication for everyone in it, which is a
    control on legacy protocols rather than on the mailbox: Graph still
    sends. Graph accepts the MIME as it stands, base64-encoded, so the
    message this sends is the same one SMTP would have carried -- same
    headers, same parts, same Message-ID.

    Graph files the copy in Sent Items itself, so nothing should append one
    afterwards.
    """
    _refuse_if_read_only(account, "sending mail")
    body = base64.b64encode(raw).decode("ascii")
    token = oauth.access_token(grant(account))
    request = urllib.request.Request(
        GRAPH + "/me/sendMail", data=body.encode("ascii"), method="POST",
        headers={"Authorization": "Bearer " + token,
                 "Content-Type": "text/plain"})
    try:
        with net.urlopen(request, timeout=60) as response:
            response.read()
        return True
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        try:
            detail = json.loads(detail)["error"]["message"]
        except (ValueError, KeyError, TypeError):
            detail = detail[:200]
        if exc.code in (401, 403):
            raise GraphError(
                "This account has not been given permission to send through "
                "Graph. Sign in for it: olook contacts-auth --account "
                + str(account.get("id", "")) + " (" + detail + ")") from exc
        raise GraphError(f"Graph could not send the message: {detail}") from exc
    except urllib.error.URLError as exc:
        raise GraphError(f"Cannot reach Microsoft: {exc.reason}") from exc
