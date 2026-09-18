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

- **Mail is slow to arrive on screen.** Measured, not guessed. Reading from
  the cache is fast -- a folder lists in 0.11s and a cached message opens in
  0.11s, most of which is Python starting. Everything slow is the network,
  and every engine call pays for its own connection:

  | step | Gmail | Outlook |
  |---|---|---|
  | connect and log in | 0.61s | 0.29s |
  | select a folder | 0.21s | 0.09s |
  | log out, waited for | 0.26s | 0.25s |
  | one STATUS per folder | 1.50s (13) | 0.58s (15) |
  | a whole inbox sync | 3.0s | |
  | opening a message not yet cached | 1.1s | |

  Three of those are done: Gmail's folder counts come back in one
  `LIST-STATUS` (1.63s to 0.15s), the log-out is no longer waited for, and
  the newest fifteen messages of a folder are fetched during the sync, so a
  first click on one is a read from disk -- 0.88s to 0.11s. An inbox sync
  went from 3.0s to 1.5s.

  What remains is the connection itself. Every engine call still opens its
  own, and a click on anything older than the prefetched fifteen pays for
  one. The real fix is one long-lived connection per account; the `watch`
  process already holds one for IDLE and could carry the rest. Outlook has no
  `LIST-STATUS` and still asks each folder in turn.


## Composing

- **Recall** only works between Exchange mailboxes, and asks the recipient's
  server to delete something already delivered. Nothing to build on IMAP.

- **The bar widget's settings are still the widget's.** The Bar widget page
  shows the sync interval and the notification switch and says where to change
  them; the shell owns those values and the client cannot write them.

## Elsewhere

- **S/MIME and PGP signatures.** The client reads the server's verdict on who
  sent a message; it does not read a certificate carried by the message
  itself. Neither appears in any mail here, which is why it is far down this
  list rather than off it.


- **A tenant can refuse the whole thing.** An organisation may require an
  administrator to approve a third-party application before anyone in it can
  consent -- TU Delft does, for Thunderbird's. Signing in for reading only
  asks for less and some tenants allow that without approval, which is the
  difference between a read-only calendar and no calendar; writing and
  sending then need the administrator. Nothing here tries to get around the
  refusal, and borrowing an application the tenant has already trusted in
  order to obtain permissions it withheld would be exactly that.

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

- **Non-mail folders are guessed by name.** Exchange's calendar, contacts
  and task folders are left out of the mail tree because IMAP cannot read
  them, and the names are matched in English, Dutch and German. A mailbox in
  another language lists them until they are hidden by hand, which each
  account's settings page now allows -- for any folder, either way.

- **One occurrence of a Google series cannot be changed on its own.** Over
  CalDAV an occurrence shares its series' resource, so rewriting it would
  replace every week with this one; the client refuses rather than doing
  that. Outlook changes an occurrence alone, and single appointments change
  on both.

- **Gmail has no picture for the account itself.** A contact's picture comes
  out of the vCard and a Microsoft mailbox's own comes from Graph, but
  Google's needs the `profile` scope, which is another trip through consent
  for a small thing. Contact pictures from a Microsoft mailbox are also not
  fetched: that is one request per contact, five hundred round trips for a
  list that is mostly initials.

- **Recurrence in a file is read, not honoured in full.** CalDAV and Graph
  expand a range on the server; a file has to be expanded here, and what is
  implemented is the part a timetable is written with -- the frequencies,
  INTERVAL, COUNT, UNTIL, BYDAY (weekly, and with a position monthly or
  yearly: "2TU", "-1FR"), BYMONTHDAY, BYMONTH, BYSETPOS, EXDATE, and a single
  occurrence moved, renamed or cancelled through RECURRENCE-ID. Hourly rules,
  BYWEEKNO and BYYEARDAY are ignored rather than guessed at, which gives the
  plain repetition instead of a wrong one; no timetable seen uses them.

- **One plugin cannot summon another's window from inside the shell.** A
  plugin's `bar.shell` handle is scoped to itself: `summon` is there, takes
  the arguments, and quietly does nothing for somebody else's overlay. The
  calendar widget therefore asks through `omarchy-shell` from outside, which
  is a process per click rather than a call.

- **Reminders are the widget's, not the engine's.** The notification before
  an appointment comes from the bar widget, so it only fires while the shell
  is running and only for appointments already fetched into it. Nothing wakes
  the machine for one, and closing the bar closes the reminders with it.

- **The bar widget replaced the clock's extras with appointments.** Omarchy's
  clock popup also carried ISO week numbers, a year-progress bar and an age
  readout; this one carries the days you have something on and what is on
  them. Anyone who wants the old extras back wants `omarchy plugin enable
  omarchy.clock`, not this.

- **Calendars cannot be added or unsubscribed from here.** Which of the
  account's calendars are shown is a panel down the left of the Calendar tab,
  and that choice is kept. Subscribing to a new one, or leaving one for good,
  is still done wherever the account lives.

  Google gates CalDAV behind a switch of its own, `caldav.googleapis.com`,
  separately from the calendar scope. That only bites an account signed in
  with an application of your own -- the borrowed one has it -- and the 403
  names the API, which the client passes through with the link to turn it on.

- **A CalDAV server is added by address, not discovered from the mail
  account.** Nextcloud, Fastmail and iCloud work from the calendar panel with
  a server address, a user name and an (app) password -- tested against a
  Radicale server: calendars found through /.well-known/caldav, and an
  appointment added, changed and deleted. Nothing looks the server up from an
  address's domain, and the password is a password: none of those three
  offers the same sign-in the mail uses.
- **Notifications carry one action, not several.** Clicking the popup opens
  the message it is about. Archive or mark-read buttons on the popup itself
  would be a few more `--action` flags, but Omarchy's notification daemon
  draws no action buttons and only ever invokes `default`, so they would be
  offered and never shown.

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
