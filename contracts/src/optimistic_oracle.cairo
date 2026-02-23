// OptimisticOracle - Proposes and resolves market outcomes with dispute window

use core::array::Span;
use starknet::ContractAddress;

#[starknet::interface]
trait IResolutionVerifier<TContractState> {
    fn verify_resolution_proof(
        ref self: TContractState,
        market_id: felt252,
        outcome: felt252,
        proof: Span<felt252>
    ) -> bool;
    fn requires_proof(self: @TContractState, market_id: felt252) -> bool;
    fn is_fast_path(self: @TContractState, market_id: felt252) -> bool;
}

#[starknet::interface]
trait IERC20<TContractState> {
    fn transfer(ref self: TContractState, to: ContractAddress, amount: u256) -> bool;
    fn transfer_from(
        ref self: TContractState,
        from: ContractAddress,
        to: ContractAddress,
        amount: u256
    ) -> bool;
}

#[starknet::contract]
mod OptimisticOracle {
    use super::{
        IERC20Dispatcher, IERC20DispatcherTrait, IResolutionVerifierDispatcher,
        IResolutionVerifierDispatcherTrait,
    };
    use core::array::SpanTrait;
    use starknet::ContractAddress;
    use starknet::storage::Map;
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;

    const STATE_PENDING: felt252 = 0;
    const STATE_PROPOSED: felt252 = 1;
    const STATE_RESOLVED: felt252 = 2;

    #[storage]
    struct Storage {
        owner: ContractAddress,
        arbiter: ContractAddress,
        verifier: ContractAddress,
        bond_token: ContractAddress,
        reporters: Map<ContractAddress, bool>,

        min_proposer_bond: u256,
        min_dispute_bond: u256,
        dispute_window: u256,

        status: Map<felt252, felt252>,
        proposed_outcome: Map<felt252, felt252>,
        final_outcome: Map<felt252, felt252>,
        data_hash: Map<felt252, felt252>,
        data_uri: Map<felt252, felt252>,
        proposed_at: Map<felt252, u256>,
        proposer: Map<felt252, ContractAddress>,
        proposer_bond: Map<felt252, u256>,
        disputer: Map<felt252, ContractAddress>,
        disputer_bond: Map<felt252, u256>,
        disputed: Map<felt252, bool>,
        fast_path: Map<felt252, bool>,
    }

    #[constructor]
    fn constructor(ref self: ContractState, bond_token: ContractAddress) {
        let caller = starknet::get_caller_address();
        self.owner.write(caller);
        self.arbiter.write(caller);
        self.verifier.write(ContractAddress { value: 0 });
        self.bond_token.write(bond_token);
        self.reporters.write(caller, true);
        self.min_proposer_bond.write(u256 { low: 100, high: 0 });
        self.min_dispute_bond.write(u256 { low: 200, high: 0 });
        self.dispute_window.write(u256 { low: 300, high: 0 });
    }

    #[external(v0)]
    fn add_reporter(ref self: ContractState, reporter: ContractAddress) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        self.reporters.write(reporter, true);
    }

    #[external(v0)]
    fn remove_reporter(ref self: ContractState, reporter: ContractAddress) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        self.reporters.write(reporter, false);
    }

    #[external(v0)]
    fn set_arbiter(ref self: ContractState, arbiter: ContractAddress) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        self.arbiter.write(arbiter);
    }

    #[external(v0)]
    fn set_verifier(ref self: ContractState, verifier: ContractAddress) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        self.verifier.write(verifier);
    }

    #[external(v0)]
    fn set_dispute_window(ref self: ContractState, window: u256) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        self.dispute_window.write(window);
    }

    #[external(v0)]
    fn propose(
        ref self: ContractState,
        market_id: felt252,
        outcome: felt252,
        data_hash: felt252,
        data_uri: felt252,
        bond: u256
    ) {
        let verifier = self.verifier.read();
        if verifier.value != 0 {
            let verifier_dispatcher = IResolutionVerifierDispatcher { contract_address: verifier };
            let requires = verifier_dispatcher.requires_proof(market_id);
            assert(!requires, 'Proof required');
        }
        self.internal_propose(market_id, outcome, data_hash, data_uri, bond, false);
    }

    #[external(v0)]
    fn propose_with_proof(
        ref self: ContractState,
        market_id: felt252,
        outcome: felt252,
        data_hash: felt252,
        zk_proof: Span<felt252>
    ) {
        let proof_len = zk_proof.len();
        assert((proof_len > 0) & (proof_len <= 1000), 'Invalid ZK proof size');
        self.internal_propose(market_id, outcome, data_hash, 0, u256 { low: 100, high: 0 }, true);

        let verifier = self.verifier.read();
        if verifier.value != 0 {
            let verifier_dispatcher = IResolutionVerifierDispatcher { contract_address: verifier };
            let requires = verifier_dispatcher.requires_proof(market_id);
            assert(requires, 'Proof not required');
            let verified = verifier_dispatcher.verify_resolution_proof(market_id, outcome, zk_proof);
            assert(verified, 'Invalid ZK proof');
        }
        self.fast_path.write(market_id, true);
    }

    #[external(v0)]
    fn dispute(ref self: ContractState, market_id: felt252, bond: u256) {
        let status = self.status.read(market_id);
        assert(status == STATE_PROPOSED, 'Wrong state');
        let disputed = self.disputed.read(market_id);
        assert(!disputed, 'Already disputed');
        let min_bond = self.min_dispute_bond.read();
        assert(bond >= min_bond, 'Bond too low');
        self.take_bond(bond);
        let caller = starknet::get_caller_address();
        self.disputer.write(market_id, caller);
        self.disputer_bond.write(market_id, bond);
        self.disputed.write(market_id, true);
    }

    #[external(v0)]
    fn finalize(ref self: ContractState, market_id: felt252) {
        let status = self.status.read(market_id);
        assert(status == STATE_PROPOSED, 'Wrong state');
        assert(!self.disputed.read(market_id), 'DISPUTED');

        let fast_path = self.fast_path.read(market_id);
        let verifier = self.verifier.read();
        if verifier.value != 0 {
            let verifier_dispatcher = IResolutionVerifierDispatcher { contract_address: verifier };
            let requires = verifier_dispatcher.requires_proof(market_id);
            if requires {
                assert(fast_path, 'Proof required');
            }
        }
        if !fast_path {
            let proposed_at = self.proposed_at.read(market_id);
            let window = self.dispute_window.read();
            let now: u256 = starknet::get_block_timestamp().into();
            assert(now >= proposed_at + window, 'Dispute window');
        }

        let outcome = self.proposed_outcome.read(market_id);
        self.final_outcome.write(market_id, outcome);
        self.status.write(market_id, STATE_RESOLVED);
        self.refund_proposer(market_id);
    }

    #[external(v0)]
    fn fast_finalize(ref self: ContractState, market_id: felt252) {
        let status = self.status.read(market_id);
        assert(status == STATE_PROPOSED, 'Wrong state');
        let fast_path = self.fast_path.read(market_id);
        assert(fast_path, 'Market is not using fast path');
        assert(!self.disputed.read(market_id), 'DISPUTED');

        let verifier = self.verifier.read();
        if verifier.value != 0 {
            let verifier_dispatcher = IResolutionVerifierDispatcher { contract_address: verifier };
            let requires = verifier_dispatcher.requires_proof(market_id);
            if requires {
                let verified = verifier_dispatcher.is_fast_path(market_id);
                assert(verified, 'Proof not verified');
            }
        }

        let outcome = self.proposed_outcome.read(market_id);
        self.final_outcome.write(market_id, outcome);
        self.status.write(market_id, STATE_RESOLVED);
        self.refund_proposer(market_id);
    }

    #[external(v0)]
    fn resolve_arbitration(ref self: ContractState, market_id: felt252, outcome: felt252) {
        let status = self.status.read(market_id);
        assert(status == STATE_PROPOSED, 'Wrong state');
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        let arbiter = self.arbiter.read();
        assert(caller == owner | caller == arbiter, 'Not arbiter');

        self.final_outcome.write(market_id, outcome);
        self.status.write(market_id, STATE_RESOLVED);
        self.disputed.write(market_id, false);
        self.settle_bonds(market_id);
    }

    #[external(v0)]
    fn get_market_status(self: @ContractState, market_id: felt252) -> felt252 {
        self.status.read(market_id)
    }

    #[external(v0)]
    fn is_disputed(self: @ContractState, market_id: felt252) -> bool {
        self.disputed.read(market_id)
    }

    #[external(v0)]
    fn get_final_outcome(self: @ContractState, market_id: felt252) -> felt252 {
        self.final_outcome.read(market_id)
    }

    fn internal_propose(
        ref self: ContractState,
        market_id: felt252,
        outcome: felt252,
        data_hash: felt252,
        data_uri: felt252,
        bond: u256,
        is_fast_path: bool
    ) {
        let status = self.status.read(market_id);
        assert(status == STATE_PENDING, 'Market exists');

        let caller = starknet::get_caller_address();
        let is_reporter = self.reporters.read(caller);
        assert(is_reporter, 'Not reporter');

        let min_bond = self.min_proposer_bond.read();
        assert(bond >= min_bond, 'Bond too low');
        self.take_bond(bond);

        self.status.write(market_id, STATE_PROPOSED);
        self.proposed_outcome.write(market_id, outcome);
        self.data_hash.write(market_id, data_hash);
        self.data_uri.write(market_id, data_uri);
        self.proposer.write(market_id, caller);
        self.proposer_bond.write(market_id, bond);
        self.proposed_at.write(market_id, starknet::get_block_timestamp().into());
        self.disputed.write(market_id, false);
        self.fast_path.write(market_id, is_fast_path);
    }

    fn take_bond(ref self: ContractState, amount: u256) {
        let token = self.bond_token.read();
        if token.value == 0 {
            return;
        }
        let caller = starknet::get_caller_address();
        let oracle_addr = starknet::get_contract_address();
        let erc20 = IERC20Dispatcher { contract_address: token };
        let ok = erc20.transfer_from(caller, oracle_addr, amount);
        assert(ok, 'Bond transfer failed');
    }

    fn refund_proposer(ref self: ContractState, market_id: felt252) {
        let token = self.bond_token.read();
        if token.value == 0 {
            return;
        }
        let proposer = self.proposer.read(market_id);
        let amount = self.proposer_bond.read(market_id);
        let erc20 = IERC20Dispatcher { contract_address: token };
        let ok = erc20.transfer(proposer, amount);
        assert(ok, 'Bond refund failed');
    }

    fn settle_bonds(ref self: ContractState, market_id: felt252) {
        let token = self.bond_token.read();
        if token.value == 0 {
            return;
        }
        let proposer = self.proposer.read(market_id);
        let proposer_bond = self.proposer_bond.read(market_id);
        let disputer = self.disputer.read(market_id);
        let disputer_bond = self.disputer_bond.read(market_id);
        let proposed = self.proposed_outcome.read(market_id);
        let final_outcome = self.final_outcome.read(market_id);
        let winner = if proposed == final_outcome { proposer } else { disputer };
        let total = proposer_bond + disputer_bond;
        let erc20 = IERC20Dispatcher { contract_address: token };
        let ok = erc20.transfer(winner, total);
        assert(ok, 'Bond payout failed');
    }
}
