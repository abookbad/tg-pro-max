# Sensor investigation — 2026-09-26

Host: MacBook Pro Mac17,6, Apple M5 Max (18 CPU cores), arm64, macOS 27.0 build 26A428. No machine identifiers are retained here.

The read-only probe was compiled and run **before** the UI and sampler were implemented. AppleSMC opened successfully as the logged-in user. Enumeration found 346 candidate temperature/fan keys; not all are usable or understood. Unknown channels are excluded from the dashboard.

## Methods evaluated

| Method | Observed result / decision |
| --- | --- |
| `powermetrics` | Local help lists thermal, CPU/GPU power and other samplers, but no SMC sampler. A one-sample thermal invocation returns “must be invoked as the superuser.” Not used; no privileged helper or subprocess per update. |
| IOKit | Opens the AppleSMC service using IOServiceOpen, then IOConnectCallStructMethod. Selected as the transport for direct read-only sensor access. Registry also exposes AppleSmartBattery data. |
| SMC | Enumeration and little-endian `flt ` readings work on this M5 Max. Metadata cached once; only selected channels read each second. No write command is implemented. |
| `ioreg` | Confirms AppleSMCKeysEndpoint and AppleSmartBattery exist. BatteryData exposes a Temperature field, but its unit is not trusted here. CLI parsing is unnecessary because battery SMC readings work. |
| `ProcessInfo.thermalState` | Returns nominal (raw 0) during the probe. Used directly for the OS's qualitative thermal pressure; never converted into degrees. |

## Actual initial readings

These are a snapshot during development, **not** baked-in values or an accuracy calibration:

- 18 mapped CPU channels `Tp00` through the M5 list ending `Tp0y`: approximately 70–80 °C.
- Seven of the eight known mapped GPU keys were readable: `Tg0U`, `Tg0X`, `Tg0d`, `Tg0g`, `Tg0j`, `Tg1Y`, `Tg1c`: approximately 54 °C. `Tg1g` was unavailable and omitted.
- `TB1T`: 34.70 °C; `TB2T`: 34.90 °C.
- `TH0x`: 32.71 °C, community mapping identifies NAND. This is not an NVMe SMART composite temperature.
- `F0Ac`: 3144 RPM; `F1Ac`: 3410 RPM.

Apple does not publish these key meanings. Component identities are **inferred community mappings**, while the numeric readings come directly from SMC. The app labels this distinction in Sensors. It uses the maximum of the available mapped channels per component, not a made-up package temperature. Average and peak refer to the selected component's sampled maxima over the most recent ten minutes.

For M5, use the narrow known key lists. On other Apple Silicon generations, CPU `Tp`/`Te` and GPU `Tg` prefix discovery is a best-effort fallback, not validated support. Unknown channels never become a CPU/SSD reading just because their values look plausible. Nonfinite, zero-temperature, out-of-range, unreadable, and unsupported-format values are omitted. Zero fan RPM is preserved.

## References

- [Stats sensor mappings](https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift): M5 CPU/GPU and Apple Silicon battery/NAND key identities. No Stats implementation code is bundled.
- [Apple: thermalState](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.property).
- [Apple: SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice).
- [swift-soc-metrics investigation](https://github.com/GoodOlClint/swift-soc-metrics/blob/main/docs/decisions/0001-die-temperature-from-smc-not-ioreport.md): corroborates direct SMC access on M5. Our own local probe determined the implemented sensor set.

## Limits

Private SMC interfaces and community mappings may change with macOS/firmware. Raw readings have not been calibrated against an external thermometer. This is a local ad-hoc-signed app, not a notarized distribution or App Store build. Notification delivery and login-item approval depend on macOS user settings. No fan control, root access, network access, analytics, or sensor log persistence is implemented.

## Local validation

- `swift test`: four test groups passed, zero failures.
- Release app built and `codesign --verify --deep --strict` passed.
- App bundle launched successfully and stayed running while reading hardware.
- Short background sample: process CPU time rose from 0.13 s at 11 s elapsed to 0.24 s at 49 s elapsed (about 0.29% of one core over 38 s); resident memory approximately 50 MB. This is a short local measurement, not a performance guarantee. Popup rendering costs additional CPU.
- Dashboard rendered from live readings for visual inspection, without screen-recording permission. Full screen capture was unavailable.
- Notification permission/delivery, actual login launch, and physical sleep/wake have not been exercised end to end. Their code paths are implemented; alert decision logic is unit tested.

## v1.1 customization validation

- Ten tests pass, including sustained alert timing, missing readings, long gaps, cooldown/rearming, preference serialization/repair, missing-value and Fahrenheit formatting, battery-rate selection, graph segmentation, and bounded history at 1/2/5/10-second cadences.
- Release build and app signature verification pass. Version 1.1 retains the original bundle identity and existing alert/login settings.
- Native view snapshots use live sensor samples to inspect light/dark dashboards, CPU/GPU overlay, compact mode, and the four Settings tabs. Preview runs use isolated in-memory preferences and cannot enable notification or login registration.
- Battery power was detected through IOKit during the check. A physical AC/battery transition was not exercised; interval selection is unit tested and change notifications are registered on the main run loop.
- Short closed-popup measurement: CPU time rose from 0.10 s at 3 s elapsed to 0.13 s at 13 s elapsed (about 0.3% of one core over ten seconds), resident memory 50,496 KiB. This is a short local observation, not a guarantee or a measurement of graph rendering cost.
- Notification delivery, login launch, physical sleep/wake, and a complete manual interaction pass across every control remain unverified end to end. Alert decisions and graph discontinuities are tested independently.
