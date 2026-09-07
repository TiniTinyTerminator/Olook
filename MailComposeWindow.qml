import QtQuick
import Quickshell
import qs.Commons
import "Model.js" as Model

// A message being written in its own toplevel window.
//
// The inline composer is right for a quick reply, but a long message wants a
// window of its own — one you can push to another workspace and come back to,
// which is exactly what Outlook's separate compose window is for. It is a real
// xdg toplevel, so Hyprland moves, tiles and remembers it like any other app.
FloatingWindow {
  id: window

  property var ui: null
  property var service: null
  property var draft: null
  // The account the message was started from, captured at pop-out time so a
  // later folder change in the main window cannot redirect the sender.
  property var account: null

  // Named `dismissed` rather than `closed`: FloatingWindow already has a
  // closed() signal of its own.
  signal dismissed()

  title: {
    var subject = composeForm.subjectText.trim()
    return (subject === "" ? "New message" : subject) + " — Olook"
  }
  color: ui ? ui.background : "#101010"
  implicitWidth: Style.space(760)
  implicitHeight: Style.space(620)
  minimumSize: Qt.size(Style.space(480), Style.space(360))

  onVisibleChanged: {
    if (visible) return
    // Whatever was typed goes to Drafts before the window goes away.
    composeForm.flush()
    window.dismissed()
  }

  MailCompose {
    id: composeForm
    anchors.fill: parent
    ui: window.ui
    service: window.service
    draft: window.draft
    account: window.account
    // Already popped out; the button would have nowhere to go.
    allowPopOut: false

    onSendRequested: function (payload) {
      window.service.send(payload, function (ok) {
        if (!ok) return
        composeForm.discardStored()
        window.visible = false
      }, window.account ? window.account.id : "")
    }
    onCancelRequested: window.visible = false
  }

  Component.onCompleted: Qt.callLater(function () { composeForm.focusFirstField() })
}
