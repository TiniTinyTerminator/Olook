# Reading your Google contacts

The People tab is built from your mail. To have it also show the address book
your phone syncs — real names, phone numbers, and people you have never
emailed — Google needs an application of your own. This is about five minutes,
done once per Google account.

## Why your own application

Olook talks to Gmail as Thunderbird. Open-source mail clients generally do:
registering an application that thousands of people will sign into means
passing Google's review, and Thunderbird has already passed it. Its
application is approved **for mail and only for mail**, and Google refuses the
sign-in outright if it is asked for anything else. That is the "app is
blocked" screen — nothing on this machine can fix it, because the application
belongs to Thunderbird.

So contacts get their own application: yours, asking for one thing.

Mail is untouched by any of this and keeps working as it does now.

## Making one

1. Open <https://console.cloud.google.com/> and make a project. Any name.

2. **APIs & Services → Library**, search for **People API**, enable it.

3. **APIs & Services → OAuth consent screen**
   - User type **External**, then Create.
   - Fill in the app name and your own address where asked.
   - **Scopes**: add `.../auth/contacts.readonly`. Nothing else.
   - **Test users**: add your own Gmail address.

4. **APIs & Services → Credentials → Create credentials → OAuth client ID**
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
the OAuth consent screen and **Publish** the app. It stays unverified — you
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
