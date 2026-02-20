starknet-devnet
# Cairox Devnet Configuration

This document describes the local devnet setup for Cairox development.

## Requirements

- Docker (optional, for containerized devnet)
- starknet-devnet (Python version)

## Installation

### Option 1: Using Docker

```bash
docker run -p 5050:5050 shardum-dev/starknet-devnet:latest --seed 0 --account-class cairo1
```

### Option 2: Using Python

```bash
pip install starknet-devnet
starknet-devnet --seed 0 --account-class cairo1
```

## Configuration

The default devnet URL is `http://127.0.0.1:5050`.

## Account Configuration

The devnet comes with pre-funded accounts. Use:
- Private Key: `0x111111111111111111111111111111111111111111111111111111111111111`
- Account Address: auto-generated from the above private key

## Deployment Script

```bash
make devnet-up
make deploy-local
```

This will:
1. Start the local devnet
2. Wait for it to be ready
3. Deploy the Cairox contracts

## Resetting the Devnet

```bash
make clean
make devnet-up
make deploy-local
```

## Troubleshooting

If the devnet doesn't start:
- Check that port 5050 is not in use
- Verify you have sufficient permissions
- Try restarting the devnet with a different seed
