#!/usr/bin/env python3
"""
Run a single market resolution.

Usage:
    python run_market.py <market_id>
    python run_market.py <market_id> --propose
    python run_market.py <market_id> --finalize

Examples:
    python run_market.py btc-tvl-2024-01
    python run_market.py btc-tvl-2024-01 --propose --network sepolia
"""

import argparse
import json
import sys
from pathlib import Path

# Add src directory to path
sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

from agent import OracleAgent


def main():
    parser = argparse.ArgumentParser(
        description="Run a single market resolution"
    )
    parser.add_argument(
        "market_id",
        help="Market ID to resolve"
    )
    parser.add_argument(
        "--propose",
        action="store_true",
        default=True,
        help="Propose the outcome on-chain (default: True)"
    )
    parser.add_argument(
        "--finalize",
        action="store_true",
        help="Finalize the market instead of proposing"
    )
    parser.add_argument(
        "--network",
        default="goerli",
        choices=["goerli", "mainnet", "sepolia", "localhost"],
        help="Starknet network to use (default: goerli)"
    )
    parser.add_argument(
        "--spec-file",
        type=str,
        help="Path to custom market specifications file"
    )
    
    args = parser.parse_args()
    
    # Initialize agent
    agent = OracleAgent(network=args.network)
    
    # Override spec file if provided
    if args.spec_file:
        path = Path(args.spec_file)
        if path.exists():
            with open(path, 'r') as f:
                try:
                    specs = json.load(f)
                    if isinstance(specs, list):
                        agent._market_specs = {s.get("market_id", i): s for i, s in enumerate(specs)}
                    else:
                        agent._market_specs = specs
                except json.JSONDecodeError:
                    print(f"Warning: Failed to parse spec file: {args.spec_file}")
    
    # Run market
    outcome = agent.run_market(args.market_id, propose=args.propose, finalize=args.finalize)
    
    if outcome:
        # Print JSON output for downstream processing
        print("\n--- RESULT ---")
        print(json.dumps(outcome.to_dict(), indent=2))
        return 0
    else:
        return 1


if __name__ == "__main__":
    sys.exit(main())
