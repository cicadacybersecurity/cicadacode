"""CICADA Kivy theme - one central design system (Phase 2.5 visual pass).

Richer Vista/7 Aero palette: stronger sky-blue gradients, deeper borders,
physical depth via shadow textures, glass highlights. Two modes: aero_day
(default, bright) and aero_night (dark blue glass derived from the same
component system). All colors, textures, fonts, type scale and control
metrics live here - widgets never invent their own values.

Stock-widget re-theme: widgets built through aero's themed factories and
labels built through aero.L register a listener via theme.on_change so a
Day/Night switch updates EVERY control, not just custom-painted widgets.

All textures are runtime-generated and cached; nothing animates.
"""
from kivy.core.text import LabelBase
from kivy.core.window import Window
from kivy.graphics.texture import Texture

_MODES = ("aero_day", "aero_night")
_current = "aero_day"


# ------------------------------------------------------------- mode state
_listeners = []


def set_mode(mode):
    """Switch mode and notify every registered control so nothing keeps a
    stale colour captured at construction time."""
    global _current
    if mode in _MODES and mode != _current:
        _current = mode
        for fn in list(_listeners):
            fn()


def current_mode():
    return _current


def on_change(fn):
    """Register a zero-arg callback fired on every mode switch."""
    _listeners.append(fn)


def hx(value, a=255):
    """'#rrggbb' -> kivy (r,g,b,a) 0-1 floats."""
    return (int(value[1:3], 16) / 255, int(value[3:5], 16) / 255,
            int(value[5:7], 16) / 255, a / 255)


DAY = {
    # environment: 3-stop Frutiger sky
    "sky_top": "#dff5ff", "sky_mid": "#b8e4f7", "sky_bot": "#86cff0",
    "sun": "#fffde8", "cloud": "#ffffff", "meadow": "#8fd9a8",
    # application surfaces: light blue glass, clearly separated from the sky
    "surface": "#f1f8fd", "surface2": "#e2f0f9", "content": "#f8fcff",
    "border": "#9ab8ca", "border_lo": "#7fa8bf", "group_line": "#b9d4e4",
    # type
    "text": "#123449", "text_dim": "#45687f", "text_faint": "#6f8ea1",
    "link": "#1a5c8f",
    # Aero blue - deeper, more saturated for interactive states
    "accent": "#2f90d4", "accent_hi": "#6cc4ee", "accent_lo": "#1f6ea6",
    "ok": "#3f9e5f", "warn": "#c08a1e", "err": "#d05a4e",
    # beveled button stops: white highlight -> saturated blue -> darker edge
    "btn_top": "#ffffff", "btn_sheen": "#ecf7fd", "btn_mid": "#c9e8f9",
    "btn_bot": "#a3d5f0", "btn_edge": "#7db3d6",
    "input_bg": "#f7fcfe",
    "selection": "#b9e2f7", "sel_text": "#0f3a57",
    "nav_hover": "#d7edfb",
    "nav_sel_top": "#c2e6f8", "nav_sel_bot": "#95cdef",
    "navpane_top": "#f4fbfe", "navpane_bot": "#dcecf7",
    "header_hi": "#ffffff", "header_lo": "#cbe7f7",
    "row_alt": "#eef6fb", "row_hover": "#d9eefb",
    "focus": "#4aa3dd",
    "glass_line": "#ffffff",
    "shadow": "#2b5876",
}

NIGHT = {
    "sky_top": "#16344a", "sky_mid": "#0f2434", "sky_bot": "#0a1a28",
    "sun": "#bfe6f4", "cloud": "#96d2eb", "meadow": "#2e5a4a",
    # dark blue glass - still Aero, not a black admin console
    "surface": "#21384c", "surface2": "#1a2c3d", "content": "#1e3446",
    "border": "#3d5a72", "border_lo": "#2f4a60", "group_line": "#37536a",
    "text": "#dcebf5", "text_dim": "#a9c2d5", "text_faint": "#7e9bb0",
    "link": "#86c4ea",
    "accent": "#55a5da", "accent_hi": "#7cc6ec", "accent_lo": "#3579ab",
    "ok": "#5cb888", "warn": "#d8a04a", "err": "#d86a5e",
    "btn_top": "#38506a", "btn_sheen": "#425c77", "btn_mid": "#2e4359",
    "btn_bot": "#25374a", "btn_edge": "#557795",
    "input_bg": "#1d3040",
    "selection": "#31547a", "sel_text": "#eaf5fd",
    "nav_hover": "#2a4256",
    "nav_sel_top": "#3a5f80", "nav_sel_bot": "#2c4a66",
    "navpane_top": "#2a4157", "navpane_bot": "#20334a",
    "header_hi": "#33506a", "header_lo": "#26405a",
    "row_alt": "#243c52", "row_hover": "#2c4a63",
    "focus": "#63b2e2",
    "glass_line": "#a8d4ee",
    "shadow": "#000a12",
}


def pal():
    return DAY if _current == "aero_day" else NIGHT


def c(key, a=255):
    return hx(pal()[key], a)


PILL = {
    "aero_day": {
        "idle": ("#2e7d46", "#e2f4e8"), "running": ("#2c7fb0", "#d4eefb"),
        "starting": ("#b06a12", "#f7ecd7"), "stopping": ("#b06a12", "#f7ecd7"),
        "failed": ("#c0392b", "#f8e3e0"), "unreachable": ("#c0392b", "#f8e3e0"),
        "stopped": ("#7d94a4", "#eef3f6"), "done": ("#2e7d46", "#e2f4e8"),
        "blocked": ("#c0392b", "#f8e3e0"), "building": ("#b06a12", "#f7ecd7"),
        "pending": ("#7d94a4", "#eef3f6"),
    },
    "aero_night": {
        "idle": ("#5cb888", "#1e3329"), "running": ("#84c4e8", "#1e3142"),
        "starting": ("#d8a04a", "#382f1e"), "stopping": ("#d8a04a", "#382f1e"),
        "failed": ("#d86a5e", "#3a2421"), "unreachable": ("#d86a5e", "#3a2421"),
        "stopped": ("#7d93a6", "#26313d"), "done": ("#5cb888", "#1e3329"),
        "blocked": ("#d86a5e", "#3a2421"), "building": ("#d8a04a", "#382f1e"),
        "pending": ("#7d93a6", "#26313d"),
    },
}


def pill(state):
    fg, bg = PILL[_current].get(state, PILL[_current]["pending"])
    return hx(fg), hx(bg)


# --------------------------------------------------------------- textures
_tex_cache = {}


def vgrad(top_key, bot_key, steps=128):
    """Vertical gradient texture (top color at texture v=1). Cached."""
    key = ("vg", _current, top_key, bot_key)
    if key in _tex_cache:
        return _tex_cache[key]
    t = hx(pal()[top_key])
    b = hx(pal()[bot_key])
    tex = Texture.create(size=(1, steps), colorfmt="rgba")
    buf = bytearray()
    for i in range(steps):  # i=0 -> bottom row
        f = i / (steps - 1)
        buf += bytes(int(b[j] * 255 + (t[j] - b[j]) * f * 255) for j in range(4))
    tex.blit_buffer(bytes(buf), colorfmt="rgba", bufferfmt="ubyte")
    tex.wrap = "repeat"
    _tex_cache[key] = tex
    return tex


def vgrad3(top_key, mid_key, bot_key, steps=192):
    """Three-stop vertical gradient (sky): top -> mid -> bot. Cached."""
    key = ("vg3", _current, top_key, mid_key, bot_key)
    if key in _tex_cache:
        return _tex_cache[key]
    t, m, b = hx(pal()[top_key]), hx(pal()[mid_key]), hx(pal()[bot_key])
    tex = Texture.create(size=(1, steps), colorfmt="rgba")
    buf = bytearray()
    for i in range(steps):  # i=0 -> bottom
        f = i / (steps - 1)
        if f < 0.5:  # bottom -> mid
            lo, hi, g = b, m, f * 2
        else:        # mid -> top
            lo, hi, g = m, t, (f - 0.5) * 2
        buf += bytes(int(lo[j] * 255 + (hi[j] - lo[j]) * g * 255) for j in range(4))
    tex.blit_buffer(bytes(buf), colorfmt="rgba", bufferfmt="ubyte")
    tex.wrap = "repeat"
    _tex_cache[key] = tex
    return tex


def radial(inner_key="cloud", alpha=160, size=64):
    """Soft radial texture: white glow (cloud/sun) or dark drop shadow
    (inner_key=\"shadow\"). Cached; reused by every control shadow."""
    key = ("rad", _current, inner_key, alpha)
    if key in _tex_cache:
        return _tex_cache[key]
    base = hx(pal()[inner_key])
    tex = Texture.create(size=(size, size), colorfmt="rgba")
    buf = bytearray()
    center = (size - 1) / 2
    for y in range(size):
        for x in range(size):
            d = (((x - center) ** 2 + (y - center) ** 2) ** 0.5) / center
            a = max(0.0, 1.0 - d) ** 1.8
            buf += bytes((int(base[0] * 255), int(base[1] * 255),
                          int(base[2] * 255), int(a * alpha)))
    tex.blit_buffer(bytes(buf), colorfmt="rgba", bufferfmt="ubyte")
    _tex_cache[key] = tex
    return tex


def solid(key, a=255):
    key2 = ("sol", _current, key, a)
    if key2 in _tex_cache:
        return _tex_cache[key2]
    tex = Texture.create(size=(1, 1), colorfmt="rgba")
    col = c(key, a)
    tex.blit_buffer(bytes(int(v * 255) for v in col), colorfmt="rgba",
                    bufferfmt="ubyte")
    tex.wrap = "repeat"
    _tex_cache[key2] = tex
    return tex


def clear_cache():
    _tex_cache.clear()


# ------------------------------------------------------------------- fonts
def register_fonts():
    """Segoe UI (Vista/7's UI font) when present on the system; Arial next;
    Kivy's default last. Mono = Consolas for logs/IDs/ports only."""
    import os
    for name, regular, bold in (
            ("CicadaSans", "C:/Windows/Fonts/segoeui.ttf", "C:/Windows/Fonts/segoeuib.ttf"),
            ("CicadaSans", "C:/Windows/Fonts/arial.ttf", "C:/Windows/Fonts/arialbd.ttf")):
        if os.path.isfile(regular):
            kwargs = {"fn_regular": regular}
            if os.path.isfile(bold):
                kwargs["fn_bold"] = bold
            try:
                LabelBase.register(name=name, **kwargs)
                break
            except Exception:
                continue
    if os.path.isfile("C:/Windows/Fonts/consola.ttf"):
        try:
            LabelBase.register(name="CicadaMono",
                               fn_regular="C:/Windows/Fonts/consola.ttf")
        except Exception:
            pass


SANS = "CicadaSans"
MONO = "CicadaMono"

# Central type scale (sp) and control metrics (px). These are the ONLY
# hardcoded dimensions in the presentation layer: typography baselines,
# control minimum heights, nav width, icon sizes, borders and padding.
FS_TITLE = 26        # page title
FS_SECTION = 15      # group captions
FS_NORMAL = 14       # normal UI text
FS_TABLE = 13        # table cells
FS_HEADER = 12       # table header (bold)
FS_NAV = 14          # navigation items
FS_NAV_CAPTION = 12  # navigation group captions
FS_SUB = 13          # page subtitle / secondary text
FS_DIM = 12          # field labels, hint text
FS_STAT = 26         # important dashboard values
H_NAV_ITEM = 36      # navigation item height
H_NAV_CAPTION = 26   # navigation group caption height
H_TABLE_HEADER = 32
H_TABLE_ROW = 34
H_BUTTON = 34
H_INPUT = 32
H_FIELD = 30         # compact in-form inputs
NAV_WIDTH = 224
PAGE_PAD = (24, 18)  # content page padding (x, y)
PAGE_SPACING = 16    # between page sections


def window_setup():
    Window.clearcolor = hx(DAY["sky_mid"])
    Window.minimum_width, Window.minimum_height = 1000, 620