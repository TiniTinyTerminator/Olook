import QtQuick
import qs.Commons

// The menu strip under the command bar — File / View / Message / Help.
//
// Outlook puts the things you configure once behind menus rather than on the
// surface, which is what keeps its toolbar usable when the window is small.
// Same idea here: the panes only carry what you use while reading mail, and
// everything you set once lives in here.
//
// `menus` is data, not markup, so MailWindow decides what the client can do
// and this file only decides how a menu looks:
//
//   [{ title: "View", items: [
//       { kind: "header", label: "Folder pane" },
//       { id: "folders-auto", label: "Automatic", kind: "radio", checked: true },
//       { kind: "separator" },
//       { id: "refresh", label: "Check for mail", glyph: "󰑐", shortcut: "g" }
//   ]}]
//
// The popup is drawn by this item but reaches well past its own height, so
// whoever embeds it has to give it a z above the panes it covers.
Item {
  id: root

  property var ui: null
  property var menus: []

  // Which menu is open, or -1. Public so the window can suspend its own key
  // handling while a menu owns the keyboard.
  property int openIndex: -1
  property real openX: 0
  // Row the keyboard is on, or -1 when only the mouse has been used.
  property int highlightIndex: -1
  readonly property bool menuOpen: openIndex >= 0

  signal triggered(string id)

  implicitHeight: Style.space(28)

  function close() {
    root.openIndex = -1
    root.highlightIndex = -1
  }

  function activate(item) {
    if (!item) return
    if (!root.selectable(item)) return
    root.close()
    root.triggered(String(item.id || ""))
  }

  function selectable(item) {
    if (!item) return false
    var kind = String(item.kind || "item")
    return kind !== "separator" && kind !== "header" && item.enabled !== false
  }

  function currentItems() {
    var menu = root.menus[root.openIndex]
    return menu && menu.items ? menu.items : []
  }

  // Where a title sits, measured rather than read back off the delegates: a
  // Repeater's children are not in a usable order.
  function titleX(index) {
    var x = titleRow.x
    for (var i = 0; i < index && i < root.menus.length; i++) {
      titleProbe.text = String(root.menus[i].title || "")
      x += titleProbe.implicitWidth + Style.space(20)
    }
    return x
  }

  function openMenu(index) {
    if (index < 0 || index >= root.menus.length) return
    root.openX = root.titleX(index)
    root.openIndex = index
    root.highlightIndex = -1
  }

  function stepMenu(delta) {
    if (root.menus.length === 0) return
    var next = (root.openIndex + delta + root.menus.length) % root.menus.length
    root.openMenu(next)
  }

  function stepRow(delta) {
    var items = root.currentItems()
    if (items.length === 0) return
    var next = root.highlightIndex
    for (var guard = 0; guard < items.length; guard++) {
      next += delta
      if (next < 0) next = items.length - 1
      else if (next >= items.length) next = 0
      if (root.selectable(items[next])) {
        root.highlightIndex = next
        return
      }
    }
  }

  function activateHighlighted() {
    var items = root.currentItems()
    if (root.highlightIndex >= 0 && root.highlightIndex < items.length)
      root.activate(items[root.highlightIndex])
  }

  Text {
    id: titleProbe
    textFormat: Text.PlainText
    visible: false
    font.family: ui.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  Rectangle {
    anchors.fill: parent
    color: Qt.darker(ui.background, 1.04)

    Rectangle {
      anchors.bottom: parent.bottom
      width: parent.width
      height: ui.hairline
      color: ui.border
    }
  }

  Row {
    id: titleRow
    anchors.left: parent.left
    anchors.leftMargin: Style.space(10)
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    spacing: 0

    Repeater {
      model: root.menus
      MenuTitle {
        required property var modelData
        required property int index
        menu: modelData
        menuIndex: index
      }
    }
  }

  // Click anywhere else to dismiss. It sits under the popup in paint order,
  // and exists only while a menu is open, so it never eats a stray click.
  MouseArea {
    visible: root.menuOpen
    x: -Style.space(4000)
    y: root.height
    width: Style.space(8000)
    height: Style.space(4000)
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onPressed: root.close()
  }

  // ------------------------------------------------------------- the popup

  Loader {
    id: popup
    active: root.menuOpen
    x: root.openX
    y: root.height
    sourceComponent: menuPanel
  }

  Component {
    id: menuPanel

    Rectangle {
      id: panel

      readonly property var items: {
        var menu = root.menus[root.openIndex]
        return menu && menu.items ? menu.items : []
      }

      // Rows are laid out at the panel's width so their shortcuts line up on
      // the right, which means the panel cannot take its width from them —
      // that is a loop. Measure the labels instead, with a Text kept off
      // screen for the purpose.
      function measure() {
        var widest = Style.space(150)
        for (var i = 0; i < panel.items.length; i++) {
          var item = panel.items[i]
          if (!item) continue
          var kind = String(item.kind || "item")
          if (kind === "separator") continue
          probe.font.pixelSize = kind === "header" ? Style.font.caption
                                                   : Style.font.bodySmall
          probe.text = String(item.label || "")
          shortcutProbe.text = String(item.shortcut || "")
          var needed = Style.space(34) + probe.implicitWidth
            + Style.space(28) + shortcutProbe.implicitWidth
          if (needed > widest) widest = needed
        }
        return widest
      }

      width: panel.measure()
      height: menuColumn.implicitHeight + Style.space(10)
      radius: ui.radius
      color: Qt.lighter(ui.background, 1.2)
      border.width: 1
      border.color: ui.border

      Text { id: probe; textFormat: Text.PlainText; visible: false; font.family: ui.fontFamily }
      Text {
        id: shortcutProbe
        textFormat: Text.PlainText
        visible: false
        font.family: ui.fontFamily
        font.pixelSize: Style.font.caption
      }

      Column {
        id: menuColumn
        width: panel.width
        y: Style.space(5)
        spacing: 0

        Repeater {
          model: panel.items
          MenuRow {
            required property var modelData
            required property int index
            width: menuColumn.width
            item: modelData
            rowIndex: index
          }
        }
      }
    }
  }

  // ------------------------------------------------------------ components

  component MenuTitle: Rectangle {
    id: menuTitle
    property var menu: null
    property int menuIndex: 0
    readonly property bool current: root.openIndex === menuTitle.menuIndex


    width: menuTitleText.implicitWidth + Style.space(20)
    height: parent ? parent.height : Style.space(28)
    color: menuTitle.current ? ui.selected
      : (menuTitleHover.containsMouse ? ui.hover : "transparent")
    radius: ui.radius

    Text {
      id: menuTitleText
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: menuTitle.menu ? String(menuTitle.menu.title || "") : ""
      color: menuTitle.current ? ui.accent : ui.foreground
      font.family: ui.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    MouseArea {
      id: menuTitleHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        if (menuTitle.current) root.close()
        else root.openMenu(menuTitle.menuIndex)
      }
      // Sliding along the strip with a menu open switches menus, the way
      // every other menu bar behaves.
      onEntered: if (root.menuOpen && !menuTitle.current) root.openMenu(menuTitle.menuIndex)
    }
  }

  component MenuRow: Item {
    id: menuRow
    property var item: null
    property int rowIndex: -1
    readonly property bool highlighted: root.highlightIndex === menuRow.rowIndex
    readonly property string kind: item ? String(item.kind || "item") : "item"
    readonly property bool disabled: !!(item && item.enabled === false)
    readonly property bool ticked: !!(item && item.checked === true)

    height: {
      if (menuRow.kind === "separator") return Style.space(7)
      if (menuRow.kind === "header") return Style.space(22)
      return Style.space(26)
    }

    // ---- separator
    Rectangle {
      visible: menuRow.kind === "separator"
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      height: ui.hairline
      color: ui.border
    }

    // ---- section header
    Text {
      textFormat: Text.PlainText
      visible: menuRow.kind === "header"
      anchors.left: parent.left
      anchors.leftMargin: Style.space(12)
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(3)
      text: menuRow.item ? String(menuRow.item.label || "") : ""
      color: ui.faint
      font.family: ui.fontFamily
      font.pixelSize: Style.font.caption
    }

    // ---- ordinary row
    Rectangle {
      visible: menuRow.kind !== "separator" && menuRow.kind !== "header"
      anchors.fill: parent
      anchors.leftMargin: Style.space(4)
      anchors.rightMargin: Style.space(4)
      radius: ui.radius
      color: (rowHover.containsMouse || menuRow.highlighted) && !menuRow.disabled
        ? ui.hover : "transparent"

      Text {
        id: rowGlyph
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.leftMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(18)
        horizontalAlignment: Text.AlignHCenter
        // Radio and check items keep the glyph column for their tick, so the
        // labels in one menu line up whether or not anything is ticked.
        text: {
          if (!menuRow.item) return ""
          if (menuRow.kind === "radio" || menuRow.kind === "check")
            return menuRow.ticked ? "󰄬" : ""
          return String(menuRow.item.glyph || "")
        }
        color: menuRow.ticked ? ui.accent : ui.dim
        font.family: ui.fontFamily
        font.pixelSize: Style.font.iconSmall
      }

      Text {
        textFormat: Text.PlainText
        anchors.left: rowGlyph.right
        anchors.leftMargin: Style.space(8)
        anchors.right: rowShortcut.left
        anchors.rightMargin: Style.space(12)
        anchors.verticalCenter: parent.verticalCenter
        text: menuRow.item ? String(menuRow.item.label || "") : ""
        color: menuRow.disabled ? ui.faint : ui.foreground
        font.family: ui.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }

      Text {
        id: rowShortcut
        textFormat: Text.PlainText
        anchors.right: parent.right
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        text: menuRow.item ? String(menuRow.item.shortcut || "") : ""
        color: ui.faint
        font.family: ui.fontFamily
        font.pixelSize: Style.font.caption
      }

      MouseArea {
        id: rowHover
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: menuRow.disabled ? Qt.ArrowCursor : Qt.PointingHandCursor
        onClicked: root.activate(menuRow.item)
        // Keep the keyboard cursor and the pointer on the same row so the two
        // never highlight different things.
        onEntered: if (!menuRow.disabled) root.highlightIndex = menuRow.rowIndex
      }
    }
  }
}
