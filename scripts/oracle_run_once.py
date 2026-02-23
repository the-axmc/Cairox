#!/usr/bin/env python3
"""
Oracle Runner Script for Cairox

This script runs the oracle once to:
1. Load due markets from the oracle
2. Fetch external data (e.g., growthepie for DAA)
3. Resolve markets
4. Propose outcomes

Requirements:
- starknet-devnet running
- Cairox contracts deployed
- Python 3.8+

Usage:
    python scripts/oracle_run_once.py [--devnet-url URL] [--verbose]
"""

import argparse
import sys
import time
import json
import os
from typing import Optional, Dict, List, Tuple

try:
    from starknet_py.contract import Contract
    from starknet_py.net.account.account import Account
    from starknet_py.net.client import Client
    from starknet_py.net.full_node_client import FullNodeClient
    from starknet_py.cairo.felt import encode_felt
    from starknet_py.utils.crypto.facade import pedersen_hash
    from starknet_py.devnet.helpers import wait_for_tx
    from starknet_py.transactions.transactions import Call
    from starknet_py.common import get_selector
except ImportError as e:
    print(f"Error: Required starknet-py library not found: {e}")
    print("Install with: pip install starknet-py")
    sys.exit(1)

# Market status constants
PENDING = 0
PROPOSED = 1
RESOLVED = 2
VOIDED = 3

# Resolution outcome constants
OUTCOME_YES = 1
OUTCOME_NO = 0

# Default configuration
DEFAULT_DEVNET_URL = "http://localhost:5050"
DEFAULT_REPORTER_ADDRESS = 0x123456789012345678901234567890123456789012345678901234567890123
DEFAULT_ARBITER_ADDRESS = 0x123456789012345678901234567890123456789012345678901234567890123

# Threshold values
DAA_THRESHOLD = 1_000_000_000_000_000_000  # 1e18 (1.0 in fixed point)
TXCOUNT_THRESHOLD = 1000
FEES_THRESHOLD = 1_000_000_000_000  # 1e12


class OracleRunner:
    """Oracle runner for Cairox deterministic markets."""
    
    def __init__(self, devnet_url: str = DEFAULT_DEVNET_URL, verbose: bool = False):
        self.devnet_url = devnet_url
        self.verbose = verbose
        self.client = None
        self.account = None
        self.oracle_contract = None
        self.market_factory = None
        self.lmsr_maker = None
        self.market_contract = None
        
    async def connect(self) -> bool:
        """Connect to Starknet devnet."""
        try:
            self.client = FullNodeClient(node_url=self.devnet_url)
            
            # Check if devnet is running
            block_number = await self.client.get_block_number()
            print(f"✓ Connected to devnet at {self.devnet_url}")
            print(f"  Block number: {block_number}")
            
            return True
        except Exception as e:
            print(f"✗ Failed to connect to devnet: {e}")
            print(f"  Make sure Starknet devnet is running: starknet-devnet --seed 0")
            return False
    
    async def load_contracts(self) -> bool:
        """Load Cairox contracts from common deployment locations."""
        print("\n=== Loading Cairox Contracts ===")
        
        try:
            # Try to get account from devnet
            # For local devnet, we use a default account
            print("  Note: For contract addresses, check:")
            print("    - contracts/artifacts/*.json")
            print("    - Environment variables (ORACLE_ADDRESS, etc.)")
            
            # Load environment variables
            oracle_address = os.environ.get('ORACLE_ADDRESS')
            factory_address = os.environ.get('MARKET_FACTORY_ADDRESS')
            
            # Try common devnet addresses if not in environment
            if not oracle_address:
                oracle_address = await self._search_for_contract('OptimisticOracle')
            
            if oracle_address:
                self.oracle_contract = Contract(
                    address=int(oracle_address, 16) if isinstance(oracle_address, str) else oracle_address,
                    abi=self._get_oracle_abi(),
                    provider=self.client
                )
                print(f"✓ Loaded OptimisticOracle: {oracle_address}")

            if factory_address:
                self.market_factory = Contract(
                    address=int(factory_address, 16) if isinstance(factory_address, str) else factory_address,
                    abi=self._get_factory_abi(),
                    provider=self.client
                )
                print(f"✓ Loaded MarketFactory: {factory_address}")
            
            return True
            
        except Exception as e:
            print(f"✗ Failed to load contracts: {e}")
            import traceback
            traceback.print_exc()
            return False
    
    async def _search_for_contract(self, contract_name: str) -> Optional[str]:
        """Search for a contract by name in common locations."""
        # Common devnet deployment addresses
        common_addresses = {
            'OptimisticOracle': [
                '0x123456789012345678901234567890123456789012345678901234567890',
                '0x05a9d05e9e7773317847e2c7c59e8d64a12e8a7a6b8c9d0e1f2a3b4c5d6e7f8',
            ],
            'MarketFactory': [
                '0x234567890123456789012345678901234567890123456789012345678901',
                '0x06b0a1b2c3d4e5f6789012345678901234567890123456789012345678901234',
            ],
        }
        
        for addr in common_addresses.get(contract_name, []):
            try:
                # Try to call a simple function
                await self.client.get_storage_at(
                    contract_address=int(addr, 16),
                    key=0,
                    block_hash="latest"
                )
                return addr
            except:
                continue
        
        return None
    
    def _get_oracle_abi(self) -> List[Dict]:
        """Get OptimisticOracle ABI (simplified for demo)."""
        return [
            {"name": "propose", "inputs": [
                {"name": "market_id", "type": "felt"},
                {"name": "outcome", "type": "felt"},
                {"name": "data_hash", "type": "felt"},
                {"name": "data_uri", "type": "felt"},
                {"name": "bond", "type": "u256"}
            ], "type": "function"},
            {"name": "resolve_arbitration", "inputs": [
                {"name": "market_id", "type": "felt"},
                {"name": "outcome", "type": "felt"}
            ], "type": "function"},
            {"name": "get_market_status", "inputs": [
                {"name": "market_id", "type": "felt"}
            ], "type": "function", "outputs": [
                {"name": "status", "type": "felt"}
            ]},
            {"name": "is_disputed", "inputs": [
                {"name": "market_id", "type": "felt"}
            ], "type": "function", "outputs": [
                {"name": "is_disputed", "type": "bool"}
            ]},
            {"name": "propose_with_proof", "inputs": [
                {"name": "market_id", "type": "felt"},
                {"name": "outcome", "type": "felt"},
                {"name": "data_hash", "type": "felt"},
                {"name": "bond", "type": "u256"},
                {"name": "zk_proof", "type": "felt*"}
            ], "type": "function"},
            {"name": "fast_finalize", "inputs": [
                {"name": "market_id", "type": "felt"}
            ], "type": "function"},
        ]

    def _get_factory_abi(self) -> List[Dict]:
        return [
            {"name": "get_market", "inputs": [
                {"name": "market_id", "type": "u256"}
            ], "type": "function", "outputs": [
                {"name": "market_address", "type": "felt"}
            ]},
        ]

    def _get_market_abi(self) -> List[Dict]:
        return [
            {"name": "resolve_from_oracle", "inputs": [], "type": "function"},
        ]
    
    async def get_due_markets(self) -> List[int]:
        """Get markets that are due for resolution."""
        print("\n=== Getting Due Markets ===")
        
        if not self.oracle_contract:
            print("  ✗ Oracle contract not loaded")
            return []
        
        # In production, we'd query:
        # 1. All markets in PROPOSED state
        # 2. Check if dispute window has passed (for non-disputed markets)
        # 3. Check if arbitration has resolved (for disputed markets)
        
        # For demo, we'll simulate by checking a few known markets
        # or returning empty list if no contract loaded
        
        print("  Note: For production, implement:")
        print("    - Query markets with status = PROPOSED")
        print("    - Check dispute window expiration")
        print("    - Check arbitration status")
        
        return []
    
    async def fetch_growthepie_data(self) -> Dict:
        """Fetch DAA (Daily Active Addresses) data from growthepie."""
        print("\n=== Fetching growthepie Data ===")
        
        # In production, this would call the growthepie API:
        # curl -s https://api.growthepie.com/v1/daily-active-addresses?chain=starknet
        
        # For demo, we'll simulate by returning mock data
        print("  Simulating growthepie API call...")
        
        # Sample DAA data for Starknet
        mock_data = {
            "date": time.strftime("%Y-%m-%d"),
            "daa": 500000,  # 500k DAA
            "daa_7d_ma": 480000,
            "daa_30d_ma": 450000,
        }
        
        print(f"  ✓ Fetched DAA data:")
        print(f"    - DAA (today): {mock_data['daa']:,}")
        print(f"    - DAA (7d MA): {mock_data['daa_7d_ma']:,}")
        
        return mock_data
    
    async def fetch_txcount_data(self) -> Dict:
        """Fetch transaction count data."""
        print("\n=== Fetching Transaction Count Data ===")
        
        # For demo, we'll simulate
        print("  Simulating API call...")
        
        mock_data = {
            "date": time.strftime("%Y-%m-%d"),
            "txcount": 15000,
            "txcount_7d_avg": 14500,
        }
        
        print(f"  ✓ Fetched txcount data:")
        print(f"    - TXCount (today): {mock_data['txcount']:,}")
        
        return mock_data
    
    async def fetch_fees_data(self) -> Dict:
        """Fetch fees data."""
        print("\n=== Fetching Fees Data ===")
        
        # For demo, we'll simulate
        print("  Simulating API call...")
        
        mock_data = {
            "date": time.strftime("%Y-%m-%d"),
            "fees": 500000000000,  # 5e11 (500k stablecoin with 6 decimals)
            "fees_7d_avg": 480000000000,
        }
        
        print(f"  ✓ Fetched fees data:")
        print(f"    - Fees (today): {mock_data['fees'] / 1e6:.2f} Stablecoin")
        
        return mock_data
    
    async def resolve_market_daa(self, market_id: int, daa_data: Dict) -> Tuple[bool, int]:
        """
        Resolve a DAA market based on threshold.
        
        Returns: (outcome, threshold_passed) where outcome is 1=YES, 0=NO
        """
        print(f"\n=== Resolving DAA Market: {market_id} ===")
        
        if not self.oracle_contract:
            print("  ✗ Oracle contract not loaded")
            return False, 0
        
        # Get DAA value
        daa_value = daa_data.get('daa', 0)
        print(f"  DAA Value: {daa_value:,}")
        print(f"  Threshold: {DAE_THRESHOLD:,}")
        
        # Compare DAA to threshold
        threshold_passed = daa_value >= DAA_THRESHOLD
        outcome = OUTCOME_YES if threshold_passed else OUTCOME_NO
        
        return threshold_passed, outcome
        
        outcome_str = "YES" if outcome == OUTCOME_YES else "NO"
        print(f"  ✓ Resolution: {outcome_str} (DAA {'>=' if threshold_passed else '<'} threshold)")
        
        return threshold_passed, outcome
    
    async def resolve_market_txcount(self, market_id: int, txcount_data: Dict) -> Tuple[bool, int]:
        """
        Resolve a txcount market based on threshold.
        
        Returns: (outcome, threshold_passed) where outcome is 1=YES, 0=NO
        """
        print(f"\n=== Resolving TXCount Market: {market_id} ===")
        
        if not self.oracle_contract:
            print("  ✗ Oracle contract not loaded")
            return False, 0
        
        # Get txcount value
        txcount_value = txcount_data.get('txcount', 0)
        print(f"  TXCount Value: {txcount_value:,}")
        print(f"  Threshold: {TXCOUNT_THRESHOLD:,}")
        
        # Compare txcount to threshold
        threshold_passed = txcount_value >= TXCOUNT_THRESHOLD
        outcome = OUTCOME_YES if threshold_passed else OUTCOME_NO
        
        return threshold_passed, outcome
        
        outcome_str = "YES" if outcome == OUTCOME_YES else "NO"
        print(f"  ✓ Resolution: {outcome_str} (txcount {'>=' if threshold_passed else '<'} threshold)")
        
        return threshold_passed, outcome
    
    async def resolve_market_fees(self, market_id: int, fees_data: Dict) -> Tuple[bool, int]:
        """
        Resolve a fees market based on threshold.
        
        Returns: (outcome, threshold_passed) where outcome is 1=YES, 0=NO
        """
        print(f"\n=== Resolving Fees Market: {market_id} ===")
        
        if not self.oracle_contract:
            print("  ✗ Oracle contract not loaded")
            return False, 0
        
        # Get fees value
        fees_value = fees_data.get('fees', 0)
        print(f"  Fees Value: {fees_value / 1e6:.2f} Stablecoin")
        print(f"  Threshold: {FEES_THRESHOLD / 1e6:.2f} Stablecoin")
        
        # Compare fees to threshold
        threshold_passed = fees_value >= FEES_THRESHOLD
        outcome = OUTCOME_YES if threshold_passed else OUTCOME_NO
        
        return threshold_passed, outcome
        
        outcome_str = "YES" if outcome == OUTCOME_YES else "NO"
        print(f"  ✓ Resolution: {outcome_str} (fees {'>=' if threshold_passed else '<'} threshold)")
        
        return threshold_passed, outcome
    
    async def propose_resolution(self, market_id: int, outcome: int, data_hash: str) -> bool:
        """
        Propose resolution outcome to oracle.
        
        Returns: True if proposal succeeded
        """
        print(f"\n=== Proposing Resolution: {market_id} -> {outcome} ===")
        
        if not self.oracle_contract:
            print("  ✗ Oracle contract not loaded")
            return False
        
        try:
            # Build proposal data
            data_uri = "ipfs://resolution-data"
            bond = 100 * 10**6  # 100 stablecoin
            
            print(f"  Market ID: {market_id}")
            print(f"  Outcome: {outcome} (1=YES, 0=NO)")
            print(f"  Data Hash: {data_hash}")
            
            # Call oracle.propose()
            result = await self.oracle_contract.functions["propose"].invoke(
                market_id=market_id,
                outcome=outcome,
                data_hash=data_hash,
                data_uri=encode_felt(data_uri),
                bond=bond,
                max_fee=int(1e16)
            )
            
            print(f"  ✓ Proposal submitted: {hex(result.transaction_hash)}")
            
            # Wait for acceptance
            await wait_for_tx(self.client, result.transaction_hash)
            print(f"  ✓ Proposal accepted")
            
            return True
            
        except Exception as e:
            print(f"  ✗ Proposal failed: {e}")
            import traceback
            traceback.print_exc()
            return False
    
    async def run_resolve_arbitration(self, market_id: int, outcome: int) -> bool:
        """
        Call oracle.resolve_arbitration to finalize the market.
        
        Returns: True if resolution succeeded
        """
        print(f"\n=== Resolving via Arbitration: {market_id} -> {outcome} ===")
        
        if not self.oracle_contract:
            print("  ✗ Oracle contract not loaded")
            return False
        
        try:
            print(f"  Market ID: {market_id}")
            print(f"  Outcome: {outcome} (1=YES, 0=NO)")
            
            # Call oracle.resolve_arbitration()
            result = await self.oracle_contract.functions["resolve_arbitration"].invoke(
                market_id=market_id,
                outcome=outcome,
                max_fee=int(1e16)
            )
            
            print(f"  ✓ Arbitration submitted: {hex(result.transaction_hash)}")
            
            # Wait for acceptance
            await wait_for_tx(self.client, result.transaction_hash)
            print(f"  ✓ Arbitration accepted")
            
            # Verify resolution
            status = await self.oracle_contract.functions["get_market_status"].call(market_id)
            status_str = {0: "PENDING", 1: "PROPOSED", 2: "RESOLVED", 3: "VOIDED"}.get(status, f"UNKNOWN({status})")
            print(f"  ✓ Market status: {status_str}")

            if status == RESOLVED:
                await self.resolve_market_from_oracle(market_id)
                return True
            return False
            
        except Exception as e:
            print(f"  ✗ Arbitration failed: {e}")
            import traceback
            traceback.print_exc()
            return False

    async def resolve_market_from_oracle(self, market_id: int) -> bool:
        """Resolve the Market contract via OptimisticOracle outcome."""
        if not self.market_factory:
            return False
        try:
            market_addr = await self.market_factory.functions["get_market"].call(
                market_id={"low": market_id, "high": 0}
            )
            market = Contract(
                address=int(market_addr),
                abi=self._get_market_abi(),
                provider=self.client
            )
            result = await market.functions["resolve_from_oracle"].invoke(
                max_fee=int(1e16)
            )
            await wait_for_tx(self.client, result.transaction_hash)
            print("  ✓ Market resolved from oracle")
            return True
        except Exception as e:
            print(f"  ✗ Failed to resolve market from oracle: {e}")
            return False
    
    async def run(self) -> bool:
        """Run the oracle once."""
        print("=" * 60)
        print("Cairox Oracle Runner - One-Shot Resolution")
        print("=" * 60)
        
        # Connect to devnet
        if not await self.connect():
            return False
        
        # Load contracts
        await self.load_contracts()
        
        results = []
        
        # Step 1: Get due markets
        due_markets = await self.get_due_markets()
        print(f"\nDue Markets: {len(due_markets)}")
        
        # Step 2: Fetch external data
        daa_data = await self.fetch_growthepie_data()
        txcount_data = await self.fetch_txcount_data()
        fees_data = await self.fetch_fees_data()
        
        # Step 3: Resolve DAA market
        if daa_data:
            threshold_passed, outcome = await self.resolve_market_daa(1001, daa_data)
            if threshold_passed:
                data_hash = pedersen_hash(encode_felt(json.dumps(daa_data)), encode_felt("daa_resolution"))
                # propose_result = await self.propose_resolution(1001, outcome, data_hash)
                # results.append(propose_result)
                
                # For demo, we'll call resolve_arbitration directly
                resolve_result = await self.run_resolve_arbitration(1001, outcome)
                results.append(resolve_result)
        
        # Step 4: Resolve TXCount market
        if txcount_data:
            threshold_passed, outcome = await self.resolve_market_txcount(1002, txcount_data)
            if threshold_passed:
                data_hash = pedersen_hash(encode_felt(json.dumps(txcount_data)), encode_felt("txcount_resolution"))
                resolve_result = await self.run_resolve_arbitration(1002, outcome)
                results.append(resolve_result)
        
        # Step 5: Resolve Fees market
        if fees_data:
            threshold_passed, outcome = await self.resolve_market_fees(1003, fees_data)
            if threshold_passed:
                data_hash = pedersen_hash(encode_felt(json.dumps(fees_data)), encode_felt("fees_resolution"))
                resolve_result = await self.run_resolve_arbitration(1003, outcome)
                results.append(resolve_result)
        
        # Summary
        print("\n" + "=" * 60)
        print("Oracle Run Summary")
        print("=" * 60)
        
        passed = sum(results)
        total = len(results)
        
        print(f"  Resolved Markets: {passed}/{total}")
        
        for i, result in enumerate(results, 1):
            status = "✓ SUCCESS" if result else "✗ FAILED"
            print(f"  Market {i}: {status}")
        
        if passed == total:
            print(f"\n  ✓ Oracle run completed successfully!")
            return True
        else:
            print(f"\n  ⚠️  Some markets failed to resolve")
            return False


async def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description="Oracle runner for Cairox deterministic markets"
    )
    parser.add_argument(
        "--devnet-url",
        default=DEFAULT_DEVNET_URL,
        help=f"Starknet devnet URL (default: {DEFAULT_DEVNET_URL})"
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Enable verbose output"
    )
    
    args = parser.parse_args()
    
    # Run oracle
    oracle = OracleRunner(devnet_url=args.devnet_url, verbose=args.verbose)
    success = await oracle.run()
    
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    import asyncio
    asyncio.run(main())
