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
import time
import re
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
        self.starkli_account = os.getenv("STARKLI_ACCOUNT") or os.getenv("STARKNET_ACCOUNT_FILE")
        self.starkli_keystore = os.getenv("STARKLI_KEYSTORE") or os.getenv("STARKNET_KEYSTORE")
        self.starkli_password = os.getenv("STARKLI_PASSWORD") or os.getenv("STARKNET_KEYSTORE_PASSWORD")
        self.starkli_rpc = os.getenv("STARKNET_RPC") or os.getenv("STARKNET_RPC_URL")
        
        # Contract addresses (defaults - should be overridden)
        self.oracle_address = self._normalize_address(os.getenv("ORACLE_CONTRACT_ADDRESS"))
        self.calculator_address = self._normalize_address(os.getenv("CALCULATOR_CONTRACT_ADDRESS"))
        self.verifier_address = self._normalize_address(os.getenv("RESOLUTION_VERIFIER_ADDRESS"))
        self.data_commitment_address = self._normalize_address(os.getenv("DATA_COMMITMENT_ADDRESS"))
        
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
                    address=self._normalize_address(self.account_address),
                    key_pair=self.private_key,
                    chain=self._get_chain_id(),
                )
        except Exception as e:
            print(f"Warning: Failed to initialize starknet.py: {e}")
            self.client = None
            self.account = None
    
    def _get_node_url(self) -> str:
        """Get RPC node URL based on network."""
        env_url = os.getenv("STARKNET_RPC_URL")
        if env_url:
            return env_url
        urls = {
            "goerli": "https://goerli.gateway.fm",
            "mainnet": "https://starknet-mainnet.public.blastapi.io",
            "sepolia": "https://starknet-sepolia.public.blastapi.io/rpc/v0_8",
            "localhost": "http://127.0.0.1:5050",
        }
        return urls.get(self.network, urls["goerli"])

    def _starkli_rpc_args(self) -> list:
        """RPC args for starkli commands."""
        rpc = self.starkli_rpc
        if not rpc:
            rpc = self._get_node_url()
        return ["--rpc", rpc] if rpc else []

    def _starkli_tx_args(self) -> list:
        """Auth args for starkli state-changing commands."""
        args = []
        if self.starkli_account:
            args.extend(["--account", self.starkli_account])
        elif self.account_address:
            args.extend(["--account", self._addr_str(self.account_address)])
        if self.starkli_keystore:
            args.extend(["--keystore", self.starkli_keystore])
        if self.starkli_password:
            args.extend(["--keystore-password", self.starkli_password])
        args.extend(self._starkli_rpc_args())
        return args
    
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

            stdout = result.stdout.strip() if result.stdout else ""
            stderr = result.stderr.strip() if result.stderr else ""
            # Some starkli versions print tx hashes to stderr (with warnings).
            return stdout if stdout else stderr
        except FileNotFoundError:
            raise RuntimeError(
                f"starkli not found. Please install starkli or set starkli_path."
            )
        except subprocess.TimeoutExpired:
            raise RuntimeError("starkli command timed out")

    def _normalize_address(self, value: Optional[Union[str, int]]) -> Optional[int]:
        """Normalize an address value into an int."""
        if value is None:
            return None
        if isinstance(value, int):
            return value
        if isinstance(value, str):
            if value.startswith("0x"):
                return int(value, 16)
            if value.isdigit():
                return int(value)
        return None

    def _addr_str(self, value: Optional[Union[str, int]]) -> Optional[str]:
        """Format an address for CLI usage."""
        if value is None:
            return None
        if isinstance(value, int):
            return hex(value)
        return value

    def _parse_felt(self, value: Union[str, int]) -> int:
        """Parse a felt from int or hex/decimal string."""
        if isinstance(value, int):
            return value
        if isinstance(value, str):
            if value.startswith("0x"):
                return int(value, 16)
            if value.isdigit():
                return int(value)
            return int(value, 16)
        return int(value)

    def _parse_starkli_u256(self, output: str) -> int:
        """Parse a starkli u256 output into int (low, high)."""
        try:
            raw = json.loads(output)
        except json.JSONDecodeError:
            raw = output.strip()
        if isinstance(raw, list) and len(raw) >= 2:
            low = int(raw[0], 16) if isinstance(raw[0], str) else int(raw[0])
            high = int(raw[1], 16) if isinstance(raw[1], str) else int(raw[1])
            return low + (high << 128)
        if isinstance(raw, list) and len(raw) == 1:
            return int(raw[0], 16) if isinstance(raw[0], str) else int(raw[0])
        if isinstance(raw, str) and raw.startswith("0x"):
            return int(raw, 16)
        return int(raw)

    def _parse_starkli_felt(self, output: str) -> int:
        """Parse a starkli felt output into int."""
        try:
            raw = json.loads(output)
        except json.JSONDecodeError:
            raw = output.strip()
        if isinstance(raw, list) and len(raw) > 0:
            val = raw[0]
            return int(val, 16) if isinstance(val, str) else int(val)
        if isinstance(raw, str) and raw.startswith("0x"):
            return int(raw, 16)
        return int(raw)

    def _extract_tx_hash(self, output: str) -> Optional[str]:
        if not output:
            return None
        match = re.search(r"0x[0-9a-fA-F]+", output)
        if match:
            return match.group(0)
        return output.strip()

    def get_market_state(self, market_address: Union[str, int]) -> Dict[str, Any]:
        """
        Fetch market state from on-chain Market contract.
        Returns yes_supply, no_supply, b_param, price_yes, price_no.
        """
        addr = self._normalize_address(market_address)
        if addr is None:
            raise ValueError("Market address is required")
        if self.client:
            return self._get_market_state_starknet_py(addr)
        return self._get_market_state_starkli(addr)

    def _get_market_state_starknet_py(self, market_address: int) -> Dict[str, Any]:
        try:
            from starknet_py.contract import Contract
            contract = Contract(
                address=market_address,
                abi=self._get_market_abi(),
                client=self.client
            )
            yes_supply = asyncio.run(contract.functions["get_yes_supply"].call())
            no_supply = asyncio.run(contract.functions["get_no_supply"].call())
            b_param = asyncio.run(contract.functions["get_b_param"].call())
            price_yes = asyncio.run(contract.functions["get_yes_price"].call())
            price_no = asyncio.run(contract.functions["get_no_price"].call())
            return {
                "success": True,
                "yes_supply": int(yes_supply[0]) if isinstance(yes_supply, tuple) else int(yes_supply),
                "no_supply": int(no_supply[0]) if isinstance(no_supply, tuple) else int(no_supply),
                "b_param": int(b_param[0]) if isinstance(b_param, tuple) else int(b_param),
                "price_yes": int(price_yes[0]) if isinstance(price_yes, tuple) else int(price_yes),
                "price_no": int(price_no[0]) if isinstance(price_no, tuple) else int(price_no),
            }
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _get_market_state_starkli(self, market_address: int) -> Dict[str, Any]:
        try:
            yes_supply = self._call_starkli([
                "call", self._addr_str(market_address), "get_yes_supply"
            ] + self._starkli_rpc_args())
            no_supply = self._call_starkli([
                "call", self._addr_str(market_address), "get_no_supply"
            ] + self._starkli_rpc_args())
            b_param = self._call_starkli([
                "call", self._addr_str(market_address), "get_b_param"
            ] + self._starkli_rpc_args())
            price_yes = self._call_starkli([
                "call", self._addr_str(market_address), "get_yes_price"
            ] + self._starkli_rpc_args())
            price_no = self._call_starkli([
                "call", self._addr_str(market_address), "get_no_price"
            ] + self._starkli_rpc_args())
            return {
                "success": True,
                "yes_supply": self._parse_starkli_u256(yes_supply),
                "no_supply": self._parse_starkli_u256(no_supply),
                "b_param": self._parse_starkli_u256(b_param),
                "price_yes": self._parse_starkli_u256(price_yes),
                "price_no": self._parse_starkli_u256(price_no),
            }
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _market_id_to_felt(self, market_id: str) -> int:
        """Convert a market_id string into a felt252."""
        if isinstance(market_id, int):
            return market_id
        if isinstance(market_id, str) and market_id.startswith("0x"):
            return int(market_id, 16)
        if isinstance(market_id, str) and market_id.isdigit():
            return int(market_id)
        # Default: pack UTF-8 into felt (up to 31 bytes)
        return int.from_bytes(str(market_id).encode()[:31], "big")

    def _outcome_to_felt(self, outcome: str) -> int:
        """Map outcome string to felt."""
        if outcome in ("YES", "yes", "Yes", "1", 1):
            return 1
        if outcome in ("NO", "no", "No", "0", 0):
            return 0
        return int.from_bytes(str(outcome).encode()[:31], "big")

    def _to_u256(self, value: int) -> list:
        """Encode a Python int as u256 [low, high]."""
        low = value & ((1 << 128) - 1)
        high = value >> 128
        return [low, high]
    
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
        bond: int,
        proof: Optional[list] = None,
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
        
        if proof is not None:
            if self.account:
                return self._propose_with_proof_starknet_py(market_id, outcome, data_hash, bond, proof)
            return self._propose_with_proof_starkli(market_id, outcome, data_hash, bond, proof)

        if self.account:
            return self._propose_starknet_py(market_id, outcome, data_hash, data_uri, bond)
        return self._propose_starkli(market_id, outcome, data_hash, data_uri, bond)

    def set_commitment_signed(
        self,
        market_id: str,
        state_hash: int,
        sig_r: int,
        sig_s: int,
    ) -> Dict[str, Any]:
        if not self.data_commitment_address:
            raise ValueError("Data commitment contract address not set")
        if self.account:
            return self._set_commitment_signed_starknet_py(market_id, state_hash, sig_r, sig_s)
        return self._set_commitment_signed_starkli(market_id, state_hash, sig_r, sig_s)

    def _set_commitment_signed_starknet_py(
        self,
        market_id: str,
        state_hash: int,
        sig_r: int,
        sig_s: int,
    ) -> Dict[str, Any]:
        market_id_felt = self._market_id_to_felt(market_id)
        call = Call(
            to_addr=self.data_commitment_address,
            selector="set_commitment_signed",
            calldata=[
                market_id_felt,
                int(state_hash),
                int(sig_r),
                int(sig_s),
            ],
        )
        try:
            tx = asyncio.run(self.account.execute_v1(calls=[call], max_fee=int(1e16)))
            return {
                "success": True,
                "transaction_hash": hex(tx.transaction_hash),
                "status": "pending",
            }
        except Exception as e:
            return {
                "success": False,
                "error": str(e),
            }

    def _set_commitment_signed_starkli(
        self,
        market_id: str,
        state_hash: int,
        sig_r: int,
        sig_s: int,
    ) -> Dict[str, Any]:
        cmd = [
            "invoke",
            self._addr_str(self.data_commitment_address),
            "set_commitment_signed",
            str(self._market_id_to_felt(market_id)),
            str(int(state_hash)),
            str(int(sig_r)),
            str(int(sig_s)),
        ]
        cmd.extend(self._starkli_tx_args())
        try:
            output = self._call_starkli(cmd)
            tx_hash = self._extract_tx_hash(output)
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
    
    def _propose_starknet_py(
        self,
        market_id: str,
        outcome: str,
        data_hash: str,
        data_uri: str,
        bond: int,
    ) -> Dict[str, Any]:
        """Propose using starknet.py."""
        market_id_felt = self._market_id_to_felt(market_id)
        outcome_felt = self._outcome_to_felt(outcome)
        data_hash_felt = self._parse_felt(data_hash)
        uri_hash = int.from_bytes(data_uri.encode()[:31], 'big')
        bond_u256 = self._to_u256(bond)

        call = Call(
            to_addr=self.oracle_address,
            selector="propose",
            calldata=[
                market_id_felt,
                outcome_felt,
                data_hash_felt,
                uri_hash,
                bond_u256[0],
                bond_u256[1],
            ],
        )

        try:
            tx = asyncio.run(self.account.execute_v1(calls=[call], max_fee=int(1e16)))
            return {
                "success": True,
                "transaction_hash": hex(tx.transaction_hash),
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
        bond: int,
    ) -> Dict[str, Any]:
        """Propose using starkli CLI."""
        outcome_felt = self._outcome_to_felt(outcome)
        data_hash_felt = self._parse_felt(data_hash)
        uri_hash = int.from_bytes(data_uri.encode()[:31], 'big')
        bond_u256 = self._to_u256(bond)
        
        # Build command
        # This assumes the oracle contract has a propose function with signature:
        # propose(market_id: felt, outcome: felt, data_hash: felt, data_uri: felt, bond: u256)
        cmd = [
            "invoke",
            self._addr_str(self.oracle_address),
            "propose",
            str(self._market_id_to_felt(market_id)),
            str(outcome_felt),
            str(data_hash_felt),
            str(uri_hash),
            str(bond_u256[0]),
            str(bond_u256[1]),
        ]
        cmd.extend(self._starkli_tx_args())
        
        try:
            output = self._call_starkli(cmd)
            tx_hash = self._extract_tx_hash(output)
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

    def _propose_with_proof_starknet_py(
        self,
        market_id: str,
        outcome: str,
        data_hash: str,
        bond: int,
        proof: list,
    ) -> Dict[str, Any]:
        """Propose with proof using starknet.py."""
        market_id_felt = self._market_id_to_felt(market_id)
        outcome_felt = self._outcome_to_felt(outcome)
        data_hash_felt = self._parse_felt(data_hash)
        bond_u256 = self._to_u256(bond)
        proof_calldata = [int(p) for p in proof]

        call = Call(
            to_addr=self.oracle_address,
            selector="propose_with_proof",
            calldata=[
                market_id_felt,
                outcome_felt,
                data_hash_felt,
                bond_u256[0],
                bond_u256[1],
                *proof_calldata,
            ],
        )

        try:
            tx = asyncio.run(self.account.execute_v1(calls=[call], max_fee=int(1e16)))
            return {
                "success": True,
                "transaction_hash": hex(tx.transaction_hash),
                "status": "pending",
            }
        except Exception as e:
            return {
                "success": False,
                "error": str(e),
            }

    def _propose_with_proof_starkli(
        self,
        market_id: str,
        outcome: str,
        data_hash: str,
        bond: int,
        proof: list,
    ) -> Dict[str, Any]:
        """Propose with proof using starkli CLI."""
        market_id_felt = self._market_id_to_felt(market_id)
        outcome_felt = self._outcome_to_felt(outcome)
        data_hash_felt = self._parse_felt(data_hash)
        bond_u256 = self._to_u256(bond)
        proof_args = [str(int(p)) for p in proof]

        cmd = [
            "invoke",
            self._addr_str(self.oracle_address),
            "propose_with_proof",
            str(market_id_felt),
            str(outcome_felt),
            str(data_hash_felt),
            str(bond_u256[0]),
            str(bond_u256[1]),
            *proof_args,
        ]
        cmd.extend(self._starkli_tx_args())

        try:
            output = self._call_starkli(cmd)
            tx_hash = self._extract_tx_hash(output)
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
            calldata=[self._market_id_to_felt(market_id)],
        )
        
        try:
            tx = asyncio.run(self.account.execute_v1(calls=[call], max_fee=int(1e16)))
            return {
                "success": True,
                "transaction_hash": hex(tx.transaction_hash),
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
            self._addr_str(self.oracle_address),
            "finalize",
            str(self._market_id_to_felt(market_id)),
        ]
        cmd.extend(self._starkli_tx_args())
        
        try:
            output = self._call_starkli(cmd)
            tx_hash = self._extract_tx_hash(output)
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

    def wait_for_tx(self, tx_hash: Optional[str], timeout: int = 120, poll: int = 5) -> Dict[str, Any]:
        """Wait for a transaction to reach finality using starkli receipt."""
        if not tx_hash:
            return {"success": False, "error": "Missing tx hash"}
        start = time.time()
        last_error = None
        while time.time() - start < timeout:
            try:
                output = self._call_starkli(["receipt", tx_hash] + self._starkli_rpc_args())
                try:
                    data = json.loads(output)
                except json.JSONDecodeError:
                    data = {"raw": output}
                exec_status = data.get("execution_status") or data.get("status")
                finality = data.get("finality_status")
                if exec_status in ("REVERTED", "REJECTED"):
                    return {"success": False, "error": exec_status, "receipt": data}
                if finality in ("ACCEPTED_ON_L2", "ACCEPTED_ON_L1"):
                    return {"success": True, "receipt": data}
                if exec_status == "SUCCEEDED":
                    return {"success": True, "receipt": data}
            except Exception as e:
                last_error = str(e)
            time.sleep(poll)
        return {"success": False, "error": f"Timeout waiting for {tx_hash}. {last_error or ''}".strip()}
    
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

    def get_commitment(self, market_id: str) -> Optional[int]:
        """Get committed data hash from DataCommitment."""
        if not self.data_commitment_address:
            return None
        try:
            output = self._call_starkli([
                "call",
                self._addr_str(self.data_commitment_address),
                "get_commitment",
                str(self._market_id_to_felt(market_id)),
            ] + self._starkli_rpc_args())
            return self._parse_starkli_felt(output)
        except Exception:
            return None
    
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
                contract.functions["get_market_status"].call(self._market_id_to_felt(market_id))
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

    def requires_proof(self, market_id: str) -> bool:
        """Check if a market requires proof via the ResolutionVerifier."""
        if not self.verifier_address:
            return False
        if not self.client:
            return False
        try:
            from starknet_py.contract import Contract
            contract = Contract(
                address=self.verifier_address,
                abi=self._get_verifier_abi(),
                client=self.client
            )
            result = asyncio.run(
                contract.functions["requires_proof"].call(self._market_id_to_felt(market_id))
            )
            # starknet_py returns named tuple or int
            if isinstance(result, dict):
                return bool(result.get("value", False))
            if hasattr(result, "value"):
                return bool(result.value)
            return bool(result)
        except Exception:
            return False
    
    def _get_status_starkli(self, market_id: str) -> Dict[str, Any]:
        """Get status using starkli CLI."""
        try:
            output = self._call_starkli([
                "call",
                self._addr_str(self.oracle_address),
                "get_market_status",
                str(self._market_id_to_felt(market_id)),
            ] + self._starkli_rpc_args())
            
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
                    {"name": "bond", "type": "u256"},
                ],
                "outputs": [],
            },
            {
                "name": "propose_with_proof",
                "type": "function",
                "inputs": [
                    {"name": "market_id", "type": "felt"},
                    {"name": "outcome", "type": "felt"},
                    {"name": "data_hash", "type": "felt"},
                    {"name": "bond", "type": "u256"},
                    {"name": "zk_proof", "type": "felt*"},
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
                "name": "fast_finalize",
                "type": "function",
                "inputs": [
                    {"name": "market_id", "type": "felt"},
                ],
                "outputs": [],
            },
            {
                "name": "get_market_status",
                "type": "function",
                "inputs": [
                    {"name": "market_id", "type": "felt"},
                ],
                "outputs": [
                    {"name": "status", "type": "felt"},
                ],
            },
            {
                "name": "get_final_outcome",
                "type": "function",
                "inputs": [
                    {"name": "market_id", "type": "felt"},
                ],
                "outputs": [
                    {"name": "outcome", "type": "felt"},
                ],
            },
        ]

    def _get_market_abi(self) -> list:
        """Get Market ABI (simplified)."""
        return [
            {
                "name": "get_yes_supply",
                "type": "function",
                "inputs": [],
                "outputs": [{"name": "value", "type": "u256"}],
            },
            {
                "name": "get_no_supply",
                "type": "function",
                "inputs": [],
                "outputs": [{"name": "value", "type": "u256"}],
            },
            {
                "name": "get_b_param",
                "type": "function",
                "inputs": [],
                "outputs": [{"name": "value", "type": "u256"}],
            },
            {
                "name": "get_yes_price",
                "type": "function",
                "inputs": [],
                "outputs": [{"name": "value", "type": "u256"}],
            },
            {
                "name": "get_no_price",
                "type": "function",
                "inputs": [],
                "outputs": [{"name": "value", "type": "u256"}],
            },
        ]

    def _get_verifier_abi(self) -> list:
        """Get ResolutionVerifier ABI (simplified)."""
        return [
            {
                "name": "requires_proof",
                "type": "function",
                "inputs": [
                    {"name": "market_id", "type": "felt"},
                ],
                "outputs": [
                    {"name": "value", "type": "bool"},
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
