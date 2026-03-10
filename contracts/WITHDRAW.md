# build withdraw input
cp zk/examples/input_withdraw.json zk/build/input.json

# update withdraw input (fresh secrets, correct roots)
node zk/scripts/compute_templates.js

# economics (important)
# - amount_low is gross amount removed from notes/pool
# - user receives amount_low - fee_low
# - relayer receives fee_low
# - change note total must satisfy:
#   out_amount1 + out_amount2 = in_total - amount_low

# witness + proof
node zk/build/shielded_transact_js/generate_witness.js \
  zk/build/shielded_transact_js/shielded_transact.wasm \
  zk/build/input.json \
  zk/build/witness.wtns

(cd zk && ./node_modules/.bin/snarkjs groth16 prove \
  build/shielded_transact_final.zkey \
  build/witness.wtns \
  build/proof.json \
  build/public.json)

# calldata
/Users/andlopvic/Desktop/Projects/Cairox/oracle-agent/venv/bin/garaga calldata \
  --system groth16 \
  --vk zk/build/verification_key.json \
  --proof zk/build/proof.json \
  --public-inputs zk/build/public.json \
  --format starkli > zk/build/proof.calldata

# relay withdraw
python3 scripts/relayer_transact.py \
  --pool "$SHIELDED_POOL_ADDRESS" \
  --public-inputs zk/build/public.json \
  --proof zk/build/proof.calldata \
  --action withdraw \
  --proof-has-len \
  --account "$STARKLI_ACCOUNT" \
  --keystore "$STARKLI_KEYSTORE" \
  --rpc "$STARKNET_RPC"
