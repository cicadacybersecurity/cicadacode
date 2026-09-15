"""Kivy-side async helper - replaces the Qt QThreadPool runner.

Same contract as the old gui/services/runner.py: run blocking service
calls off the UI thread, deliver results on the Kivy main loop.
"""
import threading

from kivy.clock import Clock


def run_async(fn, on_done=None, on_failed=None):
    def work():
        try:
            result = fn()
        except Exception as exc:  # surfaced to the UI, never a raw crash
            if on_failed:
                Clock.schedule_once(lambda _dt: on_failed(str(exc)), 0)
            return
        if on_done:
            Clock.schedule_once(lambda _dt: on_done(result), 0)

    threading.Thread(target=work, daemon=True).start()