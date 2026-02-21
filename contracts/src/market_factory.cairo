// MarketFactory - Creates markets
#[starknet::contract]
mod MarketFactory {
    use starknet::ContractAddress;
    use starknet::get_caller_address;
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;

    #[storage]
    struct Storage {
        owner: ContractAddress,
        market_count: u64,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        let caller = get_caller_address();
        self.owner.write(caller);
        self.market_count.write(0);
    }

    #[external(v0)]
    fn create_market(ref self: ContractState) -> u64 {
        let caller = get_caller_address();
        assert(caller == self.owner.read(), 'Only owner');
        let count = self.market_count.read();
        self.market_count.write(count + 1);
        count
    }

    #[external(v0)]
    fn get_market_count(self: @ContractState) -> u64 {
        self.market_count.read()
    }
}
