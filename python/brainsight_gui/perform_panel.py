"""Module 2: Perform panel.

Active controls during a session:
  * Crosshairs driver dropdown (Combobox) + coil-follow checkbox
  * Target dropdown (Combobox)
  * Linear threshold widget (mm) -- 0..200, default 40
  * Angular threshold widget (rad) -- 0..1.5708, default 0.20
  * Scrolling message log at the bottom

Until the worker has been started (Setup -> Connect & Start), the panel
is disabled.
"""

from datetime import datetime
import tkinter as tk
from tkinter import font as tkfont
from tkinter import ttk

from brainsight_gui import messages as M
from brainsight_gui.threshold_widget import ThresholdWidget

DEFAULT_LOC_THR = 40.0
DEFAULT_ANG_THR = 0.20

LOC_MIN, LOC_MAX = 0.0, 200.0      # mm
ANG_MIN, ANG_MAX = 0.0, 1.5708     # rad (~90 degrees)

PROMPT_BG = "#fdecea"              # target-prompt banner (alert red on pink)
PROMPT_FG = "#c0392b"


class PerformPanel(ttk.LabelFrame):

    def __init__(self, master,
                 on_driver_changed=None,
                 on_target_changed=None,
                 on_linear_changed=None,
                 on_angular_changed=None,
                 on_follow_toggled=None,
                 on_coil_follow_toggled=None,
                 on_triggers_toggled=None,
                 on_keep_target=None,
                 on_back=None,
                 **kwargs):
        super().__init__(master, text="Module 2 — Perform", padding=10, **kwargs)
        self._on_driver_changed  = on_driver_changed  or (lambda name: None)
        self._on_target_changed  = on_target_changed  or (lambda name: None)
        self._on_linear_changed  = on_linear_changed  or (lambda vec: None)
        self._on_angular_changed = on_angular_changed or (lambda vec: None)
        self._on_follow_toggled  = on_follow_toggled  or (lambda enabled: None)
        self._on_coil_follow_toggled = on_coil_follow_toggled or (lambda enabled: None)
        self._on_triggers_toggled= on_triggers_toggled or (lambda enabled: None)
        self._on_keep_target     = on_keep_target     or (lambda: None)
        self._on_back           = on_back            or (lambda: None)

        self._enabled = False  # Setup must run before this becomes active
        self._build()
        self.set_enabled(False)

    # ── widgets ───────────────────────────────────────────────────────────────

    def _build(self):
        # ─ Top bar: Back button + link status ─
        top_bar = self._top_bar = ttk.Frame(self)
        top_bar.pack(fill="x", pady=(0, 8))
        self._back_btn = ttk.Button(top_bar, text="← Back", command=self._on_back_clicked)
        self._back_btn.pack(side="left")
        # Who this session is being logged under — read-only here; change it by
        # going Back to Setup, which reconnects and re-stamps a fresh sync row.
        self._participant_label = ttk.Label(top_bar, text="", foreground="#333")
        self._participant_label.pack(side="left", padx=(12, 0))
        self._link_status = ttk.Label(top_bar, text="", foreground="#1a7f1a")
        self._link_status.pack(side="right")

        # ─ Target prompt (hidden until a coil swap leaves the target as is) ─
        # Explicit line breaks rather than wraplength, so the banner's width
        # never depends on the window's and can't fight the scroll container.
        self._prompt_frame = tk.Frame(self, background=PROMPT_BG,
                                      highlightthickness=1,
                                      highlightbackground=PROMPT_FG,
                                      padx=10, pady=6)
        self._prompt_label = tk.Label(self._prompt_frame, text="",
                                      justify="left", anchor="w",
                                      background=PROMPT_BG, foreground=PROMPT_FG)
        bold = tkfont.nametofont("TkDefaultFont").copy()
        bold.configure(weight="bold")
        self._prompt_label.configure(font=bold)
        self._prompt_label.pack(fill="x")
        prompt_btns = tk.Frame(self._prompt_frame, background=PROMPT_BG)
        prompt_btns.pack(fill="x", pady=(6, 0))
        ttk.Button(prompt_btns, text="Keep current target",
                   command=self._on_keep_target_clicked).pack(side="left")
        tk.Label(prompt_btns, text="or pick a target from the Target dropdown",
                 background=PROMPT_BG, foreground=PROMPT_FG).pack(
                     side="left", padx=(8, 0))

        # ─ Dropdowns row ─
        dd_frame = ttk.Frame(self); dd_frame.pack(fill="x", pady=(0, 8))

        ttk.Label(dd_frame, text="Crosshairs driver:",
                  width=18, anchor="e").grid(row=0, column=0, sticky="e", padx=(0,6))
        self._driver_var = tk.StringVar()
        self._driver_combo = ttk.Combobox(dd_frame, textvariable=self._driver_var,
                                           state="readonly", width=32)
        self._driver_combo.grid(row=0, column=1, sticky="ew", pady=(0, 4))
        self._driver_combo.bind("<<ComboboxSelected>>", self._on_driver_select)

        # Coil-follow: when checked, the driver tracks the coil selected in
        # Brainsight (a coil swap switches it). Picking from the dropdown
        # above pins a driver and clears this automatically.
        self._coil_follow_var = tk.BooleanVar(value=True)
        self._coil_follow_check = ttk.Checkbutton(
            dd_frame,
            text="Auto-follow coil selected in Brainsight",
            variable=self._coil_follow_var,
            command=self._on_coil_follow_toggle)
        self._coil_follow_check.grid(row=1, column=1, sticky="w", pady=(0, 8))

        ttk.Label(dd_frame, text="Target:",
                  width=18, anchor="e").grid(row=2, column=0, sticky="e", padx=(0,6))
        self._target_var = tk.StringVar()
        self._target_combo = ttk.Combobox(dd_frame, textvariable=self._target_var,
                                           state="readonly", width=32)
        self._target_combo.grid(row=2, column=1, sticky="ew")
        self._target_combo.bind("<<ComboboxSelected>>", self._on_target_select)

        # Auto-follow: when checked, the active target tracks the most-recently
        # selected target in the Brainsight file. Picking from the dropdown
        # above pins a target and clears this automatically.
        self._follow_var = tk.BooleanVar(value=True)
        self._follow_check = ttk.Checkbutton(
            dd_frame,
            text="Auto-follow target selected in the Brainsight file",
            variable=self._follow_var,
            command=self._on_follow_toggle)
        self._follow_check.grid(row=3, column=1, sticky="w", pady=(4, 0))

        dd_frame.columnconfigure(1, weight=1)

        # ─ TMS triggering switch ─
        # Clinically significant: when OFF, no SS start/stop keystrokes are sent
        # to QTrack — the app only time-syncs and monitors distance. Pure gate,
        # so flipping it never itself types into QTrack. Defaults ON.
        trig_frame = ttk.LabelFrame(self, text="TMS triggering", padding=(8, 4))
        trig_frame.pack(fill="x", pady=(0, 8))
        self._triggers_var = tk.BooleanVar(value=True)
        self._triggers_check = ttk.Checkbutton(
            trig_frame,
            text="Send TMS triggers (SS start/stop to QTrack)",
            variable=self._triggers_var,
            command=self._on_triggers_toggle)
        self._triggers_check.pack(side="left")
        self._triggers_status = ttk.Label(trig_frame, text="")
        self._triggers_status.pack(side="right")
        self._reflect_triggers_status(True)

        # ─ Threshold widgets (side by side) ─
        thr_frame = ttk.Frame(self); thr_frame.pack(fill="x", pady=(0, 8))
        self._linear_widget = ThresholdWidget(
            thr_frame, label="Linear threshold", unit="mm",
            min_value=LOC_MIN, max_value=LOC_MAX, default_value=DEFAULT_LOC_THR,
            value_fmt="{:.1f}",
            on_change=self._on_linear)
        self._linear_widget.pack(side="left", fill="both", expand=True, padx=(0, 6))

        self._angular_widget = ThresholdWidget(
            thr_frame, label="Angular threshold", unit="rad",
            min_value=ANG_MIN, max_value=ANG_MAX, default_value=DEFAULT_ANG_THR,
            value_fmt="{:.3f}",
            on_change=self._on_angular)
        self._angular_widget.pack(side="left", fill="both", expand=True, padx=(6, 0))

        # ─ Message log ─
        log_frame = ttk.LabelFrame(self, text="Status / messages", padding=(6, 4))
        log_frame.pack(fill="both", expand=True)
        # Small requested size: the log fills whatever room the window gives
        # it, and a small request lets the window shrink before it scrolls.
        self._log = tk.Text(log_frame, height=6, width=40, state="disabled",
                            font=("Menlo", 10), wrap="word", padx=4, pady=2)
        log_scroll = ttk.Scrollbar(log_frame, command=self._log.yview)
        self._log.configure(yscrollcommand=log_scroll.set)
        self._log.pack(side="left", fill="both", expand=True)
        log_scroll.pack(side="right", fill="y")

        # Pre-configure tags for each level color
        for level, color in M.LEVEL_COLORS.items():
            self._log.tag_configure(level, foreground=color)

    # ── public API (called by App / controller) ──────────────────────────────

    def set_enabled(self, enabled):
        """Lock/unlock all interactive widgets (Back stays available)."""
        self._enabled = enabled
        state = "readonly" if enabled else "disabled"
        self._driver_combo.config(state=state)
        self._target_combo.config(state=state)
        self._follow_check.config(state="normal" if enabled else "disabled")
        self._coil_follow_check.config(state="normal" if enabled else "disabled")
        self._triggers_check.config(state="normal" if enabled else "disabled")
        # ThresholdWidget contains sliders and entries; toggle children
        for child in self._iter_threshold_children():
            try:
                child.config(state="normal" if enabled else "disabled")
            except tk.TclError:
                pass

    def set_link_status(self, connected, info=""):
        if connected:
            self._link_status.config(
                text=f"● Link: {info}" if info else "● Link: connected",
                foreground="#1a7f1a")
        else:
            self._link_status.config(text="● Link: lost — reconnecting...",
                                      foreground="#c0392b")

    def set_participant(self, participant):
        """Show the study code this session's time-sync rows are logged under."""
        self._participant_label.config(
            text=f"Participant: {participant}" if participant else "")

    def populate_drivers(self, names, active=None):
        self._driver_combo["values"] = list(names)
        if active is not None and active in names:
            self._driver_var.set(active)
        elif names and not self._driver_var.get():
            self._driver_var.set(names[0])

    def populate_targets(self, names, active=None):
        self._target_combo["values"] = list(names)
        if active is not None and active in names:
            self._target_var.set(active)
        elif names and not self._target_var.get():
            self._target_var.set(names[0])

    def set_follow(self, enabled):
        """Reflect the worker's auto-follow state in the checkbox. Setting the
        variable programmatically does NOT fire the command callback, so this
        won't loop back into the worker."""
        self._follow_var.set(bool(enabled))

    def set_coil_follow(self, enabled):
        """Reflect the worker's coil-follow state in its checkbox (no
        callback fires, so this won't loop back into the worker)."""
        self._coil_follow_var.set(bool(enabled))

    def set_triggers(self, enabled):
        """Reflect the worker's trigger-gate state in the checkbox + status
        label. Setting the variable programmatically does NOT fire the command
        callback, so this won't loop back into the worker."""
        enabled = bool(enabled)
        self._triggers_var.set(enabled)
        self._reflect_triggers_status(enabled)

    def _reflect_triggers_status(self, enabled):
        """Update the little colored state label next to the switch."""
        if enabled:
            self._triggers_status.config(text="● ON — sending SS to QTrack",
                                         foreground="#1a7f1a")
        else:
            self._triggers_status.config(
                text="○ OFF — monitoring + time-sync only",
                foreground="#b87515")

    def show_target_prompt(self, coil, target):
        """Ask the operator to pick the target for a newly swapped-in coil."""
        self._prompt_label.config(
            text=(f"Coil changed to {coil}, but the target was not changed.\n"
                  f"Still measuring against '{target}'. "
                  f"Is that the right target for {coil}?"))
        if not self._prompt_frame.winfo_manager():
            self._prompt_frame.pack(fill="x", pady=(0, 8), after=self._top_bar)

    def hide_target_prompt(self):
        self._prompt_frame.pack_forget()

    def set_linear_threshold(self, vec3):
        self._linear_widget.set(vec3)

    def set_angular_threshold(self, vec3):
        self._angular_widget.set(vec3)

    def append_message(self, level, message):
        timestamp = datetime.now().strftime("%H:%M:%S")
        line = f"[{timestamp}] {message}\n"
        self._log.configure(state="normal")
        self._log.insert("end", line, level)
        # Cap log size to avoid pathological memory use over a long session
        line_count = int(self._log.index("end-1c").split(".")[0])
        if line_count > 1000:
            self._log.delete("1.0", "200.0")
        self._log.see("end")
        self._log.configure(state="disabled")

    # ── handlers (forward to controller) ─────────────────────────────────────

    def _on_back_clicked(self):
        self._on_back()

    def _on_keep_target_clicked(self):
        self._on_keep_target()

    def _on_driver_select(self, _evt=None):
        name = self._driver_var.get()
        if name:
            self._on_driver_changed(name)

    def _on_target_select(self, _evt=None):
        name = self._target_var.get()
        if name:
            self._on_target_changed(name)

    def _on_follow_toggle(self):
        self._on_follow_toggled(self._follow_var.get())

    def _on_coil_follow_toggle(self):
        self._on_coil_follow_toggled(self._coil_follow_var.get())

    def _on_triggers_toggle(self):
        # Reflect immediately for snappy feedback; the worker's
        # on_triggers_changed callback will also call set_triggers (idempotent).
        enabled = self._triggers_var.get()
        self._reflect_triggers_status(enabled)
        self._on_triggers_toggled(enabled)

    def _on_linear(self, vec):
        if self._enabled:
            self._on_linear_changed(vec)

    def _on_angular(self, vec):
        if self._enabled:
            self._on_angular_changed(vec)

    # ── helpers ───────────────────────────────────────────────────────────────

    def _iter_threshold_children(self):
        """Walk into the threshold widgets and yield every Scale/Entry/Radiobutton."""
        for parent in (self._linear_widget, self._angular_widget):
            for w in _walk(parent):
                if isinstance(w, (ttk.Scale, ttk.Entry, ttk.Radiobutton)):
                    yield w


def _walk(widget):
    """Yield widget and all descendants."""
    yield widget
    for child in widget.winfo_children():
        yield from _walk(child)
