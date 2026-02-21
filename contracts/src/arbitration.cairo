// Arbitration Contract for Cairox
// Minimal arbitration system for v0 - handles dispute resolution and bond transfers

use starknet::ContractAddress;
use starknet::SyscallResult;
use starknet::{get_caller_address, StorageAddress};
use starknet::cast::cast_felt;
use openzeppelin::math::u256 as u256_lib;
use openzeppelin::token::erc20::interfaces::IERC20Metadata;

#[cfg(test)]
mod test {
    use starknet::ContractAddress;
    use starknet::cast::cast_felt;
    use openzeppelin::math::u256 as u256_lib;

    // Test arbiters for v0 (1-of-1)
    pub fn arbiter_address() -> ContractAddress {
        ContractAddress::from(0x123456789012345678901234567890123456789012345678901234567890123_u128)
    }

    // Test protocol fee recipient
    pub fn protocol_address() -> ContractAddress {
        ContractAddress::from(0x999999999999999999999999999999999999999999999999999999999999999_u128)
    }

    // Helper function to create a u256 value
    pub fn u256_value(amount: u128) -> u256_lib::U256 {
        u256_lib::U256 {
            low: amount,
            high: 0,
        }
    }
}

// Oracle contract address
const ORACLE_ADDRESS: felt252 = 0x3;

// Protocol fee percentage (10%)
const PROTOCOL_FEE_PERCENTAGE: u64 = 10;

#[starknet::interface]
pub trait IArbitration {
    fn resolve_dispute(
        ref self: Arbitration,
        market_id: felt252,
        outcome: felt252,
        proposer_wins: bool
    );
    fn set_arbiter(ref self: Arbitration, new_arbiter: starknet::ContractAddress);
    fn get_arbiter(self: @Arbitration) -> starknet::ContractAddress;
}

#[starknet::contract]
mod Arbitration {
    use super::{test, IArbitration};
    use starknet::SyscallResult;
    use starknet::{get_caller_address, StorageAddress};
    use starknet::cast::cast_felt;
    use openzeppelin::math::u256 as u256_lib;
    use openzeppelin::token::erc20::interfaces::IERC20Metadata;
    use cairox_contracts::oracle::OptimisticOracle;

    #[storage]
    struct Storage {
        /// Arbiter address - can resolve disputes
        arbiter: starknet::ContractAddress,
        /// Protocol fee recipient
        protocol_recipient: starknet::ContractAddress,
    }

    #[external]
    #[init]
    fn constructor(ref self: ContractState) {
        // Set default arbiter for v0
        let arbiter_addr = starknet::ContractAddress::from(0x123456789012345678901234567890123456789012345678901234567890123);
        self.arbiter.write(arbiter_addr);
        
        // Set default protocol recipient
        let protocol_addr = starknet::ContractAddress::from(0x999999999999999999999999999999999999999999999999999999999999999);
        self.protocol_recipient.write(protocol_addr);
    }

    #[external]
    fn resolve_dispute(
        ref self: ContractState,
        market_id: felt252,
        outcome: felt252,
        proposer_wins: bool
    ) {
        let caller = get_caller_address();
        
        // Only the arbiter can resolve disputes
        let arbiter = self.arbiter.read();
        assert(caller.value == arbiter.value, 'Unauthorized: only arbiter can resolve');
        
        // Get the oracle to update the market
        let oracle_addr = cast_felt(ORACLE_ADDRESS);
        
        // Call the oracle to resolution
        // Note: In practice, we'd use a library call or interface call
        // For now, we just record the resolution
        OptimisticOracle::resolve_arbitration(
            ref contract: oracle_addr,
            market_id: market_id,
            outcome: outcome
        );
        
        // Transfer bonds based on outcome
        Self::transfer_bonds(
            ref self,
            market_id,
            proposer_wins
        );
    }

    #[external]
    fn set_arbiter(ref self: ContractState, new_arbiter: starknet::ContractAddress) {
        let caller = get_caller_address();
        
        // Only the current arbiter can set a new one
        let arbiter = self.arbiter.read();
        assert(caller.value == arbiter.value, 'Unauthorized: only arbiter can update arbiter');
        
        self.arbiter.write(new_arbiter);
    }

    #[external]
    fn get_arbiter(self: @ContractState) -> starknet::ContractAddress {
        self.arbiter.read()
    }

    /// Transfers bonds based on dispute resolution
    /// @param market_id The market ID
    /// @param proposer_wins True if proposal is upheld, False if dispute wins
    fn transfer_bonds(
        ref self: ContractState,
        market_id: felt252,
        proposer_wins: bool
    ) {
        let oracle_addr = cast_felt(ORACLE_ADDRESS);
        let oracle = OptimisticOracle::contract_state_at(oracle_addr);
        
        // Read market data from oracle to get bond amounts
        // Note: In Cairo, we can't directly read another contract's storage
        // This would typically be done via oracle functions or events
        
        // For v0, we'll assume the oracle has these functions:
        // - get_proposer(market_id) -> ContractAddress
        // - get_proposer_bond(market_id) -> u256
        // - get_dispute_bond(market_id) -> u256
        
        // These would need to be added to the oracle interface
        // For now, this function is a placeholder for the bond transfer logic
        
        if proposer_wins {
            // Proposal upheld: dispute bond goes to proposer
            // Proposer keeps their bond, dispute bond transfers to proposer
            // Self: transfer dispute_bond to proposer
        } else {
            // Dispute wins: proposer bond + half dispute bond to dispute, half to protocol
            // Proposer loses their bond, half dispute bond goes to disputing party, half to protocol
            // Self: transfer proposer_bond + half_dispute_bond to dispute party
            // Self: transfer half_dispute_bond to protocol
        }
    }
}
