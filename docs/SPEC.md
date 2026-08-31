# Omarchy Social Poster プラグイン 仕様書

- Status: Draft v0.2(2026-08-31)
- Plugin ID: `io.github.polidog.social-poster`
- Repository: `polidog/omarchy-plugin-social-poster`
- v0.2 での変更: SNS 対応をプロバイダー機構として外部化し、利用者が独自 SNS を追加できる設計に変更

## 1. 概要

Bluesky・Misskey などの SNS に対して、Omarchy デスクトップから直接

1. **投稿する**(コンポーザーをオーバーレイで呼び出してポスト)
2. **メンションを確認する**(バーのウィジェットから一覧表示、新着はデスクトップ通知)

ための Omarchy シェルプラグイン。ブラウザを開かずに、Hyprland のキーバインド一発で投稿・確認できることを目指す。

本体(コア)は SNS を一切知らない。SNS ごとの実装は**プロバイダー**という独立した実行ファイルに分離し、利用者はスクリプトを 1 つ置くだけで任意の SNS を追加できる。Bluesky / Misskey は同じ契約に従う同梱プロバイダーとして提供する。

### ゴール

- テキスト投稿(複数アカウント対応、クロスポスト可)
- メンション・リプライの一覧表示と未読バッジ、新着のデスクトップ通知
- **プロバイダー契約(§4)による SNS の後付け追加**(コアの変更・再インストール不要)
- `omarchy plugin add <git-url>` でインストールできる標準的なプラグイン形態

### 非ゴール(v1 では対象外)

- 画像・動画添付(契約上は拡張余地を残す → §10)
- タイムライン全体の閲覧(「投稿」と「自分宛て」に絞る)
- いいね・リポスト・フォロー等の操作

## 2. Omarchy プラグイン基盤の前提

実装は Omarchy シェル(Quickshell / QML)のプラグイン機構に載せる。調査で確認した制約:

| 項目 | 内容 |
|------|------|
| 配置場所 | `~/.config/omarchy/plugins/io.github.polidog.social-poster/`(git 管理し `omarchy plugin add` で導入) |
| マニフェスト | `manifest.json`、`schemaVersion: 1`。`id` に `omarchy.*` は使用不可 |
| kinds | `bar-widget`(バーのピル+ポップアップ)、`overlay`(コンポーザー)、`service`(常駐ポーリング)を使う。kind ごとに `entryPoints.barWidget` / `.overlay` / `.service` が必須 |
| ネットワーク | QML に fetch は無いため外部プロセス実行(`Process`)経由。本プラグインではプロバイダー実行ファイルがこの層を担う |
| 設定/状態ファイル | `FileView` で読み書き・変更監視 |
| リロード | `~/.config/omarchy/plugins/` 以下の保存で自動リロード。失敗時は `omarchy-shell shell rescanPlugins` |
| 検証 | `omarchy plugin validate <folder>`。シンボリックリンク禁止、entryPoint は相対パスで実在必須 |
| 通知 | `omarchy-notification-send` を利用 |
| 外部からの呼び出し | `omarchy-shell shell summon io.github.polidog.social-poster '<jsonPayload>'` でオーバーレイを召喚できる(キーバインドから投稿画面を開く用途) |

QML から任意のユーザー JS を動的ロードするのは Quickshell 上で安全に行いにくい。そこで拡張点は QML/JS ではなく**実行ファイル + JSON over stdio** に置く。これなら言語自由・プロセス分離・ホットリロード不要(呼び出しごとに最新が使われる)という利点もある。

## 3. コンポーネント構成

```
io.github.polidog.social-poster/
├── manifest.json
├── README.md
├── docs/
│   └── PROVIDER.md        # プロバイダー契約の公開ドキュメント(利用者向け)
├── providers/             # 同梱プロバイダー(契約 §4 に従う実行ファイル)
│   ├── bluesky            # bash + curl + jq
│   └── misskey            # bash + curl + jq
├── shared/
│   ├── Accounts.js        # accounts.json の読み込み・検証
│   ├── Providers.js       # プロバイダー解決(探索順・キャッシュ)と呼び出しヘルパ
│   └── Store.js           # 既読状態・プロバイダー状態の永続化ヘルパ
├── service/
│   └── Service.qml        # 常駐: メンションポーリング・通知・未読数の一元管理
├── bar/
│   ├── BarWidget.qml      # バーのアイコン+未読バッジ
│   └── MentionsPanel.qml  # クリックで開くメンション一覧ポップアップ
└── composer/
    └── Composer.qml       # 投稿用オーバーレイ
```

### manifest.json(案)

```json
{
  "schemaVersion": 1,
  "id": "io.github.polidog.social-poster",
  "name": "Social Poster",
  "version": "0.1.0",
  "author": "polidog",
  "description": "Post to social networks and watch mentions from the bar",
  "kinds": ["service", "bar-widget", "overlay"],
  "entryPoints": {
    "service": "service/Service.qml",
    "barWidget": "bar/BarWidget.qml",
    "overlay": "composer/Composer.qml"
  },
  "barWidget": {
    "displayName": "Social",
    "description": "SNS mentions and quick post",
    "category": "Social",
    "allowMultiple": false,
    "defaultSection": "right"
  }
}
```

### 責務分担

- **Service**(常駐): 唯一の「データオーナー」。各アカウントのメンションを `Timer` で定期取得し、未読数・最新一覧を保持。新着があれば `omarchy-notification-send` を実行。BarWidget / Panel はここから読むだけにして、プロバイダー呼び出し箇所を一本化する。
- **BarWidget**: アイコン + 未読件数バッジ。左クリックで MentionsPanel をトグル、中クリックで手動リフレッシュ、右クリックでコンポーザー召喚。
- **MentionsPanel**: サービス保持のメンション一覧を表示。項目クリックでブラウザの該当ポストを開く(`xdg-open`)。「返信」ボタンで返信先コンテキスト付きコンポーザーを開く。既読化・削除はヘッダー/行の明示操作のみで、開閉では既読にしない。
- **Composer**(overlay): テキスト入力・投稿先アカウント選択(複数チェックでクロスポスト)・残り文字数表示・送信。`shell summon` の payload で `{"replyTo": {...}}` を受け取ると返信モードになる。

## 4. プロバイダー機構(本仕様の中核)

### 4.1 設計方針

- プロバイダーは **1 SNS = 1 実行ファイル**。言語は問わない(同梱は bash + curl + jq、利用者は Python でも Go でも可)
- コアとの通信は **サブコマンド + JSON over stdin/stdout**。秘密情報は必ず stdin 経由で渡す(argv・環境変数には載せない。argv は `ps` で他プロセスから見える)
- プロバイダーは**ステートレス**。セッションキャッシュ等が必要なら `state` として JSON を返し、コアが永続化して次回呼び出し時にそのまま渡す(プロバイダー自身にファイル管理をさせない)

### 4.2 探索と解決

`accounts.json` の各アカウントが持つ `provider` 名を、以下の順で実行ファイルに解決する(先勝ち。ユーザーが同梱実装を差し替えることも可能):

1. `~/.config/omarchy/social-poster/providers/<name>`(利用者追加・上書き用)
2. `<プラグインディレクトリ>/providers/<name>`(同梱)

実行権限のないファイル・見つからない名前は該当アカウントを設定エラー扱いにする(§8)。

### 4.3 契約(Provider Contract v1)

呼び出し形式: `<provider> <subcommand>`、stdin に JSON リクエスト、stdout に JSON レスポンス、stderr は診断ログ(コアがデバッグ用に保持。ユーザーには出さない)。タイムアウトはコア側で 30 秒。

すべてのリクエストに共通で入るもの:

```json
{
  "contractVersion": 1,
  "account": { ...accounts.json の該当エントリがそのまま入る... },
  "state": { ...前回プロバイダーが返した state。初回は {}... }
}
```

すべてのレスポンスに共通:

```json
{
  "ok": true,
  "state": { ...次回渡してほしい state(省略時は前回値を維持)... },
  "error": { "code": "auth|network|invalid|other", "message": "人間向け説明" }
}
```

`ok: false` のとき `error` 必須。`error.code: "auth"` はコアが「再設定が必要」通知+アカウント一時停止のトリガーに使う(§8)。

#### サブコマンド一覧

| サブコマンド | 追加リクエストフィールド | 追加レスポンスフィールド | 必須 |
|---|---|---|---|
| `info` | なし | `name`, `maxChars`(null 可), `capabilities: ["post", "mentions", "markRead"]` | ✔ |
| `verify` | なし | なし(認証確認のみ。`ok` で判定) | ✔ |
| `post` | `text`, `replyTo`(null 可、§4.4) | `url`(投稿の permalink、null 可) | ✔ |
| `mentions` | `cursor`(前回レスポンスの値、初回 null) | `mentions: [...]`(§4.4), `cursor` | ✔ |
| `markRead` | `until`(ISO 8601 時刻) | なし | 任意 |

- `info` は起動時とアカウント設定変更時に呼び、文字数上限・対応機能をコアが把握する。`capabilities` に無い操作は UI から隠す(投稿専用プロバイダー、閲覧専用プロバイダーも作れる)
- `maxChars` はアカウント設定依存(Misskey のインスタンス上限など)の場合があるため `info` の応答とした
- `markRead` 非対応プロバイダーは、コアがローカル既読(state.json の最終閲覧時刻)のみで処理する

#### 4.4 共通データ型

**Mention**(`mentions` の要素):

```json
{
  "id": "プロバイダー内で一意な文字列",
  "author": { "handle": "@polidog", "displayName": "polidog", "avatarUrl": null },
  "text": "本文(プレーンテキスト)",
  "createdAt": "2026-08-31T12:34:56Z",
  "url": "ブラウザで開く permalink",
  "replyContext": { ...そのまま post の replyTo に渡せる不透明オブジェクト... }
}
```

`replyContext` は**コアが中身を解釈しない不透明値**。返信時に `post` の `replyTo` へそのまま渡す(Bluesky なら `{uri, cid, rootUri, rootCid}`、Misskey なら `{noteId}` が入るが、コアは知らなくてよい)。この不透明化により、返信の仕組みが SNS ごとに違ってもコアは変更不要。

#### 4.5 プロバイダー自作の例(利用者向けドキュメントに載せる最小形)

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

契約の詳細は `docs/PROVIDER.md` として公開し、リポジトリに契約準拠を確認する簡易テストスクリプト(`tools/provider-check <path>`)を同梱する。

### 4.6 同梱プロバイダー

#### bluesky(AT Protocol)

- 認証: App Password。`com.atproto.server.createSession` → `accessJwt`/`refreshJwt` を `state` に保存。失効時は `refreshSession` → 再ログインの順で回復
- `post`: `com.atproto.repo.createRecord`(`app.bsky.feed.post`)。`maxChars: 300`。`replyTo` の `replyContext` から `reply.root/parent` を構築。v1 はプレーンテキストのみ(facet 解決なし)
- `mentions`: `app.bsky.notification.listNotifications` を `reason in (mention, reply)` でフィルタ
- `markRead`: `app.bsky.notification.updateSeen`
- アカウント設定: `service`(既定 `https://bsky.social`), `identifier`, `appPassword`

#### misskey

- 認証: Web UI で発行した API トークン(必要権限: `write:notes`, `read:notifications`, `write:notifications`)
- `post`: `POST /api/notes/create`(`text`, `replyId`, `visibility`)。`maxChars` はインスタンスの `/api/meta` から取得して返す(取得失敗時 3000)
- `mentions`: `POST /api/i/notifications`(`includeTypes: ["mention", "reply"]`)
- `markRead`: `POST /api/notifications/mark-all-as-read`(個別既読は将来課題)
- アカウント設定: `host`, `token`, `visibility`(既定 `public`)

## 5. アカウント設定と認証情報

### 5.1 設定ファイル

`~/.config/omarchy/social-poster/accounts.json`(**プラグインディレクトリの外**。プラグイン更新・再インストールで消えない場所に置く):

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
      "id": "misskey-io",
      "provider": "misskey",
      "host": "https://misskey.io",
      "token": "XXXXXXXX",
      "visibility": "public",
      "enabled": true
    },
    {
      "id": "misskey-sub",
      "provider": "misskey",
      "host": "https://misskey.io",
      "token": "ZZZZZZZZ",
      "enabled": true
    },
    {
      "provider": "example",
      "token": "YYYYYYYY",
      "enabled": true
    }
  ],
  "defaultPostTargets": ["bluesky"],
  "pollIntervalSeconds": 120,
  "notifications": true
}
```

- コアが解釈するのは `id` / `provider` / `enabled` のみ。**残りのフィールドはプロバイダー固有**で、そのまま `account` としてプロバイダーに渡る(プロバイダー追加時に accounts.json のスキーマ変更が不要)
- `id` は**省略可**。省略時は `provider` 名がそのまま id になる(1 SNS 1 アカウントという通常のケースでは書かなくてよい)。同じ `provider` のアカウントを複数持つときだけ、両方に id を付けて区別する。省略のまま衝突した 2 つ目は設定エラーとして扱い、一覧に警告を出す
- id はアカウントの安定キー(state.json のキー、`defaultPostTargets` の参照先)なので、後から id を付け替えると既読・削除済みの記録はリセットされる。省略していたアカウントに後から id を付けるときは `provider` と同じ値にすれば引き継がれる
- コアは UI とファイル書き戻しの内部フラグに `__` 始まりのキー(`__implicitId` など)を使う。これはプロバイダーにも accounts.json にも出さない。ユーザー・プロバイダーは `__` 始まりのフィールド名を使わないこと
- ファイルは **パーミッション 600 必須**。サービス起動時に検査し、緩い場合は警告通知を出して読み込みを拒否する
- 秘密の直書きを避けたい利用者向けに、任意のフィールドで `{"$command": "secret-tool lookup service bsky"}` 形式を許容する。コアが実行して stdout の値に展開してからプロバイダーへ渡す(展開はメモリ上のみ)

### 5.2 状態ファイル

`~/.config/omarchy/social-poster/state.json`(コアが管理、ユーザー編集不要、600):

- アカウントごとのプロバイダー `state`(Bluesky のセッション等)
- アカウントごとの `cursor`、最終既読時刻、最後に通知したメンション ID(重複通知防止)
- アカウントごとの、利用者が明示的に消したメンション ID(`dismissedIds`、最大 200 件。再ポーリングで同じメンションが返っても一覧に復活させない)

## 6. 機能仕様

### 6.1 投稿フロー

1. キーバインド(例: `SUPER+SHIFT+P`)→ `omarchy-shell shell summon io.github.polidog.social-poster` でコンポーザーが開く
2. 投稿先アカウントをチェックボックスで選択(初期値は `defaultPostTargets`。`capabilities` に `post` の無いアカウントは非表示)
3. テキスト入力。選択中アカウントの `maxChars` の最小値に対する残数を表示
4. `Ctrl+Enter` で送信、`Esc` でキャンセル
5. 送信結果はアカウントごとに判定し、全成功なら閉じて成功通知、一部失敗なら失敗分を明示してコンポーザーを開いたまま(本文保持)

オーバーレイは**ノンモーダル**とする。レイヤーサーフェス自体は全画面だが、入力領域(`mask`)をカードの矩形だけに絞り、キーボードフォーカスはマップ直後の短い `Exclusive` プライムの後 `OnDemand` へ落とす。これによりオーバーレイを開いたまま背後のウィンドウ操作と Hyprland のキーバインドが使える(設定画面でトークンを他アプリからコピーしてくる用途)。代わりに全画面スクリムと「外側クリックで閉じる」は持たず、閉じる操作は `Esc` / ヘッダーの 󰅖 / 投稿成功時のみ。

キーバインドは README で案内する(`~/.config/hypr/bindings.lua` にユーザー自身が追加):

```lua
o.bind("SUPER SHIFT, P", "exec", "omarchy-shell shell summon io.github.polidog.social-poster")
```

### 6.2 メンション表示

- BarWidget: 未読 0 件ならアイコンのみ、1 件以上でバッジ(既存ウィジェットのスタイルに合わせる)
- MentionsPanel: 全アカウント統合の時系列一覧(新しい順、最大 50 件)。各行に「プロバイダー名 / 投稿者 / 本文抜粋 / 相対時刻」
- 行クリック → `xdg-open` で `url` を開く
- 行の返信ボタン → `replyContext` 付きでコンポーザー召喚
- **既読化・削除は明示操作のみ**。パネルを開いた/閉じただけでは既読にならない
  - 行の 󰅖 → そのメンションのみ一覧から消す(ID を `dismissedIds` に記録、プロバイダー呼び出しなし)
  - ヘッダーの 󰄬「すべて既読にする」 → `markRead`(対応プロバイダーのみ)+ローカル state 更新。行は残り、未読マークとバッジだけ消える
  - ヘッダーの 󰆴「一覧をすべて消す」 → 表示中の全メンションを `dismissedIds` に記録して一覧から除去し、併せて「すべて既読」と同じ既読処理を行う

### 6.3 通知

- ポーリング間隔: `pollIntervalSeconds`(既定 120 秒、最小 60 秒にクランプ)。アカウントごとに逐次実行(プロバイダープロセスの同時多発を避ける)
- 新着メンション 1 件: 「@user (Bluesky): 本文抜粋」を `omarchy-notification-send`
- 同時複数件: 「新着メンション N 件」に集約
- `notifications: false` で通知のみ無効化(バッジは維持)

## 7. セキュリティ・プライバシー

- トークン類を **argv・環境変数・ログ・エラー通知に一切出さない**。プロバイダーへは stdin の JSON で渡す(同梱プロバイダー内でも curl へは stdin/`-H @-` 経由)
- `accounts.json` / `state.json` は 600 で作成・検査
- プロバイダーは利用者が自分で配置した実行ファイルのみ(コアが勝手にダウンロードしない)。**プロバイダーを置くこと = そのコードにトークンを渡すこと**である旨を PROVIDER.md に明記
- 同梱プロバイダーは `--proto '=https'` で https を強制
- stderr の診断ログはメモリ内リングバッファのみ(ファイルに書かない)

## 8. エラーハンドリング方針

| 状況 | 挙動 |
|------|------|
| ネットワーク不通(`error.code: network`) | バーアイコンを淡色化+ツールチップにエラー。指数バックオフ(30s→60s→120s、上限 5 分)後に自動復帰。通知は出さない |
| 認証エラー(`error.code: auth`) | 「再設定が必要」を 1 回だけ通知し、該当アカウントを一時停止(accounts.json 変更で自動再開) |
| 投稿失敗 | コンポーザー内にアカウント別エラー表示、本文は保持 |
| accounts.json 不正 / プロバイダー未発見・実行権限なし | 該当エントリのみスキップし、パネルに設定エラーを表示 |
| プロバイダーの不正応答(JSON でない・タイムアウト) | `other` エラー扱い。連続 3 回でそのアカウントを次回設定変更まで一時停止 |

## 9. マイルストーン

1. **M1 – 骨組み**: manifest + 空の 3 エントリポイント、`omarchy plugin validate` 通過、バーにアイコンが出る
2. **M2 – プロバイダー基盤**: 契約 v1 の確定、`Providers.js`(解決・呼び出し・state 永続化)、`tools/provider-check`、PROVIDER.md
3. **M3 – Bluesky プロバイダー + 投稿**: accounts.json 読み込み、コンポーザーからテキスト投稿
4. **M4 – メンション**: サービスのポーリング、パネル一覧、通知、既読同期
5. **M5 – Misskey プロバイダー**: 契約が 2 実装目に耐えるかの検証(契約の穴はここで塞ぐ)
6. **M6 – 磨き込み**: 返信フロー、クロスポスト、バックオフ、エラー UI、README / PROVIDER.md 整備

## 10. 将来拡張

- 契約 v2 候補: 画像添付(`post` に `attachments`、`info.capabilities` に `attachments`)、個別既読(`markRead` に `ids`)、リッチテキスト
- Mastodon 等の公式プロバイダー追加(契約に従うだけなので別リポジトリ配布も可)
- コミュニティプロバイダーの一覧ページ(README にリンク集)
- キーリング統合の標準化(`$command` の推奨レシピ集)
- 設定 UI(Omarchy の settingsForm 機構が第三者プラグインに開放されたら追従)

## 11. 未決事項(実装前に判断)

- [ ] コンポーザーの kind を `overlay` にするか `panel` にするか(既存 `omarchy.emojis` / `omarchy.clipboard` は overlay。summon 契約の詳細は M1 で実機確認)
- [ ] `mentions` のページング粒度(`cursor` の意味論をプロバイダー任せにするか、`sinceId` を標準化するか)
- [ ] プロバイダー呼び出しの並列度(v1 は逐次で開始し、アカウント数が多い場合の体感を見て判断)
- [ ] Misskey のカスタム絵文字の描画範囲(v1 ではショートコードのまま表示)
