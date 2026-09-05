import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Compose form. It fills the reading pane rather than opening a second window,
// which is how Outlook's inline reply behaves and keeps the layer-shell
// surface single.
Item {
  id: root

  property var ui: null
  property var service: null
  property var draft: null

  signal sendRequested(var draft)
  signal cancelRequested()

  property string toText: ""
  property string ccText: ""
  property string subjectText: ""
  property string bodyText: ""

  readonly property bool canSend: toText.trim().length > 0 && !(service && service.busy)

  onDraftChanged: loadDraft()

  function loadDraft() {
    var source = draft || {}
    toText = (source.to || []).join(", ")
    ccText = (source.cc || []).join(", ")
    subjectText = String(source.subject || "")
    bodyText = String(source.body || "")
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

  function submit() {
    if (!canSend) return
    var source = draft || {}
    root.sendRequested({
      to: splitAddresses(toText),
      cc: splitAddresses(ccText),
      subject: subjectText,
      body: bodyText,
      inReplyTo: source.inReplyTo || "",
      references: source.references || ""
    })
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
            text: "Discard  (Esc)"
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
        readOnlyValue: service && service.currentAccount
          ? String(service.currentAccount.email) : ""
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

    // --------------------------------------------------------------- body
    Item {
      width: parent.width
      height: parent.height - composeHeader.height - fields.height

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
            text: "Write your message…"
            color: ui.faint
            font.family: ui.fontFamily
            font.pixelSize: Style.font.body
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
