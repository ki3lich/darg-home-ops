#!/usr/bin/env python3
"""Generate the lovelace.dashboard_dom_2 storage-mode config.

Room-based layout (see docs/home-assistant/dashboards.md):
- Home: Alerty (conditional leak tiles), Salon, Kuchnia i jadalnia, Sypialnia,
  Biuro, Podwórko, Woda, Więcej (nav headings).
- Subviews: Góra (room sections), Kamery, Klimatyzacja.
- Native cards only. Critical controls (water valve, gates) tap_action=more-info.

Usage:
    export HASS_TOKEN=$(op read op://darg-home-ops/claude/password)
    scripts/generate-dom-dashboard.py [--states states.json] [--out out.json]

Validates every referenced entity against /api/states (fetched live, or read
from --states) and refuses output containing custom: cards. Then deploy per
docs/home-assistant/dashboards.md ("Editing a storage-mode dashboard").
"""
import argparse
import json
import os
import sys
import urllib.request

HASS_URL = "https://hass.darg.win"

def tile(entity, name=None, features=None, picture=False, tap_more_info=False,
         visibility=None):
    t = {
        "type": "tile",
        "entity": entity,
        "vertical": False,
        "features_position": "bottom",
    }
    if name:
        t["name"] = name
    if features:
        t["features"] = features
    if picture:
        t["show_entity_picture"] = True
    if tap_more_info:
        t["tap_action"] = {"action": "more-info"}
    if visibility:
        t["visibility"] = visibility
    return t

def cover_tile(entity, name=None):
    return tile(entity, name=name, features=[{"type": "cover-open-close"}])

def heading(text, style="title", icon=None, navigate=None):
    h = {"type": "heading", "heading": text, "heading_style": style}
    if icon:
        h["icon"] = icon
    if navigate:
        h["tap_action"] = {"action": "navigate", "navigation_path": navigate}
    return h

def section(cards):
    return {"type": "grid", "cards": cards}

def view(title, icon, sections, path=None, subview=False, badges=None):
    v = {
        "type": "sections",
        "title": title,
        "icon": icon,
        "max_columns": 4,
        "subview": subview,
        "cards": [],
        "sections": sections,
    }
    if path:
        v["path"] = path
    if badges is not None:
        v["badges"] = badges
    return v

def leak_tile(entity, name):
    return tile(entity, name=name, tap_more_info=True,
                visibility=[{"condition": "state", "entity": entity, "state": "on"}])

home_view = view(
    "Dom", "mdi:home",
    badges=[
        {"type": "entity", "show_name": False, "show_state": True,
         "show_icon": True, "entity": "weather.pirateweather"},
        {"type": "entity", "show_name": False, "show_state": True,
         "show_icon": True, "entity": "sun.sun"},
    ],
    sections=[
        # Alerty — no heading; section disappears entirely when nothing triggers
        section([
            leak_tile("binary_sensor.tuya_czujnik_zalania_wodomierz_water_leak",
                      "Zalanie wodomierz"),
            leak_tile("binary_sensor.tuya_czujnik_zalania_kuchnia_water_leak",
                      "Zalanie kuchnia"),
        ]),
        section([
            heading("Salon"),
            tile("media_player.tv", picture=True),
            tile("media_player.ht_zf9"),
            tile("light.tv_ambilight", visibility=[
                {"condition": "state", "entity": "media_player.tv", "state": "on"}]),
            cover_tile("cover.roleta_08salon", "Salon Przód"),
            cover_tile("cover.roleta_07salon_1", "Salon TV"),
            tile("climate.salon", "Klima"),
            tile("vacuum.roborock_s7_maxv", "Robo"),
        ]),
        section([
            heading("Kuchnia i jadalnia"),
            cover_tile("cover.roleta_10kuchnia", "Kuchnia"),
            cover_tile("cover.roleta_09jadalni", "Jadalnia"),
        ]),
        section([
            heading("Sypialnia"),
            cover_tile("cover.roleta_11sypialn"),
        ]),
        section([
            heading("Biuro"),
            tile("climate.biuro", "Klima"),
            tile("light.gledopto_zarowka_biuro", "Żarówka"),
        ]),
        section([
            heading("Podwórko"),
            cover_tile("cover.markiza_tarasowa"),
            cover_tile("cover.megane", "Megane"),
            cover_tile("cover.expert", "Expert"),
            tile("script.brama_przelacz", "Brama wjazdowa", tap_more_info=True),
            tile("lawn_mower.robolinho2000_mower", "ALK"),
            heading("Kamery", style="subtitle", icon="mdi:cctv",
                    navigate="/dashboard-dom-2/kamery"),
        ]),
        section([
            heading("Woda", icon="mdi:water"),
            tile("switch.nous_zawor_wody_glowny", "Zawór główny",
                 tap_more_info=True),
            tile("switch.oxt_brama_biuro_state", "Brama piwnica",
                 tap_more_info=True),
        ]),
        section([
            heading("Więcej"),
            heading("Góra", style="subtitle", icon="mdi:stairs",
                    navigate="/dashboard-dom-2/gora"),
            heading("Klimatyzacja", style="subtitle", icon="mdi:hvac",
                    navigate="/dashboard-dom-2/klimatyzacje"),
        ]),
    ],
)
home_view["dense_section_placement"] = False
home_view["header"] = {"layout": "center", "badges_position": "top",
                       "badges_wrap": "wrap"}

gora_view = view(
    "Góra", "mdi:stairs", path="gora", subview=True,
    sections=[
        section([
            heading("Pracownia"),
            cover_tile("cover.roleta_03pracown", "Pracownia 1"),
            cover_tile("cover.roleta_04pracown", "Pracownia 2"),
        ]),
        section([
            heading("Pokój Szymona"),
            cover_tile("cover.szymon", "Szymon"),
        ]),
        section([
            heading("Pokój Weroniki"),
            cover_tile("cover.roleta_01weronik", "Weronika"),
            cover_tile("cover.roleta_02weronik", "Weronika balkon"),
        ]),
        section([
            heading("Pokój Bartka"),
            cover_tile("cover.roleta_05bartosz", "Bartosz"),
        ]),
    ],
)

kamery_view = view(
    "Kamery", "mdi:cctv", path="kamery", subview=True,
    sections=[
        section([
            heading("Kamery"),
            tile("camera.kamera_przod_direct", "Przód", picture=True),
            tile("camera.192_168_1_234", "Podwórko", picture=True),
            tile("camera.192_168_1_234_2", "Podwórko taras", picture=True),
            tile("camera.192_168_1_234_3", "Podwórko Wacek", picture=True),
        ]),
    ],
)

klima_view = view(
    "Klimatyzacja", "mdi:hvac", path="klimatyzacje", subview=True,
    sections=[
        section([
            heading("Klimatyzacja"),
            tile("climate.pracownia", "Klima Pracownia"),
            tile("climate.klima1", "Klima1"),
            tile("climate.gree_climate_2", "Gree Climate"),
        ]),
    ],
)

config = {
    "version": 1,
    "minor_version": 1,
    "key": "lovelace.dashboard_dom_2",
    "data": {"config": {"views": [home_view, gora_view, kamery_view, klima_view]}},
}

# --- validation: every referenced entity must exist in /api/states ---
parser = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--states",
                    help="path to a saved /api/states JSON dump "
                         "(default: fetch live from %(default)s)")
parser.add_argument("--out", default="/tmp/lovelace.dashboard_dom_2.new.json",
                    help="output path (default: %(default)s)")
args = parser.parse_args()

if args.states:
    states = {e["entity_id"] for e in json.load(open(args.states))}
else:
    token = os.environ.get("HASS_TOKEN")
    if not token:
        sys.exit("HASS_TOKEN not set — get it with: "
                 "op read op://darg-home-ops/claude/password")
    req = urllib.request.Request(
        f"{HASS_URL}/api/states",
        headers={"Authorization": f"Bearer {token}",
                 # ingress rejects the default Python-urllib UA
                 "User-Agent": "curl/8.0"})
    states = {e["entity_id"] for e in json.load(urllib.request.urlopen(req))}

referenced = set()
def walk(node):
    if isinstance(node, dict):
        e = node.get("entity")
        if isinstance(e, str):
            referenced.add(e)
        for v in node.values():
            walk(v)
    elif isinstance(node, list):
        for v in node:
            walk(v)
walk(config)

missing = sorted(referenced - states)
if missing:
    print("MISSING ENTITIES:", *missing, sep="\n  ")
    sys.exit(1)

# no custom cards
raw = json.dumps(config)
assert '"type": "custom:' not in raw and '"type":"custom:' not in raw

with open(args.out, "w") as f:
    json.dump(config, f, ensure_ascii=False, indent=2)
print("wrote", args.out)

print(f"OK: {len(referenced)} entities validated, no custom cards")
print("views:", [v.get("path", "home") for v in config["data"]["config"]["views"]])
