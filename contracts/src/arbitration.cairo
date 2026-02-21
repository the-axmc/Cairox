// Simplified Arbitration - Cairo 2.x
#[starknet::contract]
mod Arbitration {
    use starknet::ContractAddress;
    use starknet::get_caller_address;

    #[storage]
    struct Storage {
        arbiter: ContractAddress,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        let arbiter_addr: ContractAddress = 0x1.try_into().unwrap();
        self.arbiter.write(arbiter_addr);
    }

    #[external(v0)]
    fn resolve_dispute(ref self: ContractState, market_id: felt252, outcome: felt252) {
        // Stubbed
    }

    #[external(v0)]
    fn get_arbiter(self: @ContractState) -> ContractAddress {
        self.arbiter.read()
    }
}
