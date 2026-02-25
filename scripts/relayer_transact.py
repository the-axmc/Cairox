#!/usr/bin/env python3
"""
Relayer helper for ShieldedPool deposit/withdraw flows.

This script loads public inputs + Groth16 proof calldata and submits a
ShieldedPool.transact call via starkli. It validates the 16-input layout
and enforces action consistency (deposit/withdraw).
"""

import argparse
import json
import os
import re
import subprocess
import sys
from typing import Any, List


ACTION_DEPOSIT = 4
ACTION_WITHDRAW = 5


def _parse_int(value: Any) -> int:
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        v = value.strip()
        if v.startswith("0x"):
            return int(v, 16)
        return int(v)
    raise ValueError(f"Unsupported int value: {value!r}")


def _load_json(path: str) -> Any:
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def _parse_int_list(raw: Any) -> List[int]:
    if isinstance(raw, list):
        return [_parse_int(v) for v in raw]
    if isinstance(raw, dict):
        for key in ("public_inputs", "inputs", "calldata", "proof", "full_proof_with_hints"):
            if key in raw:
                return _parse_int_list(raw[key])
    if isinstance(raw, str):
        tokens = re.findall(r"0x[0-9a-fA-F]+|\\d+", raw)
        return [_parse_int(t) for t in tokens]
    raise ValueError("Unsupported proof/public input format.")


def load_public_inputs(path: str) -> List[int]:
    raw = _load_json(path)
    values = _parse_int_list(raw)
    if len(values) != 16:
        raise ValueError(f"Expected 16 public inputs, got {len(values)}")
    return values


def load_proof(path: str) -> List[int]:
    if path.endswith(".json"):
        raw = _load_json(path)
        return _parse_int_list(raw)
    with open(path, "r", encoding="utf-8") as handle:
        return _parse_int_list(handle.read())


def with_length(values: List[int], assume_has_len: bool) -> List[int]:
    if assume_has_len:
        return values
    if values and values[0] == len(values) - 1:
        return values
    return [len(values)] + values


def main() -> int:
    parser = argparse.ArgumentParser(description="Relayer helper for ShieldedPool deposit/withdraw.")
    parser.add_argument("--pool", required=True, help="ShieldedPool contract address")
    parser.add_argument("--public-inputs", required=True, help="Path to public inputs JSON")
    parser.add_argument("--proof", required=True, help="Path to proof calldata (json or text)")
    parser.add_argument(
        "--action",
        choices=["deposit", "withdraw"],
        required=True,
        help="Action to validate against public input action",
    )
    parser.add_argument("--account", default=os.getenv("STARKLI_ACCOUNT"))
    parser.add_argument("--keystore", default=os.getenv("STARKLI_KEYSTORE"))
    parser.add_argument("--rpc", default=os.getenv("STARKNET_RPC_URL") or os.getenv("STARKNET_RPC"))
    parser.add_argument("--proof-has-len", action="store_true", help="Treat proof calldata as length-prefixed")
    parser.add_argument("--dry-run", action="store_true", help="Print starkli command without executing")
    args = parser.parse_args()

    if not args.account or not args.keystore or not args.rpc:
        print("Missing --account/--keystore/--rpc (or STARKLI_ACCOUNT/STARKLI_KEYSTORE/STARKNET_RPC_URL).")
        return 2

    public_inputs = load_public_inputs(args.public_inputs)
    proof = load_proof(args.proof)
    proof_args = with_length(proof, args.proof_has_len)

    (
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
        recipient,
    ) = public_inputs

    expected_action = ACTION_DEPOSIT if args.action == "deposit" else ACTION_WITHDRAW
    if action != expected_action:
        raise ValueError(f"Public input action {action} does not match {args.action} ({expected_action})")

    cmd = [
        "starkli",
        "invoke",
        args.pool,
        "transact",
        str(old_root),
        str(new_root),
        "2",
        str(nullifier1),
        str(nullifier2),
        str(market_state_hash),
        str(action),
        str(market_id),
        str(outcome),
        str(amount_low),
        str(amount_high),
        str(limit_low),
        str(limit_high),
        str(relayer),
        str(recipient),
        str(fee_low),
        str(fee_high),
        *[str(v) for v in proof_args],
        "--account",
        args.account,
        "--keystore",
        args.keystore,
        "--rpc",
        args.rpc,
    ]

    print(" ".join(cmd))
    if args.dry_run:
        return 0

    result = subprocess.run(cmd, check=False, capture_output=True, text=True)
    if result.stdout:
        print(result.stdout.strip())
    if result.stderr:
        print(result.stderr.strip(), file=sys.stderr)
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
