// Arbitration - Dispute resolution for markets

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
        // market_address -> dispute_status
        disputes: Map<felt252, felt252>,
        // market_address -> resolution
        resolutions: Map<felt252, felt252>,
        // market_address -> dispute_count
        dispute_count: Map<felt252, u256>,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        self.owner.write(0);
    }

    #[external(v0)]
    fn raise_dispute(ref self: ContractState, market: felt252, reason: felt252) {
        let count = self.dispute_count.read(market);
        self.dispute_count.write(market, count + u256 { low: 1, high: 0 });
        self.disputes.write(market, STATUS_PENDING);
    }

    #[external(v0)]
    fn resolve_dispute(ref self: ContractState, market: felt252, outcome: felt252) {
        assert(self.disputes.read(market) == STATUS_PENDING, 'Not pending');
        self.disputes.write(market, STATUS_RESOLVED);
        self.resolutions.write(market, outcome);
    }

    #[external(v0)]
    fn get_dispute_status(self: @ContractState, market: felt252) -> felt252 {
        self.disputes.read(market)
    }

    #[external(v0)]
    fn get_resolution(self: @ContractState, market: felt252) -> felt252 {
        self.resolutions.read(market)
    }
}
