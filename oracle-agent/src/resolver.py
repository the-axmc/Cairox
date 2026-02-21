"""
Market Resolution Logic

This module handles the logic for computing market outcomes based on
received data and the resolution rules defined in market specifications.
"""

import hashlib
import json
import os
from dataclasses import dataclass
from datetime import datetime
from enum import Enum
from typing import Any, Dict, List, Optional, Union


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


class MarketResolver:
    """Resolves market outcomes based on specifications and data."""

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

    def _store_data(self, data: Dict[str, Any], market_id: str) -> str:
        """
        Store raw data and return URI.

        Args:
            data: Raw data dictionary
            market_id: Market identifier

        Returns:
            URI indicating where data is stored
        """
        data_hash = self._compute_data_hash(data)
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
        data_uri = self._store_data(data, market_spec.market_id)
        data_hash = data_uri.split("://")[1]

        return MarketOutcome(
            market_id=market_spec.market_id,
            outcome=outcome,
            data_hash=data_hash,
            data_uri=data_uri,
            resolved_at=datetime.utcnow().isoformat() + "Z",
            raw_value=aggregated_value,
            resolution_rule=resolution_rule,
            aggregation_method=market_spec.aggregation_method.value,
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
