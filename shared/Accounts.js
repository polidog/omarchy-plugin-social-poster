// accounts.json の読み込み・検証(SPEC §5.1)
// コアが解釈するのは id / provider / enabled のみ。残りはプロバイダー固有の
// フィールドとしてそのまま account オブジェクトでプロバイダーに渡す。
// id は省略可(省略時は provider 名が id になる)。パース結果の `__` で始まる
// キーはコア内部用で、プロバイダーにも accounts.json にも出さない。
.pragma library

var MIN_POLL_SECONDS = 60
var DEFAULT_POLL_SECONDS = 120

// text -> { ok, accounts, defaultPostTargets, pollIntervalSeconds,
//           notifications, errors: [{accountId?, message}] }
function parse(text) {
  var out = {
    ok: false,
    accounts: [],
    defaultPostTargets: [],
    pollIntervalSeconds: DEFAULT_POLL_SECONDS,
    notifications: true,
    errors: []
  }

  var raw
  try {
    raw = JSON.parse(text)
  } catch (e) {
    out.errors.push({ message: "accounts.json が JSON として読めません: " + e.message })
    return out
  }
  if (!raw || typeof raw !== "object") {
    out.errors.push({ message: "accounts.json のトップレベルはオブジェクトである必要があります" })
    return out
  }

  var seen = {}
  var list = Array.isArray(raw.accounts) ? raw.accounts : []
  if (!Array.isArray(raw.accounts))
    out.errors.push({ message: "accounts フィールド(配列)がありません" })

  for (var i = 0; i < list.length; i++) {
    var a = list[i]
    if (!a || typeof a !== "object") {
      out.errors.push({ message: "accounts[" + i + "] がオブジェクトではありません" })
      continue
    }
    if (typeof a.provider !== "string" || a.provider === "" || /[\/\0]/.test(a.provider)) {
      out.errors.push({ message: "accounts[" + i + "] の provider 名が不正です" })
      continue
    }
    if (a.id !== undefined && a.id !== null && typeof a.id !== "string") {
      out.errors.push({ message: "accounts[" + i + "] の id は文字列で指定してください" })
      continue
    }
    // id 省略時は provider 名をそのまま id にする。1 つの SNS に 1 アカウントなら
    // これで一意になり、同じ provider を複数持つときだけ明示すればよい。
    var id = typeof a.id === "string" ? a.id.trim() : ""
    var implicitId = id === ""
    if (implicitId) id = a.provider
    if (seen[id]) {
      out.errors.push({ accountId: id, message: implicitId
        ? "provider \"" + a.provider + "\" のアカウントが複数あります。id を付けて区別してください"
        : "id が重複しています: " + id })
      continue
    }
    seen[id] = true
    var entry = {}
    for (var k in a) entry[k] = a[k]
    entry.id = id
    entry.enabled = a.enabled !== false
    if (implicitId) entry.__implicitId = true
    out.accounts.push(entry)
  }

  if (Array.isArray(raw.defaultPostTargets)) {
    for (var j = 0; j < raw.defaultPostTargets.length; j++) {
      var t = raw.defaultPostTargets[j]
      if (typeof t === "string" && seen[t]) out.defaultPostTargets.push(t)
    }
  }

  if (typeof raw.pollIntervalSeconds === "number" && isFinite(raw.pollIntervalSeconds))
    out.pollIntervalSeconds = Math.max(MIN_POLL_SECONDS, Math.round(raw.pollIntervalSeconds))

  if (raw.notifications === false) out.notifications = false

  out.ok = true
  return out
}

// アカウント内の {"$command": "..."} フィールドのキー一覧
function secretCommandKeys(account) {
  var keys = []
  for (var k in account) {
    var v = account[k]
    if (v && typeof v === "object" && typeof v["$command"] === "string") keys.push(k)
  }
  return keys
}
