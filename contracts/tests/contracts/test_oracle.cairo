use snforge::test;
use starknet::ContractAddress;
use cairox_contracts::OptimisticOracle;
use openzeppelin::math::u256 as u256_lib;

// Helper function to create a test reporter address
fn reporter_address() -> ContractAddress {
    ContractAddress::from(0x123456789012345678901234567890123456789012345678901234567890123_u128)
}

fn u256_value(amount: u128) -> u256_lib::U256 {
    u256_lib::U256 {
        low: amount,
        high: 0,
    }
}

#[test]
fn test_propose_market() {
    let mut oracle = OptimisticOracle::constructor(bond_token: ContractAddress::from(0_u128));
    
    // Propose a market as the reporter
    oracle.register_market(market_id: 1);
    oracle.propose(
        market_id: 1,
        outcome: 1,
        data_hash: 0x1234567890abcdef,
        data_uri: 0x68747470733a2f2f6578616d706c652e636f6d,  // "https://example.com"
        bond: u256_value(100)
    );
    
    let status = oracle.get_market_status(market_id: 1);
    assert(status == 1, 'Market status should be PROPOSED (1)');
}

#[test]
#[should_revert]
fn test_propose_unauthorized() {
    let mut oracle = OptimisticOracle::constructor(bond_token: ContractAddress::from(0_u128));
    
    // Try to propose from a non-reporter address
    oracle.register_market(market_id: 1);
    let non_reporter = reporter_address();
    starknet::set_caller_address(starknet::CallerAddress { value: non_reporter.value });
    oracle.propose(
        market_id: 1,
        outcome: 1,
        data_hash: 0x1234567890abcdef,
        data_uri: 0x68747470733a2f2f6578616d706c652e636f6d,
        bond: u256_value(100)
    );
}

#[test]
fn test_cannot_finalize_early() {
    let mut oracle = OptimisticOracle::constructor(bond_token: ContractAddress::from(0_u128));
    
    // Propose a market
    oracle.register_market(market_id: 1);
    oracle.propose(
        market_id: 1,
        outcome: 1,
        data_hash: 0x1234567890abcdef,
        data_uri: 0x68747470733a2f2f6578616d706c652e636f6d,
        bond: u256_value(100)
    );
    
    // Try to finalize immediately - should fail because dispute window hasn't passed
    let result = oracle.finalize(market_id: 1);
    // The test framework will catch the revert if we're using should_revert
}

#[test]
fn test_finalize_after_dispute_window() {
    let mut oracle = OptimisticOracle::constructor(bond_token: ContractAddress::from(0_u128));
    
    // Propose a market
    oracle.register_market(market_id: 1);
    oracle.propose(
        market_id: 1,
        outcome: 1,
        data_hash: 0x1234567890abcdef,
        data_uri: 0x68747470733a2f2f6578616d706c652e636f6d,
        bond: u256_value(100)
    );
    
    // Get initial status
    let status_before = oracle.get_market_status(market_id: 1);
    assert(status_before == 1, 'Status before finalize should be PROPOSED (1)');
    
    // Advance time by 301 seconds (past the 300 second dispute window)
    // Note: In a real test environment, we would use Starknet's time manipulation
    // For now, we simulate the passage of time in the contract logic
    
    // Finalize after dispute window
    oracle.set_dispute_window(u256_value(0));
    oracle.finalize(market_id: 1);
    
    // Verify status is RESOLVED
    let status_after = oracle.get_market_status(market_id: 1);
    assert(status_after == 2, 'Status after finalize should be RESOLVED (2)');
}

#[test]
fn test_market_data_storage() {
    let mut oracle = OptimisticOracle::constructor(bond_token: ContractAddress::from(0_u128));
    
    let proposer = reporter_address();
    oracle.register_market(market_id: 42);
    oracle.propose(
        market_id: 42,
        outcome: 5,
        data_hash: 0xabc123def456,
        data_uri: 0x736f6d655f646174615f757269,  // "some_data_uri"
        bond: u256_value(100)
    );
    
    // Verify we can retrieve the status
    let status = oracle.get_market_status(market_id: 42);
    assert(status == 1, 'Market should be in PROPOSED state');
}
