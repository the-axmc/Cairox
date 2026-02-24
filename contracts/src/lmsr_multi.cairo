// LMSRMulti - Multi-outcome LMSR for markets with more than 2 outcomes

#[starknet::contract]
mod LMSRMulti {
    use core::box::BoxTrait;
    use starknet::storage::Map;
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;
    use starknet::ContractAddress;

    #[storage]
    struct Storage {
        owner: felt252,
        b_params: Map<felt252, u256>,
        // Store outcome prices for a market
        outcome_prices: Map<(felt252, felt252), u256>,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        let owner = deployer_felt();
        self.owner.write(owner);
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

    fn is_zero_address(addr: ContractAddress) -> bool {
        let felt: felt252 = addr.into();
        felt == 0
    }

    fn deployer_felt() -> felt252 {
        let tx_info = starknet::get_tx_info().unbox();
        tx_info.account_contract_address.into()
    }
}
