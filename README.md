# Olook

A mail client for [Omarchy](https://omarchy.org/), built as a plugin for the
Omarchy shell — so it is QML running inside the same Quickshell process as the
bar, themed by whatever Omarchy theme you are using.

It is laid out like Outlook on Windows: an app rail, a folder pane, a message
list grouped by date, and a reading pane.

```
┌──────────────────────────────────────────────────────────────────────────┐
│ ✉ Olook  Mail          [ Search mail ]                        ⟳    ✕     │
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
- Bar widget with an unread badge and the newest mail across every account
- Read, reply, reply-all, forward, archive, delete, flag, mark read/unread
- Compose and send, with a copy filed in Sent
- Attachments: saved to disk and opened with your default app
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
and asks the shell to rescan, and the running shell picks them up immediately.
There is a `--link` mode that symlinks the checkout instead, but the shell's
watcher does not see edits through the symlink, so that mode needs an
`omarchy restart shell` after every change.

## Add an account

```bash
olook setup
```

It asks for your address, works out the servers, signs you in, tests the
connection, and pulls your inbox. What that looks like per provider:

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

## Using it

Click the envelope in the bar for the panel, or open the full window from the
panel's **Open Mail** button. From a terminal or a keybinding:

```bash
omarchy-shell shell summon ttt.olook '{}'                # open
omarchy-shell shell summon ttt.olook '{"compose":true}'  # open composing
omarchy-shell ttt.olook toggle                           # bar panel
omarchy-shell ttt.olook sync                             # check for mail
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
| `Ctrl+Enter` | Send (while composing) |
| `Esc` | Discard compose → clear search → close |

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
```

`olook demo` seeds two fake accounts so you can try the interface — including
the multi-account folder tree — before adding a real one; `olook demo --clear`
removes them.

## Where things live

| Path | What |
|---|---|
| `~/.config/olook/accounts.json` | Accounts and server settings (0600, no secrets) |
| `~/.local/state/olook/mail.db` | SQLite cache of headers and fetched bodies |
| `~/.cache/olook/attachments/` | Attachments you have opened |
| system keyring | Passwords and OAuth refresh tokens (`secret-tool`, service `olook`) |

Secrets go to the Secret Service keyring. If no keyring is available, they fall
back to `~/.local/state/olook/secrets.json` with 0600 permissions.

## Troubleshooting

**Nothing happens when I click the bar icon** — `omarchy restart shell`, then
check `quickshell log -i "$(qs list --all | grep -oP 'Instance \K\w+' | head -1)" --tail 50`.

**"IMAP rejected the OAuth token"** — the grant was revoked or the password
changed. `olook auth <account-id>` signs in again.

**A Microsoft work account fails at sign-in** — some tenants block the
device-code grant. Try `olook auth <id> --flow loopback`. If IMAP is disabled
tenant-wide, no client can connect until an admin enables it.

**Sync is slow the first time** — the initial pass fetches headers for the last
200 messages. Later syncs only fetch what is new.

## Licence

MIT.
