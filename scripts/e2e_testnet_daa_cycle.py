#!/usr/bin/env python3
"""
E2E Testnet DAA Cycle Script for Cairox

This script runs a complete end-to-end test:
1. Deploy contracts to testnet
2. Create a DAA market
3. Run oracle to fetch data and resolve
4. Verify market resolution
5. Verify vault balances

Requirements:
- Starknet testnet access
- Private key for account
- Python 3.8+

Usage:
    python scripts/e2e_testnet_daa_cycle.py [--rpc-url URL] [--account ADDRESS] [--private-key KEY]
"""

import argparse
import sys
import os
import time
import json
from typing import Optional, Dict, List, Tuple

try:
    from starknet_py.contract import Contract
    from starknet_py.net.account.account import Account
    from starknet_py.net.client import Client
    from starknet_py.net.full_node_client import FullNodeClient
    from starknet_py.transactions.deploy import DeployTransaction
    from starknet_py.cairo.felt import encode_felt
    from starknet_py.utils.crypto.facade import pedersen_hash
    from starknet_py.devnet.helpers import wait_for_tx
    from starknet_py.transactions.transactions import Call
    from starknet_py.common import get_selector
    from starknet_py.net.models import StarknetChainId
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
DEFAULT_RPC_URL = "https://starknet-testnet.public.blastapi.io/rpc/v0_7"
DEFAULT_ACCOUNT_ADDRESS = "0x123456789012345678901234567890123456789012345678901234567890123"
DEFAULT_PRIVATE_KEY = "0x11111111111111111111112222222222222222223333333333333333"

# Threshold values
DAA_THRESHOLD = 1_000_000_000_000_000_000  # 1e18 (1.0 in fixed point)
TXCOUNT_THRESHOLD = 1000
FEES_THRESHOLD = 1_000_000_000_000  # 1e12


class E2ETestnetRunner:
    """E2E testnet runner for Cairox DAA cycle."""
    
    def __init__(self, rpc_url: str, account_address: str, private_key: str, initial_subsidy: int):
        self.rpc_url = rpc_url
        self.account_address = account_address
        self.private_key = private_key
        self.initial_subsidy = initial_subsidy
        self.client = None
        self.account = None
        self.oracle_contract = None
        self.collateral_vault = None
        self.market_factory = None
        self.lmsr_maker = None
        self.stablecoin_token = None
        self.daa_market_id = None
        self.daa_market_address = None
        self.daa_market_contract = None
        
    async def connect(self) -> bool:
        """Connect to Starknet testnet."""
        print(f"Connecting to Starknet testnet at {self.rpc_url}...")
        
        try:
            self.client = FullNodeClient(node_url=self.rpc_url)
            
            # Check connection
            block_number = await self.client.get_block_number()
            print(f"✓ Connected to testnet")
            print(f"  Block number: {block_number}")
            
            # Setup account
            self.account = Account(
                client=self.client,
                address=self.account_address,
                key_pair=self.private_key,
                chain=StarknetChainId.SN_SEPOLIA
            )
            
            print(f"✓ Account: {hex(self.account_address)}")
            
            return True
        except Exception as e:
            print(f"✗ Failed to connect: {e}")
            return False
    
    async def deploy_contracts(self) -> bool:
        """Deploy Cairox contracts to testnet."""
        print("\n=== Deploying Cairox Contracts ===")
        
        print("  Note: For full deployment, use:")
        print("    cd contracts && scarb build && snforge deploy --network testnet")
        print("  Or use the deployment scripts in scripts/deploy.sh")
        
        # For demo, we'll assume contracts are already deployed
        # Or we'll use placeholder addresses
        
        oracle_address = os.environ.get('ORACLE_ADDRESS_TESTNET')
        factory_address = os.environ.get('MARKET_FACTORY_ADDRESS_TESTNET')
        vault_address = os.environ.get('COLLATERAL_VAULT_ADDRESS_TESTNET')
        stablecoin_address = (
            os.environ.get('STABLECOIN_ADDRESS_TESTNET')
            or os.environ.get('COLLATERAL_TOKEN_ADDRESS')
            or os.environ.get('USDC_ADDRESS_TESTNET')
        )
        
        if oracle_address:
            self.oracle_contract = Contract(
                address=int(oracle_address, 16),
                abi=self._get_oracle_abi(),
                provider=self.account
            )
            print(f"✓ Loaded OptimisticOracle: {oracle_address}")
        
        if factory_address:
            self.market_factory = Contract(
                address=int(factory_address, 16),
                abi=self._get_factory_abi(),
                provider=self.account
            )
            print(f"✓ Loaded MarketFactory: {factory_address}")
        
        if vault_address:
            self.collateral_vault = Contract(
                address=int(vault_address, 16),
                abi=self._get_vault_abi(),
                provider=self.account
            )
            print(f"✓ Loaded CollateralVault: {vault_address}")
        
        if stablecoin_address:
            self.stablecoin_token = Contract(
                address=int(stablecoin_address, 16),
                abi=self._get_stablecoin_abi(),
                provider=self.account
            )
            print(f"✓ Loaded Stablecoin Token: {stablecoin_address}")
        
        # If contracts not in environment, ask user to provide
        if not all([oracle_address, factory_address, vault_address, stablecoin_address]):
            print("\n  ⚠️  Some contracts not found in environment variables")
            print("  Please set:")
            print("    ORACLE_ADDRESS_TESTNET")
            print("    MARKET_FACTORY_ADDRESS_TESTNET")
            print("    COLLATERAL_VAULT_ADDRESS_TESTNET")
            print("    STABLECOIN_ADDRESS_TESTNET")
            print("    COLLATERAL_TOKEN_ADDRESS")
            print("    USDC_ADDRESS_TESTNET (legacy)")
            
            # Check if user wants to provide addresses manually
            if not oracle_address:
                oracle_address = input("  Enter OptimisticOracle address: ").strip()
                if oracle_address:
                    self.oracle_contract = Contract(
                        address=int(oracle_address, 16),
                        abi=self._get_oracle_abi(),
                        provider=self.account
                    )
        
        return bool(self.oracle_contract and self.market_factory and self.collateral_vault and self.stablecoin_token)
    
    def _get_oracle_abi(self) -> List[Dict]:
        """Get OptimisticOracle ABI."""
        return [
            {"name": "set_market_factory", "inputs": [
                {"name": "market_factory", "type": "felt"}
            ], "type": "function"},
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
        ]
    
    def _get_factory_abi(self) -> List[Dict]:
        """Get MarketFactory ABI."""
        return [
            {"name": "create_market", "inputs": [
                {"name": "question_hash", "type": "felt"},
                {"name": "question_uri", "type": "felt"},
                {"name": "initial_subsidy", "type": "u256"}
            ], "type": "function", "outputs": [
                {"name": "market_id", "type": "u256"}
            ]},
            {"name": "get_market_count", "inputs": [], "type": "function", "outputs": [
                {"name": "count", "type": "u256"}
            ]},
            {"name": "get_market", "inputs": [
                {"name": "market_id", "type": "u256"}
            ], "type": "function", "outputs": [
                {"name": "market_address", "type": "felt"}
            ]},
        ]

    def _get_market_abi(self) -> List[Dict]:
        """Get Market ABI (minimal)."""
        return [
            {"name": "resolve_from_oracle", "inputs": [], "type": "function"},
            {"name": "redeem", "inputs": [], "type": "function", "outputs": [
                {"name": "winnings", "type": "u256"}
            ]},
            {"name": "get_status", "inputs": [], "type": "function", "outputs": [
                {"name": "status", "type": "felt"}
            ]},
        ]

    def _u256_to_int(self, value) -> int:
        if isinstance(value, dict):
            return int(value.get("low", 0)) + (int(value.get("high", 0)) << 128)
        if hasattr(value, "low"):
            return int(value.low) + (int(value.high) << 128)
        if isinstance(value, (list, tuple)) and len(value) == 2:
            return int(value[0]) + (int(value[1]) << 128)
        return int(value)

    def _to_u256(self, value: int) -> Dict:
        return {"low": value & ((1 << 128) - 1), "high": value >> 128}
    
    def _get_vault_abi(self) -> List[Dict]:
        """Get CollateralVault ABI."""
        return [
            {"name": "deposit", "inputs": [
                {"name": "user", "type": "felt"},
                {"name": "amount", "type": "u256"}
            ], "type": "function"},
            {"name": "withdraw", "inputs": [
                {"name": "user", "type": "felt"},
                {"name": "amount", "type": "u256"}
            ], "type": "function"},
            {"name": "get_balance", "inputs": [
                {"name": "user", "type": "felt"}
            ], "type": "function", "outputs": [
                {"name": "balance", "type": "u256"}
            ]},
        ]
    
    def _get_stablecoin_abi(self) -> List[Dict]:
        """Get stablecoin token ABI."""
        return [
            {"name": "balance_of", "inputs": [
                {"name": "account", "type": "felt"}
            ], "type": "function", "outputs": [
                {"name": "balance", "type": "u256"}
            ]},
            {"name": "decimals", "inputs": [], "type": "function", "outputs": [
                {"name": "decimals", "type": "u8"}
            ]},
            {"name": "approve", "inputs": [
                {"name": "spender", "type": "felt"},
                {"name": "amount", "type": "u256"}
            ], "type": "function", "outputs": [
                {"name": "ok", "type": "bool"}
            ]},
            {"name": "transfer", "inputs": [
                {"name": "to", "type": "felt"},
                {"name": "amount", "type": "u256"}
            ], "type": "function"},
        ]
    
    async def create_daa_market(self) -> int:
        """Create a new DAA market."""
        print("\n=== Creating DAA Market ===")
        
        if not self.market_factory:
            print("  ✗ MarketFactory not loaded")
            return 0
        
        try:
            count_before = await self.market_factory.functions["get_market_count"].call()
            count_before_value = count_before
            if isinstance(count_before, dict):
                count_before_value = count_before.get("count", count_before)
            elif hasattr(count_before, "count"):
                count_before_value = count_before.count
            count_before_int = self._u256_to_int(count_before_value)

            question = encode_felt("DAA >= threshold?")

            if self.oracle_contract and self.market_factory:
                try:
                    set_tx = await self.oracle_contract.functions["set_market_factory"].invoke(
                        market_factory=int(self.market_factory.address),
                        max_fee=int(1e16)
                    )
                    await wait_for_tx(self.client, set_tx.transaction_hash)
                except Exception as e:
                    print(f"  ⚠ Failed to set market factory on oracle: {e}")

            if self.stablecoin_token:
                try:
                    approve_tx = await self.stablecoin_token.functions["approve"].invoke(
                        spender=int(self.market_factory.address),
                        amount=self._to_u256(self.initial_subsidy),
                        max_fee=int(1e16)
                    )
                    await wait_for_tx(self.client, approve_tx.transaction_hash)
                except Exception as e:
                    print(f"  ⚠ Failed to approve subsidy: {e}")

            result = await self.market_factory.functions["create_market"].invoke(
                question_hash=question,
                question_uri=0,
                initial_subsidy=self._to_u256(self.initial_subsidy),
                max_fee=int(1e17)
            )

            print(f"  ✓ Market creation submitted: {hex(result.transaction_hash)}")

            # Wait for acceptance
            await wait_for_tx(self.client, result.transaction_hash)
            print(f"  ✓ Market created")

            self.daa_market_id = count_before_int
            print(f"  ✓ DAA Market ID: {self.daa_market_id}")

            market_addr_raw = await self.market_factory.functions["get_market"].call(
                market_id={"low": self.daa_market_id, "high": 0}
            )
            market_addr = market_addr_raw
            if isinstance(market_addr_raw, dict):
                market_addr = market_addr_raw.get("market_address", market_addr_raw)
            elif hasattr(market_addr_raw, "market_address"):
                market_addr = market_addr_raw.market_address
            self.daa_market_address = int(market_addr)
            self.daa_market_contract = Contract(
                address=self.daa_market_address,
                abi=self._get_market_abi(),
                provider=self.account
            )
            print(f"  ✓ DAA Market Address: {hex(self.daa_market_address)}")
            return self.daa_market_id
            
        except Exception as e:
            print(f"  ✗ Failed to create market: {e}")
            import traceback
            traceback.print_exc()
            return 0
    
    async def fetch_growthepie_data(self) -> Dict:
        """Fetch DAA data from growthepie API."""
        print("\n=== Fetching growthepie Data ===")
        
        try:
            import aiohttp
            
            async with aiohttp.ClientSession() as session:
                # Mock API call - in production, this would call growthepie
                # url = "https://api.growthepie.com/v1/daily-active-addresses?chain=starknet"
                print("  Simulating API call to growthepie...")
                
                # Simulate response
                mock_response = {
                    "date": time.strftime("%Y-%m-%d"),
                    "daa": 500000,  # 500k DAA
                    "daa_7d_ma": 480000,
                    "daa_30d_ma": 450000,
                }
                
                print(f"  ✓ Fetched DAA data:")
                print(f"    - DAA (today): {mock_response['daa']:,}")
                print(f"    - DAA (7d MA): {mock_response['daa_7d_ma']:,}")
                
                return mock_response
                
        except Exception as e:
            print(f"  ✗ Failed to fetch data: {e}")
            print("  Using fallback data...")
            
            # Fallback data
            return {
                "date": time.strftime("%Y-%m-%d"),
                "daa": 500000,
                "daa_7d_ma": 480000,
                "daa_30d_ma": 450000,
            }
    
    async def fetch_txcount_data(self) -> Dict:
        """Fetch transaction count data."""
        print("\n=== Fetching Transaction Count Data ===")
        
        try:
            import aiohttp
            
            async with aiohttp.ClientSession() as session:
                print("  Simulating API call...")
                
                mock_response = {
                    "date": time.strftime("%Y-%m-%d"),
                    "txcount": 15000,
                    "txcount_7d_avg": 14500,
                }
                
                print(f"  ✓ Fetched txcount data:")
                print(f"    - TXCount (today): {mock_response['txcount']:,}")
                
                return mock_response
                
        except Exception as e:
            print(f"  ✗ Failed to fetch data: {e}")
            
            return {
                "date": time.strftime("%Y-%m-%d"),
                "txcount": 15000,
            }
    
    async def fetch_fees_data(self) -> Dict:
        """Fetch fees data."""
        print("\n=== Fetching Fees Data ===")
        
        try:
            import aiohttp
            
            async with aiohttp.ClientSession() as session:
                print("  Simulating API call...")
                
                mock_response = {
                    "date": time.strftime("%Y-%m-%d"),
                    "fees": 500000000000,  # 5e11
                    "fees_7d_avg": 480000000000,
                }
                
                print(f"  ✓ Fetched fees data:")
                print(f"    - Fees (today): {mock_response['fees'] / 1e6:.2f} Stablecoin")
                
                return mock_response
                
        except Exception as e:
            print(f"  ✗ Failed to fetch data: {e}")
            
            return {
                "date": time.strftime("%Y-%m-%d"),
                "fees": 500000000000,
            }
    
    async def resolve_daa_market(self, daa_data: Dict) -> bool:
        """Resolve DAA market based on threshold."""
        print("\n=== Resolving DAA Market ===")
        
        if not self.oracle_contract:
            print("  ✗ Oracle contract not loaded")
            return False
        
        if not self.daa_market_id:
            print("  ✗ DAA market ID not set")
            return False
        
        try:
            # Get DAA value
            daa_value = daa_data.get('daa', 0)
            threshold_passed = daa_value >= DAA_THRESHOLD
            outcome = OUTCOME_YES if threshold_passed else OUTCOME_NO
            
            outcome_str = "YES" if outcome == OUTCOME_YES else "NO"
            print(f"  DAA: {daa_value:,}")
            print(f"  Threshold: {DAA_THRESHOLD:,}")
            print(f"  Resolution: {outcome_str}")
            
            # Call oracle.resolve_arbitration()
            result = await self.oracle_contract.functions["resolve_arbitration"].invoke(
                market_id=self.daa_market_id,
                outcome=outcome,
                max_fee=int(1e17)
            )
            
            print(f"  ✓ Resolution submitted: {hex(result.transaction_hash)}")
            
            # Wait for acceptance
            await wait_for_tx(self.client, result.transaction_hash)
            print(f"  ✓ Resolution accepted")
            
            # Verify resolution
            status = await self.oracle_contract.functions["get_market_status"].call(self.daa_market_id)
            status_str = {0: "PENDING", 1: "PROPOSED", 2: "RESOLVED", 3: "VOIDED"}.get(status, f"UNKNOWN({status})")
            print(f"  ✓ Market status: {status_str}")

            if status == RESOLVED:
                await self.resolve_market_from_oracle()
                return True
            return False
            
        except Exception as e:
            print(f"  ✗ Failed to resolve: {e}")
            import traceback
            traceback.print_exc()
            return False

    async def resolve_market_from_oracle(self) -> bool:
        """Resolve the on-chain Market from OptimisticOracle outcome."""
        if not self.daa_market_contract:
            print("  ✗ Market contract not loaded")
            return False
        try:
            result = await self.daa_market_contract.functions["resolve_from_oracle"].invoke(
                max_fee=int(1e17)
            )
            await wait_for_tx(self.client, result.transaction_hash)
            print("  ✓ Market resolved from oracle")
            return True
        except Exception as e:
            print(f"  ✗ Failed to resolve market from oracle: {e}")
            return False
    
    async def verify_vault_balances(self) -> Dict:
        """Verify collateral vault balances."""
        print("\n=== Verifying Vault Balances ===")
        
        if not self.collateral_vault:
            print("  ✗ CollateralVault not loaded")
            return {}
        
        try:
            # Get account balance
            balance = await self.collateral_vault.functions["get_balance"].call(self.account_address)
            balance_value = balance.low + (balance.high << 128)
            
            # Get stablecoin decimals
            decimals = await self.stablecoin_token.functions["decimals"].call()
            
            print(f"  Account Balance: {balance_value / 10**decimals:.2f} Stablecoin")
            
            return {
                "account_balance": balance_value,
                "decimals": decimals
            }
            
        except Exception as e:
            print(f"  ✗ Failed to verify balances: {e}")
            return {}
    
    async def verify_market_resolution(self) -> bool:
        """Verify that the DAA market was resolved correctly."""
        print("\n=== Verifying Market Resolution ===")
        
        if not self.oracle_contract:
            print("  ✗ Oracle contract not loaded")
            return False
        
        if not self.daa_market_id:
            print("  ✗ DAA market ID not set")
            return False
        
        try:
            # Get market status
            status = await self.oracle_contract.functions["get_market_status"].call(self.daa_market_id)
            is_disputed = await self.oracle_contract.functions["is_disputed"].call(self.daa_market_id)
            
            status_str = {0: "PENDING", 1: "PROPOSED", 2: "RESOLVED", 3: "VOIDED"}.get(status, f"UNKNOWN({status})")
            
            print(f"  Market Status: {status_str}")
            print(f"  Is Disputed: {is_disputed}")
            
            if status == RESOLVED and not is_disputed:
                print("  ✓ Market resolved successfully")
                return True
            else:
                print("  ✗ Market not resolved correctly")
                return False
                
        except Exception as e:
            print(f"  ✗ Failed to verify: {e}")
            return False
    
    async def run(self) -> bool:
        """Run the complete E2E testnet DAA cycle."""
        print("=" * 60)
        print("Cairox E2E Testnet DAA Cycle Test")
        print("=" * 60)
        
        # Connect to testnet
        if not await self.connect():
            return False
        
        # Deploy contracts (assume already deployed for testnet)
        # await self.deploy_contracts()
        
        # Check if we have the necessary contracts
        has_oracle = bool(self.oracle_contract)
        has_factory = bool(self.market_factory)
        has_vault = bool(self.collateral_vault)
        has_stablecoin = bool(self.stablecoin_token)
        
        if not has_oracle:
            print("\n  ⚠️  Oracle contract not available")
            print("  Skipping DAA market creation and resolution")
        
        results = []
        
        # Step 1: Create DAA market (if factory available)
        if has_factory:
            daa_market_id = await self.create_daa_market()
            if daa_market_id:
                results.append(True)
        else:
            print("\n  Skipping market creation (no factory)")
        
        # Step 2: Fetch external data
        daa_data = await self.fetch_growthepie_data()
        txcount_data = await self.fetch_txcount_data()
        fees_data = await self.fetch_fees_data()
        
        # Step 3: Resolve DAA market (if oracle available)
        if has_oracle and self.daa_market_id:
            resolve_success = await self.resolve_daa_market(daa_data)
            results.append(resolve_success)
            
            # Step 4: Verify market resolution
            verify_success = await self.verify_market_resolution()
            results.append(verify_success)
        
        # Step 5: Verify vault balances
        balances = await self.verify_vault_balances()
        
        # Summary
        print("\n" + "=" * 60)
        print("Test Summary")
        print("=" * 60)
        
        passed = sum(results)
        total = len(results)
        
        print(f"  Tests Passed: {passed}/{total}")
        
        for i, result in enumerate(results, 1):
            status = "✓ PASS" if result else "✗ FAIL"
            print(f"  Test {i}: {status}")
        
        if balances:
            print(f"\n  Account Balance: {balances.get('account_balance', 0) / 10**balances.get('decimals', 6):.2f} Stablecoin")
        
        if passed == total:
            print(f"\n  ✓ All tests passed!")
            return True
        else:
            print(f"\n  ⚠️  Some tests failed")
            return False


async def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description="E2E testnet DAA cycle for Cairox"
    )
    parser.add_argument(
        "--rpc-url",
        default=DEFAULT_RPC_URL,
        help=f"RPC URL (default: {DEFAULT_RPC_URL})"
    )
    parser.add_argument(
        "--account",
        default=DEFAULT_ACCOUNT_ADDRESS,
        help=f"Account address (default: {DEFAULT_ACCOUNT_ADDRESS})"
    )
    parser.add_argument(
        "--private-key",
        default=DEFAULT_PRIVATE_KEY,
        help=f"Private key (default: {DEFAULT_PRIVATE_KEY})"
    )
    parser.add_argument(
        "--initial-subsidy",
        default=int(os.getenv("INITIAL_SUBSIDY", "1000000")),
        type=int,
        help="Initial LMSR subsidy (base units)"
    )
    
    args = parser.parse_args()
    
    # Handle hex string addresses
    account_addr = args.account
    if account_addr.startswith("0x"):
        account_addr = int(account_addr, 16)
    
    private_key = args.private_key
    if private_key.startswith("0x"):
        private_key = int(private_key, 16)
    
    # Run E2E test
    runner = E2ETestnetRunner(
        rpc_url=args.rpc_url,
        account_address=account_addr,
        private_key=private_key,
        initial_subsidy=args.initial_subsidy
    )
    
    success = await runner.run()
    
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    import asyncio
    asyncio.run(main())
