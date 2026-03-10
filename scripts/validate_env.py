#!/usr/bin/env python3
"""
Validate required environment variables for Cairox services.

Usage:
  python scripts/validate_env.py --profile middleware --env .env
  python scripts/validate_env.py --profile oracle --env .env
  python scripts/validate_env.py --profile indexer --env .env
  python scripts/validate_env.py --profile all --env .env
"""
from __future__ import annotations

import argparse
import os
import re
from pathlib import Path


ENV_LINE = re.compile(r"^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$")
ADDR_RE = re.compile(r"^0x[0-9a-fA-F]{3,}$")


def load_env_file(path: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    if not path.exists():
        return env
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line or line.lstrip().startswith("#"):
            continue
        match = ENV_LINE.match(line)
        if not match:
            continue
        key, value = match.group(1), match.group(2).strip()
        env[key] = value
    return env


def get_env(path: Path | None) -> dict[str, str]:
    merged = dict(os.environ)
    if path:
        merged.update(load_env_file(path))
    return merged


def require(env: dict[str, str], key: str, errors: list[str]) -> None:
    value = env.get(key, "").strip()
    if not value:
        errors.append(f"Missing {key}")


def require_address(env: dict[str, str], key: str, errors: list[str]) -> None:
    value = env.get(key, "").strip()
    if not value:
        errors.append(f"Missing {key}")
        return
    if not ADDR_RE.match(value):
        errors.append(f"Invalid address for {key}: {value}")


def require_one_of(env: dict[str, str], keys: list[str], errors: list[str], label: str) -> None:
    if not any(env.get(k, "").strip() for k in keys):
        errors.append(f"Missing {label}: one of {', '.join(keys)}")


def validate(profile: str, env: dict[str, str]) -> list[str]:
    errors: list[str] = []

    require(env, "STARKNET_NETWORK", errors)
    require(env, "STARKNET_RPC_URL", errors)

    if profile in ("middleware", "all"):
        require_one_of(env, ["CAIROX_TOKEN_ADDRESS", "STABLECOIN_ADDRESS"], errors, "token address")

    if profile in ("indexer", "all"):
        require_one_of(env, ["MARKET_FACTORY_ADDRESS", "MARKET_ADDRESSES_JSON"], errors, "market sources")

    if profile in ("oracle", "all"):
        require_address(env, "ORACLE_CONTRACT_ADDRESS", errors)
        require_address(env, "DATA_COMMITMENT_ADDRESS", errors)
        require(env, "ORACLE_SIGNER_PUBLIC_KEY", errors)
        require_one_of(
            env,
            ["ORACLE_SIGNER_PRIVATE_KEY", "STARKNET_PRIVATE_KEY", "STARKLI_ACCOUNT"],
            errors,
            "signing credentials",
        )
        require_one_of(env, ["STARKNET_ACCOUNT_ADDRESS", "STARKLI_ACCOUNT"], errors, "account")

    if profile in ("relayer", "all"):
        require_address(env, "SHIELDED_POOL_ADDRESS", errors)
        require(env, "STARKLI_ACCOUNT", errors)
        require(env, "STARKLI_KEYSTORE", errors)

    if profile in ("frontend", "all"):
        require(env, "VITE_MIDDLEWARE_URL", errors)

    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate environment variables for Cairox services.")
    parser.add_argument("--profile", default="all", choices=["all", "middleware", "indexer", "oracle", "relayer", "frontend"])
    parser.add_argument("--env", default=".env", help="Optional .env file")
    args = parser.parse_args()

    env_path = Path(args.env) if args.env else None
    env = get_env(env_path)
    errors = validate(args.profile, env)

    if errors:
        print("Environment validation failed:")
        for err in errors:
            print(f"  - {err}")
        return 2

    print(f"Environment validation OK ({args.profile}).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
