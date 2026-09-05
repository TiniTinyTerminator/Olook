import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The full mail client: a fullscreen layer-shell overlay laid out the way
// Outlook lays out its window — app rail, folder pane, message list, reading
// pane — using the Omarchy theme's own colors so it belongs to the desktop
// rather than imitating Windows chrome.
Item {
  id: root

  // Injected by the shell when it loads an overlay plugin.
  property var shell: null
  property var manifest: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  property bool opened: false
  property string view: "mail"          // mail | calendar | people
  property string pane: "list"          // folders | list | reader
  property bool composing: false
  property var draft: null
  property string searchText: ""
  property bool searchFocused: false
  property int selectedRow: -1

  readonly property var rows: Model.withGroupHeaders(mail.messages, new Date())
  // The reading pane gives way to the sign-in card when there is no account,
  // or the current one lost its authorization.
  readonly property bool needsSignIn: mail.ready
    && (!mail.configured || (mail.currentAccount && mail.currentAccount.authorized === false))
  readonly property var current: {
    if (selectedRow < 0 || selectedRow >= rows.length) return null
    var row = rows[selectedRow]
    return row && !row.isHeader ? row : null
  }

  // ------------------------------------------------------------- lifecycle

  function open(payloadJson) {
    var payload = Model.parseJson(payloadJson, {}) || {}
    root.opened = true
    root.view = payload.view === "calendar" ? "calendar" : "mail"
    root.composing = false
    root.draft = null

    if (payload.account && payload.account !== mail.accountId) mail.setAccount(payload.account)
    else mail.refreshStatus(true)

    if (payload.folder && payload.folder !== mail.folder) mail.setFolder(payload.folder)
    if (payload.uid) pendingUid = Number(payload.uid)
    if (payload.compose === true) Qt.callLater(function () { root.startCompose(null) })

    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    root.composing = false
    root.searchFocused = false
  }

  function toggle() { root.opened ? root.close() : root.open("{}") }

  property int pendingUid: 0

  // ------------------------------------------------------------ navigation

  function firstMessageRow() {
    for (var i = 0; i < rows.length; i++) if (!rows[i].isHeader) return i
    return -1
  }

  function stepRow(delta) {
    if (rows.length === 0) return
    var index = selectedRow
    if (index < 0) {
      index = firstMessageRow()
      if (index >= 0) selectRow(index)
      return
    }
    var next = index
    for (var guard = 0; guard < rows.length; guard++) {
      next += delta
      if (next < 0 || next >= rows.length) return
      if (!rows[next].isHeader) {
        selectRow(next)
        return
      }
    }
  }

  function selectRow(index) {
    if (index < 0 || index >= rows.length) return
    if (rows[index].isHeader) return
    root.selectedRow = index
    root.pane = "list"
    mail.openMessage(rows[index])
  }

  function selectByUid(uid) {
    for (var i = 0; i < rows.length; i++) {
      if (!rows[i].isHeader && rows[i].uid === uid) {
        selectRow(i)
        return true
      }
    }
    return false
  }

  function setView(next) {
    root.view = next
    if (next === "mail") root.pane = "list"
  }

  // --------------------------------------------------------------- compose

  function startCompose(prefill) {
    root.draft = prefill || { to: [], cc: [], subject: "", body: "",
                              inReplyTo: "", references: "" }
    root.composing = true
    root.view = "mail"
    Qt.callLater(function () { composeForm.focusFirstField() })
  }

  function replyTo(kind) {
    if (!root.current) return
    mail.buildDraft(root.current, kind, function (draft) { root.startCompose(draft) })
  }

  function cancelCompose() {
    root.composing = false
    root.draft = null
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  function sendDraft(draft) {
    mail.send(draft, function (ok) {
      if (ok) root.cancelCompose()
    })
  }

  // ----------------------------------------------------------------- keys

  function handleKey(event) {
    if (event.key === Qt.Key_Escape) {
      if (root.composing) root.cancelCompose()
      else if (root.searchText !== "") { root.searchText = ""; mail.setQuery("") }
      else root.close()
      return true
    }
    if (root.composing || root.searchFocused) return false

    switch (event.key) {
    case Qt.Key_Down: case Qt.Key_J: stepRow(1); return true
    case Qt.Key_Up:   case Qt.Key_K: stepRow(-1); return true
    case Qt.Key_PageDown: stepRow(8); return true
    case Qt.Key_PageUp: stepRow(-8); return true
    case Qt.Key_Home: selectRow(firstMessageRow()); return true
    case Qt.Key_Return: case Qt.Key_Enter:
      if (root.selectedRow < 0) stepRow(1)
      else root.pane = "reader"
      return true
    case Qt.Key_Tab:
      root.pane = root.pane === "folders" ? "list" : (root.pane === "list" ? "reader" : "folders")
      return true
    case Qt.Key_Delete:
      if (root.current) mail.remove(root.current)
      return true
    case Qt.Key_E:
      if (root.current) mail.archive(root.current)
      return true
    case Qt.Key_U:
      if (root.current) mail.toggleRead(root.current)
      return true
    case Qt.Key_S:
      if (root.current) mail.toggleFlagged(root.current)
      return true
    case Qt.Key_R:
      if (root.current) replyTo(event.modifiers & Qt.ShiftModifier ? "reply-all" : "reply")
      return true
    case Qt.Key_A:
      if (root.current) replyTo("reply-all")
      return true
    case Qt.Key_F:
      if (root.current) replyTo("forward")
      return true
    case Qt.Key_C: case Qt.Key_N:
      startCompose(null)
      return true
    case Qt.Key_G:
      mail.sync(false)
      return true
    case Qt.Key_Slash:
      root.searchFocused = true
      Qt.callLater(function () { searchField.forceActiveFocus() })
      return true
    }
    return false
  }

  // ---------------------------------------------------------------- service

  Service {
    id: mail
    listLimit: 300
    // The bar widget polls in the background; the window only needs its own
    // timer while someone is looking at it.
    pollEnabled: root.opened

    onMessagesLoaded: {
      if (root.pendingUid > 0 && root.selectByUid(root.pendingUid)) {
        root.pendingUid = 0
        return
      }
      if (root.selectedRow >= 0 && root.selectedRow < root.rows.length
          && !root.rows[root.selectedRow].isHeader) return
      root.selectedRow = -1
    }
  }

  IpcHandler {
    target: "ttt.olook-window"
    function open(): void { root.open("{}") }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function compose(): string { root.open('{"compose":true}'); return "ok" }
  }

  // ------------------------------------------------------------------ theme

  QtObject {
    id: ui
    readonly property color background: Color.menu.background
    readonly property color surface: Qt.lighter(Color.menu.background, 1.14)
    readonly property color foreground: Color.menu.text
    readonly property color dim: Qt.darker(Color.menu.text, 1.55)
    readonly property color faint: Qt.darker(Color.menu.text, 2.2)
    readonly property color accent: Color.accent
    readonly property color urgent: Color.urgent
    readonly property color border: Util.alpha(Color.menu.text, 0.14)
    readonly property color hover: Util.alpha(Color.menu.text, 0.07)
    readonly property color selected: Util.alpha(Color.accent, 0.16)
    readonly property string fontFamily: Style.font.menuFamily
    readonly property int radius: Style.cornerRadius
  }

  // A real toplevel window, not a layer-shell overlay: a mail client is
  // something you leave open on a workspace and tile beside other work, so
  // Hyprland should treat it like any other application window.
  FloatingWindow {
    id: window
    visible: root.opened
    title: "Olook"
    color: ui.background
    implicitWidth: Style.space(1440)
    implicitHeight: Style.space(900)
    minimumSize: Qt.size(Style.space(820), Style.space(520))

    // The compositor can close or hide the window without going through
    // root.close(); keep our own state in step so the next summon reopens it.
    onVisibleChanged: if (!visible && root.opened) root.opened = false

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function (event) {
        if (root.handleKey(event)) event.accepted = true
      }

      Column {
        anchors.fill: parent
        spacing: 0

        // ------------------------------------------------------ command bar
        Item {
          id: commandBar
          width: parent.width
          height: Style.space(52)

          Row {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(16)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(10)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "󰇮"
              color: ui.accent
              font.family: ui.fontFamily
              font.pixelSize: Style.font.heading
            }

            Text {
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              text: "Olook"
              color: ui.foreground
              font.family: ui.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              text: root.view === "mail" ? "Mail"
                : (root.view === "calendar" ? "Calendar" : "People")
              color: ui.faint
              font.family: ui.fontFamily
              font.pixelSize: Style.font.title
            }
          }

          // Search sits centered, the way Outlook centers its search bar.
          BorderSurface {
            id: searchBox
            anchors.centerIn: parent
            width: Math.min(Style.space(520), commandBar.width * 0.42)
            height: Style.space(30)
            radius: ui.radius
            color: root.searchFocused ? ui.hover : Util.alpha(ui.foreground, 0.04)
            borderSpec: Border.controlSpec(root.searchFocused ? "focus" : "normal",
                                           ui.foreground, ui.accent)

            Text {
              id: searchGlyph
              anchors.left: parent.left
              anchors.leftMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              text: "󰍉"
              color: ui.dim
              font.family: ui.fontFamily
              font.pixelSize: Style.font.iconSmall
            }

            TextInput {
              id: searchField
              anchors.left: searchGlyph.right
              anchors.leftMargin: Style.space(8)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              color: ui.foreground
              selectionColor: Util.alpha(ui.accent, 0.4)
              selectedTextColor: ui.foreground
              font.family: ui.fontFamily
              font.pixelSize: Style.font.body
              clip: true
              text: root.searchText
              onTextChanged: {
                if (text === root.searchText) return
                root.searchText = text
                searchDebounce.restart()
              }
              onActiveFocusChanged: root.searchFocused = activeFocus
              Keys.onEscapePressed: {
                root.searchText = ""
                text = ""
                mail.setQuery("")
                keyCatcher.forceActiveFocus()
              }
              Keys.onReturnPressed: keyCatcher.forceActiveFocus()

              Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: searchField.text === ""
                text: "Search mail"
                color: ui.faint
                font.family: ui.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.IBeamCursor
              onClicked: searchField.forceActiveFocus()
            }
          }

          Row {
            anchors.right: parent.right
            anchors.rightMargin: Style.space(14)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            MailButton {
              glyph: mail.syncing ? "󰑖" : "󰑐"
              tooltip: "Check for new mail  (g)"
              enabled: !mail.syncing
              onTriggered: mail.sync(false)
            }
            MailButton {
              glyph: "󰅖"
              tooltip: "Close  (Esc)"
              onTriggered: root.close()
            }
          }

          Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: 1
            color: ui.border
          }
        }

        // ---------------------------------------------------------- body
        Item {
          width: parent.width
          height: parent.height - commandBar.height - statusBar.height

          Row {
            anchors.fill: parent
            spacing: 0

            MailRail {
              id: rail
              width: Style.space(56)
              height: parent.height
              ui: ui
              view: root.view
              unread: mail.unread
              onViewRequested: function (next) { root.setView(next) }
            }

            MailFolderPane {
              id: folderPane
              width: Style.space(220)
              height: parent.height
              visible: root.view === "mail"
              ui: ui
              service: mail
              active: root.pane === "folders"
              onComposeRequested: root.startCompose(null)
              onFolderChosen: function (name) {
                root.selectedRow = -1
                mail.setFolder(name)
                root.pane = "list"
              }
              onAccountChosen: function (id) {
                root.selectedRow = -1
                mail.setAccount(id)
              }
            }

            MailList {
              id: messageList
              width: Style.space(380)
              height: parent.height
              visible: root.view === "mail"
              ui: ui
              service: mail
              rows: root.rows
              selectedRow: root.selectedRow
              active: root.pane === "list"
              onRowChosen: function (index) { root.selectRow(index) }
              onFilterChosen: function (mode) {
                root.selectedRow = -1
                mail.setFilter(mode)
              }
            }

            Item {
              width: parent.width - rail.width
                - (root.view === "mail" ? folderPane.width + messageList.width : 0)
              height: parent.height

              MailReader {
                anchors.fill: parent
                visible: root.view === "mail" && !root.composing && !root.needsSignIn
                ui: ui
                service: mail
                message: mail.selected
                body: mail.body
                active: root.pane === "reader"
                onReplyRequested: function (kind) { root.replyTo(kind) }
                onArchiveRequested: if (mail.selected) mail.archive(mail.selected)
                onDeleteRequested: if (mail.selected) mail.remove(mail.selected)
                onFlagRequested: if (mail.selected) mail.toggleFlagged(mail.selected)
                onUnreadRequested: if (mail.selected) mail.toggleRead(mail.selected)
                onAttachmentRequested: function (index) {
                  if (mail.selected) mail.saveAttachment(mail.selected, index, true)
                }
              }

              MailCompose {
                id: composeForm
                anchors.fill: parent
                visible: root.view === "mail" && root.composing
                ui: ui
                service: mail
                draft: root.draft
                onSendRequested: function (payload) { root.sendDraft(payload) }
                onCancelRequested: root.cancelCompose()
              }

              MailSignIn {
                anchors.fill: parent
                // Takes over the reading pane whenever there is nothing to
                // read yet: no account at all, or one whose token expired.
                visible: root.view === "mail" && !root.composing && root.needsSignIn
                ui: ui
                service: mail
              }

              MailPlaceholder {
                anchors.fill: parent
                visible: root.view !== "mail"
                ui: ui
                glyph: root.view === "calendar" ? "󰃭" : "󰀓"
                title: root.view === "calendar" ? "Calendar" : "People"
                subtitle: root.view === "calendar"
                  ? "Your calendar lands here next — the mail engine already speaks to the same accounts."
                  : "Contacts from your mail accounts will show up here."
              }
            }
          }
        }

        // ---------------------------------------------------- status bar
        Item {
          id: statusBar
          width: parent.width
          height: Style.space(26)

          Rectangle {
            anchors.top: parent.top
            width: parent.width
            height: 1
            color: ui.border
          }

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.leftMargin: Style.space(16)
            anchors.verticalCenter: parent.verticalCenter
            text: {
              if (mail.error !== "") return mail.error
              if (mail.notice !== "") return mail.notice
              if (mail.syncing) return "Checking for new mail…"
              if (!mail.configured) return "No account configured"
              var total = mail.messages.length
              return total + (total === 1 ? " message" : " messages")
                + (mail.unread > 0 ? ",  " + mail.unread + " unread" : "")
            }
            color: mail.error !== "" ? ui.urgent : ui.dim
            font.family: ui.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            width: Math.max(0, statusBar.width - Style.space(340))
          }

          Text {
            textFormat: Text.PlainText
            anchors.right: parent.right
            anchors.rightMargin: Style.space(16)
            anchors.verticalCenter: parent.verticalCenter
            text: mail.lastSync > 0
              ? "Updated " + Model.shortTime(mail.lastSync, new Date())
              : "Not synced yet"
            color: ui.faint
            font.family: ui.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  Timer {
    id: searchDebounce
    interval: 220
    onTriggered: {
      root.selectedRow = -1
      mail.setQuery(root.searchText)
    }
  }

  // A compact icon button used by the command bar.
  component MailButton: Rectangle {
    id: mailButton
    property string glyph: ""
    property string tooltip: ""
    property bool enabled: true
    signal triggered()

    width: Style.space(30)
    height: Style.space(30)
    radius: ui.radius
    color: hoverArea.containsMouse && mailButton.enabled ? ui.hover : "transparent"

    Text {
      anchors.centerIn: parent
      text: mailButton.glyph
      color: mailButton.enabled ? ui.foreground : ui.faint
      font.family: ui.fontFamily
      font.pixelSize: Style.font.icon
    }

    MouseArea {
      id: hoverArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: mailButton.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: if (mailButton.enabled) mailButton.triggered()
    }

    PanelToolTip {
      visible: hoverArea.containsMouse && mailButton.tooltip !== ""
      text: mailButton.tooltip
      fontFamily: ui.fontFamily
    }
  }
}
