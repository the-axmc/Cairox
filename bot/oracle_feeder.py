#!/usr/bin/env python3
"""
Oracle Feeder Bot - Fetches Growthepie data and updates Cairox oracle
Run with: python oracle_feeder.py
"""

import os
import time
import json
import requests
from datetime import datetime

# Growthepie API endpoints
GROWTHEPIE_API = "https://api.growthepie.com/v1"

# Oracle contract address (update after deployment)
ORACLE_ADDRESS = os.environ.get("ORACLE_ADDRESS", "0x...")
WALLET_ADDRESS = os.environ.get("WALLET_ADDRESS", "0x...")
PRIVATE_KEY = os.environ.get("PRIVATE_KEY", "")

def fetch_growthepie_data():
    """Fetch ecosystem stats from Growthepie"""
    stats = {}
    
    endpoints = [
        ("daw", "daily-active-wallets"),
        ("txs", "transactions"),
        ("contracts", "contracts"),
    ]
    
    for key, endpoint in endpoints:
        try:
            response = requests.get(f"{GROWTHEPIE_API}/{endpoint}", timeout=10)
            if response.status_code == 200:
                data = response.json()
                stats[key] = data
                print(f"✓ Fetched {key}: {data}")
            else:
                print(f"✗ {key} API returned {response.status_code}")
        except Exception as e:
            print(f"✗ Error fetching {key}: {e}")
    
    return stats

def format_for_oracle(stats):
    """Format stats for oracle contract"""
    # Extract numeric values - adjust based on actual API response format
    formatted = {}
    
    # Try to extract values (adjust based on actual API response)
    if "daw" in stats:
        daw = stats["daw"]
        if isinstance(daw, dict):
            formatted["daw"] = daw.get("value", daw.get("daw", 0))
        else:
            formatted["daw"] = daw
    
    if "txs" in stats:
        txs = stats["txs"]
        if isinstance(txs, dict):
            formatted["txs"] = txs.get("value", txs.get("transactions", 0))
        else:
            formatted["txs"] = txs
            
    if "contracts" in stats:
        contracts = stats["contracts"]
        if isinstance(contracts, dict):
            formatted["contracts"] = contracts.get("value", contracts.get("contracts", 0))
        else:
            formatted["contracts"] = contracts
    
    return formatted

def update_oracle(stats):
    """Call oracle contract to update values"""
    if not PRIVATE_KEY or PRIVATE_KEY == "0x...":
        print("⚠ No private key configured - skipping on-chain update")
        print("Would update oracle with:", stats)
        return
    
    # TODO: Implement starknet.js contract call
    # For now, just print what would be called
    print(f"Would call oracle.update_daw({stats.get('daw', 0)})")
    print(f"Would call oracle.update_txs({stats.get('txs', 0)})")
    print(f"Would call oracle.update_contracts({stats.get('contracts', 0)})")

def main():
    print(f"=== Oracle Feeder Bot - {datetime.now().isoformat()} ===")
    
    # Fetch data
    stats = fetch_growthepie_data()
    
    if not stats:
        print("No data fetched, exiting")
        return
    
    # Format for oracle
    formatted = format_for_oracle(stats)
    print(f"\nFormatted for oracle: {formatted}")
    
    # Update oracle
    update_oracle(formatted)
    print("\n✓ Oracle update complete")

if __name__ == "__main__":
    main()
