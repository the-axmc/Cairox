// LMSRMulti - Categorical outcome market maker
use starknet::ContractAddress;
use starknet::get_caller_address;
use starknet::storage::StoragePointerReadAccess;
use starknet::storage::StoragePointerWriteAccess;
use starknet::storage::Map;

#[starknet::contract]
mod LMSRMulti {
    use super::*;

    #[storage]
    struct Storage {
        owner: ContractAddress,
        market: ContractAddress,
        invariant: u128,
        outcome_count: u32,
        outcome_tokens: Map<u32, ContractAddress>,
        token_balances: Map<u32, u128>,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        market: ContractAddress,
        outcome_count: u32,
        invariant: u128
    ) {
        self.owner.write(owner);
        self.market.write(market);
        self.outcome_count.write(outcome_count);
        self.invariant.write(invariant);
    }

    #[external(v0)]
    fn get_price(self: @ContractState, outcome: u32) -> u128 {
        let count = self.outcome_count.read();
        if count == 0 {
            return 0;
        }
        let mut total: u128 = 0;
        let mut i: u32 = 0;
        loop {
            if i >= count {
                break;
            }
            total = total + self.token_balances.read(i);
            i += 1;
        };
        
        if total == 0 {
            return 1000000000000000000 / count.into();
        }
        
        let outcome_shares = self.token_balances.read(outcome);
        (outcome_shares * 1000000000000000000) / total
    }

    #[external(v0)]
    fn get_total_shares(self: @ContractState) -> u128 {
        let count = self.outcome_count.read();
        let mut total: u128 = 0;
        let mut i: u32 = 0;
        loop {
            if i >= count {
                break;
            }
            total = total + self.token_balances.read(i);
            i += 1;
        };
        total
    }

    #[external(v0)]
    fn calculate_cost(self: @ContractState, outcome: u32, amount: u128) -> u128 {
        let price = self.get_price(outcome);
        (amount * price) / 1000000000000000000
    }

    #[external(v0)]
    fn update_balance(ref self: ContractState, outcome: u32, new_balance: u128) {
        assert(get_caller_address() == self.market.read(), 'Only market');
        self.token_balances.write(outcome, new_balance);
    }

    #[external(v0)]
    fn set_invariant(ref self: ContractState, new_invariant: u128) {
        assert(get_caller_address() == self.owner.read(), 'Only owner');
        self.invariant.write(new_invariant);
    }

    #[external(v0)]
    fn get_outcome_count(self: @ContractState) -> u32 {
        self.outcome_count.read()
    }

    #[external(v0)]
    fn get_token_balance(self: @ContractState, outcome: u32) -> u128 {
        self.token_balances.read(outcome)
    }
}
