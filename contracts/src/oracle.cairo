// Simplified Optimistic Oracle - Cairo 2.x compatible

#[starknet::contract]
mod OptimisticOracle {
    use starknet::ContractAddress;
    use starknet::get_caller_address;
    use starknet::get_block_info;
    use starknet::storage::Map;

    const PENDING: felt252 = 0;
    const PROPOSED: felt252 = 1;
    const RESOLVED: felt252 = 2;

    #[storage]
    struct Storage {
        // Individual storage vars instead of struct in Map
        market_proposer: Map<felt252, ContractAddress>,
        market_outcome: Map<felt252, felt252>,
        market_disputed: Map<felt252, bool>,
        market_status: Map<felt252, felt252>,
        market_proposed_at: Map<felt252, u64>,
        min_proposer_bond: u64,
        min_dispute_bond: u64,
        arbiter: ContractAddress,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        self.min_proposer_bond.write(100);
        self.min_dispute_bond.write(200);
        let arbiter_addr: ContractAddress = 0x123456789012345678901234567890123456789012345678901234567890123.try_into().unwrap();
        self.arbiter.write(arbiter_addr);
    }

    #[external(v0)]
    fn propose(
        ref self: ContractState,
        market_id: felt252,
        outcome: felt252,
        data_hash: felt252,
        bond: u64
    ) {
        let caller = get_caller_address();
        let min_bond = self.min_proposer_bond.read();
        assert(bond >= min_bond, 'Bond too low');
        
        let status = self.market_status.read(market_id);
        assert(status == PENDING, 'Market already proposed');

        self.market_proposer.write(market_id, caller);
        self.market_outcome.write(market_id, outcome);
        self.market_disputed.write(market_id, false);
        self.market_status.write(market_id, PROPOSED);
        
        let block_info = get_block_info().unbox();
        self.market_proposed_at.write(market_id, block_info.block_timestamp);
    }

    #[external(v0)]
    fn dispute(ref self: ContractState, market_id: felt252, bond: u64) {
        let min_bond = self.min_dispute_bond.read();
        assert(bond >= min_bond, 'Dispute bond too low');
        
        let status = self.market_status.read(market_id);
        assert(status == PROPOSED, 'Market not in Proposed state');
        
        self.market_disputed.write(market_id, true);
    }

    #[external(v0)]
    fn finalize(ref self: ContractState, market_id: felt252) {
        let status = self.market_status.read(market_id);
        assert(status == PROPOSED, 'Market not in Proposed state');
        
        let disputed = self.market_disputed.read(market_id);
        assert(!disputed, 'Market is disputed');
        
        self.market_status.write(market_id, RESOLVED);
    }

    #[external(v0)]
    fn get_market_status(self: @ContractState, market_id: felt252) -> felt252 {
        self.market_status.read(market_id)
    }

    #[external(v0)]
    fn is_disputed(self: @ContractState, market_id: felt252) -> bool {
        self.market_disputed.read(market_id)
    }
}
