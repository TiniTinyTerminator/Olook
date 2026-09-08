import QtQuick
import Quickshell
import qs.Commons

// One message in its own toplevel window.
//
// The client's reading pane is where you skim; this is where a message goes
// when you want to keep it. It is a real xdg toplevel, so Hyprland moves,
// tiles and remembers it like any other app, and it is what the bar widget
// opens when you pick a message there — reading one mail should not have to
// summon the whole client.
//
// The message is pinned at the moment the window opens. The client behind it
// goes on selecting other mail; neither redraws the other.
FloatingWindow {
  id: window

  property var ui: null
  property var service: null
  property var message: null
  property var body: null
  // The account this message arrived on, captured here so a later folder
  // change in the client cannot redirect the reply.
  property var account: null
  property bool showAccount: false

  // Named `dismissed` rather than `closed`: FloatingWindow has a closed()
  // signal of its own.
  signal dismissed()
  signal composeRequested(string kind, var entry, var account)

  title: {
    var subject = window.message ? String(window.message.subject || "") : ""
    return (subject.trim() === "" ? "Message" : subject) + " — Olook"
  }
  color: ui ? ui.background : "#101010"
  implicitWidth: Style.space(820)
  implicitHeight: Style.space(640)
  minimumSize: Qt.size(Style.space(420), Style.space(320))

  onVisibleChanged: if (!visible) window.dismissed()

  MailReader {
    id: reader
    anchors.fill: parent
    ui: window.ui
    service: window.service
    message: window.message
    body: window.body
    account: window.account
    showAccount: window.showAccount
    active: window.visible
    // Already in a window of its own.
    allowPopOut: false

    onReplyRequested: function (kind) {
      window.composeRequested(kind, window.message, window.account)
    }
    onArchiveRequested: {
      if (window.service && window.message) window.service.archive(window.message)
      window.visible = false
    }
    onDeleteRequested: {
      if (window.service && window.message) window.service.remove(window.message)
      window.visible = false
    }
    onFlagRequested: if (window.service && window.message)
      window.service.toggleFlagged(window.message)
    onUnreadRequested: if (window.service && window.message)
      window.service.toggleRead(window.message)
    onAttachmentRequested: function (index) {
      if (window.service && window.message)
        window.service.saveAttachment(window.message, index)
    }
    onShowImagesRequested: {
      if (!window.service || !window.message) return
      window.service.fetchBody(window.message, false, function (body) {
        window.body = body
      }, true)
    }
  }
}
