import QtQuick
import qs.Commons
import qs.Ui

// アカウントのセットアップ画面(Composer オーバーレイ内に表示)。
// accounts.json の読み書きはすべて service 側の API 経由で行い、
// このビューは秘密情報を保持しない(入力欄 → 保存時に entry を組むだけ)。
Column {
  id: root

  property var service: null
  property color foreground: Color.menu.text
  property string fontFamily: Style.font.menuFamily
  property bool busy: false

  signal requestCompose()

  readonly property var accounts: service ? service.accounts : []
  readonly property var defaults: service ? service.defaultPostTargets : []

  // 同梱プロバイダーの入力フォーム定義。無いプロバイダーは key/value 自由入力。
  readonly property var templates: ({
    bluesky: [
      { key: "service", label: "サービス URL", placeholder: "https://bsky.social", def: "https://bsky.social", secret: false, required: false },
      { key: "identifier", label: "ハンドル", placeholder: "you.bsky.social", def: "", secret: false, required: true },
      { key: "appPassword", label: "App Password", placeholder: "xxxx-xxxx-xxxx-xxxx", def: "", secret: true, required: true }
    ],
    misskey: [
      { key: "host", label: "インスタンス URL", placeholder: "https://misskey.io", def: "", secret: false, required: true },
      { key: "token", label: "API トークン", placeholder: "", def: "", secret: true, required: true },
      { key: "visibility", label: "公開範囲 (public/home/followers)", placeholder: "public", def: "public", secret: false, required: false }
    ],
    mastodon: [
      { key: "host", label: "インスタンス URL", placeholder: "https://mastodon.social", def: "", secret: false, required: true },
      { key: "token", label: "アクセストークン(設定 → 開発 → 新規アプリ)", placeholder: "", def: "", secret: true, required: true },
      { key: "visibility", label: "公開範囲 (public/unlisted/private)", placeholder: "public", def: "public", secret: false, required: false }
    ]
  })

  property var providers: ["bluesky", "misskey", "mastodon"]
  property string providerName: "bluesky"
  readonly property var template: templates[providerName] || null
  property var fieldValues: ({})
  property var customFields: [{ key: "", value: "" }]
  property bool makeDefault: true
  property string message: ""
  property bool messageIsError: false

  spacing: Style.spacing.md

  function refreshProviders() {
    if (!service) return
    service.listProviders(function(names) {
      var merged = ["bluesky", "misskey", "mastodon"]
      for (var i = 0; i < names.length; i++)
        if (merged.indexOf(names[i]) === -1) merged.push(names[i])
      root.providers = merged
    })
  }

  function resetForm() {
    fieldValues = ({})
    customFields = [{ key: "", value: "" }]
    idField.text = ""
    message = ""
    messageIsError = false
  }

  function setMessage(text, isError) {
    message = text
    messageIsError = isError === true
  }

  // 入力からアカウントエントリを組み立てる。不備があれば null + メッセージ。
  function buildEntry() {
    var id = idField.text.trim()
    // ID は省略可。省略時は provider 名がそのまま ID になる(同じ SNS で
    // 複数アカウントを使うときだけ入力してもらう)
    var entry = { id: id === "" ? providerName : id, provider: providerName, enabled: true }
    if (id === "") entry.__implicitId = true
    if (template) {
      for (var i = 0; i < template.length; i++) {
        var f = template[i]
        var value = String(fieldValues[f.key] !== undefined ? fieldValues[f.key] : f.def).trim()
        if (value === "" && f.required) {
          setMessage("「" + f.label + "」を入力してください", true)
          return null
        }
        if (value !== "") entry[f.key] = value
      }
    } else {
      for (var j = 0; j < customFields.length; j++) {
        var key = String(customFields[j].key).trim()
        var val = String(customFields[j].value)
        if (key === "") continue
        entry[key] = val
      }
    }
    return entry
  }

  function testConnection() {
    var entry = buildEntry()
    if (!entry || !service) return
    busy = true
    setMessage("接続を確認しています…", false)
    service.verifyDraft(entry, function(res) {
      busy = false
      if (res.ok === true) setMessage("接続 OK(" + entry.provider + ")", false)
      else setMessage("接続エラー: " + (res.error ? res.error.message : "unknown"), true)
    })
  }

  function addAccount() {
    var entry = buildEntry()
    if (!entry || !service) return
    var exists = false
    for (var i = 0; i < accounts.length; i++)
      if (accounts[i].id === entry.id) exists = true
    if (exists && entry.__implicitId === true) {
      setMessage("「" + providerName + "」のアカウントが既にあります。区別するためにアカウント ID を入力するか、既存の行を削除してください", true)
      return
    }
    busy = true
    setMessage(exists ? "既存の「" + entry.id + "」を上書きしています…" : "保存しています…", false)
    service.upsertAccount(entry, makeDefault, function(ok, err) {
      busy = false
      if (ok) {
        resetForm()
        setMessage("アカウントを保存しました", false)
      } else {
        setMessage(err, true)
      }
    })
  }

  Component.onCompleted: refreshProviders()

  // ---- 既存アカウント一覧 ----
  Text {
    visible: root.accounts.length > 0
    text: "アカウント"
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.subtitle
    font.bold: true
  }

  Column {
    width: parent.width
    spacing: Style.space(2)
    visible: root.accounts.length > 0

    Repeater {
      model: root.accounts

      Item {
        id: accountRow
        required property var modelData

        readonly property var status: root.service ? root.service.accountStatus[modelData.id] : null
        readonly property bool isDefault: root.defaults.indexOf(modelData.id) !== -1
        property bool confirmingDelete: false

        width: parent.width
        height: Style.space(32)

        Timer {
          interval: 3000
          running: accountRow.confirmingDelete
          onTriggered: accountRow.confirmingDelete = false
        }

        ToggleSwitch {
          id: enabledToggle
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          checked: accountRow.modelData.enabled === true
          interactive: !root.busy
          foreground: root.foreground
          onToggled: root.service.setAccountEnabled(accountRow.modelData.id, !accountRow.modelData.enabled)
        }

        Column {
          anchors.left: enabledToggle.right
          anchors.leftMargin: Style.space(8)
          anchors.right: rowButtons.left
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter

          Text {
            width: parent.width
            text: (accountRow.modelData.__implicitId === true
                   ? accountRow.modelData.provider
                   : accountRow.modelData.id + " · " + accountRow.modelData.provider)
              + (accountRow.isDefault ? " ★" : "")
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          Text {
            width: parent.width
            visible: accountRow.status && accountRow.status.state !== "ok" && accountRow.status.state !== "pending"
            text: accountRow.status ? accountRow.status.message || accountRow.status.state : ""
            color: Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        Row {
          id: rowButtons
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Button {
            iconText: "★"
            tooltipText: accountRow.isDefault ? "デフォルト投稿先から外す" : "デフォルト投稿先にする"
            foreground: accountRow.isDefault ? Color.accent : Qt.darker(root.foreground, 1.6)
            enabled: !root.busy
            horizontalPadding: Style.space(4)
            onClicked: root.service.toggleDefaultTarget(accountRow.modelData.id)
          }

          Button {
            text: accountRow.confirmingDelete ? "削除?" : ""
            iconText: accountRow.confirmingDelete ? "" : "󰩹"
            tooltipText: "アカウントを削除"
            foreground: accountRow.confirmingDelete ? Color.urgent : Qt.darker(root.foreground, 1.4)
            enabled: !root.busy
            horizontalPadding: Style.space(4)
            onClicked: {
              if (!accountRow.confirmingDelete) {
                accountRow.confirmingDelete = true
                return
              }
              accountRow.confirmingDelete = false
              root.service.removeAccount(accountRow.modelData.id, function(ok, err) {
                root.setMessage(ok ? "削除しました" : err, !ok)
              })
            }
          }
        }
      }
    }
  }

  PanelSeparator {
    visible: root.accounts.length > 0
    foreground: root.foreground
  }

  // ---- アカウント追加フォーム ----
  Text {
    text: "アカウント追加"
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.subtitle
    font.bold: true
  }

  Dropdown {
    width: parent.width
    label: "プロバイダー"
    value: root.providerName
    options: root.providers.map(function(p) { return { value: p, label: p } })
    foreground: root.foreground
    onChanged: function(value) {
      root.providerName = value
      root.fieldValues = ({})
      root.customFields = [{ key: "", value: "" }]
      root.message = ""
    }
  }

  TextField {
    id: idField
    width: parent.width
    placeholderText: "アカウント ID(省略可 · 既定は「" + root.providerName + "」)"
    foreground: root.foreground
    enabled: !root.busy
  }

  // 同梱プロバイダー: 定義済みフォーム
  Column {
    width: parent.width
    spacing: Style.space(4)
    visible: root.template !== null

    Repeater {
      model: root.template || []

      TextField {
        required property var modelData
        width: parent.width
        placeholderText: modelData.label + (modelData.placeholder ? "(" + modelData.placeholder + ")" : "")
        password: modelData.secret === true
        text: modelData.def
        foreground: root.foreground
        enabled: !root.busy
        Component.onCompleted: root.fieldValues[modelData.key] = text
        onTextChanged: root.fieldValues[modelData.key] = text
      }
    }
  }

  // 独自プロバイダー: key / value 自由入力
  Column {
    width: parent.width
    spacing: Style.space(4)
    visible: root.template === null

    Text {
      width: parent.width
      text: "このプロバイダーのフォーム定義はありません。必要なフィールドを key / value で追加してください(docs/PROVIDER.md 参照)。"
      color: Qt.darker(root.foreground, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.Wrap
    }

    Repeater {
      model: root.customFields.length

      Row {
        id: customRow
        required property int index
        width: parent.width
        spacing: Style.space(4)

        TextField {
          width: (customRow.width - Style.space(8)) * 0.35
          placeholderText: "key(例: token)"
          text: root.customFields[customRow.index] ? root.customFields[customRow.index].key : ""
          foreground: root.foreground
          enabled: !root.busy
          onTextChanged: if (root.customFields[customRow.index]) root.customFields[customRow.index].key = text
        }

        TextField {
          width: (customRow.width - Style.space(8)) * 0.65
          placeholderText: "value"
          password: true
          text: root.customFields[customRow.index] ? root.customFields[customRow.index].value : ""
          foreground: root.foreground
          enabled: !root.busy
          onTextChanged: if (root.customFields[customRow.index]) root.customFields[customRow.index].value = text
        }
      }
    }

    Button {
      text: "＋ フィールド追加"
      foreground: root.foreground
      fontSize: Style.font.caption
      onClicked: {
        var next = root.customFields.slice()
        next.push({ key: "", value: "" })
        root.customFields = next
      }
    }
  }

  // ---- デフォルト投稿先チェック ----
  Item {
    width: parent.width
    height: Style.space(26)

    ToggleSwitch {
      id: defaultToggle
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      checked: root.makeDefault
      interactive: !root.busy
      foreground: root.foreground
      onToggled: root.makeDefault = !root.makeDefault
    }

    Text {
      anchors.left: defaultToggle.right
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: "デフォルトの投稿先にする"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall

      MouseArea {
        anchors.fill: parent
        enabled: !root.busy
        onClicked: root.makeDefault = !root.makeDefault
      }
    }
  }

  // ---- 結果メッセージ ----
  Text {
    width: parent.width
    visible: root.message !== ""
    text: root.message
    color: root.messageIsError ? Color.urgent : Color.accent
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.Wrap
  }

  // ---- アクション ----
  Item {
    width: parent.width
    height: Style.space(34)

    Button {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: "投稿画面へ"
      foreground: root.foreground
      visible: root.accounts.length > 0
      enabled: !root.busy
      onClicked: root.requestCompose()
    }

    Row {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(6)

      Button {
        text: "接続テスト"
        foreground: root.foreground
        enabled: !root.busy
        onClicked: root.testConnection()
      }

      Button {
        text: root.busy ? "処理中…" : "保存"
        foreground: root.foreground
        accent: Color.accent
        selected: !root.busy
        enabled: !root.busy
        onClicked: root.addAccount()
      }
    }
  }
}
