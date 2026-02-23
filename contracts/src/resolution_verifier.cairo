// ResolutionVerifier - Verifies market resolutions from oracle

#[starknet::contract]
mod ResolutionVerifier {
    use core::array::Span;
    use core::array::SpanTrait;
    use core::option::OptionTrait;
    use starknet::ContractAddress;
    use starknet::ecdsa::{verify, Signature};
    use starknet::storage::Map;
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;
    use self::{
        IOptimisticOracleDispatcher, IOptimisticOracleDispatcherTrait,
        IGroth16VerifierBN254Dispatcher, IGroth16VerifierBN254DispatcherTrait,
    };

    #[starknet::interface]
    trait IOptimisticOracle<TContractState> {
        fn get_data_hash(self: @TContractState, market_id: felt252) -> felt252;
    }

    #[starknet::interface]
    trait IGroth16VerifierBN254<TContractState> {
        fn verify_groth16_proof_bn254(
            self: @TContractState,
            full_proof_with_hints: Span<felt252>
        ) -> Option<Span<u256>>;
    }

    #[storage]
    struct Storage {
        owner: felt252,
        oracle: felt252,
        signer_pubkey: felt252,
        zk_verifier: ContractAddress,
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
        self.signer_pubkey.write(0);
        self.zk_verifier.write(ContractAddress { value: 0 });
    }

    #[external(v0)]
    fn set_oracle(ref self: ContractState, oracle: felt252) {
        let caller: felt252 = starknet::get_caller_address().into();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        self.oracle.write(oracle);
    }

    #[external(v0)]
    fn set_signer_pubkey(ref self: ContractState, pubkey: felt252) {
        let caller: felt252 = starknet::get_caller_address().into();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        self.signer_pubkey.write(pubkey);
    }

    #[external(v0)]
    fn get_signer_pubkey(self: @ContractState) -> felt252 {
        self.signer_pubkey.read()
    }

    #[external(v0)]
    fn set_zk_verifier(ref self: ContractState, verifier: ContractAddress) {
        let caller: felt252 = starknet::get_caller_address().into();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        self.zk_verifier.write(verifier);
    }

    #[external(v0)]
    fn get_zk_verifier(self: @ContractState) -> ContractAddress {
        self.zk_verifier.read()
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
        assert(oracle != 0, 'Oracle not set');

        let expected_hash = IOptimisticOracleDispatcher { contract_address: ContractAddress { value: oracle } }
            .get_data_hash(market_id);
        let zk_verifier = self.zk_verifier.read();
        if zk_verifier.value != 0 {
            assert(proof.len() > 0, 'Empty proof');
            let verifier = IGroth16VerifierBN254Dispatcher { contract_address: zk_verifier };
            let proof_inputs_opt = verifier.verify_groth16_proof_bn254(proof);
            assert(proof_inputs_opt.is_some(), 'Invalid ZK proof');
            let proof_inputs = proof_inputs_opt.unwrap();
            assert(proof_inputs.len() == 3, 'Invalid public inputs');

            let expected_market: u256 = market_id.into();
            let expected_outcome: u256 = outcome.into();
            let expected_data: u256 = expected_hash.into();

            assert(*proof_inputs.at(0) == expected_market, 'Market ID mismatch');
            assert(*proof_inputs.at(1) == expected_outcome, 'Outcome mismatch');
            assert(*proof_inputs.at(2) == expected_data, 'Data hash mismatch');
        } else {
            assert(proof.len() == 3, 'Invalid proof size');
            let provided_hash = *proof.at(0);
            assert(provided_hash == expected_hash, 'Data hash mismatch');

            let pubkey = self.signer_pubkey.read();
            if pubkey != 0 {
                let r = *proof.at(1);
                let s = *proof.at(2);
                let msg_hash = Self::message_hash(market_id, outcome, provided_hash);
                let sig = Signature { r, s };
                let ok = verify(pubkey, msg_hash, sig);
                assert(ok, 'Invalid signature');
            } else {
                assert(caller == owner, 'Signer not set');
            }
        }

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

    fn message_hash(market_id: felt252, outcome: felt252, data_hash: felt252) -> felt252 {
        let acc = starknet::pedersen(market_id, outcome);
        starknet::pedersen(acc, data_hash)
    }
}
