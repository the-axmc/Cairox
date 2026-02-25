// Outcome Token Tests for Cairox (updated API)

use snforge_std::test;
use starknet::ContractAddress;
use openzeppelin::math::u256 as u256_lib;
use cairox_contracts::OutcomeToken;
use core::option::OptionTrait;
use core::traits::TryInto;

fn owner_address() -> ContractAddress {
    addr(0x111111111111111111111111111111111111111111111111111111111111111_u128)
}

fn user_address() -> ContractAddress {
    addr(0x222222222222222222222222222222222222222222222222222222222222222_u128)
}

fn other_address() -> ContractAddress {
    addr(0x333333333333333333333333333333333333333333333333333333333333333_u128)
}

fn addr(value: u128) -> ContractAddress {
    value.try_into().unwrap()
}

fn u256_value(amount: u128) -> u256_lib::U256 {
    u256_lib::U256 {
        low: amount,
        high: 0,
    }
}

#[test]
fn test_constructor_and_owner() {
    let owner = owner_address();
    let token = OutcomeToken::constructor(name: 'YES', symbol: 'YES', owner: owner.into());
    let stored_owner = token.get_owner();
    assert(stored_owner == owner.into(), 'Owner should match constructor');
}

#[test]
fn test_owner_can_mint_and_burn() {
    let owner = owner_address();
    let mut token = OutcomeToken::constructor(name: 'YES', symbol: 'YES', owner: owner.into());

    // Mint as owner
    starknet::set_caller_address(owner);
    token.mint(to: user_address().into(), amount: u256_value(100));
    let balance = token.balance_of(account: user_address().into());
    assert(balance.low == 100, 'Mint should credit balance');

    // Burn as owner
    token.burn(from: user_address().into(), amount: u256_value(40));
    let balance_after = token.balance_of(account: user_address().into());
    assert(balance_after.low == 60, 'Burn should reduce balance');
}

#[test]
#[should_revert]
fn test_non_owner_cannot_mint() {
    let owner = owner_address();
    let mut token = OutcomeToken::constructor(name: 'YES', symbol: 'YES', owner: owner.into());

    // Call from non-owner
    let non_owner = user_address();
    starknet::set_caller_address(non_owner);
    token.mint(to: user_address().into(), amount: u256_value(10));
}

#[test]
#[should_revert]
fn test_non_owner_cannot_burn() {
    let owner = owner_address();
    let mut token = OutcomeToken::constructor(name: 'YES', symbol: 'YES', owner: owner.into());

    // Mint as owner
    starknet::set_caller_address(owner);
    token.mint(to: user_address().into(), amount: u256_value(10));

    // Burn as non-owner
    let non_owner = other_address();
    starknet::set_caller_address(non_owner);
    token.burn(from: user_address().into(), amount: u256_value(5));
}

#[test]
fn test_transfer_and_transfer_from() {
    let owner = owner_address();
    let mut token = OutcomeToken::constructor(name: 'YES', symbol: 'YES', owner: owner.into());

    // Mint as owner
    starknet::set_caller_address(owner);
    token.mint(to: user_address().into(), amount: u256_value(100));

    // Transfer from user to other
    let user = user_address();
    starknet::set_caller_address(user);
    token.transfer(to: other_address().into(), amount: u256_value(30));
    let user_balance = token.balance_of(account: user_address().into());
    let other_balance = token.balance_of(account: other_address().into());
    assert(user_balance.low == 70, 'User balance should be 70');
    assert(other_balance.low == 30, 'Other balance should be 30');

    // Approve and transfer_from
    token.approve(spender: owner_address().into(), amount: u256_value(20));
    let owner = owner_address();
    starknet::set_caller_address(owner);
    token.transfer_from(
        from: user_address().into(),
        to: other_address().into(),
        amount: u256_value(20)
    );

    let user_balance_after = token.balance_of(account: user_address().into());
    let other_balance_after = token.balance_of(account: other_address().into());
    assert(user_balance_after.low == 50, 'User balance should be 50');
    assert(other_balance_after.low == 50, 'Other balance should be 50');
}
