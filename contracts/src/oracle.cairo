// OptimisticOracle - Cairo 2.x 
#[starknet::contract]
mod OptimisticOracle {
    use starknet::ContractAddress;
    use starknet::get_caller_address;
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;

    const PENDING: felt252 = 0;
    const PROPOSED: felt252 = 1;
    const RESOLVED: felt252 = 2;
    const DISPUTED: felt252 = 3;

    #[storage]
    struct Storage {
        min_proposer_bond: u64,
        min_dispute_bond: u64,
        arbiter: ContractAddress,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        self.min_proposer_bond.write(100);
        self.min_dispute_bond.write(200);
        let addr: ContractAddress = 1.try_into().unwrap();
        self.arbiter.write(addr);
    }

    #[external(v0)]
    fn get_status(self: @ContractState) -> felt252 {
        PENDING
    }
}
