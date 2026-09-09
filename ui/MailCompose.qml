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
  property string bccText: ""
  // Hidden until wanted, the way Outlook hides it: most mail has no blind
  // copy, and a field that is nearly always empty is a field in the way.
  property bool showBcc: false
  property string subjectText: ""
  property string bodyText: ""
  // The chain being replied to, kept apart from what you are writing so it
  // can be folded away. Rejoined when the message goes out.
  property string quotedText: ""
  // The same chain as markup, when the message being replied to was HTML.
  // What goes out, and what the fold shows when the shell can render it.
  property string quotedHtml: ""
  property bool quoteExpanded: false
  readonly property bool quotedIsHtml: root.quotedHtml !== ""
    && Qt.application.arguments.length > 0
  // What the markdown will look like when it arrives, rendered by the engine
  // that will send it rather than by a second opinion living here.
  property string previewHtml: ""
  readonly property bool showPreview: root.format === "markdown"
    && Qt.application.arguments.length > 0 && root.bodyText.trim() !== ""

  Timer {
    id: previewTimer
    interval: 400
    onTriggered: {
      if (!root.service || root.format !== "markdown") return
      root.service.renderMarkdown(root.bodyText, function (html) {
        root.previewHtml = html
      })
    }
  }

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
    || bccText.trim() !== ""
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
    bccText = (source.bcc || []).join(", ")
    showBcc = bccText !== ""
    subjectText = String(source.subject || "")
    bodyText = String(source.body || "")
    quotedText = String(source.quoted || "")
    quotedHtml = String(source.quotedHtml || "")
    quoteExpanded = false
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
  onBccTextChanged: root.touch()
  onSubjectTextChanged: root.touch()
  onBodyTextChanged: {
    root.touch()
    if (root.format === "markdown") previewTimer.restart()
  }
  onFormatChanged: {
    root.touch()
    if (root.format === "markdown") previewTimer.restart()
  }
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

  // ---------------------------------------------- recipient completion
  //
  // The address book is the mail already on disk, so the names offered are
  // the people actually written to. Only the fragment after the last comma is
  // matched: recipient fields hold a list, and the one being typed is the
  // last of them.
  property var completingField: null
  property int completionIndex: 0
  property real completionX: 0
  property real completionY: 0

  readonly property string completionFragment: {
    if (!root.completingField) return ""
    var text = String(root.completingField.text || "")
    return text.slice(text.lastIndexOf(",") + 1).trim()
  }

  readonly property var completions: {
    var needle = root.completionFragment.toLowerCase()
    // One letter matches most of an address book, which is not a suggestion.
    if (!root.service || needle.length < 2) return []
    var people = root.service.contacts || []
    var out = []
    for (var i = 0; i < people.length && out.length < 6; i++) {
      var person = people[i]
      if (String(person.address).indexOf(needle) >= 0
          || String(person.name || "").toLowerCase().indexOf(needle) >= 0)
        out.push(person)
    }
    return out
  }

  function beginCompletion(field) {
    root.completingField = field
    root.completionIndex = 0
    if (!field) return
    var point = field.mapToItem(root, 0, field.height + Style.space(6))
    root.completionX = point.x
    root.completionY = point.y
  }

  function acceptCompletion(person) {
    var field = root.completingField
    if (!field || !person) return
    var text = String(field.text || "")
    var cut = text.lastIndexOf(",")
    var head = cut < 0 ? "" : text.slice(0, cut + 1) + " "
    field.text = head + (person.name
      ? person.name + " <" + person.address + ">" : person.address) + ", "
    field.cursorPosition = field.text.length
    root.completionIndex = 0
  }

  // Returns true when the key belonged to the suggestion list rather than to
  // the field, so the caller knows to stop there.
  function completionKey(event) {
    if (root.completions.length === 0) return false
    if (event.key === Qt.Key_Down) {
      root.completionIndex = (root.completionIndex + 1) % root.completions.length
      return true
    }
    if (event.key === Qt.Key_Up) {
      root.completionIndex = (root.completionIndex + root.completions.length - 1)
        % root.completions.length
      return true
    }
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
        || event.key === Qt.Key_Tab) {
      root.acceptCompletion(root.completions[root.completionIndex])
      return true
    }
    if (event.key === Qt.Key_Escape) {
      root.completingField = null
      return true
    }
    return false
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
      bcc: splitAddresses(bccText),
      subject: subjectText,
      // What was written and the chain stay apart all the way to the engine:
      // it renders the reply as it was typed and the original as the markup
      // it arrived in, and joins them once per alternative.
      body: bodyText,
      quoted: root.quotedText,
      quotedHtml: root.quotedHtml,
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

  Component.onCompleted: if (root.service && (root.service.contacts || []).length === 0)
    root.service.loadContacts("")

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
          onActiveFocusChanged: root.beginCompletion(activeFocus ? toField : null)
          Keys.onPressed: function (event) {
            if (root.completingField === toField && root.completionKey(event))
              event.accepted = true
          }
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
          onActiveFocusChanged: root.beginCompletion(activeFocus ? ccField : null)
          Keys.onPressed: function (event) {
            if (root.completingField === ccField && root.completionKey(event))
              event.accepted = true
          }
          anchors.rightMargin: bccToggle.width + Style.space(8)
          verticalAlignment: TextInput.AlignVCenter
          text: root.ccText
          onTextChanged: root.ccText = text
          color: ui.foreground
          selectionColor: Util.alpha(ui.accent, 0.35)
          selectedTextColor: ui.foreground
          font.family: ui.fontFamily
          font.pixelSize: Style.font.body
          clip: true
          KeyNavigation.tab: root.showBcc ? bccField : subjectField
        }

        Text {
          id: bccToggle
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          visible: !root.showBcc
          text: "Bcc"
          color: bccHover.containsMouse ? ui.accent : ui.faint
          font.family: ui.fontFamily
          font.pixelSize: Style.font.caption

          MouseArea {
            id: bccHover
            anchors.fill: parent
            anchors.margins: -Style.space(6)
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              root.showBcc = true
              bccField.forceActiveFocus()
            }
          }
        }
      }

      FieldRow {
        label: "Bcc"
        field: bccField
        visible: root.showBcc
        TextInput {
          id: bccField
          anchors.fill: parent
          onActiveFocusChanged: root.beginCompletion(activeFocus ? bccField : null)
          Keys.onPressed: function (event) {
            if (root.completingField === bccField && root.completionKey(event))
              event.accepted = true
          }
          verticalAlignment: TextInput.AlignVCenter
          text: root.bccText
          onTextChanged: root.bccText = text
          color: ui.foreground
          selectionColor: Util.alpha(ui.accent, 0.35)
          selectedTextColor: ui.foreground
          font.family: ui.fontFamily
          font.pixelSize: Style.font.body
          clip: true
          KeyNavigation.tab: subjectField

          Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: bccField.text === ""
            text: "Blind copies — nobody else sees these"
            color: ui.faint
            font.family: ui.fontFamily
            font.pixelSize: Style.font.body
          }
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
        contentHeight: bodyColumn.implicitHeight + Style.space(20)
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: bodyColumn
          width: bodyFlick.width - Style.space(12)
          spacing: Style.space(10)

          TextEdit {
            id: bodyField
            width: parent.width
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

          // The message being replied to. Folded by default: it is context, not
          // the thing being written, and a reply that opens onto a screenful of
          // someone else's text is a worse place to start. Still there, still
          // editable once opened, and still sent either way.
          Rectangle {
            visible: root.quotedText !== "" || root.quotedHtml !== ""
            width: Style.space(46)
            height: Style.space(22)
            radius: ui.radius
            color: quoteHover.containsMouse ? ui.hover : ui.surface
            border.width: 1
            border.color: ui.border

            Text {
              anchors.centerIn: parent
              text: "\u00b7\u00b7\u00b7"
              color: ui.dim
              font.family: ui.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }

            MouseArea {
              id: quoteHover
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.quoteExpanded = !root.quoteExpanded
            }

            PanelToolTip {
              visible: quoteHover.containsMouse
              text: root.quoteExpanded ? "Hide the quoted message"
                                       : "Show the quoted message"
              fontFamily: ui.fontFamily
            }
          }

          // The preview. Below what is being written rather than beside it:
          // the composer is often half a window wide, and a column split in
          // two is two columns too narrow to write in.
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.showPreview

            Rectangle {
              width: parent.width
              height: 1
              color: ui.border
            }

            Text {
              textFormat: Text.PlainText
              text: "Preview"
              color: ui.faint
              font.family: ui.fontFamily
              font.pixelSize: Style.font.caption
            }

            Loader {
              id: previewView
              width: parent.width
              height: item ? item.contentHeight : 0
              active: root.showPreview
              source: "MailHtmlView.qml"
              onLoaded: item.fragment = Qt.binding(function () {
                return root.previewHtml
              })
            }
          }

          // The original as it arrived. Read-only when it is HTML: the reply
          // is what you are writing, and a quoted page is not something this
          // editor can offer to change. Its remote images stay unfetched
          // while the reply is only being written; they still travel with it.
          Loader {
            id: quotedView
            visible: root.quotedIsHtml && root.quoteExpanded
            active: visible
            width: parent.width
            height: item ? item.contentHeight : 0
            source: "MailHtmlView.qml"
            onLoaded: item.fragment = Qt.binding(function () { return root.quotedHtml })
          }

          TextEdit {
            id: quoteField
            visible: root.quotedText !== "" && root.quoteExpanded
              && !root.quotedIsHtml
            width: parent.width
            text: root.quotedText
            onTextChanged: root.quotedText = text
            color: ui.dim
            selectionColor: Util.alpha(ui.accent, 0.35)
            selectedTextColor: ui.foreground
            font.family: ui.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: TextEdit.Wrap
            selectByMouse: true
            textFormat: TextEdit.PlainText
          }
        }

        MomentumScroll { view: bodyFlick }
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

  // The suggestion list. A child of the composer rather than of the field, so
  // it can hang over the rows underneath instead of being clipped by its own.
  Rectangle {
    id: completionList
    x: root.completionX
    y: root.completionY
    z: 50
    visible: root.completions.length > 0
    width: Math.min(Style.space(380), root.width - root.completionX - Style.space(24))
    height: completionColumn.implicitHeight + Style.space(8)
    radius: ui.radius
    color: ui.surface
    border.width: 1
    border.color: ui.border

    Column {
      id: completionColumn
      x: Style.space(4)
      y: Style.space(4)
      width: parent.width - Style.space(8)

      Repeater {
        model: root.completions

        Rectangle {
          required property var modelData
          required property int index
          width: completionColumn.width
          height: Style.space(34)
          radius: ui.radius
          color: index === root.completionIndex ? ui.selected
            : (suggestionHover.containsMouse ? ui.hover : "transparent")

          Column {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(1)

            Text {
              textFormat: Text.PlainText
              text: modelData.name || modelData.address
              color: ui.foreground
              font.family: ui.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              textFormat: Text.PlainText
              visible: !!modelData.name
              text: modelData.address
              color: ui.faint
              font.family: ui.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          MouseArea {
            id: suggestionHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.acceptCompletion(modelData)
          }
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
