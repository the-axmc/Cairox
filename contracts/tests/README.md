# Cairox Tests

Tests require `snforge` (Starknet Forge).

## Install snforge
```bash
cargo install snforge
```

## Run tests
```bash
cd contracts
snforge test
```

## Test coverage needed
- collateral_vault: deposit, withdraw, balance
- market: buy, sell, resolve, redeem, prices
- oracle: update values, get values
- lmsr_market_maker: price calculations
