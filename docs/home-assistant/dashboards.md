# Home Assistant dashboards runbook

Operational notes for inspecting and editing HA dashboards in this cluster. HA
runs as `default/home-assistant` (HelmRelease under
`kubernetes/apps/default/home-assistant/`); `/config` is a PVC.

The pod name is ephemeral (`home-assistant-<rs>-<pod>`). Always address it by
label selector:

```sh
POD=$(kubectl -n default get pod -l app.kubernetes.io/name=home-assistant -o name | head -1)
```

## Dashboards are storage-mode — not in git

Every dashboard here is **storage mode**: hand-edited in the HA UI, persisted as
JSON on the PVC, never reconciled by Flux. There is no YAML-mode dashboard and
no git artifact. Dashboards survive pod restarts (on the PVC) and are backed up
by volsync; they are not reviewable or diffable in this repo. See ADR-0002 for
why `/config` is treated as HA's mutable state, not a reconciled artifact.

Three files in `/config/.storage/` matter:

| File | Holds |
| --- | --- |
| `lovelace.<dashboard_id>` | One dashboard's config (views, sections, cards) |
| `lovelace_dashboards` | Registry of all dashboards (id, title, url_path, mode) |
| `lovelace_resources` | HACS / custom JS resources loaded by the frontend |

List them:

```sh
kubectl -n default exec $POD -c app -- ls -la /config/.storage/ | grep lovelace
```

## Getting entities

There are three sources, and they disagree. Know which one you're reading.

### 1. REST API — authoritative

`GET /api/states` returns **every** entity currently in HA's state machine:
registered entities *plus* `input_boolean.*`, `input_button.*`, `automation.*`,
`person.*`, `sun.sun`, `weather.*`, template sensors, and everything else. This
is the only source that covers the lot. Needs a long-lived access token
(HA UI → Profile → Long-Lived Access Tokens). The token lives in 1Password:

```sh
export HASS_TOKEN=$(op read op://darg-home-ops/claude/password)
curl -s -H "Authorization: Bearer $HASS_TOKEN" https://hass.darg.win/api/states > states.json
```

Use this to validate that entity ids referenced by a dashboard actually exist.

### 2. `core.entity_registry` — registered entities only

```sh
kubectl -n default exec $POD -c app -- cat /config/.storage/core.entity_registry > entity_registry.json
```

Only covers entities backed by a device/integration. **It does NOT contain**
`input_boolean`, `input_button`, `automation`, `person`, `sun`, `weather`, or
template sensors. Checking dashboard entity ids against this file alone will
report false-missing for all of those. Use it for `light.*`, `switch.*`,
`sensor.*` (hardware), `cover.*`, `climate.*`, `camera.*`, `media_player.*`,
`vacuum.*`, etc.

### 3. `core.restore_state` — unreliable proxy

Only entities HA has recently restored state for. Real entities can be absent
(e.g. `weather.pirateweather` was missing from it during testing). Don't use it
to verify existence.

### Floor / area / label grouping

A cover or climate's `floor_id` is often `null` in the entity registry even when
it clearly belongs to a floor. The floor assignment usually lives on the
**device**, reached via the area:

```
entity → device (core.device_registry) → area_id → area (core.area_registry) → floor_id
```

So to group covers by floor, walk device → area → floor, not the entity's own
`floor_id`. The auto-entities `floor:` filter in old dashboards resolved through
this same chain — which is why a `floor: parter` filter silently returned
nothing when the devices had no area assigned.

Registries involved:

```sh
kubectl -n default exec $POD -c app -- cat /config/.storage/core.area_registry
kubectl -n default exec $POD -c app -- cat /config/.storage/core.floor_registry
kubectl -n default exec $POD -c app -- cat /config/.storage/core.label_registry
kubectl -n default exec $POD -c app -- cat /config/.storage/core.device_registry
```

## Editing a storage-mode dashboard

1. **Generate** the config as JSON. The storage wrapper shape is:

   ```json
   {
     "version": 1,
     "minor_version": 1,
     "key": "lovelace.<dashboard_id>",
     "data": { "config": { "views": [ ... ] } }
   }
   ```

2. **Validate before pushing** — every entity id should exist in
   `/api/states`, and (if going addon-free) no card `type` starts with
   `custom:`. Native tile features like `cover-open` / `cover-close` are fine.

3. **Back up** the existing file on the PVC first:

   ```sh
   TS=$(date +%Y%m%d-%H%M%S)
   kubectl -n default exec $POD -c app -- sh -c \
     "cp /config/.storage/lovelace.<id> /config/.storage/lovelace.<id>.bak.$TS"
   ```

4. **Write** the new JSON to a temp path on the pod, validate it parses there,
   then atomically move it into place and fix ownership to match the other
   storage files (`1000:1000`, mode `644`):

   ```sh
   cat new.json | kubectl -n default exec -i $POD -c app -- sh -c \
     'cat > /config/.storage/lovelace.<id>.new'
   kubectl -n default exec $POD -c app -- python3 -c \
     "import json; json.load(open('/config/.storage/lovelace.<id>.new'))"
   kubectl -n default exec $POD -c app -- sh -c '
     mv /config/.storage/lovelace.<id>.new /config/.storage/lovelace.<id> &&
     chown 1000:1000 /config/.storage/lovelace.<id> &&
     chmod 644 /config/.storage/lovelace.<id>'
   ```

5. **Restart the pod** to pick up the change. HA caches lovelace storage in
   memory and does **not** watch the `.storage` files for external edits, so a
   raw file write is invisible until HA reboots:

   ```sh
   kubectl -n default delete pod $POD
   ```

   (Saving through HA's WebSocket API `lovelace/config/save` would update the
   in-memory store live without a restart, but a pod restart is the simpler,
   lower-risk path for an external edit.)

## Adding a new dashboard

1. Append an entry to the `lovelace_dashboards` registry (`mode: storage`,
   with `id`, `title`, `url_path`, `show_in_sidebar`). The `url_path` is the
   slug in the URL; `id` is the `.storage` filename suffix.
2. Create `/config/.storage/lovelace.<id>` with the config wrapper above.
3. Restart the pod.

## Going addon-free: bubble-card / auto-entities → native tiles

The legacy `dashboard_dom` (url `dashboard-dom`) is built on
`custom:bubble-card` (27 cards) and `custom:auto-entities` (5 blocks). The
loaded HACS resources are in `lovelace_resources`: bubble-card, auto-entities,
card-mod, mini-media-player, mini-graph-card, power-flow-card-plus,
webrtc-camera.

The pattern to flatten when dropping those addons:

- A bubble-card **button → `#hash` pop-up → auto-entities grid** becomes a
  native **subview** (`subview: true`) containing explicit **tile** cards, with
  a `heading` card on the Home view whose `tap_action` navigates to
  `/<dashboard-slug>/<view-path>`.
- auto-entities groups (e.g. `domain: cover`, `floor: parter`) become
  hand-listed tiles. Because the tiles are explicit, **the dashboard will not
  auto-follow** later area/floor changes in HA — adding a new blind means
  editing the dashboard. That is the trade-off for dropping auto-entities.
- Cover controls: a `tile` card with `features: [{type: cover-open-close}]`
  (or the separate `{type: cover-open}` / `{type: cover-close}` pair)
  preserves one-tap open/close without an addon. `dashboard-dom-2` uses the
  combined form.
- Cameras: a `tile` with `show_entity_picture: true` renders a live snapshot on
  the face — no `picture-entity` or webrtc addon needed.

The converted dashboard lives at `dashboard-dom-2` (file
`lovelace.dashboard_dom_2`) alongside the original, so the two can be compared
before the old one is retired.

## dashboard-dom-2 layout conventions (2026-08 redesign)

`dashboard-dom-2` is **room-based**, not domain-based: the Home view has one
section per room (Salon, Kuchnia i jadalnia, Sypialnia, Biuro, Podwórko, Woda),
and each section holds that room's covers, lights, climate, and media as native
tile cards. Subviews: `gora` (upstairs rooms, one section each), `kamery`,
`klimatyzacje` (units not already shown in a room section).

Conventions to keep when editing it:

- **Regenerate, don't hand-edit JSON.** `scripts/generate-dom-dashboard.py`
  emits the full config and validates every referenced entity against
  `/api/states` (live fetch, or `--states dump.json`) before writing output:

  ```sh
  export HASS_TOKEN=$(op read op://darg-home-ops/claude/password)
  scripts/generate-dom-dashboard.py          # writes /tmp/lovelace.dashboard_dom_2.new.json
  ```

  Then deploy with the "Editing a storage-mode dashboard" flow above. The
  dashboard JSON itself stays storage-mode (ADR-0002) — the script is the
  reviewable source of its structure, not a reconciled artifact.
- **New device → add a tile to its room section in the generator.** No
  auto-entities, so the dashboard does not follow area/floor changes on its own.
- **Critical controls use `tap_action: more-info`** — the main water valve and
  both gates must not toggle on a single tap. Lights keep the default
  tap-to-toggle.
- **Alert tiles are conditional**: leak sensors sit in a heading-less top
  section with `visibility: [state == on]` — invisible when dry, present when
  triggered. Add future alert sensors the same way.
- Cover tiles carry `features: [cover-open-close]`; positioning stays in the
  more-info dialog.
- `climate.gree_climate` is a stale duplicate of `climate.gree_climate_2`'s
  device and is deliberately excluded.
