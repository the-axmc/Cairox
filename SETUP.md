# Cairox - Starknet Ecosystem Prediction Protocol

## Repository Structure

This is the Cairox repository for a Starknet-native prediction market protocol.

### Getting Started

1. **Clone the repository:**

```bash
git clone https://github.com/the-axmc/Cairox.git
cd Cairox
```

2. **Install dependencies:**

```bash
# Cairo and Scarb
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source "$HOME/.cargo/env"
cargo install scarb starknet-foundry

# Verify installations
scarb --version
snforge --version
```

3. **Set up the project:**

```bash
# Start local devnet
make devnet-up

# Run tests
make test

# Deploy contracts
make deploy-local
```

### Project Structure

```
Cairox/
├── contracts/           # Cairo smart contracts (Scarb package)
├── oracle-agent/        # Data oracle agent (Python)
├── indexer/             # Indexer service (Python)
├── bot/                 # Oracle feeder bot
├── scripts/             # Repo-level utilities
├── specs/               # Market specifications (JSON)
├── docs/                # Protocol documentation
├── zk/                  # ZK tooling and circuits
├── .github/workflows/   # CI workflows
├── Makefile             # Build targets
├── README.md
└── .env.sample
```

### Makefile Targets

| Target | Description |
|--------|-------------|
| `make test` | Run all tests with snforge |
| `make devnet-up` | Start local Starknet devnet |
| `make deploy-local` | Deploy contracts to local devnet |
| `make clean` | Remove build artifacts |

### Development

#### Running Tests

```bash
make test
```

This runs all Cairo tests using Starknet Foundry.

#### Local Development

```bash
# Start devnet in one terminal
make devnet-up

# Deploy contracts in another terminal
make deploy-local
```

### Smart Contracts

The Cairox protocol consists of:
- **MarketFactory** - Creates prediction markets
- **Market** - Core market logic
- **CollateralVault** - Holds collateral deposits
- **OutcomeToken** - Outcome tokens
- **Oracle / OptimisticOracle** - Data commitments and proposals
- **ResolutionVerifier** - Verifies resolution claims
- **LMSRMarketMaker / LMSRMulti** - Bonding curve market makers
- **Arbitration** - Dispute resolution
- **LaunchConfig** - Market creation parameters

### Data Integration

Cairox uses the growthepie API for objective ecosystem metrics:
- User activity (DAU, WAU, MAU)
- Transaction metrics
- DeFi metrics
- Token performance

### CI/CD

The CI workflow automatically runs tests on push and pull requests.

### License

MIT License - See LICENSE file for details.
