# Cairox Contracts - Scarb Workspace

This directory contains the Cairo smart contracts for the Cairox protocol.

## Structure

```
contracts/
├── Scarb.toml       # Workspace manifest
├── src/
│   └── lib.cairo    # Main contract entry point
└── tests/
    └── contracts/   # Test files
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
