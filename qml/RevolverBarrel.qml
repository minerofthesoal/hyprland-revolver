// RevolverBarrel.qml
//
// A spinnable 8-chamber revolver desktop widget for illogical-impulse.
// Reuses MaterialCookie (the same wavy-edged dial shape CookieClock.qml
// uses) and StyledDropShadow for the same soft-shadow treatment.
//
// Lives as a plain Item inside Background.qml's WidgetCanvas - same
// mechanism the clock uses - rather than its own window.
//
// Drag the drum to spin it (disabled while the screen is locked - a
// diagonal metal safety bar covers it instead). It's loaded with
// chamberCount chambers sampled from whichever source/mode is picked in
// Settings (Steam, PrismLauncher, or MultiMC; for Steam, weighted by
// recent play, uniformly random, or a broader "recommended" curve — see
// revolver_lib/ for the scoring). Landing plays an optional fire
// sequence (gun frame fades in, a side clip loads and ejects, hammer
// cocks and strikes, the widget kicks with recoil, a muzzle burst fires
// from the pin) before launching - or launches instantly if that's
// toggled off in settings. Whichever chamber fired then visibly ejects
// its spent shell and loads a fresh one before the drum can be spun
// again.
//
// Installed by install.sh — do not edit __SCRIPT_PATH__ by hand, that's
// templated in at install time to point at revolver-scan.

pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.ii.background.widgets.clock

Item {
    id: root

    property int chamberCount: 8
    property bool fireAnimationEnabled: true
    // Both of these are only used here to know *when* to trigger a fresh
    // scan - revolver-scan reads the actual source/mode itself out of
    // ii's config.json, so the values passed in don't need to be
    // forwarded to the script, just watched for changes.
    property string source: "steam"
    property string steamMode: "recent"

    implicitWidth: 230
    implicitHeight: 268
    width: implicitWidth
    height: implicitHeight

    property bool spinning: false
    property bool loading: false
    property bool firing: false
    property bool committedSpin: false   // false while chambers aren't ready yet
    property var chambers: []            // [{id, name, weight, launch}, ...] length chamberCount
    property var lastPool: []            // full weighted pool from the last scan, for single-chamber reloads
    property var _pendingChosen: null    // stashed launch target while the fire sequence plays
    property int landedIndex: -1
    property int ejectingIndex: -1       // which chamber (if any) is mid eject/reload animation
    property string statusText: "drag to spin"

    // chamberCount changing at runtime (Settings panel) used to leave a
    // stale-length `chambers` array behind forever, since committedSpin
    // required chambers.length === chamberCount and nothing ever
    // resynced them - meaning the drum could only ever fire again if you
    // happened to land back on exactly 8. Resample immediately instead.
    onChamberCountChanged: {
        if (root.lastPool.length > 0) {
            root.chambers = root._weightedPick(root.lastPool, root.chamberCount)
        } else {
            root._rescan()
        }
    }
    // Source/mode changes swap out the whole pool's composition, so
    // there's nothing worth salvaging from lastPool - full rescan.
    onSourceChanged: root._rescan()
    onSteamModeChanged: root._rescan()

    // Same Material You tokens CookieClock.qml pulls from.
    property color colBackground: Appearance.colors.colPrimaryContainer
    property color colOnBackground: Appearance.colors.colSecondary
    property color colAccent: Appearance.colors.colTertiary
    property color colChamber: Appearance.colors.colShadow

    Component.onCompleted: root._rescan()

    Process {
        id: scanProc
        command: ["__SCRIPT_PATH__"]
        stdout: StdioCollector {
            onStreamFinished: root._onScanFinished(this.text)
        }
        // A scan that fails to even run (missing python3, a bad
        // __SCRIPT_PATH__, a permissions problem, a crash before it
        // could print anything) might never reach onStreamFinished at
        // all - without this, `loading` would stay stuck true forever,
        // and since every rescan (chamber count, source, and mode
        // changes all included) goes through the same `if (root.loading)
        // return` guard in _rescan(), one bad scan would silently brick
        // every one of those controls at once, not just the scan itself.
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0 && root.loading) {
                root.loading = false
                root.statusText = "scan failed (exit " + exitCode + ") - try 'revolver-scan' in a terminal"
            }
        }
    }

    // Belt-and-braces on top of onExited above, in case a scan hangs
    // outright rather than exiting - e.g. something on the PATH it
    // shells out to (xdg-open, a launcher binary) blocking instead of
    // returning. Without this there'd be no way to recover short of
    // reloading quickshell.
    Timer {
        id: scanWatchdog
        interval: 15000
        repeat: false
        onTriggered: {
            if (root.loading) {
                scanProc.running = false
                root.loading = false
                root.statusText = "scan timed out - try 'revolver-scan' in a terminal"
            }
        }
    }

    Process {
        id: launchProc
        command: ["xdg-open", "steam://rungameid/0"]
    }

    function _rescan() {
        if (root.loading) return
        root.loading = true
        root.statusText = "chambering..."
        scanWatchdog.restart()
        scanProc.running = true
    }

    function _onScanFinished(text) {
        root.loading = false
        scanWatchdog.stop()
        var pool = []
        try {
            pool = JSON.parse(text)
        } catch (e) {
            pool = []
        }
        if (pool.length === 0) {
            root.statusText = "nothing found for this source - check it's installed"
            return
        }
        root.lastPool = pool
        root.chambers = root._weightedPick(pool, root.chamberCount)
        root.statusText = "drag to spin"
    }

    // Weighted sample of `count` games without replacement (reshuffles from
    // the full pool if it has fewer installed games than chambers).
    function _weightedPick(pool, count) {
        var src = pool.slice()
        var out = []
        for (var i = 0; i < count; i++) {
            if (src.length === 0) src = pool.slice()
            var total = 0
            for (var j = 0; j < src.length; j++) total += src[j].weight
            var r = Math.random() * total
            var acc = 0
            var pick = src.length - 1
            for (var k = 0; k < src.length; k++) {
                acc += src[k].weight
                if (r <= acc) { pick = k; break }
            }
            out.push(src[pick])
            src.splice(pick, 1)
        }
        return out
    }

    // Valid resting rotations put a chamber's center exactly under the pin
    // at the top (-90°/270°). Chamber i sits at local angle i*step before
    // rotation (step = 360/chamberCount), so it lands on the pin when
    // rotation ≡ 270 - i*step (mod 360) — i.e. whenever
    // (rotation mod step) == (270 mod step). Snap `raw` to the closest
    // such rotation.
    function _snapToChamber(raw) {
        var step = 360 / root.chamberCount
        var offset = 270 % step
        var mod = ((raw % step) + step) % step
        var diff = offset - mod
        if (diff > step / 2) diff -= step
        if (diff < -step / 2) diff += step
        return raw + diff
    }

    function _chamberAtRotation(rot) {
        var step = 360 / root.chamberCount
        var normR = ((rot % 360) + 360) % 360
        var i = Math.round((270 - normR) / step)
        return ((i % root.chamberCount) + root.chamberCount) % root.chamberCount
    }

    function _releaseSpin(velocityPerMs) {
        var vAbs = Math.min(2.2, Math.abs(velocityPerMs)) // clamp insane flicks
        if (vAbs < 0.03) {
            // barely a nudge - just settle where it is, no launch
            root.committedSpin = false
            spinAnim.duration = 350
            spinAnim.to = root._snapToChamber(drum.rotation)
            spinAnim.start()
            return
        }

        var dir = velocityPerMs >= 0 ? 1 : -1
        var extraDegrees = vAbs * 900
        var duration = Math.max(500, Math.min(3200, 500 + vAbs * 1400))
        var rawTarget = drum.rotation + dir * extraDegrees
        var target = root._snapToChamber(rawTarget)

        root.committedSpin = root.chambers.length >= root.chamberCount
        root.landedIndex = root._chamberAtRotation(target)
        root.spinning = root.committedSpin
        root.statusText = root.committedSpin ? "spinning..." : "still chambering..."

        spinAnim.duration = duration
        spinAnim.to = target
        spinAnim.start()
    }

    function _onSpinStopped() {
        root.spinning = false
        if (!root.committedSpin) {
            root.statusText = "drag to spin"
            return
        }
        var chosen = root.chambers[root.landedIndex]
        if (!chosen) {
            root.statusText = "misfire — try again"
            return
        }
        root.statusText = "drag to spin"
        if (root.fireAnimationEnabled) {
            root._pendingChosen = chosen
            fireSequence.start()
        } else {
            root._launchGame(chosen)
            root._replaceChamber(root.landedIndex)
        }
    }

    // Called mid fire-sequence, right as the hammer strikes.
    function _fireShot() {
        if (root._pendingChosen) {
            root._launchGame(root._pendingChosen)
            root._startEject(root.landedIndex)
            root._pendingChosen = null
        }
    }

    function _launchGame(chosen) {
        // Defensive: if a previous launch never cleanly exited (e.g. its
        // Steam dialog got cancelled), don't let a wedged Process silently
        // eat every launch after it - force it idle before reusing it.
        if (launchProc.running) {
            launchProc.running = false
        }
        // Every source (Steam, PrismLauncher, MultiMC) emits its own
        // ready-to-run argv in "launch", so this stays source-agnostic.
        // The steam:// fallback only matters for a pool entry produced
        // before this field existed.
        launchProc.command = chosen.launch || ["xdg-open", "steam://rungameid/" + chosen.id]
        launchProc.running = true
    }

    // Kick off that chamber's eject/reload animation (see the Repeater
    // delegate below) - it calls back into _replaceChamber once the
    // spent shell has visually fallen clear, so the new game's name
    // never appears mid-fall.
    function _startEject(idx) {
        root.ejectingIndex = idx
    }

    // Load a different entry into chamber `idx`, like loading a fresh
    // round after ejecting a spent shell. Prefers a game/instance not
    // already loaded in one of the other chambers.
    function _replaceChamber(idx) {
        if (root.lastPool.length === 0) return
        var loadedIds = root.chambers.map(function(c) { return c.id })
        var candidates = root.lastPool.filter(function(g) { return loadedIds.indexOf(g.id) === -1 })
        if (candidates.length === 0) candidates = root.lastPool.slice()
        var picked = root._weightedPick(candidates, 1)[0]
        var updated = root.chambers.slice()
        updated[idx] = picked
        root.chambers = updated
    }

    SequentialAnimation {
        id: fireSequence
        ScriptAction { script: root.firing = true }
        NumberAnimation { target: gunFrame; property: "opacity"; to: 1; duration: 180 }
        NumberAnimation { target: clipItem; property: "x"; to: 4; duration: 220; easing.type: Easing.OutBack }
        PauseAnimation { duration: 120 }
        NumberAnimation { target: clipItem; property: "x"; to: -40; duration: 180; easing.type: Easing.InBack }
        NumberAnimation { target: hammer; property: "rotation"; to: -35; duration: 180; easing.type: Easing.OutQuad }
        ScriptAction { script: root._fireShot() }
        ScriptAction { script: root.firing = false }
        ParallelAnimation {
            NumberAnimation { target: hammer; property: "rotation"; to: 0; duration: 70; easing.type: Easing.InQuad }
            NumberAnimation { target: recoilWrapper; property: "y"; to: -8; duration: 60; easing.type: Easing.OutQuad }
            ScriptAction { script: muzzleBurst.burst() }
        }
        NumberAnimation { target: recoilWrapper; property: "y"; to: 0; duration: 260; easing.type: Easing.OutBack }
        NumberAnimation { target: gunFrame; property: "opacity"; to: 0; duration: 220 }
    }

    Item {
        id: drumArea
        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter
        width: 230
        height: 230

        // Abstract "gun frame" - not literal artwork (can't generate custom
        // illustrations here), just a stylized shape that fades in behind
        // the cylinder during the fire sequence.
        Rectangle {
            id: gunFrame
            anchors.centerIn: parent
            width: parent.width + 36
            height: parent.height * 0.5
            y: parent.height * 0.58
            radius: 20
            color: "transparent"
            border.color: root.colOnBackground
            border.width: 2
            opacity: 0
            z: -1
        }

        // Everything that should kick back on recoil, isolated in a plain
        // (non-anchored) Item so animating its `y` can't clobber an anchor
        // binding the way animating drumArea's own y would.
        Item {
            id: recoilWrapper
            width: parent.width
            height: parent.height
            y: 0

            StyledDropShadow {
                target: cookieLoader
            }

            Loader {
                id: cookieLoader
                anchors.fill: parent
                visible: false // StyledDropShadow draws it
                sourceComponent: MaterialCookie {
                    implicitSize: drumArea.width
                    sides: root.chamberCount
                    color: root.colBackground
                }
            }

            Item {
                id: drum
                anchors.fill: parent
                rotation: 0

                Repeater {
                    model: root.chamberCount
                    delegate: Item {
                        id: chamberSlot
                        required property int index
                        property real angle: index * (360 / root.chamberCount) * Math.PI / 180
                        x: drum.width / 2 + Math.cos(angle) * 82 - 24
                        y: drum.height / 2 + Math.sin(angle) * 82 - 24
                        width: 48
                        height: 48
                        // counter-rotate the label so text stays upright as the drum spins
                        rotation: -drum.rotation

                        property bool isLive: root.landedIndex === chamberSlot.index && !root.spinning && root.committedSpin
                        property bool isEjecting: root.ejectingIndex === chamberSlot.index

                        // Rising edge only - the SequentialAnimation below
                        // runs to completion on its own once started, so
                        // this doesn't need to (and shouldn't) retrigger
                        // just because isEjecting later goes false again.
                        onIsEjectingChanged: if (chamberSlot.isEjecting) ejectReload.start()

                        // Everything that physically moves during an eject/
                        // reload lives in here, kept separate from
                        // chamberSlot's own x/y/rotation (those stay locked
                        // to this chamber's fixed position on the drum).
                        Item {
                            id: shell
                            anchors.fill: parent
                            property real fallY: 0
                            property real wobble: 0
                            transform: [
                                Rotation { angle: shell.wobble; origin.x: shell.width / 2; origin.y: shell.height / 2 },
                                Translate { y: shell.fallY }
                            ]

                            // brass rim peeking out from behind the casing face
                            Rectangle {
                                anchors.fill: parent
                                radius: width / 2
                                color: chamberSlot.isLive ? root.colAccent : Qt.lighter(root.colChamber, 1.4)
                                opacity: chamberSlot.isLive ? 0.55 : 0.35
                            }

                            // casing face
                            Rectangle {
                                anchors.fill: parent
                                anchors.margins: 2
                                radius: width / 2
                                color: chamberSlot.isLive ? root.colAccent : root.colChamber
                                opacity: chamberSlot.isLive ? 0.92 : 0.5
                                border.width: 1
                                border.color: Qt.darker(chamberSlot.isLive ? root.colAccent : root.colChamber, 1.3)

                                Text {
                                    anchors.fill: parent
                                    anchors.margins: 4
                                    text: root.chambers.length > chamberSlot.index ? root.chambers[chamberSlot.index].name : "—"
                                    color: root.colOnBackground
                                    font.pixelSize: chamberSlot.isLive ? 9 : 8
                                    font.bold: chamberSlot.isLive
                                    wrapMode: Text.WordWrap
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                    elide: Text.ElideRight
                                    maximumLineCount: 4
                                }
                            }

                            // primer cap - a small inset dot near the rim,
                            // the way a cartridge's primer sits at the base
                            // of the case. Brightens on the live chamber.
                            Rectangle {
                                width: 7
                                height: 7
                                radius: 3.5
                                anchors.top: parent.top
                                anchors.horizontalCenter: parent.horizontalCenter
                                anchors.topMargin: 3
                                color: chamberSlot.isLive ? root.colOnBackground : Qt.darker(root.colChamber, 1.2)
                                opacity: chamberSlot.isLive ? 0.9 : 0.55
                                border.width: 1
                                border.color: root.colBackground
                            }
                        }

                        // Spent shell drops clear (falling + tumbling +
                        // fading), the next round loads into the pool
                        // while it's off-screen, then drops back in from
                        // above and settles with a little bounce.
                        SequentialAnimation {
                            id: ejectReload
                            ParallelAnimation {
                                NumberAnimation { target: shell; property: "fallY"; to: 46; duration: 240; easing.type: Easing.InQuad }
                                NumberAnimation { target: shell; property: "wobble"; to: (chamberSlot.index % 2 === 0 ? 1 : -1) * 50; duration: 240; easing.type: Easing.InQuad }
                                NumberAnimation { target: shell; property: "opacity"; to: 0; duration: 220 }
                            }
                            ScriptAction { script: root._replaceChamber(chamberSlot.index) }
                            PropertyAction { target: shell; property: "fallY"; value: -46 }
                            PropertyAction { target: shell; property: "wobble"; value: 0 }
                            PropertyAction { target: shell; property: "opacity"; value: 0 }
                            PauseAnimation { duration: 60 }
                            ParallelAnimation {
                                NumberAnimation { target: shell; property: "fallY"; to: 0; duration: 260; easing.type: Easing.OutBack }
                                NumberAnimation { target: shell; property: "opacity"; to: 1; duration: 200 }
                            }
                            ScriptAction { script: if (root.ejectingIndex === chamberSlot.index) root.ejectingIndex = -1 }
                        }
                    }
                }

                NumberAnimation {
                    id: spinAnim
                    target: drum
                    property: "rotation"
                    easing.type: Easing.OutCubic
                    onStopped: root._onSpinStopped()
                }
            }

            // Center hub - the fixed axis pin a real cylinder rotates around.
            Item {
                anchors.centerIn: parent
                width: 46
                height: 46

                Rectangle {
                    anchors.fill: parent
                    radius: width / 2
                    color: root.colChamber
                    opacity: 0.65
                    border.color: root.colOnBackground
                    border.width: 1
                }
                Rectangle {
                    anchors.centerIn: parent
                    width: parent.width * 0.55
                    height: width
                    radius: width / 2
                    color: root.colAccent
                    opacity: 0.85
                }
                Rectangle {
                    anchors.centerIn: parent
                    width: parent.width * 0.3
                    height: 3
                    radius: 1.5
                    color: root.colBackground
                    opacity: 0.85
                }
            }

            // Hammer - pivots at its base like a real hinge, cocks back then strikes.
            Item {
                id: hammer
                anchors.horizontalCenter: parent.horizontalCenter
                y: -26
                width: 14
                height: 20
                rotation: 0
                transformOrigin: Item.Bottom

                Rectangle {
                    anchors.fill: parent
                    radius: 3
                    color: root.colAccent
                    border.color: root.colOnBackground
                    border.width: 1
                }
            }

            // Side-loading clip - slides in from off-widget, pauses, slides back out.
            // Hidden at rest: only the fire sequence should ever show it, its
            // x: -40 is a "retracted" position, not actually off-widget.
            Rectangle {
                id: clipItem
                visible: root.firing
                width: 14
                height: 50
                radius: 3
                anchors.verticalCenter: parent.verticalCenter
                x: -40
                color: root.colChamber
                border.color: root.colOnBackground
                border.width: 1
            }

            // Muzzle burst - hand-animated dots rather than QtQuick.Particles,
            // since that module's default resources aren't guaranteed to
            // resolve the same way inside Quickshell's engine.
            Item {
                id: muzzleBurst
                anchors.horizontalCenter: parent.horizontalCenter
                y: -4
                width: 1
                height: 1

                function burst() {
                    for (var i = 0; i < 8; i++) {
                        var p = particleComponent.createObject(muzzleBurst)
                        var angle = (Math.random() * 140 - 70 - 90) * Math.PI / 180
                        var dist = 18 + Math.random() * 14
                        p.targetX = Math.cos(angle) * dist
                        p.targetY = Math.sin(angle) * dist
                        p.start()
                    }
                }

                Component {
                    id: particleComponent
                    Rectangle {
                        id: particle
                        property real targetX: 0
                        property real targetY: 0
                        width: 4
                        height: 4
                        radius: 2
                        x: -2
                        y: -2
                        color: root.colAccent

                        function start() {
                            particleAnim.start()
                        }

                        ParallelAnimation {
                            id: particleAnim
                            NumberAnimation { target: particle; property: "x"; to: particle.targetX; duration: 260; easing.type: Easing.OutQuad }
                            NumberAnimation { target: particle; property: "y"; to: particle.targetY; duration: 260; easing.type: Easing.OutQuad }
                            NumberAnimation { target: particle; property: "opacity"; from: 1; to: 0; duration: 260 }
                            onStopped: particle.destroy()
                        }
                    }
                }
            }

            // firing pin — whichever chamber ends up here is the one that launches
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                y: -4
                width: 8
                height: 8
                radius: 4
                color: root.colAccent
            }
        }

        // Diagonal metal safety bar - shown while the screen is locked,
        // since dragging to spin is disabled then anyway.
        Rectangle {
            id: lockBar
            visible: GlobalStates.screenLocked
            z: 20
            anchors.centerIn: parent
            width: parent.width * 1.05
            height: 26
            rotation: -8
            radius: 4
            border.color: root.colBackground
            border.width: 1
            gradient: Gradient {
                GradientStop { position: 0.0; color: root.colChamber }
                GradientStop { position: 0.5; color: root.colOnBackground }
                GradientStop { position: 1.0; color: root.colChamber }
            }

            // brushed-metal diagonal hatching
            Repeater {
                model: 14
                delegate: Rectangle {
                    required property int index
                    width: 2
                    height: lockBar.height
                    x: index * (lockBar.width / 14)
                    rotation: 20
                    color: root.colBackground
                    opacity: 0.25
                }
            }

            Rectangle {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: 6
                width: 8
                height: 8
                radius: 4
                color: root.colAccent
                border.color: root.colBackground
            }
            Rectangle {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.rightMargin: 6
                width: 8
                height: 8
                radius: 4
                color: root.colAccent
                border.color: root.colBackground
            }
        }

        // drag-to-spin: grab anywhere on the drum and flick it
        MouseArea {
            id: dragArea
            anchors.fill: parent
            enabled: !GlobalStates.screenLocked && !root.firing
            preventStealing: true

            property real lastAngle: 0
            property real lastTimestamp: 0
            property real velocity: 0 // degrees per ms, smoothed

            function _angleAt(mx, my) {
                return Math.atan2(my - height / 2, mx - width / 2) * 180 / Math.PI
            }

            onPressed: (mouse) => {
                if (root.spinning) return
                spinAnim.stop()
                lastAngle = _angleAt(mouse.x, mouse.y)
                lastTimestamp = Date.now()
                velocity = 0
                root.statusText = "..."
            }

            onPositionChanged: (mouse) => {
                if (!pressed || root.spinning) return
                var a = _angleAt(mouse.x, mouse.y)
                var delta = a - lastAngle
                while (delta > 180) delta -= 360
                while (delta < -180) delta += 360
                var now = Date.now()
                var dt = Math.max(1, now - lastTimestamp)
                velocity = velocity * 0.7 + (delta / dt) * 0.3
                drum.rotation += delta
                lastAngle = a
                lastTimestamp = now
            }

            onReleased: {
                if (root.spinning) return
                root._releaseSpin(velocity)
            }
        }
    }

    Text {
        anchors.top: drumArea.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.topMargin: 10
        text: root.statusText
        color: root.colOnBackground
        font.pixelSize: 11
    }
}
