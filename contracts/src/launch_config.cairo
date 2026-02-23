// LaunchConfig - Testnet launch parameters for controlled rollout

#[starknet::contract]
mod LaunchConfig {
    use starknet::storage::Map;
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;

    const PHASE_SEED: felt252 = 1;
    const PHASE_CONTROLLED: felt252 = 2;
    const PHASE_OPEN: felt252 = 3;

    #[storage]
    struct Storage {
        owner: felt252,
        current_phase: felt252,
        max_bet_size: u256,
        max_total_volume: u256,
        b_parameter: u256,
        allowlist_enabled: bool,
        allowed_traders: Map<felt252, bool>,
        allowed_lps: Map<felt252, bool>,
        max_markets: u256,
        active_market_count: u256,
        permissionless_reporting: bool,
        dispute_enabled: bool,
        total_traders: u256,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        let caller: felt252 = starknet::get_caller_address().into();
        self.owner.write(caller);
        
        self.current_phase.write(PHASE_SEED);
        self.max_bet_size.write(u256 { low: 100000000000000000, high: 0 });
        self.max_total_volume.write(u256 { low: 1000000000000000000, high: 0 });
        self.b_parameter.write(u256 { low: 1000, high: 0 });
        self.allowlist_enabled.write(true);
        self.max_markets.write(4);
        self.active_market_count.write(0);
        self.permissionless_reporting.write(false);
        self.dispute_enabled.write(false);
        self.total_traders.write(0);
    }

    #[external(v0)]
    fn transfer_ownership(ref self: ContractState, new_owner: felt252) {
        let current = self.owner.read();
        let caller: felt252 = starknet::get_caller_address().into();
        assert(caller == current, 'Not owner');
        self.owner.write(new_owner);
    }

    #[external(v0)]
    fn set_phase(ref self: ContractState, phase: felt252) {
        let current = self.owner.read();
        let caller: felt252 = starknet::get_caller_address().into();
        assert(caller == current, 'Not owner');
        self.current_phase.write(phase);
    }

    #[external(v0)]
    fn enable_controlled(ref self: ContractState) {
        let current = self.owner.read();
        let caller: felt252 = starknet::get_caller_address().into();
        assert(caller == current, 'Not owner');
        self.current_phase.write(PHASE_CONTROLLED);
    }

    #[external(v0)]
    fn enable_open(ref self: ContractState) {
        let current = self.owner.read();
        let caller: felt252 = starknet::get_caller_address().into();
        assert(caller == current, 'Not owner');
        self.current_phase.write(PHASE_OPEN);
    }

    #[external(v0)]
    fn set_limits(ref self: ContractState, max_bet: u256, max_volume: u256, b: u256) {
        let current = self.owner.read();
        let caller: felt252 = starknet::get_caller_address().into();
        assert(caller == current, 'Not owner');
        self.max_bet_size.write(max_bet);
        self.max_total_volume.write(max_volume);
        self.b_parameter.write(b);
    }

    #[external(v0)]
    fn add_lp(ref self: ContractState, lp: felt252) {
        let current = self.owner.read();
        let caller: felt252 = starknet::get_caller_address().into();
        assert(caller == current, 'Not owner');
        self.allowed_lps.write(lp, true);
    }

    #[external(v0)]
    fn remove_lp(ref self: ContractState, lp: felt252) {
        let current = self.owner.read();
        let caller: felt252 = starknet::get_caller_address().into();
        assert(caller == current, 'Not owner');
        self.allowed_lps.write(lp, false);
    }

    #[external(v0)]
    fn add_trader(ref self: ContractState, trader: felt252) {
        let current = self.owner.read();
        let caller: felt252 = starknet::get_caller_address().into();
        assert(caller == current, 'Not owner');
        self.allowed_traders.write(trader, true);
        let count = self.total_traders.read();
        self.total_traders.write(count + u256 { low: 1, high: 0 });
    }

    #[external(v0)]
    fn remove_trader(ref self: ContractState, trader: felt252) {
        let current = self.owner.read();
        let caller: felt252 = starknet::get_caller_address().into();
        assert(caller == current, 'Not owner');
        self.allowed_traders.write(trader, false);
    }

    #[external(v0)]
    fn toggle_allowlist(ref self: ContractState, enabled: bool) {
        let current = self.owner.read();
        let caller: felt252 = starknet::get_caller_address().into();
        assert(caller == current, 'Not owner');
        self.allowlist_enabled.write(enabled);
    }

    #[external(v0)]
    fn enable_permissionless_reporting(ref self: ContractState) {
        let current = self.owner.read();
        let caller: felt252 = starknet::get_caller_address().into();
        assert(caller == current, 'Not owner');
        self.permissionless_reporting.write(true);
    }

    #[external(v0)]
    fn enable_disputes(ref self: ContractState) {
        let current = self.owner.read();
        let caller: felt252 = starknet::get_caller_address().into();
        assert(caller == current, 'Not owner');
        self.dispute_enabled.write(true);
    }

    #[external(v0)]
    fn can_trade(self: @ContractState, trader: felt252) -> bool {
        let phase = self.current_phase.read();
        
        if phase == PHASE_SEED {
            return self.allowed_lps.read(trader);
        }
        
        if phase == PHASE_CONTROLLED {
            if self.allowlist_enabled.read() {
                let is_allowed = self.allowed_traders.read(trader);
                let is_lp = self.allowed_lps.read(trader);
                return is_allowed | is_lp;
            }
            return true;
        }
        
        true
    }

    #[external(v0)]
    fn get_phase(self: @ContractState) -> felt252 {
        self.current_phase.read()
    }

    #[external(v0)]
    fn get_max_bet_size(self: @ContractState) -> u256 {
        self.max_bet_size.read()
    }

    #[external(v0)]
    fn get_b_parameter(self: @ContractState) -> u256 {
        self.b_parameter.read()
    }

    #[external(v0)]
    fn is_allowlist_enabled(self: @ContractState) -> bool {
        self.allowlist_enabled.read()
    }

    #[external(v0)]
    fn is_allowed_lp(self: @ContractState, lp: felt252) -> bool {
        self.allowed_lps.read(lp)
    }

    #[external(v0)]
    fn get_total_traders(self: @ContractState) -> u256 {
        self.total_traders.read()
    }
}
