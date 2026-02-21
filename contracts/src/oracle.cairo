#[starknet::contract]
mod CairoxOracle {
    #[storage]
    struct Storage {
        owner: felt252,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        self.owner.write(0);
    }
}
