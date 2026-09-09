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
  signal showImagesRequested()
  signal popOutRequested()
  signal threadMessageRequested(var entry)

  // The rest of the conversation, when the list is grouped. Grouping that
  // hid the older messages with no way back to them would be worse than not
  // grouping at all.
  readonly property var threadMembers: message && message.thread ? message.thread : []

  // False once the message is already in a window of its own, where the
  // button would have nowhere to go. Mirrors MailCompose.
  property bool allowPopOut: true
  // Which account this message arrived on. Shown when the list is mixing
  // accounts, so a reply's sender is never a surprise.
  property var account: null
  property bool showAccount: false

  readonly property var attachments: body && body.parts ? body.parts : []
  readonly property bool loadingBody: message !== null && body === null

  // HTML mail renders as rich text on a light "paper" card, the way every
  // other mail client shows it: the markup carries its own colours, and those
  // were written for a white background, not the theme's.
  readonly property bool hasRich: !!(body && String(body.rich || "") !== "")
  readonly property int blockedImages: body && body.blockedImages ? body.blockedImages : 0
  // What the receiving server made of the sender's identity, and whether that
  // plus your say-so was enough to let the pictures through by itself.
  readonly property var authentication: body && body.authentication
    ? body.authentication : null
  readonly property bool verifiedSender: !!(root.authentication
                                            && root.authentication.verified)
  readonly property bool autoImages: !!(body && body.autoImages)
  readonly property bool senderTrusted: !!(body && body.senderTrusted)
  readonly property string senderAddress: message && message.fromAddr
    ? String(message.fromAddr) : ""

  signal trustSenderRequested(string address)
  property bool formatted: true

  // The web renderer lays out the stylesheet the message came with, which is
  // most of what makes mail look like itself. It is only safe to construct
  // when Qt has an argument list: QtWebEngine aborts the process on an empty
  // one, and that would take the shell down rather than this pane. Quickshell
  // passes argc 0, so lib/argcshim.c is what makes this true.
  readonly property bool webRenderer: Qt.application.arguments.length > 0
  readonly property string webDocument: body ? String(body.document || "") : ""
  // Per message, never remembered. Asking for one sender's pictures is not
  // agreeing to the next one's.
  property bool remoteImages: false

  onMessageChanged: {
    root.formatted = true
    root.remoteImages = false
  }

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

            // Who the server says this is really from. Worth saying only when
            // it was checked: silence would otherwise read as a verdict.
            Row {
              width: parent.width
              spacing: Style.space(5)
              visible: !!root.authentication && root.authentication.checked

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.verifiedSender ? "󰄴" : "󰀦"
                color: root.verifiedSender ? ui.accent : ui.urgent
                font.family: ui.fontFamily
                font.pixelSize: Style.font.iconSmall
              }

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: {
                  if (!root.authentication) return ""
                  if (!root.verifiedSender) return "Sender could not be verified"
                  var by = String(root.authentication.signedBy || "")
                  return by === "" ? "Verified sender" : "Verified as " + by
                }
                color: root.verifiedSender ? ui.faint : ui.urgent
                font.family: ui.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            // Which mailbox this arrived on. Only worth saying when the list
            // is mixing accounts, and worth saying then: it is the address a
            // reply will go out from.
            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: root.showAccount && !!root.account
              text: root.account
                ? "Received by " + String(root.account.email || root.account.name || "")
                : ""
              color: ui.accent
              font.family: ui.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          Text {
            id: dateLabel
            textFormat: Text.PlainText
            anchors.right: popOutButton.visible ? popOutButton.left : parent.right
            anchors.rightMargin: popOutButton.visible ? Style.space(10) : 0
            anchors.verticalCenter: parent.verticalCenter
            text: root.message ? Model.fullTime(root.message.date) : ""
            color: ui.faint
            font.family: ui.fontFamily
            font.pixelSize: Style.font.caption
          }

          // Hand this message to a window of its own, so it can sit on another
          // workspace while the client goes back to the list.
          Rectangle {
            id: popOutButton
            visible: root.allowPopOut && root.message !== null
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
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
          }
        }

        // ------------------------------------------------------ action row
        //
        // Two connected groups rather than seven loose buttons: the ones that
        // write a new message, then the ones that file or mark this one.
        // Sharing an outline reads as a single control and takes far less
        // width — and a Flow, so the second group wraps instead of running off
        // the edge when the pane is narrow. Sized to sit on one line at any
        // width worth reading mail at.
        Flow {
          width: parent.width
          spacing: Style.space(6)

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

      // No inset. A message is the thing being read, so it gets the whole
      // pane: its own markup already carries the margins its designer wanted,
      // and a second set around the outside only makes the column narrower.
      // The parts that are ours rather than the sender's -- attachments, the
      // plain-text view, the notices -- keep their own breathing room below.
      Flickable {
        id: bodyFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: bodyColumn.implicitHeight + Style.space(16)
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: bodyColumn
          width: bodyFlick.width
          spacing: Style.space(16)
          // What our own chrome insets itself by, so it does not sit against
          // the edge the message is allowed to use.
          readonly property real gutter: Style.space(20)

          // The rest of this conversation.
          Column {
            x: bodyColumn.gutter
            width: parent.width - bodyColumn.gutter * 2
            spacing: Style.space(4)
            visible: root.threadMembers.length > 0 && !root.loadingBody

            Text {
              textFormat: Text.PlainText
              text: root.threadMembers.length === 1
                ? "1 earlier message in this conversation"
                : root.threadMembers.length + " earlier messages in this conversation"
              color: ui.faint
              font.family: ui.fontFamily
              font.pixelSize: Style.font.caption
            }

            Repeater {
              model: root.threadMembers

              Rectangle {
                required property var modelData
                width: parent.width
                height: Style.space(28)
                radius: ui.radius
                color: earlierHover.containsMouse ? ui.hover : "transparent"

                Row {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(8)
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(8)

                  Text {
                    textFormat: Text.PlainText
                    text: modelData.seen ? "󰇮" : "󰇯"
                    color: modelData.seen ? ui.faint : ui.accent
                    font.family: ui.fontFamily
                    font.pixelSize: Style.font.iconSmall
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: Model.senderLabel(modelData)
                    color: ui.foreground
                    font.family: ui.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: Model.fullTime(modelData.date)
                    color: ui.faint
                    font.family: ui.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                MouseArea {
                  id: earlierHover
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.threadMessageRequested(modelData)
                }
              }
            }
          }

          // attachments strip
          Flow {
            x: bodyColumn.gutter
            width: parent.width - bodyColumn.gutter * 2
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
            x: bodyColumn.gutter
            width: parent.width - bodyColumn.gutter * 2
            visible: root.loadingBody
            text: "Loading message…"
            color: ui.faint
            font.family: ui.fontFamily
            font.pixelSize: Style.font.body
          }

          // The formatted view: a light card, because mail HTML assumes one.
          Rectangle {
            id: formattedCard
            // A browser engine when the shell can host one, Qt's rich text
            // when it cannot: the same card either way.
            readonly property bool web: htmlView.status === Loader.Ready
            width: parent.width
            height: visible
              ? (web ? htmlView.item.contentHeight
                     : richText.implicitHeight + Style.space(28))
              : 0
            visible: root.hasRich && root.formatted && !root.loadingBody
            // Flush: no rounding, no outline, no inset. The paper runs to the
            // edges of the pane and the message decides its own margins.
            color: "#fbfbf9"

            Loader {
              id: htmlView
              width: parent.width
              height: item ? item.contentHeight : 0
              active: root.webRenderer && root.webDocument !== ""
                && root.hasRich && root.formatted && !root.loadingBody
              source: "MailHtmlView.qml"
              // Remote access first, then the document: setting the
              // document is what triggers the load, and a load that starts
              // before the setting is in place renders without the pictures.
              onLoaded: {
                item.allowRemote = Qt.binding(function () {
                  return root.remoteImages || root.autoImages
                })
                item.document = Qt.binding(function () { return root.webDocument })
              }

              Connections {
                target: htmlView.item
                function onLinkActivated(link) { Qt.openUrlExternally(link) }
                function onWheeled(angleY, pixelY) {
                  if (pixelY !== 0)
                    bodyScroll.slideBy(pixelY)
                  else if (angleY !== 0)
                    bodyScroll.throwBy(angleY / 120)
                }
              }
            }

            TextEdit {
              id: richText
              visible: !formattedCard.web
              x: Style.space(14)
              y: Style.space(14)
              width: parent.width - Style.space(28)
              // Qt's rich text has no page of its own to carry margins, so
              // this one keeps the inset the web view does not need.
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
            x: bodyColumn.gutter
            width: parent.width - bodyColumn.gutter * 2
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
            x: bodyColumn.gutter
            width: parent.width - bodyColumn.gutter * 2
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

        MomentumScroll { id: bodyScroll; view: bodyFlick }
      }

      // Pinned to the corner of the message rather than sitting on a row of
      // its own above it. These controls belong to the message being shown,
      // and a whole row of height to say "Formatted" is height the message
      // could have used instead. They stay put while it scrolls under them,
      // which also keeps them in reach at the bottom of a long mail.
      // No ground of its own: the message shows through. The ink is the
      // paper's rather than the theme's, though -- these sit on the light card
      // the message is drawn on, where the dim grey the rest of the app uses
      // would barely be there at all.
      Row {
        id: controlRow
        anchors.right: bodyFlick.right
        anchors.top: bodyFlick.top
        anchors.rightMargin: Style.space(14)
        anchors.topMargin: Style.space(10)
        spacing: Style.space(8)
        visible: root.hasRich && !root.loadingBody
        z: 1

        readonly property color ink: "#5a616b"
        readonly property color edge: Qt.rgba(0, 0, 0, 0.14)

        ViewToggle {
          label: root.formatted ? "󰈙  Formatted" : "󰦨  Plain text"
          ink: controlRow.ink
          edge: controlRow.edge
          onTriggered: root.formatted = !root.formatted
        }

        Text {
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          visible: root.blockedImages > 0
          text: root.blockedImages === 1
            ? "1 remote image blocked"
            : root.blockedImages + " remote images blocked"
          color: controlRow.ink
          font.family: ui.fontFamily
          font.pixelSize: Style.font.caption
        }

        // Fetching a message's pictures tells the sender the mail was
        // opened -- that is what the tracking pixel among them is for. So
        // it stays the reader's decision, one message at a time.
        ViewToggle {
          label: "󰋩  Show images"
          visible: root.blockedImages > 0 && root.formatted
          ink: controlRow.ink
          edge: controlRow.edge
          onTriggered: {
            root.remoteImages = true
            root.showImagesRequested()
          }
        }

        // The standing version of the same permission. Signed mail already
        // loads by itself, so what reaches this button is the mail whose
        // sender the server could not vouch for -- which is exactly the case
        // where the address in the From line is only a claim. Worth having,
        // worth knowing: it is a decision about a name, not about a proof.
        ViewToggle {
          label: "󰀓  Always from this sender"
          visible: root.blockedImages > 0 && root.formatted
            && !root.senderTrusted && root.senderAddress !== ""
          ink: controlRow.ink
          edge: controlRow.edge
          onTriggered: root.trustSenderRequested(root.senderAddress)
        }
      }
    }
  }

  component ViewToggle: Rectangle {
    id: viewToggle
    property string label: ""
    // Defaults are the app's own. The pair floating over a message override
    // them, because there the background is the sender's, not the theme's.
    property color ink: ui.dim
    property color edge: ui.border
    signal triggered()

    width: viewToggleText.implicitWidth + Style.space(20)
    height: Style.space(26)
    radius: ui.radius
    color: viewToggleHover.containsMouse
      ? Qt.rgba(viewToggle.ink.r, viewToggle.ink.g, viewToggle.ink.b, 0.10)
      : "transparent"
    border.width: 1
    border.color: viewToggle.edge

    Text {
      id: viewToggleText
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: viewToggle.label
      color: viewToggle.ink
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
    height: Style.space(22)
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

    width: segmentContent.implicitWidth + Style.space(root.compact ? 10 : 12)
    height: parent ? parent.height : Style.space(22)
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
      spacing: Style.space(4)

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
