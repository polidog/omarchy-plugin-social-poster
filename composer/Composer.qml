import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// 投稿用オーバーレイ(SPEC §6.1)。
// `omarchy-shell shell summon io.github.polidog.social-poster '<payload>'` で開く。
// payload に {"replyTo": {accountId, replyContext, authorHandle, excerpt}}
// が入っていると返信モードになる(replyContext は不透明値のまま渡す)。
Item {
  id: root

  property var shell: null
  property var manifest: null
  property var service: null  // シェルが同一プラグインの service を注入する

  property bool opened: false
  property bool keyboardHeld: true      // false なら他ウィンドウにキーボードを譲る
  property bool busy: false
  property bool setupMode: false       // true ならアカウント設定画面
  property var replyTo: null           // null なら新規投稿
  property var targets: []             // service.postAccounts のスナップショット
  property var selected: ({})          // accountId -> bool
  property var postErrors: ({})        // accountId -> エラーメッセージ

  // IME の未確定文字列(preedit)は input.text に入らないので、本文は必ず
  // これを経由して読む。素の input.text を見ると変換中は「0 文字」になり、
  // そのまま投稿すると未確定分が落ちる。
  readonly property string draft: input.text + input.preeditText
  readonly property int charCount: Array.from(draft).length
  readonly property var charLimit: {
    var limit = null
    for (var i = 0; i < targets.length; i++) {
      var t = targets[i]
      if (!selected[t.id] || t.maxChars === null) continue
      if (limit === null || t.maxChars < limit) limit = t.maxChars
    }
    return limit
  }
  readonly property bool overLimit: charLimit !== null && charCount > charLimit
  readonly property int selectedCount: {
    var n = 0
    for (var id in selected) if (selected[id]) n += 1
    return n
  }
  readonly property bool canSend: !busy && selectedCount > 0 && !overLimit
    && draft.trim().length > 0

  // オーバーレイは menu サーフェスのトークンを共有(omarchy.emojis と同じ流儀)
  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color borderColor: Color.menu.border
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", borderColor, Math.max(1, Style.space(2)))
  readonly property int cornerRadius: Style.cornerRadius
  readonly property string fontFamily: Style.font.menuFamily
  readonly property int contentMargin: Style.spacing.panelPadding

  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") || {} } catch (e) {}

    // {"setup": true} での召喚、またはアカウント未設定ならセットアップ画面を開く
    if (payload.setup === true || (service && service.accounts.length === 0 && !payload.replyTo)) {
      setupMode = true
      replyTo = null
      keyboardHeld = true
      opened = true
      Qt.callLater(function() { contentColumn.forceActiveFocus() })
      return
    }

    prepareCompose(payload)
    keyboardHeld = true
    opened = true
    Qt.callLater(function() { input.forceActiveFocus() })
  }

  function prepareCompose(payload) {
    setupMode = false
    replyTo = (payload.replyTo && typeof payload.replyTo === "object") ? payload.replyTo : null
    targets = service ? service.postAccounts.slice() : []
    postErrors = ({})
    busy = false
    Qt.inputMethod.reset()   // 前回の未確定文字を持ち越さない
    input.text = ""

    // 投稿先の初期値: 返信は元アカウント固定、新規は defaultPostTargets(SPEC §6.1)
    var sel = {}
    if (replyTo) {
      sel[replyTo.accountId] = true
    } else {
      var defaults = service ? service.defaultPostTargets : []
      for (var i = 0; i < targets.length; i++) {
        if (defaults.indexOf(targets[i].id) !== -1) sel[targets[i].id] = true
      }
      if (Object.keys(sel).length === 0 && targets.length === 1) sel[targets[0].id] = true
    }
    selected = sel
  }

  function switchToCompose() {
    prepareCompose({})
    Qt.callLater(function() { input.forceActiveFocus() })
  }

  function switchToSetup() {
    setupMode = true
    Qt.callLater(function() { contentColumn.forceActiveFocus() })
  }

  function close() {
    opened = false
  }

  function dismiss() {
    opened = false
    if (shell && typeof shell.hide === "function")
      shell.hide((manifest && manifest.id) || "io.github.polidog.social-poster")
  }

  function toggleTarget(id) {
    if (replyTo || busy) return
    var next = {}
    for (var k in selected) next[k] = selected[k]
    next[id] = !next[id]
    selected = next
  }

  property bool _committing: false

  function send() {
    if (!canSend || !service) return

    // IME 変換中はその未確定分が input.text に入っていない。先に確定させ、
    // 反映された次のイベントループで送り直す(1 回だけ)。
    if (input.inputMethodComposing && !_committing) {
      _committing = true
      Qt.inputMethod.commit()
      Qt.callLater(function() { root._committing = false; root.send() })
      return
    }
    _committing = false

    var ids = []
    for (var i = 0; i < targets.length; i++)
      if (selected[targets[i].id]) ids.push(targets[i].id)
    if (ids.length === 0) return

    busy = true
    postErrors = ({})
    var text = input.text
    service.post(text, ids, replyTo, function(results) {
      var failed = {}
      var failedCount = 0
      for (var j = 0; j < results.length; j++) {
        if (!results[j].ok) {
          failed[results[j].accountId] = results[j].message
          failedCount += 1
        }
      }
      busy = false
      if (failedCount === 0) {
        // 全成功: 閉じて成功通知(SPEC §6.1)
        service.notify("投稿しました", ids.length > 1 ? ids.length + " アカウントに投稿" : "", false)
        Qt.inputMethod.reset()
        input.text = ""
        root.dismiss()
      } else {
        // 一部失敗: 失敗分を明示して開いたまま・本文保持。
        // 成功したアカウントは選択から外して二重投稿を防ぐ。
        postErrors = failed
        var sel = {}
        for (var k in failed) sel[k] = true
        selected = sel
      }
    })
  }

  PanelWindow {
    id: panel
    visible: root.opened
    // サーフェスは全画面のまま(カードの中央寄せを素直に書けるため)だが、
    // ポインタ入力は下の mask でカードの矩形だけに絞る。オーバーレイを
    // 開いたままブラウザや端末をクリックできる = ノンモーダル。
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-social-poster"
    WlrLayershell.layer: WlrLayer.Overlay
    exclusionMode: ExclusionMode.Ignore

    // 開いている間はキーボードを掴む。Hyprland は OnDemand のレイヤー
    // サーフェスにマップ時のフォーカスを与えないので、途中で OnDemand へ
    // 降格すると refocus が走ってフォーカスごと奪われ、キーイベントが一切
    // 届かなくなる(Esc すら効かない)。他のウィンドウで打ちたいときは
    // Ctrl+Esc / 󰌌 で明示的に手放し、カードをクリックすれば掴み直す。
    WlrLayershell.keyboardFocus: root.opened
      ? (root.keyboardHeld ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.OnDemand)
      : WlrKeyboardFocus.None

    // クリックを受けるのはカードの矩形だけで、外側はクリックスルー。
    // よって「外側クリックで閉じる」は無くなり、閉じるのは Esc / 󰅖 /
    // 投稿完了時のみ。
    // (contentColumn を足しているのは、内容がカード高さを超えて描画された
    // ときにその部分が入力を受け取れなくなるのを防ぐため)
    mask: Region {
      item: card
      Region { item: contentColumn }
    }

    BorderSurface {
      id: card
      width: Math.min(Style.space(440), panel.width - Style.gapsOut * 2)
      height: Math.min(contentColumn.implicitHeight + card.contentTopInset + card.contentBottomInset,
                       panel.height - Style.gapsOut * 2)
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      // 手放したキーボードを掴み直す。下の入力欄・ボタンにもイベントを
      // 通したいので accepted は落とす(この MouseArea は最前面に置く)。
      MouseArea {
        anchors.fill: parent
        z: 1
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        onPressed: function(mouse) {
          root.keyboardHeld = true
          mouse.accepted = false
        }
      }

      Column {
        id: contentColumn
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: card.contentTopInset
        anchors.leftMargin: card.contentLeftInset
        anchors.rightMargin: card.contentRightInset
        spacing: Style.spacing.md

        // フォーカスが入力欄にあっても、未処理の Esc はここまでバブルしてくる
        focus: true
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape && (event.modifiers & Qt.ControlModifier)) {
            root.keyboardHeld = false
            event.accepted = true
          }
        }
        Keys.onEscapePressed: root.dismiss()

        // ---- ヘッダー ----
        Item {
          width: parent.width
          height: Style.space(28)

          Text {
            anchors.left: parent.left
            anchors.right: headerButtons.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.setupMode
              ? "Social Poster セットアップ"
              : (root.replyTo ? "返信 → " + (root.replyTo.authorHandle || "") : "新規投稿")
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
            elide: Text.ElideRight
          }

          Row {
            id: headerButtons
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Button {
              iconText: "󰌌"
              tooltipText: "キーボードを他のウィンドウへ譲る (Ctrl+Esc)"
              visible: root.keyboardHeld
              foreground: root.foreground
              onClicked: root.keyboardHeld = false
            }

            // 設定画面からは閉じ直さずに新規投稿へ戻れるようにする。
            // 投稿先が 1 つも無いうちは戻っても書けないので隠す。
            Button {
              iconText: "󰤌"
              tooltipText: "新規投稿"
              visible: root.setupMode
                && !!root.service && root.service.postAccounts.length > 0
              foreground: root.foreground
              onClicked: root.switchToCompose()
            }

            Button {
              iconText: "󰒓"
              tooltipText: "アカウント設定"
              visible: !root.setupMode
              foreground: root.foreground
              onClicked: root.switchToSetup()
            }

            Button {
              iconText: "󰅖"
              tooltipText: "閉じる (Esc)"
              foreground: root.foreground
              onClicked: root.dismiss()
            }
          }
        }

        // ---- 返信元の引用 ----
        Rectangle {
          width: parent.width
          visible: !root.setupMode && root.replyTo !== null
          height: visible ? quoteText.implicitHeight + Style.space(12) : 0
          radius: root.cornerRadius
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07)

          Text {
            id: quoteText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(8)
            anchors.rightMargin: Style.space(8)
            text: root.replyTo ? String(root.replyTo.excerpt || "").slice(0, 200) : ""
            color: Qt.darker(root.foreground, 1.3)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
            maximumLineCount: 3
            elide: Text.ElideRight
          }
        }

        // ---- 投稿先アカウント(複数チェックでクロスポスト) ----
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: !root.setupMode && root.targets.length === 0

          Text {
            width: parent.width
            text: "投稿できるアカウントがありません。"
            color: Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
          }

          Button {
            text: "アカウントを設定する"
            foreground: root.foreground
            accent: Color.accent
            selected: true
            onClicked: root.switchToSetup()
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(2)
          visible: !root.setupMode

          Repeater {
            model: root.targets

            Item {
              id: targetRow
              required property var modelData
              width: parent.width
              height: Style.space(30)
              opacity: root.replyTo && !root.selected[modelData.id] ? 0.35 : 1.0

              ToggleSwitch {
                id: targetToggle
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                checked: root.selected[targetRow.modelData.id] === true
                interactive: !root.replyTo && !root.busy
                foreground: root.foreground
                onToggled: root.toggleTarget(targetRow.modelData.id)
              }

              Text {
                anchors.left: targetToggle.right
                anchors.leftMargin: Style.space(8)
                anchors.right: limitText.left
                anchors.verticalCenter: parent.verticalCenter
                text: targetRow.modelData.label
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight

                MouseArea {
                  anchors.fill: parent
                  enabled: !root.replyTo && !root.busy
                  onClicked: root.toggleTarget(targetRow.modelData.id)
                }
              }

              Text {
                id: limitText
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: targetRow.modelData.maxChars !== null ? targetRow.modelData.maxChars + "字" : ""
                color: Qt.darker(root.foreground, 1.5)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }

        // ---- 本文 ----
        Rectangle {
          width: parent.width
          visible: !root.setupMode
          height: Style.space(140)
          radius: root.cornerRadius
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)

          Flickable {
            id: inputFlick
            anchors.fill: parent
            anchors.margins: Style.space(8)
            clip: true
            contentWidth: width
            contentHeight: input.implicitHeight
            boundsBehavior: Flickable.StopAtBounds

            function ensureVisible(r) {
              if (contentY >= r.y) contentY = r.y
              else if (contentY + height <= r.y + r.height) contentY = r.y + r.height - height
            }

            TextEdit {
              id: input
              width: inputFlick.width
              height: Math.max(implicitHeight, inputFlick.height)
              text: ""
              color: root.foreground
              selectionColor: Color.menu.selectedBackground
              selectedTextColor: Color.menu.selectedText
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: TextEdit.Wrap
              readOnly: root.busy
              onCursorRectangleChanged: inputFlick.ensureVisible(cursorRectangle)

              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape && (event.modifiers & Qt.ControlModifier)) {
                  root.keyboardHeld = false
                  event.accepted = true
                } else if (event.key === Qt.Key_Escape) {
                  root.dismiss()
                  event.accepted = true
                } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                           && (event.modifiers & Qt.ControlModifier)) {
                  root.send()
                  event.accepted = true
                }
              }

              Text {
                visible: input.text.length === 0 && input.preeditText.length === 0
                text: "いまどうしてる?"
                color: Qt.darker(root.foreground, 1.6)
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }
          }
        }

        // ---- アカウント別エラー(SPEC §8: 投稿失敗は本文保持で明示) ----
        Column {
          width: parent.width
          spacing: Style.space(2)
          visible: !root.setupMode && Object.keys(root.postErrors).length > 0

          Repeater {
            model: Object.keys(root.postErrors)

            Text {
              required property var modelData
              width: parent.width
              text: "󰀪 " + modelData + ": " + root.postErrors[modelData]
              color: Color.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
            }
          }
        }

        // ---- セットアップ画面 ----
        SetupView {
          width: parent.width
          visible: root.setupMode
          service: root.service
          foreground: root.foreground
          fontFamily: root.fontFamily
          onRequestCompose: root.switchToCompose()
        }

        // ---- フッター ----
        Item {
          width: parent.width
          visible: !root.setupMode
          height: Style.space(34)

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.charLimit !== null
              ? "残り " + (root.charLimit - root.charCount)
              : root.charCount + " 文字"
            color: root.overLimit ? Color.urgent : Qt.darker(root.foreground, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: root.overLimit
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            Button {
              text: "キャンセル"
              foreground: root.foreground
              enabled: !root.busy
              onClicked: root.dismiss()
            }

            Button {
              text: root.busy ? "送信中…" : "投稿"
              tooltipText: "Ctrl+Enter"
              foreground: root.foreground
              accent: Color.accent
              selected: root.canSend
              enabled: root.canSend
              opacity: root.canSend ? 1.0 : 0.5
              onClicked: root.send()
            }
          }
        }
      }
    }
  }
}
