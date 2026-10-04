// Threads — notification center with true per-conversation grouping.
//
// The stock service strips every hint except omarchy-glyph/omarchy-exec before
// anything downstream sees a notification, so no consumer of it can tell two
// WhatsApp groups apart. This plugin never reads the stock service: it watches
// the session bus itself (bin/thread-watch), which still carries the full
// Notify payload — x-dunst-stack-tag / x-kde-eventId and friends. Groups are
// keyed by those hints, falling back to app+summary (chat apps put the
// conversation name there), then app.
//
// Storage is a JSON archive under $XDG_STATE_HOME/omarchy/thread-center/,
// managed by bin/thread-store. Per-entry and per-thread delete are permanent:
// nothing re-reads the pipeline after removal, so a dismissed conversation
// never comes back. This is a passive observer — it runs beside the stock
// daemon (or any other) and never owns org.freedesktop.Notifications.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "ThreadLogic.js" as ThreadLogic

Panel {
  id: root

  moduleName: "cad0p.thread-center"
  ipcTarget: "cad0p.thread-center"

  // The bar slot sizes from the widget's implicit size (see
  // panels/audio/Panel.qml for the same pattern); without this the slot is
  // 0-wide and the bell never renders.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Injected by the shell's plugin loader.
  property string omarchyPath: ""

  // Resolved against this QML file so the plugin works from any install
  // location (user plugin dir, symlinked dev checkout, ...).
  readonly property string storeBin: Qt.resolvedUrl("bin/thread-store").toString().replace(/^file:\/\//, "")
  readonly property string watchBin: Qt.resolvedUrl("bin/thread-watch").toString().replace(/^file:\/\//, "")

  readonly property string uiFont: bar && bar.fontFamily ? bar.fontFamily : Style.font.family
  readonly property color textColor: Color.popups.text
  readonly property color dimColor: Qt.darker(Color.popups.text, 1.4)
  readonly property string fallbackGrouping: String(setting("fallbackGrouping", "summary"))

  // Archive entries, newest first. Every producer replaces the array (never
  // mutates), so bindings below re-evaluate on each change.
  property var entries: []
  property real readMark: 0
  property string searchQuery: ""
  // threadKey -> true for every thread the user expanded.
  property var expanded: ({})
  // Index into `flat`, the keyboard cursor's row list.
  property int cursorIndex: 0

  readonly property var threads: ThreadLogic.groupRows(entries, {
    query: searchQuery,
    readMark: readMark
  })
  readonly property var flat: ThreadLogic.flattenRows(threads, expanded)
  readonly property var cursorRow: cursorIndex >= 0 && cursorIndex < flat.length ? flat[cursorIndex] : null
  readonly property int unread: ThreadLogic.unreadCount(entries, readMark)

  onFlatChanged: {
    if (flat.length === 0) {
      cursorIndex = 0
    } else if (cursorIndex >= flat.length) {
      cursorIndex = flat.length - 1
    }
  }

  function iconSource(icon) {
    var value = String(icon || "")
    if (value.length === 0) return ""
    // A Chromium-family temp badge dies with the notification; never draw one.
    if (value.indexOf("/tmp/org.chromium.") >= 0) return ""
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return Util.fileUrl(value)
    return Quickshell.iconPath(value, true)
  }

  function findEntry(key) {
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].key === key) return entries[i]
    }
    return null
  }

  function cursorIndexOf(kind, key) {
    for (var i = 0; i < flat.length; i++) {
      var row = flat[i]
      if (row.kind !== kind) continue
      if (kind === "thread" && row.threadKey === key) return i
      if (kind === "entry" && row.entryKey === key) return i
    }
    return -1
  }

  function toggleThread(key) {
    var next = {}
    for (var k in expanded) next[k] = expanded[k]
    if (next[key]) delete next[key]
    else next[key] = true
    expanded = next
  }

  function removeEntry(key) {
    var dismissed = entries.filter(function(e) { return e.key === key })
    dismissLiveToasts(ThreadLogic.dismissSummaries(dismissed))
    entries = entries.filter(function(e) { return e.key !== key })
    queueStore(["remove", String(key)])
  }

  function removeThread(key) {
    dismissLiveToasts(ThreadLogic.dismissSummaries(entries.filter(function(e) { return e.threadKey === key })))
    entries = entries.filter(function(e) { return e.threadKey !== key })
    var next = {}
    for (var k in expanded) if (k !== key) next[k] = expanded[k]
    expanded = next
    queueStore(["remove-thread", String(key)])
  }

  function clearAll() {
    entries = []
    expanded = ({})
    queueStore(["clear"])
  }

  // Dismissing a conversation should take its live toasts off the screen too:
  // the daemon matches on the summary, which is the chat name for web apps and
  // the subject for mail. A miss answers "none" and costs nothing.
  function dismissLiveToasts(summaries) {
    if (!summaries || summaries.length === 0) return
    var bin = omarchyPath ? omarchyPath + "/bin/omarchy-shell" : "omarchy-shell"
    for (var i = 0; i < summaries.length; i++)
      Quickshell.execDetached([bin, "notifications", "dismiss", summaries[i]])
  }

  // Focus the sending window, trying each target in order: web source host
  // first, then the app id. Each step only runs when the previous one found
  // no window. Returns false when the entry has nothing to focus.
  function focusEntryWindow(entry) {
    var targets = ThreadLogic.focusTargets(entry)
    if (targets.length === 0 || !omarchyPath) return false
    var bin = Util.shellQuote(omarchyPath + "/bin/omarchy-hyprland-focus-app")
    Util.execDetached(targets.map(function(target) {
      return bin + " " + Util.shellQuote(target)
    }).join(" || "))
    return true
  }

  function openLinkOrFocus(entry) {
    var link = String((entry && entry.link) || "") || ThreadLogic.firstLink(entry)
    // A Chromium web notification's archived link is only the app origin
    // (https://web.whatsapp.com/): opening it reloads the PWA at its root.
    // Focus the sending window instead; real deep links still open below.
    if (ThreadLogic.isWebOrigin(entry) && focusEntryWindow(entry)) return
    if (link) {
      Quickshell.execDetached(["xdg-open", link])
      return
    }
    focusEntryWindow(entry)
  }

  // Prefer the sender's live "default" action: for Chromium web apps the
  // chat/message jump only exists while the popup is alive and carries no URL,
  // so the archived link can only reopen the app root. Fall back when the
  // notification is already gone (the IPC answers "none").
  function focusEntry(entry) {
    if (entry && ThreadLogic.canInvokeLive(entry)) {
      liveInvokeEntry = entry
      liveInvokeResult = ""
      liveInvokeProc.command = [
        (omarchyPath ? omarchyPath + "/bin/omarchy-shell" : "omarchy-shell"),
        "omapager", "invoke", String(entry.id), "default"
      ]
      liveInvokeProc.running = true
      return
    }
    openLinkOrFocus(entry)
  }

  property var liveInvokeEntry: null
  property string liveInvokeResult: ""

  Process {
    id: liveInvokeProc
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.liveInvokeResult = String(text || "").trim()
    }
    onExited: liveInvokeFallback.restart()
  }

  // The collector may finish before or after onExited; let the result settle
  // briefly so a successful invoke never also opens the fallback link.
  Timer {
    id: liveInvokeFallback
    interval: 300
    onTriggered: {
      var entry = root.liveInvokeEntry
      root.liveInvokeEntry = null
      // Any non-empty answer that isn't "none" means the live action fired;
      // an empty answer (IPC missing or failed) falls back to the link.
      var result = String(root.liveInvokeResult || "").toLowerCase()
      if (result === "" || result === "none") {
        if (entry) root.openLinkOrFocus(entry)
      }
    }
  }

  function moveCursor(dy) {
    if (flat.length === 0) return
    cursorIndex = Math.max(0, Math.min(flat.length - 1, cursorIndex + dy))
  }

  function activateCursor() {
    var row = cursorRow
    if (!row) return
    if (row.kind === "thread") {
      toggleThread(row.threadKey)
      return
    }
    var entry = findEntry(row.entryKey)
    if (entry) focusEntry(entry)
  }

  function deleteCursor() {
    var row = cursorRow
    if (!row) return
    if (row.kind === "thread") removeThread(row.threadKey)
    else removeEntry(row.entryKey)
  }

  function markRead() {
    var now = Date.now()
    readMark = now
    queueStore(["mark-read", String(now)])
  }

  function reload() {
    loadProc.running = true
    metaProc.running = true
  }

  // ------------------------------------------------------------- store queue
  //
  // Every mutation goes through one serialized Process so an upsert from the
  // watcher can never interleave with a delete from the UI. The store itself
  // locks too; this just keeps argv order deterministic.

  property var storeQueue: []
  property var runningStoreJob: null

  function queueStore(args, done) {
    storeQueue = storeQueue.concat([{ args: args, done: done || null }])
    runStoreJob()
  }

  function runStoreJob() {
    if (storeProc.running || storeQueue.length === 0) return
    runningStoreJob = storeQueue[0]
    storeQueue = storeQueue.slice(1)
    storeProc.command = [storeBin].concat(runningStoreJob.args)
    storeProc.running = true
  }

  Process {
    id: storeProc
    running: false
    onExited: {
      var job = root.runningStoreJob
      root.runningStoreJob = null
      if (job && job.done) job.done()
      root.runStoreJob()
    }
  }

  // --------------------------------------------------------------- watcher

  function onWatcherLine(line) {
    var text = String(line || "").trim()
    if (!text.length) return
    var event
    try {
      event = JSON.parse(text)
    } catch (e) {
      return
    }
    if (!event || !event.event) return

    if (event.event === "notify") {
      var next = ThreadLogic.applyEvent(entries, event, { fallbackGrouping: fallbackGrouping })
      var entry = next[0]
      entries = next
      queueStore(["upsert", JSON.stringify(entry)])
      // Watching the panel counts as reading: the badge must not grow under
      // the user's eyes for notifications they are looking at right now.
      if (opened) markRead()
    } else if (event.event === "id") {
      var id = Number(event.id || 0)
      if (id <= 0) return
      entries = ThreadLogic.applyId(entries, event.sender, event.cookie, id)
      queueStore(["set-id", String(event.sender || ""), String(event.cookie), String(id)])
    }
  }

  Process {
    id: watcher
    command: [root.watchBin]
    running: false
    stdout: SplitParser {
      onRead: function(line) { root.onWatcherLine(line) }
    }
    onExited: watcherRestart.restart()
  }

  Timer {
    id: watcherRestart
    interval: 2000
    repeat: false
    onTriggered: watcher.running = true
  }

  // ---------------------------------------------------------------- loading

  Process {
    id: loadProc
    command: [root.storeBin, "load"]
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.entries = ThreadLogic.parseArchive(text)
    }
  }

  Process {
    id: metaProc
    command: [root.storeBin, "meta"]
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var state = ThreadLogic.parseState(text)
        root.readMark = Number(state.readMark || 0)
      }
    }
  }

  onOpenedChanged: {
    if (opened) {
      cursorIndex = 0
      // Re-read from disk: the watcher may have been restarted (or the
      // archive changed while the panel was closed), and the panel must not
      // show a stale snapshot in that case.
      reload()
      markRead()
      Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
    }
  }

  Component.onCompleted: {
    loadProc.running = true
    metaProc.running = true
    watcher.running = true
  }

  // ------------------------------------------------------------ bar button

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰂚"
    tooltipText: "Threads"

    onPressed: root.opened ? root.close() : root.open()
  }

  Rectangle {
    id: badge
    visible: root.unread > 0
    anchors.right: button.right
    anchors.top: button.top
    width: Math.max(Style.space(13), badgeLabel.implicitWidth + Style.space(5))
    height: Style.space(13)
    radius: height / 2
    color: Color.urgent
    z: 2

    Text {
      id: badgeLabel
      anchors.centerIn: parent
      text: root.unread > 99 ? "99+" : String(root.unread)
      color: Color.popups.background
      font.family: root.uiFont
      font.pixelSize: Style.font.caption
    }
  }

  // ------------------------------------------------------------ the panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: searchField.activeFocus

      onMoveRequested: function(dx, dy) { root.moveCursor(dy) }
      onActivateRequested: root.activateCursor()
      onDeleteRequested: root.deleteCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "/") {
          searchField.forceActiveFocus()
        } else if (t === "c") {
          root.clearAll()
        } else if (t === "r") {
          root.reload()
        }
      }

      ColumnLayout {
        id: column
        anchors.fill: parent
        spacing: Style.space(6)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          Text {
            text: "Threads"
            color: root.textColor
            font.family: root.uiFont
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            visible: root.flat.length > 0
            text: String(root.flat.length)
            color: root.dimColor
            font.family: root.uiFont
            font.pixelSize: Style.font.caption
          }

          Item { Layout.fillWidth: true }

          TextField {
            id: searchField
            Layout.preferredWidth: Style.space(140)
            placeholderText: "Search"
            onTextChanged: root.searchQuery = text
            // Esc leaves the field instead of closing the panel, so a bad
            // search can be cleared without losing the whole popup.
            Keys.onEscapePressed: function(event) {
              text = ""
              root.searchQuery = ""
              keyCatcher.forceActiveFocus()
              event.accepted = true
            }
          }

          PanelActionButton {
            iconText: "󰅖"
            tooltipText: "Clear all"
            foreground: root.dimColor
            hoverColor: Color.urgent
            onClicked: root.clearAll()
          }
        }

        Flickable {
          id: threadList
          Layout.fillWidth: true
          Layout.preferredHeight: root.threads.length === 0
            ? Style.space(40)
            : Math.min(threadColumn.implicitHeight, Style.space(430))
          contentHeight: threadColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          Column {
            id: threadColumn
            width: threadList.width
            spacing: Style.space(2)

            Text {
              visible: root.threads.length === 0
              width: parent.width
              text: root.searchQuery.length > 0 ? "No matches" : "No notifications"
              color: root.dimColor
              font.family: root.uiFont
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
              topPadding: Style.space(8)
            }

            Repeater {
              model: root.threads

              delegate: Column {
                id: threadItem
                required property var modelData
                required property int index

                readonly property var thread: modelData
                readonly property bool isExpanded: !!root.expanded[thread.threadKey]
                readonly property bool isCursor: root.cursorRow
                  && root.cursorRow.kind === "thread"
                  && root.cursorRow.threadKey === thread.threadKey

                width: threadColumn.width
                spacing: 0

                Rectangle {
                  id: threadHeader
                  width: parent.width
                  height: threadRow.implicitHeight + Style.space(8)
                  radius: Style.cornerRadius
                  color: threadItem.isCursor
                    ? Style.controlFill(true, false, root.textColor, Color.accent)
                    : (threadHover.hovered
                      ? Style.controlFill(false, true, root.textColor, Color.accent)
                      : "transparent")

                  HoverHandler { id: threadHover }

                  MouseArea {
                    anchors.fill: parent
                    onClicked: {
                      var at = root.cursorIndexOf("thread", threadItem.thread.threadKey)
                      if (at >= 0) root.cursorIndex = at
                      root.toggleThread(threadItem.thread.threadKey)
                    }
                  }

                  RowLayout {
                    id: threadRow
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Style.space(8)
                    anchors.rightMargin: Style.space(4)
                    spacing: Style.space(8)

                    Item {
                      Layout.preferredWidth: Style.space(18)
                      Layout.preferredHeight: Style.space(18)

                      Image {
                        id: threadIcon
                        anchors.fill: parent
                        source: root.iconSource(threadItem.thread.icon || threadItem.thread.appIcon)
                        fillMode: Image.PreserveAspectFit
                        visible: status === Image.Ready
                      }

                      Text {
                        anchors.centerIn: parent
                        visible: !threadIcon.visible
                        text: "󰂚"
                        color: root.dimColor
                        font.family: root.uiFont
                        font.pixelSize: Style.font.body
                      }
                    }

                    ColumnLayout {
                      Layout.fillWidth: true
                      spacing: 0

                      Text {
                        Layout.fillWidth: true
                        text: threadItem.thread.label
                        color: root.textColor
                        font.family: root.uiFont
                        font.pixelSize: Style.font.body
                        font.bold: threadItem.thread.unread > 0
                        elide: Text.ElideRight
                        maximumLineCount: 1
                      }

                      Text {
                        Layout.fillWidth: true
                        visible: text.length > 0
                        text: threadItem.thread.preview || threadItem.thread.app
                        color: root.dimColor
                        font.family: root.uiFont
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                        maximumLineCount: 1
                      }
                    }

                    Rectangle {
                      visible: threadItem.thread.count > 1
                      Layout.preferredWidth: Math.max(Style.space(16), countLabel.implicitWidth + Style.space(6))
                      Layout.preferredHeight: Style.space(14)
                      radius: height / 2
                      color: threadItem.thread.unread > 0 ? Color.accent : root.dimColor

                      Text {
                        id: countLabel
                        anchors.centerIn: parent
                        text: String(threadItem.thread.count)
                        color: Color.popups.background
                        font.family: root.uiFont
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }
                    }

                    Text {
                      text: ThreadLogic.relativeTime(threadItem.thread.latest)
                      color: root.dimColor
                      font.family: root.uiFont
                      font.pixelSize: Style.font.caption
                    }

                    Text {
                      text: threadItem.isExpanded ? "󰅃" : "󰅀"
                      color: root.dimColor
                      font.family: root.uiFont
                      font.pixelSize: Style.font.caption
                    }

                    PanelActionButton {
                      iconText: "󰅖"
                      tooltipText: "Dismiss conversation"
                      foreground: root.dimColor
                      hoverColor: Color.urgent
                      onClicked: root.removeThread(threadItem.thread.threadKey)
                    }
                  }
                }

                Repeater {
                  model: threadItem.isExpanded ? threadItem.thread.entries : []

                  delegate: Rectangle {
                    id: entryRow
                    required property var modelData

                    readonly property var entry: modelData
                    readonly property bool isCursor: root.cursorRow
                      && root.cursorRow.kind === "entry"
                      && root.cursorRow.entryKey === entry.key

                    width: threadItem.width
                    height: entryColumn.implicitHeight + Style.space(6)
                    radius: Style.cornerRadius
                    color: entryRow.isCursor
                      ? Style.controlFill(true, false, root.textColor, Color.accent)
                      : (entryHover.hovered
                        ? Style.controlFill(false, true, root.textColor, Color.accent)
                        : "transparent")

                    HoverHandler { id: entryHover }

                    MouseArea {
                      anchors.fill: parent
                      onClicked: {
                        var at = root.cursorIndexOf("entry", entryRow.entry.key)
                        if (at >= 0) root.cursorIndex = at
                        root.focusEntry(entryRow.entry)
                      }
                    }

                    RowLayout {
                      id: entryColumn
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      anchors.leftMargin: Style.space(34)
                      anchors.rightMargin: Style.space(4)
                      spacing: Style.space(8)

                      ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0

                        Text {
                          Layout.fillWidth: true
                          text: entryRow.entry.summary || entryRow.entry.app
                          color: root.textColor
                          font.family: root.uiFont
                          font.pixelSize: Style.font.bodySmall
                          elide: Text.ElideRight
                          maximumLineCount: 1
                        }

                        Text {
                          Layout.fillWidth: true
                          visible: text.length > 0
                          text: ThreadLogic.plainBody(entryRow.entry.body)
                          color: root.dimColor
                          font.family: root.uiFont
                          font.pixelSize: Style.font.caption
                          wrapMode: Text.Wrap
                          maximumLineCount: 2
                          elide: Text.ElideRight
                          textFormat: Text.PlainText
                        }
                      }

                      Text {
                        text: ThreadLogic.relativeTime(entryRow.entry.timestamp)
                        color: root.dimColor
                        font.family: root.uiFont
                        font.pixelSize: Style.font.caption
                      }

                      PanelActionButton {
                        iconText: "󰅖"
                        tooltipText: "Dismiss"
                        foreground: root.dimColor
                        hoverColor: Color.urgent
                        onClicked: root.removeEntry(entryRow.entry.key)
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
