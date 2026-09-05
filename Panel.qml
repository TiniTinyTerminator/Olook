import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar widget: an envelope with the unread count, and a popup with the newest
// mail. Everything heavier — reading, replying, folders — lives in the
// full-window overlay this panel summons.
Panel {
  id: root
  moduleName: "ttt.olook"
  ipcTarget: "ttt.olook"
  manageIpc: false

  property int messageIndex: 0
  property bool cursorActive: false
  property string focusSection: "messages"   // header | messages

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property int panelMessageCount: {
    var value = parseInt(String(setting("panelMessageCount", 8)), 10)
    return isFinite(value) ? Math.max(3, Math.min(20, value)) : 8
  }
  readonly property bool hideWhenRead: setting("unreadOnlyBadge", false) === true

  readonly property var visibleMessages: mail.messages.slice(0, panelMessageCount)
  readonly property bool hasUnread: mail.unread > 0
  readonly property color barIconColor: hasUnread ? barForeground : Qt.darker(barForeground, 1.45)

  // Only one bar instance per monitor should drive the periodic sync and the
  // new-mail notification; the others just render the same cached state.
  readonly property bool isPrimary: {
    if (!bar || typeof bar.moduleWidgets !== "function") return true
    var peers = bar.moduleWidgets(moduleName)
    return !peers || peers.length === 0 || peers[0] === root
  }

  function selectedMessage() {
    if (visibleMessages.length === 0) return null
    return visibleMessages[Math.max(0, Math.min(messageIndex, visibleMessages.length - 1))]
  }

  function ensureCursor() {
    if (visibleMessages.length === 0) {
      focusSection = "header"
      messageIndex = 0
      return
    }
    if (messageIndex >= visibleMessages.length) messageIndex = visibleMessages.length - 1
    if (messageIndex < 0) messageIndex = 0
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    ensureCursor()
    if (dy === 0) return
    if (focusSection === "header") {
      if (dy > 0 && visibleMessages.length > 0) {
        focusSection = "messages"
        messageIndex = 0
      }
      return
    }
    if (dy < 0 && messageIndex === 0) {
      focusSection = "header"
      return
    }
    messageIndex = Math.max(0, Math.min(visibleMessages.length - 1, messageIndex + dy))
  }

  function activateCursor() {
    ensureCursor()
    if (focusSection === "header") openWindow({})
    else openMessage(selectedMessage())
  }

  function openMessage(entry) {
    if (!entry) return
    openWindow({ account: entry.account, folder: entry.folder, uid: entry.uid })
  }

  function openWindow(payload) {
    root.close()
    var target = payload || {}
    if (bar && bar.shell && typeof bar.shell.summon === "function") {
      bar.shell.summon("ttt.olook", JSON.stringify(target))
      return
    }
    // No shell handle (unexpected): fall back to the IPC wrapper on PATH.
    Quickshell.execDetached(["omarchy-shell", "shell", "summon", "ttt.olook",
                             JSON.stringify(target)])
  }

  function compose() { openWindow({ compose: true }) }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  visible: !hideWhenRead || hasUnread || opened

  onOpenedChanged: if (opened) {
    cursorActive = false
    messageIndex = 0
    focusSection = "messages"
    mail.refreshStatus()
    mail.loadMessages()
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  Service {
    id: mail
    settings: root.settings
    // One syncer per desktop: the other monitors' widgets render the same
    // cache this one fills.
    pollEnabled: root.isPrimary

    onNewMail: function (count, message) {
      if (!root.isPrimary || !mail.notifyOnNew || !message) return
      Quickshell.execDetached([
        "notify-send", "--app-name=Mail", "--icon=mail-unread",
        Model.senderLabel(message),
        String(message.subject || "") + (count > 1 ? "\nand " + (count - 1) + " more" : "")
      ])
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function sync(): string { mail.sync(false); return "ok" }
    function unread(): string { return String(mail.unread) }
    function window(): string { root.openWindow({}); return "ok" }
    function compose(): string { root.compose(); return "ok" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        Text {
          id: glyph
          anchors.centerIn: parent
          text: root.hasUnread ? "󰇮" : "󰇮"
          color: root.barIconColor
          font.family: root.fontFamily
          font.pixelSize: Style.bar.iconFont
        }

        // Unread badge, tucked into the glyph's top-right like Outlook's.
        Rectangle {
          visible: root.hasUnread
          anchors.left: glyph.right
          anchors.leftMargin: -Style.space(5)
          anchors.bottom: glyph.top
          anchors.bottomMargin: -Style.space(7)
          height: Style.space(11)
          width: Math.max(height, badgeText.implicitWidth + Style.space(5))
          radius: height / 2
          color: root.urgent

          Text {
            id: badgeText
            anchors.centerIn: parent
            text: Model.badgeText(mail.unread)
            color: Color.background
            font.family: root.fontFamily
            font.pixelSize: Math.max(7, Style.space(8))
            font.bold: true
          }
        }
      }
    }
    onPressed: function (buttonCode) {
      if (buttonCode === Qt.RightButton) mail.sync(false)
      else if (buttonCode === Qt.MiddleButton) root.compose()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function (dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onTextKey: function (text) {
        if (text === "r" || text === "R") mail.sync(false)
        else if (text === "c" || text === "C") root.compose()
        else if (text === "o" || text === "O") root.openWindow({})
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            id: hero
            width: parent.width
            title: "Olook"
            meta: {
              if (!mail.configured) return "No account yet"
              if (mail.syncing) return "Checking for mail…"
              if (mail.unread > 0) return mail.unread + (mail.unread === 1 ? " unread message" : " unread messages")
              return "You're all caught up"
            }
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: "󰇮"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              PanelActionButton {
                iconText: "󰑐"
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: !mail.syncing && mail.configured
                onClicked: mail.sync(false)

                PanelToolTip {
                  visible: parent.containsMouse !== undefined ? parent.containsMouse : false
                  text: "Check for new mail"
                  fontFamily: root.fontFamily
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: mail.error !== "" || mail.notice !== ""
            width: parent.width
            text: mail.notice !== "" ? mail.notice : mail.error
            color: mail.notice !== "" ? root.dim : root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          SetupRow {
            visible: mail.ready && !mail.configured
            width: parent.width
          }

          PanelSeparator {
            visible: mail.configured
            foreground: root.foreground
          }

          Column {
            visible: mail.configured
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: root.mailboxLabel()
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              textFormat: Text.PlainText
              visible: root.visibleMessages.length === 0
              width: parent.width
              text: mail.loading ? "Loading…" : "Nothing in this mailbox yet."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Column {
              id: messageColumn
              width: parent.width
              spacing: Style.space(4)

              Repeater {
                model: root.visibleMessages
                MessageRow {
                  required property var modelData
                  required property int index
                  width: messageColumn.width
                  message: modelData
                  rowIndex: index
                }
              }
            }
          }

          PanelSeparator {
            visible: mail.configured
            foreground: root.foreground
          }

          Row {
            visible: mail.configured
            width: parent.width
            spacing: Style.space(8)

            FooterAction {
              text: "Open Mail"
              glyph: "󰏋"
              onTriggered: root.openWindow({})
            }
            FooterAction {
              text: "New message"
              glyph: "󰝒"
              onTriggered: root.compose()
            }
          }
        }
      }
    }
  }

  function mailboxLabel() {
    var account = mail.currentAccount
    var label = account ? (account.email || "Inbox") : "Inbox"
    return label.toUpperCase()
  }

  component SetupRow: CursorSurface {
    hasCursor: root.cursorActive && root.focusSection === "header"
    foreground: root.foreground
    implicitHeight: setupColumn.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: { root.cursorActive = true; root.focusSection = "header" }
      onClicked: { root.close(); mail.openSetupTerminal() }
    }

    Column {
      id: setupColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(2)

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: "Add a mail account"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: "Gmail, Outlook.com, Microsoft 365, or any IMAP server"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }

  component MessageRow: CursorSurface {
    id: messageRow
    property var message: null
    property int rowIndex: 0

    hasCursor: root.cursorActive && root.focusSection === "messages" && root.messageIndex === rowIndex
    foreground: root.foreground
    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onEntered: {
        root.cursorActive = true
        root.focusSection = "messages"
        root.messageIndex = messageRow.rowIndex
      }
      onClicked: function (mouse) {
        if (mouse.button === Qt.RightButton) mail.toggleRead(messageRow.message)
        else root.openMessage(messageRow.message)
      }
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Rectangle {
        Layout.alignment: Qt.AlignVCenter
        width: Style.space(6)
        height: width
        radius: width / 2
        color: root.urgent
        opacity: messageRow.message && messageRow.message.seen ? 0 : 1
      }

      ColumnLayout {
        id: rowContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: Model.senderLabel(messageRow.message)
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: messageRow.message ? !messageRow.message.seen : false
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            text: messageRow.message ? Model.shortTime(messageRow.message.date, new Date()) : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: messageRow.message ? String(messageRow.message.subject || "(no subject)") : ""
          color: root.foreground
          opacity: messageRow.message && messageRow.message.seen ? 0.75 : 1
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          visible: !!(messageRow.message && String(messageRow.message.preview || "") !== "")
          text: messageRow.message ? String(messageRow.message.preview || "") : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: !!(messageRow.message && messageRow.message.attachments > 0)
        text: "󰏢"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.iconSmall
        Layout.alignment: Qt.AlignVCenter
      }

      Text {
        textFormat: Text.PlainText
        visible: !!(messageRow.message && messageRow.message.flagged)
        text: "󰈻"
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.iconSmall
        Layout.alignment: Qt.AlignVCenter
      }
    }
  }

  component FooterAction: CursorSurface {
    id: footerAction
    property string text: ""
    property string glyph: ""
    signal triggered()

    width: (messageColumn.width - Style.space(8)) / 2
    implicitHeight: footerRow.implicitHeight + Style.spacing.controlPaddingY * 2
    foreground: root.foreground
    bordered: true

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: footerAction.triggered()
    }

    Row {
      id: footerRow
      anchors.centerIn: parent
      spacing: Style.space(6)

      Text {
        text: footerAction.glyph
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.iconSmall
        anchors.verticalCenter: parent.verticalCenter
      }
      Text {
        textFormat: Text.PlainText
        text: footerAction.text
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        anchors.verticalCenter: parent.verticalCenter
      }
    }
  }
}
