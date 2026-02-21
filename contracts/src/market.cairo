// Market - Basic market contract
#[starknet::contract]
mod Market {
    use starknet::ContractAddress;
    use starknet::get_caller_address;
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;

    const PENDING: felt252 = 0;
    const ACTIVE: felt252 = 1;
    const RESOLVED: felt252 = 2;

    #[storage]
    struct Storage {
        creator: ContractAddress,
        outcome: felt252,
        status: felt252,
        yes_token: ContractAddress,
        no_token: ContractAddress,
    }

    #[constructor]
    fn constructor(ref self: ContractState, creator: ContractAddress) {
        self.creator.write(creator);
        self.status.write(PENDING);
    }

    #[external(v0)]
    fn resolve(ref self: ContractState, outcome: felt252) {
        let caller = get_caller_address();
        assert(caller == self.creator.read(), 'Only creator');
        self.outcome.write(outcome);
        self.status.write(RESOLVED);
    }

    #[external(v0)]
    fn get_status(self: @ContractState) -> felt252 {
        self.status.read()
    }
}
