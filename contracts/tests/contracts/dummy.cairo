use snforge::test;
use cairox_contracts::Contract;

#[test]
fn test_initial_value() {
    let contract = Contract::constructor();
    assert_eq!(contract.get_value(), 42, 'Initial value should be 42');
}

#[test]
fn test_set_value() {
    let mut contract = Contract::constructor();
    contract.set_value(100);
    assert_eq!(contract.get_value(), 100, 'Value should be 100 after setting');
}