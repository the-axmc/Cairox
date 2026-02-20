# Oracle Agent v0 for Cairox

A Python agent that resolves growthepie-based markets end-to-end with deterministic outcomes and Starknet integration via the OptimisticOracle.

## Features

- **Fetch data from Growthepie API** with graceful error handling
- **Compute market outcomes** based on aggregation rules (threshold, top1, categorical)
- **On-chain commitments** via Starknet OptimisticOracle
- **Safety checks** to prevent invalid proposals
- **Local data caching** with SHA256 hashing for reproducibility

## Installation

```bash
cd oracle-agent

# Create virtual environment (recommended)
python -m venv venv
source venv/bin/activate

# Install dependencies
pip install -r requirements.txt
```

For basic Growthepie integration without Starknet:
```bash
pip install requests
```

For Starknet integration:
```bash
pip install starknet-py starkli
```

## Configuration

Set environment variables for Starknet interaction:

```bash
export STARKNET_NETWORK=goerli
export STARKNET_ACCOUNT_ADDRESS=0x...
export STARKNET_PRIVATE_KEY=0x...
export ORACLE_CONTRACT_ADDRESS=0x...
export GROWTH_API_URL=https://api.growthepie.xyz
```

## Market Specifications

Create `specs/markets.json` with your market definitions:

```json
{
  "btc-tvl-binary": {
    "market_id": "btc-tvl-binary",
    "endpoint": "/v1/metrics/btc-tvl",
    "resolution_rule": "threshold",
    "aggregation_method": "latest",
    "data_key": "value",
    "threshold": 500000
  },
  "eth-price-top1": {
    "market_id": "eth-price-top1",
    "endpoint": "/v1/metrics/eth-price",
    "resolution_rule": "top1",
    "aggregation_method": "average"
  },
  "top-dexs": {
    "market_id": "top-dexs",
    "endpoint": "/v1/metrics/dex-volumes",
    "resolution_rule": "top1_categorical",
    "aggregation_method": "sum",
    "data_key": "volumes",
    "categorical_options": ["uniswap", "pancakeswap", "sushiswap", "curve"]
  }
}
```

## Usage

### Run a Single Market

```bash
python scripts/run_market.py <market_id>
python scripts/run_market.py btc-tvl-binary --propose
python scripts/run_market.py btc-tvl-binary --finalize
```

Options:
- `--propose`: Propose outcome on-chain (default)
- `--finalize`: Finalize the market
- `--network <goerli|mainnet|sepolia|localhost>`: Starknet network
- `--spec-file <path>`: Custom specifications file

### Run All Markets

```bash
python -m agent --network goerli
```

## Core Logic

### 1. Fetch Data from Growthepie

- Makes HTTP requests to Growthepie API
- Handles timeouts, connection errors, and HTTP errors gracefully
- Performs health check before fetching data

### 2. Compute Outcome

The resolver applies rules based on market specification:

- **THRESHOLD**: Returns YES/NO based on whether value >= threshold
- **TOP1**: Returns YES if top value exists, NO otherwise
- **TOP1_CATEGORICAL**: Returns the winner category name

Aggregation methods:
- `average`: Mean of values
- `median`: Median of values
- `sum`: Sum of values
- `weighted_avg`: Weighted average
- `first`: First value
- `latest`: Latest value (default for time series)

### 3. On-Chain Commitment

- Computes `data_hash = sha256(raw_json)`
- Stores raw data locally with URI `local://{hash}`
- Calls `oracle.propose(market_id, outcome, data_hash, data_uri)` on Starknet

### 4. Safety Checks

The agent **will NOT propose** if:
- API is down or unreachable
- Data is missing or null
- Outcome cannot be computed
- Invalid resolution parameters

## Project Structure

```
oracle-agent/
├── src/
│   ├── agent.py          # Main oracle agent
│   ├── growthepie.py     # Growthepie API client
│   ├── resolver.py       # Market resolution logic
│   └── contracts.py      # Starknet contract interaction
├── scripts/
│   └── run_market.py     # CLI to run a single market
├── specs/
│   └── markets.json      # Market specifications (create this)
├── requirements.txt
└── README.md
```

## Example: BTC TVL Binary Market

1. **Market Spec** (`specs/markets.json`):
```json
{
  "btc-tvl-2024-01": {
    "market_id": "btc-tvl-2024-01",
    "endpoint": "/v1/metrics/btc-tvl",
    "resolution_rule": "threshold",
    "aggregation_method": "latest",
    "data_key": "value",
    "threshold": 600000
  }
}
```

2. **Run the agent**:
```bash
python scripts/run_market.py btc-tvl-2024-01 --propose
```

3. **Wait 5 minutes** for the dispute window

4. **Finalize the market**:
```bash
python scripts/run_market.py btc-tvl-2024-01 --finalize
```

5. **Verify the result**:
```bash
# Query the oracle contract for the market status
```

## Testing

Create a test market spec:

```bash
cat > specs/test_market.json << 'EOF'
{
  "test-market-1": {
    "market_id": "test-market-1",
    "endpoint": "/v1/metrics/btc-tvl",
    "resolution_rule": "threshold",
    "aggregation_method": "latest",
    "data_key": "value",
    "threshold": 100000
  }
}
EOF
```

Run with custom spec file:
```bash
python scripts/run_market.py test-market-1 --spec-file specs/test_market.json
```

## Error Handling

| Error | Behavior |
|-------|----------|
| Growthepie API down | Logs error, does NOT propose |
| Network timeout | Logs error, does NOT propose |
| Invalid data format | Logs error, does NOT propose |
| Missing threshold | Raises ValueError, does NOT propose |
| Starknet connection failed | Logs error, does NOT propose |

## Integration with OptimisticOracle

The `contracts.py` module provides:
- `propose(market_id, outcome, data_hash, data_uri)` - Submit outcome
- `finalize(market_id)` - Finalize after dispute window
- `get_market_status(market_id)` - Query market status
- `get_balance(address)` - Check ETH balance

## License

MIT
