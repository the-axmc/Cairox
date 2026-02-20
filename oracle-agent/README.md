# Cairox Oracle Agent

This directory contains the oracle agent that fetches external data for Cairox market resolution.

## Overview

The oracle agent connects to the growthepie API and provides data for:
- User activity metrics (DAU, WAU, MAU)
- Transaction volumes and counts
- DeFi metrics (TVL, DEX volume)
- Token performance data

## Architecture

```
oracle-agent/
├── src/
│   ├── data_fetcher.ts    # API data fetching
│   ├── oracle.ts          # Oracle contract interaction
│   └── resolver.ts        # Resolution logic
├── config/
│   └── markets.json       # Market configuration
└── package.json
```

## Setup

```bash
cd oracle-agent
npm install
cp .env.example .env
# Configure your environment variables
npm run build
npm start
```

## Data Sources

- growthepie API - Ecosystem analytics
- CoinGecko API - Token prices
- Dune Analytics - On-chain metrics (optional)

## Deployment

The oracle agent can be deployed as:
- A Docker container
- A serverless function
- A long-running service

## Security

- Rate limiting on external APIs
- Data validation before submission
- Cache invalidation for stale data
