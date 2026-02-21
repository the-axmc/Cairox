// MarketFactory - Deploys and tracks Cairox markets
use starknet::ContractAddress;
use starknet::get_caller_address;
use starknet::storage::StoragePointerReadAccess;
use starknet::storage::StoragePointerWriteAccess;
use starknet::storage::Map;

#[starknet::contract]
mod MarketFactory {
    use super::*;

    #[storage]
    struct Storage {
        owner: ContractAddress,
        markets: Map<u256, ContractAddress>,
        market_questions: Map<ContractAddress, felt252>,
        is_market: Map<ContractAddress, bool>,
        market_count: u256,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        self.owner.write(get_caller_address());
        self.market_count.write(0);
    }

    #[external(v0)]
    fn create_market(
        ref self: ContractState,
        market_address: ContractAddress,
        question: felt252
    ) -> u256 {
        assert(get_caller_address() == self.owner.read(), 'Only owner');
        let id = self.market_count.read();
        self.markets.write(id, market_address);
        self.market_questions.write(market_address, question);
        self.is_market.write(market_address, true);
        self.market_count.write(id + 1);
        id
    }

    #[external(v0)]
    fn get_market_count(self: @ContractState) -> u256 {
        self.market_count.read()
    }

    #[external(v0)]
    fn get_market(self: @ContractState, id: u256) -> ContractAddress {
        self.markets.read(id)
    }

    #[external(v0)]
    fn get_market_question(self: @ContractState, market: ContractAddress) -> felt252 {
        self.market_questions.read(market)
    }

    #[external(v0)]
    fn is_valid_market(self: @ContractState, market: ContractAddress) -> bool {
        self.is_market.read(market)
    }
}
