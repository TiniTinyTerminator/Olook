import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Sign-in card. Microsoft and Google both hand back a short code the user
// types on another device (or a browser tab we open for them), so the flow has
// to be visible in the app rather than buried in a terminal — a Microsoft 365
// token expires on its own schedule and this is where you land when it does.
Item {
  id: root

  property var ui: null
  property var service: null

  property string state: "idle"      // idle | starting | code | browser | done | error
  property string userCode: ""
  property string verificationUri: ""
  property string errorText: ""

  signal addAccountRequested()

  readonly property var account: service ? service.currentAccount : null
  readonly property bool configured: service ? service.configured : false

  function start() {
    if (!service || state === "starting" || state === "code") return
    root.state = "starting"
    root.errorText = ""
    root.userCode = ""
    service.authorize(function (event) {
      var kind = String(event.event || "")
      if (kind === "device_code") {
        root.userCode = String(event.user_code || "")
        root.verificationUri = String(event.verification_uri || "")
        root.state = "code"
      } else if (kind === "open_url") {
        root.verificationUri = String(event.url || "")
        root.state = "browser"
      } else if (kind === "authorized") {
        root.state = "done"
        service.refreshStatus(true)
        service.sync(false)
      } else if (kind === "extras_authorized" || kind === "extras_failed") {
        // The contacts and calendar consent follows the mail one and sends
        // the panel back through "browser" on its way. Mail is already in by
        // then, so this only has to put the panel back where it was.
        root.state = "done"
        service.refreshStatus(true)
      } else if (kind === "error") {
        root.errorText = String(event.error || "Sign-in failed")
        root.state = "error"
      }
    })
  }

  function openVerification() {
    if (Model.isSafeLink(root.verificationUri)) Qt.openUrlExternally(root.verificationUri)
  }

  Rectangle {
    anchors.fill: parent
    color: ui.background
  }

  Column {
    anchors.centerIn: parent
    width: Math.min(Style.space(460), parent.width - Style.space(60))
    spacing: Style.space(16)

    Text {
      textFormat: Text.PlainText
      anchors.horizontalCenter: parent.horizontalCenter
      text: root.configured ? "󰌾" : "󰇮"
      color: ui.faint
      font.family: ui.fontFamily
      font.pixelSize: Style.space(48)
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      text: root.configured
        ? "Sign in to " + (root.account ? root.account.email : "your account")
        : "Add a mail account"
      color: ui.foreground
      font.family: ui.fontFamily
      font.pixelSize: Style.font.title
      font.bold: true
      wrapMode: Text.WordWrap
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      visible: root.state === "idle" || root.state === "starting"
      text: root.configured
        ? "This account needs a fresh sign-in before Olook can read its mail."
        : "Gmail, Outlook.com, Microsoft 365, or any IMAP server — Olook finds the server settings for you."
      color: ui.dim
      font.family: ui.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }

    // ---------------------------------------------------------- device code
    Column {
      width: parent.width
      spacing: Style.space(10)
      visible: root.state === "code"

      Text {
        textFormat: Text.PlainText
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: "Enter this code at " + root.verificationUri
        color: ui.dim
        font.family: ui.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }

      Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        width: codeText.implicitWidth + Style.space(32)
        height: Style.space(46)
        radius: ui.radius
        color: Util.alpha(ui.accent, 0.12)
        border.width: 1
        border.color: Util.alpha(ui.accent, 0.5)

        Text {
          id: codeText
          textFormat: Text.PlainText
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
        horizontalAlignment: Text.AlignHCenter
        text: "The code is on your clipboard. Waiting for you to approve…"
        color: ui.faint
        font.family: ui.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      visible: root.state === "browser"
      text: "Finish signing in in your browser…"
      color: ui.dim
      font.family: ui.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      visible: root.state === "error"
      text: root.errorText
      color: ui.urgent
      font.family: ui.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }

    // -------------------------------------------------------------- actions
    Row {
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.space(8)

      PrimaryButton {
        label: {
          if (!root.configured) return "Add an account"
          if (root.state === "starting") return "Starting…"
          if (root.state === "code" || root.state === "browser") return "Open sign-in page"
          if (root.state === "error") return "Try again"
          return "Sign in"
        }
        onTriggered: {
          if (!root.configured) root.addAccountRequested()
          else if (root.state === "code" || root.state === "browser") root.openVerification()
          else root.start()
        }
      }

      SecondaryButton {
        visible: root.configured
        label: "Add another account"
        onTriggered: root.addAccountRequested()
      }

      SecondaryButton {
        label: "Set up in a terminal"
        onTriggered: if (root.service) root.service.openSetupTerminal()
      }
    }
  }

  component PrimaryButton: Rectangle {
    id: primary
    property string label: ""
    signal triggered()

    width: primaryText.implicitWidth + Style.space(28)
    height: Style.space(32)
    radius: ui.radius
    color: primaryHover.containsMouse ? Qt.lighter(ui.accent, 1.12) : ui.accent

    Text {
      id: primaryText
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: primary.label
      color: ui.background
      font.family: ui.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
    }

    MouseArea {
      id: primaryHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: primary.triggered()
    }
  }

  component SecondaryButton: Rectangle {
    id: secondary
    property string label: ""
    signal triggered()

    width: secondaryText.implicitWidth + Style.space(28)
    height: Style.space(32)
    radius: ui.radius
    color: secondaryHover.containsMouse ? ui.hover : "transparent"
    border.width: 1
    border.color: ui.border

    Text {
      id: secondaryText
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: secondary.label
      color: ui.foreground
      font.family: ui.fontFamily
      font.pixelSize: Style.font.body
    }

    MouseArea {
      id: secondaryHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: secondary.triggered()
    }
  }
}
