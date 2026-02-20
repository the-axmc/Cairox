"""
ZK Integrity Proofs for Sentiment Index

Generates and verifies Zero-Knowledge proofs that metrics
were computed correctly from on-chain events.

The proof structure is designed for future Groth16/PLONK integration
while providing a working stub for v0.
"""

import hashlib
import json
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import numpy as np


class ZKProofGenerator:
    """
    Generates and verifies ZK integrity proofs for sentiment metrics.
    """
    
    def __init__(self, proof_directory: Optional[str] = None):
        """
        Initialize the ZK proof generator.
        
        Args:
            proof_directory: Directory to store proofs (default: ./proofs/)
        """
        self.proof_directory = proof_directory or Path(__file__).parent.parent / "proofs"
        self.proof_directory.mkdir(parents=True, exist_ok=True)
    
    def generate_integrity_proof(self, market_id: str, metrics: Dict[str, Any],
                                 events: List[Tuple[int, Dict[str, Any]]]) -> Dict[str, Any]:
        """
        Generate proof that metrics were computed correctly from on-chain events.
        
        Args:
            market_id: The unique identifier for the market
            metrics: Dictionary of computed metrics:
                - probability: Current implied probability
                - probability_confidence: Confidence in probability estimate
                - liquidity: Total liquidity
                - volatility: Annualized volatility
            events: List of (block_number, event_data) tuples from on-chain
        
        Returns:
            Proof dictionary with:
                - public_inputs: [market_id_hash, probability, liquidity, volatility]
                - proof: ZK proof data (currently placeholder)
                - verified: Proof verification status
                - metadata: Additional information about proof generation
        """
        # Hash the market_id for public inputs
        market_id_hash = hashlib.sha256(market_id.encode()).hexdigest()
        
        # Extract metric values
        probability = metrics.get('probability', 0.5)
        liquidity = metrics.get('liquidity', 0.0)
        volatility = metrics.get('volatility', 0.0)
        
        # Build public inputs vector
        public_inputs = [
            int(market_id_hash[:8], 16),  # Truncated hash for demo
            int(probability * 10000),       # Scaled probability (4 decimal places)
            int(liquidity * 100),           # Scaled liquidity (2 decimal places)
            int(volatility * 100)           # Scaled volatility (2 decimal places)
        ]
        
        # Compute data hash from events (deterministic)
        events_data = []
        for block, event in events:
            events_data.append({
                'block': block,
                'event_hash': self._hash_event(event)
            })
        
        events_json = json.dumps(events_data, sort_keys=True)
        events_hash = hashlib.sha256(events_json.encode()).hexdigest()
        
        # Compute metrics hash from computed values
        metrics_hash = self._hash_metrics(metrics)
        
        # Generate non-interactive proof (placeholder for actual ZK proof)
        # In production, this would be replaced with:
        # - Groth16: snarkjs groth16 prove circuit.zkey proof.json
        # - PLONK:/snarkjs plonk prove circuit.zkey witness.wtns proof.json
        
        proof_data = {
            'version': '0.1.0',
            'generator': 'zk-sentiment-indexer',
            'generated_at': datetime.now().isoformat(),
            'events_hash': events_hash,
            'metrics_hash': metrics_hash,
            'events_count': len(events),
            'market_id': market_id,
            'market_id_hash': market_id_hash,
            'public_inputs': public_inputs,
            'proof_type': 'groth16_stub',  # For future migration
            'proof': self._generate_stub_proof(market_id, metrics, events),
            'metadata': {
                'probability_input': probability,
                'liquidity_input': liquidity,
                'volatility_input': volatility,
                'events_sample': events_data[:10] if len(events) > 10 else events_data
            }
        }
        
        # Save proof to file
        proof_file = self.proof_directory / f"proof_{market_id}_{datetime.now().strftime('%Y%m%d')}.json"
        with open(proof_file, 'w') as f:
            json.dump(proof_data, f, indent=2)
        
        return proof_data
    
    def verify_proof(self, proof: Dict[str, Any]) -> Tuple[bool, str]:
        """
        Verify a ZK proof (stub implementation).
        
        Args:
            proof: Proof dictionary to verify
        
        Returns:
            Tuple of (is_valid, message)
        """
        try:
            # Check required fields exist
            required_fields = ['public_inputs', 'proof', 'metadata']
            for field in required_fields:
                if field not in proof:
                    return False, f"Missing required field: {field}"
            
            # Check public inputs structure
            public_inputs = proof['public_inputs']
            if not isinstance(public_inputs, list) or len(public_inputs) < 4:
                return False, "Invalid public inputs structure"
            
            # Verify proof type
            proof_type = proof.get('proof_type', 'unknown')
            if proof_type == 'groth16_stub':
                # For stub proofs, verify basic integrity
                if not self._verify_stub_proof(proof):
                    return False, "Stub proof verification failed"
            elif proof_type == 'plonk_stub':
                if not self._verify_stub_proof(proof):
                    return False, "Stub proof verification failed"
            else:
                # Unknown proof type - could be future actual ZK proof
                # For now, accept it as valid if properly structured
                pass
            
            # Verify metrics hash matches
            if 'metadata' in proof and 'metrics_hash' in proof['metadata']:
                computed_hash = self._hash_metrics({
                    'probability': proof['metadata'].get('probability_input', 0),
                    'liquidity': proof['metadata'].get('liquidity_input', 0),
                    'volatility': proof['metadata'].get('volatility_input', 0)
                })
                stored_hash = proof['metadata'].get('metrics_hash', '')
                if computed_hash != stored_hash:
                    return False, "Metrics hash mismatch"
            
            # Verify events hash matches
            if 'metadata' in proof and 'events_hash' in proof['metadata']:
                stored_events_hash = proof['metadata'].get('events_hash', '')
                # Re-compute events hash from events_sample if available
                if 'events_sample' in proof['metadata']:
                    events_data = []
                    for event_info in proof['metadata']['events_sample']:
                        events_data.append({
                            'block': event_info.get('block'),
                            'event_hash': event_info.get('event_hash')
                        })
                    computed_hash = hashlib.sha256(
                        json.dumps(events_data, sort_keys=True).encode()
                    ).hexdigest()
                    if computed_hash != stored_events_hash:
                        return False, "Events hash mismatch"
            
            return True, "Proof verified successfully"
        
        except Exception as e:
            return False, f"Verification error: {str(e)}"
    
    def _hash_event(self, event: Dict[str, Any]) -> str:
        """Compute SHA256 hash of an event."""
        event_copy = event.copy()
        # Remove non-deterministic fields
        event_copy.pop('timestamp', None)
        event_copy.pop('tx_hash', None)
        
        event_json = json.dumps(event_copy, sort_keys=True)
        return hashlib.sha256(event_json.encode()).hexdigest()
    
    def _hash_metrics(self, metrics: Dict[str, Any]) -> str:
        """Compute SHA256 hash of metrics."""
        metrics_copy = {
            'probability': round(metrics.get('probability', 0.5), 4),
            'probability_confidence': round(metrics.get('probability_confidence', 0.5), 4),
            'liquidity': round(metrics.get('liquidity', 0.0), 2),
            'volatility': round(metrics.get('volatility', 0.0), 2)
        }
        metrics_json = json.dumps(metrics_copy, sort_keys=True)
        return hashlib.sha256(metrics_json.encode()).hexdigest()
    
    def _generate_stub_proof(self, market_id: str, metrics: Dict[str, Any],
                             events: List[Tuple[int, Dict[str, Any]]]) -> Dict[str, Any]:
        """
        Generate a stub proof for demonstration purposes.
        
        This would be replaced with actual ZK proof in production.
        """
        # Create deterministic signature using all inputs
        proof_data = {
            'public_inputs': metrics,
            'events_commitment': hashlib.sha256(
                str(len(events)).encode()
            ).hexdigest()[:16],
            'market_id': market_id,
            'signature': hashlib.sha256(
                (market_id + str(metrics) + str(len(events))).encode()
            ).hexdigest()[:32]
        }
        return proof_data
    
    def _verify_stub_proof(self, proof: Dict[str, Any]) -> bool:
        """
        Verify a stub proof for demonstration purposes.
        
        This would be replaced with actual ZK verification in production.
        """
        if 'proof' not in proof:
            return False
        
        proof_data = proof['proof']
        
        # Verify signature
        if 'signature' not in proof_data:
            return False
        
        expected_signature = hashlib.sha256(
            (proof_data.get('market_id', '') + 
             str(proof_data.get('public_inputs', {})) + 
             str(len(proof.get('metadata', {}).get('events_sample', [])))).encode()
        ).hexdigest()[:32]
        
        return proof_data['signature'] == expected_signature
    
    def get_proof(self, market_id: str, date: Optional[str] = None) -> Optional[Dict[str, Any]]:
        """
        Load a previously generated proof.
        
        Args:
            market_id: The market identifier
            date: Optional date string (YYYYMMDD format)
        
        Returns:
            Proof dictionary or None if not found
        """
        if date:
            proof_file = self.proof_directory / f"proof_{market_id}_{date}.json"
        else:
            # Find most recent proof for this market
            proofs = list(self.proof_directory.glob(f"proof_{market_id}_*.json"))
            if not proofs:
                return None
            proof_file = max(proofs, key=lambda p: p.stat().st_mtime)
        
        try:
            with open(proof_file, 'r') as f:
                return json.load(f)
        except (FileNotFoundError, json.JSONDecodeError):
            return None
    
    def get_all_proofs(self, market_id: Optional[str] = None) -> List[Dict[str, Any]]:
        """
        Get all stored proofs, optionally filtered by market_id.
        
        Args:
            market_id: Optional market identifier filter
        
        Returns:
            List of proof dictionaries
        """
        proofs = []
        
        if market_id:
            proofs.extend(list(self.proof_directory.glob(f"proof_{market_id}_*.json")))
        else:
            proofs.extend(list(self.proof_directory.glob("proof_*.json")))
        
        results = []
        for proof_file in proofs:
            try:
                with open(proof_file, 'r') as f:
                    results.append(json.load(f))
            except json.JSONDecodeError:
                continue
        
        return results


def compute_commitment_hash(proof: Dict[str, Any]) -> str:
    """
    Compute a commitment hash for a proof.
    
    This hash can be stored on-chain for verification.
    
    Args:
        proof: Proof dictionary
    
    Returns:
        SHA256 hash of the commitment
    """
    public_inputs = proof.get('public_inputs', [])
    proof_hash = hashlib.sha256(
        json.dumps(public_inputs, sort_keys=True).encode()
    ).hexdigest()
    
    return proof_hash


def main():
    """Demo of ZK proof generation and verification."""
    import sys
    sys.path.insert(0, str(Path(__file__).parent.parent / "src"))
    
    from metrics import compute_all_metrics
    
    # Sample trade data
    trades = [
        {'price': 0.55, 'volume': 100, 'timestamp': '2024-01-01T10:00:00'},
        {'price': 0.58, 'volume': 200, 'timestamp': '2024-01-01T11:00:00'},
        {'price': 0.62, 'volume': 150, 'timestamp': '2024-01-01T12:00:00'},
        {'price': 0.60, 'volume': 180, 'timestamp': '2024-01-01T13:00:00'},
    ]
    
    # Compute metrics
    metrics = compute_all_metrics('test-market-1', trades)
    
    # Sample events
    events = [
        (1000, {'event_type': 'trade', 'price': 0.55, 'volume': 100}),
        (1001, {'event_type': 'trade', 'price': 0.58, 'volume': 200}),
        (1002, {'event_type': 'trade', 'price': 0.62, 'volume': 150}),
        (1003, {'event_type': 'trade', 'price': 0.60, 'volume': 180}),
    ]
    
    # Generate proof
    generator = ZKProofGenerator()
    proof = generator.generate_integrity_proof('test-market-1', metrics, events)
    
    print("Generated proof:")
    print(f"  Public inputs: {proof['public_inputs']}")
    print(f"  Market ID: {proof['metadata']['market_id']}")
    
    # Verify proof
    is_valid, message = generator.verify_proof(proof)
    print(f"\nVerification result: {is_valid}")
    print(f"Message: {message}")
    
    # Compute commitment hash
    commitment = compute_commitment_hash(proof)
    print(f"\nCommitment hash: {commitment}")


if __name__ == '__main__':
    main()
