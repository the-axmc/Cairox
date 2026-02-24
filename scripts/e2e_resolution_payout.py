#!/usr/bin/env python3
"""
E2E Resolution + Payout Test

Flow:
1. Create market via MarketFactory
2. Mint/approve stablecoin
3. Buy YES tokens
4. Propose outcome on OptimisticOracle
5. Finalize + resolve_from_oracle
6. Redeem winnings
"""

import argparse
import os
import sys
from typing import Dict, List

try:
    from starknet_py.contract import Contract
    from starknet_py.net.account.account import Account
    from starknet_py.net.full_node_client import FullNodeClient
    from starknet_py.net.models import StarknetChainId
    from starknet_py.utils.crypto.facade import pedersen_hash
    from starknet_py.cairo.felt import encode_felt
    from starknet_py.devnet.helpers import wait_for_tx
except ImportError as e:
    print(f"Error: starknet_py not found: {e}")
    print("Install with: pip install starknet-py")
    sys.exit(1)


def u256_to_int(value) -> int:
    if isinstance(value, dict):
        return int(value.get("low", 0)) + (int(value.get("high", 0)) << 128)
    if hasattr(value, "low"):
        return int(value.low) + (int(value.high) << 128)
    if isinstance(value, (list, tuple)) and len(value) == 2:
        return int(value[0]) + (int(value[1]) << 128)
    return int(value)


def to_u256(value: int) -> Dict:
    return {"low": value & ((1 << 128) - 1), "high": value >> 128}


def get_factory_abi() -> List[Dict]:
    return [
        {"name": "create_market", "inputs": [
            {"name": "question", "type": "felt"},
            {"name": "initial_subsidy", "type": "u256"},
        ], "type": "function", "outputs": [{"name": "market_id", "type": "u256"}]},
        {"name": "get_market_count", "inputs": [], "type": "function", "outputs": [{"name": "count", "type": "u256"}]},
        {"name": "get_market", "inputs": [{"name": "market_id", "type": "u256"}], "type": "function", "outputs": [{"name": "market_address", "type": "felt"}]},
    ]


def get_oracle_abi() -> List[Dict]:
    return [
        {"name": "set_market_factory", "inputs": [{"name": "market_factory", "type": "felt"}], "type": "function"},
        {"name": "propose", "inputs": [
            {"name": "market_id", "type": "felt"},
            {"name": "outcome", "type": "felt"},
            {"name": "data_hash", "type": "felt"},
            {"name": "data_uri", "type": "felt"},
            {"name": "bond", "type": "u256"},
        ], "type": "function"},
        {"name": "finalize", "inputs": [{"name": "market_id", "type": "felt"}], "type": "function"},
        {"name": "set_dispute_window", "inputs": [{"name": "window", "type": "u256"}], "type": "function"},
        {"name": "get_market_status", "inputs": [{"name": "market_id", "type": "felt"}], "type": "function", "outputs": [{"name": "status", "type": "felt"}]},
    ]


def get_market_abi() -> List[Dict]:
    return [
        {"name": "buy", "inputs": [
            {"name": "outcome", "type": "felt"},
            {"name": "collateral_amount", "type": "u256"},
            {"name": "min_tokens", "type": "u256"},
        ], "type": "function", "outputs": [{"name": "tokens_out", "type": "u256"}]},
        {"name": "resolve_from_oracle", "inputs": [], "type": "function"},
        {"name": "redeem", "inputs": [], "type": "function", "outputs": [{"name": "winnings", "type": "u256"}]},
    ]


def get_stablecoin_abi() -> List[Dict]:
    return [
        {"name": "mint", "inputs": [{"name": "to", "type": "felt"}, {"name": "amount", "type": "u256"}], "type": "function"},
        {"name": "approve", "inputs": [{"name": "spender", "type": "felt"}, {"name": "amount", "type": "u256"}], "type": "function", "outputs": [{"name": "ok", "type": "bool"}]},
        {"name": "balance_of", "inputs": [{"name": "account", "type": "felt"}], "type": "function", "outputs": [{"name": "balance", "type": "u256"}]},
    ]


def parse_args():
    parser = argparse.ArgumentParser(description="E2E resolution + payout test")
    parser.add_argument("--rpc-url", default=os.getenv("STARKNET_RPC_URL", "http://127.0.0.1:5050"))
    parser.add_argument("--account", default=os.getenv("STARKNET_ACCOUNT_ADDRESS", "0x0"))
    parser.add_argument("--private-key", default=os.getenv("STARKNET_PRIVATE_KEY", "0x0"))
    parser.add_argument("--oracle", default=os.getenv("ORACLE_CONTRACT_ADDRESS", "0x0"))
    parser.add_argument("--factory", default=os.getenv("MARKET_FACTORY_ADDRESS", "0x0"))
    parser.add_argument("--stablecoin", default=os.getenv("STABLECOIN_TOKEN_ADDRESS", "0x0"))
    parser.add_argument("--bond", type=int, default=int(os.getenv("ORACLE_PROPOSER_BOND", "100")))
    parser.add_argument("--collateral", type=int, default=1_000_000)  # 1.0 with 6 decimals
    parser.add_argument("--initial-subsidy", type=int, default=int(os.getenv("INITIAL_SUBSIDY", "1000000")))
    return parser.parse_args()


async def main():
    args = parse_args()
    if args.account == "0x0" or args.private_key == "0x0":
        print("Missing STARKNET_ACCOUNT_ADDRESS or STARKNET_PRIVATE_KEY")
        return 1

    client = FullNodeClient(node_url=args.rpc_url)
    account = Account(
        client=client,
        address=int(args.account, 16),
        key_pair=args.private_key,
        chain=StarknetChainId.SN_SEPOLIA,
    )

    oracle = Contract(address=int(args.oracle, 16), abi=get_oracle_abi(), provider=account)
    factory = Contract(address=int(args.factory, 16), abi=get_factory_abi(), provider=account)
    stablecoin = Contract(address=int(args.stablecoin, 16), abi=get_stablecoin_abi(), provider=account)

    # Ensure oracle recognizes factory
    try:
        set_tx = await oracle.functions["set_market_factory"].invoke(
            market_factory=int(args.factory, 16),
            max_fee=int(1e16)
        )
        await wait_for_tx(client, set_tx.transaction_hash)
    except Exception as e:
        print(f"set_market_factory skipped/failed (owner-only): {e}")

    # Create market
    count_before = await factory.functions["get_market_count"].call()
    market_id = u256_to_int(count_before)
    question = encode_felt("E2E market")

    # Mint + approve subsidy
    try:
        mint_tx = await stablecoin.functions["mint"].invoke(
            to=account.address,
            amount=to_u256(args.initial_subsidy + args.collateral),
            max_fee=int(1e16)
        )
        await wait_for_tx(client, mint_tx.transaction_hash)
    except Exception as e:
        print(f"Mint skipped/failed (owner-only): {e}")

    subsidy_approve_tx = await stablecoin.functions["approve"].invoke(
        spender=int(args.factory, 16),
        amount=to_u256(args.initial_subsidy),
        max_fee=int(1e16)
    )
    await wait_for_tx(client, subsidy_approve_tx.transaction_hash)

    tx = await factory.functions["create_market"].invoke(
        question=question,
        initial_subsidy=to_u256(args.initial_subsidy),
        max_fee=int(1e17)
    )
    await wait_for_tx(client, tx.transaction_hash)

    market_addr_raw = await factory.functions["get_market"].call(market_id=to_u256(market_id))
    if isinstance(market_addr_raw, dict):
        market_addr = market_addr_raw.get("market_address", market_addr_raw)
    elif hasattr(market_addr_raw, "market_address"):
        market_addr = market_addr_raw.market_address
    else:
        market_addr = market_addr_raw
    market = Contract(address=int(market_addr), abi=get_market_abi(), provider=account)

    # Approve collateral for trading
    approve_tx = await stablecoin.functions["approve"].invoke(
        spender=int(market_addr),
        amount=to_u256(args.collateral),
        max_fee=int(1e16)
    )
    await wait_for_tx(client, approve_tx.transaction_hash)

    # Buy YES
    buy_tx = await market.functions["buy"].invoke(outcome=1, collateral_amount=to_u256(args.collateral), min_tokens=to_u256(0), max_fee=int(1e16))
    await wait_for_tx(client, buy_tx.transaction_hash)

    # Propose + finalize
    data_hash = pedersen_hash(encode_felt(b"e2e"), encode_felt(b"data"))
    data_uri = encode_felt("local://e2e")
    propose_tx = await oracle.functions["propose"].invoke(
        market_id=market_id,
        outcome=1,
        data_hash=data_hash,
        data_uri=data_uri,
        bond=to_u256(args.bond),
        max_fee=int(1e16)
    )
    await wait_for_tx(client, propose_tx.transaction_hash)

    # Skip dispute window for test
    try:
        window_tx = await oracle.functions["set_dispute_window"].invoke(window=to_u256(0), max_fee=int(1e16))
        await wait_for_tx(client, window_tx.transaction_hash)
    except Exception as e:
        print(f"set_dispute_window skipped/failed (owner-only): {e}")

    finalize_tx = await oracle.functions["finalize"].invoke(market_id=market_id, max_fee=int(1e16))
    await wait_for_tx(client, finalize_tx.transaction_hash)

    # Resolve market from oracle and redeem
    resolve_tx = await market.functions["resolve_from_oracle"].invoke(max_fee=int(1e16))
    await wait_for_tx(client, resolve_tx.transaction_hash)

    before_balance = await stablecoin.functions["balance_of"].call(account.address)
    redeem_tx = await market.functions["redeem"].invoke(max_fee=int(1e16))
    await wait_for_tx(client, redeem_tx.transaction_hash)
    after_balance = await stablecoin.functions["balance_of"].call(account.address)

    print("Balance before redeem:", u256_to_int(before_balance))
    print("Balance after redeem:", u256_to_int(after_balance))
    print("E2E resolution + payout completed")
    return 0


if __name__ == "__main__":
    import asyncio
    raise SystemExit(asyncio.run(main()))
