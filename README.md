# Neuro_Nav

Real-time processing and visualization of neuronavigation data from
**Brainsight TMS** sessions, plus a cross-platform trigger pipeline
that turns Brainsight drift events on a Mac into QTrack keystrokes on
a Windows machine.

The project has two halves:

- **`python/`** — live drift monitoring on the Mac side
  ([`alert_brainsight_v2.2.0.py`](python/alert_brainsight_v2.2.0.py) is
  the current entry point).
- **`trigger_app_AJ/`** — headless TCP receiver on the Windows side
  that types `ss`+Enter into the focused QTrack window when the Mac
  reports a drift transition.

There's also an **`R/`** half for offline analysis and visualization.

---

## Quick start

### For lab members (distributable bundles, no Python needed)

**Windows lab machine (receiver):**
- Download `TMS Trigger Receiver.exe` (built via the steps below)
- Double-click. A terminal opens with the live banner: LAN IP, port,
  auth token, and a paste-ready command for the Mac side.
- Open QTrack, leave it focused. Done.

**Mac (Brainsight monitor + GUI):**
- Download the `Brainsight Monitor.dmg`. Double-click in Finder, drag
  `Brainsight Monitor` into Applications.
- First launch: right-click → Open → Open (bypasses the unsigned-app
  warning), or remove the quarantine flag once:
  `xattr -dr com.apple.quarantine "/Applications/Brainsight Monitor.app"`
- In the GUI: paste the Mac IP / port / token from the Windows
  receiver's banner, pick the Brainsight `.txt` file, click `Next →`.

### For developers (from source, with Python installed)

**Windows:**
```powershell
pip install -r trigger_app_AJ\requirements.txt
python -m trigger_app_AJ.windows.main
# or double-click launch_receiver.bat at the repo root
```

**Mac GUI:**
```bash
cd python
python3 -m brainsight_gui
# or double-click launch_gui.command at the repo root
```

**Mac CLI (no GUI):**
```bash
python3 python/alert_brainsight_v2.2.0.py "/path/to/Streamed Info.txt" \
    --trigger-to <windows-ip>:5050 \
    --token <token-from-windows>
```

The CLI script establishes the trigger link first, then waits for the
Brainsight file, then enters an interactive REPL. Without
`--trigger-to`, it works as a terminal-only drift monitor (no
networking).

---

## Building the distributable bundles

### Windows `.exe` (run on a Windows machine)

```bat
trigger_app_AJ\build\build_windows.bat
```

Produces `trigger_app_AJ\dist\TMS Trigger Receiver.exe` — a ~30 MB
single-file executable. PyInstaller can't cross-compile, so this must
run on Windows.

### Mac `.app` + `.dmg` (run on a Mac)

```bash
bash python/brainsight_gui/build/build_mac.sh
```

Produces `dist/Brainsight Monitor.app` and `dist/Brainsight Monitor.dmg`.
The build script installs PyInstaller + Pillow on demand, generates a
text-monogram icon, converts it to `.icns` via macOS-native
`sips`/`iconutil`, and packages everything up.

---

## Documentation

- [`CLAUDE.md`](CLAUDE.md) — full system context (data formats,
  versioning convention, dependency list)
- [`trigger_app_AJ/README.md`](trigger_app_AJ/README.md) — wire
  protocol, file layout, build instructions for the Windows .exe,
  troubleshooting

---

## Versions

| Component             | Current | Tag                          |
|-----------------------|---------|------------------------------|
| Alert monitor (CLI)   | v2.2.0  | `alert-brainsight-v2.2.0`    |
| GUI (Mac)             | v0.1.0  | `gui-v0.1.0`                 |
| Trigger app (Windows) | v0.1.0  | `trigger-app-v0.1.0`         |
| Distributable bundles | v0.1.0  | `dist-v0.1.0`                |
| Project release       | v0.1.0  | `v0.1.0`                     |

Old script versions are kept in `python/` (`alert_brainsight_v1.py`
through `alert_brainsight_v2.1.0.py`) — see CLAUDE.md for the rationale.

---

## Repository

Mirrored to two GitHub accounts:

- **Canonical**: `github.com/Ali-Dor-SRI/Neuro_Nav` (work)
- **Mirror**:    `github.com/Aria-Doroodchi/Neuro_Nav` (personal)

---

## Not in this repo

- `data/` — Brainsight session exports live in the lab data store, not in
  git. They can contain subject identifiers and are large.
- `tms_token.json` (and legacy `tms_token.txt`/`windows_token.txt`),
  `config.json` — the per-install 4-digit shared-secret token and the Mac's
  saved connection details. Generated per-install; must never be committed.
