// MarketFactory - Creates and manages markets

use starknet::ContractAddress;

#[starknet::interface]
trait IOutcomeToken<TContractState> {
    fn transfer_ownership(ref self: TContractState, new_owner: felt252);
}

#[starknet::interface]
trait IERC20<TContractState> {
    fn transfer_from(
        ref self: TContractState,
        from: ContractAddress,
        to: ContractAddress,
        amount: u256
    ) -> bool;
}

#[starknet::interface]
trait ILMSRMarketMaker<TContractState> {
    fn get_initial_cost(self: @TContractState, b: u256) -> u256;
}

#[starknet::interface]
trait IMarket<TContractState> {
    fn seed_collateral(ref self: TContractState, amount: u256);
}

#[starknet::interface]
trait IOptimisticOracle<TContractState> {
    fn register_market(ref self: TContractState, market_id: felt252);
}

#[starknet::contract]
mod MarketFactory {
    use super::{
        IERC20Dispatcher, IERC20DispatcherTrait, ILMSRMarketMakerDispatcher,
        ILMSRMarketMakerDispatcherTrait, IMarketDispatcher, IMarketDispatcherTrait,
        IOptimisticOracleDispatcher, IOptimisticOracleDispatcherTrait, IOutcomeTokenDispatcher,
        IOutcomeTokenDispatcherTrait,
    };
    use core::array::Array;
    use core::array::ArrayTrait;
    use core::array::SpanTrait;
    use starknet::ContractAddress;
    use starknet::SyscallResultTrait;
    use starknet::storage::Map;
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;
    use starknet::syscalls::deploy_syscall;

    #[storage]
    struct Storage {
        owner: ContractAddress,
        collateral_token: ContractAddress,
        market_class_hash: felt252,
        outcome_token_class_hash: felt252,
        lmsr_market_maker: ContractAddress,
        b_param: u256,
        oracle: ContractAddress,
        market_count: u256,
        // market_id -> market info
        markets: Map<u256, ContractAddress>,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        collateral_token: ContractAddress,
        market_class_hash: felt252,
        outcome_token_class_hash: felt252,
        lmsr_market_maker: ContractAddress,
        b_param: u256,
        oracle: ContractAddress
    ) {
        let caller = starknet::get_caller_address();
        self.owner.write(caller);
        self.collateral_token.write(collateral_token);
        self.market_class_hash.write(market_class_hash);
        self.outcome_token_class_hash.write(outcome_token_class_hash);
        self.lmsr_market_maker.write(lmsr_market_maker);
        self.b_param.write(b_param);
        self.oracle.write(oracle);
        self.market_count.write(u256 { low: 0, high: 0 });
    }

    #[external(v0)]
    fn create_market(ref self: ContractState, question: felt252, initial_subsidy: u256) -> u256 {
        let id = self.market_count.read();
        self.market_count.write(id + u256 { low: 1, high: 0 });

        let lmsr_addr = self.lmsr_market_maker.read();
        assert(lmsr_addr.value != 0, 'LMSR not set');
        let b = self.b_param.read();
        let lmsr = ILMSRMarketMakerDispatcher { contract_address: lmsr_addr };
        let min_subsidy = lmsr.get_initial_cost(b);
        assert(initial_subsidy >= min_subsidy, 'Insufficient subsidy');

        let factory_addr = starknet::get_contract_address();
        let token_class_hash = self.outcome_token_class_hash.read();
        let market_class_hash = self.market_class_hash.read();

        let mut yes_calldata = Array::new();
        yes_calldata.append(question);
        yes_calldata.append(s'YES');
        yes_calldata.append(factory_addr.into());
        let yes_salt: felt252 = id.low.into();
        let (yes_token, _) = deploy_syscall(
            token_class_hash,
            yes_salt,
            yes_calldata.span(),
            false
        )
        .unwrap_syscall();

        let mut no_calldata = Array::new();
        no_calldata.append(question);
        no_calldata.append(s'NO');
        no_calldata.append(factory_addr.into());
        let no_salt: felt252 = (id.low + 1_u128).into();
        let (no_token, _) = deploy_syscall(
            token_class_hash,
            no_salt,
            no_calldata.span(),
            false
        )
        .unwrap_syscall();

        let mut market_calldata = Array::new();
        market_calldata.append(question);
        market_calldata.append(self.collateral_token.read().into());
        market_calldata.append(yes_token.into());
        market_calldata.append(no_token.into());
        market_calldata.append(lmsr_addr.into());
        market_calldata.append(b.low.into());
        market_calldata.append(b.high.into());
        market_calldata.append(self.oracle.read().into());
        market_calldata.append(id.low.into());
        let market_salt: felt252 = (id.low + 2_u128).into();
        let (market_addr, _) = deploy_syscall(
            market_class_hash,
            market_salt,
            market_calldata.span(),
            false
        )
        .unwrap_syscall();

        // Transfer outcome token ownership to the market contract
        let yes_dispatcher = IOutcomeTokenDispatcher { contract_address: yes_token };
        yes_dispatcher.transfer_ownership(market_addr.into());
        let no_dispatcher = IOutcomeTokenDispatcher { contract_address: no_token };
        no_dispatcher.transfer_ownership(market_addr.into());

        if initial_subsidy > u256 { low: 0, high: 0 } {
            let caller = starknet::get_caller_address();
            let collateral = IERC20Dispatcher { contract_address: self.collateral_token.read() };
            let ok = collateral.transfer_from(caller, market_addr, initial_subsidy);
            assert(ok, 'Collateral transfer failed');
            let market = IMarketDispatcher { contract_address: market_addr };
            market.seed_collateral(initial_subsidy);
        }

        let oracle_addr = self.oracle.read();
        if oracle_addr.value != 0 {
            let oracle = IOptimisticOracleDispatcher { contract_address: oracle_addr };
            oracle.register_market(id.low.into());
        }

        // Store market address
        self.markets.write(id, market_addr);
        id
    }

    #[external(v0)]
    fn get_market_count(self: @ContractState) -> u256 {
        self.market_count.read()
    }

    #[external(v0)]
    fn get_market(self: @ContractState, market_id: u256) -> felt252 {
        self.markets.read(market_id).into()
    }
}
