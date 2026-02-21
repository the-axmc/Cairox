// ResolutionVerifier - Verifies market resolutions from oracle

#[starknet::contract]
mod ResolutionVerifier {
    use starknet::storage::Map;
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;

    #[storage]
    struct Storage {
        owner: felt252,
        oracle: felt252,
        verified: Map<felt252, felt252>,
        verified_at: Map<felt252, u256>,
    }

    #[constructor]
    fn constructor(ref self: ContractState, oracle: felt252) {
        self.owner.write(0);
        self.oracle.write(oracle);
    }

    #[external(v0)]
    fn verify_resolution(ref self: ContractState, market: felt252, outcome: felt252) {
        let timestamp: u256 = starknet::get_block_timestamp().into();
        self.verified.write(market, outcome);
        self.verified_at.write(market, timestamp);
    }

    #[external(v0)]
    fn get_verified_outcome(self: @ContractState, market: felt252) -> felt252 {
        self.verified.read(market)
    }

    #[external(v0)]
    fn is_verified(self: @ContractState, market: felt252) -> bool {
        let outcome = self.verified.read(market);
        outcome != 0
    }
}
