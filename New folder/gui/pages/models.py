"""Models page - configuration tool on the common Page frame.

Same choices logic (discovered + currently assigned, never lost) and the
same apply semantics: save config + recompile the opencode JSON.
Assignments use spinners; an editable '(custom...)' entry swaps in a text
field for manual model IDs.
"""
from kivy.uix.boxlayout import BoxLayout
from kivy.uix.scrollview import ScrollView

from .. import theme
from ..components.aero import L, TInput, TSpinner
from ..components.aero_button import AeroButton
from ..components.aero_panel import AeroGroup, Page

SEATS = (("planner", "Planner (decomposes the objective)"),
         ("reviewer", "Reviewer (accepts / rejects each task)"),
         ("builder", "Builder (writes the code)"))


class _ModelTree(BoxLayout):
    """Provider -> models as an indented Explorer-style list."""

    def __init__(self, **kwargs):
        kwargs.setdefault("orientation", "vertical")
        kwargs.setdefault("size_hint_y", None)
        super().__init__(**kwargs)
        self.bind(minimum_height=self.setter("height"))

    def fill(self, registry):
        self.clear_widgets()
        for p in registry.all():
            head = L(p.display_name + ("" if p.enabled else "  (disabled)") +
                     "   -   " + (str(len(p.models)) + " models" if p.models
                                else "not discovered"),
                     size=theme.FS_TABLE, bold=True, size_hint_y=None, height=24,
                     padding=(4, 0))
            self.add_widget(head)
            for mid in p.models:
                self.add_widget(L(mid + "    (" + p.id + "/" + mid + ")",
                                  size=theme.FS_DIM, color="text_dim", mono=True,
                                  size_hint_y=None, height=20,
                                  padding=(22, 0)))


class _SeatRow(BoxLayout):
    """Spinner of known models + '(custom...)' -> editable text field."""

    def __init__(self, **kwargs):
        kwargs.setdefault("orientation", "horizontal")
        kwargs.setdefault("size_hint_y", None)
        kwargs.setdefault("height", theme.H_FIELD)
        kwargs.setdefault("spacing", 6)
        super().__init__(**kwargs)
        self.spinner = TSpinner(size_hint_x=1)
        self.spinner.bind(text=self._changed)
        self.custom = TInput(placeholder="custom model id", size_hint_x=1)
        self.add_widget(self.spinner)

    def _changed(self, *_a):
        if self.spinner.text == "(custom...)":
            self.clear_widgets()
            self.add_widget(self.custom)
        self.custom.text = ""

    def set_choices(self, choices, current):
        values = list(choices) + ["(custom...)"]
        self.spinner.values = values
        if current and current in choices:
            if self.spinner.parent is None:
                self.clear_widgets()
                self.add_widget(self.spinner)
            self.spinner.text = current
        elif current:
            self.clear_widgets()
            self.add_widget(self.custom)
            self.custom.text = current
            self.spinner.text = "(custom...)"

    def value(self):
        if self.custom.parent is not None:
            return self.custom.text.strip()
        text = self.spinner.text
        return "" if text == "(custom...)" else text.strip()


class ModelsPage(Page):
    def __init__(self, registry, config, on_change, **kwargs):
        super().__init__("Models",
                         "Discover models on the Providers tab first. "
                         "Assignments apply to new workers and runs "
                         "immediately.", **kwargs)
        self.registry = registry
        self.config = config
        self.on_change = on_change

        tree_grp = AeroGroup("Discovered models", weight=1)
        scroll = ScrollView()
        self.tree = _ModelTree()
        scroll.add_widget(self.tree)
        tree_grp.content.add_widget(scroll)
        self.content.add_widget(tree_grp)

        assign = AeroGroup("Assignments")  # auto-fit: fixed-height form rows
        form = BoxLayout(orientation="vertical", spacing=6, size_hint_y=None)
        form.bind(minimum_height=form.setter("height"))
        form.add_widget(L("Default model", size=theme.FS_DIM,
                          color="text_dim", size_hint_y=None, height=16))
        self.default_model = _SeatRow()
        form.add_widget(self.default_model)
        self.seat_rows = {}
        for seat, label in SEATS:
            form.add_widget(L(label, size=theme.FS_DIM, color="text_dim",
                              size_hint_y=None, height=16))
            row = _SeatRow()
            self.seat_rows[seat] = row
            form.add_widget(row)
        assign.content.add_widget(form)
        self.content.add_widget(assign)

        bar = self.make_actions()
        bar.add_widget(AeroButton("Apply assignments", accent=True,
                                  on_press_fn=self._apply,
                                  size_hint_x=None, width=150))
        bar.add_widget(AeroButton("Refresh", on_press_fn=self.refresh,
                                  size_hint_x=None, width=90))
        bar.add_widget(BoxLayout())
        self.status = L("", size=theme.FS_DIM, color="text_faint",
                        size_hint_x=None, width=320)
        bar.add_widget(self.status)

    def on_activate(self):
        self.refresh()

    def _choices(self):
        known = set(self.registry.all_models())
        known.add(self.config.get("default_model", ""))
        known.update(self.config.get("seats", {}).values())
        return sorted(m for m in known if m)

    def refresh(self):
        self.tree.fill(self.registry)
        choices = self._choices()
        self.default_model.set_choices(choices,
                                       self.config.get("default_model", ""))
        seats = self.config.get("seats", {})
        for seat, _label in SEATS:
            self.seat_rows[seat].set_choices(choices, seats.get(seat, ""))

    def _apply(self):
        self.config["default_model"] = self.default_model.value()
        self.config.setdefault("seats", {})
        for seat, _label in SEATS:
            self.config["seats"][seat] = self.seat_rows[seat].value()
        self.on_change()
        self.status.text = "assignments saved + opencode config regenerated"
        self.status.color = theme.c("ok")