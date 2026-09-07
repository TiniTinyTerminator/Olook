import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Compose form. Inline in the reading pane it behaves like Outlook's inline
// reply; the same component fills a popped-out window when a message wants
// more room than the reading pane has (see MailComposeWindow.qml).
Item {
  id: root

  property var ui: null
  property var service: null
  property var draft: null
  // Set when the form is not writing as whatever account the window happens
  // to be showing — a popped-out window pins its sender this way.
  property var account: null
  // Popped-out windows hide the button that popped them out.
  property bool allowPopOut: true

  readonly property var fromAccount: root.account
    || (service ? service.currentAccount : null)

  signal sendRequested(var draft)
  signal cancelRequested()
  signal popOutRequested()

  property string toText: ""
  property string ccText: ""
  property string subjectText: ""
  property string bodyText: ""
  // plain | markdown | html — how the body is written, and therefore what
  // goes on the wire: plain text alone, or text plus an HTML alternative.
  property string format: "plain"
  property var attachments: []

  // The copy of this message sitting in the Drafts folder. Saving again
  // replaces it; sending or discarding deletes it.
  property int draftUid: 0
  // Files that were on the saved copy but are not on this one, because a
  // reopened draft does not pull its attachments back down.
  property int strandedAttachments: 0
  // Set while loadDraft() is populating the fields, so filling them in does
  // not read as the user typing and schedule a save.
  property bool loading: false

  readonly property bool worthSaving: toText.trim() !== "" || ccText.trim() !== ""
    || subjectText.trim() !== "" || bodyText.trim() !== "" || attachments.length > 0
  // Demo accounts have no server to put a draft on.
  readonly property bool canSaveDraft: !!(service && account && account.demo !== true)

  readonly property bool canSend: toText.trim().length > 0 && !(service && service.busy)

  onDraftChanged: loadDraft()

  function loadDraft() {
    var source = draft || {}
    root.loading = true
    toText = (source.to || []).join(", ")
    ccText = (source.cc || []).join(", ")
    subjectText = String(source.subject || "")
    bodyText = String(source.body || "")
    format = String(source.format || "plain")
    attachments = (source.attachments || []).slice()
    draftUid = Number(source.draftUid || 0)
    strandedAttachments = Number(source.strandedAttachments || 0)
    root.loading = false
  }

  // ------------------------------------------------------------------ drafts

  // Every edit pushes the save out; a pause writes it. The point is that
  // closing the composer, or the whole client, can never lose the message.
  function touch() {
    if (root.loading) return
    if (root.canSaveDraft) autosaveTimer.restart()
  }

  function saveDraft() {
    autosaveTimer.stop()
    if (!root.canSaveDraft || !root.worthSaving) return
    service.saveDraft(root.payload(), root.draftUid, root.account.id,
                      function (ok, payload) {
                        if (ok && payload && payload.uid > 0)
                          root.draftUid = payload.uid
                      })
  }

  // Called by whoever owns this form when it is about to go away.
  function flush() {
    if (autosaveTimer.running) root.saveDraft()
  }

  // Handing this message to another window: the stored draft goes with it, so
  // this form must not save again on its way out.
  function handOff() { autosaveTimer.stop() }

  // Called once the message has actually gone out: the draft has served its
  // purpose and should not linger in the folder.
  function discardStored() {
    autosaveTimer.stop()
    if (root.draftUid > 0 && root.canSaveDraft)
      service.discardDraft(root.draftUid, root.account.id, null)
    root.draftUid = 0
  }

  onToTextChanged: root.touch()
  onCcTextChanged: root.touch()
  onSubjectTextChanged: root.touch()
  onBodyTextChanged: root.touch()
  onFormatChanged: root.touch()
  onAttachmentsChanged: root.touch()

  Timer {
    id: autosaveTimer
    interval: 4000
    repeat: false
    onTriggered: root.saveDraft()
  }

  // Dropping files on the composer attaches them — the same thing the
  // paperclip does, for when the file is already in front of you.
  DropArea {
    anchors.fill: parent
    onEntered: function (drag) {
      if (!drag.hasUrls) drag.accepted = false
    }
    onDropped: function (drop) {
      if (!drop.hasUrls) return
      root.attachUrls(drop.urls)
      drop.accept()
    }
  }

  // file:// URLs from a file manager, turned back into paths the engine can
  // open. Anything that is not a local file is not something we can attach.
  function attachUrls(urls) {
    var next = root.attachments.slice()
    for (var i = 0; i < urls.length; i++) {
      var url = String(urls[i])
      if (url.indexOf("file://") !== 0) continue
      var path = decodeURIComponent(url.substring(7))
      if (path !== "" && next.indexOf(path) === -1) next.push(path)
    }
    root.attachments = next
  }

  // The whole client is driven from the keyboard, so attaching cannot be the
  // one thing that needs a mouse. Unhandled keys bubble up from whichever
  // field has focus, so this works in the pane and in a popped-out window.
  Keys.onPressed: function (event) {
    if (event.key === Qt.Key_A && (event.modifiers & Qt.ControlModifier)
        && (event.modifiers & Qt.ShiftModifier)) {
      root.attach()
      event.accepted = true
    }
  }

  function attach() {
    if (!service) return
    service.pickFiles(function (paths) {
      if (!paths || paths.length === 0) return
      var next = root.attachments.slice()
      for (var i = 0; i < paths.length; i++)
        if (next.indexOf(paths[i]) === -1) next.push(paths[i])
      root.attachments = next
    })
  }

  function detach(path) {
    var next = []
    for (var i = 0; i < root.attachments.length; i++)
      if (root.attachments[i] !== path) next.push(root.attachments[i])
    root.attachments = next
  }

  // What the chosen format actually sends, said once next to the control so
  // nobody has to guess what "Markdown" does to a message.
  readonly property string formatHint: {
    if (root.format === "markdown") return "Sent as text and as HTML"
    if (root.format === "html") return "Sent as you wrote it"
    return "No formatting"
  }

  function baseName(path) {
    var parts = String(path || "").split("/")
    return parts[parts.length - 1] || String(path || "")
  }

  function focusFirstField() {
    if (toText === "") toField.forceActiveFocus()
    else bodyField.forceActiveFocus()
  }

  function splitAddresses(text) {
    var parts = String(text || "").split(/[,;]/)
    var out = []
    for (var i = 0; i < parts.length; i++) {
      var value = parts[i].trim()
      if (value.length > 0) out.push(value)
    }
    return out
  }

  // The draft as the engine wants it. Send uses it, and so does pop-out, so
  // moving a half-written message into its own window loses nothing.
  function payload() {
    var source = draft || {}
    return {
      to: splitAddresses(toText),
      cc: splitAddresses(ccText),
      subject: subjectText,
      body: bodyText,
      format: root.format,
      attachments: root.attachments.slice(),
      inReplyTo: source.inReplyTo || "",
      references: source.references || ""
    }
  }

  function submit() {
    if (!canSend) return
    root.sendRequested(root.payload())
  }

  Rectangle {
    anchors.fill: parent
    color: ui.background
  }

  Column {
    anchors.fill: parent
    spacing: 0

    // ------------------------------------------------------------- header
    Item {
      id: composeHeader
      width: parent.width
      height: Style.space(52)

      Text {
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.leftMargin: Style.space(24)
        anchors.verticalCenter: parent.verticalCenter
        text: String(root.subjectText || "New message")
        color: ui.foreground
        font.family: ui.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        elide: Text.ElideRight
        width: parent.width - Style.space(280)
      }

      Row {
        anchors.right: parent.right
        anchors.rightMargin: Style.space(20)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(8)

        Rectangle {
          width: sendRow.implicitWidth + Style.space(22)
          height: Style.space(30)
          radius: ui.radius
          color: root.canSend
            ? (sendHover.containsMouse ? Qt.lighter(ui.accent, 1.12) : ui.accent)
            : Util.alpha(ui.foreground, 0.08)

          Row {
            id: sendRow
            anchors.centerIn: parent
            spacing: Style.space(7)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: service && service.busy ? "󰔟" : "󰒊"
              color: root.canSend ? ui.background : ui.faint
              font.family: ui.fontFamily
              font.pixelSize: Style.font.iconSmall
            }
            Text {
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              text: service && service.busy ? "Sending…" : "Send"
              color: root.canSend ? ui.background : ui.faint
              font.family: ui.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }
          }

          MouseArea {
            id: sendHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: root.canSend ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: root.submit()
          }
        }

        Rectangle {
          width: Style.space(30)
          height: Style.space(30)
          radius: ui.radius
          color: attachHover.containsMouse ? ui.hover : "transparent"
          border.width: 1
          border.color: ui.border

          Text {
            anchors.centerIn: parent
            text: "󰏢"
            color: root.attachments.length > 0 ? ui.accent : ui.dim
            font.family: ui.fontFamily
            font.pixelSize: Style.font.iconSmall
          }

          MouseArea {
            id: attachHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.attach()
          }

          PanelToolTip {
            visible: attachHover.containsMouse
            text: (root.attachments.length > 0
              ? root.attachments.length + " attached — add more"
              : "Attach files") + "  (Ctrl+Shift+A)"
            fontFamily: ui.fontFamily
          }
        }

        // Pop out: hand this draft to its own window so it can live on
        // another workspace while you go back to reading mail.
        Rectangle {
          visible: root.allowPopOut
          width: Style.space(30)
          height: Style.space(30)
          radius: ui.radius
          color: popOutHover.containsMouse ? ui.hover : "transparent"
          border.width: 1
          border.color: ui.border

          Text {
            anchors.centerIn: parent
            text: "󰏋"
            color: ui.dim
            font.family: ui.fontFamily
            font.pixelSize: Style.font.iconSmall
          }

          MouseArea {
            id: popOutHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.popOutRequested()
          }

          PanelToolTip {
            visible: popOutHover.containsMouse
            text: "Open in its own window  (Ctrl+Shift+O)"
            fontFamily: ui.fontFamily
          }
        }

        Rectangle {
          width: Style.space(30)
          height: Style.space(30)
          radius: ui.radius
          color: discardHover.containsMouse ? ui.hover : "transparent"
          border.width: 1
          border.color: ui.border

          Text {
            anchors.centerIn: parent
            text: "󰅖"
            color: ui.dim
            font.family: ui.fontFamily
            font.pixelSize: Style.font.iconSmall
          }

          MouseArea {
            id: discardHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.cancelRequested()
          }

          PanelToolTip {
            visible: discardHover.containsMouse
            text: root.canSaveDraft ? "Close — keeps a draft  (Esc)"
                                    : "Discard  (Esc)"
            fontFamily: ui.fontFamily
          }
        }
      }

      Rectangle {
        anchors.bottom: parent.bottom
        width: parent.width
        height: 1
        color: ui.border
      }
    }

    // ------------------------------------------------------------- fields
    Column {
      id: fields
      width: parent.width
      spacing: 0

      FieldRow {
        label: "From"
        readOnlyValue: root.fromAccount ? String(root.fromAccount.email) : ""
      }

      FieldRow {
        label: "To"
        field: toField
        TextInput {
          id: toField
          anchors.fill: parent
          verticalAlignment: TextInput.AlignVCenter
          text: root.toText
          onTextChanged: root.toText = text
          color: ui.foreground
          selectionColor: Util.alpha(ui.accent, 0.35)
          selectedTextColor: ui.foreground
          font.family: ui.fontFamily
          font.pixelSize: Style.font.body
          clip: true
          KeyNavigation.tab: ccField

          Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: toField.text === ""
            text: "Recipients, separated by commas"
            color: ui.faint
            font.family: ui.fontFamily
            font.pixelSize: Style.font.body
          }
        }
      }

      FieldRow {
        label: "Cc"
        field: ccField
        TextInput {
          id: ccField
          anchors.fill: parent
          verticalAlignment: TextInput.AlignVCenter
          text: root.ccText
          onTextChanged: root.ccText = text
          color: ui.foreground
          selectionColor: Util.alpha(ui.accent, 0.35)
          selectedTextColor: ui.foreground
          font.family: ui.fontFamily
          font.pixelSize: Style.font.body
          clip: true
          KeyNavigation.tab: subjectField
        }
      }

      FieldRow {
        label: "Subject"
        field: subjectField
        TextInput {
          id: subjectField
          anchors.fill: parent
          verticalAlignment: TextInput.AlignVCenter
          text: root.subjectText
          onTextChanged: root.subjectText = text
          color: ui.foreground
          selectionColor: Util.alpha(ui.accent, 0.35)
          selectedTextColor: ui.foreground
          font.family: ui.fontFamily
          font.pixelSize: Style.font.body
          clip: true
          KeyNavigation.tab: bodyField
        }
      }
    }

    // ------------------------------------------------- format + attachments
    Item {
      id: strip
      width: parent.width
      height: stripColumn.implicitHeight + Style.space(16)

      Column {
        id: stripColumn
        anchors.left: parent.left
        anchors.leftMargin: Style.space(24)
        anchors.right: parent.right
        anchors.rightMargin: Style.space(24)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(8)

        Row {
          spacing: Style.space(8)

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            text: "Write in"
            color: ui.faint
            font.family: ui.fontFamily
            font.pixelSize: Style.font.caption
          }

          Dropdown {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(140)
            height: Style.space(26)
            rowHeight: Style.space(26)
            showLabel: false
            fontFamily: ui.fontFamily
            value: root.format
            options: [
              { value: "plain", label: "Plain text" },
              { value: "markdown", label: "Markdown" },
              { value: "html", label: "HTML" }
            ]
            onChanged: function (next) { root.format = next }
          }

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            text: root.formatHint
            color: ui.faint
            font.family: ui.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Flow {
          width: parent.width
          spacing: Style.space(6)
          visible: root.attachments.length > 0

          Repeater {
            model: root.attachments
            AttachmentChip {
              required property var modelData
              path: modelData
            }
          }
        }

        // A draft reopened from the folder does not bring its files back with
        // it, so say that plainly instead of letting them go missing.
        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: root.strandedAttachments > 0
          text: root.strandedAttachments === 1
            ? "The saved copy has 1 attachment — attach it again to send it."
            : "The saved copy has " + root.strandedAttachments
              + " attachments — attach them again to send them."
          color: ui.urgent
          font.family: ui.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      Rectangle {
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.leftMargin: Style.space(24)
        anchors.right: parent.right
        anchors.rightMargin: Style.space(24)
        height: 1
        color: ui.border
      }
    }

    // --------------------------------------------------------------- body
    Item {
      width: parent.width
      height: parent.height - composeHeader.height - fields.height - strip.height

      Flickable {
        id: bodyFlick
        anchors.fill: parent
        anchors.margins: Style.space(20)
        contentWidth: width
        contentHeight: bodyField.implicitHeight + Style.space(20)
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        TextEdit {
          id: bodyField
          width: bodyFlick.width - Style.space(12)
          text: root.bodyText
          onTextChanged: root.bodyText = text
          color: ui.foreground
          selectionColor: Util.alpha(ui.accent, 0.35)
          selectedTextColor: ui.foreground
          font.family: ui.fontFamily
          font.pixelSize: Style.font.body
          wrapMode: TextEdit.Wrap
          selectByMouse: true
          textFormat: TextEdit.PlainText
          // Ctrl+Enter is the send shortcut everywhere else; keep it here too.
          Keys.onPressed: function (event) {
            if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                && (event.modifiers & Qt.ControlModifier)) {
              root.submit()
              event.accepted = true
            }
          }

          Text {
            anchors.top: parent.top
            anchors.left: parent.left
            visible: bodyField.text === ""
            text: {
              if (root.format === "markdown")
                return "Write your message in Markdown — **bold**, lists, links…"
              if (root.format === "html") return "Write HTML — it is sent as-is."
              return "Write your message…"
            }
            color: ui.faint
            font.family: ui.fontFamily
            font.pixelSize: Style.font.body
          }
        }

        SmoothScroll { view: bodyFlick }
      }
    }
  }

  component AttachmentChip: Rectangle {
    id: attachmentChip
    property string path: ""

    width: attachmentRow.implicitWidth + Style.space(16)
    height: Style.space(26)
    radius: ui.radius
    color: Util.alpha(ui.foreground, 0.06)
    border.width: 1
    border.color: ui.border

    Row {
      id: attachmentRow
      anchors.centerIn: parent
      spacing: Style.space(6)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "󰏢"
        color: ui.dim
        font.family: ui.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        text: root.baseName(attachmentChip.path)
        color: ui.foreground
        font.family: ui.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "󰅖"
        color: removeHover.containsMouse ? ui.urgent : ui.faint
        font.family: ui.fontFamily
        font.pixelSize: Style.font.caption

        MouseArea {
          id: removeHover
          anchors.fill: parent
          anchors.margins: -Style.space(4)
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.detach(attachmentChip.path)
        }
      }
    }
  }

  component FieldRow: Item {
    id: fieldRow
    property string label: ""
    property string readOnlyValue: ""
    property Item field: null
    default property alias content: fieldHolder.data

    width: fields.width
    height: visible ? Style.space(38) : 0

    Text {
      id: fieldLabel
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.leftMargin: Style.space(24)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(60)
      text: fieldRow.label
      color: ui.faint
      font.family: ui.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      textFormat: Text.PlainText
      visible: fieldRow.readOnlyValue !== ""
      anchors.left: fieldLabel.right
      anchors.verticalCenter: parent.verticalCenter
      text: fieldRow.readOnlyValue
      color: ui.dim
      font.family: ui.fontFamily
      font.pixelSize: Style.font.body
    }

    Item {
      id: fieldHolder
      anchors.left: fieldLabel.right
      anchors.right: parent.right
      anchors.rightMargin: Style.space(24)
      anchors.verticalCenter: parent.verticalCenter
      height: Style.space(24)
    }

    MouseArea {
      anchors.fill: fieldHolder
      cursorShape: fieldRow.field ? Qt.IBeamCursor : Qt.ArrowCursor
      onClicked: if (fieldRow.field) fieldRow.field.forceActiveFocus()
      z: -1
    }

    Rectangle {
      anchors.bottom: parent.bottom
      anchors.left: parent.left
      anchors.leftMargin: Style.space(24)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(24)
      height: 1
      color: ui.border
    }
  }
}
