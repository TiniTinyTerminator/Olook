import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model

// People: everyone the cached mail has been to or from.
//
// Not an address book synced from anywhere -- it is built from the mail
// already on disk, because the people worth showing are the ones actually
// corresponded with, and the ranking that matters is how often and how
// recently. A list on the left, one person on the right, the same shape as
// the mail view so it needs no learning.
Item {
  id: root

  property var ui: null
  property var service: null

  // Which address is open on the right.
  property string selected: ""
  property string filter: ""

  // The list's width, as asked for by dragging the edge. Kept as the request
  // rather than the result, so a window too narrow to honour it gives it back
  // when the window grows again.
  property real listAsked: 0
  // Pinned to pixels once there is a width to take a share of, for the same
  // reason the mail view's list is: a pane measured as a share of what is
  // left moves whenever anything else does.
  property bool listPinned: false
  readonly property int listMin: Style.space(200)
  readonly property int listMax: Math.max(root.listMin, Math.round(root.width * 0.6))
  readonly property int listWidth: {
    var wanted = root.listAsked > 0 ? root.listAsked
      : Math.min(Style.space(420), Math.round(root.width * 0.34))
    return Math.max(root.listMin, Math.min(root.listMax, wanted))
  }

  signal composeRequested(string address)
  signal mailRequested(string address)

  readonly property var people: service ? service.contacts : []
  readonly property var current: {
    for (var i = 0; i < root.people.length; i++)
      if (root.people[i].address === root.selected) return root.people[i]
    return null
  }

  onVisibleChanged: if (visible && root.people.length === 0 && service)
    service.loadContacts("")

  onWidthChanged: root.pinList()
  Component.onCompleted: root.pinList()

  function pinList() {
    if (root.listPinned || root.width <= 0)
      return
    root.listAsked = Math.min(Style.space(420), Math.round(root.width * 0.34))
    root.listPinned = true
  }

  Rectangle {
    anchors.fill: parent
    color: ui.background
  }

  Row {
    anchors.fill: parent

    // ------------------------------------------------------------ the list
    Item {
      width: root.listWidth
      height: parent.height

      Column {
        anchors.fill: parent
        anchors.margins: Style.space(12)
        spacing: Style.space(10)

        Rectangle {
          width: parent.width
          height: Style.space(32)
          radius: ui.radius
          color: ui.surface
          border.width: 1
          border.color: searchField.activeFocus ? ui.accent : ui.border

          TextInput {
            id: searchField
            anchors.fill: parent
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(10)
            verticalAlignment: TextInput.AlignVCenter
            color: ui.foreground
            font.family: ui.fontFamily
            font.pixelSize: Style.font.bodySmall
            selectionColor: Util.alpha(ui.accent, 0.35)
            selectByMouse: true
            clip: true
            onTextChanged: {
              root.filter = text
              if (root.service) root.service.loadContacts(text)
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              visible: searchField.text === ""
              text: "Search people…"
              color: ui.faint
              font.family: ui.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }
        }

        ListView {
          id: peopleList
          width: parent.width
          height: parent.height - y
          clip: true
          model: root.people
          boundsBehavior: Flickable.StopAtBounds
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          delegate: Rectangle {
            required property var modelData
            width: peopleList.width
            height: Style.space(50)
            radius: ui.radius
            color: modelData.address === root.selected ? ui.selected
              : (rowHover.containsMouse ? ui.hover : "transparent")

            Rectangle {
              id: dot
              anchors.left: parent.left
              anchors.leftMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(30)
              height: width
              radius: width / 2
              // Same trick the message list uses: a stable colour per person,
              // so a face you know keeps the same one between sessions.
              color: Qt.hsla((modelData.address.length % 12) / 12, 0.45, 0.45, 1.0)

              Text {
                anchors.centerIn: parent
                text: Model.initials(modelData.name, modelData.address)
                color: "white"
                font.family: ui.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }

            Column {
              anchors.left: dot.right
              anchors.leftMargin: Style.space(10)
              anchors.right: countLabel.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: modelData.name || modelData.address
                color: ui.foreground
                font.family: ui.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: modelData.address
                color: ui.faint
                font.family: ui.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            Text {
              id: countLabel
              anchors.right: parent.right
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              text: Model.badgeText(modelData.messages)
              color: ui.faint
              font.family: ui.fontFamily
              font.pixelSize: Style.font.caption
            }

            MouseArea {
              id: rowHover
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.selected = modelData.address
            }
          }

          MomentumScroll { view: peopleList }
        }
      }
    }

    PaneSplitter {
      id: listSplit
      height: parent.height
      ui: root.ui
      onMoved: function (delta) {
        root.listAsked = Math.max(root.listMin,
                                  Math.min(root.listMax, root.listWidth + delta))
      }
    }

    // ---------------------------------------------------------- one person
    Item {
      width: parent.width - root.listWidth - listSplit.width
      height: parent.height

      MailPlaceholder {
        anchors.fill: parent
        visible: root.current === null
        ui: root.ui
        glyph: "󰀓"
        title: root.people.length === 0 ? "No people yet" : "Nobody selected"
        subtitle: root.people.length === 0
          ? "Sync some mail and the people you write to will show up here."
          : "Pick someone on the left to see what you have exchanged."
      }

      Column {
        visible: root.current !== null
        anchors.fill: parent
        anchors.margins: Style.space(24)
        spacing: Style.space(16)

        Row {
          width: parent.width
          spacing: Style.space(14)

          Rectangle {
            width: Style.space(56)
            height: width
            radius: width / 2
            anchors.verticalCenter: parent.verticalCenter
            color: root.current
              ? Qt.hsla((root.current.address.length % 12) / 12, 0.45, 0.45, 1.0)
              : ui.surface

            Text {
              anchors.centerIn: parent
              text: root.current
                ? Model.initials(root.current.name, root.current.address) : ""
              color: "white"
              font.family: ui.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }
          }

          Column {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            Text {
              textFormat: Text.PlainText
              text: root.current ? (root.current.name || root.current.address) : ""
              color: ui.foreground
              font.family: ui.fontFamily
              font.pixelSize: Style.font.title
            }

            Text {
              textFormat: Text.PlainText
              text: root.current ? root.current.address : ""
              color: ui.faint
              font.family: ui.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }
        }

        Row {
          spacing: Style.space(8)

          ActionChip {
            label: "󰇮  New mail"
            onTriggered: if (root.current) root.composeRequested(root.current.address)
          }

          ActionChip {
            label: "󰍉  Their mail"
            onTriggered: if (root.current) root.mailRequested(root.current.address)
          }
        }

        Rectangle { width: parent.width; height: 1; color: ui.border }

        Column {
          width: parent.width
          spacing: Style.space(8)

          DetailLine {
            label: "Messages"
            value: root.current ? String(root.current.messages) : ""
          }
          DetailLine {
            label: "From them"
            value: root.current ? String(root.current.received) : ""
          }
          DetailLine {
            label: "To them"
            value: root.current ? String(root.current.sent) : ""
          }
          DetailLine {
            label: "Last seen"
            value: root.current ? Model.fullTime(root.current.lastSeen) : ""
          }
          DetailLine {
            label: root.current && root.current.accounts.length === 1
              ? "Account" : "Accounts"
            value: root.current ? root.current.accounts.join(", ") : ""
          }
        }
      }
    }
  }

  component DetailLine: Row {
    property string label: ""
    property string value: ""
    spacing: Style.space(10)

    Text {
      textFormat: Text.PlainText
      width: Style.space(110)
      text: parent.label
      color: ui.faint
      font.family: ui.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      textFormat: Text.PlainText
      text: parent.value
      color: ui.foreground
      font.family: ui.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  component ActionChip: Rectangle {
    id: chip
    property string label: ""
    signal triggered()

    width: chipText.implicitWidth + Style.space(22)
    height: Style.space(30)
    radius: ui.radius
    color: chipHover.containsMouse ? ui.hover : "transparent"
    border.width: 1
    border.color: ui.border

    Text {
      id: chipText
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: chip.label
      color: ui.foreground
      font.family: ui.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    MouseArea {
      id: chipHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: chip.triggered()
    }
  }
}
