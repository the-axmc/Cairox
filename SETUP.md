# Cairox - Starknet Ecosystem Prediction Protocol

## Repository Structure

This is the Cairox repository for a Starknet-native prediction market protocol.

### Getting Started

1. **Create the repository on GitHub:**
   - Go to https://github.com/new
   - Enter repository name: `cairox`
   - Select "Public"
   - Check "Add a README file"
   - Click "Create repository"

2. **Initialize your local repository:**

```bash
git clone https://github.com/YOUR_USERNAME/cairox.git
cd cairox
git remote add upstream https://github.com/OPENCLAW/cairox.git
```

3. **Install dependencies:**

```bash
# Cairo and Scarb
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source "$HOME/.cargo/env"
cargo install scarb starknet-foundry

# Verify installations
scarb --version
snforge --version
```

4. **Set up the project:**

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
cairox/
├── contracts/           # Cairo smart contracts (Scarb workspace)
├── oracle-agent/        # Data oracle agent
├── indexer/             # Indexer service (optional)
├── specs/               # Market specifications (JSON)
├── .github/workflows/   # CI workflows
├── Makefile             # Build targets
├── README.md
└── spec.md
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
- **ConditionalTokens** - Outcome tokens
- **Resolver** - Oracle for market resolution
- **AMM** - Bonding curve market maker

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
