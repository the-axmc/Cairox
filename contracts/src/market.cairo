// CairoxMarket - Prediction market for ecosystem analytics
// Users trade YES/NO tokens on outcomes like "Will ETH daily active wallets exceed 100k?"
use starknet::ContractAddress;
use starknet::get_caller_address;
use starknet::storage::StoragePointerReadAccess;
use starknet::storage::StoragePointerWriteAccess;

#[starknet::contract]
mod CairoxMarket {
    use super::*;

    const PENDING: felt252 = 0;
    const ACTIVE: felt252 = 1;
    const RESOLVED: felt252 = 2;
    const OUTCOME_NO: felt252 = 0;
    const OUTCOME_YES: felt252 = 1;

    #[storage]
    struct Storage {
        owner: ContractAddress,
        collateral_token: ContractAddress,
        oracle: ContractAddress,
        market_question: felt252,
        outcome_token_yess: ContractAddress,
        outcome_token_nos: ContractAddress,
        market_status: felt252,
        resolved_outcome: felt252,
        invariant: u128,
        yes_shares: u128,
        no_shares: u128,
        fee_bps: u64,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        collateral: ContractAddress,
        oracle: ContractAddress,
        question: felt252,
        invariant: u128
    ) {
        self.owner.write(owner);
        self.collateral_token.write(collateral);
        self.oracle.write(oracle);
        self.market_question.write(question);
        self.invariant.write(invariant);
        self.yes_shares.write(0);
        self.no_shares.write(0);
        self.fee_bps.write(20);
        self.market_status.write(PENDING);
    }

    #[external(v0)]
    fn buy_yes(ref self: ContractState, collateral_amount: u128) -> u128 {
        assert(self.market_status.read() == ACTIVE, 'Market not active');
        let cost = internal_calculate_buy_cost(collateral_amount);
        self.yes_shares.write(self.yes_shares.read() + cost);
        cost
    }

    #[external(v0)]
    fn buy_no(ref self: ContractState, collateral_amount: u128) -> u128 {
        assert(self.market_status.read() == ACTIVE, 'Market not active');
        let cost = internal_calculate_buy_cost(collateral_amount);
        self.no_shares.write(self.no_shares.read() + cost);
        cost
    }

    #[external(v0)]
    fn sell_yes(ref self: ContractState, share_amount: u128) -> u128 {
        assert(self.market_status.read() == ACTIVE, 'Market not active');
        assert(self.yes_shares.read() >= share_amount, 'Insufficient shares');
        let redeem = internal_calculate_sell_redeem(share_amount);
        self.yes_shares.write(self.yes_shares.read() - share_amount);
        redeem
    }

    #[external(v0)]
    fn sell_no(ref self: ContractState, share_amount: u128) -> u128 {
        assert(self.market_status.read() == ACTIVE, 'Market not active');
        assert(self.no_shares.read() >= share_amount, 'Insufficient shares');
        let redeem = internal_calculate_sell_redeem(share_amount);
        self.no_shares.write(self.no_shares.read() - share_amount);
        redeem
    }

    #[external(v0)]
    fn get_yes_price(self: @ContractState) -> u128 {
        let yes = self.yes_shares.read();
        let no = self.no_shares.read();
        if yes + no == 0 {
            return 500000000000000000;
        }
        (yes * 1000000000000000000) / (yes + no)
    }

    #[external(v0)]
    fn get_no_price(self: @ContractState) -> u128 {
        let yes = self.yes_shares.read();
        let no = self.no_shares.read();
        if yes + no == 0 {
            return 500000000000000000;
        }
        (no * 1000000000000000000) / (yes + no)
    }

    #[external(v0)]
    fn resolve(ref self: ContractState, outcome: felt252) {
        assert(get_caller_address() == self.oracle.read(), 'Only oracle');
        assert(self.market_status.read() == ACTIVE, 'Not active');
        self.resolved_outcome.write(outcome);
        self.market_status.write(RESOLVED);
    }

    #[external(v0)]
    fn start_trading(ref self: ContractState) {
        assert(get_caller_address() == self.owner.read(), 'Only owner');
        self.market_status.write(ACTIVE);
    }

    #[external(v0)]
    fn get_market_status(self: @ContractState) -> felt252 {
        self.market_status.read()
    }

    #[external(v0)]
    fn get_outcome(self: @ContractState) -> felt252 {
        self.resolved_outcome.read()
    }

    #[external(v0)]
    fn get_total_shares(self: @ContractState) -> u128 {
        self.yes_shares.read() + self.no_shares.read()
    }

    #[external(v0)]
    fn get_question(self: @ContractState) -> felt252 {
        self.market_question.read()
    }

    // Internal helpers
    fn internal_calculate_buy_cost(amount: u128) -> u128 {
        amount
    }

    fn internal_calculate_sell_redeem(amount: u128) -> u128 {
        amount
    }
}
