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

### On the Windows lab machine (receiver)

```powershell
pip install -r trigger_app_AJ\requirements.txt
python -m trigger_app_AJ.windows.main
```

The receiver prints its LAN IP and the shared-secret token. Note both;
you'll paste them on the Mac side.

### On the Mac (Brainsight + alert monitor)

```bash
python3 python/alert_brainsight_v2.2.0.py "/path/to/Streamed Info.txt" \
    --trigger-to <windows-ip>:5050 \
    --token <token-from-windows>
```

The monitor establishes the trigger link first, then waits for the
Brainsight file, then enters an interactive REPL where you can set
per-axis thresholds, switch targets/drivers, and so on.

Without `--trigger-to`, the same script works as a terminal-only drift
monitor (no networking).

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
| Alert monitor         | v2.2.0  | `alert-brainsight-v2.2.0`    |
| Trigger app           | v0.1.0  | `trigger-app-v0.1.0`         |
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
- `tms_token.txt`, `windows_token.txt`, `config.json` — shared-secret
  tokens are generated per-install and must never be committed.
