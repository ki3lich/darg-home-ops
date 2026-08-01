# Store the Zigbee network key explicitly in 1Password

Zigbee2mqtt's network identity (network key, PAN ID, extended PAN ID) is stored as an explicit 1Password item and injected via `envFrom`, rather than using z2mqtt's `GENERATE` option. The explicit key keeps network identity declarative and independent of the PVC, so a PVC loss that volsync cannot restore still preserves the key devices are bonded to. The trade-off is a hard startup prerequisite — the pod will not start until the `zigbee` 1Password item exists — and a first-boot verification obligation: if z2mqtt silently rejects the key format and auto-generates instead, "fixing" the value later orphans any devices already paired.

## Considered options

- **`GENERATE` (rejected):** z2mqtt generates the key on first boot and persists it to `state.json` on the PVC, which volsync already backs up hourly. Simpler — no secret, no startup prerequisite, no format-parsing risk. Rejected because it loses network identity on a double failure (PVC loss plus an unrestorable backup); the explicit key covers exactly that case. Note that device pairings live in `state.json` regardless, so the explicit key preserves only network identity, not the device list — volsync remains the recovery mechanism for pairings.
