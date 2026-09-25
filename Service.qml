import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "engine/state.js" as State
import "engine/minimize.js" as Minimize

// Owns minimized-window state and every hyprctl interaction. The bar widget is
// display-only; the keybind drop-in and all IPC calls land here, so minimize
// keeps working with no widget on the bar.
Item {
  id: root

  // Injected by the service loader.
  property var shell: null
  property var manifest: null

  readonly property string stateDirectory: Quickshell.env("HOME") + "/.local/state/omarchy-modes"
  readonly property string statePath: stateDirectory + "/state.json"
  readonly property string dropinDirectory: Quickshell.env("HOME") + "/.local/state/omarchy/toggles/hypr"
  readonly property string dropinPath: dropinDirectory + "/omarchy-minimized.lua"
  readonly property int hyprctlTimeoutMs: 5000
  // Whole-operation budget, separate from the per-process watchdog: a step
  // can wedge with no process running (e.g. a save whose onSaved never lands
  // because the file's own watchChanges reload raced it), and busy would
  // then hold forever — every IPC call answering "busy". startHyprctl and
  // saveState restart it; finish() stops it.
  readonly property int operationTimeoutMs: 15000
  readonly property int doubleClickMs: 450

  // The binds are the feature, so they are emitted unconditionally — but gated
  // on our id still being in shell.json, so a drop-in that outlives
  // disable/remove comes up inert on the next reload. SUPER+ALT+SHIFT+M is
  // Omarchy's music TUI now; restore moved to SUPER+ALT+R.
  readonly property string dropinContent:
    "-- omarchy-minimized: generated, do not edit\n" +
    "pcall(function()\n" +
    "  local paths_ok, paths = pcall(require, \"default.hypr.paths\")\n" +
    "  local config_home = paths_ok and paths.config_home\n" +
    "    or (os.getenv(\"HOME\") .. \"/.config\")\n" +
    "  local f = io.open(config_home .. \"/omarchy/shell.json\", \"r\")\n" +
    "  local enabled = false\n" +
    "  if f then\n" +
    "    enabled = (f:read(\"*a\") or \"\"):find('\"id\"%s*:%s*\"omarchy%-modes%.minimized\"') ~= nil\n" +
    "    f:close()\n" +
    "  end\n" +
    "  if not enabled then return end\n" +
    "  local function ipc(fn)\n" +
    "    return hl.dsp.exec_cmd(\"qs ipc -n -p \\\"$OMARCHY_PATH/shell\\\" call omarchy-modes.minimized \" .. fn)\n" +
    "  end\n" +
    "  hl.bind(\"SUPER + ALT + M\", ipc(\"minimizeActive\"), { description = \"Minimize active window\" })\n" +
    "  hl.bind(\"SUPER + ALT + R\", ipc(\"restoreLast\"), { description = \"Restore last minimized window\" })\n" +
    "  hl.bind(\"ALT + mouse:272\", ipc(\"click\"), { mouse = true, non_consuming = true, description = \"Minimize window (Alt double-click)\" })\n" +
    "end)\n"

  // Live model maintained by Quickshell's Hyprland IPC — no polling.
  readonly property var allToplevels: Hyprland.toplevels ? Hyprland.toplevels.values : []
  readonly property var minimizedToplevels: allToplevels.filter(function(toplevel) {
    return toplevel && toplevel.workspace
      && toplevel.workspace.name === Minimize.MINIMIZED_WORKSPACE
  })
  readonly property string activeWindowAddress: toplevelAddress(Hyprland.activeToplevel)

  property var modeState: State.defaultState()
  property bool stateLoaded: false
  property string stateError: ""
  property bool sessionPruned: false
  property bool dirsReady: false
  property bool dropinKnown: false
  property string dropinExisting: ""

  // Single-flight operation state. Only one state transition may be in flight;
  // everything else reports "busy" instead of interleaving.
  property bool busy: false
  property string operation: ""
  property string operationAddress: ""
  property string operationCommand: ""
  property var reconciledState: null
  property var pendingState: null
  property var stateSaveContinuation: null
  property var hyprctlContinuation: null
  property string hyprctlDescription: ""
  property string lastMinimizedAddress: ""

  // Alt+click path: separate probe process so a click can never collide with
  // an in-flight operation on hyprctlProcess. Clicks arriving mid-probe are
  // queued — without this, the second click of a fast double-click is dropped.
  property double lastClickAt: 0
  property string lastClickAddress: ""
  property bool clickQueued: false

  function validAddress(value) {
    return typeof value === "string" && Minimize.WINDOW_ADDRESS.test(value)
  }

  function focusedWorkspaceName() {
    var ws = Hyprland.focusedWorkspace
    var name = ws ? String(ws.name || "") : ""
    return /^(?:0|[1-9][0-9]*)$/.test(name) ? name : "1"
  }

  // Quickshell's toplevel.address is bare hex (QString::number(addr, 16));
  // hyprctl and our state use the "0x"-prefixed form. Prefer the raw IPC
  // object, fall back to prefixing.
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

  function clientSnapshot() {
    return allToplevels.map(function(toplevel) {
      return {
        address: toplevelAddress(toplevel),
        workspace: { name: toplevel.workspace ? String(toplevel.workspace.name || "") : "" },
        title: String(toplevel.title || ""),
        "class": toplevelClass(toplevel)
      }
    })
  }

  function toplevelClass(toplevel) {
    if (!toplevel || !toplevel.lastIpcObject) return ""
    return typeof toplevel.lastIpcObject["class"] === "string"
      ? toplevel.lastIpcObject["class"] : ""
  }

  function notify(summary, body) {
    if (notifier.running) return
    notifier.command = ["notify-send", "-a", "Omarchy Minimized", summary, body]
    notifier.running = true
  }

  function finish(message) {
    hyprctlWatchdog.stop()
    operationWatchdog.stop()
    var wasUserFacing = operation === "minimize" || operation === "restore"
    busy = false
    operation = ""
    operationAddress = ""
    operationCommand = ""
    reconciledState = null
    hyprctlContinuation = null
    if (message && wasUserFacing) notify("Minimized windows", message)
    if (message) console.warn("omarchy-minimized: " + message)
  }

  function fail(message) {
    finish(String(message || "Minimized-window action failed."))
  }

  function loadState(text) {
    var result = State.readState(text)
    stateLoaded = true
    stateError = result.ok ? "" : result.error
    if (!result.ok) return
    modeState = result.state
    maybeSessionPrune()
  }

  // Prune once per service lifetime against live clients — not a blanket wipe:
  // a shell restart keeps windows (and their parked addresses) alive, while a
  // Hyprland restart kills them all, in which case every entry is dead anyway.
  function maybeSessionPrune() {
    if (sessionPruned || stateError !== "") return
    sessionPruned = true
    busy = true
    operation = "session-prune"
    startHyprctl(["-j", "clients"], "-j clients", function(rawClients) {
      var clients = parseClients(rawClients, "-j clients")
      if (!clients) return
      // An empty list this early usually means Hyprland's IPC answered
      // before its client table was populated — not that every parked
      // window died. Skip rather than wipe; a later reload can retry.
      if (clients.length === 0) {
        sessionPruned = false
        finish("")
        return
      }
      var reconciliation
      try {
        reconciliation = Minimize.prune(modeState, clients)
      } catch (error) {
        fail(error.message)
        return
      }
      if (reconciliation.staleAddresses.length === 0) finish("")
      else saveState(reconciliation.state, function() { finish("") })
    })
  }

  function saveState(nextState, continuation) {
    try {
      pendingState = State.validateState(nextState)
      stateSaveContinuation = continuation
      if (busy) operationWatchdog.restart()
      if (dirsReady) {
        stateFile.setText(State.writeState(pendingState))
      } else {
        ensureDirectories.running = true
      }
    } catch (error) {
      fail("Could not write state.json: " + error.message)
    }
  }

  function startHyprctl(args, description, continuation) {
    if (!busy || hyprctlProcess.running) {
      fail("Could not start hyprctl " + description + ".")
      return
    }
    hyprctlDescription = description
    hyprctlContinuation = continuation
    operationWatchdog.restart()
    hyprctlProcess.command = ["hyprctl"].concat(args)
    hyprctlProcess.running = true
    hyprctlWatchdog.restart()
  }

  function parseClients(text, description) {
    var clients
    try {
      clients = JSON.parse(text)
    } catch (error) {
      fail("hyprctl " + description + " did not return JSON: " + error.message)
      return null
    }
    if (!Array.isArray(clients)) {
      fail("hyprctl " + description + " did not return an array.")
      return null
    }
    return clients
  }

  // Post-dispatch check: Hyprland reports ok even when a move did not happen,
  // so confirm the window actually landed on the expected workspace.
  function verifyWorkspace(address, workspaceName, continuation) {
    startHyprctl(["-j", "clients"], "verify move", function(rawClients) {
      var clients = parseClients(rawClients, "verify move")
      if (!clients) return
      var client = Minimize.clientAtAddress(clients, address)
      continuation(!!client && Minimize.clientWorkspaceName(client) === workspaceName)
    })
  }

  function planActiveWindow(rawActiveWindow) {
    var activeWindow
    try {
      activeWindow = JSON.parse(rawActiveWindow)
    } catch (error) {
      fail("hyprctl -j activewindow did not return JSON: " + error.message)
      return
    }
    if (!activeWindow || !validAddress(activeWindow.address)) {
      finish("Could not minimize: there is no active window.")
      return
    }
    operationAddress = String(activeWindow.address)
    startHyprctl(["-j", "clients"], "-j clients", planMinimize)
  }

  function startMinimize() {
    if (busy) return "busy"
    if (!stateLoaded) return "not-ready"
    if (stateError !== "") return "invalid-state"
    busy = true
    operation = "minimize"
    operationAddress = validAddress(activeWindowAddress) ? activeWindowAddress : ""
    if (operationAddress !== "") {
      startHyprctl(["-j", "clients"], "-j clients", planMinimize)
    } else {
      startHyprctl(["-j", "activewindow"], "-j activewindow", planActiveWindow)
    }
    return "started"
  }

  function startMinimizeAddress(address) {
    if (busy) return "busy"
    if (!stateLoaded) return "not-ready"
    if (stateError !== "") return "invalid-state"
    if (!validAddress(address)) return "invalid-address"
    busy = true
    operation = "minimize"
    operationAddress = address
    startHyprctl(["-j", "clients"], "-j clients", planMinimize)
    return "started"
  }

  function planMinimize(rawClients) {
    var clients = parseClients(rawClients, "-j clients")
    var reconciliation
    var plan
    if (!clients) return
    try {
      reconciliation = Minimize.prune(modeState, clients)
      plan = Minimize.planMinimize(reconciliation.state, clients, operationAddress)
    } catch (error) {
      fail(error.message)
      return
    }
    if (!plan.ok) {
      finish("Could not minimize this window: " + plan.reason + ".")
      return
    }
    operationCommand = plan.command
    // The origin is durable before the window leaves its numbered workspace.
    saveState(plan.state, function() {
      startHyprctl(["dispatch", operationCommand], "dispatch minimize", function() {
        verifyWorkspace(plan.address, Minimize.MINIMIZED_WORKSPACE, function(moved) {
          if (moved) {
            lastMinimizedAddress = plan.address
            finish("")
          } else {
            fail("Hyprland accepted the move but the window did not park.")
          }
        })
      })
    })
  }

  function startRestore(address) {
    if (busy) return "busy"
    if (!stateLoaded) return "not-ready"
    if (stateError !== "") return "invalid-state"
    if (!validAddress(address)) return "invalid-address"
    busy = true
    operation = "restore"
    operationAddress = address
    startHyprctl(["-j", "clients"], "-j clients", beginRestore)
    return "started"
  }

  function beginRestore(rawClients) {
    var clients = parseClients(rawClients, "-j clients")
    if (!clients) return
    try {
      reconciledState = Minimize.prune(modeState, clients).state
    } catch (error) {
      fail(error.message)
      return
    }
    // Persist destroyed-window cleanup before the final liveness read.
    if (JSON.stringify(reconciledState) !== JSON.stringify(modeState)) {
      saveState(reconciledState, function() {
        startHyprctl(["-j", "clients"], "-j clients", planRestore)
      })
    } else {
      startHyprctl(["-j", "clients"], "-j clients", planRestore)
    }
  }

  function planRestore(rawClients) {
    var clients = parseClients(rawClients, "-j clients")
    var plan
    if (!clients) return
    try {
      // Deliberately immediately before dispatch: Hyprland returns ok for an
      // address that has already died, without moving anything.
      plan = Minimize.planRestore(reconciledState, clients, operationAddress, focusedWorkspaceName())
    } catch (error) {
      fail(error.message)
      return
    }
    if (!plan.ok) {
      if (plan.reason === "dead-address") {
        saveState(plan.state, function() { finish("") })
      } else {
        finish("Could not restore this window: " + plan.reason + ".")
      }
      return
    }
    operationCommand = plan.command
    startHyprctl(["dispatch", operationCommand], "dispatch restore", function() {
      verifyWorkspace(plan.address, plan.origin, function(moved) {
        if (!moved) {
          // Keep the entry so a retry can still reach the origin.
          fail("Hyprland accepted the move but the window did not land on workspace " + plan.origin + ".")
          return
        }
        // Keep the origin until Hyprland has accepted the move.
        saveState(plan.state, function() { finish("") })
      })
    })
  }

  function restoreLast() {
    var address = lastMinimizedAddress
    if (!validAddress(address)) {
      if (minimizedToplevels.length === 0) return "none"
      address = toplevelAddress(minimizedToplevels[minimizedToplevels.length - 1])
    }
    return startRestore(address)
  }

  // Alt+click lands here through the non-consuming mouse bind. Two clicks on
  // the same window inside doubleClickMs minimize the window under the cursor.
  function click() {
    if (probeProcess.running) {
      clickQueued = true
      return "queued"
    }
    probeProcess.command = ["sh", "-c", "hyprctl cursorpos; echo ===; hyprctl -j clients"]
    probeWatchdog.restart()
    probeProcess.running = true
    return "probing"
  }

  function processClick(address) {
    var now = Date.now()
    if (address !== "" && address === lastClickAddress
        && now - lastClickAt <= doubleClickMs) {
      lastClickAt = 0
      lastClickAddress = ""
      startMinimizeAddress(address)
    } else {
      lastClickAt = now
      lastClickAddress = address
    }
  }

  function windowAtCursor(text) {
    var parts = String(text).split("\n===\n")
    if (parts.length !== 2) return ""
    var pos = /^(-?\d+),\s*(-?\d+)/.exec(parts[0].trim())
    if (!pos) return ""
    var x = Number(pos[1])
    var y = Number(pos[2])
    var clients
    try {
      clients = JSON.parse(parts[1])
    } catch (error) {
      return ""
    }
    if (!Array.isArray(clients)) return ""
    // focusHistoryID 0 is the most recently focused window — the best proxy
    // for "topmost" among the clients whose geometry contains the cursor.
    var best = ""
    var bestFocus = -1
    for (var i = 0; i < clients.length; i++) {
      var c = clients[i]
      if (!c || !c.mapped || c.hidden) continue
      // Any special-workspace window (ours or e.g. a scratchpad) has no
      // numbered origin, so it can never be a minimize target.
      if (c.workspace && String(c.workspace.name || "").indexOf("special:") === 0) continue
      var at = c.at, size = c.size
      if (!at || !size || x < at[0] || x >= at[0] + size[0] || y < at[1] || y >= at[1] + size[1]) continue
      var focus = typeof c.focusHistoryID === "number" ? c.focusHistoryID : 2147483647
      if (best === "" || focus < bestFocus) {
        bestFocus = focus
        best = c.address
      }
    }
    return best
  }

  function pruneDestroyed() {
    var reconciliation
    if (busy || !stateLoaded || stateError !== "") return
    var snap = clientSnapshot()
    // The Hyprland toplevel model can still be empty moments after service
    // load; pruning against it would drop every parked entry at once.
    if (snap.length === 0) return
    try {
      reconciliation = Minimize.prune(modeState, snap)
    } catch (error) {
      console.warn("omarchy-minimized: " + error.message)
      return
    }
    if (reconciliation.staleAddresses.length === 0) return
    busy = true
    operation = "prune"
    saveState(reconciliation.state, function() { finish("") })
  }

  Component.onCompleted: {
    ensureDirectories.command = ["mkdir", "-p", stateDirectory, dropinDirectory]
    ensureDirectories.running = true
  }

  function maybeWriteDropin() {
    if (!dirsReady || !dropinKnown) return
    if (dropinExisting === dropinContent) return
    dropinFile.setText(dropinContent)
  }

  // destroy() on disable/remove lands here; children are already torn down, so
  // go through the singleton. The orphan sweep re-checks shell.json a few
  // times — a shell restart destroys us too, and a single check can catch the
  // file mid-rewrite by the incoming shell and sweep parked windows by mistake.
  Component.onDestruction: {
    Quickshell.execDetached(["sh", "-c",
      "rm -f -- \"$1\" && hyprctl reload >/dev/null 2>&1 || :; " +
      "sleep 3; " +
      "for i in 1 2 3; do " +
      "jq -e --arg id omarchy-modes.minimized " +
      "'([.plugins[]?.id] + [(.bar.layout // {})[] | .[]? | .id]) | any(. == $id)' " +
      "\"$HOME/.config/omarchy/shell.json\" >/dev/null 2>&1 && exit 0; " +
      "sleep 2; " +
      "done; " +
      "hyprctl -j clients | jq -r '.[] | select(.workspace.name == \"special:minimized\") | .address' | " +
      "while read -r a; do " +
      "o=$(jq -r --arg a \"$a\" '.minimized[$a].origin // empty' " +
      "\"$HOME/.local/state/omarchy-modes/state.json\" 2>/dev/null); " +
      "case \"$o\" in ''|*[!0-9]*) o=$(hyprctl -j activeworkspace | jq -r '.name') ;; esac; " +
      "case \"$o\" in ''|*[!0-9]*) o=1 ;; esac; " +
      "hyprctl dispatch \"hl.dsp.window.move({ workspace = \\\"$o\\\", window = \\\"address:$a\\\", follow = false })\" >/dev/null 2>&1 || :; " +
      "done",
      "omarchy-minimized-cleanup", dropinPath])
  }

  IpcHandler {
    target: "omarchy-modes.minimized"

    function minimizeActive(): string { return root.startMinimize() }
    function minimizeWindow(address: string): string { return root.startMinimizeAddress(address) }
    function restore(address: string): string { return root.startRestore(address) }
    function restoreLast(): string { return root.restoreLast() }
    function click(): string { return root.click() }
  }

  Process {
    id: ensureDirectories
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        console.warn("omarchy-minimized: could not create state directories")
        root.notify("Minimized windows", "Could not create the state directories.")
        return
      }
      root.dirsReady = true
      root.maybeWriteDropin()
      // A pending save from before mkdir finished — retry it now.
      if (root.busy && root.pendingState && root.stateSaveContinuation) {
        try {
          stateFile.setText(State.writeState(root.pendingState))
        } catch (error) {
          root.fail("Could not write state.json: " + error.message)
        }
      }
    }
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadState(text())
    onLoadFailed: root.loadState(null)
    onFileChanged: reload()
    onSaved: {
      root.modeState = root.pendingState
      root.pendingState = null
      var continuation = root.stateSaveContinuation
      root.stateSaveContinuation = null
      if (continuation) continuation()
    }
    onSaveFailed: root.fail("Could not save state.json.")
  }

  FileView {
    id: dropinFile
    path: root.dropinPath
    atomicWrites: true
    printErrors: false
    onLoaded: {
      root.dropinExisting = text()
      root.dropinKnown = true
      root.maybeWriteDropin()
    }
    onLoadFailed: {
      root.dropinExisting = ""
      root.dropinKnown = true
      root.maybeWriteDropin()
    }
    onSaved: Quickshell.execDetached(["hyprctl", "reload"])
    onSaveFailed: console.warn("omarchy-minimized: could not save the keybind drop-in")
  }

  Process {
    id: hyprctlProcess
    stdout: StdioCollector { id: hyprctlStdout; waitForEnd: true }
    stderr: StdioCollector { id: hyprctlStderr; waitForEnd: true }
    onExited: function(exitCode) {
      hyprctlWatchdog.stop()
      if (!root.busy) return
      var continuation = root.hyprctlContinuation
      root.hyprctlContinuation = null
      if (exitCode !== 0) {
        root.fail("hyprctl " + root.hyprctlDescription + " failed" +
          (hyprctlStderr.text ? ": " + String(hyprctlStderr.text).trim() : "."))
        return
      }
      if (continuation) continuation(String(hyprctlStdout.text || ""))
    }
  }

  // Alt+click probing gets its own process: clicks must never gate on an
  // in-flight minimize/restore.
  Process {
    id: probeProcess
    stdout: StdioCollector { id: probeStdout; waitForEnd: true }
    onExited: function(exitCode) {
      probeWatchdog.stop()
      var queued = root.clickQueued
      root.clickQueued = false
      if (exitCode === 0) root.processClick(root.windowAtCursor(probeStdout.text))
      // A click queued mid-probe gets its own fresh probe — its timestamp is
      // recorded when that probe lands, keeping the double-click window honest.
      // On a watchdog kill it gets the same retry instead of being dropped.
      if (queued) root.click()
    }
  }

  Process { id: notifier }

  // Click probes run outside the operation lock, so they get their own
  // watchdog — a hung hyprctl there would otherwise silence Alt+click
  // for the rest of the session.
  Timer {
    id: probeWatchdog
    interval: root.hyprctlTimeoutMs
    repeat: false
    onTriggered: if (probeProcess.running) probeProcess.signal(9)
  }

  Timer {
    id: operationWatchdog
    interval: root.operationTimeoutMs
    repeat: false
    onTriggered: root.fail("Operation timed out after "
      + root.operationTimeoutMs / 1000 + "s; the state lock was released.")
  }

  Timer {
    id: hyprctlWatchdog
    interval: root.hyprctlTimeoutMs
    repeat: false
    onTriggered: {
      if (!hyprctlProcess.running || !root.busy) return
      hyprctlProcess.signal(9)
      root.fail("hyprctl " + root.hyprctlDescription + " did not answer within "
        + root.hyprctlTimeoutMs + "ms; Hyprland IPC may be wedged.")
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event && event.name === "closewindow") Qt.callLater(root.pruneDestroyed)
    }
  }
}
