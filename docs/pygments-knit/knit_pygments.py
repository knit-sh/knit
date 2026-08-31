"""Knit-branded Pygments styles for the documentation.

Two styles --- ``knit-light`` and ``knit-dark`` --- registered as Pygments
plugins through this distribution's ``pygments.styles`` entry points (see
``pyproject.toml``), so Sphinx and sphinx-book-theme discover them by name via
``pygments.styles.get_all_styles()``.

The token -> color mapping mirrors the landing-page code theme built by
``maint/build-landing.py``, and the palette mirrors the ``:root`` custom
properties in ``web/styles.css``. Those three places share one brand palette;
keep them in sync when the colors change. The dark style reuses the site's own
(dark) code colors verbatim; the light style keeps the same accents and only
swaps the near-white foreground/background for their dark counterparts.
"""

from pygments.style import Style
from pygments.token import (
    Comment,
    Keyword,
    Name,
    Number,
    Operator,
    String,
    Text,
)

# Brand palette --- mirrors the :root block of web/styles.css.
_PURPLE = "#9e7fd4"     # --knit-purple  : builtins (the Knit API)
_CORAL = "#fe8369"      # --knit-coral   : strings
_MAGENTA = "#b83a83"    # --knit-magenta : keywords and numbers
_FG_MUTED = "#a89fc0"   # --knit-fg-muted: operators

_DARK_BG = "#161b26"    # --knit-surface : dark card background
_DARK_FG = "#e8e6ef"    # --knit-fg      : dark-theme foreground (soft white)
_LIGHT_BG = "#ffffff"   # --knit-white   : light-theme background
_LIGHT_FG = "#0d1117"   # --knit-bg      : light-theme foreground (near-black)

# Comments keep the (theme-appropriate) neutral gray of the min-light / min-dark
# themes rather than a brand accent, so they stay quiet in the margins.
_COMMENT_LIGHT = "#c2c3c5"   # min-light comment gray
_COMMENT_DARK = "#6b737c"    # min-dark comment gray


def _token_styles(foreground, comment):
    """Return the shared token map; the base text and comment colors differ by
    theme (every accent is identical light vs dark, as the landing page uses
    them)."""
    return {
        Text: foreground,
        Comment: f"italic {comment}",
        Keyword: _MAGENTA,
        Name.Builtin: f"bold {_PURPLE}",
        # The `@` declaration shorthand (reclassified to the decorator token by
        # the Knit-aware lexer): the Knit API in its own magenta accent, next to
        # the purple `knit_*` builtins.
        Name.Decorator: f"bold {_MAGENTA}",
        String: _CORAL,
        Number: _MAGENTA,
        Operator: _FG_MUTED,
    }


class KnitDarkStyle(Style):
    """Dark Knit code theme --- the landing-page palette, verbatim."""

    name = "knit-dark"
    background_color = _DARK_BG
    # Emphasized lines (:emphasize-lines) --- a translucent magenta tint (the
    # brand accent at ~35% alpha) so the line clearly stands out on the dark
    # surface while the code text on top stays legible.
    highlight_color = _MAGENTA + "59"
    styles = _token_styles(_DARK_FG, _COMMENT_DARK)


class KnitLightStyle(Style):
    """Light Knit code theme --- same accents, near-white swapped for dark."""

    name = "knit-light"
    background_color = _LIGHT_BG
    highlight_color = "#ece1fb"
    styles = _token_styles(_LIGHT_FG, _COMMENT_LIGHT)
