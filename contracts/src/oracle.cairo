#[starknet::interface]
pub trait IOptimisticOracle {
    fn propose(
        ref self: ContractState,
        market_id: felt252,
        outcome: felt252,
        data_hash: felt252,
        data_uri: felt252,
        bond: u256_lib::U256
    );
    fn dispute(ref self: ContractState, market_id: felt252, bond: u256_lib::U256);
    fn finalize(ref self: ContractState, market_id: felt252);
    fn resolve_arbitration(ref self: ContractState, market_id: felt252, outcome: felt252);
    fn get_market_status(self: @ContractState, market_id: felt252) -> felt252;
    fn propose_with_proof(
        ref self: ContractState,
        market_id: felt252,
        outcome: felt252,
        data_hash: felt252,
        zk_proof: Span<felt252>
    );
    fn is_disputed(self: @ContractState, market_id: felt252) -> bool;
}

#[starknet::contract]
mod OptimisticOracle {
    use starknet::SyscallResult;
    use starknet::{get_caller_address, StorageAddress, get_contract_address};
    use starknet::cast::cast_felt;
    use openzeppelin::math::u256 as u256_lib;

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
    }

    #[external]
    #[init]
    fn constructor(ref self: ContractState) {
        self.min_proposer_bond.write(DEFAULT_MIN_PROPOSER_BOND);
        self.min_dispute_bond.write(DEFAULT_MIN_DISPUTE_BOND);
        // Set arbiter to a default address for v0 (can be updated later)
        let arbiter_addr = starknet::ContractAddress::from(0x123456789012345678901234567890123456789012345678901234567890123);
        self.arbiter.write(arbiter_addr);
    }

    #[external]
    fn propose(
        ref self: ContractState,
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
    fn dispute(ref self: ContractState, market_id: felt252, bond: u256_lib::U256) {
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
    fn finalize(ref self: ContractState, market_id: felt252) {
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
    fn resolve_arbitration(ref self: ContractState, market_id: felt252, outcome: felt252) {
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
        ref self: ContractState,
        market_id: felt252,
        outcome: felt252,
        data_hash: felt252,
        zk_proof: Span<felt252>
    ) {
        // Stub for ZK proof integration - for v0, just call regular propose
        // ZK proofs can be verified off-chain or integrated in future versions
        
        // For now, just validate the proof is not too large
        // In production, this would verify the ZK proof
        let proof_len = zk_proof.len();
        assert(proof_len <= 1000, 'ZK proof too large');
        
        // The actual propose logic would be called here
        // For v0, we just allow the call to succeed as a stub
    }

    #[external]
    fn get_market_status(self: @ContractState, market_id: felt252) -> felt252 {
        let market = self.markets.read(market_id);
        market.status
    }

    #[external]
    fn is_disputed(self: @ContractState, market_id: felt252) -> bool {
        let market = self.markets.read(market_id);
        market.disputed
    }
}
