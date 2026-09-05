import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Reading pane: subject, correspondent, the action row, then the message
// itself with its attachments.
Item {
  id: root

  property var ui: null
  property var service: null
  property var message: null
  property var body: null
  property bool active: false

  signal replyRequested(string kind)
  signal archiveRequested()
  signal deleteRequested()
  signal flagRequested()
  signal unreadRequested()
  signal attachmentRequested(int index)

  readonly property var attachments: body && body.parts ? body.parts : []
  readonly property bool loadingBody: message !== null && body === null

  Rectangle {
    anchors.fill: parent
    color: ui.background
  }

  MailPlaceholder {
    anchors.fill: parent
    visible: root.message === null
    ui: root.ui
    glyph: "󰇰"
    title: "Nothing selected"
    subtitle: "Pick a message on the left to read it here."
  }

  Column {
    anchors.fill: parent
    visible: root.message !== null
    spacing: 0

    // ------------------------------------------------------------- header
    Item {
      id: header
      width: parent.width
      height: headerColumn.implicitHeight + Style.space(28)

      Column {
        id: headerColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Style.space(24)
        anchors.rightMargin: Style.space(24)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(12)

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: root.message ? String(root.message.subject || "(no subject)") : ""
          color: ui.foreground
          font.family: ui.fontFamily
          font.pixelSize: Style.font.heading
          font.bold: true
          wrapMode: Text.WordWrap
          maximumLineCount: 2
          elide: Text.ElideRight
        }

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
            color: Qt.hsla(Model.avatarHue(root.message ? root.message.fromAddr : "") / 360,
                           0.45, 0.45, 1.0)

            Text {
              anchors.centerIn: parent
              text: Model.initials(root.message ? root.message.fromName : "",
                                   root.message ? root.message.fromAddr : "")
              color: "white"
              font.family: ui.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }
          }

          Column {
            anchors.left: avatar.right
            anchors.leftMargin: Style.space(12)
            anchors.right: dateLabel.left
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.message
                ? Model.senderLabel(root.message)
                  + (root.message.fromAddr ? "  <" + root.message.fromAddr + ">" : "")
                : ""
              color: ui.foreground
              font.family: ui.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.message ? "To: " + Model.recipientLabel(root.message) : ""
              color: ui.faint
              font.family: ui.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          Text {
            id: dateLabel
            textFormat: Text.PlainText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.message ? Model.fullTime(root.message.date) : ""
            color: ui.faint
            font.family: ui.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // ------------------------------------------------------ action row
        //
        // A Flow, not a Row: on a narrow reading pane the trailing actions
        // wrap to a second line instead of running off the edge.
        Flow {
          width: parent.width
          spacing: Style.space(6)

          ActionButton { glyph: "󰑚"; label: "Reply"; onTriggered: root.replyRequested("reply") }
          ActionButton { glyph: "󰑛"; label: "Reply all"; onTriggered: root.replyRequested("reply-all") }
          ActionButton { glyph: "󰒭"; label: "Forward"; onTriggered: root.replyRequested("forward") }

          Item { width: Style.space(10); height: 1 }

          ActionButton { glyph: "󰇠"; label: "Archive"; onTriggered: root.archiveRequested() }
          ActionButton { glyph: "󰩹"; label: "Delete"; onTriggered: root.deleteRequested() }
          ActionButton {
            glyph: "󰈻"
            label: root.message && root.message.flagged ? "Unflag" : "Flag"
            highlighted: root.message ? root.message.flagged === true : false
            onTriggered: root.flagRequested()
          }
          ActionButton {
            glyph: "󰇮"
            label: root.message && root.message.seen ? "Mark unread" : "Mark read"
            onTriggered: root.unreadRequested()
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

    // ------------------------------------------------------------ content
    Item {
      width: parent.width
      height: parent.height - header.height

      Flickable {
        id: bodyFlick
        anchors.fill: parent
        anchors.leftMargin: Style.space(24)
        anchors.rightMargin: Style.space(12)
        anchors.topMargin: Style.space(16)
        contentWidth: width
        contentHeight: bodyColumn.implicitHeight + Style.space(24)
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: bodyColumn
          width: bodyFlick.width - Style.space(12)
          spacing: Style.space(16)

          // attachments strip
          Flow {
            width: parent.width
            spacing: Style.space(8)
            visible: root.attachments.length > 0

            Repeater {
              model: root.attachments
              AttachmentChip {
                required property var modelData
                part: modelData
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: root.loadingBody
            text: "Loading message…"
            color: ui.faint
            font.family: ui.fontFamily
            font.pixelSize: Style.font.body
          }

          TextEdit {
            width: parent.width
            visible: !root.loadingBody
            text: root.body ? String(root.body.text || "") : ""
            color: ui.foreground
            font.family: ui.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: TextEdit.Wrap
            readOnly: true
            selectByMouse: true
            selectionColor: Util.alpha(ui.accent, 0.35)
            selectedTextColor: ui.foreground
            textFormat: TextEdit.PlainText
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: !root.loadingBody && !!root.body
              && String(root.body.text || "") === ""
            text: root.body && root.body.failed === true
              ? "This message could not be loaded. "
                + (root.service && root.service.error !== ""
                   ? root.service.error : "Check the account's connection.")
              : "This message has no text content."
            color: root.body && root.body.failed === true ? ui.urgent : ui.faint
            font.family: ui.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }

  component ActionButton: Rectangle {
    id: actionButton
    property string glyph: ""
    property string label: ""
    property bool highlighted: false
    signal triggered()

    width: actionRow.implicitWidth + Style.space(20)
    height: Style.space(28)
    radius: ui.radius
    color: actionHover.containsMouse ? ui.hover : "transparent"
    border.width: 1
    border.color: actionHover.containsMouse ? ui.border : "transparent"

    Row {
      id: actionRow
      anchors.centerIn: parent
      spacing: Style.space(6)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: actionButton.glyph
        color: actionButton.highlighted ? ui.urgent : ui.dim
        font.family: ui.fontFamily
        font.pixelSize: Style.font.iconSmall
      }

      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        text: actionButton.label
        color: ui.foreground
        font.family: ui.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }

    MouseArea {
      id: actionHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: actionButton.triggered()
    }
  }

  component AttachmentChip: Rectangle {
    id: chip
    property var part: null

    width: chipRow.implicitWidth + Style.space(20)
    height: Style.space(30)
    radius: ui.radius
    color: chipHover.containsMouse ? ui.hover : Util.alpha(ui.foreground, 0.05)
    border.width: 1
    border.color: ui.border

    Row {
      id: chipRow
      anchors.centerIn: parent
      spacing: Style.space(8)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "󰏢"
        color: ui.dim
        font.family: ui.fontFamily
        font.pixelSize: Style.font.iconSmall
      }

      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        text: chip.part ? String(chip.part.filename || "attachment") : ""
        color: ui.foreground
        font.family: ui.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        text: chip.part ? Model.fileSize(chip.part.size) : ""
        color: ui.faint
        font.family: ui.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    MouseArea {
      id: chipHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.attachmentRequested(chip.part ? chip.part.index : 0)
    }

    PanelToolTip {
      visible: chipHover.containsMouse
      text: "Save and open"
      fontFamily: ui.fontFamily
    }
  }
}
