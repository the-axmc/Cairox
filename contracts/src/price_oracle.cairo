// PriceOracle - Simple EUR price oracle with authorized updaters

use starknet::ContractAddress;

#[starknet::contract]
mod PriceOracle {
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
        price: u256,
        decimals: u8,
        updated_at: u256,
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
    }

    #[external(v0)]
    fn remove_updater(ref self: ContractState, updater: ContractAddress) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        self.updaters.write(updater, 0);
    }

    #[external(v0)]
    fn update_price(ref self: ContractState, price: u256) {
        let caller = starknet::get_caller_address();
        let authorized = self.updaters.read(caller);
        assert(authorized == 1, 'Not authorized');
        self.price.write(price);
        self.updated_at.write(starknet::get_block_timestamp().into());
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

    fn is_zero_address(addr: ContractAddress) -> bool {
        let felt: felt252 = addr.into();
        felt == 0
    }

    fn deployer_address() -> ContractAddress {
        let tx_info = starknet::get_tx_info().unbox();
        tx_info.account_contract_address
    }
}
