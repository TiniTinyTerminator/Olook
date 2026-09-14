import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The calendar: a month at a time with the day's agenda beside it, which is
// the shape Outlook opens on. The grid is the navigation and the agenda is
// where the detail lives, so a cell only has to say how busy a day looks.
Item {
  id: root

  property var ui: null
  property var service: null

  // The month on show, held as its first day, and the day picked out of it.
  property date month: root.startOfMonth(new Date())
  property string selected: root.dayKey(new Date())

  readonly property var events: service ? service.events : []
  readonly property string today: root.dayKey(new Date())

  // Sunday-start weeks are an American habit; the Netherlands starts Monday.
  readonly property var weekdays: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
  readonly property var monthNames: ["January", "February", "March", "April",
    "May", "June", "July", "August", "September", "October", "November", "December"]

  function startOfMonth(date) {
    return new Date(date.getFullYear(), date.getMonth(), 1)
  }

  function dayKey(date) {
    return date.getFullYear() + "-" + Model.pad(date.getMonth() + 1)
           + "-" + Model.pad(date.getDate())
  }

  // The Monday on or before the first of the month, which is where the grid
  // starts. getDay() calls Sunday 0, so Monday has to be pulled forward six.
  function gridStart() {
    var first = root.startOfMonth(root.month)
    var weekday = (first.getDay() + 6) % 7
    return new Date(first.getFullYear(), first.getMonth(), 1 - weekday)
  }

  function cellDate(index) {
    var from = root.gridStart()
    return new Date(from.getFullYear(), from.getMonth(), from.getDate() + index)
  }

  // Events keyed by the day they fall on, so a cell is a lookup rather than a
  // scan of everything on show.
  readonly property var byDay: {
    var map = ({})
    for (var i = 0; i < root.events.length; i++) {
      var event = root.events[i]
      var key = event.day || ""
      if (!key) continue
      if (!map[key]) map[key] = []
      map[key].push(event)
    }
    return map
  }

  function eventsOn(key) { return root.byDay[key] || [] }

  function step(months) {
    root.month = new Date(root.month.getFullYear(), root.month.getMonth() + months, 1)
    root.ask()
  }

  function goToday() {
    var now = new Date()
    root.month = root.startOfMonth(now)
    root.selected = root.dayKey(now)
    root.ask()
  }

  // A fortnight either side of the month, so the grid's leading and trailing
  // days are filled in too.
  function ask() {
    if (!root.service) return
    var from = root.gridStart()
    var to = new Date(from.getFullYear(), from.getMonth(), from.getDate() + 42)
    root.service.loadCalendar(root.dayKey(from), root.dayKey(to))
  }

  onVisibleChanged: if (visible && service) {
    root.ask()
    service.loadCalendars()
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
      width: parent.width
      height: Style.space(46)

      Row {
        anchors.left: parent.left
        anchors.leftMargin: Style.space(16)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(8)

        StepButton { glyph: "\udb80\udd41"; onTriggered: root.step(-1) }
        StepButton { glyph: "\udb80\udd42"; onTriggered: root.step(1) }

        Rectangle {
          width: todayText.implicitWidth + Style.space(20)
          height: Style.space(28)
          anchors.verticalCenter: parent.verticalCenter
          radius: ui.radius
          color: todayHover.containsMouse ? ui.hover : "transparent"
          border.width: 1
          border.color: ui.border

          Text {
            id: todayText
            anchors.centerIn: parent
            text: "Today"
            color: ui.foreground
            font.family: ui.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          MouseArea {
            id: todayHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.goToday()
          }
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: root.monthNames[root.month.getMonth()] + " " + root.month.getFullYear()
          color: ui.foreground
          font.family: ui.fontFamily
          font.pixelSize: Style.font.title
        }
      }

      Rectangle {
        id: refreshButton
        anchors.right: parent.right
        anchors.rightMargin: Style.space(16)
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(28)
        height: Style.space(28)
        radius: ui.radius
        color: refreshHover.containsMouse ? ui.hover : "transparent"
        border.width: 1
        border.color: ui.border

        Text {
          anchors.centerIn: parent
          text: root.service && root.service.calendarSyncing ? "󰔟" : "󰑐"
          color: ui.dim
          font.family: ui.fontFamily
          font.pixelSize: Style.font.iconSmall
        }

        MouseArea {
          id: refreshHover
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: if (root.service) root.service.syncCalendar(null)
        }

        PanelToolTip {
          visible: refreshHover.containsMouse
          text: "Fetch this month from your accounts"
          fontFamily: ui.fontFamily
        }
      }
    }

    Rectangle { width: parent.width; height: ui.hairline; color: ui.border }

    Row {
      width: parent.width
      height: parent.height - y
      spacing: 0

      // ---------------------------------------------------------- the month
      Item {
        width: parent.width - agenda.width - agendaEdge.width
        height: parent.height

        Column {
          anchors.fill: parent
          spacing: 0

          Row {
            width: parent.width
            height: Style.space(24)

            Repeater {
              model: root.weekdays
              Item {
                required property string modelData
                width: parent.width / 7
                height: parent.height

                Text {
                  anchors.centerIn: parent
                  text: parent.modelData
                  color: ui.faint
                  font.family: ui.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }
          }

          Grid {
            id: monthGrid
            width: parent.width
            height: parent.height - y
            columns: 7
            rows: 6

            Repeater {
              model: 42

              Item {
                id: cell
                required property int index
                width: monthGrid.width / 7
                height: monthGrid.height / 6

                readonly property date date: root.cellDate(cell.index)
                readonly property string key: root.dayKey(cell.date)
                readonly property bool outside: cell.date.getMonth() !== root.month.getMonth()
                readonly property var items: root.eventsOn(cell.key)
                // Three fit; a fourth would push the count off the bottom.
                readonly property int shown: Math.min(3, cell.items.length)

                Rectangle {
                  anchors.fill: parent
                  color: cell.key === root.selected ? ui.selected
                    : (cellHover.containsMouse ? ui.hover : "transparent")

                  Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    height: ui.hairline
                    color: ui.border
                  }
                  Rectangle {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: ui.hairline
                    color: ui.border
                  }
                }

                Column {
                  anchors.fill: parent
                  anchors.margins: Style.space(4)
                  spacing: Style.space(2)

                  Rectangle {
                    width: Style.space(20)
                    height: Style.space(18)
                    radius: height / 2
                    color: cell.key === root.today ? ui.accent : "transparent"

                    Text {
                      anchors.centerIn: parent
                      text: String(cell.date.getDate())
                      color: cell.key === root.today ? ui.background
                        : (cell.outside ? ui.faint : ui.foreground)
                      font.family: ui.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: cell.key === root.today
                    }
                  }

                  Repeater {
                    model: cell.shown

                    Rectangle {
                      required property int index
                      readonly property var event: cell.items[index]
                      width: parent.width
                      height: Style.space(15)
                      radius: Style.space(3)
                      color: Util.alpha(event.colour || ui.accent, 0.22)

                      Text {
                        anchors.fill: parent
                        anchors.leftMargin: Style.space(4)
                        anchors.rightMargin: Style.space(3)
                        verticalAlignment: Text.AlignVCenter
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        text: (parent.event.allDay ? "" : Model.pad(
                                 new Date(parent.event.start * 1000).getHours()) + ":"
                                 + Model.pad(new Date(parent.event.start * 1000).getMinutes())
                                 + "  ")
                              + parent.event.summary
                        color: cell.outside ? ui.dim : ui.foreground
                        font.family: ui.fontFamily
                        font.pixelSize: Style.font.bodySmall
                      }
                    }
                  }

                  Text {
                    visible: cell.items.length > cell.shown
                    text: "+" + (cell.items.length - cell.shown) + " more"
                    color: ui.faint
                    font.family: ui.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }

                MouseArea {
                  id: cellHover
                  anchors.fill: parent
                  hoverEnabled: true
                  onClicked: root.selected = cell.key
                }
              }
            }
          }
        }
      }

      Rectangle {
        id: agendaEdge
        width: ui.hairline
        height: parent.height
        color: ui.border
      }

      // --------------------------------------------------------- the agenda
      Item {
        id: agenda
        width: Math.max(Style.space(240), Math.round(root.width * 0.26))
        height: parent.height

        Column {
          anchors.fill: parent
          anchors.margins: Style.space(14)
          spacing: Style.space(10)

          Text {
            width: parent.width
            textFormat: Text.PlainText
            elide: Text.ElideRight
            text: root.agendaTitle
            color: ui.foreground
            font.family: ui.fontFamily
            font.pixelSize: Style.font.body
          }

          Text {
            width: parent.width
            visible: root.eventsOn(root.selected).length === 0
            wrapMode: Text.Wrap
            text: root.service && !root.service.canReadCalendar
              ? "No account here keeps a calendar."
              : (root.events.length === 0
                 ? "Nothing fetched yet — press the refresh button above. The first time, it will ask you to sign in for the calendar."
                 : "Nothing on this day.")
            color: ui.faint
            font.family: ui.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          ListView {
            width: parent.width
            height: parent.height - y
            clip: true
            spacing: Style.space(8)
            model: root.eventsOn(root.selected)
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            delegate: Column {
              required property var modelData
              width: ListView.view.width
              spacing: Style.space(2)

              Row {
                spacing: Style.space(6)

                Rectangle {
                  width: Style.space(3)
                  height: Style.space(14)
                  radius: Style.space(2)
                  anchors.verticalCenter: parent.verticalCenter
                  color: modelData.colour || ui.accent
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData.allDay ? "All day" : root.clock(modelData)
                  color: ui.dim
                  font.family: ui.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                text: modelData.summary || "(no title)"
                color: ui.foreground
                font.family: ui.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                width: parent.width
                visible: (modelData.location || "") !== ""
                textFormat: Text.PlainText
                elide: Text.ElideRight
                text: "󰍎  " + modelData.location
                color: ui.faint
                font.family: ui.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                width: parent.width
                visible: (modelData.calendarName || "") !== ""
                textFormat: Text.PlainText
                elide: Text.ElideRight
                text: modelData.calendarName
                color: ui.faint
                font.family: ui.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
          }
        }
      }
    }
  }

  readonly property string agendaTitle: {
    var parts = root.selected.split("-")
    if (parts.length !== 3) return "Agenda"
    var when = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]))
    return root.weekdays[(when.getDay() + 6) % 7] + " "
           + when.getDate() + " " + root.monthNames[when.getMonth()]
  }

  function clock(event) {
    var from = new Date(event.start * 1000)
    var to = new Date(event.end * 1000)
    return Model.pad(from.getHours()) + ":" + Model.pad(from.getMinutes())
           + " – " + Model.pad(to.getHours()) + ":" + Model.pad(to.getMinutes())
  }

  component StepButton: Rectangle {
    id: step
    property string glyph: ""
    signal triggered()

    width: Style.space(28)
    height: Style.space(28)
    anchors.verticalCenter: parent.verticalCenter
    radius: ui.radius
    color: stepHover.containsMouse ? ui.hover : "transparent"
    border.width: 1
    border.color: ui.border

    Text {
      anchors.centerIn: parent
      text: step.glyph
      color: ui.dim
      font.family: ui.fontFamily
      font.pixelSize: Style.font.iconSmall
    }

    MouseArea {
      id: stepHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: step.triggered()
    }
  }
}
