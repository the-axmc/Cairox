// MarketFactory - Creates and manages markets

use starknet::ContractAddress;
use starknet::class_hash::ClassHash;

#[starknet::interface]
trait IOutcomeToken<TContractState> {
    fn transfer_ownership(ref self: TContractState, new_owner: ContractAddress);
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

#[starknet::interface]
trait ILaunchConfig<TContractState> {
    fn can_create_market(self: @TContractState, creator: felt252) -> bool;
    fn register_market(ref self: TContractState);
    fn get_b_parameter(self: @TContractState) -> u256;
}

#[starknet::contract]
mod MarketFactory {
    use super::{
        IERC20Dispatcher, IERC20DispatcherTrait, ILMSRMarketMakerDispatcher,
        ILMSRMarketMakerDispatcherTrait, IMarketDispatcher, IMarketDispatcherTrait,
        IOptimisticOracleDispatcher, IOptimisticOracleDispatcherTrait, IOutcomeTokenDispatcher,
        IOutcomeTokenDispatcherTrait, ILaunchConfigDispatcher, ILaunchConfigDispatcherTrait,
    };
    use core::array::Array;
    use core::array::ArrayTrait;
    use core::array::SpanTrait;
    use core::box::BoxTrait;
    use starknet::ContractAddress;
    use starknet::class_hash::ClassHash;
    use starknet::SyscallResultTrait;
    use starknet::storage::Map;
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;
    use starknet::syscalls::deploy_syscall;
    use starknet::syscalls::replace_class_syscall;

    #[storage]
    struct Storage {
        owner: ContractAddress,
        collateral_token: ContractAddress,
        market_class_hash: ClassHash,
        outcome_token_class_hash: ClassHash,
        lmsr_market_maker: ContractAddress,
        b_param: u256,
        oracle: ContractAddress,
        launch_config: ContractAddress,
        circuit_breaker: ContractAddress,
        privacy_adapter: ContractAddress,
        market_count: u256,
        // market_id -> market info
        markets: Map<u256, ContractAddress>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        MarketCreated: MarketCreated,
        OwnershipTransferred: OwnershipTransferred,
        Upgraded: Upgraded,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct MarketCreated {
        #[key]
        market_id: u256,
        market_address: ContractAddress,
        yes_token: ContractAddress,
        no_token: ContractAddress,
        question_hash: felt252,
        question_uri: felt252,
        initial_subsidy: u256,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct OwnershipTransferred {
        #[key]
        previous_owner: ContractAddress,
        #[key]
        new_owner: ContractAddress,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct Upgraded {
        class_hash: ClassHash,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        collateral_token: ContractAddress,
        market_class_hash: ClassHash,
        outcome_token_class_hash: ClassHash,
        lmsr_market_maker: ContractAddress,
        b_param: u256,
        oracle: ContractAddress,
        launch_config: ContractAddress,
        circuit_breaker: ContractAddress,
        privacy_adapter: ContractAddress
    ) {
        let owner = deployer_address();
        self.owner.write(owner);
        self.collateral_token.write(collateral_token);
        self.market_class_hash.write(market_class_hash);
        self.outcome_token_class_hash.write(outcome_token_class_hash);
        self.lmsr_market_maker.write(lmsr_market_maker);
        self.b_param.write(b_param);
        self.oracle.write(oracle);
        self.launch_config.write(launch_config);
        self.circuit_breaker.write(circuit_breaker);
        self.privacy_adapter.write(privacy_adapter);
        self.market_count.write(u256 { low: 0, high: 0 });
    }

    #[external(v0)]
    fn transfer_ownership(ref self: ContractState, new_owner: ContractAddress) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        self.owner.write(new_owner);
        self.emit(OwnershipTransferred { previous_owner: owner, new_owner });
    }

    #[external(v0)]
    fn set_launch_config(ref self: ContractState, launch_config: ContractAddress) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        self.launch_config.write(launch_config);
    }

    #[external(v0)]
    fn set_circuit_breaker(ref self: ContractState, circuit_breaker: ContractAddress) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        self.circuit_breaker.write(circuit_breaker);
    }

    #[external(v0)]
    fn set_privacy_adapter(ref self: ContractState, privacy_adapter: ContractAddress) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        self.privacy_adapter.write(privacy_adapter);
    }

    #[external(v0)]
    fn create_market(
        ref self: ContractState,
        question_hash: felt252,
        question_uri: felt252,
        initial_subsidy: u256
    ) -> u256 {
        let caller = starknet::get_caller_address();
        let launch_cfg = self.launch_config.read();
        if !is_zero_address(launch_cfg) {
            let cfg = ILaunchConfigDispatcher { contract_address: launch_cfg };
            let creator: felt252 = caller.into();
            assert(cfg.can_create_market(creator), 'Launch: creation not allowed');
        }

        let id = self.market_count.read();
        self.market_count.write(id + u256 { low: 1, high: 0 });

        let lmsr_addr = self.lmsr_market_maker.read();
        assert(!is_zero_address(lmsr_addr), 'LMSR not set');
        let mut b = self.b_param.read();
        if !is_zero_address(launch_cfg) {
            let cfg = ILaunchConfigDispatcher { contract_address: launch_cfg };
            let cfg_b = cfg.get_b_parameter();
            if cfg_b.low != 0 || cfg_b.high != 0 {
                b = cfg_b;
            }
        }
        let lmsr = ILMSRMarketMakerDispatcher { contract_address: lmsr_addr };
        let min_subsidy = lmsr.get_initial_cost(b);
        assert(initial_subsidy >= min_subsidy, 'Insufficient subsidy');

        let factory_addr = starknet::get_contract_address();
        let token_class_hash = self.outcome_token_class_hash.read();
        let market_class_hash = self.market_class_hash.read();

        let mut yes_calldata: Array<felt252> = ArrayTrait::new();
        yes_calldata.append(question_hash);
        yes_calldata.append('YES');
        yes_calldata.append(factory_addr.into());
        let yes_salt: felt252 = id.low.into();
        let (yes_token, _) = deploy_syscall(
            token_class_hash,
            yes_salt,
            yes_calldata.span(),
            false
        )
        .unwrap_syscall();

        let mut no_calldata: Array<felt252> = ArrayTrait::new();
        no_calldata.append(question_hash);
        no_calldata.append('NO');
        no_calldata.append(factory_addr.into());
        let no_salt: felt252 = (id.low + 1_u128).into();
        let (no_token, _) = deploy_syscall(
            token_class_hash,
            no_salt,
            no_calldata.span(),
            false
        )
        .unwrap_syscall();

        let mut market_calldata: Array<felt252> = ArrayTrait::new();
        market_calldata.append(question_hash);
        market_calldata.append(question_uri);
        market_calldata.append(self.collateral_token.read().into());
        market_calldata.append(yes_token.into());
        market_calldata.append(no_token.into());
        market_calldata.append(lmsr_addr.into());
        market_calldata.append(b.low.into());
        market_calldata.append(b.high.into());
        market_calldata.append(self.oracle.read().into());
        market_calldata.append(self.launch_config.read().into());
        market_calldata.append(self.circuit_breaker.read().into());
        market_calldata.append(self.privacy_adapter.read().into());
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
        yes_dispatcher.transfer_ownership(market_addr);
        let no_dispatcher = IOutcomeTokenDispatcher { contract_address: no_token };
        no_dispatcher.transfer_ownership(market_addr);

        let zero = u256 { low: 0, high: 0 };
        if initial_subsidy > zero {
            let collateral = IERC20Dispatcher { contract_address: self.collateral_token.read() };
            let ok = collateral.transfer_from(caller, market_addr, initial_subsidy);
            assert(ok, 'Collateral transfer failed');
            let market = IMarketDispatcher { contract_address: market_addr };
            market.seed_collateral(initial_subsidy);
        }

        let oracle_addr = self.oracle.read();
        if !is_zero_address(oracle_addr) {
            let oracle = IOptimisticOracleDispatcher { contract_address: oracle_addr };
            oracle.register_market(id.low.into());
        }

        // Store market address
        self.markets.write(id, market_addr);
        if !is_zero_address(launch_cfg) {
            let cfg = ILaunchConfigDispatcher { contract_address: launch_cfg };
            cfg.register_market();
        }
        self.emit(MarketCreated {
            market_id: id,
            market_address: market_addr,
            yes_token,
            no_token,
            question_hash,
            question_uri,
            initial_subsidy
        });
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

    #[external(v0)]
    fn get_launch_config(self: @ContractState) -> ContractAddress {
        self.launch_config.read()
    }

    #[external(v0)]
    fn get_circuit_breaker(self: @ContractState) -> ContractAddress {
        self.circuit_breaker.read()
    }

    #[external(v0)]
    fn get_privacy_adapter(self: @ContractState) -> ContractAddress {
        self.privacy_adapter.read()
    }

    #[external(v0)]
    fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        replace_class_syscall(new_class_hash).unwrap_syscall();
        self.emit(Upgraded { class_hash: new_class_hash });
    }

    fn is_zero_address(addr: ContractAddress) -> bool {
        let felt: felt252 = addr.into();
        felt == 0
    }

    fn deployer_address() -> ContractAddress {
        let tx_info = starknet::get_tx_info().unbox();
        tx_info.account_contract_address
    }
}
