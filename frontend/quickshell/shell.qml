import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root

    property string configPath: Quickshell.env("CRONBAR_CONFIG") || ((Quickshell.env("HOME") || "") + "/.config/cronbar/config.json")
    property string stateDir: Quickshell.env("CRONBAR_STATE_DIR") || ((Quickshell.env("HOME") || "") + "/.local/state/cronbar")
    property string cronbarBin: Quickshell.env("CRONBAR_BIN") || "cronbar"
    property string snapshotPath: stateDir + "/snapshot.json"
    property string uiPath: stateDir + "/ui.json"
    property string eventPath: stateDir + "/state-event.json"
    property string runsPath: stateDir + "/runs.json"
    property string textFont: "Fira Code"
    property string iconFont: "Symbols Nerd Font Mono"

    property var viewData: snapshotAdapter.view && snapshotAdapter.view.summary ? snapshotAdapter.view : ({ summary: {}, surfaces: [], jobs: [], errors: [] })
    property var summary: viewData.summary || ({})
    property var surfaces: viewData.surfaces || []
    property var jobs: viewData.jobs || []
    property var errors: viewData.errors || []
    property var runList: {
        var runs = runsAdapter.runs
        return (runs && runs.length !== undefined) ? runs : []
    }

    property var alerts: viewData.alerts || []
    // Safe accessor: before the first snapshot lands, viewData.statusChip is
    // undefined and a bare .tone read warns every frame.
    readonly property var statusChip: viewData.statusChip || ({ text: "loading", tone: "muted" })
    property bool narrowLayout: panel.width < 720
    // Viewport arithmetic, never panel.height: the panel's height derives from
    // panelHeight() (which reads this flag), so measuring the flag from the
    // panel's own height would tie a binding loop.
    property bool shortViewport: ((root.panelScreen() ? root.panelScreen().height : 900) - (root.panelTopMargin || 52) - 12) < 560
    property string narrowPanelView: "jobs"

    property string filterText: ""
    property string surfaceFilter: "all"
    property var selectedJob: null
    property string runPass: ""
    property bool runDry: false
    property bool confirmArmed: false
    property string lastRunResult: ""
    property bool historyOpen: false

    // Omarchy theme wiring: live-follows the active Omarchy theme palette
    // (the same colors.toml the Omarchy shell reads). Falls back to the
    // built-in palette where a key is absent or Omarchy is not running.
    property string themeColorsPath: Quickshell.env("OMARCHY_THEME_COLORS") || ((Quickshell.env("HOME") || "") + "/.local/state/omarchy/current/theme/colors.toml")
    property var themePalette: ({})

    function applyThemeColors(raw) {
        var parsed = {}
        var lines = String(raw || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
            var match = lines[i].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
            if (match)
                parsed[match[1]] = match[2]
        }
        root.themePalette = parsed
    }

    function themeColor(key, fallback) {
        var value = root.themePalette[key]
        return (typeof value === "string" && value.length > 0) ? value : fallback
    }

    readonly property QtObject theme: QtObject {
        readonly property color bg: root.themeColor("background", "#0B0C16")
        readonly property color bgDeep: root.themeColor("dark_background", "#050711")
        readonly property color surface: root.themeColor("lighter_background", "#151927")
        readonly property color surfaceAlt: root.themeColor("selection", "#10131F")
        readonly property color border: root.themeColor("muted", "#2E344A")
        readonly property color borderSoft: root.themeColor("muted", "#26304A")
        readonly property color borderFaint: root.themeColor("selection", "#252B3F")
        readonly property color text: root.themeColor("bright_foreground", "#DDF7FF")
        readonly property color textMuted: root.themeColor("dark_foreground", "#6A6E95")
        readonly property color good: root.themeColor("green", "#82FB9C")
        readonly property color goodSoft: root.themeColor("bright_green", "#9CF7C2")
        readonly property color info: root.themeColor("bright_cyan", "#85E1FB")
        readonly property color warn: root.themeColor("yellow", "#F2C572")
        readonly property color bad: root.themeColor("red", "#E06C75")
    }

    FileView {
        id: themeFile
        path: root.themeColorsPath
        watchChanges: true
        printErrors: false
        onLoaded: root.applyThemeColors(text())
        onFileChanged: reload()
        onLoadFailed: root.applyThemeColors("")
    }

    // Command queue: every dispatched cronbar command runs, none is dropped
    // when a previous action is still in flight (the family bug class).
    property var commandQueue: []

    function runCronbar(args) {
        root.commandQueue.push(args)
        drainQueue()
    }

    function drainQueue() {
        if (actionRunner.running || root.commandQueue.length === 0)
            return
        actionRunner.command = [root.cronbarBin].concat(root.commandQueue.shift()).concat(["--config", root.configPath])
        actionRunner.running = true
    }

    function closeModal() {
        root.runCronbar(["ui", "close"])
    }

    function refresh() {
        root.runCronbar(["refresh", "--format", "json"])
    }

    // Status text for a run record: presenter vocabulary, never a bare word.
    // Timeout is incomplete, not clean; failures carry the exit code.
    function runStatusText(record) {
        var status = record && record.status ? record.status : ""
        if (status === "timeout")
            return "timeout (incomplete)"
        if (status === "failed")
            return "failed" + (record.exitCode !== undefined && record.exitCode !== null ? " (exit " + record.exitCode + ")" : "")
        if (status === "dry-run")
            return "dry-run preview"
        return status.length > 0 ? status : "unknown"
    }

    function factTone(status) {
        if (status === "success")
            return root.theme.good
        if (status === "timeout")
            return root.theme.warn
        if (status === "dry-run")
            return root.theme.info
        if (status.length > 0)
            return root.theme.bad
        return root.theme.textMuted
    }

    // Diagnostics for the selected job, on the surface: last manual run
    // outcome, exit code and stderr head, plus the next scheduled time.
    // Never behind an ellipsis: lines wrap.
    function lastRunFacts() {
        var job = root.selectedJob
        if (!job)
            return []
        var facts = []
        var latest = null
        for (var i = 0; i < root.runList.length; i++) {
            var record = root.runList[i]
            if (record.jobId === job.id && !record.dryRun)
                latest = record
        }
        if (latest) {
            facts.push({ fact: lastRunFactText(latest), color: root.factTone(latest.status) })
            if (latest.status !== "success" && latest.stderr && latest.stderr.length > 0)
                facts.push({ fact: "stderr: " + latest.stderr.split("\n")[0], color: root.theme.bad })
        } else {
            facts.push({ fact: "no manual run yet", color: root.theme.textMuted })
        }
        return facts
    }

    function lastRunFactText(record) {
        var head = record.startedAt || ""
        return "last manual run " + head + " — " + root.runStatusText(record)
    }

    function statusColor(status) {
        if (status === "error")
            return root.theme.bad
        if (status === "stale" || status === "loading")
            return root.theme.textMuted
        return root.theme.good
    }

    function chipTone(tone) {
        if (tone === "bad")
            return root.theme.bad
        if (tone === "good")
            return root.theme.good
        if (tone === "warn")
            return root.theme.warn
        if (tone === "muted")
            return root.theme.textMuted
        return root.theme.good
    }

    function jobTone(job) {
        if (job.commented)
            return root.theme.warn
        if (job.privilege === "sudo")
            return root.theme.bad
        if (job.surface === "anacron")
            return root.theme.info
        return root.theme.good
    }

    function jobSubtitle(job) {
        var parts = [job.schedule]
        if (job.surface === "cron.d" && job.user)
            parts.push(job.user + " (user)")
        else if (job.user)
            parts.push(job.user)
        if (job.surface === "anacron")
            parts.push("+" + (job.delayMinutes || 0) + "m delay")
        return parts.join("   ")
    }

    function jobNext(job) {
        if (job.commented)
            return "commented out — manual runs only"
        if (job.surface === "anacron")
            return job.nextLabel || "after start"
        return job.nextLabel || "?"
    }

    function filteredJobs() {
        var query = root.filterText.toLowerCase()
        var out = []
        for (var i = 0; i < root.jobs.length; i++) {
            var job = root.jobs[i]
            if (root.surfaceFilter !== "all" && job.surface !== root.surfaceFilter)
                continue
            if (query.length && (job.command + " " + (job.name || "") + " " + job.schedule).toLowerCase().indexOf(query) < 0)
                continue
            out.push(job)
        }
        return out
    }

    function selectJob(job) {
        root.selectedJob = job
        root.confirmArmed = false
        root.lastRunResult = ""
    }

    function armRun() {
        if (!root.selectedJob)
            return
        if (!root.confirmArmed) {
            root.confirmArmed = true
            return
        }
        if (root.runPass.length === 0) {
            root.lastRunResult = "passphrase required"
            return
        }
        var args = ["run", root.selectedJob.id, "--pass", root.runPass]
        if (root.runDry)
            args.push("--dry-run")
        args.push("--format", "json")
        root.runCronbar(args)
        root.lastRunResult = root.runDry ? "dry run dispatched…" : "run dispatched…"
        root.confirmArmed = false
        root.runPass = ""
    }

    Process {
        id: actionRunner
        running: false
        stdout: StdioCollector {
            id: actionStdout
            onStreamFinished: {
                var text = actionStdout.text.trim()
                if (!text.length)
                    return
                try {
                    var payload = JSON.parse(text)
                    if (payload && payload.status) {
                        root.lastRunResult = (payload.dryRun ? "dry-run " : "") + payload.status +
                            (payload.exitCode !== undefined && payload.exitCode !== null ? " (exit " + payload.exitCode + ")" : "")
                    }
                } catch (e) {
                    console.log(text)
                }
            }
        }
        stderr: StdioCollector {
            id: actionStderr
            onStreamFinished: {
                if (actionStderr.text.trim().length)
                    console.log(actionStderr.text.trim())
            }
        }
        onExited: drainQueue()
    }

    FileView {
        id: snapshotFile
        path: root.snapshotPath
        watchChanges: true
        onFileChanged: reload()

        JsonAdapter {
            id: snapshotAdapter
            property int snapshotVersion: 0
            property string generatedAt: ""
            property string status: "loading"
            property var summary: ({})
            property var surfaces: []
            property var jobs: []
            property var errors: []
            property var view: ({})
        }
    }

    FileView {
        id: uiFile
        path: root.uiPath
        watchChanges: true
        onFileChanged: reload()

        JsonAdapter {
            id: uiAdapter
            property bool open: false
            property string requestedAt: ""
        }
    }

    FileView {
        id: runsFile
        path: root.runsPath
        watchChanges: true
        printErrors: false
        onFileChanged: reload()

        JsonAdapter {
            id: runsAdapter
            property var runs: []
        }
    }

    FileView {
        id: eventFile
        path: root.eventPath
        watchChanges: true
        onFileChanged: root.reloadState()
    }

    function reloadState() {
        snapshotFile.reload()
        uiFile.reload()
        runsFile.reload()
        eventFile.reload()
    }

    Component.onCompleted: root.reloadState()

    component SurfaceCard: Rectangle {
        property var surface: null

        // Flow is a positioner: it lays children out by width/height, and a
        // bare Rectangle has no implicit size — the tiles would render 0x0
        // with their text spilling as one overdrawn line. Measure from the
        // tile's own content instead; Layout attached properties are ignored
        // inside a positioner.
        implicitWidth: surfaceCardColumn.implicitWidth + 20
        implicitHeight: 64
        color: cardArea.containsMouse ? root.theme.surface : root.theme.surfaceAlt
        border.color: surface && surface.locked ? root.theme.warn : (surfaceFilter === (surface && surface.id) ? root.theme.info : root.theme.borderFaint)
        border.width: surfaceFilter === (surface && surface.id) ? 2 : 1
        radius: 0

        Behavior on border.color {
            ColorAnimation { duration: 110 }
        }

        ColumnLayout {
            id: surfaceCardColumn
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.margins: 10
            spacing: 2

            Text {
                text: surface ? surface.label : ""
                color: root.theme.textMuted
                font.family: root.textFont
                font.pixelSize: 10
                font.bold: true
                elide: Text.ElideRight
            }

            Text {
                text: surface ? ((surface.jobCount || 0) + " jobs" + (surface.failingCount > 0 ? " · " + surface.failingCount + " failing" : "") + (surface.commentedCount ? " · " + surface.commentedCount + " off" : "")) : ""
                color: surface && surface.locked ? root.theme.warn : (surface && surface.failingCount > 0 ? root.theme.bad : root.theme.good)
                font.family: root.textFont
                font.pixelSize: 15
                font.bold: true
                elide: Text.ElideRight
            }

            Text {
                visible: surface && surface.locked
                text: surface && surface.locked ? "locked (sudo)" : ""
                color: root.theme.warn
                font.family: root.textFont
                font.pixelSize: 9
                elide: Text.ElideRight
            }
        }

        MouseArea {
            id: cardArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                if (!surface)
                    return
                root.surfaceFilter = root.surfaceFilter === surface.id ? "all" : surface.id
            }
        }
    }

    component MetricTile: Rectangle {
        property string label: ""
        property string value: ""
        property color accent: root.theme.good

        // Same positioner rule as SurfaceCard: implicit size from content.
        implicitWidth: metricTileColumn.implicitWidth + 24
        implicitHeight: 62
        color: root.theme.surfaceAlt
        border.color: Qt.rgba(accent.r, accent.g, accent.b, 0.5)
        border.width: 1
        radius: 0

        ColumnLayout {
            id: metricTileColumn
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.margins: 12
            spacing: 2

            Text {
                text: label
                color: root.theme.textMuted
                font.family: root.textFont
                font.pixelSize: 10
                elide: Text.ElideRight
            }

            Text {
                text: value
                color: accent
                font.family: root.textFont
                font.pixelSize: 20
                font.bold: true
                elide: Text.ElideRight
            }
        }
    }

    component IconButton: Rectangle {
        signal clicked()
        property string icon: ""
        property string label: ""
        property color accent: root.theme.good

        implicitWidth: iconLabelRow.implicitWidth + 24
        Layout.preferredHeight: 34
        color: buttonArea.containsMouse ? Qt.rgba(accent.r, accent.g, accent.b, 0.14) : root.theme.surface
        border.color: buttonArea.containsMouse ? accent : root.theme.border
        border.width: 1
        radius: 0

        Behavior on color {
            ColorAnimation { duration: 110 }
        }

        Behavior on border.color {
            ColorAnimation { duration: 110 }
        }

        RowLayout {
            id: iconLabelRow
            anchors.centerIn: parent
            spacing: 7

            Text {
                text: icon
                color: accent
                font.family: root.iconFont
                font.pixelSize: 14
            }

            Text {
                text: label
                color: root.theme.text
                font.family: root.textFont
                font.pixelSize: 12
            }
        }

        MouseArea {
            id: buttonArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: parent.clicked()
        }
    }

    component ToneDot: Rectangle {
        property color tone: root.theme.good

        Layout.preferredWidth: 10
        Layout.fillHeight: true
        color: tone
        radius: 0
    }

    component DetailPane: Rectangle {
        property bool compact: false

        color: root.theme.surfaceAlt
        border.color: root.theme.borderFaint
        border.width: 1

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: root.shortViewport || compact ? 8 : 12
            spacing: root.shortViewport || compact ? 6 : 10

            Text {
                text: "job"
                color: root.theme.textMuted
                font.family: root.textFont
                font.pixelSize: 9
                font.bold: true
            }

            Text {
                Layout.fillWidth: true
                text: root.selectedJob ? root.selectedJob.id : "select a job"
                color: root.theme.info
                font.family: root.textFont
                font.pixelSize: 14
                font.bold: true
                elide: Text.ElideRight
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 64
                color: root.theme.bgDeep
                border.color: root.theme.borderFaint
                border.width: 1

                Text {
                    anchors.fill: parent
                    anchors.margins: 8
                    text: root.selectedJob ? root.selectedJob.command : ""
                    color: root.theme.text
                    font.family: root.textFont
                    font.pixelSize: 11
                    wrapMode: Text.WrapAnywhere
                }
            }

            GridLayout {
                Layout.fillWidth: true
                columns: 2
                columnSpacing: 10
                rowSpacing: 4

                Text {
                    text: "schedule"
                    color: root.theme.textMuted
                    font.family: root.textFont
                    font.pixelSize: 10
                }

                Text {
                    Layout.fillWidth: true
                    text: root.selectedJob ? root.selectedJob.schedule : ""
                    color: root.theme.text
                    font.family: root.textFont
                    font.pixelSize: 10
                    elide: Text.ElideRight
                }

                Text {
                    text: "next"
                    color: root.theme.textMuted
                    font.family: root.textFont
                    font.pixelSize: 10
                }

                Text {
                    Layout.fillWidth: true
                    text: root.selectedJob ? root.jobNext(root.selectedJob) : ""
                    color: root.theme.goodSoft
                    font.family: root.textFont
                    font.pixelSize: 10
                    elide: Text.ElideRight
                }

                Text {
                    text: "source"
                    color: root.theme.textMuted
                    font.family: root.textFont
                    font.pixelSize: 10
                }

                Text {
                    Layout.fillWidth: true
                    text: root.selectedJob ? ((root.selectedJob.source || "") + ":" + (root.selectedJob.line || "?")) : ""
                    color: root.theme.text
                    font.family: root.textFont
                    font.pixelSize: 10
                    elide: Text.ElideRight
                }

                Text {
                    text: "runs as"
                    color: root.theme.textMuted
                    font.family: root.textFont
                    font.pixelSize: 10
                }

                Text {
                    Layout.fillWidth: true
                    text: root.selectedJob ? (root.selectedJob.privilege === "sudo" ? "sudo (may prompt)" : (root.selectedJob.user || "you")) : ""
                    color: root.selectedJob && root.selectedJob.privilege === "sudo" ? root.theme.bad : root.theme.text
                    font.family: root.textFont
                    font.pixelSize: 10
                    elide: Text.ElideRight
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2
                visible: root.lastRunFacts().length > 0

                Repeater {
                    model: root.lastRunFacts()

                    Text {
                        required property var modelData
                        Layout.fillWidth: true
                        text: modelData.fact
                        color: modelData.color
                        font.family: root.textFont
                        font.pixelSize: 10
                        wrapMode: Text.Wrap
                    }
                }
            }

            Item {
                Layout.fillHeight: true
            }

            Text {
                Layout.fillWidth: true
                visible: root.lastRunResult.length > 0
                text: root.lastRunResult
                color: root.lastRunResult.indexOf("success") >= 0 ? root.theme.good : (root.lastRunResult.indexOf("dispatch") >= 0 ? root.theme.info : root.theme.bad)
                font.family: root.textFont
                font.pixelSize: 11
                elide: Text.ElideRight
            }

            CheckBox {
                id: dryCheck
                visible: root.selectedJob !== null
                text: "dry run (show, don't execute)"
                checked: root.runDry
                onToggled: root.runDry = checked
                contentItem: Text {
                    text: dryCheck.text
                    color: root.theme.textMuted
                    font.family: root.textFont
                    font.pixelSize: 11
                    leftPadding: dryCheck.indicator.width + dryCheck.spacing
                    verticalAlignment: Text.AlignVCenter
                }
            }

            TextField {
                id: passField
                visible: root.selectedJob !== null
                Layout.fillWidth: true
                placeholderText: "run passphrase"
                echoMode: TextInput.Password
                font.family: root.textFont
                font.pixelSize: 12
                color: root.theme.text
                onTextChanged: root.runPass = text
            }

            IconButton {
                visible: root.selectedJob !== null
                Layout.fillWidth: true
                icon: root.confirmArmed ? "\uF05A" : "\uF04B"
                label: root.confirmArmed ? "confirm " + (root.runDry ? "dry run" : "run") : (root.runDry ? "dry run" : "run now")
                accent: root.confirmArmed ? root.theme.warn : root.theme.good
                onClicked: root.armRun()
            }

            Text {
                Layout.fillWidth: true
                // fixed height so arming never shifts the confirm button out
                // from under the cursor
                Layout.preferredHeight: 24
                text: root.confirmArmed ? "click again to confirm — this executes the job on this machine" : ""
                color: root.theme.warn
                font.family: root.textFont
                font.pixelSize: 10
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
            }
        }
    }

    // Bounded bar drop-down geometry. The surface is exactly the card's rect
    // (plus the shadow's drop band) anchored to the top bar edge — the bar
    // drop-down, not a covering modal: the desktop under and beside it stays
    // interactive. The height is counted from the parts actually laid out —
    // never from implicit sizes, which collapse on a ListView or a fillHeight
    // pane — and capped to the viewport, so the card never overlaps the
    // screen's bottom edge; rows beyond the count scroll inside the list with
    // their own cue. 52 = the SolverForge Fira Code 13px bar plus its margins
    // and a breathing gap; horizontal side margins center the bar-edge band on
    // the chip's side of the bar (modules-left), and exact chip-anchoring has
    // no plumbing while Waybar and QuickShell are separate processes (honest
    // bar-edge placement, per family).
    property int panelTopMargin: 52
    property int panelMaxWidth: 1180
    property int panelMaxHeight: 760
    property int panelMinHeight: 480
    property int shadowDrop: 6

    // Screen dims are read from Quickshell.screens[0], never from the panel's
    // own properties: reading panel.* inside the geometry that sizes the same
    // window ties an implicitHeight/width binding loop.
    function panelScreen() {
        return Quickshell.screens.length ? Quickshell.screens[0] : null
    }

    function panelWidth() {
        var screen = root.panelScreen()
        var availableWidth = Math.max(332, (screen ? screen.width : 1440) - 64)
        return Math.min(root.panelMaxWidth, availableWidth)
    }

    function panelHeight() {
        // Counted chrome: card margins (16*2 or 10*2) + header band (48:
        // title/subtitle and the 34px action buttons) + filter row (34) +
        // count line (13) + layout spacings (12*3 or 8*3) between the top
        // level bands + the tile band (two wrapped Flow rows of 64 + 8 wrap
        // spacing).
        var chromeCounted = root.shortViewport ? 132 : 180
        var tilesBand = root.shortViewport ? 72 : 140
        var alertsHeight = root.alerts.length > 0 ? Math.min(96, root.alerts.length * 30) : 0
        var visibleJobs = Math.min(root.filteredJobs().length, 12)
        var listPane = 63 + visibleJobs * 70
        var detailFloor = 360
        var contentHeight = Math.max(listPane, detailFloor)
        var counted = chromeCounted + tilesBand + alertsHeight + contentHeight
        var screen = root.panelScreen()
        var availableHeight = Math.max(root.panelMinHeight, (screen ? screen.height : 900) - root.panelTopMargin - 12)
        return Math.max(root.panelMinHeight, Math.min(root.panelMaxHeight, availableHeight, counted))
    }
    PanelWindow {
        id: panel
        visible: uiAdapter.open
        screen: Quickshell.screens.length ? Quickshell.screens[0] : null
        // Bounded bar drop-down: the surface is anchored to the top bar edge
        // (plus left/right, one edge each, which pin the horizontal span) and
        // its implicit size is exactly the card's counted geometry plus the
        // margin that hangs it from the bar and the shadow's bottom drop band
        // — nothing bottom-anchored, nothing screen-sized. No mask: the
        // bounded surface accepts input across its own rect (a Wayland layer
        // surface is opaque to input), so a click inside the window but
        // outside the card's radius dismisses; the desktop outside the strip
        // is never covered and keeps its own clicks.
        implicitWidth: panelWidth()
        implicitHeight: panelHeight() + root.panelTopMargin + root.shadowDrop
        color: "transparent"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
        aboveWindows: true
        exclusionMode: ExclusionMode.Ignore
        anchors {
            top: true
            left: true
            right: true
        }
        margins {
            top: root.panelTopMargin
            bottom: 0
            left: Math.max(8, Math.round(((root.panelScreen() ? root.panelScreen().width : 1440) - panelWidth()) / 2))
            right: Math.max(8, Math.round(((root.panelScreen() ? root.panelScreen().width : 1440) - panelWidth()) / 2))
        }

        onVisibleChanged: {
            if (visible)
                modalFade.restart()
        }

        NumberAnimation {
            id: modalFade
            target: modalFrame
            property: "opacity"
            from: 0
            to: 1
            duration: 150
            easing.type: Easing.OutCubic
        }

        Shortcut {
            sequence: "Esc"
            context: Qt.WindowShortcut
            onActivated: root.closeModal()
        }

        Item {
            id: panelItem
            anchors.fill: parent

            // Transparent strip catcher filling the bounded window: any click
            // inside the surface but outside the card's radius (the shadow
            // drop band and the corner slivers) dismisses. The card's own
            // catcher swallows dead space inside the card first.
            MouseArea {
                id: stripCatcher
                anchors.fill: parent
                z: -2
                onClicked: root.closeModal()
            }

            // Shadow separation: the card hangs from the bar edge, so a 5px
            // translucent offset below it reads as a drop, not a float. The
            // drop band (shadowDrop) below the card is part of the window.
            Rectangle {
                id: frameShadow
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.top
                width: modalFrame.width
                height: modalFrame.height
                color: Qt.rgba(0, 0, 0, 0.35)
                radius: 8
                visible: modalFrame.visible
            }

            Rectangle {
                id: modalFrame
                anchors.fill: parent
                anchors.bottomMargin: root.shadowDrop
                color: root.theme.bg
                border.color: root.chipTone(root.statusChip.tone)
                border.width: 1
                radius: 8
                Keys.onEscapePressed: root.closeModal()

                // Swallow clicks that land on the card but miss every control,
                // so dead space inside the card stays interactive without
                // reaching the strip catcher beneath the card.
                MouseArea {
                    id: cardCatcher
                    anchors.fill: parent
                    z: -1
                }

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 1
                    radius: 7
                    color: "transparent"
                    border.color: root.theme.borderSoft
                    border.width: 1
                }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: root.shortViewport ? 10 : 16
                    spacing: root.shortViewport ? 8 : 12

                    // ------------------------------------------------- header

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 12

                        ColumnLayout {
                            spacing: 2

                            Row {
                                spacing: 8

                                Text {
                                    text: "cronbar"
                                    color: root.theme.text
                                    font.family: root.textFont
                                    font.pixelSize: root.shortViewport ? 20 : 24
                                    font.bold: true
                                }
                                // Live dot: the panel is a live view; the dot
                                // carries that at a glance (amber while a
                                // command is in flight, red on an error
                                // snapshot, green when idle).
                                Rectangle {
                                    id: liveDot
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 7
                                    height: 7
                                    radius: 3.5
                                    color: root.statusChip.tone === "bad" ? root.theme.bad
                                        : (actionRunner.running || root.commandQueue.length > 0)
                                            ? root.theme.warn : root.theme.goodSoft
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                visible: !root.shortViewport || !root.narrowLayout || root.historyOpen
                                text: "scheduled jobs · " + (snapshotAdapter.generatedAt || "waiting for data")
                                color: root.theme.goodSoft
                                font.family: root.textFont
                                font.pixelSize: 11
                                elide: Text.ElideRight
                            }
                        }

                        Rectangle {
                            Layout.preferredWidth: statusChipText.width + 20
                            Layout.preferredHeight: 30
                            color: Qt.rgba(root.chipTone(root.statusChip.tone).r, root.chipTone(root.statusChip.tone).g, root.chipTone(root.statusChip.tone).b, 0.13)
                            border.color: root.chipTone(root.statusChip.tone)
                            border.width: 1

                            Text {
                                id: statusChipText
                                anchors.centerIn: parent
                                text: root.statusChip.text
                                color: root.chipTone(root.statusChip.tone)
                                font.family: root.textFont
                                font.pixelSize: 12
                                font.bold: true
                            }
                        }

                        Item {
                            Layout.fillWidth: true
                        }

                        IconButton {
                            icon: "\uEAB0"
                            label: "Refresh"
                            onClicked: root.refresh()
                        }

                        IconButton {
                            icon: "\uF03D"
                            label: root.historyOpen ? "Jobs" : "History"
                            accent: root.theme.info
                            onClicked: root.historyOpen = !root.historyOpen
                        }

                        IconButton {
                            icon: "\uF415"
                            label: "Close"
                            accent: root.theme.info
                            onClicked: root.closeModal()
                        }
                    }

                    // ------------------------------------------- surface strip

                    Flow {
                        Layout.fillWidth: true
                        spacing: 8

                        Repeater {
                            model: root.surfaces
                            SurfaceCard {
                                surface: modelData
                            }
                        }

                        MetricTile {
                            label: "jobs, this machine"
                            value: (summary.jobCount || 0) + " · " + (summary.activeJobCount || 0) + " active"
                            accent: (summary.failingJobCount || 0) > 0 ? root.theme.warn : root.theme.good
                        }

                        MetricTile {
                            label: "commented, manual-only"
                            value: summary.commentedJobCount || 0
                            accent: (summary.commentedJobCount || 0) > 0 ? root.theme.warn : root.theme.good
                        }

                        MetricTile {
                            label: (summary.failingJobCount || 0) > 0 ? ("failing, of " + ((summary.jobCount || 0) - (summary.failingJobCount || 0)) + " healthy") : "manual runs"
                            value: (summary.failingJobCount || 0) > 0 ? ((summary.failingJobCount || 0) + " failing") : (summary.manualRunCount || 0)
                            accent: (summary.failingJobCount || 0) > 0 ? root.theme.bad : root.theme.good
                        }

                        MetricTile {
                            label: "next up"
                            value: summary.soonest ? (summary.soonest.nextLabel || "?") : "—"
                            accent: root.theme.info
                        }
                    }

                    // --------------------------------------------- alerts strip

                    Rectangle {
                        Layout.fillWidth: true
                        visible: root.alerts.length > 0
                        implicitHeight: alertsColumn.implicitHeight + 18
                        color: root.theme.surfaceAlt
                        border.color: root.theme.warn
                        border.width: 1

                        ColumnLayout {
                            id: alertsColumn
                            anchors.fill: parent
                            anchors.margins: 9
                            spacing: 3

                            Repeater {
                                model: root.alerts

                                Text {
                                    Layout.fillWidth: true
                                    Layout.minimumWidth: 0
                                    text: modelData.tone === "bad" ? "! " + modelData.text : "△ " + modelData.text
                                    color: modelData.tone === "bad" ? root.theme.bad : root.theme.warn
                                    font.family: root.textFont
                                    font.pixelSize: 10
                                    wrapMode: Text.Wrap
                                }
                            }
                        }
                    }

                    // ------------------------------------------------- content

                    RowLayout {
                        id: dashboardAreas
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        spacing: 12
                        visible: !root.narrowLayout

                        // job list pane
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            Layout.minimumWidth: 420
                            spacing: 8

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8

                                TextField {
                                    id: filterField
                                    Layout.fillWidth: true
                                    placeholderText: "filter jobs…"
                                    font.family: root.textFont
                                    font.pixelSize: 12
                                    color: root.theme.text
                                    onTextChanged: root.filterText = text
                                }

                                IconButton {
                                    icon: "\uEAB0"
                                    label: "All"
                                    accent: root.surfaceFilter === "all" ? root.theme.info : root.theme.textMuted
                                    onClicked: root.surfaceFilter = "all"
                                }
                            }

                            Rectangle {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                color: root.theme.bgDeep
                                border.color: root.theme.borderFaint
                                border.width: 1

                                ListView {
                                    id: jobList
                                    anchors.fill: parent
                                    anchors.margins: 8
                                    model: root.filteredJobs()
                                    clip: true
                                    spacing: 6
                                    boundsBehavior: Flickable.StopAtBounds
                                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                                    delegate: Rectangle {
                                        width: jobList.width
                                        height: 64
                                        color: root.selectedJob && root.selectedJob.id === modelData.id ? Qt.rgba(root.theme.info.r, root.theme.info.g, root.theme.info.b, 0.10) : (index % 2 === 0 ? root.theme.surface : root.theme.surfaceAlt)
                                        border.color: root.selectedJob && root.selectedJob.id === modelData.id ? root.theme.info : root.theme.borderFaint
                                        border.width: 1

                                        RowLayout {
                                            anchors.fill: parent
                                            anchors.margins: 8
                                            spacing: 8

                                            ToneDot {
                                                tone: root.jobTone(modelData)
                                            }

                                            ColumnLayout {
                                                Layout.fillWidth: true
                                                spacing: 3

                                                Text {
                                                    Layout.fillWidth: true
                                                    text: modelData.command
                                                    color: root.theme.text
                                                    font.family: root.textFont
                                                    font.pixelSize: 12
                                                    font.bold: true
                                                    elide: Text.ElideRight
                                                }

                                                Text {
                                                    Layout.fillWidth: true
                                                    text: root.jobSubtitle(modelData)
                                                    color: root.theme.textMuted
                                                    font.family: root.textFont
                                                    font.pixelSize: 10
                                                    elide: Text.ElideRight
                                                }

                                                Text {
                                                    Layout.fillWidth: true
                                                    text: root.jobNext(modelData)
                                                    color: modelData.commented ? root.theme.warn : root.theme.goodSoft
                                                    font.family: root.textFont
                                                    font.pixelSize: 10
                                                    elide: Text.ElideRight
                                                }
                                            }

                                            Text {
                                                text: modelData.id
                                                color: root.theme.textMuted
                                                font.family: root.textFont
                                                font.pixelSize: 9
                                                horizontalAlignment: Text.AlignRight
                                            }
                                        }

                                        MouseArea {
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.selectJob(modelData)
                                        }
                                    }

                                    Text {
                                        anchors.centerIn: parent
                                        visible: root.jobs.length === 0
                                        text: snapshotAdapter.status === "loading" ? "waiting for first refresh…" : "no jobs match"
                                        color: root.theme.textMuted
                                        font.family: root.textFont
                                        font.pixelSize: 13
                                    }
                                }
                            }


                            // Visible overflow cue: the count names the whole
                            // list, "scroll" appears when rows exceed the pane.
                            Text {
                                Layout.fillWidth: true
                                text: root.filteredJobs().length + " jobs" +
                                      (jobList.contentHeight > jobList.height ? " · scroll" : "")
                                color: root.theme.textMuted
                                font.family: root.textFont
                                font.pixelSize: 10
                            }
                        }

                        // detail / history pane
                        Rectangle {
                            Layout.preferredWidth: 400
                            Layout.maximumWidth: 440
                            Layout.fillHeight: true
                            Layout.fillWidth: false
                            color: root.theme.surfaceAlt
                            border.color: root.theme.borderFaint
                            border.width: 1

                            DetailPane {
                                anchors.fill: parent
                                anchors.margins: 1
                                visible: !root.historyOpen
                            }

                            // history view
                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 12
                                spacing: 8
                                visible: root.historyOpen

                                Text {
                                    text: "manual runs"
                                    color: root.theme.textMuted
                                    font.family: root.textFont
                                    font.pixelSize: 9
                                    font.bold: true
                                }

                                ListView {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    model: root.runList.slice().reverse()
                                    clip: true
                                    spacing: 4

                                    delegate: Rectangle {
                                        width: ListView.view.width
                                        height: 44
                                        color: index % 2 === 0 ? root.theme.surface : root.theme.surfaceAlt
                                        border.color: modelData.status === "success" ? Qt.rgba(root.theme.good.r, root.theme.good.g, root.theme.good.b, 0.4) : root.theme.bad
                                        border.width: 1

                                        ColumnLayout {
                                            anchors.fill: parent
                                            anchors.margins: 6
                                            spacing: 1

                                            RowLayout {
                                                Layout.fillWidth: true

                                                Text {
                                                    Layout.fillWidth: true
                                                    text: (modelData.jobId || "?") + "  ·  " + (modelData.startedAt || "")
                                                    color: root.theme.text
                                                    font.family: root.textFont
                                                    font.pixelSize: 10
                                                    font.bold: true
                                                    elide: Text.ElideRight
                                                }

                                                Text {
                                                    text: modelData.status + (modelData.exitCode !== undefined && modelData.exitCode !== null ? " (" + modelData.exitCode + ")" : "")
                                                    color: modelData.status === "success" ? root.theme.good : root.theme.bad
                                                    font.family: root.textFont
                                                    font.pixelSize: 10
                                                }
                                            }

                                            Text {
                                                Layout.fillWidth: true
                                                text: (modelData.dryRun ? "[dry] " : "") + (modelData.command || "")
                                                color: root.theme.textMuted
                                                font.family: root.textFont
                                                font.pixelSize: 9
                                                elide: Text.ElideRight
                                            }
                                        }
                                    }

                                    Text {
                                        anchors.centerIn: parent
                                        visible: root.runList.length === 0
                                        text: "no manual runs yet"
                                        color: root.theme.textMuted
                                        font.family: root.textFont
                                        font.pixelSize: 12
                                    }
                                }
                            }
                        }
                    }

                    // ------------------------------------------------ narrow stack

                    // Below 720px the two panes cannot share a row: the full
                    // width switches between one page at a time instead of
                    // squeezing both past legibility. The detail page reuses
                    // the wide detail pane as a component.
                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        spacing: 8
                        visible: root.narrowLayout

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6

                            IconButton {
                                label: "Jobs"
                                accent: root.narrowPanelView === "jobs" ? root.theme.info : root.theme.textMuted
                                onClicked: root.narrowPanelView = "jobs"
                            }

                            IconButton {
                                label: "History"
                                accent: root.narrowPanelView === "history" ? root.theme.info : root.theme.textMuted
                                onClicked: root.narrowPanelView = "history"
                            }

                            IconButton {
                                label: "Selected job"
                                accent: root.narrowPanelView === "detail" ? root.theme.info : root.theme.textMuted
                                onClicked: root.narrowPanelView = "detail"
                            }

                            Item {
                                Layout.fillWidth: true
                            }

                            Text {
                                // Overflow cue for the narrow list: rows are
                                // scrolling when the content outgrows the pane.
                                text: root.narrowPanelView === "jobs" && narrowJobList.contentHeight > narrowJobList.height ? "\u00b7 scroll" : ""
                                color: root.theme.textMuted
                                font.family: root.textFont
                                font.pixelSize: 10
                            }
                        }

                        StackLayout {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            currentIndex: root.narrowPanelView === "jobs" ? 0 : (root.narrowPanelView === "history" ? 1 : 2)

                            // narrow page 1: job list
                            ColumnLayout {
                                spacing: 8

                                TextField {
                                    id: narrowFilterField
                                    Layout.fillWidth: true
                                    placeholderText: "filter jobs\u2026"
                                    font.family: root.textFont
                                    font.pixelSize: 12
                                    color: root.theme.text
                                    onTextChanged: root.filterText = text
                                }

                                Rectangle {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    color: root.theme.bgDeep
                                    border.color: root.theme.borderFaint
                                    border.width: 1

                                    ListView {
                                        id: narrowJobList
                                        anchors.fill: parent
                                        anchors.margins: 8
                                        model: root.filteredJobs()
                                        clip: true
                                        spacing: 6
                                        boundsBehavior: Flickable.StopAtBounds
                                        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                                        delegate: Rectangle {
                                            width: narrowJobList.width
                                            height: 56
                                            color: root.selectedJob && root.selectedJob.id === modelData.id ? Qt.rgba(root.theme.info.r, root.theme.info.g, root.theme.info.b, 0.10) : (index % 2 === 0 ? root.theme.surface : root.theme.surfaceAlt)
                                            border.color: root.selectedJob && root.selectedJob.id === modelData.id ? root.theme.info : root.theme.borderFaint
                                            border.width: 1

                                            MouseArea {
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    root.selectJob(modelData)
                                                    root.narrowPanelView = "detail"
                                                }
                                            }

                                            ColumnLayout {
                                                anchors.fill: parent
                                                anchors.margins: 8
                                                spacing: 2

                                                RowLayout {
                                                    Layout.fillWidth: true
                                                    spacing: 8

                                                    ToneDot {
                                                        Layout.preferredWidth: 8
                                                        Layout.fillHeight: false
                                                        Layout.preferredHeight: 40
                                                        tone: root.jobTone(modelData)
                                                    }

                                                    Text {
                                                        Layout.fillWidth: true
                                                        Layout.minimumWidth: 0
                                                        text: modelData.command
                                                        color: root.theme.text
                                                        font.family: root.textFont
                                                        font.pixelSize: 12
                                                        font.bold: true
                                                        elide: Text.ElideRight
                                                    }

                                                    Text {
                                                        Layout.maximumWidth: 90
                                                        text: modelData.id
                                                        color: root.theme.textMuted
                                                        font.family: root.textFont
                                                        font.pixelSize: 9
                                                        horizontalAlignment: Text.AlignRight
                                                        elide: Text.ElideRight
                                                    }
                                                }

                                                Text {
                                                    Layout.fillWidth: true
                                                    Layout.minimumWidth: 0
                                                    text: root.jobSubtitle(modelData) + "   " + root.jobNext(modelData)
                                                    color: modelData.commented ? root.theme.warn : root.theme.textMuted
                                                    font.family: root.textFont
                                                    font.pixelSize: 10
                                                    elide: Text.ElideRight
                                                }
                                            }
                                        }

                                        Text {
                                            anchors.centerIn: parent
                                            visible: root.jobs.length === 0
                                            text: snapshotAdapter.status === "loading" ? "waiting for first refresh\u2026" : "no jobs match"
                                            color: root.theme.textMuted
                                            font.family: root.textFont
                                            font.pixelSize: 13
                                        }
                                    }
                                }

                                Text {
                                    Layout.fillWidth: true
                                    text: root.filteredJobs().length + " jobs" +
                                          (narrowJobList.contentHeight > narrowJobList.height ? " \u00b7 scroll" : "")
                                    color: root.theme.textMuted
                                    font.family: root.textFont
                                    font.pixelSize: 10
                                }
                            }

                            // narrow page 2: history
                            ColumnLayout {
                                spacing: 8

                                ListView {
                                    id: narrowHistoryList
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    model: root.runList.slice().reverse()
                                    clip: true
                                    spacing: 4
                                    boundsBehavior: Flickable.StopAtBounds
                                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                                    delegate: Rectangle {
                                        width: narrowHistoryList.width
                                        height: 44
                                        color: index % 2 === 0 ? root.theme.surface : root.theme.surfaceAlt
                                        border.color: modelData.status === "success" ? Qt.rgba(root.theme.good.r, root.theme.good.g, root.theme.good.b, 0.4) : (modelData.status === "timeout" ? root.theme.warn : root.theme.bad)
                                        border.width: 1

                                        ColumnLayout {
                                            anchors.fill: parent
                                            anchors.margins: 6
                                            spacing: 1

                                            RowLayout {
                                                Layout.fillWidth: true

                                                Text {
                                                    Layout.fillWidth: true
                                                    Layout.minimumWidth: 0
                                                    text: (modelData.jobId || "?") + "  \u00b7  " + (modelData.startedAt || "")
                                                    color: root.theme.text
                                                    font.family: root.textFont
                                                    font.pixelSize: 10
                                                    font.bold: true
                                                    elide: Text.ElideRight
                                                }

                                                Text {
                                                    text: root.runStatusText(modelData)
                                                    color: modelData.status === "success" ? root.theme.good : (modelData.status === "timeout" ? root.theme.warn : root.theme.bad)
                                                    font.family: root.textFont
                                                    font.pixelSize: 10
                                                }
                                            }

                                            Text {
                                                Layout.fillWidth: true
                                                Layout.minimumWidth: 0
                                                text: (modelData.dryRun ? "[dry] " : "") + (modelData.command || "")
                                                color: root.theme.textMuted
                                                font.family: root.textFont
                                                font.pixelSize: 9
                                                elide: Text.ElideRight
                                            }
                                        }
                                    }

                                    Text {
                                        anchors.centerIn: parent
                                        visible: root.runList.length === 0
                                        text: "no manual runs yet"
                                        color: root.theme.textMuted
                                        font.family: root.textFont
                                        font.pixelSize: 12
                                    }
                                }
                            }

                            // narrow page 3: selected job detail, the
                            // same DetailPane the wide layout shows
                            Loader {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                active: root.narrowLayout
                                sourceComponent: DetailPane {
                                    compact: true
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
