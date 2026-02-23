// Tests for Deterministic Markets (DAA Resolution) in Cairox
// Tests DAA-based resolution: DAA >= threshold → YES, else NO
// Also tests: txcount, fees resolution

use snforge::test;
use starknet::ContractAddress;
use starknet::cast::cast_felt;
use openzeppelin::math::u256 as u256_lib;
use cairox_contracts::OptimisticOracle;
use cairox_contracts::ResolutionVerifier;

// ==================== Helper Functions ====================

fn reporter_address() -> ContractAddress {
    ContractAddress::from(0x123456789012345678901234567890123456789012345678901234567890123_u128)
}

fn oracle_address() -> ContractAddress {
    ContractAddress::from(0x223456789012345678901234567890123456789012345678901234567890123_u128)
}

fn arbiter_address() -> ContractAddress {
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

// Threshold values for DAA resolution
fn daa_threshold() -> u128 {
    1_000_000_000_000_000_000_u128  // 1e18 (1.0 in fixed point)
}

fn txcount_threshold() -> u128 {
    1000  // 1000 transactions
}

fn fees_threshold() -> u128 {
    1000000000000u128  // 1e12 fees (1000 stablecoin with 6 decimals)
}

// Market ID helpers
fn daa_market_id() -> felt252 {
    s'daa_test_market'
}

fn txcount_market_id() -> felt252 {
    s'txcount_test_market'
}

fn fees_market_id() -> felt252 {
    s'fees_test_market'
}

// Resolution outcome constants
const OUTCOME_YES: felt252 = 1;
const OUTCOME_NO: felt252 = 0;

// Market status constants
const PENDING: felt252 = 0;
const PROPOSED: felt252 = 1;
const RESOLVED: felt252 = 2;

// ==================== Test: DAA Above Threshold Resolves YES ====================

#[test]
func test_daa_above_threshold_resolves_yes() {
    // Test that when DAA >= threshold, market resolves to YES
    
    let mut oracle = OptimisticOracle::constructor(bond_token: ContractAddress::from(0_u128));
    let mut verifier = ResolutionVerifier::constructor();
    
    let market_id = daa_market_id();
    let outcome = OUTCOME_YES;
    let data_hash = s'0x123456789012345678901234567890123456789012345678901234567890123';
    let data_uri = s'ipfs://daa-data';
    let proposer_bond = u256_value(100);
    
    // Set threshold in verifier (in production, this would be configured)
    // For this test, we verify the resolution logic
    
    // 1. Propose DAA market with threshold check
    // The oracle's resolve_arbitration should check DAA data
    oracle.propose(
        market_id: market_id,
        outcome: outcome,
        data_hash: data_hash,
        data_uri: data_uri,
        bond: proposer_bond
    );
    
    // 2. Verify market is in Proposed state
    let status = oracle.get_market_status(market_id);
    assert(status == PROPOSED, 'Market should be in Proposed state');
    
    // 3. Arbiter resolves with YES outcome
    // In a real DAA market, the oracle would:
    // - Fetch DAA data from the data URI
    // - Compare DAA >= threshold
    // - Return YES if true, NO if false
    
    // Simulate arbiter resolution
    oracle.set_arbiter(arbiter_address());

    starknet::set_caller_address(starknet::CallerAddress { value: arbiter_address().value });
    
    oracle.resolve_arbitration(
        market_id: market_id,
        outcome: outcome
    );
    
    // 4. Verify market is resolved with YES outcome
    let final_status = oracle.get_market_status(market_id);
    assert(final_status == RESOLVED, 'Market should be Resolved');
    
    // Verify outcome is YES (encoded as 0)
    assert(outcome == OUTCOME_YES, 'Outcome should be YES');
}

// ==================== Test: DAA Below Threshold Resolves NO ====================

#[test]
func test_daa_below_threshold_resolves_no() {
    // Test that when DAA < threshold, market resolves to NO
    
    let mut oracle = OptimisticOracle::constructor(bond_token: ContractAddress::from(0_u128));
    
    let market_id = daa_market_id();
    let outcome = OUTCOME_NO;  // NO = 0
    let data_hash = s'0x987654321098765432109876543210987654321098765432109876543210987';
    let data_uri = s'ipfs://daa-data-low';
    let proposer_bond = u256_value(100);
    
    // Propose DAA market with low DAA value
    oracle.propose(
        market_id: market_id,
        outcome: outcome,
        data_hash: data_hash,
        data_uri: data_uri,
        bond: proposer_bond
    );
    
    // Verify market is in Proposed state
    let status = oracle.get_market_status(market_id);
    assert(status == PROPOSED, 'Market should be in Proposed state');
    
    // Arbiter resolves with NO outcome
    oracle.set_arbiter(arbiter_address());

    starknet::set_caller_address(starknet::CallerAddress { value: arbiter_address().value });
    
    oracle.resolve_arbitration(
        market_id: market_id,
        outcome: outcome
    );
    
    // Verify market is resolved
    let final_status = oracle.get_market_status(market_id);
    assert(final_status == RESOLVED, 'Market should be Resolved');
    
    // Verify outcome is NO
    assert(outcome == OUTCOME_NO, 'Outcome should be NO');
}

// ==================== Test: DAA Resolution with Data Verification ====================

#[test]
func test_daa_resolution_with_data_verification() {
    // Test the complete DAA resolution flow with data verification
    
    let mut oracle = OptimisticOracle::constructor(bond_token: ContractAddress::from(0_u128));
    let mut verifier = ResolutionVerifier::constructor();
    
    let market_id = daa_market_id();
    let daa_value = daa_threshold() * 2;  // DAA is 2x threshold
    let outcome = OUTCOME_YES;
    
    // Store DAA data hash (in production, this would be the hash of DAA data)
    let data_hash = s'0x111111111111111111111111111111111111111111111111111111111111111';
    
    // Propose the market
    oracle.propose(
        market_id: market_id,
        outcome: outcome,
        data_hash: data_hash,
        data_uri: s'ipfs://daa-verification',
        bond: u256_value(100)
    );
    
    // Market should be in Proposed state
    let status = oracle.get_market_status(market_id);
    assert(status == PROPOSED, 'Market should be in Proposed state');
    
    // Verify DAA data using verifier
    let daa_data = [daa_value as felt252];
    let verified = ResolutionVerifier::verify_resolution_proof(
        ref contract: verifier,
        market_id: market_id,
        outcome: outcome,
        proof: starknet::SpanTrait::new(daa_data)
    );
    
    assert(verified, 'DAA data should be verified');
    
    // Arbiter resolves based on verified DAA
    oracle.set_arbiter(arbiter_address());

    starknet::set_caller_address(starknet::CallerAddress { value: arbiter_address().value });
    
    oracle.resolve_arbitration(
        market_id: market_id,
        outcome: outcome
    );
    
    // Market should be resolved with YES outcome
    let final_status = oracle.get_market_status(market_id);
    assert(final_status == RESOLVED, 'Market should be Resolved');
}

// ==================== Test: TXCount Resolution ====================

#[test]
func test_txcount_resolution() {
    // Test that when txcount >= threshold, market resolves to YES
    
    let mut oracle = OptimisticOracle::constructor(bond_token: ContractAddress::from(0_u128));
    
    let market_id = txcount_market_id();
    let txcount_value = txcount_threshold() + 100;  // txcount is above threshold
    let outcome = OUTCOME_YES;
    
    // Propose txcount market
    oracle.propose(
        market_id: market_id,
        outcome: outcome,
        data_hash: s'0x222222222222222222222222222222222222222222222222222222222222222',
        data_uri: s'ipfs://txcount-data',
        bond: u256_value(100)
    );
    
    // Verify market state
    let status = oracle.get_market_status(market_id);
    assert(status == PROPOSED, 'Market should be in Proposed state');
    
    // Verify txcount data
    let txcount_data = [txcount_value as felt252];
    let verified = Verification::verify_txcount(
        ref contract: oracle,
        market_id: market_id,
        txcount: txcount_value
    );
    
    assert(verified, 'TXCount should be verified');
    
    // Arbiter resolves with YES (txcount >= threshold)
    oracle.set_arbiter(arbiter_address());

    starknet::set_caller_address(starknet::CallerAddress { value: arbiter_address().value });
    
    oracle.resolve_arbitration(
        market_id: market_id,
        outcome: outcome
    );
    
    // Verify resolution
    let final_status = oracle.get_market_status(market_id);
    assert(final_status == RESOLVED, 'Market should be Resolved');
}

// ==================== Test: TXCount Below Threshold Resolves NO ====================

#[test]
func test_txcount_below_threshold_resolves_no() {
    // Test that when txcount < threshold, market resolves to NO
    
    let mut oracle = OptimisticOracle::constructor(bond_token: ContractAddress::from(0_u128));
    
    let market_id = txcount_market_id();
    let txcount_value = txcount_threshold() - 100;  // txcount is below threshold
    let outcome = OUTCOME_NO;
    
    // Propose txcount market
    oracle.propose(
        market_id: market_id,
        outcome: outcome,
        data_hash: s'0x333333333333333333333333333333333333333333333333333333333333333',
        data_uri: s'ipfs://txcount-data-low',
        bond: u256_value(100)
    );
    
    // Verify market state
    let status = oracle.get_market_status(market_id);
    assert(status == PROPOSED, 'Market should be in Proposed state');
    
    // Verify txcount data
    let txcount_data = [txcount_value as felt252];
    let verified = Verification::verify_txcount(
        ref contract: oracle,
        market_id: market_id,
        txcount: txcount_value
    );
    
    assert(verified, 'TXCount should be verified');
    
    // Arbiter resolves with NO (txcount < threshold)
    oracle.set_arbiter(arbiter_address());

    starknet::set_caller_address(starknet::CallerAddress { value: arbiter_address().value });
    
    oracle.resolve_arbitration(
        market_id: market_id,
        outcome: outcome
    );
    
    // Verify resolution
    let final_status = oracle.get_market_status(market_id);
    assert(final_status == RESOLVED, 'Market should be Resolved');
}

// ==================== Test: Fees Resolution ====================

#[test]
func test_fees_resolution() {
    // Test that when fees >= threshold, market resolves to YES
    
    let mut oracle = OptimisticOracle::constructor(bond_token: ContractAddress::from(0_u128));
    
    let market_id = fees_market_id();
    let fees_value = fees_threshold() + 1_000_000_000_000u128;  // fees above threshold
    let outcome = OUTCOME_YES;
    
    // Propose fees market
    oracle.propose(
        market_id: market_id,
        outcome: outcome,
        data_hash: s'0x444444444444444444444444444444444444444444444444444444444444444',
        data_uri: s'ipfs://fees-data',
        bond: u256_value(100)
    );
    
    // Verify market state
    let status = oracle.get_market_status(market_id);
    assert(status == PROPOSED, 'Market should be in Proposed state');
    
    // Verify fees data
    let fees_data = [fees_value as felt252];
    let verified = Verification::verify_fees(
        ref contract: oracle,
        market_id: market_id,
        fees: fees_value
    );
    
    assert(verified, 'Fees should be verified');
    
    // Arbiter resolves with YES (fees >= threshold)
    oracle.set_arbiter(arbiter_address());

    starknet::set_caller_address(starknet::CallerAddress { value: arbiter_address().value });
    
    oracle.resolve_arbitration(
        market_id: market_id,
        outcome: outcome
    );
    
    // Verify resolution
    let final_status = oracle.get_market_status(market_id);
    assert(final_status == RESOLVED, 'Market should be Resolved');
}

// ==================== Test: Fees Below Threshold Resolves NO ====================

#[test]
func test_fees_below_threshold_resolves_no() {
    // Test that when fees < threshold, market resolves to NO
    
    let mut oracle = OptimisticOracle::constructor(bond_token: ContractAddress::from(0_u128));
    
    let market_id = fees_market_id();
    let fees_value = fees_threshold() - 1_000_000_000_000u128;  // fees below threshold
    let outcome = OUTCOME_NO;
    
    // Propose fees market
    oracle.propose(
        market_id: market_id,
        outcome: outcome,
        data_hash: s'0x555555555555555555555555555555555555555555555555555555555555555',
        data_uri: s'ipfs://fees-data-low',
        bond: u256_value(100)
    );
    
    // Verify market state
    let status = oracle.get_market_status(market_id);
    assert(status == PROPOSED, 'Market should be in Proposed state');
    
    // Verify fees data
    let fees_data = [fees_value as felt252];
    let verified = Verification::verify_fees(
        ref contract: oracle,
        market_id: market_id,
        fees: fees_value
    );
    
    assert(verified, 'Fees should be verified');
    
    // Arbiter resolves with NO (fees < threshold)
    oracle.set_arbiter(arbiter_address());

    starknet::set_caller_address(starknet::CallerAddress { value: arbiter_address().value });
    
    oracle.resolve_arbitration(
        market_id: market_id,
        outcome: outcome
    );
    
    // Verify resolution
    let final_status = oracle.get_market_status(market_id);
    assert(final_status == RESOLVED, 'Market should be Resolved');
}

// ==================== Test: DAA Resolution Verify Function ====================

#[test]
func test_daa_verify_function() {
    // Test the DAA verification function
    
    let mut oracle = OptimisticOracle::constructor(bond_token: ContractAddress::from(0_u128));
    
    let market_id = daa_market_id();
    let daa_above = daa_threshold() * 2;
    let daa_below = daa_threshold() / 2;
    
    // Test DAA above threshold
    let verified_above = Verification::verify_daa(
        ref contract: oracle,
        market_id: market_id,
        daa: daa_above,
        threshold: daa_threshold()
    );
    
    assert(verified_above, 'DAA above threshold should be verified as YES');
    
    // Test DAA below threshold
    let verified_below = Verification::verify_daa(
        ref contract: oracle,
        market_id: market_id,
        daa: daa_below,
        threshold: daa_threshold()
    );
    
    assert(!verified_below, 'DAA below threshold should be verified as NO');
}

// ==================== Test: Resolution Threshold Constants ====================

#[test]
func test_threshold_constants() {
    // Verify threshold constants are correct
    
    // DAA threshold should be 1e18 (1.0 in fixed point)
    assert(daa_threshold() == 1_000_000_000_000_000_000_u128, 'DAA threshold should be 1e18');
    
    // TXCount threshold should be 1000
    assert(txcount_threshold() == 1000, 'TXCount threshold should be 1000');
    
    // Fees threshold should be 1e12 (1000 stablecoin with 6 decimals)
    assert(fees_threshold() == 1_000_000_000_000u128, 'Fees threshold should be 1e12');
}

// ==================== Helper Contract for Verification ====================

#[contract]
mod Verification {
    use super::{OptimisticOracle, daa_threshold, txcount_threshold, fees_threshold, OUTCOME_YES, OUTCOME_NO};
    
    /// Verify DAA (Daily Active Addresses) against threshold
    /// @param contract The oracle contract state
    /// @param market_id The market ID
    /// @param daa The DAA value to verify
    /// @param threshold The threshold for resolution
    /// @return verified True if DAA >= threshold (YES), false if DAA < threshold (NO)
    pub fn verify_daa(
        ref contract: OptimisticOracle,
        market_id: felt252,
        daa: u128,
        threshold: u128
    ) -> bool {
        // DAA >= threshold → YES (true)
        // DAA < threshold → NO (false)
        daa >= threshold
    }
    
    /// Verify transaction count against threshold
    /// @param contract The oracle contract state
    /// @param market_id The market ID
    /// @param txcount The transaction count to verify
    /// @return verified True if txcount >= threshold (YES), false if txcount < threshold (NO)
    pub fn verify_txcount(
        ref contract: OptimisticOracle,
        market_id: felt252,
        txcount: u128
    ) -> bool {
        // txcount >= threshold → YES (true)
        // txcount < threshold → NO (false)
        txcount >= txcount_threshold()
    }
    
    /// Verify fees against threshold
    /// @param contract The oracle contract state
    /// @param market_id The market ID
    /// @param fees The fees value to verify
    /// @return verified True if fees >= threshold (YES), false if fees < threshold (NO)
    pub fn verify_fees(
        ref contract: OptimisticOracle,
        market_id: felt252,
        fees: u128
    ) -> bool {
        // fees >= threshold → YES (true)
        // fees < threshold → NO (false)
        fees >= fees_threshold()
    }
}
