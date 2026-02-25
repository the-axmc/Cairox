"""
Cairox Indexer Package

Off-chain indexer for Cairox prediction markets.
Computes sentiment metrics and generates ZK integrity proofs.
"""

__version__ = "0.1.0"

from .indexer import CairoxIndexer
from .metrics import compute_all_metrics, compute_probability, compute_liquidity, compute_volatility
from .proof import ZKProofGenerator, compute_commitment_hash

__all__ = [
    'CairoxIndexer',
    'compute_all_metrics',
    'compute_probability',
    'compute_liquidity',
    'compute_volatility',
    'ZKProofGenerator',
    'compute_commitment_hash',
]
