import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Message list: filter tabs on top, then date-grouped rows. Row anatomy
// follows Outlook's — unread bar, sender, time, subject, preview, and the
// flag/attachment markers on the trailing edge.
Item {
  id: root

  property var ui: null
  property var service: null
  property var rows: []
  property int selectedRow: -1
  property bool active: false
  // Off when the reading pane is below rather than beside the list, where a
  // line down the right-hand side would be drawing a border to nowhere.
  property bool edge: true

  signal rowChosen(int index)
  signal rowToggled(int index)
  signal rowRanged(int index)
  signal selectionCleared()
  signal bulkRequested(string action)
  signal filterChosen(string mode)

  // Keys of the rows currently ticked, as "account|folder|uid". Keys rather
  // than indices because the list reorders under a sync.
  property var selectedKeys: []

  readonly property string filter: service ? service.filter : "all"

  function positionAt(index) {
    if (index < 0 || index >= listView.count) return
    // Stop any throw still in flight first: it would carry on afterwards and
    // drag the list back off the row the keyboard just selected.
    listScroll.cancel()
    listView.positionViewAtIndex(index, ListView.Contain)
  }

  onSelectedRowChanged: positionAt(selectedRow)

  Rectangle {
    anchors.fill: parent
    color: ui.background
  }

  Rectangle {
    visible: root.edge
    anchors.right: parent.right
    width: 1
    height: parent.height
    color: ui.border
  }

  Column {
    anchors.fill: parent
    spacing: 0

    // -------------------------------------------------------- filter tabs
    //
    // The same strip does two jobs. With nothing ticked it filters; with a
    // selection it acts on it, because that is where the eye already is and
    // it costs no height.
    Item {
      id: tabs
      width: parent.width
      height: Style.space(38)

      readonly property bool picking: root.selectedKeys.length > 0

      Row {
        anchors.left: parent.left
        anchors.leftMargin: Style.space(12)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(4)
        visible: !tabs.picking

        FilterTab { label: "All"; mode: "all" }
        FilterTab { label: "Unread"; mode: "unread" }
        FilterTab { label: "Flagged"; mode: "flagged" }
      }

      Row {
        anchors.left: parent.left
        anchors.leftMargin: Style.space(12)
        anchors.right: parent.right
        anchors.rightMargin: Style.space(12)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(6)
        visible: tabs.picking

        Text {
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          text: root.selectedKeys.length + " selected"
          color: ui.accent
          font.family: ui.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        BulkButton { glyph: "󰉒"; hint: "Move to folder"; action: "move" }
        BulkButton { glyph: "󰀼"; hint: "Archive"; action: "archive" }
        BulkButton { glyph: "󰆴"; hint: "Delete"; action: "delete" }
        BulkButton { glyph: "󰇮"; hint: "Mark read"; action: "read" }
        BulkButton { glyph: "󰛑"; hint: "Mark unread"; action: "unread" }
        BulkButton { glyph: "󰈻"; hint: "Flag"; action: "flag" }
        BulkButton { glyph: "󰅖"; hint: "Clear selection"; action: "clear" }
      }

      Text {
        textFormat: Text.PlainText
        // The folder pane and the status bar both say where you are; in a
        // narrow list this is the label that can go.
        visible: !tabs.picking && root.width >= Style.space(300)
        anchors.right: parent.right
        anchors.rightMargin: Style.space(12)
        anchors.verticalCenter: parent.verticalCenter
        text: root.service ? Model.folderLabel(root.service.currentFolder
                                               || { name: root.service.folder }) : ""
        color: ui.faint
        font.family: ui.fontFamily
        font.pixelSize: Style.font.caption
      }

      Rectangle {
        anchors.bottom: parent.bottom
        width: parent.width
        height: 1
        color: ui.border
      }
    }

    // -------------------------------------------------------------- rows
    Item {
      width: parent.width
      height: parent.height - tabs.height

      ListView {
        id: listView
        anchors.fill: parent
        model: root.rows
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        delegate: Item {
          id: rowItem
          required property var modelData
          required property int index

          readonly property bool header: modelData && modelData.isHeader === true
          readonly property bool current: !header && root.selectedRow === index
          readonly property bool picked: !header && modelData
            && root.selectedKeys.indexOf(modelData.account + "|" + modelData.folder
                                         + "|" + modelData.uid) >= 0

          width: listView.width
          height: header ? Style.space(28) : Style.space(76)

          // ---- group header
          Text {
            textFormat: Text.PlainText
            visible: rowItem.header
            anchors.left: parent.left
            anchors.leftMargin: Style.space(14)
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.space(4)
            text: rowItem.header ? String(rowItem.modelData.title) : ""
            color: ui.faint
            font.family: ui.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          // ---- message row
          Rectangle {
            visible: !rowItem.header
            anchors.fill: parent
            anchors.leftMargin: Style.space(6)
            anchors.rightMargin: Style.space(6)
            anchors.topMargin: Style.space(1)
            anchors.bottomMargin: Style.space(1)
            radius: ui.radius
            color: rowItem.picked ? Util.alpha(ui.accent, 0.22)
              : rowItem.current ? ui.selected
              : (rowHover.containsMouse ? ui.hover : "transparent")

            // Unread marker: a bar on the leading edge, like Outlook's.
            Rectangle {
              visible: !!(rowItem.modelData && !rowItem.modelData.seen)
              anchors.left: parent.left
              anchors.leftMargin: Style.space(4)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(3)
              height: parent.height * 0.55
              radius: width
              color: ui.accent
            }

            Column {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(3)

              // sender + time
              Item {
                width: parent.width
                height: senderText.implicitHeight

                Text {
                  id: senderText
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.right: timeText.left
                  anchors.rightMargin: Style.space(8)
                  text: Model.senderLabel(rowItem.modelData)
                  color: ui.foreground
                  font.family: ui.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: rowItem.modelData ? !rowItem.modelData.seen : false
                  elide: Text.ElideRight
                }

                Text {
                  id: timeText
                  textFormat: Text.PlainText
                  anchors.right: parent.right
                  anchors.verticalCenter: senderText.verticalCenter
                  text: rowItem.modelData
                    ? Model.shortTime(rowItem.modelData.date, new Date()) : ""
                  color: rowItem.modelData && !rowItem.modelData.seen ? ui.accent : ui.faint
                  font.family: ui.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              // subject + markers
              Item {
                width: parent.width
                height: subjectText.implicitHeight

                Text {
                  id: subjectText
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.right: markers.left
                  anchors.rightMargin: Style.space(6)
                  text: rowItem.modelData
                    ? String(rowItem.modelData.subject || "(no subject)") : ""
                  color: rowItem.modelData && !rowItem.modelData.seen
                    ? ui.foreground : ui.dim
                  font.family: ui.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }

                Row {
                  id: markers
                  anchors.right: parent.right
                  anchors.verticalCenter: subjectText.verticalCenter
                  spacing: Style.space(5)

                  Text {
                    visible: !!(rowItem.modelData && rowItem.modelData.attachments > 0)
                    text: "󰏢"
                    color: ui.faint
                    font.family: ui.fontFamily
                    font.pixelSize: Style.font.iconSmall
                  }
                  Text {
                    visible: !!(rowItem.modelData && rowItem.modelData.answered)
                    text: "󰑚"
                    color: ui.faint
                    font.family: ui.fontFamily
                    font.pixelSize: Style.font.iconSmall
                  }
                  Text {
                    visible: !!(rowItem.modelData && rowItem.modelData.flagged)
                    text: "󰈻"
                    color: ui.urgent
                    font.family: ui.fontFamily
                    font.pixelSize: Style.font.iconSmall
                  }
                }
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: rowItem.modelData ? String(rowItem.modelData.preview || "") : ""
                color: ui.faint
                font.family: ui.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                maximumLineCount: 1
              }
            }

            MouseArea {
              id: rowHover
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              acceptedButtons: Qt.LeftButton | Qt.RightButton
              onClicked: function (mouse) {
                if (mouse.button === Qt.RightButton) {
                  if (root.service) root.service.toggleRead(rowItem.modelData)
                } else if (mouse.modifiers & Qt.ControlModifier) {
                  root.rowToggled(rowItem.index)
                } else if (mouse.modifiers & Qt.ShiftModifier) {
                  root.rowRanged(rowItem.index)
                } else {
                  root.rowChosen(rowItem.index)
                }
              }
            }
          }
        }

        MomentumScroll { id: listScroll; view: listView }
      }

      // ---- empty states
      Column {
        anchors.centerIn: parent
        width: parent.width - Style.space(48)
        spacing: Style.space(8)
        visible: root.rows.length === 0

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          text: root.service && root.service.loading ? "󰔟" : "󰇮"
          color: ui.faint
          font.family: ui.fontFamily
          font.pixelSize: Style.space(34)
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: {
            if (!root.service) return ""
            if (root.service.loading) return "Loading…"
            if (!root.service.configured) return "No account yet"
            if (root.service.query !== "") return "Nothing matches that search"
            if (root.service.filter === "unread") return "No unread mail"
            if (root.service.filter === "flagged") return "Nothing flagged"
            return "This folder is empty"
          }
          color: ui.dim
          font.family: ui.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  component BulkButton: Rectangle {
    id: bulk
    property string glyph: ""
    property string hint: ""
    property string action: ""

    width: Style.space(28)
    height: Style.space(26)
    radius: ui.radius
    color: bulkHover.containsMouse ? ui.hover : "transparent"

    Text {
      anchors.centerIn: parent
      text: bulk.glyph
      color: bulkHover.containsMouse ? ui.foreground : ui.dim
      font.family: ui.fontFamily
      font.pixelSize: Style.font.iconSmall
    }

    MouseArea {
      id: bulkHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        if (bulk.action === "clear") root.selectionCleared()
        else root.bulkRequested(bulk.action)
      }
    }

    PanelToolTip {
      visible: bulkHover.containsMouse
      text: bulk.hint
      fontFamily: ui.fontFamily
    }
  }

  component FilterTab: Rectangle {
    id: tab
    property string label: ""
    property string mode: "all"
    readonly property bool current: root.filter === tab.mode

    width: tabLabel.implicitWidth + Style.space(18)
    height: Style.space(24)
    radius: ui.radius
    color: tab.current ? ui.selected : (tabHover.containsMouse ? ui.hover : "transparent")

    Text {
      id: tabLabel
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: tab.label
      color: tab.current ? ui.accent : ui.dim
      font.family: ui.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: tab.current
    }

    MouseArea {
      id: tabHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.filterChosen(tab.mode)
    }
  }
}
