# Cairox Tests

## Test Structure

This directory contains Cairo smart contract tests using Starknet Foundry (snforge).

## Running Tests

```bash
cd contracts
make test
```

Or directly with snforge:
```bash
snforge test
```

## Test Categories

### contracts/

- **test_market.cairo** - Tests for market functions (mint, redeem, settlement)
- **test_oracle.cairo** - Tests for the optimistic oracle
- **test_outcome_token.cairo** - Tests for outcome token operations
- **test_collateral_vault.cairo** - Tests for collateral vault management
- **test_lmsr.cairo** - Tests for LMSR market maker
- **test_disputes.cairo** - Tests for dispute resolution
- **test_proof_verification.cairo** - Tests for ZK proof verification (fast-finalize path)

## ZK Proof Verification Tests

The `test_proof_verification.cairo` file tests the fast-finalization path using ZK proofs:

### Test Cases

1. **test_valid_proof_fast_finalize**
   - Propose with proof
   - Fast finalize succeeds
   - Verify status = Resolved immediately

2. **test_invalid_proof_reverts**
   - Propose with invalid proof
   - Fast finalize reverts

3. **test_optimistic_path_still_works**
   - Propose without proof
   - Wait dispute window
   - Finalize works (normal path)

4. **test_outcome_identical**
   - Same data + same spec = same outcome whether proof or optimistic

### E2E Test Script

`scripts/e2e_proof_resolution.py` provides end-to-end testing:

```bash
# Run E2E tests
python scripts/e2e_proof_resolution.py --devnet-url http://localhost:5050

# Options
python scripts/e2e_proof_resolution.py --help
```

## Writing New Tests

Use the snforge testing framework:

```cairo
#[test]
fn test_example() {
    // Setup
    let mut contract = MyContract::constructor();
    
    // Execute
    contract.my_function(arg1, arg2);
    
    // Verify
    let result = contract.get_result();
    assert(result == expected, 'Result mismatch');
}

#[test]
#[should_revert]
fn test_revert() {
    // Test that a function reverts
    let mut contract = MyContract::constructor();
    contract.invalid_call();
}
```

## CI/CD

Tests run automatically on push and pull requests via `.github/workflows/ci.yml`.
