"""Module 1: Setup panel.

Collects the inputs the worker needs to start:
  * Participant / study code for this session
  * Brainsight .txt file path (with a Browse... button)
  * Windows machine IP
  * Windows machine TCP port (default 5050)
  * Auth token shown in the Windows receiver

The participant ID is entered here rather than on the Windows receiver: the
receiver types `ss` into whatever window has focus, so typing on that machine
mid-session could swallow a trigger meant for QTrack. It is sent over the
trigger link and Windows stamps it on every time-sync log row. Like the file
path — and unlike the connection details — it is deliberately NOT persisted
between launches: it changes every session, and it is participant data.

Navigation:
  * "Next ->" button fires `on_next(participant, filepath, host, port, token)`. The
    controller starts the worker; the link comes up asynchronously. The
    button transforms into "Cancel" and the fields lock while we wait.
  * "Cancel" fires `on_cancel()` (controller stops the worker). Fields
    unlock and the button reverts to "Next ->".
  * Once the link is established the controller hides this panel and
    shows the Perform panel; this panel's state is preserved so a
    later "Back" press from Perform restores everything intact.
"""

import tkinter as tk
from tkinter import filedialog, ttk

DEFAULT_PORT = 5050


class SetupPanel(ttk.LabelFrame):

    def __init__(self, master, on_next=None, on_cancel=None, **kwargs):
        super().__init__(master, text="Module 1 — Setup", padding=10, **kwargs)
        self._on_next   = on_next   or (lambda *a, **kw: None)
        self._on_cancel = on_cancel or (lambda: None)

        self._participant_var = tk.StringVar()
        self._file_var  = tk.StringVar()
        self._ip_var    = tk.StringVar()
        self._port_var  = tk.StringVar(value=str(DEFAULT_PORT))
        self._token_var = tk.StringVar()

        # State: "idle" (fields editable, Next button shown)
        #        "connecting" (fields locked, Cancel button shown)
        self._state = "idle"

        self._build()

    # ── public API ────────────────────────────────────────────────────────────

    def prefill(self, windows_ip=None, port=None, token=None):
        """Populate saved connection fields on launch. Empty/None values are
        left at their current defaults. The Brainsight file path is never
        prefilled (it changes per session)."""
        if windows_ip:
            self._ip_var.set(str(windows_ip))
        if port:
            self._port_var.set(str(port))
        if token:
            self._token_var.set(str(token))

    def set_link_state(self, connected, info=""):
        """Called by the controller to reflect the current TCP link state."""
        if connected:
            self._status_dot.config(foreground="#1a7f1a")  # green
            self._status_text.config(text=f"Connected to {info}" if info else "Connected")
        elif self._state == "connecting":
            self._status_dot.config(foreground="#d4a017")  # amber
            self._status_text.config(text="Connecting...")
        else:
            self._status_dot.config(foreground="#c0392b")  # red
            self._status_text.config(text="Not connected")

    # ── widget construction ──────────────────────────────────────────────────

    def _build(self):
        # Participant row — first, because it labels everything the session
        # writes. Sent to Windows and stamped on the time-sync log.
        row = ttk.Frame(self); row.pack(fill="x", pady=(0, 4))
        ttk.Label(row, text="Participant ID:", width=18, anchor="e").pack(side="left")
        self._participant_entry = ttk.Entry(row, textvariable=self._participant_var)
        self._participant_entry.pack(side="left", fill="x", expand=True, padx=(6, 0))
        row = ttk.Frame(self); row.pack(fill="x", pady=(0, 6))
        ttk.Label(row, text="", width=18).pack(side="left")
        ttk.Label(row, text="Study code only (e.g. SNBR-000) — never a name. "
                            "Recorded in the Windows time-sync log.",
                  foreground="#777").pack(side="left", padx=(6, 0))

        # File path row
        row = ttk.Frame(self); row.pack(fill="x", pady=(0, 4))
        ttk.Label(row, text="Brainsight file:", width=18, anchor="e").pack(side="left")
        self._file_entry = ttk.Entry(row, textvariable=self._file_var)
        self._file_entry.pack(side="left", fill="x", expand=True, padx=(6, 4))
        self._browse_btn = ttk.Button(row, text="Browse...", command=self._on_browse)
        self._browse_btn.pack(side="left")

        # Windows IP + port row
        row = ttk.Frame(self); row.pack(fill="x", pady=(0, 4))
        ttk.Label(row, text="Windows IP:", width=18, anchor="e").pack(side="left")
        self._ip_entry = ttk.Entry(row, textvariable=self._ip_var)
        self._ip_entry.pack(side="left", fill="x", expand=True, padx=(6, 4))
        ttk.Label(row, text="Port:").pack(side="left")
        self._port_entry = ttk.Entry(row, textvariable=self._port_var, width=6,
                                      justify="right")
        self._port_entry.pack(side="left", padx=(4, 0))

        # Token row
        row = ttk.Frame(self); row.pack(fill="x", pady=(0, 8))
        ttk.Label(row, text="Auth token:", width=18, anchor="e").pack(side="left")
        self._token_entry = ttk.Entry(row, textvariable=self._token_var)
        self._token_entry.pack(side="left", fill="x", expand=True, padx=(6, 0))

        # Action row — Next on the right (wizard-style), status indicator on left
        row = ttk.Frame(self); row.pack(fill="x")

        status_row = ttk.Frame(row); status_row.pack(side="left")
        self._status_dot = ttk.Label(status_row, text="●",
                                      font=("Helvetica", 14), foreground="#c0392b")
        self._status_dot.pack(side="left")
        self._status_text = ttk.Label(status_row, text="Not connected",
                                       foreground="#555")
        self._status_text.pack(side="left", padx=(4, 0))

        self._action_btn = ttk.Button(row, text="Next →",
                                      command=self._on_action_clicked)
        self._action_btn.pack(side="right")

    # ── handlers ──────────────────────────────────────────────────────────────

    def _on_browse(self):
        path = filedialog.askopenfilename(
            title="Select Brainsight Streamed Info .txt",
            filetypes=[("Text files", "*.txt"), ("All files", "*.*")],
        )
        if path:
            self._file_var.set(path)

    def _on_action_clicked(self):
        if self._state == "connecting":
            # User wants out -- cancel the connection attempt.
            self._enter_idle()
            self._on_cancel()
            return

        # idle -> connecting. Validate inputs first.
        # Normalize in the field itself, so what the operator sees is exactly
        # what gets recorded in the Windows time-sync log.
        participant = " ".join(self._participant_var.get().split())
        self._participant_var.set(participant)
        path  = self._file_var.get().strip()
        ip    = self._ip_var.get().strip()
        port_s= self._port_var.get().strip()
        token = self._token_var.get().strip()

        # Required: an unlabelled time-sync row can't be matched to a
        # participant afterwards, which is the whole point of recording it.
        if not participant:
            self._flash_invalid(self._participant_entry); return
        if not path:
            self._flash_invalid(self._file_entry); return
        if not ip:
            self._flash_invalid(self._ip_entry); return
        try:
            port = int(port_s)
            if not (1 <= port <= 65535):
                raise ValueError()
        except ValueError:
            self._flash_invalid(self._port_entry); return
        if not token:
            self._flash_invalid(self._token_entry); return

        self._enter_connecting()
        self._on_next(participant, path, ip, port, token)

    def reset_to_idle(self):
        """Called by the controller after Back from Perform -- restores idle UI."""
        self._enter_idle()

    def _enter_idle(self):
        self._state = "idle"
        self._set_fields_locked(False)
        self._action_btn.config(text="Next →")
        self.set_link_state(False)

    def _enter_connecting(self):
        self._state = "connecting"
        self._set_fields_locked(True)
        self._action_btn.config(text="Cancel")
        self._status_text.config(text="Connecting...")
        self._status_dot.config(foreground="#d4a017")   # amber while waiting

    def _set_fields_locked(self, locked):
        state = "disabled" if locked else "normal"
        for w in (self._participant_entry, self._file_entry, self._browse_btn,
                  self._ip_entry, self._port_entry, self._token_entry):
            w.config(state=state)

    def _flash_invalid(self, widget):
        """Briefly highlight a widget that failed validation."""
        try:
            orig = widget.cget("foreground")
        except tk.TclError:
            orig = "black"
        widget.config(foreground="#c0392b")
        widget.after(800, lambda: widget.config(foreground=orig))
        try:
            widget.focus_set()
        except tk.TclError:
            pass
