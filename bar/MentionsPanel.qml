import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// メンション一覧ポップアップ(SPEC §6.2)。
// サービス保持の統合一覧を表示するだけで、データは一切持たない。
// 行クリックでブラウザ、返信ボタンで返信コンテキスト付きコンポーザー召喚。
// 開いただけでは既読にならず、既読化・削除はヘッダー/行の明示操作で行う。
PopupCard {
  id: root

  property var svc: null
  property int nowMs: Date.now()

  readonly property var problems: svc ? svc.statusSummary() : []
  readonly property var rows: svc ? svc.mentions : []

  contentWidth: fittedContentWidth(Style.space(380))
  contentHeight: fittedContentHeight(column.implicitHeight, Style.space(520))

  onOpenChanged: if (open) nowMs = Date.now()

  function summonComposer(payload) {
    if (!root.bar || !root.bar.shell) return
    root.close()
    root.bar.shell.summon("io.github.polidog.social-poster", JSON.stringify(payload || {}))
  }

  Column {
    id: column
    anchors.fill: parent
    spacing: Style.space(8)

    // 相対時刻の再計算用(PopupCard の contentItem は Item 限定のため Column 内に置く)
    Timer {
      interval: 30000
      repeat: true
      running: root.open
      onTriggered: root.nowMs = Date.now()
    }

    // ---- ヘッダー ----
    Item {
      width: parent.width
      height: Style.space(26)

      Text {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: "メンション" + (root.svc && root.svc.unreadCount > 0 ? "(未読 " + root.svc.unreadCount + ")" : "")
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }

      Row {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(4)

        Button {
          iconText: "󰑐"
          tooltipText: "更新"
          foreground: root.bar.foreground
          iconSpinning: root.svc ? root.svc.refreshing : false
          onClicked: if (root.svc) root.svc.refreshNow()
        }

        Button {
          iconText: "󰄬"
          tooltipText: "すべて既読にする"
          foreground: root.bar.foreground
          visible: root.svc ? root.svc.unreadCount > 0 : false
          onClicked: if (root.svc) root.svc.markAllRead()
        }

        Button {
          iconText: "󰆴"
          tooltipText: "一覧をすべて消す"
          foreground: root.bar.foreground
          visible: root.rows.length > 0
          onClicked: if (root.svc) root.svc.dismissAll()
        }

        Button {
          iconText: "󰤌"
          tooltipText: "新規投稿"
          foreground: root.bar.foreground
          onClicked: root.summonComposer({})
        }

        Button {
          iconText: "󰒓"
          tooltipText: "アカウント設定"
          foreground: root.bar.foreground
          onClicked: root.summonComposer({ setup: true })
        }
      }
    }

    // ---- 設定・接続エラー(SPEC §8: 設定エラーはパネルに表示) ----
    Column {
      width: parent.width
      spacing: Style.space(2)
      visible: root.problems.length > 0

      Repeater {
        model: root.problems

        Text {
          required property var modelData
          width: parent.width
          text: "󰀪 " + modelData
          color: Color.urgent
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }
      }
    }

    PanelSeparator {
      foreground: root.bar.foreground
      visible: root.problems.length > 0
    }

    // ---- 空表示 ----
    Column {
      width: parent.width
      visible: root.rows.length === 0
      spacing: Style.space(8)
      topPadding: Style.space(12)
      bottomPadding: Style.space(12)

      Text {
        width: parent.width
        text: root.svc && root.svc.accountsReady && root.svc.accounts.length > 0
          ? "メンションはまだありません"
          : "アカウントが設定されていません"
        color: Qt.darker(root.bar.foreground, 1.4)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        horizontalAlignment: Text.AlignHCenter
      }

      Button {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: !(root.svc && root.svc.accountsReady && root.svc.accounts.length > 0)
        text: "セットアップを開く"
        foreground: root.bar.foreground
        accent: Color.accent
        selected: true
        onClicked: root.summonComposer({ setup: true })
      }
    }

    // ---- メンション一覧 ----
    Item {
      width: parent.width
      visible: root.rows.length > 0
      implicitHeight: Math.min(mentionColumn.implicitHeight, Style.space(400))
      height: implicitHeight

      Flickable {
        anchors.fill: parent
        clip: true
        contentWidth: width
        contentHeight: mentionColumn.implicitHeight
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: mentionColumn
          width: parent.width
          spacing: Style.space(4)

          Repeater {
            model: root.rows

            BorderSurface {
              id: row
              required property var modelData

              readonly property bool unread: modelData.unread === true

              width: mentionColumn.width
              height: rowInner.implicitHeight + Style.space(12)
              radius: Style.spacing.labelGap
              color: rowMouse.containsMouse
                ? Style.selectedFillFor(root.bar.foreground, Color.accent)
                : "transparent"
              borderSpec: Border.none()

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: row.modelData.url ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: if (root.svc) root.svc.openUrl(row.modelData.url)
              }

              Column {
                id: rowInner
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(8)
                spacing: Style.space(2)

                Item {
                  width: parent.width
                  height: Math.max(metaText.implicitHeight, rowActions.implicitHeight)

                  Text {
                    id: metaText
                    anchors.left: parent.left
                    anchors.right: rowActions.left
                    anchors.rightMargin: Style.space(6)
                    text: (row.unread ? "● " : "")
                      + (row.modelData.author.displayName || row.modelData.author.handle)
                      + " " + row.modelData.author.handle
                      + " · " + row.modelData.providerName
                    color: row.unread ? Color.accent : root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: row.unread
                    elide: Text.ElideRight
                  }

                  Row {
                    id: rowActions
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(2)

                    Button {
                      text: "返信"
                      fontSize: Style.font.caption
                      foreground: root.bar.foreground
                      horizontalPadding: Style.space(6)
                      verticalPadding: Style.space(1)
                      visible: row.modelData.replyContext !== null
                      onClicked: root.summonComposer({
                        replyTo: {
                          accountId: row.modelData.accountId,
                          replyContext: row.modelData.replyContext,
                          authorHandle: row.modelData.author.handle,
                          excerpt: row.modelData.text
                        }
                      })
                    }

                    Button {
                      iconText: "󰅖"
                      iconSize: Style.font.caption
                      tooltipText: "このメンションを消す"
                      foreground: root.bar.foreground
                      horizontalPadding: Style.space(6)
                      verticalPadding: Style.space(1)
                      onClicked: if (root.svc) root.svc.dismissMention(row.modelData.accountId, row.modelData.id)
                    }
                  }
                }

                Text {
                  width: parent.width
                  text: row.modelData.text
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.Wrap
                  maximumLineCount: 3
                  elide: Text.ElideRight
                }

                Text {
                  text: {
                    var t = Date.parse(row.modelData.createdAt)
                    if (isNaN(t)) return ""
                    var diff = Math.max(0, Math.floor((root.nowMs - t) / 1000))
                    if (diff < 60) return "たった今"
                    if (diff < 3600) return Math.floor(diff / 60) + "分前"
                    if (diff < 86400) return Math.floor(diff / 3600) + "時間前"
                    return Math.floor(diff / 86400) + "日前"
                  }
                  color: Qt.darker(root.bar.foreground, 1.5)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }
      }
    }
  }
}
