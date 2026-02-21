// Cairox Market - Prediction Market with LMSR pricing
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

    #[storage]
    struct Storage {
        owner: ContractAddress,
        collateral_token: ContractAddress,
        oracle: ContractAddress,
        fee_bps: u64,
        market_status: felt252,
        outcome: felt252,
        invariant: u128,
        yes_balance: u128,
        no_balance: u128,
        total_shares: u128,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        collateral: ContractAddress,
        oracle: ContractAddress,
        invariant: u128
    ) {
        self.owner.write(owner);
        self.collateral_token.write(collateral);
        self.oracle.write(oracle);
        self.fee_bps.write(20);
        self.invariant.write(invariant);
        self.yes_balance.write(0);
        self.no_balance.write(0);
        self.total_shares.write(0);
        self.market_status.write(PENDING);
    }

    #[external(v0)]
    fn buy_yes(ref self: ContractState, collateral_amount: u128) -> u128 {
        assert(self.market_status.read() == ACTIVE, 'Market not active');
        let shares = collateral_amount; // Simplified
        self.yes_balance.write(self.yes_balance.read() + shares);
        self.total_shares.write(self.total_shares.read() + shares);
        shares
    }

    #[external(v0)]
    fn buy_no(ref self: ContractState, collateral_amount: u128) -> u128 {
        assert(self.market_status.read() == ACTIVE, 'Market not active');
        let shares = collateral_amount;
        self.no_balance.write(self.no_balance.read() + shares);
        self.total_shares.write(self.total_shares.read() + shares);
        shares
    }

    #[external(v0)]
    fn sell_yes(ref self: ContractState, share_amount: u128) -> u128 {
        assert(self.market_status.read() == ACTIVE, 'Market not active');
        self.yes_balance.write(self.yes_balance.read() - share_amount);
        self.total_shares.write(self.total_shares.read() - share_amount);
        share_amount
    }

    #[external(v0)]
    fn sell_no(ref self: ContractState, share_amount: u128) -> u128 {
        assert(self.market_status.read() == ACTIVE, 'Market not active');
        self.no_balance.write(self.no_balance.read() - share_amount);
        self.total_shares.write(self.total_shares.read() - share_amount);
        share_amount
    }

    #[external(v0)]
    fn get_yes_price(self: @ContractState) -> u128 {
        let yes = self.yes_balance.read();
        let no = self.no_balance.read();
        if yes + no == 0 {
            return 500000000000000000;
        }
        (yes * 1000000000000000000) / (yes + no)
    }

    #[external(v0)]
    fn get_no_price(self: @ContractState) -> u128 {
        let yes = self.yes_balance.read();
        let no = self.no_balance.read();
        if yes + no == 0 {
            return 500000000000000000;
        }
        (no * 1000000000000000000) / (yes + no)
    }

    #[external(v0)]
    fn resolve(ref self: ContractState, outcome: felt252) {
        assert(get_caller_address() == self.oracle.read(), 'Only oracle');
        assert(self.market_status.read() == ACTIVE, 'Not active');
        self.outcome.write(outcome);
        self.market_status.write(RESOLVED);
    }

    #[external(v0)]
    fn start_market(ref self: ContractState) {
        assert(get_caller_address() == self.owner.read(), 'Only owner');
        self.market_status.write(ACTIVE);
    }

    #[external(v0)]
    fn get_market_status(self: @ContractState) -> felt252 {
        self.market_status.read()
    }

    #[external(v0)]
    fn get_outcome(self: @ContractState) -> felt252 {
        self.outcome.read()
    }

    #[external(v0)]
    fn get_total_shares(self: @ContractState) -> u128 {
        self.total_shares.read()
    }
}
