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
            "See docs/CONTACTS.md — it takes about five minutes.")
    return {
        "id": account["id"] + "#contacts",
        "reauth": "olook contacts-auth --account " + account["id"],
        "email": account.get("email", ""),
        "provider": "gmail",
        "auth": "oauth2",
        "oauth": {
            "flavor": "google",
            "client_id": creds["client_id"],
            "client_secret": creds.get("client_secret", ""),
            "scope": " ".join(scopes(account)),
            "exact": True,
        },
    }


def scopes(account):
    """What your own application asks for.

    Reading contacts unless the account says otherwise. Writing to contacts
    or the calendar is a wider grant and has to be asked for deliberately,
    because a permission granted is a permission that can be used -- and
    Olook cannot write to either yet, so asking for it today buys nothing but
    saves a second trip through the consent screen when it can.

    All of them are "sensitive" rather than "restricted" in Google's grading,
    read and write alike, so none of this costs the security assessment that a
    Gmail scope would. Mail stays with Thunderbird's application, which is
    already reviewed for it.
    """
    asked = credentials(account).get("scopes")
    if asked:
        return providers.expand_scope(" ".join(asked) if isinstance(asked, list)
                                      else str(asked))
    return [providers.GOOGLE_CONTACTS_SCOPE]


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
        "etag": str(person.get("etag") or ""),
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


# ------------------------------------------------------------------ writing

API_URL = "https://people.googleapis.com/v1/"

# The fields an edit is allowed to touch. Google wants this spelled out on
# every update, and anything left off it is wiped from the contact, so it has
# to match exactly what _person builds below.
WRITABLE = "names,emailAddresses,phoneNumbers,organizations"


def _person(contact):
    """A flat contact as the shape the People API expects back."""
    name = str(contact.get("name") or "").strip()
    person = {}
    if name:
        # unstructuredName lets Google do the splitting, which it does better
        # than a guess at where a family name starts -- "van der Berg" is one
        # surname and "Maria de Jong" is not three given names.
        person["names"] = [{"unstructuredName": name}]
    emails = [a for a in (str(e or "").strip() for e in contact.get("emails") or []) if a]
    if emails:
        person["emailAddresses"] = [{"value": a} for a in emails]
    phones = [p for p in (str(n or "").strip() for n in contact.get("phones") or []) if p]
    if phones:
        person["phoneNumbers"] = [{"value": p} for p in phones]
    organisation = str(contact.get("organisation") or "").strip()
    if organisation:
        person["organizations"] = [{"name": organisation}]
    return person


def _call(account, method, url, body=None):
    token = oauth.access_token(grant(account))
    data = json.dumps(body).encode("utf-8") if body is not None else None
    request = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": "Bearer " + token,
        "Content-Type": "application/json",
    })
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            raw = response.read().decode("utf-8")
            return json.loads(raw) if raw.strip() else {}
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        try:
            detail = json.loads(detail)["error"]["message"]
        except (ValueError, KeyError, TypeError):
            detail = detail[:200]
        if exc.code in (401, 403):
            raise AddressBookError(
                "Your contacts application may only read, not write. Ask for "
                "the wider scope and sign in again: olook set "
                + str(account.get("id", "")) + " --contacts-scopes contacts, "
                "then olook contacts-auth. (" + detail + ")") from exc
        if exc.code == 400 and "etag" in detail.lower():
            raise AddressBookError(
                "This contact changed somewhere else since it was last "
                "fetched. Refresh the list and try again.") from exc
        raise AddressBookError(f"Contacts request failed: {exc.code} {detail}") from exc
    except urllib.error.URLError as exc:
        raise AddressBookError(f"Cannot reach Google: {exc.reason}") from exc


def create(account, contact):
    """Add a contact to the account's address book, and return it as saved."""
    person = _person(contact)
    if not person:
        raise AddressBookError("A contact needs at least a name.")
    url = API_URL + "people:createContact?" + urllib.parse.urlencode(
        {"personFields": FIELDS})
    return _flatten(_call(account, "POST", url, person))


def update(account, resource, etag, contact):
    """Change a contact that is already there.

    The etag is Google's guard against two edits crossing: hand back the one
    that came with the copy being edited, and the write is refused if the
    contact moved on in the meantime.
    """
    if not resource:
        raise AddressBookError("That contact has no address-book entry to edit.")
    if not etag:
        raise AddressBookError(
            "This contact was cached before edits were possible. "
            "Refresh the list and try again.")
    person = _person(contact)
    person["etag"] = etag
    # resource is already "people/<id>", which is the path Google wants.
    url = (API_URL + resource + ":updateContact?"
           + urllib.parse.urlencode({"updatePersonFields": WRITABLE,
                                     "personFields": FIELDS}))
    return _flatten(_call(account, "PATCH", url, person))


def remove(account, resource):
    """Delete a contact from the account's address book."""
    if not resource:
        raise AddressBookError("That contact has no address-book entry to delete.")
    url = API_URL + resource + ":deleteContact"
    _call(account, "DELETE", url)
    return resource
