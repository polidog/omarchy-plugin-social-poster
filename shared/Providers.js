// プロバイダー契約 v1(SPEC §4)のリクエスト構築・レスポンス検証ヘルパ。
// 実際のプロセス起動と探索順の解決は service/Service.qml のジョブキューが行う。
.pragma library

var CONTRACT_VERSION = 1
var TIMEOUT_MS = 30000

// 探索順(先勝ち): 利用者ディレクトリ → 同梱(SPEC §4.2)
function candidatePaths(configDir, pluginDir, providerName) {
  return [
    configDir + "/providers/" + providerName,
    pluginDir + "/providers/" + providerName
  ]
}

function buildRequest(account, state, extra) {
  // `__` で始まるキーはコア内部用(例: __implicitId)なのでプロバイダーには渡さない
  var acc = {}
  for (var key in account) if (key.indexOf("__") !== 0) acc[key] = account[key]
  var req = { contractVersion: CONTRACT_VERSION, account: acc, state: state || {} }
  if (extra) for (var k in extra) req[k] = extra[k]
  return req
}

// stdout テキスト -> レスポンスオブジェクト(不正なら null)
function parseResponse(text) {
  var parsed
  try {
    parsed = JSON.parse(text)
  } catch (e) {
    return null
  }
  if (!parsed || typeof parsed !== "object") return null
  if (parsed.ok !== true && parsed.ok !== false) return null
  if (parsed.ok === false) {
    if (!parsed.error || typeof parsed.error !== "object") return null
    var code = parsed.error.code
    if (["auth", "network", "invalid", "other"].indexOf(code) === -1)
      parsed.error.code = "other"
    if (typeof parsed.error.message !== "string") parsed.error.message = "unknown error"
  }
  return parsed
}

function errorResponse(code, message) {
  return { ok: false, error: { code: code, message: message } }
}

// info レスポンスの正規化(不正なら null)
function parseInfo(res) {
  if (!res || res.ok !== true) return null
  if (typeof res.name !== "string" || res.name === "") return null
  var caps = Array.isArray(res.capabilities) ? res.capabilities : []
  var maxChars = (typeof res.maxChars === "number" && isFinite(res.maxChars) && res.maxChars > 0)
    ? Math.round(res.maxChars) : null
  return { name: res.name, maxChars: maxChars, capabilities: caps }
}

// mentions レスポンスの各要素を検証・正規化(SPEC §4.4)
function parseMentions(res) {
  if (!res || res.ok !== true || !Array.isArray(res.mentions)) return []
  var out = []
  for (var i = 0; i < res.mentions.length; i++) {
    var m = res.mentions[i]
    if (!m || typeof m !== "object") continue
    if (typeof m.id !== "string" || m.id === "") continue
    var author = (m.author && typeof m.author === "object") ? m.author : {}
    out.push({
      id: m.id,
      author: {
        handle: typeof author.handle === "string" ? author.handle : "",
        displayName: typeof author.displayName === "string" ? author.displayName : "",
        avatarUrl: typeof author.avatarUrl === "string" ? author.avatarUrl : null
      },
      text: typeof m.text === "string" ? m.text : "",
      createdAt: typeof m.createdAt === "string" ? m.createdAt : "",
      url: typeof m.url === "string" ? m.url : null,
      replyContext: m.replyContext !== undefined ? m.replyContext : null
    })
  }
  return out
}

function hasCapability(info, cap) {
  return !!info && Array.isArray(info.capabilities) && info.capabilities.indexOf(cap) !== -1
}
