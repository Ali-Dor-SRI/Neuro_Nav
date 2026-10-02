"""Reusable threshold widget: a title row + general/3-DoF toggle, then
either 1 slider (general) or 3 sliders (X/Y/Z, 3-DoF), each with an
editable numeric value field beneath.

The widget is value-driven: it owns a 3-tuple of floats internally. In
'general' mode all three are kept equal; in '3-DoF' mode they're
independent. Whenever the user moves a slider or commits the value
field, on_change(vec3) fires with the new 3-tuple.
"""

import tkinter as tk
from tkinter import ttk

AXIS_NAMES = ("X", "Y", "Z")


class ThresholdWidget(ttk.LabelFrame):
    """LabelFrame containing the slider(s), mode toggle, and value entries."""

    def __init__(self, master, label, unit,
                 min_value, max_value, default_value,
                 value_fmt="{:.2f}",
                 on_change=None,
                 **kwargs):
        """
        Args:
            label:      title shown at top (e.g. "Linear threshold")
            unit:       displayed after numbers (e.g. "mm" or "rad")
            min_value:  slider minimum (inclusive)
            max_value:  slider maximum (inclusive)
            default_value: initial value, applied to all 3 axes
            value_fmt:  format spec for displaying the value (e.g. "{:.1f}")
            on_change:  callable(vec3: list[float]) fired on every change
        """
        super().__init__(master, text=label, padding=(10, 6, 10, 8), **kwargs)
        self._label = label
        self._unit = unit
        self._min = min_value
        self._max = max_value
        self._fmt = value_fmt
        self._on_change = on_change or (lambda vec: None)

        # Internal state — always length 3
        self._values = [float(default_value)] * 3
        self._suspend_callbacks = False   # avoid re-entrant updates while syncing

        # Mode toggle var
        self._mode_var = tk.StringVar(value="general")

        self._build()
        self._apply_mode()   # initial layout

    # ── public API ────────────────────────────────────────────────────────────

    def get(self):
        """Return the current 3-tuple as a plain list."""
        return list(self._values)

    def set(self, vec3):
        """Programmatically set values. Sync widgets. Does NOT fire on_change."""
        self._suspend_callbacks = True
        try:
            self._values = [float(v) for v in vec3]
            # If all 3 are equal, leave mode alone; otherwise force 3-DoF.
            if not (self._values[0] == self._values[1] == self._values[2]):
                self._mode_var.set("3dof")
                self._apply_mode()
            for i in range(3):
                self._sync_axis_widgets(i)
        finally:
            self._suspend_callbacks = False

    # ── widget construction ──────────────────────────────────────────────────

    def _build(self):
        # Mode row
        mode_row = ttk.Frame(self)
        mode_row.pack(fill="x", pady=(0, 6))
        ttk.Label(mode_row, text="Mode:").pack(side="left")
        ttk.Radiobutton(mode_row, text="general",
                        variable=self._mode_var, value="general",
                        command=self._on_mode_change).pack(side="left", padx=(6, 4))
        ttk.Radiobutton(mode_row, text="3 DoF",
                        variable=self._mode_var, value="3dof",
                        command=self._on_mode_change).pack(side="left", padx=(0, 4))

        # Slider rows (always built; visibility toggled by mode)
        self._axis_frames = []
        self._scales      = []
        self._entry_vars  = []
        self._entries     = []

        for i in range(3):
            f = ttk.Frame(self)
            self._axis_frames.append(f)

            header = ttk.Frame(f); header.pack(fill="x")
            self._axis_labels = getattr(self, "_axis_labels", [])
            axis_label = ttk.Label(header, text=AXIS_NAMES[i], width=2)
            axis_label.pack(side="left")
            self._axis_labels.append(axis_label)
            ttk.Label(header, text=f"({self._min:.1f} - {self._max:.1f} {self._unit})",
                      foreground="#777").pack(side="right")

            scale = ttk.Scale(f, from_=self._min, to=self._max, orient="horizontal",
                              value=self._values[i],
                              command=lambda v, idx=i: self._on_scale(idx, v))
            scale.pack(fill="x", pady=(2, 2))
            self._scales.append(scale)

            entry_row = ttk.Frame(f); entry_row.pack(fill="x")
            var = tk.StringVar(value=self._fmt.format(self._values[i]))
            entry = ttk.Entry(entry_row, textvariable=var, width=10, justify="right")
            entry.pack(side="left")
            entry.bind("<Return>",   lambda e, idx=i: self._on_entry_commit(idx))
            entry.bind("<FocusOut>", lambda e, idx=i: self._on_entry_commit(idx))
            ttk.Label(entry_row, text=self._unit, foreground="#555").pack(
                side="left", padx=(4, 0))
            self._entry_vars.append(var)
            self._entries.append(entry)

    # ── mode handling ─────────────────────────────────────────────────────────

    def _on_mode_change(self):
        # When switching to 'general', collapse all 3 to the X value.
        if self._mode_var.get() == "general":
            v = self._values[0]
            self._values = [v, v, v]
            for i in range(3):
                self._sync_axis_widgets(i)
            self._fire_change()
        self._apply_mode()

    def _apply_mode(self):
        # Show only axis 0 in general mode; show all 3 in 3-DoF.
        # Also hide the "X" label in general mode (no axis identity needed).
        for f in self._axis_frames:
            f.pack_forget()
        if self._mode_var.get() == "general":
            self._axis_frames[0].pack(fill="x")
            self._axis_labels[0].configure(text="")
        else:
            for i in range(3):
                self._axis_frames[i].pack(fill="x", pady=(0, 2))
                self._axis_labels[i].configure(text=AXIS_NAMES[i])

    # ── input handlers ────────────────────────────────────────────────────────

    def _on_scale(self, idx, value):
        if self._suspend_callbacks:
            return
        try:
            v = float(value)
        except (TypeError, ValueError):
            return
        self._values[idx] = v
        if self._mode_var.get() == "general":
            # Mirror to all axes
            for j in range(3):
                self._values[j] = v
                self._sync_axis_widgets(j)
        else:
            self._sync_entry_only(idx)
        self._fire_change()

    def _on_entry_commit(self, idx):
        if self._suspend_callbacks:
            return
        try:
            v = float(self._entry_vars[idx].get())
        except ValueError:
            # invalid input - revert to current value
            self._sync_entry_only(idx)
            return
        # Clamp to slider range for the slider; let entry show the typed value
        v = max(self._min, min(self._max, v))
        self._values[idx] = v
        if self._mode_var.get() == "general":
            for j in range(3):
                self._values[j] = v
                self._sync_axis_widgets(j)
        else:
            self._sync_axis_widgets(idx)
        self._fire_change()

    # ── helpers ───────────────────────────────────────────────────────────────

    def _sync_axis_widgets(self, idx):
        """Push self._values[idx] into both the scale and the entry."""
        self._suspend_callbacks = True
        try:
            self._scales[idx].set(self._values[idx])
            self._entry_vars[idx].set(self._fmt.format(self._values[idx]))
        finally:
            self._suspend_callbacks = False

    def _sync_entry_only(self, idx):
        self._suspend_callbacks = True
        try:
            self._entry_vars[idx].set(self._fmt.format(self._values[idx]))
        finally:
            self._suspend_callbacks = False

    def _fire_change(self):
        if not self._suspend_callbacks:
            self._on_change(list(self._values))
