import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
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

  // day | workweek | week | month. Each answers a different question: a month
  // says how busy a fortnight looks, a day says whether there is room at
  // three o'clock, and a work week is how a timetable is actually read.
  property string view: "month"
  readonly property var viewNames: [
    { "id": "day", "label": "Day" },
    { "id": "workweek", "label": "Work week" },
    { "id": "week", "label": "Week" },
    { "id": "month", "label": "Month" }
  ]

  function dateOf(key) {
    var parts = String(key || "").split("-")
    if (parts.length !== 3) return new Date()
    return new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]))
  }

  // The Monday of whichever week the given day falls in.
  function weekStart(date) {
    var weekday = (date.getDay() + 6) % 7
    return new Date(date.getFullYear(), date.getMonth(), date.getDate() - weekday)
  }

  // The first day on screen, and how many days follow it.
  function spanStart() {
    var day = root.dateOf(root.selected)
    if (root.view === "day") return day
    if (root.view === "month") return root.gridStart()
    return root.weekStart(day)
  }

  function spanDays() {
    if (root.view === "day") return 1
    if (root.view === "workweek") return 5
    if (root.view === "week") return 7
    return 42
  }

  // What the time grid draws: one entry per column.
  readonly property var spanColumns: {
    var out = []
    if (root.view === "month") return out
    var from = root.spanStart()
    for (var i = 0; i < root.spanDays(); i++) {
      var day = new Date(from.getFullYear(), from.getMonth(), from.getDate() + i)
      out.push({
        "key": root.dayKey(day),
        "date": day,
        "label": root.weekdays[(day.getDay() + 6) % 7] + " " + day.getDate()
      })
    }
    return out
  }

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

  // The appointment being looked at, which takes over the pane beside the
  // grid. A month cell has room for a name and nothing else, so everything
  // else an appointment carries needs somewhere to be read.
  property var openEvent: null

  function showEvent(entry) {
    if (!entry) return
    root.openEvent = entry
    if (entry.day) root.selected = String(entry.day)
  }

  onSelectedChanged: {
    // Moving to another day is leaving the appointment that was open on the
    // last one, unless the appointment is what moved us.
    if (root.openEvent && String(root.openEvent.day || "") !== root.selected)
      root.openEvent = null
  }

  readonly property var calendars: service ? service.calendars : []

  // Offered whatever else is on screen: an account already signed in does
  // not sign in the one beside it, and gating this on "no calendars at all"
  // hid the button behind another account's calendar.
  readonly property var needSignIn: service ? service.accountsNeedingExtras : []

  // The panel's contents, flattened: an account heading followed by that
  // account's calendars. Headings are only worth the room when more than one
  // account has a calendar to name.
  readonly property var calendarRows: {
    var order = []
    var grouped = ({})
    for (var i = 0; i < root.calendars.length; i++) {
      var entry = root.calendars[i]
      if (!grouped[entry.account]) {
        grouped[entry.account] = []
        order.push(entry.account)
      }
      grouped[entry.account].push(entry)
    }

    var accounts = root.service ? root.service.accounts : []
    function nameOf(id) {
      // Calendars read from a file belong to no mailbox, so they are grouped
      // under where they came from rather than under an address.
      if (id === "local") return "On this computer"
      for (var j = 0; j < accounts.length; j++)
        if (accounts[j].id === id) return accounts[j].email || accounts[j].name
      return id
    }

    var rows = []
    for (var k = 0; k < order.length; k++) {
      if (order.length > 1)
        rows.push({ "heading": nameOf(order[k]), "calendar": null })
      var mine = grouped[order[k]]
      for (var m = 0; m < mine.length; m++)
        rows.push({ "heading": "", "calendar": mine[m] })
    }
    return rows
  }

  // Adding a calendar that lives in a file. Held here rather than in the
  // fields so that closing the form and opening it again starts clean.
  property bool addingCalendar: false
  property string draftName: ""
  property string draftSource: ""

  function startAddCalendar() {
    root.draftName = ""
    root.draftSource = ""
    root.addingCalendar = true
  }

  function commitCalendar() {
    if (!root.service || root.draftSource.trim() === "") return
    root.service.addCalendarFile(root.draftName.trim(), root.draftSource.trim(), "",
                                 function (ok) { if (ok) root.addingCalendar = false })
  }

  function toggleCalendar(entry) {
    if (root.service && entry) root.service.setCalendarHidden(entry.id, !entry.hidden)
  }

  function step(direction) {
    if (root.view === "month") {
      root.month = new Date(root.month.getFullYear(),
                            root.month.getMonth() + direction, 1)
      root.ask()
      return
    }
    var days = root.view === "day" ? 1 : 7
    var day = root.dateOf(root.selected)
    var moved = new Date(day.getFullYear(), day.getMonth(),
                         day.getDate() + direction * days)
    root.selected = root.dayKey(moved)
    root.month = root.startOfMonth(moved)
    root.ask()
  }

  function setView(name) {
    if (!name || name === root.view) return
    root.view = name
    root.month = root.startOfMonth(root.dateOf(root.selected))
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
    var from = root.spanStart()
    // A day or a week is a small ask; fetching the month around it means
    // stepping to the next day is usually a read from the cache.
    var length = root.view === "month" ? 42 : 42
    if (root.view !== "month") from = root.gridStart()
    var to = new Date(from.getFullYear(), from.getMonth(), from.getDate() + length)
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
          text: root.headingText
          color: ui.foreground
          font.family: ui.fontFamily
          font.pixelSize: Style.font.title
        }
      }

      Row {
        anchors.right: refreshButton.left
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(4)

        Repeater {
          model: root.viewNames

          Rectangle {
            required property var modelData
            readonly property bool current: root.view === modelData.id
            width: viewLabel.implicitWidth + Style.space(16)
            height: Style.space(26)
            radius: ui.radius
            color: current ? ui.selected
              : (viewHover.containsMouse ? ui.hover : "transparent")
            border.width: 1
            border.color: current ? Util.alpha(ui.accent, 0.55) : ui.border

            Text {
              id: viewLabel
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: parent.modelData.label
              color: parent.current ? ui.accent : ui.dim
              font.family: ui.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            MouseArea {
              id: viewHover
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.setView(parent.modelData.id)
            }
          }
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

      // ------------------------------------------------------ the calendars
      Item {
        id: calendarPanel
        visible: root.calendarRows.length > 0
        width: visible ? Math.max(Style.space(170), Math.round(root.width * 0.16)) : 0
        height: parent.height

        Column {
          anchors.fill: parent
          anchors.margins: Style.space(12)
          spacing: Style.space(8)

          Item {
            width: parent.width
            height: Style.space(18)

            Text {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Calendars"
              color: ui.dim
              font.family: ui.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Rectangle {
              id: addCalendarButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(18)
              height: Style.space(18)
              radius: Style.space(4)
              color: addCalendarHover.containsMouse ? ui.hover : "transparent"

              Text {
                anchors.centerIn: parent
                text: "\udb81\udc15"
                color: ui.dim
                font.family: ui.fontFamily
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                id: addCalendarHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.addingCalendar ? root.addingCalendar = false
                                               : root.startAddCalendar()
              }

              PanelToolTip {
                visible: addCalendarHover.containsMouse
                text: "Add a calendar from a file or a link"
                fontFamily: ui.fontFamily
              }
            }
          }

          // The form, which stays out of the way until the plus is pressed.
          Column {
            width: parent.width
            visible: root.addingCalendar
            spacing: Style.space(5)

            CalendarField {
              id: nameField
              width: parent.width
              placeholder: "Name"
              onEdited: function (value) { root.draftName = value }
            }

            CalendarField {
              id: sourceField
              width: parent.width
              placeholder: "File path or https:// link"
              onEdited: function (value) { root.draftSource = value }
            }

            Row {
              spacing: Style.space(5)

              PanelChip {
                label: "Browse…"
                onTriggered: calendarPicker.open()
              }

              PanelChip {
                label: "Add"
                accent: true
                onTriggered: root.commitCalendar()
              }
            }
          }

          ListView {
            id: calendarList
            width: parent.width
            height: parent.height - y
            clip: true
            spacing: Style.space(1)
            model: root.calendarRows
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            MomentumScroll { view: calendarList }

            delegate: Item {
              id: calendarRow
              required property var modelData
              width: ListView.view.width
              height: modelData.heading !== "" ? Style.space(26) : Style.space(24)

              // An account's name, above the calendars that belong to it.
              Text {
                visible: calendarRow.modelData.heading !== ""
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                anchors.bottomMargin: Style.space(3)
                width: parent.width
                textFormat: Text.PlainText
                elide: Text.ElideRight
                text: calendarRow.modelData.heading
                color: ui.faint
                font.family: ui.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Rectangle {
                visible: calendarRow.modelData.calendar !== null
                anchors.fill: parent
                radius: Style.space(3)
                color: calendarHover.containsMouse ? ui.hover : "transparent"

                Row {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(4)
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(4)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(7)

                  // Filled when the calendar is shown, hollow when it is not:
                  // the tick and the colour key are the same mark.
                  Rectangle {
                    id: swatch
                    readonly property var entry: calendarRow.modelData.calendar
                    readonly property color ink: (entry && entry.colour)
                      ? entry.colour : ui.accent
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(12)
                    height: Style.space(12)
                    radius: Style.space(3)
                    color: (entry && entry.hidden) ? "transparent" : swatch.ink
                    border.width: 1
                    border.color: swatch.ink
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - swatch.width - parent.spacing
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    text: calendarRow.modelData.calendar
                      ? calendarRow.modelData.calendar.name : ""
                    color: (calendarRow.modelData.calendar
                            && calendarRow.modelData.calendar.hidden)
                      ? ui.faint : ui.foreground
                    font.family: ui.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }

                MouseArea {
                  id: calendarHover
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.toggleCalendar(calendarRow.modelData.calendar)
                }

                Rectangle {
                  readonly property var entry: calendarRow.modelData.calendar
                  visible: !!entry && entry.account === "local"
                           && (calendarHover.containsMouse || forgetHover.containsMouse)
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(2)
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(16)
                  height: Style.space(16)
                  radius: Style.space(4)
                  color: forgetHover.containsMouse
                    ? Util.alpha(ui.urgent, 0.22) : "transparent"

                  Text {
                    anchors.centerIn: parent
                    text: "\u00d7"
                    color: forgetHover.containsMouse ? ui.urgent : ui.faint
                    font.family: ui.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  MouseArea {
                    id: forgetHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: if (root.service && parent.entry)
                      root.service.forgetCalendar(parent.entry.id)
                  }

                  PanelToolTip {
                    visible: forgetHover.containsMouse
                    text: "Stop showing this calendar"
                    fontFamily: ui.fontFamily
                  }
                }
              }
            }
          }
        }
      }

      Rectangle {
        id: panelEdge
        visible: calendarPanel.visible
        width: visible ? ui.hairline : 0
        height: parent.height
        color: ui.border
      }

      // ------------------------------------------------- the month, or hours
      Item {
        width: parent.width - calendarPanel.width - panelEdge.width
               - agenda.width - agendaEdge.width
        height: parent.height

        MailTimeGrid {
          anchors.fill: parent
          visible: root.view !== "month"
          ui: root.ui
          days: root.spanColumns
          byDay: root.byDay
          today: root.today
          selected: root.selected
          onDaySelected: function (key) { root.selected = key }
          onEventChosen: function (event) { root.showEvent(event) }
        }

        Column {
          anchors.fill: parent
          visible: root.view === "month"
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

                // How many appointments a cell can show depends on how tall
                // the cell is, which depends on the window. Three was assumed
                // and the third plus the "+2 more" under it hung out of the
                // bottom of a short cell.
                readonly property int chipStep: Style.space(15) + Style.space(2)
                // What is left under the date pill, margins and its spacing.
                readonly property int roomForChips:
                  Math.max(0, cell.height - Style.space(28))
                readonly property int fits:
                  Math.floor(cell.roomForChips / cell.chipStep)
                // When there are more than fit, one of the places goes to
                // the line that says how many are left.
                readonly property int shown: cell.items.length <= cell.fits
                  ? cell.items.length
                  : Math.max(0, cell.fits - 1)

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
                  // Belt and braces: the arithmetic above decides what to
                  // draw, and this makes certain nothing escapes the cell
                  // whatever it decides.
                  clip: true

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

                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                          root.selected = cell.key
                          root.showEvent(parent.event)
                        }
                      }
                    }
                  }

                  Text {
                    width: parent.width
                    visible: cell.items.length > cell.shown
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    text: "+" + (cell.items.length - cell.shown) + " more"
                    color: ui.faint
                    font.family: ui.fontFamily
                    font.pixelSize: Style.font.bodySmall

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      // The rest of the day is what the agenda beside the
                      // grid is for.
                      onClicked: root.selected = cell.key
                    }
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

        // ------------------------------------------------ one appointment
        Flickable {
          id: detailFlick
          anchors.fill: parent
          visible: !!root.openEvent
          contentWidth: width
          contentHeight: detail.implicitHeight + Style.space(28)
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          MomentumScroll { view: detailFlick }

          Column {
            id: detail
            x: Style.space(14)
            y: Style.space(14)
            width: parent.width - Style.space(28)
            spacing: Style.space(8)

            Row {
              spacing: Style.space(6)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "\udb80\udd41"
                color: ui.dim
                font.family: ui.fontFamily
                font.pixelSize: Style.font.bodySmall

                MouseArea {
                  anchors.fill: parent
                  anchors.margins: -Style.space(4)
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.openEvent = null
                }
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Back to the day"
                color: ui.dim
                font.family: ui.fontFamily
                font.pixelSize: Style.font.caption

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.openEvent = null
                }
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(7)

              Rectangle {
                width: Style.space(3)
                height: titleText.implicitHeight
                radius: Style.space(2)
                color: root.openEvent
                  ? (root.openEvent.colour || ui.accent) : ui.accent
              }

              Text {
                id: titleText
                width: parent.width - Style.space(10)
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                text: root.openEvent
                  ? (root.openEvent.summary || "(no title)") : ""
                color: ui.foreground
                font.family: ui.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            EventLine {
              width: parent.width
              label: "When"
              value: root.openEvent ? root.whenText(root.openEvent) : ""
            }
            EventLine {
              width: parent.width
              label: "Where"
              value: root.openEvent ? (root.openEvent.location || "") : ""
            }
            EventLine {
              width: parent.width
              label: "Organiser"
              value: root.openEvent ? (root.openEvent.organiser || "") : ""
            }
            EventLine {
              width: parent.width
              label: "Calendar"
              value: root.openEvent ? (root.openEvent.calendarName || "") : ""
            }
            EventLine {
              width: parent.width
              label: "Repeats"
              value: !!(root.openEvent && root.openEvent.recurring)
                ? "One of a series" : ""
            }

            Rectangle {
              width: parent.width
              height: ui.hairline
              color: ui.border
              visible: !!(root.openEvent && (root.openEvent.description || "") !== "")
            }

            Text {
              width: parent.width
              visible: !!(root.openEvent && (root.openEvent.description || "") !== "")
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              text: root.openEvent ? (root.openEvent.description || "") : ""
              color: ui.dim
              font.family: ui.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }
        }

        Column {
          anchors.fill: parent
          visible: !root.openEvent
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
              : (root.needSignIn.length > 0
                 ? "One sign-in per account covers its calendar and its contacts."
                 : (root.events.length === 0
                    ? "Nothing fetched yet — press the refresh button above."
                    : "Nothing on this day."))
            color: ui.faint
            font.family: ui.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          // When the organisation will not let someone consent for
          // themselves, the narrower ask is the one thing worth trying
          // before going to an administrator.
          Rectangle {
            visible: !!(root.service && root.service.extrasNeedApproval)
            width: readOnlyText.implicitWidth + Style.space(22)
            height: Style.space(30)
            radius: ui.radius
            color: readOnlyHover.containsMouse ? ui.hover : "transparent"
            border.width: 1
            border.color: ui.border

            Text {
              id: readOnlyText
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: "Try asking for read-only"
              color: ui.foreground
              font.family: ui.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            MouseArea {
              id: readOnlyHover
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                var waiting = root.needSignIn
                if (root.service && waiting.length > 0)
                  root.service.authorizeExtras(waiting[0].id, function () {
                    root.service.syncCalendar(null)
                  }, true)
              }
            }
          }

          // The sign-in the calendar needs, rather than a line of prose
          // telling you to go and find a terminal.
          Repeater {
            model: root.needSignIn

            Rectangle {
              required property var modelData
              width: signInText.implicitWidth + Style.space(22)
              height: Style.space(30)
              radius: ui.radius
              color: signInHover.containsMouse ? ui.hover : "transparent"
              border.width: 1
              border.color: Util.alpha(ui.accent, 0.55)

              Text {
                id: signInText
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: root.service && root.service.extrasAuthorizing
                  ? "Signing in…"
                  : "Sign in — " + (modelData.email || modelData.id)
                color: ui.accent
                font.family: ui.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              MouseArea {
                id: signInHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: if (root.service && !root.service.extrasAuthorizing)
                  root.service.authorizeExtras(modelData.id, function () {
                    root.service.syncCalendar(null)
                  }, false)
              }
            }
          }

          ListView {
            id: agendaList
            width: parent.width
            height: parent.height - y
            clip: true
            spacing: Style.space(8)
            model: root.eventsOn(root.selected)
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            MomentumScroll { view: agendaList }

            // The row is an Item holding a Column, not a Column itself: a
            // MouseArea filling its parent cannot be a child of a Column,
            // which both positions it and is sized by it. Putting one there
            // collapsed the height and drew every row on top of the last.
            delegate: Item {
              id: agendaRow
              required property var modelData
              width: ListView.view.width
              implicitHeight: agendaBody.implicitHeight
              height: implicitHeight

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.showEvent(agendaRow.modelData)
              }

              Column {
                id: agendaBody
                width: parent.width
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
  }

  // What the header says, which is the span on screen rather than always a
  // month: "Thu 17 September", "15 – 19 September", "September 2026".
  readonly property string headingText: {
    if (root.view === "month")
      return root.monthNames[root.month.getMonth()] + " " + root.month.getFullYear()

    var columns = root.spanColumns
    if (columns.length === 0) return ""
    var first = columns[0].date
    var last = columns[columns.length - 1].date
    if (root.view === "day")
      return root.weekdays[(first.getDay() + 6) % 7] + " " + first.getDate()
             + " " + root.monthNames[first.getMonth()]
    if (first.getMonth() === last.getMonth())
      return first.getDate() + " – " + last.getDate() + " "
             + root.monthNames[first.getMonth()] + " " + first.getFullYear()
    return first.getDate() + " " + root.monthNames[first.getMonth()] + " – "
           + last.getDate() + " " + root.monthNames[last.getMonth()]
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

  FileDialog {
    id: calendarPicker
    title: "Choose a calendar file"
    nameFilters: ["Calendars (*.ics *.ical *.ifb)", "All files (*)"]
    onAccepted: {
      var path = String(calendarPicker.selectedFile).replace(/^file:\/\//, "")
      root.draftSource = decodeURIComponent(path)
      sourceField.text = root.draftSource
      if (root.draftName === "") {
        var base = root.draftSource.split("/").pop().replace(/\.[^.]*$/, "")
        root.draftName = base
        nameField.text = base
      }
    }
  }

  // A labelled line that takes no room when there is nothing to put on it.
  component EventLine: Column {
    property string label: ""
    property string value: ""
    visible: value !== ""
    height: visible ? implicitHeight : 0
    spacing: Style.space(1)

    Text {
      text: parent.label
      color: ui.faint
      font.family: ui.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      width: parent.width
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: parent.value
      color: ui.foreground
      font.family: ui.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  function whenText(event) {
    if (!event) return ""
    var from = new Date(event.start * 1000)
    var day = root.weekdays[(from.getDay() + 6) % 7] + " " + from.getDate()
              + " " + root.monthNames[from.getMonth()]
    if (event.allDay) return day + " — all day"
    return day + ", " + root.clock(event)
  }

  component CalendarField: Rectangle {
    id: field
    property string placeholder: ""
    property alias text: fieldInput.text
    signal edited(string value)

    height: Style.space(26)
    radius: ui.radius
    color: ui.surface
    border.width: 1
    border.color: fieldInput.activeFocus ? ui.accent : ui.border

    TextInput {
      id: fieldInput
      anchors.fill: parent
      anchors.leftMargin: Style.space(7)
      anchors.rightMargin: Style.space(7)
      verticalAlignment: TextInput.AlignVCenter
      color: ui.foreground
      font.family: ui.fontFamily
      font.pixelSize: Style.font.caption
      selectionColor: Util.alpha(ui.accent, 0.35)
      selectByMouse: true
      clip: true
      onTextChanged: field.edited(text)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: fieldInput.text === ""
        text: field.placeholder
        color: ui.faint
        font.family: ui.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  component PanelChip: Rectangle {
    id: chip
    property string label: ""
    property bool accent: false
    signal triggered()

    width: chipLabel.implicitWidth + Style.space(14)
    height: Style.space(24)
    radius: ui.radius
    color: chipHover.containsMouse ? ui.hover : "transparent"
    border.width: 1
    border.color: chip.accent ? Util.alpha(ui.accent, 0.55) : ui.border

    Text {
      id: chipLabel
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: chip.label
      color: chip.accent ? ui.accent : ui.foreground
      font.family: ui.fontFamily
      font.pixelSize: Style.font.caption
    }

    MouseArea {
      id: chipHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: chip.triggered()
    }
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
