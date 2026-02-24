# Cairox Invariants

## Core Invariants

### 1. Collateral Preservation
- Total collateral in market = sum of all user deposits
- Users can only withdraw what they've deposited
- Collateral decreases only when tokens are sold or market resolves

### 2. Token Supply
- YES + NO tokens = total supply
- Buying YES increases YES supply, decreases NO (if using LMSR)
- Burning tokens decreases supply

### 3. Resolution Integrity
- Market can only resolve once
- Winning outcome is final once set
- Redeemable tokens = winning outcome balance

### 4. Access Control
- Only owner can pause/resume
- Only owner/factory can resolve market
- Circuit breakers prevent trading when paused

### 5. Rate Limits
- Oracle updates can be rate-limited
- Disputes have cooldown periods
- Spam protection on critical functions

## Verification Strategy

### Static Verification
- Access control: Owner-only functions
- State transitions: Valid state machine paths
- Arithmetic: No overflow in calculations

### Dynamic Verification
- Total supply tracking
- Balance reconciliation
- Event emission for off-chain monitoring
