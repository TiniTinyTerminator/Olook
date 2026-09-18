# Changelog

## 1.0.0

The first release.

**Mail**
- Gmail, Outlook.com and Microsoft 365 over OAuth2, and any IMAP/SMTP server
  with a password; servers discovered from the address alone.
- Several accounts side by side, dragged into the order you want, with their
  folders dragged within them and any folder shown or hidden.
- Push mail over IMAP IDLE, with a notification that opens the message.
- HTML mail with remote pictures held back unless the sender is known.
- Conversations threaded on References and In-Reply-To, expanding in the list.
- Rules for arriving mail, managed in Settings.
- Plain text, Markdown or HTML, with formatting buttons and a live preview;
  drafts autosaved; send later; an outbox for mail written offline.
- Sending through Microsoft Graph when a tenant has switched SMTP off.

**Calendar**
- Day, work week, week and month views.
- Google over CalDAV, Microsoft over Graph, any CalDAV server (Nextcloud,
  Fastmail, iCloud), and `.ics` files and links with their recurrence expanded.
- Appointments added, changed and deleted; each opens in a window of its own.

**People**
- Google contacts over CardDAV and Microsoft's over Graph, added, edited and
  removed, with their pictures.

**Bar**
- `ttt.olook`: unread count and the newest mail across every account.
- `ttt.olook-calendar`: a clock that stands in for Omarchy's, with a month,
  what is next, and a reminder before each appointment.

What is still missing, and what cannot be built from here, is in
[docs/MISSING.md](docs/MISSING.md).
