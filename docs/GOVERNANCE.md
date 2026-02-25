# Cairox Governance & Upgrade Strategy

## Goals
- Minimize single‑key risk (EOA owners).
- Provide a clear upgrade path for deployed contracts.
- Ensure changes are transparent and delayed when possible.

## Recommended Setup (Production)
1. **Multisig owner** for all owner‑controlled contracts.
2. **Timelock** between governance decision and execution.
3. **Upgrade policy** published in advance with emergency procedures.

## Upgrade Mechanics
Contracts expose an `upgrade(new_class_hash)` function guarded by `owner`.
In production, the owner should be a multisig (or timelocked multisig).

**Process:**
1. Deploy new class hash.
2. Submit upgrade transaction via multisig.
3. Observe delay (timelock).
4. Execute upgrade and announce publicly.

## Owner Role Hygiene
- Use separate roles for **operations** (oracle reporter) and **governance** (upgrade/pause).
- Limit owner actions to:
  - pausing,
  - upgrading,
  - setting critical parameters (bonds, windows, bounds).

## Emergency Procedures
- Pause trading and/or oracle updates.
- Communicate incident publicly.
- Upgrade to a patched class hash after validation.

## Dev/Test vs Production
