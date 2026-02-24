// CairoxOracle - Growthepie integration with safety features

#[starknet::contract]
mod CairoxOracle {
    use starknet::storage::Map;
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;

    const METRIC_DAW: felt252 = 1;
    const METRIC_TXS: felt252 = 2;
    const METRIC_CONTRACTS: felt252 = 3;
    const METRIC_TOKENS: felt252 = 4;

    const STATE_NORMAL: felt252 = 0;
    const STATE_PAUSED: felt252 = 1;

    #[storage]
    struct Storage {
        owner: felt252,
        pending_owner: felt252,
        circuit_state: felt252,
        pause_reason: felt252,
        update_interval: u256,
        authorized_updaters: Map<felt252, u8>,
        latest_values: Map<felt252, u256>,
        last_updated: Map<felt252, u256>,
        update_count: Map<felt252, u256>,
        total_updates: u256,
        failed_updates: u256,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        let caller: felt252 = starknet::get_caller_address().into();
        self.owner.write(caller);
        self.pending_owner.write(0);
        self.circuit_state.write(STATE_NORMAL);
        self.pause_reason.write(0);
        self.update_interval.write(u256 { low: 3600, high: 0 });
        self.authorized_updaters.write(caller, 1);
        self.total_updates.write(u256 { low: 0, high: 0 });
        self.failed_updates.write(u256 { low: 0, high: 0 });
    }

    #[external(v0)]
    fn transfer_ownership(ref self: ContractState, new_owner: felt252) {
        let current = self.owner.read();
        let caller: felt252 = starknet::get_caller_address().into();
        assert(caller == current, 'Not owner');
        self.pending_owner.write(new_owner);
    }

    #[external(v0)]
    fn accept_ownership(ref self: ContractState) {
        let pending = self.pending_owner.read();
        let caller: felt252 = starknet::get_caller_address().into();
        assert(caller == pending, 'Not pending');
        self.owner.write(pending);
        self.pending_owner.write(0);
    }

    #[external(v0)]
    fn pause_oracle(ref self: ContractState, reason: felt252) {
        let current = self.owner.read();
        let caller: felt252 = starknet::get_caller_address().into();
        assert(caller == current, 'Not owner');
        self.circuit_state.write(STATE_PAUSED);
        self.pause_reason.write(reason);
    }

    #[external(v0)]
    fn resume(ref self: ContractState) {
        let current = self.owner.read();
        let caller: felt252 = starknet::get_caller_address().into();
        assert(caller == current, 'Not owner');
        self.circuit_state.write(STATE_NORMAL);
        self.pause_reason.write(0);
    }

    #[external(v0)]
    fn set_update_interval(ref self: ContractState, interval: u256) {
        let current = self.owner.read();
        let caller: felt252 = starknet::get_caller_address().into();
        assert(caller == current, 'Not owner');
        self.update_interval.write(interval);
    }

    #[external(v0)]
    fn add_updater(ref self: ContractState, updater: felt252) {
        let current = self.owner.read();
        let caller: felt252 = starknet::get_caller_address().into();
        assert(caller == current, 'Not owner');
        self.authorized_updaters.write(updater, 1);
    }

    #[external(v0)]
    fn remove_updater(ref self: ContractState, updater: felt252) {
        let current = self.owner.read();
        let caller: felt252 = starknet::get_caller_address().into();
        assert(caller == current, 'Not owner');
        self.authorized_updaters.write(updater, 0);
    }

    #[external(v0)]
    fn update_daw(ref self: ContractState, value: u256) {
        assert(self.circuit_state.read() == STATE_NORMAL, 'Paused');
        let caller: felt252 = starknet::get_caller_address().into();
        let owner = self.owner.read();
        let authorized = self.authorized_updaters.read(caller);
        assert((caller == owner) || (authorized == 1), 'Not authorized');
        
        self.latest_values.write(METRIC_DAW, value);
        let timestamp: u256 = starknet::get_block_timestamp().into();
        self.last_updated.write(METRIC_DAW, timestamp);
        
        let count = self.update_count.read(METRIC_DAW);
        self.update_count.write(METRIC_DAW, count + u256 { low: 1, high: 0 });
        
        let total = self.total_updates.read();
        self.total_updates.write(total + u256 { low: 1, high: 0 });
    }

    #[external(v0)]
    fn update_txs(ref self: ContractState, value: u256) {
        assert(self.circuit_state.read() == STATE_NORMAL, 'Paused');
        let caller: felt252 = starknet::get_caller_address().into();
        let owner = self.owner.read();
        let authorized = self.authorized_updaters.read(caller);
        assert((caller == owner) || (authorized == 1), 'Not authorized');
        
        self.latest_values.write(METRIC_TXS, value);
        let timestamp: u256 = starknet::get_block_timestamp().into();
        self.last_updated.write(METRIC_TXS, timestamp);
        
        let count = self.update_count.read(METRIC_TXS);
        self.update_count.write(METRIC_TXS, count + u256 { low: 1, high: 0 });
        
        let total = self.total_updates.read();
        self.total_updates.write(total + u256 { low: 1, high: 0 });
    }

    #[external(v0)]
    fn update_contracts(ref self: ContractState, value: u256) {
        assert(self.circuit_state.read() == STATE_NORMAL, 'Paused');
        let caller: felt252 = starknet::get_caller_address().into();
        let owner = self.owner.read();
        let authorized = self.authorized_updaters.read(caller);
        assert((caller == owner) || (authorized == 1), 'Not authorized');
        
        self.latest_values.write(METRIC_CONTRACTS, value);
        let timestamp: u256 = starknet::get_block_timestamp().into();
        self.last_updated.write(METRIC_CONTRACTS, timestamp);
        
        let count = self.update_count.read(METRIC_CONTRACTS);
        self.update_count.write(METRIC_CONTRACTS, count + u256 { low: 1, high: 0 });
        
        let total = self.total_updates.read();
        self.total_updates.write(total + u256 { low: 1, high: 0 });
    }

    #[external(v0)]
    fn update_tokens(ref self: ContractState, value: u256) {
        assert(self.circuit_state.read() == STATE_NORMAL, 'Paused');
        let caller: felt252 = starknet::get_caller_address().into();
        let owner = self.owner.read();
        let authorized = self.authorized_updaters.read(caller);
        assert((caller == owner) || (authorized == 1), 'Not authorized');
        
        self.latest_values.write(METRIC_TOKENS, value);
        let timestamp: u256 = starknet::get_block_timestamp().into();
        self.last_updated.write(METRIC_TOKENS, timestamp);
        
        let count = self.update_count.read(METRIC_TOKENS);
        self.update_count.write(METRIC_TOKENS, count + u256 { low: 1, high: 0 });
        
        let total = self.total_updates.read();
        self.total_updates.write(total + u256 { low: 1, high: 0 });
    }

    #[external(v0)]
    fn record_failure(ref self: ContractState) {
        let caller: felt252 = starknet::get_caller_address().into();
        let owner = self.owner.read();
        let authorized = self.authorized_updaters.read(caller);
        assert((caller == owner) || (authorized == 1), 'Not authorized');
        let failed = self.failed_updates.read();
        self.failed_updates.write(failed + u256 { low: 1, high: 0 });
    }

    #[external(v0)]
    fn get_circuit_state(self: @ContractState) -> felt252 {
        self.circuit_state.read()
    }

    #[external(v0)]
    fn get_total_updates(self: @ContractState) -> u256 {
        self.total_updates.read()
    }

    #[external(v0)]
    fn get_failed_updates(self: @ContractState) -> u256 {
        self.failed_updates.read()
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
}
