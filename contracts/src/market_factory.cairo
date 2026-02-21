// MarketFactory - Creates and manages markets

#[starknet::contract]
mod MarketFactory {
    use starknet::storage::Map;
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;

    #[storage]
    struct Storage {
        owner: felt252,
        collateral_vault: felt252,
        outcome_token_template: felt252,
        market_count: u256,
        // market_id -> market info
        markets: Map<u256, felt252>,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        collateral_vault: felt252,
        outcome_token_template: felt252
    ) {
        self.owner.write(0);
        self.collateral_vault.write(collateral_vault);
        self.outcome_token_template.write(outcome_token_template);
        self.market_count.write(u256 { low: 0, high: 0 });
    }

    #[external(v0)]
    fn create_market(ref self: ContractState, question: felt252) -> u256 {
        let id = self.market_count.read();
        self.market_count.write(id + u256 { low: 1, high: 0 });
        // Store market address (placeholder)
        self.markets.write(id, 0);
        id
    }

    #[external(v0)]
    fn get_market_count(self: @ContractState) -> u256 {
        self.market_count.read()
    }

    #[external(v0)]
    fn get_market(self: @ContractState, market_id: u256) -> felt252 {
        self.markets.read(market_id)
    }
}
