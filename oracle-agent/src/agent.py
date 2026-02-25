"""
Oracle Agent v0 for Cairox

Main oracle agent that orchestrates market resolution using Growthepie data.
"""

import argparse
import json
import os
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Dict, Optional

# Add src directory to path
sys.path.insert(0, str(Path(__file__).parent))

from growthepie import GrowthepieClient, GrowthepieError
from resolver import MarketResolver, MarketOutcome, MarketSpec, ResolutionRule, AggregationMethod


class OracleAgent:
    """
    Oracle Agent that resolves markets using Growthepie data and
    proposals outcomes to the OptimisticOracle on Starknet.
    """
    
    def __init__(
        self,
        growthepie_url: Optional[str] = None,
        local_cache_dir: Optional[str] = None,
        network: str = "goerli",
    ):
        """
        Initialize the OracleAgent.
        
        Args:
            growthepie_url: Base URL for Growthepie API
            local_cache_dir: Directory to cache resolved data
            network: Starknet network to use
        """
        self.growthepie = GrowthepieClient(base_url=growthepie_url)
        
        # Try to get Growthepie URL from environment
        if growthepie_url is None:
            growthepie_url = os.getenv("GROWTH_API_URL", "https://api.growthepie.com")
            self.growthepie = GrowthepieClient(base_url=growthepie_url)
        
        self.resolver = MarketResolver(local_cache_dir=local_cache_dir)
        self.starknet = None
        self.proposer_bond = int(os.getenv("ORACLE_PROPOSER_BOND", "100"))
        self.require_signed = os.getenv("ORACLE_REQUIRE_SIGNED", "1") == "1"
        self.verifier_address = os.getenv("RESOLUTION_VERIFIER_ADDRESS")
        self.commit_market_state = os.getenv("ORACLE_COMMIT_MARKET_STATE", "0") == "1"
        self.commit_mode = os.getenv("ORACLE_COMMIT_MODE", "data_hash").lower()
        self.wait_commitment = os.getenv("ORACLE_WAIT_COMMITMENT", "1") == "1"
        self.debug = os.getenv("ORACLE_DEBUG", "0") == "1"
        self.wait_finalize = os.getenv("ORACLE_WAIT_FINALIZE", "1") == "1"
        self.finalize_timeout = int(os.getenv("ORACLE_FINALIZE_TIMEOUT", "600"))
        self.finalize_poll = int(os.getenv("ORACLE_FINALIZE_POLL", "15"))
        self.market_address_env = os.getenv("ORACLE_MARKET_ADDRESS")
        self.market_address_map = os.getenv("ORACLE_MARKET_ADDRESSES_JSON")
        
        # Initialize Starknet interface.
        # If account creds are available, use starknet.py. Otherwise fall back to starkli.
        from contracts import StarknetInterface
        if os.getenv("STARKNET_ACCOUNT_ADDRESS") and os.getenv("STARKNET_PRIVATE_KEY"):
            self.starknet = StarknetInterface(
                network=network,
                account_address=os.getenv("STARKNET_ACCOUNT_ADDRESS"),
                private_key=os.getenv("STARKNET_PRIVATE_KEY"),
            )
        else:
            self.starknet = StarknetInterface(network=network)
        
        # Load market specifications
        self._market_specs = self._load_market_specs()
    
    def _load_market_specs(self) -> Dict[str, Dict]:
        """
        Load market specifications from repo-root/specs/markets.json.
        
        Returns:
            Dictionary of market_id -> market specification
        """
        # Canonical specs live at repo-root/specs/markets.json
        specs_path = Path(__file__).resolve().parents[2] / "specs" / "markets.json"
        
        if specs_path.exists():
            try:
                with open(specs_path, 'r') as f:
                    specs = json.load(f)
                
                # Convert to dict keyed by market_id
                if isinstance(specs, list):
                    return {s.get("market_id", i): s for i, s in enumerate(specs)}
                return specs
            except (json.JSONDecodeError, IOError) as e:
                print(f"Warning: Failed to load market specs: {e}")
                return {}
        
        return {}
    
    def get_market_spec(self, market_id: str) -> Optional[Dict]:
        """
        Get market specification by ID.
        
        Args:
            market_id: Market identifier
        
        Returns:
            Market specification dictionary or None
        """
        return self._market_specs.get(market_id)
    
    def fetch_market_data(self, market_id: str) -> Optional[Dict]:
        """
        Fetch market data from Growthepie.
        
        Args:
            market_id: Market identifier
        
        Returns:
            Raw market data dictionary or None on error
        """
        spec = self.get_market_spec(market_id)
        if spec is None:
            print(f"Error: No market specification found for {market_id}")
            return None
        
        endpoint = spec.get("endpoint")
        if endpoint is None:
            print(f"Error: No endpoint specified for market {market_id}")
            return None
        
        # Health check before fetching
        if not self.growthepie.health_check():
            print("Error: Growthepie API is not reachable")
            return None
        
        try:
            # If the endpoint is already a full API path, fetch directly.
            if isinstance(endpoint, str) and endpoint.startswith("/"):
                raw = self.growthepie.fetch_market_data(endpoint)
            else:
                raw = self.growthepie.fetch_by_market_id(endpoint)
            return self.growthepie.normalize_export_response(raw)
        except GrowthepieError as e:
            print(f"Error fetching market data: {e}")
            return None
    
    def compute_outcome(self, market_id: str, data: Dict) -> Optional[MarketOutcome]:
        """
        Compute the market outcome from resolved data.
        
        Args:
            market_id: Market identifier
            data: Market data from Growthepie
        
        Returns:
            MarketOutcome or None if resolution fails
        """
        spec = self.get_market_spec(market_id)
        if spec is None:
            print(f"Error: No market specification found for {market_id}")
            return None
        
        try:
            return self.resolver.resolve_from_dict(spec, data)
        except (ValueError, KeyError) as e:
            print(f"Error resolving market: {e}")
            return None
    
    def propose_outcome(self, outcome: MarketOutcome) -> Optional[Dict]:
        """
        Propose an outcome to the OptimisticOracle.
        
        Args:
            outcome: MarketOutcome to propose
        
        Returns:
            Transaction result dictionary or None if proposal fails
        """
        if self.starknet is None:
            print("Error: Starknet interface not initialized")
            return None

        if self.require_signed and self.starknet.account is None:
            print("Error: Signed submissions required, but no account is configured")
            print("Set STARKNET_ACCOUNT_ADDRESS and STARKLI_ACCOUNT/STARKLI_KEYSTORE,")
            print("or set ORACLE_REQUIRE_SIGNED=0 to allow starkli fallback.")
            return None
        
        if self.starknet.oracle_address is None:
            print("Error: Oracle contract address not set")
            print("Set ORACLE_CONTRACT_ADDRESS environment variable")
            return None

        if self.commit_market_state:
            if self.commit_mode == "market_state":
                commit_result = self.commit_state_auto(outcome.market_id)
            else:
                commit_result = self.commit_data_hash(outcome)
            if not commit_result or not commit_result.get("success"):
                print(f"Error: Failed to commit market state: {commit_result}")
                return None
            if self.wait_commitment and commit_result.get("transaction_hash"):
                wait = self.starknet.wait_for_tx(commit_result.get("transaction_hash"))
                if not wait.get("success"):
                    print(f"Error: Commitment tx not confirmed: {wait}")
                    return None
        
        proof = None
        data_hash = outcome.data_hash
        data_uri = outcome.data_uri
        requires_proof = False
        if self.verifier_address:
            requires_proof = self.starknet.requires_proof(outcome.market_id)
        if requires_proof:
            proof_bundle = self.resolver.build_proof(
                outcome=outcome.outcome,
                raw_value=outcome.raw_value,
                data_hash=outcome.data_hash,
                market_id=outcome.market_id
            )
            proof = proof_bundle.proof

            if proof_bundle.public_inputs:
                public_inputs = proof_bundle.public_inputs
                if len(public_inputs) < 3:
                    raise RuntimeError("ZK public inputs must include market_id, outcome, data_hash")

                expected_market = self.resolver._market_id_to_felt(outcome.market_id)
                expected_outcome = self.resolver._outcome_to_felt(outcome.outcome)
                if public_inputs[0] != expected_market:
                    raise RuntimeError("ZK public input market_id does not match outcome.market_id")
                if public_inputs[1] != expected_outcome:
                    raise RuntimeError("ZK public input outcome does not match computed outcome")

                zk_data_hash = int(public_inputs[2])
                if isinstance(data_hash, str):
                    data_hash_felt = int(data_hash, 16) if data_hash.startswith("0x") else int(data_hash)
                else:
                    data_hash_felt = int(data_hash)

                if zk_data_hash != data_hash_felt:
                    if outcome.raw_data is None:
                        raise RuntimeError("ZK data_hash mismatch and raw_data is missing")
                    data_hash = hex(zk_data_hash)
                    data_uri = self.resolver._store_data(outcome.raw_data, outcome.market_id, data_hash)

        return self.starknet.propose(
            market_id=outcome.market_id,
            outcome=outcome.outcome,
            data_hash=data_hash,
            data_uri=data_uri,
            bond=self.proposer_bond,
            proof=proof,
        )

    def commit_state_from_env(self, market_id: str) -> Optional[Dict]:
        """
        Commit signed market state hash using env-provided state.
        Requires ORACLE_MARKET_STATE_JSON and ORACLE_SIGNER_PRIVATE_KEY.
        """
        if self.starknet is None:
            print("Error: Starknet interface not initialized")
            return None
        if self.starknet.data_commitment_address is None:
            print("Error: DataCommitment address not set (DATA_COMMITMENT_ADDRESS)")
            return None

        raw = os.getenv("ORACLE_MARKET_STATE_JSON")
        if not raw:
            print("Error: ORACLE_MARKET_STATE_JSON not set")
            return None
        try:
            state = json.loads(raw)
        except json.JSONDecodeError as e:
            print(f"Error: Invalid ORACLE_MARKET_STATE_JSON: {e}")
            return None

        required = ["yes_supply", "no_supply", "b_param", "price_yes", "price_no", "timestamp"]
        missing = [k for k in required if k not in state]
        if missing:
            print(f"Error: Missing market state fields: {missing}")
            return None

        state_hash = self.resolver.compute_market_state_hash(
            yes_supply=state["yes_supply"],
            no_supply=state["no_supply"],
            b_param=state["b_param"],
            price_yes=state["price_yes"],
            price_no=state["price_no"],
            timestamp=state["timestamp"],
        )
        sig_r, sig_s = self.resolver.sign_market_state(market_id, state_hash)
        return self.starknet.set_commitment_signed(market_id, state_hash, sig_r, sig_s)

    def commit_data_hash(self, outcome: MarketOutcome) -> Optional[Dict]:
        """
        Commit the resolved data hash (required by OptimisticOracle).
        Uses the DataCommitment contract signature flow.
        """
        if self.starknet is None:
            print("Error: Starknet interface not initialized")
            return None
        if self.starknet.data_commitment_address is None:
            print("Error: DataCommitment address not set (DATA_COMMITMENT_ADDRESS)")
            return None
        data_hash = outcome.data_hash
        try:
            data_hash_felt = int(data_hash, 16) if isinstance(data_hash, str) else int(data_hash)
        except Exception:
            print(f"Error: Invalid data_hash: {data_hash}")
            return None
        if self.debug:
            print(f"Committing data_hash felt: {hex(data_hash_felt)}")
        sig_r, sig_s = self.resolver.sign_market_state(outcome.market_id, data_hash_felt)
        result = self.starknet.set_commitment_signed(outcome.market_id, data_hash_felt, sig_r, sig_s)
        if self.debug:
            committed = self.starknet.get_commitment(outcome.market_id)
            if committed is not None:
                print(f"On-chain commitment: {hex(committed)}")
        return result

    def commit_state_from_market(self, market_id: str, market_address: str) -> Optional[Dict]:
        """
        Fetch market state on-chain and commit signed state hash.
        """
        if self.starknet is None:
            print("Error: Starknet interface not initialized")
            return None
        state = self.starknet.get_market_state(market_address)
        if not state.get("success"):
            print(f"Error: Failed to fetch market state: {state}")
            return None
        timestamp = int(datetime.utcnow().timestamp())
        state_hash = self.resolver.compute_market_state_hash(
            yes_supply=state["yes_supply"],
            no_supply=state["no_supply"],
            b_param=state["b_param"],
            price_yes=state["price_yes"],
            price_no=state["price_no"],
            timestamp=timestamp,
        )
        sig_r, sig_s = self.resolver.sign_market_state(market_id, state_hash)
        return self.starknet.set_commitment_signed(market_id, state_hash, sig_r, sig_s)

    def commit_state_auto(self, market_id: str) -> Optional[Dict]:
        """
        Auto-commit state from market contract if address is available,
        otherwise fall back to ORACLE_MARKET_STATE_JSON.
        """
        market_address = None
        # 1) Spec-level address
        spec = self.get_market_spec(market_id)
        if spec and isinstance(spec, dict) and spec.get("market_address"):
            market_address = spec.get("market_address")
        # 2) Env mapping JSON
        if market_address is None and self.market_address_map:
            try:
                mapping = json.loads(self.market_address_map)
                market_address = mapping.get(market_id)
            except json.JSONDecodeError:
                market_address = None
        # 3) Env single address
        if market_address is None and self.market_address_env:
            market_address = self.market_address_env

        if market_address:
            return self.commit_state_from_market(market_id, market_address)
        return self.commit_state_from_env(market_id)
    
    def run_market(self, market_id: str, propose: bool = True, finalize: bool = False) -> Optional[MarketOutcome]:
        """
        Run a single market resolution.
        
        Args:
            market_id: Market identifier
            propose: Whether to propose the outcome on-chain
            finalize: Whether to finalize the market
        
        Returns:
            MarketOutcome if successful, None otherwise
        """
        print(f"[{datetime.utcnow().isoformat()}] Starting market resolution: {market_id}")
        
        # Safety check 1: Verify Growthepie is reachable
        print("Checking Growthepie API health...")
        if not self.growthepie.health_check():
            print("❌ Safety check failed: Growthepie API is not reachable")
            print("Will NOT propose outcome due to API unavailability")
            return None
        
        # Step 1: Fetch data
        print(f"Fetching data for market {market_id}...")
        data = self.fetch_market_data(market_id)
        if data is None:
            print("❌ Failed to fetch market data")
            print("Will NOT propose outcome due to missing data")
            return None
        
        print(f"✓ Fetched data ({len(json.dumps(data))} bytes)")
        
        # Step 2: Compute outcome
        print("Computing outcome...")
        outcome = self.compute_outcome(market_id, data)
        if outcome is None:
            print("❌ Failed to compute outcome")
            print("Will NOT propose outcome due to resolution failure")
            return None
        
        print(f"✓ Computed outcome: {outcome.outcome}")
        print(f"  Raw value: {outcome.raw_value}")
        print(f"  Data hash: {outcome.data_hash}")
        print(f"  Data URI: {outcome.data_uri}")
        
        # Safety check 2: Validate data is not null/missing
        if outcome.raw_value is None:
            print("❌ Safety check failed: Raw value is null")
            print("Will NOT propose outcome due to invalid data")
            return None
        
        # Safety check 3: Verify outcome is computable (already computed successfully)
        if outcome.outcome not in ["YES", "NO"] and outcome.outcome != "unknown":
            # Valid categorical outcome
            pass
        elif outcome.outcome not in ["YES", "NO"]:
            print(f"❌ Safety check failed: Invalid outcome '{outcome.outcome}'")
            return None
        
        # Step 3: Propose outcome (if requested and not finalize mode)
        if propose and not finalize:
            print("Proposing outcome to OptimisticOracle...")
            result = self.propose_outcome(outcome)
            if result is None:
                print("❌ Failed to propose outcome")
                return None
            
            if result.get("success"):
                print(f"✓ Proposed outcome")
                print(f"  Transaction hash: {result.get('transaction_hash', 'N/A')}")
                print(f"  Status: {result.get('status', 'N/A')}")
            else:
                print(f"❌ Proposal failed: {result.get('error', 'Unknown error')}")
                return None
        
        # Step 4: Finalize (if requested)
        if finalize:
            print("Finalizing market...")
            if self.starknet is None:
                print("❌ Finalize failed: Starknet interface not initialized")
                return None
            if self.wait_finalize:
                result = self.finalize_with_wait(market_id)
            else:
                result = self.starknet.finalize(market_id)
            if not result or not result.get("success"):
                print(f"❌ Finalize failed: {result.get('error') if result else 'Unknown error'}")
            else:
                print("✓ Finalized market")
                print(f"  Transaction hash: {result.get('transaction_hash')}")
                print(f"  Status: {result.get('status')}")
        
        return outcome

    def finalize_with_wait(self, market_id: str) -> Optional[Dict]:
        """
        Attempt to finalize, waiting out dispute window if needed.
        """
        end = time.time() + self.finalize_timeout
        while True:
            result = self.starknet.finalize(market_id)
            if result and result.get("success"):
                tx_hash = result.get("transaction_hash")
                if tx_hash:
                    wait = self.starknet.wait_for_tx(tx_hash)
                    if not wait.get("success"):
                        return {"success": False, "error": f"Finalize tx not confirmed: {wait}"}
                return result

            err = (result or {}).get("error", "")
            if "Dispute window" in err and time.time() < end:
                time.sleep(self.finalize_poll)
                continue
            return result

    def is_market_due_for_resolution(self, market_id: str) -> bool:
        """
        Check if a market is due for resolution based on cutoff time.

        Args:
            market_id: Market identifier

        Returns:
            True if market is due for resolution
        """
        spec = self.get_market_spec(market_id)
        if spec is None:
            return False

        cutoff_str = spec.get("cutoff")
        if not cutoff_str:
            return False

        try:
            from datetime import datetime, timezone
            cutoff = datetime.fromisoformat(cutoff_str.replace("Z", "+00:00"))
            now = datetime.now(timezone.utc)
            return now >= cutoff
        except (ValueError, TypeError):
            return False

    def fetch_growthepie_data(self, endpoint: str) -> Optional[Dict]:
        """
        Fetch data from Growthepie API.

        Args:
            endpoint: API endpoint path (e.g., "/defi/daa")

        Returns:
           Raw data dictionary or None if API call fails
        """
        try:
            return self.growthepie.fetch_market_data(endpoint)
        except GrowthepieError as e:
            print(f"Error fetching Growthepie data from {endpoint}: {e}")
            return None

    def resolve_deterministically(self, market_id: str, endpoint: str, threshold: float, metric_name: str) -> Optional[Dict]:
        """
        Resolve a market deterministically using Growthepie API.

        Args:
            market_id: Market identifier
            endpoint: Growthepie endpoint (e.g., "/defi/daa")
            threshold: Threshold value for YES/NO classification
            metric_name: Name of the metric for logging

        Returns:
            Resolution result dict with outcome, data, or None on error
        """
        # Fetch data
        data = self.fetch_growthepie_data(endpoint)
        if data is None:
            print(f"❌ No data available for {metric_name} from Growthepie API")
            return None

        # Compute outcome deterministically
        try:
            value = data.get("value", data.get("v", data.get("daa", data.get("txcount", data.get("total_fees", 0)))))
            outcome = "YES" if float(value) >= threshold else "NO"

            return {
                "outcome": outcome,
                "value": value,
                "data": data,
                "endpoint": endpoint,
            }
        except (TypeError, ValueError) as e:
            print(f"❌ Error computing deterministic outcome: {e}")
            return None

    def run_deterministic_markets(self, propose: bool = True) -> Dict[str, Dict]:
        """
        Run deterministic markets (binary threshold markets).

        This method:
        1. Checks which markets are due for resolution
        2. Fetches Growthepie data
        3. Computes outcome deterministically
        4. Proposes to oracle if valid data exists
        5. Handles void conditions (no data = no proposal)

        Args:
            propose: Whether to propose outcomes on-chain

        Returns:
            Dictionary of market_id -> resolution result
        """
        results = {}

        for market_id, spec in self._market_specs.items():
            market_type = spec.get("type")
            if market_type != "binary_threshold":
                continue

            if not self.is_market_due_for_resolution(market_id):
                print(f"[{datetime.utcnow().isoformat()}] Skipping {market_id}: not due yet")
                continue

            print(f"[{datetime.utcnow().isoformat()}] Processing deterministic market: {market_id}")

            endpoint = spec.get("endpoint", "")
            threshold = spec.get("threshold", 0)

            # Determine metric name from endpoint
            metric_name = "unknown"
            if "/daa" in endpoint:
                metric_name = "DAA"
            elif "/txcount" in endpoint:
                metric_name = "txcount"
            elif "/fees" in endpoint:
                metric_name = "fees"

            result = self.resolve_deterministically(market_id, endpoint, threshold, metric_name)

            if result is None:
                # Void condition: no data available
                print(f"⚠️  Void condition triggered for {market_id}: no data available")
                results[market_id] = {
                    "status": "voided",
                    "reason": "no_data_available",
                    "market_id": market_id,
                }
                continue

            # Propose outcome
            if propose:
                outcome_outcome = self.compute_outcome(market_id, result["data"])
                if outcome_outcome:
                    outcome_outcome.outcome = result["outcome"]
                    proposal_result = self.propose_outcome(outcome_outcome)
                    if proposal_result:
                        results[market_id] = {
                            "status": "proposed",
                            "outcome": result["outcome"],
                            "value": result["value"],
                            "proposal_result": proposal_result,
                        }
                    else:
                        results[market_id] = {
                            "status": "proposal_failed",
                            "outcome": result["outcome"],
                            "reason": "proposal failed",
                        }
                else:
                    results[market_id] = {
                        "status": "error",
                        "reason": "compute_outcome failed",
                    }
            else:
                results[market_id] = {
                    "status": "computed_only",
                    "outcome": result["outcome"],
                    "value": result["value"],
                }

        return results

    def run_all(self, propose: bool = True) -> Dict[str, MarketOutcome]:
        """
        Run all markets from the specifications.
        
        Args:
            propose: Whether to propose outcomes on-chain
        
        Returns:
            Dictionary of market_id -> MarketOutcome
        """
        results = {}
        
        for market_id, spec in self._market_specs.items():
            outcome = self.run_market(market_id, propose=propose)
            if outcome is not None:
                results[market_id] = outcome
        
        return results


def main():
    """Main entry point for the CLI."""
    parser = argparse.ArgumentParser(
        description="Oracle Agent v0 for Cairox - Resolves growthepie-based markets"
    )
    parser.add_argument(
        "market_id",
        nargs="?",
        help="Market ID to resolve (optional, runs all if not specified)"
    )
    parser.add_argument(
        "--propose",
        action="store_true",
        default=True,
        help="Propose the outcome on-chain (default: True)"
    )
    parser.add_argument(
        "--finalize",
        action="store_true",
        help="Finalize the market instead of proposing"
    )
    parser.add_argument(
        "--network",
        default="goerli",
        choices=["goerli", "mainnet", "sepolia", "localhost"],
        help="Starknet network to use (default: goerli)"
    )
    parser.add_argument(
        "--spec-file",
        type=str,
        help="Path to market specifications file"
    )
    
    args = parser.parse_args()
    
    # Initialize agent
    agent = OracleAgent(network=args.network)
    
    # Override spec file if provided
    if args.spec_file:
        path = Path(args.spec_file)
        if path.exists():
            with open(path, 'r') as f:
                try:
                    specs = json.load(f)
                    if isinstance(specs, list):
                        agent._market_specs = {s.get("market_id", i): s for i, s in enumerate(specs)}
                    else:
                        agent._market_specs = specs
                except json.JSONDecodeError:
                    print(f"Warning: Failed to parse spec file: {args.spec_file}")
    
    # Run market(s)
    if args.market_id:
        outcome = agent.run_market(args.market_id, propose=args.propose, finalize=args.finalize)
        if outcome:
            # Print JSON output for downstream processing
            print("\n--- RESULT ---")
            print(json.dumps(outcome.to_dict(), indent=2))
            return 0
        return 1
    else:
        results = agent.run_all(propose=args.propose)
        print(f"\nProcessed {len(results)} markets")
        return 0


if __name__ == "__main__":
    sys.exit(main())
