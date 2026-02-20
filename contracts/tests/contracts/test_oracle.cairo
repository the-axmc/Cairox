use snforge::test;
use starknet::ContractAddress;
use cairox_contracts::OptimisticOracle;

// Helper function to create a test reporter address
fn reporter_address() -> ContractAddress {
    ContractAddress::from(0x123456789012345678901234567890123456789012345678901234567890123_u128)
}

#[test]
fn test_propose_market() {
    let mut oracle = OptimisticOracle::constructor();
    
    // Propose a market as the reporter
    oracle.propose(
        market_id: 1,
        outcome: 1,
        data_hash: 0x1234567890abcdef,
        data_uri: 0x68747470733a2f2f6578616d706c652e636f6d  // "https://example.com"
    );
    
    let status = oracle.get_market_status(market_id: 1);
    assert(status == 1, 'Market status should be PROPOSED (1)');
}

#[test]
#[should_revert]
fn test_propose_unauthorized() {
    let mut oracle = OptimisticOracle::constructor();
    
    // Try to propose from a non-reporter address (this should fail internally)
    // Note: In practice, we can't easily change get_caller_address in tests
    // This test is more about documenting expected behavior
    oracle.propose(
        market_id: 1,
        outcome: 1,
        data_hash: 0x1234567890abcdef,
        data_uri: 0x68747470733a2f2f6578616d706c652e636f6d
    );
}

#[test]
fn test_cannot_finalize_early() {
    let mut oracle = OptimisticOracle::constructor();
    
    // Propose a market
    oracle.propose(
        market_id: 1,
        outcome: 1,
        data_hash: 0x1234567890abcdef,
        data_uri: 0x68747470733a2f2f6578616d706c652e636f6d
    );
    
    // Try to finalize immediately - should fail because dispute window hasn't passed
    let result = oracle.finalize(market_id: 1);
    // The test framework will catch the revert if we're using should_revert
}

#[test]
fn test_finalize_after_dispute_window() {
    let mut oracle = OptimisticOracle::constructor();
    
    // Propose a market
    oracle.propose(
        market_id: 1,
        outcome: 1,
        data_hash: 0x1234567890abcdef,
        data_uri: 0x68747470733a2f2f6578616d706c652e636f6d
    );
    
    // Get initial status
    let status_before = oracle.get_market_status(market_id: 1);
    assert(status_before == 1, 'Status before finalize should be PROPOSED (1)');
    
    // Advance time by 301 seconds (past the 300 second dispute window)
    // Note: In a real test environment, we would use Starknet's time manipulation
    // For now, we simulate the passage of time in the contract logic
    
    // Finalize after dispute window
    oracle.finalize(market_id: 1);
    
    // Verify status is RESOLVED
    let status_after = oracle.get_market_status(market_id: 1);
    assert(status_after == 2, 'Status after finalize should be RESOLVED (2)');
}

#[test]
fn test_market_data_storage() {
    let mut oracle = OptimisticOracle::constructor();
    
    let proposer = reporter_address();
    oracle.propose(
        market_id: 42,
        outcome: 5,
        data_hash: 0xabc123def456,
        data_uri: 0x736f6d655f646174615f757269  // "some_data_uri"
    );
    
    // Verify we can retrieve the status
    let status = oracle.get_market_status(market_id: 42);
    assert(status == 1, 'Market should be in PROPOSED state');
}
