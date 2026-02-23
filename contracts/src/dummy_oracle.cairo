// DummyOracle - Test helper for ResolutionVerifier

#[starknet::contract]
mod DummyOracle {
    use starknet::storage::Map;
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;

    #[storage]
    struct Storage {
        data_hash: Map<felt252, felt252>,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {}

    #[external(v0)]
    fn set_data_hash(ref self: ContractState, market_id: felt252, data_hash: felt252) {
        self.data_hash.write(market_id, data_hash);
    }

    #[external(v0)]
    fn get_data_hash(self: @ContractState, market_id: felt252) -> felt252 {
        self.data_hash.read(market_id)
    }
}
