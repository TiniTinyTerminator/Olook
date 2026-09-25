import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Settings view: everything about the client that isn't a message.
//
// Accounts come first because they are the only part most people ever touch —
// add one, sign it back in when a Microsoft token expires, fix the name that
// goes out on your mail, or take it off this machine entirely.
Item {
  id: root

  property var ui: null
  property var service: null

  property string mode: "accounts"      // accounts | add
  property var rows: []                 // full account list, disabled included
  // Which page the right-hand side is showing: "account:<id>", or one of
  // general, calendar, widget. Empty means "whatever makes sense", which is
  // the first account when there is one.
  property string section: ""

  readonly property string activeSection: {
    if (root.section !== "") return root.section
    return root.rows.length > 0 ? "account:" + root.rows[0].id : "general"
  }

  readonly property var selectedAccount: {
    var wanted = root.activeSection
    if (wanted.indexOf("account:") !== 0) return null
    var id = wanted.substring(8)
    for (var i = 0; i < root.rows.length; i++)
      if (root.rows[i].id === id) return root.rows[i]
    return root.rows.length > 0 ? root.rows[0] : null
  }
  property string confirmRemoveId: ""
  property string testingId: ""
  property var testResults: ({})        // account id -> { ok, imap, smtp }

  signal accountOpened(string accountId)

  function refresh() {
    if (!service) return
    service.listAccounts(function (accounts) { root.rows = accounts })
  }

  function startAdd() {
    root.mode = "add"
    setupPanel.reset()
  }

  // All three are read from bindings that evaluate before the account list
  // has arrived, and once more on the way out when it is emptied, so none of
  // them may assume there is a row.
  function statusText(row) {
    if (!row) return ""
    if (row.demo) return "Sample data"
    if (!row.authorized) return "Needs sign-in"
    if (!row.enabled) return "Paused"
    return "Signed in"
  }

  function statusColor(row) {
    if (!row) return ui.faint
    if (!row.authorized) return ui.urgent
    if (!row.enabled || row.demo) return ui.faint
    return ui.accent
  }

  function authLabel(row) {
    if (!row) return ""
    if (row.demo) return "no server"
    return row.auth === "oauth2" ? "provider sign-in" : "password"
  }

  Component.onCompleted: refresh()
  onVisibleChanged: if (visible) refresh()

  Rectangle {
    anchors.fill: parent
    color: ui.background
  }

  // ------------------------------------------------------------ add account
  MailAccountSetup {
    id: setupPanel
    anchors.fill: parent
    visible: root.mode === "add"
    ui: root.ui
    service: root.service
    onCancelled: {
      root.mode = "accounts"
      root.refresh()
    }
    onFinished: function (accountId) {
      root.mode = "accounts"
      root.refresh()
      root.accountOpened(accountId)
    }
  }

  // ----------------------------------------------------------------- shape
  //
  // A list of places on the left, one of them open on the right. Settings
  // that were a single long scroll are now sorted into the things they are
  // about, because "everything about this account" and "how the client
  // behaves" are different questions and were being answered in one column.
  Row {
    anchors.fill: parent
    visible: root.mode === "accounts"
    spacing: 0

    Item {
      id: nav
      width: Math.max(Style.space(200),
                      Math.min(Style.space(280), Math.round(root.width * 0.26)))
      height: parent.height

      Flickable {
        id: navFlick
        anchors.fill: parent
        anchors.margins: Style.space(12)
        contentWidth: width
        contentHeight: navColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: navColumn
          width: navFlick.width
          spacing: Style.space(2)

          // Above the accounts, because adding one is what you come here to
          // do before there is anything to pick.
          SettingsButton {
            primary: true
            glyph: "󰐕"
            label: "Add account"
            onTriggered: root.startAdd()
          }

          Item { width: 1; height: Style.space(8) }

          NavHeading { text: "Accounts" }

          Repeater {
            model: root.rows

            NavAccount {
              required property var modelData
              width: navColumn.width
              row: modelData
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: root.rows.length === 0
            leftPadding: Style.space(10)
            text: "None yet."
            color: ui.faint
            font.family: ui.fontFamily
            font.pixelSize: Style.font.caption
          }

          Item { width: 1; height: Style.space(10) }

          NavHeading { text: "Client" }

          NavItem { section: "general"; glyph: "󰒓"; label: "General" }
          NavItem { section: "rules"; glyph: "\uDB80\uDE32"; label: "Rules" }
          NavItem { section: "calendar"; glyph: "󰃭"; label: "Calendar" }
          NavItem { section: "widget"; glyph: "󰍜"; label: "Bar widget" }
        }

        MomentumScroll { view: navFlick }
      }
    }

    Rectangle { width: ui.hairline; height: parent.height; color: ui.border }

    // ------------------------------------------------------------ the page
    Item {
      width: parent.width - nav.width - 1
      height: parent.height

      Flickable {
        id: accountsFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: page.height + Style.space(60)
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: page
          y: Style.space(24)
          anchors.horizontalCenter: parent.horizontalCenter
          width: Math.min(Style.space(680), parent.width - Style.space(56))
          spacing: Style.space(14)

          // ------------------------------------------------------ account
          AccountCard {
            width: page.width
            visible: root.activeSection.indexOf("account:") === 0
            row: root.selectedAccount
          }

          // ------------------------------------------------------ general
          Column {
            width: parent.width
            spacing: Style.space(14)
            visible: root.activeSection === "general"
            onVisibleChanged: if (visible) {
              service.refreshOutbox()
              service.checkSetup()
            }

            Text {
              textFormat: Text.PlainText
              text: "General"
              color: ui.foreground
              font.family: ui.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            // Pictures in a message are fetched from whoever sent it, which
            // tells them the mail was opened. This is the one privacy
            // decision the client makes on your behalf, so it is said in full
            // rather than hidden behind a switch labelled "safe".
            Text {
              textFormat: Text.PlainText
              text: "Pictures in messages"
              color: ui.foreground
              font.family: ui.fontFamily
              font.pixelSize: Style.font.subtitle
            }

            Column {
              width: parent.width
              spacing: Style.space(4)

              PolicyChoice {
                value: "verified"
                label: "When the sender is known"
                hint: "Signed by the sender's own domain, or someone you named. "
                      + "Most real mail is signed; a tracking pixel in it will load."
              }

              PolicyChoice {
                value: "trusted"
                label: "Only senders I have named"
                hint: "Nothing loads until you say so for that sender."
              }

              PolicyChoice {
                value: "never"
                label: "Never, always ask"
                hint: "Every message offers the button and none acts on its own."
              }
            }

            // What `omarchy plugin add` does not do: shown until it is done.
            Column {
              id: setupBlock
              readonly property var state: service.setupState
              readonly property bool renderReady: !!(state && state.renderer.active)
              readonly property bool complete: !!(state && state.cli.ok
                                                  && state.renderer.active && state.mailto.ok
                                                  && (!state.launcher || state.launcher.ok))
              width: parent.width
              spacing: Style.space(6)
              visible: !!state && !complete

              Text {
                textFormat: Text.PlainText
                text: "Finish setup"
                color: ui.foreground
                font.family: ui.fontFamily
                font.pixelSize: Style.font.subtitle
              }

              SetupLine {
                done: !!(setupBlock.state && setupBlock.state.cli.ok)
                label: "The olook command in a terminal"
              }
              SetupLine {
                done: setupBlock.renderReady
                label: {
                  var r = setupBlock.state ? setupBlock.state.renderer : null
                  if (!r || r.active) return "Mail rendered as HTML"
                  if (!r.built) return "Mail rendered as HTML" + (r.compiler ? "" : " — needs gcc")
                  if (r.configured) return "Mail rendered as HTML — restart the shell to start it"
                  return "Mail rendered as HTML — "
                    + (r.stale ? "replace the argcshim line in" : "add this line to")
                    + " ~/.config/hypr/hyprland.lua, then restart the shell:"
                }
              }
              // The one step left to you: Olook does not edit Hyprland's
              // config, so the line is offered to copy.
              Row {
                visible: !!(setupBlock.state && setupBlock.state.renderer.built
                            && !setupBlock.state.renderer.active
                            && !setupBlock.state.renderer.configured)
                leftPadding: Style.space(22)
                spacing: Style.space(8)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Math.min(implicitWidth, setupBlock.width - Style.space(110))
                  textFormat: Text.PlainText
                  elide: Text.ElideMiddle
                  text: setupBlock.state ? setupBlock.state.renderer.line : ""
                  color: ui.dim
                  font.family: ui.fontFamily
                  font.pixelSize: Style.font.caption
                }
                SettingsButton {
                  label: "Copy"
                  onTriggered: Quickshell.execDetached(["wl-copy", setupBlock.state.renderer.line])
                }
              }
              SetupLine {
                done: !!(setupBlock.state && setupBlock.state.mailto.ok)
                label: "mailto: links open Olook"
              }
              SetupLine {
                done: !!(setupBlock.state && setupBlock.state.launcher
                         && setupBlock.state.launcher.ok)
                label: "Olook in the app menu"
              }

              SettingsButton {
                primary: true
                glyph: "\uF0AD"
                label: service.settingUp ? "Setting up…" : "Finish setup"
                enabled: !service.settingUp
                onTriggered: service.finishSetup(null)
              }
            }

            // Waiting in the outbox: scheduled, or written while offline.
            Column {
              width: parent.width
              spacing: Style.space(6)
              visible: service.outboxItems.length > 0

              Text {
                textFormat: Text.PlainText
                text: "Waiting to be sent"
                color: ui.foreground
                font.family: ui.fontFamily
                font.pixelSize: Style.font.subtitle
              }

              Repeater {
                model: service.outboxItems

                delegate: Item {
                  required property var modelData
                  width: parent.width
                  height: Style.space(40)

                  Column {
                    anchors.left: parent.left
                    anchors.right: outboxCancel.left
                    anchors.rightMargin: Style.space(10)
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      elide: Text.ElideRight
                      text: String(modelData.subject || "(no subject)")
                      color: ui.foreground
                      font.family: ui.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }

                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      elide: Text.ElideRight
                      text: (modelData.sendAt > Date.now() / 1000
                        ? "Goes out " + Qt.formatDateTime(new Date(modelData.sendAt * 1000),
                                                          "ddd d MMM, HH:mm")
                        : "Waiting for a connection")
                        + ((modelData.to || []).length > 0 ? " — to " + modelData.to.join(", ") : "")
                      color: ui.faint
                      font.family: ui.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  SettingsButton {
                    id: outboxCancel
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    label: "Back to Drafts"
                    onTriggered: service.cancelScheduled(modelData.path)
                  }
                }
              }
            }

            InfoRow {
              label: "Accounts file"
              value: "~/.config/olook/accounts.json"
              hint: "Passwords and tokens live in the keyring, never in this file."
            }

            InfoRow {
              label: "Mail cache"
              value: "~/.local/state/olook/mail.db"
              hint: "Removing an account deletes its cached mail with it."
            }

            Row {
              spacing: Style.space(8)
              topPadding: Style.space(6)

              SettingsButton {
                glyph: "󰑐"
                label: "Check all accounts now"
                onTriggered: {
                  for (var i = 0; i < root.rows.length; i++) {
                    if (root.rows[i].enabled && !root.rows[i].demo)
                      service.syncAccount(root.rows[i].id)
                  }
                }
              }

              SettingsButton {
                glyph: "󰆍"
                label: "Advanced setup in a terminal"
                onTriggered: service.openSetupTerminal()
              }
            }
          }

          // -------------------------------------------------------- rules
          Column {
            id: rulesPage
            width: parent.width
            spacing: Style.space(12)
            visible: root.activeSection === "rules"
            onVisibleChanged: if (visible) service.loadRules()

            property bool markRead: false
            property bool busy: false
            readonly property bool hasCondition: ruleFrom.text.trim() !== ""
              || ruleTo.text.trim() !== "" || ruleSubject.text.trim() !== ""
            readonly property bool hasAction: ruleMove.text.trim() !== ""
              || ruleCategory.text.trim() !== "" || rulesPage.markRead

            Text {
              textFormat: Text.PlainText
              text: "Rules"
              color: ui.foreground
              font.family: ui.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Applied to new mail as it arrives, in every account. Every "
                + "condition you fill in has to match; one you leave empty is not "
                + "looked at."
              color: ui.dim
              font.family: ui.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Text {
              textFormat: Text.PlainText
              visible: service.rules.length === 0
              text: "No rules yet."
              color: ui.faint
              font.family: ui.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Repeater {
              model: service.rules

              delegate: Item {
                required property var modelData
                width: rulesPage.width
                height: Math.max(ruleSays.implicitHeight, Style.space(30)) + Style.space(10)

                Rectangle {
                  anchors.fill: parent
                  radius: ui.radius
                  color: "transparent"
                  border.width: ui.hairline
                  border.color: ui.border
                }

                Text {
                  id: ruleSays
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(12)
                  anchors.right: ruleRemove.left
                  anchors.rightMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  text: String(modelData.says || "")
                  color: ui.foreground
                  font.family: ui.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.Wrap
                }

                SettingsButton {
                  id: ruleRemove
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  danger: true
                  glyph: "\uDB82\uDE7A"
                  label: "Remove"
                  onTriggered: service.removeRule(modelData.index)
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              topPadding: Style.space(8)
              text: "New rule"
              color: ui.foreground
              font.family: ui.fontFamily
              font.pixelSize: Style.font.subtitle
            }

            SettingsField {
              label: "When the sender contains"
              placeholder: "newsletter@example.com, or just example.com"
              input: ruleFrom
              RuleInput { id: ruleFrom }
            }

            SettingsField {
              label: "When a recipient contains"
              placeholder: "list@example.com"
              input: ruleTo
              RuleInput { id: ruleTo }
            }

            SettingsField {
              label: "When the subject contains"
              placeholder: "[ci]"
              input: ruleSubject
              RuleInput { id: ruleSubject }
            }

            SettingsField {
              label: "Move it to the folder"
              placeholder: "Folder name, as the account names it"
              input: ruleMove
              RuleInput { id: ruleMove }
            }

            SettingsField {
              label: "Give it the category"
              placeholder: "Receipts"
              input: ruleCategory
              RuleInput { id: ruleCategory }
            }

            Item {
              width: parent.width
              height: Style.space(28)

              Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)

                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  text: rulesPage.markRead ? "\uDB80\uDD32" : "\uDB80\uDD31"
                  color: rulesPage.markRead ? ui.accent : ui.dim
                  font.family: ui.fontFamily
                  font.pixelSize: Style.font.iconSmall
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Mark it as read"
                  color: ui.foreground
                  font.family: ui.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: rulesPage.markRead = !rulesPage.markRead
              }
            }

            Row {
              spacing: Style.space(10)

              SettingsButton {
                primary: true
                glyph: "\uDB81\uDC15"
                label: rulesPage.busy ? "Adding…" : "Add rule"
                enabled: rulesPage.hasCondition && rulesPage.hasAction && !rulesPage.busy
                onTriggered: {
                  rulesPage.busy = true
                  service.addRule({
                    from: ruleFrom.text.trim(), to: ruleTo.text.trim(),
                    subject: ruleSubject.text.trim(), move: ruleMove.text.trim(),
                    category: ruleCategory.text.trim(), read: rulesPage.markRead
                  }, function (ok) {
                    rulesPage.busy = false
                    if (!ok) return
                    ruleFrom.text = ""; ruleTo.text = ""; ruleSubject.text = ""
                    ruleMove.text = ""; ruleCategory.text = ""
                    rulesPage.markRead = false
                  })
                }
              }

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                visible: !rulesPage.hasCondition || !rulesPage.hasAction
                text: !rulesPage.hasCondition ? "Fill in at least one condition."
                                              : "Choose what should happen."
                color: ui.faint
                font.family: ui.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // ----------------------------------------------------- calendar
          Column {
            width: parent.width
            spacing: Style.space(12)
            visible: root.activeSection === "calendar"

            Text {
              textFormat: Text.PlainText
              text: "Calendar"
              color: ui.foreground
              font.family: ui.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            InfoRow {
              label: "Calendars"
              value: {
                var shown = 0
                for (var i = 0; i < service.calendars.length; i++)
                  if (!service.calendars[i].hidden) shown++
                return shown + " shown of " + service.calendars.length
              }
              hint: "Accounts bring their own calendars once signed in for them. "
                + "Open the calendar and use its calendar list to hide one, or to "
                + "add one from an .ics file, a link or a CalDAV server."
            }

            InfoRow {
              label: "Reminders"
              value: "From the bar's clock"
              hint: "The clock in the bar reminds you before an appointment; "
                + "right-click it to choose how long before, or to turn it off."
            }
          }

          // ------------------------------------------------------- widget
          Column {
            width: parent.width
            spacing: Style.space(12)
            visible: root.activeSection === "widget"

            Text {
              textFormat: Text.PlainText
              text: "Bar widget"
              color: ui.foreground
              font.family: ui.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            InfoRow {
              label: "Check for mail"
              value: "every " + service.syncIntervalSec + " seconds"
              hint: "These belong to the widget rather than to the client, so "
                + "the bar owns them: right-click the Olook icon to change one."
            }

            InfoRow {
              label: "New-mail notifications"
              value: service.notifyOnNew ? "On" : "Off"
            }
          }
        }

        MomentumScroll { view: accountsFlick }
      }
    }
  }

  // ------------------------------------------------------------- components

  component NavHeading: Text {
    textFormat: Text.PlainText
    leftPadding: Style.space(10)
    bottomPadding: Style.space(2)
    color: ui.faint
    font.family: ui.fontFamily
    font.pixelSize: Style.font.caption
  }

  component NavItem: Rectangle {
    id: navItem
    property string section: ""
    property string glyph: ""
    property string label: ""
    readonly property bool current: root.activeSection === navItem.section

    width: parent ? parent.width : 0
    height: Style.space(30)
    radius: ui.radius
    color: navItem.current ? ui.selected
      : (navItemHover.containsMouse ? ui.hover : "transparent")

    Row {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        text: navItem.glyph
        color: navItem.current ? ui.accent : ui.dim
        font.family: ui.fontFamily
        font.pixelSize: Style.font.iconSmall
      }

      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        text: navItem.label
        color: ui.foreground
        font.family: ui.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }

    MouseArea {
      id: navItemHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.section = navItem.section
    }
  }

  // An account in the list: enough to tell them apart and to see which one
  // needs attention, and nothing else -- the rest is on the right.
  component NavAccount: Rectangle {
    id: navAccount
    property var row: null
    readonly property string key: row ? "account:" + row.id : ""
    readonly property bool current: root.activeSection === navAccount.key

    height: Style.space(42)
    radius: ui.radius
    color: navAccount.current ? ui.selected
      : (navAccountHover.containsMouse ? ui.hover : "transparent")

    Rectangle {
      id: navAvatar
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(26)
      height: width
      radius: width / 2
      color: Qt.hsla(Model.avatarHue(String((navAccount.row
             && navAccount.row.email) || "")) / 360, 0.45, 0.42, 1.0)

      Text {
        textFormat: Text.PlainText
        anchors.centerIn: parent
        text: Model.initials(String((navAccount.row && (navAccount.row.name
              || navAccount.row.email)) || ""))
        color: "#ffffff"
        font.family: ui.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }

    Column {
      anchors.left: navAvatar.right
      anchors.leftMargin: Style.space(9)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: 0

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: String((navAccount.row && (navAccount.row.name
              || navAccount.row.email)) || "")
        color: ui.foreground
        font.family: ui.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: navAccount.row ? root.statusText(navAccount.row) : ""
        color: navAccount.row ? root.statusColor(navAccount.row) : ui.faint
        font.family: ui.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    MouseArea {
      id: navAccountHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.section = navAccount.key
    }
  }

  component AccountCard: Rectangle {
    id: cardRoot
    property var row: null
    // The card is the page now rather than a row that opens, so it is open.
    readonly property bool expanded: true

    // Local edits, committed by Save so a half-typed name never gets written.
    property string nameDraft: ""
    property string signatureDraft: ""
    readonly property bool dirty: !!(row
      && (nameDraft !== String(row.name || "")
          || signatureDraft !== String(row.signature || "")))

    function loadDrafts() {
      nameDraft = String((row && row.name) || "")
      signatureDraft = String((row && row.signature) || "")
    }

    onRowChanged: loadDrafts()
    onExpandedChanged: if (expanded) loadDrafts()

    height: cardColumn.height + Style.space(24)
    radius: ui.radius
    color: cardRoot.expanded ? Util.alpha(ui.foreground, 0.05) : "transparent"
    border.width: 1
    border.color: ui.border

    Column {
      id: cardColumn
      y: Style.space(12)
      x: Style.space(14)
      width: parent.width - Style.space(28)
      spacing: Style.space(10)

      // --------------------------------------------------------- summary
      Item {
        width: parent.width
        height: Style.space(38)

        Rectangle {
          id: avatar
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(34)
          height: width
          radius: width / 2
          color: Qt.hsla(Model.avatarHue(String((cardRoot.row && cardRoot.row.email) || "")) / 360,
                         0.45, 0.42, 1.0)

          Text {
            textFormat: Text.PlainText
            anchors.centerIn: parent
            text: Model.initials(String((cardRoot.row && (cardRoot.row.name
                  || cardRoot.row.email)) || ""))
            color: "#ffffff"
            font.family: ui.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
        }

        Column {
          anchors.left: avatar.right
          anchors.leftMargin: Style.space(12)
          anchors.right: cardActions.left
          anchors.rightMargin: Style.space(12)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: String((cardRoot.row && (cardRoot.row.name || cardRoot.row.email)) || "")
            color: ui.foreground
            font.family: ui.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
            elide: Text.ElideRight
          }

          Row {
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              text: String((cardRoot.row && cardRoot.row.email) || "")
              color: ui.dim
              font.family: ui.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              textFormat: Text.PlainText
              text: "·  " + root.statusText(cardRoot.row) + "  ("
                + root.authLabel(cardRoot.row) + ")"
              color: root.statusColor(cardRoot.row)
              font.family: ui.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        Row {
          id: cardActions
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(6)

          SettingsButton {
            visible: !!(cardRoot.row && !cardRoot.row.authorized && !cardRoot.row.demo)
            primary: true
            glyph: "󰌆"
            label: "Sign in"
            onTriggered: root.signIn(cardRoot.row.id)
          }

        }
      }

      // --------------------------------------------------------- expanded
      Column {
        width: parent.width
        spacing: Style.space(10)
        visible: cardRoot.expanded

        Rectangle { width: parent.width; height: ui.hairline; color: ui.border }

        SettingsField {
          label: "Display name"
          placeholder: "Shown as the sender"
          input: cardNameField

          TextInput {
            id: cardNameField
            anchors.fill: parent
            verticalAlignment: TextInput.AlignVCenter
            text: cardRoot.nameDraft
            onTextChanged: cardRoot.nameDraft = text
            color: ui.foreground
            selectionColor: Util.alpha(ui.accent, 0.35)
            selectedTextColor: ui.foreground
            font.family: ui.fontFamily
            font.pixelSize: Style.font.body
            clip: true
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(4)

          Text {
            textFormat: Text.PlainText
            text: "Signature"
            color: ui.faint
            font.family: ui.fontFamily
            font.pixelSize: Style.font.caption
          }

          Rectangle {
            width: parent.width
            height: Style.space(72)
            radius: ui.radius
            color: Util.alpha(ui.foreground, 0.04)
            border.width: 1
            border.color: cardSignatureField.activeFocus ? ui.accent : ui.border

            TextEdit {
              id: cardSignatureField
              anchors.fill: parent
              anchors.margins: Style.space(8)
              text: cardRoot.signatureDraft
              onTextChanged: cardRoot.signatureDraft = text
              color: ui.foreground
              selectionColor: Util.alpha(ui.accent, 0.35)
              selectedTextColor: ui.foreground
              font.family: ui.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: TextEdit.Wrap
              selectByMouse: true
              textFormat: TextEdit.PlainText
              clip: true

              Text {
                textFormat: Text.PlainText
                visible: cardSignatureField.text === ""
                text: "Appended to every message you send from this account."
                color: ui.faint
                font.family: ui.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
          }
        }

        InfoRow {
          label: "Servers"
          value: String((cardRoot.row && cardRoot.row.imapHost) || "—") + "  ·  "
            + String((cardRoot.row && cardRoot.row.smtpHost) || "—")
          hint: ""
        }

        // The test result, when someone has asked for one.
        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: !!(cardRoot.row && root.testResults[cardRoot.row.id])
          text: {
            var result = cardRoot.row ? root.testResults[cardRoot.row.id] : null
            if (!result) return ""
            return "IMAP: " + result.imap + "\nSMTP: " + result.smtp
          }
          color: {
            var result = cardRoot.row ? root.testResults[cardRoot.row.id] : null
            return result && result.ok ? ui.dim : ui.urgent
          }
          font.family: ui.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Flow {
          width: parent.width
          spacing: Style.space(6)

          SettingsButton {
            primary: cardRoot.dirty
            enabled: cardRoot.dirty
            glyph: "󰆓"
            label: "Save"
            onTriggered: service.updateAccount(cardRoot.row.id, {
              name: cardRoot.nameDraft, signature: cardRoot.signatureDraft
            }, function () { root.refresh() })
          }

          SettingsButton {
            glyph: "󰑓"
            label: root.testingId === (cardRoot.row ? cardRoot.row.id : "")
              ? "Checking…" : "Test connection"
            enabled: root.testingId === ""
            onTriggered: root.test(cardRoot.row.id)
          }

          SettingsButton {
            glyph: "󰌆"
            label: cardRoot.row && cardRoot.row.auth === "oauth2"
              ? "Sign in again" : "Change password"
            visible: !!(cardRoot.row && !cardRoot.row.demo)
            onTriggered: root.signIn(cardRoot.row.id)
          }

          SettingsButton {
            glyph: cardRoot.row && cardRoot.row.enabled ? "󰏤" : "󰐊"
            label: cardRoot.row && cardRoot.row.enabled ? "Pause syncing" : "Resume syncing"
            onTriggered: service.updateAccount(cardRoot.row.id,
              { enabled: !cardRoot.row.enabled }, function () { root.refresh() })
          }

          SettingsButton {
            danger: true
            glyph: "󰆴"
            label: root.confirmRemoveId === (cardRoot.row ? cardRoot.row.id : "")
              ? "Really remove?" : "Remove"
            onTriggered: {
              if (root.confirmRemoveId === cardRoot.row.id) {
                root.confirmRemoveId = ""
                service.removeAccount(cardRoot.row.id, function () { root.refresh() })
              } else {
                root.confirmRemoveId = cardRoot.row.id
              }
            }
          }
        }

        // Which folders are in the tree. Folders IMAP cannot show as mail --
        // an Exchange calendar, contacts, tasks -- are guessed by name and
        // left out; the guess can be overruled here, and any folder hidden.
        Column {
          width: parent.width
          spacing: Style.space(2)
          visible: cardFolders.count > 0

          Text {
            textFormat: Text.PlainText
            topPadding: Style.space(6)
            bottomPadding: Style.space(4)
            text: "Folders"
            color: ui.faint
            font.family: ui.fontFamily
            font.pixelSize: Style.font.caption
          }

          Repeater {
            id: cardFolders
            model: cardRoot.row
              ? Model.sortFolders(service.foldersFor(cardRoot.row.id)) : []

            delegate: Item {
              required property var modelData
              readonly property bool shown: String(modelData.kind || "mail") === "mail"
              readonly property bool guessed: String(modelData.kind || "mail")
                === String(modelData.guessedKind || modelData.kind || "mail")
              width: parent.width
              height: Style.space(34)

              Text {
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.right: folderToggle.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                text: Model.folderLabel(modelData)
                  + (shown ? "" : (guessed ? "  — not mail, left out" : "  — hidden"))
                color: shown ? ui.foreground : ui.faint
                font.family: ui.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              SettingsButton {
                id: folderToggle
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                label: shown ? "Hide" : "Show"
                // Setting a folder back to what the name suggests forgets the
                // choice, so a later rename is judged afresh.
                onTriggered: {
                  var want = shown ? "other" : "mail"
                  var auto = String(modelData.guessedKind || "mail") === want
                  service.setFolderKind(cardRoot.row.id, modelData.name,
                                        auto ? "auto" : want)
                }
              }
            }
          }
        }

        // Password re-entry, shown only while a password account is being
        // re-authorized; OAuth accounts get the sign-in card instead.
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: !!(cardRoot.row && root.passwordForId === cardRoot.row.id)

          SettingsField {
            label: "New password"
            placeholder: "Password or app password"
            input: cardPasswordField

            TextInput {
              id: cardPasswordField
              anchors.fill: parent
              verticalAlignment: TextInput.AlignVCenter
              echoMode: TextInput.Password
              color: ui.foreground
              selectionColor: Util.alpha(ui.accent, 0.35)
              selectedTextColor: ui.foreground
              font.family: ui.fontFamily
              font.pixelSize: Style.font.body
              clip: true
              onAccepted: {
                service.setPassword(cardRoot.row.id, text, function () {
                  root.passwordForId = ""
                  root.refresh()
                })
                text = ""
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            text: "Press Enter to store it in the keyring."
            color: ui.faint
            font.family: ui.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // OAuth re-authorization, in place — the same device code the setup
        // panel shows, without leaving the account you are fixing.
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: !!(cardRoot.row && root.signInForId === cardRoot.row.id)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.signInError !== "" ? root.signInError
              : (root.signInCode !== ""
                 ? "Enter " + root.signInCode + " at " + root.signInUri
                   + " — the code is on your clipboard."
                 : (root.signInUri !== "" ? "Finish signing in in your browser…"
                                          : "Starting the sign-in…"))
            color: root.signInError !== "" ? ui.urgent : ui.dim
            font.family: ui.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          SettingsButton {
            visible: root.signInUri !== ""
            primary: true
            glyph: "󰖟"
            label: "Open sign-in page"
            onTriggered: if (Model.isSafeLink(root.signInUri)) Qt.openUrlExternally(root.signInUri)
          }
        }
      }
    }
  }

  // Sign-in state, hoisted out of the cards so only one runs at a time.
  property string passwordForId: ""
  property string signInForId: ""
  property string signInCode: ""
  property string signInUri: ""
  property string signInError: ""

  function signIn(accountId) {
    root.expandedId = accountId
    var row = null
    for (var i = 0; i < root.rows.length; i++)
      if (root.rows[i].id === accountId) row = root.rows[i]
    if (row && row.auth !== "oauth2") {
      root.passwordForId = accountId
      root.signInForId = ""
      return
    }
    root.passwordForId = ""
    root.signInForId = accountId
    root.signInCode = ""
    root.signInUri = ""
    root.signInError = ""
    service.authorize(function (event) {
      var kind = String(event.event || "")
      if (kind === "device_code") {
        root.signInCode = String(event.user_code || "")
        root.signInUri = String(event.verification_uri || "")
      } else if (kind === "open_url") {
        root.signInUri = String(event.url || "")
      } else if (kind === "authorized") {
        root.signInForId = ""
        root.refresh()
        service.syncAccount(accountId)
      } else if (kind === "error") {
        root.signInError = String(event.error || "Sign-in failed.")
      }
    }, accountId)
  }

  function test(accountId) {
    root.testingId = accountId
    service.testAccount(accountId, function (ok, result) {
      var next = ({})
      for (var key in root.testResults) next[key] = root.testResults[key]
      next[accountId] = {
        ok: ok,
        imap: String((result && result.imap) || "no answer"),
        smtp: String((result && result.smtp) || "no answer")
      }
      root.testResults = next
      root.testingId = ""
    })
  }

  component PolicyChoice: Rectangle {
    id: choice
    property string value: ""
    property string label: ""
    property string hint: ""
    readonly property bool current: !!(service && service.imagePolicy === choice.value)

    width: parent ? parent.width : 0
    height: choiceColumn.implicitHeight + Style.space(14)
    radius: ui.radius
    color: choiceHover.containsMouse ? ui.hover : "transparent"
    border.width: 1
    border.color: choice.current ? ui.accent : "transparent"

    Row {
      anchors.fill: parent
      anchors.margins: Style.space(8)
      spacing: Style.space(10)

      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        text: choice.current ? "󰄲" : "󰄱"
        color: choice.current ? ui.accent : ui.dim
        font.family: ui.fontFamily
        font.pixelSize: Style.font.icon
      }

      Column {
        id: choiceColumn
        width: parent.width - Style.space(40)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: choice.label
          color: ui.foreground
          font.family: ui.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: choice.hint
          color: ui.faint
          font.family: ui.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }

    MouseArea {
      id: choiceHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: if (service) service.setImagePolicy(choice.value)
    }
  }

  component InfoRow: Item {
    id: infoRow
    property string label: ""
    property string value: ""
    property string hint: ""

    width: parent ? parent.width : 0
    height: infoColumn.height

    Text {
      id: infoLabel
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.top: parent.top
      width: Style.space(170)
      text: infoRow.label
      color: ui.dim
      font.family: ui.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Column {
      id: infoColumn
      anchors.left: infoLabel.right
      anchors.right: parent.right
      anchors.top: parent.top
      spacing: Style.space(2)

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: infoRow.value
        color: ui.foreground
        font.family: ui.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: infoRow.hint !== ""
        text: infoRow.hint
        color: ui.faint
        font.family: ui.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }
  }

  component SetupLine: Row {
    id: setupLine
    property bool done: false
    property string label: ""
    width: parent ? parent.width : 0
    spacing: Style.space(8)

    Text {
      textFormat: Text.PlainText
      anchors.top: parent.top
      width: Style.space(14)
      text: parent.done ? "\uDB80\uDD32" : "\uDB80\uDD31"
      color: parent.done ? ui.accent : ui.faint
      font.family: ui.fontFamily
      font.pixelSize: Style.font.iconSmall
    }
    Text {
      width: setupLine.width - Style.space(22)
      wrapMode: Text.Wrap
      textFormat: Text.PlainText
      text: parent.label
      color: parent.done ? ui.dim : ui.foreground
      font.family: ui.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  component RuleInput: TextInput {
    anchors.fill: parent
    verticalAlignment: TextInput.AlignVCenter
    clip: true
    color: ui.foreground
    selectionColor: Util.alpha(ui.accent, 0.35)
    selectedTextColor: ui.foreground
    font.family: ui.fontFamily
    font.pixelSize: Style.font.body
  }

  component SettingsField: Item {
    id: settingsField
    property string label: ""
    property string placeholder: ""
    property Item input: null
    default property alias content: settingsHolder.data

    width: parent ? parent.width : 0
    height: Style.space(48)

    Text {
      id: settingsLabel
      textFormat: Text.PlainText
      anchors.top: parent.top
      anchors.left: parent.left
      text: settingsField.label
      color: ui.faint
      font.family: ui.fontFamily
      font.pixelSize: Style.font.caption
    }

    Item {
      id: settingsHolder
      anchors.top: settingsLabel.bottom
      anchors.topMargin: Style.space(4)
      anchors.left: parent.left
      anchors.right: parent.right
      height: Style.space(24)

      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        visible: !!(settingsField.input && settingsField.input.text === "")
        text: settingsField.placeholder
        color: ui.faint
        font.family: ui.fontFamily
        font.pixelSize: Style.font.body
      }
    }

    Rectangle {
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(4)
      width: parent.width
      height: ui.hairline
      color: !!(settingsField.input && settingsField.input.activeFocus)
        ? ui.accent : ui.border
    }

    MouseArea {
      anchors.fill: settingsHolder
      cursorShape: Qt.IBeamCursor
      onClicked: if (settingsField.input) settingsField.input.forceActiveFocus()
      z: -1
    }
  }

  component SettingsButton: Rectangle {
    id: settingsButton
    property string label: ""
    property string glyph: ""
    property bool primary: false
    property bool danger: false
    property bool enabled: true
    signal triggered()

    width: settingsButtonRow.implicitWidth + Style.space(20)
    height: Style.space(30)
    radius: ui.radius
    color: {
      if (!settingsButton.enabled) return Util.alpha(ui.foreground, 0.05)
      if (settingsButton.primary)
        return settingsHover.containsMouse ? Qt.lighter(ui.accent, 1.12) : ui.accent
      if (settingsButton.danger && settingsHover.containsMouse)
        return Util.alpha(ui.urgent, 0.18)
      return settingsHover.containsMouse ? ui.hover : "transparent"
    }
    border.width: settingsButton.primary ? 0 : 1
    border.color: settingsButton.danger ? Util.alpha(ui.urgent, 0.5) : ui.border

    Row {
      id: settingsButtonRow
      anchors.centerIn: parent
      spacing: Style.space(6)

      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        visible: settingsButton.glyph !== ""
        text: settingsButton.glyph
        color: settingsButtonText.color
        font.family: ui.fontFamily
        font.pixelSize: Style.font.iconSmall
      }

      Text {
        id: settingsButtonText
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        text: settingsButton.label
        color: {
          if (!settingsButton.enabled) return ui.faint
          if (settingsButton.primary) return ui.background
          if (settingsButton.danger) return ui.urgent
          return ui.foreground
        }
        font.family: ui.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: settingsButton.primary
      }
    }

    MouseArea {
      id: settingsHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: settingsButton.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: if (settingsButton.enabled) settingsButton.triggered()
    }
  }
}
