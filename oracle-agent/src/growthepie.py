"""
Growthepie API Client

This module provides a client to fetch market data from Growthepie's API.
"""

import json
import os
import requests
from typing import Optional, Dict, Any


class GrowthepieClient:
    """Client for interacting with Growthepie's API."""
    
    def __init__(self, base_url: Optional[str] = None, timeout: int = 30):
        """
        Initialize the Growthepie client.
        
        Args:
            base_url: Base URL for the Growthepie API. Defaults to https://api.growthepie.com
            timeout: Request timeout in seconds
        """
        self.base_url = base_url or "https://api.growthepie.com"
        self.timeout = timeout
        self.session = requests.Session()
    
    def fetch_market_data(self, endpoint: str) -> Dict[str, Any]:
        """
        Fetch market data from Growthepie API.
        
        Args:
            endpoint: The API endpoint path (e.g., "/v1/markets/btc-tvl")
        
        Returns:
            Parsed JSON response as dictionary
        
        Raises:
            GrowthepieError: If the API request fails
        """
        url = f"{self.base_url}{endpoint}"
        
        try:
            response = self.session.get(url, timeout=self.timeout)
            response.raise_for_status()
            return response.json()
        except requests.exceptions.Timeout:
            raise GrowthepieError(f"Request to {url} timed out after {self.timeout}s")
        except requests.exceptions.ConnectionError as e:
            raise GrowthepieError(f"Connection error when accessing {url}: {e}")
        except requests.exceptions.HTTPError as e:
            raise GrowthepieError(f"HTTP error when accessing {url}: {e}")
        except json.JSONDecodeError as e:
            raise GrowthepieError(f"Failed to parse JSON response from {url}: {e}")
    
    def fetch_by_market_id(self, market_id: str) -> Dict[str, Any]:
        """
        Fetch data for a specific market by ID.
        
        Args:
            market_id: The market identifier
        
        Returns:
            Market data dictionary
        """
        # Try various endpoint patterns
        endpoints = [
            f"/v1/markets/{market_id}",
            f"/v1/metrics/{market_id}",
            f"/api/v1/markets/{market_id}",
            f"/api/v1/metrics/{market_id}",
        ]
        
        errors = []
        for endpoint in endpoints:
            try:
                return self.fetch_market_data(endpoint)
            except GrowthepieError as e:
                errors.append(str(e))
                continue
        
        raise GrowthepieError(f"All endpoint attempts failed for market {market_id}. Errors: {errors}")
    
    def health_check(self) -> bool:
        """
        Check if the Growthepie API is reachable.
        
        Returns:
            True if the API is reachable, False otherwise
        """
        try:
            response = self.session.get(
                f"{self.base_url}/health",
                timeout=self.timeout
            )
            return response.status_code == 200
        except Exception:
            return False


class GrowthepieError(Exception):
    """Custom exception for Growthepie API errors."""
    pass
