// Outcome Token Contract for Cairox
// ERC20 token representing an outcome in a prediction market
// Only the Collateral Vault can mint and burn these tokens

use starknet::ContractAddress;
use starknet::SyscallResult;
use starknet::{get_caller_address, StorageAddress};
use starknet::cast::cast_felt;
use openzeppelin::token::erc20::interfaces::IERC20Metadata;
use openzeppelin::math::u256 as u256_lib;
use openzeppelin::utils::Revertable;
use openzeppelin::introspection::IERC165;

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
}

// Vault address - only this contract can mint/burn
const VAULT_ADDRESS: felt252 = 0x1;

#[starknet::interface]
pub trait IOutcomeToken {
    fn transfer(ref self: OutcomeToken, to: starknet::ContractAddress, amount: u256_lib::U256) -> bool;
    fn balance_of(self: @OutcomeToken, account: starknet::ContractAddress) -> u256_lib::U256;
    fn mint(ref self: OutcomeToken, account: starknet::ContractAddress, amount: u256_lib::U256);
    fn burn(ref self: OutcomeToken, account: starknet::ContractAddress, amount: u256_lib::U256);
    fn name(self: @OutcomeToken) -> felt252;
    fn symbol(self: @OutcomeToken) -> felt252;
    fn decimals(self: @OutcomeToken) -> u8;
}

#[starknet::contract]
mod OutcomeToken {
    use super::{test, IOutcomeToken};
    use starknet::SyscallResult;
    use starknet::{get_caller_address, StorageAddress};
    use starknet::cast::cast_felt;
    use openzeppelin::token::erc20::interfaces::IERC20Metadata;
    use openzeppelin::math::u256 as u256_lib;
    use openzeppelin::utils::Revertable;
    use openzeppelin::introspection::IERC165;
    use openzeppelin::access::ownable::OwnableEntityTrait;

    #[storage]
    struct Storage {
        /// Mapping of account -> balance
        balances: Map<starknet::ContractAddress, u256_lib::U256>,
        /// Mapping of owner -> spender -> allowance
        allowances: Map<(starknet::ContractAddress, starknet::ContractAddress), u256_lib::U256>,
        /// Total supply of tokens
        total_supply: u256_lib::U256,
        /// Name of the token
        name: felt252,
        /// Symbol of the token
        symbol: felt252,
        /// Number of decimals
        decimals: u8,
        /// Collateral vault address - only this contract can mint/burn
        vault: starknet::ContractAddress,
    }

    /// Initializes the outcome token
    /// @param name The name of the token
    /// @param symbol The symbol of the token
    /// @param decimals The number of decimals
    /// @param vault The address of the collateral vault
    #[external]
    #[init]
    fn initialize(ref self: OutcomeToken, name: felt252, symbol: felt252, decimals: u8, vault: starknet::ContractAddress) {
        let caller = get_caller_address();
        
        // Only allow initialization by the vault
        let vault_felt = cast_felt(VAULT_ADDRESS);
        assert(caller.value == vault.value, 'Unauthorized: only vault can initialize outcome token');
        
        self.name.write(name);
        self.symbol.write(symbol);
        self.decimals.write(decimals);
        self.vault.write(vault);
        self.total_supply.write(u256_lib::U256 { low: 0, high: 0 });
    }

    /// Transfers tokens to another address
    /// @param to The recipient address
    /// @param amount The amount to transfer (u256)
    /// @return true if the transfer was successful
    #[external]
    fn transfer(ref self: OutcomeToken, to: starknet::ContractAddress, amount: u256_lib::U256) -> bool {
        let from = get_caller_address();
        Self::transfer_from(ref self, from, to, amount);
        true
    }

    /// Gets the balance of an account
    /// @param account The account address
    /// @return The account's balance (u256)
    #[external]
    fn balance_of(self: @OutcomeToken, account: starknet::ContractAddress) -> u256_lib::U256 {
        self.balances.read(account)
    }

    /// Mints new tokens for an account
    /// Only the vault can call this function
    /// @param account The account to mint tokens to
    /// @param amount The amount to mint (u256)
    #[external]
    fn mint(ref self: OutcomeToken, account: starknet::ContractAddress, amount: u256_lib::U256) {
        let caller = get_caller_address();
        
        // Only the vault can mint
        let stored_vault = self.vault.read();
        assert(caller.value == stored_vault.value, 'Unauthorized: only vault can mint');
        
        // Update balance
        let current_balance = self.balances.read(account);
        self.balances.write(account, u256_lib::U256_add(current_balance, amount));
        
        // Update total supply
        let total = self.total_supply.read();
        self.total_supply.write(u256_lib::U256_add(total, amount));
    }

    /// Burns tokens from an account
    /// Only the vault can call this function
    /// @param account The account to burn tokens from
    /// @param amount The amount to burn (u256)
    #[external]
    fn burn(ref self: OutcomeToken, account: starknet::ContractAddress, amount: u256_lib::U256) {
        let caller = get_caller_address();
        
        // Only the vault can burn
        let stored_vault = self.vault.read();
        assert(caller.value == stored_vault.value, 'Unauthorized: only vault can burn');
        
        // Check sufficient balance
        let current_balance = self.balances.read(account);
        assert(u256_lib::U256_sub(current_balance, amount).is_ok(), 'Insufficient balance');
        
        // Update balance
        let new_balance = u256_lib::U256_sub(current_balance, amount).unwrap();
        self.balances.write(account, new_balance);
        
        // Update total supply
        let total = self.total_supply.read();
        self.total_supply.write(u256_lib::U256_sub(total, amount).unwrap());
    }

    /// Gets the name of the token
    /// @return The token name
    #[external]
    fn name(self: @OutcomeToken) -> felt252 {
        self.name.read()
    }

    /// Gets the symbol of the token
    /// @return The token symbol
    #[external]
    fn symbol(self: @OutcomeToken) -> felt252 {
        self.symbol.read()
    }

    /// Gets the number of decimals
    /// @return The number of decimals
    #[external]
    fn decimals(self: @OutcomeToken) -> u8 {
        self.decimals.read()
    }

    /// Internal transfer from one account to another
    /// @param from The sender address
    /// @param to The recipient address
    /// @param amount The amount to transfer (u256)
    fn transfer_from(ref self: OutcomeToken, from: starknet::ContractAddress, to: starknet::ContractAddress, amount: u256_lib::U256) {
        // Check sufficient balance
        let current_balance = self.balances.read(from);
        assert(u256_lib::U256_sub(current_balance, amount).is_ok(), 'Insufficient balance');
        
        // Update sender balance
        let new_from_balance = u256_lib::U256_sub(current_balance, amount).unwrap();
        self.balances.write(from, new_from_balance);
        
        // Update recipient balance
        let to_balance = self.balances.read(to);
        self.balances.write(to, u256_lib::U256_add(to_balance, amount));
    }

    /// Gets the allowance of an account
    /// @param owner The owner address
    /// @param spender The spender address
    /// @return The allowance (u256)
    #[external]
    fn allowance(self: @OutcomeToken, owner: starknet::ContractAddress, spender: starknet::ContractAddress) -> u256_lib::U256 {
        self.allowances.read((owner, spender))
    }

    /// Sets the allowance of an account
    /// @param spender The spender address
    /// @param amount The allowance amount (u256)
    #[external]
    fn approve(ref self: OutcomeToken, spender: starknet::ContractAddress, amount: u256_lib::U256) -> bool {
        let owner = get_caller_address();
        self.allowances.write((owner, spender), amount);
        true
    }
}
