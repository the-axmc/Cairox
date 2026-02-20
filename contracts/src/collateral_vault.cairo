// Collateral Vault Contract for Cairox
// Manages user deposits and tracks collateral balances
// Only the Market Factory can create markets that interact with this vault

use starknet::ContractAddress;
use starknet::SyscallResult;
use starknet::{get_caller_address, StorageAddress};
use starknet::cast::cast_felt;
use openzeppelin::token::erc20::interfaces::IERC20Metadata;
use openzeppelin::token::erc20::ERC20;
use openzeppelin::introspection::IERC165;
use openzeppelin::math::u256 as u256_lib;
use super::market_factory::MarketFactory;

#[cfg(test)]
mod test {
    use starknet::ContractAddress;
    use starknet::cast::cast_felt;
    use openzeppelin::math::u256 as u256_lib;

    // Test address for USDC
    pub fn test_collateral_address() -> ContractAddress {
        ContractAddress::from(0x123456789012345678901234567890123456789012345678901234567890123_u128)
    }

    // Helper function to create a u256 value
    pub fn u256_value(amount: u128) -> u256_lib::U256 {
        u256_lib::U256 {
            low: amount,
            high: 0,
        }
    }
}

// Market address - set during initialization
const MARKET_FACTORY_ADDRESS: felt252 = 0x1;

#[starknet::interface]
pub trait ICollateralVault {
    fn deposit(ref self: CollateralVault, user: starknet::ContractAddress, amount: u256_lib::U256);
    fn withdraw(ref self: CollateralVault, user: starknet::ContractAddress, amount: u256_lib::U256);
    fn get_balance(self: @CollateralVault, user: starknet::ContractAddress) -> u256_lib::U256;
    fn get_collateral_token(self: @CollateralVault) -> starknet::ContractAddress;
    fn initialize(ref self: CollateralVault, market_factory: starknet::ContractAddress, collateral_token: starknet::ContractAddress);
}

#[starknet::contract]
mod CollateralVault {
    use super::{test, ICollateralVault};
    use starknet::SyscallResult;
    use starknet::{get_caller_address, StorageAddress};
    use starknet::cast::cast_felt;
    use openzeppelin::token::erc20::interfaces::IERC20Metadata;
    use openzeppelin::math::u256 as u256_lib;
    use openzeppelin::access::ownable::OwnableEntityTrait;

    #[storage]
    struct Storage {
        /// Mapping of user address -> deposited amount (u256)
        balances: Map<starknet::ContractAddress, u256_lib::U256>,
        /// Collateral token contract address
        collateral_token: starknet::ContractAddress,
        /// Market factory address - only this contract can trigger deposit/withdraw
        market_factory: starknet::ContractAddress,
        /// Total collateral held by the vault
        total_collateral: u256_lib::U256,
    }

    /// Initializes the collateral vault
    /// @param market_factory The address of the market factory contract
    /// @param collateral_token The address of the ERC20 token used as collateral
    #[external]
    #[init]
    fn initialize(ref self: CollateralVault, market_factory: starknet::ContractAddress, collateral_token: starknet::ContractAddress) {
        let caller = get_caller_address();
        
        // Only allow initialization by the market factory
        let market_factory_felt = cast_felt(MARKET_FACTORY_ADDRESS);
        assert(caller.value == market_factory.value, 'Unauthorized: only market factory can initialize');
        
        self.market_factory.write(market_factory);
        self.collateral_token.write(collateral_token);
        self.total_collateral.write(u256_lib::U256 { low: 0, high: 0 });
    }

    /// Deposits collateral into the vault on behalf of a user
    /// This function is called by the market factory when a user wants to mint outcome tokens
    /// @param user The user address to credit the deposit to
    /// @param amount The amount of collateral to deposit (u256)
    #[external]
    fn deposit(ref self: CollateralVault, user: starknet::ContractAddress, amount: u256_lib::U256) {
        let caller = get_caller_address();
        
        // Only the market factory can call this function
        let stored_market_factory = self.market_factory.read();
        assert(caller.value == stored_market_factory.value, 'Unauthorized: only market factory can deposit');
        
        // Get current balance
        let current_balance = self.balances.read(user);
        
        // Add amount to user's balance
        let new_balance = u256_lib::U256_add(current_balance, amount);
        self.balances.write(user, new_balance);
        
        // Update total collateral
        let total = self.total_collateral.read();
        self.total_collateral.write(u256_lib::U256_add(total, amount));
        
        // Transfer collateral token from caller to this contract
        let token = self.collateral_token.read();
        IERC20Metadata::transfer_from(
            ref contract: token,
            from: caller,
            to: starknet::ContractAddress::from(0),
            amount: amount
        );
    }

    /// Withdraws collateral from the vault for a user
    /// This function is called by the market factory when a user redeems their position
    /// @param user The user address to withdraw from
    /// @param amount The amount of collateral to withdraw (u256)
    #[external]
    fn withdraw(ref self: CollateralVault, user: starknet::ContractAddress, amount: u256_lib::U256) {
        let caller = get_caller_address();
        
        // Only the market factory can call this function
        let stored_market_factory = self.market_factory.read();
        assert(caller.value == stored_market_factory.value, 'Unauthorized: only market factory can withdraw');
        
        // Get current balance
        let current_balance = self.balances.read(user);
        
        // Check sufficient balance
        assert(u256_lib::U256_sub(current_balance, amount).is_ok(), 'Insufficient balance');
        
        // Subtract amount from user's balance
        let new_balance = u256_lib::U256_sub(current_balance, amount).unwrap();
        self.balances.write(user, new_balance);
        
        // Update total collateral
        let total = self.total_collateral.read();
        self.total_collateral.write(u256_lib::U256_sub(total, amount).unwrap());
        
        // Transfer collateral token from this contract to user
        let token = self.collateral_token.read();
        IERC20Metadata::transfer(
            ref contract: token,
            to: user,
            amount: amount
        );
    }

    /// Gets the collateral balance of a user
    /// @param user The user address
    /// @return The user's collateral balance (u256)
    #[external]
    fn get_balance(self: @CollateralVault, user: starknet::ContractAddress) -> u256_lib::U256 {
        self.balances.read(user)
    }

    /// Gets the collateral token contract address
    /// @return The collateral token address
    #[external]
    fn get_collateral_token(self: @CollateralVault) -> starknet::ContractAddress {
        self.collateral_token.read()
    }
}
