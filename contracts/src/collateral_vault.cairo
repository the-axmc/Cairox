// CollateralVault - Manages collateral deposits
#[starknet::contract]
mod CollateralVault {
    use starknet::ContractAddress;
    use starknet::get_caller_address;
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;

    #[storage]
    struct Storage {
        owner: ContractAddress,
        total_deposits: u128,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        self.owner.write(get_caller_address());
        self.total_deposits.write(0);
    }

    #[external(v0)]
    fn deposit(ref self: ContractState, amount: u128) {
        self.total_deposits.write(self.total_deposits.read() + amount);
    }

    #[external(v0)]
    fn withdraw(ref self: ContractState, amount: u128) {
        let total = self.total_deposits.read();
        assert(total >= amount, 'Insufficient');
        self.total_deposits.write(total - amount);
    }

    #[external(v0)]
    fn get_total_deposits(self: @ContractState) -> u128 {
        self.total_deposits.read()
    }
}
