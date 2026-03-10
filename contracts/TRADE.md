# pull on-chain market state
call_dec () {
  local out
  out=$(starkli call "$1" "$2" --rpc "$STARKNET_RPC")
  OUT="$out" python3 - <<'PY'
import json,os
arr=json.loads(os.environ["OUT"])
if len(arr)==2:
  low,high=arr
  print(int(low,16)+(int(high,16)<<128))
else:
  print(int(arr[0],16))
PY
}

POOL="$SHIELDED_POOL_ADDRESS"
MARKET="$MARKET_ADDRESS_0"

ROOT_DEC=$(call_dec "$POOL" get_root)
YES_SUPPLY=$(call_dec "$MARKET" get_yes_supply)
NO_SUPPLY=$(call_dec "$MARKET" get_no_supply)
B_PARAM=$(call_dec "$MARKET" get_b_param)
YES_PRICE=$(call_dec "$MARKET" get_yes_price)
NO_PRICE=$(call_dec "$MARKET" get_no_price)

OUTCOME=1        # 1 = YES
SPEND=100000     # 0.1 CAIROX
FEE=0
LIMIT=0
TS=$(date +%s)

node zk/scripts/build_trade_input.js \
  --old-root "$ROOT_DEC" \
  --market-id 0 \
  --outcome "$OUTCOME" \
  --amount "$SPEND" \
  --fee "$FEE" \
  --limit "$LIMIT" \
  --price-yes "$YES_PRICE" \
  --price-no "$NO_PRICE" \
  --yes-supply "$YES_SUPPLY" \
  --no-supply "$NO_SUPPLY" \
  --b-param "$B_PARAM" \
  --timestamp "$TS"

# build proof
cp zk/examples/input_trade.json zk/build/input.json
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

# relay trade
python3 scripts/relayer_transact.py \
  --pool "$SHIELDED_POOL_ADDRESS" \
  --public-inputs zk/build/public.json \
  --proof zk/build/proof.calldata \
  --action trade \
  --proof-has-len \
  --account "$STARKLI_ACCOUNT" \
  --keystore "$STARKLI_KEYSTORE" \
  --rpc "$STARKNET_RPC"
