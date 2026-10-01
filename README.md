# TG PRO MAX

A native, monitoring-only macOS menu bar utility built in Swift/SwiftUI for Apple Silicon. Built and probed on an M5 Max. No external dependencies.

## Run

```sh
./scripts/build-app.sh
open "dist/TG PRO MAX.app"
```

Click the thermometer and live temperature in the menu bar. The app has no Dock icon. The gear opens a dedicated Settings window; Sensors shows source keys and mapping caveats. Select a component row to view its history and statistics.

For a stable installation, move the app to `~/Applications` or `/Applications` before enabling launch at login. Launch the app bundle rather than the bare Swift executable so notifications and login registration have a bundle identity. Notifications are off until enabled; macOS will request permission. This build is locally ad-hoc signed.

## Customize

Settings are saved locally and restored after quitting or rebuilding with the same bundle ID.

- **Appearance:** menu-bar CPU, GPU, CPU+GPU, battery, SSD or icon-only; optional thermometer; decimal precision; optional orange warning color and independent warning threshold. Celsius/Fahrenheit, system/light/dark theme and four accent colors. Temperature thresholds are stored in Celsius and displayed in your chosen unit.
- **Dashboard:** hide/show and reorder component/fan rows using up/down buttons; compact layout; graph visibility; CPU/GPU overlay. The GPU line is dashed to distinguish it from CPU. Hiding rows does not disable monitoring or alerts.
- **Efficiency:** sample every 1, 2, 5 or 10 seconds. Optionally use a slower interval on battery; power-source changes are event-driven. The slower of the main and battery intervals applies on battery. Default remains one second with battery slowdown off.
- **Alerts:** CPU threshold (40–110 °C), required sustained duration (immediate/5/15/30/60 seconds), minimum cooldown (1/5/10/30 minutes). Default is 15 seconds above 90 °C, five-minute cooldown, notifications disabled. Before another alert, CPU must cool to at least 3 °C below threshold. A missing reading, long sampling gap, sleep or a sampling-rate change resets the pending duration. Alerts are evaluated only when a sample arrives; they cannot detect excursions between samples.
- **Launch at login:** available at the bottom of Settings, using native SMAppService.

## Process Watch

Finds what is actually heating the Mac and cleans up after forgotten dev servers.

- Every 15 seconds (30 on battery) the app reads the process table through libproc (no shell commands) and computes CPU per process.
- Dev servers (Next.js, Vite, Expo, Astro, Nuxt, Remix, Storybook, Webpack, Wrangler, Django, Flask, Uvicorn, Rails, file/test watchers) are grouped with their launchers (`npm` → `sh -c` → `node` → `next-server`) and named by project, worktree and port: **IMSA Website · Next.js server (test)** · `help-desk worktree · :3019 · up 6d 15h`.
- A dev server is flagged when its launcher is gone (terminal or agent exited, so it was reparented to launchd) for 15 minutes, when it has run longer than 24 hours, or when it uses ≥ 80 % CPU for 10 minutes. With auto-stop on (default), flagged dev servers are stopped as a whole tree (SIGTERM, then SIGKILL after 3 s, with a pid-reuse check) and you get a notification.
- Any other process that runs away is reported with a notification and a Stop button, never stopped automatically.
- ✦ explains a process with OpenAI (default `gpt-5-mini`), on demand or when a runaway alert fires. Key order: Settings (Keychain) → `OPENAI_API_KEY` → `~/.codex/secrets/openai.env`. Keys and tokens in command lines are redacted before sending.
- `swift run SensorProbe processes` prints what Process Watch sees without signalling anything.

## Monitoring and efficiency

- Real CPU/SoC, GPU, battery, SSD/NAND and fan readings, with unavailable channels hidden.
- Component values use the hottest available mapped sensor; the menu bar identifies CPU/GPU separately when both are shown.
- Ten minutes of in-memory history, capped at 600 snapshots across all components. At slower rates there are fewer samples; no synthetic interpolation or extra sampling for overlays.
- Current/average/peak follow the selected component even in overlay mode. Average is the arithmetic mean of retained samples (not time-weighted if you change the sampling interval).
- Graph gaps represent missing data or sleep; supported slower sampling does not create false gaps. Disabling the graph leaves history and statistics available.
- OS thermal pressure reported independently of temperatures.
- Serial utility queue, cached SMC metadata, no recurring shell commands, sampling paused during sleep, chart released while the popup is closed, settings view released when its window closes.
- No telemetry or automatic sensor logging to disk. The only network call is the optional AI explanation (Process Watch). Preferences are saved only when changed.

## Development and checks

Requires Xcode/Swift 6 tools, arm64 macOS 14 or later. Open `Package.swift` in Xcode to edit. No package downloads are needed.

```sh
swift test
swift run SensorProbe
swift build -c release
```

Ten tests cover wire decoding, malformed payloads, unavailable sensors, bounded history, mapping boundaries, preference serialization/repair, Celsius/Fahrenheit and missing-value formatting, battery cadence, sustained alerts/hysteresis/cooldown, and graph segmentation with changing sampling intervals.

The C bridge implements only SMC reads, key enumeration and metadata retrieval. No fan-control writes or thermal load generator are used.

For live-data visual checks without screen-recording permission:

```sh
mkdir -p /tmp/tg-previews
"dist/TG PRO MAX.app/Contents/MacOS/TGProMax" --render-previews /tmp/tg-previews
```

This reads real sensors for 12 seconds and renders dashboard/settings variants. Preview mode neither loads nor saves your preferences and cannot enable notifications or login registration. It does not inject fake history. Native view snapshots include the actual settings controls and scroll containers.

Read [the sensor investigation](docs/SENSOR-INVESTIGATION.md) for actual hardware findings, the five access methods evaluated, sources and limitations. Component labels are inferred from community mappings; values are direct sensor readings, not estimates. Other Apple Silicon models have a best-effort discovery fallback and have not been tested here.
