# Omarchy Social Poster

Bluesky・Misskey・Mastodon などの SNS に、[Omarchy](https://omarchy.org/) デスクトップから
ブラウザを開かずに **投稿**し、**メンションをバーで確認**するシェルプラグインです。

- テキスト投稿(複数アカウント対応、クロスポスト可、返信対応)
- メンション・リプライの一覧表示と未読バッジ、新着のデスクトップ通知
- SNS ごとの実装は**プロバイダー**(実行ファイル + JSON over stdio)に分離。
  スクリプトを 1 つ置くだけで任意の SNS を後付けできます
  → [docs/PROVIDER.md](docs/PROVIDER.md)

## 必要なもの

- Omarchy(シェルプラグイン機構のあるバージョン)
- `curl` と `jq`(同梱プロバイダーが使用)

## インストール

```bash
omarchy plugin add https://github.com/polidog/omarchy-plugin-social-poster
```

有効化してバーの右セクションにウィジェットを追加します:

```bash
omarchy plugin enable io.github.polidog.social-poster --section right
```

## アンインストール

```bash
# バーから外して無効化
omarchy plugin disable io.github.polidog.social-poster

# プラグイン本体を削除
omarchy plugin remove io.github.polidog.social-poster
```

アカウント設定はプラグインを消しても残ります。認証情報ごと消すには手動で
削除してください:

```bash
rm -rf ~/.config/omarchy/social-poster
```

## 更新

```bash
omarchy plugin update io.github.polidog.social-poster
```

## アカウント設定

### セットアップ UI(推奨)

バーのアイコンを右クリック(またはクリック → 「セットアップを開く」)すると
セットアップ画面が開きます。アカウント未設定のときは投稿画面の代わりに自動で
表示されます。プロバイダーを選んで ID・認証情報を入力し、「接続テスト」で
確認してから「保存」してください。既存アカウントの有効/無効・デフォルト
投稿先・削除も同じ画面で管理できます。

設定は `~/.config/omarchy/social-poster/accounts.json` にパーミッション 600 で
保存されます。

同梱プロバイダー:

- **bluesky**: `appPassword` には App Password(設定 → アプリパスワード)を使います
- **misskey**: `token` は Web UI で発行した API トークン。必要権限は
  `write:notes` / `read:notifications` / `write:notifications`。
  Misskey フォーク(Firefish / Sharkey など)でも動く見込みです
- **mastodon**: `token` は Web UI の「設定 → 開発 → 新規アプリ」で発行した
  アクセストークン。必要スコープは `read:accounts` / `read:notifications` /
  `write:statuses` / `write:accounts`(markers 更新用)。
  Mastodon API 互換サーバー(Pleroma / Akkoma / GoToSocial など)でも使えます

### 手動で編集する場合

`accounts.json` は直接編集してもかまいません(**600 必須**。緩いと読み込みを
拒否します。保存すると自動で再読み込みされます):

```json
{
  "accounts": [
    {
      "id": "bsky-main",
      "provider": "bluesky",
      "service": "https://bsky.social",
      "identifier": "polidog.bsky.social",
      "appPassword": "xxxx-xxxx-xxxx-xxxx",
      "enabled": true
    },
    {
      "id": "misskey-io",
      "provider": "misskey",
      "host": "https://misskey.io",
      "token": "XXXXXXXX",
      "visibility": "public",
      "enabled": true
    },
    {
      "id": "mstdn",
      "provider": "mastodon",
      "host": "https://mastodon.social",
      "token": "YYYYYYYY",
      "visibility": "public",
      "enabled": true
    }
  ],
  "defaultPostTargets": ["bsky-main"],
  "pollIntervalSeconds": 120,
  "notifications": true
}
```

### 秘密を直書きしたくない場合

任意のフィールドに `{"$command": "..."}` を書くと、コアがコマンドを実行して
stdout の値に展開してからプロバイダーへ渡します(展開はメモリ上のみ):

```json
{ "appPassword": { "$command": "secret-tool lookup service bsky" } }
```

## 使い方

| 操作 | 動作 |
|------|------|
| バーのアイコンを左クリック | メンション一覧をトグル(閉じると既読化) |
| 中クリック | 手動リフレッシュ |
| 右クリック | 投稿コンポーザーを開く |
| 一覧の行をクリック | ブラウザで該当ポストを開く |
| 行の「返信」 | 返信コンテキスト付きでコンポーザーを開く |
| パネル・コンポーザーの 󰒓 | セットアップ画面(アカウント管理)を開く |

コンポーザーでは投稿先アカウントをチェックボックスで選び(複数選択で
クロスポスト)、`Ctrl+Enter` で送信、`Esc` でキャンセルです。

### キーバインドで投稿画面を開く

`~/.config/hypr/bindings.lua` に追加します:

```lua
o.bind("SUPER SHIFT, P", "exec", "omarchy-shell shell summon io.github.polidog.social-poster")
```

## 独自 SNS の追加

`~/.config/omarchy/social-poster/providers/<name>` に契約
([docs/PROVIDER.md](docs/PROVIDER.md))に従う実行ファイルを置き、
accounts.json のエントリで `"provider": "<name>"` を指定するだけです。
コアの変更・再インストールは不要です。準拠確認には
`tools/provider-check` が使えます。

## セキュリティ

- トークン類は argv・環境変数・ログ・通知に出しません(プロバイダーへは stdin の JSON で渡します)
- `accounts.json` / `state.json` は 600 で作成・検査します
- 同梱プロバイダーは `--proto '=https'` で https を強制します
- プロバイダーの stderr 診断ログはメモリ内のみで、ファイルには書きません

## トラブルシューティング

```bash
# サービスの状態を確認
omarchy-shell social-poster status

# 手動リフレッシュ
omarchy-shell social-poster refresh
```

バーのアイコンに 󰀪 が出ているときは、ツールチップかメンション一覧の上部に
エラー内容が表示されます。認証エラーのアカウントは accounts.json を修正して
保存すると自動で再開します。

## ライセンス

MIT
