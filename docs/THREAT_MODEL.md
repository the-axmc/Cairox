# Cairox Threat Model

## Assets
- User collateral (deposited funds)
- Market outcomes (YES/NO tokens)
- Oracle data (metric values)

## Threat Vectors

### 1. Oracle Manipulation
- **Risk**: False data posted to oracle
- **Mitigation**: Rate limiting, circuit breakers, owner controls
- **Impact**: Incorrect market resolution

### 2. Front-Running
- **Risk**: Traders seeing pending transactions
- **Mitigation**: Front-running not fully preventable on-chain
- **Impact**: Reduced user confidence

### 3. Dispute Abuse
- **Risk**: Spam disputes to delay resolution
- **Mitigation**: Rate limits, reject capability
- **Impact**: Delayed resolution, DOS

### 4. Circuit Breaker Failure
- **Risk**: Breakers not triggering when needed
- **Mitigation**: Manual override, observability
- **Impact**: Continued trading during crisis

### 5. Collusion
- **Risk**: Owner + attacker coordination
- **Mitigation**: Multi-sig consideration, transparency
- **Impact**: Fund theft, unfair resolution

## Security Assumptions
- Owner is benign (or multisig)
- Starknet L1 is secure
- Growthepie API data is reliable

## Monitoring
- `total_trades`, `total_volume` - trading activity
- `total_updates`, `failed_updates` - oracle health
- `trading_paused` - circuit breaker status
- `dispute_count` - dispute activity
