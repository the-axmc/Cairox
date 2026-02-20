use snforge::test;
use cairox_contracts::DummyContract;

#[test]
fn test_initial_value() {
    let mut contract = DummyContract::constructor();
    assert_eq!(contract.get_value(), 42, 'Initial value should be 42');
}

#[test]
fn test_set_value() {
    let mut contract = DummyContract::constructor();
    contract.set_value(100);
    assert_eq!(contract.get_value(), 100, 'Value should be 100 after setting');
}

#[test]
fn test_create_market() {
    let mut contract = DummyContract::constructor();
    assert_eq!(contract.get_market_count(), 0, 'Initial market count should be 0');
    
    contract.create_market(s'market1');
    assert_eq!(contract.get_market_count(), 1, 'Market count should be 1 after creation');
}

#[test]
fn test_multiple_markets() {
    let mut contract = DummyContract::constructor();
    
    contract.create_market(s'market1');
    contract.create_market(s'market2');
    contract.create_market(s'market3');
    
    assert_eq!(contract.get_market_count(), 3, 'Market count should be 3');
}
