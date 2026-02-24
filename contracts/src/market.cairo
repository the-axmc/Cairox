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
    fn mint(ref self: TContractState, to: ContractAddress, amount: u256);
    fn burn(ref self: TContractState, from: ContractAddress, amount: u256);
    fn balance_of(self: @TContractState, account: ContractAddress) -> u256;
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

#[starknet::interface]
trait IOptimisticOracle<TContractState> {
    fn get_market_status(self: @TContractState, market_id: felt252) -> felt252;
    fn get_final_outcome(self: @TContractState, market_id: felt252) -> felt252;
}

#[starknet::contract]
mod Market {
    use super::{
        IERC20Dispatcher, IERC20DispatcherTrait, IOutcomeTokenDispatcher, IOutcomeTokenDispatcherTrait,
        ILMSRMarketMakerDispatcher, ILMSRMarketMakerDispatcherTrait,
        IOptimisticOracleDispatcher, IOptimisticOracleDispatcherTrait,
    };
    use starknet::ContractAddress;
    use core::box::BoxTrait;
    use core::option::OptionTrait;
    use core::traits::TryInto;
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

        // Oracle
        oracle: ContractAddress,
        market_id: felt252,

        // Market data
        question: felt252,

        // Circuit breaker
        trading_paused: bool,
        pause_reason: felt252,
        locked: bool,

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
        b_param: u256,
        oracle: ContractAddress,
        market_id: felt252
    ) {
        let caller = starknet::get_caller_address();
        let owner = deployer_address();
        self.owner.write(owner);
        self.pending_owner.write(zero_address());
        let factory = if is_zero_address(caller) { owner } else { caller };
        self.factory_addr.write(factory);

        self.collateral_token.write(collateral_token);
        self.yes_token.write(yes_token);
        self.no_token.write(no_token);
        self.lmsr_market_maker.write(lmsr_market_maker);
        self.b_param.write(b_param);
        self.oracle.write(oracle);
        self.market_id.write(market_id);
        self.question.write(question);

        self.trading_paused.write(false);
        self.pause_reason.write(0);
        self.locked.write(false);

        self.total_collateral.write(u256 { low: 0, high: 0 });
        self.yes_supply.write(u256 { low: 0, high: 0 });
        self.no_supply.write(u256 { low: 0, high: 0 });

        self.status.write(STATE_ACTIVE);
        self.winning_outcome.write(0);
        self.resolved_at.write(u256 { low: 0, high: 0 });
        let timestamp: u256 = starknet::get_block_timestamp().into();
        self.created_at.write(timestamp);
        self.resolution_delay.write(u256 { low: 0, high: 0 }); // default 0 for oracle-driven resolution

        self.max_trade_size.write(u256 { low: 1000000000000000000, high: 0 }); // 1e18
        self.min_trade_size.write(u256 { low: 1, high: 0 });

        self.total_trades.write(u256 { low: 0, high: 0 });
        self.total_volume.write(u256 { low: 0, high: 0 });
    }

    // Ownership
    #[external(v0)]
    fn transfer_ownership(ref self: ContractState, new_owner: ContractAddress) {
        let current = self.owner.read();
        let caller = starknet::get_caller_address();
        assert(caller == current, 'Not owner');
        self.pending_owner.write(new_owner);
    }

    #[external(v0)]
    fn accept_ownership(ref self: ContractState) {
        let pending = self.pending_owner.read();
        let caller = starknet::get_caller_address();
        assert(caller == pending, 'Not pending');
        self.owner.write(pending);
        self.pending_owner.write(zero_address());
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
        assert(!self.locked.read(), 'Reentrancy');
        self.locked.write(true);
        // Check circuit breaker
        assert(!self.trading_paused.read(), 'Trading paused');
        assert(self.status.read() == STATE_ACTIVE, 'Market not active');
        assert(outcome == OUTCOME_YES || outcome == OUTCOME_NO, 'Invalid outcome');

        // Check limits
        let max_size = self.max_trade_size.read();
        let min_size = self.min_trade_size.read();
        assert(collateral_amount >= min_size, 'Too small');
        assert(collateral_amount <= max_size, 'Too large');

        let buyer = starknet::get_caller_address();
        let lmsr_addr = self.lmsr_market_maker.read();
        assert(!is_zero_address(lmsr_addr), 'LMSR not set');
        let lmsr = ILMSRMarketMakerDispatcher { contract_address: lmsr_addr };
        let tokens_out = lmsr.calculate_buy_amount(
            self.b_param.read(),
            self.yes_supply.read(),
            self.no_supply.read(),
            outcome,
            collateral_amount
        );
        assert(tokens_out >= min_tokens, 'Slippage exceeded');

        let total = self.total_collateral.read();
        self.total_collateral.write(total + collateral_amount);

        // Mint tokens
        if outcome == OUTCOME_YES {
            let supply = self.yes_supply.read();
            self.yes_supply.write(supply + tokens_out);
            let token = IOutcomeTokenDispatcher { contract_address: self.yes_token.read() };
            token.mint(buyer, tokens_out);
        } else {
            let supply = self.no_supply.read();
            self.no_supply.write(supply + tokens_out);
            let token = IOutcomeTokenDispatcher { contract_address: self.no_token.read() };
            token.mint(buyer, tokens_out);
        };

        // Transfer collateral into the market
        let collateral = IERC20Dispatcher { contract_address: self.collateral_token.read() };
        let market_addr = starknet::get_contract_address();
        let ok = collateral.transfer_from(buyer, market_addr, collateral_amount);
        assert(ok, 'Collateral transfer failed');
        
        // Observability
        let trades = self.total_trades.read();
        self.total_trades.write(trades + u256 { low: 1, high: 0 });
        let volume = self.total_volume.read();
        self.total_volume.write(volume + collateral_amount);

        self.locked.write(false);
        tokens_out
    }

    // Sell tokens
    #[external(v0)]
    fn sell(ref self: ContractState, outcome: felt252, token_amount: u256, min_collateral: u256) -> u256 {
        assert(!self.locked.read(), 'Reentrancy');
        self.locked.write(true);
        assert(!self.trading_paused.read(), 'Trading paused');
        assert(self.status.read() == STATE_ACTIVE, 'Market not active');
        assert(outcome == OUTCOME_YES || outcome == OUTCOME_NO, 'Invalid outcome');

        let seller = starknet::get_caller_address();
        let lmsr_addr = self.lmsr_market_maker.read();
        assert(!is_zero_address(lmsr_addr), 'LMSR not set');
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
            token.burn(seller, token_amount);
        } else {
            let supply = self.no_supply.read();
            assert(supply >= token_amount, 'Insufficient supply');
            self.no_supply.write(supply - token_amount);
            let token = IOutcomeTokenDispatcher { contract_address: self.no_token.read() };
            token.burn(seller, token_amount);
        };

        let total = self.total_collateral.read();
        assert(total >= collateral_out, 'Insufficient collateral');
        self.total_collateral.write(total - collateral_out);

        // Transfer collateral back to seller
        let collateral = IERC20Dispatcher { contract_address: self.collateral_token.read() };
        let ok = collateral.transfer(seller, collateral_out);
        assert(ok, 'Collateral transfer failed');

        // Observability
        let trades = self.total_trades.read();
        self.total_trades.write(trades + u256 { low: 1, high: 0 });
        let volume = self.total_volume.read();
        self.total_volume.write(volume + collateral_out);

        self.locked.write(false);
        collateral_out
    }

    // Resolve market
    #[external(v0)]
    fn resolve(ref self: ContractState, winning_outcome: felt252) {
        assert(self.status.read() == STATE_ACTIVE, 'Already resolved');
        assert(winning_outcome == OUTCOME_YES || winning_outcome == OUTCOME_NO, 'Invalid outcome');
        let oracle_addr = self.oracle.read();
        assert(is_zero_address(oracle_addr), 'Oracle set');

        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        let factory = self.factory_addr.read();

        // Check authorization
        let is_owner = caller == owner;
        let is_factory = caller == factory;
        assert(is_owner || is_factory, 'Not authorized');

        // Enforce resolution delay
        let now: u256 = starknet::get_block_timestamp().into();
        let created_at = self.created_at.read();
        let delay = self.resolution_delay.read();
        assert(now >= created_at + delay, 'Resolution delay');

        self.status.write(STATE_RESOLVED);
        self.winning_outcome.write(winning_outcome);

        self.resolved_at.write(now);
    }

    // Resolve market from OptimisticOracle outcome
    #[external(v0)]
    fn resolve_from_oracle(ref self: ContractState) {
        assert(self.status.read() == STATE_ACTIVE, 'Already resolved');
        let oracle_addr = self.oracle.read();
        assert(!is_zero_address(oracle_addr), 'Oracle not set');
        let oracle = IOptimisticOracleDispatcher { contract_address: oracle_addr };
        let market_id = self.market_id.read();
        let status = oracle.get_market_status(market_id);
        assert(status == 2, 'Oracle not resolved');
        let outcome = oracle.get_final_outcome(market_id);
        assert(outcome == OUTCOME_YES || outcome == OUTCOME_NO, 'Invalid outcome');

        let now: u256 = starknet::get_block_timestamp().into();
        let created_at = self.created_at.read();
        let delay = self.resolution_delay.read();
        assert(now >= created_at + delay, 'Resolution delay');

        self.status.write(STATE_RESOLVED);
        self.winning_outcome.write(outcome);
        self.resolved_at.write(now);
    }

    // Seed collateral for LMSR solvency (factory-only)
    #[external(v0)]
    fn seed_collateral(ref self: ContractState, amount: u256) {
        let caller = starknet::get_caller_address();
        let factory = self.factory_addr.read();
        assert(caller == factory, 'Not factory');
        assert(amount > u256 { low: 0, high: 0 }, 'Zero amount');

        let total = self.total_collateral.read();
        self.total_collateral.write(total + amount);
    }

    // Redeem winnings
    #[external(v0)]
    fn redeem(ref self: ContractState) -> u256 {
        assert(!self.locked.read(), 'Reentrancy');
        self.locked.write(true);
        assert(self.status.read() == STATE_RESOLVED, 'Not resolved');

        let user = starknet::get_caller_address();
        let winning = self.winning_outcome.read();

        let (token, supply) = if winning == OUTCOME_YES {
            (IOutcomeTokenDispatcher { contract_address: self.yes_token.read() }, self.yes_supply.read())
        } else {
            (IOutcomeTokenDispatcher { contract_address: self.no_token.read() }, self.no_supply.read())
        };

        let winnings = token.balance_of(user);
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

        self.locked.write(false);
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
        assert(!is_zero_address(lmsr_addr), 'LMSR not set');
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
        assert(!is_zero_address(lmsr_addr), 'LMSR not set');
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
    fn get_yes_supply(self: @ContractState) -> u256 {
        self.yes_supply.read()
    }

    #[external(v0)]
    fn get_no_supply(self: @ContractState) -> u256 {
        self.no_supply.read()
    }

    #[external(v0)]
    fn get_b_param(self: @ContractState) -> u256 {
        self.b_param.read()
    }

    #[external(v0)]
    fn get_owner(self: @ContractState) -> felt252 {
        self.owner.read().into()
    }

    #[external(v0)]
    fn set_resolution_delay(ref self: ContractState, delay: u256) {
        let current = self.owner.read();
        let caller = starknet::get_caller_address();
        assert(caller == current, 'Not owner');
        self.resolution_delay.write(delay);
    }

    fn is_zero_address(addr: ContractAddress) -> bool {
        let felt: felt252 = addr.into();
        felt == 0
    }

    fn zero_address() -> ContractAddress {
        0.try_into().unwrap()
    }

    fn deployer_address() -> ContractAddress {
        let tx_info = starknet::get_tx_info().unbox();
        tx_info.account_contract_address
    }
}
