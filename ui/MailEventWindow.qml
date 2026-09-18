import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import "Model.js" as Model

// One appointment in its own toplevel window.
//
// The companion to MailReaderWindow: what the bar's calendar opens when you
// pick an appointment there, the way the mail widget opens a message. Reading
// one appointment should not have to summon the whole client, and a
// timetable entry's description -- rooms, course codes, links to floor plans
// -- needs more room than a panel row.
//
// The appointment is pinned when the window opens; nothing behind it redraws
// it, and it redraws nothing.
FloatingWindow {
  id: window

  property var ui: null
  property var entry: null

  // Named `dismissed` rather than `closed`: FloatingWindow has a closed()
  // signal of its own.
  signal dismissed()
  signal calendarRequested(var entry)

  readonly property var weekdays: ["Monday", "Tuesday", "Wednesday", "Thursday",
                                   "Friday", "Saturday", "Sunday"]
  readonly property var monthNames: ["January", "February", "March", "April",
    "May", "June", "July", "August", "September", "October", "November", "December"]

  title: {
    var name = window.entry ? String(window.entry.summary || "") : ""
    return (name.trim() === "" ? "Appointment" : name) + " — Olook"
  }
  color: ui ? ui.background : "#101010"
  implicitWidth: Style.space(520)
  implicitHeight: Style.space(560)
  minimumSize: Qt.size(Style.space(360), Style.space(280))

  onVisibleChanged: if (!visible) window.dismissed()

  function clock(seconds) {
    var when = new Date(seconds * 1000)
    return Model.pad(when.getHours()) + ":" + Model.pad(when.getMinutes())
  }

  readonly property string whenText: {
    if (!window.entry) return ""
    var from = new Date(window.entry.start * 1000)
    var day = window.weekdays[(from.getDay() + 6) % 7] + " " + from.getDate()
              + " " + window.monthNames[from.getMonth()] + " " + from.getFullYear()
    if (window.entry.allDay) return day + " — all day"
    return day + "\n" + window.clock(window.entry.start)
           + " – " + window.clock(window.entry.end)
  }

  // Timetable descriptions are full of links to floor plans and course pages.
  // The text is escaped first and only then are the links made clickable, so
  // nothing in a description can turn into markup of its own.
  function linkified(text) {
    var safe = String(text || "")
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    safe = safe.replace(/(https?:\/\/[^\s<]+)/g, function (url) {
      return "<a href=\"" + url + "\">" + url + "</a>"
    })
    return safe.replace(/\n/g, "<br>")
  }

  Rectangle {
    anchors.fill: parent
    color: window.ui ? window.ui.background : "#101010"
  }

  Flickable {
    id: detailFlick
    anchors.fill: parent
    anchors.bottomMargin: footer.height
    contentWidth: width
    contentHeight: detail.implicitHeight + Style.space(40)
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    MomentumScroll { view: detailFlick }

    Column {
      id: detail
      x: Style.space(22)
      y: Style.space(20)
      width: parent.width - Style.space(44)
      spacing: Style.space(14)

      Row {
        width: parent.width
        spacing: Style.space(10)

        Rectangle {
          width: Style.space(4)
          height: titleText.implicitHeight
          radius: Style.space(2)
          color: window.entry && window.entry.colour
            ? window.entry.colour : (window.ui ? window.ui.accent : "#89b4fa")
        }

        Text {
          id: titleText
          width: parent.width - Style.space(14)
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          text: window.entry ? (window.entry.summary || "(no title)") : ""
          color: window.ui ? window.ui.foreground : "white"
          font.family: window.ui ? window.ui.fontFamily : Style.font.family
          font.pixelSize: Style.font.title
        }
      }

      Line { label: "When"; value: window.whenText }
      Line { label: "Where"; value: window.entry ? (window.entry.location || "") : "" }
      Line { label: "Organiser"; value: window.entry ? (window.entry.organiser || "") : "" }
      Line { label: "Calendar"; value: window.entry ? (window.entry.calendarName || "") : "" }
      Line {
        label: "Repeats"
        value: window.entry && window.entry.recurring ? "One of a series" : ""
      }

      Rectangle {
        width: parent.width
        height: window.ui ? window.ui.hairline : 1
        color: window.ui ? window.ui.border : "#444"
        visible: descriptionText.visible
      }

      Text {
        id: descriptionText
        width: parent.width
        visible: !!(window.entry && String(window.entry.description || "").trim() !== "")
        textFormat: Text.StyledText
        wrapMode: Text.Wrap
        text: window.linkified(window.entry ? window.entry.description : "")
        color: window.ui ? window.ui.dim : "#aaa"
        linkColor: window.ui ? window.ui.accent : "#89b4fa"
        font.family: window.ui ? window.ui.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
        onLinkActivated: function (link) { Qt.openUrlExternally(link) }

        HoverHandler {
          cursorShape: descriptionText.hoveredLink !== ""
            ? Qt.PointingHandCursor : Qt.ArrowCursor
        }
      }
    }
  }

  // ------------------------------------------------------------------ footer
  Item {
    id: footer
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    height: Style.space(52)

    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      height: window.ui ? window.ui.hairline : 1
      color: window.ui ? window.ui.border : "#444"
    }

    Row {
      anchors.right: parent.right
      anchors.rightMargin: Style.space(16)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)

      FooterButton {
        label: "Show in calendar"
        onTriggered: window.calendarRequested(window.entry)
      }
      FooterButton {
        label: "Close"
        onTriggered: window.visible = false
      }
    }
  }

  // A labelled line that takes no room when there is nothing to put on it.
  component Line: Column {
    property string label: ""
    property string value: ""
    width: parent.width
    visible: value !== ""
    height: visible ? implicitHeight : 0
    spacing: Style.space(2)

    Text {
      text: parent.label
      color: window.ui ? window.ui.faint : "#777"
      font.family: window.ui ? window.ui.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
    }

    Text {
      width: parent.width
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: parent.value
      color: window.ui ? window.ui.foreground : "white"
      font.family: window.ui ? window.ui.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
    }
  }

  component FooterButton: Rectangle {
    id: button
    property string label: ""
    signal triggered()

    width: buttonText.implicitWidth + Style.space(24)
    height: Style.space(30)
    radius: window.ui ? window.ui.radius : 6
    color: buttonHover.containsMouse
      ? (window.ui ? window.ui.hover : "#333") : "transparent"
    border.width: 1
    border.color: window.ui ? window.ui.border : "#444"

    Text {
      id: buttonText
      anchors.centerIn: parent
      text: button.label
      color: window.ui ? window.ui.foreground : "white"
      font.family: window.ui ? window.ui.fontFamily : Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    MouseArea {
      id: buttonHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: button.triggered()
    }
  }
}
