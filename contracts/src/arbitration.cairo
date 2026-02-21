// Arbitration - Dispute resolution for Cairox markets
use starknet::ContractAddress;
use starknet::get_caller_address;
use starknet::storage::StoragePointerReadAccess;
use starknet::storage::StoragePointerWriteAccess;
use starknet::storage::Map;

#[starknet::contract]
mod Arbitration {
    use super::*;

    const NO_DISPUTE: felt252 = 0;
    const DISPUTE_OPEN: felt252 = 1;
    const RESOLVED: felt252 = 2;

    #[storage]
    struct Storage {
        owner: ContractAddress,
        arbiter: ContractAddress,
        dispute_fee: u128,
        protocol_fee_bps: u64,
        dispute_market: Map<felt252, felt252>,  // market_id -> status
        dispute_reason: Map<felt252, felt252>,
        final_outcome: Map<felt252, felt252>,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        let caller = get_caller_address();
        self.owner.write(caller);
        self.arbiter.write(caller);
        self.dispute_fee.write(100);
        self.protocol_fee_bps.write(10);
    }

    #[external(v0)]
    fn open_dispute(ref self: ContractState, market_id: felt252, reason: felt252) {
        let status = self.dispute_market.read(market_id);
        assert(status == NO_DISPUTE, 'Dispute already active');
        self.dispute_market.write(market_id, DISPUTE_OPEN);
        self.dispute_reason.write(market_id, reason);
    }

    #[external(v0)]
    fn resolve_dispute(ref self: ContractState, market_id: felt252, outcome: felt252) {
        assert(get_caller_address() == self.arbiter.read(), 'Only arbiter');
        let status = self.dispute_market.read(market_id);
        assert(status == DISPUTE_OPEN, 'No active dispute');
        self.final_outcome.write(market_id, outcome);
        self.dispute_market.write(market_id, RESOLVED);
    }

    #[external(v0)]
    fn dismiss_dispute(ref self: ContractState, market_id: felt252) {
        assert(get_caller_address() == self.arbiter.read(), 'Only arbiter');
        self.dispute_market.write(market_id, NO_DISPUTE);
    }

    #[external(v0)]
    fn set_arbiter(ref self: ContractState, new_arbiter: ContractAddress) {
        assert(get_caller_address() == self.owner.read(), 'Only owner');
        self.arbiter.write(new_arbiter);
    }

    #[external(v0)]
    fn set_dispute_fee(ref self: ContractState, fee: u128) {
        assert(get_caller_address() == self.owner.read(), 'Only owner');
        self.dispute_fee.write(fee);
    }

    #[external(v0)]
    fn get_arbiter(self: @ContractState) -> ContractAddress {
        self.arbiter.read()
    }

    #[external(v0)]
    fn get_dispute_status(self: @ContractState, market_id: felt252) -> felt252 {
        self.dispute_market.read(market_id)
    }

    #[external(v0)]
    fn get_final_outcome(self: @ContractState, market_id: felt252) -> felt252 {
        self.final_outcome.read(market_id)
    }

    #[external(v0)]
    fn has_dispute(self: @ContractState, market_id: felt252) -> bool {
        self.dispute_market.read(market_id) != NO_DISPUTE
    }
}
