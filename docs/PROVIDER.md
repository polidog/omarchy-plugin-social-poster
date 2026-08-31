# Provider Contract v1

The Social Poster core knows nothing about any social network. Each network is
implemented in a **provider** — a standalone executable — so adding a network is
a matter of dropping in one script.

> ⚠️ **Installing a provider means handing your account tokens to that code.**
> Only install providers you wrote yourself, or whose source you have read and
> decided to trust. The core never downloads a provider on its own.

## Location and lookup order

The `provider` name on each account in `accounts.json` is resolved to an
executable in this order (first match wins, so dropping in a file with the same
name overrides a bundled implementation):

1. `~/.config/omarchy/social-poster/providers/<name>` (user-installed, overrides)
2. `<plugin directory>/providers/<name>` (bundled: bluesky / misskey / mastodon)

If the file is missing or not executable (`chmod +x`), that account becomes a
configuration error and is reported in the panel.

## Invocation

```
<provider> <subcommand>
```

- **stdin**: the JSON request (secrets always arrive here, never in argv or the environment)
- **stdout**: the JSON response (a single object)
- **stderr**: diagnostics; the core keeps them in an in-memory ring buffer (never written to disk)
- Timeout: 30 seconds, enforced by the core. Exceeding it is treated as an error

Any language will do (the bundled ones are bash + curl + jq). Write providers as
**stateless**. If you need something like a session cache, return it as `state`
JSON and the core will persist it and hand it back on the next call.

## Request (common to every subcommand)

```json
{
  "contractVersion": 1,
  "account": { "...the matching accounts.json entry, verbatim..." },
  "state": { "...the state your provider returned last time; {} on the first call..." }
}
```

Of `account`, the core only interprets `id` / `provider` / `enabled`. The
remaining fields (host names, tokens, …) are provider-specific.

`id` may be omitted in accounts.json, in which case the core fills in the
`provider` name as the id — providers always receive an `id` that is already
resolved. Keys starting with `__` are reserved for core internals and are never
included in the request.

## Response (common to every subcommand)

```json
{
  "ok": true,
  "state": { "...state to hand back next time (omit to keep the previous value)..." },
  "error": { "code": "auth|network|invalid|other", "message": "human-readable explanation" }
}
```

- `error` is required when `ok` is `false`
- `error.code: "auth"` makes the core notify the user that reconfiguration is
  needed and suspend the account
- `error.code: "network"` triggers an automatic retry with exponential backoff
  (no notification)

## Subcommands

| Subcommand | Extra request fields | Extra response fields | Required |
|---|---|---|---|
| `info` | none | `name`, `maxChars` (nullable), `capabilities: ["post", "mentions", "markRead"]` | ✔ |
| `verify` | none | none (authentication check only; judged by `ok`) | ✔ |
| `post` | `text`, `replyTo` (nullable) | `url` (permalink of the post, nullable) | ✔ |
| `mentions` | `cursor` (the value from your last response; null on the first call) | `mentions: [...]`, `cursor` | ✔ |
| `markRead` | `until` (ISO 8601 timestamp) | none | optional |

- `info` is called at startup and whenever account settings change, so the core
  learns the character limit and the supported features. Actions missing from
  `capabilities` are hidden in the UI (post-only and read-only providers are
  both fine)
- If `maxChars` depends on the account (an instance limit on Misskey, say),
  return it dynamically from `info`
- Without `markRead`, the core falls back to local read tracking (last viewed
  timestamp) only
- The semantics of `cursor` are entirely up to you. Return `null` if you do not
  need one — the core deduplicates mentions by ID

## The Mention type (elements of `mentions`)

```json
{
  "id": "a string unique within this provider",
  "author": { "handle": "@polidog", "displayName": "polidog", "avatarUrl": null },
  "text": "the body, as plain text",
  "createdAt": "2026-08-31T12:34:56Z",
  "url": "permalink to open in the browser",
  "replyContext": { "...an opaque object that can be passed straight to post's replyTo..." }
}
```

`replyContext` is an **opaque value the core never interprets**. When the user
replies, it comes back to `post` as `replyTo` exactly as you produced it (for
Bluesky it holds `{uri, cid, rootUri, rootCid}`, for Misskey `{noteId}` — the
core knows neither). Networks can thread replies however they like without any
core changes.

## Security obligations

- **Keep tokens out of argv, the environment and logs.** Pass them to external
  commands (curl and friends) over stdin too (`-H @-`, `--data @-`)
- Force https (`--proto '=https'` with curl)
- Never write secrets to temporary files

## A minimal provider

```bash
#!/usr/bin/env bash
# ~/.config/omarchy/social-poster/providers/example
set -euo pipefail
req=$(cat)
case "${1:?subcommand required}" in
  info)     echo '{"ok":true,"name":"Example","maxChars":500,"capabilities":["post"]}' ;;
  verify)   echo '{"ok":true}' ;;
  post)
    text=$(jq -r .text <<<"$req")
    token=$(jq -r .account.token <<<"$req")
    curl -fsS --proto '=https' -X POST https://example.social/api/post \
      -H @- -d "$(jq -n --arg t "$text" '{text:$t}')" <<<"Authorization: Bearer $token" \
      >/dev/null && echo '{"ok":true,"url":null}' \
      || echo '{"ok":false,"error":{"code":"network","message":"post failed"}}' ;;
  *)        echo '{"ok":false,"error":{"code":"invalid","message":"unsupported"}}' ;;
esac
```

The matching accounts.json entry:

```json
{ "provider": "example", "token": "YYYYYYYY", "enabled": true }
```

(Since `id` is omitted, this account's id is `example`.)

## Checking conformance

The bundled check script verifies the basics of the contract:

```bash
tools/provider-check ~/.config/omarchy/social-poster/providers/example

# To go as far as verify / mentions against a real account
# (account.json holds one accounts.json entry; post is never executed)
tools/provider-check ./providers/bluesky --account /tmp/account.json
```
