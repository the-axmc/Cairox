// CollateralVault - User deposits and balance management

#[starknet::contract]
mod CollateralVault {
    use starknet::storage::Map;
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;

    #[storage]
    struct Storage {
        owner: felt252,
        balances: Map<felt252, u256>,
        total_deposited: u256,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        self.owner.write(0);
        self.total_deposited.write(u256 { low: 0, high: 0 });
    }

    #[external(v0)]
    fn deposit(ref self: ContractState, amount: u256) {
        let caller: felt252 = starknet::get_contract_address().into();
        let current = self.balances.read(caller);
        self.balances.write(caller, current + amount);
        
        let total = self.total_deposited.read();
        self.total_deposited.write(total + amount);
    }

    #[external(v0)]
    fn withdraw(ref self: ContractState, amount: u256) {
        let caller: felt252 = starknet::get_contract_address().into();
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
}
