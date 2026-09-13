import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// A standing notification indicator for the bar.
//
// Omarchy's notification plugin is a service with no bar-widget entry point:
// toasts appear top-right, expire, and are archived as one JSON file each in
// the history directory. Nothing in the bar says that happened. The only
// stock indicator is the DND glyph inside omarchy.indicators, and it is
// deliberately invisible unless DND is on -- so a notification you missed and
// a notification that never arrived look identical.
//
// This widget reads that history directory and counts what landed there since
// you last looked. The distinction that makes the count mean something: a
// notification only reaches history once its toast has expired. Anything still
// on screen is being seen right now and is deliberately not counted -- the
// badge is "what I missed", not "what exists".
Panel {
  id: root
  moduleName: "dbarke.notifications"
  ipcTarget: "dbarke.notifications"
  manageIpc: false

  // ---------------------------------------------------------------- theme
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool barVertical: bar ? bar.vertical : false

  // -------------------------------------------------------------- service
  // The same handle omarchy's own DND indicator uses. Reached defensively:
  // if a future shell stops exposing it to third-party plugins the widget
  // still works, falling back to the documented IPC surface below.
  readonly property var svc: (bar && bar.shell && typeof bar.shell.firstPartyServiceFor === "function")
    ? bar.shell.firstPartyServiceFor("omarchy.notifications") : null
  readonly property bool dnd: svc ? !!svc.doNotDisturb : dndFallback
  // Mirrors DND when the service handle is unavailable and IPC is the only
  // route; kept in sync by the polls below.
  property bool dndFallback: false

  // ------------------------------------------------------------- settings
  readonly property int intervalMs: Math.max(5, Number(setting("refreshIntervalSec", 15))) * 1000
  readonly property bool showBadge: setting("showBadge", true) !== false
  readonly property bool hideWhenQuiet: setting("hideWhenQuiet", false) === true
  readonly property int bodyChars: Math.max(0, Number(setting("bodyChars", 140)))
  // Comma-separated text matched against "app summary". Notifications you
  // caused yourself -- the screenshot confirmation above all -- are not things
  // you missed, so they are dropped before they can reach the count.
  readonly property string ignorePatterns: String(setting("ignorePatterns", "Screenshot saved") || "")

  readonly property string historyDir:
    Quickshell.env("HOME") + "/.local/state/omarchy/notifications/history"

  // ---------------------------------------------------------------- state
  property var entries: []
  property bool ready: false
  property string lastError: ""
  property double nowMs: Date.now()

  // Survives QML hot-reloads, which happen every time a plugin file is saved.
  // It does NOT survive a full shell restart: on a cold start lastSeenMs is
  // stamped to now, so a restart reads as "nothing missed yet" rather than
  // dumping ten old rows into the badge.
  PersistentProperties {
    id: seenState
    reloadableId: "dbarke-notifications"
    property double lastSeenMs: 0
  }

  readonly property int unseen: {
    var n = 0
    for (var i = 0; i < entries.length; i++)
      if (Number(entries[i].timestamp) > seenState.lastSeenMs) n++
    return n
  }

  readonly property bool anyUrgent: {
    for (var i = 0; i < entries.length; i++)
      if (Number(entries[i].timestamp) > seenState.lastSeenMs && Number(entries[i].urgency) >= 2)
        return true
    return false
  }

  // Silenced always shows. Hiding a mute is how a quiet day turns out to have
  // been a broken one.
  visible: !hideWhenQuiet || unseen > 0 || dnd

  // ------------------------------------------------------------- helpers
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function ago(ms) {
    var delta = Math.max(0, root.nowMs - Number(ms || 0))
    var minutes = Math.floor(delta / 60000)
    if (minutes < 1) return "just now"
    if (minutes < 60) return minutes + "m ago"
    var hours = Math.floor(minutes / 60)
    if (hours < 24) return hours + "h ago"
    return Math.floor(hours / 24) + "d ago"
  }

  function truncate(text, limit) {
    var s = String(text || "")
    if (limit <= 0 || s.length <= limit) return s
    return s.slice(0, limit).replace(/\s+\S*$/, "") + "…"
  }

  function markSeen() {
    seenState.lastSeenMs = Date.now()
  }

  // ------------------------------------------------------------- reading
  //
  // One file per notification, so the read is a directory scan. Python does
  // the parse because the payloads carry newlines and markup that would have
  // to be unpicked from shell output otherwise; it emits one JSON array.
  readonly property string readerScript:
    "import json,glob,os,re,sys\n" +
    "d=sys.argv[1]\n" +
    "pats=[p.strip().lower() for p in (sys.argv[2] if len(sys.argv)>2 else '').split(',') if p.strip()]\n" +
    "tag=re.compile(r'<[^>]+>')\n" +
    "out=[]\n" +
    "try:\n" +
    "    fs=sorted(glob.glob(os.path.join(d,'*.json')),key=os.path.getmtime,reverse=True)\n" +
    "except Exception:\n" +
    "    fs=[]\n" +
    "for f in fs:\n" +
    "    try:\n" +
    "        e=json.load(open(f))\n" +
    "    except Exception:\n" +
    "        continue\n" +
    "    app=str(e.get('app') or '')\n" +
    "    summary=tag.sub('', str(e.get('summary') or '')).strip()\n" +
    "    if any(p in (app+' '+summary).lower() for p in pats):\n" +
    "        continue\n" +
    "    out.append({\n" +
    "        'app': app,\n" +
    "        'summary': summary,\n" +
    "        'body': tag.sub('', str(e.get('body') or '')).strip(),\n" +
    "        'timestamp': e.get('timestamp') or 0,\n" +
    "        'urgency': e.get('urgency') or 1,\n" +
    "    })\n" +
    "print(json.dumps(out))\n"

  function refreshNow() {
    if (!readProc.running) readProc.running = true
    if (!svc && !dndProc.running) dndProc.running = true
  }

  function applyOutput(text) {
    var raw = String(text || "").trim()
    if (raw === "") { entries = []; ready = true; return }
    try {
      var parsed = JSON.parse(raw)
      entries = Array.isArray(parsed) ? parsed : []
      lastError = ""
    } catch (e) {
      lastError = "Could not read notification history"
    }
    ready = true

    // A cold start should not present the existing archive as unread.
    if (seenState.lastSeenMs === 0) markSeen()
  }

  // ------------------------------------------------------------- actions
  function runCmd(args) {
    if (actionProc.running) return
    actionProc.command = args
    actionProc.running = true
  }

  function replayHistory() {
    if (svc && typeof svc.showRecentHistory === "function") svc.showRecentHistory()
    else runCmd(["omarchy-shell", "-q", "notifications", "showHistory"])
    markSeen()
  }

  function toggleDnd() {
    if (svc && typeof svc.setDoNotDisturb === "function") svc.setDoNotDisturb(!svc.doNotDisturb)
    else {
      dndFallback = !dndFallback
      runCmd(["omarchy-shell", "-q", "notifications", "toggleDnd"])
    }
  }

  function clearHistory() {
    if (svc && typeof svc.clearHistory === "function") svc.clearHistory()
    else runCmd(["omarchy-shell", "-q", "notifications", "clear"])
    markSeen()
    Qt.callLater(function () { root.refreshNow() })
  }

  // ---------------------------------------------------------------- bar
  // Nerd Font bell, bell-ring and bell-off, written as surrogate pairs so the
  // file survives any transport that mangles astral-plane characters.
  readonly property string glyph:
    dnd ? "󰂛" : (unseen > 0 ? "󰂞" : "󰂚")

  readonly property color glyphColor: {
    if (dnd) return dim
    if (anyUrgent) return urgent
    if (unseen > 0) return foreground
    return dim
  }

  readonly property string barTooltip: {
    if (dnd) return "Notifications silenced\nRight-click to allow them again"
    if (!ready) return "Reading notification history…"
    if (lastError !== "") return lastError
    if (unseen === 0)
      return entries.length === 0
        ? "Nothing in history\nRight-click to silence notifications"
        : "Nothing missed\nClick for the last " + entries.length
          + (entries.length === 1 ? " notification" : " notifications")

    var lines = [unseen + (unseen === 1 ? " missed notification" : " missed notifications"), ""]
    var shown = 0
    for (var i = 0; i < entries.length && shown < 4; i++) {
      if (Number(entries[i].timestamp) <= seenState.lastSeenMs) continue
      var app = String(entries[i].app || "").trim()
      var summary = String(entries[i].summary || "").trim()
      lines.push("  " + (app !== "" ? app + " · " : "") + (summary !== "" ? summary : "(no title)"))
      shown++
    }
    if (unseen > shown) lines.push("  …and " + (unseen - shown) + " more")
    return lines.join("\n")
  }

  // --------------------------------------------------------------- wiring
  Timer {
    interval: root.intervalMs
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshNow()
  }

  // Only drives the "8m ago" strings, so it can idle while the panel is shut.
  Timer {
    interval: root.opened ? 1000 : 60000
    running: true
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  // A toast leaving the screen is exactly the moment a row lands in history,
  // so this is what makes the count immediate rather than up-to-15s stale.
  Connections {
    target: root.svc && root.svc.popupModel ? root.svc.popupModel : null
    ignoreUnknownSignals: true
    function onCountChanged() { Qt.callLater(function () { root.refreshNow() }) }
  }

  Process {
    id: readProc
    running: false
    command: ["python3", "-c", root.readerScript, root.historyDir, root.ignorePatterns]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyOutput(text)
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text || "").trim() !== "")
        console.warn("dbarke.notifications", String(text).trim())
    }
  }

  // Only used when the service handle is unavailable.
  Process {
    id: dndProc
    running: false
    command: ["omarchy-shell", "notifications", "isDnd"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.dndFallback = String(text || "").trim() === "on"
    }
  }

  Process {
    id: actionProc
    running: false
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshNow(); return "ok" }
    function replay(): string { root.replayHistory(); return "ok" }
    function seen(): string { root.markSeen(); return "ok" }
  }

  onOpenedChanged: if (opened) {
    nowMs = Date.now()
    refreshNow()
    // Opening the panel IS reading them.
    markSeen()
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    active: root.unseen > 0 || root.dnd
    horizontalMargin: 8.75
    tooltipText: root.barTooltip
    fixedWidth: root.barVertical ? -1 : barRow.implicitWidth + button.scaledHorizontalMargin * 2

    onPressed: function (buttonCode) {
      if (buttonCode === Qt.RightButton) root.toggleDnd()
      else root.toggle()
    }

    Row {
      id: barRow
      anchors.centerIn: parent
      spacing: Style.space(6)

      Text {
        textFormat: Text.PlainText
        text: root.glyph
        color: button.active && button.useActiveColor ? button.activeColor : root.glyphColor
        font.family: button.fontFamily
        font.pixelSize: Style.bar.iconFont
        renderType: Text.NativeRendering
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        visible: !root.barVertical && root.showBadge && root.unseen > 0
        textFormat: Text.PlainText
        text: root.unseen > 99 ? "99+" : String(root.unseen)
        color: root.anyUrgent ? root.urgent : root.foreground
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
        renderType: Text.NativeRendering
        anchors.verticalCenter: parent.verticalCenter

        Behavior on color {
          enabled: !root.bar || root.bar.foregroundAnimationEnabled
          ColorAnimation { duration: 160 }
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
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onActivateRequested: root.replayHistory()
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onTextKey: function (t) {
        if (t === "r" || t === "R") root.replayHistory()
        else if (t === "c" || t === "C") root.clearHistory()
        else if (t === "d" || t === "D") root.toggleDnd()
      }
      onMoveRequested: function (dx, dy) {
        if (dy !== 0)
          panelFlick.contentY = Math.max(0, Math.min(panelFlick.contentY + dy * Style.space(56),
                                         Math.max(0, panelFlick.contentHeight - panelFlick.height)))
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelSectionHeader {
            width: parent.width
            text: root.dnd ? "SILENCED" : "RECENT"
            foreground: root.dnd ? root.urgent : root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            width: parent.width
            visible: root.dnd
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: "Do not disturb is on. Notifications are still recorded here, but no toast appears. Press d to allow them again."
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            width: parent.width
            visible: root.lastError !== "" || (root.ready && root.entries.length === 0)
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.lastError !== "" ? root.lastError : "Nothing has arrived yet."
            color: root.lastError !== "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Repeater {
            model: root.entries

            NotificationRow {
              required property var modelData
              width: column.width
              entry: modelData
            }
          }

          PanelSeparator {
            width: parent.width
            visible: root.entries.length > 0
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: "r replay as toasts · c clear · d " + (root.dnd ? "allow" : "silence")
              + "\nOmarchy keeps the last 10."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  // One archived notification: who sent it and when, its title, and as much
  // body as the setting allows.
  component NotificationRow: Column {
    id: notificationRow
    property var entry: null
    readonly property bool fresh:
      !!entry && Number(entry.timestamp) > seenState.lastSeenMs
    readonly property bool critical: !!entry && Number(entry.urgency) >= 2

    spacing: Style.space(3)

    Item {
      width: parent.width
      implicitHeight: Math.max(appText.implicitHeight, timeText.implicitHeight)

      Text {
        id: appText
        anchors.left: parent.left
        anchors.right: timeText.left
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        elide: Text.ElideRight
        text: {
          var app = notificationRow.entry ? String(notificationRow.entry.app || "").trim() : ""
          if (app === "") app = "Unknown app"
          return notificationRow.fresh ? "• " + app : app
        }
        color: notificationRow.critical ? root.urgent
          : (notificationRow.fresh ? root.foreground : root.dim)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        id: timeText
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: notificationRow.entry ? root.ago(notificationRow.entry.timestamp) : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      visible: text !== ""
      text: {
        if (!notificationRow.entry) return ""
        var summary = String(notificationRow.entry.summary || "").trim()
        return summary !== "" ? summary : "(no title)"
      }
      color: notificationRow.fresh ? root.foreground : Qt.darker(root.foreground, 1.25)
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      visible: text !== ""
      text: notificationRow.entry
        ? root.truncate(notificationRow.entry.body, root.bodyChars) : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
