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

Calendar belongs on your application when there is a calendar to fill. It is
sensitive rather than restricted, so it can sit beside contacts without
costing anything — add it to `scopes` in the account's `contactsOauth` and
sign in once more. No second project.

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

2. **APIs & Services → Library**, search for **People API**, enable it.

3. Open **Google Auth Platform** (older consoles call this **APIs &
   Services → OAuth consent screen**; it is the same thing under four tabs).
   - **Branding**: an app name, and your own address for support and contact.
   - **Audience**: user type **External**. Under **Test users**, add your own
     Gmail address — an app in testing will not let anyone else near it.
   - **Data access → Add or remove scopes**: tick
     `.../auth/contacts.readonly`. Nothing else. If you plan to add the
     calendar later, `.../auth/calendar.readonly` can go on at the same time.

4. **Clients → Create client** (older consoles: **Credentials → Create
   credentials → OAuth client ID**)
   - Application type **Desktop app**.
   - Copy the client ID and the client secret.

5. Give them to Olook, and sign in:

   ```
   olook set --account someone-gmail.com \
     --contacts-client-id  YOUR_CLIENT_ID \
     --contacts-client-secret YOUR_CLIENT_SECRET

   olook contacts-auth --account someone-gmail.com
   ```

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
