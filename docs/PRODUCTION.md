# Production Readiness (V1 – Private Trades Only, Sepolia)

This guide is optimized for **Sepolia** and **private trades only** with conservative settings.

## 1) Environment + Addresses

Update `config/addresses.sepolia.json` after deploys:

```bash
python scripts/merge_env.py --addresses config/addresses.sepolia.json --env .env
python scripts/validate_env.py --profile all --env .env
```

## 2) ZK Circuit Artifacts (Docker)

Compile and generate Groth16 keys:

```bash
./scripts/zk_build_docker.sh
```

Or run the commands manually:

```bash
UID_GID="$(id -u):$(id -g)"

docker run --rm -u "$UID_GID" \
  -v "$PWD":/w -w /w \
  ghcr.io/iden3/circom:2.1.8 \
  circom zk/circuits/shielded_transact.circom --r1cs --wasm --sym -o zk/build

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
```

Generate the Starknet verifier (requires `scarb` inside the container):

```bash
./scripts/garaga_gen_docker.sh
```

Or run the commands manually:

```bash
UID_GID="$(id -u):$(id -g)"

docker run --rm \
  -v "$PWD":/w -w /w/zk/build \
  python:3.10-bookworm \
  bash -lc 'apt-get update -y >/dev/null && \
    apt-get install -y build-essential libgmp-dev pkg-config curl ca-certificates >/dev/null && \
    arch=$(uname -m); \
    if [ "$arch" = "x86_64" ]; then pkg=scarb-v2.8.0-x86_64-unknown-linux-gnu.tar.gz; \
    elif [ "$arch" = "aarch64" ] || [ "$arch" = "arm64" ]; then pkg=scarb-v2.8.0-aarch64-unknown-linux-gnu.tar.gz; \
    else echo "unsupported arch: $arch"; exit 1; fi; \
    curl -L https://github.com/software-mansion/scarb/releases/download/v2.8.0/$pkg -o /tmp/scarb.tgz && \
    tar -xzf /tmp/scarb.tgz -C /tmp && \
    SCARB_BIN=$(find /tmp -name scarb -type f | head -n1) && \
    mv "$SCARB_BIN" /usr/local/bin/scarb && \
    pip install -q garaga && \
    garaga gen --system groth16 \
      --vk /w/zk/build/verification_key.json \
      --project-name shielded_pool_verifier && \
    chown -R '"$UID_GID"' /w/zk/build/shielded_pool_verifier'
```

Build the verifier contract (Docker):

```bash
UID_GID="$(id -u):$(id -g)"

docker run --rm -u "$UID_GID" \
  -v "$PWD":/w -w /w/zk/build/shielded_pool_verifier \
  ghcr.io/software-mansion/scarb:2.8.0 \
  scarb build
```

## 2.1) Required Redeploy After Circuit Changes

If `zk/circuits/shielded_transact.circom` changes, you must:

1. Regenerate `zk/build/shielded_transact_final.zkey` and `zk/build/verification_key.json`.
2. Regenerate + build `zk/build/shielded_pool_verifier`.
3. Declare + deploy the new verifier contract class.
4. Call `ShieldedPool.set_verifier(new_verifier_address)` as pool owner.
5. Restart relayer/middleware with the updated verifier artifacts (`RELAYER_VK`, `RELAYER_ZKEY`, `RELAYER_WASM`).

Skipping these steps will make deposit/trade/withdraw proofs fail verification.

## 3) Contracts

Build + declare + upgrade:

```bash
cd contracts
scarb build
```

Then declare + upgrade `Market` and `ShieldedPool` and set the new verifier address.

## 4) Services (Self‑Hosted)

Minimum services for V1 private trades:
- `oracle-agent` (market state commitments)
- `indexer` (state/markets; optional for MVP)
- `middleware` (frontend API + relayer proxy)

Use the docker-compose stack in `ops/`:

```bash
python scripts/validate_env.py --profile all --env .env
docker compose -f ops/docker-compose.yml build
docker compose -f ops/docker-compose.yml up -d
```

## 5) Checks

```bash
python scripts/validate_env.py --profile all --env .env
```

Suggested smoke tests:
- `starkli call $SHIELDED_POOL_ADDRESS get_root`
- `starkli call $MARKET_FACTORY_ADDRESS get_market 0`
- middleware `/health`
