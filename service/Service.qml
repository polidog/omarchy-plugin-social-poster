import QtQuick
import Quickshell
import Quickshell.Io
import "../shared/Accounts.js" as Accounts
import "../shared/Providers.js" as Providers
import "../shared/Store.js" as Store

// 常駐サービス: 唯一の「データオーナー」(SPEC §3)。
// アカウント設定の読み込み、プロバイダー呼び出し(逐次ジョブキュー)、
// メンションのポーリング・通知・未読管理・state 永続化を一元管理する。
// BarWidget / MentionsPanel / Composer はここから読むだけ。
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string configDir: home + "/.config/omarchy/social-poster"
  readonly property string accountsPath: configDir + "/accounts.json"
  readonly property string statePath: configDir + "/state.json"
  readonly property string pluginDir: {
    var url = Qt.resolvedUrl("..").toString()
    return url.replace(/^file:\/\//, "").replace(/\/$/, "")
  }

  // ---- accounts.json 由来の設定 ----
  property var accounts: []
  property var configErrors: []       // [{accountId?, message}]
  property var defaultPostTargets: []
  property int pollIntervalSeconds: 120
  property bool notificationsEnabled: true
  property bool accountsReady: false
  property string accountsProblem: "" // accounts.json 自体の問題(欠落・パーミッション等)

  // ---- アカウントごとのランタイム状態(id キー) ----
  property var accountInfo: ({})      // id -> {name, maxChars, capabilities}
  property var accountStatus: ({})    // id -> {state: pending|ok|auth|network|config|paused, message}
  property var mentionsByAccount: ({})

  // ---- UI が読む集約値 ----
  property var mentions: []           // 統合一覧(新しい順、最大 50 件)
  property int unreadCount: 0
  property var postAccounts: []       // 投稿可能アカウント [{id, label, maxChars}]
  property bool refreshing: false
  property var diagLog: []            // stderr リングバッファ(メモリのみ、SPEC §7)

  // ---- 内部状態 ----
  property var persist: Store.emptyState()
  property bool persistLoaded: false
  property var _schedule: ({})        // id -> {nextAt, netFailures, otherFailures, authNotified}
  property var _secretCache: ({})     // $command 文字列 -> 展開値(メモリのみ)
  property bool _permWarned: false
  property int _pendingPolls: 0

  signal mentionsUpdated()

  // ======================================================== ジョブキュー
  // プロバイダー呼び出しは逐次実行(SPEC §6.3)。秘密は stdin 経由で渡す。

  property var _jobs: []
  property var _job: null

  function enqueueJob(argv, stdinText, timeoutMs, cb) {
    _jobs.push({ argv: argv, stdinText: stdinText, timeoutMs: timeoutMs || Providers.TIMEOUT_MS, cb: cb, timedOut: false })
    _pumpJobs()
  }

  function _pumpJobs() {
    if (_job || _jobs.length === 0) return
    _job = _jobs.shift()
    proc.command = _job.argv
    proc.stdinEnabled = _job.stdinText !== null && _job.stdinText !== undefined
    jobTimer.interval = _job.timeoutMs
    jobTimer.restart()
    proc.running = true
  }

  function _finishJob(exitCode) {
    jobTimer.stop()
    var job = _job
    _job = null
    if (!job) { Qt.callLater(_pumpJobs); return }
    var result = {
      exitCode: exitCode,
      stdout: procOut.text,
      stderr: procErr.text,
      timedOut: job.timedOut === true
    }
    if (result.stderr) pushDiag(job.argv.join(" "), result.stderr)
    Qt.callLater(_pumpJobs)
    try { job.cb(result) } catch (e) {
      console.warn("social-poster: job callback threw:", e)
    }
  }

  Process {
    id: proc
    stdout: StdioCollector { id: procOut; waitForEnd: true }
    stderr: StdioCollector { id: procErr; waitForEnd: true }
    onStarted: {
      if (root._job && root._job.stdinText !== null && root._job.stdinText !== undefined) {
        proc.write(root._job.stdinText)
        proc.stdinEnabled = false // stdin を閉じてプロバイダーの read を返す
      }
    }
    onExited: function(exitCode, exitStatus) { root._finishJob(exitCode) }
  }

  Timer {
    id: jobTimer
    repeat: false
    onTriggered: {
      if (!root._job) return
      root._job.timedOut = true
      proc.running = false
    }
  }

  function pushDiag(source, text) {
    var log = diagLog.slice()
    log.push({ at: new Date().toISOString(), source: source, text: String(text).slice(0, 4000) })
    if (log.length > 100) log = log.slice(log.length - 100)
    diagLog = log
  }

  // ==================================================== プロバイダー呼び出し

  // 探索順(利用者 → 同梱)の解決と実行を 1 ジョブにまとめる。
  // どちらも実行可能でなければ exit 127 で戻り、設定エラーにする(SPEC §4.2)。
  function callProvider(account, subcommand, extra, cb) {
    expandSecrets(account, function(expanded, err) {
      if (!expanded) {
        cb(Providers.errorResponse("other", err || "秘密情報の展開に失敗しました"))
        return
      }
      var req = Providers.buildRequest(expanded, providerStateFor(account.id), extra)
      var candidates = Providers.candidatePaths(root.configDir, root.pluginDir, account.provider)
      var script = 'for p in "$1" "$2"; do if [ -x "$p" ]; then exec "$p" "$3"; fi; done; exit 127'
      enqueueJob(["bash", "-c", script, "provider-exec", candidates[0], candidates[1], subcommand],
                 JSON.stringify(req), Providers.TIMEOUT_MS, function(r) {
        if (r.exitCode === 127) {
          cb(Providers.errorResponse("config", "プロバイダーが見つかりません(実行権限を確認): " + account.provider))
          return
        }
        if (r.timedOut) {
          cb(Providers.errorResponse("other", "プロバイダーが 30 秒以内に応答しませんでした"))
          return
        }
        var parsed = Providers.parseResponse(r.stdout)
        if (!parsed) {
          pushDiag(account.provider + " " + subcommand, "invalid response: " + String(r.stdout).slice(0, 500))
          cb(Providers.errorResponse("other", "プロバイダーの応答が不正です"))
          return
        }
        if (parsed.ok === true && parsed.state !== undefined && parsed.state !== null)
          setProviderState(account.id, parsed.state)
        cb(parsed)
      })
    })
  }

  // {"$command": "..."} フィールドの展開(SPEC §5.1)。展開値はメモリ上のみ。
  function expandSecrets(account, cb) {
    var keys = Accounts.secretCommandKeys(account)
    if (keys.length === 0) { cb(account); return }
    var out = JSON.parse(JSON.stringify(account))
    var i = 0
    function next() {
      if (i >= keys.length) { cb(out); return }
      var key = keys[i++]
      var cmd = account[key]["$command"]
      if (root._secretCache[cmd] !== undefined) {
        out[key] = root._secretCache[cmd]
        next()
        return
      }
      enqueueJob(["bash", "-c", cmd], null, 15000, function(r) {
        if (r.exitCode !== 0) {
          cb(null, "フィールド " + key + " の $command が失敗しました (exit " + r.exitCode + ")")
          return
        }
        var value = String(r.stdout).replace(/\n+$/, "")
        root._secretCache[cmd] = value
        out[key] = value
        next()
      })
    }
    next()
  }

  // ========================================================== 永続 state

  function providerStateFor(accountId) {
    return Store.accountRecord(persist, accountId).providerState
  }

  function setProviderState(accountId, state) {
    Store.accountRecord(persist, accountId).providerState = state
    schedulePersist()
  }

  function schedulePersist() {
    persistTimer.restart()
  }

  Timer {
    id: persistTimer
    interval: 1000
    repeat: false
    onTriggered: stateView.setText(JSON.stringify(root.persist, null, 2) + "\n")
  }

  FileView {
    id: stateView
    path: root.statePath
    printErrors: false
    onLoaded: {
      if (!root.persistLoaded) {
        root.persist = Store.parseState(text())
        root.persistLoaded = true
      }
    }
    onLoadFailed: root.persistLoaded = true
  }

  // ======================================================= accounts.json

  FileView {
    id: accountsView
    path: root.accountsPath
    watchChanges: true
    printErrors: false
    onLoaded: root.checkAccountsFile()
    onFileChanged: accountsView.reload()
    onLoadFailed: {
      root.accountsReady = false
      root.accountsProblem = "accounts.json がありません: " + root.accountsPath
      root.applyAccounts({ ok: false, accounts: [], defaultPostTargets: [], pollIntervalSeconds: 120, notifications: true, errors: [] })
    }
  }

  // パーミッション 600 必須(SPEC §5.1)。緩い場合は警告して読み込み拒否。
  function checkAccountsFile() {
    enqueueJob(["stat", "-c", "%a", root.accountsPath], null, 5000, function(r) {
      var perm = String(r.stdout).trim()
      if (r.exitCode !== 0) {
        root.accountsReady = false
        root.accountsProblem = "accounts.json を確認できません"
        return
      }
      if (perm !== "600" && perm !== "400") {
        root.accountsReady = false
        root.accountsProblem = "accounts.json のパーミッションが " + perm + " です(600 にしてください)"
        if (!root._permWarned) {
          root._permWarned = true
          root.notify("Social Poster", "accounts.json のパーミッションが緩いため読み込みを拒否しました。chmod 600 してください。", true)
        }
        root.applyAccounts({ ok: false, accounts: [], defaultPostTargets: [], pollIntervalSeconds: 120, notifications: true, errors: [] })
        return
      }
      root._permWarned = false
      root.accountsProblem = ""
      root.applyAccounts(Accounts.parse(accountsView.text()))
    })
  }

  function applyAccounts(parsed) {
    accounts = parsed.accounts
    configErrors = parsed.errors
    defaultPostTargets = parsed.defaultPostTargets
    pollIntervalSeconds = parsed.pollIntervalSeconds
    notificationsEnabled = parsed.notifications
    accountsReady = parsed.ok
    if (!parsed.ok && !accountsProblem && parsed.errors.length > 0)
      accountsProblem = parsed.errors[0].message

    // 消えたアカウントのランタイム状態を掃除し、残りを初期化し直す
    var validIds = {}
    for (var i = 0; i < accounts.length; i++) validIds[accounts[i].id] = true
    var nextMentions = {}
    for (var id in mentionsByAccount) if (validIds[id]) nextMentions[id] = mentionsByAccount[id]
    mentionsByAccount = nextMentions

    accountInfo = ({})
    var status = {}
    var sched = {}
    for (var j = 0; j < accounts.length; j++) {
      var a = accounts[j]
      if (!a.enabled) continue
      status[a.id] = { state: "pending", message: "" }
      // accounts.json 変更で一時停止は自動解除(SPEC §8)
      sched[a.id] = { nextAt: 0, netFailures: 0, otherFailures: 0, authNotified: false }
    }
    accountStatus = status
    _schedule = sched
    updateDerived()

    for (var k = 0; k < accounts.length; k++) {
      if (accounts[k].enabled) fetchInfo(accounts[k])
    }
  }

  function accountById(id) {
    for (var i = 0; i < accounts.length; i++)
      if (accounts[i].id === id) return accounts[i]
    return null
  }

  function setStatus(accountId, state, message) {
    var next = {}
    for (var k in accountStatus) next[k] = accountStatus[k]
    next[accountId] = { state: state, message: message || "" }
    accountStatus = next
    updateDerived()
  }

  // ============================================================== info

  function fetchInfo(account) {
    callProvider(account, "info", {}, function(res) {
      if (res.ok !== true) {
        handleAccountError(account, res.error, "info")
        return
      }
      var info = Providers.parseInfo(res)
      if (!info) {
        setStatus(account.id, "config", "info 応答が不正です")
        return
      }
      var next = {}
      for (var k in accountInfo) next[k] = accountInfo[k]
      next[account.id] = info
      accountInfo = next
      setStatus(account.id, "ok", "")
      // 準備が整ったら即ポーリングする
      var sched = _schedule[account.id]
      if (sched) sched.nextAt = 0
      Qt.callLater(function() { root.pollDueAccounts(false) })
    })
  }

  // ========================================================== ポーリング

  Timer {
    id: pollTick
    interval: 15000
    repeat: true
    running: true
    onTriggered: root.pollDueAccounts(false)
  }

  function refreshNow() {
    for (var id in _schedule) _schedule[id].nextAt = 0
    pollDueAccounts(true)
  }

  function pollDueAccounts(manual) {
    if (!accountsReady) return
    var now = Date.now()
    for (var i = 0; i < accounts.length; i++) {
      var a = accounts[i]
      if (!a.enabled) continue
      var st = accountStatus[a.id]
      if (!st || st.state === "auth" || st.state === "paused" || st.state === "config" || st.state === "pending") continue
      if (!Providers.hasCapability(accountInfo[a.id], "mentions")) continue
      var sched = _schedule[a.id]
      if (!sched || now < sched.nextAt) continue
      sched.nextAt = now + pollIntervalSeconds * 1000
      pollMentions(a)
    }
  }

  function pollMentions(account) {
    _pendingPolls += 1
    refreshing = true
    var rec = Store.accountRecord(persist, account.id)
    callProvider(account, "mentions", { cursor: rec.cursor || null }, function(res) {
      _pendingPolls = Math.max(0, _pendingPolls - 1)
      refreshing = _pendingPolls > 0
      if (res.ok !== true) {
        handleAccountError(account, res.error, "mentions")
        return
      }
      handleMentions(account, res)
    })
  }

  function handleMentions(account, res) {
    var sched = _schedule[account.id]
    if (sched) { sched.netFailures = 0; sched.otherFailures = 0 }
    setStatus(account.id, "ok", "")

    var rec = Store.accountRecord(persist, account.id)
    if (res.cursor !== undefined) rec.cursor = res.cursor

    var list = Providers.parseMentions(res)
    var providerName = accountInfo[account.id] ? accountInfo[account.id].name : account.provider
    for (var i = 0; i < list.length; i++) {
      list[i].accountId = account.id
      list[i].providerName = providerName
    }

    // 初回(通知済み ID が空)は通知せずに既知として seed する
    var seeding = rec.notifiedIds.length === 0
    var fresh = []
    for (var j = 0; j < list.length; j++) {
      if (rec.notifiedIds.indexOf(list[j].id) === -1) fresh.push(list[j])
    }
    Store.rememberNotified(rec, fresh.map(function(m) { return m.id }))
    schedulePersist()

    var next = {}
    for (var k in mentionsByAccount) next[k] = mentionsByAccount[k]
    next[account.id] = list
    mentionsByAccount = next
    updateDerived()
    mentionsUpdated()

    if (!seeding && notificationsEnabled && fresh.length > 0) {
      if (fresh.length === 1) {
        var m = fresh[0]
        notify(m.author.handle + " (" + providerName + ")", Store.excerpt(m.text, 120), false)
      } else {
        notify("新着メンション " + fresh.length + " 件", "", false)
      }
    }
  }

  // ==================================================== エラーハンドリング

  function handleAccountError(account, error, context) {
    var code = error && error.code ? error.code : "other"
    var message = error && error.message ? error.message : "unknown error"
    var sched = _schedule[account.id]
    pushDiag(account.provider + " " + context, code + ": " + message)

    if (code === "auth") {
      // 1 回だけ通知してアカウントを一時停止(SPEC §8)
      setStatus(account.id, "auth", message)
      if (sched && !sched.authNotified) {
        sched.authNotified = true
        notify("Social Poster: " + account.id, "認証エラーです。accounts.json の再設定が必要です。", true)
      }
    } else if (code === "network") {
      // 淡色化 + 指数バックオフ、通知なし(SPEC §8)
      if (sched) {
        sched.netFailures += 1
        sched.nextAt = Date.now() + Store.backoffSeconds(sched.netFailures) * 1000
      }
      setStatus(account.id, "network", message)
    } else if (code === "config") {
      setStatus(account.id, "config", message)
    } else {
      // 不正応答・タイムアウト等: 連続 3 回で次回設定変更まで一時停止(SPEC §8)
      if (sched) {
        sched.otherFailures += 1
        if (sched.otherFailures >= 3) {
          setStatus(account.id, "paused", "エラーが続いたため一時停止中: " + message)
          return
        }
      }
      setStatus(account.id, "network", message)
    }
  }

  // ====================================================== 既読・非表示処理

  // 「見たら消える」自動既読はしない(SPEC §6.2)。既読化・削除は
  // すべてパネルの明示操作からのみ行われる。

  function markAllRead() {
    var now = new Date().toISOString()
    var changed = false
    for (var i = 0; i < accounts.length; i++) {
      var a = accounts[i]
      if (!a.enabled) continue
      var rec = Store.accountRecord(persist, a.id)
      rec.lastReadAt = now
      changed = true
      if (Providers.hasCapability(accountInfo[a.id], "markRead")) {
        (function(account) {
          callProvider(account, "markRead", { until: now }, function(res) {
            if (res.ok !== true) pushDiag(account.provider + " markRead", res.error ? res.error.message : "failed")
          })
        })(a)
      }
    }
    if (changed) {
      schedulePersist()
      updateDerived()
    }
  }

  // 個別メンションを一覧から消す。消した ID は state.json に残るので
  // 再ポーリングで同じメンションが返ってきても復活しない。
  function dismissMention(accountId, mentionId) {
    if (!accountId || !mentionId) return
    Store.rememberDismissed(Store.accountRecord(persist, accountId), [mentionId])
    schedulePersist()
    updateDerived()
  }

  // 表示中のメンションをすべて消す(併せて既読化する)。
  function dismissAll() {
    var idsByAccount = {}
    for (var i = 0; i < mentions.length; i++) {
      var m = mentions[i]
      if (!idsByAccount[m.accountId]) idsByAccount[m.accountId] = []
      idsByAccount[m.accountId].push(m.id)
    }
    for (var id in idsByAccount)
      Store.rememberDismissed(Store.accountRecord(persist, id), idsByAccount[id])
    markAllRead()
    schedulePersist()
    updateDerived()
  }

  // ================================================================ 投稿

  // done([{accountId, ok, url, message}])
  function post(text, accountIds, replyTo, done) {
    var results = []
    var remaining = accountIds.length
    if (remaining === 0) { done([]); return }
    for (var i = 0; i < accountIds.length; i++) {
      (function(id) {
        var account = root.accountById(id)
        if (!account || !account.enabled) {
          results.push({ accountId: id, ok: false, url: null, message: "アカウントが見つかりません" })
          if (--remaining === 0) done(results)
          return
        }
        var reply = (replyTo && replyTo.accountId === id) ? (replyTo.replyContext || null) : null
        root.callProvider(account, "post", { text: text, replyTo: reply }, function(res) {
          if (res.ok === true) {
            results.push({ accountId: id, ok: true, url: res.url || null, message: "" })
          } else {
            root.handleAccountError(account, res.error, "post")
            results.push({ accountId: id, ok: false, url: null, message: res.error ? res.error.message : "unknown error" })
          }
          if (--remaining === 0) done(results)
        })
      })(accountIds[i])
    }
  }

  // ================================================ アカウント管理(セットアップ UI)

  // 現在の構成を accounts.json に書き戻せる形で再構築する。
  // コアが解釈しない未知のトップレベルフィールドは保持されない点に注意。
  function configSnapshot() {
    var list = []
    for (var i = 0; i < accounts.length; i++)
      list.push(JSON.parse(JSON.stringify(accounts[i])))
    return {
      accounts: list,
      defaultPostTargets: defaultPostTargets.slice(),
      pollIntervalSeconds: pollIntervalSeconds,
      notifications: notificationsEnabled
    }
  }

  // 秘密を含むため JSON は stdin 経由で渡し、600 のまま原子的に置き換える
  function writeAccountsConfig(config, cb) {
    // 省略された id は省略のまま、コア内部用の `__` キーは落として書き戻す
    var cfg = JSON.parse(JSON.stringify(config))
    for (var i = 0; i < cfg.accounts.length; i++) {
      var a = cfg.accounts[i]
      if (a.__implicitId === true) delete a.id
      for (var k in a) if (k.indexOf("__") === 0) delete a[k]
    }
    var json = JSON.stringify(cfg, null, 2) + "\n"
    enqueueJob(["bash", "-c",
      'umask 077; tmp="$1.tmp.$$"; cat > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$1"',
      "write-accounts", root.accountsPath], json, 10000, function(r) {
      if (r.exitCode !== 0) {
        if (cb) cb(false, "accounts.json の書き込みに失敗しました")
        return
      }
      accountsView.reload()
      if (cb) cb(true, "")
    })
  }

  function upsertAccount(entry, makeDefault, cb) {
    var cfg = configSnapshot()
    var replaced = false
    for (var i = 0; i < cfg.accounts.length; i++) {
      if (cfg.accounts[i].id === entry.id) {
        cfg.accounts[i] = entry
        replaced = true
      }
    }
    if (!replaced) cfg.accounts.push(entry)
    if (makeDefault && cfg.defaultPostTargets.indexOf(entry.id) === -1)
      cfg.defaultPostTargets.push(entry.id)
    writeAccountsConfig(cfg, cb)
  }

  function removeAccount(id, cb) {
    var cfg = configSnapshot()
    cfg.accounts = cfg.accounts.filter(function(a) { return a.id !== id })
    cfg.defaultPostTargets = cfg.defaultPostTargets.filter(function(t) { return t !== id })
    writeAccountsConfig(cfg, cb)
  }

  function setAccountEnabled(id, enabled, cb) {
    var cfg = configSnapshot()
    for (var i = 0; i < cfg.accounts.length; i++)
      if (cfg.accounts[i].id === id) cfg.accounts[i].enabled = enabled
    writeAccountsConfig(cfg, cb)
  }

  function toggleDefaultTarget(id, cb) {
    var cfg = configSnapshot()
    var idx = cfg.defaultPostTargets.indexOf(id)
    if (idx === -1) cfg.defaultPostTargets.push(id)
    else cfg.defaultPostTargets.splice(idx, 1)
    writeAccountsConfig(cfg, cb)
  }

  // 保存前のドラフトを検証する(accounts.json には触らない)
  function verifyDraft(account, cb) {
    callProvider(account, "verify", {}, cb)
  }

  // 探索パスにある実行可能なプロバイダー名一覧(セットアップのドロップダウン用)
  function listProviders(cb) {
    enqueueJob(["bash", "-c",
      'for d in "$1" "$2"; do [ -d "$d" ] || continue; for f in "$d"/*; do [ -x "$f" ] && basename "$f"; done; done | sort -u',
      "list-providers", root.configDir + "/providers", root.pluginDir + "/providers"],
      null, 5000, function(r) {
      var names = String(r.stdout).split("\n").filter(function(s) { return s !== "" })
      cb(names)
    })
  }

  // ============================================================ 集約値更新

  function updateDerived() {
    var merged = Store.mergeMentions(mentionsByAccount, function(accountId, mentionId) {
      return Store.accountRecord(root.persist, accountId).dismissedIds.indexOf(mentionId) !== -1
    })
    var unread = 0
    for (var i = 0; i < merged.length; i++) {
      var rec = Store.accountRecord(persist, merged[i].accountId)
      merged[i].unread = Store.isUnread(merged[i], rec.lastReadAt)
      if (merged[i].unread) unread += 1
    }
    mentions = merged
    unreadCount = unread

    var posts = []
    for (var j = 0; j < accounts.length; j++) {
      var a = accounts[j]
      if (!a.enabled) continue
      var info = accountInfo[a.id]
      var st = accountStatus[a.id]
      if (!Providers.hasCapability(info, "post")) continue
      if (st && (st.state === "auth" || st.state === "config" || st.state === "paused")) continue
      var providerLabel = info ? info.name : a.provider
      posts.push({
        id: a.id,
        label: a.__implicitId === true ? providerLabel : providerLabel + " · " + a.id,
        maxChars: info ? info.maxChars : null
      })
    }
    postAccounts = posts
  }

  // アカウント状態の要約(バーのツールチップ・パネルの警告表示用)
  function statusSummary() {
    var problems = []
    if (accountsProblem) problems.push(accountsProblem)
    for (var i = 0; i < configErrors.length; i++) problems.push(configErrors[i].message)
    for (var id in accountStatus) {
      var st = accountStatus[id]
      if (st.state === "ok" || st.state === "pending") continue
      problems.push(id + ": " + (st.message || st.state))
    }
    return problems
  }

  function hasNetworkProblem() {
    for (var id in accountStatus)
      if (accountStatus[id].state === "network") return true
    return false
  }

  function notify(headline, body, critical) {
    var argv = ["omarchy-notification-send", "--app-name", "Social Poster", "-g", "󰍥",
                "-u", critical ? "critical" : "normal", headline]
    if (body) argv.push(body)
    Quickshell.execDetached(argv)
  }

  function openUrl(url) {
    if (url) Quickshell.execDetached(["xdg-open", url])
  }

  // ============================================================== 起動処理

  Component.onCompleted: {
    // 設定ディレクトリと state.json を 600 で用意(SPEC §5.2, §7)
    enqueueJob(["bash", "-c",
      'install -d -m 700 "$1" "$1/providers" && { [ -e "$2" ] || install -m 600 /dev/null "$2"; } && chmod 600 "$2"',
      "setup", root.configDir, root.statePath], null, 10000, function(r) {
      if (r.exitCode !== 0) console.warn("social-poster: setup failed:", r.stderr)
      stateView.reload()
      accountsView.reload()
    })
  }

  IpcHandler {
    target: "social-poster"

    function refresh(): string {
      root.refreshNow()
      return "ok"
    }

    function status(): string {
      return JSON.stringify({
        accountsReady: root.accountsReady,
        problem: root.accountsProblem,
        unread: root.unreadCount,
        mentions: root.mentions.length,
        accounts: root.accountStatus
      })
    }

    function ping(): string {
      return "ok"
    }
  }
}
