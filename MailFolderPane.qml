import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Folder pane: the New mail button, then one collapsible section per account
// with that account's folders nested under it — the way Outlook stacks several
// mailboxes in a single tree rather than showing one account at a time.
Item {
  id: root

  property var ui: null
  property var service: null
  property bool active: false

  // Account id -> expanded. An account the user has not touched follows the
  // current account, so a fresh window opens with the mailbox you are reading.
  property var expandedAccounts: ({})

  signal composeRequested()
  signal folderChosen(string accountId, string folderName)

  readonly property var accounts: service ? service.accounts : []

  function isExpanded(accountId) {
    var state = expandedAccounts[accountId]
    if (state === undefined) return service && service.accountId === accountId
    return state === true
  }

  function toggleAccount(accountId) {
    var next = ({})
    for (var key in expandedAccounts) next[key] = expandedAccounts[key]
    next[accountId] = !isExpanded(accountId)
    expandedAccounts = next
  }

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

    // --------------------------------------------------------- account tree
    Flickable {
      width: parent.width
      height: Math.max(0, parent.height - y)
      contentWidth: width
      contentHeight: treeColumn.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      interactive: contentHeight > height
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: treeColumn
        width: parent.width
        spacing: Style.space(4)

        Repeater {
          model: root.accounts
          AccountSection {
            required property var modelData
            width: treeColumn.width
            account: modelData
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: root.accounts.length === 0
          width: parent.width
          text: "No account yet — add one to see your folders here."
          color: ui.faint
          font.family: ui.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  // One account: a header that expands, with its folders underneath.
  component AccountSection: Column {
    id: section
    property var account: null
    readonly property string accountId: account ? String(account.id) : ""
    readonly property bool expanded: root.isExpanded(accountId)
    readonly property var folders: Model.sortFolders(
      root.service ? root.service.foldersFor(accountId) : [])
    readonly property bool current: root.service && root.service.accountId === accountId

    spacing: Style.space(1)

    Rectangle {
      id: accountHeader
      width: section.width
      height: Style.space(38)
      radius: ui.radius
      color: accountHover.containsMouse ? ui.hover : "transparent"

      Row {
        anchors.left: parent.left
        anchors.leftMargin: Style.space(4)
        anchors.right: parent.right
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(6)

        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(14)
          horizontalAlignment: Text.AlignHCenter
          text: section.expanded ? "󰅀" : "󰅂"
          color: ui.dim
          font.family: ui.fontFamily
          font.pixelSize: Style.font.caption
        }

        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(22)
          height: width
          radius: width / 2
          color: Qt.hsla(Model.avatarHue(section.account ? section.account.email : "") / 360,
                         0.45, 0.45, 1.0)

          Text {
            anchors.centerIn: parent
            text: Model.initials(section.account ? section.account.name : "",
                                 section.account ? section.account.email : "")
            color: "white"
            font.family: ui.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }

        Column {
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - Style.space(50)
            - (accountBadge.visible ? accountBadge.implicitWidth + Style.space(6) : 0)
          spacing: 0

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: section.account
              ? String(section.account.name || section.account.email) : ""
            color: ui.foreground
            font.family: ui.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: section.current
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: {
              if (!section.account) return ""
              if (section.account.authorized === false) return "Needs sign-in"
              return String(section.account.email)
            }
            color: section.account && section.account.authorized === false
              ? ui.urgent : ui.faint
            font.family: ui.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        Text {
          id: accountBadge
          anchors.verticalCenter: parent.verticalCenter
          visible: !section.expanded && section.account && section.account.unread > 0
          text: section.account ? Model.badgeText(section.account.unread) : ""
          color: ui.accent
          font.family: ui.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }

      MouseArea {
        id: accountHover
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggleAccount(section.accountId)
      }
    }

    // Folder rows, indented under their account.
    Column {
      width: section.width
      spacing: Style.space(1)
      visible: section.expanded
      height: visible ? implicitHeight : 0

      Repeater {
        model: section.folders
        FolderRow {
          required property var modelData
          width: section.width
          folder: modelData
          accountId: section.accountId
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: section.folders.length === 0
        width: parent.width
        leftPadding: Style.space(30)
        text: "No folders cached yet."
        color: ui.faint
        font.family: ui.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  component FolderRow: Rectangle {
    id: folderRow
    property var folder: null
    property string accountId: ""
    readonly property bool current: root.service
      && root.service.accountId === accountId
      && root.service.folder === (folder ? folder.name : "")

    height: Style.space(26)
    radius: ui.radius
    color: folderRow.current ? ui.selected
      : (folderHover.containsMouse ? ui.hover : "transparent")

    Row {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(24)
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
        width: parent.width - Style.space(30)
          - (unreadLabel.visible ? unreadLabel.implicitWidth : 0)
        text: Model.folderLabel(folderRow.folder)
        color: ui.foreground
        font.family: ui.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: !!(folderRow.folder && folderRow.folder.unseen > 0)
        elide: Text.ElideRight
      }

      Text {
        id: unreadLabel
        anchors.verticalCenter: parent.verticalCenter
        visible: !!(folderRow.folder && folderRow.folder.unseen > 0)
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
      onClicked: root.folderChosen(folderRow.accountId,
                                   folderRow.folder ? folderRow.folder.name : "")
    }
  }
}
