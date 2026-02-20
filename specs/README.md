# Cairox Market Specifications

## Overview

This directory contains the specification format for prediction markets on Cairox, using Growthepie as the data source.

## Structure

```
specs/
├── market.schema.json    # JSON Schema for market definitions
├── markets.json          # Example market specifications
└── README.md            # This file
```

## Market Specification Format

### Core Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `market_id` | string | Yes | SHA-256 hash of the spec content (excluding itself) |
| `type` | string | Yes | Market type: `binary_threshold` or `categorical_top1` |
| `metric_source` | string | Yes | Data source: `growthepie` (only supported source) |
| `endpoint` | string | Yes | Growthepie API endpoint path (e.g., `/defi/tvl`) |
| `cutoff` | string (ISO 8601) | Yes | UTC timestamp for market expiration |
| `resolution_rule` | string | Yes | Resolution method: `threshold` or `top1` |
| `aggregation` | string | Yes | How to select final datapoint (e.g., `daily bucket at date 2026-03-01`) |
| `outcomes` | array | Yes | Array of possible outcomes |
| `void_conditions` | array | Yes | Conditions that void the market |
| `dispute_window_seconds` | integer | Yes | Time window for disputes after resolution |

### Type-Specific Fields

#### Binary Threshold Markets (`binary_threshold`)

Additional fields in `threshold_config`:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `threshold_config.threshold_value` | number | Yes | Threshold value to compare against |
| `threshold_config.threshold_operator` | string | Yes | Comparison operator: `>`, `>=`, `<`, `<=` |
| `threshold_config.threshold_unit` | string | Yes | Unit of the threshold value |

Example: `Is BTC TVL above $100B?` with `threshold_value: 100000000000`, `threshold_operator: ">"`, `threshold_unit: "USD"`

#### Categorical Top1 Markets (`categorical_top1`)

Additional fields:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `category_field` | string | Yes | Field name containing category labels |
| `value_field` | string | Yes | Field name containing values to compare |

Example: `Which L2 has highest TVL?` with `category_field: "chain"`, `value_field: "total_active_users"`

### Optional Fields

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Human-readable market name |
| `description` | string | Detailed market description |
| `metadata` | object | Additional metadata |

## Deterministic Market ID

The `market_id` is computed as a SHA-256 hash of the canonicalized market specification (excluding the `market_id` field itself). This ensures:

- Same spec content always produces the same market_id
- No external state required
- Deterministic for smart contract deployment

### Hash Algorithm

1. Sort all keys in the spec alphabetically
2. Serialize to compact JSON (no whitespace)
3. Compute SHA-256 hash of the UTF-8 encoded JSON

```python
import hashlib
import json

def compute_market_id(spec):
    spec_copy = {k: v for k, v in spec.items() if k != "market_id"}
    canonical = json.dumps(spec_copy, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()
```

## Growthepie Integration

### Supported Endpoints

The following Growthepie endpoints are supported:

- `/defi/tvl` - Total Value Locked byasset
- `/ecosystem/activity` - Ecosystem activity metrics
- `/tokens/price` - Token price data
- `/defi/derivatives` - Derivatives market data

### Data Format

Growthepie API responses follow a consistent structure:

```json
{
  "data": [
    {
      "date": "2026-03-01",
      "value": 123456789,
      "category": "Bitcoin"
    }
  ],
  "last_updated": "2026-03-01T00:00:00Z"
}
```

For categorical markets:
```json
{
  "data": [
    {
      "date": "2026-03-01",
      "chain": "Arbitrum",
      "total_active_users": 123456
    }
  ]
}
```

## Validation

Run the validation script to verify market specifications:

```bash
python3 scripts/validate_specs.py
```

## Example Markets

### Binary Threshold Market

```json
{
  "type": "binary_threshold",
  "metric_source": "growthepie",
  "endpoint": "/defi/tvl",
  "cutoff": "2026-03-01T00:00:00Z",
  "resolution_rule": "threshold",
  "aggregation": "daily bucket at date 2026-03-01",
  "outcomes": ["YES", "NO"],
  "void_conditions": [
    "if no BTC TVL data available by cutoff date"
  ],
  "dispute_window_seconds": 86400,
  "threshold_config": {
    "threshold_value": 100000000000,
    "threshold_operator": ">",
    "threshold_unit": "USD"
  },
  "name": "Is BTC TVL above $100B on March 1st?"
}
```

### Categorical Top1 Market

```json
{
  "type": "categorical_top1",
  "metric_source": "growthepie",
  "endpoint": "/ecosystem/activity",
  "cutoff": "2026-03-01T00:00:00Z",
  "resolution_rule": "top1",
  "aggregation": "daily bucket at date 2026-03-01",
  "outcomes": ["Arbitrum", "Optimism", "Base", "Starknet"],
  "void_conditions": [
    "if no L2 activity data available by cutoff date"
  ],
  "dispute_window_seconds": 86400,
  "category_field": "chain",
  "value_field": "total_active_users",
  "name": "Which L2 has highest TVL on March 1st?"
}
```

## Resolution Process

1. **Data Collection**: At the cutoff time, fetch data from the specified Growthepie endpoint
2. **Aggregation**: Apply the aggregation rule to select the final datapoint
3. **Resolution**: Apply the resolution rule:
   - `threshold`: Compare value against threshold, return YES/NO
   - `top1`: Return the category with the highest value
4. **Dispute Window**: Allow disputes for the specified window period
5. **Finalization**: After dispute window, finalize the market outcome

## Void Conditions

Markets may be voided under the following conditions:

- Data source unavailable or returning errors
-Insufficient data points by cutoff time
- Anomaly detected in the data (e.g., sudden spike with no explanation)

Void conditions should be specific and verifiable programmatically.
