import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Add-an-account panel.
//
// The terminal wizard (`olook setup`) still exists, but nobody should have to
// find it: this walks the same four steps in the window — address, the server
// settings we detected, sign-in, and a real connection test — so a new account
// is a few clicks from the folder tree it will appear in.
Item {
  id: root

  property var ui: null
  property var service: null

  // address | looking | settings | adding | signin | password | testing | done
  property string step: "address"

  property string emailText: ""
  property string nameText: ""
  property string passwordText: ""

  // What discovery found, and the editable copy the advanced rows write to.
  property var found: null
  property bool editServers: false
  property string imapHostText: ""
  property string imapPortText: ""
  property string smtpHostText: ""
  property string smtpPortText: ""
  property string authMode: "password"

  property string newAccountId: ""
  property string userCode: ""
  property string verificationUri: ""
  property string errorText: ""
  property string testImap: ""
  property string testSmtp: ""

  signal finished(string accountId)
  signal cancelled()

  readonly property bool busy: step === "looking" || step === "adding"
    || step === "testing"

  function reset() {
    root.step = "address"
    root.emailText = ""
    root.nameText = ""
    root.passwordText = ""
    root.found = null
    root.editServers = false
    root.newAccountId = ""
    root.userCode = ""
    root.verificationUri = ""
    root.errorText = ""
    root.testImap = ""
    root.testSmtp = ""
    Qt.callLater(function () { emailField.forceActiveFocus() })
  }

  function providerLabel(provider) {
    switch (String(provider || "")) {
    case "gmail": return "Google"
    case "microsoft": return "Microsoft 365 / Outlook"
    case "icloud": return "iCloud"
    case "yahoo": return "Yahoo"
    case "fastmail": return "Fastmail"
    case "proton": return "Proton"
    case "zoho": return "Zoho"
    default: return "IMAP"
    }
  }

  function sourceLabel(source) {
    var text = String(source || "")
    if (text === "builtin") return "known provider"
    if (text.indexOf("mx:") === 0) return "MX record " + text.substring(3)
    if (text === "ispdb") return "Thunderbird's provider database"
    if (text === "autoconfig") return "the domain's autoconfig"
    if (text === "guess") return "a guess from the domain name"
    return text
  }

  // -------------------------------------------------------------- step 1

  function lookUp() {
    var address = root.emailText.trim()
    if (address.indexOf("@") < 1) {
      root.errorText = "That does not look like an email address."
      return
    }
    root.errorText = ""
    root.step = "looking"
    service.discover(address, function (ok, payload) {
      if (!ok || !payload) {
        root.errorText = "Could not look up " + address + ". Check your network, "
          + "or type the server settings in yourself."
        root.found = { provider: "generic", auth: "password",
                       imap: { host: "", port: 993 },
                       smtp: { host: "", port: 587 }, source: "manual" }
      } else {
        root.found = payload
        root.errorText = ""
      }
      root.imapHostText = String(root.found.imap.host || "")
      root.imapPortText = String(root.found.imap.port || 993)
      root.smtpHostText = String(root.found.smtp.host || "")
      root.smtpPortText = String(root.found.smtp.port || 587)
      root.authMode = String(root.found.auth || "password")
      root.editServers = root.found.source === "guess" || root.found.source === "manual"
      root.step = "settings"
    })
  }

  // -------------------------------------------------------------- step 2

  function createAccount() {
    root.errorText = ""
    root.step = "adding"
    service.addAccount({
      email: root.emailText.trim(),
      name: root.nameText.trim(),
      auth: root.authMode,
      imapHost: root.imapHostText.trim(),
      imapPort: parseInt(root.imapPortText, 10) || 0,
      smtpHost: root.smtpHostText.trim(),
      smtpPort: parseInt(root.smtpPortText, 10) || 0
    }, function (ok, account) {
      if (!ok || !account) {
        root.errorText = service.error || "Could not add the account."
        root.step = "settings"
        return
      }
      root.newAccountId = String(account.id)
      if (root.authMode === "oauth2") {
        root.step = "signin"
        root.startOAuth()
      } else {
        root.step = "password"
        Qt.callLater(function () { passwordField.forceActiveFocus() })
      }
    })
  }

  // -------------------------------------------------------------- step 3

  function startOAuth() {
    root.errorText = ""
    root.userCode = ""
    root.verificationUri = ""
    service.authorize(function (event) {
      var kind = String(event.event || "")
      if (kind === "device_code") {
        root.userCode = String(event.user_code || "")
        root.verificationUri = String(event.verification_uri || "")
      } else if (kind === "open_url") {
        root.verificationUri = String(event.url || "")
      } else if (kind === "authorized") {
        root.runTest()
      } else if (kind === "error") {
        root.errorText = String(event.error || "Sign-in failed.")
      }
    }, root.newAccountId)
  }

  function submitPassword() {
    if (root.passwordText === "") return
    root.errorText = ""
    var secret = root.passwordText
    root.passwordText = ""
    root.step = "testing"
    service.setPassword(root.newAccountId, secret, function (ok) {
      if (!ok) {
        root.errorText = service.error || "Could not store the password."
        root.step = "password"
        return
      }
      root.runTest()
    })
  }

  // -------------------------------------------------------------- step 4

  function runTest() {
    root.step = "testing"
    root.testImap = ""
    root.testSmtp = ""
    service.testAccount(root.newAccountId, function (ok, result) {
      root.testImap = String((result && result.imap) || "")
      root.testSmtp = String((result && result.smtp) || "")
      if (!ok) {
        root.errorText = "The account was saved, but the servers turned the "
          + "credentials down."
        root.step = "done"
        return
      }
      root.errorText = ""
      // First sync happens here so the folder tree is populated by the time
      // the panel hands over to the inbox.
      service.syncAccount(root.newAccountId, function () { root.step = "done" })
    })
  }

  function openVerification() {
    if (root.verificationUri !== "") Qt.openUrlExternally(root.verificationUri)
  }

  readonly property bool succeeded: step === "done" && errorText === ""

  Rectangle {
    anchors.fill: parent
    color: ui.background
  }

  Flickable {
    anchors.fill: parent
    contentWidth: width
    contentHeight: card.height + Style.space(80)
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Column {
      id: card
      y: Style.space(36)
      anchors.horizontalCenter: parent.horizontalCenter
      width: Math.min(Style.space(520), parent.width - Style.space(64))
      spacing: Style.space(18)

      // ------------------------------------------------------------ heading
      Column {
        width: parent.width
        spacing: Style.space(6)

        Text {
          text: root.succeeded ? "󰄬" : "󰇮"
          color: root.succeeded ? ui.accent : ui.faint
          font.family: ui.fontFamily
          font.pixelSize: Style.space(40)
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: {
            switch (root.step) {
            case "address": case "looking": return "Add a mail account"
            case "settings": case "adding": return "Server settings"
            case "signin": return "Sign in with " + root.providerLabel(
              root.found ? root.found.provider : "")
            case "password": return "Password"
            case "testing": return "Checking the connection…"
            default: return root.succeeded ? "Account ready" : "Almost there"
            }
          }
          color: ui.foreground
          font.family: ui.fontFamily
          font.pixelSize: Style.font.display
          font.bold: true
          wrapMode: Text.WordWrap
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: {
            switch (root.step) {
            case "address": case "looking":
              return "Gmail, Outlook.com, a Microsoft 365 work account, or any "
                + "IMAP server. Olook looks the servers up for you."
            case "settings": case "adding":
              return root.found
                ? root.providerLabel(root.found.provider) + " — found via "
                  + root.sourceLabel(root.found.source)
                : ""
            case "signin":
              return "Your password never reaches Olook: the provider hands "
                + "back a token instead."
            case "password":
              return "Gmail and Outlook accounts with two-factor sign-in need "
                + "an app password rather than your normal one."
            case "testing":
              return "Signing in to " + root.imapHostText + " and "
                + root.smtpHostText + "…"
            default:
              return root.succeeded
                ? root.emailText + " is set up and its inbox is downloading."
                : root.errorText
            }
          }
          color: root.step === "done" && !root.succeeded ? ui.urgent : ui.dim
          font.family: ui.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }
      }

      // ------------------------------------------------------------ step 1
      Column {
        width: parent.width
        spacing: Style.space(4)
        visible: root.step === "address" || root.step === "looking"

        SetupField {
          id: emailFieldRow
          label: "Email address"
          placeholder: "you@example.com"
          input: emailField

          TextInput {
            id: emailField
            anchors.fill: parent
            verticalAlignment: TextInput.AlignVCenter
            text: root.emailText
            onTextChanged: root.emailText = text
            color: ui.foreground
            selectionColor: Util.alpha(ui.accent, 0.35)
            selectedTextColor: ui.foreground
            font.family: ui.fontFamily
            font.pixelSize: Style.font.body
            clip: true
            KeyNavigation.tab: nameField
            Keys.onReturnPressed: root.lookUp()
          }
        }

        SetupField {
          label: "Your name"
          placeholder: "Shown as the sender"
          input: nameField

          TextInput {
            id: nameField
            anchors.fill: parent
            verticalAlignment: TextInput.AlignVCenter
            text: root.nameText
            onTextChanged: root.nameText = text
            color: ui.foreground
            selectionColor: Util.alpha(ui.accent, 0.35)
            selectedTextColor: ui.foreground
            font.family: ui.fontFamily
            font.pixelSize: Style.font.body
            clip: true
            Keys.onReturnPressed: root.lookUp()
          }
        }
      }

      // ------------------------------------------------------------ step 2
      Column {
        width: parent.width
        spacing: Style.space(10)
        visible: root.step === "settings" || root.step === "adding"

        // The summary everybody reads; the fields below it are for the domains
        // discovery had to guess at.
        Column {
          width: parent.width
          spacing: Style.space(4)
          visible: !root.editServers

          SummaryRow { label: "Account"; value: root.emailText }
          SummaryRow {
            label: "Sign-in"
            value: root.authMode === "oauth2"
              ? root.providerLabel(root.found ? root.found.provider : "") + " sign-in"
              : "Password"
          }
          SummaryRow { label: "IMAP"; value: root.imapHostText + ":" + root.imapPortText }
          SummaryRow { label: "SMTP"; value: root.smtpHostText + ":" + root.smtpPortText }
          SummaryRow {
            label: "Note"
            value: root.found && root.found.note ? String(root.found.note) : ""
            visible: value !== ""
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(4)
          visible: root.editServers

          SetupField {
            label: "IMAP server"
            placeholder: "imap.example.com"
            input: imapHostField
            TextInput {
              id: imapHostField
              anchors.fill: parent
              verticalAlignment: TextInput.AlignVCenter
              text: root.imapHostText
              onTextChanged: root.imapHostText = text
              color: ui.foreground
              font.family: ui.fontFamily
              font.pixelSize: Style.font.body
              clip: true
              KeyNavigation.tab: imapPortField
            }
          }

          SetupField {
            label: "IMAP port"
            placeholder: "993"
            input: imapPortField
            TextInput {
              id: imapPortField
              anchors.fill: parent
              verticalAlignment: TextInput.AlignVCenter
              text: root.imapPortText
              onTextChanged: root.imapPortText = text
              validator: IntValidator { bottom: 1; top: 65535 }
              color: ui.foreground
              font.family: ui.fontFamily
              font.pixelSize: Style.font.body
              clip: true
              KeyNavigation.tab: smtpHostField
            }
          }

          SetupField {
            label: "SMTP server"
            placeholder: "smtp.example.com"
            input: smtpHostField
            TextInput {
              id: smtpHostField
              anchors.fill: parent
              verticalAlignment: TextInput.AlignVCenter
              text: root.smtpHostText
              onTextChanged: root.smtpHostText = text
              color: ui.foreground
              font.family: ui.fontFamily
              font.pixelSize: Style.font.body
              clip: true
              KeyNavigation.tab: smtpPortField
            }
          }

          SetupField {
            label: "SMTP port"
            placeholder: "587"
            input: smtpPortField
            TextInput {
              id: smtpPortField
              anchors.fill: parent
              verticalAlignment: TextInput.AlignVCenter
              text: root.smtpPortText
              onTextChanged: root.smtpPortText = text
              validator: IntValidator { bottom: 1; top: 65535 }
              color: ui.foreground
              font.family: ui.fontFamily
              font.pixelSize: Style.font.body
              clip: true
            }
          }
        }

        // Some Gmail and Outlook.com accounts are still reached with an app
        // password, so the detected sign-in method has to be overridable.
        Row {
          spacing: Style.space(8)
          visible: root.editServers

          AuthChip {
            label: root.providerLabel(root.found ? root.found.provider : "") + " sign-in"
            mode: "oauth2"
          }
          AuthChip { label: "Password"; mode: "password" }
        }

        Text {
          textFormat: Text.PlainText
          text: root.editServers ? "Use the detected settings" : "Edit server settings"
          color: ui.accent
          font.family: ui.fontFamily
          font.pixelSize: Style.font.bodySmall

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.editServers = !root.editServers
          }
        }
      }

      // ------------------------------------------------------------ step 3
      Column {
        width: parent.width
        spacing: Style.space(12)
        visible: root.step === "signin"

        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: root.userCode !== ""
          text: "Open " + root.verificationUri + " and enter this code — it is "
            + "already on your clipboard."
          color: ui.dim
          font.family: ui.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Rectangle {
          visible: root.userCode !== ""
          width: setupCode.implicitWidth + Style.space(32)
          height: Style.space(46)
          radius: ui.radius
          color: Util.alpha(ui.accent, 0.12)
          border.width: 1
          border.color: Util.alpha(ui.accent, 0.5)

          Text {
            id: setupCode
            anchors.centerIn: parent
            text: root.userCode
            color: ui.accent
            font.family: ui.fontFamily
            font.pixelSize: Style.font.display
            font.bold: true
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: root.userCode === "" && root.errorText === ""
          text: root.verificationUri === ""
            ? "Starting the sign-in…"
            : "Finish signing in in your browser, then come back here."
          color: ui.dim
          font.family: ui.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }
      }

      // ------------------------------------------------------------ step 3b
      Column {
        width: parent.width
        spacing: Style.space(4)
        visible: root.step === "password"

        SetupField {
          label: "Password"
          placeholder: "Password or app password"
          input: passwordField

          TextInput {
            id: passwordField
            anchors.fill: parent
            verticalAlignment: TextInput.AlignVCenter
            text: root.passwordText
            onTextChanged: root.passwordText = text
            echoMode: TextInput.Password
            color: ui.foreground
            selectionColor: Util.alpha(ui.accent, 0.35)
            selectedTextColor: ui.foreground
            font.family: ui.fontFamily
            font.pixelSize: Style.font.body
            clip: true
            Keys.onReturnPressed: root.submitPassword()
          }
        }
      }

      // ------------------------------------------------------------ step 4
      Column {
        width: parent.width
        spacing: Style.space(4)
        visible: root.step === "done" && (root.testImap !== "" || root.testSmtp !== "")

        SummaryRow { label: "IMAP"; value: root.testImap }
        SummaryRow { label: "SMTP"; value: root.testSmtp }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: root.errorText !== "" && root.step !== "done"
        text: root.errorText
        color: ui.urgent
        font.family: ui.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }

      // ----------------------------------------------------------- actions
      Row {
        spacing: Style.space(8)

        SetupButton {
          primary: true
          label: {
            switch (root.step) {
            case "address": return "Continue"
            case "looking": return "Looking up…"
            case "settings": return "Add account"
            case "adding": return "Adding…"
            case "signin": return root.errorText !== "" ? "Try again"
              : (root.verificationUri === "" ? "Starting…" : "Open sign-in page")
            case "password": return "Sign in"
            case "testing": return "Checking…"
            default: return root.succeeded ? "Go to inbox" : "Open anyway"
            }
          }
          enabled: {
            switch (root.step) {
            case "address": return root.emailText.trim() !== ""
            case "settings": return root.imapHostText.trim() !== ""
              || root.authMode === "oauth2"
            case "signin": return root.errorText !== "" || root.verificationUri !== ""
            case "password": return root.passwordText !== ""
            case "done": return true
            default: return false
            }
          }
          onTriggered: {
            switch (root.step) {
            case "address": root.lookUp(); break
            case "settings": root.createAccount(); break
            case "signin":
              if (root.errorText !== "") root.startOAuth()
              else root.openVerification()
              break
            case "password": root.submitPassword(); break
            case "done": root.finished(root.newAccountId); break
            }
          }
        }

        SetupButton {
          label: root.step === "done" ? "Add another" : "Cancel"
          enabled: !root.busy
          onTriggered: {
            if (root.step === "done") root.reset()
            else root.cancelled()
          }
        }

        // A wrong password is worth retrying without walking the whole panel
        // again, and a failed test is exactly when you want that.
        SetupButton {
          visible: root.step === "done" && !root.succeeded
          label: "Retry sign-in"
          onTriggered: {
            if (root.authMode === "oauth2") { root.step = "signin"; root.startOAuth() }
            else { root.step = "password"; root.errorText = "" }
          }
        }
      }
    }
  }

  // ------------------------------------------------------------- components

  component AuthChip: Rectangle {
    id: authChip
    property string label: ""
    property string mode: ""
    readonly property bool current: root.authMode === authChip.mode

    width: authChipText.implicitWidth + Style.space(22)
    height: Style.space(28)
    radius: ui.radius
    color: authChip.current ? ui.selected
      : (authChipHover.containsMouse ? ui.hover : "transparent")
    border.width: 1
    border.color: authChip.current ? Util.alpha(ui.accent, 0.6) : ui.border

    Text {
      id: authChipText
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: authChip.label
      color: authChip.current ? ui.accent : ui.dim
      font.family: ui.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    MouseArea {
      id: authChipHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.authMode = authChip.mode
    }
  }

  component SummaryRow: Item {
    id: summaryRow
    property string label: ""
    property string value: ""

    width: card.width
    height: visible ? Style.space(24) : 0

    Text {
      id: summaryLabel
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(76)
      text: summaryRow.label
      color: ui.faint
      font.family: ui.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      textFormat: Text.PlainText
      anchors.left: summaryLabel.right
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: summaryRow.value
      color: ui.foreground
      font.family: ui.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }
  }

  component SetupField: Item {
    id: setupField
    property string label: ""
    property string placeholder: ""
    property Item input: null
    default property alias content: setupHolder.data

    width: card.width
    height: Style.space(52)

    Text {
      id: setupLabel
      textFormat: Text.PlainText
      anchors.top: parent.top
      anchors.left: parent.left
      text: setupField.label
      color: ui.faint
      font.family: ui.fontFamily
      font.pixelSize: Style.font.caption
    }

    Item {
      id: setupHolder
      anchors.top: setupLabel.bottom
      anchors.topMargin: Style.space(4)
      anchors.left: parent.left
      anchors.right: parent.right
      height: Style.space(24)

      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        visible: !!(setupField.input && setupField.input.text === "")
        text: setupField.placeholder
        color: ui.faint
        font.family: ui.fontFamily
        font.pixelSize: Style.font.body
      }
    }

    Rectangle {
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(6)
      width: parent.width
      height: 1
      color: !!(setupField.input && setupField.input.activeFocus) ? ui.accent : ui.border
    }

    MouseArea {
      anchors.fill: setupHolder
      cursorShape: Qt.IBeamCursor
      onClicked: if (setupField.input) setupField.input.forceActiveFocus()
      z: -1
    }
  }

  component SetupButton: Rectangle {
    id: setupButton
    property string label: ""
    property bool primary: false
    property bool enabled: true
    signal triggered()

    width: setupButtonText.implicitWidth + Style.space(28)
    height: Style.space(32)
    radius: ui.radius
    color: {
      if (!setupButton.enabled) return Util.alpha(ui.foreground, 0.06)
      if (setupButton.primary)
        return setupButtonHover.containsMouse ? Qt.lighter(ui.accent, 1.12) : ui.accent
      return setupButtonHover.containsMouse ? ui.hover : "transparent"
    }
    border.width: setupButton.primary ? 0 : 1
    border.color: ui.border

    Text {
      id: setupButtonText
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: setupButton.label
      color: !setupButton.enabled ? ui.faint
        : (setupButton.primary ? ui.background : ui.foreground)
      font.family: ui.fontFamily
      font.pixelSize: Style.font.body
      font.bold: setupButton.primary
    }

    MouseArea {
      id: setupButtonHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: setupButton.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: if (setupButton.enabled) setupButton.triggered()
    }
  }
}
