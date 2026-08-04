# Home Assistant blueprints runbook

Operational notes for authoring and deploying HA automation blueprints in
this cluster. HA runs as `default/home-assistant` (HelmRelease under
`kubernetes/apps/default/home-assistant/`); `/config` is a PVC. Zigbee devices
are served by the separate `zigbee` HelmRelease (Zigbee2MQTT) feeding a
standalone `mosquitto` broker — this cluster is **Zigbee2MQTT, not ZHA**, so
only `integration: mqtt` blueprints apply here.

The pod name is ephemeral. Address it by label selector:

```sh
POD=$(kubectl -n default get pod -l app.kubernetes.io/name=home-assistant -o name | head -1)
```

## Blueprint sources are reviewable YAML, deployed by hand

Like the `cover.brama_piwnica` template snippet documented in `dashboards.md`,
a blueprint is **reviewable source, not a reconciled artifact**. The reviewable
YAML lives under `docs/home-assistant/blueprints/` in this repo; the live copy
is hand-placed on the PVC at `/config/blueprints/automation/`. Nothing in this
repo reconciles the live copy — see ADR-0002 for why `/config` is treated as
HA's mutable state.

Per blueprint (so far):

- [`zigbee2mqtt_tuya_ts004f_1_button_loginovo.yaml`](./blueprints/zigbee2mqtt_tuya_ts004f_1_button_loginovo.yaml)
  — Loginovo ZG-101ZL 1-button smart button (Tuya TS004F).

## Deploying a blueprint

A new blueprint is a single new file copied onto the PVC, so this flow is
shorter than the `configuration.yaml` and storage-mode dashboard flows in
`pod-operations.md` / `dashboards.md`: there is no existing copy to back up
(no `.bak` step), and a malformed blueprint surfaces as a validation error
when you create an automation from it in the UI (step 4) — the natural
check point — rather than as a boot failure.

1. **Copy** the YAML onto the pod:

   ```sh
   cat docs/home-assistant/blueprints/<name>.yaml \
     | kubectl -n default exec -i $POD -c app -- sh -c \
       'cat > /config/blueprints/automation/<name>.yaml'
   ```

2. **Fix ownership** to match the other config files (`1000:1000`, mode `644`):

   ```sh
   kubectl -n default exec $POD -c app -- sh -c \
     'chown 1000:1000 /config/blueprints/automation/<name>.yaml &&
      chmod 644 /config/blueprints/automation/<name>.yaml'
   ```

3. **Load it.** Unlike `configuration.yaml` and the `.storage` lovelace files
   (which HA caches in memory and does not watch — so they need a pod
   restart), blueprints are re-scanned on a reload. Try **Developer Tools →
   YAML → Reload Automations** (and Reload Blueprints if shown) first; the new
   blueprint should appear in Settings → Automations → Blueprints. If it
   doesn't, fall back to a pod restart — the restart always works:

   ```sh
   kubectl -n default delete $POD
   ```

4. **Create an automation** from the blueprint in the UI:
   Settings → Automations → Blueprints → pick the blueprint → fill the inputs
   (the button device, and an action for each press type).

## Zigbee2MQTT device triggers — why not the event entity or the action sensor

This cluster's blueprints key off **MQTT device triggers**
(`platform: device`, `domain: mqtt`, `type: action`, `subtype: <action>`),
not the two other Zigbee2MQTT trigger styles. The choice is specific to this
cluster's config:

- **Event entity** (`event.<name>_action`, read via
  `platform: state` on the event entity's `event_type` attribute) is the
  modern Z2M 2.x shape, but it requires
  `homeassistant.experimental_event_entities: true` in the Zigbee2MQTT
  `configuration.yaml`. That flag is **not set** in
  `kubernetes/apps/default/zigbee/app/helmrelease.yaml`, so Z2M does not emit
  `event.*_action` entities here. Adopting that style would be a separate,
  cluster-wide decision (every Z2M device gains event entities) and is not
  coupled to a single button blueprint.
- **`sensor.<name>_action` state trigger** (`platform: state`,
  `attribute: action`) works without the flag, but the action payload is
  published with retain (`ZIGBEE2MQTT_CONFIG_DEVICE_OPTIONS_RETAIN: "true"` in
  the helmrelease). On HA restart the sensor re-reads the last retained
  action, and a state trigger keyed on it can mis-fire once. Device triggers
  are event-based and immune to that restart footgun.
- **MQTT device triggers** need no config change, fire per-press, and are what
  Z2M discovers natively. That is what these blueprints use.

## `operation_mode` prerequisite (ZG-101ZL)

The Loginovo ZG-101ZL has an `operation_mode` setting:

- **`event`** (what these blueprints need) — emits `single` / `double` /
  `hold`, the subtypes the blueprint's device triggers match on.
- **`command`** (the default, group-control mode) — emits `on` / `off` /
  `brightness_*`. The `single` / `double` / `hold` triggers will never fire in
  this mode, and the blueprint will silently do nothing.

Set `operation_mode: event` once per device in the Zigbee2MQTT frontend; the
setting persists on the device. This is a one-time device configuration step,
**not** something the blueprint automates — the blueprint's job is to react to
presses, not to reconfigure the device on every boot.

After pairing or after switching modes, press the button once for **each**
action type (single, double, long press). HA only registers an MQTT device
trigger after it has seen the matching action at least once, so a press type
that has never been pressed will not appear as a discovered trigger.

## Authoring conventions

Keep these when adding a new blueprint:

- **One file per blueprint** under `docs/home-assistant/blueprints/`, named
  `<integration>_<vendor>_<button-count>_button_<commercial>.yaml` for
  button remotes (mirroring the existing TS004F blueprint). The file is the
  verbatim source copied to the PVC.
- **Use device triggers, not event entities or action-sensor state triggers**
  (see above). Key the `trigger:` block with `id:` tags and dispatch with
  `condition: trigger` + `id` in a `choose:` — no Jinja string comparison
  against the action payload.
- **Open `integration: mqtt` device selector** — do **not** constrain by
  `model:` / `manufacturer:`. A constrained selector comes up empty if Z2M
  registers the vendor string slightly differently, which is strictly worse
  than an open selector with the identifying strings named in the input
  `description`. (This is the same false-empty failure mode the
  `floor: parter` auto-entities filter hit, recorded in `dashboards.md`.)
- **One action input per physical gesture the device emits**, each
  independently assignable with `default: []` and an `action: {}` selector.
  Do not trim a harmless gesture (e.g. a button's hold) to "reduce clutter" —
  an unwired input is a no-op now and a blueprint-instance edit later, where a
  dropped input is a blueprint rewrite plus a migration of every instance.
- **`mode: single` + `max_exceeded: silent`** for scene remotes. `restart`
  aborts a running action mid-flight when the next press arrives (a
  half-faded light plus the new press's action), which is worse than
  dropping the overlap; `queued` serialises presses meant to be discrete.
- **Capture the trigger-mechanism rationale here, not in an ADR.** These are
  reversible, hand-deployed YAML files, not infrastructure — the choice fails
  the "hard to reverse" bar for an ADR. A future cluster-wide flip of
  `experimental_event_entities` and migration of all blueprints to event
  entities would clear that bar; a single blueprint does not.
