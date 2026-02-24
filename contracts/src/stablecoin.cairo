// Stablecoin - Collateralized ERC20 with oracle-priced mint/redeem

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
}

#[starknet::interface]
trait IChainlinkAggregator<TContractState> {
    fn latest_round_data(self: @TContractState) -> (u256, u256, u256, u256, u256);
    fn decimals(self: @TContractState) -> u8;
}

#[starknet::interface]
trait IPriceOracle<TContractState> {
    fn get_price(self: @TContractState) -> u256;
    fn get_decimals(self: @TContractState) -> u8;
    fn get_updated_at(self: @TContractState) -> u256;
}

#[starknet::contract]
mod Stablecoin {
    use super::{
        ContractAddress, IERC20Dispatcher, IERC20DispatcherTrait,
        IChainlinkAggregatorDispatcher, IChainlinkAggregatorDispatcherTrait,
        IPriceOracleDispatcher, IPriceOracleDispatcherTrait,
    };
    use starknet::storage::Map;
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;

    #[storage]
    struct Storage {
        name: felt252,
        symbol: felt252,
        decimals: u8,
        owner: ContractAddress,
        price_feed: ContractAddress,
        price_feed_type: u8,
        collateral_token: ContractAddress,
        collateral_decimals: u8,
        price_locked: bool,
        locked_price: u256,
        total_supply: u256,
        balances: Map<ContractAddress, u256>,
        allowances: Map<(ContractAddress, ContractAddress), u256>,
    }

    const PRICE_FEED_CHAINLINK: u8 = 0;
    const PRICE_FEED_ORACLE: u8 = 1;
    const MAX_U128: u128 = 0xFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Transfer: Transfer,
        Approval: Approval,
        Minted: Minted,
        Burned: Burned,
        CollateralDeposited: CollateralDeposited,
        CollateralWithdrawn: CollateralWithdrawn,
        PriceLocked: PriceLocked,
        PriceUnlocked: PriceUnlocked,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct Transfer {
        #[key]
        from: ContractAddress,
        #[key]
        to: ContractAddress,
        value: u256,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct Approval {
        #[key]
        owner: ContractAddress,
        #[key]
        spender: ContractAddress,
        value: u256,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct Minted {
        #[key]
        to: ContractAddress,
        amount: u256,
        collateral_in: u256,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct Burned {
        #[key]
        from: ContractAddress,
        amount: u256,
        collateral_out: u256,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct CollateralDeposited {
        #[key]
        from: ContractAddress,
        amount: u256,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct CollateralWithdrawn {
        #[key]
        to: ContractAddress,
        amount: u256,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct PriceLocked {
        price: u256,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct PriceUnlocked {}

    #[constructor]
    fn constructor(
        ref self: ContractState,
        name: felt252,
        symbol: felt252,
        decimals: u8,
        owner: ContractAddress,
        collateral_token: ContractAddress,
        collateral_decimals: u8,
        price_feed: ContractAddress,
        price_feed_type: u8,
    ) {
        assert(
            price_feed_type == PRICE_FEED_CHAINLINK || price_feed_type == PRICE_FEED_ORACLE,
            'Invalid feed type'
        );
        assert(!is_zero_address(collateral_token), 'Invalid collateral token');
        self.name.write(name);
        self.symbol.write(symbol);
        self.decimals.write(decimals);
        self.owner.write(owner);
        self.collateral_token.write(collateral_token);
        self.collateral_decimals.write(collateral_decimals);
        self.price_feed.write(price_feed);
        self.price_feed_type.write(price_feed_type);
        self.price_locked.write(false);
        self.locked_price.write(u256 { low: 0, high: 0 });
        self.total_supply.write(u256 { low: 0, high: 0 });
    }

    #[external(v0)]
    fn name(self: @ContractState) -> felt252 {
        self.name.read()
    }

    #[external(v0)]
    fn symbol(self: @ContractState) -> felt252 {
        self.symbol.read()
    }

    #[external(v0)]
    fn decimals(self: @ContractState) -> u8 {
        self.decimals.read()
    }

    #[external(v0)]
    fn total_supply(self: @ContractState) -> u256 {
        self.total_supply.read()
    }

    #[external(v0)]
    fn balance_of(self: @ContractState, account: ContractAddress) -> u256 {
        self.balances.read(account)
    }

    #[external(v0)]
    fn allowance(self: @ContractState, owner: ContractAddress, spender: ContractAddress) -> u256 {
        self.allowances.read((owner, spender))
    }

    #[external(v0)]
    fn approve(ref self: ContractState, spender: ContractAddress, amount: u256) -> bool {
        let owner = starknet::get_caller_address();
        self.allowances.write((owner, spender), amount);
        self.emit(Approval { owner, spender, value: amount });
        true
    }

    #[external(v0)]
    fn transfer(ref self: ContractState, to: ContractAddress, amount: u256) -> bool {
        let from = starknet::get_caller_address();
        let balance = self.balances.read(from);
        assert(balance >= amount, 'Insufficient balance');

        self.balances.write(from, balance - amount);
        let to_balance = self.balances.read(to);
        self.balances.write(to, to_balance + amount);
        self.emit(Transfer { from, to, value: amount });
        true
    }

    #[external(v0)]
    fn transfer_from(
        ref self: ContractState,
        from: ContractAddress,
        to: ContractAddress,
        amount: u256
    ) -> bool {
        let spender = starknet::get_caller_address();
        let allowance = self.allowances.read((from, spender));
        assert(allowance >= amount, 'Allowance exceeded');
        self.allowances.write((from, spender), allowance - amount);
        self.emit(Approval { owner: from, spender, value: allowance - amount });

        let balance = self.balances.read(from);
        assert(balance >= amount, 'Insufficient balance');
        self.balances.write(from, balance - amount);

        let to_balance = self.balances.read(to);
        self.balances.write(to, to_balance + amount);
        self.emit(Transfer { from, to, value: amount });
        true
    }

    // Deposit collateral and mint stablecoin at oracle price.
    #[external(v0)]
    fn deposit_collateral(ref self: ContractState, amount: u256) -> u256 {
        assert(!is_zero_u256(amount), 'Zero amount');
        let caller = starknet::get_caller_address();
        let token = IERC20Dispatcher { contract_address: self.collateral_token.read() };
        let contract_addr = starknet::get_contract_address();
        let ok = token.transfer_from(caller, contract_addr, amount);
        assert(ok, 'Collateral transfer failed');
        self.emit(CollateralDeposited { from: caller, amount });

        let mint_amount = collateral_to_stable(@self, amount);
        mint_internal(ref self, caller, mint_amount);
        self.emit(Minted { to: caller, amount: mint_amount, collateral_in: amount });
        mint_amount
    }

    // Burn stablecoin and withdraw collateral at oracle price.
    #[external(v0)]
    fn redeem(ref self: ContractState, amount: u256) -> u256 {
        assert(!is_zero_u256(amount), 'Zero amount');
        let caller = starknet::get_caller_address();
        let collateral_out = stable_to_collateral(@self, amount);
        burn_internal(ref self, caller, amount);

        let token = IERC20Dispatcher { contract_address: self.collateral_token.read() };
        let ok = token.transfer(caller, collateral_out);
        assert(ok, 'Collateral transfer failed');
        self.emit(CollateralWithdrawn { to: caller, amount: collateral_out });
        self.emit(Burned { from: caller, amount, collateral_out });
        collateral_out
    }

    #[external(v0)]
    fn transfer_ownership(ref self: ContractState, new_owner: ContractAddress) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        self.owner.write(new_owner);
    }

    #[external(v0)]
    fn get_owner(self: @ContractState) -> ContractAddress {
        self.owner.read()
    }

    #[external(v0)]
    fn set_price_feed(ref self: ContractState, feed: ContractAddress, feed_type: u8) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        assert(
            feed_type == PRICE_FEED_CHAINLINK || feed_type == PRICE_FEED_ORACLE,
            'Invalid feed type'
        );
        self.price_feed.write(feed);
        self.price_feed_type.write(feed_type);
    }

    #[external(v0)]
    fn lock_price(ref self: ContractState) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        let price = fetch_price(@self);
        self.price_locked.write(true);
        self.locked_price.write(price);
        self.emit(PriceLocked { price });
    }

    #[external(v0)]
    fn unlock_price(ref self: ContractState) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        self.price_locked.write(false);
        self.locked_price.write(u256 { low: 0, high: 0 });
        self.emit(PriceUnlocked {});
    }

    #[external(v0)]
    fn get_price_feed(self: @ContractState) -> ContractAddress {
        self.price_feed.read()
    }

    #[external(v0)]
    fn get_price_feed_type(self: @ContractState) -> u8 {
        self.price_feed_type.read()
    }

    #[external(v0)]
    fn get_latest_price(self: @ContractState) -> u256 {
        fetch_price(self)
    }

    #[external(v0)]
    fn get_price_decimals(self: @ContractState) -> u8 {
        let feed = self.price_feed.read();
        assert(!is_zero_address(feed), 'No price feed');
        let feed_type = self.price_feed_type.read();
        if feed_type == PRICE_FEED_CHAINLINK {
            let aggregator = IChainlinkAggregatorDispatcher { contract_address: feed };
            aggregator.decimals()
        } else {
            let oracle = IPriceOracleDispatcher { contract_address: feed };
            oracle.get_decimals()
        }
    }

    #[external(v0)]
    fn get_price_updated_at(self: @ContractState) -> u256 {
        let feed = self.price_feed.read();
        assert(!is_zero_address(feed), 'No price feed');
        let feed_type = self.price_feed_type.read();
        if feed_type == PRICE_FEED_CHAINLINK {
            let aggregator = IChainlinkAggregatorDispatcher { contract_address: feed };
            let (_, _, _, updated_at, _) = aggregator.latest_round_data();
            updated_at
        } else {
            let oracle = IPriceOracleDispatcher { contract_address: feed };
            oracle.get_updated_at()
        }
    }

    #[external(v0)]
    fn get_collateral_token(self: @ContractState) -> ContractAddress {
        self.collateral_token.read()
    }

    #[external(v0)]
    fn get_collateral_decimals(self: @ContractState) -> u8 {
        self.collateral_decimals.read()
    }

    #[external(v0)]
    fn is_price_locked(self: @ContractState) -> bool {
        self.price_locked.read()
    }

    #[external(v0)]
    fn get_locked_price(self: @ContractState) -> u256 {
        self.locked_price.read()
    }

    fn mint_internal(ref self: ContractState, to: ContractAddress, amount: u256) {
        let supply = self.total_supply.read();
        self.total_supply.write(supply + amount);
        let balance = self.balances.read(to);
        self.balances.write(to, balance + amount);
        self.emit(Transfer { from: zero_address(), to, value: amount });
    }

    fn burn_internal(ref self: ContractState, from: ContractAddress, amount: u256) {
        let balance = self.balances.read(from);
        assert(balance >= amount, 'Insufficient balance');
        self.balances.write(from, balance - amount);
        let supply = self.total_supply.read();
        self.total_supply.write(supply - amount);
        self.emit(Transfer { from, to: zero_address(), value: amount });
    }

    fn fetch_price(self: @ContractState) -> u256 {
        let feed = self.price_feed.read();
        assert(!is_zero_address(feed), 'No price feed');
        if self.price_locked.read() {
            let locked = self.locked_price.read();
            assert(!is_zero_u256(locked), 'No locked price');
            return locked;
        }
        let feed_type = self.price_feed_type.read();
        if feed_type == PRICE_FEED_CHAINLINK {
            let aggregator = IChainlinkAggregatorDispatcher { contract_address: feed };
            let (_, answer, _, _, _) = aggregator.latest_round_data();
            answer
        } else {
            let oracle = IPriceOracleDispatcher { contract_address: feed };
            oracle.get_price()
        }
    }

    fn collateral_to_stable(self: @ContractState, amount: u256) -> u256 {
        let amount_u = u256_to_u128(amount);
        let price_u = u256_to_u128(fetch_price(self));
        assert(price_u > 0, 'Invalid price');
        let price_dec = get_price_decimals(self);
        let collateral_dec = self.collateral_decimals.read();
        let stable_dec = self.decimals.read();
        let scale_stable = pow10(stable_dec);
        let scale_price = pow10(price_dec);
        let scale_collateral = pow10(collateral_dec);

        let step1 = mul_checked(amount_u, scale_stable);
        let numerator = mul_checked(step1, scale_price);
        let denom = mul_checked(scale_collateral, price_u);
        let minted = numerator / denom;
        u256 { low: minted, high: 0 }
    }

    fn stable_to_collateral(self: @ContractState, amount: u256) -> u256 {
        let amount_u = u256_to_u128(amount);
        let price_u = u256_to_u128(fetch_price(self));
        assert(price_u > 0, 'Invalid price');
        let price_dec = get_price_decimals(self);
        let collateral_dec = self.collateral_decimals.read();
        let stable_dec = self.decimals.read();
        let scale_stable = pow10(stable_dec);
        let scale_price = pow10(price_dec);
        let scale_collateral = pow10(collateral_dec);

        let step1 = mul_checked(amount_u, price_u);
        let numerator = mul_checked(step1, scale_collateral);
        let denom = mul_checked(scale_stable, scale_price);
        let collateral_out = numerator / denom;
        u256 { low: collateral_out, high: 0 }
    }

    fn u256_to_u128(x: u256) -> u128 {
        assert(x.high == 0, 'u256 overflow');
        x.low
    }

    fn mul_checked(a: u128, b: u128) -> u128 {
        if a == 0 || b == 0 {
            return 0;
        }
        assert(a <= MAX_U128 / b, 'mul overflow');
        a * b
    }

    fn pow10(decimals: u8) -> u128 {
        let mut result: u128 = 1;
        let mut i: u8 = 0;
        loop {
            if i >= decimals {
                break;
            }
            result = mul_checked(result, 10);
            i += 1;
        };
        result
    }

    fn is_zero_address(addr: ContractAddress) -> bool {
        let felt: felt252 = addr.into();
        felt == 0
    }

    fn zero_address() -> ContractAddress {
        0.try_into().unwrap()
    }

    fn is_zero_u256(value: u256) -> bool {
        value.low == 0 && value.high == 0
    }
}
