// Cairox Prediction Market - Oracle Integration with Growthepie
use starknet::ContractAddress;
use starknet::get_caller_address;
use starknet::storage::StoragePointerReadAccess;
use starknet::storage::StoragePointerWriteAccess;

const GROWTHEPIE_ETH_USD_FEED: felt252 = 0x01a0;

#[starknet::contract]
mod CairoxOracle {
    use super::*;

    const PENDING: felt252 = 0;
    const ACTIVE: felt252 = 1;
    const RESOLVED: felt252 = 2;

    #[storage]
    struct Storage {
        owner: ContractAddress,
        growthepie_feed_id: felt252,
        growthepie_threshold_bps: u64,
        market_active: bool,
        market_outcome: felt252,
        market_resolved: bool,
        last_price: u64,
        price_updated_at: u64,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        let caller = get_caller_address();
        self.owner.write(caller);
        self.growthepie_feed_id.write(GROWTHEPIE_ETH_USD_FEED);
        self.growthepie_threshold_bps.write(500);
        self.market_active.write(false);
        self.market_resolved.write(false);
    }

    #[external(v0)]
    fn update_price(ref self: ContractState, price: u64, timestamp: u64) {
        self.last_price.write(price);
        self.price_updated_at.write(timestamp);
    }

    #[external(v0)]
    fn set_feed(ref self: ContractState, feed_id: felt252) {
        assert(get_caller_address() == self.owner.read(), 'Only owner');
        self.growthepie_feed_id.write(feed_id);
    }

    #[external(v0)]
    fn set_threshold(ref self: ContractState, threshold_bps: u64) {
        assert(get_caller_address() == self.owner.read(), 'Only owner');
        self.growthepie_threshold_bps.write(threshold_bps);
    }

    #[external(v0)]
    fn create_market(ref self: ContractState) {
        assert(!self.market_active.read(), 'Market already active');
        self.market_active.write(true);
        self.market_resolved.write(false);
    }

    #[external(v0)]
    fn resolve_market(ref self: ContractState, current_price: u64) {
        assert(get_caller_address() == self.owner.read(), 'Only owner');
        assert(self.market_active.read(), 'No active market');
        assert(!self.market_resolved.read(), 'Already resolved');
        
        let last_price = self.last_price.read();
        
        // Determine outcome: YES if price went UP, NO if DOWN
        let outcome = if current_price > last_price { 1 } else { 0 };
        
        self.market_outcome.write(outcome);
        self.market_resolved.write(true);
        self.market_active.write(false);
    }

    #[external(v0)]
    fn force_resolve(ref self: ContractState, outcome: felt252) {
        assert(get_caller_address() == self.owner.read(), 'Only owner');
        self.market_outcome.write(outcome);
        self.market_resolved.write(true);
        self.market_active.write(false);
    }

    #[external(v0)]
    fn get_market_status(self: @ContractState) -> felt252 {
        if self.market_resolved.read() {
            RESOLVED
        } else if self.market_active.read() {
            ACTIVE
        } else {
            PENDING
        }
    }

    #[external(v0)]
    fn get_outcome(self: @ContractState) -> felt252 {
        self.market_outcome.read()
    }

    #[external(v0)]
    fn get_last_price(self: @ContractState) -> u64 {
        self.last_price.read()
    }

    #[external(v0)]
    fn is_resolved(self: @ContractState) -> bool {
        self.market_resolved.read()
    }
}
