cairox
# Cairox - Starknet Ecosystem Prediction Protocol

## Quick Start

```bash
# Clone the repository
git clone https://github.com/YOUR_USERNAME/cairox.git
cd cairox

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
cairox/
├── contracts/           # Cairo smart contracts (Scarb workspace)
│   ├── Scarb.toml       # Workspace manifest
│   ├── src/             # Contract source code
│   │   ├── lib.cairo    # Main contract
│   │   └── dummy_market.cairo  # Dummy contract for testing
│   └── tests/           # Integration tests
│       └── contracts/
│           ├── dummy.cairo
│           └── dummy_market_test.cairo
├── oracle-agent/        # Data oracle agent
│   ├── README.md
│   └── package.json
├── indexer/             # Indexer service (optional)
│   └── README.md
├── specs/               # Market specifications (JSON)
│   ├── markets.json
│   └── package.json
├── .github/workflows/   # CI workflows
│   └── ci.yml
├── Makefile             # Build targets
├── README.md
├── CONTRIBUTING.md
└── DEVNET.md
```

## Smart Contracts

The Cairox protocol consists of:

1. **MarketFactory** - Creates and manages prediction markets
2. **ConditionalTokens** - ERC-1155 style outcome tokens
3. **Resolver** - Oracle for market resolution using growthepie API
4. **AMM** - Bonding curve market maker

### Contract Tests

The dummy contracts demonstrate:
- Contract initialization
- Storage management
- External function calls
- Market creation logic

Run tests with:
```bash
make test
```

## Tooling

- **Scarb** - Cairo package manager and build tool
- **Starknet Foundry (snforge)** - Testing framework
- **Starknet Devnet** - Local development network
- **Starknet.js** - Frontend SDK

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
- Formatting checks

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
