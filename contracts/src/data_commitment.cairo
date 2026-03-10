// DataCommitment - Stores authenticated data hash commitments per market

use starknet::ContractAddress;

#[starknet::contract]
mod DataCommitment {
    use super::ContractAddress;
    use core::box::BoxTrait;
    use core::ecdsa::check_ecdsa_signature;
    use core::pedersen::pedersen;
    use core::traits::TryInto;
    use starknet::SyscallResultTrait;
    use starknet::class_hash::ClassHash;
    use starknet::storage::Map;
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;
    use starknet::syscalls::replace_class_syscall;

    const DOMAIN: felt252 = 'MSTATE';

    #[storage]
    struct Storage {
        owner: ContractAddress,
        signer_pubkey: felt252,
        updaters: Map<ContractAddress, u8>,
        commitments: Map<felt252, u256>,
        updated_at: Map<felt252, u256>,
        max_commitment_age: u256,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        SignerSet: SignerSet,
        UpdaterAdded: UpdaterAdded,
        UpdaterRemoved: UpdaterRemoved,
        CommitmentSet: CommitmentSet,
        CommitmentSetSigned: CommitmentSetSigned,
        MaxCommitmentAgeSet: MaxCommitmentAgeSet,
        Upgraded: Upgraded,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct SignerSet {
        #[key]
        pubkey: felt252,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct UpdaterAdded {
        #[key]
        updater: ContractAddress,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct UpdaterRemoved {
        #[key]
        updater: ContractAddress,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct CommitmentSet {
        #[key]
        market_id: felt252,
        data_hash: u256,
        updated_at: u256,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct CommitmentSetSigned {
        #[key]
        market_id: felt252,
        data_hash: u256,
        updated_at: u256,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct MaxCommitmentAgeSet {
        max_age: u256,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct Upgraded {
        class_hash: ClassHash,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        let owner = deployer_address();
        self.owner.write(owner);
        self.signer_pubkey.write(0);
        self.updaters.write(owner, 1);
        self.max_commitment_age.write(u256 { low: 3600, high: 0 });
    }

    #[external(v0)]
    fn set_signer_pubkey(ref self: ContractState, pubkey: felt252) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        self.signer_pubkey.write(pubkey);
        self.emit(SignerSet { pubkey });
    }

    #[external(v0)]
    fn add_updater(ref self: ContractState, updater: ContractAddress) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        self.updaters.write(updater, 1);
        self.emit(UpdaterAdded { updater });
    }

    #[external(v0)]
    fn remove_updater(ref self: ContractState, updater: ContractAddress) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        self.updaters.write(updater, 0);
        self.emit(UpdaterRemoved { updater });
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
    fn set_commitment(ref self: ContractState, market_id: felt252, data_hash: u256) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        let authorized = self.updaters.read(caller);
        assert(caller == owner || authorized == 1, 'Not authorized');
        assert(!is_zero_u256(data_hash), 'Empty hash');
        self.commitments.write(market_id, data_hash);
        let now: u256 = starknet::get_block_timestamp().into();
        self.updated_at.write(market_id, now);
        self.emit(CommitmentSet { market_id, data_hash, updated_at: now });
    }

    #[external(v0)]
    fn set_commitment_signed(
        ref self: ContractState,
        market_id: felt252,
        data_hash: u256,
        sig_r: felt252,
        sig_s: felt252
    ) {
        let pubkey = self.signer_pubkey.read();
        assert(pubkey != 0, 'Signer not set');
        assert(!is_zero_u256(data_hash), 'Empty hash');
        let msg_hash = message_hash(market_id, data_hash);
        let ok = check_ecdsa_signature(msg_hash, pubkey, sig_r, sig_s);
        assert(ok, 'Invalid signature');
        self.commitments.write(market_id, data_hash);
        let now: u256 = starknet::get_block_timestamp().into();
        self.updated_at.write(market_id, now);
        self.emit(CommitmentSetSigned { market_id, data_hash, updated_at: now });
    }

    #[external(v0)]
    fn get_commitment(self: @ContractState, market_id: felt252) -> u256 {
        self.commitments.read(market_id)
    }

    #[external(v0)]
    fn get_updated_at(self: @ContractState, market_id: felt252) -> u256 {
        self.updated_at.read(market_id)
    }

    #[external(v0)]
    fn get_max_commitment_age(self: @ContractState) -> u256 {
        self.max_commitment_age.read()
    }

    #[external(v0)]
    fn get_commitment_fresh(self: @ContractState, market_id: felt252) -> u256 {
        let value = self.commitments.read(market_id);
        let max_age = self.max_commitment_age.read();
        if max_age.low != 0 || max_age.high != 0 {
            let updated_at = self.updated_at.read(market_id);
            let now: u256 = starknet::get_block_timestamp().into();
            let now_u: u128 = u256_to_u128(now);
            let updated_u: u128 = u256_to_u128(updated_at);
            let max_u: u128 = u256_to_u128(max_age);
            assert(now_u >= updated_u, 'Invalid timestamp');
            assert(now_u - updated_u <= max_u, 'Stale commitment');
        }
        value
    }

    #[external(v0)]
    fn get_owner(self: @ContractState) -> ContractAddress {
        self.owner.read()
    }

    #[external(v0)]
    fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        replace_class_syscall(new_class_hash).unwrap_syscall();
        self.emit(Upgraded { class_hash: new_class_hash });
    }

    fn message_hash(market_id: felt252, data_hash: u256) -> felt252 {
        let acc = pedersen(market_id, data_hash.low.into());
        let acc = pedersen(acc, data_hash.high.into());
        pedersen(acc, domain_separator())
    }

    fn domain_separator() -> felt252 {
        let tx_info = starknet::get_tx_info().unbox();
        let chain_id = tx_info.chain_id;
        let addr: felt252 = starknet::get_contract_address().into();
        let acc = pedersen(DOMAIN, chain_id);
        pedersen(acc, addr)
    }

    fn u256_to_u128(x: u256) -> u128 {
        assert(x.high == 0, 'u256 overflow');
        x.low
    }

    fn is_zero_u256(value: u256) -> bool {
        value.low == 0 && value.high == 0
    }

    fn deployer_address() -> ContractAddress {
        let tx_info = starknet::get_tx_info().unbox();
        tx_info.account_contract_address
    }
}
