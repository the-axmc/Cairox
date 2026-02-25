#!/usr/bin/env python3
"""
Simple E2E indexer check: index a recent block range and report counts.
"""

import argparse
import os
from pathlib import Path

import sys
sys.path.insert(0, str(Path(__file__).parent))

from indexer import CairoxIndexer


def main() -> None:
    parser = argparse.ArgumentParser(description="Cairox Indexer E2E Check")
    parser.add_argument("--rpc", help="RPC URL (overrides env)")
    parser.add_argument("--from-block", type=int, default=None)
    parser.add_argument("--to-block", type=int, default=None)
    parser.add_argument("--db", help="SQLite DB path")
    args = parser.parse_args()

    indexer = CairoxIndexer(rpc_url=args.rpc, db_path=args.db)

    from_block = args.from_block or indexer._get_last_block()
    to_block = args.to_block
    if to_block is None:
        to_block = indexer._rpc("starknet_blockNumber", {})

    count = indexer.index_range(from_block, to_block)
    print(f"Indexed {count} events from {from_block} to {to_block}.")


if __name__ == "__main__":
    main()
