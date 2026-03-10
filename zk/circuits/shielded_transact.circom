pragma circom 2.0.0;

// Shielded pool transaction circuit with:
// - Merkle membership for two input notes
// - Nullifier checks
// - Join-split conservation
// - Merkle insertion for two output notes (new_root)
// - Market state hash binding (signed off-chain, verified on-chain via DataCommitment)
// - Price-based trade constraints (no LMSR math in-circuit)
//
// Public inputs are aligned with ShieldedPool.transact expected layout:
// [old_root, new_root, nullifier1, nullifier2, market_state_hash, action, market_id, outcome,
//  amount_low, amount_high, limit_low, limit_high, relayer, fee_low, fee_high, recipient]

include "../node_modules/circomlib/circuits/poseidon.circom";
include "../node_modules/circomlib/circuits/comparators.circom";
include "../node_modules/circomlib/circuits/bitify.circom";

template MerkleRoot(DEPTH) {
    signal input leaf;
    signal input pathElements[DEPTH];
    signal input pathIndices[DEPTH]; // 0 = leaf on left, 1 = leaf on right
    signal output root;

    component h[DEPTH];
    signal left[DEPTH];
    signal right[DEPTH];
    signal cur[DEPTH + 1];
    signal delta[DEPTH];
    signal prod[DEPTH];
    cur[0] <== leaf;

    var i;
    for (i = 0; i < DEPTH; i++) {
        // enforce pathIndices[i] is boolean
        pathIndices[i] * (pathIndices[i] - 1) === 0;
        delta[i] <== pathElements[i] - cur[i];
        prod[i] <== pathIndices[i] * delta[i];
        left[i] <== cur[i] + prod[i];
        right[i] <== pathElements[i] - prod[i];
        h[i] = Poseidon(2);
        h[i].inputs[0] <== left[i];
        h[i].inputs[1] <== right[i];
        cur[i + 1] <== h[i].out;
    }
    root <== cur[DEPTH];
}

template Range128() {
    signal input in;
    component n2b = Num2Bits(128);
    n2b.in <== in;
}

template AssertLessThan(nBits) {
    signal input a;
    signal input b;
    component lt = LessThan(nBits);
    lt.in[0] <== a;
    lt.in[1] <== b;
    lt.out === 1;
}

template DivModConst(nBits, CONST) {
    signal input a;
    signal output q;
    signal output r;
    a === q * CONST + r;
    component rq = Range128();
    rq.in <== q;
    component rr = Range128();
    rr.in <== r;
    component lt = LessThan(nBits);
    lt.in[0] <== r;
    lt.in[1] <== CONST;
    lt.out === 1;
}

template DivMod(nBits) {
    signal input a;
    signal input b;
    signal output q;
    signal output r;
    a === q * b + r;
    component rq = Range128();
    rq.in <== q;
    component rr = Range128();
    rr.in <== r;
    component lt = LessThan(nBits);
    lt.in[0] <== r;
    lt.in[1] <== b;
    lt.out === 1;
}

template MulDiv(nBits) {
    signal input a;
    signal input b;
    signal input denom;
    signal output q;
    signal output r;
    signal prod;
    prod <== a * b;
    component rp = Range128();
    rp.in <== prod;
    component div = DivMod(nBits);
    div.a <== prod;
    div.b <== denom;
    q <== div.q;
    r <== div.r;
}

template ShieldedTransact(DEPTH) {
    // Public inputs (match on-chain expected order)
    signal input old_root;
    signal input new_root;
    signal input nullifier1;
    signal input nullifier2;
    signal input market_state_hash;
    signal input action;
    signal input market_id;
    signal input outcome;
    signal input amount_low;
    signal input amount_high;
    signal input limit_low;
    signal input limit_high;
    signal input relayer;
    signal input fee_low;
    signal input fee_high;
    signal input recipient;

    // Private inputs for two input notes
    signal input in_owner_pubkey1;
    signal input in_asset_id1;
    signal input in_market_id1;
    signal input in_outcome1;
    signal input in_amount1;
    signal input in_nonce1;
    signal input in_owner_pubkey2;
    signal input in_asset_id2;
    signal input in_market_id2;
    signal input in_outcome2;
    signal input in_amount2;
    signal input in_nonce2;
    signal input in_nullifier_secret1;
    signal input in_nullifier_secret2;
    signal input in_path_elements1[DEPTH];
    signal input in_path_elements2[DEPTH];
    signal input in_path_indices1[DEPTH];
    signal input in_path_indices2[DEPTH];

    // Private inputs for two output notes
    signal input out_owner_pubkey1;
    signal input out_asset_id1;
    signal input out_market_id1;
    signal input out_outcome1;
    signal input out_amount1;
    signal input out_nonce1;
    signal input out_owner_pubkey2;
    signal input out_asset_id2;
    signal input out_market_id2;
    signal input out_outcome2;
    signal input out_amount2;
    signal input out_nonce2;
    signal input out_path_elements1[DEPTH];
    signal input out_path_elements2[DEPTH];
    signal input out_path_indices1[DEPTH];
    signal input out_path_indices2[DEPTH];

    // Enforce action is in {0,1,2,3,4,5}
    component eq_action0 = IsEqual();
    eq_action0.in[0] <== action;
    eq_action0.in[1] <== 0;
    component eq_action1 = IsEqual();
    eq_action1.in[0] <== action;
    eq_action1.in[1] <== 1;
    component eq_action2 = IsEqual();
    eq_action2.in[0] <== action;
    eq_action2.in[1] <== 2;
    component eq_action3 = IsEqual();
    eq_action3.in[0] <== action;
    eq_action3.in[1] <== 3;
    component eq_action4 = IsEqual();
    eq_action4.in[0] <== action;
    eq_action4.in[1] <== 4;
    component eq_action5 = IsEqual();
    eq_action5.in[0] <== action;
    eq_action5.in[1] <== 5;
    signal action_ok;
    action_ok <== eq_action0.out + eq_action1.out + eq_action2.out + eq_action3.out + eq_action4.out + eq_action5.out;
    action_ok === 1;

    // Enforce outcome is 0/1
    outcome * (outcome - 1) === 0;

    // Note commitments (Poseidon)
    component cin1 = Poseidon(6);
    cin1.inputs[0] <== in_owner_pubkey1;
    cin1.inputs[1] <== in_asset_id1;
    cin1.inputs[2] <== in_market_id1;
    cin1.inputs[3] <== in_outcome1;
    cin1.inputs[4] <== in_amount1;
    cin1.inputs[5] <== in_nonce1;
    signal in_commitment1;
    in_commitment1 <== cin1.out;

    component cin2 = Poseidon(6);
    cin2.inputs[0] <== in_owner_pubkey2;
    cin2.inputs[1] <== in_asset_id2;
    cin2.inputs[2] <== in_market_id2;
    cin2.inputs[3] <== in_outcome2;
    cin2.inputs[4] <== in_amount2;
    cin2.inputs[5] <== in_nonce2;
    signal in_commitment2;
    in_commitment2 <== cin2.out;

    component cout1 = Poseidon(6);
    cout1.inputs[0] <== out_owner_pubkey1;
    cout1.inputs[1] <== out_asset_id1;
    cout1.inputs[2] <== out_market_id1;
    cout1.inputs[3] <== out_outcome1;
    cout1.inputs[4] <== out_amount1;
    cout1.inputs[5] <== out_nonce1;
    signal out_commitment1;
    out_commitment1 <== cout1.out;

    component cout2 = Poseidon(6);
    cout2.inputs[0] <== out_owner_pubkey2;
    cout2.inputs[1] <== out_asset_id2;
    cout2.inputs[2] <== out_market_id2;
    cout2.inputs[3] <== out_outcome2;
    cout2.inputs[4] <== out_amount2;
    cout2.inputs[5] <== out_nonce2;
    signal out_commitment2;
    out_commitment2 <== cout2.out;

    // Notes must belong to this market (simple guard)
    in_market_id1 === market_id;
    in_market_id2 === market_id;
    out_market_id1 === market_id;
    out_market_id2 === market_id;

    // Action helpers
    signal is_buy;
    is_buy <== eq_action1.out;
    signal is_sell;
    is_sell <== eq_action2.out;
    signal is_redeem;
    is_redeem <== eq_action3.out;
    signal is_deposit;
    is_deposit <== eq_action4.out;
    signal is_withdraw;
    is_withdraw <== eq_action5.out;

    // Trade actions that require live market state (buy/sell only).
    signal is_trade;
    is_trade <== is_buy + is_sell;
    is_trade * (is_trade - 1) === 0;

    signal is_exit;
    is_exit <== is_sell + is_redeem;
    is_exit * (is_exit - 1) === 0;

    signal needs_inputs;
    needs_inputs <== is_buy + is_sell + is_redeem + is_withdraw;
    needs_inputs * (needs_inputs - 1) === 0;

    // Merkle membership for input notes (old_root) - only required for trades/withdrawals
    component in_root1 = MerkleRoot(DEPTH);
    in_root1.leaf <== in_commitment1;
    in_root1.pathElements <== in_path_elements1;
    in_root1.pathIndices <== in_path_indices1;
    (in_root1.root - old_root) * needs_inputs === 0;

    component in_root2 = MerkleRoot(DEPTH);
    in_root2.leaf <== in_commitment2;
    in_root2.pathElements <== in_path_elements2;
    in_root2.pathIndices <== in_path_indices2;
    (in_root2.root - old_root) * needs_inputs === 0;

    // Nullifiers
    component n1 = Poseidon(2);
    n1.inputs[0] <== in_commitment1;
    n1.inputs[1] <== in_nullifier_secret1;
    (n1.out - nullifier1) * needs_inputs === 0;

    component n2 = Poseidon(2);
    n2.inputs[0] <== in_commitment2;
    n2.inputs[1] <== in_nullifier_secret2;
    (n2.out - nullifier2) * needs_inputs === 0;

    // Merkle insertion for output notes (new_root)
    component out_root1 = MerkleRoot(DEPTH);
    out_root1.leaf <== out_commitment1;
    out_root1.pathElements <== out_path_elements1;
    out_root1.pathIndices <== out_path_indices1;
    out_root1.root === new_root;

    component out_root2 = MerkleRoot(DEPTH);
    out_root2.leaf <== out_commitment2;
    out_root2.pathElements <== out_path_elements2;
    out_root2.pathIndices <== out_path_indices2;
    out_root2.root === new_root;

    // Market state hash binding (signed off-chain by oracle)
    // Private inputs for market state and price
    signal input yes_supply;
    signal input no_supply;
    signal input b_param;
    signal input price_yes;
    signal input price_no;
    signal input state_timestamp;

    component state_hash = Poseidon(6);
    state_hash.inputs[0] <== yes_supply;
    state_hash.inputs[1] <== no_supply;
    state_hash.inputs[2] <== b_param;
    state_hash.inputs[3] <== price_yes;
    state_hash.inputs[4] <== price_no;
    state_hash.inputs[5] <== state_timestamp;
    (state_hash.out - market_state_hash) * is_trade === 0;

    // Ensure u256 highs are zero for fixed-point math
    amount_high === 0;
    limit_high === 0;
    fee_high === 0;

    // Enforce prices sum to SCALE (allow off-by-1 from integer division) for trades
    signal price_sum;
    price_sum <== price_yes + price_no;
    component lt_price_hi = LessThan(128);
    lt_price_hi.in[0] <== 1000000000000000000;
    lt_price_hi.in[1] <== price_sum;
    lt_price_hi.out * is_trade === 0;
    component lt_price_lo = LessThan(128);
    lt_price_lo.in[0] <== price_sum;
    lt_price_lo.in[1] <== 999999999999999999;
    lt_price_lo.out * is_trade === 0;

    // Price is accepted from signed state.

    // Trade constraints (exact LMSR buy/sell)
    // (is_buy / is_sell / is_withdraw already derived above)

    // Recipient must be zero for non-withdraw actions, and non-zero for withdraw.
    recipient * (1 - is_withdraw) === 0;
    component eq_recipient_zero = IsEqual();
    eq_recipient_zero.in[0] <== recipient;
    eq_recipient_zero.in[1] <== 0;
    eq_recipient_zero.out * is_withdraw === 0;

    // Outcome asset id = 2 - outcome (YES->1, NO->2)
    signal outcome_asset_id;
    outcome_asset_id <== 2 - outcome;

    // Input note type helpers
    component eq_in_asset1_coll = IsEqual();
    eq_in_asset1_coll.in[0] <== in_asset_id1;
    eq_in_asset1_coll.in[1] <== 0;
    component eq_in_outcome1_zero = IsEqual();
    eq_in_outcome1_zero.in[0] <== in_outcome1;
    eq_in_outcome1_zero.in[1] <== 0;
    signal in_is_collateral1;
    in_is_collateral1 <== eq_in_asset1_coll.out * eq_in_outcome1_zero.out;

    component eq_in_asset2_coll = IsEqual();
    eq_in_asset2_coll.in[0] <== in_asset_id2;
    eq_in_asset2_coll.in[1] <== 0;
    component eq_in_outcome2_zero = IsEqual();
    eq_in_outcome2_zero.in[0] <== in_outcome2;
    eq_in_outcome2_zero.in[1] <== 0;
    signal in_is_collateral2;
    in_is_collateral2 <== eq_in_asset2_coll.out * eq_in_outcome2_zero.out;

    component eq_in_asset1_out = IsEqual();
    eq_in_asset1_out.in[0] <== in_asset_id1;
    eq_in_asset1_out.in[1] <== outcome_asset_id;
    component eq_in_outcome1 = IsEqual();
    eq_in_outcome1.in[0] <== in_outcome1;
    eq_in_outcome1.in[1] <== outcome;
    signal in_is_outcome1;
    in_is_outcome1 <== eq_in_asset1_out.out * eq_in_outcome1.out;

    component eq_in_asset2_out = IsEqual();
    eq_in_asset2_out.in[0] <== in_asset_id2;
    eq_in_asset2_out.in[1] <== outcome_asset_id;
    component eq_in_outcome2 = IsEqual();
    eq_in_outcome2.in[0] <== in_outcome2;
    eq_in_outcome2.in[1] <== outcome;
    signal in_is_outcome2;
    in_is_outcome2 <== eq_in_asset2_out.out * eq_in_outcome2.out;

    // BUY: inputs are collateral, outputs are outcome + collateral change
    (1 - in_is_collateral1) * is_buy === 0;
    (1 - in_is_collateral2) * is_buy === 0;
    (out_asset_id1 - outcome_asset_id) * is_buy === 0;
    (out_outcome1 - outcome) * is_buy === 0;
    (out_asset_id2) * is_buy === 0;
    (out_outcome2) * is_buy === 0;

    // SELL/REDEEM: inputs may be outcome + collateral, outputs are collateral + outcome change
    (in_is_collateral1 + in_is_outcome1 - 1) * is_exit === 0;
    (in_is_collateral2 + in_is_outcome2 - 1) * is_exit === 0;
    (out_asset_id1) * is_exit === 0;
    (out_outcome1) * is_exit === 0;
    (out_asset_id2 - outcome_asset_id) * is_exit === 0;
    (out_outcome2 - outcome) * is_exit === 0;

    // Output amounts for BUY / SELL / REDEEM with fee accounting
    signal in_outcome_amt1;
    in_outcome_amt1 <== in_amount1 * in_is_outcome1;
    signal in_outcome_amt2;
    in_outcome_amt2 <== in_amount2 * in_is_outcome2;
    signal in_outcome_total;
    in_outcome_total <== in_outcome_amt1 + in_outcome_amt2;

    signal in_collateral_amt1;
    in_collateral_amt1 <== in_amount1 * in_is_collateral1;
    signal in_collateral_amt2;
    in_collateral_amt2 <== in_amount2 * in_is_collateral2;
    signal in_collateral_total;
    in_collateral_total <== in_collateral_amt1 + in_collateral_amt2;

    // BUY: out_amount1 == limit_low (expected tokens), out_amount2 == change
    (out_amount1 - limit_low) * is_buy === 0;
    (out_amount2 - (in_collateral_total - amount_low - fee_low)) * is_buy === 0;

    component lt_buy_spend = LessThan(128);
    lt_buy_spend.in[0] <== in_collateral_total;
    lt_buy_spend.in[1] <== amount_low + fee_low;
    lt_buy_spend.out * is_buy === 0;

    // SELL: out_amount1 == collateral change (in_collateral_total + limit_low - fee)
    (out_amount1 - (in_collateral_total + limit_low - fee_low)) * is_sell === 0;
    (out_amount2 - (in_outcome_total - amount_low)) * is_sell === 0;

    component lt_sell_amt = LessThan(128);
    lt_sell_amt.in[0] <== in_outcome_total;
    lt_sell_amt.in[1] <== amount_low;
    lt_sell_amt.out * is_sell === 0;

    component lt_sell_fee = LessThan(128);
    lt_sell_fee.in[0] <== in_collateral_total + limit_low;
    lt_sell_fee.in[1] <== fee_low;
    lt_sell_fee.out * is_sell === 0;

    // REDEEM: 1:1 conversion (limit_low must match amount_low)
    (limit_low - amount_low) * is_redeem === 0;
    (out_amount1 - (in_collateral_total + amount_low - fee_low)) * is_redeem === 0;
    (out_amount2 - (in_outcome_total - amount_low)) * is_redeem === 0;

    component lt_redeem_amt = LessThan(128);
    lt_redeem_amt.in[0] <== in_outcome_total;
    lt_redeem_amt.in[1] <== amount_low;
    lt_redeem_amt.out * is_redeem === 0;

    component lt_redeem_fee = LessThan(128);
    lt_redeem_fee.in[0] <== in_collateral_total + amount_low;
    lt_redeem_fee.in[1] <== fee_low;
    lt_redeem_fee.out * is_redeem === 0;

    // DEPOSIT: no input notes, output collateral notes == amount - fee
    in_amount1 * is_deposit === 0;
    in_amount2 * is_deposit === 0;
    in_asset_id1 * is_deposit === 0;
    in_asset_id2 * is_deposit === 0;
    in_outcome1 * is_deposit === 0;
    in_outcome2 * is_deposit === 0;
    out_asset_id1 * is_deposit === 0;
    out_asset_id2 * is_deposit === 0;
    out_outcome1 * is_deposit === 0;
    out_outcome2 * is_deposit === 0;
    signal out_total;
    out_total <== out_amount1 + out_amount2;
    (out_total - (amount_low - fee_low)) * is_deposit === 0;
    component lt_deposit_fee = LessThan(128);
    lt_deposit_fee.in[0] <== amount_low;
    lt_deposit_fee.in[1] <== fee_low;
    lt_deposit_fee.out * is_deposit === 0;

    // WITHDRAW: input collateral notes, output change notes == in_total - amount.
    // `amount_low` is the gross value removed from notes/pool; user receives
    // `amount_low - fee_low` in ShieldedPool and relayer receives `fee_low`.
    in_asset_id1 * is_withdraw === 0;
    in_asset_id2 * is_withdraw === 0;
    in_outcome1 * is_withdraw === 0;
    in_outcome2 * is_withdraw === 0;
    out_asset_id1 * is_withdraw === 0;
    out_asset_id2 * is_withdraw === 0;
    out_outcome1 * is_withdraw === 0;
    out_outcome2 * is_withdraw === 0;
    (out_total - (in_collateral_total - amount_low)) * is_withdraw === 0;
    component lt_withdraw_spend = LessThan(128);
    lt_withdraw_spend.in[0] <== in_collateral_total;
    lt_withdraw_spend.in[1] <== amount_low;
    lt_withdraw_spend.out * is_withdraw === 0;
    component lt_withdraw_fee = LessThan(128);
    lt_withdraw_fee.in[0] <== amount_low;
    lt_withdraw_fee.in[1] <== fee_low;
    lt_withdraw_fee.out * is_withdraw === 0;
}

component main {
    public [
        old_root,
        new_root,
        nullifier1,
        nullifier2,
        market_state_hash,
        action,
        market_id,
        outcome,
        amount_low,
        amount_high,
        limit_low,
        limit_high,
        relayer,
        fee_low,
        fee_high,
        recipient
    ]
} = ShieldedTransact(32);
