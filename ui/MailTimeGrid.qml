import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The day, work week and week views: hours down the side, one column per day,
// appointments drawn where they actually sit in the day. The month grid says
// how busy a fortnight looks; this says whether there is room at three
// o'clock, which is the question the other one cannot answer.
Item {
  id: root

  property var ui: null
  // [{ key: "2026-09-17", date: <Date>, label: "Thu 17" }]
  property var days: []
  property var byDay: ({})
  property string today: ""
  property string selected: ""

  signal daySelected(string key)
  signal eventChosen(var event)

  readonly property int hourHeight: Style.space(42)
  readonly property int gutter: Style.space(46)
  readonly property int columnWidth: days.length > 0
    ? (width - root.gutter) / days.length : width

  function eventsOn(key) { return root.byDay[key] || [] }

  function minutesInto(event, dayStart) {
    return Math.max(0, Math.round((event.start - dayStart) / 60))
  }

  // Appointments at the same hour are laid out side by side rather than on
  // top of each other. Anything that overlaps anything already in a cluster
  // joins it, and the cluster's width is split between its columns -- which
  // is the whole of what a calendar needs to stop hiding a meeting behind
  // another one.
  function laidOut(key, dayStart) {
    var timed = []
    var items = root.eventsOn(key)
    for (var i = 0; i < items.length; i++)
      if (!items[i].allDay) timed.push(items[i])
    timed.sort(function (a, b) { return a.start - b.start })

    var placed = []
    var cluster = []
    var clusterEnd = -1

    function flush() {
      // Every column in a cluster is as wide as the cluster allows, so two
      // overlapping appointments each take half and neither is hidden.
      var columns = []
      for (var c = 0; c < cluster.length; c++) {
        var entry = cluster[c]
        var column = 0
        while (column < columns.length && columns[column] > entry.event.start) column++
        if (column === columns.length) columns.push(0)
        columns[column] = entry.event.end
        entry.column = column
      }
      for (var d = 0; d < cluster.length; d++) {
        cluster[d].columns = columns.length
        placed.push(cluster[d])
      }
      cluster = []
      clusterEnd = -1
    }

    for (var j = 0; j < timed.length; j++) {
      var event = timed[j]
      if (cluster.length > 0 && event.start >= clusterEnd) flush()
      cluster.push({ "event": event, "column": 0, "columns": 1 })
      clusterEnd = Math.max(clusterEnd, event.end)
    }
    if (cluster.length > 0) flush()

    var out = []
    for (var k = 0; k < placed.length; k++) {
      var slot = placed[k]
      var from = root.minutesInto(slot.event, dayStart)
      var to = Math.min(1440, Math.round((slot.event.end - dayStart) / 60))
      out.push({
        "event": slot.event,
        "top": from / 60 * root.hourHeight,
        // A fifteen-minute appointment still needs room for its own name.
        "span": Math.max(Style.space(18), (to - from) / 60 * root.hourHeight),
        "column": slot.column,
        "columns": slot.columns
      })
    }
    return out
  }

  function allDayOn(key) {
    var out = []
    var items = root.eventsOn(key)
    for (var i = 0; i < items.length; i++)
      if (items[i].allDay) out.push(items[i])
    return out
  }

  readonly property int allDayRows: {
    var most = 0
    for (var i = 0; i < root.days.length; i++)
      most = Math.max(most, root.allDayOn(root.days[i].key).length)
    return most
  }

  Column {
    anchors.fill: parent
    spacing: 0

    // ------------------------------------------------------- day headings
    Item {
      width: parent.width
      height: Style.space(26)

      Row {
        anchors.fill: parent

        Item { width: root.gutter; height: parent.height }

        Repeater {
          model: root.days

          Item {
            required property var modelData
            width: root.columnWidth
            height: parent.height

            Text {
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: parent.modelData.label
              color: parent.modelData.key === root.today ? ui.accent
                : (parent.modelData.key === root.selected ? ui.foreground : ui.dim)
              font.family: ui.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: parent.modelData.key === root.today
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.daySelected(parent.modelData.key)
            }
          }
        }
      }
    }

    Rectangle { width: parent.width; height: ui.hairline; color: ui.border }

    // ------------------------------------------------ all day, above the rule
    Item {
      width: parent.width
      visible: root.allDayRows > 0
      height: visible ? root.allDayRows * Style.space(17) + Style.space(4) : 0

      Row {
        anchors.fill: parent
        anchors.topMargin: Style.space(2)

        Text {
          width: root.gutter
          horizontalAlignment: Text.AlignRight
          rightPadding: Style.space(6)
          text: "all"
          color: ui.faint
          font.family: ui.fontFamily
          font.pixelSize: Style.font.caption
        }

        Repeater {
          model: root.days

          Item {
            required property var modelData
            width: root.columnWidth
            height: parent.height

            Column {
              anchors.fill: parent
              anchors.leftMargin: Style.space(2)
              anchors.rightMargin: Style.space(2)
              spacing: Style.space(1)

              Repeater {
                model: root.allDayOn(parent.parent.modelData.key)

                Rectangle {
                  required property var modelData
                  width: parent.width
                  height: Style.space(15)
                  radius: Style.space(3)
                  color: Util.alpha(modelData.colour || ui.accent, 0.28)

                  Text {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(4)
                    verticalAlignment: Text.AlignVCenter
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    text: parent.modelData.summary || "(no title)"
                    color: ui.foreground
                    font.family: ui.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.eventChosen(parent.modelData)
                  }
                }
              }
            }
          }
        }
      }
    }

    Rectangle {
      width: parent.width
      height: root.allDayRows > 0 ? ui.hairline : 0
      visible: root.allDayRows > 0
      color: ui.border
    }

    // ----------------------------------------------------------- the hours
    Flickable {
      id: hourFlick
      width: parent.width
      height: parent.height - y
      contentWidth: width
      contentHeight: 24 * root.hourHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      MomentumScroll { view: hourFlick }

      // Opening on midnight wastes half the view on hours nobody uses.
      Component.onCompleted: contentY = Math.min(
        Math.max(0, 7 * root.hourHeight - Style.space(8)),
        Math.max(0, contentHeight - height))

      Item {
        width: hourFlick.width
        height: hourFlick.contentHeight

        // Hour lines and their labels.
        Repeater {
          model: 24

          Item {
            required property int index
            y: index * root.hourHeight
            width: parent.width
            height: root.hourHeight

            Text {
              anchors.right: parent.left
              anchors.rightMargin: -root.gutter + Style.space(6)
              anchors.top: parent.top
              anchors.topMargin: -Style.space(5)
              text: Model.pad(parent.index) + ":00"
              color: ui.faint
              font.family: ui.fontFamily
              font.pixelSize: Style.font.caption
            }

            Rectangle {
              anchors.left: parent.left
              anchors.leftMargin: root.gutter
              anchors.right: parent.right
              anchors.top: parent.top
              height: ui.hairline
              color: ui.border
            }
          }
        }

        // One column per day, with the appointments in it.
        Row {
          anchors.fill: parent
          anchors.leftMargin: root.gutter

          Repeater {
            model: root.days

            Item {
              id: dayColumn
              required property var modelData
              width: root.columnWidth
              height: parent.height

              Rectangle {
                anchors.fill: parent
                color: dayColumn.modelData.key === root.selected
                  ? Util.alpha(ui.accent, 0.05) : "transparent"
              }

              Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: ui.hairline
                color: ui.border
              }

              Repeater {
                model: root.laidOut(dayColumn.modelData.key,
                                    Math.round(dayColumn.modelData.date.getTime() / 1000))

                Rectangle {
                  required property var modelData
                  readonly property real slotWidth:
                    (dayColumn.width - Style.space(4)) / modelData.columns
                  x: Style.space(2) + modelData.column * slotWidth
                  y: modelData.top
                  width: slotWidth - Style.space(1)
                  height: modelData.span
                  radius: Style.space(3)
                  color: Util.alpha(modelData.event.colour || ui.accent, 0.3)
                  border.width: 1
                  border.color: Util.alpha(modelData.event.colour || ui.accent, 0.65)

                  readonly property string clockText:
                    Model.pad(new Date(modelData.event.start * 1000).getHours())
                    + ":" + Model.pad(new Date(modelData.event.start * 1000).getMinutes())
                  // Below this there is one line to spend, and it is better
                  // spent on the name than on a time the position already
                  // gives away.
                  readonly property bool roomForBoth: height >= Style.space(34)

                  Column {
                    anchors.fill: parent
                    anchors.margins: Style.space(3)
                    spacing: 0
                    clip: true

                    Text {
                      visible: parent.parent.roomForBoth
                      height: visible ? implicitHeight : 0
                      width: parent.width
                      textFormat: Text.PlainText
                      elide: Text.ElideRight
                      text: parent.parent.clockText
                      color: ui.dim
                      font.family: ui.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      wrapMode: Text.Wrap
                      elide: Text.ElideRight
                      maximumLineCount: parent.parent.roomForBoth ? 2 : 1
                      text: (parent.parent.roomForBoth ? "" : parent.parent.clockText + "  ")
                            + (modelData.event.summary || "(no title)")
                      color: ui.foreground
                      font.family: ui.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      root.daySelected(dayColumn.modelData.key)
                      root.eventChosen(modelData.event)
                    }
                  }
                }
              }

              // Where the day has got to, drawn only on today.
              Rectangle {
                visible: dayColumn.modelData.key === root.today
                anchors.left: parent.left
                anchors.right: parent.right
                height: ui.hairline * 2
                color: ui.urgent
                y: {
                  var now = new Date()
                  return (now.getHours() * 60 + now.getMinutes()) / 60 * root.hourHeight
                }
              }
            }
          }
        }
      }
    }
  }
}
