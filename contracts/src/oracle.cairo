#[starknet::interface]
pub trait IOptimisticOracle<T> {
    fn propose(
        ref self: T,
        market_id: felt252,
        outcome: felt252,
        data_hash: felt252,
        data_uri: felt252,
        bond: u256_lib::U256
    );
    fn dispute(ref self: T, market_id: felt252, bond: u256_lib::U256);
    fn finalize(ref self: T, market_id: felt252);
    fn resolve_arbitration(ref self: T, market_id: felt252, outcome: felt252);
    fn get_market_status(self: @T, market_id: felt252) -> felt252;
    fn propose_with_proof(
        ref self: T,
        market_id: felt252,
        outcome: felt252,
        data_hash: felt252,
        zk_proof: Span<felt252>
    );
    fn fast_finalize(ref self: T, market_id: felt252);
    fn is_disputed(self: @T, market_id: felt252) -> bool;
}

#[starknet::contract]
mod OptimisticOracle {
    use starknet::SyscallResult;
    use starknet::{get_caller_address, StorageAddress, get_contract_address};
    use starknet::cast::cast_felt;
    use openzeppelin::math::u256 as u256_lib;
    use super::resolution_verifier::ResolutionVerifier;

    // Market status constants
    const PENDING: felt252 = 0;
    const PROPOSED: felt252 = 1;
    const RESOLVED: felt252 = 2;
    const VOIDED: felt252 = 3;

    // Dispute window in seconds (5 minutes for testing)
    const DISPUTE_WINDOW_SECONDS: u64 = 300;

    // Single centralized reporter address for v0
    // Using a sample address - in production this should be set properly
    const REPORTER: felt252 = 0x123456789012345678901234567890123456789012345678901234567890123;

    // Default bond amounts for v0
    const DEFAULT_MIN_PROPOSER_BOND: u256_lib::U256 = u256_lib::U256 { low: 100, high: 0 };  // 100 USDC
    const DEFAULT_MIN_DISPUTE_BOND: u256_lib::U256 = u256_lib::U256 { low: 200, high: 0 };   // 200 USDC

    #[storage]
    struct Storage {
        // map market_id -> Market struct
        markets: Map<felt252, Market>,
        // Config
        min_proposer_bond: u256_lib::U256,
        min_dispute_bond: u256_lib::U256,
        arbiter: starknet::ContractAddress,
        // Fast-finalize config
        fast_finalize_enabled: bool,
    }

    #[derive(Drop, CairoShape)]
    struct Market {
        proposer: starknet::ContractAddress,
        proposer_bond: u256_lib::U256,
        outcome: felt252,
        disputed: bool,
        dispute_bond: u256_lib::U256,
        dispute_resolved: bool,
        data_hash: felt252,
        data_uri: felt252,
        proposed_at: u64,
        resolved_at: u64,
        status: felt252,
        // Fast-finalize fields
        fast_path: bool,
        proof_hash: felt252,
    }

    #[external]
    #[init]
    fn constructor(ref self: ContractState) {
        self.min_proposer_bond.write(DEFAULT_MIN_PROPOSER_BOND);
        self.min_dispute_bond.write(DEFAULT_MIN_DISPUTE_BOND);
        // Set arbiter to a default address for v0 (can be updated later)
        let arbiter_addr = starknet::ContractAddress::from(0x123456789012345678901234567890123456789012345678901234567890123);
        self.arbiter.write(arbiter_addr);
        // Enable fast-finalize for v0 (but proofs are stubbed)
        self.fast_finalize_enabled.write(true);
    }

    #[external]
    fn propose(
        ref self: T,
        market_id: felt252,
        outcome: felt252,
        data_hash: felt252,
        data_uri: felt252,
        bond: u256_lib::U256
    ) {
        let caller = get_caller_address();
        
        // Only allow the authorized reporter to propose
        let reporter_felt = cast_felt(REPORTER);
        assert(caller.value == reporter_felt, 'Unauthorized: only reporter can propose');
        
        // Verify bond meets minimum requirement
        let min_bond = self.min_proposer_bond.read();
        assert(u256_lib::U256_gte(bond, min_bond), 'Bond too low: must be >= min_proposer_bond');
        
        let existing_market = self.markets.read(market_id);
        // If market exists and is not pending, reject
        assert(existing_market.status == PENDING, 'Market already proposed');

        let market = Market {
            proposer: caller,
            proposer_bond: bond,
            outcome: outcome,
            disputed: false,
            dispute_bond: u256_lib::U256 { low: 0, high: 0 },
            dispute_resolved: false,
            data_hash: data_hash,
            data_uri: data_uri,
            proposed_at: starknet::block_timestamp(),
            resolved_at: 0,
            status: PROPOSED,
        };
        
        self.markets.write(market_id, market);
    }

    #[external]
    fn dispute(ref self: T, market_id: felt252, bond: u256_lib::U256) {
        let caller = get_caller_address();
        
        let market = self.markets.read(market_id);
        
        // Market must be in Proposed status
        assert(market.status == PROPOSED, 'Market is not in Proposed state');
        
        // Market must not already be disputed
        assert(!market.disputed, 'Market is already disputed');
        
        // Verify bond meets minimum requirement
        let min_dispute_bond = self.min_dispute_bond.read();
        assert(u256_lib::U256_gte(bond, min_dispute_bond), 'Dispute bond too low: must be >= min_dispute_bond');
        
        let mut updated_market = market;
        updated_market.disputed = true;
        updated_market.dispute_bond = bond;
        updated_market.proposer_bond = market.proposer_bond;  // Store proposer bond for later
        
        self.markets.write(market_id, updated_market);
    }

    #[external]
    fn finalize(ref self: T, market_id: felt252) {
        let market = self.markets.read(market_id);
        
        // Market must be in Proposed status
        assert(market.status == PROPOSED, 'Market is not in Proposed state');
        
        // Market must not be disputed
        assert(!market.disputed, 'Market is disputed: must go through arbitration');
        
        let current_time = starknet::block_timestamp();
        let time_since_proposal = current_time - market.proposed_at;
        
        // Must wait for dispute window to pass
        assert(time_since_proposal >= DISPUTE_WINDOW_SECONDS, 'Dispute window not passed');
        
        let mut updated_market = market;
        updated_market.status = RESOLVED;
        updated_market.resolved_at = current_time;
        
        self.markets.write(market_id, updated_market);
    }

    #[external]
    fn resolve_arbitration(ref self: T, market_id: felt252, outcome: felt252) {
        let caller = get_caller_address();
        
        let market = self.markets.read(market_id);
        
        // Market must be disputed
        assert(market.disputed, 'Market is not disputed');
        
        // Only the arbiter can resolve
        let arbiter = self.arbiter.read();
        assert(caller.value == arbiter.value, 'Unauthorized: only arbiter can resolve');
        
        let mut updated_market = market;
        updated_market.outcome = outcome;
        updated_market.disputed = false;
        updated_market.dispute_resolved = true;
        updated_market.status = RESOLVED;
        updated_market.resolved_at = starknet::block_timestamp();
        
        self.markets.write(market_id, updated_market);
    }

    #[external]
    fn propose_with_proof(
        ref self: T,
        market_id: felt252,
        outcome: felt252,
        data_hash: felt252,
        zk_proof: Span<felt252>
    ) {
        let caller = get_caller_address();
        
        // Only allow the authorized reporter to propose
        let reporter_felt = cast_felt(REPORTER);
        assert(caller.value == reporter_felt, 'Unauthorized: only reporter can propose');
        
        // Verify bond meets minimum requirement
        let min_bond = self.min_proposer_bond.read();
        let proposer_bond = min_bond;  // Use minimum for fast-finalize (no bond needed for proof)
        
        let existing_market = self.markets.read(market_id);
        // If market exists and is not pending, reject
        assert(existing_market.status == PENDING, 'Market already proposed');
        
        // Verify proof is not too large (basic validation - in production, verify SNARK)
        let proof_len = zk_proof.len();
        assert(proof_len > 0 && proof_len <= 1000, 'Invalid ZK proof size');
        
        // Compute proof hash for storage
        let proof_hash = Self::compute_proof_hash(zk_proof);
        
        // Verify ZK proof (stubbed for v0 - always succeeds)
        // In production, this would call the ResolutionVerifier contract
        let verified = Self::verify_zk_proof(market_id, outcome, zk_proof);
        assert(verified, 'Invalid ZK proof');
        
        let market = Market {
            proposer: caller,
            proposer_bond: proposer_bond,
            outcome: outcome,
            disputed: false,
            dispute_bond: u256_lib::U256 { low: 0, high: 0 },
            dispute_resolved: false,
            data_hash: data_hash,
            data_uri: data_uri,
            proposed_at: starknet::block_timestamp(),
            resolved_at: 0,
            status: PROPOSED,
            fast_path: true,  // Mark as fast-path market
            proof_hash: proof_hash,
        };
        
        self.markets.write(market_id, market);
    }

    /// Fast-finalize a market using ZK proof (skips dispute window)
    /// Only works if:
    /// 1. Fast-finalize is enabled
    /// 2. Market was proposed with proof (fast_path = true)
    /// 3. ZK proof was verified during propose
    #[external]
    fn fast_finalize(ref self: T, market_id: felt252) {
        let market = self.markets.read(market_id);
        
        // Check fast-finalize is enabled
        let fast_enabled = self.fast_finalize_enabled.read();
        assert(fast_enabled, 'Fast-finalize not enabled');
        
        // Market must be in Proposed status
        assert(market.status == PROPOSED, 'Market is not in Proposed state');
        
        // Market must be using fast-path (was proposed with proof)
        assert(market.fast_path, 'Market is not using fast path: call propose_with_proof first');
        
        // Verify proof was recorded during propose
        assert(market.proof_hash != 0, 'Proof hash not recorded');
        
        // No dispute window check needed - fast-finalize skips it
        let current_time = starknet::block_timestamp();
        
        let mut updated_market = market;
        updated_market.status = RESOLVED;
        updated_market.resolved_at = current_time;
        
        self.markets.write(market_id, updated_market);
    }

    #[external]
    fn get_market_status(self: @T, market_id: felt252) -> felt252 {
        let market = self.markets.read(market_id);
        market.status
    }

    #[external]
    fn is_disputed(self: @T, market_id: felt252) -> bool {
        let market = self.markets.read(market_id);
        market.disputed
    }

    /// Verify ZK proof (stubbed for v0)
    /// @param market_id The market ID
    /// @param outcome The claimed outcome
    /// @param proof The ZK proof
    /// @return verified True if proof is valid
    fn verify_zk_proof(
        market_id: felt252,
        outcome: felt252,
        proof: Span<felt252>
    ) -> bool {
        // For v0: ZK proof verification is stubbed (always returns true)
        // The actual verification logic would be in the ResolutionVerifier contract
        // 
        // In production, this would:
        // 1. Hash the proof using pedersen
        // 2. Call ResolutionVerifier::verify_resolution_proof()
        // 3. Or implement actual SNARK verification using pedersen, poseidon, etc.
        
        true  // Stubbed - always verify
    }

    /// Compute hash of a ZK proof for storage
    /// @param proof The ZK proof
    /// @return hash The hash of the proof
    fn compute_proof_hash(proof: Span<felt252>) -> felt252 {
        let mut hasher = starknet::pedersen::Pedersen::new();
        
        proof.for_each(|p| {
            hasher.update(p);
        });
        
        hasher.finalize()
    }
}
