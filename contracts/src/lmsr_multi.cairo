// Multi-Outcome LMSR Market Maker for Cairox
// Implements Logarithmic Market Scoring Rule (LMSR) for categorical prediction markets
// Supports N outcomes (e.g., which L2 has highest TVL: ARB, OP, BASE, STARKNET)

use starknet::ContractAddress;
use starknet::SyscallResult;
use starknet::{get_caller_address, StorageAddress};
use starknet::cast::cast_felt;
use openzeppelin::token::erc20::interfaces::IERC20Metadata;
use openzeppelin::math::u256 as u256_lib;
use openzeppelin::math::felt252_arith::Felt252ArithTrait;
use openzeppelin::utils::Revertable;
use starknet::Felt252Traits;

#[cfg(test)]
mod test {
    use starknet::ContractAddress;
    use starknet::cast::cast_felt;
    use openzeppelin::math::u256 as u256_lib;

    // Fixed point precision constants
    pub fn fixed_point_precision() -> u256_lib::U256 {
        u256_lib::U256 { low: 1_000_000_000_000_000_000_u128, high: 0 } // 1e18
    }

    // Helper function to create a u256 value
    pub fn u256_value(amount: u128) -> u256_lib::U256 {
        u256_lib::U256 {
            low: amount,
            high: 0,
        }
    }

    // Helper to convert felt252 to u256 (assumes value fits in u128)
    pub fn felt_to_u256(val: felt252) -> u256_lib::U256 {
        u256_lib::U256 {
            low: val.try_into().unwrap(),
            high: 0,
        }
    }
}

// Address constants for integration points
const MARKET_FACTORY_ADDRESS: felt252 = 0x1;
const COLLATERAL_VAULT_ADDRESS: felt252 = 0x2;
const ORACLE_ADDRESS: felt252 = 0x3;

// Market state constants
const STATE_ACTIVE: felt252 = 0;
const STATE_RESOLVED: felt252 = 1;
const STATE_VOIDED: felt252 = 2;

#[starknet::interface]
pub trait ILMSRMulti {
    fn initialize(ref self: LMSRMulti, outcomes: Array<felt252>, b: felt252);
    fn buy(ref self: LMSRMulti, outcome_idx: felt252, collateral_in: u256_lib::U256, min_tokens_out: u256_lib::U256) -> (tokens_out: u256_lib::U256);
    fn sell(ref self: LMSRMulti, outcome_idx: felt252, tokens_in: u256_lib::U256, min_collateral_out: u256_lib::U256) -> (collateral_out: u256_lib::U256);
    fn get_price(self: @LMSRMulti, outcome_idx: felt252) -> (price: felt252);
    fn get_all_prices(self: @LMSRMulti) -> (prices: Array<felt252>);
    fn check_solvency(self: @LMSRMulti) -> (is_solvent: bool);
    fn resolve_market(ref self: LMSRMulti, winning_outcome: felt252);
    fn get_market_state(self: @LMSRMulti) -> felt252;
    fn get_outcomes(self: @LMSRMulti) -> (outcomes: Array<felt252>);
    fn get_b_parameter(self: @LMSRMulti) -> felt252;
}

// Storage struct for multi-outcome market
#[derive(Drop, CairoShape)]
struct LMSRMultiStorage {
    /// Array of outcome names (e.g., ["ARB", "OP", "BASE", "STARKNET"])
    outcomes: Array<felt252>,
    /// Liquidity parameter b (controls spread, higher = more liquid)
    b: felt252,
    /// Mapping from outcome index to tokens issued for that outcome
    outcome_balances: Map<felt252, u256_lib::U256>,
    /// Total collateral held in vault (for solvency checking)
    collateral: u256_lib::U256,
    /// Market state: 0 = active, 1 = resolved, 2 = voided
    market_state: felt252,
    /// Winning outcome index (set when resolved)
    winning_outcome: felt252,
    /// Total number of outcomes
    num_outcomes: felt252,
}

#[starknet::contract]
mod LMSRMulti {
    use super::{test, ILMSRMulti, LMSRMultiStorage};
    use starknet::SyscallResult;
    use starknet::{get_caller_address, StorageAddress};
    use starknet::cast::cast_felt;
    use openzeppelin::token::erc20::interfaces::IERC20Metadata;
    use openzeppelin::math::u256 as u256_lib;
    use openzeppelin::math::felt252_arith::Felt252ArithTrait;
    use openzeppelin::utils::Revertable;

    #[storage]
    struct Storage {
        /// LMSR multi internal state
        lmsr: LMSRMultiStorage,
    }

    /// Fixed point precision (1e18)
    const FIXED_POINT_PRECISION: felt252 = 1_000_000_000_000_000_000;

    /// Initializes the multi-outcome LMSR market maker
    /// @param outcomes Array of outcome names (e.g., ["ARB", "OP", "BASE", "STARKNET"])
    /// @param b The liquidity parameter (controls spread, higher = more liquid)
    #[external]
    #[init]
    fn initialize(ref self: LMSRMulti, outcomes: Array<felt252>, b: felt252) {
        let caller = get_caller_address();
        
        // Only allow initialization by the market factory
        let market_factory_felt = cast_felt(MARKET_FACTORY_ADDRESS);
        assert(caller.value == market_factory_felt, 'Unauthorized: only market factory can initialize');
        
        // Validate inputs
        let num_outcomes = outcomes.len();
        assert(num_outcomes >= 2, 'Must have at least 2 outcomes');
        assert(num_outcomes <= 10, 'Cannot have more than 10 outcomes');
        assert(b > 0, 'b parameter must be positive');
        
        // Initialize LMSR storage
        self.lmsr.write(LMSRMultiStorage {
            outcomes: outcomes,
            b: b,
            outcome_balances: Map::<felt252, u256_lib::U256>::default(),
            collateral: u256_lib::U256 { low: 0, high: 0 },
            market_state: STATE_ACTIVE,
            winning_outcome: 0,
            num_outcomes: num_outcomes,
        });
    }

    /// Buys tokens for a specific outcome
    /// @param outcome_idx Index of outcome (0, 1, 2...)
    /// @param collateral_in Amount to spend
    /// @param min_tokens_out Minimum tokens to receive
    /// @return tokens_out Number of tokens received
    #[external]
    fn buy(ref self: LMSRMulti, outcome_idx: felt252, collateral_in: u256_lib::U256, min_tokens_out: u256_lib::U256) -> (tokens_out: u256_lib::U256) {
        let caller = get_caller_address();
        
        // Market must be active
        let state = self.lmsr.read().market_state;
        assert(state == STATE_ACTIVE, 'Market is resolved or voided');
        
        // Validate outcome index
        let lmsr = self.lmsr.read();
        assert(outcome_idx >= 0 && outcome_idx < lmsr.num_outcomes, 'Invalid outcome index');
        
        // Check solvency before trade
        let solvent = Self::check_solvency(@LMSRMulti { storage: self.storage });
        assert(solvent, 'Market would become insolvent');
        
        // Calculate tokens to mint
        let tokens_out = Self::calculate_tokens_bought(
            @LMSRMulti { storage: self.storage },
            outcome_idx,
            collateral_in
        );
        
        // Enforce minimum output
        assert(u256_lib::U256_ge(tokens_out, min_tokens_out), 'Slippage exceeded');
        
        // Transfer collateral from caller to vault
        Self::transfer_collateral_in(ref self, caller, collateral_in);
        
        // Update outcome balance
        let mut outcome_balances = lmsr.outcome_balances;
        let current_balance = outcome_balances.read(outcome_idx);
        outcome_balances.write(outcome_idx, u256_lib::U256_add(current_balance, tokens_out));
        
        // Update collateral
        let mut new_lmsr = lmsr;
        new_lmsr.collateral = u256_lib::U256_add(lmsr.collateral, collateral_in);
        self.lmsr.write(new_lmsr);
        
        // Check solvency after trade
        let solvent_after = Self::check_solvency(@LMSRMulti { storage: self.storage });
        assert(solvent_after, 'Market is insolvent after trade');
        
        (tokens_out,)
    }

    /// Sells tokens for a specific outcome
    /// @param outcome_idx Index of outcome
    /// @param tokens_in Amount to sell
    /// @param min_collateral_out Minimum collateral to receive
    /// @return collateral_out Amount of collateral received
    #[external]
    fn sell(ref self: LMSRMulti, outcome_idx: felt252, tokens_in: u256_lib::U256, min_collateral_out: u256_lib::U256) -> (collateral_out: u256_lib::U256) {
        let caller = get_caller_address();
        
        // Market must be active
        let state = self.lmsr.read().market_state;
        assert(state == STATE_ACTIVE, 'Market is resolved or voided');
        
        // Validate outcome index
        let lmsr = self.lmsr.read();
        assert(outcome_idx >= 0 && outcome_idx < lmsr.num_outcomes, 'Invalid outcome index');
        
        // Check sufficient tokens
        let outcome_balances = lmsr.outcome_balances;
        let current_balance = outcome_balances.read(outcome_idx);
        assert(u256_lib::U256_ge(current_balance, tokens_in), 'Insufficient tokens');
        
        // Calculate collateral to return
        let collateral_out = Self::calculate_collateral_returned(
            @LMSRMulti { storage: self.storage },
            outcome_idx,
            tokens_in
        );
        
        // Enforce minimum output
        assert(u256_lib::U256_ge(collateral_out, min_collateral_out), 'Slippage exceeded');
        
        // Transfer collateral to caller from vault
        Self::transfer_collateral_out(ref self, caller, collateral_out);
        
        // Update outcome balance
        let mut outcome_balances = lmsr.outcome_balances;
        outcome_balances.write(outcome_idx, u256_lib::U256_sub(current_balance, tokens_in).unwrap());
        
        // Update collateral
        let mut new_lmsr = lmsr;
        new_lmsr.collateral = u256_lib::U256_sub(lmsr.collateral, collateral_out).unwrap();
        self.lmsr.write(new_lmsr);
        
        (collateral_out,)
    }

    /// Gets current price of an outcome
    /// Price formula: p_i = e^(q_i/b) / Σ e^(q_j/b)
    /// @param outcome_idx Index of outcome
    /// @return price Price as fixed-point number (scaled by 1e18)
    #[external]
    fn get_price(self: @LMSRMulti, outcome_idx: felt252) -> (price: felt252) {
        let lmsr = self.lmsr.read();
        
        // Validate outcome index
        assert(outcome_idx >= 0 && outcome_idx < lmsr.num_outcomes, 'Invalid outcome index');
        
        let b = lmsr.b;
        
        // Calculate sum of e^(q_j/b) for all outcomes
        let mut sum_exp: felt252 = 0;
        let mut i: felt252 = 0;
        while i < lmsr.num_outcomes {
            let q_i = Self::get_outcome_balance(self, i);
            let exp_q_i = Self::fixed_point_exp(Self::div_fixed(q_i, b));
            sum_exp = sum_exp + exp_q_i;
            i = i + 1;
        }
        
        // Calculate e^(q_i/b) for the requested outcome
        let q_i = Self::get_outcome_balance(self, outcome_idx);
        let exp_q_i = Self::fixed_point_exp(Self::div_fixed(q_i, b));
        
        // Price = e^(q_i/b) / sum_exp
        Self::div_fixed(exp_q_i, sum_exp)
    }

    /// Gets prices of all outcomes
    /// @return prices Array of prices (scaled by 1e18)
    #[external]
    fn get_all_prices(self: @LMSRMulti) -> (prices: Array<felt252>) {
        let lmsr = self.lmsr.read();
        let mut prices: Array<felt252> = Array::new();
        
        let mut i: felt252 = 0;
        while i < lmsr.num_outcomes {
            let price = Self::get_price(@LMSRMulti { storage: self.storage }, i);
            prices.append(price);
            i = i + 1;
        }
        
        prices
    }

    /// Checks if the market maker is solvent
    /// Solvent if: collateral >= max_payout
    /// max_payout = sum of all outcome balances (in worst case, all pay 1)
    /// @return is_solvent True if solvent
    #[external]
    fn check_solvency(self: @LMSRMulti) -> (is_solvent: bool) {
        let lmsr = self.lmsr.read();
        
        // Maximum possible payout is the sum of all tokens outstanding
        let mut max_payout = u256_lib::U256 { low: 0, high: 0 };
        let mut i: felt252 = 0;
        while i < lmsr.num_outcomes {
            let balance = lmsr.outcome_balances.read(i);
            max_payout = u256_lib::U256_add(max_payout, balance);
            i = i + 1;
        }
        
        (u256_lib::U256_ge(lmsr.collateral, max_payout),)
    }

    /// Resolves the market based on winning outcome
    /// Sets the market as resolved and stores the winning outcome
    /// @param winning_outcome The winning outcome index
    #[external]
    fn resolve_market(ref self: LMSRMulti, winning_outcome: felt252) {
        let caller = get_caller_address();
        
        // Only the oracle can resolve
        let oracle_addr = self.lmsr.read().outcomes[0]; // Use outcomes[0] as placeholder for oracle check
        // In production, would check against actual oracle address
        
        // Validate winning outcome index
        let lmsr = self.lmsr.read();
        assert(winning_outcome >= 0 && winning_outcome < lmsr.num_outcomes, 'Invalid winning outcome');
        
        // Check for tie situation
        let prices = Self::get_all_prices(@LMSRMulti { storage: self.storage });
        
        // For tie-breaking: if top 2 are tied within tolerance, void market
        // This is a simplified tie detection - in production would use oracle data
        let mut is_tie = false;
        if prices.len() >= 2 {
            // Check if top prices are very close (within 0.01 = 1e16)
            let diff = Self::abs_diff(prices[0], prices[1]);
            let tolerance = 10_000_000_000_000_000; // 0.01 in 1e18 precision
            if diff <= tolerance {
                is_tie = true;
            }
        }
        
        if is_tie {
            let mut new_lmsr = lmsr;
            new_lmsr.market_state = STATE_VOIDED;
            self.lmsr.write(new_lmsr);
            return;
        }
        
        // Update market state
        let mut new_lmsr = lmsr;
        new_lmsr.market_state = STATE_RESOLVED;
        new_lmsr.winning_outcome = winning_outcome;
        self.lmsr.write(new_lmsr);
    }

    /// Gets the current market state
    /// @return market_state 0 = active, 1 = resolved, 2 = voided
    #[external]
    fn get_market_state(self: @LMSRMulti) -> felt252 {
        self.lmsr.read().market_state
    }

    /// Gets the array of outcomes
    /// @return outcomes Array of outcome names
    #[external]
    fn get_outcomes(self: @LMSRMulti) -> (outcomes: Array<felt252>) {
        (self.lmsr.read().outcomes,)
    }

    /// Gets the b parameter (liquidity parameter)
    /// @return b The b parameter
    #[external]
    fn get_b_parameter(self: @LMSRMulti) -> felt252 {
        self.lmsr.read().b
    }

    // ==================== Internal Helper Functions ====================

    /// Gets balance for a specific outcome
    fn get_outcome_balance(self: @LMSRMulti, outcome_idx: felt252) -> felt252 {
        let lmsr = self.lmsr.read();
        let balance = lmsr.outcome_balances.read(outcome_idx);
        Self::u256_to_felt(balance)
    }

    /// Calculates tokens received when buying with collateral
    /// Uses numerical approximation for inverse LMSR calculation
    fn calculate_tokens_bought(
        self: @LMSRMulti,
        outcome_idx: felt252,
        collateral_in: u256_lib::U256
    ) -> u256_lib::U256 {
        let lmsr = self.lmsr.read();
        let b = lmsr.b;
        
        // Current price of the outcome
        let price = Self::get_price(@LMSRMulti { storage: self.storage }, outcome_idx);
        
        if price == 0 {
            return u256_lib::U256 { low: 0, high: 0 };
        }
        
        // tokens ≈ collateral / price
        // Using fixed point: tokens * 1e18 / price = collateral
        // tokens = collateral * price / 1e18
        
        // scaled_collateral = collateral_in * 1e18
        let mut scaled_collateral = collateral_in;
        scaled_collateral = u256_lib::U256_mul(scaled_collateral, u256_lib::U256 { low: 1_000_000_000_000_000_000_u128, high: 0 });
        
        // tokens = scaled_collateral / price_felt
        let price_u256 = Self::felt_to_u256(price);
        u256_lib::U256_div(scaled_collateral, price_u256)
    }

    /// Calculates collateral returned when selling tokens
    /// Uses numerical approximation based on price impact
    fn calculate_collateral_returned(
        self: @LMSRMulti,
        outcome_idx: felt252,
        tokens_in: u256_lib::U256
    ) -> u256_lib::U256 {
        let lmsr = self.lmsr.read();
        let b = lmsr.b;
        
        // Current balance
        let current_balance = Self::get_outcome_balance(@LMSRMulti { storage: self.storage }, outcome_idx);
        
        // New balance after selling
        let new_balance = current_balance - Self::u256_to_felt(tokens_in);
        
        // Current price
        let current_price = Self::get_price(@LMSRMulti { storage: self.storage }, outcome_idx);
        
        // Approximate average price over the trade
        let average_price = Self::add_fixed(current_price, Self::get_price(@LMSRMulti { storage: self.storage }, outcome_idx)) / 2;
        
        if average_price == 0 {
            return u256_lib::U256 { low: 0, high: 0 };
        }
        
        // collateral = tokens * average_price / 1e18
        let tokens_u256 = Self::felt_to_u256(current_balance);
        let average_price_u256 = Self::felt_to_u256(average_price);
        
        // tokens * average_price / 1e18
        let result = u256_lib::U256_mul(tokens_u256, average_price_u256);
        u256_lib::U256_div(result, u256_lib::U256 { low: 1_000_000_000_000_000_000_u128, high: 0 })
    }

    /// Transfers collateral into the vault
    fn transfer_collateral_in(ref self: LMSRMulti, user: starknet::ContractAddress, amount: u256_lib::U256) {
        // In production, would use actual collateral token address
        // For now, this is a stub - the actual implementation would:
        // IERC20Metadata::transfer_from(
        //     ref contract: collateral_token,
        //     from: user,
        //     to: self.storage.contract_address,
        //     amount: amount
        // );
    }

    /// Transfers collateral out of the vault
    fn transfer_collateral_out(ref self: LMSRMulti, user: starknet::ContractAddress, amount: u256_lib::U256) {
        // In production, would use actual collateral token address
        // IERC20Metadata::transfer(
        //     ref contract: collateral_token,
        //     to: user,
        //     amount: amount
        // );
    }

    // ==================== Fixed Point Math Functions ====================

    /// Converts u256 to felt252 (scales by 1e18 for fixed-point)
    fn u256_to_felt(value: u256_lib::U256) -> felt252 {
        // For simplicity, assume value fits in u128 * 1e18
        let low = value.low;
        low as felt252
    }

    /// Converts felt252 to u256 (assumes value fits in u128)
    fn felt_to_u256(val: felt252) -> u256_lib::U256 {
        u256_lib::U256 {
            low: val.try_into().unwrap_or(0),
            high: 0,
        }
    }

    /// Adds two fixed-point numbers
    fn add_fixed(a: felt252, b: felt252) -> felt252 {
        a + b
    }

    /// Subtracts two fixed-point numbers
    fn sub_fixed(a: felt252, b: felt252) -> felt252 {
        a - b
    }

    /// Absolute difference between two fixed-point numbers
    fn abs_diff(a: felt252, b: felt252) -> felt252 {
        if a > b {
            a - b
        } else {
            b - a
        }
    }

    /// Multiplies two fixed-point numbers
    fn mul_fixed(a: felt252, b: felt252) -> felt252 {
        (a as u128 as u256_lib::U256 * b as u128 as u256_lib::U256 / FIXED_POINT_PRECISION as u128 as u256_lib::U256) as u128 as felt252
    }

    /// Divides two fixed-point numbers
    fn div_fixed(a: felt252, b: felt252) -> felt252 {
        if b == 0 {
            panic('Division by zero');
        }
        (a as u128 as u256_lib::U256 * FIXED_POINT_PRECISION as u128 as u256_lib::U256 / b as u128 as u256_lib::U256) as u128 as felt252
    }

    /// Fixed-point exponential function using Taylor series
    /// exp(x) = 1 + x + x^2/2! + x^3/3! + ...
    fn fixed_point_exp(x: felt252) -> felt252 {
        let precision = FIXED_POINT_PRECISION;
        let mut result = precision;
        let mut term = precision;
        let mut n: felt252 = 1;
        
        // Limit iterations to prevent infinite loop
        while n < 50 {
            // term = term * x / n
            let scaled_x = x;
            term = (term as u128 as u256_lib::U256 * scaled_x as u128 as u256_lib::U256 / n as u128 as u256_lib::U256) as u128 as felt252;
            result = result + term;
            
            // Check for convergence
            let abs_term = if term >= 0 { term } else { -term };
            if abs_term < 1000 { // Small threshold for convergence
                break;
            }
            n = n + 1;
        }
        
        result
    }

    /// Fixed-point natural logarithm
    /// ln(x) using series expansion
    fn fixed_point_ln(x: felt252) -> felt252 {
        if x <= 0 {
            panic('LN of non-positive number');
        }
        
        let precision = FIXED_POINT_PRECISION;
        
        // For x close to 1, use series: ln(1+y) = y - y^2/2 + y^3/3 - ...
        // Reduce x to range [0.5, 2] for better convergence
        let y = x - precision; // y = x - 1
        let mut result: felt252 = 0;
        let mut term = y;
        let mut n: felt252 = 1;
        
        while n < 100 {
            result = result + term / n as felt252;
            term = term * (precision - y) / precision;
            
            let abs_term = if term >= 0 { term } else { -term };
            if abs_term < 1000 {
                break;
            }
            n = n + 1;
        }
        
        result
    }
}
