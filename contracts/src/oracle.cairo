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
    fn update_daw(ref self: ContractState, value: u256) {
        self.latest_values.write(METRIC_DAW, value);
        let timestamp: u256 = starknet::get_block_timestamp().into();
        self.last_updated.write(METRIC_DAW, timestamp);
        let count = self.update_count.read(METRIC_DAW);
        self.update_count.write(METRIC_DAW, count + u256 { low: 1, high: 0 });
    }

    #[external(v0)]
    fn update_txs(ref self: ContractState, value: u256) {
        self.latest_values.write(METRIC_TXS, value);
        let timestamp: u256 = starknet::get_block_timestamp().into();
        self.last_updated.write(METRIC_TXS, timestamp);
        let count = self.update_count.read(METRIC_TXS);
        self.update_count.write(METRIC_TXS, count + u256 { low: 1, high: 0 });
    }

    #[external(v0)]
    fn update_contracts(ref self: ContractState, value: u256) {
        self.latest_values.write(METRIC_CONTRACTS, value);
        let timestamp: u256 = starknet::get_block_timestamp().into();
        self.last_updated.write(METRIC_CONTRACTS, timestamp);
        let count = self.update_count.read(METRIC_CONTRACTS);
        self.update_count.write(METRIC_CONTRACTS, count + u256 { low: 1, high: 0 });
    }

    #[external(v0)]
    fn update_tokens(ref self: ContractState, value: u256) {
        self.latest_values.write(METRIC_TOKENS, value);
        let timestamp: u256 = starknet::get_block_timestamp().into();
        self.last_updated.write(METRIC_TOKENS, timestamp);
        let count = self.update_count.read(METRIC_TOKENS);
        self.update_count.write(METRIC_TOKENS, count + u256 { low: 1, high: 0 });
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
    fn get_daw(self: @ContractState) -> u256 {
        self.latest_values.read(METRIC_DAW)
    }

    #[external(v0)]
    fn get_transaction_count(self: @ContractState) -> u256 {
        self.latest_values.read(METRIC_TXS)
    }

    #[external(v0)]
    fn get_contract_activity(self: @ContractState) -> u256 {
        self.latest_values.read(METRIC_CONTRACTS)
    }

    #[external(v0)]
    fn get_token_activity(self: @ContractState) -> u256 {
        self.latest_values.read(METRIC_TOKENS)
    }
}
