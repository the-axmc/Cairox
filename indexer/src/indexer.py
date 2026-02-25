"""
Cairox Indexer

Indexes on-chain events from Cairox contracts and persists them to SQLite.
Focuses on correctness and replayability (no in-memory stub parsing).
"""

import argparse
import json
import os
import sqlite3
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple

import requests

try:
    from starknet_py.hash.selector import get_selector_from_name
    _SELECTOR_OK = True
except Exception:
    _SELECTOR_OK = False


def _to_int(value: str) -> int:
    if isinstance(value, int):
        return value
    if value.startswith("0x"):
        return int(value, 16)
    return int(value)


def _u256_from_felts(low: str, high: str) -> int:
    low_i = _to_int(low)
    high_i = _to_int(high)
    return low_i + (high_i << 128)


def _felt(value: str) -> str:
    if isinstance(value, int):
        return hex(value)
    return value


def _selector(name: str) -> str:
    if not _SELECTOR_OK:
        raise RuntimeError("starknet_py is required for selector hashing")
    return hex(get_selector_from_name(name))


@dataclass
class ContractSet:
    market_factory: Optional[str]
    optimistic_oracle: Optional[str]
    data_commitment: Optional[str]
    price_oracle: Optional[str]
    markets: List[str]


class CairoxIndexer:
    def __init__(
        self,
        rpc_url: Optional[str] = None,
        db_path: Optional[str] = None,
        from_block: Optional[int] = None,
    ):
        self.rpc_url = rpc_url or os.getenv("INDEXER_RPC_URL") or os.getenv("STARKNET_RPC_URL")
        if not self.rpc_url:
            raise RuntimeError("Missing RPC URL (INDEXER_RPC_URL or STARKNET_RPC_URL).")
        self.db_path = db_path or os.getenv("INDEXER_DB_PATH") or "indexer/data/indexer.db"
        self.from_block = from_block

        self.contracts = self._load_contracts()
        self._ensure_db()

        self.selectors = {
            "Trade": _selector("Trade"),
            "MarketCreated": _selector("MarketCreated"),
            "Proposed": _selector("Proposed"),
            "Disputed": _selector("Disputed"),
            "Finalized": _selector("Finalized"),
            "FastFinalized": _selector("FastFinalized"),
            "ArbitrationResolved": _selector("ArbitrationResolved"),
            "DisputeTimedOut": _selector("DisputeTimedOut"),
            "CommitmentSet": _selector("CommitmentSet"),
            "CommitmentSetSigned": _selector("CommitmentSetSigned"),
            "PriceUpdated": _selector("PriceUpdated"),
        }

    def _load_contracts(self) -> ContractSet:
        def env_addr(name: str) -> Optional[str]:
            v = os.getenv(name)
            return v if v else None

        markets = []
        markets_json = os.getenv("MARKET_ADDRESSES_JSON")
        if markets_json:
            try:
                data = json.loads(markets_json)
                if isinstance(data, list):
                    markets = data
                elif isinstance(data, dict):
                    markets = list(data.values())
            except Exception:
                pass

        # Fallback to specs/markets.json (repo root)
        if not markets:
            specs_path = Path(__file__).resolve().parents[2] / "specs" / "markets.json"
            if specs_path.exists():
                try:
                    specs = json.loads(specs_path.read_text())
                    if isinstance(specs, list):
                        for s in specs:
                            addr = s.get("market_address")
                            if addr:
                                markets.append(addr)
                    elif isinstance(specs, dict):
                        for _, s in specs.items():
                            addr = s.get("market_address")
                            if addr:
                                markets.append(addr)
                except Exception:
                    pass

        return ContractSet(
            market_factory=env_addr("MARKET_FACTORY_ADDRESS"),
            optimistic_oracle=env_addr("OPTIMISTIC_ORACLE_ADDRESS") or env_addr("ORACLE_CONTRACT_ADDRESS"),
            data_commitment=env_addr("DATA_COMMITMENT_ADDRESS"),
            price_oracle=env_addr("PRICE_ORACLE_ADDRESS"),
            markets=markets,
        )

    def _ensure_db(self) -> None:
        Path(self.db_path).parent.mkdir(parents=True, exist_ok=True)
        with sqlite3.connect(self.db_path) as conn:
            c = conn.cursor()
            c.execute(
                """
                CREATE TABLE IF NOT EXISTS indexer_state (
                    id INTEGER PRIMARY KEY,
                    last_block INTEGER
                );
                """
            )
            c.execute(
                """
                CREATE TABLE IF NOT EXISTS events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    block_number INTEGER,
                    tx_hash TEXT,
                    event_index INTEGER,
                    contract_address TEXT,
                    selector TEXT,
                    keys TEXT,
                    data TEXT,
                    created_at TEXT
                );
                """
            )
            c.execute(
                """
                CREATE TABLE IF NOT EXISTS markets (
                    market_id TEXT,
                    market_address TEXT,
                    yes_token TEXT,
                    no_token TEXT,
                    question_hash TEXT,
                    question_uri TEXT,
                    initial_subsidy TEXT,
                    block_number INTEGER,
                    tx_hash TEXT
                );
                """
            )
            c.execute(
                """
                CREATE TABLE IF NOT EXISTS trades (
                    market_address TEXT,
                    trader TEXT,
                    outcome TEXT,
                    is_buy INTEGER,
                    collateral TEXT,
                    tokens TEXT,
                    block_number INTEGER,
                    tx_hash TEXT
                );
                """
            )
            c.execute(
                """
                CREATE TABLE IF NOT EXISTS proposals (
                    market_id TEXT,
                    outcome TEXT,
                    data_hash TEXT,
                    data_uri TEXT,
                    bond TEXT,
                    proposer TEXT,
                    proposed_at TEXT,
                    fast_path INTEGER,
                    block_number INTEGER,
                    tx_hash TEXT
                );
                """
            )
            c.execute(
                """
                CREATE TABLE IF NOT EXISTS disputes (
                    market_id TEXT,
                    disputer TEXT,
                    bond TEXT,
                    disputed_at TEXT,
                    block_number INTEGER,
                    tx_hash TEXT
                );
                """
            )
            c.execute(
                """
                CREATE TABLE IF NOT EXISTS finalizations (
                    market_id TEXT,
                    outcome TEXT,
                    finalized_at TEXT,
                    fast_path INTEGER,
                    block_number INTEGER,
                    tx_hash TEXT
                );
                """
            )
            c.execute(
                """
                CREATE TABLE IF NOT EXISTS commitments (
                    market_id TEXT,
                    data_hash TEXT,
                    updated_at TEXT,
                    signed INTEGER,
                    block_number INTEGER,
                    tx_hash TEXT
                );
                """
            )
            c.execute(
                """
                CREATE TABLE IF NOT EXISTS prices (
                    price TEXT,
                    updated_at TEXT,
                    block_number INTEGER,
                    tx_hash TEXT
                );
                """
            )
            conn.commit()

    def _get_last_block(self) -> int:
        with sqlite3.connect(self.db_path) as conn:
            c = conn.cursor()
            c.execute("SELECT last_block FROM indexer_state WHERE id = 1")
            row = c.fetchone()
            return int(row[0]) if row and row[0] is not None else 0

    def _set_last_block(self, block_number: int) -> None:
        with sqlite3.connect(self.db_path) as conn:
            c = conn.cursor()
            c.execute(
                "INSERT OR REPLACE INTO indexer_state (id, last_block) VALUES (1, ?)",
                (int(block_number),),
            )
            conn.commit()

    def _rpc(self, method: str, params: Dict[str, Any]) -> Dict[str, Any]:
        payload = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
        resp = requests.post(self.rpc_url, json=payload, timeout=30)
        resp.raise_for_status()
        data = resp.json()
        if "error" in data:
            raise RuntimeError(data["error"])
        return data["result"]

    def _iter_events(self, address: str, from_block: int, to_block: Optional[int]) -> Iterable[Dict[str, Any]]:
        continuation = None
        while True:
            filt: Dict[str, Any] = {
                "from_block": {"block_number": from_block},
                "chunk_size": 1000,
                "address": address,
            }
            if to_block is not None:
                filt["to_block"] = {"block_number": to_block}
            if continuation:
                filt["continuation_token"] = continuation
            result = self._rpc("starknet_getEvents", {"filter": filt})
            for evt in result.get("events", []):
                yield evt
            continuation = result.get("continuation_token")
            if not continuation:
                break

    def index_range(self, from_block: int, to_block: Optional[int] = None) -> int:
        contracts = []
        if self.contracts.market_factory:
            contracts.append(self.contracts.market_factory)
        if self.contracts.optimistic_oracle:
            contracts.append(self.contracts.optimistic_oracle)
        if self.contracts.data_commitment:
            contracts.append(self.contracts.data_commitment)
        if self.contracts.price_oracle:
            contracts.append(self.contracts.price_oracle)
        contracts.extend(self.contracts.markets)

        total = 0
        for addr in contracts:
            for evt in self._iter_events(addr, from_block, to_block):
                self._store_event(evt)
                total += 1
        if to_block is not None:
            self._set_last_block(to_block)
        return total

    def _store_event(self, evt: Dict[str, Any]) -> None:
        block_number = evt.get("block_number")
        tx_hash = evt.get("transaction_hash")
        event_index = evt.get("event_index")
        address = evt.get("from_address")
        keys = evt.get("keys", [])
        data = evt.get("data", [])
        selector = keys[0] if keys else "0x0"
        now = datetime.utcnow().isoformat() + "Z"

        with sqlite3.connect(self.db_path) as conn:
            c = conn.cursor()
            c.execute(
                """
                INSERT INTO events (
                    block_number, tx_hash, event_index, contract_address, selector, keys, data, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    block_number,
                    tx_hash,
                    event_index,
                    address,
                    selector,
                    json.dumps(keys),
                    json.dumps(data),
                    now,
                ),
            )
            conn.commit()

        self._store_typed_event(selector, keys, data, block_number, tx_hash, address)

    def _store_typed_event(
        self,
        selector: str,
        keys: List[str],
        data: List[str],
        block_number: int,
        tx_hash: str,
        address: str,
    ) -> None:
        with sqlite3.connect(self.db_path) as conn:
            c = conn.cursor()

            if selector == self.selectors["MarketCreated"]:
                market_id = _felt(keys[1])
                market_address = _felt(data[0])
                yes_token = _felt(data[1])
                no_token = _felt(data[2])
                question_hash = _felt(data[3])
                question_uri = _felt(data[4])
                initial_subsidy = str(_u256_from_felts(data[5], data[6]))
                c.execute(
                    """
                    INSERT INTO markets (
                        market_id, market_address, yes_token, no_token, question_hash, question_uri,
                        initial_subsidy, block_number, tx_hash
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        market_id,
                        market_address,
                        yes_token,
                        no_token,
                        question_hash,
                        question_uri,
                        initial_subsidy,
                        block_number,
                        tx_hash,
                    ),
                )

            if selector == self.selectors["Trade"]:
                trader = _felt(keys[1])
                outcome = _felt(keys[2])
                is_buy = _to_int(data[0])
                collateral = str(_u256_from_felts(data[1], data[2]))
                tokens = str(_u256_from_felts(data[3], data[4]))
                c.execute(
                    """
                    INSERT INTO trades (
                        market_address, trader, outcome, is_buy, collateral, tokens, block_number, tx_hash
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (address, trader, outcome, is_buy, collateral, tokens, block_number, tx_hash),
                )

            if selector == self.selectors["Proposed"]:
                market_id = _felt(keys[1])
                outcome = _felt(data[0])
                data_hash = _felt(data[1])
                data_uri = _felt(data[2])
                bond = str(_u256_from_felts(data[3], data[4]))
                proposer = _felt(data[5])
                proposed_at = str(_u256_from_felts(data[6], data[7]))
                fast_path = _to_int(data[8])
                c.execute(
                    """
                    INSERT INTO proposals (
                        market_id, outcome, data_hash, data_uri, bond, proposer, proposed_at,
                        fast_path, block_number, tx_hash
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        market_id,
                        outcome,
                        data_hash,
                        data_uri,
                        bond,
                        proposer,
                        proposed_at,
                        fast_path,
                        block_number,
                        tx_hash,
                    ),
                )

            if selector == self.selectors["Disputed"]:
                market_id = _felt(keys[1])
                disputer = _felt(data[0])
                bond = str(_u256_from_felts(data[1], data[2]))
                disputed_at = str(_u256_from_felts(data[3], data[4]))
                c.execute(
                    """
                    INSERT INTO disputes (
                        market_id, disputer, bond, disputed_at, block_number, tx_hash
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    (market_id, disputer, bond, disputed_at, block_number, tx_hash),
                )

            if selector in (self.selectors["Finalized"], self.selectors["FastFinalized"]):
                market_id = _felt(keys[1])
                outcome = _felt(data[0])
                finalized_at = str(_u256_from_felts(data[1], data[2]))
                fast_path = 1 if selector == self.selectors["FastFinalized"] else 0
                c.execute(
                    """
                    INSERT INTO finalizations (
                        market_id, outcome, finalized_at, fast_path, block_number, tx_hash
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    (market_id, outcome, finalized_at, fast_path, block_number, tx_hash),
                )

            if selector in (self.selectors["CommitmentSet"], self.selectors["CommitmentSetSigned"]):
                market_id = _felt(keys[1])
                data_hash = _felt(data[0])
                updated_at = str(_u256_from_felts(data[1], data[2]))
                signed = 1 if selector == self.selectors["CommitmentSetSigned"] else 0
                c.execute(
                    """
                    INSERT INTO commitments (
                        market_id, data_hash, updated_at, signed, block_number, tx_hash
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    (market_id, data_hash, updated_at, signed, block_number, tx_hash),
                )

            if selector == self.selectors["PriceUpdated"]:
                price = str(_u256_from_felts(data[0], data[1]))
                updated_at = str(_u256_from_felts(data[2], data[3]))
                c.execute(
                    """
                    INSERT INTO prices (
                        price, updated_at, block_number, tx_hash
                    ) VALUES (?, ?, ?, ?)
                    """,
                    (price, updated_at, block_number, tx_hash),
                )

            conn.commit()

    def run(self, poll_interval: int = 15) -> None:
        last_block = self.from_block if self.from_block is not None else self._get_last_block()
        if last_block == 0:
            last_block = int(os.getenv("INDEXER_START_BLOCK", "0"))

        while True:
            latest = self._rpc("starknet_blockNumber", {})
            if latest < last_block:
                time.sleep(poll_interval)
                continue
            count = self.index_range(last_block, latest)
            print(f"Indexed {count} events up to block {latest}")
            last_block = latest + 1
            self._set_last_block(last_block)
            time.sleep(poll_interval)


def main() -> None:
    parser = argparse.ArgumentParser(description="Cairox Indexer")
    parser.add_argument("--rpc", dest="rpc", help="RPC URL (overrides env)")
    parser.add_argument("--db", dest="db", help="SQLite DB path")
    parser.add_argument("--from-block", dest="from_block", type=int)
    parser.add_argument("--to-block", dest="to_block", type=int)
    parser.add_argument("--once", action="store_true", help="Index once and exit")
    args = parser.parse_args()

    indexer = CairoxIndexer(rpc_url=args.rpc, db_path=args.db, from_block=args.from_block)
    if args.once:
        latest = args.to_block
        if latest is None:
            latest = indexer._rpc("starknet_blockNumber", {})
        count = indexer.index_range(args.from_block or indexer._get_last_block(), latest)
        print(f"Indexed {count} events up to block {latest}")
    else:
        indexer.run()


if __name__ == "__main__":
    main()
