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

#[starknet::interface]
trait IDataCommitment<TContractState> {
    fn get_commitment(self: @TContractState, market_id: felt252) -> felt252;
    fn get_updated_at(self: @TContractState, market_id: felt252) -> u256;
}

#[starknet::contract]
mod OptimisticOracle {
    use super::{
        IERC20Dispatcher, IERC20DispatcherTrait, IResolutionVerifierDispatcher,
        IResolutionVerifierDispatcherTrait, IDataCommitmentDispatcher, IDataCommitmentDispatcherTrait,
    };
    use core::array::SpanTrait;
    use core::box::BoxTrait;
    use core::option::OptionTrait;
    use core::traits::TryInto;
    use starknet::ContractAddress;
    use starknet::SyscallResultTrait;
    use starknet::class_hash::ClassHash;
    use starknet::storage::Map;
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;
    use starknet::syscalls::replace_class_syscall;

    const STATE_PENDING: felt252 = 0;
    const STATE_PROPOSED: felt252 = 1;
    const STATE_RESOLVED: felt252 = 2;

    #[storage]
    struct Storage {
        owner: ContractAddress,
        arbiter: ContractAddress,
        verifier: ContractAddress,
        bond_token: ContractAddress,
        reporters: Map<ContractAddress, u8>,
        market_factory: ContractAddress,
        data_commitment: ContractAddress,
        registered: Map<felt252, u8>,

        min_proposer_bond: u256,
        min_dispute_bond: u256,
        dispute_window: u256,
        dispute_timeout: u256,
        max_commitment_age: u256,

        status: Map<felt252, felt252>,
        proposed_outcome: Map<felt252, felt252>,
        final_outcome: Map<felt252, felt252>,
        data_hash: Map<felt252, felt252>,
        data_uri: Map<felt252, felt252>,
        proposed_at: Map<felt252, u256>,
        disputed_at: Map<felt252, u256>,
        proposer: Map<felt252, ContractAddress>,
        proposer_bond: Map<felt252, u256>,
        disputer: Map<felt252, ContractAddress>,
        disputer_bond: Map<felt252, u256>,
        disputed: Map<felt252, u8>,
        fast_path: Map<felt252, u8>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        ReporterAdded: ReporterAdded,
        ReporterRemoved: ReporterRemoved,
        ArbiterSet: ArbiterSet,
        VerifierSet: VerifierSet,
        MarketFactorySet: MarketFactorySet,
        DataCommitmentSet: DataCommitmentSet,
        MarketRegistered: MarketRegistered,
        DisputeWindowSet: DisputeWindowSet,
        DisputeTimeoutSet: DisputeTimeoutSet,
        MaxCommitmentAgeSet: MaxCommitmentAgeSet,
        Proposed: Proposed,
        Disputed: Disputed,
        Finalized: Finalized,
        FastFinalized: FastFinalized,
        ArbitrationResolved: ArbitrationResolved,
        DisputeTimedOut: DisputeTimedOut,
        Upgraded: Upgraded,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct ReporterAdded {
        #[key]
        reporter: ContractAddress,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct ReporterRemoved {
        #[key]
        reporter: ContractAddress,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct ArbiterSet {
        #[key]
        arbiter: ContractAddress,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct VerifierSet {
        #[key]
        verifier: ContractAddress,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct MarketFactorySet {
        #[key]
        market_factory: ContractAddress,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct DataCommitmentSet {
        #[key]
        data_commitment: ContractAddress,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct MarketRegistered {
        #[key]
        market_id: felt252,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct DisputeWindowSet {
        window: u256,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct DisputeTimeoutSet {
        timeout: u256,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct MaxCommitmentAgeSet {
        max_age: u256,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct Proposed {
        #[key]
        market_id: felt252,
        outcome: felt252,
        data_hash: felt252,
        data_uri: felt252,
        bond: u256,
        proposer: ContractAddress,
        proposed_at: u256,
        fast_path: u8,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct Disputed {
        #[key]
        market_id: felt252,
        disputer: ContractAddress,
        bond: u256,
        disputed_at: u256,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct Finalized {
        #[key]
        market_id: felt252,
        outcome: felt252,
        finalized_at: u256,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct FastFinalized {
        #[key]
        market_id: felt252,
        outcome: felt252,
        finalized_at: u256,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct ArbitrationResolved {
        #[key]
        market_id: felt252,
        outcome: felt252,
        resolved_at: u256,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct DisputeTimedOut {
        #[key]
        market_id: felt252,
        outcome: felt252,
        resolved_at: u256,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct Upgraded {
        class_hash: ClassHash,
    }

    #[constructor]
    fn constructor(ref self: ContractState, bond_token: ContractAddress) {
        let owner = deployer_address();
        self.owner.write(owner);
        self.arbiter.write(owner);
        self.verifier.write(zero_address());
        self.bond_token.write(bond_token);
        self.reporters.write(owner, 1);
        self.market_factory.write(zero_address());
        self.data_commitment.write(zero_address());
        self.min_proposer_bond.write(u256 { low: 100, high: 0 });
        self.min_dispute_bond.write(u256 { low: 200, high: 0 });
        self.dispute_window.write(u256 { low: 300, high: 0 });
        self.dispute_timeout.write(u256 { low: 3600, high: 0 });
        self.max_commitment_age.write(u256 { low: 3600, high: 0 });
    }

    #[external(v0)]
    fn add_reporter(ref self: ContractState, reporter: ContractAddress) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        self.reporters.write(reporter, 1);
        self.emit(ReporterAdded { reporter });
    }

    #[external(v0)]
    fn remove_reporter(ref self: ContractState, reporter: ContractAddress) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        self.reporters.write(reporter, 0);
        self.emit(ReporterRemoved { reporter });
    }

    #[external(v0)]
    fn set_arbiter(ref self: ContractState, arbiter: ContractAddress) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        self.arbiter.write(arbiter);
        self.emit(ArbiterSet { arbiter });
    }

    #[external(v0)]
    fn set_verifier(ref self: ContractState, verifier: ContractAddress) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        self.verifier.write(verifier);
        self.emit(VerifierSet { verifier });
    }

    #[external(v0)]
    fn set_market_factory(ref self: ContractState, market_factory: ContractAddress) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        self.market_factory.write(market_factory);
        self.emit(MarketFactorySet { market_factory });
    }

    #[external(v0)]
    fn set_data_commitment(ref self: ContractState, commitment: ContractAddress) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        self.data_commitment.write(commitment);
        self.emit(DataCommitmentSet { data_commitment: commitment });
    }

    #[external(v0)]
    fn get_verifier(self: @ContractState) -> ContractAddress {
        self.verifier.read()
    }

    #[external(v0)]
    fn get_data_commitment(self: @ContractState) -> ContractAddress {
        self.data_commitment.read()
    }

    #[external(v0)]
    fn register_market(ref self: ContractState, market_id: felt252) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        let factory = self.market_factory.read();
        assert(caller == owner || caller == factory, 'Not authorized');
        let already = self.registered.read(market_id);
        assert(already == 0, 'Market already registered');
        self.registered.write(market_id, 1);
        self.status.write(market_id, STATE_PENDING);
        self.disputed.write(market_id, 0);
        self.fast_path.write(market_id, 0);
        self.emit(MarketRegistered { market_id });
    }

    #[external(v0)]
    fn set_dispute_window(ref self: ContractState, window: u256) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        self.dispute_window.write(window);
        self.emit(DisputeWindowSet { window });
    }

    #[external(v0)]
    fn set_dispute_timeout(ref self: ContractState, timeout: u256) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        self.dispute_timeout.write(timeout);
        self.emit(DisputeTimeoutSet { timeout });
    }

    #[external(v0)]
    fn set_max_commitment_age(ref self: ContractState, max_age: u256) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        self.max_commitment_age.write(max_age);
        self.emit(MaxCommitmentAgeSet { max_age });
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
        if !is_zero_address(verifier) {
            let verifier_dispatcher = IResolutionVerifierDispatcher { contract_address: verifier };
            let requires = verifier_dispatcher.requires_proof(market_id);
            assert(!requires, 'Proof required');
        }
        internal_propose(ref self, market_id, outcome, data_hash, data_uri, bond, false);
    }

    #[external(v0)]
    fn propose_with_proof(
        ref self: ContractState,
        market_id: felt252,
        outcome: felt252,
        data_hash: felt252,
        bond: u256,
        zk_proof: Span<felt252>
    ) {
        let proof_len = zk_proof.len();
        assert((proof_len > 0) && (proof_len <= 1000), 'Invalid ZK proof size');
        let verifier = self.verifier.read();
        assert(!is_zero_address(verifier), 'Verifier not set');
        let verifier_dispatcher = IResolutionVerifierDispatcher { contract_address: verifier };
        let requires = verifier_dispatcher.requires_proof(market_id);
        assert(requires, 'Proof not required');
        internal_propose(ref self, market_id, outcome, data_hash, 0, bond, true);
        let verified = verifier_dispatcher.verify_resolution_proof(market_id, outcome, zk_proof);
        assert(verified, 'Invalid ZK proof');
        self.fast_path.write(market_id, 1);
    }

    #[external(v0)]
    fn dispute(ref self: ContractState, market_id: felt252, bond: u256) {
        let status = self.status.read(market_id);
        assert(status == STATE_PROPOSED, 'Wrong state');
        let disputed = self.disputed.read(market_id);
        assert(disputed == 0, 'Already disputed');
        let min_bond = self.min_dispute_bond.read();
        assert(bond >= min_bond, 'Bond too low');
        take_bond(ref self, bond);
        let caller = starknet::get_caller_address();
        self.disputer.write(market_id, caller);
        self.disputer_bond.write(market_id, bond);
        self.disputed.write(market_id, 1);
        let now: u256 = starknet::get_block_timestamp().into();
        self.disputed_at.write(market_id, now);
        self.emit(Disputed { market_id, disputer: caller, bond, disputed_at: now });
    }

    #[external(v0)]
    fn finalize(ref self: ContractState, market_id: felt252) {
        let status = self.status.read(market_id);
        assert(status == STATE_PROPOSED, 'Wrong state');
        assert(self.disputed.read(market_id) == 0, 'DISPUTED');

        let fast_path = self.fast_path.read(market_id);
        let verifier = self.verifier.read();
        if !is_zero_address(verifier) {
            let verifier_dispatcher = IResolutionVerifierDispatcher { contract_address: verifier };
            let requires = verifier_dispatcher.requires_proof(market_id);
            if requires {
                assert(fast_path == 1, 'Proof required');
                let verified = verifier_dispatcher.is_fast_path(market_id);
                assert(verified, 'Proof not verified');
            }
        }
        if fast_path == 0 {
            let proposed_at = self.proposed_at.read(market_id);
            let window = self.dispute_window.read();
            let now: u256 = starknet::get_block_timestamp().into();
            assert(now >= proposed_at + window, 'Dispute window');
        }

        let outcome = self.proposed_outcome.read(market_id);
        self.final_outcome.write(market_id, outcome);
        self.status.write(market_id, STATE_RESOLVED);
        refund_proposer(ref self, market_id);
        let now: u256 = starknet::get_block_timestamp().into();
        self.emit(Finalized { market_id, outcome, finalized_at: now });
    }

    #[external(v0)]
    fn fast_finalize(ref self: ContractState, market_id: felt252) {
        let status = self.status.read(market_id);
        assert(status == STATE_PROPOSED, 'Wrong state');
        let fast_path = self.fast_path.read(market_id);
        assert(fast_path == 1, 'Market is not using fast path');
        assert(self.disputed.read(market_id) == 0, 'DISPUTED');

        let verifier = self.verifier.read();
        if !is_zero_address(verifier) {
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
        refund_proposer(ref self, market_id);
        let now: u256 = starknet::get_block_timestamp().into();
        self.emit(FastFinalized { market_id, outcome, finalized_at: now });
    }

    #[external(v0)]
    fn resolve_arbitration(ref self: ContractState, market_id: felt252, outcome: felt252) {
        let status = self.status.read(market_id);
        assert(status == STATE_PROPOSED, 'Wrong state');
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        let arbiter = self.arbiter.read();
        assert(caller == owner || caller == arbiter, 'Not arbiter');

        self.final_outcome.write(market_id, outcome);
        self.status.write(market_id, STATE_RESOLVED);
        self.disputed.write(market_id, 0);
        settle_bonds(ref self, market_id);
        let now: u256 = starknet::get_block_timestamp().into();
        self.emit(ArbitrationResolved { market_id, outcome, resolved_at: now });
    }

    #[external(v0)]
    fn finalize_dispute_timeout(ref self: ContractState, market_id: felt252) {
        let status = self.status.read(market_id);
        assert(status == STATE_PROPOSED, 'Wrong state');
        let disputed = self.disputed.read(market_id);
        assert(disputed == 1, 'Not disputed');
        let timeout = self.dispute_timeout.read();
        let now: u256 = starknet::get_block_timestamp().into();
        if timeout.low != 0 || timeout.high != 0 {
            let disputed_at = self.disputed_at.read(market_id);
            let now_u: u128 = u256_to_u128(now);
            let disputed_u: u128 = u256_to_u128(disputed_at);
            let timeout_u: u128 = u256_to_u128(timeout);
            assert(now_u >= disputed_u, 'Invalid timestamp');
            assert(now_u - disputed_u >= timeout_u, 'Dispute timeout');
        }
        let outcome = self.proposed_outcome.read(market_id);
        self.final_outcome.write(market_id, outcome);
        self.status.write(market_id, STATE_RESOLVED);
        self.disputed.write(market_id, 0);
        settle_bonds(ref self, market_id);
        self.emit(DisputeTimedOut { market_id, outcome, resolved_at: now });
    }

    #[external(v0)]
    fn get_market_status(self: @ContractState, market_id: felt252) -> felt252 {
        self.status.read(market_id)
    }

    #[external(v0)]
    fn is_disputed(self: @ContractState, market_id: felt252) -> bool {
        self.disputed.read(market_id) == 1
    }

    #[external(v0)]
    fn get_final_outcome(self: @ContractState, market_id: felt252) -> felt252 {
        self.final_outcome.read(market_id)
    }

    #[external(v0)]
    fn get_data_hash(self: @ContractState, market_id: felt252) -> felt252 {
        self.data_hash.read(market_id)
    }

    #[external(v0)]
    fn get_dispute_timeout(self: @ContractState) -> u256 {
        self.dispute_timeout.read()
    }

    #[external(v0)]
    fn get_max_commitment_age(self: @ContractState) -> u256 {
        self.max_commitment_age.read()
    }

    #[external(v0)]
    fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        replace_class_syscall(new_class_hash).unwrap_syscall();
        self.emit(Upgraded { class_hash: new_class_hash });
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
        let registered = self.registered.read(market_id);
        assert(registered == 1, 'Market not registered');
        let status = self.status.read(market_id);
        assert(status == STATE_PENDING, 'Market exists');

        let commitment_addr = self.data_commitment.read();
        if !is_zero_address(commitment_addr) {
            let commitment = IDataCommitmentDispatcher { contract_address: commitment_addr };
            let expected = commitment.get_commitment(market_id);
            assert(expected != 0, 'No commitment');
            assert(data_hash == expected, 'Data hash mismatch');
            let max_age = self.max_commitment_age.read();
            if max_age.low != 0 || max_age.high != 0 {
                let updated_at = commitment.get_updated_at(market_id);
                let now: u256 = starknet::get_block_timestamp().into();
                let now_u: u128 = u256_to_u128(now);
                let updated_u: u128 = u256_to_u128(updated_at);
                let max_u: u128 = u256_to_u128(max_age);
                assert(now_u >= updated_u, 'Invalid timestamp');
                assert(now_u - updated_u <= max_u, 'Stale commitment');
            }
        }

        let caller = starknet::get_caller_address();
        let is_reporter = self.reporters.read(caller);
        assert(is_reporter == 1, 'Not reporter');

        let min_bond = self.min_proposer_bond.read();
        assert(bond >= min_bond, 'Bond too low');
        take_bond(ref self, bond);

        self.status.write(market_id, STATE_PROPOSED);
        self.proposed_outcome.write(market_id, outcome);
        self.data_hash.write(market_id, data_hash);
        self.data_uri.write(market_id, data_uri);
        self.proposer.write(market_id, caller);
        self.proposer_bond.write(market_id, bond);
        let proposed_time: u256 = starknet::get_block_timestamp().into();
        self.proposed_at.write(market_id, proposed_time);
        self.disputed.write(market_id, 0);
        self.fast_path.write(market_id, if is_fast_path { 1 } else { 0 });
        self.emit(Proposed {
            market_id,
            outcome,
            data_hash,
            data_uri,
            bond,
            proposer: caller,
            proposed_at: proposed_time,
            fast_path: if is_fast_path { 1 } else { 0 }
        });
    }

    fn take_bond(ref self: ContractState, amount: u256) {
        let token = self.bond_token.read();
        if is_zero_address(token) {
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
        if is_zero_address(token) {
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
        if is_zero_address(token) {
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

    fn u256_to_u128(x: u256) -> u128 {
        assert(x.high == 0, 'u256 overflow');
        x.low
    }
}
