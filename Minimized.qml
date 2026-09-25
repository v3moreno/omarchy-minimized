import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui
import "engine/minimize.js" as Minimize

// Display-only: the list is the live Hyprland toplevels model and every action
// is an IPC call into the plugin's service, which owns all state.
BarWidget {
  id: root
  moduleName: "omarchy-modes.minimized"

  readonly property var allToplevels: Hyprland.toplevels ? Hyprland.toplevels.values : []
  // Do not replace this with workspace existence, `hidden`, or a polling timer —
  // the model is already maintained from Hyprland IPC events.
  readonly property var minimizedToplevels: allToplevels.filter(function(toplevel) {
    return toplevel && toplevel.workspace
      && toplevel.workspace.name === Minimize.MINIMIZED_WORKSPACE
  })
  readonly property int minimizedCount: minimizedToplevels.length
  readonly property string activeWindowAddress: toplevelAddress(Hyprland.activeToplevel)
  readonly property string omarchyPath: Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy"
  readonly property string shellPath: omarchyPath + "/shell"

  property bool menuOpen: false
  property int menuCursor: 0

  function ipcCall(fn, arg) {
    var command = ["qs", "ipc", "-n", "-p", shellPath, "call",
      "omarchy-modes.minimized", fn]
    if (typeof arg === "string" && arg !== "") command.push(arg)
    Quickshell.execDetached(command)
  }

  // Quickshell reports toplevel.address as bare hex without the 0x prefix;
  // the IPC handlers expect hyprctl's "0x..." form.
  function toplevelAddress(toplevel) {
    if (!toplevel) return ""
    var ipc = toplevel.lastIpcObject
    if (ipc && typeof ipc.address === "string" && Minimize.WINDOW_ADDRESS.test(ipc.address))
      return ipc.address
    var raw = String(toplevel.address || "")
    if (raw === "") return ""
    if (raw.indexOf("0x") !== 0) raw = "0x" + raw
    return Minimize.WINDOW_ADDRESS.test(raw) ? raw : ""
  }

  function toplevelClass(toplevel) {
    if (!toplevel || !toplevel.lastIpcObject) return ""
    return typeof toplevel.lastIpcObject["class"] === "string"
      ? toplevel.lastIpcObject["class"] : ""
  }

  function windowLabel(toplevel) {
    var title = toplevel && typeof toplevel.title === "string" ? toplevel.title : ""
    if (title !== "") return title
    var windowClass = toplevelClass(toplevel)
    return windowClass !== "" ? windowClass : "Unnamed window"
  }

  function open() {
    // Item 0 is the MINIMIZE header; the action row follows it.
    menuCursor = 1
    menuOpen = true
  }

  function close() {
    menuOpen = false
  }

  function toggle() {
    if (menuOpen) close()
    else open()
  }

  // ---- menu model ----
  // Same flat layout as omarchy-modes.switcher: one gutter, caps section
  // headers, glyphs in a leading slot, values flush right.
  readonly property string menuFont: bar && bar.fontFamily ? bar.fontFamily : Style.font.family
  readonly property color menuInk: Color.popups.text
  readonly property color menuValue: Util.alpha(Color.popups.text, 0.72)
  readonly property color menuLabel: Util.alpha(Color.popups.text, 0.48)
  readonly property color menuSurface: Util.alpha(Color.popups.text, 0.07)
  readonly property int menuGutter: Style.space(18)
  readonly property int menuEdge: Style.space(8)
  readonly property int menuSlot: Style.space(18)
  readonly property int menuRowH: Style.space(24)
  readonly property int menuHeadH: Style.space(14)
  readonly property int menuGroupGap: Style.space(16)
  readonly property int menuTopPad: Style.space(10)

  function menuItems() {
    var items = [{ kind: "sec", label: "MINIMIZE" }]
    items.push({
      kind: "action", id: "minimize-active", label: "active window",
      glyph: "󰖰", enabled: activeWindowAddress !== ""
    })
    items.push({ kind: "sec", label: "MINIMIZED" })
    if (minimizedCount === 0) {
      items.push({ kind: "empty", label: "nothing minimized" })
    } else {
      for (var i = 0; i < minimizedToplevels.length; i++) {
        var t = minimizedToplevels[i]
        items.push({
          kind: "window", id: toplevelAddress(t), label: windowLabel(t),
          value: toplevelClass(t)
        })
      }
    }
    return items
  }

  readonly property var menuModel: menuItems()
  onMenuModelChanged: menuCursor = Math.max(0, Math.min(menuModel.length - 1, menuCursor))

  function moveMenuCursor(dy) {
    var items = menuModel, i = menuCursor
    for (;;) {
      var next = i + dy
      if (next < 0 || next >= items.length) break
      i = next
      if (items[i].kind === "action" || items[i].kind === "window") break
    }
    menuCursor = i
  }

  function activateMenuItem() {
    var item = menuModel[menuCursor]
    if (!item) return
    if (item.kind === "action" && item.enabled) {
      ipcCall("minimizeActive")
      close()
    } else if (item.kind === "window") {
      ipcCall("restore", item.id)
      close()
    }
  }

  implicitWidth: triggerRow.implicitWidth
  implicitHeight: triggerRow.implicitHeight

  // The service owns the omarchy-modes.minimized target; the widget gets its
  // own so a keybind or script can open the restore list directly.
  IpcHandler {
    target: "omarchy-modes.minimized.widget"

    function menu(): string { root.toggle(); return "toggled" }
  }

  Row {
    id: triggerRow
    anchors.fill: parent
    spacing: Style.space(1)

    BarIconButton {
      id: minimizedButton
      bar: root.bar
      text: "󰖰"
      tooltipText: root.minimizedCount + " minimized window"
        + (root.minimizedCount === 1 ? "" : "s")
      active: root.menuOpen
      onPressed: root.toggle()
    }

    WidgetButton {
      id: minimizedLabelButton
      bar: root.bar
      text: root.minimizedCount + " minimized 󰅂"
      tooltipText: minimizedButton.tooltipText
      horizontalMargin: Style.spaceReal(3)
      active: root.menuOpen
      onPressed: root.toggle()
    }
  }

  KeyboardPanel {
    id: minimizedMenu
    anchorItem: minimizedButton
    owner: root
    bar: root.bar
    open: root.menuOpen
    focusTarget: menuKeys
    contentWidth: minimizedMenu.fittedContentWidth(Style.space(280))
    contentHeight: minimizedMenu.fittedContentHeight(menuRows.implicitHeight)

    PanelKeyCatcher {
      id: menuKeys
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveMenuCursor(dy) }
      onActivateRequested: root.activateMenuItem()
      onCloseRequested: root.close()

      Column {
        id: menuRows
        width: parent.width
        spacing: 0
        topPadding: Style.space(4)
        bottomPadding: root.menuTopPad

        Repeater {
          model: root.menuModel

          Item {
            required property var modelData
            required property int index
            readonly property var item: modelData
            readonly property bool isRow: item.kind !== "sec"
            readonly property bool cursor: isRow && root.menuCursor === index
            readonly property bool actionable: item.kind === "window"
              || (item.kind === "action" && item.enabled)
            width: menuRows.width
            height: isRow ? root.menuRowH
              : (index === 0 ? 0 : root.menuGroupGap) + root.menuHeadH
            opacity: isRow && !actionable ? 0.55 : 1

            Text {
              visible: !parent.isRow
              x: root.menuGutter
              anchors.bottom: parent.bottom
              text: parent.item.label
              color: root.menuLabel
              font.family: root.menuFont
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Rectangle {
              visible: parent.isRow
              x: root.menuEdge
              width: parent.width - 2 * root.menuEdge
              height: root.menuRowH
              radius: 2
              color: parent.cursor ? root.menuSurface : "transparent"
            }

            Text {
              visible: parent.isRow && !!parent.item.glyph
              x: root.menuGutter
              anchors.verticalCenter: parent.verticalCenter
              text: parent.item.glyph || ""
              color: root.menuValue
              font.family: root.menuFont
              font.pixelSize: Style.font.body
            }

            Text {
              id: valueLabel
              visible: parent.isRow && !!parent.item.value
              anchors.right: parent.right
              anchors.rightMargin: root.menuGutter
              anchors.verticalCenter: parent.verticalCenter
              width: Math.min(implicitWidth, parent.width * 0.45)
              text: parent.item.value || ""
              color: root.menuValue
              font.family: root.menuFont
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            Text {
              visible: parent.isRow
              x: root.menuGutter + (parent.item.glyph ? root.menuSlot : 0)
              width: (valueLabel.visible ? valueLabel.x - Style.space(8)
                : parent.width - root.menuGutter) - x
              anchors.verticalCenter: parent.verticalCenter
              text: parent.item.label
              color: parent.item.kind === "empty" ? root.menuLabel : root.menuInk
              font.family: root.menuFont
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            MouseArea {
              visible: parent.actionable
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: root.menuCursor = parent.index
              onClicked: root.activateMenuItem()
            }
          }
        }
      }
    }
  }
}
