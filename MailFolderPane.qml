import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Folder pane: the New mail button, an account switcher when there is more
// than one account, and the folder tree with unread counts.
Item {
  id: root

  property var ui: null
  property var service: null
  property bool active: false

  signal composeRequested()
  signal folderChosen(string name)
  signal accountChosen(string id)

  readonly property var folders: Model.sortFolders(service ? service.folders : [])
  readonly property var accounts: service ? service.accounts : []

  Rectangle {
    anchors.fill: parent
    color: Qt.darker(ui.background, 1.08)
  }

  Rectangle {
    anchors.right: parent.right
    width: 1
    height: parent.height
    color: ui.border
  }

  Column {
    anchors.fill: parent
    anchors.margins: Style.space(12)
    spacing: Style.space(10)

    // ------------------------------------------------------------ new mail
    Rectangle {
      id: composeButton
      width: parent.width
      height: Style.space(34)
      radius: ui.radius
      color: composeHover.containsMouse ? Qt.lighter(ui.accent, 1.1) : ui.accent

      Row {
        anchors.centerIn: parent
        spacing: Style.space(8)

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "󰝒"
          color: ui.background
          font.family: ui.fontFamily
          font.pixelSize: Style.font.icon
        }
        Text {
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          text: "New mail"
          color: ui.background
          font.family: ui.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }
      }

      MouseArea {
        id: composeHover
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.composeRequested()
      }
    }

    // ------------------------------------------------------------- account
    Column {
      width: parent.width
      spacing: Style.space(2)
      visible: root.accounts.length > 0

      Repeater {
        model: root.accounts
        AccountRow {
          required property var modelData
          width: parent.width
          account: modelData
        }
      }
    }

    Rectangle {
      width: parent.width
      height: 1
      color: ui.border
      visible: root.accounts.length > 0
    }

    // ------------------------------------------------------------- folders
    Text {
      textFormat: Text.PlainText
      text: "FOLDERS"
      color: ui.faint
      font.family: ui.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    Flickable {
      width: parent.width
      height: Math.max(0, parent.height - y)
      contentWidth: width
      contentHeight: folderColumn.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      interactive: contentHeight > height

      Column {
        id: folderColumn
        width: parent.width
        spacing: Style.space(1)

        Repeater {
          model: root.folders
          FolderRow {
            required property var modelData
            width: folderColumn.width
            folder: modelData
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: root.folders.length === 0
          width: parent.width
          text: root.service && root.service.configured
            ? "No folders yet — sync to load them."
            : "Add an account to get started."
          color: ui.faint
          font.family: ui.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  component AccountRow: Rectangle {
    id: accountRow
    property var account: null
    readonly property bool current: root.service && root.service.accountId === (account ? account.id : "")

    height: Style.space(38)
    radius: ui.radius
    color: accountRow.current ? ui.selected
      : (accountHover.containsMouse ? ui.hover : "transparent")

    Row {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)

      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(22)
        height: width
        radius: width / 2
        color: Qt.hsla(Model.avatarHue(accountRow.account ? accountRow.account.email : "") / 360,
                       0.45, 0.45, 1.0)

        Text {
          anchors.centerIn: parent
          text: Model.initials(accountRow.account ? accountRow.account.name : "",
                               accountRow.account ? accountRow.account.email : "")
          color: "white"
          font.family: ui.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }

      Column {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - Style.space(30)
        spacing: 0

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: accountRow.account ? String(accountRow.account.name || accountRow.account.email) : ""
          color: ui.foreground
          font.family: ui.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: {
            if (!accountRow.account) return ""
            if (!accountRow.account.authorized) return "Needs sign-in"
            return String(accountRow.account.email)
          }
          color: accountRow.account && !accountRow.account.authorized ? ui.urgent : ui.faint
          font.family: ui.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }

    MouseArea {
      id: accountHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.accountChosen(accountRow.account ? accountRow.account.id : "")
    }
  }

  component FolderRow: Rectangle {
    id: folderRow
    property var folder: null
    readonly property bool current: root.service && root.service.folder === (folder ? folder.name : "")

    height: Style.space(28)
    radius: ui.radius
    color: folderRow.current ? ui.selected
      : (folderHover.containsMouse ? ui.hover : "transparent")

    Row {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: Model.folderGlyph(folderRow.folder)
        color: folderRow.current ? ui.accent : ui.dim
        font.family: ui.fontFamily
        font.pixelSize: Style.font.iconSmall
      }

      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - Style.space(30) - (unreadLabel.visible ? unreadLabel.implicitWidth : 0)
        text: Model.folderLabel(folderRow.folder)
        color: ui.foreground
        font.family: ui.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: folderRow.folder ? folderRow.folder.unseen > 0 : false
        elide: Text.ElideRight
      }

      Text {
        id: unreadLabel
        anchors.verticalCenter: parent.verticalCenter
        visible: folderRow.folder ? folderRow.folder.unseen > 0 : false
        text: folderRow.folder ? Model.badgeText(folderRow.folder.unseen) : ""
        color: ui.accent
        font.family: ui.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }

    MouseArea {
      id: folderHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.folderChosen(folderRow.folder ? folderRow.folder.name : "")
    }
  }
}
