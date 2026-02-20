"""
Starknet Contract Interaction

This module provides functionality to interact with the OptimisticOracle contract
on Starknet, including proposing outcomes and finalizing markets.
"""

import asyncio
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, Optional, Union

# Check if starknet.py is available
try:
    from starknet_py.net.account.account import Account
    from starknet_py.net.client import Client
    from starknet_py.net.models import Address, Call
    from starknet_py.transaction_handling import TransactionResult
    
    STARKNET_PY_AVAILABLE = True
except ImportError:
    STARKNET_PY_AVAILABLE = False


class StarknetInterface:
    """
    Interface for interacting with Starknet contracts.
    Supports both starknet.py and starkli command-line interface.
    """
    
    def __init__(
        self,
        network: str = "goerli",
        account_address: Optional[str] = None,
        private_key: Optional[str] = None,
        starkli_path: str = "starkli",
    ):
        """
        Initialize the Starknet interface.
        
        Args:
            network: Starknet network to connect to (goerli, mainnet, sepolia)
            account_address: Account address for transactions
            private_key: Private key for signing transactions
            starkli_path: Path to starkli CLI executable
        """
        self.network = network
        self.account_address = account_address or os.getenv("STARKNET_ACCOUNT_ADDRESS")
        self.private_key = private_key or os.getenv("STARKNET_PRIVATE_KEY")
        self.starkli_path = starkli_path
        
        # Contract addresses (defaults - should be overridden)
        self.oracle_address = os.getenv("ORACLE_CONTRACT_ADDRESS")
        self.calculator_address = os.getenv("CALCULATOR_CONTRACT_ADDRESS")
        
        # Initialize starknet.py client if available
        self.client = None
        self.account = None
        if STARKNET_PY_AVAILABLE:
            self._initialize_starknet_py()
    
    def _initialize_starknet_py(self):
        """Initialize starknet.py client and account."""
        try:
            self.client = Client(
                node_url=self._get_node_url(),
                chain=self._get_chain_id()
            )
            
            if self.account_address and self.private_key:
                self.account = Account(
                    client=self.client,
                    address=self.account_address,
                    key_pair=self.private_key,
                    chain=self._get_chain_id(),
                )
        except Exception as e:
            print(f"Warning: Failed to initialize starknet.py: {e}")
            self.client = None
            self.account = None
    
    def _get_node_url(self) -> str:
        """Get RPC node URL based on network."""
        urls = {
            "goerli": "https://goerli.gateway.fm",
            "mainnet": "https://starknet-mainnet.public.blastapi.io",
            "sepolia": "https://.sepolia.starknet_gateway.io",
            "localhost": "http://127.0.0.1:5050",
        }
        return urls.get(self.network, urls["goerli"])
    
    def _get_chain_id(self) -> str:
        """Get chain ID based on network."""
        chain_ids = {
            "goerli": "SN_GOERLI",
            "mainnet": "SN_MAIN",
            "sepolia": "SN_SEPOLIA",
            "localhost": "SN_LOCAL",
        }
        return chain_ids.get(self.network, "SN_GOERLI")
    
    def _call_starkli(self, args: list) -> str:
        """
        Execute a starkli command.
        
        Args:
            args: Command arguments
        
        Returns:
            Command output
        """
        cmd = [self.starkli_path] + args
        
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=60,
            )
            
            if result.returncode != 0:
                raise RuntimeError(f"starkli failed: {result.stderr}")
            
            return result.stdout.strip()
        except FileNotFoundError:
            raise RuntimeError(
                f"starkli not found. Please install starkli or set starkli_path."
            )
        except subprocess.TimeoutExpired:
            raise RuntimeError("starkli command timed out")
    
    def get_balance(self, address: Optional[str] = None) -> float:
        """
        Get ETH balance of an address.
        
        Args:
            address: Address to check (defaults to account address)
        
        Returns:
            Balance in ETH
        """
        addr = address or self.account_address
        if not addr:
            raise ValueError("No address provided")
        
        if self.account:
            # Use starknet.py
            from starknet_py.contract import Contract
            from starknet_py.utils.xyk_hash import get_hash
            
            eth_address = self._get_eth_token_address()
            
            balance = asyncio.run(
                Contract(address=eth_address, abi=[], client=self.client).functions["balanceOf"].call(addr)
            )
            return float(balance.balance) / 1e18
        else:
            # Use starkli
            output = self._call_starkli([
                "call",
                self._get_eth_token_address(),
                "balanceOf",
                addr,
            ])
            
            # Parse output - starkli returns hex by default
            balance_hex = output.strip()
            return int(balance_hex, 16) / 1e18
    
    def _get_eth_token_address(self) -> str:
        """Get ETH token contract address."""
        addresses = {
            "goerli": "0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7",
            "mainnet": "0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7",
            "sepolia": "0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7",
        }
        return addresses.get(self.network, addresses["goerli"])
    
    def propose(
        self,
        market_id: str,
        outcome: str,
        data_hash: str,
        data_uri: str,
    ) -> Dict[str, Any]:
        """
        Propose an outcome for a market.
        
        Args:
            market_id: Market identifier
            outcome: Proposed outcome (YES/NO or winner name)
            data_hash: SHA256 hash of the raw data
            data_uri: URI to the raw data
        
        Returns:
            Transaction result dictionary
        """
        if not self.oracle_address:
            raise ValueError("Oracle contract address not set")
        
        if self.account:
            return self._propose_starknet_py(market_id, outcome, data_hash, data_uri)
        else:
            return self._propose_starkli(market_id, outcome, data_hash, data_uri)
    
    def _propose_starknet_py(
        self,
        market_id: str,
        outcome: str,
        data_hash: str,
        data_uri: str,
    ) -> Dict[str, Any]:
        """Propose using starknet.py."""
        from starknet_py.utils.crypto.facade import encode_avm
        from starknet_py.utils.transaction_helpers import broadcast_tx
        
        # Convert outcome to felt (simplified - adjust for your contract's encoding)
        outcome_felt = encode_avm(outcome)
        data_hash_felt = int(data_hash, 16)
        # For data_uri, use a hash or encode as felt
        uri_hash = int.from_bytes(data_uri.encode()[:31], 'big')
        
        # Execute the propose function
        call = Call(
            to_addr=self.oracle_address,
            selector="propose",
            calldata=[
                int(market_id),
                outcome_felt,
                data_hash_felt,
                uri_hash,
            ],
        )
        
        try:
            tx = asyncio.run(broadcast_tx(self.account, [call], max_fee=int(1e16)))
            return {
                "success": True,
                "transaction_hash": hex(tx.hash),
                "status": "pending",
            }
        except Exception as e:
            return {
                "success": False,
                "error": str(e),
            }
    
    def _propose_starkli(
        self,
        market_id: str,
        outcome: str,
        data_hash: str,
        data_uri: str,
    ) -> Dict[str, Any]:
        """Propose using starkli CLI."""
        # Encode values for starkli
        outcome_bytes = outcome.encode()[:31].ljust(31, b'\0')
        outcome_felt = int.from_bytes(outcome_bytes, 'big')
        data_hash_felt = int(data_hash, 16)
        uri_hash = int.from_bytes(data_uri.encode()[:31], 'big')
        
        # Build command
        # This assumes the oracle contract has a propose function with signature:
        # propose(market_id: felt, outcome: felt, data_hash: felt, data_uri: felt)
        cmd = [
            "invoke",
            self.oracle_address,
            "propose",
            str(int(market_id)),
            str(outcome_felt),
            str(data_hash_felt),
            str(uri_hash),
        ]
        
        # Add fee arguments if needed
        if self.account_address:
            cmd.extend(["--account", self.account_address])
        
        try:
            output = self._call_starkli(cmd)
            tx_hash = output.split("Transaction hash: ")[-1].strip() if "Transaction hash:" in output else output
            return {
                "success": True,
                "transaction_hash": tx_hash,
                "status": "pending",
                "raw_output": output,
            }
        except Exception as e:
            return {
                "success": False,
                "error": str(e),
            }
    
    def finalize(self, market_id: str) -> Dict[str, Any]:
        """
        Finalize a market after the dispute window.
        
        Args:
            market_id: Market identifier
        
        Returns:
            Transaction result dictionary
        """
        if not self.oracle_address:
            raise ValueError("Oracle contract address not set")
        
        if self.account:
            return self._finalize_starknet_py(market_id)
        else:
            return self._finalize_starkli(market_id)
    
    def _finalize_starknet_py(self, market_id: str) -> Dict[str, Any]:
        """Finalize using starknet.py."""
        call = Call(
            to_addr=self.oracle_address,
            selector="finalize",
            calldata=[int(market_id)],
        )
        
        try:
            tx = asyncio.run(broadcast_tx(self.account, [call], max_fee=int(1e16)))
            return {
                "success": True,
                "transaction_hash": hex(tx.hash),
                "status": "pending",
            }
        except Exception as e:
            return {
                "success": False,
                "error": str(e),
            }
    
    def _finalize_starkli(self, market_id: str) -> Dict[str, Any]:
        """Finalize using starkli CLI."""
        cmd = [
            "invoke",
            self.oracle_address,
            "finalize",
            str(int(market_id)),
        ]
        
        if self.account_address:
            cmd.extend(["--account", self.account_address])
        
        try:
            output = self._call_starkli(cmd)
            tx_hash = output.split("Transaction hash: ")[-1].strip() if "Transaction hash:" in output else output
            return {
                "success": True,
                "transaction_hash": tx_hash,
                "status": "pending",
                "raw_output": output,
            }
        except Exception as e:
            return {
                "success": False,
                "error": str(e),
            }
    
    def get_market_status(self, market_id: str) -> Dict[str, Any]:
        """
        Get the status of a market.
        
        Args:
            market_id: Market identifier
        
        Returns:
            Market status dictionary
        """
        if not self.oracle_address:
            raise ValueError("Oracle contract address not set")
        
        if self.client:
            return self._get_status_starknet_py(market_id)
        else:
            return self._get_status_starkli(market_id)
    
    def _get_status_starknet_py(self, market_id: str) -> Dict[str, Any]:
        """Get status using starknet.py."""
        try:
            from starknet_py.contract import Contract
            contract = Contract(
                address=self.oracle_address,
                abi=self._get_oracle_abi(),
                client=self.client
            )
            
            status = asyncio.run(
                contract.functions["getMarketStatus"].call(int(market_id))
            )
            
            return {
                "success": True,
                "status": str(status),
                "raw_value": status,
            }
        except Exception as e:
            return {
                "success": False,
                "error": str(e),
            }
    
    def _get_status_starkli(self, market_id: str) -> Dict[str, Any]:
        """Get status using starkli CLI."""
        try:
            output = self._call_starkli([
                "call",
                self.oracle_address,
                "getMarketStatus",
                str(int(market_id)),
            ])
            
            return {
                "success": True,
                "output": output,
            }
        except Exception as e:
            return {
                "success": False,
                "error": str(e),
            }
    
    def _get_oracle_abi(self) -> list:
        """Get OptimisticOracle ABI (simplified)."""
        return [
            {
                "name": "propose",
                "type": "function",
                "inputs": [
                    {"name": "market_id", "type": "felt"},
                    {"name": "outcome", "type": "felt"},
                    {"name": "data_hash", "type": "felt"},
                    {"name": "data_uri", "type": "felt"},
                ],
                "outputs": [],
            },
            {
                "name": "finalize",
                "type": "function",
                "inputs": [
                    {"name": "market_id", "type": "felt"},
                ],
                "outputs": [],
            },
            {
                "name": "getMarketStatus",
                "type": "function",
                "inputs": [
                    {"name": "market_id", "type": "felt"},
                ],
                "outputs": [
                    {"name": "status", "type": "felt"},
                ],
            },
        ]


# Convenience factory functions
def create_starknet_interface() -> StarknetInterface:
    """
    Create a StarknetInterface using environment variables.
    
    Returns:
        Initialized StarknetInterface
    """
    return StarknetInterface(
        network=os.getenv("STARKNET_NETWORK", "goerli"),
        account_address=os.getenv("STARKNET_ACCOUNT_ADDRESS"),
        private_key=os.getenv("STARKNET_PRIVATE_KEY"),
    )
