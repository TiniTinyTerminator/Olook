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
  property string view: "mail"          // mail | calendar | people | settings
  property string pane: "list"          // folders | list | reader
  property bool composing: false
  property var draft: null
  property string searchText: ""
  property bool searchFocused: false
  property int selectedRow: -1
  property bool showShortcuts: false

  // ------------------------------------------------------------------ layout
  //
  // Set from the View menu. "auto" lets the window width decide, which is the
  // default; choosing anything else pins it.
  property string folderPanePref: "auto"      // auto | expanded | icons
  property string readingPanePref: "right"    // right | bottom

  // Pane widths the pointer can change. Kept as what was asked for rather
  // than what was granted: a window too narrow to honour the request should
  // give it back when the window grows again, not forget it.
  // Zero means "never dragged": the pane keeps the width it always had until
  // someone asks for a different one.
  property real folderPaneAsked: 0
  property real listAsked: 0
  // The list starts as a share of the space beside it and is pinned to that
  // many pixels as soon as there is a real width to take a share of. After
  // that it is a number, not a proportion, which is the whole point: dragging
  // the folder pane changes what is left over, and a pane still expressed as
  // a share of the leftovers would slide about every time a different edge
  // moved. Only the reading pane gives and takes.
  property bool listPinned: false

  readonly property int folderPaneMin: Style.space(150)
  // Bounded by the row the panes actually live in, not by the plugin root:
  // the root is not the window, and using it made the ceiling 40% of the
  // wrong number and pinned the pane to its floor.
  readonly property int folderPaneMax: Math.max(
    root.folderPaneMin,
    Math.min(Style.space(460), Math.round(bodyRow.width * 0.4)))

  function clamp(value, low, high) {
    return Math.max(low, Math.min(high, value))
  }

  // Three tiers, each one giving up chrome rather than capability. First the
  // folder pane trades its names for icons and tooltips; then the list and the
  // reading pane stop sharing the width and take turns, with a back button.
  readonly property bool foldersCollapsed: root.folderPanePref === "icons"
    || (root.folderPanePref === "auto" && window.width < Style.space(1120))
  readonly property bool stacked: window.width < Style.space(780)
  readonly property bool readerBelow: root.readingPanePref === "bottom" && !root.stacked

  // "Yesterday", "This week" and so on describe a list in date order. Sorted
  // by sender or subject they would be labels over nothing.
  readonly property var rows: mail.sortMode === "date"
    ? Model.withGroupHeaders(mail.messages, new Date())
    : (mail.messages || [])
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

    // A summon naming one message and asking for a popout gets that message
    // in its own window, and the client stays as it was -- closed, or on
    // whatever it was showing. This is how the bar widget opens mail.
    if (payload.popout && payload.uid) {
      root.popOutReader({
        account: payload.account || mail.accountId,
        folder: payload.folder || mail.folder,
        uid: Number(payload.uid),
        subject: payload.subject || "",
        seen: false
      }, null)
      return
    }

    root.opened = true
    root.view = payload.view === "calendar" ? "calendar" : "mail"
    root.composing = false
    root.draft = null

    if (payload.account && payload.account !== mail.accountId) mail.setAccount(payload.account)
    else mail.refreshStatus(true)

    if (payload.folder && payload.folder !== mail.folder) mail.setFolder(payload.folder)
    if (payload.uid) pendingUid = Number(payload.uid)
    // `compose` may be a draft rather than just true, so a bind or a
    // mailto: handler can open the client with the message half written.
    if (payload.compose)
      Qt.callLater(function () {
        root.startCompose(typeof payload.compose === "object" ? payload.compose : null)
      })

    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    root.composing = false
    root.searchFocused = false
    // Transient chrome should not survive a close and be waiting, still open,
    // the next time the window is summoned.
    root.showShortcuts = false
    menuBar.close()
  }

  function toggle() { root.opened ? root.close() : root.open("{}") }

  property int pendingUid: 0

  // ------------------------------------------------------------ selection
  //
  // More than one message at a time, because a mailbox is dealt with in
  // handfuls. Held as the message rows themselves rather than as indices:
  // the list reorders under a sync, and an index would then point at whatever
  // had taken that place.
  property var selection: []

  function rowKey(entry) {
    return entry ? entry.account + "|" + entry.folder + "|" + entry.uid : ""
  }

  readonly property var selectionKeys: {
    var out = []
    for (var i = 0; i < root.selection.length; i++)
      out.push(root.rowKey(root.selection[i]))
    return out
  }

  function clearSelection() { root.selection = [] }

  function toggleSelection(index) {
    var entry = root.rows[index]
    if (!entry || entry.isHeader) return
    var key = root.rowKey(entry)
    var next = []
    var found = false
    for (var i = 0; i < root.selection.length; i++) {
      if (root.rowKey(root.selection[i]) === key) found = true
      else next.push(root.selection[i])
    }
    if (!found) next.push(entry)
    root.selection = next
    root.selectedRow = index
  }

  // Everything between the row last landed on and this one, headers skipped.
  function selectRange(index) {
    var anchor = root.selectedRow >= 0 ? root.selectedRow : index
    var low = Math.min(anchor, index)
    var high = Math.max(anchor, index)
    var next = []
    for (var i = low; i <= high; i++) {
      var entry = root.rows[i]
      if (entry && !entry.isHeader) next.push(entry)
    }
    root.selection = next
    root.selectedRow = index
  }

  // ------------------------------------------------------- move to folder
  //
  // Roles first, then the folders of the account on screen. Roles are offered
  // because a selection made in All mail can span accounts, and "archive"
  // resolves per account where a folder name would only exist on one of them.
  property bool movePickerOpen: false

  readonly property var moveTargets: {
    var out = [
      { name: "archive", label: "Archive", glyph: "\u{f003c}" },
      { name: "junk", label: "Junk Email", glyph: "\u{f0026}" },
      { name: "trash", label: "Deleted Items", glyph: "\u{f01b4}" }
    ]
    var folders = mail.folders || []
    for (var i = 0; i < folders.length; i++) {
      var folder = folders[i]
      if (!folder || folder.special !== "") continue
      out.push({ name: folder.name, label: Model.folderLabel(folder),
                 glyph: "\u{f024b}" })
    }
    return out
  }

  function moveSelectionTo(target) {
    var picked = root.selectionOrCurrent()
    root.movePickerOpen = false
    if (picked.length === 0) return
    mail.moveMany(picked, target)
    root.clearSelection()
  }

  function selectAllRows() {
    var next = []
    for (var i = 0; i < root.rows.length; i++)
      if (root.rows[i] && !root.rows[i].isHeader) next.push(root.rows[i])
    root.selection = next
  }

  function selectionOrCurrent() {
    if (root.selection.length > 0) return root.selection
    return mail.selected ? [mail.selected] : []
  }

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

  // Clicking a row is a request to read it. Side by side that is already true
  // of selecting it; stacked, it has to move the pane.
  function openRow(index) {
    // Opening one message is a fresh start: whatever was ticked before was
    // for an action that has been abandoned.
    root.clearSelection()
    root.selectRow(index)
    if (mail.inDrafts && root.current) {
      root.openStoredDraft(root.current)
      return
    }
    if (root.stacked) root.pane = "reader"
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
    menuBar.close()
    root.view = next
    if (next === "mail") root.pane = "list"
    if (next === "settings") root.composing = false
  }

  function openSettings(addAccount) {
    root.opened = true
    root.setView("settings")
    if (addAccount) Qt.callLater(function () { settingsPane.startAdd() })
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

  // Popped-out compose windows, one per message being written. They are
  // parented to the plugin root rather than the main window, so closing Olook
  // — or sending it to another workspace — leaves a half-written mail alone.
  property var composeWindows: []

  Component {
    id: composeWindowFactory
    MailComposeWindow {}
  }

  // Popped-out messages, one window each. Parented to the plugin root like
  // the compose windows, so closing the client leaves them where they are.
  property var readerWindows: []

  Component {
    id: readerWindowFactory
    MailReaderWindow {}
  }

  function popOutReader(entry, account) {
    if (!entry) return null
    var win = readerWindowFactory.createObject(root, {
      ui: ui,
      service: mail,
      message: entry,
      body: null,
      account: account || mail.accountFor(entry.account),
      showAccount: mail.folder === Model.ALL_FOLDER,
      visible: true
    })
    if (!win) {
      mail.actionFailed("Could not open a message window.")
      return null
    }
    // The window owns its message: fetched separately so the client behind it
    // can go on selecting others without either redrawing the other.
    mail.fetchBody(entry, entry.seen !== true, function (body, summary) {
      win.body = body
      if (summary) win.message = summary
    })
    root.readerWindows.push(win)
    win.dismissed.connect(function () {
      var kept = []
      for (var i = 0; i < root.readerWindows.length; i++)
        if (root.readerWindows[i] !== win) kept.push(root.readerWindows[i])
      root.readerWindows = kept
      Qt.callLater(function () { win.destroy() })
    })
    win.composeRequested.connect(function (kind, message, account) {
      mail.buildDraft(message, kind, function (draft) {
        root.popOutCompose(draft, account)
      })
    })
    return win
  }

  function popOutCompose(prefill, account) {
    var win = composeWindowFactory.createObject(root, {
      ui: ui,
      service: mail,
      draft: prefill || { to: [], cc: [], subject: "", body: "",
                          inReplyTo: "", references: "" },
      account: account || mail.currentAccount,
      visible: true
    })
    if (!win) {
      mail.actionFailed("Could not open a compose window.")
      return null
    }
    root.composeWindows.push(win)
    win.dismissed.connect(function () {
      var kept = []
      for (var i = 0; i < root.composeWindows.length; i++)
        if (root.composeWindows[i] !== win) kept.push(root.composeWindows[i])
      root.composeWindows = kept
      Qt.callLater(function () { win.destroy() })
    })
    return win
  }

  // Moves the message being written inline into a window of its own, keeping
  // every field and the account it was started from.
  function popOutCurrentCompose() {
    if (!root.composing) return
    var payload = composeForm.payload()
    payload.draftUid = composeForm.draftUid
    var account = mail.currentAccount
    // The new window inherits the stored draft, so this form must not write
    // one of its own on the way out.
    composeForm.handOff()
    root.composing = false
    root.draft = null
    root.popOutCompose(payload, account)
  }

  function cancelCompose() {
    // Closing is not discarding any more: whatever was typed goes to the
    // Drafts folder on the way out.
    if (root.composing) composeForm.flush()
    root.composing = false
    root.draft = null
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  function sendDraft(draft) {
    mail.send(draft, function (ok) {
      if (!ok) return
      // The message went out, so the draft has done its job.
      composeForm.discardStored()
      root.cancelCompose()
    })
  }

  // A row in Drafts is a message you were writing; open it where you were
  // writing it. Selection alone still previews, so walking the list with j/k
  // does not throw you into the composer on every keypress.
  function openStoredDraft(entry) {
    mail.openDraft(entry, function (draft) {
      if (draft) root.startCompose(draft)
    })
  }

  // ----------------------------------------------------------------- menus

  readonly property bool hasMessage: root.current !== null

  readonly property var menuModel: [
    { title: "File", items: [
      { id: "compose", label: "New message", glyph: "󰝒", shortcut: "c" },
      { id: "compose-window", label: "New message in its own window",
        glyph: "󰏋", shortcut: "Ctrl+N" },
      { kind: "separator" },
      { id: "add-account", label: "Add an account…", glyph: "󰀓" },
      { id: "settings", label: "Settings", glyph: "󰒓", shortcut: "Ctrl+," },
      { kind: "separator" },
      { id: "refresh", label: "Check for mail", glyph: "󰑐", shortcut: "g" },
      { id: "close", label: "Close window", glyph: "󰅖", shortcut: "Esc" }
    ] },

    { title: "View", items: [
      { kind: "header", label: "Folder pane" },
      { id: "folders-auto", label: "Fit to window", kind: "radio",
        checked: root.folderPanePref === "auto" },
      { id: "folders-expanded", label: "Names", kind: "radio",
        checked: root.folderPanePref === "expanded" },
      { id: "folders-icons", label: "Icons only", kind: "radio",
        checked: root.folderPanePref === "icons" },
      { kind: "separator" },
      { kind: "header", label: "Reading pane" },
      { id: "reader-right", label: "Right", kind: "radio",
        checked: root.readingPanePref === "right", enabled: !root.stacked },
      { id: "reader-bottom", label: "Bottom", kind: "radio",
        checked: root.readingPanePref === "bottom", enabled: !root.stacked },
      { kind: "separator" },
      { id: "conversations", label: "Conversations", kind: "check",
        checked: mail.conversationMode },
      { kind: "separator" },

      { kind: "header", label: "Sort by" },
      { id: "sort-date", label: "Date", kind: "radio",
        checked: mail.sortMode === "date" },
      { id: "sort-sender", label: "Sender", kind: "radio",
        checked: mail.sortMode === "sender" },
      { id: "sort-subject", label: "Subject", kind: "radio",
        checked: mail.sortMode === "subject" },
      { id: "sort-size", label: "Size", kind: "radio",
        checked: mail.sortMode === "size" },
      { id: "sort-unread", label: "Unread first", kind: "radio",
        checked: mail.sortMode === "unread" },
      { kind: "separator" },

      { kind: "header", label: "Message body" },
      { id: "body-formatted", label: "Formatted", kind: "radio",
        checked: readerPane.formatted, enabled: readerPane.hasRich },
      { id: "body-plain", label: "Plain text", kind: "radio",
        checked: !readerPane.formatted, enabled: readerPane.hasRich }
    ] },

    { title: "Message", items: [
      { id: "reply", label: "Reply", glyph: "󰑚", shortcut: "r", enabled: root.hasMessage },
      { id: "reply-all", label: "Reply all", glyph: "󰑛", shortcut: "a", enabled: root.hasMessage },
      { id: "forward", label: "Forward", glyph: "󰒭", shortcut: "f", enabled: root.hasMessage },
      { kind: "separator" },
      { id: "move", label: "Move to folder…", glyph: "󰉒", shortcut: "v",
        enabled: root.hasMessage || root.selection.length > 0 },
      { id: "archive", label: "Archive", glyph: "󰇠", shortcut: "e", enabled: root.hasMessage },
      { id: "delete", label: "Delete", glyph: "󰩹", shortcut: "Del", enabled: root.hasMessage },
      { kind: "separator" },
      { id: "flag", glyph: "󰈻", shortcut: "s", enabled: root.hasMessage,
        label: root.current && root.current.flagged ? "Remove flag" : "Flag" },
      { id: "unread", glyph: "󰇮", shortcut: "u", enabled: root.hasMessage,
        label: root.current && root.current.seen ? "Mark unread" : "Mark read" },
      { kind: "separator" },
      { id: "select-all", label: "Select all", glyph: "󰒆", shortcut: "Ctrl+A",
        enabled: root.rows.length > 0 },
      { id: "mark-all-read", label: "Mark everything here as read", glyph: "󰇮",
        enabled: mail.unread > 0 },
      { kind: "separator" },
      { id: "undo", glyph: "󰕌", shortcut: "Ctrl+Z",
        enabled: mail.canUndo,
        label: mail.undoLabel === "" ? "Undo" : "Undo " + mail.undoLabel }
    ] },

    { title: "Help", items: [
      { id: "shortcuts", label: "Keyboard shortcuts", glyph: "󰌌", shortcut: "?" }
    ] }
  ]

  function runMenu(id) {
    switch (id) {
    case "compose": root.startCompose(null); return
    case "compose-window": root.popOutCompose(null, null); return
    case "add-account": root.openSettings(true); return
    case "settings": root.openSettings(false); return
    case "refresh": mail.sync(false); return
    case "close": root.close(); return

    case "move": root.movePickerOpen = true; return
    case "select-all": root.selectAllRows(); return
    case "mark-all-read": mail.markVisibleRead(); root.clearSelection(); return
    case "undo": mail.undoLast(); return

    case "conversations": mail.setConversations(!mail.conversationMode); return
    case "sort-date": mail.setSort("date"); return
    case "sort-sender": mail.setSort("sender"); return
    case "sort-subject": mail.setSort("subject"); return
    case "sort-size": mail.setSort("size"); return
    case "sort-unread": mail.setSort("unread"); return

    case "folders-auto": root.folderPanePref = "auto"; return
    case "folders-expanded": root.folderPanePref = "expanded"; return
    case "folders-icons": root.folderPanePref = "icons"; return
    case "reader-right": root.readingPanePref = "right"; return
    case "reader-bottom": root.readingPanePref = "bottom"; return
    case "body-formatted": readerPane.formatted = true; return
    case "body-plain": readerPane.formatted = false; return

    case "reply": case "reply-all": case "forward": root.replyTo(id); return
    case "archive": if (mail.selected) mail.archive(mail.selected); return
    case "delete": if (mail.selected) mail.remove(mail.selected); return
    case "flag": if (mail.selected) mail.toggleFlagged(mail.selected); return
    case "unread": if (mail.selected) mail.toggleRead(mail.selected); return

    case "shortcuts": root.showShortcuts = !root.showShortcuts; return
    }
  }

  // ----------------------------------------------------------------- keys

  function handleKey(event) {
    if (event.key === Qt.Key_Escape) {
      if (root.movePickerOpen) root.movePickerOpen = false
      else if (root.showShortcuts) root.showShortcuts = false
      else if (menuBar.menuOpen) menuBar.close()
      else if (root.composing) root.cancelCompose()
      // Stacked, the reading pane is covering the list; Escape steps back to
      // it before it starts closing things.
      else if (root.stacked && root.pane === "reader") root.pane = "list"
      else if (root.searchText !== "") { root.searchText = ""; mail.setQuery("") }
      else root.close()
      return true
    }
    // An open menu owns the keyboard until it is done.
    if (menuBar.menuOpen) {
      switch (event.key) {
      case Qt.Key_Left:  menuBar.stepMenu(-1); return true
      case Qt.Key_Right: menuBar.stepMenu(1); return true
      case Qt.Key_Down: case Qt.Key_J: menuBar.stepRow(1); return true
      case Qt.Key_Up: case Qt.Key_K: menuBar.stepRow(-1); return true
      case Qt.Key_Return: case Qt.Key_Enter: menuBar.activateHighlighted(); return true
      }
      menuBar.close()
      return true
    }
    // F10 is the menu bar key everywhere else; a client you drive from the
    // keyboard should not hide its menus behind the mouse.
    if (event.key === Qt.Key_F10) {
      menuBar.openMenu(0)
      return true
    }
    if (root.showShortcuts && !root.composing) {
      root.showShortcuts = false
      return true
    }
    // Pop-out is the one shortcut that has to work while a message is being
    // written; every other key belongs to the field with focus.
    if (root.composing) {
      if (event.key === Qt.Key_O && (event.modifiers & Qt.ControlModifier)
          && (event.modifiers & Qt.ShiftModifier)) {
        root.popOutCurrentCompose()
        return true
      }
      return false
    }
    if (root.searchFocused) return false

    switch (event.key) {
    case Qt.Key_Down: case Qt.Key_J: stepRow(1); return true
    case Qt.Key_Up:   case Qt.Key_K: stepRow(-1); return true
    case Qt.Key_PageDown: stepRow(8); return true
    case Qt.Key_PageUp: stepRow(-8); return true
    case Qt.Key_Home: selectRow(firstMessageRow()); return true
    case Qt.Key_Return: case Qt.Key_Enter:
      if (root.selectedRow < 0) stepRow(1)
      else if (mail.inDrafts && root.current) root.openStoredDraft(root.current)
      else root.pane = "reader"
      return true
    case Qt.Key_Question:
      root.showShortcuts = !root.showShortcuts
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
      if (event.modifiers & Qt.ControlModifier) popOutCompose(null, null)
      else startCompose(null)
      return true
    case Qt.Key_Comma:
      if (event.modifiers & Qt.ControlModifier) root.openSettings(false)
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
    // timer while someone is looking at it — and while it is open it holds an
    // IDLE connection instead, which stands the timer down entirely.
    pollEnabled: root.opened
    watchEnabled: root.opened

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
    // Same, but with the message already half written — `{"to": [...],
    // "subject": ..., "body": ..., "format": ..., "attachments": [...]}` —
    // which is what a mailto: handler or a "mail this file" script wants.
    function composeWith(draftJson: string): string {
      root.open(JSON.stringify({ compose: Model.parseJson(draftJson, {}) || {} }))
      return "ok"
    }
    // A compose window on its own, without dragging the whole client along.
    function newMessage(): string { root.popOutCompose(null, null); return "ok" }
    // Moves the message being written inline into its own window, for a
    // Hyprland bind that does what the compose header's pop-out button does.
    function popOut(): string { root.popOutCurrentCompose(); return "ok" }
    function settings(): string { root.openSettings(false); return "ok" }
    function addAccount(): string { root.openSettings(true); return "ok" }
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
    minimumSize: Qt.size(Style.space(520), Style.space(400))

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
            id: brandGroup
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
              // First thing to go when the window narrows: the rail already
              // says which view you are in.
              visible: window.width >= Style.space(820)
              anchors.verticalCenter: parent.verticalCenter
              text: {
                switch (root.view) {
                case "mail": return "Mail"
                case "calendar": return "Calendar"
                case "settings": return "Settings"
                default: return "People"
                }
              }
              color: ui.faint
              font.family: ui.fontFamily
              font.pixelSize: Style.font.title
            }
          }

          // Search sits centered, the way Outlook centers its search bar.
          BorderSurface {
            id: searchBox
            // Centred, but never into the groups either side of it — that
            // overlap is what made a narrow window look broken.
            readonly property real room: commandBar.width - brandGroup.width
              - actionGroup.width - Style.space(56)
            visible: root.view === "mail" && room >= Style.space(150)
            anchors.centerIn: parent
            width: Math.min(Style.space(520), Math.max(Style.space(150), room))
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
                // The refiners are only useful if they are discoverable, and
                // the placeholder is the only place to say so without
                // spending a panel on it the way Outlook does.
                text: "Search mail — try from:, subject:, is:unread, has:attachment"
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
            id: actionGroup
            anchors.right: parent.right
            anchors.rightMargin: Style.space(14)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            MailButton {
              glyph: "󰏋"
              tooltip: "New message in its own window  (Ctrl+N)"
              onTriggered: root.popOutCompose(null, null)
            }
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

        // ------------------------------------------------------- menu bar
        //
        // Above the panes, so its popups paint over them: children of a
        // Column are drawn in order, and z lifts this one over the rest.
        MailMenuBar {
          id: menuBar
          width: parent.width
          z: 50
          ui: ui
          menus: root.menuModel
          onTriggered: function (id) { root.runMenu(id) }
        }

        // ---------------------------------------------------------- body
        Item {
          width: parent.width
          height: parent.height - commandBar.height - menuBar.height - statusBar.height

          Row {
            id: bodyRow
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
              onSettingsRequested: root.openSettings(false)
            }

            MailFolderPane {
              id: folderPane
              width: root.foldersCollapsed
                ? Style.space(50)
                : root.clamp(root.folderPaneAsked > 0 ? root.folderPaneAsked
                                                      : Style.space(220),
                             root.folderPaneMin, root.folderPaneMax)
              height: parent.height
              visible: root.view === "mail"
              collapsed: root.foldersCollapsed
              ui: ui
              service: mail
              active: root.pane === "folders"
              onComposeRequested: root.startCompose(null)
              onFolderChosen: function (accountId, name) {
                root.selectedRow = -1
                mail.openFolder(accountId, name)
                root.pane = "list"
              }
            }

            PaneSplitter {
              id: folderSplit
              height: parent.height
              visible: folderPane.visible && !root.foldersCollapsed
              ui: ui
              onMoved: function (delta) {
                root.folderPaneAsked = root.clamp(folderPane.width + delta,
                                                  root.folderPaneMin,
                                                  root.folderPaneMax)
              }
            }

            // The list and the reading pane share what is left. They sit side
            // by side, or stacked top and bottom, or — in a window too narrow
            // for either — take turns, which is why they are placed by hand
            // rather than dropped into another Row.
            Item {
              id: mainArea
              width: parent.width - rail.width
                - (folderPane.visible ? folderPane.width : 0)
                - (folderSplit.visible ? folderSplit.width : 0)
              height: parent.height

              readonly property bool split: root.view === "mail"
              readonly property bool sideBySide: split && !root.stacked && !root.readerBelow
              readonly property bool topBottom: split && !root.stacked && root.readerBelow

              readonly property int listMin: Style.space(200)
              readonly property int listMax: Math.max(
                mainArea.listMin, Math.round(mainArea.width * 0.7))
              readonly property int listW: {
                if (!mainArea.split) return 0
                if (!mainArea.sideBySide) return mainArea.width
                var wanted = root.listAsked > 0 ? root.listAsked
                  : Math.min(Style.space(400), Math.round(mainArea.width * 0.36))
                return root.clamp(wanted, mainArea.listMin, mainArea.listMax)
              }

              onWidthChanged: mainArea.pinList()

              function pinList() {
                if (root.listPinned || mainArea.width <= 0)
                  return
                root.listAsked = Math.min(Style.space(400),
                                          Math.round(mainArea.width * 0.36))
                root.listPinned = true
              }

              Component.onCompleted: mainArea.pinList()
              readonly property int listH: {
                if (!mainArea.split) return 0
                if (!mainArea.topBottom) return mainArea.height
                return Math.max(Style.space(150), Math.round(mainArea.height * 0.42))
              }

              MailList {
                id: messageList
                selectedKeys: root.selectionKeys
                onRowToggled: function (index) { root.toggleSelection(index) }
                onRowRanged: function (index) { root.selectRange(index) }
                onSelectionCleared: root.clearSelection()
                onBulkRequested: function (action) {
                  var picked = root.selectionOrCurrent()
                  if (picked.length === 0) return
                  if (action === "move") { root.movePickerOpen = true; return }
                  if (action === "archive") mail.moveMany(picked, "archive")
                  else if (action === "delete") mail.removeMany(picked)
                  else if (action === "read") mail.setFlagMany(picked, "seen")
                  else if (action === "unread") mail.setFlagMany(picked, "unseen")
                  else if (action === "flag") mail.setFlagMany(picked, "flagged")
                  else if (action === "all-read") mail.markVisibleRead()
                  root.clearSelection()
                }
                x: 0
                y: 0
                width: mainArea.listW
                height: mainArea.listH
                visible: mainArea.split && !(root.stacked && root.pane === "reader")
                edge: mainArea.sideBySide
                ui: ui
                service: mail
                rows: root.rows
                selectedRow: root.selectedRow
                active: root.pane === "list"
                onRowChosen: function (index) { root.openRow(index) }
                onFilterChosen: function (mode) {
                  root.selectedRow = -1
                  mail.setFilter(mode)
                }
              }

              PaneSplitter {
                id: listSplit
                x: mainArea.listW
                height: mainArea.height
                visible: mainArea.sideBySide && messageList.visible
                ui: ui
                onMoved: function (delta) {
                  root.listAsked = root.clamp(mainArea.listW + delta,
                                              mainArea.listMin, mainArea.listMax)
                }
              }

              Rectangle {
                visible: mainArea.topBottom
                y: mainArea.listH
                width: mainArea.width
                height: 1
                color: ui.border
              }

              Item {
                id: readerArea
                x: mainArea.sideBySide ? mainArea.listW + listSplit.width : 0
                y: mainArea.topBottom ? mainArea.listH : 0
                width: mainArea.sideBySide
                  ? mainArea.width - mainArea.listW - listSplit.width
                  : mainArea.width
                height: mainArea.topBottom ? mainArea.height - mainArea.listH : mainArea.height
                visible: !(mainArea.split && root.stacked && root.pane !== "reader")

                MailReader {
                  id: readerPane
                  anchors.fill: parent
                  compact: readerArea.width < Style.space(560)
                  showBack: root.stacked
                  onBackRequested: root.pane = "list"
                  visible: root.view === "mail" && !root.composing && !root.needsSignIn
                  ui: ui
                  service: mail
                  // In the All folder the reader says which mailbox the
                  // message arrived on, because that is the address a reply
                  // leaves from.
                  account: mail.accountFor(mail.selected ? mail.selected.account : "")
                  showAccount: mail.viewingAll
                  message: mail.selected
                  body: mail.body
                  active: root.pane === "reader"
                  onReplyRequested: function (kind) { root.replyTo(kind) }
                  onArchiveRequested: if (mail.selected) mail.archive(mail.selected)
                  onDeleteRequested: if (mail.selected) mail.remove(mail.selected)
                  onFlagRequested: if (mail.selected) mail.toggleFlagged(mail.selected)
                  onUnreadRequested: if (mail.selected) mail.toggleRead(mail.selected)
                  onShowImagesRequested: mail.loadRemoteImages()
                  onPopOutRequested: if (mail.selected) root.popOutReader(mail.selected, null)
                  onThreadMessageRequested: function (entry) { mail.openMessage(entry) }
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
                  onPopOutRequested: root.popOutCurrentCompose()
                }

                MailSignIn {
                  anchors.fill: parent
                  // Takes over the reading pane whenever there is nothing to
                  // read yet: no account at all, or one whose token expired.
                  visible: root.view === "mail" && !root.composing && root.needsSignIn
                  ui: ui
                  service: mail
                  onAddAccountRequested: root.openSettings(true)
                }

                MailSettings {
                  id: settingsPane
                  anchors.fill: parent
                  visible: root.view === "settings"
                  ui: ui
                  service: mail
                  // A freshly added account should land you in its inbox.
                  onAccountOpened: function (accountId) {
                    root.setView("mail")
                    mail.setAccount(accountId)
                  }
                }

                MailContacts {
                  anchors.fill: parent
                  visible: root.view === "people"
                  ui: ui
                  service: mail

                  onComposeRequested: function (address) {
                    root.popOutCompose({ to: [address], cc: [], subject: "",
                                         body: "", inReplyTo: "", references: "" },
                                       mail.currentAccount)
                  }
                  // Everything exchanged with this person, in the mail view.
                  onMailRequested: function (address) {
                    root.setView("mail")
                    root.searchText = address
                    mail.setQuery(address)
                  }
                }

                MailPlaceholder {
                  anchors.fill: parent
                  visible: root.view === "calendar"
                  ui: ui
                  glyph: "󰃭"
                  title: "Calendar"
                  subtitle: "Your calendar lands here next — the mail engine already speaks to the same accounts."
                }
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
      MailShortcuts {
        anchors.fill: parent
        visible: root.showShortcuts
        z: 200
        ui: ui
        onDismissed: root.showShortcuts = false
      }

      // Move to folder. A short list in the middle rather than a menu hung
      // off a button: it is opened from the menu, from the keyboard and from
      // a selection in the list, and those have no single button to hang from.
      Item {
        anchors.fill: parent
        visible: root.movePickerOpen
        z: 210

        MouseArea {
          anchors.fill: parent
          onClicked: root.movePickerOpen = false
        }

        Rectangle {
          anchors.centerIn: parent
          width: Style.space(320)
          height: Math.min(parent.height - Style.space(80),
                           targetColumn.implicitHeight + Style.space(52))
          radius: ui.radius
          color: ui.surface
          border.width: 1
          border.color: ui.border

          Text {
            id: pickerTitle
            textFormat: Text.PlainText
            anchors.top: parent.top
            anchors.topMargin: Style.space(14)
            anchors.left: parent.left
            anchors.leftMargin: Style.space(16)
            text: root.selection.length > 1
              ? "Move " + root.selection.length + " messages to" : "Move to"
            color: ui.foreground
            font.family: ui.fontFamily
            font.pixelSize: Style.font.subtitle
          }

          Flickable {
            id: targetFlick
            anchors.top: pickerTitle.bottom
            anchors.topMargin: Style.space(10)
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: Style.space(8)
            contentWidth: width
            contentHeight: targetColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
              id: targetColumn
              width: targetFlick.width

              Repeater {
                model: root.moveTargets

                Rectangle {
                  required property var modelData
                  width: targetColumn.width
                  height: Style.space(30)
                  radius: ui.radius
                  color: targetHover.containsMouse ? ui.hover : "transparent"

                  Row {
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(10)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(8)

                    Text {
                      text: modelData.glyph
                      color: ui.dim
                      font.family: ui.fontFamily
                      font.pixelSize: Style.font.iconSmall
                    }

                    Text {
                      textFormat: Text.PlainText
                      text: modelData.label
                      color: ui.foreground
                      font.family: ui.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                  }

                  MouseArea {
                    id: targetHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.moveSelectionTo(modelData.name)
                  }
                }
              }
            }

            MomentumScroll { view: targetFlick }
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
