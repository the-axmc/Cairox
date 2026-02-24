# Cairox Testnet Launch Plan

## Phase 1: SEED (Day 1-7)
**Goal**: Internal testing with allowlisted LPs only

### Parameters
- Max bet size: 0.1 ETH
- Max total volume: 1 ETH
- B-parameter: 1000 (conservative)
- Markets: 2-4
- Allowlist: REQUIRED

### Markets (Example)
1. "Will Starknet hit 10k TPS by end of Q1 2026?"
2. "Will ETH exceed $5000 in 2026?"
3. "Will Bitcoin hit $200k in 2026?"

### Controls
- Only allowlisted addresses can trade
- No permissionless reporting
- No disputes
- Full owner control

## Phase 2: CONTROLLED (Day 7-21)
**Goal**: Expand to more traders with limits

### Parameters
- Max bet size: 0.5 ETH
- Max total volume: 10 ETH
- B-parameter: 5000
- Markets: 8-10
- Allowlist: OPTIONAL

### Actions
- Add trusted traders to allowlist
- Enable permissionless reporting (owner-only)
- Enable disputes (limited)

## Phase 3: OPEN (Day 21+)
**Goal**: Full launch

### Parameters
- Max bet size: 10 ETH
- Max total volume: Unlimited
- B-parameter: 10000
- Markets: Unlimited
- Allowlist: DISABLED

## Deployment Checklist

### Pre-deploy
- [ ] Deploy LaunchConfig
- [ ] Deploy Oracle
- [ ] Deploy CollateralVault
- [ ] Deploy MarketFactory
- [ ] Create initial markets

### Seed Phase
- [ ] Add LP addresses to allowlist
- [ ] Verify contracts work
- [ ] Monitor trading activity

### Controlled Phase  
- [ ] Enable controlled phase
- [ ] Add trader allowlist
- [ ] Enable reporting

### Open Phase
- [ ] Enable open phase
- [ ] Disable allowlist
- [ ] Monitor for issues

## Emergency Rollback
If issues occur:
1. `pause_oracle()` - Stop oracle updates
2. `pause_trading()` - Stop all trading
3. `set_phase(PHASE_SEED)` - Return to seed phase
