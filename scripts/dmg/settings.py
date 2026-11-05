# Indeling van de DMG voor dmgbuild. release.sh geeft `app`, `icon` en `background` mee met -D.
app = defines["app"]  # noqa: F821 (dmgbuild levert `defines`)

format = "UDZO"
filesystem = "HFS+"
# In de DMG heet de app "DJ Agenda.app", met spatie; de handtekening blijft geldig.
name = "DJ Agenda.app"
files = [(app, name)]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]  # noqa: F821

# Venster van 640 × 400 met de achtergrond uit background.swift.
background = defines["background"]  # noqa: F821
window_rect = ((200, 120), (640, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {
    name: (170, 165),
    "Applications": (470, 165),
}
