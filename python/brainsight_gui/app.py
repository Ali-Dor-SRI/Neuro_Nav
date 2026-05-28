"""Brainsight GUI — main window + controller.

Layout:
  ┌─ Window ──────────────────────────────────────────────┐
  │  Module 1 — Setup                                     │
  │    [file path]                          [Browse...]   │
  │    [Windows IP]            [Port]                     │
  │    [Token]                                            │
  │    [Connect & Start]                    ● status      │
  │                                                       │
  │  Module 2 — Perform  (disabled until Setup starts)    │
  │    [Crosshairs driver dropdown]                       │
  │    [Target dropdown]                                  │
  │    [Linear threshold widget]  [Angular threshold w.]  │
  │    ┌─ Status / messages (scrolling log) ──────────┐   │
  │    │ [time] info: Waiting for file to be created  │   │
  │    │ [time] ok:   Connection successful           │   │
  │    │ [time] alert: Outside threshold ...          │   │
  │    └──────────────────────────────────────────────┘   │
  └───────────────────────────────────────────────────────┘
"""

if __name__ == "__main__" and __package__ in (None, ""):
    # Allow `python python/brainsight_gui/app.py` as well as `python -m brainsight_gui`.
    import os, sys
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import tkinter as tk
from tkinter import ttk

from brainsight_gui.monitor_worker import MonitorWorker
from brainsight_gui.perform_panel  import (
    PerformPanel, DEFAULT_LOC_THR, DEFAULT_ANG_THR,
)
from brainsight_gui.setup_panel    import SetupPanel
from brainsight_gui import messages as M


class App:

    def __init__(self, root):
        self.root = root
        self.root.title("Brainsight Drift Monitor")
        self.root.geometry("780x720")
        self.root.minsize(640, 600)

        # UI dispatcher: schedule fn on the Tk main thread
        self._dispatch = lambda fn, *args: self.root.after(0, fn, *args)

        # Worker (backend)
        self.worker = MonitorWorker(ui_dispatch=self._dispatch)

        # Both panels are constructed up front but only one is packed
        # (visible) at a time — wizard-style navigation between Setup and
        # Perform. Their state is preserved across show/hide so Back
        # restores everything intact.
        self.setup = SetupPanel(
            self.root,
            on_next  = self._on_setup_next,
            on_cancel= self._on_setup_cancel,
        )
        self.perform = PerformPanel(
            self.root,
            on_driver_changed = self._on_driver_changed,
            on_target_changed = self._on_target_changed,
            on_linear_changed = self._on_linear_changed,
            on_angular_changed= self._on_angular_changed,
            on_back           = self._on_perform_back,
        )
        self._current_view = None   # set by _show_*
        self._show_setup()

        # Wire worker callbacks back to panel handlers
        self.worker.on_status_message     = self._on_status_message
        self.worker.on_targets_changed    = self._on_targets_changed
        self.worker.on_drivers_changed    = self._on_drivers_changed
        self.worker.on_link_state         = self._on_link_state
        self.worker.on_thresholds_changed = self._on_thresholds_changed

        # Apply default thresholds to the panel
        self.perform.set_linear_threshold([DEFAULT_LOC_THR] * 3)
        self.perform.set_angular_threshold([DEFAULT_ANG_THR] * 3)

        self.root.protocol("WM_DELETE_WINDOW", self.shutdown)

    # ── View switching ───────────────────────────────────────────────────────

    def _show_setup(self):
        if self._current_view == "setup":
            return
        try: self.perform.pack_forget()
        except Exception: pass
        self.setup.pack(fill="both", expand=True, padx=10, pady=10)
        self._current_view = "setup"

    def _show_perform(self):
        if self._current_view == "perform":
            return
        try: self.setup.pack_forget()
        except Exception: pass
        self.perform.pack(fill="both", expand=True, padx=10, pady=10)
        self._current_view = "perform"

    # ── Setup -> Worker ──────────────────────────────────────────────────────

    def _on_setup_next(self, filepath, host, port, token):
        """User clicked Next on Setup. Start the worker; transition to
        Perform happens later, when the TCP link comes up."""
        self.worker.configure(filepath=filepath,
                              trigger_host=host,
                              trigger_port=port,
                              trigger_token=token)
        self.worker.set_linear_threshold(self.perform._linear_widget.get())
        self.worker.set_angular_threshold(self.perform._angular_widget.get())
        ok = self.worker.start()
        if not ok:
            # validation failure inside the worker — already logged.
            self.setup.reset_to_idle()
            return
        # Stay on Setup; _on_link_state will switch us to Perform when
        # the receiver answers AUTH:OK.

    def _on_setup_cancel(self):
        """User clicked Cancel during the connection attempt."""
        self.worker.stop()

    # ── Perform -> Worker ────────────────────────────────────────────────────

    def _on_perform_back(self):
        """User clicked Back on Perform. Stop the worker; go back to Setup.
        All UI state (dropdowns, sliders, log) is preserved per spec."""
        self.worker.stop()
        self.setup.reset_to_idle()
        self._show_setup()

    # ── Perform -> Worker ────────────────────────────────────────────────────

    def _on_driver_changed(self, name):
        self.worker.set_driver(name)

    def _on_target_changed(self, name):
        self.worker.set_target(name)

    def _on_linear_changed(self, vec):
        self.worker.set_linear_threshold(vec)

    def _on_angular_changed(self, vec):
        self.worker.set_angular_threshold(vec)

    # ── Worker -> UI (already on Tk thread; ui_dispatch routed it here) ─────

    def _on_status_message(self, level, message):
        self.perform.append_message(level, message)

    def _on_targets_changed(self, names, active):
        self.perform.populate_targets(names, active)

    def _on_drivers_changed(self, names, active):
        self.perform.populate_drivers(names, active)

    def _on_link_state(self, connected, info):
        # Still mirror the state on Setup (relevant while still on Setup
        # waiting to connect, AND if the user presses Back later).
        self.setup.set_link_state(connected, info)
        # Mirror on Perform as well so a mid-session drop is visible.
        self.perform.set_link_status(connected, info)

        # Auto-advance from Setup to Perform on the first successful
        # connection. After that, link drops are handled by the worker's
        # reconnect loop and we stay on Perform.
        if connected and self._current_view == "setup":
            self.perform.set_enabled(True)
            self._show_perform()

    def _on_thresholds_changed(self, loc, ang):
        # Don't push back into the widgets every poll — only when the
        # values came from somewhere other than the widget itself
        # (currently only worker.set_*_threshold sends this, so noop).
        pass

    # ── Shutdown ─────────────────────────────────────────────────────────────

    def shutdown(self):
        try:
            self.worker.stop()
        except Exception:
            pass
        self.root.destroy()


def main():
    root = tk.Tk()
    # Use a modern ttk theme where available
    style = ttk.Style()
    try:
        if "aqua" in style.theme_names():
            style.theme_use("aqua")        # macOS native
        elif "vista" in style.theme_names():
            style.theme_use("vista")       # Windows native
        elif "clam" in style.theme_names():
            style.theme_use("clam")        # cleaner cross-platform fallback
    except tk.TclError:
        pass
    App(root)
    root.mainloop()


if __name__ == "__main__":
    main()
