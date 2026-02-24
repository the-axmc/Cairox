// DataCommitment - Stores authenticated data hash commitments per market

use starknet::ContractAddress;

#[starknet::contract]
mod DataCommitment {
    use super::ContractAddress;
    use core::box::BoxTrait;
    use core::traits::TryInto;
    use starknet::storage::Map;
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;

    #[storage]
    struct Storage {
        owner: ContractAddress,
        updaters: Map<ContractAddress, u8>,
        commitments: Map<felt252, felt252>,
        updated_at: Map<felt252, u256>,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        let owner = deployer_address();
        self.owner.write(owner);
        self.updaters.write(owner, 1);
    }

    #[external(v0)]
    fn add_updater(ref self: ContractState, updater: ContractAddress) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        self.updaters.write(updater, 1);
    }

    #[external(v0)]
    fn remove_updater(ref self: ContractState, updater: ContractAddress) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        self.updaters.write(updater, 0);
    }

    #[external(v0)]
    fn set_commitment(ref self: ContractState, market_id: felt252, data_hash: felt252) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        let authorized = self.updaters.read(caller);
        assert(caller == owner || authorized == 1, 'Not authorized');
        assert(data_hash != 0, 'Empty hash');
        self.commitments.write(market_id, data_hash);
        let now: u256 = starknet::get_block_timestamp().into();
        self.updated_at.write(market_id, now);
    }

    #[external(v0)]
    fn get_commitment(self: @ContractState, market_id: felt252) -> felt252 {
        self.commitments.read(market_id)
    }

    #[external(v0)]
    fn get_updated_at(self: @ContractState, market_id: felt252) -> u256 {
        self.updated_at.read(market_id)
    }

    #[external(v0)]
    fn get_owner(self: @ContractState) -> ContractAddress {
        self.owner.read()
    }

    fn deployer_address() -> ContractAddress {
        let tx_info = starknet::get_tx_info().unbox();
        tx_info.account_contract_address
    }
}
