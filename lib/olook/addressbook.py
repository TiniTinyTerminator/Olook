"""The address book the phone syncs, read over the provider's own API.

The People tab is built from mail: everyone written to or heard from. That
misses the people you have a number for and have never emailed, and it shows
"ci_activity@noreply.github.com" where a real name exists. This fills both
gaps in, from Google Contacts, and leaves the mail-derived list alone -- the
two are merged when they are read, not when they are stored.

Google only, for now. Microsoft's equivalent is Graph /me/contacts and would
slot in beside this.
"""

import json
import urllib.error
import urllib.parse
import urllib.request

from . import oauth, providers, store

PEOPLE_URL = "https://people.googleapis.com/v1/people/me/connections"
FIELDS = "names,emailAddresses,phoneNumbers,organizations,photos"


class AddressBookError(Exception):
    pass


def supports(account):
    """Whether this account has an address book we know how to read."""
    return (account.get("provider") == "gmail"
            and account.get("auth") == "oauth2"
            and not account.get("demo"))


def credentials(account):
    return account.get("contactsOauth") or {}


def configured(account):
    return bool(credentials(account).get("client_id"))


def grant(account):
    """A stand-in account for the contacts grant.

    Mail speaks to Google as Thunderbird, whose application is approved for
    mail and refuses to be asked for anything else. Contacts therefore needs
    an application of your own, and gets its own grant: a different client, a
    single scope, and tokens kept under their own name so neither can disturb
    the other.
    """
    creds = credentials(account)
    if not creds.get("client_id"):
        raise AddressBookError(
            "This account has no contacts application configured. "
            "See CONTACTS.md — it takes about five minutes.")
    return {
        "id": account["id"] + "#contacts",
        "email": account.get("email", ""),
        "provider": "gmail",
        "auth": "oauth2",
        "oauth": {
            "flavor": "google",
            "client_id": creds["client_id"],
            "client_secret": creds.get("client_secret", ""),
            "scope": providers.GOOGLE_CONTACTS_SCOPE,
            "exact": True,
        },
    }


def fetch(account, limit=2000):
    """Every contact the account can see, as flat records."""
    if not supports(account):
        raise AddressBookError("Only Google accounts carry an address book here.")

    token = oauth.access_token(grant(account))
    people, page = [], ""
    while len(people) < limit:
        query = {"personFields": FIELDS, "pageSize": "200"}
        if page:
            query["pageToken"] = page
        request = urllib.request.Request(
            PEOPLE_URL + "?" + urllib.parse.urlencode(query),
            headers={"Authorization": "Bearer " + token})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")[:200]
            if exc.code in (401, 403):
                raise AddressBookError(
                    "The contacts application has not been granted access. "
                    "Run: olook contacts-auth --account "
                    + str(account.get("id", ""))) from exc
            raise AddressBookError(f"Contacts request failed: {exc.code} {detail}") from exc
        except urllib.error.URLError as exc:
            raise AddressBookError(f"Cannot reach Google: {exc.reason}") from exc

        people.extend(payload.get("connections") or [])
        page = payload.get("nextPageToken") or ""
        if not page:
            break

    return [_flatten(person) for person in people]


def _first(values, key):
    for value in values or []:
        if value.get(key):
            return value[key]
    return ""


def _flatten(person):
    names = person.get("names") or []
    emails = [e.get("value", "").strip().lower()
              for e in (person.get("emailAddresses") or []) if e.get("value")]
    phones = [p.get("value", "").strip()
              for p in (person.get("phoneNumbers") or []) if p.get("value")]
    return {
        "resource": str(person.get("resourceName") or ""),
        "name": _first(names, "displayName"),
        "emails": emails,
        "phones": phones,
        "organisation": _first(person.get("organizations") or [], "name"),
        "photo": _first(person.get("photos") or [], "url"),
    }


def save(conn, account_id, people):
    """Replace this account's address book with what was just fetched."""
    store.replace_address_book(conn, account_id, people)
    return len(people)
