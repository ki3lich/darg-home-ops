# Domain glossary

This repo's ubiquitous language. Implementation-free — terms only, no specs,
no decisions (those live in `docs/adr/`). Maintained by the `/domain-modeling`
skill; see `docs/agents/domain.md`.

## Gates

- **Brama piwnica** — the household name for the single gate the household calls
  "piwnica" (basement), even though the HA integration names the underlying
  device "biuro" (office). One physical gate; the name mismatch is purely an
  integration-vs-household vocabulary split.
  - Backed by the **OXT** device `oxt_brama_biuro` (the working integration):
    - `switch.oxt_brama_biuro_state` — the **trigger**: fires the gate motor.
      Its on/off is *not* a reliable position, because travel can be
      interrupted/stopped mid-open or mid-close.
    - `binary_sensor.oxt_brama_biuro_garage_door_contact` — the **position
      readback**: a `garage_door` reed contact at the closed seal. `off` =
      closed; `on` = anything else (opening / fully open / closing / stopped
      mid-travel). It answers "is it safely shut?" reliably but cannot
      distinguish "fully open" from "stopped halfway."
    - `cover.brama_piwnica` — the **fused cover** entity that exposes the gate
      as one control: state from the contact readback, open/close from the
      trigger. The dashboard binds to this, not to the bare switch.
  - Supersedes the abandoned **Smart Garage Door Opener** integration
    (`cover.smart_garage_door_opener_switch_1` and
    `switch.smart_garage_door_opener_switch_1`, both `unavailable`), whose
    cover was also named "Piwnica." Those are stale registry entries.
