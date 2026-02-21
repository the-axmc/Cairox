// MarketFactory - Deploys markets
#[starknet::contract]
mod MarketFactory {
    use starknet::ContractAddress;
    use starknet::get_caller_address;
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;

    #[storage]
    struct Storage {
        owner: ContractAddress,
        market_count: u256,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        self.owner.write(get_caller_address());
        self.market_count.write(0);
    }

    #[external(v0)]
    fn create_market(ref self: ContractState, market: ContractAddress, question: felt252) -> u256 {
        assert(get_caller_address() == self.owner.read(), 'Only owner');
        let id = self.market_count.read();
        self.market_count.write(id + 1);
        id
    }

    #[external(v0)]
    fn get_market_count(self: @ContractState) -> u256 {
        self.market_count.read()
    }
}
