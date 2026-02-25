// ShieldedPool - ZK-based private trading pool for outcome markets

use starknet::ContractAddress;

#[starknet::interface]
trait IERC20<TContractState> {
    fn transfer(ref self: TContractState, to: ContractAddress, amount: u256) -> bool;
}

#[starknet::interface]
trait IMarket<TContractState> {
    fn buy(ref self: TContractState, outcome: felt252, collateral_amount: u256, min_tokens: u256) -> u256;
    fn sell(ref self: TContractState, outcome: felt252, token_amount: u256, min_collateral: u256) -> u256;
    fn redeem(ref self: TContractState) -> u256;
}

#[starknet::interface]
trait IGroth16VerifierBN254<TContractState> {
    fn verify_groth16_proof_bn254(
        self: @TContractState,
        full_proof_with_hints: Span<felt252>
    ) -> Option<Span<u256>>;
}

#[starknet::interface]
trait IDataCommitment<TContractState> {
    fn get_commitment(self: @TContractState, market_id: felt252) -> felt252;
}

#[starknet::contract]
mod ShieldedPool {
    use super::{
        IERC20Dispatcher, IERC20DispatcherTrait, IMarketDispatcher, IMarketDispatcherTrait,
        IGroth16VerifierBN254Dispatcher, IGroth16VerifierBN254DispatcherTrait,
        IDataCommitmentDispatcher, IDataCommitmentDispatcherTrait,
    };
    use core::array::Span;
    use core::array::SpanTrait;
    use core::box::BoxTrait;
    use core::option::OptionTrait;
    use core::traits::TryInto;
    use core::integer::u256_from_felt252;
    use starknet::ContractAddress;
    use starknet::storage::Map;
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;
    use starknet::SyscallResultTrait;
    use starknet::class_hash::ClassHash;
    use starknet::syscalls::replace_class_syscall;

    const ACTION_NONE: felt252 = 0;
    const ACTION_BUY: felt252 = 1;
    const ACTION_SELL: felt252 = 2;
    const ACTION_REDEEM: felt252 = 3;

    #[storage]
    struct Storage {
        owner: ContractAddress,
        verifier: ContractAddress,
        collateral_token: ContractAddress,
        data_commitment: ContractAddress,
        merkle_root: felt252,
        relayer_fee_bps: u16,
        locked: bool,
        nullifiers: Map<felt252, u8>,
        markets: Map<felt252, ContractAddress>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        RootUpdated: RootUpdated,
        NullifierUsed: NullifierUsed,
        ActionExecuted: ActionExecuted,
        Upgraded: Upgraded,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct RootUpdated {
        #[key]
        old_root: felt252,
        #[key]
        new_root: felt252,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct NullifierUsed {
        #[key]
        nullifier: felt252,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct ActionExecuted {
        #[key]
        action: felt252,
        #[key]
        market_id: felt252,
        amount: u256,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct Upgraded {
        class_hash: ClassHash,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        collateral_token: ContractAddress,
        verifier: ContractAddress,
        initial_root: felt252
    ) {
        let owner = deployer_address();
        self.owner.write(owner);
        self.collateral_token.write(collateral_token);
        self.verifier.write(verifier);
        self.data_commitment.write(zero_address());
        self.merkle_root.write(initial_root);
        self.relayer_fee_bps.write(0);
        self.locked.write(false);
    }

    #[external(v0)]
    fn set_verifier(ref self: ContractState, verifier: ContractAddress) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        self.verifier.write(verifier);
    }

    #[external(v0)]
    fn set_market(ref self: ContractState, market_id: felt252, market: ContractAddress) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        self.markets.write(market_id, market);
    }

    #[external(v0)]
    fn set_data_commitment(ref self: ContractState, commitment: ContractAddress) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        self.data_commitment.write(commitment);
    }

    #[external(v0)]
    fn set_relayer_fee_bps(ref self: ContractState, fee_bps: u16) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        self.relayer_fee_bps.write(fee_bps);
    }

    #[external(v0)]
    fn get_root(self: @ContractState) -> felt252 {
        self.merkle_root.read()
    }

    #[external(v0)]
    fn is_nullifier_used(self: @ContractState, nullifier: felt252) -> bool {
        self.nullifiers.read(nullifier) == 1
    }

    #[external(v0)]
    fn transact(
        ref self: ContractState,
        old_root: felt252,
        new_root: felt252,
        nullifiers: Span<felt252>,
        market_state_hash: felt252,
        action: felt252,
        market_id: felt252,
        outcome: felt252,
        amount: u256,
        limit: u256,
        relayer: ContractAddress,
        relayer_fee: u256,
        proof: Span<felt252>
    ) -> bool {
        assert(!self.locked.read(), 'Reentrancy');
        self.locked.write(true);

        // Check root matches.
        let current_root = self.merkle_root.read();
        assert(current_root == old_root, 'Invalid root');

        // Verify ZK proof and public inputs.
        let verifier = self.verifier.read();
        assert(!is_zero_address(verifier), 'Verifier not set');
        let verifier_dispatcher = IGroth16VerifierBN254Dispatcher { contract_address: verifier };
        let inputs_opt = verifier_dispatcher.verify_groth16_proof_bn254(proof);
        assert(inputs_opt.is_some(), 'Invalid proof');
        let inputs = inputs_opt.unwrap();

        // Expect fixed public inputs layout:
        // [old_root, new_root, nullifier1, nullifier2, market_state_hash, action, market_id, outcome,
        //  amount_low, amount_high, limit_low, limit_high, relayer, fee_low, fee_high]
        assert(inputs.len() == 15, 'Invalid public inputs');
        assert(*inputs.at(0) == old_root.into(), 'Input root mismatch');
        assert(*inputs.at(1) == new_root.into(), 'Input root mismatch');
        assert(*inputs.at(4) == market_state_hash.into(), 'State hash mismatch');
        assert(*inputs.at(5) == action.into(), 'Action mismatch');
        assert(*inputs.at(6) == market_id.into(), 'Market mismatch');
        assert(*inputs.at(7) == outcome.into(), 'Outcome mismatch');
        assert(*inputs.at(8) == amount.low.into(), 'Amount mismatch');
        assert(*inputs.at(9) == amount.high.into(), 'Amount mismatch');
        assert(*inputs.at(10) == limit.low.into(), 'Limit mismatch');
        assert(*inputs.at(11) == limit.high.into(), 'Limit mismatch');
        let relayer_felt: felt252 = relayer.into();
        let relayer_u = u256_from_felt252(relayer_felt);
        assert(*inputs.at(12) == relayer_u, 'Relayer mismatch');
        assert(*inputs.at(13) == relayer_fee.low.into(), 'Fee mismatch');
        assert(*inputs.at(14) == relayer_fee.high.into(), 'Fee mismatch');

        // Validate and mark nullifiers (fixed to 2 for now).
        assert(nullifiers.len() == 2, 'Invalid nullifiers');
        let n0 = *nullifiers.at(0);
        let n1 = *nullifiers.at(1);
        assert(self.nullifiers.read(n0) == 0, 'Nullifier used');
        assert(self.nullifiers.read(n1) == 0, 'Nullifier used');
        self.nullifiers.write(n0, 1);
        self.nullifiers.write(n1, 1);
        self.emit(NullifierUsed { nullifier: n0 });
        self.emit(NullifierUsed { nullifier: n1 });

        // Update root.
        self.merkle_root.write(new_root);
        self.emit(RootUpdated { old_root, new_root });

        // Check committed market state hash if configured.
        let commitment_addr = self.data_commitment.read();
        if !is_zero_address(commitment_addr) {
            let commitment = IDataCommitmentDispatcher { contract_address: commitment_addr };
            let expected = commitment.get_commitment(market_id);
            assert(expected != 0, 'No commitment');
            assert(expected == market_state_hash, 'State commitment mismatch');
        }

        // Execute market action as the pool.
        if action != ACTION_NONE {
            let market_addr = self.markets.read(market_id);
            assert(!is_zero_address(market_addr), 'Market not set');
            let market = IMarketDispatcher { contract_address: market_addr };
            if action == ACTION_BUY {
                market.buy(outcome, amount, limit);
            } else if action == ACTION_SELL {
                market.sell(outcome, amount, limit);
            } else if action == ACTION_REDEEM {
                market.redeem();
            } else {
                assert(false, 'Invalid action');
            }
            self.emit(ActionExecuted { action, market_id, amount });
        }

        // Pay relayer fee (from pool collateral balance).
        if !is_zero_u256(relayer_fee) {
            let token = self.collateral_token.read();
            let erc20 = IERC20Dispatcher { contract_address: token };
            let ok = erc20.transfer(relayer, relayer_fee);
            assert(ok, 'Relayer fee failed');
        }

        self.locked.write(false);
        true
    }

    #[external(v0)]
    fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        replace_class_syscall(new_class_hash).unwrap_syscall();
        self.emit(Upgraded { class_hash: new_class_hash });
    }

    fn is_zero_address(addr: ContractAddress) -> bool {
        let felt: felt252 = addr.into();
        felt == 0
    }

    fn zero_address() -> ContractAddress {
        0.try_into().unwrap()
    }

    fn is_zero_u256(value: u256) -> bool {
        value.low == 0 && value.high == 0
    }

    fn deployer_address() -> ContractAddress {
        let tx_info = starknet::get_tx_info().unbox();
        tx_info.account_contract_address
    }
}
