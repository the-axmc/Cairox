# Cairox - Starknet Ecosystem Prediction Protocol

**Decentralized prediction markets for Starknet ecosystem analytics**

Cairox is a prediction market protocol built on Starknet that allows users to trade on real-world and on-chain ecosystem metrics (DAU, TVL, transaction counts) using data from the Growthepie API.

## Table of Contents

- [Overview](#overview)
- [Tech Stack](#tech-stack)
- [Architecture](#architecture)
- [Smart Contracts](#smart-contracts)
- [Getting Started](#getting-started)
- [Project Structure](#project-structure)
- [Data Integration](#data-integration)
- [Running Tests](#running-tests)
- [Deployment](#deployment)
- [License](#license)

## Overview

Cairox enables permissionless prediction markets for Starknet ecosystem metrics.

**V1 Privacy Model**
- Users deposit **USDC** into the ShieldedPool and receive **private Cairox notes** (1:1 backed by USDC).
- All bets are executed via ZK proofs; on-chain trades are attributed to the pool, not user addresses.
- Withdrawals use ZK proofs and are paid out to fresh addresses or relayers.

- **Binary Markets** - YES/NO outcomes (e.g., "Will Starknet exceed 1M DAU?")
- **Categorical Markets** - Multiple outcomes (e.g., "Which L2 will have highest TVL?")
- **Comparative Markets** - Ranked outcomes

Markets are resolved using objective ecosystem data from Growthepie, eliminating oracle manipulation risks.

## Tech Stack

| Component | Technology | Version |
|-----------|------------|---------|
| Smart Contracts | Cairo | 2.8.0 |
| Package Manager | Scarb | 2.8.0 |
| Testing Framework | Starknet Foundry (snforge) | Latest |
| Local Devnet | Starknet Devnet | Latest |
| Oracle Agent | Python | 3.10+ |
| HTTP Client | requests | >=2.28.0 |
| Starknet SDK | starknet-py | >=0.5.0 |
| Indexer | Python | 3.10+ |
| Indexer SDKs | starknet-py, aiohttp | >=0.20.0 |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        User Interface                       │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    Smart Contracts (Starknet)              │
│  ┌─────────────┐  ┌────────────┐  ┌──────────────────────┐ │
│  │   Market    │  │  Collateral│  │   Outcome Tokens     │ │
│  │  Factory    │  │   Vault    │  │   (ERC-1155)         │ │
│  └─────────────┘  └────────────┘  └──────────────────────┘ │
│  ┌─────────────┐  ┌────────────┐  ┌──────────────────────┐ │
│  │    LMSR     │  │  Oracle    │  │   Resolution         │ │
│  │ Market Maker│  │            │  │   Verifier            │ │
│  └─────────────┘  └────────────┘  └──────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    Off-Chain Services                       │
│  ┌─────────────────┐        ┌─────────────────────────┐    │
│  │  Oracle Agent   │        │      Indexer            │    │
│  │ (Growthepie API)│        │  (Event Processing)     │    │
│  └─────────────────┘        └─────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                      Data Sources                           │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              Growthepie API                         │   │
│  │     (https://api.growthepie.com/v1)                 │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## Smart Contracts

The Cairox protocol consists of the following core contracts:

| Contract | Purpose |
|----------|---------|
| `MarketFactory` | Creates and manages prediction markets |
| `Market` | Core market logic (minting, redemption, resolution) |
| `CollateralVault` | Holds collateral deposits |
| `OutcomeToken` | ERC-1155 tokens representing market outcomes |
| `Oracle` | Stores ecosystem metrics from authorized updaters |
| `DataCommitment` | Stores signed market state/data commitments |
| `OptimisticOracle` | Challenge/response oracle workflow |
| `ResolutionVerifier` | Verifies multi-user resolution claims |
| `LMSRMarketMaker` | Automated market maker using LMSR pricing |
| `LMSRMulti` | Multi-outcome LMSR implementation |
| `ShieldedPool` | ZK-based privacy pool for trading |
| `Arbitration` | Dispute resolution for contested outcomes |
| `LaunchConfig` | Configuration for market creation parameters |
| `PriceOracle` | Price feed adapter for collateral |
| `Stablecoin` | Protocol stablecoin for collateral and bonds |

### Key Features

- **Permissionless Market Creation**: Anyone can create a market with collateral
- **Complete Set Minting**: Users deposit collateral to mint equal amounts of all outcomes
- **LMSR Bonding Curve**: Automated price discovery with constant liquidity
- **Deterministic Resolution**: Markets resolve based on Growthepie data
- **Insolvency Prevention**: Total collateral always covers outstanding tokens

## Getting Started

### Prerequisites

- **Rust** (for Scarb)
- **Python 3.10+** (for oracle agent and indexer)
- **Docker** (for local devnet)

### Quick Start

```bash
# Clone the repository
git clone https://github.com/the-axmc/Cairox.git
cd Cairox

# Build contracts
cd contracts
scarb build

# Run tests
make test

# Start local devnet
make devnet-up

# Deploy contracts locally
make deploy-local
```

### Oracle Agent Setup

```bash
cd oracle-agent

# Create virtual environment
python -m venv venv
source venv/bin/activate

# Install dependencies
pip install -r requirements.txt

# Configure environment
cp ../.env.sample .env
# Edit .env with your values

# Run oracle agent
python src/agent.py
```

## Project Structure

```
Cairox/
├── contracts/              # Cairo smart contracts (Scarb package)
│   ├── Scarb.toml         # Package manifest
│   ├── config.json        # Deployment/config inputs
│   ├── scripts/           # Deployment/helpers
│   ├── src/               # Contract source code
│   │   ├── lib.cairo      # Module declarations
│   │   ├── market.cairo
│   │   ├── market_factory.cairo
│   │   ├── collateral_vault.cairo
│   │   ├── outcome_token.cairo
│   │   ├── data_commitment.cairo
│   │   ├── optimistic_oracle.cairo
│   │   ├── price_oracle.cairo
│   │   ├── lmsr_market_maker.cairo
│   │   ├── shielded_pool.cairo
│   │   ├── arbitration.cairo
│   │   ├── resolution_verifier.cairo
│   │   ├── launch_config.cairo
│   │   └── stablecoin.cairo
│   └── tests/             # Integration tests
│       ├── contracts/
│       └── test_cairox.cairo
├── oracle-agent/          # Python oracle for market resolution
│   ├── src/
│   │   ├── agent.py       # Main agent logic
│   │   ├── growthepie.py  # Growthepie API client
│   │   ├── resolver.py    # Resolution logic
│   │   └── contracts.py   # Starknet bindings
│   ├── scripts/
│   └── requirements.txt
├── indexer/               # Off-chain event indexer
│   ├── src/
│   ├── scripts/
│   ├── tests/
│   └── requirements.txt
├── bot/                   # Oracle feeder bot
│   └── oracle_feeder.py
├── scripts/               # Utility scripts
│   ├── e2e_testnet_daa_cycle.py
│   └── oracle_run_once.py
├── specs/                 # Market specifications
├── docs/                  # Documentation
│   ├── DEPLOYMENT.md
│   ├── MARKET_SPEC.md
│   ├── INVARIANTS.md
│   └── THREAT_MODEL.md
├── zk/                    # ZK tooling and circuits
├── .github/workflows/     # CI/CD
│   └── ci.yml
├── Makefile
├── README.md
├── SETUP.md
└── DEVNET.md
```

## Data Integration

### Growthepie API

Cairox uses the Growthepie API for objective ecosystem metrics:

**Base URL**: `https://api.growthepie.com/v1`

**Available Endpoints**:
- `/v1/master.json` - Chain metadata
- `/v1/fundamentals.json?metric={metric}&chain={chain}` - Historical metrics
- `/v1/export/{metric}.json` - Metric exports

**Supported Metrics**:
- `daa` - Daily Active Addresses
- `tvl` - Total Value Locked
- `txcount` - Transaction Count
- `gas_per_second` - Gas usage

**Supported Chains**:
- Ethereum, Starknet, Arbitrum, Base, Optimism
- zkSync Era, Linea, Scroll, Mantle, and others

### Example Query

```bash
curl "https://api.growthepie.com/v1/fundamentals.json?metric=daa&chain=starknet"
```

## Running Tests

### Contract Tests

```bash
cd contracts
make test
```

Or directly with snforge:
```bash
cd contracts
snforge test
```

### Oracle Agent Tests

```bash
cd oracle-agent
source venv/bin/activate
pytest
```

## Deployment

### Local Devnet

```bash
make devnet-up
make deploy-local
```

### Testnet (Sepolia)

See [DEPLOYMENT.md](docs/DEPLOYMENT.md) for detailed instructions.

### Mainnet

Mainnet deployment requires:
1. External oracle (Growthepie API access)
2. Treasury multisig
3. Token bridge integration

## CI/CD

The project uses GitHub Actions for continuous integration:

- **Contract Compilation**: Scarb build verification
- **Tests**: snforge unit tests
- **Formatting**: Cairo format checks

Workflow runs on:
- Push to `master`
- Pull requests to `master`
- Manual dispatch

## Documentation

- [Market Specification](docs/MARKET_SPEC.md) - Market types and resolution rules
- [Deployment Guide](docs/DEPLOYMENT.md) - Testnet and mainnet deployment
- [Invariant Specs](docs/INVARIANTS.md) - Protocol invariants
- [Threat Model](docs/THREAT_MODEL.md) - Security considerations
- [Governance & Upgrades](docs/GOVERNANCE.md) - Upgrade path and admin policy

## License

MIT License - See [LICENSE](LICENSE) for details.

## Resources

- **Website**: https://cairox.io (coming soon)
- **GitHub**: https://github.com/the-axmc/Cairox
- **Discord**: https://discord.gg/cairox (coming soon)
- **Growthepie API Docs**: https://docs.growthepie.com
