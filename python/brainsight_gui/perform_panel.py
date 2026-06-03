"""Module 2: Perform panel.

Active controls during a session:
  * Crosshairs driver dropdown (Combobox)
  * Target dropdown (Combobox)
  * Linear threshold widget (mm) -- 0..200, default 40
  * Angular threshold widget (rad) -- 0..1.5708, default 0.20
  * Scrolling message log at the bottom

Until the worker has been started (Setup -> Connect & Start), the panel
is disabled.
"""

from datetime import datetime
import tkinter as tk
from tkinter import ttk

from brainsight_gui import messages as M
from brainsight_gui.threshold_widget import ThresholdWidget

DEFAULT_LOC_THR = 40.0
DEFAULT_ANG_THR = 0.20

LOC_MIN, LOC_MAX = 0.0, 200.0      # mm
ANG_MIN, ANG_MAX = 0.0, 1.5708     # rad (~90 degrees)


class PerformPanel(ttk.LabelFrame):

    def __init__(self, master,
                 on_driver_changed=None,
                 on_target_changed=None,
                 on_linear_changed=None,
                 on_angular_changed=None,
                 on_follow_toggled=None,
                 on_back=None,
                 **kwargs):
        super().__init__(master, text="Module 2 — Perform", padding=10, **kwargs)
        self._on_driver_changed  = on_driver_changed  or (lambda name: None)
        self._on_target_changed  = on_target_changed  or (lambda name: None)
        self._on_linear_changed  = on_linear_changed  or (lambda vec: None)
        self._on_angular_changed = on_angular_changed or (lambda vec: None)
        self._on_follow_toggled  = on_follow_toggled  or (lambda enabled: None)
        self._on_back            = on_back            or (lambda: None)

        self._enabled = False  # Setup must run before this becomes active
        self._build()
        self.set_enabled(False)

    # ── widgets ───────────────────────────────────────────────────────────────

    def _build(self):
        # ─ Top bar: Back button + link status ─
        top_bar = ttk.Frame(self); top_bar.pack(fill="x", pady=(0, 8))
        self._back_btn = ttk.Button(top_bar, text="← Back", command=self._on_back_clicked)
        self._back_btn.pack(side="left")
        self._link_status = ttk.Label(top_bar, text="", foreground="#1a7f1a")
        self._link_status.pack(side="right")

        # ─ Dropdowns row ─
        dd_frame = ttk.Frame(self); dd_frame.pack(fill="x", pady=(0, 8))

        ttk.Label(dd_frame, text="Crosshairs driver:",
                  width=18, anchor="e").grid(row=0, column=0, sticky="e", padx=(0,6))
        self._driver_var = tk.StringVar()
        self._driver_combo = ttk.Combobox(dd_frame, textvariable=self._driver_var,
                                           state="readonly", width=32)
        self._driver_combo.grid(row=0, column=1, sticky="ew", pady=(0, 4))
        self._driver_combo.bind("<<ComboboxSelected>>", self._on_driver_select)

        ttk.Label(dd_frame, text="Target:",
                  width=18, anchor="e").grid(row=1, column=0, sticky="e", padx=(0,6))
        self._target_var = tk.StringVar()
        self._target_combo = ttk.Combobox(dd_frame, textvariable=self._target_var,
                                           state="readonly", width=32)
        self._target_combo.grid(row=1, column=1, sticky="ew")
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
        self._follow_check.grid(row=2, column=1, sticky="w", pady=(4, 0))

        dd_frame.columnconfigure(1, weight=1)

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
        self._log = tk.Text(log_frame, height=10, width=80, state="disabled",
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
