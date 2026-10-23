# dmgbuild settings for Bremorph.dmg (used by make-dmg.command).
# A 660 x 400 window: the app on the left, an Applications shortcut on the right,
# and dmg-background.png (rendered from dmg-background.html) behind them.
import os.path

app = defines["app"]
appname = os.path.basename(app)
here = defines["dir"]

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")
background = os.path.join(here, "dmg-background.png")   # dmg-background@2x.png is picked up for Retina

window_rect = ((200, 120), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
arrange_by = None
label_pos = "bottom"
text_size = 13
icon_size = 112
icon_locations = {appname: (170, 190), "Applications": (490, 190)}
hide_extensions = [appname]
