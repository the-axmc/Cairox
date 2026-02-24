# Cairox Market Types Specification

## Binary Markets (YES/NO)

### Structure
- Single question: "Will [event] happen?"
- Two outcomes: YES (1) or NO (0)
- Resolution by oracle or owner

### Parameters
- `b`: Liquidity parameter (higher = more stable prices)
- `min_trade_size`: Minimum trade allowed
- `max_trade_size`: Maximum trade allowed
- `resolution_delay`: Time before resolution allowed

### Lifecycle
1. **Created**: Market deployed with question
2. **Active**: Trading open
3. **Paused**: Trading halted (emergency)
4. **Resolved**: Winner determined
5. **Redeemed**: Winners claim tokens

### Example Markets
1. "Will Starknet hit 100k TPS by Q4 2025?"
2. "Will ETH exceed $5000 in 2025?"
3. "Will Cairo have native fixed-point math?"

## Multi-Outcome Markets

### Structure
- Multiple possible outcomes
- LMSR for price calculation
- Winner receives all (or portion)

### Parameters
- `outcome_count`: Number of possible outcomes
- `b`: Liquidity parameter

## Integration with Growthepie

### Metrics
- `DAW`: Daily Active Wallets
- `TXS`: Transaction count
- `CONTRACTS`: Contract activity
- `TOKENS`: Token activity

### Oracle Usage
Markets can use oracle data for:
- Determining resolution (if metric-based)
- Informing users (off-chain display)
- Statistical analysis

## Circuit Breakers

### Oracle Circuit Breaker
- `pause_oracle()`: Stop all oracle updates
- `resume()`: Resume normal operation
- State: NORMAL → PAUSED

### Market Circuit Breaker  
- `pause_trading()`: Halt all trading
- `resume_trading()`: Resume trading
- State: ACTIVE → PAUSED → ACTIVE
