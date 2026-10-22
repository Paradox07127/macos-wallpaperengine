"""Build both SKU disk images using the background renderer's layout."""

from pathlib import Path
import shlex

layout = dict(assignment.split("=", 1) for assignment in shlex.split(defines["layout"]))
staging = Path(defines["staging"])
app = f"{defines['app_name']}.app"
readme = defines["readme"]

files = [str(staging / app), str(staging / readme)]
symlinks = {"Applications": "/Applications"}
# Hiding the extension writes FinderInfo on the signed bundle and breaks strict verification.
background = defines["background"]
format = "ULMO"
filesystem = "HFS+"
window_rect = ((200, 120), (int(layout["DMG_WINDOW_W"]), int(layout["DMG_WINDOW_H"])))
icon_size = int(layout["DMG_ICON_SIZE"])
text_size = 16
icon_locations = {
    app: (int(layout["DMG_APP_X"]), int(layout["DMG_APP_Y"])),
    "Applications": (int(layout["DMG_APPS_X"]), int(layout["DMG_APPS_Y"])),
    readme: (int(layout["DMG_README_X"]), int(layout["DMG_README_Y"])),
}
default_view = "icon-view"
show_status_bar = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
