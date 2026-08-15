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
// diagonal metal safety bar covers it instead). It's loaded with 8
// chambers sampled (weighted toward recently-played) from your installed
// Steam library. Landing plays an optional fire sequence (gun frame fades
// in, a side clip loads and ejects, hammer cocks and strikes, the whole
// widget kicks with recoil, a muzzle burst fires from the pin) before
// launching - or launches instantly if that's toggled off in settings.
//
// Installed by install.sh — do not edit __SCRIPT_PATH__ by hand, that's
// templated in at install time to point at revolver-scan-steam.

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

    implicitWidth: 230
    implicitHeight: 268
    width: implicitWidth
    height: implicitHeight

    property bool spinning: false
    property bool loading: false
    property bool firing: false
    property bool committedSpin: false   // false while chambers aren't ready yet
    property var chambers: []            // [{appid, name, weight}, ...] length chamberCount
    property var lastPool: []            // full weighted pool from the last scan, for single-chamber reloads
    property var _pendingChosen: null    // stashed launch target while the fire sequence plays
    property int landedIndex: -1
    property string statusText: "drag to spin"

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
    }

    Process {
        id: launchProc
        command: ["xdg-open", "steam://rungameid/0"]
    }

    function _rescan() {
        if (root.loading) return
        root.loading = true
        root.statusText = "chambering..."
        scanProc.running = true
    }

    function _onScanFinished(text) {
        root.loading = false
        var pool = []
        try {
            pool = JSON.parse(text)
        } catch (e) {
            pool = []
        }
        if (pool.length === 0) {
            root.statusText = "no steam library found"
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
            root._replaceChamber(root.landedIndex)
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
        launchProc.command = ["xdg-open", "steam://rungameid/" + chosen.appid]
        launchProc.running = true
    }

    // Eject the just-launched chamber and load a different game into it,
    // like ejecting a spent shell. Prefers a game not already loaded in one
    // of the other chambers.
    function _replaceChamber(idx) {
        if (root.lastPool.length === 0) return
        var loadedIds = root.chambers.map(function(c) { return c.appid })
        var candidates = root.lastPool.filter(function(g) { return loadedIds.indexOf(g.appid) === -1 })
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
                        required property int index
                        property real angle: index * (360 / root.chamberCount) * Math.PI / 180
                        x: drum.width / 2 + Math.cos(angle) * 82 - 24
                        y: drum.height / 2 + Math.sin(angle) * 82 - 24
                        width: 48
                        height: 48
                        // counter-rotate the label so text stays upright as the drum spins
                        rotation: -drum.rotation

                        Rectangle {
                            anchors.fill: parent
                            radius: width / 2
                            color: (root.landedIndex === index && !root.spinning && root.committedSpin) ? root.colAccent : root.colChamber
                            opacity: (root.landedIndex === index && !root.spinning && root.committedSpin) ? 0.92 : 0.5

                            Text {
                                anchors.fill: parent
                                anchors.margins: 4
                                text: root.chambers.length > index ? root.chambers[index].name : "—"
                                color: root.colOnBackground
                                font.pixelSize: (root.landedIndex === index && !root.spinning && root.committedSpin) ? 9 : 8
                                font.bold: root.landedIndex === index && !root.spinning && root.committedSpin
                                wrapMode: Text.WordWrap
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                                elide: Text.ElideRight
                                maximumLineCount: 4
                            }
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
