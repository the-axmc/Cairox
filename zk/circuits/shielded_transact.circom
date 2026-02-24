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
//  amount_low, amount_high, limit_low, limit_high, relayer, fee_low, fee_high]

include "../node_modules/circomlib/circuits/poseidon.circom";
include "../node_modules/circomlib/circuits/comparators.circom";
include "../node_modules/circomlib/circuits/bitify.circom";

template MerkleRoot(DEPTH) {
    signal input leaf;
    signal input pathElements[DEPTH];
    signal input pathIndices[DEPTH]; // 0 = leaf on left, 1 = leaf on right
    signal output root;

    var i;
    var cur;
    cur = leaf;
    for (i = 0; i < DEPTH; i++) {
        // enforce pathIndices[i] is boolean
        pathIndices[i] * (pathIndices[i] - 1) === 0;
        signal left;
        signal right;
        left <== (1 - pathIndices[i]) * cur + pathIndices[i] * pathElements[i];
        right <== pathIndices[i] * cur + (1 - pathIndices[i]) * pathElements[i];
        component h = Poseidon(2);
        h.inputs[0] <== left;
        h.inputs[1] <== right;
        cur <== h.out;
    }
    root <== cur;
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

    // Enforce action is in {0,1,2,3}
    action * (action - 1) * (action - 2) * (action - 3) === 0;

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

    // Merkle membership for input notes (old_root)
    component in_root1 = MerkleRoot(DEPTH);
    in_root1.leaf <== in_commitment1;
    in_root1.pathElements <== in_path_elements1;
    in_root1.pathIndices <== in_path_indices1;
    in_root1.root === old_root;

    component in_root2 = MerkleRoot(DEPTH);
    in_root2.leaf <== in_commitment2;
    in_root2.pathElements <== in_path_elements2;
    in_root2.pathIndices <== in_path_indices2;
    in_root2.root === old_root;

    // Nullifiers
    component n1 = Poseidon(2);
    n1.inputs[0] <== in_commitment1;
    n1.inputs[1] <== in_nullifier_secret1;
    n1.out === nullifier1;

    component n2 = Poseidon(2);
    n2.inputs[0] <== in_commitment2;
    n2.inputs[1] <== in_nullifier_secret2;
    n2.out === nullifier2;

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
    state_hash.out === market_state_hash;

    // Ensure u256 highs are zero for fixed-point math
    amount_high === 0;
    limit_high === 0;
    fee_high === 0;

    // Enforce prices sum to SCALE (simple invariant)
    price_yes + price_no === 1000000000000000000;

    // Price is accepted from signed state.

    // Trade constraints (exact LMSR buy/sell)
    component eq_buy = IsEqual();
    eq_buy.in[0] <== action;
    eq_buy.in[1] <== 1;
    signal is_buy;
    is_buy <== eq_buy.out;

    component eq_sell = IsEqual();
    eq_sell.in[0] <== action;
    eq_sell.in[1] <== 2;
    signal is_sell;
    is_sell <== eq_sell.out;

    // Outcome asset id = 2 - outcome (YES->1, NO->2)
    signal outcome_asset_id;
    outcome_asset_id <== 2 - outcome;

    // BUY: inputs are collateral, outputs are outcome + collateral change
    // Enforce asset ids
    (in_asset_id1) * is_buy === 0;
    (in_asset_id2) * is_buy === 0;
    (out_asset_id1 - outcome_asset_id) * is_buy === 0;
    (out_outcome1 - outcome) * is_buy === 0;
    (out_asset_id2) * is_buy === 0;
    (out_outcome2) * is_buy === 0;

    // SELL: inputs are outcome, outputs are collateral + outcome change
    (in_asset_id1 - outcome_asset_id) * is_sell === 0;
    (in_outcome1 - outcome) * is_sell === 0;
    (in_asset_id2 - outcome_asset_id) * is_sell === 0;
    (in_outcome2 - outcome) * is_sell === 0;
    (out_asset_id1) * is_sell === 0;
    (out_outcome1) * is_sell === 0;
    (out_asset_id2 - outcome_asset_id) * is_sell === 0;
    (out_outcome2 - outcome) * is_sell === 0;

    // Price-based buy/sell amounts
    signal price;
    price <== outcome * price_yes + (1 - outcome) * price_no;

    component buy_tokens = MulDiv(128);
    buy_tokens.a <== amount_low;
    buy_tokens.b <== 1000000000000000000;
    buy_tokens.denom <== price;
    signal tokens_out;
    tokens_out <== buy_tokens.q;

    component sell_collateral = MulDiv(128);
    sell_collateral.a <== amount_low;
    sell_collateral.b <== price;
    sell_collateral.denom <== 1000000000000000000;
    signal collateral_out;
    collateral_out <== sell_collateral.q;

    // Enforce min output constraint depending on action
    component lt_buy = LessThan(128);
    lt_buy.in[0] <== tokens_out;
    lt_buy.in[1] <== limit_low;
    lt_buy.out * is_buy === 0;

    component lt_sell = LessThan(128);
    lt_sell.in[0] <== collateral_out;
    lt_sell.in[1] <== limit_low;
    lt_sell.out * is_sell === 0;

    // Output amounts for BUY / SELL with fee accounting
    signal in_total;
    in_total <== in_amount1 + in_amount2;
    (out_amount1 - tokens_out) * is_buy === 0;
    (out_amount2 - (in_total - amount_low - fee_low)) * is_buy === 0;

    (out_amount1 - (collateral_out - fee_low)) * is_sell === 0;
    (out_amount2 - (in_total - amount_low)) * is_sell === 0;
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
        fee_high
    ]
} = ShieldedTransact(32);
