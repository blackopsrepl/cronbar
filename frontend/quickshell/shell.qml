import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

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

    function statusColor(status) {
        if (status === "error")
            return root.theme.bad
        if (status === "stale" || status === "loading")
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

        Layout.fillWidth: true
        Layout.preferredHeight: 64
        color: cardArea.containsMouse ? root.theme.surface : root.theme.surfaceAlt
        border.color: surface && surface.locked ? root.theme.warn : (surfaceFilter === (surface && surface.id) ? root.theme.info : root.theme.borderFaint)
        border.width: surfaceFilter === (surface && surface.id) ? 2 : 1
        radius: 0

        Behavior on border.color {
            ColorAnimation { duration: 110 }
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 8
            spacing: 2

            Text {
                Layout.fillWidth: true
                text: surface ? surface.label : ""
                color: root.theme.textMuted
                font.family: root.textFont
                font.pixelSize: 10
                font.bold: true
                elide: Text.ElideRight
            }

            Text {
                Layout.fillWidth: true
                text: surface ? ((surface.jobCount || 0) + " jobs" + (surface.commentedCount ? " · " + surface.commentedCount + " off" : "")) : ""
                color: surface && surface.locked ? root.theme.warn : root.theme.good
                font.family: root.textFont
                font.pixelSize: 15
                font.bold: true
                elide: Text.ElideRight
            }

            Text {
                Layout.fillWidth: true
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

        Layout.fillWidth: true
        Layout.preferredHeight: 62
        color: root.theme.surfaceAlt
        border.color: Qt.rgba(accent.r, accent.g, accent.b, 0.5)
        border.width: 1
        radius: 0

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 8
            spacing: 2

            Text {
                Layout.fillWidth: true
                text: label
                color: root.theme.textMuted
                font.family: root.textFont
                font.pixelSize: 10
                elide: Text.ElideRight
            }

            Text {
                Layout.fillWidth: true
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

    PanelWindow {
        id: modal
        visible: uiAdapter.open
        screen: Quickshell.screens.length ? Quickshell.screens[0] : null
        property int verticalMargin: 24
        implicitWidth: screen ? screen.width : 1280
        implicitHeight: screen ? screen.height : 800
        color: "transparent"
        focusable: true
        aboveWindows: true
        exclusionMode: ExclusionMode.Ignore
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        margins {
            top: 0
            bottom: 0
            left: 0
            right: 0
        }

        onVisibleChanged: {
            if (visible)
                modalFade.restart()
        }

        NumberAnimation {
            id: modalFade
            target: card
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
            anchors.fill: parent

            Rectangle {
                anchors.fill: parent
                color: root.theme.bgDeep
                opacity: 0.66
            }

            MouseArea {
                anchors.fill: parent
                onClicked: root.closeModal()
            }

            Rectangle {
                anchors.centerIn: parent
                width: card.width + 10
                height: card.height + 10
                radius: 0
                color: Qt.rgba(0, 0, 0, 0.22)
            }

            Rectangle {
                anchors.centerIn: parent
                width: card.width + 4
                height: card.height + 4
                radius: 0
                color: Qt.rgba(0, 0, 0, 0.34)
            }

            Rectangle {
                id: card
                width: Math.min(1180, Math.max(720, modal.width - 64))
                height: Math.min(modal.height - 16, Math.max(480, modal.height - (modal.verticalMargin * 2)))
                anchors.centerIn: parent
                color: root.theme.bg
                border.color: root.theme.good
                border.width: 1
                radius: 0

                // Swallow clicks that land on the card but miss every
                // control: without this they fall through to the backdrop
                // and close the panel under the user's cursor.
                MouseArea {
                    anchors.fill: parent
                    z: -1
                }

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 1
                    radius: 0
                    color: "transparent"
                    border.color: root.theme.borderSoft
                    border.width: 1
                }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 16
                    spacing: 12

                    // ------------------------------------------------- header

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 12

                        ColumnLayout {
                            spacing: 2

                            Text {
                                text: "cronbar"
                                color: root.theme.text
                                font.family: root.textFont
                                font.pixelSize: 24
                                font.bold: true
                            }

                            Text {
                                text: "scheduled jobs · " + (snapshotAdapter.generatedAt || "waiting for data")
                                color: root.theme.goodSoft
                                font.family: root.textFont
                                font.pixelSize: 11
                            }
                        }

                        Rectangle {
                            Layout.preferredWidth: 96
                            Layout.preferredHeight: 30
                            color: Qt.rgba(root.statusColor(snapshotAdapter.status).r, root.statusColor(snapshotAdapter.status).g, root.statusColor(snapshotAdapter.status).b, 0.13)
                            border.color: root.statusColor(snapshotAdapter.status)
                            border.width: 1

                            Text {
                                anchors.centerIn: parent
                                text: snapshotAdapter.status || "loading"
                                color: root.statusColor(snapshotAdapter.status)
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

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8

                        Repeater {
                            model: root.surfaces
                            SurfaceCard {
                                surface: modelData
                            }
                        }

                        MetricTile {
                            label: "active"
                            value: summary.activeJobCount || 0
                            accent: root.theme.good
                        }

                        MetricTile {
                            label: "commented"
                            value: summary.commentedJobCount || 0
                            accent: (summary.commentedJobCount || 0) > 0 ? root.theme.warn : root.theme.good
                        }

                        MetricTile {
                            label: "next up"
                            value: summary.soonest ? (summary.soonest.nextLabel || "?") : "—"
                            accent: root.theme.info
                        }
                    }

                    // --------------------------------------------- error strip

                    Text {
                        Layout.fillWidth: true
                        visible: root.errors.length > 0
                        text: root.errors.map(function (e) {
                            return (e.context ? e.context + ": " : "") + e.message
                        }).join("   ·   ")
                        color: root.theme.bad
                        font.family: root.textFont
                        font.pixelSize: 11
                        elide: Text.ElideRight
                    }

                    // ------------------------------------------------- content

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        spacing: 12

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

                            // detail view
                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 12
                                spacing: 10
                                visible: !root.historyOpen

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
                                    Layout.preferredHeight: 74
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
                                    // fixed height so arming never shifts the
                                    // confirm button out from under the cursor
                                    Layout.preferredHeight: 24
                                    text: root.confirmArmed ? "click again to confirm — this executes the job on this machine" : ""
                                    color: root.theme.warn
                                    font.family: root.textFont
                                    font.pixelSize: 10
                                    wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                }
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
                }
            }
        }
    }
}
