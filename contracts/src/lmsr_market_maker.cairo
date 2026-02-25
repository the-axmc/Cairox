// LMSRMarketMaker - Logarithmic Market Scoring Rule implementation

#[starknet::contract]
mod LMSRMarketMaker {
    use core::box::BoxTrait;
    use starknet::storage::Map;
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;
    use starknet::ContractAddress;
    use starknet::SyscallResultTrait;
    use starknet::class_hash::ClassHash;
    use starknet::syscalls::replace_class_syscall;

    const SCALE: u128 = 1000000000000000000_u128; // 1e18
    const E_SCALED: u128 = 2718281828459045235_u128; // e * 1e18
    const MAX_EXP_INPUT: u128 = 10000000000000000000_u128; // 10 * 1e18
    const EXP_TERMS: u128 = 10_u128;
    const MAX_U128: u128 = 340282366920938463463374607431768211455_u128;
    const MAX_Q: u128 = MAX_U128 / SCALE;

    #[storage]
    struct Storage {
        owner: felt252,
        b_params: Map<felt252, u256>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Upgraded: Upgraded,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct Upgraded {
        class_hash: ClassHash,
    }
    #[constructor]
    fn constructor(ref self: ContractState) {
        let owner = deployer_felt();
        self.owner.write(owner);
    }

    #[external(v0)]
    fn set_b_param(ref self: ContractState, market: felt252, b: u256) {
        self.b_params.write(market, b);
    }

    #[external(v0)]
    fn calculate_buy_amount(
        self: @ContractState,
        b: u256,
        yes_supply: u256,
        no_supply: u256,
        outcome: felt252,
        collateral: u256
    ) -> u256 {
        assert(outcome == 0 || outcome == 1, 'Invalid outcome');
        let b_u = u256_to_u128(b);
        assert(b_u > 0, 'b=0');
        let yes_u = u256_to_u128(yes_supply);
        let no_u = u256_to_u128(no_supply);
        let collateral_u = u256_to_u128(collateral);

        let (q_buy, q_other) = if outcome == 1 { (yes_u, no_u) } else { (no_u, yes_u) };
        assert(q_buy <= MAX_Q, 'supply too large');
        assert(q_other <= MAX_Q, 'supply too large');
        assert(collateral_u <= MAX_Q, 'collateral too large');

        let exp_buy = exp_ratio(q_buy, b_u);
        let exp_other = exp_ratio(q_other, b_u);
        let sum = exp_buy + exp_other;

        let cost_fp = mul_div(collateral_u, SCALE, b_u);
        assert(cost_fp <= MAX_EXP_INPUT, 'exp overflow');
        let exp_cost = exp_fp(cost_fp);

        // exp(delta/b) = (exp(cost/b) * (exp(q_buy/b)+exp(q_other/b)) - exp(q_other/b)) / exp(q_buy/b)
        let term = mul_div(exp_cost, sum, SCALE);
        assert(term > exp_other, 'Invalid collateral');
        let numerator = term - exp_other;
        let ratio = mul_div(numerator, SCALE, exp_buy);
        let ln_ratio = ln_fp(ratio);
        let delta = mul_div(b_u, ln_ratio, SCALE);

        u256 { low: delta, high: 0 }
    }

    #[external(v0)]
    fn calculate_sell_amount(
        self: @ContractState,
        b: u256,
        yes_supply: u256,
        no_supply: u256,
        outcome: felt252,
        tokens: u256
    ) -> u256 {
        assert(outcome == 0 || outcome == 1, 'Invalid outcome');
        let b_u = u256_to_u128(b);
        assert(b_u > 0, 'b=0');
        let yes_u = u256_to_u128(yes_supply);
        let no_u = u256_to_u128(no_supply);
        let tokens_u = u256_to_u128(tokens);

        let (q_sell, q_other) = if outcome == 1 { (yes_u, no_u) } else { (no_u, yes_u) };
        assert(q_sell <= MAX_Q, 'supply too large');
        assert(q_other <= MAX_Q, 'supply too large');
        assert(tokens_u <= MAX_Q, 'tokens too large');
        assert(q_sell >= tokens_u, 'Insufficient supply');

        let cost_before = cost(b_u, q_sell, q_other);
        let cost_after = cost(b_u, q_sell - tokens_u, q_other);
        assert(cost_before >= cost_after, 'Invalid cost');
        let collateral_out = cost_before - cost_after;

        u256 { low: collateral_out, high: 0 }
    }

    #[external(v0)]
    fn get_price(
        self: @ContractState,
        b: u256,
        yes_supply: u256,
        no_supply: u256,
        outcome: felt252
    ) -> u256 {
        assert(outcome == 0 || outcome == 1, 'Invalid outcome');
        let b_u = u256_to_u128(b);
        assert(b_u > 0, 'b=0');
        let yes_u = u256_to_u128(yes_supply);
        let no_u = u256_to_u128(no_supply);

        assert(yes_u <= MAX_Q, 'supply too large');
        assert(no_u <= MAX_Q, 'supply too large');
        let exp_yes = exp_ratio(yes_u, b_u);
        let exp_no = exp_ratio(no_u, b_u);
        let sum = exp_yes + exp_no;
        let price = if outcome == 1 {
            mul_div(exp_yes, SCALE, sum)
        } else {
            mul_div(exp_no, SCALE, sum)
        };
        u256 { low: price, high: 0 }
    }

    #[external(v0)]
    fn get_initial_cost(self: @ContractState, b: u256) -> u256 {
        let b_u = u256_to_u128(b);
        assert(b_u > 0, 'b=0');
        let cost = cost(b_u, 0_u128, 0_u128);
        u256 { low: cost, high: 0 }
    }

    #[external(v0)]
    fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
        let caller: felt252 = starknet::get_caller_address().into();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        replace_class_syscall(new_class_hash).unwrap_syscall();
        self.emit(Upgraded { class_hash: new_class_hash });
    }

    fn u256_to_u128(x: u256) -> u128 {
        assert(x.high == 0, 'u256 overflow');
        x.low
    }

    fn mul_div(a: u128, b: u128, denom: u128) -> u128 {
        assert(denom != 0, 'div by zero');
        if a == 0 || b == 0 {
            return 0;
        }
        assert(a <= MAX_U128 / b, 'mul overflow');
        a * b / denom
    }

    fn exp_ratio(q: u128, b: u128) -> u128 {
        let x = mul_div(q, SCALE, b);
        assert(x <= MAX_EXP_INPUT, 'exp overflow');
        exp_fp(x)
    }

    fn exp_fp(x: u128) -> u128 {
        // Split x into integer and fractional parts to extend range
        let k = x / SCALE;
        assert(k <= 10, 'exp overflow');
        let r = x - k * SCALE;
        let mut result = exp_series(r);
        let mut i = 0_u128;
        loop {
            if i >= k {
                break;
            }
            result = mul_div(result, E_SCALED, SCALE);
            i += 1;
        };
        result
    }

    fn exp_series(r: u128) -> u128 {
        let mut term = SCALE;
        let mut sum = SCALE;
        let mut i = 1_u128;
        loop {
            if i > EXP_TERMS {
                break;
            }
            term = mul_div(term, r, SCALE);
            term = term / i;
            sum = sum + term;
            i += 1;
        };
        sum
    }

    fn ln_fp(y: u128) -> u128 {
        assert(y > 0, 'ln undefined');
        let mut low = 0_u128;
        let mut high = MAX_EXP_INPUT;
        let mut i = 0_u32;
        loop {
            if i >= 64 {
                break;
            }
            let mid = (low + high) / 2;
            let exp_mid = exp_fp(mid);
            if exp_mid > y {
                high = mid;
            } else {
                low = mid;
            }
            i += 1;
        };
        low
    }

    fn cost(b: u128, q_yes: u128, q_no: u128) -> u128 {
        assert(q_yes <= MAX_Q, 'supply too large');
        assert(q_no <= MAX_Q, 'supply too large');
        let exp_yes = exp_ratio(q_yes, b);
        let exp_no = exp_ratio(q_no, b);
        let sum = exp_yes + exp_no;
        let ln_sum = ln_fp(sum);
        mul_div(b, ln_sum, SCALE)
    }

    fn is_zero_address(addr: ContractAddress) -> bool {
        let felt: felt252 = addr.into();
        felt == 0
    }

    fn deployer_felt() -> felt252 {
        let tx_info = starknet::get_tx_info().unbox();
        tx_info.account_contract_address.into()
    }
}
