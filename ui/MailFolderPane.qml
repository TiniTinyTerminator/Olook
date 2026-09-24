import QtQuick
import Qt5Compat.GraphicalEffects
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Folder pane: the New mail button, then one collapsible section per account
// with that account's folders nested under it — the way Outlook stacks several
// mailboxes in a single tree rather than showing one account at a time.
//
// `collapsed` narrows it to a strip of icons for a small window. Nothing goes
// away in that mode — every account and every folder is still a row you can
// click — the names just move into tooltips.
Item {
  id: root

  property var ui: null
  property var service: null
  property bool active: false
  property bool collapsed: false

  // Account id -> expanded. An account the user has not touched follows the
  // current account, so a fresh window opens with the mailbox you are reading.
  property var expandedAccounts: ({})

  signal composeRequested()
  signal folderChosen(string accountId, string folderName)

  readonly property var accounts: service ? service.accounts : []

  // ------------------------------------------------------------ reordering
  //
  // The order lives here while a drag is in progress and is written to the
  // engine when it ends. Reordering a local list rather than the engine's
  // means the tree follows the pointer without a round trip per row crossed.
  property var accountIds: []

  onAccountsChanged: root.takeAccountOrder()
  Component.onCompleted: root.takeAccountOrder()

  function takeAccountOrder() {
    var ids = []
    for (var i = 0; i < root.accounts.length; i++)
      ids.push(String(root.accounts[i].id))
    root.accountIds = ids
  }

  readonly property var orderedAccounts: {
    var byId = ({})
    for (var i = 0; i < root.accounts.length; i++)
      byId[String(root.accounts[i].id)] = root.accounts[i]
    var out = []
    for (var j = 0; j < root.accountIds.length; j++) {
      var entry = byId[root.accountIds[j]]
      if (entry) out.push(entry)
    }
    // An account that arrived while a drag was in flight still belongs on
    // screen, even though nobody has said where it goes.
    for (var k = 0; k < root.accounts.length; k++)
      if (root.accountIds.indexOf(String(root.accounts[k].id)) === -1)
        out.push(root.accounts[k])
    return out
  }

  function moveAccount(from, to) {
    if (from === to || from < 0 || to < 0) return
    var ids = root.accountIds.slice()
    if (from >= ids.length || to >= ids.length) return
    ids.splice(to, 0, ids.splice(from, 1)[0])
    root.accountIds = ids
  }

  function commitAccountOrder() {
    if (root.service) root.service.reorderAccounts(root.accountIds)
  }

  Item {
    id: dragProxy
    width: Style.space(8)
    height: Style.space(8)
    visible: false
    // "account" or "folder"; which list is being reordered decides what a
    // drop area is allowed to do with it.
    property string kind: ""
    property int from: -1
    property var owner: null
    Drag.active: false
    Drag.source: dragProxy
    Drag.hotSpot.x: width / 2
    Drag.hotSpot.y: height / 2
  }

  function startDrag(area, mouse, kind, from, owner) {
    var point = area.mapToItem(root, mouse.x, mouse.y)
    dragProxy.x = point.x - dragProxy.width / 2
    dragProxy.y = point.y - dragProxy.height / 2
    dragProxy.kind = kind
    dragProxy.from = from
    dragProxy.owner = owner
  }

  function endDrag(active) {
    if (active) {
      dragProxy.Drag.active = true
      return
    }
    if (!dragProxy.Drag.active) return
    dragProxy.Drag.drop()
    dragProxy.Drag.active = false
    if (dragProxy.kind === "account") root.commitAccountOrder()
    else if (dragProxy.owner) dragProxy.owner.commitFolderOrder()
    dragProxy.kind = ""
    dragProxy.from = -1
    dragProxy.owner = null
  }

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
    width: ui.hairline
    height: parent.height
    color: ui.border
  }

  Column {
    anchors.fill: parent
    anchors.margins: root.collapsed ? Style.space(6) : Style.space(12)
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
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          text: "󰝒"
          color: ui.background
          font.family: ui.fontFamily
          font.pixelSize: Style.font.icon
        }
        Text {
          textFormat: Text.PlainText
          visible: !root.collapsed
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

      PanelToolTip {
        visible: root.collapsed && composeHover.containsMouse
        text: "New mail  (c)"
        fontFamily: ui.fontFamily
      }
    }

    // --------------------------------------------------------- account tree
    Flickable {
      id: treeFlick
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

        // Every account's inbox in one list. Only worth offering when there
        // is more than one account to merge.
        FolderRow {
          width: treeColumn.width
          visible: root.accounts.length > 1
          isAll: true
          accountId: ""
          folder: ({
            name: Model.ALL_FOLDER,
            special: "allaccounts",
            unseen: root.service ? root.service.unreadEverywhere : 0
          })
        }

        Repeater {
          model: root.orderedAccounts
          AccountSection {
            required property var modelData
            required property int index
            width: treeColumn.width
            account: modelData
            position: index
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: root.accounts.length === 0 && !root.collapsed
          width: parent.width
          text: "No account yet — add one to see your folders here."
          color: ui.faint
          font.family: ui.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      MomentumScroll { view: treeFlick }
    }
  }

  // One account: a header that expands, with its folders underneath.
  component AccountSection: Column {
    id: section
    property var account: null
    property int position: 0

    // One account's folders, in the order they are being dragged into. Kept
    // beside the account rather than in the pane because a folder may only
    // move within the account it belongs to.
    property var folderNames: []

    function takeFolderOrder() {
      var names = []
      for (var i = 0; i < section.folders.length; i++)
        names.push(String(section.folders[i].name))
      section.folderNames = names
    }

    onFoldersChanged: section.takeFolderOrder()
    Component.onCompleted: section.takeFolderOrder()

    readonly property var orderedFolders: {
      var byName = ({})
      for (var i = 0; i < section.folders.length; i++)
        byName[String(section.folders[i].name)] = section.folders[i]
      var out = []
      for (var j = 0; j < section.folderNames.length; j++) {
        var entry = byName[section.folderNames[j]]
        if (entry) out.push(entry)
      }
      for (var k = 0; k < section.folders.length; k++)
        if (section.folderNames.indexOf(String(section.folders[k].name)) === -1)
          out.push(section.folders[k])
      return out
    }

    function moveFolder(from, to) {
      if (from === to || from < 0 || to < 0) return
      var names = section.folderNames.slice()
      if (from >= names.length || to >= names.length) return
      names.splice(to, 0, names.splice(from, 1)[0])
      section.folderNames = names
    }

    function commitFolderOrder() {
      if (root.service)
        root.service.reorderFolders(section.accountId, section.folderNames)
    }

    readonly property string accountId: account ? String(account.id) : ""
    readonly property bool expanded: root.isExpanded(accountId)
    readonly property var folders: Model.sortFolders(Model.mailFolders(
      root.service ? root.service.foldersFor(accountId) : []))
    readonly property bool current: root.service && root.service.accountId === accountId

    spacing: Style.space(1)

    Rectangle {
      id: accountHeader
      width: section.width
      height: Style.space(38)
      radius: ui.radius
      color: accountHover.containsMouse ? ui.hover : "transparent"

      // Positioned by x rather than anchored: collapsed it centres on the
      // avatar, expanded it fills the row, and declaring left, right and
      // horizontalCenter together is not allowed even when only one is live.
      Row {
        x: root.collapsed
          ? Math.round((parent.width - implicitWidth) / 2) : Style.space(4)
        width: root.collapsed ? implicitWidth : parent.width - Style.space(12)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(6)

        Text {
          textFormat: Text.PlainText
          visible: !root.collapsed
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
            textFormat: Text.PlainText
            anchors.centerIn: parent
            // The initials are the fallback, not the thing being replaced:
            // a picture that fails to load leaves them showing rather than a
            // blank disc.
            visible: accountPicture.status !== Image.Ready
            text: Model.initials(section.account ? section.account.name : "",
                                 section.account ? section.account.email : "")
            color: "white"
            font.family: ui.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          Image {
            id: accountPicture
            anchors.fill: parent
            source: section.account ? (section.account.avatar || "") : ""
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            visible: status === Image.Ready
            layer.enabled: visible
            layer.effect: OpacityMask {
              maskSource: Rectangle {
                width: accountPicture.width
                height: accountPicture.height
                radius: width / 2
              }
            }
          }

          // Collapsed there is no room for a count, so unread becomes a dot
          // on the avatar — enough to tell you the mailbox wants attention.
          Rectangle {
            visible: root.collapsed && !!(section.account && section.account.unread > 0)
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.rightMargin: -Style.space(1)
            anchors.topMargin: -Style.space(1)
            width: Style.space(8)
            height: width
            radius: width / 2
            color: ui.accent
            border.width: 1
            border.color: Qt.darker(ui.background, 1.08)
          }
        }

        Column {
          visible: !root.collapsed
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
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          visible: !root.collapsed && !section.expanded
            && !!(section.account && section.account.unread > 0)
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
        drag.target: root.collapsed ? null : dragProxy
        drag.threshold: Style.space(6)
        onPressed: function (mouse) {
          root.startDrag(accountHover, mouse, "account", section.position, null)
        }
        drag.onActiveChanged: root.endDrag(accountHover.drag.active)
        onClicked: root.toggleAccount(section.accountId)
      }

      DropArea {
        anchors.fill: parent
        onPositionChanged: {
          if (dragProxy.kind !== "account") return
          if (dragProxy.from === section.position) return
          root.moveAccount(dragProxy.from, section.position)
          dragProxy.from = section.position
        }
      }

      // A line under the pointer while an account is being carried, so the
      // row it will land on is not a guess.
      Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: ui.hairline * 2
        color: ui.accent
        visible: dragProxy.kind === "account" && dragProxy.from === section.position
      }

      PanelToolTip {
        visible: root.collapsed && accountHover.containsMouse
        text: {
          if (!section.account) return ""
          var name = String(section.account.name || section.account.email)
          if (section.account.authorized === false) return name + " — needs sign-in"
          if (section.account.unread > 0) return name + " — " + section.account.unread + " unread"
          return name
        }
        fontFamily: ui.fontFamily
      }
    }

    // Folder rows, indented under their account.
    Column {
      width: section.width
      spacing: Style.space(1)
      visible: section.expanded
      height: visible ? implicitHeight : 0

      Repeater {
        model: section.orderedFolders
        FolderRow {
          required property var modelData
          required property int index
          width: section.width
          folder: modelData
          accountId: section.accountId
          position: index
          owner: section
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: section.folders.length === 0 && !root.collapsed
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
    // The All row belongs to no account, so it cannot be matched on one.
    property bool isAll: false
    property int position: -1
    property var owner: null
    // The All row belongs to nothing and so cannot be moved within it.
    readonly property bool draggable: !folderRow.isAll && !!folderRow.owner
                                      && !root.collapsed
    readonly property bool current: folderRow.isAll
      ? !!(root.service && Model.isAllFolder(root.service.folder))
      : !!(root.service
           && root.service.accountId === accountId
           && root.service.folder === (folder ? folder.name : ""))

    height: Style.space(26)
    radius: ui.radius
    color: folderRow.current ? ui.selected
      : (folderHover.containsMouse ? ui.hover : "transparent")

    Row {
      x: root.collapsed
        ? Math.round((parent.width - implicitWidth) / 2) : Style.space(24)
      width: root.collapsed ? implicitWidth : parent.width - Style.space(32)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)

      Item {
        anchors.verticalCenter: parent.verticalCenter
        width: folderGlyph.implicitWidth
        height: folderGlyph.implicitHeight

        Text {
          id: folderGlyph
          textFormat: Text.PlainText
          text: Model.folderGlyph(folderRow.folder)
          color: folderRow.current ? ui.accent : ui.dim
          font.family: ui.fontFamily
          font.pixelSize: Style.font.iconSmall
        }

        Rectangle {
          visible: root.collapsed && !!(folderRow.folder && folderRow.folder.unseen > 0)
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.rightMargin: -Style.space(3)
          anchors.topMargin: -Style.space(2)
          width: Style.space(6)
          height: width
          radius: width / 2
          color: ui.accent
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: !root.collapsed
        anchors.verticalCenter: parent.verticalCenter
        width: root.collapsed ? 0 : parent.width - Style.space(30)
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
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        visible: !root.collapsed && !!(folderRow.folder && folderRow.folder.unseen > 0)
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
      drag.target: folderRow.draggable ? dragProxy : null
      drag.threshold: Style.space(6)
      onPressed: function (mouse) {
        if (!folderRow.draggable) return
        root.startDrag(folderHover, mouse, "folder", folderRow.position,
                       folderRow.owner)
      }
      drag.onActiveChanged: root.endDrag(folderHover.drag.active)
      onClicked: root.folderChosen(folderRow.accountId,
                                   folderRow.folder ? folderRow.folder.name : "")
    }

    DropArea {
      anchors.fill: parent
      onPositionChanged: {
        // A folder may only move within the account it belongs to, so a
        // drop area in another account refuses the carried row.
        if (dragProxy.kind !== "folder") return
        if (dragProxy.owner !== folderRow.owner) return
        if (dragProxy.from === folderRow.position) return
        folderRow.owner.moveFolder(dragProxy.from, folderRow.position)
        dragProxy.from = folderRow.position
      }
    }

    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: ui.hairline * 2
      color: ui.accent
      visible: dragProxy.kind === "folder"
               && dragProxy.owner === folderRow.owner
               && dragProxy.from === folderRow.position
    }

    PanelToolTip {
      visible: root.collapsed && folderHover.containsMouse
      text: {
        var label = Model.folderLabel(folderRow.folder)
        var unseen = folderRow.folder ? folderRow.folder.unseen : 0
        return unseen > 0 ? label + " — " + unseen + " unread" : label
      }
      fontFamily: ui.fontFamily
    }
  }
}
