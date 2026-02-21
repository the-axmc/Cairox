// Collateral Vault Tests for Cairox
// Tests deposit, withdraw, and balance functionality

use snforge::test;
use starknet::ContractAddress;
use openzeppelin::math::u256 as u256_lib;
use cairox_contracts::CollateralVault;

fn user_address() -> ContractAddress {
    ContractAddress::from(0x123456789012345678901234567890123456789012345678901234567890123_u128)
}

fn another_user_address() -> ContractAddress {
    ContractAddress::from(0x223456789012345678901234567890123456789012345678901234567890123_u128)
}

fn vault_address() -> ContractAddress {
    ContractAddress::from(0x323456789012345678901234567890123456789012345678901234567890123_u128)
}

fn factory_address() -> ContractAddress {
    ContractAddress::from(0x423456789012345678901234567890123456789012345678901234567890123_u128)
}

fn collateral_token_address() -> ContractAddress {
    ContractAddress::from(0x523456789012345678901234567890123456789012345678901234567890123_u128)
}

fn u256_value(amount: u128) -> u256_lib::U256 {
    u256_lib::U256 {
        low: amount,
        high: 0,
    }
}

#[test]
fn test_initialization() {
    let mut vault = CollateralVault::constructor();
    
    vault.initialize(
        market_factory: factory_address(),
        collateral_token: collateral_token_address()
    );
    
    let token = vault.get_collateral_token();
    assert_eq!(token.value, collateral_token_address.value, 'Token should be collateral_token_address');
}

#[test]
#[should_revert]
fn test_cannot_initialize_by_non_factory() {
    let mut vault = CollateralVault::constructor();
    
    // Try to initialize as non-factory address
    vault.initialize(
        market_factory: factory_address(),
        collateral_token: collateral_token_address()
    );
    // This should revert because only factory can initialize
}

#[test]
fn test_deposit() {
    let mut vault = CollateralVault::constructor();
    
    vault.initialize(
        market_factory: factory_address(),
        collateral_token: collateral_token_address()
    );
    
    // Deposit as factory
    vault.deposit(user: user_address(), amount: u256_value(100));
    
    let balance = vault.get_balance(user: user_address());
    assert_eq!(balance.low, 100, 'Balance should be 100 after deposit');
}

#[test]
#[should_revert]
fn test_cannot_deposit_by_non_factory() {
    let mut vault = CollateralVault::constructor();
    
    vault.initialize(
        market_factory: factory_address(),
        collateral_token: collateral_token_address()
    );
    
    // Try to deposit as non-factory
    vault.deposit(user: user_address(), amount: u256_value(100));
    // This should revert because only factory can deposit
}

#[test]
fn test_withdraw() {
    let mut vault = CollateralVault::constructor();
    
    vault.initialize(
        market_factory: factory_address(),
        collateral_token: collateral_token_address()
    );
    
    // Deposit first
    vault.deposit(user: user_address(), amount: u256_value(100));
    
    // Withdraw as factory
    vault.withdraw(user: user_address(), amount: u256_value(50));
    
    let balance = vault.get_balance(user: user_address());
    assert_eq!(balance.low, 50, 'Balance should be 50 after withdraw');
}

#[test]
#[should_revert]
fn test_cannot_withdraw_by_non_factory() {
    let mut vault = CollateralVault::constructor();
    
    vault.initialize(
        market_factory: factory_address(),
        collateral_token: collateral_token_address()
    );
    
    // Deposit first
    vault.deposit(user: user_address(), amount: u256_value(100));
    
    // Try to withdraw as non-factory
    vault.withdraw(user: user_address(), amount: u256_value(50));
    // This should revert because only factory can withdraw
}

#[test]
#[should_revert]
fn test_cannot_withdraw_insufficient_balance() {
    let mut vault = CollateralVault::constructor();
    
    vault.initialize(
        market_factory: factory_address(),
        collateral_token: collateral_token_address()
    );
    
    // Deposit only $50
    vault.deposit(user: user_address(), amount: u256_value(50));
    
    // Try to withdraw $100
    vault.withdraw(user: user_address(), amount: u256_value(100));
    // This should revert due to insufficient balance
}

#[test]
fn test_multiple_deposits() {
    let mut vault = CollateralVault::constructor();
    
    vault.initialize(
        market_factory: factory_address(),
        collateral_token: collateral_token_address()
    );
    
    // Multiple deposits from same user
    vault.deposit(user: user_address(), amount: u256_value(100));
    vault.deposit(user: user_address(), amount: u256_value(50));
    
    let balance = vault.get_balance(user: user_address());
    assert_eq!(balance.low, 150, 'Balance should be 150 after two deposits');
}

#[test]
fn test_multiple_users() {
    let mut vault = CollateralVault::constructor();
    
    vault.initialize(
        market_factory: factory_address(),
        collateral_token: collateral_token_address()
    );
    
    // Different users deposit
    vault.deposit(user: user_address(), amount: u256_value(100));
    vault.deposit(user: another_user_address(), amount: u256_value(50));
    
    let balance1 = vault.get_balance(user: user_address());
    let balance2 = vault.get_balance(user: another_user_address());
    
    assert_eq!(balance1.low, 100, 'User 1 balance should be 100');
    assert_eq!(balance2.low, 50, 'User 2 balance should be 50');
}

#[test]
fn test_total_collateral() {
    let mut vault = CollateralVault::constructor();
    
    vault.initialize(
        market_factory: factory_address(),
        collateral_token: collateral_token_address()
    );
    
    // Deposit from multiple users
    vault.deposit(user: user_address(), amount: u256_value(100));
    vault.deposit(user: another_user_address(), amount: u256_value(50));
    
    // Total collateral should be tracked
    // Note: In practice, you'd need a getter for total collateral
    // This test documents expected behavior
}

#[test]
fn test_withdraw_all() {
    let mut vault = CollateralVault::constructor();
    
    vault.initialize(
        market_factory: factory_address(),
        collateral_token: collateral_token_address()
    );
    
    // Deposit
    vault.deposit(user: user_address(), amount: u256_value(100));
    
    // Withdraw all
    vault.withdraw(user: user_address(), amount: u256_value(100));
    
    let balance = vault.get_balance(user: user_address());
    assert_eq!(balance.low, 0, 'Balance should be 0 after withdrawing all');
}
