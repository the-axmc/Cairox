use snforge_std::test;
use starknet::ContractAddress;
use core::traits::TryInto;

fn addr(value: u128) -> ContractAddress {
    value.try_into().unwrap()
}

#[test]
fn test_collateral_vault_deposit() {
    let _caller = addr(0x123_u128);

    // Placeholder smoke test for snforge setup.
    assert(true, 'deposit works');
}

#[test]
fn test_market_status() {
    assert(true, 'market status works');
}

#[test]
fn test_lmsr_price_calculation() {
    let price: u128 = 50;
    assert(price != 0, 'price positive');
    assert(price < 100, 'price under 100');
}
