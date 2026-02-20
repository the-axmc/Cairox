"""
Tests for Cairox Indexer ZK Proofs

Unit tests for the ZK proof generation and verification module.
"""

import sys
from datetime import datetime
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

from proof import ZKProofGenerator, compute_commitment_hash
from metrics import compute_all_metrics


class TestZKProofGenerator:
    """Tests for ZKProofGenerator class."""
    
    def setup_method(self):
        """Set up test fixtures."""
        self.generator = ZKProofGenerator()
    
    def test_generate_integrity_proof(self):
        """Test generating a ZK integrity proof."""
        # Create sample metrics
        metrics = compute_all_metrics(
            market_id='test-market',
            trades=[{'price': 0.55, 'volume': 100}],
            vault_balances={'yes': 1000.0},
            orderbook_depth=None,
            window_days=7
        )
        
        # Create sample events
        events = [
            (1000, {'event_type': 'trade', 'price': 0.55, 'volume': 100}),
            (1001, {'event_type': 'trade', 'price': 0.58, 'volume': 200}),
        ]
        
        proof = self.generator.generate_integrity_proof('test-market', metrics, events)
        
        # Check proof structure
        assert 'public_inputs' in proof
        assert 'proof' in proof
        assert 'metadata' in proof
        
        # Check public inputs
        public_inputs = proof['public_inputs']
        assert len(public_inputs) >= 4  # At least 4 values
    
    def test_verify_valid_proof(self):
        """Test verifying a valid proof."""
        # Generate a proof first
        metrics = compute_all_metrics(
            market_id='test-market-verify',
            trades=[{'price': 0.55, 'volume': 100}],
            vault_balances={'yes': 1000.0},
            window_days=7
        )
        
        events = [(1000, {'event_type': 'trade', 'price': 0.55})]
        proof = self.generator.generate_integrity_proof('test-market-verify', metrics, events)
        
        # Verify the proof
        is_valid, message = self.generator.verify_proof(proof)
        
        # Stub proof should verify (not cryptographically secure)
        assert is_valid is True
        assert "verified" in message.lower()
    
    def test_verify_invalid_proof(self):
        """Test verifying an invalid proof."""
        # Create a tampered proof
        proof = {
            'public_inputs': [0, 10000, 100000, 5000],
            'proof': {'signature': 'invalid_signature'},
            'metadata': {
                'market_id': 'test-market',
                'probability_input': 0.7,
                'liquidity_input': 100000,
                'volatility_input': 50.0
            }
        }
        
        is_valid, message = self.generator.verify_proof(proof)
        
        # Should fail due to invalid signature
        assert is_valid is False
    
    def test_proof_contains_market_id_hash(self):
        """Test that proof contains hashed market_id."""
        metrics = compute_all_metrics('test-market-hash', [])
        events = [(1000, {'event_type': 'trade'})]
        
        proof = self.generator.generate_integrity_proof('test-market-hash', metrics, events)
        
        assert 'market_id_hash' in str(proof)
    
    def test_proof_contains_events_hash(self):
        """Test that proof contains events hash."""
        metrics = compute_all_metrics('test-market-events', [])
        events = [
            (1000, {'event_type': 'trade', 'price': 0.55}),
            (1001, {'event_type': 'trade', 'price': 0.60}),
        ]
        
        proof = self.generator.generate_integrity_proof('test-market-events', metrics, events)
        
        assert 'events_hash' in proof


class TestComputeCommitmentHash:
    """Tests for compute_commitment_hash function."""
    
    def test_compute_commitment_hash(self):
        """Test computing a commitment hash."""
        metrics = compute_all_metrics('test-market', [])
        events = [(1000, {'event_type': 'trade'})]
        
        generator = ZKProofGenerator()
        proof = generator.generate_integrity_proof('test-market', metrics, events)
        
        commitment_hash = compute_commitment_hash(proof)
        
        # Should be a valid SHA256 hash
        assert len(commitment_hash) == 64
        assert all(c in '0123456789abcdef' for c in commitment_hash)
    
    def test_commitment_hash_deterministic(self):
        """Test that commitment hash is deterministic."""
        metrics = {'probability': 0.55, 'liquidity': 100000.0, 'volatility': 50.0}
        events = [(1000, {'event_type': 'trade'})]
        
        generator = ZKProofGenerator()
        proof = generator.generate_integrity_proof('test-market', metrics, events)
        
        # Generate commitment hash twice
        hash1 = compute_commitment_hash(proof)
        hash2 = compute_commitment_hash(proof)
        
        # Should be identical
        assert hash1 == hash2


class TestProofPersistence:
    """Tests for proof file persistence."""
    
    def test_proof_saved_to_file(self, tmp_path):
        """Test that proofs are saved to files."""
        generator = ZKProofGenerator(proof_directory=str(tmp_path))
        
        metrics = compute_all_metrics('test-market-file', [])
        events = [(1000, {'event_type': 'trade'})]
        
        proof = generator.generate_integrity_proof('test-market-file', metrics, events)
        
        # Check file was created
        proof_files = list(tmp_path.glob('proof_test-market-file_*.json'))
        assert len(proof_files) >= 1
    
    def test_load_proof_from_file(self, tmp_path):
        """Test loading a proof from file."""
        generator = ZKProofGenerator(proof_directory=str(tmp_path))
        
        metrics = compute_all_metrics('test-market-load', [])
        events = [(1000, {'event_type': 'trade'})]
        
        # Generate and save proof
        proof = generator.generate_integrity_proof('test-market-load', metrics, events)
        
        # Load it back
        loaded_proof = generator.get_proof('test-market-load')
        
        assert loaded_proof is not None
        assert loaded_proof['market_id'] == 'test-market-load'
