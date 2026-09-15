"""AeroBackground - integrates the finished Frutiger artwork assets.

Rules from the brief, implemented exactly:
- artwork is loaded ONCE per file (textures cached), never per frame
- aspect ratio is preserved: COVER style = scale until the window is
  fully covered, crop only the excess, never stretch
- 16:9 vs 16:10 selected by window aspect ratio (threshold ~1.69,
  between 1.6 and 1.7778); the variant only swaps when the family
  changes (the repaint itself only happens on resize/theme events)
- day/night follows theme.current_mode()
- if the PNGs are not installed yet, available() is False and the main
  window keeps its procedural scene as a fallback

Discovery reads each PNG's IHDR header for real pixel dimensions -
no Pillow dependency.
"""
import glob
import os

from kivy.core.image import Image as CoreImage

from .. import theme

ASSET_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "assets", "backgrounds")
THRESHOLD = 1.69  # between 16:10 (1.600) and 16:9 (1.778)


class BackgroundArt:
    def __init__(self):
        self._files = {"aero_day": {}, "aero_night": {}}
        self._textures = {}
        self.refresh_files()

    # -- discovery ----------------------------------------------------------
    def refresh_files(self):
        """Scan the assets dir; classify by name (day/night) and by the
        PNG's real aspect ratio (16x9 vs 16x10)."""
        self._files = {"aero_day": {}, "aero_night": {}}
        for path in glob.glob(os.path.join(ASSET_DIR, "*.png")):
            size = self._png_size(path)
            if size is None:
                continue
            w, h = size
            name = os.path.basename(path).lower()
            mode = "aero_night" if "night" in name else "aero_day"
            fam = "16x9" if (w / max(h, 1)) >= THRESHOLD else "16x10"
            self._files[mode][fam] = path

    @staticmethod
    def _png_size(path):
        """Width/height straight from the PNG IHDR - no imaging library."""
        try:
            with open(path, "rb") as fh:
                head = fh.read(26)
            if head[:8] != b"\x89PNG\r\n\x1a\n":
                return None
            return (int.from_bytes(head[16:20], "big"),
                    int.from_bytes(head[20:24], "big"))
        except OSError:
            return None

    # -- selection ----------------------------------------------------------
    @staticmethod
    def family(w, h):
        return "16x9" if (w / max(h, 1)) >= THRESHOLD else "16x10"

    def available(self):
        files = self._files[theme.current_mode()]
        return bool(files.get("16x9") or files.get("16x10"))

    def texture(self, fam):
        """The texture for this mode/family, loaded once and cached."""
        files = self._files[theme.current_mode()]
        path = files.get(fam) or files.get("16x9") or files.get("16x10")
        if not path:
            return None
        if path not in self._textures:
            self._textures[path] = CoreImage(path).texture
        return self._textures[path]

    # -- cover math ---------------------------------------------------------
    @staticmethod
    def cover(tex, w, h):
        """Scale so the window is fully covered; the excess is cropped by
        the window edges. Returns the (width, height) to draw centered."""
        iw, ih = tex.size
        scale = max(w / iw, h / ih)
        return iw * scale, ih * scale