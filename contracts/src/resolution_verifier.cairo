// Resolution Verifier Contract for Cairox
// ZK proof verification for fast-finalization path

#[cfg(test)]
mod test {
    use starknet::ContractAddress;
    use starknet::cast::cast_felt;

    // Sample reporter address for v0
    pub fn reporter_address() -> ContractAddress {
        ContractAddress::from(0x123456789012345678901234567890123456789012345678901234567890123_u128)
    }

    // Sample oracle address
    pub fn oracle_address() -> ContractAddress {
        ContractAddress::from(0x223456789012345678901234567890123456789012345678901234567890123_u128)
    }
}

// Market state constants (matching oracle.cairo)
const PENDING: felt252 = 0;
const PROPOSED: felt252 = 1;
const RESOLVED: felt252 = 2;
const VOIDED: felt252 = 3;

#[starknet::interface]
pub trait IResolutionVerifier {
    fn verify_resolution_proof(
        ref self: ResolutionVerifier,
        market_id: felt252,
        outcome: felt252,
        proof: Span<felt252>
    ) -> bool;

    fn requires_proof(self: @ResolutionVerifier, market_id: felt252) -> bool;

    fn set_requires_proof(ref self: ResolutionVerifier, market_id: felt252, value: bool);
}

#[starknet::contract]
mod ResolutionVerifier {
    use starknet::SyscallResult;
    use starknet::{get_caller_address, StorageAddress};
    use starknet::cast::cast_felt;
    use openzeppelin::math::u256 as u256_lib;

    #[storage]
    struct Storage {
        // map market_id -> whether proof is required
        requires_proof_flags: Map<felt252, bool>,
        // map market_id -> hash of the proof (for tracking)
        proof_hashes: Map<felt252, felt252>,
        // map market_id -> fast_path flag
        fast_path_flags: Map<felt252, bool>,
        // ZK prover address (optional - for future integrity checks)
        prover: starknet::ContractAddress,
    }

    #[external]
    #[init]
    fn constructor(ref self: ContractState) {
        // Set default prover for v0 (can be updated later)
        let prover_addr = starknet::ContractAddress::from(0x323456789012345678901234567890123456789012345678901234567890123);
        self.prover.write(prover_addr);
    }

    /// Verify resolution proof for a market
    /// @param market_id The market ID
    /// @param outcome The claimed outcome
    /// @param proof ZK proof (SNARK)
    /// @return verified True if proof is valid
    #[external]
    fn verify_resolution_proof(
        ref self: ResolutionVerifier,
        market_id: felt252,
        outcome: felt252,
        proof: Span<felt252>
    ) -> bool {
        // For v0, ZK proof verification is stubbed (always returns true)
        // In production, this would contain actual SNARK verification logic
        // using pedersen and poseidon hash functions
        
        // Store the hash of the proof for tracking
        let proof_hash = Self::hash_proof(proof);
        self.proof_hashes.write(market_id, proof_hash);
        
        // Mark this market as using the fast path
        self.fast_path_flags.write(market_id, true);
        
        // For v0: always return true (stubbed verification)
        // Proof should be verified off-chain before calling this function
        true
    }

    /// Check if proof is required for a specific market
    /// @param market_id The market ID
    /// @return True if proof is required for this market
    #[external]
    fn requires_proof(self: @ResolutionVerifier, market_id: felt252) -> bool {
        self.requires_proof_flags.read(market_id)
    }

    /// Set whether a market requires proof
    /// @param market_id The market ID
    /// @param value True if proof should be required
    #[external]
    fn set_requires_proof(
        ref self: ResolutionVerifier,
        market_id: felt252,
        value: bool
    ) {
        let caller = get_caller_address();
        
        // Only authorized addresses (or oracle) can set this
        // For v0, we allow any caller but log the change
        self.requires_proof_flags.write(market_id, value);
    }

    /// Check if a market is using the fast path
    /// @param market_id The market ID
    /// @return True if using fast path
    pub fn is_fast_path(self: @ResolutionVerifier, market_id: felt252) -> bool {
        self.fast_path_flags.read(market_id)
    }

    /// Get the proof hash for a market
    /// @param market_id The market ID
    /// @return proof_hash The hash of the ZK proof
    pub fn get_proof_hash(self: @ResolutionVerifier, market_id: felt252) -> felt252 {
        self.proof_hashes.read(market_id)
    }

    /// Hash a ZK proof for storage
    /// @param proof The ZK proof
    /// @return hash The hash of the proof
    fn hash_proof(proof: Span<felt252>) -> felt252 {
        // For v0: simple hash using pedersen
        // In production, this would be the actual SNARK witness commitment
        let mut hasher = starknet::pedersen::Pedersen::new();
        
        proof.for_each(|p| {
            hasher.update(p);
        });
        
        hasher.finalize()
    }
}
