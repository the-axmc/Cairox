// Arbitration - Dispute resolution
#[starknet::contract]
mod Arbitration {
    use starknet::ContractAddress;
    use starknet::get_caller_address;
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;

    #[storage]
    struct Storage {
        arbiter: ContractAddress,
        protocol_fee: u64,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        let addr: ContractAddress = 1.try_into().unwrap();
        self.arbiter.write(addr);
        self.protocol_fee.write(10); // 10%
    }

    #[external(v0)]
    fn resolve_dispute(
        ref self: ContractState,
        market_id: felt252,
        outcome: felt252,
        proposer_wins: bool
    ) {
        let caller = get_caller_address();
        assert(caller == self.arbiter.read(), 'Only arbiter');
    }

    #[external(v0)]
    fn set_arbiter(ref self: ContractState, new_arbiter: ContractAddress) {
        let caller = get_caller_address();
        assert(caller == self.arbiter.read(), 'Only arbiter');
        self.arbiter.write(new_arbiter);
    }

    #[external(v0)]
    fn get_arbiter(self: @ContractState) -> ContractAddress {
        self.arbiter.read()
    }
}
