# プロバイダー契約 v1(Provider Contract v1)

Social Poster プラグインのコアは SNS を一切知りません。SNS ごとの実装は
**プロバイダー**という独立した実行ファイルに分離されていて、スクリプトを
1 つ置くだけで任意の SNS を追加できます。

> ⚠️ **プロバイダーを置くこと = そのコードにアカウントのトークンを渡すこと**です。
> 自分で書いたか、中身を読んで信頼できると判断したものだけを配置してください。
> コアがプロバイダーを勝手にダウンロードすることはありません。

## 配置場所と探索順

`accounts.json` の各アカウントが持つ `provider` 名を、次の順で実行ファイルに
解決します(先勝ち。同名を置けば同梱実装を差し替えられます):

1. `~/.config/omarchy/social-poster/providers/<name>`(利用者追加・上書き用)
2. `<プラグインディレクトリ>/providers/<name>`(同梱: bluesky / misskey / mastodon)

実行権限(`chmod +x`)がない・見つからない場合、そのアカウントは設定エラーに
なりパネルに表示されます。

## 呼び出し形式

```
<provider> <subcommand>
```

- **stdin**: JSON リクエスト(秘密情報は必ずここで渡される。argv・環境変数には載らない)
- **stdout**: JSON レスポンス(1 オブジェクト)
- **stderr**: 診断ログ。コアがメモリ内リングバッファに保持する(ファイルには書かれない)
- タイムアウト: コア側で 30 秒。超えるとエラー扱い

言語は自由です(同梱は bash + curl + jq)。プロバイダーは**ステートレス**に
書きます。セッションキャッシュ等が必要なら `state` として JSON を返せば、
コアが永続化して次回呼び出し時にそのまま渡します。

## リクエスト(全サブコマンド共通)

```json
{
  "contractVersion": 1,
  "account": { "...accounts.json の該当エントリがそのまま入る..." },
  "state": { "...前回プロバイダーが返した state。初回は {}..." }
}
```

`account` のうちコアが解釈するのは `id` / `provider` / `enabled` のみ。
残りのフィールド(ホスト名・トークンなど)はプロバイダー固有です。

## レスポンス(全サブコマンド共通)

```json
{
  "ok": true,
  "state": { "...次回渡してほしい state(省略時は前回値を維持)..." },
  "error": { "code": "auth|network|invalid|other", "message": "人間向け説明" }
}
```

- `ok: false` のとき `error` は必須
- `error.code: "auth"` はコアが「再設定が必要」通知とアカウント一時停止に使う
- `error.code: "network"` は指数バックオフによる自動リトライになる(通知なし)

## サブコマンド一覧

| サブコマンド | 追加リクエストフィールド | 追加レスポンスフィールド | 必須 |
|---|---|---|---|
| `info` | なし | `name`, `maxChars`(null 可), `capabilities: ["post", "mentions", "markRead"]` | ✔ |
| `verify` | なし | なし(認証確認のみ。`ok` で判定) | ✔ |
| `post` | `text`, `replyTo`(null 可) | `url`(投稿の permalink、null 可) | ✔ |
| `mentions` | `cursor`(前回レスポンスの値、初回 null) | `mentions: [...]`, `cursor` | ✔ |
| `markRead` | `until`(ISO 8601 時刻) | なし | 任意 |

- `info` は起動時とアカウント設定変更時に呼ばれ、文字数上限・対応機能をコアが
  把握します。`capabilities` に無い操作は UI から隠されます(投稿専用・閲覧専用の
  プロバイダーも作れます)
- `maxChars` がアカウント設定依存(Misskey のインスタンス上限など)の場合は
  `info` の応答で動的に返してください
- `markRead` 非対応の場合、コアはローカル既読(最終閲覧時刻)のみで処理します
- `cursor` の意味論はプロバイダー任せです。使わないなら `null` を返して
  かまいません(コアはメンション ID で重複を排除します)

## Mention 型(`mentions` の要素)

```json
{
  "id": "プロバイダー内で一意な文字列",
  "author": { "handle": "@polidog", "displayName": "polidog", "avatarUrl": null },
  "text": "本文(プレーンテキスト)",
  "createdAt": "2026-08-31T12:34:56Z",
  "url": "ブラウザで開く permalink",
  "replyContext": { "...そのまま post の replyTo に渡せる不透明オブジェクト..." }
}
```

`replyContext` は**コアが中身を解釈しない不透明値**です。ユーザーが返信すると
`post` の `replyTo` にそのまま渡ってきます(Bluesky なら `{uri, cid, rootUri,
rootCid}`、Misskey なら `{noteId}` ですが、コアは知りません)。返信の仕組みが
SNS ごとに違ってもコアの変更は不要です。

## セキュリティ上の約束事

- トークン類を **argv・環境変数・ログに出さない**こと。外部コマンド(curl 等)に
  渡すときも stdin 経由(`-H @-` や `--data @-`)を使う
- 通信は https を強制する(curl なら `--proto '=https'`)
- 一時ファイルに秘密を書かない

## 最小のプロバイダー例

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

対応する accounts.json のエントリ:

```json
{ "id": "my-sns", "provider": "example", "token": "YYYYYYYY", "enabled": true }
```

## 契約準拠の確認

同梱のチェックスクリプトで最低限の準拠を確認できます:

```bash
tools/provider-check ~/.config/omarchy/social-poster/providers/example

# 実アカウントで verify / mentions まで確認する場合
# (account.json には accounts.json の 1 エントリ分を入れる。post は実行されない)
tools/provider-check ./providers/bluesky --account /tmp/account.json
```
