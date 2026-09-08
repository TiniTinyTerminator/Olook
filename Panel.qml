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

  // Which mailbox the panel is showing, by account id; "" is all of them.
  // Session-scoped on purpose: the widget opens showing everything.
  property string accountFilter: ""

  readonly property var filteredAccount: {
    if (root.accountFilter === "") return null
    for (var i = 0; i < mail.accounts.length; i++)
      if (String(mail.accounts[i].id) === root.accountFilter) return mail.accounts[i]
    return null
  }

  readonly property var filteredRecent: {
    if (root.accountFilter === "") return mail.recent
    var out = []
    for (var i = 0; i < mail.recent.length; i++)
      if (String(mail.recent[i].account) === root.accountFilter) out.push(mail.recent[i])
    return out
  }

  readonly property var visibleMessages: root.filteredRecent.slice(0, panelMessageCount)

  onAccountFilterChanged: {
    root.messageIndex = 0
    root.ensureCursor()
  }

  // An account can be removed or paused while the panel remembers it.
  Connections {
    target: mail
    function onAccountsChanged() {
      if (root.accountFilter !== "" && !root.filteredAccount) root.accountFilter = ""
    }
  }

  // "" (all inboxes) then each account, wrapping.
  function stepAccountFilter(step) {
    var ids = [""]
    for (var i = 0; i < mail.accounts.length; i++) ids.push(String(mail.accounts[i].id))
    var at = ids.indexOf(root.accountFilter)
    if (at < 0) at = 0
    root.accountFilter = ids[(at + step + ids.length) % ids.length]
  }
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
    // The chip row is horizontal and dx meant nothing here before, so left
    // and right step through the mailboxes.
    if (dx !== 0 && mail.accounts.length > 1) {
      root.stepAccountFilter(dx > 0 ? 1 : -1)
      return
    }
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
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  Service {
    id: mail
    settings: root.settings
    // One syncer per desktop: the other monitors' widgets render the same
    // cache this one fills. It keeps an IDLE connection open per account, so
    // new mail — and its notification — arrives when it arrives.
    pollEnabled: root.isPrimary
    watchEnabled: root.isPrimary

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
    contentHeight: panel.fittedContentHeight(headerColumn.implicitHeight
      + messageColumn.implicitHeight + footerColumn.implicitHeight
      + Style.space(34), Style.space(560))

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

      // Header and footer are pinned: only the message list scrolls, so the
      // account line and the two actions stay where you left them.
      Item {
        id: panelBody
        anchors.fill: parent

        Column {
          id: headerColumn
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          spacing: Style.space(12)

          PanelHero {
            id: hero
            width: parent.width
            title: "Olook"
            meta: {
              if (!mail.configured) return "No account yet"
              if (mail.syncing) return "Checking for mail…"
              // With one mailbox picked, the count should be that mailbox's,
              // not every account's.
              var unread = root.filteredAccount ? (root.filteredAccount.unread || 0)
                                                : mail.unread
              if (unread > 0)
                return unread + (unread === 1 ? " unread message" : " unread messages")
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

          // Pick one mailbox, or all of them. Wraps, so a fourth account
          // does not push the row off the edge of the panel.
          Flow {
            visible: mail.configured && mail.accounts.length > 1
            width: parent.width
            spacing: Style.space(6)

            AccountChip {}

            Repeater {
              model: mail.accounts
              AccountChip {
                required property var modelData
                account: modelData
              }
            }
          }

          PanelSectionHeader {
            visible: mail.configured
            text: root.mailboxLabel()
            foreground: root.foreground
            fontFamily: root.fontFamily
          }
        }

        // The only part that scrolls.
        Flickable {
          id: panelFlick
          anchors.top: headerColumn.bottom
          anchors.topMargin: Style.space(10)
          anchors.bottom: footerColumn.top
          anchors.bottomMargin: Style.space(12)
          anchors.left: parent.left
          anchors.right: parent.right
          contentWidth: width
          contentHeight: messageColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: contentHeight > height

          Column {
            id: messageColumn
            width: panelFlick.width
            spacing: Style.space(4)

            Text {
              textFormat: Text.PlainText
              visible: !!(mail.configured && root.visibleMessages.length === 0)
              width: parent.width
              text: mail.loading ? "Loading…" : "Nothing in this mailbox yet."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

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

          MomentumScroll { view: panelFlick }
        }

        Column {
          id: footerColumn
          anchors.bottom: parent.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          spacing: Style.space(12)

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
    if (root.filteredAccount)
      return String(root.filteredAccount.email || "Inbox").toUpperCase()
    if (mail.accounts.length > 1) return "ALL INBOXES"
    var account = mail.currentAccount
    var label = account ? (account.email || "Inbox") : "Inbox"
    return label.toUpperCase()
  }

  // One mailbox, as an avatar; or "All" for every inbox at once. The address
  // itself is in the tooltip and spelled out in the section header below, so
  // the row stays narrow however long the addresses are.
  component AccountChip: Rectangle {
    id: chip
    property var account: null
    readonly property string accountId: chip.account ? String(chip.account.id) : ""
    readonly property bool current: root.accountFilter === chip.accountId

    width: chip.account ? Style.space(28) : allLabel.implicitWidth + Style.space(18)
    height: Style.space(28)
    radius: height / 2
    color: chip.current ? Util.alpha(Color.accent, 0.22)
      : (chipHover.containsMouse ? Util.alpha(root.foreground, 0.10) : "transparent")
    border.width: 1
    border.color: chip.current ? Util.alpha(Color.accent, 0.65)
                               : Util.alpha(root.foreground, 0.18)

    Text {
      id: allLabel
      textFormat: Text.PlainText
      visible: !chip.account
      anchors.centerIn: parent
      text: "All"
      color: chip.current ? Color.accent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: chip.current
    }

    Rectangle {
      visible: !!chip.account
      anchors.centerIn: parent
      width: Style.space(20)
      height: width
      radius: width / 2
      color: Qt.hsla(Model.avatarHue(chip.account ? chip.account.email : "") / 360,
                     0.45, 0.45, 1.0)

      Text {
        anchors.centerIn: parent
        text: Model.initials(chip.account ? chip.account.name : "",
                             chip.account ? chip.account.email : "")
        color: "white"
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      Rectangle {
        visible: !!(chip.account && chip.account.unread > 0)
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.rightMargin: -Style.space(1)
        anchors.topMargin: -Style.space(1)
        width: Style.space(8)
        height: width
        radius: width / 2
        color: Color.accent
      }
    }

    MouseArea {
      id: chipHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.accountFilter = chip.accountId
    }

    PanelToolTip {
      visible: chipHover.containsMouse
      text: {
        if (!chip.account) return "All inboxes"
        var unread = chip.account.unread || 0
        return String(chip.account.email) + (unread > 0 ? " — " + unread + " unread" : "")
      }
      fontFamily: root.fontFamily
    }
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
