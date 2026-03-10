#!/usr/bin/env bash
set -euo pipefail

UID_GID="$(id -u):$(id -g)"

# Prefer Docker circom if CIRCOM_IMAGE is set. Fallback to local circom.
if [ -n "${CIRCOM_IMAGE:-}" ]; then
  if ! docker run --rm -u "$UID_GID" \
    -v "$PWD":/w -w /w \
    "$CIRCOM_IMAGE" \
    circom zk/circuits/shielded_transact.circom --r1cs --wasm --sym -o zk/build; then
    echo "Docker circom failed. Falling back to local circom."
    circom zk/circuits/shielded_transact.circom --r1cs --wasm --sym -o zk/build
  fi
else
  circom zk/circuits/shielded_transact.circom --r1cs --wasm --sym -o zk/build
fi

docker run --rm -u "$UID_GID" \
  -v "$PWD":/w -w /w \
  node:20-bullseye \
  bash -lc 'cd zk && ./node_modules/.bin/snarkjs groth16 setup \
    build/shielded_transact.r1cs build/pot18_final.ptau build/shielded_transact_0000.zkey'

docker run --rm -u "$UID_GID" \
  -v "$PWD":/w -w /w \
  node:20-bullseye \
  bash -lc 'cd zk && ./node_modules/.bin/snarkjs zkey contribute \
    build/shielded_transact_0000.zkey build/shielded_transact_final.zkey \
    --name="cairox" -e="cairox-seed"'

docker run --rm -u "$UID_GID" \
  -v "$PWD":/w -w /w \
  node:20-bullseye \
  bash -lc 'cd zk && ./node_modules/.bin/snarkjs zkey export verificationkey \
    build/shielded_transact_final.zkey build/verification_key.json'

echo "ZK artifacts written to zk/build"
