// Stablecoin Tests for Cairox

use snforge::test;
use starknet::ContractAddress;
use openzeppelin::math::u256 as u256_lib;
use cairox_contracts::Stablecoin;

fn owner_address() -> ContractAddress {
    ContractAddress::from(0x111111111111111111111111111111111111111111111111111111111111111_u128)
}

fn user_address() -> ContractAddress {
    ContractAddress::from(0x222222222222222222222222222222222222222222222222222222222222222_u128)
}

fn other_address() -> ContractAddress {
    ContractAddress::from(0x333333333333333333333333333333333333333333333333333333333333333_u128)
}

fn u256_value(amount: u128) -> u256_lib::U256 {
    u256_lib::U256 { low: amount, high: 0 }
}

#[test]
fn test_constructor_and_metadata() {
    let owner = owner_address();
    let recipient = user_address();
    let token = Stablecoin::constructor(
        name: s'cUSD',
        symbol: s'cUSD',
        decimals: 6,
        owner: owner,
        initial_supply: u256_value(1_000_000),
        recipient: recipient
    );

    assert(token.name() == s'cUSD', 'Name should match');
    assert(token.symbol() == s'cUSD', 'Symbol should match');
    assert(token.decimals() == 6, 'Decimals should match');

    let balance = token.balance_of(account: recipient);
    assert(balance.low == 1_000_000, 'Recipient should get initial supply');
}

#[test]
fn test_owner_can_mint_and_burn() {
    let owner = owner_address();
    let recipient = user_address();
    let mut token = Stablecoin::constructor(
        name: s'cUSD',
        symbol: s'cUSD',
        decimals: 6,
        owner: owner,
        initial_supply: u256_value(0),
        recipient: recipient
    );

    // Mint as owner
    starknet::set_caller_address(starknet::CallerAddress { value: owner.value });
    token.mint(to: recipient, amount: u256_value(100));
    let balance = token.balance_of(account: recipient);
    assert(balance.low == 100, 'Mint should credit balance');

    // Burn as owner
    token.burn(from: recipient, amount: u256_value(40));
    let balance_after = token.balance_of(account: recipient);
    assert(balance_after.low == 60, 'Burn should reduce balance');
}

#[test]
fn test_transfer_and_transfer_from() {
    let owner = owner_address();
    let recipient = user_address();
    let mut token = Stablecoin::constructor(
        name: s'cUSD',
        symbol: s'cUSD',
        decimals: 6,
        owner: owner,
        initial_supply: u256_value(100),
        recipient: recipient
    );

    // Transfer from recipient to other
    let user = user_address();
    starknet::set_caller_address(starknet::CallerAddress { value: user.value });
    let ok = token.transfer(to: other_address(), amount: u256_value(30));
    assert(ok, 'Transfer should succeed');

    let user_balance = token.balance_of(account: user_address());
    let other_balance = token.balance_of(account: other_address());
    assert(user_balance.low == 70, 'User balance should be 70');
    assert(other_balance.low == 30, 'Other balance should be 30');

    // Approve and transfer_from
    token.approve(spender: owner_address(), amount: u256_value(20));
    let owner = owner_address();
    starknet::set_caller_address(starknet::CallerAddress { value: owner.value });
    let ok_from = token.transfer_from(
        from: user_address(),
        to: other_address(),
        amount: u256_value(20)
    );
    assert(ok_from, 'Transfer from should succeed');

    let user_balance_after = token.balance_of(account: user_address());
    let other_balance_after = token.balance_of(account: other_address());
    assert(user_balance_after.low == 50, 'User balance should be 50');
    assert(other_balance_after.low == 50, 'Other balance should be 50');
}
