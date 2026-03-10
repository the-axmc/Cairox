# approve Cairox to ShieldedPool (use enough for your deposit)
starkli invoke "$CAIROX_TOKEN_ADDRESS" approve "$SHIELDED_POOL_ADDRESS" 6000000 0 \
  --account "$STARKLI_ACCOUNT" --keystore "$STARKLI_KEYSTORE" --rpc "$STARKNET_RPC" --watch

# build deposit input
cp zk/examples/input_deposit.json zk/build/input.json

# update deposit input (fresh secrets, correct roots)
node zk/scripts/compute_templates.js

# generate witness + proof
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

# relay deposit
python3 scripts/relayer_transact.py \
  --pool "$SHIELDED_POOL_ADDRESS" \
  --public-inputs zk/build/public.json \
  --proof zk/build/proof.calldata \
  --action deposit \
  --proof-has-len \
  --account "$STARKLI_ACCOUNT" \
  --keystore "$STARKLI_KEYSTORE" \
  --rpc "$STARKNET_RPC"
