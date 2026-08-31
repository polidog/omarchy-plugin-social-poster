// state.json(SPEC §5.2)の形と、メンション一覧まわりの純粋関数。
// 永続化そのもの(FileView への書き込み)は service/Service.qml が行う。
.pragma library

var MAX_NOTIFIED_IDS = 200
var MAX_MENTIONS = 50

function emptyState() {
  return { accounts: {} }
}

function parseState(text) {
  try {
    var raw = JSON.parse(text)
    if (raw && typeof raw === "object" && raw.accounts && typeof raw.accounts === "object")
      return raw
  } catch (e) {}
  return emptyState()
}

// アカウントごとの永続レコード:
//   providerState: プロバイダーが返した state(不透明)
//   cursor:        mentions の前回カーソル
//   lastReadAt:    ローカル既読時刻(ISO 8601)
//   notifiedIds:   通知済みメンション ID(重複通知防止)
function accountRecord(state, accountId) {
  var rec = state.accounts[accountId]
  if (!rec || typeof rec !== "object") {
    rec = { providerState: {}, cursor: null, lastReadAt: null, notifiedIds: [] }
    state.accounts[accountId] = rec
  }
  if (!rec.providerState || typeof rec.providerState !== "object") rec.providerState = {}
  if (!Array.isArray(rec.notifiedIds)) rec.notifiedIds = []
  return rec
}

function rememberNotified(rec, ids) {
  for (var i = 0; i < ids.length; i++) {
    if (rec.notifiedIds.indexOf(ids[i]) === -1) rec.notifiedIds.push(ids[i])
  }
  if (rec.notifiedIds.length > MAX_NOTIFIED_IDS)
    rec.notifiedIds = rec.notifiedIds.slice(rec.notifiedIds.length - MAX_NOTIFIED_IDS)
}

// 全アカウント統合の時系列一覧(新しい順、最大 MAX_MENTIONS 件)
function mergeMentions(mentionsByAccount) {
  var all = []
  for (var id in mentionsByAccount) {
    var list = mentionsByAccount[id] || []
    for (var i = 0; i < list.length; i++) all.push(list[i])
  }
  all.sort(function(a, b) {
    return String(b.createdAt).localeCompare(String(a.createdAt))
  })
  return all.slice(0, MAX_MENTIONS)
}

function isUnread(mention, lastReadAt) {
  if (!mention.createdAt) return false
  if (!lastReadAt) return true
  return String(mention.createdAt) > String(lastReadAt)
}

// ネットワークエラーの指数バックオフ(SPEC §8): 30s → 60s → 120s、上限 300s
function backoffSeconds(failures) {
  if (failures <= 0) return 0
  return Math.min(30 * Math.pow(2, failures - 1), 300)
}

function excerpt(text, maxLen) {
  var t = String(text || "").replace(/\s+/g, " ").trim()
  if (t.length <= maxLen) return t
  return t.slice(0, maxLen - 1) + "…"
}

function relativeTime(iso, nowMs) {
  var t = Date.parse(iso)
  if (isNaN(t)) return ""
  var diff = Math.max(0, Math.floor((nowMs - t) / 1000))
  if (diff < 60) return "たった今"
  if (diff < 3600) return Math.floor(diff / 60) + "分前"
  if (diff < 86400) return Math.floor(diff / 3600) + "時間前"
  return Math.floor(diff / 86400) + "日前"
}
