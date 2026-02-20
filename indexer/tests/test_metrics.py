"""
Tests for Cairox Indexer Metrics

Unit tests for the metrics computation module.
"""

import sys
from datetime import datetime, timedelta
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

from metrics import (
    compute_all_metrics,
    compute_probability,
    compute_liquidity,
    compute_volatility,
    parse_trade_event,
)


class TestComputeProbability:
    """Tests for compute_probability function."""
    
    def test_compute_probability_with_data(self):
        """Test probability computation with valid data."""
        time_series = [
            {'price': 0.55, 'volume': 100, 'timestamp': '2024-01-01T10:00:00'},
            {'price': 0.58, 'volume': 200, 'timestamp': '2024-01-01T11:00:00'},
            {'price': 0.62, 'volume': 150, 'timestamp': '2024-01-01T12:00:00'},
            {'price': 0.60, 'volume': 180, 'timestamp': '2024-01-01T13:00:00'},
        ]
        
        probability, confidence = compute_probability('test-market', time_series)
        
        assert 0.0 <= probability <= 1.0
        assert 0.0 <= confidence <= 1.0
        assert probability > 0.5  # Weighted average of 0.55-0.62
    
    def test_compute_probability_empty_data(self):
        """Test probability computation with empty data."""
        probability, confidence = compute_probability('test-market', [])
        
        assert probability == 0.5  # Default value
        assert confidence == 0.0   # No confidence without data
    
    def test_compute_probability_with_timestamps(self):
        """Test that timestamps affect weighting."""
        now = datetime.now()
        recent = now - timedelta(hours=1)
        old = now - timedelta(days=1)
        
        time_series = [
            {'price': 0.50, 'volume': 100, 'timestamp': old.isoformat()},
            {'price': 0.70, 'volume': 100, 'timestamp': recent.isoformat()},  # More weight
        ]
        
        probability, confidence = compute_probability('test-market', time_series)
        
        # Recent trade should have more influence
        assert probability > 0.60


class TestComputeLiquidity:
    """Tests for compute_liquidity function."""
    
    def test_compute_liquidity_with_vault_balances(self):
        """Test liquidity from vault balances."""
        vault_balances = {
            'yes': 1000.0,
            'no': 900.0,
        }
        
        liquidity = compute_liquidity('test-market', vault_balances=vault_balances)
        
        # Should be at least 1900 * 100 = 190,000
        assert liquidity > 190000
    
    def test_compute_liquidity_with_orderbook(self):
        """Test liquidity from orderbook depth."""
        orderbook_depth = {
            'yes': 500.0,
            'no': 450.0,
        }
        
        liquidity = compute_liquidity('test-market', orderbook_depth=orderbook_depth)
        
        # Should be at least 950 * 50 = 47,500
        assert liquidity > 47500
    
    def test_compute_liquidity_combined(self):
        """Test liquidity from both sources."""
        vault_balances = {
            'yes': 1000.0,
            'no': 900.0,
        }
        
        orderbook_depth = {
            'yes': 500.0,
            'no': 450.0,
        }
        
        liquidity = compute_liquidity(
            'test-market',
            vault_balances=vault_balances,
            orderbook_depth=orderbook_depth
        )
        
        # Should include both vault and orderbook
        assert liquidity > 190000  # At least vault value


class TestComputeVolatility:
    """Tests for compute_volatility function."""
    
    def test_compute_volatility_with_data(self):
        """Test volatility computation with valid data."""
        time_series = [
            {'price': 0.50, 'timestamp': '2024-01-01T10:00:00'},
            {'price': 0.52, 'timestamp': '2024-01-01T11:00:00'},
            {'price': 0.48, 'timestamp': '2024-01-01T12:00:00'},
            {'price': 0.55, 'timestamp': '2024-01-01T13:00:00'},
        ]
        
        volatility = compute_volatility('test-market', time_series, window_days=7)
        
        # Should return a positive volatility
        assert volatility > 0.0
    
    def test_compute_volatility_empty_data(self):
        """Test volatility computation with empty data."""
        volatility = compute_volatility('test-market', [])
        assert volatility == 0.0
    
    def test_compute_volatility_single_price(self):
        """Test volatility with single price."""
        time_series = [
            {'price': 0.50, 'timestamp': '2024-01-01T10:00:00'},
        ]
        
        volatility = compute_volatility('test-market', time_series, window_days=7)
        assert volatility == 0.0  # No volatility with single price


class TestComputeAllMetrics:
    """Tests for compute_all_metrics function."""
    
    def test_compute_all_metrics(self):
        """Test full metrics computation."""
        trades = [
            {'price': 0.55, 'volume': 100, 'timestamp': '2024-01-01T10:00:00'},
            {'price': 0.58, 'volume': 200, 'timestamp': '2024-01-01T11:00:00'},
        ]
        
        vault_balances = {'yes': 1000.0, 'no': 900.0}
        
        metrics = compute_all_metrics(
            market_id='test-market',
            trades=trades,
            vault_balances=vault_balances,
            orderbook_depth=None,
            window_days=7
        )
        
        # Check all required fields
        assert 'probability' in metrics
        assert 'probability_confidence' in metrics
        assert 'liquidity' in metrics
        assert 'volatility' in metrics
        assert 'timestamp' in metrics
        
        # Check value ranges
        assert 0.0 <= metrics['probability'] <= 1.0
        assert 0.0 <= metrics['probability_confidence'] <= 1.0
        assert metrics['liquidity'] > 0.0
        assert metrics['volatility'] >= 0.0


class TestParseTradeEvent:
    """Tests for parse_trade_event function."""
    
    def test_parse_trade_event(self):
        """Test parsing a trade event."""
        event = {
            'event_type': 'trade',
            'market_id': 'test-market',
            'price': 0.55,
            'volume': 100,
            'timestamp': '2024-01-01T10:00:00',
            'trader': '0x1234',
            'side': 'yes'
        }
        
        parsed = parse_trade_event(event)
        
        assert parsed['event_type'] == 'trade'
        assert parsed['market_id'] == 'test-market'
        assert parsed['price'] == 0.55
        assert parsed['volume'] == 100.0
    
    def test_parse_trade_event_with_defaults(self):
        """Test parsing with default values."""
        event = {
            'price': 0.55,
        }
        
        parsed = parse_trade_event(event)
        
        assert parsed['price'] == 0.55
        assert parsed['event_type'] == 'trade'
        assert parsed['volume'] == 0.0
