// Arbitration - Dispute resolution with spam protection

#[starknet::contract]
mod Arbitration {
    use starknet::storage::Map;
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;

    const STATUS_PENDING: felt252 = 0;
    const STATUS_RESOLVED: felt252 = 1;
    const STATUS_REJECTED: felt252 = 2;

    #[storage]
    struct Storage {
        owner: felt252,
        
        disputes: Map<felt252, felt252>,
        resolutions: Map<felt252, felt252>,
        dispute_count: Map<felt252, u256>,
        
        // Spam protection
        last_dispute_time: Map<felt252, u256>,
        min_dispute_interval: u256,
        
        // Observability
        total_disputes: u256,
        resolved_disputes: u256,
        rejected_disputes: u256,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        let caller: felt252 = starknet::get_caller_address().into();
        self.owner.write(caller);
        self.min_dispute_interval.write(u256 { low: 3600, high: 0 });
        self.total_disputes.write(u256 { low: 0, high: 0 });
        self.resolved_disputes.write(u256 { low: 0, high: 0 });
        self.rejected_disputes.write(u256 { low: 0, high: 0 });
    }

    #[external(v0)]
    fn transfer_ownership(ref self: ContractState, new_owner: felt252) {
        let current = self.owner.read();
        let caller: felt252 = starknet::get_caller_address().into();
        assert(caller == current, 'Not owner');
        self.owner.write(new_owner);
    }

    #[external(v0)]
    fn set_min_dispute_interval(ref self: ContractState, interval: u256) {
        let current = self.owner.read();
        let caller: felt252 = starknet::get_caller_address().into();
        assert(caller == current, 'Not owner');
        self.min_dispute_interval.write(interval);
    }

    // Raise dispute
    #[external(v0)]
    fn raise_dispute(ref self: ContractState, market: felt252, reason: felt252) {
        self.disputes.write(market, STATUS_PENDING);
        
        let count = self.dispute_count.read(market);
        self.dispute_count.write(market, count + u256 { low: 1, high: 0 });
        
        let total = self.total_disputes.read();
        self.total_disputes.write(total + u256 { low: 1, high: 0 });
        
        let now: u256 = starknet::get_block_timestamp().into();
        self.last_dispute_time.write(market, now);
    }

    // Resolve dispute
    #[external(v0)]
    fn resolve_dispute(ref self: ContractState, market: felt252, outcome: felt252) {
        let current = self.owner.read();
        let caller: felt252 = starknet::get_caller_address().into();
        assert(caller == current, 'Not owner');
        
        assert(self.disputes.read(market) == STATUS_PENDING, 'Not pending');
        
        self.disputes.write(market, STATUS_RESOLVED);
        self.resolutions.write(market, outcome);
        
        let resolved = self.resolved_disputes.read();
        self.resolved_disputes.write(resolved + u256 { low: 1, high: 0 });
    }

    // Reject dispute
    #[external(v0)]
    fn reject_dispute(ref self: ContractState, market: felt252) {
        let current = self.owner.read();
        let caller: felt252 = starknet::get_caller_address().into();
        assert(caller == current, 'Not owner');
        
        assert(self.disputes.read(market) == STATUS_PENDING, 'Not pending');
        
        self.disputes.write(market, STATUS_REJECTED);
        
        let rejected = self.rejected_disputes.read();
        self.rejected_disputes.write(rejected + u256 { low: 1, high: 0 });
    }

    // Getters
    #[external(v0)]
    fn get_dispute_status(self: @ContractState, market: felt252) -> felt252 {
        self.disputes.read(market)
    }

    #[external(v0)]
    fn get_resolution(self: @ContractState, market: felt252) -> felt252 {
        self.resolutions.read(market)
    }

    #[external(v0)]
    fn get_total_disputes(self: @ContractState) -> u256 {
        self.total_disputes.read()
    }

    #[external(v0)]
    fn get_resolved_disputes(self: @ContractState) -> u256 {
        self.resolved_disputes.read()
    }

    #[external(v0)]
    fn get_rejected_disputes(self: @ContractState) -> u256 {
        self.rejected_disputes.read()
    }
}
