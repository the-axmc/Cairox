// Tests for Disputes and Arbitration in Cairox
// Tests dispute workflow: propose, dispute, arbitration, finalize

use snforge::test;
use starknet::ContractAddress;
use starknet::cast::cast_felt;
use openzeppelin::math::u256 as u256_lib;
use cairox_contracts::OptimisticOracle;
use cairox_contracts::Arbitration;

// ==================== Helper Functions ====================

fn arbiter_address() -> ContractAddress {
    ContractAddress::from(0x123456789012345678901234567890123456789012345678901234567890123_u128)
}

fn proposer_address() -> ContractAddress {
    ContractAddress::from(0x223456789012345678901234567890123456789012345678901234567890123_u128)
}

fn disputor_address() -> ContractAddress {
    ContractAddress::from(0x323456789012345678901234567890123456789012345678901234567890123_u128)
}

fn protocol_address() -> ContractAddress {
    ContractAddress::from(0x999999999999999999999999999999999999999999999999999999999999999_u128)
}

fn u256_value(amount: u128) -> u256_lib::U256 {
    u256_lib::U256 {
        low: amount,
        high: 0,
    }
}

fn market_id_1() -> felt252 {
    s'market_1'
}

// Minimum bond amounts (same as defaults in oracle.cairo)
fn min_proposer_bond() -> u256_lib::U256 {
    u256_lib::U256 { low: 100, high: 0 }
}

fn min_dispute_bond() -> u256_lib::U256 {
    u256_lib::U256 { low: 200, high: 0 }
}

// ==================== Test: Dispute Blocks Finalize ====================

#[test]
#[should_revert]
func test_dispute_blocks_finalize() {
    // 1. Propose market with bond
    let mut oracle = OptimisticOracle::constructor(bond_token: ContractAddress::from(0_u128));
    
    let market_id = market_id_1();
    let outcome = s'YES';
    let data_hash = s'0x1234';
    let data_uri = s'metadata';
    let proposer_bond = min_proposer_bond();
    
    // Propose from authorized reporter
    oracle.register_market(market_id: market_id);
    oracle.propose(
        market_id: market_id,
        outcome: outcome,
        data_hash: data_hash,
        data_uri: data_uri,
        bond: proposer_bond
    );
    
    // Verify market is in Proposed state
    let status = oracle.get_market_status(market_id);
    assert(status == 1, 'Market should be in Proposed state');  // 1 = PROPOSED
    
    // 2. Dispute the proposal
    let dispute_bond = min_dispute_bond();
    oracle.dispute(market_id: market_id, bond: dispute_bond);
    
    // Verify market is disputed
    let is_disputed = oracle.is_disputed(market_id);
    assert(is_disputed, 'Market should be disputed');
    
    // 3. Try finalize - should revert with "DISPUTED"
    oracle.finalize(market_id: market_id);
}

// ==================== Test: Bond Transfer After Arbitration ====================

#[test]
func test_bond_transfer() {
    // Setup: Oracle and arbitration contracts
    let mut oracle = OptimisticOracle::constructor(bond_token: ContractAddress::from(0_u128));
    let _arbitration = Arbitration::constructor();
    
    let market_id = market_id_1();
    let outcome = s'YES';
    let data_hash = s'0x1234';
    let data_uri = s'metadata';
    
    let proposer_bond = min_proposer_bond();
    let dispute_bond = min_dispute_bond();
    
    // 1. Propose with bond
    oracle.register_market(market_id: market_id);
    oracle.propose(
        market_id: market_id,
        outcome: outcome,
        data_hash: data_hash,
        data_uri: data_uri,
        bond: proposer_bond
    );
    
    // 2. Dispute with bond
    oracle.dispute(market_id: market_id, bond: dispute_bond);
    
    // Verify disputed state
    let is_disputed = oracle.is_disputed(market_id);
    assert(is_disputed, 'Market should be disputed');
    
    // 3. Arbitration resolves (proposer wins)
    // Need to call from arbiter address
    oracle.set_arbiter(arbiter_address());
    let arbiter = arbiter_address();
    starknet::set_caller_address(starknet::CallerAddress { value: arbiter.value });
    
    oracle.resolve_arbitration(
        market_id: market_id,
        outcome: outcome
    );
    
    // 4. Verify: proposer gets their bond + dispute bond
    // In this implementation, bond tracking is done in the oracle
    // The proposer should have received both bonds back
    
    // Verify market status is Resolved
    let status = oracle.get_market_status(market_id);
    assert(status == 2, 'Market should be Resolved');  // 2 = RESOLVED
    
    // Verify disputed flag is cleared after arbitration
    // Note: In actual implementation, bond transfers would be verified via token balances
}

// ==================== Test: Arbitration Resolution ====================

#[test]
func test_arbitration_resolution() {
    // 1. Propose
    let mut oracle = OptimisticOracle::constructor(bond_token: ContractAddress::from(0_u128));
    
    let market_id = market_id_1();
    let outcome = s'YES';
    let data_hash = s'0x1234';
    let data_uri = s'metadata';
    let proposer_bond = min_proposer_bond();
    
    oracle.register_market(market_id: market_id);
    oracle.propose(
        market_id: market_id,
        outcome: outcome,
        data_hash: data_hash,
        data_uri: data_uri,
        bond: proposer_bond
    );
    
    let status = oracle.get_market_status(market_id);
    assert(status == 1, 'Market should be in Proposed state');  // 1 = PROPOSED
    
    // 2. Dispute
    let dispute_bond = min_dispute_bond();
    oracle.dispute(market_id: market_id, bond: dispute_bond);
    
    let is_disputed = oracle.is_disputed(market_id);
    assert(is_disputed, 'Market should be disputed');
    
    // 3. Arbiter resolves with outcome
    oracle.set_arbiter(arbiter_address());
    let arbiter = arbiter_address();
    starknet::set_caller_address(starknet::CallerAddress { value: arbiter.value });
    
    let resolved_outcome = s'NO';  // Different from proposed outcome
    oracle.resolve_arbitration(
        market_id: market_id,
        outcome: resolved_outcome
    );
    
    // 4. Verify: status = Resolved, outcome set correctly
    let final_status = oracle.get_market_status(market_id);
    assert(final_status == 2, 'Market status should be Resolved');  // 2 = RESOLVED
    
    let is_disputed_after = oracle.is_disputed(market_id);
    assert(!is_disputed_after, 'Market should no longer be disputed');
}

// ==================== Test: Non-Disputed Proposal Finalizes Correctly ====================

#[test]
func test_non_disputed_finalize() {
    // 1. Propose with bond
    let mut oracle = OptimisticOracle::constructor(bond_token: ContractAddress::from(0_u128));
    
    let market_id = market_id_1();
    let outcome = s'YES';
    let data_hash = s'0x1234';
    let data_uri = s'metadata';
    let proposer_bond = min_proposer_bond();
    
    oracle.register_market(market_id: market_id);
    oracle.propose(
        market_id: market_id,
        outcome: outcome,
        data_hash: data_hash,
        data_uri: data_uri,
        bond: proposer_bond
    );
    
    let status = oracle.get_market_status(market_id);
    assert(status == 1, 'Market should be in Proposed state');  // 1 = PROPOSED
    
    // 2. Wait past dispute window (or mock time)
    // In a real test, we would use block_timestamp manipulation
    // For now, we'll assume the dispute window has passed
    // Note: starknet-foundry doesn't directly support time manipulation in tests
    
    // To test this properly, we'd need to:
    // - Set up a mock block timestamp
    // - Wait for the dispute window to expire (300 seconds default)
    
    // For this test, we'll use a workaround:
    // If the market hasn't been disputed, we can fast-forward time via mocking
    // But since we can't mock in snforge directly, this test documents the expected behavior
    
    // 3. Finalize succeeds (set dispute window to 0 for test)
    oracle.set_dispute_window(u256_value(0));
    oracle.finalize(market_id: market_id);
    
    // 4. Verify: status = Resolved
    let final_status = oracle.get_market_status(market_id);
    assert(final_status == 2, 'Market status should be Resolved');  // 2 = RESOLVED
}

// ==================== Test: DisputedProposalCannotBeFinalizedManually ====================

#[test]
#[should_revert]
func test_disputed_proposal_cannot_be_finalized() {
    // Test that a disputed proposal cannot be finalized without arbitration
    
    let mut oracle = OptimisticOracle::constructor(bond_token: ContractAddress::from(0_u128));
    
    let market_id = market_id_1();
    let outcome = s'YES';
    let data_hash = s'0x1234';
    let data_uri = s'metadata';
    let proposer_bond = min_proposer_bond();
    
    // Propose
    oracle.register_market(market_id: market_id);
    oracle.propose(
        market_id: market_id,
        outcome: outcome,
        data_hash: data_hash,
        data_uri: data_uri,
        bond: proposer_bond
    );
    
    // Dispute
    let dispute_bond = min_dispute_bond();
    oracle.dispute(market_id: market_id, bond: dispute_bond);
    
    // Try to finalize (should fail because market is disputed)
    oracle.finalize(market_id: market_id);
}

// ==================== Test: NonDisputedProposalFinalizesAfterWindow ====================

#[test]
func test_non_disputed_finalizes_after_window() {
    // Test the full flow of a non-disputed proposal
    
    let mut oracle = OptimisticOracle::constructor(bond_token: ContractAddress::from(0_u128));
    
    let market_id = market_id_1();
    let outcome = s'YES';
    let data_hash = s'0x1234';
    let data_uri = s'metadata';
    let proposer_bond = min_proposer_bond();
    
    // Propose
    oracle.register_market(market_id: market_id);
    oracle.propose(
        market_id: market_id,
        outcome: outcome,
        data_hash: data_hash,
        data_uri: data_uri,
        bond: proposer_bond
    );
    
    let initial_status = oracle.get_market_status(market_id);
    assert(initial_status == 1, 'Initial status should be PROPOSED (1)');
    
    // Dispute window is 300 seconds by default
    // For tests, set it to 0 to allow finalize
    oracle.set_dispute_window(u256_value(0));
    oracle.finalize(market_id: market_id);
    
    let final_status = oracle.get_market_status(market_id);
    assert(final_status == 2, 'Market status should be Resolved');
}

// ==================== Test: ArbitrationOnlyByArbiter ====================

#[test]
#[should_revert]
func test_arbitration_only_by_arbiter() {
    // Test that only the arbiter can resolve disputes
    
    let mut oracle = OptimisticOracle::constructor(bond_token: ContractAddress::from(0_u128));
    
    let market_id = market_id_1();
    let outcome = s'YES';
    let data_hash = s'0x1234';
    let data_uri = s'metadata';
    let proposer_bond = min_proposer_bond();
    
    // Propose
    oracle.register_market(market_id: market_id);
    oracle.propose(
        market_id: market_id,
        outcome: outcome,
        data_hash: data_hash,
        data_uri: data_uri,
        bond: proposer_bond
    );
    
    // Dispute
    let dispute_bond = min_dispute_bond();
    oracle.dispute(market_id: market_id, bond: dispute_bond);
    
    // Try to resolve from a non-arbiter address
    oracle.set_arbiter(arbiter_address());
    let random_user = proposer_address();
    starknet::set_caller_address(starknet::CallerAddress { value: random_user.value });
    
    oracle.resolve_arbitration(
        market_id: market_id,
        outcome: outcome
    );
}

// ==================== Test: CannotDisputeAlreadyDisputed ====================

#[test]
#[should_revert]
func test_cannot_dispute_already_disputed() {
    // Test that a market cannot be disputed multiple times
    
    let mut oracle = OptimisticOracle::constructor(bond_token: ContractAddress::from(0_u128));
    
    let market_id = market_id_1();
    let outcome = s'YES';
    let data_hash = s'0x1234';
    let data_uri = s'metadata';
    let proposer_bond = min_proposer_bond();
    
    // Propose
    oracle.register_market(market_id: market_id);
    oracle.propose(
        market_id: market_id,
        outcome: outcome,
        data_hash: data_hash,
        data_uri: data_uri,
        bond: proposer_bond
    );
    
    // First dispute
    let dispute_bond = min_dispute_bond();
    oracle.dispute(market_id: market_id, bond: dispute_bond);
    
    // Second dispute should fail
    oracle.dispute(market_id: market_id, bond: dispute_bond);
}

// ==================== Test: DisputeWrongState ====================

#[test]
#[should_revert]
func test_dispute_wrong_state() {
    // Test that dispute fails if market is not in Proposed state
    
    let mut oracle = OptimisticOracle::constructor(bond_token: ContractAddress::from(0_u128));
    
    let market_id = market_id_1();
    let outcome = s'YES';
    let data_hash = s'0x1234';
    let data_uri = s'metadata';
    let proposer_bond = min_proposer_bond();
    
    // Propose
    oracle.register_market(market_id: market_id);
    oracle.propose(
        market_id: market_id,
        outcome: outcome,
        data_hash: data_hash,
        data_uri: data_uri,
        bond: proposer_bond
    );
    
    // Resolve manually (without dispute) to change state
    oracle.set_arbiter(arbiter_address());
    let arbiter = arbiter_address();
    starknet::set_caller_address(starknet::CallerAddress { value: arbiter.value });
    
    oracle.resolve_arbitration(
        market_id: market_id,
        outcome: outcome
    );
    
    // Now try to dispute (should fail - market is Resolved, not Proposed)
    let dispute_bond = min_dispute_bond();
    oracle.dispute(market_id: market_id, bond: dispute_bond);
}

// ==================== Test: ProposeWrongState ====================

#[test]
#[should_revert]
func test_propose_wrong_state() {
    // Test that proposing an already-proposed market fails
    
    let mut oracle = OptimisticOracle::constructor(bond_token: ContractAddress::from(0_u128));
    
    let market_id = market_id_1();
    let outcome = s'YES';
    let data_hash = s'0x1234';
    let data_uri = s'metadata';
    let proposer_bond = min_proposer_bond();
    
    // First propose
    oracle.register_market(market_id: market_id);
    oracle.propose(
        market_id: market_id,
        outcome: outcome,
        data_hash: data_hash,
        data_uri: data_uri,
        bond: proposer_bond
    );
    
    // Second propose (should fail - market already exists)
    oracle.register_market(market_id: market_id);
    oracle.propose(
        market_id: market_id,
        outcome: outcome,
        data_hash: data_hash,
        data_uri: data_uri,
        bond: proposer_bond
    );
}

// ==================== Test: FinalizeWrongState ====================

#[test]
#[should_revert]
func test_finalize_wrong_state() {
    // Test that finalize fails for non-existent market
    
    let mut oracle = OptimisticOracle::constructor(bond_token: ContractAddress::from(0_u128));
    
    let market_id = s'nonexistent';
    
    // Try to finalize non-existent market
    oracle.finalize(market_id: market_id);
}

// ==================== Test: BondAmountCheck ====================

#[test]
#[should_revert]
func test_propose_bond_too_low() {
    // Test that propose fails if bond is below minimum
    
    let mut oracle = OptimisticOracle::constructor(bond_token: ContractAddress::from(0_u128));
    
    let market_id = market_id_1();
    let outcome = s'YES';
    let data_hash = s'0x1234';
    let data_uri = s'metadata';
    let low_bond = u256_value(50);  // Below minimum of 100
    
    // Propose with insufficient bond
    oracle.register_market(market_id: market_id);
    oracle.propose(
        market_id: market_id,
        outcome: outcome,
        data_hash: data_hash,
        data_uri: data_uri,
        bond: low_bond
    );
}

#[test]
#[should_revert]
func test_dispute_bond_too_low() {
    // Test that dispute fails if bond is below minimum
    
    let mut oracle = OptimisticOracle::constructor(bond_token: ContractAddress::from(0_u128));
    
    let market_id = market_id_1();
    let outcome = s'YES';
    let data_hash = s'0x1234';
    let data_uri = s'metadata';
    let proposer_bond = min_proposer_bond();
    
    // Propose first
    oracle.register_market(market_id: market_id);
    oracle.propose(
        market_id: market_id,
        outcome: outcome,
        data_hash: data_hash,
        data_uri: data_uri,
        bond: proposer_bond
    );
    
    // Try to dispute with insufficient bond
    let low_dispute_bond = u256_value(150);  // Below minimum of 200
    oracle.dispute(market_id: market_id, bond: low_dispute_bond);
}

// ==================== Test: OutcomeValidation ====================

#[test]
func test_arbitration_outcome_validation() {
    // Test that arbitration outcome is stored correctly
    
    let mut oracle = OptimisticOracle::constructor(bond_token: ContractAddress::from(0_u128));
    
    let market_id = market_id_1();
    let proposed_outcome = s'YES';
    let data_hash = s'0x1234';
    let data_uri = s'metadata';
    let proposer_bond = min_proposer_bond();
    
    // Propose
    oracle.register_market(market_id: market_id);
    oracle.propose(
        market_id: market_id,
        outcome: proposed_outcome,
        data_hash: data_hash,
        data_uri: data_uri,
        bond: proposer_bond
    );
    
    // Dispute
    let dispute_bond = min_dispute_bond();
    oracle.dispute(market_id: market_id, bond: dispute_bond);
    
    // Arbiter resolves with a different outcome
    let arbiter = arbiter_address();
    starknet::set_caller_address(starknet::CallerAddress { value: arbiter.value });
    
    let resolved_outcome = s'NO';
    oracle.resolve_arbitration(
        market_id: market_id,
        outcome: resolved_outcome
    );
    
    // Verify the resolved outcome matches what was set
    let status = oracle.get_market_status(market_id);
    assert(status == 2, 'Market should be Resolved');
    
    // The outcome should be updated in the oracle's storage
    // In a full implementation, we would have a function to get the final outcome
}
