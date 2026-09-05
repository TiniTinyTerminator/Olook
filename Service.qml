import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Bridge between the QML surfaces and the `olook` engine.
//
// Every call is a short-lived subprocess that prints one JSON object. Reads
// (list, status, body) come straight out of the local SQLite cache and return
// in a few milliseconds; only `sync` and the write actions touch the network,
// and those report through `syncing` / `busy` so the UI can show it.
Item {
  id: root

  property var settings: ({})

  // The plugin directory ships the engine next to the QML, so the same
  // checkout works whether it was installed by `omarchy plugin add`, symlinked
  // from a working copy, or copied in by hand.
  readonly property string cliPath: Qt.resolvedUrl("bin/olook").toString().replace(/^file:\/\//, "")

  property var accounts: []
  property string accountId: ""
  property var folders: []
  property string folder: "INBOX"
  property var messages: []
  property var selected: null
  property var body: null
  property int unread: 0
  property int lastSync: 0
  property bool configured: false
  property bool ready: false

  property bool syncing: false
  property bool loading: false
  property bool busy: false
  property string error: ""
  property string notice: ""

  // Background polling is opt-out: the bar widget on the primary monitor owns
  // it, and every other surface reads the cache the sync fills.
  property bool pollEnabled: true

  property string filter: "all"     // all | unread | flagged
  property string query: ""
  property int listLimit: 200

  readonly property int syncIntervalSec: {
    var value = parseInt(String(setting("syncIntervalSec", 180)), 10)
    if (!isFinite(value)) value = 180
    return Math.max(30, Math.min(3600, value))
  }
  readonly property bool notifyOnNew: setting("notify", true) !== false

  readonly property var currentAccount: {
    for (var i = 0; i < accounts.length; i++)
      if (accounts[i].id === accountId) return accounts[i]
    return accounts.length > 0 ? accounts[0] : null
  }
  readonly property var currentFolder: {
    for (var i = 0; i < folders.length; i++)
      if (folders[i].name === folder) return folders[i]
    return null
  }

  signal newMail(int count, var message)
  signal messagesLoaded()
  signal bodyLoaded()
  signal actionFailed(string text)
  signal sent()

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  // ------------------------------------------------------------------ runner

  Component {
    id: cliRunner

    Process {
      id: proc
      property var handler: null
      property string label: ""
      running: false
      stdout: StdioCollector { id: outCollector; waitForEnd: true }
      stderr: StdioCollector { id: errCollector; waitForEnd: true }
      onExited: function (exitCode) {
        var payload = Model.parseJson(outCollector.text, null)
        if (proc.handler) {
          proc.handler(exitCode === 0 && payload && payload.ok !== false,
                       payload, String(errCollector.text || ""))
        }
        Qt.callLater(function () { proc.destroy() })
      }
    }
  }

  function run(args, handler, label) {
    if (!cliPath || cliPath.indexOf("bin/olook") === -1) {
      root.error = "Mail engine not found next to the plugin."
      return null
    }
    var command = [cliPath, "--json"].concat(args)
    var process = cliRunner.createObject(root, {
      command: command, handler: handler, label: label || ""
    })
    if (!process) {
      root.error = "Could not start the mail engine."
      return null
    }
    process.running = true
    return process
  }

  function accountArgs(extra) {
    var args = extra.slice()
    if (root.accountId) args = args.concat(["--account", root.accountId])
    return args
  }

  function reportFailure(payload, stderrText, fallback) {
    var text = payload && payload.error ? String(payload.error)
      : (String(stderrText || "").trim() || fallback)
    root.error = text
    root.actionFailed(text)
  }

  // ------------------------------------------------------------------ status

  function refreshStatus(thenLoad) {
    run(["status", "--limit", "12"], function (ok, payload) {
      if (!ok || !payload) return
      var previousUnread = root.unread
      var hadAccounts = root.accounts.length > 0

      root.accounts = payload.accounts || []
      root.configured = payload.configured === true
      root.unread = payload.unread || 0
      root.lastSync = payload.lastSync || 0
      root.ready = true

      if (!root.accountId && root.accounts.length > 0) root.accountId = root.accounts[0].id

      if (hadAccounts && root.unread > previousUnread) {
        var newest = (payload.messages || [])[0] || null
        root.newMail(root.unread - previousUnread, newest)
      }
      if (thenLoad) root.loadFolders()
    }, "status")
  }

  // ----------------------------------------------------------------- folders

  function loadFolders(refresh) {
    if (!root.accountId) return
    var args = accountArgs(["folders"])
    if (refresh) args.push("--refresh")
    run(args, function (ok, payload) {
      if (!ok || !payload) return
      root.folders = payload.folders || []
      if (root.folders.length > 0) {
        var found = false
        for (var i = 0; i < root.folders.length; i++)
          if (root.folders[i].name === root.folder) found = true
        if (!found) root.folder = root.folders[0].name
      }
      root.loadMessages()
    }, "folders")
  }

  function setAccount(id) {
    if (!id || id === root.accountId) return
    root.accountId = id
    root.selected = null
    root.body = null
    root.folder = "INBOX"
    root.messages = []
    loadFolders()
  }

  function setFolder(name) {
    if (!name || name === root.folder) return
    root.folder = name
    root.selected = null
    root.body = null
    loadMessages()
  }

  function setFilter(mode) {
    if (mode === root.filter) return
    root.filter = mode
    loadMessages()
  }

  function setQuery(text) {
    root.query = String(text || "")
    loadMessages()
  }

  // ---------------------------------------------------------------- messages

  function loadMessages() {
    if (!root.accountId) return
    root.loading = true
    var args = accountArgs(["list", "--folder", root.folder,
                            "--limit", String(root.listLimit)])
    if (root.filter === "unread") args.push("--unread")
    if (root.filter === "flagged") args.push("--flagged")
    if (root.query) args = args.concat(["--query", root.query])
    run(args, function (ok, payload, stderrText) {
      root.loading = false
      if (!ok) {
        reportFailure(payload, stderrText, "Could not read the mailbox")
        return
      }
      root.error = ""
      root.messages = payload.messages || []
      root.messagesLoaded()
      // Keep the open message in sync with the refreshed row (flags, seen).
      if (root.selected) {
        for (var i = 0; i < root.messages.length; i++) {
          if (root.messages[i].uid === root.selected.uid
              && root.messages[i].folder === root.selected.folder) {
            root.selected = root.messages[i]
            return
          }
        }
      }
    }, "list")
  }

  function sync(full) {
    if (root.syncing || !root.accountId) return
    if (root.currentAccount && root.currentAccount.demo) {
      root.refreshStatus()
      root.loadMessages()
      return
    }
    root.syncing = true
    var args = accountArgs(["sync", "--folder", root.folder, "--limit", "300"])
    if (full) args.push("--full")
    run(args, function (ok, payload, stderrText) {
      root.syncing = false
      if (!ok) {
        reportFailure(payload, stderrText, "Could not reach the mail server")
        return
      }
      var results = (payload && payload.results) || []
      for (var i = 0; i < results.length; i++) {
        if (results[i].ok === false) {
          reportFailure({ error: results[i].error }, "", "Sync failed")
          return
        }
      }
      root.error = ""
      root.refreshStatus()
      root.loadFolders()
    }, "sync")
  }

  function openMessage(entry) {
    if (!entry) return
    root.selected = entry
    root.body = null
    var args = accountArgs(["body", "--folder", entry.folder,
                            "--uid", String(entry.uid)])
    if (!entry.seen) args.push("--mark-read")
    run(args, function (ok, payload, stderrText) {
      if (!ok) {
        reportFailure(payload, stderrText, "Could not open the message")
        // Resolve the pending state so the reading pane shows the failure
        // instead of an indefinite "Loading message…".
        if (root.selected && root.selected.uid === entry.uid) {
          root.body = { text: "", html: "", parts: [], headers: {}, failed: true }
          root.bodyLoaded()
        }
        return
      }
      if (!root.selected || root.selected.uid !== entry.uid) return
      root.body = payload.body || null
      if (payload.message) root.selected = payload.message
      root.bodyLoaded()
      if (!entry.seen) {
        markLocalSeen(entry, true)
        root.refreshStatus()
      }
    }, "body")
  }

  function markLocalSeen(entry, seen) {
    var next = []
    for (var i = 0; i < root.messages.length; i++) {
      var row = root.messages[i]
      if (row.uid === entry.uid && row.folder === entry.folder) {
        var copy = {}
        for (var key in row) copy[key] = row[key]
        copy.seen = seen
        next.push(copy)
      } else {
        next.push(row)
      }
    }
    root.messages = next
  }

  // ----------------------------------------------------------------- actions

  function setFlag(entry, flagName) {
    if (!entry) return
    root.busy = true
    var args = accountArgs(["flag", "--folder", entry.folder,
                            "--uid", String(entry.uid), "--set", flagName])
    run(args, function (ok, payload, stderrText) {
      root.busy = false
      if (!ok) {
        reportFailure(payload, stderrText, "Could not update the message")
        return
      }
      root.loadMessages()
      root.refreshStatus()
    }, "flag")
  }

  function toggleRead(entry) {
    if (!entry) return
    setFlag(entry, entry.seen ? "unseen" : "seen")
  }

  function toggleFlagged(entry) {
    if (!entry) return
    setFlag(entry, entry.flagged ? "unflagged" : "flagged")
  }

  function moveTo(entry, target) {
    if (!entry || !target) return
    root.busy = true
    dropLocal(entry)
    var args = accountArgs(["move", "--folder", entry.folder,
                            "--uid", String(entry.uid), "--to", target])
    run(args, function (ok, payload, stderrText) {
      root.busy = false
      if (!ok) {
        reportFailure(payload, stderrText, "Could not move the message")
        root.loadMessages()
        return
      }
      root.notice = target === "archive" ? "Archived" : ("Moved to " + target)
      noticeTimer.restart()
      root.loadFolders()
      root.refreshStatus()
    }, "move")
  }

  function archive(entry) { moveTo(entry, "archive") }

  function remove(entry) {
    if (!entry) return
    root.busy = true
    dropLocal(entry)
    var args = accountArgs(["delete", "--folder", entry.folder,
                            "--uid", String(entry.uid)])
    run(args, function (ok, payload, stderrText) {
      root.busy = false
      if (!ok) {
        reportFailure(payload, stderrText, "Could not delete the message")
        root.loadMessages()
        return
      }
      root.notice = "Deleted"
      noticeTimer.restart()
      root.loadFolders()
      root.refreshStatus()
    }, "delete")
  }

  // Drop the row from the list right away so the UI answers the click, and
  // let the reload that follows the server round trip be the correction.
  function dropLocal(entry) {
    var next = []
    var nextSelected = null
    for (var i = 0; i < root.messages.length; i++) {
      var row = root.messages[i]
      if (row.uid === entry.uid && row.folder === entry.folder) {
        nextSelected = root.messages[i + 1] || root.messages[i - 1] || null
        continue
      }
      next.push(row)
    }
    root.messages = next
    if (root.selected && root.selected.uid === entry.uid) {
      root.selected = null
      root.body = null
      if (nextSelected) openMessage(nextSelected)
    }
  }

  function buildDraft(entry, kind, handler) {
    if (!entry) return
    var args = accountArgs(["draft", "--folder", entry.folder,
                            "--uid", String(entry.uid), "--kind", kind])
    run(args, function (ok, payload, stderrText) {
      if (!ok) {
        reportFailure(payload, stderrText, "Could not build the reply")
        return
      }
      if (handler) handler(payload.draft || {})
    }, "draft")
  }

  function send(draft, handler) {
    root.busy = true
    var payloadText = JSON.stringify(draft)
    var process = sendRunner.createObject(root, {
      command: [cliPath, "--json", "send", "--account", root.accountId, "--draft", "-"],
      payload: payloadText,
      handler: handler
    })
    if (!process) {
      root.busy = false
      root.actionFailed("Could not start the mail engine.")
      return
    }
    process.running = true
  }

  Component {
    id: sendRunner

    Process {
      id: sendProc
      property string payload: ""
      property var handler: null
      running: false
      stdinEnabled: true
      stdout: StdioCollector { id: sendOut; waitForEnd: true }
      stderr: StdioCollector { id: sendErr; waitForEnd: true }
      onStarted: {
        sendProc.write(sendProc.payload)
        sendProc.stdinEnabled = false
      }
      onExited: function (exitCode) {
        var parsed = Model.parseJson(sendOut.text, null)
        var ok = exitCode === 0 && parsed && parsed.ok !== false
        root.busy = false
        if (ok) {
          root.notice = "Message sent"
          noticeTimer.restart()
          root.sent()
        } else {
          root.reportFailure(parsed, sendErr.text, "Could not send the message")
        }
        if (sendProc.handler) sendProc.handler(ok, parsed)
        Qt.callLater(function () { sendProc.destroy() })
      }
    }
  }

  function saveAttachment(entry, index, open) {
    if (!entry) return
    var args = accountArgs(["attachment", "--folder", entry.folder,
                            "--uid", String(entry.uid), "--index", String(index)])
    if (open) args.push("--open")
    run(args, function (ok, payload, stderrText) {
      if (!ok) {
        reportFailure(payload, stderrText, "Could not save the attachment")
        return
      }
      root.notice = "Saved to " + String(payload.path || "")
      noticeTimer.restart()
    }, "attachment")
  }

  function authorize(handler) {
    if (!root.accountId) return
    var process = authRunner.createObject(root, {
      command: [cliPath, "auth", root.accountId, "--stream"],
      handler: handler
    })
    if (process) process.running = true
    return process
  }

  Component {
    id: authRunner

    Process {
      id: authProc
      property var handler: null
      running: false
      stdout: SplitParser {
        onRead: function (line) {
          var event = Model.parseJson(line, null)
          if (event && authProc.handler) authProc.handler(event)
        }
      }
      onExited: Qt.callLater(function () { authProc.destroy() })
    }
  }

  function openSetupTerminal() {
    Quickshell.execDetached(["uwsm-app", "--", "alacritty", "-e",
                             cliPath, "setup"])
  }

  Timer {
    id: noticeTimer
    interval: 2600
    onTriggered: root.notice = ""
  }

  Timer {
    id: syncTimer
    interval: root.syncIntervalSec * 1000
    repeat: true
    running: root.configured && root.pollEnabled
    onTriggered: root.sync(false)
  }

  Component.onCompleted: refreshStatus(true)
}
