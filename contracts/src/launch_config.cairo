// LaunchConfig - Testnet launch parameters for controlled rollout

#[starknet::contract]
mod LaunchConfig {
    use core::box::BoxTrait;
    use starknet::storage::Map;
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;
    use starknet::ContractAddress;
    use starknet::SyscallResultTrait;
    use starknet::class_hash::ClassHash;
    use starknet::syscalls::replace_class_syscall;

    const PHASE_SEED: felt252 = 1;
    const PHASE_CONTROLLED: felt252 = 2;
    const PHASE_OPEN: felt252 = 3;

    #[storage]
    struct Storage {
        owner: felt252,
        market_factory: felt252,
        current_phase: felt252,
        max_bet_size: u256,
        max_total_volume: u256,
        b_parameter: u256,
        allowlist_enabled: bool,
        allowed_traders: Map<felt252, u8>,
        allowed_lps: Map<felt252, u8>,
        max_markets: u256,
        active_market_count: u256,
        permissionless_reporting: bool,
        dispute_enabled: bool,
        total_traders: u256,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        OwnershipTransferred: OwnershipTransferred,
        PhaseSet: PhaseSet,
        LimitsSet: LimitsSet,
        AllowlistToggled: AllowlistToggled,
        TraderAllowed: TraderAllowed,
        TraderRemoved: TraderRemoved,
        LpAllowed: LpAllowed,
        LpRemoved: LpRemoved,
        PermissionlessReportingEnabled: PermissionlessReportingEnabled,
        DisputesEnabled: DisputesEnabled,
        Upgraded: Upgraded,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct OwnershipTransferred {
        #[key]
        previous_owner: felt252,
        #[key]
        new_owner: felt252,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct PhaseSet {
        phase: felt252,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct LimitsSet {
        max_bet: u256,
        max_volume: u256,
        b_param: u256,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct AllowlistToggled {
        enabled: bool,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct TraderAllowed {
        #[key]
        trader: felt252,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct TraderRemoved {
        #[key]
        trader: felt252,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct LpAllowed {
        #[key]
        lp: felt252,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct LpRemoved {
        #[key]
        lp: felt252,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct PermissionlessReportingEnabled {}

    #[derive(Copy, Drop, starknet::Event)]
    struct DisputesEnabled {}

    #[derive(Copy, Drop, starknet::Event)]
    struct Upgraded {
        class_hash: ClassHash,
    }
    #[constructor]
    fn constructor(ref self: ContractState) {
        let owner = deployer_felt();
        self.owner.write(owner);
        self.market_factory.write(0);
        
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
        self.emit(OwnershipTransferred { previous_owner: current, new_owner });
    }

    #[external(v0)]
    fn set_market_factory(ref self: ContractState, factory: felt252) {
        let current = self.owner.read();
        let caller: felt252 = starknet::get_caller_address().into();
        assert(caller == current, 'Not owner');
        self.market_factory.write(factory);
    }

    #[external(v0)]
    fn set_phase(ref self: ContractState, phase: felt252) {
        let current = self.owner.read();
        let caller: felt252 = starknet::get_caller_address().into();
        assert(caller == current, 'Not owner');
        self.current_phase.write(phase);
        self.emit(PhaseSet { phase });
    }

    #[external(v0)]
    fn enable_controlled(ref self: ContractState) {
        let current = self.owner.read();
        let caller: felt252 = starknet::get_caller_address().into();
        assert(caller == current, 'Not owner');
        self.current_phase.write(PHASE_CONTROLLED);
        self.emit(PhaseSet { phase: PHASE_CONTROLLED });
    }

    #[external(v0)]
    fn enable_open(ref self: ContractState) {
        let current = self.owner.read();
        let caller: felt252 = starknet::get_caller_address().into();
        assert(caller == current, 'Not owner');
        self.current_phase.write(PHASE_OPEN);
        self.emit(PhaseSet { phase: PHASE_OPEN });
    }

    #[external(v0)]
    fn set_limits(ref self: ContractState, max_bet: u256, max_volume: u256, b: u256) {
        let current = self.owner.read();
        let caller: felt252 = starknet::get_caller_address().into();
        assert(caller == current, 'Not owner');
        self.max_bet_size.write(max_bet);
        self.max_total_volume.write(max_volume);
        self.b_parameter.write(b);
        self.emit(LimitsSet { max_bet, max_volume, b_param: b });
    }

    #[external(v0)]
    fn add_lp(ref self: ContractState, lp: felt252) {
        let current = self.owner.read();
        let caller: felt252 = starknet::get_caller_address().into();
        assert(caller == current, 'Not owner');
        self.allowed_lps.write(lp, 1);
        self.emit(LpAllowed { lp });
    }

    #[external(v0)]
    fn remove_lp(ref self: ContractState, lp: felt252) {
        let current = self.owner.read();
        let caller: felt252 = starknet::get_caller_address().into();
        assert(caller == current, 'Not owner');
        self.allowed_lps.write(lp, 0);
        self.emit(LpRemoved { lp });
    }

    #[external(v0)]
    fn add_trader(ref self: ContractState, trader: felt252) {
        let current = self.owner.read();
        let caller: felt252 = starknet::get_caller_address().into();
        assert(caller == current, 'Not owner');
        self.allowed_traders.write(trader, 1);
        let count = self.total_traders.read();
        self.total_traders.write(count + u256 { low: 1, high: 0 });
        self.emit(TraderAllowed { trader });
    }

    #[external(v0)]
    fn remove_trader(ref self: ContractState, trader: felt252) {
        let current = self.owner.read();
        let caller: felt252 = starknet::get_caller_address().into();
        assert(caller == current, 'Not owner');
        self.allowed_traders.write(trader, 0);
        self.emit(TraderRemoved { trader });
    }

    #[external(v0)]
    fn toggle_allowlist(ref self: ContractState, enabled: bool) {
        let current = self.owner.read();
        let caller: felt252 = starknet::get_caller_address().into();
        assert(caller == current, 'Not owner');
        self.allowlist_enabled.write(enabled);
        self.emit(AllowlistToggled { enabled });
    }

    #[external(v0)]
    fn enable_permissionless_reporting(ref self: ContractState) {
        let current = self.owner.read();
        let caller: felt252 = starknet::get_caller_address().into();
        assert(caller == current, 'Not owner');
        self.permissionless_reporting.write(true);
        self.emit(PermissionlessReportingEnabled {});
    }

    #[external(v0)]
    fn enable_disputes(ref self: ContractState) {
        let current = self.owner.read();
        let caller: felt252 = starknet::get_caller_address().into();
        assert(caller == current, 'Not owner');
        self.dispute_enabled.write(true);
        self.emit(DisputesEnabled {});
    }

    #[external(v0)]
    fn register_market(ref self: ContractState) {
        let caller: felt252 = starknet::get_caller_address().into();
        let owner = self.owner.read();
        let factory = self.market_factory.read();
        assert(caller == owner || caller == factory, 'Not authorized');
        let max_markets = self.max_markets.read();
        let active = self.active_market_count.read();
        if max_markets.low != 0 || max_markets.high != 0 {
            assert(active < max_markets, 'Max markets reached');
        }
        self.active_market_count.write(active + u256 { low: 1, high: 0 });
    }

    #[external(v0)]
    fn can_trade(self: @ContractState, trader: felt252) -> bool {
        let phase = self.current_phase.read();
        
        if phase == PHASE_SEED {
            return self.allowed_lps.read(trader) == 1;
        }
        
        if phase == PHASE_CONTROLLED {
            if self.allowlist_enabled.read() {
                let is_allowed = self.allowed_traders.read(trader);
                let is_lp = self.allowed_lps.read(trader);
                return (is_allowed == 1) || (is_lp == 1);
            }
            return true;
        }
        
        true
    }

    #[external(v0)]
    fn can_create_market(self: @ContractState, creator: felt252) -> bool {
        let max_markets = self.max_markets.read();
        let active = self.active_market_count.read();
        if max_markets.low != 0 || max_markets.high != 0 {
            if active >= max_markets {
                return false;
            }
        }
        can_trade(self, creator)
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
    fn get_max_total_volume(self: @ContractState) -> u256 {
        self.max_total_volume.read()
    }

    #[external(v0)]
    fn get_max_markets(self: @ContractState) -> u256 {
        self.max_markets.read()
    }

    #[external(v0)]
    fn get_active_market_count(self: @ContractState) -> u256 {
        self.active_market_count.read()
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
        self.allowed_lps.read(lp) == 1
    }

    #[external(v0)]
    fn get_total_traders(self: @ContractState) -> u256 {
        self.total_traders.read()
    }

    #[external(v0)]
    fn is_permissionless_reporting(self: @ContractState) -> bool {
        self.permissionless_reporting.read()
    }

    #[external(v0)]
    fn is_dispute_enabled(self: @ContractState) -> bool {
        self.dispute_enabled.read()
    }

    #[external(v0)]
    fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
        let current = self.owner.read();
        let caller: felt252 = starknet::get_caller_address().into();
        assert(caller == current, 'Not owner');
        replace_class_syscall(new_class_hash).unwrap_syscall();
        self.emit(Upgraded { class_hash: new_class_hash });
    }

    fn is_zero_address(addr: ContractAddress) -> bool {
        let felt: felt252 = addr.into();
        felt == 0
    }

    fn deployer_felt() -> felt252 {
        let tx_info = starknet::get_tx_info().unbox();
        tx_info.account_contract_address.into()
    }
}
