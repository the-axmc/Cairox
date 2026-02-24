# Cairox ZK System (Garaga Groth16 BN254)

This folder contains the Groth16 circuit and workflow used for on-chain ZK verification
via Garaga on Starknet. The system proves a binary threshold outcome and derives the
`data_hash` as a Poseidon hash of `(market_id, value, threshold)`.

## Circuit

- `zk/circuits/market_threshold.circom`
- Public inputs (order): `market_id`, `outcome`, `data_hash`
- Private inputs: `value`, `threshold`

The circuit enforces:
- `outcome = 1` if `value >= threshold`, else `0`
- `data_hash = Poseidon(market_id, value, threshold)`

## Tooling

You need:
- `circom` (for circuit compilation)
- `snarkjs` (for Groth16 setup/proof generation)
- `garaga` (to generate a Starknet verifier and calldata)

## Build And Prove

```bash
cd zk

# Install circomlib (Poseidon + comparators)
npm init -y
npm install circomlib

# Compile circuit
mkdir -p build
circom circuits/market_threshold.circom --r1cs --wasm --sym -o build

# Powers of Tau (example size 2^16, adjust as needed)
snarkjs powersoftau new bn128 16 build/pot16_0000.ptau -v
snarkjs powersoftau contribute build/pot16_0000.ptau build/pot16_0001.ptau --name="cairox"
snarkjs powersoftau prepare phase2 build/pot16_0001.ptau build/pot16_final.ptau

# Groth16 setup + contribution
snarkjs groth16 setup build/market_threshold.r1cs build/pot16_final.ptau build/market_threshold_0000.zkey
snarkjs zkey contribute build/market_threshold_0000.zkey build/market_threshold_final.zkey --name="cairox"
snarkjs zkey export verificationkey build/market_threshold_final.zkey build/verification_key.json

# Generate witness + proof
cat > build/input.json << 'EOF'
{
  "market_id": "123",
  "outcome": "1",
  "value": "500",
  "threshold": "400"
}
EOF

node build/market_threshold_js/generate_witness.js \
  build/market_threshold_js/market_threshold.wasm \
  build/input.json \
  build/witness.wtns

snarkjs groth16 prove \
  build/market_threshold_final.zkey \
  build/witness.wtns \
  build/proof.json \
  build/public.json
```

`build/public.json` will contain `[market_id, outcome, data_hash]`. The oracle agent
can read this file to set `data_hash` automatically.

## Generate Starknet Verifier (Garaga)

```bash
# Generate verifier contract code
garaga gen \
  --system groth16 \
  --vk build/verification_key.json \
  --output build/verifier
```

Deploy the generated verifier contract and set it on `ResolutionVerifier`:

```bash
starkli deploy build/verifier/Verifier.sierra.json --compiler-version 2.8.0
starkli invoke <RESOLUTION_VERIFIER_ADDRESS> set_zk_verifier <ZK_VERIFIER_ADDRESS>
```

## Create On-Chain Calldata

```bash
garaga calldata \
  --system groth16 \
  --vk build/verification_key.json \
  --proof build/proof.json \
  --public-inputs build/public.json \
  --format starkli > build/proof.calldata
```

Then point the oracle agent at the proof and public inputs:

```bash
export ORACLE_ZK_PROOF_PATH=zk/build/proof.calldata
export ORACLE_ZK_PUBLIC_INPUTS_PATH=zk/build/public.json
```

## Notes

- The current circuit is for binary threshold markets. Categorical markets require
  a different circuit.
- Inputs are assumed to fit in 64 bits (see `LessThan(64)`). Rescale metrics if needed.
