import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons

Item {
  id: root

  property var shell: null
  property var manifest: null
  readonly property var desktopEntries: DesktopEntries.applications.values
  property bool opened: false
  property bool loading: false
  property int selectedIndex: 0
  property var windows: []
  // Address of the window Hyprland had focused when the switcher opened, so
  // the first highlight can land one step past it the way Cmd+Tab does.
  property string activeAddress: ""
  // Selection is tracked by address as well as by row so a background poll
  // that reorders or trims the list cannot move the highlight under the user.
  property string selectedAddress: ""
  property bool pendingInitial: false
  property int initialStep: 1
  property string holdModifier: "super"
  property bool confirmOnLoad: false
  property bool keyboardApplied: false
  property bool keyboardTarget: false

  property color background: Color.menu.background
  readonly property bool darkBackground: background.r * 0.299 + background.g * 0.587 + background.b * 0.114 < 0.5
  readonly property color foreground: darkBackground ? "#f5f5f7" : "#1d1d1f"
  readonly property int cornerRadius: Style.space(26)
  property string fontFamily: "sans-serif"
  readonly property int contentMargin: Style.space(22)
  readonly property int tileSize: Math.max(Style.space(84), Math.min(Style.space(124),
    (panel.width - Style.space(100)) / Math.max(1, displayModel.count)))
  readonly property int iconSize: Math.round(Math.min(tileSize * 0.7, tileSize - Style.space(36)))
  readonly property int cardWidth: Math.max(1, Math.min(panel.width - Style.space(40),
    Math.max(Style.space(300), displayModel.count * tileSize + contentMargin * 2)))
  readonly property int cardHeight: tileSize + Style.space(36)

  function pluginId() {
    return (root.manifest && root.manifest.id) || "illegalstudio.omarchy-cmdtab"
  }

  function open(payloadJson) {
    var step = 1
    try {
      var payload = JSON.parse(payloadJson || "{}") || {}
      if (payload.step !== undefined) step = Number(payload.step)
    } catch (error) { step = 1 }
    if (!isFinite(step) || step === 0) step = 1

    // A second summon while the overlay is up means "keep walking the list",
    // never "reset it".
    if (root.opened) { root.moveSelection(step); return }

    root.opened = true
    root.selectedIndex = 0
    root.selectedAddress = ""
    displayModel.clear()
    root.initialStep = step
    root.holdModifier = payload && payload.modifier === "alt" ? "alt" : "super"
    root.confirmOnLoad = false
    root.pendingInitial = true
    root.syncKeyboard()
    root.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    root.confirmOnLoad = false
    root.syncKeyboard()
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId())
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // IPC entry point for the keybinding:
  //   omarchy-shell shell call illegalstudio.omarchy-cmdtab cycle 1
  // Bound instead of `shell toggle` so holding SUPER and tapping TAB keeps
  // stepping down the list rather than closing the overlay on the second tap.
  function cycle(step) {
    var parts = String(step || "1").trim().split(/\s+/)
    var delta = Number(parts[0])
    if (!isFinite(delta) || delta === 0) delta = 1
    if (root.opened) root.moveSelection(delta)
    else root.open(JSON.stringify({ step: delta, modifier: parts[1] }))
    return "ok"
  }

  // Activate the current selection, also used when the held modifier is released:
  //   omarchy-shell shell call illegalstudio.omarchy-cmdtab confirm ""
  function confirm() {
    if (!root.opened) return "closed"
    // A quick tap can release SUPER before hyprctl has returned the clients.
    if (root.pendingInitial) { root.confirmOnLoad = true; return "pending" }
    if (displayModel.count === 0) { root.dismiss(); return "empty" }
    root.activate(root.selectedIndex)
    return "ok"
  }

  function release(modifier) {
    if (!root.opened) return "closed"
    if (String(modifier) !== root.holdModifier) return "ignored"
    return root.confirm()
  }

  function vimNavigate(key) {
    if (!root.opened) return "closed"
    var delta = key === "h" ? -1 : key === "l" ? 1 : 0
    if (!delta) return "ignored"
    root.moveSelection(delta)
    return "ok"
  }

  function handleKey(key, modifiers) {
    if (!root.opened) return false
    if (key === Qt.Key_Escape) root.dismiss()
    else if (key === Qt.Key_H) root.moveSelection(-1)
    else if (key === Qt.Key_L) root.moveSelection(1)
    else if (key === Qt.Key_Backtab || (key === Qt.Key_Tab && (modifiers & Qt.ShiftModifier))) root.moveSelection(-1)
    else if (key === Qt.Key_Tab) root.moveSelection(1)
    // Consume every other key without activating a command or editing text.
    return true
  }

  function syncKeyboard() {
    if (keyboardProc.running || root.keyboardApplied === root.opened) return
    root.keyboardTarget = root.opened
    var name = root.keyboardTarget ? "omarchy-cmdtab" : "reset"
    keyboardProc.command = ["hyprctl", "eval", 'hl.dispatch(hl.dsp.submap("' + name + '"))']
    keyboardProc.running = true
  }

  function keyboardFinished(exitCode) {
    // The entry binding may already have captured input even if this process
    // failed. Always attempt the matching reset before treating it as released.
    root.keyboardApplied = root.keyboardTarget
    if (exitCode !== 0 && root.keyboardTarget && root.opened) root.dismiss()
    if (root.keyboardApplied !== root.opened)
      Qt.callLater(function() { root.syncKeyboard() })
  }

  Component.onDestruction: {
    if (root.opened || root.keyboardApplied || keyboardProc.running)
      Quickshell.execDetached(["hyprctl", "eval", 'hl.dispatch(hl.dsp.submap("reset"))'])
  }

  function refresh() {
    if (activeProc.running || clientsProc.running) return
    root.loading = true
    // activewindow first: loadClients needs the focused address to place the
    // initial highlight, and chaining keeps the two views of the same instant.
    activeProc.running = true
  }

  function loadClients(raw) {
    var parsed = []
    try { parsed = JSON.parse(raw || "[]") } catch (error) { parsed = [] }
    if (!Array.isArray(parsed)) parsed = []

    var next = []
    var haveFocusHistory = parsed.length > 0
    for (var i = 0; i < parsed.length; i++) {
      var client = parsed[i]
      if (!client || client.mapped === false || !client.address) continue
      var appClass = String(client.class || client.initialClass || "Window")
      var workspace = client.workspace || {}
      var application = root.applicationFor(client)
      // Hyprland ranks clients by how recently each held focus: 0 is the
      // window in front of you, 1 the one before it, and so on.
      var focusOrder = Number(client.focusHistoryID)
      if (!isFinite(focusOrder)) {
        focusOrder = next.length
        haveFocusHistory = false
      }
      next.push({
        address: String(client.address),
        appClass: appClass,
        appIcon: application.icon,
        appName: application.name,
        focusOrder: focusOrder,
        workspaceId: Number(workspace.id || 0)
      })
    }
    // Most-recently-used order, like macOS Cmd+Tab. Hyprland builds that
    // predate focusHistoryID fall back to the old workspace grouping.
    if (haveFocusHistory) {
      next.sort(function(a, b) { return a.focusOrder - b.focusOrder })
    } else {
      next.sort(function(a, b) {
        if (a.workspaceId !== b.workspaceId) return a.workspaceId - b.workspaceId
        return a.appClass.localeCompare(b.appClass)
      })
    }
    root.windows = next
    root.rebuildDisplay(root.pendingInitial ? "initial" : "restore")
    root.loading = false
    if (root.opened && root.confirmOnLoad) root.confirm()
  }

  function normalizedAppId(value) {
    return String(value || "").toLowerCase().replace(/\.desktop$/, "").replace(/[^a-z0-9]/g, "")
  }

  function applicationFor(client) {
    var appClass = String(client.class || client.initialClass || "Window")
    var classes = [appClass, String(client.initialClass || "")]
    var best = null
    var bestScore = 0
    // Overlay plugins do not receive shell.appLibrary. DesktopEntries is the
    // public Quickshell index and includes the user's Omarchy webapps.
    var entries = root.desktopEntries || []
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i]
      if (!entry || !entry.icon) continue
      var score = 0
      for (var k = 0; k < classes.length; k++) {
        var wanted = root.normalizedAppId(classes[k])
        if (!wanted) continue
        var candidates = [entry.startupClass, entry.id, entry.name]
        for (var j = 0; j < candidates.length; j++) {
          var candidate = root.normalizedAppId(candidates[j])
          if (candidate && candidate === wanted) score = Math.max(score, 120 - j * 10 - k)
        }
        var webClass = classes[k].match(/^(?:chrome|chromium|brave|msedge|microsoft-edge|vivaldi)-(.+)-(?:Default|Profile.*|\d+)$/i)
        var url = String(entry.execString || "").match(/https?:\/\/([^\s"']+)/i)
        if (webClass && url) {
          var identity = webClass[1].toLowerCase()
          var host = url[1].split("/")[0].toLowerCase()
          // Compare whole hosts, then prefer the longest matching URL path
          // when multiple webapps share a host (for example separate inboxes).
          if (identity.split(/[\/_]/)[0] === host) {
            var urlKey = root.normalizedAppId(url[1])
            var windowKey = root.normalizedAppId(identity)
            if (windowKey.indexOf(urlKey) === 0) score = Math.max(score, 150 + urlKey.length)
          }
        }
      }
      if (score > bestScore) { bestScore = score; best = entry }
    }
    if (!best) best = DesktopEntries.heuristicLookup(appClass)
      || DesktopEntries.heuristicLookup(classes[1])
    var browser = appClass.match(/^(chrome|chromium|brave|msedge|microsoft-edge|vivaldi)-/i)
    var fallback = browser ? ({ chrome: "google-chrome", brave: "brave-browser",
      msedge: "microsoft-edge" })[browser[1].toLowerCase()] || browser[1].toLowerCase()
      : appClass.toLowerCase()
    return { icon: String((best && best.icon) || fallback),
      name: String((best && best.name) || appClass) }
  }

  function iconSource(icon) {
    var value = String(icon || "")
    if (value.indexOf("file:") === 0 || value.indexOf("image:") === 0) return value
    if (value.charAt(0) === "/") return Util.fileUrl(value)
    return Quickshell.iconPath(value, true) || Quickshell.iconPath("application-x-executable", true)
  }

  function rowIndexOf(address) {
    if (!address) return -1
    for (var i = 0; i < displayModel.count; i++) {
      if (displayModel.get(i).address === address) return i
    }
    return -1
  }

  // Initial selection is relative to the focused window. Refreshes preserve
  // the selected address even when the compositor reorders the clients.
  function rebuildDisplay(mode) {
    var intent = mode || "restore"
    var previous = root.selectedAddress
    displayModel.clear()
    for (var i = 0; i < root.windows.length; i++) {
      var win = root.windows[i]
      displayModel.append(win)
    }

    var count = displayModel.count
    if (count === 0) {
      if (intent === "initial") root.pendingInitial = false
      root.selectedIndex = 0
      root.selectedAddress = ""
      return
    }

    if (intent === "initial") {
      root.pendingInitial = false
      // One step past the window you are on, so a single SUPER+TAB and release
      // returns to the window you last used. With nothing focused (an empty
      // workspace) row 0 is already that window, so forward starts there.
      var active = root.rowIndexOf(root.activeAddress)
      var anchor = active >= 0 ? active : (root.initialStep > 0 ? -1 : 0)
      root.selectedIndex = ((anchor + root.initialStep) % count + count) % count
    } else {
      var restored = root.rowIndexOf(previous)
      root.selectedIndex = restored >= 0 ? restored : Math.max(0, Math.min(root.selectedIndex, count - 1))
    }
    root.selectedAddress = displayModel.get(root.selectedIndex).address
    Qt.callLater(function() {
      if (displayModel.count > 0) resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    })
  }

  function selectIndex(index) {
    if (index < 0 || index >= displayModel.count) return
    root.selectedIndex = index
    root.selectedAddress = displayModel.get(index).address
  }

  function moveSelection(delta) {
    if (root.pendingInitial) { root.initialStep += delta; return }
    var count = displayModel.count
    if (count === 0) return
    root.selectIndex(((root.selectedIndex + delta) % count + count) % count)
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function activate(index) {
    if (index < 0 || index >= displayModel.count) return
    var address = displayModel.get(index).address
    root.dismiss()
    // Hyprland's Lua config provider does not accept the legacy
    // `dispatch focuswindow address:…` syntax. Resolve the native window
    // object and focus it through the current Lua dispatcher API instead.
    if (!/^0x[0-9a-f]+$/i.test(address)) return
    var code = "local w = hl.get_window(\"address:" + address
      + "\"); if w then hl.dispatch(hl.dsp.focus({ window = w })); "
      + "hl.dispatch(hl.dsp.window.bring_to_top()) end"
    // Drop the exclusive layer keyboard focus before focusing the client.
    Qt.callLater(function() { Quickshell.execDetached(["hyprctl", "eval", code]) })
  }

  Process {
    id: keyboardProc
    onExited: function(exitCode, exitStatus) { root.keyboardFinished(exitCode) }
  }

  ListModel { id: displayModel }

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() { if (root.opened) root.refresh() }
  }

  Process {
    id: activeProc
    command: ["hyprctl", "-j", "activewindow"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var address = ""
        try {
          var active = JSON.parse(text || "{}")
          if (active && active.address) address = String(active.address)
        } catch (error) { address = "" }
        root.activeAddress = address
        clientsProc.running = true
      }
    }
  }

  Process {
    id: clientsProc
    command: ["hyprctl", "-j", "clients"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadClients(text)
    }
    onExited: root.loading = false
  }

  Timer {
    interval: 1500
    repeat: true
    running: root.opened
    onTriggered: root.refresh()
  }

  PanelWindow {
    id: panel
    visible: root.opened && root.keyboardApplied && root.keyboardTarget
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-cmdtab"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    MouseArea { anchors.fill: parent; onClicked: {} }

    Rectangle {
      anchors.centerIn: card
      anchors.verticalCenterOffset: Style.space(8)
      width: card.width + Style.space(12)
      height: card.height + Style.space(12)
      radius: root.cornerRadius + Style.space(6)
      color: "#18000000"
    }

    Rectangle {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: Qt.rgba(root.background.r, root.background.g, root.background.b, 0.97)
      border.width: 1
      border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.16)
      antialiasing: true

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onReleased: function(event) {
          if (event.isAutoRepeat) return
          if (event.key === Qt.Key_Meta || event.key === Qt.Key_Super_L || event.key === Qt.Key_Super_R) {
            root.release("super"); event.accepted = true
          } else if (event.key === Qt.Key_Alt || event.key === Qt.Key_AltGr) {
            root.release("alt"); event.accepted = true
          }
        }
        Keys.onPressed: function(event) {
          event.accepted = root.handleKey(event.key, event.modifiers)
        }
      }

      ListView {
        id: resultList
        x: root.contentMargin
        y: Style.space(18)
        width: parent.width - root.contentMargin * 2
        height: root.tileSize
        orientation: ListView.Horizontal
        interactive: false
        model: displayModel
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        delegate: Item {
          required property int index
          required property string appIcon
          required property string appName
          readonly property bool selected: index === root.selectedIndex
          width: root.tileSize
          height: resultList.height

          Rectangle {
            x: Style.space(4)
            y: Style.space(2)
            width: parent.width - Style.space(8)
            height: parent.height - Style.space(4)
            radius: Style.space(17)
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, selected ? 0.16 : 0)
            border.width: selected ? 1 : 0
            border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
            Behavior on color { ColorAnimation { duration: 90 } }
          }

          Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            y: Style.space(8)
            width: root.iconSize
            height: root.iconSize
            radius: Style.space(16)
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
            visible: appIconImage.status !== Image.Ready
            Text {
              anchors.centerIn: parent
              text: appName.slice(0, 1).toUpperCase()
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: root.iconSize * 0.45
              font.weight: Font.Medium
            }
          }

          Image {
            id: appIconImage
            anchors.horizontalCenter: parent.horizontalCenter
            y: Style.space(8)
            width: root.iconSize
            height: root.iconSize
            fillMode: Image.PreserveAspectFit
            sourceSize.width: width * Screen.devicePixelRatio
            sourceSize.height: height * Screen.devicePixelRatio
            source: root.iconSource(appIcon)
            asynchronous: false
          }

          Text {
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.space(8)
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width - Style.space(12)
            text: appName
            visible: selected
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.space(13)
            font.weight: Font.Medium
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }


        }
      }
    }
  }
}
