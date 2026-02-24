# Cairox - Starknet Ecosystem Prediction Protocol

## Quick Start

```bash
# Clone the repository
git clone https://github.com/the-axmc/Cairox.git
cd Cairox

# Install dependencies
cd contracts
scarb build

# Run tests
make test

# Start local devnet
make devnet-up

# Deploy contracts locally
make deploy-local
```

## Project Structure

```
Cairox/
├── contracts/           # Cairo smart contracts (Scarb package)
│   ├── Scarb.toml       # Package manifest
│   ├── src/             # Contract source code
│   ├── tests/           # Integration tests
│   └── scripts/         # Deployment/helpers
├── oracle-agent/        # Data oracle agent (Python)
│   ├── README.md
│   ├── requirements.txt
│   └── src/             # Oracle implementation
├── indexer/             # Indexer service (Python)
│   ├── README.md
│   ├── requirements.txt
│   └── src/
├── specs/               # Market specifications (JSON)
│   └── markets.json
├── docs/                # Protocol documentation
├── zk/                  # ZK tooling and circuits
├── scripts/             # Repo-level utilities
├── .github/workflows/   # CI workflows
│   └── ci.yml
├── Makefile             # Build targets
└── README.md
```

## Smart Contracts

The Cairox protocol consists of:

1. **MarketFactory** - Creates and manages prediction markets
2. **Market** - Core market logic (mint, redeem, resolve)
3. **CollateralVault** - Holds collateral deposits
4. **OutcomeToken** - ERC-1155 style outcome tokens
5. **Oracle / OptimisticOracle** - Data commitments and proposals
6. **ResolutionVerifier** - Verifies multi-user resolution claims
7. **LMSRMarketMaker / LMSRMulti** - Bonding curve pricing
8. **Arbitration** - Dispute resolution
9. **LaunchConfig** - Market creation parameters
10. **PriceOracle / Stablecoin** - Pricing + collateral primitives

## Tooling

- **Scarb** - Cairo package manager and build tool
- **Starknet Foundry (snforge)** - Testing framework
- **Starknet Devnet** - Local development network
- **Python** - Oracle agent and indexer services

## Development

### Local Development

```bash
# Start local devnet
make devnet-up

# Deploy contracts
make deploy-local

# Run all tests
make test

# Clean build artifacts
make clean
```

### CI/CD

The `.github/workflows/ci.yml` workflow runs:
- Contract compilation
- Unit tests with snforge
- Integration tests

## Market Types

1. **Binary Markets** - YES/NO outcomes
2. **Categorical Markets** - Multiple outcome options
3. **Comparative Markets** - Winner among multiple options

## Data Integration

Cairox uses the growthepie API for objective ecosystem metrics:
- Daily/Weekly/Monthly active users
- Transaction counts and volumes
- TVL and DeFi metrics
- Token performance data

## License

MIT License - See LICENSE file for details.
