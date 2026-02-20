# Cairox Indexer

This directory contains the indexer for tracking Cairox events and market data.

## Overview

The indexer:
- Tracks market creation events
- Records trades and liquidity provisioning
- Maintains historical market data
- Provides an API for frontend queries

## Structure

```
indexer/
├── src/
│   ├── indexer.ts         # Main indexer logic
│   ├── db/                # Database schemas
│   └── api/               # GraphQL/REST API
├── migrations/            # Database migrations
└── package.json
```

## Setup

```bash
cd indexer
npm install
npm run migrate
npm start
```

## API Endpoints

- `/api/v1/markets` - List all markets
- `/api/v1/markets/{id}` - Get specific market
- `/api/v1/trades` - Get trades
- `/api/v1/stats` - Market statistics

## Data Retention

- Full history for active markets
- Archival for expired markets
