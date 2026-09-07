import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

Item {
  id: root

  property var shell: null
  property var manifest: null
  readonly property var appLibrary: root.shell ? root.shell.appLibrary : null
  property bool opened: false
  property bool loading: false
  property string filterText: ""
  property int selectedIndex: 0
  property var windows: []
  // Selection is tracked by address as well as by row so a background poll
  // that reorders or trims the list cannot move the highlight under the user.
  property string selectedAddress: ""

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int cardWidth: Math.min(Style.space(680), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(520), panel.height - Style.gapsOut * 2)
  property int contentMargin: Style.spacing.panelPadding
  property int rowHeight: Math.max(Style.space(58), Style.font.body + Style.font.caption + Style.spacing.rowPaddingX * 2)

  function pluginId() {
    return (root.manifest && root.manifest.id) || "nahime.window-switcher"
  }

  function open(payloadJson) {
    root.opened = true
    root.filterText = ""
    root.selectedIndex = 0
    root.selectedAddress = ""
    if (root.appLibrary) root.appLibrary.refreshIcons()
    root.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId())
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function refresh() {
    if (!clientsProc.running) {
      root.loading = true
      clientsProc.running = true
    }
  }

  function loadClients(raw) {
    var parsed = []
    try { parsed = JSON.parse(raw || "[]") } catch (error) { parsed = [] }

    var next = []
    for (var i = 0; i < parsed.length; i++) {
      var client = parsed[i]
      if (client.mapped === false || !client.address) continue
      var appClass = String(client.class || client.initialClass || "Window")
      var title = String(client.title || client.initialTitle || appClass)
      var workspace = client.workspace || {}
      var resolvedIcon = root.iconForClass(appClass)
      next.push({
        address: String(client.address),
        appClass: appClass,
        appIcon: resolvedIcon,
        title: title,
        workspaceId: Number(workspace.id || 0),
        workspaceName: String(workspace.name || workspace.id || "")
      })
    }
    next.sort(function(a, b) {
      if (a.workspaceId !== b.workspaceId) return a.workspaceId - b.workspaceId
      return a.appClass.localeCompare(b.appClass)
    })
    root.windows = next
    root.rebuildDisplay()
    root.loading = false
  }

  function normalizedAppId(value) {
    return String(value || "").toLowerCase().replace(/\.desktop$/, "").replace(/[^a-z0-9]/g, "")
  }

  function iconForClass(appClass) {
    var rawClass = String(appClass || "")
    var wanted = root.normalizedAppId(rawClass)
    if (!wanted) return "application-x-executable"

    if (root.appLibrary) {
      var rows = root.appLibrary.sortedEntries("")
      var partialIcon = ""
      for (var i = 0; i < rows.length; i++) {
        var entry = rows[i].entry
        if (!entry) continue
        var icon = String(entry.icon || "")
        if (!icon) continue
        var candidates = [entry.id, entry.name, entry.startupClass]
        for (var j = 0; j < candidates.length; j++) {
          var candidate = root.normalizedAppId(candidates[j])
          if (!candidate) continue
          if (candidate === wanted) return icon
          if (!partialIcon && candidate.length >= 4
              && (wanted.indexOf(candidate) === 0 || candidate.indexOf(wanted) === 0)) partialIcon = icon
        }

        // Omarchy web-app desktop entries launch a URL but usually omit
        // StartupWMClass. Chrome includes that URL's host in the window class,
        // so match the host to preserve each web-app's dedicated icon.
        var execString = String(entry.execString || "")
        var urlMatch = execString.match(/https?:\/\/([^\/\s]+)/i)
        if (urlMatch && urlMatch[1]) {
          var host = root.normalizedAppId(urlMatch[1])
          if (host.length >= 4 && wanted.indexOf(host) !== -1) return icon
        }
      }
      if (partialIcon) return partialIcon
    }

    // Chrome web-app window classes start with `chrome-`, while their
    // desktop entry and themed icon are named google-chrome.
    if (rawClass.toLowerCase().indexOf("chrome-") === 0) return "google-chrome"
    return rawClass.toLowerCase()
  }

  function rowIndexOf(address) {
    if (!address) return -1
    for (var i = 0; i < displayModel.count; i++) {
      if (displayModel.get(i).address === address) return i
    }
    return -1
  }

  // mode: "top" jumps to the best match after the query changed, "restore"
  // (default) keeps the highlight on whichever window it was already on.
  function rebuildDisplay(mode) {
    var intent = mode || "restore"
    var query = root.filterText.toLowerCase().trim()
    var previous = root.selectedAddress
    displayModel.clear()
    for (var i = 0; i < root.windows.length; i++) {
      var win = root.windows[i]
      var haystack = (win.appClass + " " + win.title + " " + win.workspaceName).toLowerCase()
      if (!query || haystack.indexOf(query) !== -1) displayModel.append(win)
    }

    var count = displayModel.count
    if (count === 0) {
      root.selectedIndex = 0
      root.selectedAddress = ""
      return
    }

    var restored = intent === "restore" ? root.rowIndexOf(previous) : -1
    root.selectedIndex = restored >= 0 ? restored
      : (intent === "top" ? 0 : Math.max(0, Math.min(root.selectedIndex, count - 1)))
    root.selectedAddress = displayModel.get(root.selectedIndex).address
    Qt.callLater(function() {
      if (displayModel.count > 0) resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    })
  }

  function setFilter(value) {
    root.filterText = value
    root.rebuildDisplay("top")
  }

  function selectIndex(index) {
    if (index < 0 || index >= displayModel.count) return
    root.selectedIndex = index
    root.selectedAddress = displayModel.get(index).address
  }

  function moveSelection(delta) {
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
    var code = "local w = hl.get_window(\"address:" + address
      + "\"); if w then return hl.dispatch(hl.dsp.focus({ window = w })) end"
    Quickshell.execDetached(["hyprctl", "eval", code])
  }

  ListModel { id: displayModel }

  Connections {
    target: root.appLibrary
    function onAppsChanged() { if (root.opened) root.refresh() }
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
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "nahime-window-switcher"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: root.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else root.dismiss()
            event.accepted = true
          } else if (event.key === Qt.Key_P && event.modifiers === Qt.ControlModifier) {
            root.moveSelection(-1); event.accepted = true
          } else if (event.key === Qt.Key_N && event.modifiers === Qt.ControlModifier) {
            root.moveSelection(1); event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.moveSelection(-1); event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.moveSelection(1); event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.activate(root.selectedIndex); event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText)); event.accepted = true
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.setFilter(root.filterText + event.text); event.accepted = true
          }
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.spacing.md

        Rectangle {
          width: parent.width
          height: Math.max(Style.space(46), Style.font.heading + Style.spacing.controlPaddingY * 2)
          radius: root.cornerRadius
          color: root.selectedBackground
          opacity: 0.88

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.md
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            text: root.filterText || "Search open windows…"
            color: root.selectedText
            opacity: root.filterText ? 1 : 0.62
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }
        }

        ListView {
          id: resultList
          width: parent.width
          height: parent.height - y
          model: displayModel
          clip: true
          spacing: Style.spacing.xs
          boundsBehavior: Flickable.StopAtBounds

          delegate: Rectangle {
            required property int index
            required property string address
            required property string appClass
            required property string appIcon
            required property string title
            required property string workspaceName
            readonly property bool selected: index === root.selectedIndex
            width: resultList.width
            height: root.rowHeight
            radius: root.cornerRadius
            color: selected ? root.selectedBackground : "transparent"

            Item {
              id: appGlyph
              width: Style.space(42)
              height: parent.height
              anchors.left: parent.left
              anchors.leftMargin: Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter

              Text {
                anchors.centerIn: parent
                text: "󰣆"
                color: selected ? root.selectedText : root.foreground
                opacity: appIconImage.status === Image.Ready ? 0 : 0.75
                font.family: root.fontFamily
                font.pixelSize: Style.font.iconLarge
              }

              Image {
                id: appIconImage
                width: Style.font.iconLarge
                height: Style.font.iconLarge
                anchors.centerIn: parent
                fillMode: Image.PreserveAspectFit
                sourceSize.width: width * Screen.devicePixelRatio
                sourceSize.height: height * Screen.devicePixelRatio
                source: root.appLibrary ? root.appLibrary.iconSource(appIcon) : Quickshell.iconPath(appIcon, true)
                // Icons are small local theme assets. Synchronous loading avoids
                // restarting an in-flight decode whenever the client list refreshes.
                asynchronous: false
              }
            }

            Column {
              anchors.left: appGlyph.right
              anchors.leftMargin: Style.spacing.sm
              anchors.right: workspaceLabel.left
              anchors.rightMargin: Style.spacing.md
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)
              Text {
                width: parent.width
                text: title
                color: selected ? root.selectedText : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                font.weight: Font.Medium
                elide: Text.ElideRight
              }
              Text {
                width: parent.width
                text: appClass
                color: selected ? root.selectedText : root.foreground
                opacity: 0.65
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            Text {
              id: workspaceLabel
              anchors.right: parent.right
              anchors.rightMargin: Style.spacing.md
              anchors.verticalCenter: parent.verticalCenter
              text: workspaceName ? "Workspace " + workspaceName : ""
              color: selected ? root.selectedText : root.foreground
              opacity: 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onContainsMouseChanged: if (containsMouse) root.selectIndex(index)
              onClicked: root.activate(index)
            }
          }

          Column {
            anchors.centerIn: parent
            visible: displayModel.count === 0
            spacing: Style.spacing.sm
            Text {
              width: parent.width
              text: root.loading ? "󰔟" : "󰖲"
              color: root.foreground
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
              horizontalAlignment: Text.AlignHCenter
            }
            Text {
              width: parent.width
              text: root.loading ? "Loading windows…" : (root.filterText ? "No matching windows" : "No open windows")
              color: root.foreground
              opacity: 0.65
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              horizontalAlignment: Text.AlignHCenter
            }
          }
        }
      }
    }
  }
}
