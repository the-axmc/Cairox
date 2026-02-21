// OutcomeToken - ERC20 token for YES/NO outcome shares
use starknet::ContractAddress;
use starknet::get_caller_address;
use starknet::storage::StoragePointerReadAccess;
use starknet::storage::StoragePointerWriteAccess;
use starknet::storage::Map;

#[starknet::contract]
mod OutcomeToken {
    use super::*;

    #[storage]
    struct Storage {
        name: felt252,
        symbol: felt252,
        decimals: u8,
        owner: ContractAddress,
        balances: Map<ContractAddress, u128>,
        allowances: Map<(ContractAddress, ContractAddress), u128>,
        total_supply: u128,
    }

    #[constructor]
    fn constructor(ref self: ContractState, name: felt252, symbol: felt252) {
        self.name.write(name);
        self.symbol.write(symbol);
        self.decimals.write(18);
        self.owner.write(get_caller_address());
        self.total_supply.write(0);
    }

    #[external(v0)]
    fn mint(ref self: ContractState, to: ContractAddress, amount: u128) {
        assert(get_caller_address() == self.owner.read(), 'Only owner');
        let new_balance = self.balances.read(to) + amount;
        self.balances.write(to, new_balance);
        self.total_supply.write(self.total_supply.read() + amount);
    }

    #[external(v0)]
    fn burn(ref self: ContractState, from: ContractAddress, amount: u128) {
        let balance = self.balances.read(from);
        assert(balance >= amount, 'Insufficient balance');
        self.balances.write(from, balance - amount);
        self.total_supply.write(self.total_supply.read() - amount);
    }

    #[external(v0)]
    fn transfer(ref self: ContractState, to: ContractAddress, amount: u128) -> bool {
        let caller = get_caller_address();
        let from_balance = self.balances.read(caller);
        assert(from_balance >= amount, 'Insufficient balance');
        self.balances.write(caller, from_balance - amount);
        self.balances.write(to, self.balances.read(to) + amount);
        true
    }

    #[external(v0)]
    fn transfer_from(
        ref self: ContractState,
        from: ContractAddress,
        to: ContractAddress,
        amount: u128
    ) -> bool {
        let caller = get_caller_address();
        let allowance = self.allowances.read((from, caller));
        assert(allowance >= amount, 'Insufficient allowance');
        let from_balance = self.balances.read(from);
        assert(from_balance >= amount, 'Insufficient balance');
        self.balances.write(from, from_balance - amount);
        self.balances.write(to, self.balances.read(to) + amount);
        self.allowances.write((from, caller), allowance - amount);
        true
    }

    #[external(v0)]
    fn approve(ref self: ContractState, spender: ContractAddress, amount: u128) -> bool {
        let caller = get_caller_address();
        self.allowances.write((caller, spender), amount);
        true
    }

    #[external(v0)]
    fn get_name(self: @ContractState) -> felt252 {
        self.name.read()
    }

    #[external(v0)]
    fn get_symbol(self: @ContractState) -> felt252 {
        self.symbol.read()
    }

    #[external(v0)]
    fn get_decimals(self: @ContractState) -> u8 {
        self.decimals.read()
    }

    #[external(v0)]
    fn get_total_supply(self: @ContractState) -> u128 {
        self.total_supply.read()
    }

    #[external(v0)]
    fn balance_of(self: @ContractState, account: ContractAddress) -> u128 {
        self.balances.read(account)
    }

    #[external(v0)]
    fn allowance(self: @ContractState, owner: ContractAddress, spender: ContractAddress) -> u128 {
        self.allowances.read((owner, spender))
    }
}
