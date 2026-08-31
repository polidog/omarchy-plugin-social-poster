import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// バーのピル: アイコン + 未読バッジ(SPEC §6.2)。
// 左クリック: メンション一覧をトグル / 中クリック: 手動リフレッシュ /
// 右クリック: コンポーザー召喚。
BarWidget {
  id: root
  moduleName: "io.github.polidog.social-poster"

  readonly property var svc: bar && bar.shell ? bar.shell.serviceFor("io.github.polidog.social-poster") : null
  readonly property int unread: svc ? svc.unreadCount : 0
  // accountStatus はマップごと再代入されるのでバインディングが追従する
  readonly property bool degraded: svc ? _computeDegraded(svc.accountStatus) : false
  readonly property bool hasProblems: svc
    ? (svc.accountsProblem !== "" || svc.configErrors.length > 0 || _computeProblem(svc.accountStatus))
    : false

  property bool popupOpen: false

  function close() { popupOpen = false }

  function _computeDegraded(status) {
    for (var id in status) if (status[id].state === "network") return true
    return false
  }

  function _computeProblem(status) {
    for (var id in status) {
      var s = status[id].state
      if (s === "auth" || s === "config" || s === "paused") return true
    }
    return false
  }

  implicitWidth: content.implicitWidth + Style.space(14)
  implicitHeight: barSize

  Row {
    id: content
    anchors.centerIn: parent
    spacing: Style.space(4)

    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: "󰍥"
      // ネットワーク不通時は淡色化(SPEC §8)
      color: root.degraded ? Qt.darker(root.bar.barForeground, 1.8) : root.bar.barForeground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.icon
      Behavior on color {
        enabled: !root.bar || root.bar.foregroundAnimationEnabled
        ColorAnimation { duration: 160 }
      }
    }

    // 未読バッジ: 0 件ならアイコンのみ
    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      visible: root.unread > 0
      width: Math.max(height, badgeText.implicitWidth + Style.space(8))
      height: badgeText.implicitHeight + Style.space(2)
      radius: height / 2
      color: Color.accent

      Text {
        id: badgeText
        anchors.centerIn: parent
        text: root.unread > 99 ? "99+" : String(root.unread)
        color: root.bar ? root.bar.background : Color.background
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }

    // 設定・認証エラーの印
    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: root.hasProblems
      text: "󰀪"
      color: Color.urgent
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

    onClicked: function(mouse) {
      if (mouse.button === Qt.MiddleButton) {
        if (root.svc) root.svc.refreshNow()
      } else if (mouse.button === Qt.RightButton) {
        if (root.bar && root.bar.shell) root.bar.shell.summon("io.github.polidog.social-poster", "{}")
      } else {
        root.popupOpen = !root.popupOpen
      }
    }
    onEntered: {
      if (!root.bar) return
      var problems = root.svc ? root.svc.statusSummary() : []
      var tip = problems.length > 0
        ? problems.join("\n")
        : (root.unread > 0 ? "未読メンション " + root.unread + " 件" : "Social Poster")
      root.bar.showTooltip(root, tip)
    }
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  MentionsPanel {
    id: panel
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    svc: root.svc

    // パネルを閉じたタイミングで既読化(SPEC §6.2)
    onOpenChanged: {
      if (!open && root.svc && root.svc.unreadCount > 0) root.svc.markAllRead()
    }
  }
}
