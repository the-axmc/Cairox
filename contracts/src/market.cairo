// Market - YES/NO prediction market with collateralized outcome tokens

use starknet::ContractAddress;

#[starknet::interface]
trait IERC20<TContractState> {
    fn transfer(ref self: TContractState, to: ContractAddress, amount: u256) -> bool;
    fn transfer_from(
        ref self: TContractState,
        from: ContractAddress,
        to: ContractAddress,
        amount: u256
    ) -> bool;
    fn balance_of(self: @TContractState, account: ContractAddress) -> u256;
}

#[starknet::interface]
trait IOutcomeToken<TContractState> {
    fn mint(ref self: TContractState, to: felt252, amount: u256);
    fn burn(ref self: TContractState, from: felt252, amount: u256);
    fn balance_of(self: @TContractState, account: felt252) -> u256;
}

#[starknet::interface]
trait ILMSRMarketMaker<TContractState> {
    fn calculate_buy_amount(
        self: @TContractState,
        b: u256,
        yes_supply: u256,
        no_supply: u256,
        outcome: felt252,
        collateral: u256
    ) -> u256;
    fn calculate_sell_amount(
        self: @TContractState,
        b: u256,
        yes_supply: u256,
        no_supply: u256,
        outcome: felt252,
        tokens: u256
    ) -> u256;
    fn get_price(
        self: @TContractState,
        b: u256,
        yes_supply: u256,
        no_supply: u256,
        outcome: felt252
    ) -> u256;
}

#[starknet::contract]
mod Market {
    use super::{
        IERC20Dispatcher, IERC20DispatcherTrait, IOutcomeTokenDispatcher, IOutcomeTokenDispatcherTrait,
        ILMSRMarketMakerDispatcher, ILMSRMarketMakerDispatcherTrait,
    };
    use starknet::ContractAddress;
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
        owner: ContractAddress,
        pending_owner: ContractAddress,

        // Factory
        factory_addr: ContractAddress,

        // Tokens
        collateral_token: ContractAddress,
        yes_token: ContractAddress,
        no_token: ContractAddress,
        lmsr_market_maker: ContractAddress,
        b_param: u256,

        // Market data
        question: felt252,

        // Circuit breaker
        trading_paused: bool,
        pause_reason: felt252,

        // Supply tracking
        total_collateral: u256,
        yes_supply: u256,
        no_supply: u256,

        // Resolution
        status: felt252,
        winning_outcome: felt252,
        resolved_at: u256,
        created_at: u256,
        resolution_delay: u256,

        // Limits
        max_trade_size: u256,
        min_trade_size: u256,

        // Observability
        total_trades: u256,
        total_volume: u256,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        question: felt252,
        collateral_token: ContractAddress,
        yes_token: ContractAddress,
        no_token: ContractAddress,
        lmsr_market_maker: ContractAddress,
        b_param: u256
    ) {
        let caller = starknet::get_caller_address();
        self.owner.write(caller);
        self.pending_owner.write(ContractAddress::from(0_u128));
        self.factory_addr.write(caller);

        self.collateral_token.write(collateral_token);
        self.yes_token.write(yes_token);
        self.no_token.write(no_token);
        self.lmsr_market_maker.write(lmsr_market_maker);
        self.b_param.write(b_param);
        self.question.write(question);

        self.trading_paused.write(false);
        self.pause_reason.write(0);

        self.total_collateral.write(u256 { low: 0, high: 0 });
        self.yes_supply.write(u256 { low: 0, high: 0 });
        self.no_supply.write(u256 { low: 0, high: 0 });

        self.status.write(STATE_ACTIVE);
        self.winning_outcome.write(0);
        self.resolved_at.write(u256 { low: 0, high: 0 });
        let timestamp: u256 = starknet::get_block_timestamp().into();
        self.created_at.write(timestamp);
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
        let caller = starknet::get_caller_address();
        assert(caller == current, 'Not owner');
        self.pending_owner.write(ContractAddress { value: new_owner });
    }

    #[external(v0)]
    fn accept_ownership(ref self: ContractState) {
        let pending = self.pending_owner.read();
        let caller = starknet::get_caller_address();
        assert(caller == pending, 'Not pending');
        self.owner.write(pending);
        self.pending_owner.write(ContractAddress::from(0_u128));
    }

    // Circuit breaker - pause trading
    #[external(v0)]
    fn pause_trading(ref self: ContractState, reason: felt252) {
        let current = self.owner.read();
        let caller = starknet::get_caller_address();
        assert(caller == current, 'Not owner');

        self.trading_paused.write(true);
        self.pause_reason.write(reason);
    }

    // Resume trading
    #[external(v0)]
    fn resume_trading(ref self: ContractState) {
        let current = self.owner.read();
        let caller = starknet::get_caller_address();
        assert(caller == current, 'Not owner');
        
        self.trading_paused.write(false);
        self.pause_reason.write(0);
    }

    // Update limits
    #[external(v0)]
    fn set_limits(ref self: ContractState, max_size: u256, min_size: u256) {
        let current = self.owner.read();
        let caller = starknet::get_caller_address();
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
        assert(outcome == OUTCOME_YES | outcome == OUTCOME_NO, 'Invalid outcome');

        // Check limits
        let max_size = self.max_trade_size.read();
        let min_size = self.min_trade_size.read();
        assert(collateral_amount >= min_size, 'Too small');
        assert(collateral_amount <= max_size, 'Too large');

        let buyer = starknet::get_caller_address();
        let lmsr_addr = self.lmsr_market_maker.read();
        assert(lmsr_addr.value != 0, 'LMSR not set');
        let lmsr = ILMSRMarketMakerDispatcher { contract_address: lmsr_addr };
        let tokens_out = lmsr.calculate_buy_amount(
            self.b_param.read(),
            self.yes_supply.read(),
            self.no_supply.read(),
            outcome,
            collateral_amount
        );
        assert(tokens_out >= min_tokens, 'Slippage exceeded');

        // Transfer collateral into the market
        let collateral = IERC20Dispatcher { contract_address: self.collateral_token.read() };
        let market_addr = starknet::get_contract_address();
        let ok = collateral.transfer_from(buyer, market_addr, collateral_amount);
        assert(ok, 'Collateral transfer failed');

        let total = self.total_collateral.read();
        self.total_collateral.write(total + collateral_amount);

        // Mint tokens
        if outcome == OUTCOME_YES {
            let supply = self.yes_supply.read();
            self.yes_supply.write(supply + tokens_out);
            let token = IOutcomeTokenDispatcher { contract_address: self.yes_token.read() };
            token.mint(buyer.into(), tokens_out);
        } else {
            let supply = self.no_supply.read();
            self.no_supply.write(supply + tokens_out);
            let token = IOutcomeTokenDispatcher { contract_address: self.no_token.read() };
            token.mint(buyer.into(), tokens_out);
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
        assert(outcome == OUTCOME_YES | outcome == OUTCOME_NO, 'Invalid outcome');

        let seller = starknet::get_caller_address();
        let lmsr_addr = self.lmsr_market_maker.read();
        assert(lmsr_addr.value != 0, 'LMSR not set');
        let lmsr = ILMSRMarketMakerDispatcher { contract_address: lmsr_addr };
        let collateral_out = lmsr.calculate_sell_amount(
            self.b_param.read(),
            self.yes_supply.read(),
            self.no_supply.read(),
            outcome,
            token_amount
        );
        assert(collateral_out >= min_collateral, 'Slippage exceeded');

        // Burn outcome tokens from seller
        if outcome == OUTCOME_YES {
            let supply = self.yes_supply.read();
            assert(supply >= token_amount, 'Insufficient supply');
            self.yes_supply.write(supply - token_amount);
            let token = IOutcomeTokenDispatcher { contract_address: self.yes_token.read() };
            token.burn(seller.into(), token_amount);
        } else {
            let supply = self.no_supply.read();
            assert(supply >= token_amount, 'Insufficient supply');
            self.no_supply.write(supply - token_amount);
            let token = IOutcomeTokenDispatcher { contract_address: self.no_token.read() };
            token.burn(seller.into(), token_amount);
        };

        // Transfer collateral back to seller
        let collateral = IERC20Dispatcher { contract_address: self.collateral_token.read() };
        let ok = collateral.transfer(seller, collateral_out);
        assert(ok, 'Collateral transfer failed');

        let total = self.total_collateral.read();
        assert(total >= collateral_out, 'Insufficient collateral');
        self.total_collateral.write(total - collateral_out);

        // Observability
        let trades = self.total_trades.read();
        self.total_trades.write(trades + u256 { low: 1, high: 0 });
        let volume = self.total_volume.read();
        self.total_volume.write(volume + collateral_out);

        collateral_out
    }

    // Resolve market
    #[external(v0)]
    fn resolve(ref self: ContractState, winning_outcome: felt252) {
        assert(self.status.read() == STATE_ACTIVE, 'Already resolved');
        assert(winning_outcome == OUTCOME_YES | winning_outcome == OUTCOME_NO, 'Invalid outcome');

        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        let factory = self.factory_addr.read();

        // Check authorization
        let is_owner = caller == owner;
        let is_factory = caller == factory;
        assert(is_owner | is_factory, 'Not authorized');

        // Enforce resolution delay
        let now: u256 = starknet::get_block_timestamp().into();
        let created_at = self.created_at.read();
        let delay = self.resolution_delay.read();
        assert(now >= created_at + delay, 'Resolution delay');

        self.status.write(STATE_RESOLVED);
        self.winning_outcome.write(winning_outcome);

        self.resolved_at.write(now);
    }

    // Redeem winnings
    #[external(v0)]
    fn redeem(ref self: ContractState) -> u256 {
        assert(self.status.read() == STATE_RESOLVED, 'Not resolved');

        let user = starknet::get_caller_address();
        let winning = self.winning_outcome.read();

        let (token, supply) = if winning == OUTCOME_YES {
            (IOutcomeTokenDispatcher { contract_address: self.yes_token.read() }, self.yes_supply.read())
        } else {
            (IOutcomeTokenDispatcher { contract_address: self.no_token.read() }, self.no_supply.read())
        };

        let winnings = token.balance_of(user.into());
        assert(winnings > u256 { low: 0, high: 0 }, 'No winnings');
        assert(supply >= winnings, 'Insufficient supply');

        // Burn winning tokens and return collateral
        token.burn(user.into(), winnings);

        let collateral = IERC20Dispatcher { contract_address: self.collateral_token.read() };
        let ok = collateral.transfer(user, winnings);
        assert(ok, 'Collateral transfer failed');

        let total = self.total_collateral.read();
        assert(total >= winnings, 'Insufficient collateral');
        self.total_collateral.write(total - winnings);

        if winning == OUTCOME_YES {
            self.yes_supply.write(supply - winnings);
        } else {
            self.no_supply.write(supply - winnings);
        }

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
        let lmsr_addr = self.lmsr_market_maker.read();
        assert(lmsr_addr.value != 0, 'LMSR not set');
        let lmsr = ILMSRMarketMakerDispatcher { contract_address: lmsr_addr };
        lmsr.get_price(
            self.b_param.read(),
            self.yes_supply.read(),
            self.no_supply.read(),
            OUTCOME_YES
        )
    }

    #[external(v0)]
    fn get_no_price(self: @ContractState) -> u256 {
        let lmsr_addr = self.lmsr_market_maker.read();
        assert(lmsr_addr.value != 0, 'LMSR not set');
        let lmsr = ILMSRMarketMakerDispatcher { contract_address: lmsr_addr };
        lmsr.get_price(
            self.b_param.read(),
            self.yes_supply.read(),
            self.no_supply.read(),
            OUTCOME_NO
        )
    }

    #[external(v0)]
    fn get_status(self: @ContractState) -> felt252 {
        self.status.read()
    }

    #[external(v0)]
    fn get_owner(self: @ContractState) -> felt252 {
        self.owner.read().into()
    }
}
