# Olook

A mail client for [Omarchy](https://omarchy.org/), built as a plugin for the
Omarchy shell — so it is QML running inside the same Quickshell process as the
bar, themed by whatever Omarchy theme you are using.

It is laid out like Outlook on Windows: an app rail, a folder pane, a message
list grouped by date, and a reading pane.

The bar panel shows every inbox at once by default. The avatar row under the
header narrows it to a single account — the address it is showing is spelled
out beneath the row, and the unread count follows the choice. It lasts for the
session; the panel opens on **All** again after a restart.

```
┌──────────────────────────────────────────────────────────────────────────┐
│ ✉ Olook  Mail          [ Search mail ]                        ⟳    ✕     │
├──────────────────────────────────────────────────────────────────────────┤
│ File   View   Message   Help                                             │
├────┬──────────────┬──────────────────────────┬───────────────────────────┤
│ ✉3 │  + New mail  │  All  Unread  Flagged    │  Notes on the Analytical… │
│ 📅 │ ⌄ Personal   │  ── Today ───────────────│  AL  Ada Lovelace         │
│ 👤 │   Inbox   2  │ ▏Ada Lovelace      19:15 │  ↩ Reply  ↩↩ All  ↪ Fwd   │
│    │   Drafts     │  Notes on the Analyt…    │  ─────────────────────    │
│    │   Sent Items │  The engine can arra…    │  The engine can arrange   │
│    │   Archive    │ ▏Omarchy           18:15 │  and combine numerical…   │
│    │   Junk    1  │  Omarchy 4.0 is out      │                           │
│    │ › Work    1  │  ── Yesterday ───────────│                           │
│    │              │  GitHub       Yesterday  │                           │
├────┴──────────────┴──────────────────────────┴───────────────────────────┤
│ 5 messages,  2 unread                                    Updated 19:15   │
└──────────────────────────────────────────────────────────────────────────┘
```

**What works today**

- Gmail / Google Workspace, Outlook.com, and Microsoft 365 business accounts
  over OAuth2 (XOAUTH2), plus any other IMAP/SMTP server with a password
- Server autodiscovery from just an email address
- Several accounts at once: each is a collapsible section in the folder pane
  with its own folders nested under it
- Adding accounts from inside the app — a setup panel that autodiscovers the
  servers and walks you through the sign-in, so the terminal is optional
- A settings view for the accounts you already have: rename, edit the
  signature, re-authorize, pause syncing, test the connection, remove
- Bar widget with an unread badge and the newest mail across every account,
  filterable to one mailbox — click an account's avatar in the panel, or step
  through them with `←` / `→`
- Read, reply, reply-all, forward, archive, delete, flag, mark read/unread
- HTML mail rendered properly, with remote images blocked and a toggle back to
  plain text
- Compose and send as plain text, Markdown, or HTML, with the message
  autosaved to the Drafts folder so closing the composer never loses it
- Push mail: an IMAP IDLE connection per account, so new mail and its
  notification arrive when it arrives rather than on the next poll
- Attachments both ways: sent with a message, and saved from one to disk —
  drag files onto the composer, or use the paperclip
- A composer that pops out into its own window, so a long message can sit on
  another workspace while you carry on reading mail
- A menu bar — File, View, Message, Help — for the things you set once
- A window that survives being made narrow: the folder pane collapses to icons,
  and below that the list and reading pane take turns instead of overlapping
- Reading pane on the right or along the bottom, your choice
- Search across the local cache, keyboard-driven navigation throughout
- Desktop notification when new mail arrives

**Not yet**

- The Calendar and People views in the rail are placeholders. The engine
  already authenticates against the same accounts, so calendar is the next
  thing to build on top of it.

## Install

```bash
git clone <this repo> ~/Projects/mailclient
cd ~/Projects/mailclient
./install.sh          # copies into ~/.config/omarchy/plugins and enables it
```

The installer adds the bar widget and links the engine to `~/.local/bin/olook`.
`./install.sh --uninstall` removes both and leaves your accounts and cached mail
alone.

**If you edit the plugin**, re-run `./install.sh` — it copies the changed files
and asks the shell to rescan. The bar widget picks the change up immediately.

The window does **not**: Quickshell compiles `MailWindow.qml` and everything it
pulls in once, and keeps it for the life of the shell process, so `rescanPlugins`,
toggling the plugin off and on, and `shell reloadConfig` all leave the old window
running. After changing anything the window draws, `omarchy restart shell`, or you
will be testing the previous version — the new IPC verbs missing from
`qs ipc -i <instance> show` is the giveaway.

There is a `--link` mode that symlinks the checkout instead, but the shell's
watcher does not see edits through the symlink, so that mode needs a restart for
the bar widget too.

## Add an account

Open Olook and click **Settings** at the bottom of the rail (or press `Ctrl+,`),
then **Add an account**. It asks for your address, works out the servers, signs
you in, tests the connection, and pulls your inbox — the same steps as the
terminal version:

```bash
olook setup
```

What the sign-in looks like per provider:

| Provider | Detected by | Sign-in |
|---|---|---|
| Gmail / Google Workspace | domain, or MX pointing at Google | Browser window, Google consent screen |
| Outlook.com, Hotmail, Live | domain | Device code: a short code you enter at microsoft.com/devicelogin |
| Microsoft 365 (work/school) | MX pointing at `*.mail.protection.outlook.com` | Device code, same as above |
| iCloud, Yahoo, Fastmail, Zoho | domain | App-specific password |
| Anything else | Thunderbird's ISPDB, the domain's autoconfig XML, then a guess | Password |

Microsoft has turned off basic authentication for IMAP, so work accounts *must*
use OAuth — that is why the sign-in is a code rather than a password box. If
your tenant's conditional-access policy blocks the device-code grant, use the
browser flow instead:

```bash
olook auth <account-id> --flow loopback
```

Signing in again later (tokens do expire) can be done from inside the app: the
reading pane turns into a sign-in card whenever an account loses its
authorization.

### Using your own OAuth client id

Olook ships the public client identifiers Thunderbird uses, which is what lets
`olook setup` work with no registration step. To use your own instead, register
a desktop/native app with Google or Microsoft and put the id in
`~/.config/olook/accounts.json`:

```json
"oauth": {
  "flavor": "microsoft",
  "client_id": "<your app id>",
  "tenant": "<your tenant id, or common>"
}
```

Microsoft needs the delegated permissions `IMAP.AccessAsUser.All` and
`SMTP.Send`; Google needs the `https://mail.google.com/` scope.

Note that Thunderbird's application is approved for mail and refuses to be
asked for anything else — ask it for contacts or a calendar and Google blocks
the sign-in outright. Those run on a separate application of your own; see
[CONTACTS.md](CONTACTS.md), which is about five minutes of clicking and does
not disturb how mail signs in.

## Using it

Click the envelope in the bar for the panel, or open the full window from the
panel's **Open Mail** button.

The menu bar carries what you do not need on the surface: **File** for new
messages, accounts and settings, **View** for the layout, **Message** for
everything you can do to the selected mail, **Help** for the key list. `F10`
opens it from the keyboard.

From a terminal or a keybinding:

```bash
omarchy-shell shell summon ttt.olook '{}'                # open
omarchy-shell shell summon ttt.olook '{"compose":true}'  # open composing
omarchy-shell ttt.olook toggle                           # bar panel
omarchy-shell ttt.olook sync                             # check for mail

omarchy-shell ttt.olook-window newMessage                # compose window only
omarchy-shell ttt.olook-window settings                  # settings view
omarchy-shell ttt.olook-window addAccount                # straight to setup
```

`composeWith` takes a draft, for a `mailto:` handler or a "mail me this file"
script:

```bash
omarchy-shell ttt.olook-window composeWith \
  '{"to":["ada@example.com"],"subject":"Logs","format":"markdown",
    "attachments":["/tmp/run.log"]}'
```

### Keyboard

| Key | Does |
|---|---|
| `j` / `k`, `↓` / `↑` | Move through the list |
| `Enter` | Open the selected message |
| `Tab` | Cycle folder pane → list → reading pane |
| `c` or `n` | New message |
| `r` / `R` or `a` | Reply / reply all |
| `f` | Forward |
| `e` | Archive |
| `Delete` | Delete |
| `u` | Toggle read/unread |
| `s` | Toggle flag |
| `/` | Search |
| `g` | Check for new mail |
| `Ctrl+c` / `Ctrl+n` | New message in its own window |
| `F10` | Open the menus, then `←` `→` between them and `↑` `↓` within one |
| `?` | Keyboard shortcuts |
| `Ctrl+,` | Settings |
| `Ctrl+Enter` | Send (while composing) |
| `Ctrl+Shift+A` | Attach files (while composing) |
| `Ctrl+Shift+O` | Move the message you are writing into its own window |
| `Esc` | Close compose (keeping a draft) → back → clear search → close |

### The window when it is small

Olook is meant to be tiled, which means it gets narrow. Rather than letting the
panes overlap, it gives up chrome in two steps — and nothing it gives up costs
you an action:

| Width | What changes |
|---|---|
| Wide | Folder pane with account and folder names, list, reading pane |
| Under ~1120 | The folder pane keeps every account and folder but shows them as icons; the names move into tooltips |
| Under ~780 | The list and the reading pane stop sharing the width and take turns — opening a message swaps to it, and a **‹ Messages** button (or `Esc`) goes back |

The reading pane's own buttons drop their labels for their icons when the pane
itself is narrow, and the search box shrinks and then steps aside rather than
running into the buttons either side of it.

**View → Folder pane** pins this if you would rather decide yourself: *Fit to
window* (the default), *Names*, or *Icons only*. **View → Reading pane** puts
the message to the right of the list or underneath it.

### Writing

The composer has a **Write in** dropdown with three choices:

| Format | What is sent |
|---|---|
| Plain text | `text/plain`. What you typed, nothing added. |
| Markdown | `multipart/alternative` — your Markdown as `text/plain`, and a rendered `text/html` beside it. Headings, lists, quotes, code, links, bold/italic/strike. |
| HTML | `multipart/alternative` — your HTML as `text/html`, and a text flattening of it as `text/plain`. Sent as you wrote it. |

Markdown is the useful default for anything with structure: people whose client
shows plain text still read exactly what you typed.

The paperclip (or `Ctrl+Shift+A`) attaches files, and so does dropping them on
the composer from a file manager; each one becomes a chip you can click to
remove. Attachments go out as normal MIME parts, so they arrive
the way any other client sends them.

The **⿻** button next to it hands the whole draft — recipients, subject, body,
format and attachments — to its own window, which you can then throw at another
workspace and finish later. `Ctrl+Shift+O` does the same from the keyboard. The
popped-out window remembers which account it was started from, so changing
folders in the main window afterwards cannot redirect the sender.

### Drafts

A message being written is saved to the account's Drafts folder a few seconds
after you stop typing, and again when you close the composer — so `Esc`, the
✕, and closing the whole client all keep the message rather than discarding it.
Popping a draft out to its own window carries the saved copy with it instead of
leaving a second one behind, and sending deletes it.

Click a message in **Drafts** (or press `Enter` on it) to carry on writing it.
Selecting one with `j`/`k` still just previews it, so walking the folder does
not throw you into the composer.

Two things to know:

- **Attachments are not restored** when you reopen a draft — the files stay on
  the saved copy on the server, and the composer says so in red rather than
  letting them go missing quietly. Attach them again before sending.
- **Demo accounts have no server**, so nothing is autosaved while you are
  trying the interface with `olook demo`.

To delete a draft rather than keep it, delete it from the Drafts folder.

### Reading

Mail that arrives as HTML is rendered, not flattened: a **Formatted** /
**Plain text** toggle sits above the body, and formatted is the default when a
message has an HTML part.

The HTML is rewritten before it is displayed. Scripts, styles, frames and forms
are dropped; attributes are cut down to structure and colour; and **remote
images are never fetched** — a remote image in mail is usually a tracking pixel,
so they are replaced by their alt text and counted in a "*n* remote images
blocked" note. Images the message actually carries (`cid:` parts) are extracted
to the cache and shown.

Formatted mail is drawn on a light card rather than the dark theme, because mail
HTML is written for a white background and picks its own text colours.

### Hyprland

Olook opens as a normal window, so it tiles and lives on a workspace like any
other app. Add a keybinding in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + M", "Mail", "omarchy-shell shell summon ttt.olook '{}'")
```

If you prefer it floating at a fixed size, add a rule to
`~/.config/hypr/looknfeel.lua`:

```lua
o.window({ title = "^(Olook)$" }, { float = true, size = "1440 900", center = true })
```

## The engine

The UI never speaks IMAP itself. `bin/olook` is a Python 3 program (standard
library only — no pip install) that does the network work and keeps a SQLite
cache, and the QML calls it for everything. That is why the panel paints
instantly: opening a folder is a local query, not a round trip.

```
Panel.qml / MailWindow.qml   QML surfaces (bar widget, window)
        │
   Service.qml               spawns the engine, parses its JSON
        │
   bin/olook  ──►  lib/olook/
                     providers.py   autodiscovery (built-ins, MX, ISPDB)
                     oauth.py       device-code + loopback PKCE, refresh
                     mailbox.py     IMAP: folders, sync, flags, moves
                     send.py        MIME + SMTP, replies and forwards
                     markdown.py    Markdown → HTML for outgoing mail
                     htmlrich.py    incoming HTML → what the reading pane shows
                     store.py       SQLite cache of headers and bodies
                     keyring.py     secrets via secret-tool
```

Useful on its own:

```bash
olook discover you@company.com     # what would it connect to?
olook test                         # do IMAP and SMTP actually accept us?
olook sync                         # fetch new mail
olook list --unread                # what's unread
olook status                       # what the bar widget sees
olook watch                        # IMAP IDLE, prints events as mail lands
                                   # (the client runs one of these per account)
olook draft-save --account <id>    # store a JSON draft in Drafts, on stdin
olook draft-discard --account <id> --uid N
olook set <id> --name Work         # rename an account, edit its signature,
                                   # move it to another server, pause it
```

`olook set` is what the settings panel writes through, so anything you can
change in the UI you can also change from a script.

`olook demo` seeds two fake accounts so you can try the interface — including
the multi-account folder tree — before adding a real one; `olook demo --clear`
removes them.

## Where things live

| Path | What |
|---|---|
| `~/.config/olook/accounts.json` | Accounts and server settings (0600, no secrets) |
| `~/.local/state/olook/mail.db` | SQLite cache of headers and fetched bodies |
| `~/.cache/olook/attachments/` | Attachments you have opened |
| `~/.cache/olook/attachments/inline/` | Images a message carries, extracted so the reading pane can show them |
| system keyring | Passwords and OAuth refresh tokens (`secret-tool`, service `olook`) |

Secrets go to the Secret Service keyring. If no keyring is available, they fall
back to `~/.local/state/olook/secrets.json` with 0600 permissions.

## Troubleshooting

**Nothing happens when I click the bar icon** — `omarchy restart shell`, then
check `quickshell log -i "$(qs list --all | grep -oP 'Instance \K\w+' | head -1)" --tail 50`.

**I changed the QML and the window looks the same** — the window's QML is
compiled once per shell process. `omarchy restart shell`. See the note under
[Install](#install).

**A message looks blank or has `[logo]` where a picture should be** — remote
images are blocked on purpose. The count under the header tells you how many;
there is no "load images anyway" button yet.

**"IMAP rejected the OAuth token"** — the grant was revoked or the password
changed. `olook auth <account-id>` signs in again.

**A Microsoft work account fails at sign-in** — some tenants block the
device-code grant. Try `olook auth <id> --flow loopback`. If IMAP is disabled
tenant-wide, no client can connect until an admin enables it.

**Sync is slow the first time** — the initial pass fetches headers for the last
200 messages. Later syncs only fetch what is new.

## Licence

MIT.
