# Scripts Directory

Contains utility scripts for working with Cairox market specifications.

## Security Note
These scripts use raw private keys for convenience in dev/test environments.
For production, use a keystore + remote signer (HSM or wallet), and avoid
passing secrets via environment variables or CLI flags.

## validate_specs.py

Validate market specifications against the JSON schema and generate deterministic market IDs.

### Usage

```bash
python3 scripts/validate_specs.py
```

### Features

- Validates markets against `specs/market.schema.json`
- Computes deterministic SHA-256 market IDs from spec content
- Detects and reports validation errors
- Prints human-readable summary

### Output

```
============================================================
Cairox Market Specification Validator
============================================================

[1/4] Loading market schema...
    ✓ Loaded schema from specs/market.schema.json

[2/4] Loading market specifications...
    ✓ Loaded 2 markets from specs/markets.json

[3/4] Validating markets...
    Market 1: Is BTC TVL above $100B on March 1st?
    Type: binary_threshold
    ✓ market_id: a3f5e8c901234567...
    ✓ All validations passed

    Market 2: Which L2 has highest TVL on March 1st?
    Type: categorical_top1
    ✓ market_id: b8d2a1e098765432...
    ✓ All validations passed

============================================================
Summary
============================================================
✓ All markets are valid

Generated market_ids (SHA-256 hashes):
  1. Is BTC TVL above $100B on March 1st?
     a3f5e8c90123456789abcdef0123456789abcdef0123456789abcdef01
  2. Which L2 has highest TVL on March 1st?
     b8d2a1e09876543210fedcba9876543210fedcba9876543210fedcba98
```

## e2e_resolution_payout.py

End-to-end flow that creates a market, buys YES, resolves via OptimisticOracle, and redeems winnings.

### Usage

```bash
python3 scripts/e2e_resolution_payout.py --rpc-url $STARKNET_RPC_URL
```
