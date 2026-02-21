// LMSR Market Maker Contract for Cairox
// Implements Logarithmic Market Scoring Rule (LMSR) for binary prediction markets
// Allows users to trade YES/NO shares against an automated market maker

use starknet::ContractAddress;
use starknet::SyscallResult;
use starknet::{get_caller_address, StorageAddress};
use starknet::cast::cast_felt;
use openzeppelin::token::erc20::interfaces::IERC20Metadata;
use openzeppelin::math::u256 as u256_lib;
use openzeppelin::utils::Revertable;
use openzeppelin::math::felt252_arith::Felt252ArithTrait;
use super::market_factory::MarketFactory;
use super::collateral_vault::CollateralVault;
use super::outcome_token::OutcomeToken;
use super::oracle::OptimisticOracle;

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

// LMSR Market Maker constants
// Address constants for integration points
const MARKET_FACTORY_ADDRESS: felt252 = 0x1;
const COLLATERAL_VAULT_ADDRESS: felt252 = 0x2;
const OUTCOME_TOKEN_YES_ADDRESS: felt252 = 0x3;
const OUTCOME_TOKEN_NO_ADDRESS: felt252 = 0x4;
const ORACLE_ADDRESS: felt252 = 0x5;

// Resolution outcome constants
const OUTCOME_YES: felt252 = 0;
const OUTCOME_NO: felt252 = 1;

// Market state constants
const STATE_ACTIVE: felt252 = 0;
const STATE_RESOLVED: felt252 = 1;

#[starknet::interface]
pub trait ILMSRMarketMaker {
    fn initialize(ref self: LMSRMarketMaker, collateral_token: starknet::ContractAddress, oracle_address: starknet::ContractAddress, b: felt252);
    fn buy_yes(ref self: LMSRMarketMaker, amount_collateral: u256_lib::U256, min_tokens_out: u256_lib::U256, sender: starknet::ContractAddress) -> (tokens_out: u256_lib::U256);
    fn sell_yes(ref self: LMSRMarketMaker, amount_tokens: u256_lib::U256, min_collateral_out: u256_lib::U256, sender: starknet::ContractAddress) -> (collateral_out: u256_lib::U256);
    fn buy_no(ref self: LMSRMarketMaker, amount_collateral: u256_lib::U256, min_tokens_out: u256_lib::U256, sender: starknet::ContractAddress) -> (tokens_out: u256_lib::U256);
    fn sell_no(ref self: LMSRMarketMaker, amount_tokens: u256_lib::U256, min_collateral_out: u256_lib::U256, sender: starknet::ContractAddress) -> (collateral_out: u256_lib::U256);
    fn get_yes_price(self: @LMSRMarketMaker) -> (price: felt252);
    fn get_no_price(self: @LMSRMarketMaker) -> (price: felt252);
    fn check_solvency(self: @LMSRMarketMaker) -> (is_solvent: bool);
    fn resolve_market(ref self: LMSRMarketMaker, outcome: felt252);
    fn get_market_state(self: @LMSRMarketMaker) -> felt252;
    fn get_b_parameter(self: @LMSRMarketMaker) -> felt252;
}

// Helper structs
#[derive(Drop, CairoShape)]
struct LMSRStorage {
    /// Collateral token contract address
    collateral_token: starknet::ContractAddress,
    /// Oracle contract address
    oracle_address: starknet::ContractAddress,
    /// Liquidity parameter b (controls spread)
    b: felt252,
    /// Market state: 0 = active, 1 = resolved
    market_state: felt252,
    /// Total quantities of YES and NO tokens in circulation (for LMSR calculations)
    /// These represent q_yes and q_no in the LMSR formula
    total_quantity_yes: u256_lib::U256,
    total_quantity_no: u256_lib::U256,
    /// Total collateral held in vault (for solvency checking)
    vault_collateral: u256_lib::U256,
    /// Market ID for this market maker
    market_id: felt252,
}

#[starknet::contract]
mod LMSRMarketMaker {
    use super::{test, ILMSRMarketMaker, LMSRStorage, STATE_ACTIVE, STATE_RESOLVED};
    use starknet::SyscallResult;
    use starknet::{get_caller_address, StorageAddress};
    use starknet::cast::cast_felt;
    use openzeppelin::token::erc20::interfaces::IERC20Metadata;
    use openzeppelin::math::u256 as u256_lib;
    use openzeppelin::math::felt252_arith::Felt252ArithTrait;
    use openzeppelin::utils::Revertable;

    #[storage]
    struct Storage {
        /// LMSR internal state
        lmsr: LMSRStorage,
    }

    /// Fixed point precision (1e18)
    const FIXED_POINT_PRECISION: felt252 = 1_000_000_000_000_000_000;

    /// Initializes the LMSR market maker
    /// @param collateral_token The address of USDC collateral token
    /// @param oracle_address The address of the OptimisticOracle for resolution
    /// @param b The liquidity parameter (controls spread, higher = more liquid)
    #[external]
    #[init]
    fn initialize(ref self: LMSRMarketMaker, collateral_token: starknet::ContractAddress, oracle_address: starknet::ContractAddress, b: felt252) {
        let caller = get_caller_address();
        
        // Only allow initialization by the market factory
        let market_factory_felt = cast_felt(MARKET_FACTORY_ADDRESS);
        assert(caller.value == market_factory_felt, 'Unauthorized: only market factory can initialize');
        
        // Initialize LMSR storage
        self.lmsr.write(LMSRStorage {
            collateral_token: collateral_token,
            oracle_address: oracle_address,
            b: b,
            market_state: STATE_ACTIVE,
            total_quantity_yes: u256_lib::U256 { low: 0, high: 0 },
            total_quantity_no: u256_lib::U256 { low: 0, high: 0 },
            vault_collateral: u256_lib::U256 { low: 0, high: 0 },
            market_id: 0, // Will be set by market factory
        });
    }

    /// Buys YES tokens by contributing collateral
    /// @param amount_collateral Amount of collateral to spend
    /// @param min_tokens_out Minimum YES tokens to receive
    /// @param sender Buyer address
    /// @return tokens_out Number of YES tokens received
    #[external]
    fn buy_yes(ref self: LMSRMarketMaker, amount_collateral: u256_lib::U256, min_tokens_out: u256_lib::U256, sender: starknet::ContractAddress) -> (tokens_out: u256_lib::U256) {
        let caller = get_caller_address();
        
        // Market must be active
        let state = self.lmsr.market_state.read();
        assert(state == STATE_ACTIVE, 'Market is resolved');
        
        // Check solvency before trade (market maker must be able to pay)
        let solvent = Self::check_solvency(@LMSRMarketMaker { storage: self.storage });
        assert(solvent, 'Market would become insolvent');
        
        // Calculate tokens to mint
        let tokens_out = Self::calculate_tokens_bought(
            @LMSRMarketMaker { storage: self.storage },
            amount_collateral,
            true // buying YES
        );
        
        // Enforce minimum output
        assert(u256_lib::U256_ge(tokens_out, min_tokens_out), 'Slippage exceeded');
        
        // Transfer collateral from sender to vault
        Self::transfer_collateral_in(ref self, caller, amount_collateral);
        
        // Mint YES tokens to sender
        Self::mint_yes_tokens(ref self, sender, tokens_out);
        
        // Update internal state
        let mut lmsr: LMSRStorage = self.lmsr.read();
        lmsr.total_quantity_yes = u256_lib::U256_add(lmsr.total_quantity_yes, tokens_out);
        lmsr.vault_collateral = u256_lib::U256_add(lmsr.vault_collateral, amount_collateral);
        self.lmsr.write(updated_lmsr);
        
        // Check solvency after trade
        let solvent_after = Self::check_solvency(@LMSRMarketMaker { storage: self.storage });
        assert(solvent_after, 'Market is insolvent after trade');
        
        (tokens_out,)
    }

    /// Sells YES tokens for collateral
    /// @param amount_tokens Amount of YES tokens to sell
    /// @param min_collateral_out Minimum collateral to receive
    /// @param sender Seller address
    /// @return collateral_out Amount of collateral received
    #[external]
    fn sell_yes(ref self: LMSRMarketMaker, amount_tokens: u256_lib::U256, min_collateral_out: u256_lib::U256, sender: starknet::ContractAddress) -> (collateral_out: u256_lib::U256) {
        let caller = get_caller_address();
        
        // Market must be active
        let state = self.lmsr.market_state.read();
        assert(state == STATE_ACTIVE, 'Market is resolved');
        
        // Burn YES tokens from sender
        Self::burn_yes_tokens(ref self, sender, amount_tokens);
        
        // Calculate collateral to return
        let collateral_out = Self::calculate_collateral_returned(
            @LMSRMarketMaker { storage: self.storage },
            amount_tokens,
            true // selling YES
        );
        
        // Enforce minimum output
        assert(u256_lib::U256_ge(collateral_out, min_collateral_out), 'Slippage exceeded');
        
        // Transfer collateral to sender from vault
        Self::transfer_collateral_out(ref self, caller, collateral_out);
        
        // Update internal state
        let mut lmsr: LMSRStorage = self.lmsr.read();
        lmsr.total_quantity_yes = u256_lib::U256_sub(lmsr.total_quantity_yes, amount_tokens).unwrap();
        lmsr.vault_collateral = u256_lib::U256_sub(lmsr.vault_collateral, collateral_out).unwrap();
        self.lmsr.write(updated_lmsr);
        
        // Check solvency after trade
        let solvent = Self::check_solvency(@LMSRMarketMaker { storage: self.storage });
        assert(solvent, 'Market is insolvent after trade');
        
        (collateral_out,)
    }

    /// Buys NO tokens by contributing collateral
    /// @param amount_collateral Amount of collateral to spend
    /// @param min_tokens_out Minimum NO tokens to receive
    /// @param sender Buyer address
    /// @return tokens_out Number of NO tokens received
    #[external]
    fn buy_no(ref self: LMSRMarketMaker, amount_collateral: u256_lib::U256, min_tokens_out: u256_lib::U256, sender: starknet::ContractAddress) -> (tokens_out: u256_lib::U256) {
        let caller = get_caller_address();
        
        // Market must be active
        let state = self.lmsr.market_state.read();
        assert(state == STATE_ACTIVE, 'Market is resolved');
        
        // Check solvency before trade
        let solvent = Self::check_solvency(@LMSRMarketMaker { storage: self.storage });
        assert(solvent, 'Market would become insolvent');
        
        // Calculate tokens to mint
        let tokens_out = Self::calculate_tokens_bought(
            @LMSRMarketMaker { storage: self.storage },
            amount_collateral,
            false // buying NO
        );
        
        // Enforce minimum output
        assert(u256_lib::U256_ge(tokens_out, min_tokens_out), 'Slippage exceeded');
        
        // Transfer collateral from sender to vault
        Self::transfer_collateral_in(ref self, caller, amount_collateral);
        
        // Mint NO tokens to sender
        Self::mint_no_tokens(ref self, sender, tokens_out);
        
        // Update internal state
        let mut lmsr: LMSRStorage = self.lmsr.read();
        lmsr.total_quantity_no = u256_lib::U256_add(lmsr.total_quantity_no, tokens_out);
        lmsr.vault_collateral = u256_lib::U256_add(lmsr.vault_collateral, amount_collateral);
        self.lmsr.write(updated_lmsr);
        
        // Check solvency after trade
        let solvent_after = Self::check_solvency(@LMSRMarketMaker { storage: self.storage });
        assert(solvent_after, 'Market is insolvent after trade');
        
        (tokens_out,)
    }

    /// Sells NO tokens for collateral
    /// @param amount_tokens Amount of NO tokens to sell
    /// @param min_collateral_out Minimum collateral to receive
    /// @param sender Seller address
    /// @return collateral_out Amount of collateral received
    #[external]
    fn sell_no(ref self: LMSRMarketMaker, amount_tokens: u256_lib::U256, min_collateral_out: u256_lib::U256, sender: starknet::ContractAddress) -> (collateral_out: u256_lib::U256) {
        let caller = get_caller_address();
        
        // Market must be active
        let state = self.lmsr.market_state.read();
        assert(state == STATE_ACTIVE, 'Market is resolved');
        
        // Burn NO tokens from sender
        Self::burn_no_tokens(ref self, sender, amount_tokens);
        
        // Calculate collateral to return
        let collateral_out = Self::calculate_collateral_returned(
            @LMSRMarketMaker { storage: self.storage },
            amount_tokens,
            false // selling NO
        );
        
        // Enforce minimum output
        assert(u256_lib::U256_ge(collateral_out, min_collateral_out), 'Slippage exceeded');
        
        // Transfer collateral to sender from vault
        Self::transfer_collateral_out(ref self, caller, collateral_out);
        
        // Update internal state
        let mut lmsr: LMSRStorage = self.lmsr.read();
        lmsr.total_quantity_no = u256_lib::U256_sub(lmsr.total_quantity_no, amount_tokens).unwrap();
        lmsr.vault_collateral = u256_lib::U256_sub(lmsr.vault_collateral, collateral_out).unwrap();
        self.lmsr.write(updated_lmsr);
        
        // Check solvency after trade
        let solvent = Self::check_solvency(@LMSRMarketMaker { storage: self.storage });
        assert(solvent, 'Market is insolvent after trade');
        
        (collateral_out,)
    }

    /// Gets current price of YES token
    /// @return price Price as fixed-point number (scaled by 1e18)
    #[external]
    fn get_yes_price(self: @LMSRMarketMaker) -> (price: felt252) {
        let lmsr: LMSRStorage = self.lmsr.read();
        
        // Price formula: p_yes = e^(q_yes/b) / (e^(q_yes/b) + e^(q_no/b))
        let b = lmsr.b;
        let q_yes = Self::u256_to_felt(lmsr.total_quantity_yes);
        let q_no = Self::u256_to_felt(lmsr.total_quantity_no);
        
        // Calculate e^(q_yes/b) and e^(q_no/b)
        let exp_q_yes = Self::fixed_point_exp(Self::div_fixed(q_yes, b));
        let exp_q_no = Self::fixed_point_exp(Self::div_fixed(q_no, b));
        
        // Calculate price
        let denominator = Self::add_fixed(exp_q_yes, exp_q_no);
        Self::div_fixed(exp_q_yes, denominator)
    }

    /// Gets current price of NO token
    /// @return price Price as fixed-point number (scaled by 1e18)
    #[external]
    fn get_no_price(self: @LMSRMarketMaker) -> (price: felt252) {
        // p_no = 1 - p_yes
        let yes_price = Self::get_yes_price(@LMSRMarketMaker { storage: self.storage });
        Self::sub_fixed(FIXED_POINT_PRECISION, yes_price)
    }

    /// Checks if the market maker is solvent
    /// Solvent if: vault_collateral >= max_payout
    /// max_payout = total_quantity_yes + total_quantity_no (in worst case, both pay 1)
    /// @return is_solvent True if solvent
    #[external]
    fn check_solvency(self: @LMSRMarketMaker) -> (is_solvent: bool) {
        let lmsr: LMSRStorage = self.lmsr.read();
        
        // Maximum possible payout is the total tokens outstanding
        // Since each token pays 1 unit of collateral if correct
        let max_payout = u256_lib::U256_add(lmsr.total_quantity_yes, lmsr.total_quantity_no);
        
        (u256_lib::U256_ge(lmsr.vault_collateral, max_payout),)
    }

    /// Resolves the market based on oracle outcome
    /// @param outcome The winning outcome (OUTCOME_YES or OUTCOME_NO)
    #[external]
    fn resolve_market(ref self: LMSRMarketMaker, outcome: felt252) {
        let caller = get_caller_address();
        
        // Only the oracle can resolve
        let lmsr_state: LMSRStorage = self.lmsr.read();
        let oracle_addr = lmsr_state.oracle_address;
        assert(caller.value == oracle_addr.value, 'Unauthorized: only oracle can resolve');
        
        // Check oracle status
        // Oracle check simplified - TODO: fix Oracle integration
        // let status = ...
        // assert(status == 2, ...); // RESOLVED
        
        // Update market state
        let mut lmsr: LMSRStorage = self.lmsr.read();
        let updated_lmsr = LMSRStorage { market_state: STATE_RESOLVED, ..lmsr };
        self.lmsr.write(updated_lmsr);
        
        // Note: Token redemption is handled by separate function or user action
    }

    /// Gets the current market state
    /// @return market_state 0 = active, 1 = resolved
    #[external]
    fn get_market_state(self: @LMSRMarketMaker) -> felt252 {
        self.lmsr.market_state.read()
    }

    /// Gets the b parameter (liquidity parameter)
    /// @return b The b parameter
    #[external]
    fn get_b_parameter(self: @LMSRMarketMaker) -> felt252 {
        self.lmsr.b.read()
    }

    // ==================== Internal Helper Functions ====================

    /// Calculates tokens received when buying with collateral
    /// Uses LMSR cost function: C(q) = b * ln(e^(q_yes/b) + e^(q_no/b))
    /// Delta C for buying tokens = C(new_q) - C(old_q)
    fn calculate_tokens_bought(
        self: @LMSRMarketMaker,
        amount_collateral: u256_lib::U256,
        buying_yes: bool
    ) -> u256_lib::U256 {
        let lmsr: LMSRStorage = self.lmsr.read();
        let b = lmsr.b;
        let q_yes = Self::u256_to_felt(lmsr.total_quantity_yes);
        let q_no = Self::u256_to_felt(lmsr.total_quantity_no);
        
        // Current cost
        let current_cost = Self::calculate_cost(q_yes, q_no, b);
        
        // New cost after adding collateral
        let collateral_felt = Self::u256_to_felt(amount_collateral);
        let new_cost = Self::add_fixed(current_cost, collateral_felt);
        
        // Solve for new quantity using inverse cost function
        // This is complex - for simplicity, use numerical approximation
        // In production, implement proper inverse LMSR calculation
        
        // For now, use a simplified approach: approximate tokens = collateral / price
        let price = if buying_yes {
            Self::get_yes_price(@LMSRMarketMaker { storage: self.storage })
        } else {
            Self::get_no_price(@LMSRMarketMaker { storage: self.storage })
        };
        
        // tokens ≈ collateral / price
        // tokens * price ≈ collateral
        // Using fixed point: tokens * 1e18 / price = collateral
        // tokens = collateral * price / 1e18
        
        if price == 0 {
            return u256_lib::U256 { low: 0, high: 0 };
        }
        
        // scaled_collateral = amount_collateral * 1e18
        let mut scaled_collateral = amount_collateral;
        scaled_collateral = u256_lib::U256_mul(scaled_collateral, u256_lib::U256 { low: 1_000_000_000_000_000_000_u128, high: 0 });
        
        // tokens = scaled_collateral / price_felt
        // price_felt is already scaled by 1e18
        let price_u256 = Self::felt_to_u256(price);
        u256_lib::U256_div(scaled_collateral, price_u256)
    }

    /// Calculates collateral returned when selling tokens
    fn calculate_collateral_returned(
        self: @LMSRMarketMaker,
        amount_tokens: u256_lib::U256,
        selling_yes: bool
    ) -> u256_lib::U256 {
        let lmsr: LMSRStorage = self.lmsr.read();
        let b = lmsr.b;
        let q_yes = Self::u256_to_felt(lmsr.total_quantity_yes);
        let q_no = Self::u256_to_felt(lmsr.total_quantity_no);
        
        // Calculate new quantities after selling
        let new_q_yes = if selling_yes {
            u256_lib::U256_sub(lmsr.total_quantity_yes, amount_tokens).unwrap()
        } else {
            lmsr.total_quantity_yes
        };
        let new_q_no = if !selling_yes {
            u256_lib::U256_sub(lmsr.total_quantity_no, amount_tokens).unwrap()
        } else {
            lmsr.total_quantity_no
        };
        
        let new_q_yes_felt = Self::u256_to_felt(new_q_yes);
        let new_q_no_felt = Self::u256_to_felt(new_q_no);
        
        // Old cost and new cost
        let old_cost = Self::calculate_cost(q_yes, q_no, b);
        let new_cost = Self::calculate_cost(new_q_yes_felt, new_q_no_felt, b);
        
        // Collateral returned = old_cost - new_cost
        Self::sub_fixed(old_cost, new_cost)
    }

    /// Calculates LMSR cost function C(q) = b * ln(e^(q_yes/b) + e^(q_no/b))
    fn calculate_cost(q_yes: felt252, q_no: felt252, b: felt252) -> felt252 {
        if b == 0 {
            return 0;
        }
        
        // e^(q_yes/b) and e^(q_no/b)
        let exp_q_yes = Self::fixed_point_exp(Self::div_fixed(q_yes, b));
        let exp_q_no = Self::fixed_point_exp(Self::div_fixed(q_no, b));
        
        // ln(e^(q_yes/b) + e^(q_no/b))
        let sum_exp = Self::add_fixed(exp_q_yes, exp_q_no);
        let ln_sum = Self::fixed_point_ln(sum_exp);
        
        // b * ln(...)
        Self::mul_fixed(b, ln_sum)
    }

    /// Transfers collateral into the vault
    fn transfer_collateral_in(ref self: LMSRMarketMaker, user: starknet::ContractAddress, amount: u256_lib::U256) {
        let lmsr_state: LMSRStorage = self.lmsr.read();
        let collateral_token = lmsr_state.collateral_token;
        IERC20Metadata::transfer_from(
            ref contract: collateral_token,
            from: user,
            to: self.storage.contract_address,
            amount: amount
        );
    }

    /// Transfers collateral out of the vault
    fn transfer_collateral_out(ref self: LMSRMarketMaker, user: starknet::ContractAddress, amount: u256_lib::U256) {
        let lmsr_state: LMSRStorage = self.lmsr.read();
        let collateral_token = lmsr_state.collateral_token;
        IERC20Metadata::transfer(
            ref contract: collateral_token,
            to: user,
            amount: amount
        );
    }

    /// Mints YES tokens
    fn mint_yes_tokens(ref self: LMSRMarketMaker, to: starknet::ContractAddress, amount: u256_lib::U256) {
        // In production, this would mint to the actual YES token contract
        // For now, we simulate by updating a balance
        // Actual implementation would store YES token address
    }

    /// Burns YES tokens
    fn burn_yes_tokens(ref self: LMSRMarketMaker, from: starknet::ContractAddress, amount: u256_lib::U256) {
        // In production, this would burn from the actual YES token contract
        // For now, we simulate by updating a balance
    }

    /// Mints NO tokens
    fn mint_no_tokens(ref self: LMSRMarketMaker, to: starknet::ContractAddress, amount: u256_lib::U256) {
        // In production, this would mint to the actual NO token contract
    }

    /// Burns NO tokens
    fn burn_no_tokens(ref self: LMSRMarketMaker, from: starknet::ContractAddress, amount: u256_lib::U256) {
        // In production, this would burn from the actual NO token contract
    }

    // ==================== Fixed Point Math Functions ====================

    /// Converts u256 to felt252 (scales by 1e18 for fixed-point)
    fn u256_to_felt(value: u256_lib::U256) -> felt252 {
        // For simplicity, assume value fits in u128 * 1e18
        let low = value.low;
        // This is a simplified conversion
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
        let mut n = 1;
        
        // Limit iterations to prevent infinite loop
        while n < 50 {
            // term = term * x / n
            let scaled_x = x;
            term = (term as u128 as u256_lib::U256 * scaled_x as u128 as u256_lib::U256 / n as u128 as u256_lib::U256) as u128 as felt252;
            result = result + term;
            
            // Check for convergence
            if term.abs() < 1000 { // Small threshold for convergence
                break;
            }
            n += 1;
        }
        
        result
    }

    /// Fixed-point natural logarithm
    /// ln(x) using Newton's method or series expansion
    fn fixed_point_ln(x: felt252) -> felt252 {
        if x <= 0 {
            panic('LN of non-positive number');
        }
        
        let precision = FIXED_POINT_PRECISION;
        
        // For x close to 1, use series: ln(1+y) = y - y^2/2 + y^3/3 - ...
        // Reduce x to range [0.5, 2] for better convergence
        let mut y = x - precision; // y = x - 1
        let mut result = 0;
        let mut term = y;
        let mut n = 1;
        
        while n < 100 {
            result = result + term / n as felt252;
            term = term * (precision - y) / precision;
            
            if term.abs() < 1000 {
                break;
            }
            n += 1;
        }
        
        result
    }
}
