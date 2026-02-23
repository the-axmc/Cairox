pragma circom 2.0.0;

// Simple threshold market circuit.
// Public inputs: market_id, outcome, data_hash
// Private inputs: value, threshold

include "../node_modules/circomlib/circuits/comparators.circom";
include "../node_modules/circomlib/circuits/poseidon.circom";

template MarketThreshold() {
    signal input market_id;
    signal input outcome;
    signal output data_hash;
    signal input value;
    signal input threshold;

    component lt = LessThan(64);
    lt.in[0] <== value;
    lt.in[1] <== threshold;

    signal calc_outcome;
    calc_outcome <== 1 - lt.out;
    outcome === calc_outcome;

    component h = Poseidon(3);
    h.inputs[0] <== market_id;
    h.inputs[1] <== value;
    h.inputs[2] <== threshold;
    h.out === data_hash;
}

component main {public [market_id, outcome, data_hash]} = MarketThreshold();
