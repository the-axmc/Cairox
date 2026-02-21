// Market Contract for Cairox
// Represents a prediction market with YES/NO outcomes
// Users can mint complete sets (YES + NO tokens) and redeem winning tokens

use starknet::ContractAddress;
use starknet::SyscallResult;
use starknet::{get_caller_address, StorageAddress};
use starknet::cast::cast_felt;
use openzeppelin::math::u256 as u256_lib;
use openzeppelin::utils::Revertable;
use openzeppelin::introspection::IERC165;
use openzeppelin::access::access_control::AccessControlEntityTrait;
use openzeppelin::token::erc20::interfaces::IERC20Metadata;

#[cfg(test)]
mod test {
    use starknet::ContractAddress;
    use starknet::cast::cast_felt;
    use openzeppelin::math::u256 as u256_lib;

    // Helper function to create a u256 value
    pub fn u256_value(amount: u128) -> u256_lib::U256 {
        u256_lib::U256 {
            low: amount,
            high: 0,
        }
    }

    // Market owner address
    pub fn market_owner_address() -> ContractAddress {
        ContractAddress::from(0x123456789012345678901234567890123456789012345678901234567890123_u128)
    }
}

// Storage addresses
const VAULT_ADDRESS: felt252 = 0x1;
const FACTORY_ADDRESS: felt252 = 0x2;

/// Market status constants
const PENDING: felt252 = 0;
const ACTIVE: felt252 = 1;
const RESOLVED: felt252 = 2;
const VOIDED: felt252 = 3;

#[derive(Drop, CairoShape)]
struct Market {
    collateral_token: starknet::ContractAddress,
    outcome_tokens: Map<felt252, ContractAddress>,
    total_collateral: u256_lib::U256,
    resolved: bool,
    winning_outcome: felt252,
    voided: bool,
    status: felt252,
}

#[starknet::interface]
pub trait IMarket {
    fn initialize(
        ref self: Market,
        collateral_token: starknet::ContractAddress,
        outcomes: Array<felt252>
    );
    fn mint_complete_set(ref self: Market, recipient: starknet::ContractAddress, amount: u256_lib::U256);
    fn redeem_winning(ref self: Market, outcome: felt252);
    fn redeem_void(ref self: Market);
    fn get_outcome_token(self: @Market, outcome: felt252) -> ContractAddress;
    fn get_total_collateral(self: @Market) -> u256_lib::U256;
    fn is_resolved(self: @Market) -> bool;
    fn is_voided(self: @Market) -> bool;
    fn get_outcomes(self: @Market) -> Array<felt252>;
}

#[starknet::contract]
mod Market {
    use super::{test, IMarket};
    use starknet::SyscallResult;
    use starknet::{get_caller_address, StorageAddress};
    use starknet::cast::cast_felt;
    use openzeppelin::math::u256 as u256_lib;
    use openzeppelin::utils::Revertable;
    use openzeppelin::introspection::IERC165;
    use openzeppelin::access::access_control::AccessControlEntityTrait;
    use openzeppelin::token::erc20::interfaces::IERC20Metadata;

    #[storage]
    struct Storage {
        /// Collateral token contract address
        collateral_token: starknet::ContractAddress,
        /// Mapping of outcome -> outcome token address
        outcome_tokens: Map<felt252, ContractAddress>,
        /// Total collateral deposited
        total_collateral: u256_lib::U256,
        /// Whether the market is resolved
        resolved: bool,
        /// The winning outcome (if resolved)
        winning_outcome: felt252,
        /// Whether the market is voided
        voided: bool,
        /// Market status
        status: felt252,
        /// List of outcomes
        outcomes: Array<felt252>,
    }

    /// Initializes the market
    /// @param collateral_token The address of the collateral token
    /// @param outcomes Array of outcome names (e.g., ["YES", "NO"])
    #[external]
    #[init]
    fn initialize(ref self: Market, collateral_token: starknet::ContractAddress, outcomes: Array<felt252>) {
        let caller = get_caller_address();
        
        // Only the market factory can initialize
        let factory_felt = cast_felt(FACTORY_ADDRESS);
        assert(caller.value == factory_felt, 'Unauthorized: only factory can initialize');
        
        self.collateral_token.write(collateral_token);
        self.total_collateral.write(u256_lib::U256 { low: 0, high: 0 });
        self.resolved.write(false);
        self.voided.write(false);
        self.status.write(PENDING);
        
        // Store outcomes
        for outcome in outcomes {
            self.outcomes.append(outcome);
            // Outcome tokens will be deployed separately and set via set_outcome_token
        }
    }

    /// Mints a complete set (equal amounts of YES and NO tokens)
    /// User deposits collateral and receives equal amounts of each outcome token
    /// @param recipient The address to receive the tokens
    /// @param amount The amount of collateral to deposit (and tokens to receive)
    #[external]
    fn mint_complete_set(ref self: Market, recipient: starknet::ContractAddress, amount: u256_lib::U256) {
        let caller = get_caller_address();
        
        // Must have at least one outcome token deployed
        let outcomes = self.outcomes.read();
        assert(outcomes.len() > 0, 'No outcome tokens deployed');
        
        // Deposit collateral into vault
        Self::deposit_collateral(ref self, caller, amount);
        
        // Mint outcome tokens for each outcome
        for outcome in outcomes {
            let token = self.outcome_tokens.read(outcome);
            IERC20Metadata::mint(
                ref contract: token,
                account: recipient,
                amount: amount
            );
        }
    }

    /// Redeems winning outcome tokens for collateral
    /// After resolution, holders of winning tokens can burn them to get collateral back
    /// @param outcome The winning outcome to redeem
    #[external]
    fn redeem_winning(ref self: Market, outcome: felt252) {
        let caller = get_caller_address();
        
        // Market must be resolved
        let is_resolved = self.resolved.read();
        assert(is_resolved, 'Market is not resolved');
        
        // Get outcome token address
        let token = self.outcome_tokens.read(outcome);
        
        // Get the amount of tokens the caller has
        let token_balance = IERC20Metadata::balance_of(
            ref contract: token,
            account: caller
        );
        
        // Burn all caller's tokens
        IERC20Metadata::burn(
            ref contract: token,
            account: caller,
            amount: token_balance
        );
        
        // Return collateral to caller
        Self::withdraw_collateral(ref self, caller, token_balance);
        
        // Mark market as fully redeemed if no more tokens outstanding
        if self.total_collateral.read().low == 0 && self.total_collateral.read().high == 0 {
            self.status.write(RESOLVED);
        }
    }

    /// Redeems all tokens for collateral (used when market is voided)
    /// Both YES and NO token holders can redeem their full collateral
    #[external]
    fn redeem_void(ref self: Market) {
        let caller = get_caller_address();
        
        // Market must be voided
        let is_voided = self.voided.read();
        assert(is_voided, 'Market is not voided');
        
        let outcomes = self.outcomes.read();
        
        // Process each outcome token
        for outcome in outcomes {
            let token = self.outcome_tokens.read(outcome);
            
            // Get caller's balance of this token
            let token_balance = IERC20Metadata::balance_of(
                ref contract: token,
                account: caller
            );
            
            // Burn the tokens
            IERC20Metadata::burn(
                ref contract: token,
                account: caller,
                amount: token_balance
            );
            
            // Return collateral (for voided markets, full collateral is returned)
            if token_balance.low > 0 || token_balance.high > 0 {
                Self::withdraw_collateral(ref self, caller, token_balance);
            }
        }
    }

    /// Gets the outcome token address for a given outcome
    /// @param outcome The outcome name
    /// @return The token contract address
    #[external]
    fn get_outcome_token(self: @Market, outcome: felt252) -> ContractAddress {
        self.outcome_tokens.read(outcome)
    }

    /// Sets the outcome token address for a given outcome
    /// @param outcome The outcome name
    /// @param token_address The token contract address
    fn set_outcome_token(ref self: Market, outcome: felt252, token_address: ContractAddress) {
        self.outcome_tokens.write(outcome, token_address);
    }

    /// Gets the total collateral deposited
    /// @return The total collateral (u256)
    #[external]
    fn get_total_collateral(self: @Market) -> u256_lib::U256 {
        self.total_collateral.read()
    }

    /// Checks if the market is resolved
    /// @return true if resolved
    #[external]
    fn is_resolved(self: @Market) -> bool {
        self.resolved.read()
    }

    /// Checks if the market is voided
    /// @return true if voided
    #[external]
    fn is_voided(self: @Market) -> bool {
        self.voided.read()
    }

    /// Gets all outcomes
    /// @return Array of outcome names
    #[external]
    fn get_outcomes(self: @Market) -> Array<felt252> {
        self.outcomes.read()
    }

    /// Resolves the market with a winning outcome
    /// @param winning_outcome The winning outcome
    fn resolve(ref self: Market, winning_outcome: felt252) {
        let caller = get_caller_address();
        
        // Only the market owner or oracle can resolve
        // Add access control check here
        
        // Verify the winning outcome is valid
        let outcomes = self.outcomes.read();
        let is_valid = outcomes.iter().any(|o| *o == winning_outcome);
        assert(is_valid, 'Invalid winning outcome');
        
        self.resolved.write(true);
        self.winning_outcome.write(winning_outcome);
        self.status.write(RESOLVED);
    }

    /// Voids the market
    /// Used when something goes wrong and all tokens can be redeemed for full collateral
    fn void(ref self: Market) {
        let caller = get_caller_address();
        
        // Only the market owner can void
        // Add access control check here
        
        self.voided.write(true);
        self.resolved.write(true);
        self.status.write(VOIDED);
    }

    /// Deploys an outcome token for a given outcome
    /// @param outcome The outcome name
    /// @param token_address The deployed token address
    fn deploy_outcome_token(ref self: Market, outcome: felt252, token_address: ContractAddress) {
        let caller = get_caller_address();
        
        // Only the factory can deploy tokens
        let factory_felt = cast_felt(FACTORY_ADDRESS);
        assert(caller.value == factory_felt, 'Unauthorized: only factory can deploy outcome tokens');
        
        self.outcome_tokens.write(outcome, token_address);
    }

    /// Deposits collateral into the vault
    /// @param user The user address
    /// @param amount The amount to deposit (u256)
    fn deposit_collateral(ref self: Market, user: starknet::ContractAddress, amount: u256_lib::U256) {
        let collateral_token = self.collateral_token.read();
        
        // Transfer collateral from user to this contract
        IERC20Metadata::transfer_from(
            ref contract: collateral_token,
            from: user,
            to: starknet::ContractAddress::from(0),
            amount: amount
        );
        
        // Update total collateral
        let current = self.total_collateral.read();
        self.total_collateral.write(u256_lib::U256_add(current, amount));
    }

    /// Withdraws collateral from the vault
    /// @param user The user address
    /// @param amount The amount to withdraw (u256)
    fn withdraw_collateral(ref self: Market, user: starknet::ContractAddress, amount: u256_lib::U256) {
        let collateral_token = self.collateral_token.read();
        
        // Transfer collateral from this contract to user
        IERC20Metadata::transfer(
            ref contract: collateral_token,
            to: user,
            amount: amount
        );
        
        // Update total collateral
        let current = self.total_collateral.read();
        self.total_collateral.write(u256_lib::U256_sub(current, amount).unwrap());
    }
}
