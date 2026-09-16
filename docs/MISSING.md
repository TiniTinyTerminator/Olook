# What Olook still lacks

Measured against Outlook, and against a couple of things Olook itself started
and did not finish. Ordered by what would actually be missed, not by what is
easiest. The last section is the part worth arguing about: features Outlook
has that this client is better off without.

## Asked for, not yet built

- **Markdown renders in place, the way Obsidian does it.** There is a live
  preview under the editor now, rendered by the engine that sends the mail so
  it cannot disagree with what arrives. What is still missing is rendering in
  the editor itself, with the syntax revealing at the cursor.

  Qt's own `TextEdit.MarkdownText` looked like the answer and is not: it
  round-trips through a rich text document, so a monospace editor font comes
  back as code spans -- `## Standup` returned as ``## `Standup` `` -- and
  emphasis typed after the fact is dropped entirely. It would quietly corrupt
  what you wrote. Doing this properly means a custom editor that keeps the
  markdown as the source of truth and decorates it, which is a project rather
  than a change.

- **Nothing here needs an application of your own any more.** Contacts and
  the calendar both ride on the grant the mail already uses, over CardDAV and
  CalDAV; Microsoft's go through Graph. The People API path is still in the
  tree for an account that has its own application configured, and is the only
  reason docs/CONTACTS.md still describes a Google Cloud project.

## Mail handling

- **Threading needs a resync to take effect on old mail.** References are
  kept from now on; messages already in the cache have none until the folder
  is fetched again, and fall back to matching on subject until then.
- **Conversations do not expand in the list.** The row is the newest message
  and the reading pane lists the rest; Outlook expands the row itself.

## Composing

- **Formatting controls.** Markdown and HTML are format choices with no
  toolbar behind them.
- **Send later**, and **recall** — the second only works between Exchange
  mailboxes anyway.

- **The bar widget's settings are still the widget's.** The Bar widget page
  shows the sync interval and the notification switch and says where to change
  them; the shell owns those values and the client cannot write them.

## Elsewhere

- **S/MIME and PGP signatures.** The client reads the server's verdict on who
  sent a message; it does not read a certificate carried by the message
  itself. Neither appears in any mail here, which is why it is far down this
  list rather than off it.


- **Two consent screens, not one.** Signing an account in now asks for its
  contacts and calendar straight after its mail, so nobody has to find a
  button for it later -- but it is two trips through the browser, because
  neither provider will issue one token for both. Microsoft mints a token per
  resource and IMAP and Graph are two; Google's mail scope sits on a grant of
  its own. The second is usually a click, the browser already knowing who you
  are.

- **Sending through Graph is untested against a server.** A tenant that has
  switched SMTP off -- TU Delft has -- sends through Graph instead, which is a
  different door to the same mailbox and not the one that switch closes. The
  detection and the fallback are written and the error it keys on was taken
  from the real refusal, but no message has gone out that way yet.

- **Calendars cannot be added or unsubscribed from here.** Which of the
  account's calendars are shown is a panel down the left of the Calendar tab,
  and that choice is kept. Subscribing to a new one, or leaving one for good,
  is still done wherever the account lives.

- **The calendar only reads.** A month grid with the day's agenda beside it
  is built, over CalDAV, and every calendar on the account is enumerated
  rather than only the default one. What is missing is writing: no new
  appointment, no edit, no accepting an invitation, and no meeting request
  from a message. The scope for it is already granted.

  Google gates CalDAV behind a switch of its own, `caldav.googleapis.com`,
  separately from the calendar scope. That only bites an account signed in
  with an application of your own -- the borrowed one has it -- and the 403
  names the API, which the client passes through with the link to turn it on.

- **Only Google and Microsoft have a calendar.** CalDAV was chosen so
  Nextcloud, Fastmail and iCloud need only a URL and a password rather than
  new code, but nothing discovers those yet.
- **Rules have no interface.** They work, and are managed with `olook rule
  add / list / remove`; nothing in the client shows or edits them.
- **Notifications** beyond the bar badge: a desktop notification per message
  with actions on it.

## Deliberately not worth having

- **Focused/Other inbox.** Two inboxes to check instead of one, sorted by a
  guess.
- **Read receipts.** Requested by senders, resented by recipients.
- **Voting buttons, polls, @mentions.** Exchange features that need Exchange
  on both ends.
- **Add-ins.** A plugin system inside a plugin.
- **The ribbon.** Olook's action row does the same work in one line.

## Known unverified

- Dragging the message-list edge, to confirm the folder tree holds its width.
  The reverse direction was measured; this one was interrupted.
- Undo: the engine side works and the Message-ID search it stands on was
  checked against the real mailbox, but no message has actually been moved and
  put back — that would mean shuffling real mail to find out.
- Conversation grouping was verified in the engine (40 messages collapsing to
  34 conversations on the real account) and the list renders with it on, but
  the demo account has no repeated subjects, so the count badge and the
  reading pane's list of earlier messages have not been seen.
- Sorting and the search refiners were verified through the engine, not
  through the menu and the search box.
- Sender verification and the image policy: the engine chain was verified
  against real mail — DKIM, SPF and DMARC parsed, and all three policies
  checked (verified lets seven images through, trusted and never hold them) —
  but the verified line and the "Always from this sender" button have not been
  seen on screen.
- Rules: matching, adding, listing and removing were verified, and a real sync
  runs the new path cleanly. No rule has actually been left in place to fire on
  arriving mail, which would mean moving real messages to find out.
- Categories: setting, storing, showing and searching were verified on the
  demo account, which has no server. The IMAP keyword itself -- the STORE that
  makes the category appear on your phone -- has not been sent, because doing
  so would leave a label behind in a real account.
- The markdown preview renders correctly when fed by hand; the debounce that
  drives it while typing has not been watched.
- Emptying a folder: the confirmation was written but never opened on screen,
  and the purge itself has deliberately not been run on real mail.
- The outbox was verified end to end against an account pointed at a host that
  does not resolve. What has not been seen is the status bar carrying the
  count, or a queued message going out on the next sync.
- The Bcc field and recipient completion: the code loads without error, but
  neither has been exercised on screen.
- The HTML quote inside the composer: the fragment renders correctly on its
  own and the built message carries it, but the fold itself has not been
  opened on screen.
- The reader popout's action buttons — reply, archive, delete, flag — are
  wired but only the window's opening and rendering were tested.

The address book is no longer among these: 500 contacts came down from Google,
and a contact was created, renamed and deleted against the live account, with
the local cache following each step.
