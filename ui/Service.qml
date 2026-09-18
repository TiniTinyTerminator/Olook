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

  // The engine sits at the root of the plugin and the QML in ui/ beside it,
  // so the same checkout works whether it was installed by `omarchy plugin
  // add`, symlinked from a working copy, or copied in by hand. Resolved
  // relative to this file, which is why it climbs out of ui/ first.
  readonly property string cliPath: Qt.resolvedUrl("../bin/olook").toString().replace(/^file:\/\//, "")

  property var accounts: []
  property string accountId: ""
  property var folders: []
  // Folders for every account, keyed by account id. The folder pane shows
  // them all at once as one tree, so it cannot ask only about the current one.
  property var accountFolders: ({})
  property string folder: "INBOX"
  property var messages: []
  property var selected: null
  property var body: null
  property int unread: 0
  property int lastSync: 0
  // Newest inbox mail across every account, newest first. The bar panel shows
  // this rather than one account's folder, the way a notification list would.
  property var recent: []
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

  // IMAP IDLE. `olook watch` holds a connection open per account and prints a
  // line the moment the server says something changed, so mail lands in the
  // cache when it arrives rather than on the next poll. While at least one
  // watcher is up the poll timer stands down — this replaces polling rather
  // than adding to it.
  property bool watchEnabled: false
  property int watchCount: 0
  readonly property bool watching: watchCount > 0
  property var watchProcs: ({})

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
    // The All folder is not in any account's folder list, so it describes
    // itself: without this the header shows the raw name nobody should see.
    if (Model.isAllFolder(folder))
      return { name: folder, special: "allaccounts",
               unseen: root.unreadEverywhere }
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

  // Same runner, but the payload goes in on stdin — passwords and message
  // bodies never belong on a command line other processes can read.
  Component {
    id: stdinRunner

    Process {
      id: inProc
      property string payload: ""
      property var handler: null
      property string label: ""
      running: false
      stdinEnabled: true
      stdout: StdioCollector { id: inOut; waitForEnd: true }
      stderr: StdioCollector { id: inErr; waitForEnd: true }
      onStarted: {
        inProc.write(inProc.payload)
        inProc.stdinEnabled = false
      }
      onExited: function (exitCode) {
        var parsed = Model.parseJson(inOut.text, null)
        if (inProc.handler) {
          inProc.handler(exitCode === 0 && parsed && parsed.ok !== false,
                         parsed, String(inErr.text || ""))
        }
        Qt.callLater(function () { inProc.destroy() })
      }
    }
  }

  function runWithInput(args, input, handler, label) {
    if (!cliPath || cliPath.indexOf("bin/olook") === -1) {
      root.error = "Mail engine not found next to the plugin."
      return null
    }
    var process = stdinRunner.createObject(root, {
      command: [cliPath, "--json"].concat(args),
      payload: String(input === undefined || input === null ? "" : input),
      handler: handler, label: label || ""
    })
    if (!process) {
      root.error = "Could not start the mail engine."
      return null
    }
    process.running = true
    return process
  }

  // `accountId` names an account other than the one on screen. A popped-out
  // reader, and every row of the All folder, belongs to whichever account the
  // message arrived on rather than to whatever the client is showing now.
  function accountArgs(extra, accountId) {
    var args = extra.slice()
    var target = accountId || root.accountId
    if (target) args = args.concat(["--account", target])
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
    run(["status", "--limit", "20"], function (ok, payload) {
      if (!ok || !payload) return
      var previousUnread = root.unread
      var hadAccounts = root.accounts.length > 0

      root.accounts = payload.accounts || []
      root.configured = payload.configured === true
      root.unread = payload.unread || 0
      root.recent = payload.messages || []
      root.lastSync = payload.lastSync || 0
      root.ready = true

      if (!root.accountId && root.accounts.length > 0) root.accountId = root.accounts[0].id

      if (hadAccounts && root.unread > previousUnread) {
        var newest = (payload.messages || [])[0] || null
        root.newMail(root.unread - previousUnread, newest)
      }
      if (thenLoad) root.loadFolders()
      // Accounts may have appeared, been paused, or lost authorization.
      if (root.watchEnabled) root.syncWatchers()
    }, "status")
  }

  // ----------------------------------------------------------------- folders

  // Loads the folder list for every configured account. Only the current
  // account's fetch is allowed to hit the server; the rest come from cache,
  // so opening the pane never costs one IMAP round trip per account.
  function loadFolders(refresh) {
    if (root.accounts.length === 0) return
    var collected = ({})
    var pending = root.accounts.length

    function finish() {
      root.accountFolders = collected
      root.folders = collected[root.accountId] || []
      if (root.folders.length > 0) {
        var found = false
        for (var i = 0; i < root.folders.length; i++)
          if (root.folders[i].name === root.folder) found = true
        if (!found) root.folder = root.folders[0].name
      }
      root.loadMessages()
    }

    function fetch(id, fromServer, done) {
      var args = ["folders", "--account", id]
      if (fromServer) args.push("--refresh")
      run(args, function (ok, payload) {
        done((ok && payload) ? (payload.folders || []) : [])
      }, "folders")
    }

    for (var index = 0; index < root.accounts.length; index++) {
      (function (account) {
        var id = account.id
        var fromServer = !!refresh && id === root.accountId
        fetch(id, fromServer, function (list) {
          // A cold cache is not an empty mailbox. An account that has never
          // had its folder list fetched — a newly added one, or one that was
          // unauthorized the last time anyone asked — has to go to the server
          // once, or it sits in the pane with no folders under it.
          if (list.length === 0 && !fromServer
              && account.demo !== true && account.authorized !== false) {
            fetch(id, true, function (fresh) {
              collected[id] = fresh
              pending -= 1
              if (pending === 0) finish()
            })
            return
          }
          collected[id] = list
          pending -= 1
          if (pending === 0) finish()
        })
      })(root.accounts[index])
    }
  }

  function foldersFor(accountId) {
    var found = root.accountFolders[accountId]
    return found === undefined ? [] : found
  }

  // One click in the tree picks an account and a folder together.
  // A folder only ever has rows because something synced it, and the timer
  // only ever syncs the one on screen. Without this, every folder but the
  // inbox stayed empty however much mail was really in it.
  property var syncedFolders: ({})

  function folderKey(accountId, folderName) {
    return String(accountId) + "\u241f" + String(folderName)
  }

  function ensureFolderSynced() {
    if (!root.accountId || !root.folder) return
    var account = root.currentAccount
    if (account && (account.demo === true || account.authorized === false)) return
    var key = root.folderKey(root.accountId, root.folder)
    if (root.syncedFolders[key]) return
    // Only one sync runs at a time. Opening an account sets its inbox syncing
    // and the folder you actually asked for arrives moments later, so waiting
    // our turn matters more than giving up.
    if (root.syncing) return
    // Marked before the result comes back, so that onSyncingChanged does not
    // turn one slow folder into a second attempt while the first is running.
    // A failure gives the mark back: a folder that could not be fetched once
    // is worth trying again when it is next opened, and leaving it marked
    // left a folder showing a count beside an empty list for the rest of the
    // session with nothing that would ever fill it.
    root.syncedFolders[key] = true
    root.sync(false, function (ok) {
      if (!ok) delete root.syncedFolders[key]
    })
  }

  // How many messages the server says are in the folder on screen. The tree
  // gets this from IMAP; the list only has what has been fetched, and the
  // difference between the two is worth saying out loud.
  readonly property int currentFolderTotal: {
    for (var i = 0; i < root.folders.length; i++)
      if (root.folders[i].name === root.folder)
        return Number(root.folders[i].total || 0)
    return 0
  }

  onSyncingChanged: if (!root.syncing) Qt.callLater(root.ensureFolderSynced)

  function openFolder(accountId, folderName) {
    if (!folderName) return
    // The All folder belongs to no account, so it names none. Whichever
    // account was current stays current: it is what a new message is sent
    // from, and reading across accounts should not silently change that.
    if (Model.isAllFolder(folderName)) {
      if (root.viewingAll) return
      root.folder = folderName
      root.selected = null
      root.body = null
      root.messages = []
      loadMessages()
      return
    }
    if (!accountId) return
    if (accountId === root.accountId && folderName === root.folder) return
    root.accountId = accountId
    root.folders = root.foldersFor(accountId)
    root.folder = folderName
    root.selected = null
    root.body = null
    root.messages = []
    loadMessages()
    ensureFolderSynced()
  }

  // Unread across every account, for the All row's badge.
  readonly property int unreadEverywhere: {
    var total = 0
    for (var i = 0; i < root.accounts.length; i++)
      total += Number(root.accounts[i].unread || 0)
    return total
  }

  function setAccount(id) {
    if (!id || id === root.accountId) return
    root.accountId = id
    root.selected = null
    root.body = null
    root.folder = "INBOX"
    root.messages = []
    root.folders = root.foldersFor(id)
    loadFolders()
    ensureFolderSynced()
  }

  function setFolder(name) {
    if (!name || name === root.folder) return
    root.folder = name
    root.selected = null
    root.body = null
    loadMessages()
    // Nothing to sync for a folder no server has; its contents are whatever
    // the accounts have already pulled down.
    if (!root.viewingAll) ensureFolderSynced()
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

  readonly property bool viewingAll: Model.isAllFolder(root.folder)

  // date | sender | subject | size | unread
  property string sortMode: "date"
  // One row per conversation rather than per message.
  property bool conversationMode: false

  function setConversations(on) {
    if (on === root.conversationMode) return
    root.conversationMode = on
    root.selected = null
    loadMessages()
  }

  function setSort(mode) {
    if (!mode || mode === root.sortMode) return
    root.sortMode = mode
    root.selected = null
    loadMessages()
  }

  function loadMessages() {
    if (!root.accountId) return
    root.loading = true
    // The All folder is not a mailbox on any server: it is every account's
    // inbox in one list, so it names no account and no folder of its own.
    var args = root.viewingAll
      ? ["list", "--all-accounts", "--limit", String(root.listLimit)]
      : accountArgs(["list", "--folder", root.folder,
                     "--limit", String(root.listLimit)])
    args = args.concat(["--sort", root.sortMode])
    if (root.conversationMode) args.push("--conversations")
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
              && root.messages[i].folder === root.selected.folder
              && root.messages[i].account === root.selected.account) {
            root.selected = root.messages[i]
            return
          }
        }
      }
    }, "list")
  }

  function sync(full, done) {
    if (root.syncing || !root.accountId) {
      if (done) done(false)
      return
    }
    if (root.currentAccount && root.currentAccount.demo) {
      root.refreshStatus()
      root.loadMessages()
      if (done) done(true)
      return
    }
    root.syncing = true
    // A connection good enough to sync is good enough to send.
    root.flushOutbox()
    var args = accountArgs(["sync", "--folder", root.folder, "--limit", "300"])
    if (full) args.push("--full")
    run(args, function (ok, payload, stderrText) {
      root.syncing = false
      if (!ok) {
        reportFailure(payload, stderrText, "Could not reach the mail server")
        if (done) done(false)
        return
      }
      var results = (payload && payload.results) || []
      for (var i = 0; i < results.length; i++) {
        if (results[i].ok === false) {
          reportFailure({ error: results[i].error }, "", "Sync failed")
          if (done) done(false)
          return
        }
      }
      root.error = ""
      root.refreshStatus()
      // finish() at the end of loadFolders reloads the message list, so the
      // rows this sync just fetched land on screen.
      root.loadFolders()
      if (done) done(true)
    }, "sync")
  }

  function openMessage(entry) {
    if (!entry) return
    root.selected = entry
    root.body = null
    var args = accountArgs(["body", "--folder", entry.folder,
                            "--uid", String(entry.uid)], entry.account)
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

  // Fetch the open message again, this time keeping the images it points at
  // over the network. Deliberately a second, explicit request: the document
  // carrying those URLs is only built once the reader has asked for it, so
  // there is no version of the message sitting around that could fetch them
  // by accident.
  function loadRemoteImages() {
    var entry = root.selected
    if (!entry) return
    var args = accountArgs(["body", "--folder", entry.folder,
                            "--uid", String(entry.uid), "--remote-images"],
                           entry.account)
    run(args, function (ok, payload, stderrText) {
      if (!ok || !payload || !payload.body) {
        reportFailure(payload, stderrText, "Could not load the images")
        return
      }
      if (!root.selected || root.selected.uid !== entry.uid) return
      root.body = payload.body
      root.bodyLoaded()
    }, "body")
  }

  // Everyone the cached mail has been to or from. Loaded on demand: the
  // People view is the only thing that wants it, and it is a whole-mailbox
  // scan rather than a folder listing.
  property var contacts: []
  property bool contactsLoading: false

  property bool contactsSyncing: false

  // Pull the address book down, then show what came of it.
  function syncContacts(done) {
    root.contactsSyncing = true
    run(["contacts", "--sync"], function (ok, payload, stderrText) {
      root.contactsSyncing = false
      var trouble = ""
      var results = (payload && payload.results) || []
      for (var i = 0; i < results.length; i++)
        if (!results[i].ok) trouble = String(results[i].error || "")
      if (!ok || trouble !== "") {
        root.error = trouble !== "" ? trouble
          : String((payload && payload.error) || stderrText
                   || "Could not read the address book")
        root.actionFailed(root.error)
      } else if (results.length === 0) {
        root.notice = "No account here keeps an address book"
        noticeTimer.restart()
      } else {
        var total = 0
        for (var j = 0; j < results.length; j++) total += Number(results[j].contacts || 0)
        root.notice = total + " contacts from your accounts"
        noticeTimer.restart()
      }
      root.loadContacts("")
      if (done) done()
    }, "contacts")
  }

  function loadContacts(text) {
    root.contactsLoading = true
    var args = ["contacts", "--limit", "500"]
    if (text) args = args.concat(["--query", String(text)])
    run(args, function (ok, payload, stderrText) {
      root.contactsLoading = false
      if (!ok) {
        reportFailure(payload, stderrText, "Could not read your contacts")
        return
      }
      root.contacts = payload.contacts || []
    }, "contacts")
  }

  // Signing in for the grant that carries contacts, the calendar, and on
  // Microsoft the ability to send when a tenant has switched SMTP off. The
  // engine opens the browser; this only follows along so the panel can say
  // what is happening.
  property bool extrasAuthorizing: false

  // Set when a tenant will not let someone consent for themselves, so the
  // panel can offer the narrower ask instead of only reporting a refusal.
  property bool extrasNeedApproval: false

  function authorizeExtras(accountId, done, readOnly) {
    var id = String(accountId || "")
    if (!id) {
      var candidates = root.bookAccounts.length ? root.bookAccounts
                                                : root.calendarAccounts
      if (!candidates.length) return null
      id = String(candidates[0].id)
    }
    root.extrasAuthorizing = true
    root.extrasNeedApproval = false
    var args = [cliPath, "contacts-auth", "--account", id, "--stream"]
    if (readOnly) args.push("--read-only")
    var process = authRunner.createObject(root, {
      command: args,
      handler: function (event) {
        var kind = String(event.event || "")
        if (kind === "error") {
          root.extrasAuthorizing = false
          root.error = String(event.error || "Sign-in failed")
          root.extrasNeedApproval = !readOnly
            && root.error.toLowerCase().indexOf("administrator") !== -1
          root.actionFailed(root.error)
        } else if (kind === "done" || kind === "authorized") {
          root.extrasAuthorizing = false
          root.notice = "Signed in"
          noticeTimer.restart()
          // The account list carries whether this grant is signed in, so it
          // has to be re-read or the button stays on screen after the job.
          root.listAccounts(function (found) { root.accounts = found })
          root.refreshStatus(true)
          root.loadCalendars()
          if (done) done()
        }
      }
    })
    if (process) process.running = true
    return process
  }

  // ------------------------------------------------------------- calendar

  property var events: []
  property var calendars: []
  property bool calendarLoading: false
  property bool calendarSyncing: false
  readonly property var calendarAccounts: {
    var out = []
    for (var i = 0; i < root.accounts.length; i++)
      if (root.accounts[i].calendar) out.push(root.accounts[i])
    return out
  }

  readonly property bool canReadCalendar: root.calendarAccounts.length > 0

  // Accounts that could keep contacts or a calendar and have not been signed
  // in for yet. Asked per account rather than "has anything been signed in",
  // because one account already set up says nothing about the next one.
  readonly property var accountsNeedingExtras: {
    var out = []
    for (var i = 0; i < root.accounts.length; i++) {
      var entry = root.accounts[i]
      if ((entry.calendar || entry.addressBook) && !entry.extrasAuthorized)
        out.push(entry)
    }
    return out
  }

  // The window currently held, as YYYY-MM-DD. The engine caches whatever it
  // has fetched, so moving back to a month already seen paints from disk.
  property string calendarFrom: ""
  property string calendarTo: ""

  // Months already asked the server about. A month with nothing in it is not
  // the same as a month nobody has fetched, and without this the calendar
  // showed an empty grid for every month until somebody pressed refresh.
  property var fetchedMonths: ({})

  function loadCalendar(from, to) {
    root.calendarFrom = String(from || "")
    root.calendarTo = String(to || "")
    root.calendarLoading = true
    var args = ["calendar"]
    if (root.calendarFrom) args = args.concat(["--start", root.calendarFrom])
    if (root.calendarTo) args = args.concat(["--end", root.calendarTo])
    run(args, function (ok, payload, stderrText) {
      root.calendarLoading = false
      if (!ok) {
        reportFailure(payload, stderrText, "Could not read the calendar")
        return
      }
      root.events = (payload && payload.events) || []

      var window = root.calendarFrom + ".." + root.calendarTo
      if (root.fetchedMonths[window] || root.calendarSyncing) return
      if (root.calendarAccounts.length === 0) return
      // Marked before the answer comes back and left marked on failure, so
      // one unreachable account cannot turn into a sync on every repaint.
      root.fetchedMonths[window] = true
      root.syncCalendar(null)
    }, "calendar")
  }

  function loadCalendars() {
    run(["calendars"], function (ok, payload) {
      if (ok && payload) root.calendars = payload.calendars || []
    }, "calendar")
  }

  function syncCalendar(done) {
    root.calendarSyncing = true
    var args = ["calendar", "--sync"]
    if (root.calendarFrom) args = args.concat(["--start", root.calendarFrom])
    if (root.calendarTo) args = args.concat(["--end", root.calendarTo])
    run(args, function (ok, payload, stderrText) {
      root.calendarSyncing = false
      // A refused calendar comes back with the events it already had, so the
      // trouble is reported without wiping what is on screen.
      var problems = (payload && payload.problems) || []
      if (problems.length > 0) {
        // Every account that could not be read, not just the first: with
        // three accounts, naming one left the other two looking fine.
        var lines = []
        for (var p = 0; p < problems.length; p++)
          lines.push(String(problems[p].account) + ": " + String(problems[p].error))
        root.error = lines.join("   ")
        root.actionFailed(root.error)
      } else if (!ok) {
        reportFailure(payload, stderrText, "Could not read the calendar")
        return
      } else {
        root.notice = ((payload && payload.count) || 0) + " events"
        noticeTimer.restart()
      }
      if (payload && payload.events) root.events = payload.events
      root.loadCalendars()
      if (done) done()
    }, "calendar")
  }

  // A new appointment. `when` and `until` are "YYYY-MM-DDTHH:MM", or
  // "YYYY-MM-DD" for an all-day one; the engine works out the rest.
  function addEvent(fields, done) {
    if (!fields || !fields.account || !fields.title || !fields.start) return
    var args = ["event-add", "--account", String(fields.account),
                "--title", String(fields.title), "--start", String(fields.start)]
    if (fields.end) args = args.concat(["--end", String(fields.end)])
    if (fields.calendar) args = args.concat(["--calendar", String(fields.calendar)])
    if (fields.allDay) args.push("--all-day")
    if (fields.location) args = args.concat(["--location", String(fields.location)])
    if (fields.description) args = args.concat(["--description", String(fields.description)])
    root.calendarSyncing = true
    run(args, function (ok, payload, stderrText) {
      root.calendarSyncing = false
      if (!ok) {
        reportFailure(payload, stderrText, "Could not add that appointment")
        if (done) done(false)
        return
      }
      root.notice = "Appointment added"
      noticeTimer.restart()
      // The window on screen was read before this existed.
      root.fetchedMonths = ({})
      root.syncCalendar(null)
      if (done) done(true)
    }, "calendar")
  }

  function editEvent(fields, done) {
    if (!fields || !fields.account || !fields.uid) return
    var args = ["event-edit", "--account", String(fields.account),
                "--uid", String(fields.uid), "--title", String(fields.title || ""),
                "--start", String(fields.start),
                "--location", String(fields.location || "")]
    if (fields.end) args = args.concat(["--end", String(fields.end)])
    args.push(fields.allDay ? "--all-day" : "--timed")
    root.calendarSyncing = true
    run(args, function (ok, payload, stderrText) {
      root.calendarSyncing = false
      if (!ok) {
        reportFailure(payload, stderrText, "Could not change that appointment")
        if (done) done(false)
        return
      }
      root.notice = "Appointment changed"
      noticeTimer.restart()
      root.fetchedMonths = ({})
      root.syncCalendar(null)
      if (done) done(true)
    }, "calendar")
  }

  function removeEvent(account, uid, done) {
    if (!account || !uid) return
    run(["event-remove", "--account", String(account), "--uid", String(uid)],
        function (ok, payload, stderrText) {
      if (!ok) {
        reportFailure(payload, stderrText, "Could not delete that appointment")
        if (done) done(false)
        return
      }
      root.notice = "Appointment deleted"
      noticeTimer.restart()
      root.loadCalendar(root.calendarFrom, root.calendarTo)
      if (done) done(true)
    }, "calendar")
  }

  // Calendars kept in a file or behind a link, which belong to no account.
  function addCalendarFile(name, source, colour, done) {
    if (!source) return
    var args = ["calendar-add", "--name", String(name || "")]
    args = args.concat([
      String(source).indexOf("://") !== -1 ? "--url" : "--file", String(source)])
    if (colour) args = args.concat(["--colour", String(colour)])
    root.calendarSyncing = true
    run(args, function (ok, payload, stderrText) {
      root.calendarSyncing = false
      if (!ok) {
        reportFailure(payload, stderrText, "Could not read that calendar")
        if (done) done(false)
        return
      }
      root.notice = ((payload && payload.events) || 0) + " events"
      noticeTimer.restart()
      root.loadCalendars()
      // The window on screen has not been fetched from this calendar yet.
      root.fetchedMonths = ({})
      root.loadCalendar(root.calendarFrom, root.calendarTo)
      if (done) done(true)
    }, "calendar")
  }

  function forgetCalendar(id, done) {
    if (!id) return
    run(["calendar-forget", String(id)], function (ok, payload, stderrText) {
      if (!ok) {
        reportFailure(payload, stderrText, "Could not remove that calendar")
        return
      }
      root.loadCalendars()
      root.loadCalendar(root.calendarFrom, root.calendarTo)
      if (done) done()
    }, "calendar")
  }

  function setCalendarHidden(id, hidden) {
    if (!id) return
    run(["calendars", hidden ? "--hide" : "--show", String(id)],
        function (ok, payload) {
      if (ok && payload) root.calendars = payload.calendars || []
      // A hidden calendar is skipped when fetching, so its events are not in
      // the cache to come back. Showing one therefore has to ask the server;
      // hiding one only has to re-read what is already here.
      if (hidden) root.loadCalendar(root.calendarFrom, root.calendarTo)
      else root.syncCalendar(null)
    }, "calendar")
  }

  // The account whose address book new contacts go into. Only accounts with
  // an application of their own behind them can be written to, so a client
  // with none offers no editing at all rather than failing at the last step.
  readonly property var bookAccounts: {
    var out = []
    for (var i = 0; i < root.accounts.length; i++)
      if (root.accounts[i].addressBook) out.push(root.accounts[i])
    return out
  }

  readonly property bool canEditContacts: root.bookAccounts.length > 0

  // Add a contact, or change one already in the book. `resource` empty means
  // a new one. Emails and phones are whole lists: what is passed replaces
  // what was there, which is how the People API treats them too.
  function saveContact(account, resource, etag, contact, done) {
    var target = account || (root.bookAccounts.length ? root.bookAccounts[0].id : "")
    if (!target) {
      root.error = "No account here can keep contacts."
      root.actionFailed(root.error)
      return
    }
    var args = ["contact-save", "--account", String(target)]
    if (resource) args = args.concat(["--resource", String(resource)])
    if (etag) args = args.concat(["--etag", String(etag)])
    args = args.concat(["--name", String(contact.name || "")])
    args = args.concat(["--organisation", String(contact.organisation || "")])
    var emails = contact.emails || []
    for (var i = 0; i < emails.length; i++)
      if (String(emails[i]).trim() !== "") args = args.concat(["--email", String(emails[i]).trim()])
    var phones = contact.phones || []
    for (var j = 0; j < phones.length; j++)
      if (String(phones[j]).trim() !== "") args = args.concat(["--phone", String(phones[j]).trim()])

    root.contactsSyncing = true
    run(args, function (ok, payload, stderrText) {
      root.contactsSyncing = false
      if (!ok) {
        reportFailure(payload, stderrText, "Could not save that contact")
        return
      }
      root.notice = resource ? "Contact saved" : "Contact added"
      noticeTimer.restart()
      root.loadContacts("")
      if (done) done(payload && payload.contact)
    }, "contacts")
  }

  function removeContact(account, resource, done) {
    if (!resource) return
    root.contactsSyncing = true
    run(["contact-remove", "--account", String(account),
         "--resource", String(resource)], function (ok, payload, stderrText) {
      root.contactsSyncing = false
      if (!ok) {
        reportFailure(payload, stderrText, "Could not delete that contact")
        return
      }
      root.notice = "Contact deleted"
      noticeTimer.restart()
      root.loadContacts("")
      if (done) done()
    }, "contacts")
  }

  // When pictures in a message may load without being asked:
  // verified | trusted | never. Kept by the engine so the terminal and the
  // client cannot disagree about it.
  property string imagePolicy: "verified"

  function loadImagePolicy() {
    run(["images"], function (ok, payload) {
      if (ok && payload && payload.policy) root.imagePolicy = String(payload.policy)
    }, "images")
  }

  function setImagePolicy(value, done) {
    if (!value || value === root.imagePolicy) return
    run(["images", String(value)], function (ok, payload, stderrText) {
      if (!ok) {
        reportFailure(payload, stderrText, "Could not change that")
        return
      }
      root.imagePolicy = String((payload && payload.policy) || value)
      // The open message was rendered under the old rule.
      if (root.selected) root.openMessage(root.selected)
      if (done) done()
    }, "images")
  }

  // Senders whose pictures load without being asked. Kept by the engine, so
  // the terminal and the client agree about who is on the list.
  function trustSender(address, trusted, done) {
    if (!address) return
    run(["trust", trusted ? "add" : "remove", String(address)],
        function (ok, payload, stderrText) {
          if (!ok) {
            reportFailure(payload, stderrText, "Could not change that")
            return
          }
          if (done) done()
        }, "trust")
  }

  // Markdown as the engine renders it, which is the point: a preview with its
  // own opinion of markdown would show something other than what is sent.
  function renderMarkdown(source, handler) {
    runWithInput(["markdown"], String(source || ""),
                 function (ok, payload) {
                   if (handler) handler(ok && payload ? String(payload.html || "") : "")
                 }, "markdown")
  }

  // The account record a message belongs to. Rows carry an account id; the
  // reader and the reply need the whole account behind it.
  function accountFor(accountId) {
    var wanted = String(accountId || root.accountId || "")
    for (var i = 0; i < root.accounts.length; i++)
      if (String(root.accounts[i].id) === wanted) return root.accounts[i]
    return root.currentAccount
  }

  // Read one message without touching what the client has open. A popped-out
  // reader owns its message: the window behind it goes on selecting others,
  // and neither should redraw the other.
  function fetchBody(entry, markRead, handler, remoteImages) {
    if (!entry || !handler) return
    var args = accountArgs(["body", "--folder", entry.folder,
                            "--uid", String(entry.uid)], entry.account)
    if (markRead) args.push("--mark-read")
    if (remoteImages) args.push("--remote-images")
    run(args, function (ok, payload, stderrText) {
      if (!ok || !payload || !payload.body) {
        reportFailure(payload, stderrText, "Could not open the message")
        handler({ text: "", html: "", parts: [], headers: {}, failed: true }, entry)
        return
      }
      handler(payload.body, payload.message || entry)
      if (markRead) {
        markLocalSeen(entry, true)
        root.refreshStatus()
      }
    }, "body")
  }

  // -------------------------------------------------------------- undo
  //
  // One step, which is the one that matters: the move or delete just made.
  // Held as Message-IDs rather than uids, because a move is a copy and a
  // delete -- the uid we knew is gone the moment the message lands elsewhere,
  // and the id it carries is the only handle that survives.
  property var lastAction: null
  readonly property bool canUndo: !!root.lastAction
  readonly property string undoLabel: root.lastAction ? root.lastAction.label : ""

  function rememberMove(entries, destination, label) {
    var groups = []
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i]
      if (!entry || !entry.messageId) continue
      var found = null
      for (var j = 0; j < groups.length; j++)
        if (groups[j].account === entry.account && groups[j].from === entry.folder)
          found = groups[j]
      if (!found) {
        found = { account: entry.account, from: entry.folder,
                  to: destination, ids: [] }
        groups.push(found)
      }
      found.ids.push(entry.messageId)
    }
    root.lastAction = groups.length > 0
      ? { label: label, groups: groups } : null
  }

  function undoLast() {
    var action = root.lastAction
    if (!action) return
    root.lastAction = null
    root.busy = true
    var left = action.groups.length
    for (var i = 0; i < action.groups.length; i++) {
      var group = action.groups[i]
      var args = accountArgs(["unmove", "--folder", group.to,
                              "--to", group.from, "--message-id"]
                             .concat(group.ids), group.account)
      run(args, function (ok, payload, stderrText) {
        if (!ok) reportFailure(payload, stderrText, "Could not undo that")
        if (--left === 0) {
          root.busy = false
          root.loadMessages()
          root.refreshStatus()
        }
      }, "unmove")
    }
  }

  // ------------------------------------------------------------ in bulk
  //
  // The engine takes several uids at a time, so a hundred messages is one
  // call per mailbox rather than a hundred calls. Rows are grouped because a
  // selection made in the All folder can span accounts.
  function groupByMailbox(entries) {
    var groups = []
    for (var i = 0; i < (entries || []).length; i++) {
      var entry = entries[i]
      if (!entry) continue
      var found = null
      for (var j = 0; j < groups.length; j++)
        if (groups[j].account === entry.account && groups[j].folder === entry.folder)
          found = groups[j]
      if (!found) {
        found = { account: entry.account, folder: entry.folder, uids: [] }
        groups.push(found)
      }
      found.uids.push(String(entry.uid))
    }
    return groups
  }

  function runOnEach(entries, build, failure, done) {
    var groups = root.groupByMailbox(entries)
    if (groups.length === 0) return
    root.busy = true
    var left = groups.length
    for (var i = 0; i < groups.length; i++) {
      var group = groups[i]
      var args = accountArgs(build(group), group.account)
      run(args, function (ok, payload, stderrText) {
        if (!ok) reportFailure(payload, stderrText, failure)
        else if (done) done(payload || {})
        if (--left === 0) {
          root.busy = false
          root.loadMessages()
          root.refreshStatus()
        }
      }, "bulk")
    }
  }

  // A category on every message given, or off every message given.
  function setCategoryMany(entries, name, remove) {
    if (!name) return
    root.runOnEach(entries, function (group) {
      var args = ["category", "--folder", group.folder, "--uid"]
        .concat(group.uids).concat(["--name", name])
      if (remove) args.push("--remove")
      return args
    }, "Could not change the category")
  }

  function setFlagMany(entries, flagName) {
    for (var i = 0; i < entries.length; i++)
      markLocalFlag(entries[i], flagName)
    root.runOnEach(entries, function (group) {
      return ["flag", "--folder", group.folder, "--uid"].concat(group.uids)
             .concat(["--set", flagName])
    }, "Could not update those messages")
  }

  function moveMany(entries, target) {
    var kept = entries.slice()
    for (var i = 0; i < entries.length; i++) dropLocal(entries[i])
    root.runOnEach(entries, function (group) {
      return ["move", "--folder", group.folder, "--uid"].concat(group.uids)
             .concat(["--to", target])
    }, "Could not move those messages", function (payload) {
      root.rememberMove(kept, String(payload.to || target),
                        kept.length === 1 ? "move" : "moving " + kept.length)
    })
  }

  function removeMany(entries) {
    var kept = entries.slice()
    for (var i = 0; i < entries.length; i++) dropLocal(entries[i])
    root.runOnEach(entries, function (group) {
      return ["delete", "--folder", group.folder, "--uid"].concat(group.uids)
    }, "Could not delete those messages", function (payload) {
      var to = String(payload.to || "")
      // A purge has nowhere to put anything back from.
      if (to !== "" && to !== "(expunged)")
        root.rememberMove(kept, to,
                          kept.length === 1 ? "delete" : "deleting " + kept.length)
    })
  }

  // Empty the folder on screen, permanently. Only ever offered for Deleted
  // Items and Junk: everywhere else "empty" is a euphemism for a mistake.
  readonly property bool canEmptyFolder: {
    var folder = root.currentFolder
    var role = folder ? String(folder.special || "") : ""
    return (role === "trash" || role === "junk") && root.messages.length > 0
  }

  function emptyFolder() {
    if (!root.canEmptyFolder) return
    var uids = []
    for (var i = 0; i < root.messages.length; i++)
      uids.push(String(root.messages[i].uid))
    if (uids.length === 0) return
    root.busy = true
    var args = accountArgs(["delete", "--folder", root.folder, "--purge",
                            "--uid"].concat(uids))
    run(args, function (ok, payload, stderrText) {
      root.busy = false
      if (!ok) {
        reportFailure(payload, stderrText, "Could not empty the folder")
        return
      }
      root.notice = "Folder emptied"
      noticeTimer.restart()
      root.loadMessages()
      root.refreshStatus()
    }, "purge")
  }

  // Everything unread in what is on screen. Outlook offers it on the folder;
  // offering it on the list means it also works in the All folder, which is
  // not a folder any server could be asked about.
  function markVisibleRead() {
    var unread = []
    for (var i = 0; i < root.messages.length; i++)
      if (root.messages[i].seen !== true) unread.push(root.messages[i])
    if (unread.length === 0) return
    root.setFlagMany(unread, "seen")
  }

  function markLocalFlag(entry, flagName) {
    if (flagName === "seen") markLocalSeen(entry, true)
    else if (flagName === "unseen") markLocalSeen(entry, false)
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
                            "--uid", String(entry.uid), "--set", flagName],
                           entry.account)
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
                            "--uid", String(entry.uid), "--to", target],
                           entry.account)
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
                            "--uid", String(entry.uid)], entry.account)
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

  // True when the folder on screen is where drafts live, which is what makes
  // clicking a row open the composer instead of the reading pane.
  readonly property bool inDrafts: {
    var folder = root.currentFolder
    return !!(folder && String(folder.special || "") === "drafts")
  }

  // Turn a stored draft back into something the composer can load.
  function openDraft(entry, handler) {
    if (!entry) return null
    var args = accountArgs(["body", "--folder", entry.folder,
                            "--uid", String(entry.uid)], entry.account)
    return run(args, function (ok, payload, stderrText) {
      if (!ok || !payload || !payload.body) {
        reportFailure(payload, stderrText, "Could not open the draft")
        if (handler) handler(null)
        return
      }
      var headers = payload.body.headers || {}
      var parts = payload.body.parts || []
      var carried = 0
      for (var i = 0; i < parts.length; i++)
        if (parts[i] && parts[i].filename && !parts[i].cid) carried++
      if (handler) handler({
        to: splitHeaderList(headers["To"]),
        cc: splitHeaderList(headers["Cc"]),
        subject: String((payload.message && payload.message.subject)
                        || headers["Subject"] || ""),
        body: String(payload.body.text || ""),
        format: "plain",
        attachments: [],
        // The stored copy this composer now stands in for: saving again
        // replaces it rather than piling up another draft.
        draftUid: entry.uid,
        // Files on the saved copy are not pulled back down, so say so rather
        // than letting them vanish quietly.
        strandedAttachments: carried
      })
    }, "body")
  }

  function splitHeaderList(value) {
    var out = []
    var parts = String(value || "").split(",")
    for (var i = 0; i < parts.length; i++) {
      var one = parts[i].trim()
      if (one !== "") out.push(one)
    }
    return out
  }

  function buildDraft(entry, kind, handler) {
    if (!entry) return
    var args = accountArgs(["draft", "--folder", entry.folder,
                            "--uid", String(entry.uid), "--kind", kind],
                           entry.account)
    run(args, function (ok, payload, stderrText) {
      if (!ok) {
        reportFailure(payload, stderrText, "Could not build the reply")
        return
      }
      if (handler) handler(payload.draft || {})
    }, "draft")
  }

  // `accountId` lets a popped-out compose window keep sending as the account
  // it was started from, whatever the main window is showing by then.
  // Messages written while nothing could be reached. They wait rather than
  // being lost with the window they were typed in.
  property int outboxWaiting: 0

  function refreshOutbox() {
    run(["outbox"], function (ok, payload) {
      root.outboxWaiting = ok && payload ? Number(payload.waiting || 0) : 0
    }, "outbox")
  }

  function flushOutbox() {
    if (root.outboxWaiting === 0) return
    run(["outbox", "--flush"], function (ok, payload) {
      if (ok && payload && payload.sent > 0) {
        root.notice = payload.sent === 1 ? "Sent the message that was waiting"
                                         : "Sent " + payload.sent + " waiting messages"
        noticeTimer.restart()
      }
      root.refreshOutbox()
    }, "outbox")
  }

  function send(draft, handler, accountId) {
    root.busy = true
    runWithInput(["send", "--account", String(accountId || root.accountId),
                  "--draft", "-", "--queue"],
                 JSON.stringify(draft), function (ok, payload, stderrText) {
      root.busy = false
      if (ok && payload && payload.queued) {
        // Not sent, but not lost either: it goes out with the next sync.
        root.notice = "No connection — kept to send later"
        noticeTimer.restart()
        root.refreshOutbox()
        root.sent()
      } else if (ok) {
        root.notice = "Message sent"
        noticeTimer.restart()
        root.sent()
      } else {
        root.reportFailure(payload, stderrText, "Could not send the message")
      }
      if (handler) handler(ok, payload)
    }, "send")
  }

  function saveAttachment(entry, index, open) {
    if (!entry) return
    var args = accountArgs(["attachment", "--folder", entry.folder,
                            "--uid", String(entry.uid), "--index", String(index)],
                           entry.account)
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

  // Streams the OAuth sign-in for one account (the current one by default),
  // handing every event to the caller so the UI can show a device code.
  function authorize(handler, accountId) {
    var id = String(accountId || root.accountId || "")
    if (!id) return null
    var process = authRunner.createObject(root, {
      command: [cliPath, "auth", id, "--stream"],
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

  // Where accounts and folders sit in the tree. Both are stored by the
  // engine, so the order survives a restart and the terminal agrees with the
  // client about it.
  function reorderAccounts(ids, done) {
    if (!ids || ids.length === 0) return
    run(["order", "--accounts", ids.join(",")], function (ok, payload, stderrText) {
      if (!ok) {
        reportFailure(payload, stderrText, "Could not save that order")
        return
      }
      root.listAccounts(function (found) { root.accounts = found })
      if (done) done()
    }, "order")
  }

  function reorderFolders(accountId, names, done) {
    if (!accountId || !names) return
    run(["order", "--account", String(accountId),
         "--folders", names.join(",")], function (ok, payload, stderrText) {
      if (!ok) {
        reportFailure(payload, stderrText, "Could not save that order")
        return
      }
      root.loadFolders(false)
      if (done) done()
    }, "order")
  }

  // ------------------------------------------------------- account setup

  // The full account list, disabled accounts included — `status` deliberately
  // hides those, but the settings panel is where you turn one back on.
  function listAccounts(handler) {
    run(["accounts"], function (ok, payload) {
      if (handler) handler(ok && payload ? (payload.accounts || []) : [])
    }, "accounts")
  }

  // Looks up the server settings for an address without writing anything, so
  // the setup panel can show what it found before the account exists.
  function discover(email, handler) {
    if (!email) return
    run(["discover", String(email)], function (ok, payload, stderrText) {
      if (!ok) {
        reportFailure(payload, stderrText, "Could not look up that domain")
        if (handler) handler(false, null)
        return
      }
      if (handler) handler(true, payload)
    }, "discover")
  }

  // `spec` mirrors the CLI: { email, name, imapHost, imapPort, smtpHost,
  // smtpPort, auth, username }. Everything but the address is optional and
  // falls back to what discovery found.
  function addAccount(spec, handler) {
    if (!spec || !spec.email) return
    var args = ["add", String(spec.email)]
    if (spec.name) args = args.concat(["--name", String(spec.name)])
    if (spec.username) args = args.concat(["--username", String(spec.username)])
    if (spec.auth) args = args.concat(["--auth", String(spec.auth)])
    if (spec.imapHost) args = args.concat(["--imap-host", String(spec.imapHost)])
    if (spec.imapPort) args = args.concat(["--imap-port", String(spec.imapPort)])
    if (spec.smtpHost) args = args.concat(["--smtp-host", String(spec.smtpHost)])
    if (spec.smtpPort) args = args.concat(["--smtp-port", String(spec.smtpPort)])
    if (spec.tenant) args = args.concat(["--tenant", String(spec.tenant)])
    if (spec.clientId) args = args.concat(["--client-id", String(spec.clientId)])
    run(args, function (ok, payload, stderrText) {
      if (!ok) {
        reportFailure(payload, stderrText, "Could not add the account")
        if (handler) handler(false, null)
        return
      }
      root.error = ""
      if (handler) handler(true, (payload && payload.account) || null)
    }, "add")
  }

  function setPassword(accountId, password, handler) {
    if (!accountId) return
    runWithInput(["auth", String(accountId), "--password-stdin"], password,
                 function (ok, payload, stderrText) {
      if (!ok) reportFailure(payload, stderrText, "Could not store the password")
      if (handler) handler(ok, payload)
    }, "auth-password")
  }

  // Writes one or more fields back onto an existing account. `changes` may
  // carry name, username, signature, enabled, imapHost/Port, smtpHost/Port.
  function updateAccount(accountId, changes, handler) {
    if (!accountId || !changes) return
    var args = ["set", String(accountId)]
    var stdinText = null
    if (changes.name !== undefined) args = args.concat(["--name", String(changes.name)])
    if (changes.username !== undefined) args = args.concat(["--username", String(changes.username)])
    if (changes.signature !== undefined) {
      // Signatures are multi-line and user-written; keep them off argv.
      stdinText = String(changes.signature)
      args.push("--signature-stdin")
    }
    if (changes.enabled !== undefined) args.push(changes.enabled ? "--enable" : "--disable")
    if (changes.imapHost) args = args.concat(["--imap-host", String(changes.imapHost)])
    if (changes.imapPort) args = args.concat(["--imap-port", String(changes.imapPort)])
    if (changes.smtpHost) args = args.concat(["--smtp-host", String(changes.smtpHost)])
    if (changes.smtpPort) args = args.concat(["--smtp-port", String(changes.smtpPort)])

    function done(ok, payload, stderrText) {
      if (!ok) {
        reportFailure(payload, stderrText, "Could not save the account")
      } else {
        root.notice = "Saved"
        noticeTimer.restart()
        root.refreshStatus()
      }
      if (handler) handler(ok, payload)
    }
    if (stdinText === null) run(args, done, "set")
    else runWithInput(args, stdinText, done, "set")
  }

  function removeAccount(accountId, handler) {
    if (!accountId) return
    run(["remove", String(accountId)], function (ok, payload, stderrText) {
      if (!ok) {
        reportFailure(payload, stderrText, "Could not remove the account")
        if (handler) handler(false)
        return
      }
      if (accountId === root.accountId) {
        root.accountId = ""
        root.messages = []
        root.selected = null
        root.body = null
      }
      root.notice = "Account removed"
      noticeTimer.restart()
      root.refreshStatus(true)
      if (handler) handler(true)
    }, "remove")
  }

  // Round trip to both servers with the stored credentials. This is the step
  // that tells someone their app password is wrong before their first sync.
  function testAccount(accountId, handler) {
    if (!accountId) return
    run(["test", String(accountId)], function (ok, payload, stderrText) {
      if (handler) {
        handler(ok, payload || { imap: String(stderrText || "failed"), smtp: "" })
      }
    }, "test")
  }

  // A first sync for a freshly added account, independent of which account
  // the window happens to be showing.
  function syncAccount(accountId, handler) {
    if (!accountId) return
    run(["sync", "--account", String(accountId), "--folder", "INBOX",
         "--limit", "200"], function (ok, payload, stderrText) {
      if (ok) {
        root.error = ""
        root.refreshStatus(true)
      }
      if (handler) handler(ok, payload)
    }, "sync-account")
  }

  // Attachment picking runs through the desktop's own file chooser rather
  // than a hand-rolled browser inside the compose form.
  Component {
    id: pickerRunner

    Process {
      id: pickProc
      property var handler: null
      running: false
      stdout: StdioCollector { id: pickOut; waitForEnd: true }
      onExited: function (exitCode) {
        var paths = []
        var lines = String(pickOut.text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          var line = lines[i].trim()
          if (line !== "") paths.push(line)
        }
        if (pickProc.handler) pickProc.handler(exitCode === 0 ? paths : [])
        Qt.callLater(function () { pickProc.destroy() })
      }
    }
  }

  // ------------------------------------------------------------------ drafts

  // A draft lives in the account's Drafts folder, not in this process, so
  // closing the composer — or the whole client — cannot lose it. `replaceUid`
  // is the copy this save supersedes, which the engine deletes once the new
  // one is safely stored.
  function saveDraft(draft, replaceUid, accountId, handler) {
    var id = String(accountId || root.accountId || "")
    if (!id) return null
    var args = ["draft-save", "--account", id]
    if (replaceUid > 0) args = args.concat(["--replace", String(replaceUid)])
    return runWithInput(args, JSON.stringify(draft), handler, "draft")
  }

  function discardDraft(uid, accountId, handler) {
    var id = String(accountId || root.accountId || "")
    if (!id || !(uid > 0)) return null
    return run(["draft-discard", "--account", id, "--uid", String(uid)],
               handler, "draft")
  }

  // ------------------------------------------------------------------- IDLE

  // Idempotent: brings the running watchers in line with the accounts that
  // should have one. Safe to call whenever the account list changes.
  function syncWatchers() {
    if (!root.watchEnabled || !root.configured) {
      root.stopWatching()
      return
    }
    var wanted = ({})
    for (var i = 0; i < root.accounts.length; i++) {
      var account = root.accounts[i]
      // Demo accounts have no server, and an account that lost its
      // authorization would just reconnect-fail in a loop.
      if (!account || account.demo === true || account.authorized === false) continue
      wanted[String(account.id)] = true
    }
    for (var running in root.watchProcs)
      if (!wanted[running]) root.stopWatcher(running)
    for (var id in wanted)
      if (!root.watchProcs[id]) root.startWatcher(id)
  }

  function startWatcher(accountId) {
    var process = watchRunner.createObject(root, { accountId: accountId })
    if (!process) return
    root.watchProcs[accountId] = process
    root.watchCount = Object.keys(root.watchProcs).length
    process.running = true
  }

  function stopWatcher(accountId) {
    var process = root.watchProcs[accountId]
    if (!process) return
    delete root.watchProcs[accountId]
    root.watchCount = Object.keys(root.watchProcs).length
    process.running = false
    Qt.callLater(function () { process.destroy() })
  }

  function stopWatching() {
    for (var id in root.watchProcs) root.stopWatcher(id)
  }

  onWatchEnabledChanged: root.syncWatchers()
  onConfiguredChanged: root.syncWatchers()

  Component {
    id: watchRunner

    Process {
      id: watchProc
      property string accountId: ""
      command: [root.cliPath, "--json", "watch", "--account", watchProc.accountId]
      running: false
      stdout: SplitParser {
        onRead: function (line) {
          var event = Model.parseJson(line, null)
          if (!event) return
          // The engine only speaks up when the folder actually changed, so
          // every sync line is worth a cache read — which is also what raises
          // newMail, and so what puts the notification on screen.
          if (String(event.event || "") === "sync") root.refreshStatus(true)
        }
      }
      // The engine reconnects across network hiccups on its own; if it exits,
      // it gave up. Drop it so polling resumes, and let watchTimer retry.
      onExited: {
        if (root.watchProcs[watchProc.accountId] === watchProc) {
          delete root.watchProcs[watchProc.accountId]
          root.watchCount = Object.keys(root.watchProcs).length
        }
        Qt.callLater(function () { watchProc.destroy() })
      }
    }
  }

  Timer {
    id: watchTimer
    interval: 60000
    repeat: true
    running: root.watchEnabled
    onTriggered: root.syncWatchers()
  }

  function pickFiles(handler) {
    var process = pickerRunner.createObject(root, {
      command: ["zenity", "--file-selection", "--multiple", "--separator=\n",
                "--title=Attach files to this message"],
      handler: handler
    })
    if (!process) {
      root.actionFailed("Could not open the file chooser.")
      return null
    }
    process.running = true
    return process
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
    // A live watcher already hears about new mail the instant it lands, so
    // polling on top of it would just be a second, slower way to find out.
    running: root.configured && root.pollEnabled && !root.watching
    onTriggered: root.sync(false)
  }

  Component.onCompleted: {
    refreshStatus(true)
    refreshOutbox()
    loadImagePolicy()
  }
}
