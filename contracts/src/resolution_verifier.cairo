// Simplified Resolution Verifier - Cairo 2.x
#[starknet::contract]
mod ResolutionVerifier {
    use starknet::ContractAddress;
    use starknet::storage::Map;

    #[storage]
    struct Storage {
        requires_proof_flags: Map<felt252, bool>,
        prover: ContractAddress,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        let prover_addr: ContractAddress = 0x1.try_into().unwrap();
        self.prover.write(prover_addr);
    }

    #[external(v0)]
    fn verify_resolution_proof(
        ref self: ContractState,
        market_id: felt252,
        outcome: felt252,
        proof: Span<felt252>
    ) -> bool {
        // Stubbed - always return true
        true
    }

    #[external(v0)]
    fn requires_proof(self: @ContractState, market_id: felt252) -> bool {
        self.requires_proof_flags.read(market_id)
    }

    #[external(v0)]
    fn set_requires_proof(ref self: ContractState, market_id: felt252, value: bool) {
        self.requires_proof_flags.write(market_id, value);
    }
}
