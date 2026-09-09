import QtQuick
import QtQuick.Controls
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

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Not built yet. The accounts already here carry one, and "
                + "the engine speaks to the same servers, so what is missing "
                + "is the reading and writing of calendar data rather than a "
                + "way to reach it."
              color: ui.dim
              font.family: ui.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
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
            onTriggered: Qt.openUrlExternally(root.signInUri)
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
