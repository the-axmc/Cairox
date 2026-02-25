// Stablecoin Tests for Cairox

use snforge_std::test;
use starknet::ContractAddress;
use starknet::contract_address_const;
use openzeppelin::math::u256 as u256_lib;
use cairox_contracts::Stablecoin;
use cairox_contracts::price_oracle::{IContractDispatcher, IContractDispatcherTrait};
use core::array::{Array, ArrayTrait};
use core::traits::TryInto;
use core::option::OptionTrait;

fn owner_address() -> ContractAddress {
    addr(0x111111111111111111111111111111111111111111111111111111111111111_u128)
}

fn user_address() -> ContractAddress {
    addr(0x222222222222222222222222222222222222222222222222222222222222222_u128)
}

fn other_address() -> ContractAddress {
    addr(0x333333333333333333333333333333333333333333333333333333333333333_u128)
}

fn zero_address() -> ContractAddress {
    addr(0_u128)
}

fn addr(value: u128) -> ContractAddress {
    value.try_into().unwrap()
}

fn price_feed_type_oracle() -> u8 {
    1
}

fn u256_value(amount: u128) -> u256_lib::U256 {
    u256_lib::U256 { low: amount, high: 0 }
}

fn deploy_price_oracle(decimals: u8, price: u128) -> ContractAddress {
    let mut calldata: Array<felt252> = ArrayTrait::new();
    calldata.append(decimals.into());
    calldata.append(price.into());
    calldata.append(0);
    starknet::deploy_syscall(
        'price_oracle',
        calldata.span(),
        0,
        false
    )
    .unwrap()
    .assert()
}

fn dummy_collateral_token() -> ContractAddress {
    contract_address_const::<0xdead>()
}

#[test]
fn test_constructor_and_metadata() {
    let owner = owner_address();
    let price_feed = deploy_price_oracle(6, 1_000_000);
    let token = Stablecoin::constructor(
        name: 'cUSD',
        symbol: 'cUSD',
        decimals: 6,
        owner: owner,
        collateral_token: dummy_collateral_token(),
        collateral_decimals: 6,
        price_feed: price_feed,
        price_feed_type: price_feed_type_oracle()
    );

    assert(token.name() == 'cUSD', 'Name should match');
    assert(token.symbol() == 'cUSD', 'Symbol should match');
    assert(token.decimals() == 6, 'Decimals should match');
    assert(token.get_owner() == owner, 'Owner should be set');
}

#[test]
fn test_approve_sets_allowance() {
    let owner = owner_address();
    let price_feed = deploy_price_oracle(6, 1_000_000);
    let mut token = Stablecoin::constructor(
        name: 'cUSD',
        symbol: 'cUSD',
        decimals: 6,
        owner: owner,
        collateral_token: dummy_collateral_token(),
        collateral_decimals: 6,
        price_feed: price_feed,
        price_feed_type: price_feed_type_oracle()
    );

    let spender = other_address();
    starknet::set_caller_address(owner);
    token.approve(spender: spender, amount: u256_value(123));
    let allowance = token.allowance(owner: owner, spender: spender);
    assert(allowance.low == 123, 'Allowance should be set');
}

#[test]
#[should_revert]
fn test_pause_blocks_deposit() {
    let owner = owner_address();
    let price_feed = deploy_price_oracle(6, 1_000_000);
    let mut token = Stablecoin::constructor(
        name: 'cUSD',
        symbol: 'cUSD',
        decimals: 6,
        owner: owner,
        collateral_token: dummy_collateral_token(),
        collateral_decimals: 6,
        price_feed: price_feed,
        price_feed_type: price_feed_type_oracle()
    );

    starknet::set_caller_address(owner);
    token.pause();
    // Should revert before touching collateral token
    token.deposit_collateral(amount: u256_value(1));
}

#[test]
#[should_revert]
fn test_price_feed_required() {
    let owner = owner_address();
    let token = Stablecoin::constructor(
        name: 'cUSD',
        symbol: 'cUSD',
        decimals: 6,
        owner: owner,
        collateral_token: dummy_collateral_token(),
        collateral_decimals: 6,
        price_feed: zero_address(),
        price_feed_type: price_feed_type_oracle()
    );

    // Should revert because no price feed is configured
    token.get_latest_price();
}

#[test]
#[should_revert]
fn test_stale_price_reverts() {
    let owner = owner_address();
    let price_feed = deploy_price_oracle(6, 1_000_000);
    let mut token = Stablecoin::constructor(
        name: 'cUSD',
        symbol: 'cUSD',
        decimals: 6,
        owner: owner,
        collateral_token: dummy_collateral_token(),
        collateral_decimals: 6,
        price_feed: price_feed,
        price_feed_type: price_feed_type_oracle()
    );
    // Set tight max age and simulate stale data
    starknet::set_caller_address(owner);
    token.set_max_price_age(max_age: u256_value(1));
    starknet::set_block_timestamp(1000);
    // Price updated_at set at deployment (timestamp 0), so now it is stale.
    token.get_latest_price();
}

#[test]
#[should_revert]
fn test_price_bounds_reverts() {
    let owner = owner_address();
    let price_feed = deploy_price_oracle(6, 1_000_000);
    let mut token = Stablecoin::constructor(
        name: 'cUSD',
        symbol: 'cUSD',
        decimals: 6,
        owner: owner,
        collateral_token: dummy_collateral_token(),
        collateral_decimals: 6,
        price_feed: price_feed,
        price_feed_type: price_feed_type_oracle()
    );
    // Set min bound above current price
    starknet::set_caller_address(owner);
    token.set_price_bounds(min_price: u256_value(2_000_000), max_price: u256_value(0));
    token.get_latest_price();
}
