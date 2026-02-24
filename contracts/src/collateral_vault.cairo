// CollateralVault - User deposits and balance management

#[starknet::contract]
mod CollateralVault {
    use starknet::storage::Map;
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;

    #[storage]
    struct Storage {
        owner: felt252,
        pending_owner: felt252,
        balances: Map<felt252, u256>,
        total_deposited: u256,
        paused: bool,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        let caller: felt252 = starknet::get_caller_address().into();
        self.owner.write(caller);
        self.pending_owner.write(0);
        self.total_deposited.write(u256 { low: 0, high: 0 });
        self.paused.write(false);
    }

    // Ownership transfer
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
        assert(caller == pending, 'Not pending owner');
        self.owner.write(pending);
        self.pending_owner.write(0);
    }

    // Pause/unpause
    #[external(v0)]
    fn pause(ref self: ContractState) {
        let current = self.owner.read();
        let caller: felt252 = starknet::get_caller_address().into();
        assert(caller == current, 'Not owner');
        self.paused.write(true);
    }

    #[external(v0)]
    fn unpause(ref self: ContractState) {
        let current = self.owner.read();
        let caller: felt252 = starknet::get_caller_address().into();
        assert(caller == current, 'Not owner');
        self.paused.write(false);
    }

    #[external(v0)]
    fn deposit(ref self: ContractState, amount: u256) {
        assert(!self.paused.read(), 'Paused');
        
        let caller: felt252 = starknet::get_caller_address().into();
        let current = self.balances.read(caller);
        self.balances.write(caller, current + amount);
        
        let total = self.total_deposited.read();
        self.total_deposited.write(total + amount);
    }

    #[external(v0)]
    fn withdraw(ref self: ContractState, amount: u256) {
        assert(!self.paused.read(), 'Paused');
        
        let caller: felt252 = starknet::get_caller_address().into();
        let current = self.balances.read(caller);
        assert(current >= amount, 'Insufficient balance');
        
        self.balances.write(caller, current - amount);
        
        let total = self.total_deposited.read();
        self.total_deposited.write(total - amount);
    }

    #[external(v0)]
    fn get_balance(self: @ContractState, user: felt252) -> u256 {
        self.balances.read(user)
    }

    #[external(v0)]
    fn get_total_deposited(self: @ContractState) -> u256 {
        self.total_deposited.read()
    }

    #[external(v0)]
    fn get_owner(self: @ContractState) -> felt252 {
        self.owner.read()
    }

    #[external(v0)]
    fn is_paused(self: @ContractState) -> bool {
        self.paused.read()
    }
}
