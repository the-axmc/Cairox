"""
Market Resolution Logic

This module handles the logic for computing market outcomes based on
received data and the resolution rules defined in market specifications.
"""

import hashlib
import json
import os
import re
from dataclasses import dataclass
from datetime import datetime
from enum import Enum
from typing import Any, Dict, List, Optional, Union

try:
    from starknet_py.hash.utils import pedersen_hash, message_signature
except Exception:
    try:
        from starkware.crypto.signature.signature import pedersen_hash, sign as message_signature
    except Exception:
        pedersen_hash = None
        message_signature = None

try:
    from poseidon_py.poseidon_hash import poseidon_hash, poseidon_hash_many
except Exception:
    try:
        from poseidon_py import poseidon_hash
        poseidon_hash_many = None
    except Exception:
        poseidon_hash = None
        poseidon_hash_many = None

def _sign_message(msg_hash: int, priv_key: int) -> tuple[int, int]:
    if message_signature is None:
        raise RuntimeError("Signing not available. Install starknet-py or starkware-crypto.")
    sig_r, sig_s = message_signature(msg_hash=msg_hash, priv_key=priv_key)
    return int(sig_r), int(sig_s)


class ResolutionRule(Enum):
    """Resolution rules for market outcomes."""
    THRESHOLD = "threshold"  # YES if value >= threshold
    TOP1 = "top1"            # YES if top value, NO otherwise
    TOP1_CATEGORICAL = "top1_categorical"  # Categorical: return the winner
    BINARY_THRESHOLD = "binary_threshold"  # Binary outcome based on threshold


class AggregationMethod(Enum):
    """How data is aggregated across sources."""
    AVERAGE = "average"
    MEDIAN = "median"
    SUM = "sum"
    WEIGHTED_AVG = "weighted_avg"
    FIRST = "first"
    LATEST = "latest"


@dataclass
class MarketSpec:
    """Market specification."""
    market_id: str
    endpoint: str
    resolution_rule: ResolutionRule
    aggregation_method: AggregationMethod
    data_key: Optional[str] = None  # Key in response to use for resolution
    threshold: Optional[float] = None  # For THRESHOLD rule
    categorical_options: Optional[List[str]] = None  # For categorical markets
    metric_source: Optional[str] = None  # Data source (e.g., "growthepie")
    void_conditions: Optional[List[str]] = None  # Conditions under which market should be voided
    asset: Optional[str] = None  # Asset being tracked (e.g., "starknet")


@dataclass
class MarketOutcome:
    """Result of market resolution."""
    market_id: str
    outcome: str  # YES, NO, or winner name for categorical
    data_hash: str
    data_uri: str
    resolved_at: str
    raw_value: Any
    resolution_rule: str
    aggregation_method: str
    raw_data: Optional[Dict[str, Any]] = None

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "market_id": self.market_id,
            "outcome": self.outcome,
            "data_hash": self.data_hash,
            "data_uri": self.data_uri,
            "resolved_at": self.resolved_at,
            "raw_value": self.raw_value,
            "resolution_rule": self.resolution_rule,
            "aggregation_method": self.aggregation_method,
        }


@dataclass
class ProofBundle:
    """Proof data plus optional public inputs."""
    proof: List[int]
    public_inputs: Optional[List[int]] = None


class MarketResolver:
    """Resolves market outcomes based on specifications and data."""

    STARKNET_PRIME = 2**251 + 17 * 2**192 + 1

    def __init__(self, local_cache_dir: Optional[str] = None):
        """
        Initialize the MarketResolver.

        Args:
            local_cache_dir: Directory to store resolved data locally. If None, data is stored in-memory only.
        """
        self.cache_dir = local_cache_dir or "/tmp/oracle_agent_cache"
        os.makedirs(self.cache_dir, exist_ok=True)

    def parse_market_spec(self, spec: Dict[str, Any]) -> MarketSpec:
        """
        Parse a market specification dictionary into a MarketSpec object.

        Args:
            spec: Dictionary containing market specification

        Returns:
            MarketSpec object
        """
        return MarketSpec(
            market_id=spec["market_id"],
            endpoint=spec["endpoint"],
            resolution_rule=ResolutionRule(spec.get("resolution_rule", "threshold")),
            aggregation_method=AggregationMethod(spec.get("aggregation_method", "latest")),
            data_key=spec.get("data_key"),
            threshold=spec.get("threshold"),
            categorical_options=spec.get("categorical_options"),
        )

    def _aggregate_data(self, data: Dict[str, Any], method: AggregationMethod, data_key: Optional[str] = None) -> Any:
        """
        Aggregate data according to the specified method.

        Args:
            data: Raw data dictionary
            method: Aggregation method
            data_key: Key to extract from data (optional)

        Returns:
            Aggregated value
        """
        # Extract the value if a data_key is specified
        value = data
        if data_key and isinstance(data, dict):
            value = data.get(data_key)
            # If data_key points to a dict, try to get the value from it
            if isinstance(value, dict) and "value" in value:
                value = value["value"]
            elif isinstance(value, dict) and "v" in value:
                value = value["v"]
            elif isinstance(value, dict):
                # Try to get a numeric value from the dict
                value = next((v for v in value.values() if isinstance(v, (int, float))), value)
        elif isinstance(value, dict):
            # Handle normalized export responses like {"value": x, "raw": {...}}
            if "value" in value:
                value = value["value"]
            elif "v" in value:
                value = value["v"]
            elif "raw" in value and isinstance(value["raw"], dict):
                raw = value["raw"]
                if "value" in raw:
                    value = raw["value"]
                elif "v" in raw:
                    value = raw["v"]

        # Handle different aggregation methods
        if method == AggregationMethod.FIRST:
            return value

        elif method == AggregationMethod.LATEST:
            # For time series data, return the latest value
            if isinstance(value, list) and len(value) > 0:
                # Try to find latest entry
                if isinstance(value[0], dict) and "t" in value[0]:
                    # Time series data
                    latest = max(value, key=lambda x: x.get("t", 0))
                    return latest.get("v", latest.get("value", latest))
                return value[-1]
            return value

        elif method == AggregationMethod.SUM:
            if isinstance(value, (int, float)):
                return value
            if isinstance(value, dict):
                # For categorical, return the raw dict for further processing
                return value
            if isinstance(value, list):
                return sum(float(v) if isinstance(v, (int, float)) else 0 for v in value)
            return 0

        elif method == AggregationMethod.AVERAGE:
            if isinstance(value, (int, float)):
                return value
            if isinstance(value, list):
                numbers = [float(v) for v in value if isinstance(v, (int, float))]
                return sum(numbers) / len(numbers) if numbers else 0
            return 0

        elif method == AggregationMethod.MEDIAN:
            if isinstance(value, (int, float)):
                return value
            if isinstance(value, list):
                numbers = sorted([float(v) for v in value if isinstance(v, (int, float))])
                if not numbers:
                    return 0
                n = len(numbers)
                if n % 2 == 0:
                    return (numbers[n//2 - 1] + numbers[n//2]) / 2
                return numbers[n//2]
            return 0

        return value

    def _compute_data_hash(self, raw_data: Dict[str, Any]) -> str:
        """
        Compute SHA256 hash of raw data.

        Args:
            raw_data: Raw data dictionary

        Returns:
            Hexadecimal hash string
        """
        serialized = json.dumps(raw_data, sort_keys=True, separators=(',', ':'))
        return hashlib.sha256(serialized.encode()).hexdigest()

    def _hash_to_felt(self, hex_hash: str) -> int:
        """Map a hex hash into a felt252."""
        return int(hex_hash, 16) % self.STARKNET_PRIME

    def _felt_from_str(self, value: str) -> int:
        """Pack a short string into felt."""
        return int.from_bytes(str(value).encode()[:31], "big")

    def _outcome_to_felt(self, outcome: str) -> int:
        """Encode outcomes consistently for proofs."""
        if outcome in ("YES", "yes", "Yes", "1", 1):
            return 1
        if outcome in ("NO", "no", "No", "0", 0):
            return 0
        return self._felt_from_str(outcome)

    def _market_id_to_felt(self, market_id: str) -> int:
        if isinstance(market_id, int):
            return market_id
        if isinstance(market_id, str) and market_id.startswith("0x"):
            return int(market_id, 16)
        if isinstance(market_id, str) and market_id.isdigit():
            return int(market_id)
        return int.from_bytes(str(market_id).encode()[:31], "big")

    def _state_domain(self) -> int:
        domain = int.from_bytes("MSTATE".encode(), "big")
        chain_id = self._chain_id_felt()
        commitment_addr = self._contract_address_felt("DATA_COMMITMENT_ADDRESS")
        if commitment_addr == 0:
            raise RuntimeError("DATA_COMMITMENT_ADDRESS is required for market state signing")
        if pedersen_hash is None:
            raise RuntimeError("pedersen_hash not available. Install starknet-py.")
        acc = pedersen_hash(domain, chain_id)
        return pedersen_hash(acc, commitment_addr)

    def _resolve_domain(self) -> int:
        domain = int.from_bytes("RESOLVE".encode(), "big")
        chain_id = self._chain_id_felt()
        verifier_addr = self._contract_address_felt("RESOLUTION_VERIFIER_ADDRESS")
        if verifier_addr == 0:
            raise RuntimeError("RESOLUTION_VERIFIER_ADDRESS is required for resolution signing")
        if pedersen_hash is None:
            raise RuntimeError("pedersen_hash not available. Install starknet-py.")
        acc = pedersen_hash(domain, chain_id)
        return pedersen_hash(acc, verifier_addr)

    def _contract_address_felt(self, env_key: str) -> int:
        value = os.getenv(env_key, "0x0")
        if isinstance(value, str) and value.startswith("0x"):
            return int(value, 16)
        if isinstance(value, str) and value.isdigit():
            return int(value)
        try:
            return int(value)
        except Exception:
            return 0

    def _chain_id_felt(self) -> int:
        env = os.getenv("STARKNET_CHAIN_ID")
        if env:
            if env.startswith("0x"):
                return int(env, 16)
            if env.isdigit():
                return int(env)
            return int.from_bytes(env.encode(), "big")
        network = os.getenv("STARKNET_NETWORK", "sepolia").lower()
        mapping = {
            "sepolia": "SN_SEPOLIA",
            "mainnet": "SN_MAIN",
            "goerli": "SN_GOERLI",
            "localhost": "SN_LOCAL",
        }
        chain = mapping.get(network, "SN_SEPOLIA")
        return int.from_bytes(chain.encode(), "big")

    def _poseidon_hash_values(self, values: List[int]) -> int:
        if poseidon_hash_many is not None:
            try:
                return int(poseidon_hash_many(values))
            except TypeError:
                pass
        if poseidon_hash is None:
            raise RuntimeError("poseidon hash not available. Install poseidon-py.")
        if not values:
            return 0
        if len(values) == 1:
            return int(values[0])
        acc = int(poseidon_hash(int(values[0]), int(values[1])))
        for v in values[2:]:
            acc = int(poseidon_hash(acc, int(v)))
        return acc

    def compute_market_state_hash(
        self,
        yes_supply: int,
        no_supply: int,
        b_param: int,
        price_yes: int,
        price_no: int,
        timestamp: int,
    ) -> int:
        values = [
            int(yes_supply),
            int(no_supply),
            int(b_param),
            int(price_yes),
            int(price_no),
            int(timestamp),
        ]
        return int(self._poseidon_hash_values(values)) % self.STARKNET_PRIME

    def sign_market_state(
        self,
        market_id: str,
        state_hash: int,
        private_key: Optional[str] = None
    ) -> tuple[int, int]:
        if pedersen_hash is None or message_signature is None:
            raise RuntimeError("Signing not available. Install starknet-py or starkware-crypto.")
        priv = private_key or os.getenv("ORACLE_SIGNER_PRIVATE_KEY") or os.getenv("STARKNET_PRIVATE_KEY")
        if not priv:
            raise RuntimeError("Missing ORACLE_SIGNER_PRIVATE_KEY for signing market state")
        priv_int = int(priv, 16) if str(priv).startswith("0x") else int(priv)
        market_id_felt = self._market_id_to_felt(market_id)
        acc = pedersen_hash(market_id_felt, int(state_hash))
        msg_hash = pedersen_hash(acc, self._state_domain())
        return _sign_message(msg_hash, priv_int)

    def _message_hash(self, market_id: str, outcome: str, data_hash: str) -> int:
        if pedersen_hash is None:
            raise RuntimeError("pedersen_hash not available. Install starknet-py.")
        market_id_felt = self._market_id_to_felt(market_id)
        outcome_felt = self._outcome_to_felt(outcome)
        data_hash_felt = int(data_hash, 16) if isinstance(data_hash, str) else int(data_hash)
        acc = pedersen_hash(market_id_felt, outcome_felt)
        acc = pedersen_hash(acc, data_hash_felt)
        return pedersen_hash(acc, self._resolve_domain())

    def _parse_int_list(self, data: Any) -> List[int]:
        if isinstance(data, str):
            tokens = [t for t in re.split(r"[,\s]+", data.strip()) if t]
            return [int(t, 16) if t.startswith("0x") else int(t) for t in tokens]
        if not isinstance(data, list):
            raise ValueError("Expected a list of integers")
        return [int(x, 16) if isinstance(x, str) and x.startswith("0x") else int(x) for x in data]

    def _load_public_inputs(self) -> Optional[List[int]]:
        path = os.getenv("ORACLE_ZK_PUBLIC_INPUTS_PATH")
        if not path:
            return None
        try:
            with open(path, "r") as f:
                raw = json.load(f)
            if isinstance(raw, dict) and "public_inputs" in raw:
                raw = raw["public_inputs"]
            return self._parse_int_list(raw)
        except Exception as exc:
            raise RuntimeError(f"Failed to load public inputs from {path}: {exc}") from exc

    def build_proof(self, outcome: str, raw_value: Any, data_hash: str, market_id: Optional[str] = None) -> ProofBundle:
        """
        Build a cryptographic proof array for on-chain verification.

        Proof layout:
        [data_hash_felt, sig_r, sig_s]
        """
        if market_id is None:
            raise ValueError("market_id is required for cryptographic proof")
        proof_path = os.getenv("ORACLE_ZK_PROOF_PATH")
        proof_dir = os.getenv("ORACLE_ZK_PROOF_DIR")
        if proof_path or proof_dir:
            path = proof_path
            if path is None and proof_dir:
                path = os.path.join(proof_dir, f"{market_id}.json")
            try:
                public_inputs = None
                raw = None
                try:
                    with open(path, "r") as f:
                        raw = json.load(f)
                except json.JSONDecodeError:
                    with open(path, "r") as f:
                        raw = f.read()

                if isinstance(raw, dict):
                    if "public_inputs" in raw:
                        public_inputs = self._parse_int_list(raw["public_inputs"])
                    elif "inputs" in raw:
                        public_inputs = self._parse_int_list(raw["inputs"])

                    if "full_proof_with_hints" in raw:
                        raw = raw["full_proof_with_hints"]
                    elif "calldata" in raw:
                        raw = raw["calldata"]
                    elif "proof" in raw:
                        raw = raw["proof"]

                proof_list = self._parse_int_list(raw)
                if public_inputs is None:
                    public_inputs = self._load_public_inputs()
                return ProofBundle(proof=proof_list, public_inputs=public_inputs)
            except Exception as exc:
                raise RuntimeError(f"Failed to load ZK proof from {path}: {exc}") from exc
        if message_signature is None:
            raise RuntimeError("sign() not available. Install starknet-py or starkware-crypto.")

        private_key = os.getenv("ORACLE_SIGNER_PRIVATE_KEY") or os.getenv("STARKNET_PRIVATE_KEY")
        if not private_key:
            raise RuntimeError("Missing ORACLE_SIGNER_PRIVATE_KEY for signing proofs")
        priv = int(private_key, 16) if str(private_key).startswith("0x") else int(private_key)

        msg_hash = self._message_hash(market_id, outcome, data_hash)
        sig_r, sig_s = _sign_message(msg_hash, priv)
        data_hash_felt = int(data_hash, 16) if isinstance(data_hash, str) else int(data_hash)
        return ProofBundle(proof=[data_hash_felt, int(sig_r), int(sig_s)], public_inputs=None)

    def _store_data(self, data: Dict[str, Any], market_id: str, data_hash: str) -> str:
        """
        Store raw data and return URI.

        Args:
            data: Raw data dictionary
            market_id: Market identifier

        Returns:
            URI indicating where data is stored
        """
        cache_path = os.path.join(self.cache_dir, f"{market_id}_{data_hash}.json")

        with open(cache_path, 'w') as f:
            json.dump(data, f)

        return f"local://{data_hash}"

    def resolve(self, market_spec: MarketSpec, data: Dict[str, Any]) -> MarketOutcome:
        """
        Resolve a market based on specification and data.

        Args:
            market_spec: Market specification
            data: Market data from Growthepie API

        Returns:
            MarketOutcome with computed result

        Raises:
            ValueError: If resolution fails due to invalid data or missing thresholds
        """
        # Aggregate data
        aggregated_value = self._aggregate_data(
            data,
            market_spec.aggregation_method,
            market_spec.data_key
        )

        # Determine outcome based on resolution rule
        outcome = None
        resolution_rule = market_spec.resolution_rule.value

        if market_spec.resolution_rule == ResolutionRule.THRESHOLD:
            if market_spec.threshold is None:
                raise ValueError("THRESHOLD resolution rule requires a threshold value")

            # Convert to float for comparison
            try:
                value = float(aggregated_value) if aggregated_value is not None else None
            except (TypeError, ValueError):
                raise ValueError(f"Cannot convert aggregated value to float: {aggregated_value}")

            if value is None:
                raise ValueError("Aggregated value is None; cannot resolve market")

            outcome = "YES" if value >= market_spec.threshold else "NO"

        elif market_spec.resolution_rule == ResolutionRule.TOP1:
            # Binary market: check if top value meets criteria
            if isinstance(aggregated_value, dict):
                values = list(aggregated_value.values())
                if values:
                    top1 = max(values)
                    try:
                        outcome = "YES" if float(top1) >= 0 else "NO"
                    except (TypeError, ValueError):
                        outcome = "YES"
                else:
                    outcome = "NO"
            else:
                try:
                    outcome = "YES" if float(aggregated_value) > 0 else "NO"
                except (TypeError, ValueError):
                    outcome = "YES"

        elif market_spec.resolution_rule == ResolutionRule.TOP1_CATEGORICAL:
            # Categorical market: return the top category
            if isinstance(aggregated_value, dict):
                # Value is a dict of category -> value
                if aggregated_value:
                    winner = max(aggregated_value.keys(), key=lambda k: aggregated_value[k])
                    outcome = winner
                else:
                    if market_spec.categorical_options:
                        outcome = market_spec.categorical_options[0]
                    else:
                        raise ValueError("Empty categorical data with no fallback options")
            elif isinstance(aggregated_value, list) and aggregated_value:
                outcome = str(aggregated_value[0])
            else:
                outcome = str(aggregated_value) if aggregated_value else "unknown"

        elif market_spec.resolution_rule == ResolutionRule.BINARY_THRESHOLD:
            # Binary threshold market: YES if value >= threshold, NO otherwise
            if market_spec.threshold is None:
                raise ValueError("BINARY_THRESHOLD resolution rule requires a threshold value")

            try:
                value = float(aggregated_value) if aggregated_value is not None else None
            except (TypeError, ValueError):
                raise ValueError(f"Cannot convert aggregated value to float: {aggregated_value}")

            if value is None:
                raise ValueError("Aggregated value is None; cannot resolve market")

            outcome = "YES" if value >= market_spec.threshold else "NO"

        else:
            raise ValueError(f"Unknown resolution rule: {resolution_rule}")

        # Store data and compute URI
        full_hash = self._compute_data_hash(data)
        data_hash_felt = self._hash_to_felt(full_hash)
        data_uri = self._store_data(data, market_spec.market_id, full_hash)
        data_hash = hex(data_hash_felt)

        return MarketOutcome(
            market_id=market_spec.market_id,
            outcome=outcome,
            data_hash=data_hash,
            data_uri=data_uri,
            resolved_at=datetime.utcnow().isoformat() + "Z",
            raw_value=aggregated_value,
            resolution_rule=resolution_rule,
            aggregation_method=market_spec.aggregation_method.value,
            raw_data=data,
        )

    def resolve_from_dict(self, spec: Dict[str, Any], data: Dict[str, Any]) -> MarketOutcome:
        """
        Resolve a market using dictionary specification.

        Args:
            spec: Market specification dictionary
            data: Market data dictionary

        Returns:
            MarketOutcome with computed result
        """
        market_spec = self.parse_market_spec(spec)
        return self.resolve(market_spec, data)

    # ============= Deterministic Resolution Functions =============

    def resolve_daa_binary(self, spec: MarketSpec, data: Dict[str, Any]) -> str:
        """
        Binary: DAA >= threshold? Deterministic resolution.

        Args:
            spec: Market specification with threshold
            data: Data dictionary containing 'daa' or 'daily_active_addresses'

        Returns:
            "YES" if DAA >= threshold, "NO" otherwise
        """
        threshold = spec.threshold
        daa = data.get('daa', data.get('daily_active_addresses', 0))

        if daa is None:
            raise ValueError("DAA data is None; cannot resolve market")

        return "YES" if float(daa) >= threshold else "NO"

    def resolve_txcount_binary(self, spec: MarketSpec, data: Dict[str, Any]) -> str:
        """
        Binary: txcount >= threshold? Deterministic resolution.

        Args:
            spec: Market specification with threshold
            data: Data dictionary containing 'txcount' or 'transaction_count'

        Returns:
            "YES" if txcount >= threshold, "NO" otherwise
        """
        threshold = spec.threshold
        txcount = data.get('txcount', data.get('transaction_count', 0))

        if txcount is None:
            raise ValueError("txcount data is None; cannot resolve market")

        return "YES" if float(txcount) >= threshold else "NO"

    def resolve_fees_binary(self, spec: MarketSpec, data: Dict[str, Any]) -> str:
        """
        Binary: fees >= threshold? Deterministic resolution.

        Args:
            spec: Market specification with threshold
            data: Data dictionary containing 'fees' or 'total_fees'

        Returns:
            "YES" if fees >= threshold, "NO" otherwise
        """
        threshold = spec.threshold
        fees = data.get('fees', data.get('total_fees', 0))

        if fees is None:
            raise ValueError("Fees data is None; cannot resolve market")

        return "YES" if float(fees) >= threshold else "NO"
