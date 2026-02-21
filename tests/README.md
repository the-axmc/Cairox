# Cairox Tests

## Running Tests

Tests require `snforge` (Starknet Forge).

### Install snforge
```bash
cargo install snforge
```

### Run tests
```bash
cd contracts
snforge test
```

## Test Coverage Needed

### collateral_vault
- `test_deposit`: User can deposit collateral
- `test_withdraw`: User can withdraw collateral
- `test_insufficient_balance`: Withdraw fails with insufficient balance
- `test_pause`: Owner can pause/unpause

### market
- `test_buy_yes`: Buy YES tokens
- `test_buy_no`: Buy NO tokens
- `test_sell`: Sell tokens
- `test_resolve`: Resolve market with winning outcome
- `test_redeem`: Redeem winnings after resolution
- `test_price_calculation`: Price changes with supply

### oracle
- `test_update_daw`: Update daily active wallets
- `test_get_metrics`: Retrieve stored metrics
- `test_multiple_updates`: Multiple updates increment counter

### lmsr_market_maker
- `test_price_range`: Price is between 0 and 1
- `test_price_movement`: Price moves toward majority
