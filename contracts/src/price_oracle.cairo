// PriceOracle - Simple EUR price oracle with authorized updaters

use starknet::ContractAddress;

#[starknet::contract]
mod PriceOracle {
    use super::ContractAddress;
    use core::box::BoxTrait;
    use core::traits::TryInto;
    use starknet::SyscallResultTrait;
    use starknet::class_hash::ClassHash;
    use starknet::storage::Map;
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;
    use starknet::syscalls::replace_class_syscall;

    #[storage]
    struct Storage {
        owner: ContractAddress,
        updaters: Map<ContractAddress, u8>,
        price: u256,
        decimals: u8,
        updated_at: u256,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        UpdaterAdded: UpdaterAdded,
        UpdaterRemoved: UpdaterRemoved,
        PriceUpdated: PriceUpdated,
        OwnershipTransferred: OwnershipTransferred,
        Upgraded: Upgraded,
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
    struct PriceUpdated {
        price: u256,
        updated_at: u256,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct OwnershipTransferred {
        #[key]
        previous_owner: ContractAddress,
        #[key]
        new_owner: ContractAddress,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct Upgraded {
        class_hash: ClassHash,
    }

    #[constructor]
    fn constructor(ref self: ContractState, decimals: u8, initial_price: u256) {
        let owner = deployer_address();
        self.owner.write(owner);
        self.updaters.write(owner, 1);
        self.price.write(initial_price);
        self.decimals.write(decimals);
        self.updated_at.write(starknet::get_block_timestamp().into());
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
    fn update_price(ref self: ContractState, price: u256) {
        let caller = starknet::get_caller_address();
        let authorized = self.updaters.read(caller);
        assert(authorized == 1, 'Not authorized');
        self.price.write(price);
        let now: u256 = starknet::get_block_timestamp().into();
        self.updated_at.write(now);
        self.emit(PriceUpdated { price, updated_at: now });
    }

    #[external(v0)]
    fn get_price(self: @ContractState) -> u256 {
        self.price.read()
    }

    #[external(v0)]
    fn get_decimals(self: @ContractState) -> u8 {
        self.decimals.read()
    }

    #[external(v0)]
    fn get_updated_at(self: @ContractState) -> u256 {
        self.updated_at.read()
    }

    #[external(v0)]
    fn get_owner(self: @ContractState) -> ContractAddress {
        self.owner.read()
    }

    #[external(v0)]
    fn transfer_ownership(ref self: ContractState, new_owner: ContractAddress) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        self.owner.write(new_owner);
        self.emit(OwnershipTransferred { previous_owner: owner, new_owner });
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

    fn deployer_address() -> ContractAddress {
        let tx_info = starknet::get_tx_info().unbox();
        tx_info.account_contract_address
    }
}
