#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${STARKNET_RPC:-}" ]]; then
  echo "STARKNET_RPC is not set" >&2
  exit 1
fi

# Resolve from env
ORACLE_ADDR=${ORACLE_CONTRACT_ADDRESS:-${OPTIMISTIC_ORACLE_ADDRESS:-}}
RESOLUTION_VERIFIER_ADDR=${RESOLUTION_VERIFIER_ADDRESS:-}
ZK_VERIFIER_ADDR=${ZK_VERIFIER_ADDRESS:-}
DATA_COMMITMENT_ADDR=${DATA_COMMITMENT_ADDRESS:-}
PRICE_ORACLE_ADDR=${PRICE_ORACLE_ADDRESS:-}
MARKET_FACTORY_ADDR=${MARKET_FACTORY_ADDRESS:-}
SHIELDED_POOL_ADDR=${SHIELDED_POOL_ADDRESS:-}

fail=0

check_addr() {
  local name="$1" val="$2"
  if [[ -z "$val" || "$val" == "0x..." ]]; then
    echo "[FAIL] $name is not set" >&2
    fail=1
  else
    echo "[OK] $name=$val"
  fi
}

check_addr ORACLE_CONTRACT_ADDRESS "$ORACLE_ADDR"
check_addr RESOLUTION_VERIFIER_ADDRESS "$RESOLUTION_VERIFIER_ADDR"
check_addr ZK_VERIFIER_ADDRESS "$ZK_VERIFIER_ADDR"
check_addr DATA_COMMITMENT_ADDRESS "$DATA_COMMITMENT_ADDR"
check_addr PRICE_ORACLE_ADDRESS "$PRICE_ORACLE_ADDR"
check_addr MARKET_FACTORY_ADDRESS "$MARKET_FACTORY_ADDR"
check_addr SHIELDED_POOL_ADDRESS "$SHIELDED_POOL_ADDR"

if [[ $fail -ne 0 ]]; then
  exit 1
fi

call_or_die() {
  local label="$1"; shift
  echo "\n== $label =="
  if ! "$@"; then
    echo "[FAIL] $label" >&2
    exit 1
  fi
}

# Resolution verifier wiring
call_or_die "ResolutionVerifier.get_zk_verifier" \
  starkli call "$RESOLUTION_VERIFIER_ADDR" get_zk_verifier --rpc "$STARKNET_RPC"
call_or_die "ResolutionVerifier.get_signer_pubkey" \
  starkli call "$RESOLUTION_VERIFIER_ADDR" get_signer_pubkey --rpc "$STARKNET_RPC"

# Optimistic oracle wiring
call_or_die "OptimisticOracle.get_verifier" \
  starkli call "$ORACLE_ADDR" get_verifier --rpc "$STARKNET_RPC"
call_or_die "OptimisticOracle.get_data_commitment" \
  starkli call "$ORACLE_ADDR" get_data_commitment --rpc "$STARKNET_RPC"

# Data commitment
call_or_die "DataCommitment.get_owner" \
  starkli call "$DATA_COMMITMENT_ADDR" get_owner --rpc "$STARKNET_RPC"
call_or_die "DataCommitment.get_max_commitment_age" \
  starkli call "$DATA_COMMITMENT_ADDR" get_max_commitment_age --rpc "$STARKNET_RPC"

# ShieldedPool
call_or_die "ShieldedPool.get_root" \
  starkli call "$SHIELDED_POOL_ADDR" get_root --rpc "$STARKNET_RPC"

# MarketFactory
call_or_die "MarketFactory.get_market_count" \
  starkli call "$MARKET_FACTORY_ADDR" get_market_count --rpc "$STARKNET_RPC"

# Market lookups (0..5) if env vars exist
for i in 0 1 2 3 4 5; do
  var="MARKET_ADDRESS_${i}"
  if [[ -n "${!var:-}" ]]; then
    call_or_die "MarketFactory.get_market(${i})" \
      starkli call "$MARKET_FACTORY_ADDR" get_market "$i" 0 --rpc "$STARKNET_RPC"
  fi
done

# Price oracle
call_or_die "PriceOracle.get_owner" \
  starkli call "$PRICE_ORACLE_ADDR" get_owner --rpc "$STARKNET_RPC"

# ZK verifier address (optional direct call)
if [[ -n "$ZK_VERIFIER_ADDR" ]]; then
  call_or_die "ZKVerifier exists (class)" \
    starkli class-hash-at "$ZK_VERIFIER_ADDR" --rpc "$STARKNET_RPC"
fi

echo "\nHealthcheck OK"
