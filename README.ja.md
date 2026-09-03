# Omarchy Social Poster

*[English README](README.md)*

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

## 手元の作業ツリーで動かす

インストール済みのコピーではなく、自分の作業ツリーを動かす場合:

```bash
tools/install-local             # ~/.config/omarchy/plugins/ へ同期
tools/install-local --restart   # 同期してシェルも再起動
```

Omarchy はプラグインフォルダ内のシンボリックリンクを許さないため、リンクでは
なくコピーします。たいていの変更はシェルが自分で拾いますが、ホットリロードは
取りこぼすことがあるので、UI が更新されないときは `--restart` を付けてください。

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

#### アカウント ID は省略できます

`id` はアカウントを指す名前(`defaultPostTargets` や state の保存キー)ですが、
**省略すると `provider` 名がそのまま ID になります**。1 つの SNS に 1 アカウント
なら書く必要はありません。

同じ provider のアカウントを複数持つときだけ、両方に `id` を付けて区別します
(片方を `"id": "misskey"` にしておけば、そのアカウントの既読状態は引き継がれます):

```json
{
  "accounts": [
    { "id": "misskey", "provider": "misskey", "host": "https://misskey.io", "token": "XXXX" },
    { "id": "misskey-sub", "provider": "misskey", "host": "https://misskey.io", "token": "YYYY" }
  ],
  "defaultPostTargets": ["misskey"]
}
```

`id` を省いたまま同じ provider を 2 つ書くと ID が衝突するため、2 つ目は設定
エラーとしてパネルに表示されます。

### 秘密を直書きしたくない場合

任意のフィールドに `{"$command": "..."}` を書くと、コアがコマンドを実行して
stdout の値に展開してからプロバイダーへ渡します(展開はメモリ上のみ):

```json
{ "appPassword": { "$command": "secret-tool lookup service bsky" } }
```

## 使い方

| 操作 | 動作 |
|------|------|
| バーのアイコンを左クリック | メンション一覧をトグル |
| 中クリック | 手動リフレッシュ |
| 右クリック | 投稿コンポーザーを開く |
| 一覧の行をクリック | ブラウザで該当ポストを開く |
| 行の「返信」 | 返信コンテキスト付きでコンポーザーを開く |
| 行の 󰅖 | そのメンションを一覧から消す |
| パネルの 󰄬 | すべて既読にする(行は残り、バッジだけ消える) |
| パネルの 󰆴 | 一覧をすべて消す(併せて既読化) |
| パネル・コンポーザーの 󰒓 | セットアップ画面(アカウント管理)を開く |
| パネル・セットアップ画面の 󰤌 | 新規投稿を書き始める |
| コンポーザーの 󰌌 | キーボードを他のウィンドウへ譲る(`Ctrl+Esc`) |

一覧は**開いただけでは既読になりません**。未読バッジを消すのは 󰄬 / 󰆴 の明示操作
だけです。消したメンションは `state.json` に記録されるため、次のポーリングで同じ
メンションが返ってきても一覧には戻りません。

コンポーザーでは投稿先アカウントをチェックボックスで選び(複数選択で
クロスポスト)、`Ctrl+Enter` で送信、`Esc` でキャンセルです。

コンポーザー・セットアップ画面は**ノンモーダル**です。クリックを受けるのはカードの
矩形だけなので、開いている間も外側は背後のウィンドウがそのまま操作できます。ただし
キーボードは開いている間だけ掴みます。Hyprland は `on_demand` のレイヤーサーフェスに
マップ時のキーボードフォーカスを与えないため、「開いた直後から打てる」オーバーレイは
掴むしかありません。

`Ctrl+Esc`(またはヘッダーの 󰌌)でキーボードを他のウィンドウへ譲れます。譲ると
Hyprland のキーバインドと背後のアプリへの入力が戻るので、トークンをブラウザや
パスワードマネージャーからコピーしてくる、といった行き来ができます。カードを
クリックすれば掴み直します。閉じるのは `Esc` かヘッダーの 󰅖 です。

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

### コンポーザーで日本語入力(fcitx5 / ibus)が効かない

コンポーザーで IME がおかしい — キーが消える、あるいは変換候補が一瞬だけ出て、その後
入力を受け付けなくなる — 場合、原因はこのプラグインではなく `QT_IM_MODULE` です。
Omarchy は既定で `QT_IM_MODULE=fcitx` を設定しており
(`/usr/share/omarchy/default/environment.d/10-omarchy-fcitx.conf`)、これにより Qt は
Wayland の `text-input-v3` ではなく fcitx の D-Bus インプットコンテキストを使います。
この経路では Quickshell のレイヤーサーフェスにまともなインプットコンテキストが付かない
ため、このプラグインに限らず Quickshell のオーバーレイ全体が影響を受けます。

ユーザー側で上書きして再ログインしてください:

```bash
printf 'QT_IM_MODULE=wayland\n' > ~/.config/environment.d/95-qt-im-wayland.conf
```

値は空ではなく `wayland` です。systemd の environment.d ジェネレーターは空代入
(`QT_IM_MODULE=`、`""` や `''` も同様)を `invalid syntax` として捨てるので、空値では
Omarchy の `fcitx` が残ったままになり上書きが効きません。qtwayland は `wayland` を
特別扱いして Wayland のインプットコンテキストを組み立てます — 未設定のときと同じ経路で、
fcitx5 も ibus もこれを話せます。再ログイン後に確認できます:

```bash
systemctl --user show-environment | grep QT_IM_MODULE   # QT_IM_MODULE=wayland
```

元に戻すにはこのファイルを削除して再ログインします。

## ライセンス

MIT
