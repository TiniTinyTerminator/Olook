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
  signal settingsRequested()

  // Settings is a destination like the others in the rail, but the window
  // treats it separately, so route it here rather than through the view list.
  function activate(target) {
    if (target === "settings") root.settingsRequested()
    else root.viewRequested(target)
  }

  Rectangle {
    anchors.fill: parent
    color: Qt.darker(ui.background, 1.18)
  }

  Rectangle {
    anchors.right: parent.right
    width: ui.hairline
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

  // Pinned to the bottom, where every desktop app keeps its settings.
  Column {
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(14)
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.horizontalCenterOffset: Style.space(2)

    RailButton { glyph: "󰒓"; label: "Settings"; target: "settings" }
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

    // No plate behind these icons, hovered or current. The rail already says
    // which app is open twice over -- the bar on the leading edge and the
    // accent on the glyph -- and hovering brightens the glyph itself.
    //
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
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: railButton.glyph
      color: railButton.current ? ui.accent
        : (hover.containsMouse ? ui.foreground : ui.dim)
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
        textFormat: Text.PlainText
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
      onClicked: root.activate(railButton.target)
    }

    PanelToolTip {
      visible: hover.containsMouse
      text: railButton.label
      fontFamily: ui.fontFamily
    }
  }
}
