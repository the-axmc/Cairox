#!/usr/bin/env python3
"""
Indexer Rebuild Script

Rebuild the sentiment index from scratch by replaying events.
"""

import argparse
import asyncio
import sys
from datetime import datetime
from pathlib import Path

# Add src directory to path
sys.path.insert(0, str(Path(__file__).parent))

from indexer import CairoxIndexer, rebuild_index


async def main():
    """Main rebuild function."""
    parser = argparse.ArgumentParser(description='Rebuild Cairox Indexer')
    parser.add_argument('--network', default='goerli', help='Starknet network')
    parser.add_argument('--contract', help='Oracle contract address')
    parser.add_argument('--start-block', type=int, default=None, help='Start block number')
    parser.add_argument('--proof-dir', help='Proof output directory')
    parser.add_argument('--market', action='append', help='Market ID to rebuild (multiple allowed)')
    
    args = parser.parse_args()
    
    # Initialize indexer
    indexer = CairoxIndexer(
        network=args.network,
        contract_address=args.contract,
        start_block=args.start_block,
        proof_directory=args.proof_dir,
    )
    
    # Rebuild index
    start_time = datetime.now()
    stats = await rebuild_index(indexer, args.market)
    elapsed = (datetime.now() - start_time).total_seconds()
    
    print(f"\nTotal time: {elapsed:.2f}s")
    
    # Save stats to file
    if args.proof_dir:
        stats_file = Path(args.proof_dir) / "rebuild_stats.json"
        import json
        with open(stats_file, 'w') as f:
            json.dump(stats, f, indent=2)
        print(f"Stats saved to: {stats_file}")


if __name__ == '__main__':
    asyncio.run(main())
