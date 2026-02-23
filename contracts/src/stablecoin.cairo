// Stablecoin - Simple ERC20 with owner-controlled mint/burn

use starknet::ContractAddress;

#[starknet::interface]
trait IChainlinkAggregator<TContractState> {
    fn latest_round_data(self: @TContractState) -> (u256, u256, u256, u256, u256);
    fn decimals(self: @TContractState) -> u8;
}

#[starknet::interface]
trait IPriceOracle<TContractState> {
    fn get_price(self: @TContractState) -> u256;
    fn get_decimals(self: @TContractState) -> u8;
    fn get_updated_at(self: @TContractState) -> u256;
}

#[starknet::contract]
mod Stablecoin {
    use super::{
        ContractAddress, IChainlinkAggregatorDispatcher, IChainlinkAggregatorDispatcherTrait,
        IPriceOracleDispatcher, IPriceOracleDispatcherTrait,
    };
    use starknet::storage::Map;
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;

    #[storage]
    struct Storage {
        name: felt252,
        symbol: felt252,
        decimals: u8,
        owner: ContractAddress,
        price_feed: ContractAddress,
        price_feed_type: u8,
        total_supply: u256,
        balances: Map<ContractAddress, u256>,
        allowances: Map<(ContractAddress, ContractAddress), u256>,
    }

    const PRICE_FEED_CHAINLINK: u8 = 0;
    const PRICE_FEED_ORACLE: u8 = 1;

    #[constructor]
    fn constructor(
        ref self: ContractState,
        name: felt252,
        symbol: felt252,
        decimals: u8,
        owner: ContractAddress,
        initial_supply: u256,
        recipient: ContractAddress,
        price_feed: ContractAddress,
        price_feed_type: u8,
    ) {
        assert(
            price_feed_type == PRICE_FEED_CHAINLINK | price_feed_type == PRICE_FEED_ORACLE,
            'Invalid feed type'
        );
        self.name.write(name);
        self.symbol.write(symbol);
        self.decimals.write(decimals);
        self.owner.write(owner);
        self.price_feed.write(price_feed);
        self.price_feed_type.write(price_feed_type);
        self.total_supply.write(initial_supply);
        self.balances.write(recipient, initial_supply);
    }

    #[external(v0)]
    fn name(self: @ContractState) -> felt252 {
        self.name.read()
    }

    #[external(v0)]
    fn symbol(self: @ContractState) -> felt252 {
        self.symbol.read()
    }

    #[external(v0)]
    fn decimals(self: @ContractState) -> u8 {
        self.decimals.read()
    }

    #[external(v0)]
    fn total_supply(self: @ContractState) -> u256 {
        self.total_supply.read()
    }

    #[external(v0)]
    fn balance_of(self: @ContractState, account: ContractAddress) -> u256 {
        self.balances.read(account)
    }

    #[external(v0)]
    fn allowance(self: @ContractState, owner: ContractAddress, spender: ContractAddress) -> u256 {
        self.allowances.read((owner, spender))
    }

    #[external(v0)]
    fn approve(ref self: ContractState, spender: ContractAddress, amount: u256) -> bool {
        let owner = starknet::get_caller_address();
        self.allowances.write((owner, spender), amount);
        true
    }

    #[external(v0)]
    fn transfer(ref self: ContractState, to: ContractAddress, amount: u256) -> bool {
        let from = starknet::get_caller_address();
        let balance = self.balances.read(from);
        assert(balance >= amount, 'Insufficient balance');

        self.balances.write(from, balance - amount);
        let to_balance = self.balances.read(to);
        self.balances.write(to, to_balance + amount);
        true
    }

    #[external(v0)]
    fn transfer_from(
        ref self: ContractState,
        from: ContractAddress,
        to: ContractAddress,
        amount: u256
    ) -> bool {
        let spender = starknet::get_caller_address();
        let allowance = self.allowances.read((from, spender));
        assert(allowance >= amount, 'Allowance exceeded');
        self.allowances.write((from, spender), allowance - amount);

        let balance = self.balances.read(from);
        assert(balance >= amount, 'Insufficient balance');
        self.balances.write(from, balance - amount);

        let to_balance = self.balances.read(to);
        self.balances.write(to, to_balance + amount);
        true
    }

    #[external(v0)]
    fn mint(ref self: ContractState, to: ContractAddress, amount: u256) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');

        let supply = self.total_supply.read();
        self.total_supply.write(supply + amount);

        let balance = self.balances.read(to);
        self.balances.write(to, balance + amount);
    }

    #[external(v0)]
    fn burn(ref self: ContractState, from: ContractAddress, amount: u256) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');

        let balance = self.balances.read(from);
        assert(balance >= amount, 'Insufficient balance');
        self.balances.write(from, balance - amount);

        let supply = self.total_supply.read();
        self.total_supply.write(supply - amount);
    }

    #[external(v0)]
    fn transfer_ownership(ref self: ContractState, new_owner: ContractAddress) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        self.owner.write(new_owner);
    }

    #[external(v0)]
    fn get_owner(self: @ContractState) -> ContractAddress {
        self.owner.read()
    }

    #[external(v0)]
    fn set_price_feed(ref self: ContractState, feed: ContractAddress, feed_type: u8) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        assert(
            feed_type == PRICE_FEED_CHAINLINK | feed_type == PRICE_FEED_ORACLE,
            'Invalid feed type'
        );
        self.price_feed.write(feed);
        self.price_feed_type.write(feed_type);
    }

    #[external(v0)]
    fn get_price_feed(self: @ContractState) -> ContractAddress {
        self.price_feed.read()
    }

    #[external(v0)]
    fn get_price_feed_type(self: @ContractState) -> u8 {
        self.price_feed_type.read()
    }

    #[external(v0)]
    fn get_latest_price(self: @ContractState) -> u256 {
        let feed = self.price_feed.read();
        assert(feed.value != 0, 'No price feed');
        let feed_type = self.price_feed_type.read();
        if feed_type == PRICE_FEED_CHAINLINK {
            let aggregator = IChainlinkAggregatorDispatcher { contract_address: feed };
            let (_, answer, _, _, _) = aggregator.latest_round_data();
            answer
        } else {
            let oracle = IPriceOracleDispatcher { contract_address: feed };
            oracle.get_price()
        }
    }

    #[external(v0)]
    fn get_price_decimals(self: @ContractState) -> u8 {
        let feed = self.price_feed.read();
        assert(feed.value != 0, 'No price feed');
        let feed_type = self.price_feed_type.read();
        if feed_type == PRICE_FEED_CHAINLINK {
            let aggregator = IChainlinkAggregatorDispatcher { contract_address: feed };
            aggregator.decimals()
        } else {
            let oracle = IPriceOracleDispatcher { contract_address: feed };
            oracle.get_decimals()
        }
    }

    #[external(v0)]
    fn get_price_updated_at(self: @ContractState) -> u256 {
        let feed = self.price_feed.read();
        assert(feed.value != 0, 'No price feed');
        let feed_type = self.price_feed_type.read();
        if feed_type == PRICE_FEED_CHAINLINK {
            let aggregator = IChainlinkAggregatorDispatcher { contract_address: feed };
            let (_, _, _, updated_at, _) = aggregator.latest_round_data();
            updated_at
        } else {
            let oracle = IPriceOracleDispatcher { contract_address: feed };
            oracle.get_updated_at()
        }
    }
}
