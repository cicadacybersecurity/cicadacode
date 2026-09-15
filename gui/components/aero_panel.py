"""AeroGroup / AeroHeader / AeroActionBar / Page - the ONE page geometry model,
Phase 2.5 depth pass: glass surfaces with soft shadows and top highlights.

Every page in the application is a Page:

    Page (vertical BoxLayout)
    +-- AeroHeader        fixed height: title + subtitle + hairline
    +-- content           vertical BoxLayout (or ScrollView when scroll=True)
    +-- AeroActionBar     optional, docked at the bottom

Content sections are AeroGroups with exactly three deterministic sizing
modes, chosen at construction:

    AeroGroup("Caption")                  auto-fit: sizes to real content;
                                          valid because every child is a
                                          fixed-height row
    AeroGroup("Caption", height=N)       fixed height (rare: genuine
                                          control minimums only)
    AeroGroup("Caption", weight=W)       flexes with size_hint_y=W inside
                                          the page content column

No other sizing convention exists anywhere in the GUI.
"""
from kivy.uix.boxlayout import BoxLayout
from kivy.uix.scrollview import ScrollView

from .. import theme
from .aero import L, hrule, paint_bg, paint_border, top_highlight, vspacer


class AeroHeader(BoxLayout):
    """Fixed-height Vista page header: title + optional subtitle + rule
    with a luminous underline (the classic Aero double hairline)."""

    def __init__(self, title_text, subtitle="", **kwargs):
        kwargs.setdefault("orientation", "vertical")
        kwargs.setdefault("size_hint_y", None)
        super().__init__(**kwargs)
        self.add_widget(L(title_text, size=theme.FS_TITLE, bold=True,
                          size_hint_y=None, height=36))
        if subtitle:
            self.add_widget(L(subtitle, size=theme.FS_SUB, color="text_dim",
                              size_hint_y=None, height=22))
        self.add_widget(vspacer(10))
        self.add_widget(hrule())
        self.add_widget(hrule(color="glass_line"))  # light catch under the rule
        self.height = 36 + (22 if subtitle else 0) + 10 + 2


class AeroGroup(BoxLayout):
    """Vista/7 group box: caption + glass framed content area with a soft
    drop shadow, a thin luminous border and a top inner highlight."""

    def __init__(self, caption="", height=None, weight=None, **kwargs):
        kwargs.setdefault("orientation", "vertical")
        kwargs.setdefault("spacing", 0)
        if height is not None:
            kwargs.setdefault("size_hint_y", None)
        elif weight is not None:
            kwargs.setdefault("size_hint_y", weight)
        else:
            kwargs.setdefault("size_hint_y", None)  # auto-fit
        super().__init__(**kwargs)
        if caption:
            self.add_widget(L(caption, size=theme.FS_SECTION, bold=True,
                              color="accent_lo", size_hint_y=None, height=24))
            self.add_widget(vspacer(4))
        self.content = BoxLayout(orientation="vertical", spacing=10,
                                 padding=(14, 12))
        self._frame = BoxLayout(orientation="vertical")
        self._frame.add_widget(self.content)
        self._frame.bind(pos=self._repaint, size=self._repaint)
        self.add_widget(self._frame)
        if height is not None:
            self.height = height  # fixed; content fills
        elif weight is not None:
            pass                  # flex: content + frame fill the allocation
        else:
            # auto-fit: size to REAL content; every descendant must be a
            # fixed-height row (flexible children would count as zero)
            self.content.size_hint_y = None
            self.content.bind(minimum_height=self.content.setter("height"))
            self._frame.size_hint_y = None
            self._frame.bind(minimum_height=self._frame.setter("height"))
            self.bind(minimum_height=self.setter("height"))
        self._repaint()

    def _repaint(self, *_a):
        # Vista/7 Aero glass panel: layered, lightweight, all cached textures
        from kivy.graphics import Color, Line, RoundedRectangle
        f = self._frame
        x, y, w, h = f.x, f.y, f.width, f.height
        f.canvas.before.clear()
        with f.canvas.before:
            # 1. soft drop shadow: the panel sits physically above the page
            Color(1, 1, 1, 1)
            RoundedRectangle(pos=(x - 4, y - 7), size=(w + 8, h + 8),
                             radius=[7],
                             texture=theme.radial("shadow", 60))
            # 2. translucent glass base: pale blue gradient, ~12% of the
            #    Frutiger environment breathes through
            Color(1, 1, 1, 0.88)
            RoundedRectangle(pos=f.pos, size=f.size, radius=[4],
                             texture=theme.vgrad("header_hi", "surface2", 48))
            # 3. soft sheen band across the upper panel - the Aero gloss
            Color(1, 1, 1, 0.32)
            RoundedRectangle(pos=(x + 2, y + h * 0.58),
                             size=(w - 4, h * 0.40 - 2), radius=[3],
                             texture=theme.radial("cloud", 90))
        f.canvas.after.clear()
        with f.canvas.after:
            # 4. thin Aero edge: subtle blue outer border
            Color(*theme.c("border_lo"))
            Line(rounded_rectangle=(x, y, w, h, 4), width=1.0)
            # 5. luminous inner edges: bright top + faint left
            Color(*theme.c("glass_line", 200))
            Line(points=(x + 4, f.top - 1, x + w - 4, f.top - 1), width=1.0)
            Color(*theme.c("glass_line", 90))
            Line(points=(x + 1, y + 4, x + 1, y + h - 4), width=1.0)
            # 6. gentle bevel: inner bottom shade line
            Color(*theme.c("shadow", 50))
            Line(points=(x + 4, y + 1, x + w - 4, y + 1), width=1.0)

    def repaint(self):
        self._repaint()


class AeroActionBar(BoxLayout):
    """Bottom-docked action/status strip: pale Aero gradient, top hairline
    plus glass highlight, integrated with the page above it.

    Named AeroActionBar deliberately: a plain "ActionBar" class name matches
    Kivy's built-in ActionBar rule in style.kv, which gets applied on
    construction and expects properties (background_color) this widget does
    not have - a startup-crashing BuilderException. The Aero prefix keeps
    this widget fully outside Kivy's class-rule matching.
    """

    def __init__(self, **kwargs):
        kwargs.setdefault("orientation", "horizontal")
        kwargs.setdefault("size_hint_y", None)
        kwargs.setdefault("height", 48)
        kwargs.setdefault("padding", (theme.PAGE_PAD[0], 8))
        kwargs.setdefault("spacing", 8)
        super().__init__(**kwargs)
        self.bind(pos=self.repaint, size=self.repaint)
        self.repaint()

    def repaint(self, *_a):
        paint_bg(self, tex=theme.vgrad("header_hi", "surface2", 24))
        paint_border(self, None)
        from kivy.graphics import Color, Rectangle
        self.canvas.after.clear()
        with self.canvas.after:
            Color(*theme.c("border_lo"))
            Rectangle(pos=(self.x, self.top - 1), size=(self.width, 1))
            Color(*theme.c("glass_line", 120))
            Rectangle(pos=(self.x, self.top - 2), size=(self.width, 1))


class Page(BoxLayout):
    """The single page frame every CICADA page is built on.

    Lifecycle: the shell calls on_activate() when the page becomes visible
    and on_deactivate() when it is hidden - pages start their Clock timers
    in on_activate and cancel them in on_deactivate, so hidden pages never
    poll.
    """

    def __init__(self, title, subtitle="", scroll=False, **kwargs):
        kwargs.setdefault("orientation", "vertical")
        super().__init__(**kwargs)

        head = AeroHeader(title, subtitle)
        head_wrap = BoxLayout(size_hint_y=None,
                              padding=(theme.PAGE_PAD[0], theme.PAGE_PAD[1],
                                       theme.PAGE_PAD[0], 0))
        head_wrap.add_widget(head)
        head_wrap.height = head.height + theme.PAGE_PAD[1]
        self.add_widget(head_wrap)

        if scroll:
            sv = ScrollView()
            self.content = BoxLayout(orientation="vertical",
                                     padding=theme.PAGE_PAD,
                                     spacing=theme.PAGE_SPACING,
                                     size_hint_y=None)
            # valid: pages using scroll=True place only auto-fit / fixed
            # groups in the column, so minimum_height is real
            self.content.bind(minimum_height=self.content.setter("height"))
            sv.add_widget(self.content)
            self.add_widget(sv)
        else:
            self.content = BoxLayout(orientation="vertical",
                                     padding=theme.PAGE_PAD,
                                     spacing=theme.PAGE_SPACING)
            self.add_widget(self.content)
        self._actions = None

    def make_actions(self):
        """Create (once) and return this page's bottom AeroActionBar."""
        if self._actions is None:
            self._actions = AeroActionBar()
            self.add_widget(self._actions)
        return self._actions

    # -- lifecycle hooks (overridden by pages that poll) --------------------
    def on_activate(self):
        pass

    def on_deactivate(self):
        pass