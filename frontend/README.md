# Cairox Frontend

A Next.js frontend for the Cairox prediction market platform on Starknet.

## Features

- **Wallet Connection**: Connect to Starknet wallets (Argent X, Braavos, etc.)
- **Market Display**: View available YES/NO prediction markets
- **Trading**: Buy YES or NO tokens on ecosystem analytics questions
- **Balance Tracking**: View your wallet balance and positions

## Contract Addresses (Placeholders)

```solidity
LaunchConfig:    0x0000000000000000000000000000000000000000000000000000000000000001
Oracle:         0x0000000000000000000000000000000000000000000000000000000000000002
Market:         0x0000000000000000000000000000000000000000000000000000000000000003
CollateralVault: 0x0000000000000000000000000000000000000000000000000000000000000004
```

> **Note**: Replace these with actual deployed contract addresses when ready.

## Getting Started

### Prerequisites

- Node.js 18+
- npm or yarn

### Installation

```bash
cd frontend
npm install
```

### Development

```bash
npm run dev
```

Open [http://localhost:3000](http://localhost:3000) with your browser.

### Build

```bash
npm run build
```

## Architecture

```
frontend/
├── app/
│   ├── globals.css     # Global styles
│   ├── layout.tsx      # Root layout
│   └── page.tsx        # Main page component
├── package.json
├── tsconfig.json
└── next.config.js
```

## Integration with Starknet

This frontend uses mock data for demonstration. To integrate with actual Starknet contracts:

1. Install starknet.js: `npm install starknet get-starknet`
2. Update `CONTRACT_ADDRESSES` with deployed addresses
3. Replace mock wallet connection with `getStarknet()`
4. Replace trade execution with actual contract calls

## Tech Stack

- **Framework**: Next.js 14
- **Language**: TypeScript
- **Styling**: CSS Modules / Global CSS
- **Blockchain**: Starknet (via starknet.js)

## License

MIT
