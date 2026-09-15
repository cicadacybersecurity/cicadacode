"""CICADA Desktop entry point (Kivy):  python gui/app.py  from the project root.

The presentation layer is Kivy; the backend (gui/services/*) is untouched.
Aero Day is the default and the primary art direction.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

os.environ.setdefault("KIVY_NO_ARGS", "1")

from kivy.app import App
from kivy.core.window import Window

from gui import theme

# Set window minimums BEFORE the native window is created (i.e. before
# CicadaApp().run()). Assigning minimum_width/minimum_height from build()
# applies them one property at a time to an already-created window, and the
# intermediate state (width set, height still 0) is exactly what triggers
# Kivy's "Both Window.minimum_width and Window.minimum_height must be bigger
# than 0" warning. Set early, and both values are present together when the
# size restriction is first applied.
theme.window_setup()

from gui.main_window import MainWindow
from gui.services.config import ConfigStore


class CicadaApp(App):
    title = "CICADA - Agent Fleet Console"

    def build(self):
        theme.register_fonts()
        mode = ConfigStore().load().get("general", {}).get("theme", "aero_day")
        theme.set_mode(mode)
        Window.clearcolor = theme.c("sky_mid")
        print("[cicada-gui] framework=kivy theme=" + theme.current_mode() +
              " surface=" + theme.pal()["surface"])
        print("[cicada-gui] toggle Day/Night from the status-bar button; "
              "delete state\\gui-config.json to reset to aero_day")
        return MainWindow()


if __name__ == "__main__":
    CicadaApp().run()