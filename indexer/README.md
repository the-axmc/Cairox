# Cairox Indexer - README

## Overview

The Cairox Indexer is an off-chain service that computes sentiment metrics for prediction markets and generates ZK integrity proofs.

### Features

- **Metrics Computation**: Compute probability, liquidity, and volatility from on-chain events
- **ZK Integrity Proofs**: Generate verifiable proofs that metrics were computed correctly
- **Daily Commitments**: Anchor daily snapshots on-chain via commitment hashes
- **Event Indexing**: Pulls on-chain events via JSON-RPC and persists to SQLite

## Installation

```bash
cd indexer

# Create virtual environment (recommended)
python -m venv venv
source venv/bin/activate

# Install dependencies
pip install -r requirements.txt

# For selector hashing
pip install starknet-py
```

## Project Structure

```
indexer/
├── src/
│   ├── indexer.py      # Main indexer logic
│   ├── metrics.py      # Compute: probability, liquidity, volatility
│   └── proof.py        # Generate ZK proof of metrics
├── scripts/
│   ├── indexer_rebuild.py      # Rebuild index from scratch
│   ├── verify_sentiment_proof.py  # Verify a proof
│   └── e2e_index_proof.py      # E2E test
├── tests/
│   ├── test_metrics.py         # Unit tests for metrics
│   └── test_proof.py           # Test proof generation and verification
├── requirements.txt
└── README.md
```

## Usage

### Basic Usage

```python
from indexer import CairoxIndexer

# Initialize indexer (RPC URL required)
indexer = CairoxIndexer(rpc_url="https://…")

# Index once (range)
indexer.index_range(from_block=0, to_block=1000)
```

### Environment Variables

```
INDEXER_RPC_URL           # Starknet RPC
INDEXER_DB_PATH           # SQLite DB path
MARKET_FACTORY_ADDRESS
OPTIMISTIC_ORACLE_ADDRESS
DATA_COMMITMENT_ADDRESS
PRICE_ORACLE_ADDRESS
MARKET_ADDRESSES_JSON     # optional JSON list or map of market addresses
```

### Command Line

```bash
# Index once
python src/indexer.py --once --from-block 0

# Follow head
python src/indexer.py
```

## Metrics

### Probability

Computed from trade history using decay-weighted average:
- Recent trades have higher weight
- Returns: `(probability, confidence)`

### Liquidity

Computed from vault balances and orderbook depth:
- Sum of all outcome token values
- Includes orderbook depth weighting

### Volatility

Computed from price history:
- Standard deviation of log returns
- Annualized for comparison

## ZK Proof Structure

```json
{
  "public_inputs": [
    "market_id_hash",
    "scaled_probability",
    "scaled_liquidity",
    "scaled_volatility"
  ],
  "proof": {
    "signature": "computed_signature",
    "events_commitment": "commitment_hash"
  },
  "verified": true
}
```

The proof structure supports future Groth16/PLONK integration.

## Dashboard Integration

Metrics include a `verified: bool` field:
- `verified: true` - Proof exists and is valid
- `verified: false` - No proof or proof invalid

The dashboard can query the indexer and show ✓ for verified snapshots.

## Scripts

### indexer_rebuild.py

Rebuild the index from scratch:

```bash
python scripts/indexer_rebuild.py
python scripts/indexer_rebuild.py --market btc-binary-2024
```

### verify_sentiment_proof.py

Verify a previously generated proof:

```bash
python scripts/verify_sentiment_proof.py --proof-path proofs/proof_btc-binary-2024_20240115.json
```

### e2e_index_proof.py

End-to-end test:

```bash
python scripts/e2e_index_proof.py
```

## Testing

```bash
cd tests

# Run all tests
pytest

# Run specific test file
pytest test_metrics.py
pytest test_proof.py

# With coverage
pytest --cov=../src --cov-report=html
```

## Configuration

Set environment variables:

```bash
export STARKNET_NETWORK=goerli
export STARKNET_ACCOUNT_ADDRESS=0x...
# Avoid raw private keys in env for production. Use a keystore + remote signer.
export STARKLI_ACCOUNT=~/.starkli-wallets/deployer/account.json
export STARKLI_KEYSTORE=~/.starkli-wallets/deployer/keystore.json
export ORACLE_CONTRACT_ADDRESS=0x...
export PROOF_DIRECTORY=./proofs
```

## Architecture

```
┌─────────────────┐
│   Starknet      │
│  (Events)       │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   Cairox        │
│   Indexer       │
│  (Events)       │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   Metrics       │
│  (Compute)      │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   ZK Proofs     │
│  (Generate)     │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   Dashboard     │
│  (Visualize)    │
└─────────────────┘
```

## Future Enhancements

- [ ] Groth16 proof generation
- [ ] PLONK proof generation  
- [ ] SQLite database for storage
- [ ] REST API for dashboard access
- [ ] WebSockets for real-time updates
- [ ] Distributed indexing with Redis

## License

MIT
