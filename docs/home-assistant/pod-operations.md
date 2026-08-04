# Home Assistant pod operations

Guide for deploying `configuration.yaml` changes to the `default/home-assistant`
pod and testing them. For dashboard-specific edits, the REST API, and the
entity registries, see `dashboards.md`. For why `/config` is treated as HA's
mutable state (not a reconciled artifact), see ADR-0002.

HA runs as `default/home-assistant` (HelmRelease under
`kubernetes/apps/default/home-assistant/`); `/config` is a PVC. The pod name is
ephemeral — address it by label selector:

```sh
POD=$(kubectl -n default get pod -l app.kubernetes.io/name=home-assistant -o name | head -1)
```

`/config` is HA's mutable state, not a reconciled artifact (ADR-0002).
`configuration.yaml` is hand-edited on the PVC; nothing in this repo reconciles
it. The snippet in `dashboards.md` (or a template entity) is the reviewable
source of a config change, not a git artifact.

## HA caches config in memory — edits need a restart

HA loads `configuration.yaml` and the `.storage/` lovelace files into memory at
startup and does **not** watch them for external edits. A raw file write via
`kubectl exec` is invisible until HA reboots. (Saving through HA's WebSocket
API updates the in-memory store live, but an external file write does not.)
Every `configuration.yaml` change therefore ends with a pod restart — same as
the storage-mode dashboard flow in `dashboards.md`.

## Deploying a `configuration.yaml` change

1. **Back up** the existing file on the PVC:

   ```sh
   TS=$(date +%Y%m%d-%H%M%S)
   kubectl -n default exec $POD -c app -- sh -c \
     "cp /config/configuration.yaml /config/configuration.yaml.bak.$TS"
   ```

2. **Write** the new config to a temp path, then atomically move it into place
   and fix ownership to match the other config files (`1000:1000`, mode `644`):

   ```sh
   # build .new from the original, then append/modify your section
   kubectl -n default exec $POD -c app -- sh -c \
     'cat /config/configuration.yaml > /config/configuration.yaml.new'
   # ...append your changes to /config/configuration.yaml.new...
   kubectl -n default exec $POD -c app -- sh -c '
     mv /config/configuration.yaml.new /config/configuration.yaml &&
     chown 1000:1000 /config/configuration.yaml &&
     chmod 644 /config/configuration.yaml'
   ```

3. **Validate before restarting** with the in-container HA CLI (below). HA
   keeps running on its in-memory config during validation, so a bad config is
   caught with no downtime; restore from the backup if it errors.

4. **Restart** the pod (below).

## Validating config without downtime: `hass --script check_config`

The authoritative validator is the HA CLI inside the container — it
understands HA-specific YAML tags (`!include`, `!include_dir_merge_named`) and
template syntax, and runs against the in-place file while HA is still up on its
old in-memory config:

```sh
kubectl -n default exec $POD -c app -- hass --script check_config -c /config
```

- **Check the exit code, not just the output.** `0` = valid. Capture it with
  `sh -c '...; echo EXIT=$?'` because the output is ANSI-coloured and long.
- **Do not pass `-f` / `--fail-on-warnings`.** It exits non-zero on pre-existing
  custom-component warnings (`custom_components/solarman/...`, `spook`,
  `webrtc`, themes) unrelated to your change, which masks the real signal. Run
  without `-f` and inspect the exit code + grep for
  `error|invalid|traceback`.
- **Do not validate `configuration.yaml` with `python3 -c "import yaml;
  yaml.safe_load(...)"`.** PyYAML's `safe_load` does not understand `!include`
  (an HA-specific tag) and raises `ConstructorError` on a pre-existing line —
  it false-fails on a valid config. Use `hass --script check_config`.

## Restarting the pod

```sh
# $POD from `kubectl get pod ... -o name` already carries the pod/ prefix —
# do NOT add a separate `pod` argument (kubectl delete pod pod/... errors).
kubectl -n default delete $POD
```

The Deployment replaces it. Wait for the new pod and poll the API for your
entity (see below).

## Testing after a config change

Integrations and template entities load **asynchronously** after startup.
Right after a restart, a new entity may read `unknown` (or be absent) for a few
seconds while its integration reports in — this is normal, not a config error.
Poll `/api/states/<entity_id>` until it resolves:

```sh
export HASS_TOKEN=$(op read op://darg-home-ops/claude/password)
for i in 1 2 3 4 5 6 7 8 9 10; do
  sleep 8
  S=$(curl -s -m 8 -H "Authorization: Bearer $HASS_TOKEN" -H "User-Agent: curl/8.0" \
    "https://hass.darg.win/api/states/<entity_id>" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('state',''))" 2>/dev/null)
  [ -n "$S" ] && { echo "ready after ~$((i*8))s: $S"; break; }
done
```

- Verify the entity exists and its state/attributes match expectations.
- Cross-check any source entities it derives from (e.g. a template cover's
  contact sensor) to confirm the derived state is correct.
- Check the pod logs for setup errors:

  ```sh
  kubectl -n default logs $POD -c app --tail=500 \
    | grep -iE "error|invalid|traceback|Error while setting up"
  ```

## Long-lived access token

The REST API (`/api/states`, etc.) needs a long-lived token from HA UI →
Profile → Long-Lived Access Tokens, stored in 1Password:

```sh
export HASS_TOKEN=$(op read op://darg-home-ops/claude/password)
```

The `op` session can expire mid-session — `op read` then returns an empty string
and every API call 401s (the entity poll above silently loops "not yet"). If
that happens, re-authenticate with `op signin` and re-export the token. Quick
probes: `echo "len: ${#HASS_TOKEN}"` (should be > 10) and
`curl -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $HASS_TOKEN" https://hass.darg.win/api/`
(should be `200`).
