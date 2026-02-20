"""
Metrics Computation for Sentiment Index

This module computes market metrics used for sentiment analysis:
- Probability: Implied probability from trade history
- Liquidity: Total liquidity available in the market
- Volatility: Price volatility over a time window
"""

import math
from datetime import datetime, timedelta
from typing import Any, Dict, List, Optional, Tuple

import numpy as np
import pandas as pd


def compute_probability(market_id: str, time_series: List[Dict[str, Any]]) -> Tuple[float, float]:
    """
    Compute probability from trade history with weighted recent trades.
    
    Uses a decay-weighted average where more recent trades have higher weight.
    
    Args:
        market_id: The unique identifier for the market
        time_series: List of trade events with 'price', 'volume', 'timestamp'
    
    Returns:
        Tuple of (current_probability, confidence_score)
        - probability: Implied probability (0.0 to 1.0)
        - confidence: Statistical confidence (0.0 to 1.0)
    """
    if not time_series:
        return 0.5, 0.0  # Default 50% if no data
    
    # Convert to DataFrame for easier processing
    df = pd.DataFrame(time_series)
    
    # Ensure required columns exist
    if 'price' not in df.columns:
        return 0.5, 0.0
    
    # Clip prices to valid probability range
    prices = np.clip(df['price'].values, 0.01, 0.99)
    
    # Compute decay weights (exponential decay, 50% half-life of 1 day)
    if 'timestamp' in df.columns:
        timestamps = pd.to_datetime(df['timestamp'])
        now = datetime.now()
        time_diffs = (now - timestamps).dt.total_seconds()
        half_life_seconds = 86400  # 1 day
        decay_factor = math.log(2) / half_life_seconds
        weights = np.exp(-decay_factor * time_diffs.values)
    else:
        # Equal weights if no timestamps
        weights = np.ones(len(prices))
    
    # Normalize weights
    weights = weights / weights.sum()
    
    # Weighted average probability
    weighted_probability = np.sum(weights * prices)
    
    # Compute confidence based on:
    # 1. Sample size (more trades = higher confidence)
    # 2. Price concentration (less spread = higher confidence)
    # 3. Volume weighted (higher volume = higher confidence)
    
    sample_size_score = min(1.0, len(prices) / 100)  # Max confidence at 100+ trades
    price_std = np.std(prices, weights=weights) if len(prices) > 1 else 0
    price_concentration_score = 1.0 - min(1.0, price_std * 2)  # Lower std = higher score
    
    # Volume weighting if available
    if 'volume' in df.columns:
        volumes = df['volume'].values
        total_volume = np.sum(volumes * weights)
        volume_score = min(1.0, total_volume / 10000)  # Max at 10k volume
    else:
        volume_score = 0.5
    
    # Combine scores
    confidence = 0.4 * sample_size_score + 0.35 * price_concentration_score + 0.25 * volume_score
    confidence = max(0.0, min(1.0, confidence))
    
    return float(weighted_probability), float(confidence)


def compute_liquidity(market_id: str, vault_balances: Optional[Dict[str, float]] = None,
                      orderbook_depth: Optional[Dict[str, float]] = None) -> float:
    """
    Compute liquidity from vault balances + orderbook depth.
    
    Args:
        market_id: The unique identifier for the market
        vault_balances: Dictionary of outcome -> token balance
        orderbook_depth: Dictionary of outcome -> orderbook depth (maximum orders)
    
    Returns:
        Total liquidity in USD equivalent
    """
    total_liquidity = 0.0
    
    # Process vault balances
    if vault_balances:
        for outcome, balance in vault_balances.items():
            # Assume $100 average trade size for conversion
            # This is a simplified model - in production would use actual token prices
            total_liquidity += balance * 100
    
    # Process orderbook depth
    if orderbook_depth:
        for outcome, depth in orderbook_depth.items():
            # Orderbook depth represents maximum tradable amount
            total_liquidity += depth * 50  # Half the vault value equivalent
    
    # Apply market multiplier based on market type
    # Binary markets typically have higher liquidity ratios
    market_type = get_market_type(market_id)
    if market_type == 'binary':
        total_liquidity *= 1.2
    elif market_type == 'categorical':
        total_liquidity *= 0.8
    
    return round(total_liquidity, 2)


def compute_volatility(market_id: str, time_series: List[Dict[str, Any]],
                       window_days: int = 7) -> float:
    """
    Compute volatility from price history using standard deviation.
    
    Uses log returns for volatility calculation.
    
    Args:
        market_id: The unique identifier for the market
        time_series: List of price events with 'price', 'timestamp'
        window_days: Number of days to look back for volatility
    
    Returns:
        Volatility score (annualized standard deviation of returns)
    """
    if not time_series:
        return 0.0
    
    # Convert to DataFrame
    df = pd.DataFrame(time_series)
    
    if 'price' not in df.columns or len(df) < 2:
        return 0.0
    
    # Filter to time window
    if 'timestamp' in df.columns:
        timestamps = pd.to_datetime(df['timestamp'])
        cutoff = datetime.now() - timedelta(days=window_days)
        df = df[timestamps >= cutoff]
    
    if len(df) < 2:
        return 0.0
    
    prices = df['price'].values
    prices = np.clip(prices, 0.01, 0.99)  # Avoid log(0)
    
    # Calculate log returns
    log_prices = np.log(prices)
    log_returns = np.diff(log_prices)
    
    # Standard deviation of returns
    std_returns = np.std(log_returns, ddof=1) if len(log_returns) > 1 else 0.0
    
    # Annualize (assuming 365 days, hourly data)
    # Adjust based on actual data frequency
    if len(prices) > 100:
        # High frequency data
        annualization_factor = math.sqrt(365 * 24)
    else:
        # Daily data
        annualization_factor = math.sqrt(365)
    
    annualized_volatility = std_returns * annualization_factor * 100  # Convert to percentage
    
    # Cap at reasonable range
    return min(max(annualized_volatility, 0.0), 200.0)


def get_market_type(market_id: str) -> str:
    """
    Infer market type from market_id.
    
    Args:
        market_id: The unique identifier for the market
    
    Returns:
        Market type: 'binary', 'categorical', or 'numeric'
    """
    market_id_lower = market_id.lower()
    
    if 'binary' in market_id_lower or 'yes' in market_id_lower or 'no' in market_id_lower:
        return 'binary'
    elif 'top' in market_id_lower or 'winner' in market_id_lower:
        return 'categorical'
    else:
        return 'numeric'


def compute_all_metrics(market_id: str, trades: List[Dict[str, Any]],
                        vault_balances: Optional[Dict[str, float]] = None,
                        orderbook_depth: Optional[Dict[str, float]] = None,
                        window_days: int = 7) -> Dict[str, Any]:
    """
    Compute all sentiment metrics for a market.
    
    Args:
        market_id: The unique identifier for the market
        trades: List of trade events
        vault_balances: Dictionary of outcome -> token balance
        orderbook_depth: Dictionary of outcome -> orderbook depth
        window_days: Number of days for volatility calculation
    
    Returns:
        Dictionary with all computed metrics:
        - probability: Current implied probability
        - probability_confidence: Confidence in probability estimate
        - liquidity: Total liquidity
        - volatility: Annualized volatility
        - timestamp: When metrics were computed
    """
    # Compute individual metrics
    probability, confidence = compute_probability(market_id, trades)
    liquidity = compute_liquidity(market_id, vault_balances, orderbook_depth)
    volatility = compute_volatility(market_id, trades, window_days)
    
    return {
        'market_id': market_id,
        'probability': round(probability, 4),
        'probability_confidence': round(confidence, 4),
        'liquidity': round(liquidity, 2),
        'volatility': round(volatility, 2),
        'timestamp': datetime.now().isoformat(),
        'window_days': window_days
    }


def parse_trade_event(event: Dict[str, Any]) -> Dict[str, Any]:
    """
    Parse a trade event from standard format.
    
    Args:
        event: Raw trade event dictionary
    
    Returns:
        Parsed trade with standardized fields
    """
    return {
        'event_type': event.get('event_type', 'trade'),
        'market_id': event.get('market_id'),
        'price': float(event.get('price', 0.5)),
        'volume': float(event.get('volume', 0)),
        'timestamp': event.get('timestamp', datetime.now().isoformat()),
        'trader': event.get('trader'),
        'side': event.get('side', 'yes')
    }


def parse_vault_event(event: Dict[str, Any]) -> Dict[str, Any]:
    """
    Parse a vault balance event.
    
    Args:
        event: Raw vault event dictionary
    
    Returns:
        Parsed vault event with standardized fields
    """
    return {
        'event_type': event.get('event_type', 'vault_update'),
        'market_id': event.get('market_id'),
        'outcome': event.get('outcome', 'default'),
        'balance': float(event.get('balance', 0)),
        'timestamp': event.get('timestamp', datetime.now().isoformat()),
    }
