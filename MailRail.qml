import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The app rail down the left edge — Mail, Calendar, People — mirroring the
// switcher Outlook puts in the same place.
Item {
  id: root

  property var ui: null
  property string view: "mail"
  property int unread: 0

  signal viewRequested(string view)

  Rectangle {
    anchors.fill: parent
    color: Qt.darker(ui.background, 1.18)
  }

  Rectangle {
    anchors.right: parent.right
    width: 1
    height: parent.height
    color: ui.border
  }

  Column {
    anchors.top: parent.top
    anchors.topMargin: Style.space(14)
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.horizontalCenterOffset: Style.space(2)
    spacing: Style.space(6)

    RailButton { glyph: "󰇮"; label: "Mail"; target: "mail"; badge: root.unread }
    RailButton { glyph: "󰃭"; label: "Calendar"; target: "calendar" }
    RailButton { glyph: "󰀓"; label: "People"; target: "people" }
  }

  component RailButton: Item {
    id: railButton
    property string glyph: ""
    property string label: ""
    property string target: ""
    property int badge: 0
    readonly property bool current: root.view === railButton.target

    width: Style.space(40)
    height: Style.space(40)

    Rectangle {
      anchors.fill: parent
      radius: ui.radius
      color: railButton.current ? ui.selected
        : (hover.containsMouse ? ui.hover : "transparent")
    }

    // Outlook marks the active app with a bar on the leading edge.
    Rectangle {
      visible: railButton.current
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left
      anchors.leftMargin: Style.space(2)
      width: Style.space(3)
      height: parent.height * 0.5
      radius: width
      color: ui.accent
    }

    Text {
      id: railGlyph
      anchors.centerIn: parent
      text: railButton.glyph
      color: railButton.current ? ui.accent : ui.dim
      font.family: ui.fontFamily
      font.pixelSize: Style.font.iconLarge
    }

    Rectangle {
      visible: railButton.badge > 0
      anchors.left: railGlyph.right
      anchors.leftMargin: -Style.space(4)
      anchors.bottom: railGlyph.top
      anchors.bottomMargin: -Style.space(8)
      height: Style.space(13)
      width: Math.max(height, railBadge.implicitWidth + Style.space(6))
      radius: height / 2
      color: ui.urgent

      Text {
        id: railBadge
        anchors.centerIn: parent
        text: Model.badgeText(railButton.badge)
        color: ui.background
        font.family: ui.fontFamily
        font.pixelSize: Math.max(8, Style.space(9))
        font.bold: true
      }
    }

    MouseArea {
      id: hover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.viewRequested(railButton.target)
    }

    PanelToolTip {
      visible: hover.containsMouse
      text: railButton.label
      fontFamily: ui.fontFamily
    }
  }
}
