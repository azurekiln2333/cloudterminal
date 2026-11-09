# Initial audit (2026-10-01)

- Clean main at 2838644 before continuation. Existing implementation had relay, pairing, Claude SDK session, Flutter screens, replay and tests; planning task status lagged committed code.
- Baseline: Node 24.15.0, 41 Node tests passed, Flutter analyze clean, 21 Flutter tests passed including real Dart/Node WebSocket integration.
- General terminal requires PTY rather than Claude provider adapters. node-pty 1.1.0 has usable prebuilt Windows binaries on this host.
- Reuse relay authentication, subscriptions, session list and lifecycle; exact terminal bytes bypass Claude normalizer.
- Bound replay by bytes and event count, preserve UTF-8/ANSI chunks; frame limits use Buffer.byteLength.
- ANSI replay after eviction cannot reconstruct all full-screen state; document best-effort reset/repaint.
- Local --terminal mode needs raw stdin, resize forwarding, pairing before attach, explicit detach, terminal restoration; phone disconnect does not terminate PTY.
- Only managed PTYs can be shared. --root constrains initial cwd, not shell privileges.
- Local Android SDK and emulator are present; APK build/device smoke will be attempted after source checks.

## Android smoke
- Debug APK built successfully using locally installed complete NDK 27.0.12077973; SDK default NDK 28.2.13676358 lacks source.properties. Temporary ndkVersion override was restored after build.
- Installed and launched on emulator-5560. Full manual terminal interaction was not claimed: another app repeatedly took foreground on this shared emulator, so interaction stopped.
- Do not mistake shared-device input interference for a CloudTerminal failure. Actual terminal command execution is verified through the Dart-to-Node integration and desktop PTY tests.
