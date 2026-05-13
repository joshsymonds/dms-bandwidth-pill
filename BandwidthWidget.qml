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
    property int intervalMs: (pluginData && pluginData.intervalMs) ? pluginData.intervalMs : 1000

    // ── Live state ─────────────────────────────────────────────────────
    property real _rxBytesPrev: -1
    property real _txBytesPrev: -1
    property real rxRate: 0     // bytes per second
    property real txRate: 0
    property string detectedIface: ""

    // Auto-pick the first interface that's actually moving traffic. We
    // skip the header rows (lines 0-1 of /proc/net/dev) and the loopback,
    // then return the first iface whose RX counter is non-zero. Stable
    // enough for desktops with one NIC; users with multiple actives
    // should set pluginData.interface explicitly.
    function _selectInterface(content) {
        if (root.ifaceSetting !== "auto")
            return root.ifaceSetting;
        const lines = content.split("\n");
        for (let i = 2; i < lines.length; i++) {
            const line = lines[i].trim();
            if (!line)
                continue;
            const colonIdx = line.indexOf(":");
            if (colonIdx < 0)
                continue;
            const iface = line.substring(0, colonIdx).trim();
            if (iface === "lo")
                continue;
            const fields = line.substring(colonIdx + 1).trim().split(/\s+/);
            const rx = parseInt(fields[0], 10);
            if (rx > 0)
                return iface;
        }
        return "";
    }

    // /proc/net/dev row format after the colon is positional whitespace-
    // separated: rx_bytes rx_packets rx_errs rx_drop rx_fifo rx_frame
    // rx_compressed rx_multicast tx_bytes tx_packets ... — we want fields
    // 0 (rx) and 8 (tx).
    function _parseStats(content, iface) {
        const lines = content.split("\n");
        const prefix = iface + ":";
        for (let i = 2; i < lines.length; i++) {
            const line = lines[i].trim();
            if (!line.startsWith(prefix))
                continue;
            const fields = line.substring(line.indexOf(":") + 1).trim().split(/\s+/);
            return {
                rx: parseInt(fields[0], 10),
                tx: parseInt(fields[8], 10)
            };
        }
        return null;
    }

    // Compact rate formatter: B/s under 1 KiB/s, K under 1 MiB/s, M
    // otherwise. One decimal place for K/M for readability without
    // jitter; no decimals for B (sub-KiB rates are visually noisy
    // anyway). The icon next to the number conveys the unit, so we
    // omit it from the text to save horizontal space in the pill.
    function _formatRate(bytesPerSec) {
        if (bytesPerSec < 1024)
            return bytesPerSec.toFixed(0);
        if (bytesPerSec < 1024 * 1024)
            return (bytesPerSec / 1024).toFixed(1) + "K";
        return (bytesPerSec / (1024 * 1024)).toFixed(1) + "M";
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
            onStreamFinished: {
                const content = this.text;
                if (!content)
                    return;

                // Pick interface on first read OR if the previously-detected
                // one has disappeared from the file (e.g. user yanked an
                // adapter); otherwise stick with what we picked so we don't
                // flip-flop between two interfaces both carrying traffic.
                let iface = root.detectedIface;
                if (!iface || !content.includes(iface + ":"))
                    iface = root._selectInterface(content);
                if (!iface)
                    return;
                if (root.detectedIface !== iface) {
                    root.detectedIface = iface;
                    root._rxBytesPrev = -1;
                    root._txBytesPrev = -1;
                }
                const stats = root._parseStats(content, iface);
                if (!stats)
                    return;
                if (root._rxBytesPrev >= 0) {
                    const dt = root.intervalMs / 1000;
                    // Max(0,…) guards against the counter wrapping to a
                    // lower value, which shouldn't happen on 64-bit
                    // kernels but costs nothing to defend against.
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
    verticalBarPill: Component {
        BasePill {
            id: pill
            content: Component {
                Item {
                    implicitWidth: pill.widgetThickness - pill.horizontalPadding * 2
                    implicitHeight: col.implicitHeight

                    Column {
                        id: col
                        anchors.centerIn: parent
                        spacing: 1

                        DankIcon {
                            name: "swap_vert"
                            size: Theme.barIconSize(pill.barThickness, undefined, pill.barConfig ? pill.barConfig.maximizeWidgetIcons : false, pill.barConfig ? pill.barConfig.iconScale : 1.0)
                            color: Theme.widgetIconColor
                            anchors.horizontalCenter: parent.horizontalCenter
                        }

                        StyledText {
                            text: root._formatRate(root.rxRate)
                            font.pixelSize: Theme.barTextSize(pill.barThickness, pill.barConfig ? pill.barConfig.fontScale : 1.0, pill.barConfig ? pill.barConfig.maximizeWidgetText : false)
                            color: Theme.widgetTextColor
                            anchors.horizontalCenter: parent.horizontalCenter
                        }

                        StyledText {
                            text: root._formatRate(root.txRate)
                            font.pixelSize: Theme.barTextSize(pill.barThickness, pill.barConfig ? pill.barConfig.fontScale : 1.0, pill.barConfig ? pill.barConfig.maximizeWidgetText : false)
                            color: Theme.widgetTextColor
                            anchors.horizontalCenter: parent.horizontalCenter
                        }
                    }
                }
            }
        }
    }

    // ── Horizontal bar pill ────────────────────────────────────────────
    // On a horizontal bar we have width to spare, so we can afford the
    // explicit directional arrows alongside the identity icon:
    //    [swap_vert] ↓ 2.3M  ↑ 0.8M
    // Same data as the vertical layout, more readable presentation.
    horizontalBarPill: Component {
        BasePill {
            id: pill
            content: Component {
                Row {
                    anchors.centerIn: parent
                    spacing: Theme.spacingS

                    DankIcon {
                        name: "swap_vert"
                        size: Theme.barIconSize(pill.barThickness, undefined, pill.barConfig ? pill.barConfig.maximizeWidgetIcons : false, pill.barConfig ? pill.barConfig.iconScale : 1.0)
                        color: Theme.widgetIconColor
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    StyledText {
                        text: "↓ " + root._formatRate(root.rxRate)
                        font.pixelSize: Theme.barTextSize(pill.barThickness, pill.barConfig ? pill.barConfig.fontScale : 1.0, pill.barConfig ? pill.barConfig.maximizeWidgetText : false)
                        color: Theme.widgetTextColor
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    StyledText {
                        text: "↑ " + root._formatRate(root.txRate)
                        font.pixelSize: Theme.barTextSize(pill.barThickness, pill.barConfig ? pill.barConfig.fontScale : 1.0, pill.barConfig ? pill.barConfig.maximizeWidgetText : false)
                        color: Theme.widgetTextColor
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }
        }
    }
}
