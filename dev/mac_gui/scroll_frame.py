"""Scrollable container so the window can be resized to any size.

Content goes in `ScrollFrame.interior`. When the window is at least as big as
the content, the content is stretched to fill it (so the Perform log still
grows with the window) and no scrollbars show. When the window is smaller
than the content in either direction, that direction scrolls instead of
clipping the controls off the edge.
"""

import sys
import tkinter as tk
from tkinter import ttk

# How often to check whether the content's requested size changed (switching
# Setup <-> Perform, the target prompt appearing, per-axis threshold mode...).
# The interior's actual size is set by us, so Tk sends no <Configure> for
# those changes on its own.
_REQ_POLL_MS = 200

# Widgets that scroll themselves or change value on the wheel — the wheel is
# left to them rather than also scrolling the page.
_OWN_WHEEL = ("Text", "Scale", "TScale", "TCombobox", "Scrollbar", "TScrollbar")


class ScrollFrame(ttk.Frame):

    def __init__(self, master, **kwargs):
        super().__init__(master, **kwargs)
        self._canvas = tk.Canvas(self, highlightthickness=0, borderwidth=0,
                                 background=self.winfo_toplevel().cget("background"))
        self._vbar = ttk.Scrollbar(self, orient="vertical",
                                   command=self._canvas.yview)
        self._hbar = ttk.Scrollbar(self, orient="horizontal",
                                   command=self._canvas.xview)
        self._canvas.configure(yscrollcommand=self._vbar.set,
                               xscrollcommand=self._hbar.set)
        self._canvas.grid(row=0, column=0, sticky="nsew")
        self.rowconfigure(0, weight=1)
        self.columnconfigure(0, weight=1)

        self.interior = ttk.Frame(self._canvas)
        self._window = self._canvas.create_window(0, 0, window=self.interior,
                                                  anchor="nw")
        self._last = None
        self.bind("<Configure>", lambda _e: self._layout())
        self._poll_request()

        self.bind_all("<MouseWheel>", self._on_wheel, add="+")
        self.bind_all("<Shift-MouseWheel>", self._on_wheel, add="+")
        self.bind_all("<Button-4>", self._on_wheel, add="+")    # X11
        self.bind_all("<Button-5>", self._on_wheel, add="+")

    # ── layout ────────────────────────────────────────────────────────────────

    def _poll_request(self):
        self._layout()
        self.after(_REQ_POLL_MS, self._poll_request)

    def _layout(self):
        # Decide on the scrollbars from THIS frame's size, which showing or
        # hiding them doesn't change — deciding from the canvas size would
        # let a scrollbar appearing flip the decision back (flicker loop).
        outer_w, outer_h = self.winfo_width(), self.winfo_height()
        req_w, req_h = self.interior.winfo_reqwidth(), self.interior.winfo_reqheight()
        state = (outer_w, outer_h, req_w, req_h)
        if state == self._last or outer_w <= 1 or outer_h <= 1:
            return
        self._last = state

        bar_w = self._vbar.winfo_reqwidth()
        bar_h = self._hbar.winfo_reqheight()
        need_v = req_h > outer_h
        need_h = req_w > outer_w - (bar_w if need_v else 0)
        if need_h and not need_v:          # the h-bar itself may cost the room
            need_v = req_h > outer_h - bar_h
        self._show(self._vbar, need_v, row=0, column=1, sticky="ns")
        self._show(self._hbar, need_h, row=1, column=0, sticky="ew")

        view_w = outer_w - (bar_w if need_v else 0)
        view_h = outer_h - (bar_h if need_h else 0)
        width, height = max(view_w, req_w), max(view_h, req_h)
        self._canvas.itemconfigure(self._window, width=width, height=height)
        self._canvas.configure(scrollregion=(0, 0, width, height))

    @staticmethod
    def _show(bar, needed, **grid):
        if needed and not bar.winfo_manager():
            bar.grid(**grid)
        elif not needed and bar.winfo_manager():
            bar.grid_remove()

    # ── mouse wheel ───────────────────────────────────────────────────────────

    def _on_wheel(self, event):
        widget = event.widget
        if not isinstance(widget, tk.Misc) or not self._contains(widget):
            return
        if widget.winfo_class() in _OWN_WHEEL:
            return
        horizontal = bool(event.state & 0x0001)             # Shift held
        bar = self._hbar if horizontal else self._vbar
        if not bar.winfo_manager():                          # nothing to scroll
            return
        if event.num == 4:
            step = -1
        elif event.num == 5:
            step = 1
        elif sys.platform == "darwin" and abs(event.delta) < 120:
            step = -event.delta                              # Tk 8.6: already "lines"
        else:
            step = -int(event.delta / 120) or (-1 if event.delta > 0 else 1)
        view = self._canvas.xview_scroll if horizontal else self._canvas.yview_scroll
        view(step, "units")

    def _contains(self, widget):
        while widget is not None:
            if widget is self:
                return True
            widget = widget.master
        return False
