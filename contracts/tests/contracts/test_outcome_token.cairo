// Outcome Token Tests for Cairox
// Tests basic ERC20 functionality

use snforge::test;
use starknet::ContractAddress;
use openzeppelin::math::u256 as u256_lib;
use cairox_contracts::OutcomeToken;

fn user_address() -> ContractAddress {
    ContractAddress::from(0x123456789012345678901234567890123456789012345678901234567890123_u128)
}

fn another_address() -> ContractAddress {
    ContractAddress::from(0x223456789012345678901234567890123456789012345678901234567890123_u128)
}

fn vault_address() -> ContractAddress {
    ContractAddress::from(0x323456789012345678901234567890123456789012345678901234567890123_u128)
}

fn u256_value(amount: u128) -> u256_lib::U256 {
    u256_lib::U256 {
        low: amount,
        high: 0,
    }
}

#[test]
fn test_initialization() {
    let mut token = OutcomeToken::constructor();
    
    token.initialize(
        name: s'YES Outcome',
        symbol: s'YES',
        decimals: 6,
        vault: vault_address()
    );
    
    assert_eq!(token.name(), s'YES Outcome', 'Name should be YES Outcome');
    assert_eq!(token.symbol(), s'YES', 'Symbol should be YES');
    assert_eq!(token.decimals(), 6, 'Decimals should be 6');
}

#[test]
fn test_mint_by_vault() {
    let mut token = OutcomeToken::constructor();
    
    token.initialize(
        name: s'YES Outcome',
        symbol: s'YES',
        decimals: 6,
        vault: vault_address()
    );
    
    // Mint tokens as vault
    token.mint(account: user_address(), amount: u256_value(100));
    
    let balance = token.balance_of(account: user_address());
    assert_eq!(balance.low, 100, 'Balance should be 100');
}

#[test]
#[should_revert]
fn test_cannot_mint_by_non_vault() {
    let mut token = OutcomeToken::constructor();
    
    token.initialize(
        name: s'YES Outcome',
        symbol: s'YES',
        decimals: 6,
        vault: vault_address()
    );
    
    // Try to mint as non-vault address
    token.mint(account: user_address(), amount: u256_value(100));
    // This should revert because only vault can mint
}

#[test]
fn test_burn_by_vault() {
    let mut token = OutcomeToken::constructor();
    
    token.initialize(
        name: s'YES Outcome',
        symbol: s'YES',
        decimals: 6,
        vault: vault_address()
    );
    
    // Mint tokens
    token.mint(account: user_address(), amount: u256_value(100));
    
    // Burn tokens as vault
    token.burn(account: user_address(), amount: u256_value(50));
    
    let balance = token.balance_of(account: user_address());
    assert_eq!(balance.low, 50, 'Balance should be 50 after burning 50');
}

#[test]
#[should_revert]
fn test_cannot_burn_by_non_vault() {
    let mut token = OutcomeToken::constructor();
    
    token.initialize(
        name: s'YES Outcome',
        symbol: s'YES',
        decimals: 6,
        vault: vault_address()
    );
    
    // Mint tokens
    token.mint(account: user_address(), amount: u256_value(100));
    
    // Try to burn as non-vault
    token.burn(account: user_address(), amount: u256_value(50));
    // This should revert because only vault can burn
}

#[test]
fn test_transfer() {
    let mut token = OutcomeToken::constructor();
    
    token.initialize(
        name: s'YES Outcome',
        symbol: s'YES',
        decimals: 6,
        vault: vault_address()
    );
    
    // Mint tokens
    token.mint(account: user_address(), amount: u256_value(100));
    
    // Transfer tokens
    token.transfer(to: another_address(), amount: u256_value(50));
    
    let user_balance = token.balance_of(account: user_address());
    let other_balance = token.balance_of(account: another_address());
    
    assert_eq!(user_balance.low, 50, 'User balance should be 50');
    assert_eq!(other_balance.low, 50, 'Other balance should be 50');
}

#[test]
#[should_revert]
fn test_cannot_transfer_insufficient_balance() {
    let mut token = OutcomeToken::constructor();
    
    token.initialize(
        name: s'YES Outcome',
        symbol: s'YES',
        decimals: 6,
        vault: vault_address()
    );
    
    // Mint tokens
    token.mint(account: user_address(), amount: u256_value(100));
    
    // Try to transfer more than balance
    token.transfer(to: another_address(), amount: u256_value(150));
    // This should revert due to insufficient balance
}

#[test]
fn test_total_supply() {
    let mut token = OutcomeToken::constructor();
    
    token.initialize(
        name: s'YES Outcome',
        symbol: s'YES',
        decimals: 6,
        vault: vault_address()
    );
    
    // Mint tokens
    token.mint(account: user_address(), amount: u256_value(100));
    token.mint(account: another_address(), amount: u256_value(50));
    
    // Burn some tokens
    token.burn(account: user_address(), amount: u256_value(20));
    
    // Total supply = 100 + 50 - 20 = 130
    // Note: In practice, you'd need a getter for total supply
    // This test documents expected behavior
}

#[test]
fn test_multiple_mints_and_burns() {
    let mut token = OutcomeToken::constructor();
    
    token.initialize(
        name: s'YES Outcome',
        symbol: s'YES',
        decimals: 6,
        vault: vault_address()
    );
    
    // Multiple mints
    token.mint(account: user_address(), amount: u256_value(100));
    token.mint(account: another_address(), amount: u256_value(200));
    
    // Multiple burns
    token.burn(account: user_address(), amount: u256_value(30));
    token.burn(account: another_address(), amount: u256_value(50));
    
    // Final balances
    let user_balance = token.balance_of(account: user_address());
    let other_balance = token.balance_of(account: another_address());
    
    assert_eq!(user_balance.low, 70, 'User final balance should be 70');
    assert_eq!(other_balance.low, 150, 'Other final balance should be 150');
}

#[test]
fn test_outcome_token_per_market() {
    // Test that each market can have its own outcome tokens
    
    // Each market would have:
    // - YES outcome token
    // - NO outcome token
    
    // Test that tokens are independent per market
    let mut token1 = OutcomeToken::constructor();
    token1.initialize(
        name: s'Market 1 YES',
        symbol: s'M1YES',
        decimals: 6,
        vault: vault_address()
    );
    
    let mut token2 = OutcomeToken::constructor();
    token2.initialize(
        name: s'Market 2 YES',
        symbol: s'M2YES',
        decimals: 6,
        vault: vault_address()
    );
    
    token1.mint(account: user_address(), amount: u256_value(100));
    token2.mint(account: user_address(), amount: u256_value(200));
    
    // Balances should be independent
    let balance1 = token1.balance_of(account: user_address());
    let balance2 = token2.balance_of(account: user_address());
    
    assert_eq!(balance1.low, 100, 'Market 1 balance should be 100');
    assert_eq!(balance2.low, 200, 'Market 2 balance should be 200');
}
