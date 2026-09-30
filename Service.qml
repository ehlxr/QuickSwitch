import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "logic.js" as Logic

Item {
    id: root

    readonly property string shortAppId: "ewweberlin.quickswitch"
    readonly property real cardRadius: Math.max(Style.cornerRadius, 14)
    readonly property real stripRadius: Math.max(Style.cornerRadius * 1.5, 20)

    property bool open: false
    property var windows: []
    property var groups: []
    property int selected: 0
    property bool sawKeyEvent: false
    property bool modsHeld: false
    property string pendingAddr: ""
    property real lastRefreshTime: 0

    function next() { if (windows.length) selected = (selected + 1) % windows.length }
    function prev() { if (windows.length) selected = (selected + windows.length - 1) % windows.length }

    function openSwitcher() {
        console.log("[task-switch] openSwitcher called")
        clientsProc.running = true
    }

    function close(doFocus) {
        if (!open) return
        const entry = (doFocus && windows.length) ? windows[selected] : null
        open = false
        if (!entry) return
        pendingAddr = entry.address
        focusTimer.start()
    }

    Timer {
        id: focusTimer
        interval: 110
        onTriggered: {
            if (root.pendingAddr)
                Hyprland.dispatch('hl.dsp.focus({ window = "address:' + root.pendingAddr + '" })')
            root.pendingAddr = ""
        }
    }

    // SUPER+Q quits the highlighted app but keeps the switcher open (SUPER is
    // still held). We close via the Lua dispatcher (matches Omarchy's own
    // close-all helper) and then re-fetch the window list so the closed window
    // disappears; focus is only switched on SUPER release.
    function quitSelected() {
        const entry = windows.length ? windows[selected] : null
        if (!entry || !entry.address) return
        const addr = entry.address
        console.log("[task-switch] quitSelected addr=", addr, "cls=", entry.cls)
        root.lastRefreshTime = Date.now()
        quitProc.command = ["hyprctl", "dispatch",
            'hl.dsp.window.close({ window = "address:' + addr + '" })']
        quitProc.running = true
    }

    Process {
        id: quitProc
        stdout: StdioCollector { onStreamFinished: console.log("[task-switch] quit stdout:", text.trim()) }
        stderr: StdioCollector { onStreamFinished: console.log("[task-switch] quit stderr:", text.trim()) }
        onExited: {
            console.log("[task-switch] quitProc exited code=", exitCode)
            refreshAfterQuit.running = true
        }
    }

    // Keep the overlay mounted (open stays true) and refresh the list.
    Timer {
        id: refreshAfterQuit
        interval: 220
        onTriggered: {
            if (root.open) root.openSwitcher()
        }
    }

    // Keep the Qt-side toplevel model in sync with the compositor so that
    // reloaded/reopened windows map to a current (fresh) wayland handle. Without
    // a refresh, Hyprland.toplevels still holds the sealed toplevel of the
    // pre-reload window, so its new address isn't found and the preview reuses
    // a stale (dead) handle.
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            switch (event.name) {
            case "openwindow":
            case "closewindow":
            case "changefloatingmode":
            case "movewindow":
                Hyprland.refreshToplevels()
                break
            }
        }
    }

    GlobalShortcut {
        appid: root.shortAppId
        name: "next"
        onPressed: {
            if (root.open) {
                root.sawKeyEvent = true
                root.modsHeld = true
                root.next()
            } else {
                root.openSwitcher()
            }
        }
    }

    // Arrow keys (SUPER+Left/Right/Up/Down). The default Omarchy tiling
    // bindings consume these before they reach the overlay's exclusive
    // keyboard grab, so we intercept them here and re-dispatch: while the
    // switcher is open they cycle prev/next; when closed they restore the
    // original "focus adjacent window" behavior.
    GlobalShortcut {
        appid: root.shortAppId
        name: "focus-left"
        onPressed: {
            if (root.open) { root.sawKeyEvent = true; root.modsHeld = true; root.prev() }
            else { Hyprland.dispatch('hl.dsp.focus({ direction = "l" })') }
        }
    }

    GlobalShortcut {
        appid: root.shortAppId
        name: "focus-right"
        onPressed: {
            if (root.open) { root.sawKeyEvent = true; root.modsHeld = true; root.next() }
            else { Hyprland.dispatch('hl.dsp.focus({ direction = "r" })') }
        }
    }

    GlobalShortcut {
        appid: root.shortAppId
        name: "focus-up"
        onPressed: {
            if (root.open) { root.sawKeyEvent = true; root.modsHeld = true; root.prev() }
            else { Hyprland.dispatch('hl.dsp.focus({ direction = "u" })') }
        }
    }

    GlobalShortcut {
        appid: root.shortAppId
        name: "focus-down"
        onPressed: {
            if (root.open) { root.sawKeyEvent = true; root.modsHeld = true; root.next() }
            else { Hyprland.dispatch('hl.dsp.focus({ direction = "d" })') }
        }
    }

    Process {
        id: clientsProc
        command: ["hyprctl", "-j", "clients"]
        stdout: StdioCollector {
            onStreamFinished: {
                let clients = []
                try { clients = JSON.parse(text) } catch (e) { return }
                fillWindows(clients)
            }
        }
    }

    function fillWindows(clients) {
        console.log("[task-switch] fillWindows called, n=", Array.isArray(clients) ? clients.length : "not-array")
        if (!Array.isArray(clients)) return
        const ordered = Logic.orderClients(clients)
        if (!ordered.length) return

        const byAddr = {}
        for (const tl of (Hyprland.toplevels.values || [])) {
            const ipc = tl.lastIpcObject
            if (ipc && ipc.address) byAddr[ipc.address] = tl
        }

        const cache = {}
        for (const w of root.windows) cache[w.address] = w

        const records = []
        for (const c of ordered) {
            const addr = c.address
            const tl = byAddr[addr]
            const prev = cache[addr]
            const rec = prev && !prev.dead ? prev : {
                address: addr,
                cls: c.class || c.initialClass || "",
                title: c.title || "-",
                workspaceId: c.workspace ? c.workspace.id : -1,
                workspaceName: c.workspace ? c.workspace.name : "-",
                fhid: c.focusHistoryID === undefined ? 0 : c.focusHistoryID,
                dead: false,
                handle: null
            }
            rec.handle = tl ? tl.wayland : null
            rec.title = c.title || "-"
            rec.cls = c.class || c.initialClass || ""
            rec.workspaceId = c.workspace ? c.workspace.id : rec.workspaceId
            rec.workspaceName = c.workspace ? c.workspace.name : rec.workspaceName
            records.push(rec)
        }

        root.windows = records
        root.groups = Logic.groupByWorkspace(ordered)
        root.selected = 0
        root.sawKeyEvent = false
        root.modsHeld = false
        root.open = true
    }

    function iconPathFor(cls, title) {
        return Logic.iconPathFor(DesktopEntries, Quickshell, cls, title)
    }

    LazyLoader {
        id: loader
        active: root.open
        PanelWindow {
            id: panel

                property bool mouseInside: true
                property bool hoverArmed: false
                property point initialPos: Qt.point(-1, -1)

                WlrLayershell.layer: WlrLayer.Overlay
                WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
                WlrLayershell.namespace: root.shortAppId
                exclusionMode: ExclusionMode.Ignore
                color: "transparent"
                anchors { top: true; bottom: true; left: true; right: true }

                function activate() { root.close(panel.mouseInside) }

                Timer {
                    id: noKeyTimer
                    interval: 150
                    repeat: true
                    running: true
                    onTriggered: {
                        if (root.sawKeyEvent) {
                            if (root.modsHeld) stop()
                            else panel.activate()
                        } else {
                            modCheck.running = true
                        }
                    }
                }

                Process {
                    id: modCheck
                    command: ["hyprctl", "eval",
                        'error(tostring(hl.is_key_down("Super_L") or hl.is_key_down("Super_R")))']
                    stdout: StdioCollector {
                        onStreamFinished: {
                            if (!root.open || root.sawKeyEvent) return
                            if (!text.trim().endsWith("true"))
                                panel.activate()
                        }
                    }
                }

                Rectangle {
                    anchors.fill: parent
                    color: Color.menu.scrim
                }

                // Clicking empty space dismisses without switching focus.
                MouseArea {
                    anchors.fill: parent
                    onClicked: root.close(false)
                }

                // Centered horizontal strip (macOS app-switcher style).
                Item {
                    id: stripWrap
                    anchors.centerIn: parent
                    width: strip.width
                    height: strip.height
                    focus: true
                    Keys.priority: Keys.BeforeItem

                    BorderSurface {
                        id: stripBg
                        anchors.fill: strip
                        radius: root.stripRadius
                        color: Color.popups.background
                        borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, 2)
                    }

                    Flow {
                        id: strip
                        anchors.centerIn: parent
                        padding: Style.spacing.panelPadding
                        spacing: Style.spacing.panelPadding
                        z: 2

                        readonly property real contentWidth: {
                            const n = root.windows.length
                            if (!n) return 0
                            const spacing = Style.spacing.panelPadding
                            const cardW = 180
                            const maxCards = Math.floor((panel.width * 0.85 - 2 * padding + spacing) / (cardW + spacing))
                            return 2 * padding + Math.min(n, maxCards) * cardW + Math.max(0, Math.min(n, maxCards) - 1) * spacing
                        }
                        width: contentWidth

                        Repeater {
                            model: root.windows

                            delegate: Item {
                                required property int index
                                readonly property var win: root.windows[index]
                                readonly property bool isSelected: root.selected === index

                                width: 180
                                height: 130
                                z: isSelected ? 10 : (hover.hovered ? 5 : 1)

                                scale: isSelected ? 1.08 : (hover.hovered ? 1.03 : 1.0)
                                opacity: isSelected ? 1.0 : (hover.hovered ? 0.9 : 0.6)
                                transformOrigin: Item.Center

                                Behavior on scale {
                                    NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                                }
                                Behavior on opacity {
                                    NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                                }

                                // Outer accent glow/ring to highlight the selected window
                                Rectangle {
                                    id: selectionGlow
                                    anchors.fill: parent
                                    anchors.margins: -4
                                    radius: root.cardRadius + 4
                                    color: "transparent"
                                    border.color: isSelected ? Qt.alpha(Color.accent, 0.45) : "transparent"
                                    border.width: 3
                                    visible: isSelected
                                    z: 0

                                    Behavior on border.color {
                                        ColorAnimation { duration: 120 }
                                    }
                                }

                                BorderSurface {
                                    id: frame
                                    anchors.fill: parent
                                    radius: root.cardRadius
                                    color: Color.popups.background
                                    clip: true
                                    borderSpec: Border.surfaceSpec(
                                        "popups", "border",
                                        isSelected ? Color.accent : (hover.hovered ? Qt.alpha(Color.accent, 0.6) : Color.popups.border),
                                        isSelected ? 3 : 2)

                                    // Shape mask for card contents to clip cleanly to rounded corners
                                    Item {
                                        id: cardMask
                                        anchors.fill: parent
                                        visible: false
                                        layer.enabled: true

                                        Rectangle {
                                            anchors.fill: parent
                                            radius: root.cardRadius
                                            color: "white"
                                        }
                                    }

                                    Item {
                                        id: cardContent
                                        anchors.fill: parent
                                        layer.enabled: true
                                        layer.smooth: true
                                        layer.effect: MultiEffect {
                                            maskEnabled: true
                                            maskSource: cardMask
                                            maskThresholdMin: 0.3
                                            maskSpreadAtMin: 0.3
                                        }

                                        // Snapshot taken while the switcher opens. The
                                        // screencopy recording context takes a moment to
                                        // establish, and its first delivered buffer is
                                        // often empty/uninitialized. So: keep requesting
                                        // frames while open, and once the first content
                                        // frame arrives keep grabbing a short "settle"
                                        // burst so a real (populated) frame replaces the
                                        // blank one, then freeze. Cards are recreated
                                        // fresh on every open (the panel is torn down when
                                        // closed), so there is no cache across opens.
                                        ScreencopyView {
                                            id: thumb
                                            anchors.fill: parent
                                            anchors.margins: isSelected ? 3 : 2
                                            z: 1
                                            captureSource: win ? win.handle : null
                                            live: false
                                            paintCursor: false
                                            visible: win && win.handle && hasContent

                                            // Whether a real snapshot has been frozen for
                                            // this open. Reset automatically because the
                                            // card is recreated fresh on each open.
                                            property bool frozen: false
                                            property int settleTicks: 0

                                            // Grab a frame as soon as a source is set
                                            // (kicks off context setup immediately).
                                            onCaptureSourceChanged: {
                                                if (thumb.captureSource) {
                                                    thumb.captureFrame()
                                                    thumb.settleTicks = 0
                                                    thumb.frozen = false
                                                }
                                            }

                                            // Runs whenever the switcher is open and a
                                            // source exists — driver via a bound
                                            // `running`, so a freshly-added window whose
                                            // onCaptureSourceChanged may not fire still
                                            // gets captured. Stops after a settle burst
                                            // once real content is present.
                                            Timer {
                                                id: grabber
                                                interval: 90
                                                repeat: true
                                                running: root.open && !!thumb.captureSource && !thumb.frozen
                                                onTriggered: {
                                                    thumb.captureFrame()
                                                    if (thumb.hasContent) {
                                                        thumb.settleTicks += 1
                                                        if (thumb.settleTicks >= 4) {
                                                            thumb.frozen = true
                                                            thumb.settleTicks = 0
                                                        }
                                                    }
                                                }
                                            }
                                        }

                                        // Fallback while content loads / when a window
                                        // can't be captured: dim area + centered icon.
                                        Rectangle {
                                            anchors.fill: parent
                                            color: Qt.alpha(Color.foreground, 0.05)
                                        }

                                        Rectangle {
                                            id: captureFallback
                                            anchors.fill: parent
                                            visible: !thumb.visible
                                            color: Color.popups.background

                                            Image {
                                                anchors.centerIn: parent
                                                width: 64
                                                height: 64
                                                sourceSize.width: 64
                                                sourceSize.height: 64
                                                fillMode: Image.PreserveAspectFit
                                                source: win ? root.iconPathFor(win.cls, win.title) : ""
                                            }
                                        }

                                        // Subtle accent highlight wash over preview when selected
                                        Rectangle {
                                            anchors.fill: parent
                                            color: Color.accent
                                            opacity: isSelected ? 0.08 : 0
                                            visible: isSelected
                                            z: 2
                                        }
                                    }

                                    Rectangle {
                                        id: iconBadge
                                        anchors.left: parent.left
                                        anchors.top: parent.top
                                        anchors.margins: Style.spacing.md
                                        width: 44
                                        height: 44
                                        radius: 10
                                        color: Qt.rgba(0, 0, 0, 0.5)
                                        border.color: Qt.rgba(255, 255, 255, 0.15)
                                        border.width: 1
                                        z: 4

                                        Image {
                                            anchors.centerIn: parent
                                            width: 30
                                            height: 30
                                            sourceSize.width: 30
                                            sourceSize.height: 30
                                            fillMode: Image.PreserveAspectFit
                                            source: win ? root.iconPathFor(win.cls, win.title) : ""
                                        }
                                    }

                                    // Top border overlay to ensure rounded border is never obscured
                                    Rectangle {
                                        id: topBorderOverlay
                                        anchors.fill: parent
                                        radius: root.cardRadius
                                        color: "transparent"
                                        border.color: isSelected ? Color.accent : (hover.hovered ? Qt.alpha(Color.accent, 0.6) : Color.popups.border)
                                        border.width: isSelected ? 3 : 2
                                        z: 5
                                    }
                                }

                                HoverHandler {
                                    id: hover
                                    onHoveredChanged: {
                                        if (hovered) root.selected = index
                                    }
                                }

                                TapHandler {
                                    onTapped: {
                                        root.selected = index
                                        root.close(true)
                                    }
                                }
                            }
                        }
                    }

                    Rectangle {
                        id: titlePill
                        anchors.horizontalCenter: strip.horizontalCenter
                        anchors.top: strip.bottom
                        anchors.topMargin: Style.spacing.lg
                        visible: root.windows.length > 0 && !!root.windows[root.selected].title
                        height: titleLabel.implicitHeight + Style.spacing.sm * 2
                        width: Math.min(titleLabel.implicitWidth + Style.spacing.lg * 2, Math.max(strip.width, 360), 680)
                        radius: height / 2
                        color: Color.popups.background
                        border.color: Color.popups.border
                        border.width: 1

                        Text {
                            id: titleLabel
                            anchors.centerIn: parent
                            width: parent.width - Style.spacing.lg * 2
                            maximumLineCount: 1
                            elide: Text.ElideRight
                            horizontalAlignment: Text.AlignHCenter
                            text: root.windows.length ? root.windows[root.selected].title : ""
                            color: Color.popups.text
                            font.family: Style.font.family
                            font.pixelSize: Style.font.body
                            font.weight: Font.DemiBold
                        }
                    }

                    // Keyboard navigation. The exclusive keyboard grab keeps
                    // keyboard events flowing here while SUPER is held. Any key
                    // reaching here means SUPER is still held (otherwise the
                    // release/noKeyTimer path would have already closed it), so
                    // mark the modifier as held for every key press.
                    Keys.onPressed: (event) => {
                        root.sawKeyEvent = true
                        root.modsHeld = true
                        if (event.key === Qt.Key_Escape) {
                            root.close(false)
                            event.accepted = true
                            return
                        }
                        // SUPER+Q quits the highlighted app. Being inside the
                        // exclusive grab already means SUPER is held, so don't
                        // rely on event.modifiers (which isn't reliably set).
                        if (event.key === Qt.Key_Q || event.key === Qt.Key_q) {
                            root.quitSelected()
                            event.accepted = true
                            return
                        }
                        if (event.key === Qt.Key_Tab || event.key === Qt.Key_Right || event.key === Qt.Key_Down) {
                            root.next()
                            event.accepted = true
                        } else if (event.key === Qt.Key_Backtab || event.key === Qt.Key_Left || event.key === Qt.Key_Up) {
                            root.prev()
                            event.accepted = true
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                            panel.activate()
                            event.accepted = true
                        }
                    }

                    Keys.onReleased: (event) => {
                        root.sawKeyEvent = true
                        const superReleasing = event.key === Qt.Key_Meta
                            || event.key === Qt.Key_Super_L || event.key === Qt.Key_Super_R
                        // event.modifiers is NOT reliably set through the
                        // exclusive grab (see the onPressed handler), so it
                        // must not gate closing. Releasing a non-SUPER key
                        // (Q, TAB, arrows) while the grab is active means
                        // SUPER is still held — keep the switcher open. Only
                        // an actual SUPER key release closes it.
                        if (superReleasing) {
                            // Closing a window can briefly disrupt the keyboard
                            // grab and deliver a synthetic SUPER release; ignore
                            // it right after a quit so the strip survives.
                            if (Date.now() - root.lastRefreshTime < 200) return
                            root.modsHeld = false
                            panel.activate()
                        } else {
                            root.modsHeld = true
                        }
                    }

                    HoverHandler {
                        onHoveredChanged: panel.mouseInside = hovered
                    }

                    Component.onCompleted: forceActiveFocus()
                }
            }
    }
}
