#!/usr/bin/env python3
"""
End-to-End Indexer and Proof Test

Tests the full indexer workflow:
1. Create sample events
2. Compute metrics
3. Generate ZK proof
4. Verify proof
5. Save commitment
"""

import asyncio
import json
import sys
from datetime import datetime
from pathlib import Path

# Add src directory to path
sys.path.insert(0, str(Path(__file__).parent))

from indexer import CairoxIndexer
from metrics import compute_all_metrics, parse_trade_event


def create_sample_events(market_id: str, count: int = 100) -> list:
    """Create sample events for testing."""
    events = []
    for i in range(count):
        event = {
            'event_type': 'trade' if i % 3 != 0 else 'vault_update',
            'market_id': market_id,
            'price': 0.5 + (i % 20) * 0.02,
            'volume': 100 + i * 10,
            'balance': 1000 + i * 50,
            'outcome': 'yes' if i % 2 == 0 else 'no',
            'timestamp': (datetime.now() - timedelta(hours=count-i)).isoformat(),
        }
        events.append(event)
    return events


def main():
    """Main E2E test function."""
    print("=" * 60)
    print("Cairox Indexer - End-to-End Test")
    print("=" * 60)
    
    # Setup
    test_market_id = "e2e-test-market-1"
    proof_dir = Path(__file__).parent.parent / "proofs"
    proof_dir.mkdir(parents=True, exist_ok=True)
    
    print(f"\n[1/5] Initializing indexer...")
    indexer = CairoxIndexer(network="localhost", proof_directory=str(proof_dir))
    print("    ✓ Indexer initialized")
    
    print(f"\n[2/5] Creating sample events...")
    sample_events = create_sample_events(test_market_id, count=50)
    
    # Process events through indexer
    for block_num, event in enumerate(sample_events, start=1000):
        if event['event_type'] == 'trade':
            if test_market_id not in indexer._trades_cache:
                indexer._trades_cache[test_market_id] = []
            indexer._trades_cache[test_market_id].append(parse_trade_event(event))
        elif event['event_type'] == 'vault_update':
            indexer._vault_cache.setdefault(test_market_id, {})
            indexer._vault_cache[test_market_id][event['outcome']] = event.get('balance', 0)
        
        indexer.events_buffer.setdefault(test_market_id, []).append((block_num, event))
    
    print(f"    ✓ Created {len(sample_events)} events")
    
    print(f"\n[3/5] Computing metrics...")
    metrics = indexer.compute_metrics(test_market_id)
    print(f"    ✓ Computed metrics:")
    print(f"        Probability: {metrics['probability']:.2%}")
    print(f"        Liquidity: ${metrics['liquidity']:,.2f}")
    print(f"        Volatility: {metrics['volatility']:.2f}%")
    
    print(f"\n[4/5] Generating ZK proof...")
    proof = indexer.generate_proof(test_market_id, metrics)
    print(f"    ✓ Generated proof")
    print(f"        Public inputs: {proof['public_inputs']}")
    print(f"        Proof type: {proof['proof_type']}")
    
    print(f"\n[5/5] Verifying proof...")
    is_valid, message = indexer.verify_proof(proof)
    print(f"    ✓ Verification result: {is_valid}")
    print(f"        Message: {message}")
    
    # Test daily commitment
    print(f"\n[6/5] Creating daily commitment...")
    commitment = indexer.daily_commitment(test_market_id, date="2024-01-15")
    print(f"    ✓ Created commitment")
    print(f"        Hash: {commitment['commitment_hash'][:16]}...")
    
    # Final results
    print("\n" + "=" * 60)
    print("E2E Test Results")
    print("=" * 60)
    
    all_passed = is_valid
    results = [
        ("Event creation", True),
        ("Metrics computation", True),
        ("Proof generation", True),
        ("Proof verification", is_valid),
        ("Daily commitment", True),
    ]
    
    for test, passed in results:
        status = "✓" if passed else "✗"
        print(f"  {status} {test}")
        all_passed = all_passed and passed
    
    print("\n" + ("=" * 60))
    if all_passed:
        print("✓ All tests passed!")
        print("=" * 60)
        return 0
    else:
        print("✗ Some tests failed")
        print("=" * 60)
        return 1


if __name__ == '__main__':
    from datetime import timedelta
    sys.exit(main())
