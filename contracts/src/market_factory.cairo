// Market Factory Contract for Cairox
// Creates markets and manages outcome token pairs
// Each market has two outcome tokens (YES/NO)

use starknet::ContractAddress;
use starknet::SyscallResult;
use starknet::{get_caller_address, StorageAddress};
use starknet::cast::cast_felt;
use openzeppelin::math::u256 as u256_lib;
use openzeppelin::utils::Revertable;
use openzeppelin::introspection::IERC165;
use openzeppelin::access::access_control::AccessControlEntityTrait;

#[cfg(test)]
mod test {
    use starknet::ContractAddress;
    use starknet::cast::cast_felt;
    use openzeppelin::math::u256 as u256_lib;

    // Market factory owner address
    pub fn factory_owner_address() -> ContractAddress {
        ContractAddress::from(0x123456789012345678901234567890123456789012345678901234567890123_u128)
    }

    // Helper to create market ID
    pub fn market_id(felt_str: felt252) -> felt252 {
        felt_str
    }
}

// Owner address constant
const OWNER_ADDRESS: felt252 = 0x1;

#[starknet::interface]
pub trait IMarketFactory {
    fn create_market(ref self: MarketFactory, metadata_uri: felt252) -> felt252;
    fn get_market_outcomes(self: @MarketFactory, market_id: felt252) -> Array<ContractAddress>;
    fn get_all_markets(self: @MarketFactory) -> Array<felt252>;
    fn get_market_info(self: @MarketFactory, market_id: felt252) -> MarketInfo;
    fn initialize(ref self: MarketFactory, collateral_vault: starknet::ContractAddress, outcome_token_template: starknet::ContractAddress);
}

#[derive(Drop, CairoShape, Serde)]
struct MarketInfo {
    outcomes: Array<ContractAddress>,
    metadata_uri: felt252,
    created_at: u64,
}

#[starknet::contract]
mod MarketFactory {
    use super::{test, IMarketFactory};
    use starknet::SyscallResult;
    use starknet::{get_caller_address, StorageAddress};
    use starknet::cast::cast_felt;
    use openzeppelin::math::u256 as u256_lib;
    use openzeppelin::utils::Revertable;
    use openzeppelin::introspection::IERC165;
    use openzeppelin::access::access_control::AccessControlEntityTrait;

    #[storage]
    struct Storage {
        /// Mapping of market ID -> MarketInfo
        markets: Map<felt252, MarketInfo>,
        /// List of all market IDs
        market_ids: Array<felt252>,
        /// Collateral vault contract address
        collateral_vault: starknet::ContractAddress,
        /// Outcome token template contract address
        outcome_token_template: starknet::ContractAddress,
        /// Market counter for unique IDs
        market_counter: u64,
    }

    /// Initializes the market factory
    /// @param collateral_vault The address of the collateral vault
    /// @param outcome_token_template The address of the outcome token template
    #[external]
    #[init]
    fn initialize(ref self: MarketFactory, collateral_vault: starknet::ContractAddress, outcome_token_template: starknet::ContractAddress) {
        let caller = get_caller_address();
        
        // Only allow initialization by the owner
        let owner_felt = cast_felt(OWNER_ADDRESS);
        assert(caller.value == owner_felt, 'Unauthorized: only owner can initialize');
        
        self.collateral_vault.write(collateral_vault);
        self.outcome_token_template.write(outcome_token_template);
        self.market_counter.write(0);
    }

    /// Creates a new market with YES/NO outcome tokens
    /// @param metadata_uri URI pointing to market metadata
    /// @return The market ID
    #[external]
    fn create_market(ref self: MarketFactory, metadata_uri: felt252) -> felt252 {
        let caller = get_caller_address();
        
        // Only the collateral vault can create markets
        let stored_vault = self.collateral_vault.read();
        assert(caller.value == stored_vault.value, 'Unauthorized: only collateral vault can create markets');
        
        // Increment market counter for unique ID
        let current_counter = self.market_counter.read();
        let market_id = felt252::from(current_counter);
        self.market_counter.write(current_counter + 1);
        
        // Deploy YES outcome token
        let yes_token = Self::deploy_outcome_token(
            ref self,
            s'YES',
            s'YES',
            6,
            market_id
        );
        
        // Deploy NO outcome token
        let no_token = Self::deploy_outcome_token(
            ref self,
            s'NO',
            s'NO',
            6,
            market_id
        );
        
        // Store market info
        let mut outcomes = Array::new();
        outcomes.append(yes_token);
        outcomes.append(no_token);
        
        let market_info = MarketInfo {
            outcomes: outcomes,
            metadata_uri: metadata_uri,
            created_at: starknet::block_timestamp(),
        };
        
        self.markets.write(market_id, market_info);
        self.market_ids.append(market_id);
        
        market_id
    }

    /// Deploys a new outcome token for a market
    /// @param name The token name
    /// @param symbol The token symbol
    /// @param decimals The number of decimals
    /// @param market_id The market ID
    /// @return The deployed token address
    fn deploy_outcome_token(
        ref self: MarketFactory,
        name: felt252,
        symbol: felt252,
        decimals: u8,
        market_id: felt252
    ) -> starknet::ContractAddress {
        let template = self.outcome_token_template.read();
        
        // Note: In practice, this would use Starknet's deploy syscall
        // For now, we return the template address with market_id as a salt
        // In a real implementation, this would be:
        // let salt = starknet::get_deploy_address(salt: felt252::from(market_id), class_hash: template.class_hash, calldata: calldata);
        // let contract_address = starknet::deploy(salt, template.class_hash, calldata, deploy_from_zero: false);
        
        // For testing purposes, we'll use a deterministic address calculation
        // This would be replaced with actual class hash and deploy logic in production
        let salt = felt252::from(market_id);
        let address_low = starknet::compute_address(
            salt,
            template.class_hash,
            @Array::new(),
            starknet::CONST_CLASS_HASH
        );
        
        ContractAddress::from(address_low)
    }

    /// Gets the outcome tokens for a market
    /// @param market_id The market ID
    /// @return Array of outcome token addresses
    #[external]
    fn get_market_outcomes(self: @MarketFactory, market_id: felt252) -> Array<ContractAddress> {
        let market_info = self.markets.read(market_id);
        market_info.outcomes
    }

    /// Gets all market IDs
    /// @return Array of all market IDs
    #[external]
    fn get_all_markets(self: @MarketFactory) -> Array<felt252> {
        self.market_ids.read()
    }

    /// Gets market info
    /// @param market_id The market ID
    /// @return The market info
    #[external]
    fn get_market_info(self: @MarketFactory, market_id: felt252) -> MarketInfo {
        self.markets.read(market_id)
    }

    /// Gets the collateral vault address
    /// @return The collateral vault address
    #[external]
    fn get_collateral_vault(self: @MarketFactory) -> starknet::ContractAddress {
        self.collateral_vault.read()
    }

    /// Gets the outcome token template address
    /// @return The outcome token template address
    #[external]
    fn get_outcome_token_template(self: @MarketFactory) -> starknet::ContractAddress {
        self.outcome_token_template.read()
    }
}
