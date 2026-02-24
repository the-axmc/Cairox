// OutcomeToken - ERC20-like token for market outcomes

#[starknet::contract]
mod OutcomeToken {
    use starknet::storage::Map;
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;

    #[storage]
    struct Storage {
        name: felt252,
        symbol: felt252,
        owner: felt252,
        total_supply: u256,
        // Account -> balance
        balances: Map<felt252, u256>,
        // Account -> spender -> amount
        allowances: Map<(felt252, felt252), u256>,
    }

    #[constructor]
    fn constructor(ref self: ContractState, name: felt252, symbol: felt252, owner: felt252) {
        self.name.write(name);
        self.symbol.write(symbol);
        self.owner.write(owner);
        self.total_supply.write(u256 { low: 0, high: 0 });
    }

    #[external(v0)]
    fn mint(ref self: ContractState, to: felt252, amount: u256) {
        // Only owner can mint
        let caller: felt252 = starknet::get_caller_address().into();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        let current_supply = self.total_supply.read();
        self.total_supply.write(current_supply + amount);
        
        let balance = self.balances.read(to);
        self.balances.write(to, balance + amount);
    }

    #[external(v0)]
    fn burn(ref self: ContractState, from: felt252, amount: u256) {
        let caller: felt252 = starknet::get_caller_address().into();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        let balance = self.balances.read(from);
        assert(balance >= amount, 'Insufficient balance');
        self.balances.write(from, balance - amount);

        let current_supply = self.total_supply.read();
        self.total_supply.write(current_supply - amount);
    }

    #[external(v0)]
    fn transfer(ref self: ContractState, to: felt252, amount: u256) {
        let from: felt252 = starknet::get_caller_address().into();
        let balance = self.balances.read(from);
        assert(balance >= amount, 'Insufficient balance');
        
        self.balances.write(from, balance - amount);
        
        let to_balance = self.balances.read(to);
        self.balances.write(to, to_balance + amount);
    }

    #[external(v0)]
    fn approve(ref self: ContractState, spender: felt252, amount: u256) {
        let owner: felt252 = starknet::get_caller_address().into();
        self.allowances.write((owner, spender), amount);
    }

    #[external(v0)]
    fn transfer_from(ref self: ContractState, from: felt252, to: felt252, amount: u256) {
        let caller: felt252 = starknet::get_caller_address().into();
        
        let allowance = self.allowances.read((from, caller));
        assert(allowance >= amount, 'Allowance exceeded');
        
        self.allowances.write((from, caller), allowance - amount);
        
        let balance = self.balances.read(from);
        assert(balance >= amount, 'Insufficient balance');
        
        self.balances.write(from, balance - amount);
        
        let to_balance = self.balances.read(to);
        self.balances.write(to, to_balance + amount);
    }

    #[external(v0)]
    fn transfer_ownership(ref self: ContractState, new_owner: felt252) {
        let caller: felt252 = starknet::get_caller_address().into();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        self.owner.write(new_owner);
    }

    #[external(v0)]
    fn get_balance(self: @ContractState, account: felt252) -> u256 {
        self.balances.read(account)
    }

    #[external(v0)]
    fn balance_of(self: @ContractState, account: felt252) -> u256 {
        self.balances.read(account)
    }

    #[external(v0)]
    fn get_owner(self: @ContractState) -> felt252 {
        self.owner.read()
    }

    #[external(v0)]
    fn get_total_supply(self: @ContractState) -> u256 {
        self.total_supply.read()
    }
}
