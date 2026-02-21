// OutcomeToken - ERC20 token for YES/NO shares
#[starknet::contract]
mod OutcomeToken {
    use starknet::ContractAddress;
    use starknet::get_caller_address;
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;

    #[storage]
    struct Storage {
        name: felt252,
        symbol: felt252,
        decimals: u8,
        owner: ContractAddress,
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
        self.total_supply.write(self.total_supply.read() + amount);
    }

    #[external(v0)]
    fn burn(ref self: ContractState, from: ContractAddress, amount: u128) {
        let supply = self.total_supply.read();
        assert(supply >= amount, 'Insufficient supply');
        self.total_supply.write(supply - amount);
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
    fn get_total_supply(self: @ContractState) -> u128 {
        self.total_supply.read()
    }
}
