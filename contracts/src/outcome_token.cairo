// OutcomeToken - ERC20-like token for market outcomes

use starknet::ContractAddress;

#[starknet::contract]
mod OutcomeToken {
    use starknet::SyscallResultTrait;
    use starknet::class_hash::ClassHash;
    use starknet::storage::Map;
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;
    use starknet::ContractAddress;
    use starknet::syscalls::replace_class_syscall;

    #[storage]
    struct Storage {
        name: felt252,
        symbol: felt252,
        owner: ContractAddress,
        total_supply: u256,
        // Account -> balance
        balances: Map<ContractAddress, u256>,
        // Account -> spender -> amount
        allowances: Map<(ContractAddress, ContractAddress), u256>,
    }

    #[constructor]
    fn constructor(ref self: ContractState, name: felt252, symbol: felt252, owner: ContractAddress) {
        self.name.write(name);
        self.symbol.write(symbol);
        self.owner.write(owner);
        self.total_supply.write(u256 { low: 0, high: 0 });
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Transfer: Transfer,
        Approval: Approval,
        OwnershipTransferred: OwnershipTransferred,
        Upgraded: Upgraded,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct Transfer {
        #[key]
        from: ContractAddress,
        #[key]
        to: ContractAddress,
        value: u256,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct Approval {
        #[key]
        owner: ContractAddress,
        #[key]
        spender: ContractAddress,
        value: u256,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct OwnershipTransferred {
        #[key]
        previous_owner: ContractAddress,
        #[key]
        new_owner: ContractAddress,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct Upgraded {
        class_hash: ClassHash,
    }

    #[external(v0)]
    fn mint(ref self: ContractState, to: ContractAddress, amount: u256) {
        // Only owner can mint
        let caller: ContractAddress = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        let current_supply = self.total_supply.read();
        self.total_supply.write(current_supply + amount);
        
        let balance = self.balances.read(to);
        self.balances.write(to, balance + amount);
        self.emit(Transfer { from: zero_address(), to, value: amount });
    }

    #[external(v0)]
    fn burn(ref self: ContractState, from: ContractAddress, amount: u256) {
        let caller: ContractAddress = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        let balance = self.balances.read(from);
        assert(balance >= amount, 'Insufficient balance');
        self.balances.write(from, balance - amount);

        let current_supply = self.total_supply.read();
        self.total_supply.write(current_supply - amount);
        self.emit(Transfer { from, to: zero_address(), value: amount });
    }

    #[external(v0)]
    fn transfer(ref self: ContractState, to: ContractAddress, amount: u256) {
        let from: ContractAddress = starknet::get_caller_address();
        let balance = self.balances.read(from);
        assert(balance >= amount, 'Insufficient balance');
        
        self.balances.write(from, balance - amount);
        
        let to_balance = self.balances.read(to);
        self.balances.write(to, to_balance + amount);
        self.emit(Transfer { from, to, value: amount });
    }

    #[external(v0)]
    fn approve(ref self: ContractState, spender: ContractAddress, amount: u256) {
        let owner: ContractAddress = starknet::get_caller_address();
        self.allowances.write((owner, spender), amount);
        self.emit(Approval { owner, spender, value: amount });
    }

    #[external(v0)]
    fn transfer_from(ref self: ContractState, from: ContractAddress, to: ContractAddress, amount: u256) {
        let caller: ContractAddress = starknet::get_caller_address();
        
        let allowance = self.allowances.read((from, caller));
        assert(allowance >= amount, 'Allowance exceeded');
        
        self.allowances.write((from, caller), allowance - amount);
        self.emit(Approval { owner: from, spender: caller, value: allowance - amount });
        
        let balance = self.balances.read(from);
        assert(balance >= amount, 'Insufficient balance');
        
        self.balances.write(from, balance - amount);
        
        let to_balance = self.balances.read(to);
        self.balances.write(to, to_balance + amount);
        self.emit(Transfer { from, to, value: amount });
    }

    #[external(v0)]
    fn transfer_ownership(ref self: ContractState, new_owner: ContractAddress) {
        let caller: ContractAddress = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        self.owner.write(new_owner);
        self.emit(OwnershipTransferred { previous_owner: owner, new_owner });
    }

    #[external(v0)]
    fn balance_of(self: @ContractState, account: ContractAddress) -> u256 {
        self.balances.read(account)
    }

    #[external(v0)]
    fn allowance(self: @ContractState, owner: ContractAddress, spender: ContractAddress) -> u256 {
        self.allowances.read((owner, spender))
    }

    #[external(v0)]
    fn get_owner(self: @ContractState) -> ContractAddress {
        self.owner.read()
    }

    #[external(v0)]
    fn get_total_supply(self: @ContractState) -> u256 {
        self.total_supply.read()
    }

    #[external(v0)]
    fn name(self: @ContractState) -> felt252 {
        self.name.read()
    }

    #[external(v0)]
    fn symbol(self: @ContractState) -> felt252 {
        self.symbol.read()
    }

    #[external(v0)]
    fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
        let caller: ContractAddress = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        replace_class_syscall(new_class_hash).unwrap_syscall();
        self.emit(Upgraded { class_hash: new_class_hash });
    }

    fn zero_address() -> ContractAddress {
        0.try_into().unwrap()
    }
}
