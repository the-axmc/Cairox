// CairoxOracle - Growthepie integration for ecosystem metrics

#[starknet::contract]
mod CairoxOracle {
    use starknet::storage::Map;
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;

    const METRIC_DAW: felt252 = 1;
    const METRIC_TXS: felt252 = 2;
    const METRIC_CONTRACTS: felt252 = 3;
    const METRIC_TOKENS: felt252 = 4;

    #[storage]
    struct Storage {
        owner: felt252,
        latest_values: Map<felt252, u256>,
        last_updated: Map<felt252, u256>,
        update_count: Map<felt252, u256>,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        self.owner.write(0);
    }

    #[external(v0)]
    fn update_value(ref self: ContractState, metric_id: felt252, value: u256) {
        self.latest_values.write(metric_id, value);
        let timestamp: u256 = starknet::get_block_timestamp().into();
        self.last_updated.write(metric_id, timestamp);
        
        let count = self.update_count.read(metric_id);
        self.update_count.write(metric_id, count + u256 { low: 1, high: 0 });
    }

    #[external(v0)]
    fn get_latest_value(self: @ContractState, metric_id: felt252) -> u256 {
        self.latest_values.read(metric_id)
    }

    #[external(v0)]
    fn get_last_updated(self: @ContractState, metric_id: felt252) -> u256 {
        self.last_updated.read(metric_id)
    }

    #[external(v0)]
    fn get_update_count(self: @ContractState, metric_id: felt252) -> u256 {
        self.update_count.read(metric_id)
    }

    #[external(v0)]
    fn get_daw(self: @ContractState) -> u256 {
        self.latest_values.read(METRIC_DAW)
    }

    #[external(v0)]
    fn get_transaction_count(self: @ContractState) -> u256 {
        self.latest_values.read(METRIC_TXS)
    }
}
