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

  // Narrow reading pane: the action buttons drop their labels and keep their
  // icons, so every action is still one click away in a fraction of the width.
  property bool compact: false
  // Shown when the list and the reading pane share the same space and only
  // one of them is on screen at a time.
  property bool showBack: false

  signal backRequested()
  signal replyRequested(string kind)
  signal archiveRequested()
  signal deleteRequested()
  signal flagRequested()
  signal unreadRequested()
  signal attachmentRequested(int index)

  readonly property var attachments: body && body.parts ? body.parts : []
  readonly property bool loadingBody: message !== null && body === null

  // HTML mail renders as rich text on a light "paper" card, the way every
  // other mail client shows it: the markup carries its own colours, and those
  // were written for a white background, not the theme's.
  readonly property bool hasRich: !!(body && String(body.rich || "") !== "")
  readonly property int blockedImages: body && body.blockedImages ? body.blockedImages : 0
  property bool formatted: true

  onMessageChanged: root.formatted = true

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

        Rectangle {
          id: backButton
          visible: root.showBack
          height: visible ? Style.space(24) : 0
          width: backRow.implicitWidth + Style.space(16)
          radius: ui.radius
          color: backHover.containsMouse ? ui.hover : "transparent"
          border.width: 1
          border.color: ui.border

          Row {
            id: backRow
            anchors.centerIn: parent
            spacing: Style.space(6)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "󰅁"
              color: ui.dim
              font.family: ui.fontFamily
              font.pixelSize: Style.font.iconSmall
            }
            Text {
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              text: "Messages"
              color: ui.foreground
              font.family: ui.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          MouseArea {
            id: backHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.backRequested()
          }
        }

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
        // Two connected groups rather than seven loose buttons: the ones that
        // write a new message, then the ones that file or mark this one.
        // Sharing an outline reads as a single control and takes far less
        // width — and a Flow, so the second group wraps instead of running off
        // the edge when the pane is narrow.
        Flow {
          width: parent.width
          spacing: Style.space(8)

          SegmentedGroup {
            SegButton { glyph: "󰑚"; label: "Reply"; onTriggered: root.replyRequested("reply") }
            SegButton { glyph: "󰑛"; label: "Reply all"; onTriggered: root.replyRequested("reply-all") }
            SegButton { glyph: "󰒭"; label: "Forward"; onTriggered: root.replyRequested("forward") }
          }

          SegmentedGroup {
            SegButton { glyph: "󰇠"; label: "Archive"; onTriggered: root.archiveRequested() }
            SegButton { glyph: "󰩹"; label: "Delete"; onTriggered: root.deleteRequested() }
            SegButton {
              glyph: "󰈻"
              label: root.message && root.message.flagged ? "Unflag" : "Flag"
              highlighted: root.message ? root.message.flagged === true : false
              onTriggered: root.flagRequested()
            }
            SegButton {
              glyph: "󰇮"
              label: root.message && root.message.seen ? "Mark unread" : "Mark read"
              onTriggered: root.unreadRequested()
            }
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

          // ------------------------------------------------- html controls
          Row {
            width: parent.width
            spacing: Style.space(10)
            visible: root.hasRich && !root.loadingBody

            ViewToggle {
              label: root.formatted ? "󰈙  Formatted" : "󰦨  Plain text"
              onTriggered: root.formatted = !root.formatted
            }

            Text {
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              visible: root.blockedImages > 0
              text: root.blockedImages === 1
                ? "1 remote image blocked"
                : root.blockedImages + " remote images blocked"
              color: ui.faint
              font.family: ui.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // The formatted view: a light card, because mail HTML assumes one.
          Rectangle {
            width: parent.width
            height: visible ? richText.implicitHeight + Style.space(28) : 0
            visible: root.hasRich && root.formatted && !root.loadingBody
            radius: ui.radius
            color: "#fbfbf9"
            border.width: 1
            border.color: Util.alpha(ui.foreground, 0.16)

            TextEdit {
              id: richText
              x: Style.space(14)
              y: Style.space(14)
              width: parent.width - Style.space(28)
              text: root.body ? String(root.body.rich || "") : ""
              textFormat: TextEdit.RichText
              color: "#16181d"
              font.family: ui.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: TextEdit.Wrap
              readOnly: true
              selectByMouse: true
              selectionColor: Util.alpha(ui.accent, 0.35)
              onLinkActivated: function (link) { Qt.openUrlExternally(link) }

              MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.NoButton
                cursorShape: richText.hoveredLink !== ""
                  ? Qt.PointingHandCursor : Qt.IBeamCursor
              }
            }
          }

          TextEdit {
            width: parent.width
            visible: !root.loadingBody && !(root.hasRich && root.formatted)
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
            visible: !root.loadingBody && !!root.body && !root.hasRich
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

  component ViewToggle: Rectangle {
    id: viewToggle
    property string label: ""
    signal triggered()

    width: viewToggleText.implicitWidth + Style.space(20)
    height: Style.space(26)
    radius: ui.radius
    color: viewToggleHover.containsMouse ? ui.hover : "transparent"
    border.width: 1
    border.color: ui.border

    Text {
      id: viewToggleText
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: viewToggle.label
      color: ui.dim
      font.family: ui.fontFamily
      font.pixelSize: Style.font.caption
    }

    MouseArea {
      id: viewToggleHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: viewToggle.triggered()
    }
  }

  // A strip of buttons sharing one outline. It clips, so the hover highlight
  // on the end buttons follows the rounded corners.
  component SegmentedGroup: Rectangle {
    id: group
    default property alias segments: segmentRow.data

    width: segmentRow.implicitWidth
    height: Style.space(24)
    radius: ui.radius
    color: "transparent"
    border.width: 1
    border.color: ui.border
    clip: true

    Row {
      id: segmentRow
      anchors.fill: parent
      spacing: 0
    }
  }

  component SegButton: Rectangle {
    id: segment
    property string glyph: ""
    property string label: ""
    property bool highlighted: false
    signal triggered()

    width: segmentContent.implicitWidth + Style.space(root.compact ? 14 : 18)
    height: parent ? parent.height : Style.space(24)
    color: segmentHover.containsMouse ? ui.hover : "transparent"

    // A divider on the leading edge of every button but the first, which is
    // what makes the group read as connected rather than as one wide button.
    Rectangle {
      visible: segment.x > 0
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: 1
      color: ui.border
    }

    Row {
      id: segmentContent
      anchors.centerIn: parent
      spacing: Style.space(5)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: segment.glyph
        color: segment.highlighted ? ui.urgent : ui.dim
        font.family: ui.fontFamily
        font.pixelSize: Style.font.iconSmall
      }

      Text {
        textFormat: Text.PlainText
        visible: !root.compact
        anchors.verticalCenter: parent.verticalCenter
        text: segment.label
        color: ui.foreground
        font.family: ui.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    MouseArea {
      id: segmentHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: segment.triggered()
    }

    PanelToolTip {
      visible: root.compact && segmentHover.containsMouse
      text: segment.label
      fontFamily: ui.fontFamily
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
