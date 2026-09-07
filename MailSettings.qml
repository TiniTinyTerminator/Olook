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
  property string expandedId: ""
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

  function statusText(row) {
    if (row.demo) return "Sample data"
    if (!row.authorized) return "Needs sign-in"
    if (!row.enabled) return "Paused"
    return "Signed in"
  }

  function statusColor(row) {
    if (!row.authorized) return ui.urgent
    if (!row.enabled || row.demo) return ui.faint
    return ui.accent
  }

  function authLabel(row) {
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

  // --------------------------------------------------------------- accounts
  Flickable {
    anchors.fill: parent
    visible: root.mode === "accounts"
    contentWidth: width
    contentHeight: page.height + Style.space(60)
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    Column {
      id: page
      y: Style.space(28)
      anchors.horizontalCenter: parent.horizontalCenter
      width: Math.min(Style.space(720), parent.width - Style.space(64))
      spacing: Style.space(14)

      // ----------------------------------------------------------- header
      Item {
        width: parent.width
        height: Style.space(34)

        Text {
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "Mail accounts"
          color: ui.foreground
          font.family: ui.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }

        SettingsButton {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          primary: true
          glyph: "󰐕"
          label: "Add account"
          onTriggered: root.startAdd()
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: root.rows.length === 0
        text: "No accounts yet. Add Gmail, Outlook.com, a Microsoft 365 work "
          + "address, or any IMAP server."
        color: ui.dim
        font.family: ui.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }

      Repeater {
        model: root.rows

        AccountCard {
          required property var modelData
          width: page.width
          row: modelData
        }
      }

      // ------------------------------------------------------------ general
      Text {
        textFormat: Text.PlainText
        text: "General"
        color: ui.foreground
        font.family: ui.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        topPadding: Style.space(10)
      }

      InfoRow {
        label: "Check for mail"
        value: "every " + service.syncIntervalSec + " seconds"
        hint: "Set on the Olook bar widget — right-click the bar icon."
      }

      InfoRow {
        label: "New-mail notifications"
        value: service.notifyOnNew ? "On" : "Off"
        hint: "Also a bar widget setting."
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
  }

  // ------------------------------------------------------------- components

  component AccountCard: Rectangle {
    id: cardRoot
    property var row: null
    readonly property bool expanded: !!(row && root.expandedId === row.id)

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

          SettingsButton {
            glyph: cardRoot.expanded ? "󰅀" : "󰅂"
            label: cardRoot.expanded ? "Close" : "Edit"
            onTriggered: root.expandedId = cardRoot.expanded ? "" : cardRoot.row.id
          }
        }
      }

      // --------------------------------------------------------- expanded
      Column {
        width: parent.width
        spacing: Style.space(10)
        visible: cardRoot.expanded

        Rectangle { width: parent.width; height: 1; color: ui.border }

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
      height: 1
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
