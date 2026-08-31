# Omarchy Social Poster

*[日本語版 README](README.ja.md)*

A shell plugin that lets you **post** to Bluesky, Misskey, Mastodon and other
social networks — and **watch your mentions from the bar** — straight from the
[Omarchy](https://omarchy.org/) desktop, without opening a browser.

- Text posts (multiple accounts, cross-posting, replies)
- A mention/reply list with an unread badge and desktop notifications for new items
- Each network lives in a **provider** (an executable speaking JSON over stdio).
  Drop in a single script and any network works — no core changes
  → [docs/PROVIDER.md](docs/PROVIDER.md)

## Requirements

- Omarchy (a version with the shell plugin system)
- `curl` and `jq` (used by the bundled providers)

## Install

```bash
omarchy plugin add https://github.com/polidog/omarchy-plugin-social-poster
```

Enable it and add the widget to the right section of the bar:

```bash
omarchy plugin enable io.github.polidog.social-poster --section right
```

## Uninstall

```bash
# Remove from the bar and disable
omarchy plugin disable io.github.polidog.social-poster

# Remove the plugin itself
omarchy plugin remove io.github.polidog.social-poster
```

Your account settings survive uninstalling the plugin. To delete them along
with the credentials, remove the directory yourself:

```bash
rm -rf ~/.config/omarchy/social-poster
```

## Update

```bash
omarchy plugin update io.github.polidog.social-poster
```

## Running a local checkout

To run your own working tree instead of the installed copy:

```bash
tools/install-local             # sync into ~/.config/omarchy/plugins/
tools/install-local --restart   # sync and restart the shell
```

Omarchy rejects symlinks inside a plugin folder, so this copies rather than
links. The shell picks most edits up on its own, but hot reload does miss
changes sometimes — pass `--restart` when the UI does not update.

## Configuring accounts

### Setup UI (recommended)

Right-click the bar icon (or click it and choose "Open setup") to open the
setup screen. It also opens automatically in place of the composer while no
account is configured. Pick a provider, fill in the ID and credentials, press
"Test connection", then "Save". Enabling/disabling accounts, choosing default
post targets and deleting accounts all happen on the same screen.

Settings are stored in `~/.config/omarchy/social-poster/accounts.json` with
permissions `600`.

Bundled providers:

- **bluesky**: `appPassword` takes an App Password (Settings → App Passwords)
- **misskey**: `token` is an API token issued from the web UI. Required
  permissions: `write:notes` / `read:notifications` / `write:notifications`.
  Misskey forks (Firefish, Sharkey, …) are expected to work too
- **mastodon**: `token` is an access token from the web UI
  (Preferences → Development → New application). Required scopes:
  `read:accounts` / `read:notifications` / `write:statuses` /
  `write:accounts` (for updating markers). Mastodon API-compatible servers
  (Pleroma, Akkoma, GoToSocial, …) work as well

### Editing the file by hand

You can edit `accounts.json` directly (**mode 600 is required** — anything
looser is refused; saving triggers an automatic reload):

```json
{
  "accounts": [
    {
      "provider": "bluesky",
      "service": "https://bsky.social",
      "identifier": "polidog.bsky.social",
      "appPassword": "xxxx-xxxx-xxxx-xxxx",
      "enabled": true
    },
    {
      "provider": "misskey",
      "host": "https://misskey.io",
      "token": "XXXXXXXX",
      "visibility": "public",
      "enabled": true
    },
    {
      "provider": "mastodon",
      "host": "https://mastodon.social",
      "token": "YYYYYYYY",
      "visibility": "public",
      "enabled": true
    }
  ],
  "defaultPostTargets": ["bluesky"],
  "pollIntervalSeconds": 120,
  "notifications": true
}
```

#### The account ID is optional

`id` is the name that refers to an account (in `defaultPostTargets` and as the
state storage key), but **if you omit it the `provider` name becomes the ID**.
With one account per network you never need to write it.

Only give accounts an explicit `id` when you have several on the same provider
(keep one of them as `"id": "misskey"` and that account's read state carries
over):

```json
{
  "accounts": [
    { "id": "misskey", "provider": "misskey", "host": "https://misskey.io", "token": "XXXX" },
    { "id": "misskey-sub", "provider": "misskey", "host": "https://misskey.io", "token": "YYYY" }
  ],
  "defaultPostTargets": ["misskey"]
}
```

Two accounts on the same provider with no `id` would collide, so the second one
is reported in the panel as a configuration error.

### Keeping secrets out of the file

Write `{"$command": "..."}` in place of any field and the core runs the command
and substitutes its stdout before handing the value to the provider (the
expansion only ever exists in memory):

```json
{ "appPassword": { "$command": "secret-tool lookup service bsky" } }
```

## Usage

| Action | Result |
|------|------|
| Left-click the bar icon | Toggle the mention list |
| Middle-click | Refresh manually |
| Right-click | Open the composer |
| Click a row in the list | Open that post in the browser |
| "Reply" on a row | Open the composer with the reply context attached |
| 󰅖 on a row | Drop that mention from the list |
| 󰄬 in the panel | Mark everything read (rows stay, only the badge clears) |
| 󰆴 in the panel | Clear the whole list (marks everything read too) |
| 󰒓 in the panel or composer | Open the setup screen (account management) |
| 󰤌 in the panel or the setup screen | Start a new post |
| 󰌌 in the composer | Hand the keyboard back to the other windows (`Ctrl+Esc`) |

Opening the list **does not** mark anything read. Only the explicit 󰄬 / 󰆴
actions clear the unread badge. Dismissed mentions are recorded in `state.json`,
so they will not come back even if the next poll returns them again.

In the composer, pick the target accounts with the checkboxes (select several to
cross-post), send with `Ctrl+Enter` and cancel with `Esc`.

The composer and the setup screen are **non-modal**: the window behind them
stays usable outside the card, since only the card rectangle accepts clicks.
The keyboard, however, is held while the overlay is open — Hyprland does not
hand keyboard focus to an `on_demand` layer surface at map time, so an overlay
that wants to be typable the moment it opens has to grab it.

Press `Ctrl+Esc` (or the 󰌌 in the header) to hand the keyboard back to the
other windows — Hyprland keybindings and the app behind the card become usable
again, so you can go fetch a token from a browser or password manager. Click
the card to take the keyboard back. Close with `Esc` or the 󰅖 in the header.

### Opening the composer with a keybinding

Add this to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER SHIFT, P", "exec", "omarchy-shell shell summon io.github.polidog.social-poster")
```

## Adding your own network

Put an executable that follows the contract
([docs/PROVIDER.md](docs/PROVIDER.md)) at
`~/.config/omarchy/social-poster/providers/<name>` and reference it from an
accounts.json entry with `"provider": "<name>"`. That is all — no core changes,
no reinstall. `tools/provider-check` verifies that a provider conforms.

## Security

- Tokens never appear in argv, environment variables, logs or notifications
  (they reach providers as JSON on stdin)
- `accounts.json` and `state.json` are created and checked with mode 600
- The bundled providers force https with `--proto '=https'`
- Provider stderr diagnostics stay in memory and are never written to disk

## Troubleshooting

```bash
# Check the service status
omarchy-shell social-poster status

# Refresh manually
omarchy-shell social-poster refresh
```

When 󰀪 shows up on the bar icon, the details are in the tooltip or at the top
of the mention list. An account that failed to authenticate resumes
automatically once you fix and save accounts.json.

### An input method (fcitx5 / ibus) does not reach the composer

If your IME is dead in the composer — keystrokes vanish, no preedit, no
candidate window — the cause is `QT_IM_MODULE`, not this plugin. Omarchy ships
`QT_IM_MODULE=fcitx` (`/usr/share/omarchy/default/environment.d/10-omarchy-fcitx.conf`),
which routes Qt through the fcitx D-Bus input context instead of the Wayland
`text-input-v3` protocol. Quickshell layer surfaces get no input context that
way, so every Quickshell overlay is affected, not just this one.

Override it for your user and log back in:

```bash
# environment.d cannot unset a variable, so override it with an empty value
printf 'QT_IM_MODULE=\n' > ~/.config/environment.d/95-qt-im-wayland.conf
```

Qt then falls back to `text-input-v3`, which fcitx5 and ibus both speak. Delete
the file and log back in to revert.

## License

MIT
