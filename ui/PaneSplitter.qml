import QtQuick
import qs.Commons

// The grab strip between two panes.
//
// It draws nothing at rest. Both panes already end in a hairline of their
// own, and a splitter with its own line beside theirs is two lines where the
// eye expects one. What it adds is a band wide enough to catch with a
// pointer -- one pixel is a fair description of where the edge is and a poor
// description of what you are trying to grab -- and a highlight on that edge
// while you are over it, so it is clear the border is a handle.
Item {
  id: root

  property var ui: null
  // Pixels the pointer has moved since the last report. The pane on the left
  // adds it to its own width; nothing here decides how wide anything is.
  signal moved(real delta)

  width: Style.space(7)

  Rectangle {
    // Against the pane's own border rather than beside it, so the edge you
    // already see is the one that lights up.
    anchors.left: parent.left
    width: ui.hairline
    height: parent.height
    visible: handle.pressed || handle.containsMouse
    color: ui.accent
  }

  MouseArea {
    id: handle
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.SplitHCursor
    // Where in the strip the drag began, so the line stays under the pointer
    // instead of jumping to centre it on the first move.
    property real grabbedAt: 0

    onPressed: function (event) { handle.grabbedAt = event.x }
    onPositionChanged: function (event) {
      if (!handle.pressed) return
      root.moved(event.x - handle.grabbedAt)
    }
  }
}
