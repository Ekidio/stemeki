# dmgbuild settings for the STEMEKI installer disk image.
# Usage (see make-dmg.sh): dmgbuild -s Tools/dmg-settings.py -D app=... -D background=... "STEMEKI" out.dmg
import os.path
import unicodedata

application = defines["app"]  # noqa: F821 (injected by dmgbuild)
appname = os.path.basename(application)

format = "UDZO"
filesystem = "HFS+"
files = [application]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(application, "Contents/Resources/AppIcon.icns")

background = defines["background"]  # noqa: F821
# Taller than the 460pt background: on macOS 26 Finder always shows the toolbar and status bar.
window_rect = ((200, 100), (680, 560))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False

icon_size = 96
text_size = 13
arrange_by = None
# HFS+ stores accented names decomposed (NFD); Finder only matches .DS_Store entries written the same way.
icon_locations = {
    unicodedata.normalize("NFD", appname): (180, 170),
    unicodedata.normalize("NFD", "Applications"): (500, 170),
}
