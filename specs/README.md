# Market Specifications

This directory contains JSON files describing Cairox market configurations.

## File Format

```json
{
  "markets": [
    {
      "id": "market_001",
      "type": "binary",
      "question": "Will Starknet DAU exceed 100k by Dec 31, 2024?",
      "metric": "dau",
      "comparator": "gt",
      "threshold": 100000,
      "period": "daily",
      "expires_at": "2024-12-31T23:59:59Z",
      "oracle_address": "0x...",
      "fees": {
        "creation_fee": "0.001",
        "trading_fee": "0.005"
      }
    }
  ]
}
```

## Available Metrics

See the SPEC.md file in the parent directory for a complete list of available metrics.
