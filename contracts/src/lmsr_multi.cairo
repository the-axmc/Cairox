// LMSRMulti - Multi-outcome LMSR for markets with more than 2 outcomes

#[starknet::contract]
mod LMSRMulti {
    use starknet::storage::Map;
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;

    #[storage]
    struct Storage {
        owner: felt252,
        b_params: Map<felt252, u256>,
        // Store outcome prices for a market
        outcome_prices: Map<(felt252, felt252), u256>,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        let caller: felt252 = starknet::get_caller_address().into();
        self.owner.write(caller);
    }

    #[external(v0)]
    fn set_b_param(ref self: ContractState, market: felt252, b: u256) {
        self.b_params.write(market, b);
    }

    #[external(v0)]
    fn set_price(ref self: ContractState, market: felt252, outcome: felt252, price: u256) {
        self.outcome_prices.write((market, outcome), price);
    }

    #[external(v0)]
    fn get_price(self: @ContractState, market: felt252, outcome: felt252) -> u256 {
        self.outcome_prices.read((market, outcome))
    }

    #[external(v0)]
    fn calculate_payout(
        self: @ContractState,
        market: felt252,
        outcome: felt252,
        amount: u256
    ) -> u256 {
        let price = self.outcome_prices.read((market, outcome));
        amount * price
    }
}
