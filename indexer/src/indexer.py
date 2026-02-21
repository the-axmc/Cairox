"""
Main Indexer for Cairox Sentiment Index

The indexer reads from on-chain events using starknet.py to compute
sentiment metrics and generate ZK integrity proofs.
"""

import asyncio
import json
import os
import sys
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import pandas as pd

# Add src directory to path
sys.path.insert(0, str(Path(__file__).parent))

from metrics import compute_all_metrics, parse_trade_event, parse_vault_event
from proof import ZKProofGenerator, compute_commitment_hash


class CairoxIndexer:
    """
    Off-chain indexer for Cairox sentiment metrics.
    
    Reads market events from Starknet and computes:
    - Probability metrics from trade history
    - Liquidity from vault balances
    - Volatility from price history
    - ZK integrity proofs for all metrics
    """
    
    def __init__(
        self,
        network: str = "goerli",
        contract_address: Optional[str] = None,
        start_block: Optional[int] = None,
        proof_directory: Optional[str] = None,
    ):
        """
        Initialize the Cairox Indexer.
        
        Args:
            network: Starknet network (goerli, mainnet, sepolia, localhost)
            contract_address: OptimisticOracle contract address
            start_block: Block to start indexing from (default: latest - 1000)
            proof_directory: Directory to store ZK proofs
        """
        self.network = network
        self.contract_address = contract_address or os.getenv(
            "ORACLE_CONTRACT_ADDRESS",
            "0x0000000000000000000000000000000000000000000000000000000000000000"
        )
        self.start_block = start_block
        self.proof_directory = proof_directory
        
        # Initialize Starknet connection
        self.client = None
        self.starknet_py_initialized = self._initialize_starknet()
        
        # Initialize ZK proof generator
        self.proof_generator = ZKProofGenerator(proof_directory)
        
        # Market state storage
        self.markets: Dict[str, Dict[str, Any]] = {}
        self.events_buffer: Dict[str, List[Tuple[int, Dict[str, Any]]]] = {}
        
        # Cache for performance
        self._trades_cache: Dict[str, List[Dict[str, Any]]] = {}
        self._vault_cache: Dict[str, Dict[str, float]] = {}
        self._orderbook_cache: Dict[str, Dict[str, float]] = {}
    
    def _initialize_starknet(self) -> bool:
        """Initialize starknet.py client."""
        try:
            from starknet_py.net.client import Client
            from starknet_py.net.account.account import Account
            from starknet_py.net.models import StarknetChainId
            
            urls = {
                "goerli": "https://goerli.gateway.fm",
                "mainnet": "https://starknet-mainnet.public.blastapi.io",
                "sepolia": "https://sepolia.starknet_gateway.io",
                "localhost": "http://127.0.0.1:5050",
            }
            
            self.client = Client(node_url=urls.get(self.network, urls["goerli"]))
            
            # Try to initialize account if credentials available
            if os.getenv("STARKNET_ACCOUNT_ADDRESS") and os.getenv("STARKNET_PRIVATE_KEY"):
                self.account = Account(
                    client=self.client,
                    address=os.getenv("STARKNET_ACCOUNT_ADDRESS"),
                    key_pair=os.getenv("STARKNET_PRIVATE_KEY"),
                    chain=StarknetChainId.TESTNET,
                )
            
            return True
        except ImportError:
            print("Warning: starknet.py not available. Running in stub mode.")
            return False
        except Exception as e:
            print(f"Warning: Failed to initialize starknet.py: {e}")
            return False
    
    async def subscribe_to_events(self, market_ids: Optional[List[str]] = None) -> None:
        """
        Subscribe to market events from Starknet.
        
        Args:
            market_ids: List of market IDs to subscribe to (None = all markets)
        """
        if not self.starknet_py_initialized:
            print("Starknet not available - using simulated events")
            await self._simulate_events(market_ids)
            return
        
        from starknet_py.net.client import Client
        from starknet_py.net.models import Event
        from starknet_py.net.account.account import Account
        
        print(f"Subscribing to events on network: {self.network}")
        
        # Get latest block number
        block_number = await self.client.get_block_number()
        start = self.start_block or max(0, block_number - 1000)
        
        print(f"Starting from block: {start}")
        
        # Continuous event polling
        while True:
            try:
                current_block = await self.client.get_block_number()
                
                for block_num in range(start, min(start + 10, current_block + 1)):
                    block = await self.client.get_block(block_num)
                    
                    for transaction in block.transactions:
                        receipt = await self.client.get_transaction_receipt(transaction.hash)
                        
                        for event in receipt.events:
                            await self._process_event(event, block_num)
                
                start = current_block + 1
                await asyncio.sleep(5)  # Poll every 5 seconds
                
            except Exception as e:
                print(f"Error polling events: {e}")
                await asyncio.sleep(10)
    
    async def _process_event(self, event: Any, block_number: int) -> None:
        """
        Process a received event and update state.
        
        Args:
            event: Starknet event
            block_number: Block number where event occurred
        """
        # Parse event data
        event_data = self._parse_event_data(event)
        
        if not event_data:
            return
        
        market_id = event_data.get('market_id')
        if not market_id:
            return
        
        # Initialize market if not seen
        if market_id not in self.events_buffer:
            self.events_buffer[market_id] = []
        
        # Buffer event
        self.events_buffer[market_id].append((block_number, event_data))
        
        # Cache event type
        event_type = event_data.get('event_type', 'unknown')
        
        if event_type == 'trade':
            if market_id not in self._trades_cache:
                self._trades_cache[market_id] = []
            self._trades_cache[market_id].append(parse_trade_event(event_data))
        elif event_type == 'vault_update':
            self._vault_cache.setdefault(market_id, {})
            self._vault_cache[market_id][event_data.get('outcome', 'default')] = event_data.get('balance', 0)
        elif event_type == 'orderbook_update':
            self._orderbook_cache.setdefault(market_id, {})
            self._orderbook_cache[market_id][event_data.get('outcome', 'default')] = event_data.get('depth', 0)
    
    def _parse_event_data(self, event: Any) -> Optional[Dict[str, Any]]:
        """Parse a Starknet event into standardized format."""
        # In production, this would parse actual Cairo events
        # For now, return a structured format
        return {
            'event_type': event.data[0] if hasattr(event, 'data') and event.data else 'trade',
            'market_id': f"market_{len(self.events_buffer)}",
            'timestamp': datetime.now().isoformat(),
        }
    
    async def _simulate_events(self, market_ids: Optional[List[str]] = None) -> None:
        """Simulate events for development/testing."""
        print("Running in simulated mode (no Starknet connection)")
        
        # Create sample markets
        sample_markets = market_ids or ['btc-binary-2024', 'eth-top1-2024', 'dex-winner-2024']
        
        for market_id in sample_markets:
            self.events_buffer[market_id] = []
            
            # Generate sample trades
            for i in range(10):
                trade = {
                    'event_type': 'trade',
                    'market_id': market_id,
                    'price': 0.5 + (i * 0.02),
                    'volume': 100 + (i * 50),
                    'timestamp': (datetime.now() - timedelta(hours=10-i)).isoformat(),
                }
                self.events_buffer[market_id].append((1000 + i, trade))
                
                if market_id not in self._trades_cache:
                    self._trades_cache[market_id] = []
                self._trades_cache[market_id].append(parse_trade_event(trade))
            
            # Generate sample vault balances
            self._vault_cache[market_id] = {
                'yes': 1000 + len(self.events_buffer[market_id]) * 10,
                'no': 900 + len(self.events_buffer[market_id]) * 9,
            }
            
            print(f"Initialized market: {market_id}")
        
        print(f"Simulated {len(sample_markets)} markets with trade history")
    
    def compute_metrics(self, market_id: str) -> Dict[str, Any]:
        """
        Compute sentiment metrics for a market.
        
        Args:
            market_id: The market identifier
        
        Returns:
            Dictionary with all computed metrics
        """
        trades = self._trades_cache.get(market_id, [])
        vault_balances = self._vault_cache.get(market_id, {})
        orderbook_depth = self._orderbook_cache.get(market_id, {})
        
        return compute_all_metrics(
            market_id=market_id,
            trades=trades,
            vault_balances=vault_balances,
            orderbook_depth=orderbook_depth,
            window_days=7
        )
    
    def generate_proof(self, market_id: str, metrics: Dict[str, Any]) -> Dict[str, Any]:
        """
        Generate ZK integrity proof for market metrics.
        
        Args:
            market_id: The market identifier
            metrics: Computed metrics dictionary
        
        Returns:
            Proof dictionary
        """
        events = self.events_buffer.get(market_id, [])
        return self.proof_generator.generate_integrity_proof(market_id, metrics, events)
    
    def daily_commitment(self, market_id: str, date: Optional[str] = None) -> Dict[str, Any]:
        """
        Anchor daily snapshot on-chain via ZK proof.
        
        Args:
            market_id: The market identifier
            date: Optional date string (YYYY-MM-DD format, defaults to today)
        
        Returns:
            Commitment dictionary with metrics and proof
        """
        if date is None:
            date = datetime.now().strftime('%Y-%m-%d')
        
        # Compute metrics for the day
        metrics = self.compute_metrics(market_id)
        
        # Generate ZK proof
        proof = self.generate_proof(market_id, metrics)
        
        # Compute commitment hash
        commitment_hash = compute_commitment_hash(proof)
        
        # Create commitment record
        commitment = {
            'market_id': market_id,
            'date': date,
            'metrics': metrics,
            'proof': proof,
            'commitment_hash': commitment_hash,
            'verified': proof.get('verified', False),
            'timestamp': datetime.now().isoformat(),
        }
        
        # Save commitment locally
        commitment_file = Path(self.proof_directory) / f"commitment_{market_id}_{date}.json"
        commitment_file.parent.mkdir(parents=True, exist_ok=True)
        
        with open(commitment_file, 'w') as f:
            json.dump(commitment, f, indent=2)
        
        print(f"Created daily commitment for {market_id} on {date}")
        print(f"  Probability: {metrics['probability']:.2%}")
        print(f"  Liquidity: ${metrics['liquidity']:,.2f}")
        print(f"  Volatility: {metrics['volatility']:.2f}%")
        print(f"  Proof verified: {proof.get('verified', False)}")
        
        return commitment
    
    def verify_proof(self, proof: Dict[str, Any]) -> Tuple[bool, str]:
        """
        Verify a ZK proof.
        
        Args:
            proof: Proof dictionary to verify
        
        Returns:
            Tuple of (is_valid, message)
        """
        return self.proof_generator.verify_proof(proof)
    
    def get_market_state(self, market_id: str) -> Dict[str, Any]:
        """Get current state of a market."""
        return {
            'market_id': market_id,
            'trades_count': len(self._trades_cache.get(market_id, [])),
            'vault_balances': self._vault_cache.get(market_id, {}),
            'orderbook_depth': self._orderbook_cache.get(market_id, {}),
        }
    
    def get_all_markets(self) -> List[str]:
        """Get list of all known market IDs."""
        return list(self.events_buffer.keys())


class DailyIndexer:
    """Runs daily commitments for all markets."""
    
    def __init__(self, indexer: CairoxIndexer):
        """Initialize with an indexer instance."""
        self.indexer = indexer
    
    async def run_daily_commitment(self, market_id: str) -> Dict[str, Any]:
        """Run daily commitment for a single market."""
        return self.indexer.daily_commitment(market_id)
    
    async def run_all_markets(self) -> List[Dict[str, Any]]:
        """Run daily commitments for all markets."""
        markets = self.indexer.get_all_markets()
        return [await self.run_daily_commitment(m) for m in markets]


async def rebuild_index(indexer: CairoxIndexer, market_ids: Optional[List[str]] = None) -> Dict[str, Any]:
    """
    Rebuild the index from scratch by replaying all events.
    
    Args:
        indexer: Indexer instance to rebuild
        market_ids: Optional list of market IDs to rebuild (None = all)
    
    Returns:
        Rebuild statistics
    """
    start_time = datetime.now()
    stats = {
        'markets_rebuilt': 0,
        'trades_processed': 0,
        'vault_updates_processed': 0,
        'events_processed': 0,
    }
    
    # Clear existing state
    indexer.markets.clear()
    indexer.events_buffer.clear()
    indexer._trades_cache.clear()
    indexer._vault_cache.clear()
    indexer._orderbook_cache.clear()
    
    # Simulate replaying events (in production, this would query on-chain)
    sample_markets = market_ids or indexer.get_all_markets()
    
    for market_id in sample_markets:
        # Generate sample event history
        for i in range(100):  # 100 events per market
            event = {
                'event_type': 'trade' if i % 3 != 0 else 'vault_update',
                'market_id': market_id,
                'price': 0.5 + (i % 20) * 0.01,
                'volume': 100 + i * 10,
                'balance': 1000 + i * 50,
                'outcome': 'yes' if i % 2 == 0 else 'no',
                'timestamp': (datetime.now() - timedelta(hours=100-i)).isoformat(),
            }
            
            block = 1000 + i
            indexer.events_buffer.setdefault(market_id, []).append((block, event))
            
            if event['event_type'] == 'trade':
                indexer._trades_cache.setdefault(market_id, []).append(parse_trade_event(event))
                stats['trades_processed'] += 1
            else:
                indexer._vault_cache.setdefault(market_id, {})
                indexer._vault_cache[market_id][event['outcome']] = event.get('balance', 0)
                stats['vault_updates_processed'] += 1
            
            stats['events_processed'] += 1
        
        stats['markets_rebuilt'] += 1
    
    elapsed = (datetime.now() - start_time).total_seconds()
    stats['elapsed_seconds'] = elapsed
    
    print(f"\nIndex rebuild complete:")
    print(f"  Markets rebuilt: {stats['markets_rebuilt']}")
    print(f"  Events processed: {stats['events_processed']}")
    print(f"  Trades: {stats['trades_processed']}")
    print(f"  Vault updates: {stats['vault_updates_processed']}")
    print(f"  Time: {elapsed:.2f}s")
    
    return stats


if __name__ == '__main__':
    import argparse
    
    parser = argparse.ArgumentParser(description='Cairox Indexer')
    parser.add_argument('--network', default='goerli', help='Starknet network')
    parser.add_argument('--contract', help='Oracle contract address')
    parser.add_argument('--start-block', type=int, help='Start block number')
    parser.add_argument('--proof-dir', help='Proof output directory')
    parser.add_argument('--market', action='append', help='Market ID to track')
    parser.add_argument('--rebuild', action='store_true', help='Rebuild index from scratch')
    parser.add_argument('--daily', action='store_true', help='Run daily commitment')
    
    args = parser.parse_args()
    
    # Initialize indexer
    indexer = CairoxIndexer(
        network=args.network,
        contract_address=args.contract,
        start_block=args.start_block,
        proof_directory=args.proof_dir,
    )
    
    if args.rebuild:
        asyncio.run(rebuild_index(indexer, args.market))
    elif args.daily:
        daily = DailyIndexer(indexer)
        markets = args.market or indexer.get_all_markets()
        for market in markets:
            asyncio.run(daily.run_daily_commitment(market))
    else:
        # Start continuous event listening
        print("Starting Cairox Indexer...")
        print(f"Network: {args.network}")
        print(f"Markets: {args.market or 'all'}")
        asyncio.run(indexer.subscribe_to_events(args.market))
