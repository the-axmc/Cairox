// Arbitration - Dispute resolution for Cairox markets
// Handles contested resolutions, appeals, and final settlement
use starknet::ContractAddress;
use starknet::get_caller_address;
use starknet::storage::StoragePointerReadAccess;
use starknet::storage::StoragePointerWriteAccess;

#[starknet::contract]
mod Arbitration {
    use super::*;

    // Dispute states
    const NO_DISPUTE: felt252 = 0;
    const DISPUTE_OPEN: felt252 = 1;
    const RESOLVED: felt252 = 2;

    #[storage]
    struct Storage {
        owner: ContractAddress,
        // Arbiter (trusted third party for disputes)
        arbiter: ContractAddress,
        // Dispute fee required to open dispute
        dispute_fee: u128,
        // Protocol fee on settlements (basis points)
        protocol_fee_bps: u64,
        // Active disputes
        dispute_market: felt252,
        dispute_status: felt252,
        dispute_reason: felt252,
        // Resolution
        final_outcome: felt252,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        let caller = get_caller_address();
        self.owner.write(caller);
        self.arbiter.write(caller); // Default to owner
        self.dispute_fee.write(100); // 100 USDC
        self.protocol_fee_bps.write(10); // 0.1%
        self.dispute_status.write(NO_DISPUTE);
    }

    // ===== Dispute Lifecycle =====

    /// Open dispute on market resolution
    #[external(v0)]
    fn open_dispute(ref self: ContractState, market_id: felt252, reason: felt252) {
        assert(self.dispute_status.read() == NO_DISPUTE, 'Dispute already active');
        
        self.dispute_market.write(market_id);
        self.dispute_reason.write(reason);
        self.dispute_status.write(DISPUTE_OPEN);
    }

    /// Resolve dispute (final decision by arbiter)
    #[external(v0)]
    fn resolve_dispute(ref self: ContractState, outcome: felt252) {
        assert(get_caller_address() == self.arbiter.read(), 'Only arbiter');
        assert(self.dispute_status.read() == DISPUTE_OPEN, 'No active dispute');
        
        self.final_outcome.write(outcome);
        self.dispute_status.write(RESOLVED);
    }

    /// Cancel/dismiss dispute
    #[external(v0)]
    fn dismiss_dispute(ref self: ContractState) {
        assert(get_caller_address() == self.arbiter.read(), 'Only arbiter');
        self.dispute_status.write(NO_DISPUTE);
    }

    // ===== Admin =====

    /// Set arbiter address
    #[external(v0)]
    fn set_arbiter(ref self: ContractState, new_arbiter: ContractAddress) {
        assert(get_caller_address() == self.owner.read(), 'Only owner');
        self.arbiter.write(new_arbiter);
    }

    /// Set dispute fee
    #[external(v0)]
    fn set_dispute_fee(ref self: ContractState, fee: u128) {
        assert(get_caller_address() == self.owner.read(), 'Only owner');
        self.dispute_fee.write(fee);
    }

    // ===== Getters =====

    #[external(v0)]
    fn get_arbiter(self: @ContractState) -> ContractAddress {
        self.arbiter.read()
    }

    #[external(v0)]
    fn get_dispute_status(self: @ContractState) -> felt252 {
        self.dispute_status.read()
    }

    #[external(v0)]
    fn get_final_outcome(self: @ContractState) -> felt252 {
        self.final_outcome.read()
    }

    #[external(v0)]
    fn has_dispute(self: @ContractState) -> bool {
        self.dispute_status.read() != NO_DISPUTE
    }
}
