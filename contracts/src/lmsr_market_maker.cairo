// LMSRMarketMaker - Binary outcome market maker with LMSR pricing
use starknet::ContractAddress;
use starknet::get_caller_address;
use starknet::storage::StoragePointerReadAccess;
use starknet::storage::StoragePointerWriteAccess;
use starknet::storage::Map;

#[starknet::contract]
mod LMSRMarketMaker {
    use super::*;

    #[storage]
    struct Storage {
        owner: ContractAddress,
        market: ContractAddress,
        invariant: u128,
        outcome_tokens: Map<felt252, ContractAddress>,
        token_balances: Map<felt252, u128>,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        market: ContractAddress,
        invariant: u128
    ) {
        self.owner.write(owner);
        self.market.write(market);
        self.invariant.write(invariant);
        self.token_balances.write(0, 0); // YES
        self.token_balances.write(1, 0); // NO
    }

    #[external(v0)]
    fn get_price(self: @ContractState, outcome: felt252) -> u128 {
        let yes = self.token_balances.read(0);
        let no = self.token_balances.read(1);
        let total = yes + no;
        if total == 0 {
            return 500000000000000000;
        }
        if outcome == 0 {
            (yes * 1000000000000000000) / total
        } else {
            (no * 1000000000000000000) / total
        }
    }

    #[external(v0)]
    fn get_total_shares(self: @ContractState) -> u128 {
        self.token_balances.read(0) + self.token_balances.read(1)
    }

    #[external(v0)]
    fn calculate_cost(self: @ContractState, outcome: felt252, amount: u128) -> u128 {
        let price = self.get_price(outcome);
        (amount * price) / 1000000000000000000
    }

    #[external(v0)]
    fn calculate_redeem(self: @ContractState, outcome: felt252, amount: u128) -> u128 {
        let price = self.get_price(outcome);
        (amount * price) / 1000000000000000000
    }

    #[external(v0)]
    fn set_invariant(ref self: ContractState, new_invariant: u128) {
        assert(get_caller_address() == self.owner.read(), 'Only owner');
        self.invariant.write(new_invariant);
    }

    #[external(v0)]
    fn update_balance(ref self: ContractState, outcome: felt252, new_balance: u128) {
        assert(get_caller_address() == self.market.read(), 'Only market');
        self.token_balances.write(outcome, new_balance);
    }

    #[external(v0)]
    fn get_invariant(self: @ContractState) -> u128 {
        self.invariant.read()
    }

    #[external(v0)]
    fn get_token_balance(self: @ContractState, outcome: felt252) -> u128 {
        self.token_balances.read(outcome)
    }
}
