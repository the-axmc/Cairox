// PriceOracle Tests

use snforge::test;
use starknet::ContractAddress;
use openzeppelin::math::u256 as u256_lib;
use cairox_contracts::PriceOracle;
use core::option::OptionTrait;
use core::traits::TryInto;

fn owner_address() -> ContractAddress {
    addr(0x111111111111111111111111111111111111111111111111111111111111111_u128)
}

fn updater_address() -> ContractAddress {
    addr(0x222222222222222222222222222222222222222222222222222222222222222_u128)
}

fn addr(value: u128) -> ContractAddress {
    value.try_into().unwrap()
}

fn u256_value(amount: u128) -> u256_lib::U256 {
    u256_lib::U256 { low: amount, high: 0 }
}

#[test]
fn test_owner_can_update_price() {
    let owner = owner_address();
    starknet::set_caller_address(owner);
    let mut oracle = PriceOracle::constructor(decimals: 8, initial_price: u256_value(100));

    // Update as owner
    oracle.update_price(price: u256_value(1234));
    let price = oracle.get_price();
    assert(price.low == 1234, 'Price should update');
}

#[test]
#[should_revert]
fn test_non_updater_cannot_update() {
    let owner = owner_address();
    starknet::set_caller_address(owner);
    let _oracle = PriceOracle::constructor(decimals: 8, initial_price: u256_value(100));
    let bad = updater_address();
    starknet::set_caller_address(bad);
    _oracle.update_price(price: u256_value(999));
}
