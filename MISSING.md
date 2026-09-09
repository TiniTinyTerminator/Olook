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

- **Contacts from Google.** The People tab is built from mail on disk. Reading
  the real address book — the same one the phone syncs — needs
  `contacts.readonly` added to the OAuth scope, which forces re-authorising
  every Google account, plus a People API fetch, somewhere to keep it, and
  merge rules so one person is not two rows.

## Mail handling

- **Date range in search.** `from:`, `to:`, `subject:`, `is:unread`,
  `is:read`, `is:flagged` and `has:attachment` all work; `before:` and
  `after:` do not.
- **Conversation grouping is by subject, not by References.** Two unrelated
  messages that happen to share a subject will be threaded together, and a
  reply whose subject was edited will not be. The cache does not keep
  References; adding it is a schema change and a resync.
- **Conversations do not expand in the list.** The row is the newest message
  and the reading pane lists the rest; Outlook expands the row itself.
- **Empty Deleted Items / Junk.**

## Composing

- **Formatting controls.** Markdown and HTML are format choices with no
  toolbar behind them.
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
- The Bcc field and recipient completion: the code loads without error, but
  neither has been exercised on screen.
- The HTML quote inside the composer: the fragment renders correctly on its
  own and the built message carries it, but the fold itself has not been
  opened on screen.
- The reader popout's action buttons — reply, archive, delete, flag — are
  wired but only the window's opening and rendering were tested.
