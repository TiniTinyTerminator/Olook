// Pure helpers for the mail UI. No QML imports here on purpose: everything in
// this file is testable with plain node/qmljs and reusable from both the bar
// panel and the full window.
.pragma library

function initials(name, address) {
  var source = String(name || "").trim() || String(address || "").trim()
  if (!source) return "?"
  var at = source.indexOf("@")
  if (at > 0 && source.indexOf(" ") === -1) source = source.substring(0, at)
  var words = source.split(/[\s._-]+/).filter(function (w) { return w.length > 0 })
  if (words.length === 0) return "?"
  if (words.length === 1) return words[0].substring(0, 2).toUpperCase()
  return (words[0][0] + words[words.length - 1][0]).toUpperCase()
}

// Deterministic hue per correspondent, so the same sender keeps the same
// avatar colour between sessions without storing anything.
function avatarHue(seed) {
  var text = String(seed || "")
  var hash = 0
  for (var i = 0; i < text.length; i++) hash = ((hash << 5) - hash + text.charCodeAt(i)) | 0
  return Math.abs(hash) % 360
}

function pad(value) { return value < 10 ? "0" + value : String(value) }

function startOfDay(date) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime()
}

// Short timestamp for a list row: time today, weekday this week, date beyond.
function shortTime(epochSeconds, now) {
  if (!epochSeconds) return ""
  var date = new Date(epochSeconds * 1000)
  var today = startOfDay(now || new Date())
  var stamp = startOfDay(date)
  var days = Math.round((today - stamp) / 86400000)
  if (days <= 0) return pad(date.getHours()) + ":" + pad(date.getMinutes())
  if (days === 1) return "Yesterday"
  if (days < 7) return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][date.getDay()]
  var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  if (date.getFullYear() === (now || new Date()).getFullYear())
    return date.getDate() + " " + months[date.getMonth()]
  return date.getDate() + " " + months[date.getMonth()] + " " + date.getFullYear()
}

function fullTime(epochSeconds) {
  if (!epochSeconds) return ""
  var date = new Date(epochSeconds * 1000)
  var days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
  var months = ["January", "February", "March", "April", "May", "June", "July",
                "August", "September", "October", "November", "December"]
  return days[date.getDay()] + " " + date.getDate() + " " + months[date.getMonth()]
    + " " + date.getFullYear() + " at " + pad(date.getHours()) + ":" + pad(date.getMinutes())
}

// Outlook groups its list by age; the header text is derived, never stored.
function dateGroup(epochSeconds, now) {
  if (!epochSeconds) return "Older"
  var reference = now || new Date()
  var today = startOfDay(reference)
  var days = Math.round((today - startOfDay(new Date(epochSeconds * 1000))) / 86400000)
  if (days <= 0) return "Today"
  if (days === 1) return "Yesterday"
  if (days < 7) return "This week"
  if (days < 30) return "This month"
  return "Older"
}

// Insert group headers into a flat, date-sorted message list.
function withGroupHeaders(messages, now) {
  var rows = []
  var current = ""
  for (var i = 0; i < (messages || []).length; i++) {
    var message = messages[i]
    var group = dateGroup(message.date, now)
    if (group !== current) {
      rows.push({ isHeader: true, title: group, key: "h:" + group })
      current = group
    }
    var row = {}
    for (var key in message) row[key] = message[key]
    row.isHeader = false
    row.key = message.account + ":" + message.folder + ":" + message.uid
    rows.push(row)
  }
  return rows
}

function fileSize(bytes) {
  var value = Number(bytes || 0)
  if (value < 1024) return value + " B"
  if (value < 1024 * 1024) return (value / 1024).toFixed(0) + " KB"
  return (value / (1024 * 1024)).toFixed(1) + " MB"
}

// The virtual folder that shows every account's mail at once. Not an IMAP
// folder: no server has one, nothing is ever moved into it, and every row in
// it remembers the account it actually came from.
var ALL_FOLDER = "__all__"

// Outlook ships colour categories named after their colours and expects you
// to rename them. These are named for what people actually sort mail into, so
// they are useful before being renamed rather than after. They are IMAP
// keywords underneath, which on Gmail means they show up as labels on the
// phone too.
var CATEGORIES = [
  { name: "Work", color: "#4a83d6" },
  { name: "Personal", color: "#4caf7d" },
  { name: "Finance", color: "#d6a24a" },
  { name: "Travel", color: "#9a6ad6" },
  { name: "Follow up", color: "#d66a6a" },
  { name: "Later", color: "#7d8595" }
]

function categoryColor(name) {
  for (var i = 0; i < CATEGORIES.length; i++)
    if (CATEGORIES[i].name.toLowerCase() === String(name || "").toLowerCase())
      return CATEGORIES[i].color
  return ""
}

function isAllFolder(name) {
  return String(name || "") === ALL_FOLDER
}

function senderLabel(message) {
  if (!message) return ""
  return String(message.fromName || message.fromAddr || "Unknown")
}

function recipientLabel(message) {
  if (!message) return ""
  var to = (message.to || []).slice(0, 3).join(", ")
  var extra = (message.to || []).length - 3
  return extra > 0 ? to + " +" + extra : to
}

// Folder glyphs come from the special-use role, not the name, so a German
// "Gesendete Elemente" gets the same icon as an English "Sent".
//
// Every codepoint here was checked by rendering it from the Nerd Font rather
// than taken from a table: the previous set was eight valid glyphs that all
// drew the wrong picture — Inbox was a plus in a box, Sent a target, Trash a
// bluetooth transfer, Flagged a speech bubble.
function folderGlyph(folder) {
  var role = folder && folder.special ? folder.special : ""
  var name = String(folder && folder.name ? folder.name : "").toLowerCase()
  if (role === "allaccounts") return "󰉓"                  // stacked folders
  if (role === "inbox" || name === "inbox") return "󰋻"   // tray, arrow in
  if (role === "sent") return "󰒊"                        // paper plane
  if (role === "drafts") return "󰏫"                      // pencil
  if (role === "trash") return "󰆴"                       // trash can
  if (role === "junk") return "󰀦"                        // alert
  if (role === "archive" || role === "all") return "󰀼"   // archive box
  if (role === "flagged") return "󰈻"                     // flag
  return "󰉋"                                             // folder
}

function folderLabel(folder) {
  var name = String(folder && folder.name ? folder.name : "")
  var role = folder && folder.special ? folder.special : ""
  var pretty = {
    inbox: "Inbox", sent: "Sent Items", drafts: "Drafts", trash: "Deleted Items",
    junk: "Junk Email", archive: "Archive", all: "Archive",
    allaccounts: "All mail"
  }
  if (pretty[role]) return pretty[role]
  if (name.toUpperCase() === "INBOX") return "Inbox"
  var parts = name.split(/[\/.]/)
  return parts[parts.length - 1] || name
}

function parseJson(raw, fallback) {
  try {
    var parsed = JSON.parse(String(raw || ""))
    return parsed === null || parsed === undefined ? fallback : parsed
  } catch (error) {
    return fallback
  }
}

function errorText(payload, fallbackText) {
  if (payload && payload.error) return String(payload.error)
  return fallbackText || "Something went wrong"
}

function badgeText(count) {
  var value = Number(count || 0)
  if (value <= 0) return ""
  return value > 99 ? "99+" : String(value)
}

// Outlook orders its folder pane by role, not alphabetically: Inbox first,
// then the folders it created, then everything the user made.
var FOLDER_ORDER = ["inbox", "drafts", "sent", "archive", "all", "junk", "trash"]

function sortFolders(folders) {
  var list = (folders || []).slice()
  list.sort(function (a, b) {
    var ra = FOLDER_ORDER.indexOf(String(a.special || ""))
    var rb = FOLDER_ORDER.indexOf(String(b.special || ""))
    if (ra === -1) ra = FOLDER_ORDER.length
    if (rb === -1) rb = FOLDER_ORDER.length
    if (ra !== rb) return ra - rb
    return folderLabel(a).localeCompare(folderLabel(b))
  })
  return list
}
