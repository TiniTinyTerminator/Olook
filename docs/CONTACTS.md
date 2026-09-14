# Google contacts and calendar

**You almost certainly do not need this page.** Both work out of the box:

```
olook contacts-auth --account <id>     # contacts and the calendar, one sign-in
olook contacts --sync
olook calendar --sync
```

The rest of this page is the older path, kept for the one case that still
wants it.

## Why nothing needs setting up

Olook talks to Google as Thunderbird, the way open-source mail clients
generally do: registering an application that thousands of people sign into
means passing Google's review, and Thunderbird has already passed it. That
application turns out to be approved for three things, not one:

| what | scope |
|---|---|
| mail | `https://mail.google.com/` |
| contacts | `https://www.googleapis.com/auth/carddav` |
| calendar | `https://www.googleapis.com/auth/calendar` |

Thunderbird asks for each only when connecting to that service, which is why
it took a while to notice. Olook now does the same: contacts over CardDAV,
the calendar over CalDAV, both on a grant of their own beside the mail one. A
scope cannot be widened after the fact -- an account already signed in for
mail holds a token good for mail alone -- so they ask separately, once.

Because that application is published rather than in testing, its tokens do
not expire after seven days, and none of the Google Cloud console below is
needed.

### The scope that *is* blocked

`https://www.googleapis.com/auth/contacts` -- the People API -- is not on
Thunderbird's list, and asking for it is what produces "Access blocked". It
reaches the same address book that `auth/carddav` does, by a different door.
If you have seen that screen, this is why.

## When you would still want your own application

Only if you want the People API specifically: it returns contact photos and a
few fields vCard does not carry, and it is a JSON API rather than XML over
WebDAV. Nothing in Olook needs it today.

Set one up and Olook uses it for contacts automatically, leaving the calendar
on the borrowed grant. Mail is untouched either way.

One thing to know before starting: mail cannot join it. Google grades
`mail.google.com` as *restricted*, which needs a paid third-party security
assessment before an application carrying it can be published, and an
unpublished application hands out refresh tokens that expire weekly. Contacts
and calendar scopes are only *sensitive*, so they publish without one.

## Making one

1. Open <https://console.cloud.google.com/> and make a project. Any name.

2. Enable the APIs your scopes belong to. The consent screen only offers
   scopes for APIs that are on, so this comes first.

   | API | enable it? | why |
   |---|---|---|
   | **Google People API** | yes | the contacts this reads and writes |
   | **CalDAV API** | with a calendar scope | what the calendar actually calls |
   | **Google Calendar API** | with a calendar scope | not called, but the scope only appears in the picker when it is on |
   | **Gmail API** | **no** | mail never touches it — see below |

   The two calendar entries are not a mistake. Olook reads calendars over
   CalDAV, which Google gates behind `caldav.googleapis.com`, a switch of its
   own that is separate from the scope. The Calendar API next to it is the
   REST one, which Olook never calls — but the consent screen's scope picker
   only lists scopes belonging to enabled APIs, and `auth/calendar` belongs to
   that one. So it is on for the picker's sake and does nothing afterwards.
   Leaving it on costs nothing: an enabled API consumes no quota until
   something calls it.

   Gmail is the surprising one. Olook reads and sends over IMAP and SMTP,
   authenticating with XOAUTH2; it makes no Gmail REST calls at all, so the
   Gmail API has nothing to do with any of this. Mail also runs on
   Thunderbird's application rather than yours, so nothing you enable in this
   project affects it either way.

   The direct links, which are more reliable than the library's search:

   - <https://console.cloud.google.com/apis/library/people.googleapis.com>
   - <https://console.cloud.google.com/apis/library/caldav.googleapis.com>
   - <https://console.cloud.google.com/apis/library/calendar-json.googleapis.com>

   Searching the library is worth avoiding: "People API" can come up empty,
   because it is listed with the "Google" in front. The **Contacts API** you will find
   instead is the old GData one, shut down in 2021, and is not what this
   talks to — the endpoint here is `people.googleapis.com`. Without the right
   one enabled, the scope will not appear in the consent screen's list and
   every request comes back 403.

3. Open **Google Auth Platform** (older consoles call this **APIs &
   Services → OAuth consent screen**; it is the same thing under four tabs).
   - **Branding**: an app name, and your own address for support and contact.
   - **Audience**: user type **External**. Under **Test users**, add your own
     Gmail address — an app in testing will not let anyone else near it.
   - **Data access → Add or remove scopes**: tick what you want the app to be
     allowed to do. Reading only:

         .../auth/contacts.readonly
         .../auth/calendar.readonly

     Reading and writing — for editing a contact or making an appointment
     from here, once Olook can:

         .../auth/contacts
         .../auth/calendar

     All four are *sensitive*, not *restricted*, so any of them can be
     published without an assessment. Ask for the wider pair now if you want
     them eventually: adding a scope later means going through the consent
     screen again.

4. **Clients → Create client** (older consoles: **Credentials → Create
   credentials → OAuth client ID**)
   - Application type **Desktop app**.
   - Copy the client ID and the client secret.

5. Give them to Olook, and sign in:

   ```
   olook set ACCOUNT \
     --contacts-client-id  YOUR_CLIENT_ID \
     --contacts-client-secret YOUR_CLIENT_SECRET \
     --contacts-scopes "contacts calendar"

   olook contacts-auth --account ACCOUNT
   ```

   `--contacts-scopes` takes the short names — `contacts`,
   `contacts.readonly`, `calendar`, `calendar.readonly` — and must match what
   you ticked in step 3. Left out, it asks to read contacts and nothing more.

   A browser opens. You will see "Google hasn't verified this app" — that is
   your own application, unreviewed, which is expected. Continue past it.

6. In Olook, open **People** and press the refresh button beside the search
   box. The same thing from a terminal, which says how many came back:

   ```
   olook contacts --sync --account ACCOUNT
   ```

## The one catch

An application left in **Testing** hands out refresh tokens that expire after
seven days, so contacts would stop working weekly. To avoid that, go back to
**Audience** and press **Publish app**. It stays unverified — you
keep the warning screen and a limit of 100 users, both of which are fine for
an application only you will ever use — but the tokens stop expiring.

Verification is only needed to remove the warning screen for strangers, which
is not a thing you need.

### If it asks for a domain

Two different screens ask, and only one of them is worth answering.

**Branding** has an *App domain* block — home page, privacy policy, terms —
and an *Authorized domains* list underneath it. All of it is optional, and the
list is only required once you have filled in one of the links above it. Leave
the four fields empty. A Desktop client redirects to `localhost`, so there is
no domain for Google to authorize in the first place.

**Verification** genuinely wants one: a site you own, carrying a privacy
policy, proven through Search Console. If publishing refuses to go through
without it, the cheapest real domain is the one the repository already has —
turn on GitHub Pages and `<user>.github.io` is a top private domain Google
accepts, verifiable by dropping the HTML file Search Console hands you into
the published folder.

Or skip the whole thing: leave the app in Testing and run `olook contacts-auth`
again when contacts go quiet. It is a weekly annoyance, not a broken feature.

## Undoing it

```
olook set ACCOUNT --contacts-client-id "" --contacts-client-secret ""
```

The address book already fetched stays in the cache until the next sync; the
mail-derived contacts carry on regardless.
