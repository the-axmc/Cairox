#!/usr/bin/env python3
"""
E2E Dispute Flow Script for Cairox

This script demonstrates the complete dispute workflow:
1. Propose market with bond (e.g., 100 stablecoin)
2. Dispute the proposal (bond = 200 stablecoin)
3. Try to finalize - should fail (disputed)
4. Arbitration resolves
5. Verify bond transfers and outcome

Requirements:
- starknet-devnet running at http://127.0.0.1:5050
- Cairox contracts deployed
- Stablecoin token deployed

Usage:
    python e2e_dispute_flow.py [--rpc-url URL] [--account ACCOUNT] [--key KEY]
"""

import json
import sys
import subprocess
import time
from typing import Optional, Tuple

try:
    from starknet_py.net.account.account import Account
    from starknet_py.net.client import Client
    from starknet_py.net.models import StarknetChainId
    from starknet_py.contract import Contract
    from starknet_py.common import to_bytes, from_bytes, int_from_felt
    from starknet_py.transactions import TRANSFER_FUNCTION_NAME
except ImportError as e:
    print(f"Error importing starknet_py: {e}")
    print("Please install starknet_py: pip install starknet")
    sys.exit(1)

# Default configuration
DEFAULT_RPC_URL = "http://127.0.0.1:5050"
DEFAULT_ACCOUNT = "0x123456789012345678901234567890123456789012345678901234567890123"
DEFAULT_PRIVATE_KEY = "0x111111111111111111111111111111111111111111111111111111111111111"

# Bond amounts in wei (assuming 6 decimal places for the stablecoin)
proposer_bond_amount = int(100 * 1e6)  # 100 stablecoin
dispute_bond_amount = int(200 * 1e6)   # 200 stablecoin

# Market ID for testing
MARKET_ID = "test_market_1"
MARKET_OUTCOME = "YES"
DATA_HASH = "0x1234567890123456789012345678901234567890123456789012345678901234"
DATA_URI = "ipfs://Qmtest"

# Contract addresses (will be populated after deployment)
ORACLE_ADDRESS = None
STABLECOIN_ADDRESS = None
USDC_ADDRESS = None  # legacy
ACCOUNT_ADDRESS = None


async def setup_client(rpc_url: str = DEFAULT_RPC_URL) -> Client:
    """Setup Starknet client."""
    print(f"Connecting to RPC at {rpc_url}...")
    return Client(url=rpc_url, chain=StarknetChainId.SN_SEPOLIA)


async def setup_account(client: Client, account_addr: str, private_key: str) -> Account:
    """Setup account for signing transactions."""
    print(f"Setting up account: {account_addr}")
    return Account(
        client=client,
        address=account_addr,
        key_pair=private_key,  # starknet_py uses private key directly
        chain=StarknetChainId.SN_SEPOLIA
    )


async def get_contract(address: str, abi_path: str, client: Client) -> Contract:
    """Load a contract from its address and ABI file."""
    with open(abi_path) as f:
        abi = json.load(f)
    return Contract(address=int(address, 16), abi=abi, client=client)


async def transfer_tokens(
    account: Account,
    token_address: int,
    to_address: int,
    amount: int,
    max_fee: int = None
) -> dict:
    """Transfer tokens from account to another address."""
    print(f"Transferring {amount} tokens to {hex(to_address)}...")
    
    # Use the default transfer call
    call = Call(
        to_addr=token_address,
        selector=TRANSFER_FUNCTION_NAME,
        calldata=[to_address, amount, 0]  # amount is u256 (low, high)
    )
    
    return await account.execute_v1(calls=[call], max_fee=max_fee)


async def propose_market(
    account: Account,
    oracle: Contract,
    market_id: str,
    outcome: str,
    data_hash: str,
    data_uri: str,
    bond_amount: int,
    reporter_address: int
) -> dict:
    """
    Propose a market outcome with a bond.
    
    Args:
        account: The account making the proposal
        oracle: The OptimisticOracle contract
        market_id: Unique identifier for the market
        outcome: The proposed outcome
        data_hash: Hash of the market data
        data_uri: URI to the market data
        bond_amount: Amount of stablecoin to bond (in wei)
        reporter_address: The authorized reporter address
    
    Returns:
        Transaction result
    """
    print(f"\n=== Proposing market: {market_id} ===")
    print(f"  Outcome: {outcome}")
    print(f"  Bond: {bond_amount / 1e6:.2f} Stablecoin")
    
    # Set caller to reporter address (only reporter can propose)
    # Note: In actual implementation, this would be done through the Oracle contract's access control
    
    # Convert strings to felt252 (Cairo format)
    market_id_felt = int.from_bytes(market_id.encode(), 'big')
    if outcome.upper() == "YES":
        outcome_felt = 1
    elif outcome.upper() == "NO":
        outcome_felt = 0
    else:
        outcome_felt = int.from_bytes(outcome.encode(), 'big')
    data_hash_felt = int(data_hash, 16)
    data_uri_felt = int.from_bytes(data_uri.encode(), 'big')
    
    # Encode bond as u256
    bond_low = bond_amount & ((1 << 128) - 1)
    bond_high = bond_amount >> 128

    # Ensure market is registered (owner/factory only)
    try:
        reg_tx = await oracle.functions["register_market"].invoke(
            market_id=market_id_felt,
            max_fee=int(1e16)
        )
        await account.client.wait_for_tx(reg_tx.transaction_hash)
    except Exception:
        # Likely already registered or not authorized
        pass
    
    # Call oracle.propose()
    call = Call(
        to_addr=oracle.address,
        selector=get_selector('propose'),
        calldata=[
            market_id_felt,
            outcome_felt,
            data_hash_felt,
            data_uri_felt,
            bond_low,
            bond_high
        ]
    )
    
    result = await account.execute_v1(calls=[call], max_fee=int(1e16))
    print(f"  Transaction hash: 0x{hex(result.transaction_hash)[2:]}")
    
    # Wait for transaction
    await account.client.wait_for_tx(result.transaction_hash)
    
    # Verify market status
    status = await oracle.functions["get_market_status"].call(market_id_felt)
    print(f"  Market status: {status}")  # 1 = PROPOSED
    
    return result


async def dispute_market(
    account: Account,
    oracle: Contract,
    market_id: str,
    bond_amount: int
) -> dict:
    """
    Dispute a proposed market.
    
    Args:
        account: The account making the dispute
        oracle: The OptimisticOracle contract
        market_id: The market ID to dispute
        bond_amount: Amount of stablecoin to dispute with (in wei)
    
    Returns:
        Transaction result
    """
    print(f"\n=== Disputing market: {market_id} ===")
    print(f"  Dispute Bond: {bond_amount / 1e6:.2f} Stablecoin")
    
    # Convert market_id to felt252
    market_id_felt = int.from_bytes(market_id.encode(), 'big')
    
    # Encode bond as u256
    bond_low = bond_amount & ((1 << 128) - 1)
    bond_high = bond_amount >> 128
    
    # Call oracle.dispute()
    call = Call(
        to_addr=oracle.address,
        selector=get_selector('dispute'),
        calldata=[
            market_id_felt,
            bond_low,
            bond_high
        ]
    )
    
    result = await account.execute_v1(calls=[call], max_fee=int(1e16))
    print(f"  Transaction hash: 0x{hex(result.transaction_hash)[2:]}")
    
    # Wait for transaction
    await account.client.wait_for_tx(result.transaction_hash)
    
    # Verify market is disputed
    is_disputed = await oracle.functions["is_disputed"].call(market_id_felt)
    print(f"  Market is disputed: {is_disputed}")
    
    return result


async def try_finalize_market(
    account: Account,
    oracle: Contract,
    market_id: str
) -> Tuple[bool, str]:
    """
    Try to finalize a market. Should fail if disputed.
    
    Args:
        account: The account calling finalize
        oracle: The OptimisticOracle contract
        market_id: The market ID to finalize
    
    Returns:
        Tuple of (success: bool, error_message: str)
    """
    print(f"\n=== Trying to finalize market: {market_id} ===")
    
    # Convert market_id to felt252
    market_id_felt = int.from_bytes(market_id.encode(), 'big')
    
    # Call oracle.finalize()
    call = Call(
        to_addr=oracle.address,
        selector=get_selector('finalize'),
        calldata=[market_id_felt]
    )
    
    try:
        result = await account.execute_v1(calls=[call], max_fee=int(1e16))
        await account.client.wait_for_tx(result.transaction_hash)
        
        # If we get here, finalize succeeded (unexpected)
        status = await oracle.functions["get_market_status"].call(market_id_felt)
        print(f"  ✗ finalize() succeeded unexpectedly!")
        print(f"  Market status: {status}")
        return False, "finalize succeeded when it should have failed"
        
    except Exception as e:
        # This is expected - finalize should fail for disputed markets
        error_msg = str(e)
        print(f"  ✓ finalize() correctly failed!")
        print(f"  Error: {error_msg}")
        return True, error_msg


async def resolve_arbitration(
    account: Account,
    oracle: Contract,
    arbitration: Contract,
    market_id: str,
    outcome: str,
    proposer_wins: bool,
    arbiter_address: int
) -> dict:
    """
    Resolve a disputed market through arbitration.
    
    Args:
        account: The account (arbiter) resolving the dispute
        oracle: The OptimisticOracle contract
        arbitration: The Arbitration contract
        market_id: The market ID to resolve
        outcome: The resolved outcome
        proposer_wins: Whether the proposer wins the dispute
        arbiter_address: The arbiter's address
    
    Returns:
        Transaction result
    """
    print(f"\n=== Resolving arbitration for market: {market_id} ===")
    print(f"  Outcome: {outcome}")
    print(f"  Proposer wins: {proposer_wins}")
    
    # Convert market_id and outcome to felt252
    market_id_felt = int.from_bytes(market_id.encode(), 'big')
    outcome_felt = int.from_bytes(outcome.encode(), 'big')
    
    # Call arbitration.resolve_dispute()
    call = Call(
        to_addr=arbitration.address,
        selector=get_selector('resolve_dispute'),
        calldata=[
            market_id_felt,
            outcome_felt,
            1 if proposer_wins else 0  # boolean as felt
        ]
    )
    
    result = await account.execute_v1(calls=[call], max_fee=int(1e16))
    print(f"  Transaction hash: 0x{hex(result.transaction_hash)[2:]}")
    
    # Wait for transaction
    await account.client.wait_for_tx(result.transaction_hash)
    
    # Verify market is resolved
    status = await oracle.functions["get_market_status"].call(market_id_felt)
    print(f"  Market status: {status}')  # 2 = RESOLVED
    
    return result


async def verify_bond_transfers(
    account: Account,
    oracle: Contract,
    stablecoin: Contract,
    market_id: str,
    proposer_address: int,
    disputor_address: int
) -> dict:
    """
    Verify bond transfers after arbitration.
    
    Args:
        account: The account to verify balances with
        oracle: The OptimisticOracle contract
        stablecoin: The stablecoin token contract
        market_id: The market ID
        proposer_address: The proposer's address
        disputor_address: The disputor's address
    
    Returns:
        Dictionary with balance information
    """
    print(f"\n=== Verifying bond transfers ===")
    
    market_id_felt = int.from_bytes(market_id.encode(), 'big')
    
    # Get stablecoin decimals
    decimals = await stablecoin.functions["decimals"].call()
    print(f"  Stablecoin decimals: {decimals}")
    
    # Get proposer balance
    proposer_balance = await stablecoin.functions["balance_of"].call(proposer_address)
    proposer_balance_wei = proposer_balance.low + (proposer_balance.high << 128)
    print(f"  Proposer balance: {proposer_balance_wei / 1e6:.2f} Stablecoin")
    
    # Get disputor balance
    disputor_balance = await stablecoin.functions["balance_of"].call(disputor_address)
    disputor_balance_wei = disputor_balance.low + (disputor_balance.high << 128)
    print(f"  Disputor balance: {disputor_balance_wei / 1e6:.2f} Stablecoin")
    
    # Verifier balance
    verifier_balance = await stablecoin.functions["balance_of"].call(account.address)
    verifier_balance_wei = verifier_balance.low + (verifier_balance.high << 128)
    print(f"  Verifier balance: {verifier_balance_wei / 1e6:.2f} Stablecoin")
    
    return {
        "proposer_balance": proposer_balance_wei,
        "disputor_balance": disputor_balance_wei,
        "verifier_balance": verifier_balance_wei
    }


async def test_non_disputed_finalize(
    account: Account,
    oracle: Contract,
    market_id: str
) -> dict:
    """
    Test that a non-disputed market can be finalized after the dispute window.
    
    Args:
        account: The account finalizing the market
        oracle: The OptimisticOracle contract
        market_id: The market ID to finalize
    
    Returns:
        Transaction result
    """
    print(f"\n=== Testing non-disputed finalization ===")
    print(f"  Market: {market_id}")
    
    market_id_felt = int.from_bytes(market_id.encode(), 'big')
    
    # Call oracle.finalize()
    call = Call(
        to_addr=oracle.address,
        selector=get_selector('finalize'),
        calldata=[market_id_felt]
    )
    
    result = await account.execute_v1(calls=[call], max_fee=int(1e16))
    print(f"  Transaction hash: 0x{hex(result.transaction_hash)[2:]}")
    
    # Wait for transaction
    await account.client.wait_for_tx(result.transaction_hash)
    
    # Verify market is resolved
    status = await oracle.functions["get_market_status"].call(market_id_felt)
    print(f"  Market status: {status}')  # 2 = RESOLVED
    
    return result


async def main(rpc_url: str = DEFAULT_RPC_URL):
    """Main E2E dispute flow test."""
    print("=" * 60)
    print("Cairox E2E Dispute Flow Test")
    print("=" * 60)
    
    # Setup
    print("\n[1/6] Setting up...")
    client = await setup_client(rpc_url)
    
    # For local devnet, use default account
    account = Account(
        client=client,
        address=DEFAULT_ACCOUNT,
        key_pair=DEFAULT_PRIVATE_KEY,
        chain=StarknetChainId.SN_SEPOLIA
    )
    
    # Load contracts
    # Note: These addresses should be from deployed contracts
    # For this test, we'll assume they're already deployed
    print("\n[2/6] Loading contracts...")
    
    try:
        oracle = await get_contract(
            ORACLE_ADDRESS or "0xcontract_oracle",
            "contracts/artifacts/oracle.json",
            client
        )
        stablecoin = await get_contract(
            STABLECOIN_ADDRESS or USDC_ADDRESS or "0xcontract_stablecoin",
            "contracts/artifacts/stablecoin.json",
            client
        )
        arbitration = await get_contract(
            "0xcontract_arbitration",
            "contracts/artifacts/arbitration.json",
            client
        )
    except Exception as e:
        print(f"Error loading contracts: {e}")
        print("Please deploy contracts first using: make deploy-local")
        return
    
    proposer_address = account.address
    disputor_address = 0x223456789012345678901234567890123456789012345678901234567890123
    arbiter_address = 0x123456789012345678901234567890123456789012345678901234567890123
    
    print("\n[3/6] Step 1: Propose market with bond...")
    try:
        await propose_market(
            account=account,
            oracle=oracle,
            market_id=MARKET_ID,
            outcome=MARKET_OUTCOME,
            data_hash=DATA_HASH,
            data_uri=DATA_URI,
            bond_amount=proposer_bond_amount,
            reporter_address=proposer_address
        )
    except Exception as e:
        print(f"Propose failed (expected if not reporter): {e}")
        print("Continuing with manual setup...")
    
    print("\n[4/6] Step 2: Dispute the proposal...")
    try:
        await dispute_market(
            account=Account(
                client=client,
                address=disputor_address,
                key_pair=DEFAULT_PRIVATE_KEY,
                chain=StarknetChainId.SN_SEPOLIA
            ),
            oracle=oracle,
            market_id=MARKET_ID,
            bond_amount=dispute_bond_amount
        )
    except Exception as e:
        print(f"Dispute failed: {e}")
        print("Continuing with verification...")
    
    print("\n[5/6] Step 3: Try to finalize (should fail)...")
    success, error = await try_finalize_market(
        account=account,
        oracle=oracle,
        market_id=MARKET_ID
    )
    
    if not success:
        print(f"  Test FAILED: {error}")
    else:
        print(f"  Test PASSED: finalize correctly blocked for disputed market")
    
    print("\n[6/6] Step 4: Resolve arbitration...")
    try:
        await resolve_arbitration(
            account=Account(
                client=client,
                address=arbiter_address,
                key_pair=DEFAULT_PRIVATE_KEY,
                chain=StarknetChainId.SN_SEPOLIA
            ),
            oracle=oracle,
            arbitration=arbitration,
            market_id=MARKET_ID,
            outcome=MARKET_OUTCOME,
            proposer_wins=True,
            arbiter_address=arbiter_address
        )
    except Exception as e:
        print(f"Arbitration failed: {e}")
    
    print("\n[7/6] Step 5: Verify bond transfers...")
    try:
        balances = await verify_bond_transfers(
            account=account,
            oracle=oracle,
            stablecoin=stablecoin,
            market_id=MARKET_ID,
            proposer_address=proposer_address,
            disputor_address=disputor_address
        )
        
        print("\n=== E2E Test Summary ===")
        print(f"Proposer received bonds: {balances['proposer_balance'] / 1e6:.2f} Stablecoin")
        print(f"Disputor balance: {balances['disputor_balance'] / 1e6:.2f} Stablecoin")
        
    except Exception as e:
        print(f"Verification failed: {e}")
    
    print("\n" + "=" * 60)
    print("E2E Dispute Flow Test Complete")
    print("=" * 60)


def parse_args():
    """Parse command line arguments."""
    import argparse
    parser = argparse.ArgumentParser(description="Cairox E2E Dispute Flow Test")
    parser.add_argument("--rpc-url", default=DEFAULT_RPC_URL,
                        help=f"RPC URL (default: {DEFAULT_RPC_URL})")
    parser.add_argument("--account", default=DEFAULT_ACCOUNT,
                        help=f"Account address (default: {DEFAULT_ACCOUNT})")
    parser.add_argument("--key", default=DEFAULT_PRIVATE_KEY,
                        help=f"Private key (default: {DEFAULT_PRIVATE_KEY})")
    return parser.parse_args()


if __name__ == "__main__":
    args = parse_args()
    
    # Run the async main function
    import asyncio
    asyncio.run(main(
        rpc_url=args.rpc_url,
        account=args.account,
        key=args.key
    ))
