// Market - YES/NO prediction market with safety features

#[starknet::contract]
mod Market {
    use starknet::storage::Map;
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;

    const OUTCOME_YES: felt252 = 1;
    const OUTCOME_NO: felt252 = 0;

    const STATE_ACTIVE: felt252 = 1;
    const STATE_PAUSED: felt252 = 2;
    const STATE_RESOLVED: felt252 = 3;

    #[storage]
    struct Storage {
        // Ownership
        owner: felt252,
        pending_owner: felt252,
        
        // Factory
        factory_addr: felt252,
        
        // Market data
        question: felt252,
        
        // Circuit breaker
        trading_paused: bool,
        pause_reason: felt252,
        
        // User balances
        collateral_deposits: Map<felt252, u256>,
        yes_balance: Map<felt252, u256>,
        no_balance: Map<felt252, u256>,
        
        // Supply tracking
        total_collateral: u256,
        yes_supply: u256,
        no_supply: u256,
        
        // Resolution
        status: felt252,
        winning_outcome: felt252,
        resolved_at: u256,
        resolution_delay: u256,
        
        // Limits
        max_trade_size: u256,
        min_trade_size: u256,
        
        // Observability
        total_trades: u256,
        total_volume: u256,
    }

    #[constructor]
    fn constructor(ref self: ContractState, factory: felt252, question: felt252, b: u256) {
        let caller: felt252 = starknet::get_contract_address().into();
        self.owner.write(caller);
        self.pending_owner.write(0);
        self.factory_addr.write(factory);
        self.question.write(question);
        
        self.trading_paused.write(false);
        self.pause_reason.write(0);
        
        self.total_collateral.write(u256 { low: 0, high: 0 });
        self.yes_supply.write(u256 { low: 0, high: 0 });
        self.no_supply.write(u256 { low: 0, high: 0 });
        
        self.status.write(STATE_ACTIVE);
        self.winning_outcome.write(0);
        self.resolved_at.write(u256 { low: 0, high: 0 });
        self.resolution_delay.write(u256 { low: 86400, high: 0 }); // 24 hours
        
        self.max_trade_size.write(u256 { low: 1000000000000000000, high: 0 }); // 1e18
        self.min_trade_size.write(u256 { low: 1, high: 0 });
        
        self.total_trades.write(u256 { low: 0, high: 0 });
        self.total_volume.write(u256 { low: 0, high: 0 });
    }

    // Ownership
    #[external(v0)]
    fn transfer_ownership(ref self: ContractState, new_owner: felt252) {
        let current = self.owner.read();
        let caller: felt252 = starknet::get_contract_address().into();
        assert(caller == current, 'Not owner');
        self.pending_owner.write(new_owner);
    }

    #[external(v0)]
    fn accept_ownership(ref self: ContractState) {
        let pending = self.pending_owner.read();
        let caller: felt252 = starknet::get_contract_address().into();
        assert(caller == pending, 'Not pending');
        self.owner.write(pending);
        self.pending_owner.write(0);
    }

    // Circuit breaker - pause trading
    #[external(v0)]
    fn pause_trading(ref self: ContractState, reason: felt252) {
        let current = self.owner.read();
        let caller: felt252 = starknet::get_contract_address().into();
        assert(caller == current, 'Not owner');
        
        self.trading_paused.write(true);
        self.pause_reason.write(reason);
    }

    // Resume trading
    #[external(v0)]
    fn resume_trading(ref self: ContractState) {
        let current = self.owner.read();
        let caller: felt252 = starknet::get_contract_address().into();
        assert(caller == current, 'Not owner');
        
        self.trading_paused.write(false);
        self.pause_reason.write(0);
    }

    // Update limits
    #[external(v0)]
    fn set_limits(ref self: ContractState, max_size: u256, min_size: u256) {
        let current = self.owner.read();
        let caller: felt252 = starknet::get_contract_address().into();
        assert(caller == current, 'Not owner');
        
        self.max_trade_size.write(max_size);
        self.min_trade_size.write(min_size);
    }

    // Buy tokens
    #[external(v0)]
    fn buy(ref self: ContractState, outcome: felt252, collateral_amount: u256, min_tokens: u256) -> u256 {
        // Check circuit breaker
        assert(!self.trading_paused.read(), 'Trading paused');
        assert(self.status.read() == STATE_ACTIVE, 'Market not active');
        
        // Check limits
        let max_size = self.max_trade_size.read();
        let min_size = self.min_trade_size.read();
        assert(collateral_amount >= min_size, 'Too small');
        assert(collateral_amount <= max_size, 'Too large');
        
        let buyer: felt252 = starknet::get_contract_address().into();
        let tokens_out = collateral_amount;
        assert(tokens_out >= min_tokens, 'Slippage exceeded');
        
        // Update collateral
        let current = self.collateral_deposits.read(buyer);
        self.collateral_deposits.write(buyer, current + collateral_amount);
        
        let total = self.total_collateral.read();
        self.total_collateral.write(total + collateral_amount);
        
        // Mint tokens
        if outcome == OUTCOME_YES {
            let current = self.yes_balance.read(buyer);
            self.yes_balance.write(buyer, current + tokens_out);
            let supply = self.yes_supply.read();
            self.yes_supply.write(supply + tokens_out);
        } else {
            let current = self.no_balance.read(buyer);
            self.no_balance.write(buyer, current + tokens_out);
            let supply = self.no_supply.read();
            self.no_supply.write(supply + tokens_out);
        };
        
        // Observability
        let trades = self.total_trades.read();
        self.total_trades.write(trades + u256 { low: 1, high: 0 });
        let volume = self.total_volume.read();
        self.total_volume.write(volume + collateral_amount);
        
        tokens_out
    }

    // Sell tokens
    #[external(v0)]
    fn sell(ref self: ContractState, outcome: felt252, token_amount: u256, min_collateral: u256) -> u256 {
        assert(!self.trading_paused.read(), 'Trading paused');
        assert(self.status.read() == STATE_ACTIVE, 'Market not active');
        
        let seller: felt252 = starknet::get_contract_address().into();
        let collateral_out = token_amount;
        assert(collateral_out >= min_collateral, 'Slippage exceeded');
        
        if outcome == OUTCOME_YES {
            let current = self.yes_balance.read(seller);
            assert(current >= token_amount, 'Insufficient tokens');
            self.yes_balance.write(seller, current - token_amount);
            let supply = self.yes_supply.read();
            self.yes_supply.write(supply - token_amount);
        } else {
            let current = self.no_balance.read(seller);
            assert(current >= token_amount, 'Insufficient tokens');
            self.no_balance.write(seller, current - token_amount);
            let supply = self.no_supply.read();
            self.no_supply.write(supply - token_amount);
        };
        
        // Observability
        let trades = self.total_trades.read();
        self.total_trades.write(trades + u256 { low: 1, high: 0 });
        
        collateral_out
    }

    // Resolve market
    #[external(v0)]
    fn resolve(ref self: ContractState, winning_outcome: felt252) {
        assert(self.status.read() == STATE_ACTIVE, 'Already resolved');
        
        let caller: felt252 = starknet::get_contract_address().into();
        let owner = self.owner.read();
        let factory = self.factory_addr.read();
        
        // Check authorization
        let is_owner = caller == owner;
        let is_factory = caller == factory;
        assert(is_owner | is_factory, 'Not authorized');
        
        self.status.write(STATE_RESOLVED);
        self.winning_outcome.write(winning_outcome);
        
        let timestamp: u256 = starknet::get_block_timestamp().into();
        self.resolved_at.write(timestamp);
    }

    // Redeem winnings
    #[external(v0)]
    fn redeem(ref self: ContractState) -> u256 {
        assert(self.status.read() == STATE_RESOLVED, 'Not resolved');
        
        let user: felt252 = starknet::get_contract_address().into();
        let winning = self.winning_outcome.read();
        
        let winnings = if winning == OUTCOME_YES {
            self.yes_balance.read(user)
        } else {
            self.no_balance.read(user)
        };
        
        // Zero balances after redeem
        self.yes_balance.write(user, u256 { low: 0, high: 0 });
        self.no_balance.write(user, u256 { low: 0, high: 0 });
        
        winnings
    }

    // Observability getters
    #[external(v0)]
    fn is_trading_paused(self: @ContractState) -> bool {
        self.trading_paused.read()
    }

    #[external(v0)]
    fn get_total_trades(self: @ContractState) -> u256 {
        self.total_trades.read()
    }

    #[external(v0)]
    fn get_total_volume(self: @ContractState) -> u256 {
        self.total_volume.read()
    }

    // Standard getters
    #[external(v0)]
    fn get_yes_price(self: @ContractState) -> u256 {
        u256 { low: 1, high: 0 }
    }

    #[external(v0)]
    fn get_no_price(self: @ContractState) -> u256 {
        u256 { low: 1, high: 0 }
    }

    #[external(v0)]
    fn get_status(self: @ContractState) -> felt252 {
        self.status.read()
    }

    #[external(v0)]
    fn get_owner(self: @ContractState) -> felt252 {
        self.owner.read()
    }
}
