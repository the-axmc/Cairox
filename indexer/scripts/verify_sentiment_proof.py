#!/usr/bin/env python3
"""
Verify Sentiment Proof Script

Verify a ZK integrity proof for sentiment metrics.
"""

import argparse
import json
import sys
from pathlib import Path

# Add src directory to path
sys.path.insert(0, str(Path(__file__).parent))

from proof import ZKProofGenerator


def main():
    """Main verification function."""
    parser = argparse.ArgumentParser(description='Verify Cairox Sentiment Proof')
    parser.add_argument('--proof-path', required=True, help='Path to proof JSON file')
    parser.add_argument('--verbose', action='store_true', help='Show full proof details')
    
    args = parser.parse_args()
    
    # Load proof
    proof_path = Path(args.proof_path)
    if not proof_path.exists():
        print(f"Error: Proof file not found: {args.proof_path}")
        sys.exit(1)
    
    try:
        with open(proof_path, 'r') as f:
            proof = json.load(f)
    except json.JSONDecodeError as e:
        print(f"Error: Invalid JSON in proof file: {e}")
        sys.exit(1)
    
    # Verify proof
    generator = ZKProofGenerator()
    is_valid, message = generator.verify_proof(proof)
    
    # Output results
    if args.verbose:
        print("Full Proof Details:")
        print(json.dumps(proof, indent=2))
        print()
    
    print(f"Verification Result: {'INVALID' if not is_valid else 'VALID'}")
    print(f"Message: {message}")
    
    # Exit with appropriate code
    if is_valid:
        print("\n✓ Proof is valid - metrics were computed correctly")
        sys.exit(0)
    else:
        print("\n✗ Proof is invalid - metrics may have been tampered with")
        sys.exit(1)


if __name__ == '__main__':
    main()
