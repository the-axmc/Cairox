#!/usr/bin/env python3
"""
Validate market specifications for Cairox prediction markets.
Generates deterministic market_id from spec content using SHA-256 hash.
"""

import json
import hashlib
import sys
from typing import Any

# JSON Schema path
SPEC_SCHEMA_PATH = "specs/market.schema.json"
MARKETS_PATH = "specs/markets.json"

try:
    import jsonschema
    from jsonschema import Draft7Validator
    JSONSCHEMA_AVAILABLE = True
except ImportError:
    JSONSCHEMA_AVAILABLE = False
    print("Warning: jsonschema not installed. Installing...")
    import subprocess
    subprocess.check_call([sys.executable, "-m", "pip", "install", "jsonschema", "-q"])
    import jsonschema
    from jsonschema import Draft7Validator
    JSONSCHEMA_AVAILABLE = True


def load_json(filepath: str) -> dict:
    """Load JSON file."""
    with open(filepath, "r") as f:
        return json.load(f)


def canonicalize_json(data: Any) -> str:
    """
    Convert JSON to canonical form for deterministic hashing.
    - Sort keys at all levels
    - Remove whitespace
    """
    return json.dumps(data, sort_keys=True, separators=(",", ":"))


def compute_market_id(spec: dict) -> str:
    """
    Compute deterministic market_id from spec content.
    The market_id field is excluded from the hash input.
    """
    # Create a copy without market_id
    spec_copy = {k: v for k, v in spec.items() if k != "market_id"}
    
    # Canonicalize and hash
    canonical_form = canonicalize_json(spec_copy)
    hash_value = hashlib.sha256(canonical_form.encode("utf-8")).hexdigest()
    
    return hash_value


def validate_market(spec: dict, schema: dict, validate_id: bool = True) -> tuple[bool, list[str]]:
    """
    Validate a market specification against the schema.
    Returns (is_valid, errors).
    """
    errors = []
    
    if not JSONSCHEMA_AVAILABLE:
        errors.append("JSON Schema library not available")
        return False, errors
    
    # Validate against schema
    try:
        validator = Draft7Validator(schema)
        errors_normalized = sorted(
            validator.iter_errors(spec),
            key=lambda e: e.path[0] if e.path else ""
        )
        
        for error in errors_normalized:
            errors.append(f"{error.path}: {error.message}")
        
        is_valid = len(errors) == 0
        
    except Exception as e:
        errors.append(f"Validation error: {e}")
        return False, errors
    
    # Validate market_id if requested
    if validate_id and is_valid:
        expected_id = compute_market_id(spec)
        actual_id = spec.get("market_id", "")
        
        if actual_id != expected_id:
            errors.append(f"market_id mismatch: expected {expected_id}, got {actual_id}")
            is_valid = False
        
        # Update market_id to correct value
        spec["market_id"] = expected_id
    
    return is_valid, errors


def main():
    """Main validation script."""
    print("=" * 60)
    print("Cairox Market Specification Validator")
    print("=" * 60)
    
    # Load schema
    print("\n[1/4] Loading market schema...")
    try:
        schema = load_json(SPEC_SCHEMA_PATH)
        print(f"    ✓ Loaded schema from {SPEC_SCHEMA_PATH}")
    except FileNotFoundError:
        print(f"    ✗ Schema not found: {SPEC_SCHEMA_PATH}")
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"    ✗ Invalid JSON in schema: {e}")
        sys.exit(1)
    
    # Load markets
    print("\n[2/4] Loading market specifications...")
    try:
        markets_data = load_json(MARKETS_PATH)
        markets = markets_data.get("markets", [markets_data])
        print(f"    ✓-loaded {len(markets)} markets from {MARKETS_PATH}")
    except FileNotFoundError:
        print(f"    ✗ Markets file not found: {MARKETS_PATH}")
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"    ✗ Invalid JSON in markets file: {e}")
        sys.exit(1)
    
    # Validate each market
    print("\n[3/4] Validating markets...")
    all_valid = True
    
    for i, market in enumerate(markets, 1):
        print(f"\n    Market {i}: {market.get('name', 'Untitled')}")
        print(f"    Type: {market.get('type', 'Unknown')}")
        
        is_valid, errors = validate_market(market, schema, validate_id=True)
        
        if is_valid:
            print(f"    ✓ market_id: {market['market_id'][:16]}...")
            print("    ✓ All validations passed")
        else:
            print("    ✗ Validation errors:")
            for error in errors:
                print(f"      - {error}")
            all_valid = False
    
    # Summary
    print("\n" + "=" * 60)
    print("Summary")
    print("=" * 60)
    
    if all_valid:
        print("✓ All markets are valid")
        print("\nGenerated market_ids (SHA-256 hashes):")
        for i, market in enumerate(markets, 1):
            market_id = market["market_id"]
            print(f"  {i}. {market.get('name', 'Untitled')}:")
            print(f"     {market_id}")
        return 0
    else:
        print("✗ Some markets have validation errors")
        return 1


if __name__ == "__main__":
    sys.exit(main())
