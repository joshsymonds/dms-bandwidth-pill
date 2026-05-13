// dms-bandwidth-pill: instantaneous network throughput in a DMS bar pill.
//
// Data source: /proc/net/dev. We poll the file at `intervalMs` (default 1s),
// diff RX/TX byte counters against the previous reading, divide by elapsed
// time to get bytes/sec for the configured interface. No daemon, no
// shell-out — just a FileView + a Timer.
//
// Interface selection: defaults to "auto", which picks the first non-`lo`
// interface in /proc/net/dev that has non-zero RX traffic. Override via
// pluginData.interface (e.g. "eno1", "wlp3s0") if you have multiple active
// interfaces and want a specific one.
//
// Rendering follows the conventions of DMS's built-in monitors (CpuMonitor,
// RamMonitor): icon + value column on a vertical bar, icon + value row on
// a horizontal bar. Two stacked direction blocks since we surface both
// RX and TX in the same pill.
import QtQuick
import Quickshell.Io
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

PluginComponent {
    id: root
    pluginId: "bandwidthPill"

    // ── Settings (configurable via pluginData) ─────────────────────────
    property string ifaceSetting: (pluginData && pluginData.interface) ? pluginData.interface : "auto"
    // Default 2s polling — 1s makes the rate values jitter visibly as
    // bursts smear across read windows; 2s smooths perceived motion
    // without losing responsiveness. Users who want snappier updates
    // can drop this via pluginData.intervalMs.
    property int intervalMs: (pluginData && pluginData.intervalMs) ? pluginData.intervalMs : 2000

    // ── Live state ─────────────────────────────────────────────────────
    property real _rxBytesPrev: -1
    property real _txBytesPrev: -1
    property real rxRate: 0     // bytes per second
    property real txRate: 0
    property string detectedIface: ""

    // Compact rate formatter — at most 4 characters wide so the text
    // doesn't overflow a 36-40px vertical pill at the bar's reduced
    // font size. Decimal point only kept for single-digit magnitudes
    // ("1.5K", "9.9M") where it adds useful precision; dropped for
    // higher magnitudes ("132K", "1.5M") where the suffix is enough.
    function _formatRate(bytesPerSec) {
        if (bytesPerSec < 1024)
            return bytesPerSec.toFixed(0);          // "0".."999"
        const k = bytesPerSec / 1024;
        if (k < 10)
            return k.toFixed(1) + "K";              // "1.0K".."9.9K"
        if (k < 1024)
            return Math.round(k) + "K";             // "10K".."1023K"
        const m = k / 1024;
        if (m < 10)
            return m.toFixed(1) + "M";              // "1.0M".."9.9M"
        return Math.round(m) + "M";                 // "10M"+
    }

    // We /could/ use a FileView here — but FileView's content access is
    // subtly different from a plain string property (text() vs text in
    // different versions, mtime-based reload heuristics that misbehave on
    // /proc files whose mtime never changes, etc.). Process + StdioCollector
    // is what DMS's own DgopService uses and it gives us a clean stdout
    // string with no API ambiguity.
    Process {
        id: procReader
        command: ["cat", "/proc/net/dev"]
        stdout: StdioCollector {
            id: collector
            onStreamFinished: {
                // Quickshell's StdioCollector exposes `text` as a QString
                // property per its qmltypes, but DMS's older Quickshell
                // build also has a `text()` method overload that the
                // QML engine sometimes resolves to first when read via
                // a bare or `this.`-prefixed identifier. Reading via the
                // explicit `id` (collector.text) plus the defensive
                // `typeof === "function"` check below covers both
                // shapes; on this host the result lands as a string.
                let raw = collector.text;
                if (typeof raw === "function")
                    raw = raw();
                const procContent = String(raw);
                if (!procContent)
                    return;

                // INLINE parsing — no function calls — so we can isolate
                // whether the prior crashes were a scoping issue with
                // function params or something else entirely.
                const lines = procContent.split("\n");
                let iface = root.detectedIface;

                // Re-detect interface if needed.
                if (!iface || !procContent.includes(iface + ":")) {
                    iface = "";
                    if (root.ifaceSetting !== "auto") {
                        iface = root.ifaceSetting;
                    } else {
                        for (let i = 2; i < lines.length; i++) {
                            const line = lines[i].trim();
                            if (!line)
                                continue;
                            const colonIdx = line.indexOf(":");
                            if (colonIdx < 0)
                                continue;
                            const candidate = line.substring(0, colonIdx).trim();
                            if (candidate === "lo")
                                continue;
                            const f = line.substring(colonIdx + 1).trim().split(/\s+/);
                            if (parseInt(f[0], 10) > 0) {
                                iface = candidate;
                                break;
                            }
                        }
                    }
                }
                if (!iface)
                    return;
                if (root.detectedIface !== iface) {
                    root.detectedIface = iface;
                    root._rxBytesPrev = -1;
                    root._txBytesPrev = -1;
                }

                // Parse stats for the chosen iface.
                let stats = null;
                const prefix = iface + ":";
                for (let i = 2; i < lines.length; i++) {
                    const line = lines[i].trim();
                    if (!line.startsWith(prefix))
                        continue;
                    const f = line.substring(line.indexOf(":") + 1).trim().split(/\s+/);
                    stats = {
                        rx: parseInt(f[0], 10),
                        tx: parseInt(f[8], 10)
                    };
                    break;
                }
                if (!stats)
                    return;
                if (root._rxBytesPrev >= 0) {
                    const dt = root.intervalMs / 1000;
                    root.rxRate = Math.max(0, (stats.rx - root._rxBytesPrev) / dt);
                    root.txRate = Math.max(0, (stats.tx - root._txBytesPrev) / dt);
                }
                root._rxBytesPrev = stats.rx;
                root._txBytesPrev = stats.tx;
            }
        }
    }

    Timer {
        interval: root.intervalMs
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: procReader.running = true
    }

    // ── Vertical bar pill ──────────────────────────────────────────────
    // Matches the visual rhythm of DMS's built-in CpuMonitor / RamMonitor
    // (single anchoring icon + value column), extended to TWO values
    // because bandwidth is inherently bidirectional. Convention:
    //
    //    [swap_vert icon]   ← the "this is bandwidth" identity
    //    2.3M               ← download rate (RX)
    //    0.8M               ← upload rate   (TX)
    //
    // Top-rate = download is the universal convention in `ifstat`,
    // `nload`, `iftop`, htop's network section, etc. — we don't fight
    // it. Inline ↓/↑ glyphs would be clearer but at the bar's
    // configurable fontScale they push the text past the 36px pill
    // width; we keep the pill clean and let a (future) popout show the
    // labeled version when the user hovers/clicks.
    // Reference pattern from DMS-shipped ColorDemoPlugin and the
    // dms-claudecode plugin: `verticalBarPill: Component { Column {...} }`
    // directly — NO BasePill wrapper, NO outer Item. The bar's
    // WidgetHost wraps the plugin's content in its own pill chrome;
    // wrapping in BasePill on the plugin side double-wraps and the
    // outer pill caps height to BasePill's hardcoded geometry, which
    // assumes 2-row content. Returning a bare Column lets the pill
    // grow to fit all three rows naturally.
    verticalBarPill: Component {
        Column {
            // Tight 2px spacing — the bar's right section is bottom-
            // anchored and budget-constrained; pairing this with
            // Theme.fontSizeSmall below brings the 3-row pill in line
            // with the 2-row CpuMonitor/RamMonitor height profile so
            // controlCenterButton still fits below us.
            spacing: 2

            DankIcon {
                name: "swap_vert"
                size: Theme.iconSizeSmall
                color: Theme.widgetIconColor
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                // Theme.fontSizeSmall (12px) deliberately bypasses the
                // bar's fontScale multiplier — at the user's larger
                // bar fontScale, rate text like "132K" would overflow
                // the pill width. Using the small font keeps it under
                // 36px wide while staying readable.
                text: root._formatRate(root.rxRate)
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.widgetTextColor
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                text: root._formatRate(root.txRate)
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.widgetTextColor
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    // ── Horizontal bar pill ────────────────────────────────────────────
    // On a horizontal bar we have width to spare, so we can afford the
    // explicit directional arrows alongside the identity icon:
    //    [swap_vert] ↓ 2.3M  ↑ 0.8M
    // Same data as the vertical layout, more readable presentation.
    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingS

            DankIcon {
                name: "swap_vert"
                size: Theme.barIconSize(root.barThickness, undefined, root.barConfig ? root.barConfig.maximizeWidgetIcons : false, root.barConfig ? root.barConfig.iconScale : 1.0)
                color: Theme.widgetIconColor
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                text: "↓ " + root._formatRate(root.rxRate)
                font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig ? root.barConfig.fontScale : 1.0, root.barConfig ? root.barConfig.maximizeWidgetText : false)
                color: Theme.widgetTextColor
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                text: "↑ " + root._formatRate(root.txRate)
                font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig ? root.barConfig.fontScale : 1.0, root.barConfig ? root.barConfig.maximizeWidgetText : false)
                color: Theme.widgetTextColor
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }
}
