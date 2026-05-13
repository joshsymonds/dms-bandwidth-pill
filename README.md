# dms-bandwidth-pill

A [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell) bar pill
that shows instantaneous network throughput (RX/TX) for a chosen interface.
Reads `/proc/net/dev` at a configurable interval — no daemon, no `nethogs`,
no `bwm-ng` dependency.

## What it looks like

On a vertical bar (DMS default), two stacked rows with explicit
direction arrows so each value labels itself — no convention required:

```
↓ 2.3M    ← download rate (RX)
↑ 0.8M    ← upload rate   (TX)
```

On a horizontal bar there's room for explicit arrows:

```
⇅  ↓ 2.3M  ↑ 0.8M
```

The pill inherits its sizing, colors, and font scale from DMS's standard
bar-widget theme machinery (`Theme.barIconSize`, `Theme.barTextSize`,
`Theme.widgetIconColor`, etc.), so it matches the rest of your bar without
configuration.

## Install

### Imperative (any DMS install)

```bash
git clone https://github.com/joshsymonds/dms-bandwidth-pill \
  ~/.config/DankMaterialShell/plugins/bandwidthPill
dms ipc call plugins reload bandwidthPill
```

Then add `bandwidthPill` to your bar's `leftWidgets` / `centerWidgets` /
`rightWidgets` array in `~/.config/DankMaterialShell/settings.json` (or via
the in-shell Bar Settings UI).

### Nix flake (NixOS via the DMS home-manager module)

```nix
# flake.nix
inputs.dms-bandwidth-pill.url = "github:joshsymonds/dms-bandwidth-pill";

# home-manager config
programs.dank-material-shell.plugins.bandwidthPill = {
  src = inputs.dms-bandwidth-pill.packages.${pkgs.system}.default;
  settings = {
    # All optional. See "Settings" below.
    # interface = "eno1";
    # intervalMs = 1000;
  };
};
```

## Settings

All optional. Defaults shown.

| Key | Default | Description |
|---|---|---|
| `interface` | `"auto"` | NIC name (e.g. `eno1`, `wlp3s0`). `"auto"` picks the first non-`lo` interface in `/proc/net/dev` with non-zero RX. Override if you have multiple actives and want a specific one. |
| `intervalMs` | `1000` | Polling interval in milliseconds. Lower is more responsive; higher is friendlier to laptop battery. |

## How it works

A `FileView` reads `/proc/net/dev` on every `Timer` tick. The widget keeps
the previous RX/TX byte counters in QML state; each read produces a delta
divided by the elapsed time, yielding bytes-per-second. The kernel does the
hard work; this widget just diffs and formats.

`/proc/net/dev` rows look like:

```
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets …
    lo: 12345   100     0    0    0    0     0          0        12345   100     …
  eno1: 1234567 1000    0    0    0    0     0          0        2345678 1500    …
```

We pull `bytes` (column 0) for RX and `bytes` (column 8) for TX.

## Caveats

- Bytes are kernel-side counters — they include packets dropped by user-space
  firewalls but exclude packets dropped in driver/hardware. For a Wireguard
  user, the underlying physical NIC's counters and the `wg0` counters can
  differ noticeably; set `interface` to the one whose number you care about.
- Counter wraparound: on 64-bit kernels the counters are 64-bit and won't
  wrap during any reasonable session. We `Math.max(0, …)` defensively just
  in case (32-bit ARM kernels exist).

## License

MIT — see [LICENSE](./LICENSE).
