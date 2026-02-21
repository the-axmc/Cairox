// CollateralVault - Manages collateral deposits for Cairox markets
use starknet::ContractAddress;
use starknet::get_caller_address;
use starknet::storage::StoragePointerReadAccess;
use starknet::storage::StoragePointerWriteAccess;

#[starknet::contract]
mod CollateralVault {
    use super::*;

    #[storage]
    struct Storage {
        owner: ContractAddress,
        balances: LegacyMap<ContractAddress, u128>,
        allowances: LegacyMap<(ContractAddress, ContractAddress), u128>,
        total_deposits: u128,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        self.owner.write(get_caller_address());
        self.total_deposits.write(0);
    }

    #[external(v0)]
    fn deposit(ref self: ContractState, amount: u128) {
        let caller = get_caller_address();
        let new_balance = self.balances.read(caller) + amount;
        self.balances.write(caller, new_balance);
        self.total_deposits.write(self.total_deposits.read() + amount);
    }

    #[external(v0)]
    fn withdraw(ref self: ContractState, amount: u128) {
        let caller = get_caller_address();
        let balance = self.balances.read(caller);
        assert(balance >= amount, 'Insufficient balance');
        self.balances.write(caller, balance - amount);
        self.total_deposits.write(self.total_deposits.read() - amount);
    }

    #[external(v0)]
    fn pull_to_market(
        ref self: ContractState,
        from: ContractAddress,
        to: ContractAddress,
        amount: u128
    ) {
        let allowance = self.allowances.read((from, to));
        assert(allowance >= amount, 'Insufficient allowance');
        
        let balance = self.balances.read(from);
        assert(balance >= amount, 'Insufficient balance');
        
        self.balances.write(from, balance - amount);
        self.balances.write(to, self.balances.read(to) + amount);
        self.allowances.write((from, to), allowance - amount);
    }

    #[external(v0)]
    fn approve_market(ref self: ContractState, market: ContractAddress, amount: u128) {
        let caller = get_caller_address();
        self.allowances.write((caller, market), amount);
    }

    #[external(v0)]
    fn get_balance(self: @ContractState, user: ContractAddress) -> u128 {
        self.balances.read(user)
    }

    #[external(v0)]
    fn get_allowance(self: @ContractState, user: ContractAddress, market: ContractAddress) -> u128 {
        self.allowances.read((user, market))
    }

    #[external(v0)]
    fn get_total_deposits(self: @ContractState) -> u128 {
        self.total_deposits.read()
    }
}
