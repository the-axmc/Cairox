#!/usr/bin/env python3
"""
Merge contract addresses from a JSON file into a .env file.

Usage:
  python scripts/merge_env.py --addresses config/addresses.sepolia.json --env .env
"""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


ENV_LINE = re.compile(r"^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$")


def load_addresses(path: Path) -> dict[str, str]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    contracts = raw.get("contracts", {})
    if not isinstance(contracts, dict):
        raise ValueError("addresses file missing 'contracts' object")
    return {str(k): str(v) for k, v in contracts.items()}


def merge_env_lines(lines: list[str], values: dict[str, str]) -> list[str]:
    index: dict[str, int] = {}
    for i, line in enumerate(lines):
        match = ENV_LINE.match(line)
        if match:
            key = match.group(1)
            index[key] = i

    for key, value in values.items():
        if key in index:
            lines[index[key]] = f"{key}={value}\n"
        else:
            lines.append(f"{key}={value}\n")

    return lines


def main() -> int:
    parser = argparse.ArgumentParser(description="Merge addresses into a .env file.")
    parser.add_argument("--addresses", default="config/addresses.sepolia.json")
    parser.add_argument("--env", default=".env")
    args = parser.parse_args()

    addresses_path = Path(args.addresses)
    env_path = Path(args.env)

    if not addresses_path.exists():
        raise SystemExit(f"Addresses file not found: {addresses_path}")

    values = load_addresses(addresses_path)

    lines: list[str]
    if env_path.exists():
        lines = env_path.read_text(encoding="utf-8").splitlines(keepends=True)
    else:
        lines = []

    merged = merge_env_lines(lines, values)
    env_path.write_text("".join(merged), encoding="utf-8")
    print(f"Wrote {env_path} with {len(values)} keys from {addresses_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
