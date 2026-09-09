# What Olook still lacks

Measured against Outlook, and against a couple of things Olook itself started
and did not finish. Ordered by what would actually be missed, not by what is
easiest. The last section is the part worth arguing about: features Outlook
has that this client is better off without.

## Asked for, not yet built

- **Markdown live preview in the composer.** The composer can already *send*
  markdown — `send.build` renders it to an HTML alternative — but you type raw
  syntax and see raw syntax. What was asked for is Obsidian's behaviour: the
  editor itself renders, and the syntax reveals itself when the cursor enters
  the span. That is an editor problem rather than a styling one, and it is the
  largest single item on this list.

- **Contacts from Google.** The People tab is built from mail on disk. Reading
  the real address book — the same one the phone syncs — needs
  `contacts.readonly` added to the OAuth scope, which forces re-authorising
  every Google account, plus a People API fetch, somewhere to keep it, and
  merge rules so one person is not two rows.

## Mail handling

- **Date range in search.** `from:`, `to:`, `subject:`, `is:unread`,
  `is:read`, `is:flagged` and `has:attachment` all work; `before:` and
  `after:` do not.
- **Conversation grouping.** Replies are separate rows. Outlook threads them,
  and for anything with more than two messages it is the difference between
  reading a conversation and reassembling one.
- **Empty Deleted Items / Junk.**

## Composing

- **Formatting controls.** Markdown and HTML are format choices with no
  toolbar behind them.
- **Signature editing per account.** The field exists in the account record;
  nothing in the interface writes it.
- **Send later**, and **recall** — the second only works between Exchange
  mailboxes anyway.

## Elsewhere

- **Calendar.** Still a placeholder. The engine already speaks to accounts
  that carry one.
- **Categories and colour labels.**
- **Rules.** Outlook's are a small programming language; something narrower —
  "from this sender, into that folder" — would carry most of the value.
- **Notifications** beyond the bar badge: a desktop notification per message
  with actions on it.
- **Offline queue.** Sending with no connection fails rather than waiting.

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
- Multi-select, the bulk action strip, the move picker and undo: the engine
  side of each was tested, and the Message-ID search undo depends on was
  checked against the real mailbox, but none of the four has been clicked
  through on screen.
- The Bcc field and recipient completion: the code loads without error, but
  neither has been exercised on screen.
- The HTML quote inside the composer: the fragment renders correctly on its
  own and the built message carries it, but the fold itself has not been
  opened on screen.
- The reader popout's action buttons — reply, archive, delete, flag — are
  wired but only the window's opening and rendering were tested.
