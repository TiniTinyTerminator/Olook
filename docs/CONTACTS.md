# Reading your Google contacts

The People tab is built from your mail. To have it also show the address book
your phone syncs — real names, phone numbers, and people you have never
emailed — Google needs an application of your own. This is about five minutes,
done once per Google account.

## Can one application do mail, calendar and contacts?

It can, and you should not. Google grades scopes, and mail is graded harder
than the rest:

| scope | grade | an unverified app can publish it |
|---|---|---|
| `mail.google.com` | restricted | no — needs a paid third-party security assessment |
| `contacts.readonly` | sensitive | yes, with a warning screen |
| `calendar.readonly` | sensitive | yes, with a warning screen |

An application left unpublished — Google calls it Testing — hands out refresh
tokens that expire after seven days. Publishing stops that, and an application
asking for mail cannot be published without an assessment nobody is going to
buy for a personal mail client.

So one application for everything means signing into your mail every week. The
split below means signing into mail never: Thunderbird's application is
already reviewed for mail, and yours carries the rest.

Calendar belongs on your application when there is a calendar to fill, and so
does write access to either. All of them are sensitive rather than restricted,
so they sit beside contacts without costing anything — `--contacts-scopes`
sets them, and no second project is ever needed.

Worth knowing before you grant them: Olook cannot write to contacts or the
calendar yet. Granting the wider scopes now only saves you a second trip
through the consent screen when it can.

## Why your own application

Olook talks to Gmail as Thunderbird. Open-source mail clients generally do:
registering an application that thousands of people will sign into means
passing Google's review, and Thunderbird has already passed it. Its
application is approved **for mail and only for mail**, and Google refuses the
sign-in outright if it is asked for anything else. That is the "app is
blocked" screen — nothing on this machine can fix it, because the application
belongs to Thunderbird.

So contacts get their own application: yours, asking for the things
Thunderbird's cannot.

Mail is untouched by any of this and keeps working as it does now.

## Making one

1. Open <https://console.cloud.google.com/> and make a project. Any name.

2. Enable the APIs your scopes belong to. The consent screen only offers
   scopes for APIs that are on, so this comes first.

   | API | enable it? | why |
   |---|---|---|
   | **Google People API** | yes | the contacts this reads |
   | **Google Calendar API** | only with a calendar scope | needed for the scope to appear, and for the calls when they exist |
   | **Gmail API** | **no** | mail never touches it — see below |

   Gmail is the surprising one. Olook reads and sends over IMAP and SMTP,
   authenticating with XOAUTH2; it makes no Gmail REST calls at all, so the
   Gmail API has nothing to do with any of this. Mail also runs on
   Thunderbird's application rather than yours, so nothing you enable in this
   project affects it either way.

   Enable the People API most reliably by going straight to
   <https://console.cloud.google.com/apis/library/people.googleapis.com> and
   pressing Enable.

   Searching the library for "People API" can come up empty, because it is
   listed with the "Google" in front. The **Contacts API** you will find
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
   olook set --account ACCOUNT \
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
   box.

## The one catch

An application left in **Testing** hands out refresh tokens that expire after
seven days, so contacts would stop working weekly. To avoid that, go back to
**Audience** and press **Publish app**. It stays unverified — you
keep the warning screen and a limit of 100 users, both of which are fine for
an application only you will ever use — but the tokens stop expiring.

Verification is only needed to remove the warning screen for strangers, which
is not a thing you need.

## Undoing it

```
olook set --account ACCOUNT --contacts-client-id "" --contacts-client-secret ""
```

The address book already fetched stays in the cache until the next sync; the
mail-derived contacts carry on regardless.
