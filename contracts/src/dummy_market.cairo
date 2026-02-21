// Dummy Market Contract - Cairo 2.x compatible

#[starknet::contract]
mod DummyContract {
    use starknet::storage::Map;

    #[storage]
    struct Storage {
        value: u64,
        market_count: u64,
        markets: Map<felt252, bool>,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        self.value.write(42);
        self.market_count.write(0);
    }

    #[external(v0)]
    fn get_value(self: @ContractState) -> u64 {
        self.value.read()
    }

    #[external(v0)]
    fn set_value(ref self: ContractState, value: u64) {
        self.value.write(value);
    }

    #[external(v0)]
    fn get_market_count(self: @ContractState) -> u64 {
        self.market_count.read()
    }

    #[external(v0)]
    fn create_market(ref self: ContractState, market_id: felt252) {
        self.markets.write(market_id, true);
        self.market_count.write(self.market_count.read() + 1);
    }
}
