// Dummy Market Contract for testing Cairox infrastructure
// This contract simulates market creation and management

#[starknet::interface]
pub trait IDummyContract {
    fn get_value(self: @DummyContractState) -> u64;
    fn set_value(ref self: DummyContractState, value: u64);
    fn get_market_count(self: @DummyContractState) -> u64;
    fn create_market(ref self: DummyContractState, market_id: felt252);
}

#[contract]
mod DummyContract {
    use starknet::SyscallResult;
    use starknet::get_caller_address;

    #[storage]
    struct Storage {
        value: u64,
        market_count: u64,
        markets: Map<felt252, bool>,
    }

    #[constructor]
    fn constructor(ref self: DummyContractState) {
        self.value.set(42);
        self.market_count.set(0);
    }

    #[external]
    fn get_value(self: @DummyContractState) -> u64 {
        self.value.read()
    }

    #[external]
    fn set_value(ref self: DummyContractState, value: u64) {
        self.value.write(value);
    }

    #[external]
    fn get_market_count(self: @DummyContractState) -> u64 {
        self.market_count.read()
    }

    #[external]
    fn create_market(ref self: DummyContractState, market_id: felt252) {
        self.markets.write(market_id, true);
        self.market_count.write(self.market_count.read() + 1);
    }
}
