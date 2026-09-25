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
    menuCursor = 0
    menuOpen = true
  }

  function close() {
    menuOpen = false
  }

  function toggle() {
    if (menuOpen) close()
    else open()
  }

  function activateMenuCursor() {
    if (menuCursor === 0) {
      ipcCall("minimizeActive")
      close()
    } else if (menuCursor <= minimizedToplevels.length) {
      ipcCall("restore", toplevelAddress(minimizedToplevels[menuCursor - 1]))
      close()
    }
  }

  implicitWidth: triggerRow.implicitWidth
  implicitHeight: triggerRow.implicitHeight

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
      onMoveRequested: function(dx, dy) {
        if (dy === 0) return
        root.menuCursor = Math.max(0,
          Math.min(root.minimizedToplevels.length, root.menuCursor + dy))
      }
      onActivateRequested: root.activateMenuCursor()
      onCloseRequested: root.close()

      Column {
        id: menuRows
        width: parent.width
        spacing: Style.spacing.labelGap

        Rectangle {
          id: minimizeActiveRow
          width: menuRows.width
          height: Style.spacing.popupRowHeight
          radius: Math.max(1, Style.cornerRadius - Style.spacing.hairline)
          color: root.menuCursor === 0
            ? Style.hoverFillFor(Color.popups.text, Color.accent) : "transparent"
          opacity: root.activeWindowAddress !== "" ? 1 : 0.55

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.controlPaddingX
            anchors.verticalCenter: parent.verticalCenter
            text: "󰖰"
            color: Color.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(32)
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.controlPaddingX
            anchors.verticalCenter: parent.verticalCenter
            text: "Minimize active window"
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          MouseArea {
            anchors.fill: parent
            enabled: root.activeWindowAddress !== ""
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onEntered: root.menuCursor = 0
            onClicked: {
              root.ipcCall("minimizeActive")
              root.close()
            }
          }
        }

        Text {
          width: menuRows.width
          visible: root.minimizedCount === 0
          text: "Nothing minimized"
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
          height: visible ? Style.spacing.popupRowHeight : 0
        }

        Repeater {
          model: root.minimizedToplevels

          Rectangle {
            required property var modelData
            required property int index
            width: menuRows.width
            height: Style.spacing.popupRowHeight
            radius: Math.max(1, Style.cornerRadius - Style.spacing.hairline)
            color: root.menuCursor === index + 1
              ? Style.hoverFillFor(Color.popups.text, Color.accent) : "transparent"

            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.spacing.controlPaddingX
              anchors.right: parent.right
              anchors.rightMargin: Style.spacing.controlPaddingX
              anchors.verticalCenter: parent.verticalCenter
              text: root.windowLabel(parent.modelData)
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: root.menuCursor = parent.index + 1
              onClicked: {
                root.ipcCall("restore", root.toplevelAddress(parent.modelData))
                root.close()
              }
            }
          }
        }
      }
    }
  }
}
