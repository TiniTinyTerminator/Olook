# Changelog

## Unreleased

- Olook is in the app menu: Finish setup installs a launcher entry and an
  icon, with **New message** among its actions.
- Finish setup and uninstall only touch files that are still Olook's. The
  command link, the mailto: and app-menu entries and the icon used to be
  overwritten and deleted whatever was there; now each is fingerprinted when
  written, and a file of yours, one you edited, or a symlink is left alone and
  reported.

## 1.2.1

**Security**
- Credentials follow a redirect only to the same origin: the same host and
  port, never onto plain http. 1.2.0 kept them within "the same site", judged
  by the last two labels of the host name, which made separate tenants of a
  shared host (alice.github.io and attacker.github.io) one site and ignored a
  change of port. iCloud's hand-off between its own CalDAV hosts is the one
  named exception.
- The same looseness is gone from sender verification: a DKIM signature
  vouches for the From address only when it is from that domain or a parent
  of it, and a server Olook does not know is believed only when its verdict
  carries the IMAP server's own name -- otherwise nothing is claimed either way.
- Mail notifications are bounded: at most three wait for a click at once, the
  oldest letting go first, and each lets go after ten minutes.

## 1.2.0

**Security.** Three reviews of everything that handles mail from other
people; each finding was reproduced before it was fixed.

- Credentials no longer follow a redirect to another site. A bearer token or
  CalDAV password was sent wherever a server redirected, even onto plain http.
- "Verified sender" now means DMARC passed, or DKIM passed for the From
  address's own domain, as judged by your provider. Before, any valid
  signature counted, so mail signed by one domain could be shown as verified
  while claiming to be from another -- and its pictures loaded by themselves.
- No password or token over an unencrypted connection: a server with neither
  SSL nor STARTTLS is refused unless it runs on this machine; CalDAV must be
  https.
- Message links open only when they are http, https or mailto; the rewritten
  HTML keeps nothing that points at a file on your computer; the message view
  can no longer be navigated away from the message.
- Names, subjects and folder names can no longer be read as HTML, which let an
  `<img>` in a subject fetch a tracking pixel in the message list.
- Secrets are never command-line arguments; CLI output cannot drive the
  terminal; notifications escape what they show; invisible direction
  overrides are stripped from names and attachment names; background mail
  watchers end with the shell.

**Fixed**
- Gmail contacts sync again: Google stopped answering the address-book query,
  so cards are now listed and fetched by address.
- The message's own controls (Formatted, Show images, ...) have a line of
  their own and no longer cover the first lines of a message in a narrow pane.
- A folder, search or appointment whose name starts with "-" works.
- Replying to a message whose subject hid a line break works.

**New**
- The window can be summoned into People, Settings or a calendar view.
- SECURITY.md: how to report a vulnerability.

## 1.1.0

- Installs with `omarchy plugin add`; **Settings → General → Finish setup**
  links the `olook` command, builds the HTML renderer library and registers
  the `mailto:` handler (`olook finish-setup` from a terminal).
- `mailto:` links open a compose window, filled in from the link.
- The bar icon shows a dot when new mail arrives -- by message, so an old
  message marked unread does not count and a shell restart does not forget
  it -- or the unread count if you choose it.
- The clock-and-calendar widget moves to its own repository,
  [olook-calendar](https://github.com/TiniTinyTerminator/Olook-calendar).

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
- `ttt.olook-calendar`: a clock that stands in for Omarchy's, laid out like
  its popup -- the date, the year's progress, a month with ISO week numbers --
  with the days you have something on marked, the coming week listed, and a
  reminder before each appointment.

What is still missing, and what cannot be built from here, is in
[docs/MISSING.md](docs/MISSING.md).
