// LMSRMulti - Categorical outcome market maker
#[starknet::contract]
mod LMSRMulti {
    use starknet::ContractAddress;
    use starknet::get_caller_address;
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;

    #[storage]
    struct Storage {
        owner: ContractAddress,
        market: ContractAddress,
        invariant: u128,
        outcome_count: u32,
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress, market: ContractAddress, outcome_count: u32, invariant: u128) {
        self.owner.write(owner);
        self.market.write(market);
        self.outcome_count.write(outcome_count);
        self.invariant.write(invariant);
    }

    #[external(v0)]
    fn get_price(self: @ContractState, outcome: u32) -> u128 {
        let count = self.outcome_count.read();
        if count == 0 {
            return 0;
        }
        1000000000000000000 / count.into()
    }

    #[external(v0)]
    fn get_outcome_count(self: @ContractState) -> u32 {
        self.outcome_count.read()
    }

    #[external(v0)]
    fn set_invariant(ref self: ContractState, new_invariant: u128) {
        assert(get_caller_address() == self.owner.read(), 'Only owner');
        self.invariant.write(new_invariant);
    }
}
