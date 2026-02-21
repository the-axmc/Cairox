// ResolutionVerifier - ZK proof verification for market resolution
use starknet::ContractAddress;
use starknet::get_caller_address;
use starknet::storage::StoragePointerReadAccess;
use starknet::storage::StoragePointerWriteAccess;
use starknet::storage::Map;

#[starknet::contract]
mod ResolutionVerifier {
    use super::*;

    #[storage]
    struct Storage {
        owner: ContractAddress,
        prover: ContractAddress,
        requires_proof: bool,
        verified_proofs: Map<felt252, bool>,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        self.owner.write(get_caller_address());
        self.prover.write(get_caller_address());
        self.requires_proof.write(true);
    }

    #[external(v0)]
    fn verify_proof(
        ref self: ContractState,
        market_id: felt252,
        outcome: felt252,
        proof: Span<felt252>
    ) -> bool {
        // In production: verify ZK proof
        // For now: mark as verified
        let key = market_id;
        self.verified_proofs.write(key, true);
        true
    }

    #[external(v0)]
    fn is_proof_required(self: @ContractState) -> bool {
        self.requires_proof.read()
    }

    #[external(v0)]
    fn set_proof_required(ref self: ContractState, required: bool) {
        assert(get_caller_address() == self.owner.read(), 'Only owner');
        self.requires_proof.write(required);
    }

    #[external(v0)]
    fn set_prover(ref self: ContractState, new_prover: ContractAddress) {
        assert(get_caller_address() == self.owner.read(), 'Only owner');
        self.prover.write(new_prover);
    }

    #[external(v0)]
    fn is_verified(self: @ContractState, market_id: felt252) -> bool {
        self.verified_proofs.read(market_id)
    }
}
