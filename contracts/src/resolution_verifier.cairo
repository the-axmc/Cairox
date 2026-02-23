// ResolutionVerifier - Verifies market resolutions from oracle

#[starknet::contract]
mod ResolutionVerifier {
    use core::array::Span;
    use core::array::SpanTrait;
    use starknet::storage::Map;
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;

    #[storage]
    struct Storage {
        owner: felt252,
        oracle: felt252,
        verified_outcome: Map<felt252, felt252>,
        verified_at: Map<felt252, u256>,
        proof_hash: Map<felt252, felt252>,
        requires_proof: Map<felt252, bool>,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        let caller: felt252 = starknet::get_caller_address().into();
        self.owner.write(caller);
        self.oracle.write(0);
    }

    #[external(v0)]
    fn set_oracle(ref self: ContractState, oracle: felt252) {
        let caller: felt252 = starknet::get_caller_address().into();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        self.oracle.write(oracle);
    }

    #[external(v0)]
    fn set_requires_proof(ref self: ContractState, market_id: felt252, value: bool) {
        let caller: felt252 = starknet::get_caller_address().into();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        self.requires_proof.write(market_id, value);
    }

    #[external(v0)]
    fn requires_proof(self: @ContractState, market_id: felt252) -> bool {
        self.requires_proof.read(market_id)
    }

    #[external(v0)]
    fn verify_resolution_proof(
        ref self: ContractState,
        market_id: felt252,
        outcome: felt252,
        proof: Span<felt252>
    ) -> bool {
        let caller: felt252 = starknet::get_caller_address().into();
        let owner = self.owner.read();
        let oracle = self.oracle.read();
        assert(caller == owner | caller == oracle, 'Not authorized');

        let hash = Self::hash_proof(market_id, outcome, proof);
        self.proof_hash.write(market_id, hash);
        self.verified_outcome.write(market_id, outcome);
        let timestamp: u256 = starknet::get_block_timestamp().into();
        self.verified_at.write(market_id, timestamp);
        true
    }

    #[external(v0)]
    fn get_proof_hash(self: @ContractState, market_id: felt252) -> felt252 {
        self.proof_hash.read(market_id)
    }

    #[external(v0)]
    fn is_fast_path(self: @ContractState, market_id: felt252) -> bool {
        self.proof_hash.read(market_id) != 0
    }

    #[external(v0)]
    fn get_verified_outcome(self: @ContractState, market: felt252) -> felt252 {
        self.verified_outcome.read(market)
    }

    #[external(v0)]
    fn is_verified(self: @ContractState, market: felt252) -> bool {
        self.proof_hash.read(market) != 0
    }

    fn hash_proof(market_id: felt252, outcome: felt252, proof: Span<felt252>) -> felt252 {
        let mut acc = starknet::pedersen(market_id, outcome);
        let mut i = 0;
        loop {
            if i >= proof.len() {
                break;
            }
            let val = *proof.at(i);
            acc = starknet::pedersen(acc, val);
            i += 1;
        };
        acc
    }
}
