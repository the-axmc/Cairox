# Cairox Contracts - Scarb Package

This directory contains the Cairo smart contracts for the Cairox protocol.

## Structure

```
contracts/
├── Scarb.toml       # Package manifest
├── config.json      # Deployment/config inputs
├── scripts/         # Deployment/helpers
├── src/
│   ├── lib.cairo                # Module declarations
│   ├── market.cairo
│   ├── market_factory.cairo
│   ├── collateral_vault.cairo
│   ├── outcome_token.cairo
│   ├── oracle.cairo
│   ├── optimistic_oracle.cairo
│   ├── price_oracle.cairo
│   ├── lmsr_market_maker.cairo
│   ├── lmsr_multi.cairo
│   ├── arbitration.cairo
│   ├── resolution_verifier.cairo
│   ├── launch_config.cairo
│   ├── stablecoin.cairo
│   ├── dummy_market.cairo
│   └── dummy_oracle.cairo
└── tests/
    ├── contracts/               # Test helpers
    └── test_cairox.cairo         # Main test entry
```

## Dependencies

- `starknet` - Starknet core library

## Building

```bash
cd contracts
scarb build
```

## Testing

```bash
scarb test
```

## Deploying Locally

```bash
make devnet-up
make deploy-local
```
