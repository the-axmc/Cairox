// ResolutionVerifier - Verifies market resolutions from oracle

use core::array::Span;
use starknet::ContractAddress;

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

#[starknet::contract]
mod ResolutionVerifier {
    use super::{
        IOptimisticOracleDispatcher, IOptimisticOracleDispatcherTrait,
        IGroth16VerifierBN254Dispatcher, IGroth16VerifierBN254DispatcherTrait,
    };
    use core::array::Span;
    use core::array::SpanTrait;
    use core::box::BoxTrait;
    use core::ecdsa::check_ecdsa_signature;
    use core::ec::stark_curve;
    use core::traits::TryInto;
    use core::option::OptionTrait;
    use starknet::ContractAddress;
    use core::pedersen::pedersen;
    use starknet::storage::Map;
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;

    #[storage]
    struct Storage {
        owner: ContractAddress,
        oracle: ContractAddress,
        signer_pubkey: felt252,
        zk_verifier: ContractAddress,
        verified_outcome: Map<felt252, felt252>,
        verified_at: Map<felt252, u256>,
        proof_hash: Map<felt252, felt252>,
        requires_proof: Map<felt252, u8>,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        let owner = deployer_address();
        self.owner.write(owner);
        self.oracle.write(zero_address());
        self.signer_pubkey.write(0);
        self.zk_verifier.write(zero_address());
    }

    #[external(v0)]
    fn set_oracle(ref self: ContractState, oracle: ContractAddress) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        self.oracle.write(oracle);
    }

    #[external(v0)]
    fn set_signer_pubkey(ref self: ContractState, pubkey: felt252) {
        let caller = starknet::get_caller_address();
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
        let caller = starknet::get_caller_address();
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
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        let flag: u8 = if value { 1 } else { 0 };
        self.requires_proof.write(market_id, flag);
    }

    #[external(v0)]
    fn requires_proof(self: @ContractState, market_id: felt252) -> bool {
        self.requires_proof.read(market_id) == 1
    }

    #[external(v0)]
    fn verify_resolution_proof(
        ref self: ContractState,
        market_id: felt252,
        outcome: felt252,
        proof: Span<felt252>
    ) -> bool {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        let oracle = self.oracle.read();
        assert((caller == owner) || (caller == oracle), 'Not authorized');
        assert(!is_zero_address(oracle), 'Oracle not set');

        let expected_hash = IOptimisticOracleDispatcher { contract_address: oracle }
            .get_data_hash(market_id);
        let zk_verifier = self.zk_verifier.read();
        if !is_zero_address(zk_verifier) {
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
            let signer_pubkey = self.signer_pubkey.read();
            assert(signer_pubkey != 0, 'Signer not set');
            assert(proof.len() >= 3, 'Invalid proof');
            let provided_hash = *proof.at(0);
            assert(provided_hash == expected_hash, 'Data hash mismatch');
            let sig_r = *proof.at(1);
            let sig_s = *proof.at(2);
            assert(is_valid_signature(market_id, outcome, provided_hash, signer_pubkey, sig_r, sig_s), 'Invalid signature');
        }

        let hash = hash_proof(market_id, outcome, proof);
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
        let mut acc = pedersen(market_id, outcome);
        let mut i = 0;
        loop {
            if i >= proof.len() {
                break;
            }
            let val = *proof.at(i);
            acc = pedersen(acc, val);
            i += 1;
        };
        acc
    }

    fn is_valid_signature(
        market_id: felt252,
        outcome: felt252,
        data_hash: felt252,
        pubkey: felt252,
        sig_r: felt252,
        sig_s: felt252
    ) -> bool {
        let msg_hash = message_hash(market_id, outcome, data_hash);
        let ord = stark_curve::ORDER;
        if sig_r >= ord || sig_s >= ord {
            return false;
        }
        // Prevent malleability by enforcing low-s
        if sig_s > (ord / 2) {
            return false;
        }
        check_ecdsa_signature(msg_hash, pubkey, sig_r, sig_s)
    }

    fn message_hash(market_id: felt252, outcome: felt252, data_hash: felt252) -> felt252 {
        let acc = pedersen(market_id, outcome);
        pedersen(acc, data_hash)
    }

    fn is_zero_address(addr: ContractAddress) -> bool {
        let felt: felt252 = addr.into();
        felt == 0
    }

    fn zero_address() -> ContractAddress {
        0.try_into().unwrap()
    }

    fn deployer_address() -> ContractAddress {
        let tx_info = starknet::get_tx_info().unbox();
        tx_info.account_contract_address
    }
}
