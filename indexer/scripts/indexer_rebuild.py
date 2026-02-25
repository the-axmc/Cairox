#!/usr/bin/env python3
"""
Indexer Rebuild Script

Rebuild the sentiment index from scratch by replaying events.
"""

import argparse
import sys
from datetime import datetime
from pathlib import Path

# Add src directory to path
sys.path.insert(0, str(Path(__file__).parent))

from indexer import CairoxIndexer


def main():
    """Rebuild index by replaying events from a start block."""
    parser = argparse.ArgumentParser(description='Rebuild Cairox Indexer')
    parser.add_argument('--rpc', help='RPC URL (overrides env)')
    parser.add_argument('--db', help='SQLite DB path')
    parser.add_argument('--start-block', type=int, default=0, help='Start block number')
    parser.add_argument('--end-block', type=int, default=None, help='End block number')
    args = parser.parse_args()

    indexer = CairoxIndexer(rpc_url=args.rpc, db_path=args.db, from_block=args.start_block)

    start_time = datetime.now()
    count = indexer.index_range(args.start_block, args.end_block)
    elapsed = (datetime.now() - start_time).total_seconds()
    print(f"Indexed {count} events in {elapsed:.2f}s")


if __name__ == '__main__':
    main()
