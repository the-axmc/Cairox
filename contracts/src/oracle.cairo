#[starknet::interface]
pub trait IOptimisticOracle {
    fn propose(
        ref self: ContractState,
        market_id: felt252,
        outcome: felt252,
        data_hash: felt252,
        data_uri: felt252
    );
    fn finalize(ref self: ContractState, market_id: felt252);
    fn get_market_status(self: @ContractState, market_id: felt252) -> felt252;
}

#[starknet::contract]
mod OptimisticOracle {
    use starknet::SyscallResult;
    use starknet::{get_caller_address, StorageAddress};
    use starknet::cast::cast_felt;

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

    #[storage]
    struct Storage {
        // map market_id -> Market struct
        markets: Map<felt252, Market>,
    }

    #[derive(Drop, CairoShape)]
    struct Market {
        proposer: starknet::ContractAddress,
        outcome: felt252,
        data_hash: felt252,
        data_uri: felt252,
        proposed_at: u64,
        resolved_at: u64,
        status: felt252,
    }

    #[external]
    fn propose(
        ref self: ContractState,
        market_id: felt252,
        outcome: felt252,
        data_hash: felt252,
        data_uri: felt252
    ) {
        let caller = get_caller_address();
        
        // Only allow the authorized reporter to propose
        let reporter_felt = cast_felt(REPORTER);
        assert(caller.value == reporter_felt, 'Unauthorized: only reporter can propose');
        
        let existing_market = self.markets.read(market_id);
        // If market exists and is not pending, reject
        assert(existing_market.status == PENDING, 'Market already proposed');

        let market = Market {
            proposer: caller,
            outcome: outcome,
            data_hash: data_hash,
            data_uri: data_uri,
            proposed_at: starknet::block_timestamp(),
            resolved_at: 0,
            status: PROPOSED,
        };
        
        self.markets.write(market_id, market);
    }

    #[external]
    fn finalize(ref self: ContractState, market_id: felt252) {
        let market = self.markets.read(market_id);
        
        // Market must be in Proposed status
        assert(market.status == PROPOSED, 'Market is not in Proposed state');
        
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
    fn get_market_status(self: @ContractState, market_id: felt252) -> felt252 {
        let market = self.markets.read(market_id);
        market.status
    }
}
