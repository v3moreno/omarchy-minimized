import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui
import "engine/minimize.js" as Minimize
import "Model.js" as Model

// Display-only: the list is the live Hyprland toplevels model and every action
// is an IPC call into the plugin's service, which owns all state.
// Model.js turns that list into the view; this file draws it.
Panel {
  id: root
  moduleName: "omarchy-modes.minimized"
  ipcTarget: "omarchy-modes.minimized.widget"
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property var allToplevels: Hyprland.toplevels ? Hyprland.toplevels.values : []
  // Do not replace this with workspace existence, `hidden`, or a polling timer —
  // the model is already maintained from Hyprland IPC events.
  readonly property var minimizedToplevels: allToplevels.filter(function(toplevel) {
    return toplevel && toplevel.workspace
      && toplevel.workspace.name === Minimize.MINIMIZED_WORKSPACE
  })
  readonly property int minimizedCount: minimizedToplevels.length
  readonly property string omarchyPath: Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy"
  readonly property string shellPath: omarchyPath + "/shell"

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

  // The live toplevels, flattened to plain data for the view builder
  readonly property var snap: ({
    windows: minimizedToplevels.map(function(t) {
      return { id: toplevelAddress(t), title: windowLabel(t), "class": toplevelClass(t) }
    })
  })
  property var ui: ({ problem: "" })
  readonly property var view: {
    try {
      return Model.build(snap, ui)
    } catch (e) {
      return { title: "MINIMIZED", mark: "", rows: [{ type: "error", label: String(e.message || e) }] }
    }
  }

  // ---- theme ----
  readonly property color theme: bar ? bar.foreground : Color.foreground
  readonly property color bg: Color.popups.background
  readonly property color surface: Util.alpha(theme, 0.06)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string mono: bar ? bar.fontFamily : Style.font.family
  // The panel's tones, each picked by the APCA contrast it must reach on a card (Model.tones)
  readonly property var tones: Model.tones(theme, bg, surface, urgent)
  readonly property color ink: Qt.rgba(tones.ink.r, tones.ink.g, tones.ink.b, 1)
  readonly property color valueTone: Qt.rgba(tones.value.r, tones.value.g, tones.value.b, 1)
  readonly property color labelTone: Qt.rgba(tones.label.r, tones.label.g, tones.label.b, 1)
  readonly property color alertTone: Qt.rgba(tones.alert.r, tones.alert.g, tones.alert.b, 1)

  readonly property int gutter: Style.space(20)
  readonly property int edge: Style.space(8)
  readonly property int rowH: Style.space(22)
  readonly property int headH: Style.space(16)
  readonly property int groupGap: Style.space(20)
  readonly property int topGap: Style.space(12)

  // Keyboard cursor over the actionable rows; hover sets it too
  property int cursor: 0
  onViewChanged: cursor = Math.max(0, Math.min((view.rows || []).length - 1, cursor))
  function moveCursor(dy) {
    var rows = view.rows || [], i = cursor
    for (;;) {
      var next = i + dy
      if (next < 0 || next >= rows.length) break
      i = next
      if (rows[i].type === "win") break
    }
    cursor = i
  }

  // An action is "verb|arg", from Model.js
  function activate(action) {
    var a = (action || "").split("|")
    if (a[0] === "restore") { ipcCall("restore", a[1]); close() }
  }

  // The mark: the minimize glyph, lit while there is something parked, faint when the list is empty
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.minimizedCount + " minimized window" + (root.minimizedCount === 1 ? "" : "s")
    onPressed: root.toggle()
    iconComponent: Component {
      Item {
        Text {
          anchors.centerIn: parent
          text: "󰖰"
          color: root.view.mark === "ready" ? root.theme : Util.alpha(root.theme, 0.3)
          font.family: root.mono
          font.pixelSize: Style.font.body
        }
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keys
    padding: 0
    contentWidth: panel.fittedContentWidth(Style.space(280))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    Rectangle { anchors.fill: parent; color: root.bg }
    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onActivateRequested: root.activate((root.view.rows[root.cursor] || {}).action)
      onCloseRequested: root.close()

      Column {
        id: content
        objectName: "omarchy-minimized-content"
        width: parent.width
        topPadding: Style.space(16)
        bottomPadding: Style.space(16)
        spacing: 0

        // The top line: the name and the parked count
        Item {
          width: parent.width
          height: root.headH
          Label {
            id: head
            x: root.gutter
            anchors.verticalCenter: parent.verticalCenter
            text: root.view.title || ""
            color: root.labelTone
          }
          Label {
            anchors.left: head.right
            anchors.leftMargin: Style.space(8)
            anchors.baseline: head.baseline
            text: root.view.version || ""
            color: Util.alpha(root.labelTone, 0.55)
            font.pixelSize: Style.font.caption - 2
          }
        }

        Repeater {
          // keyed by position, so a refresh updates rows in place instead of rebuilding them (no flicker)
          model: (root.view.rows || []).length
          Item {
            required property int index
            readonly property var r: (root.view.rows || [])[index] || ({ type: "" })
            readonly property bool cursor: r.type === "win" && root.cursor === index
            width: content.width
            height: (r.type === "sec" || r.type === "error" ? (index === 0 ? 0 : root.groupGap) : index === 0 ? root.topGap : 0) + row.height

            Loader {
              id: row
              y: r.type === "sec" || r.type === "error" ? (index === 0 ? 0 : root.groupGap) : index === 0 ? root.topGap : 0
              width: parent.width
              sourceComponent: ({ win: winC, soon: soonC })[r.type] || textC
            }

            // A parked window: a cursor surface, its title, its class on the right
            Component {
              id: winC
              Item {
                height: root.rowH
                Rectangle {
                  x: root.edge
                  width: parent.width - 2 * root.edge
                  height: parent.height
                  radius: 2
                  color: cursor ? root.surface : "transparent"
                }
                Label {
                  x: root.gutter
                  width: parent.width - 2 * root.gutter - (winClass.visible ? winClass.width + Style.space(8) : 0)
                  anchors.verticalCenter: parent.verticalCenter
                  text: r.label
                  color: root.ink
                  elide: Text.ElideRight
                }
                Right { id: winClass; visible: !!r.value; margin: root.gutter; text: r.value || ""; color: root.labelTone }
                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: root.cursor = index
                  onClicked: root.activate(r.action)
                }
              }
            }

            // Nothing parked: a single dash sweeping its track, one line of how to park
            Component {
              id: soonC
              Column {
                topPadding: Style.space(28)
                bottomPadding: Style.space(20)
                spacing: Style.space(18)
                Item {
                  id: track
                  anchors.horizontalCenter: parent.horizontalCenter
                  width: Style.space(140)
                  height: Style.space(18)
                  Rectangle {
                    id: dash
                    width: Style.space(26)
                    height: 1.5
                    y: (track.height - height) / 2
                    color: root.labelTone
                    SequentialAnimation on x {
                      running: root.opened
                      loops: Animation.Infinite
                      NumberAnimation { from: 0; to: track.width - dash.width; duration: 1600; easing.type: Easing.InOutQuad }
                      PauseAnimation { duration: 400 }
                      NumberAnimation { from: track.width - dash.width; to: 0; duration: 1600; easing.type: Easing.InOutQuad }
                      PauseAnimation { duration: 400 }
                    }
                  }
                }
                Label {
                  x: root.gutter
                  width: parent.width - 2 * root.gutter
                  horizontalAlignment: Text.AlignHCenter
                  text: r.head
                  color: root.labelTone
                  wrapMode: Text.WordWrap
                }
              }
            }

            // A section's name, or an error in its place
            Component {
              id: textC
              Label {
                readonly property bool sec: r.type === "sec"
                leftPadding: root.gutter; rightPadding: root.gutter
                width: parent.width
                height: sec ? root.headH : implicitHeight
                verticalAlignment: Text.AlignVCenter
                text: r.label || ""
                color: sec ? root.labelTone : root.alertTone
                wrapMode: Text.WordWrap
              }
            }
          }
        }
      }
    }
  }

  // ---------------------------------------------------------------- pieces

  component Label: Text {
    textFormat: Text.PlainText
    color: root.valueTone
    font.family: root.mono
    font.pixelSize: Style.font.caption
  }

  // A label against its row's right edge
  component Right: Label {
    property int margin
    anchors.right: parent.right
    anchors.rightMargin: margin
    anchors.verticalCenter: parent.verticalCenter
  }

}
