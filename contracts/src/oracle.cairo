// CairoxOracle - Growthepie ecosystem data integration for market resolution
// Resolves markets based on structured analytics: endpoint, cutoff time, aggregation rule
use starknet::ContractAddress;
use starknet::get_caller_address;
use starknet::storage::StoragePointerReadAccess;
use starknet::storage::StoragePointerWriteAccess;

#[starknet::contract]
mod CairoxOracle {
    use super::*;

    // Market status
    const PENDING: felt252 = 0;
    const ACTIVE: felt252 = 1;
    const RESOLVED: felt252 = 2;

    // Outcome types
    const OUTCOME_NO: felt252 = 0;
    const OUTCOME_YES: felt252 = 1;

    #[storage]
    struct Storage {
        owner: ContractAddress,
        
        // Growthepie configuration (per market)
        growthepie_endpoint: felt252,      // e.g., "daw/eth"
        growthepie_metric: felt252,         // e.g., "daily_active_wallets"
        resolution_threshold: u128,          // Value to compare against
        comparison_type: felt252,            // 0 = greater_than, 1 = less_than, 2 = equals
        
        // Market timing
        market_question: felt252,           // Human-readable question
        cutoff_time: u64,                    // Unix timestamp when market closes
        resolved_at: u64,
        
        // Resolution data
        current_value: u128,                 // Latest fetched value from Growthepie
        value_updated_at: u64,
        
        // Market state
        market_status: felt252,
        outcome: felt252,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        let caller = get_caller_address();
        self.owner.write(caller);
        self.market_status.write(PENDING);
        self.comparison_type.write(0); // default: greater_than
    }

    // ===== Growthepie Data Integration =====

    /// Update the ecosystem metric value (called by oracle/automation)
    #[external(v0)]
    fn update_metric(ref self: ContractState, value: u128, timestamp: u64) {
        // In production: verify caller is authorized oracle
        self.current_value.write(value);
        self.value_updated_at.write(timestamp);
    }

    /// Configure market resolution parameters
    #[external(v0)]
    fn configure_market(
        ref self: ContractState,
        question: felt252,
        endpoint: felt252,
        metric: felt252,
        threshold: u128,
        comparison: felt252,
        cutoff: u64
    ) {
        assert(get_caller_address() == self.owner.read(), 'Only owner');
        
        self.market_question.write(question);
        self.growthepie_endpoint.write(endpoint);
        self.growthepie_metric.write(metric);
        self.resolution_threshold.write(threshold);
        self.comparison_type.write(comparison);
        self.cutoff_time.write(cutoff);
    }

    // ===== Market Lifecycle =====

    /// Activate market for trading
    #[external(v0)]
    fn activate_market(ref self: ContractState) {
        assert(get_caller_address() == self.owner.read(), 'Only owner');
        assert(self.cutoff_time.read() > 0, 'Market not configured');
        self.market_status.write(ACTIVE);
    }

    /// Resolve market based on Growthepie data
    /// Deterministic: compares metric value against threshold using comparison type
    #[external(v0)]
    fn resolve_market(ref self: ContractState) {
        assert(get_caller_address() == self.owner.read(), 'Only owner');
        assert(self.market_status.read() == ACTIVE, 'Market not active');
        
        let value = self.current_value.read();
        let threshold = self.resolution_threshold.read();
        let comparison = self.comparison_type.read();
        
        // Deterministic resolution logic
        let result = if comparison == 0 {  // greater_than
            value > threshold
        } else if comparison == 1 {      // less_than
            value < threshold
        } else {                          // equals
            value == threshold
        };
        
        self.outcome.write(if result { OUTCOME_YES } else { OUTCOME_NO });
        self.market_status.write(RESOLVED);
    }

    /// Emergency force resolve (if Growthepie is unavailable)
    #[external(v0)]
    fn force_resolve(ref self: ContractState, outcome: felt252) {
        assert(get_caller_address() == self.owner.read(), 'Only owner');
        self.outcome.write(outcome);
        self.market_status.write(RESOLVED);
    }

    // ===== Getters =====

    #[external(v0)]
    fn get_market_status(self: @ContractState) -> felt252 {
        self.market_status.read()
    }

    #[external(v0)]
    fn get_outcome(self: @ContractState) -> felt252 {
        self.outcome.read()
    }

    #[external(v0)]
    fn get_current_value(self: @ContractState) -> u128 {
        self.current_value.read()
    }

    #[external(v0)]
    fn get_market_question(self: @ContractState) -> felt252 {
        self.market_question.read()
    }

    #[external(v0)]
    fn is_resolved(self: @ContractState) -> bool {
        self.market_status.read() == RESOLVED
    }
}
