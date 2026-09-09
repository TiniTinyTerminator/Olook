import QtQuick
import qs.Commons

// Empty-state panel: used for the reading pane with nothing selected, and for
// the rail's not-yet-built views.
Item {
  id: root

  property var ui: null
  property string glyph: ""
  property string title: ""
  property string subtitle: ""

  Column {
    anchors.centerIn: parent
    width: Math.min(Style.space(420), parent.width - Style.space(60))
    spacing: Style.space(12)

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: root.glyph
      color: ui.faint
      font.family: ui.fontFamily
      font.pixelSize: Style.space(56)
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      text: root.title
      color: ui.dim
      font.family: ui.fontFamily
      font.pixelSize: Style.font.title
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      text: root.subtitle
      color: ui.faint
      font.family: ui.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }
  }
}
