'use client';

import { useState, useEffect, useCallback } from 'react';

// Types
interface Market {
  id: string;
  question: string;
  category: string;
  yesPrice: number;
  noPrice: number;
  volume: number;
  endsAt: string;
  resolved: boolean;
}

interface EcosystemStats {
  daw: number;
  dawChange: number;
  transactions: number;
  transactionsChange: number;
  contracts: number;
  contractsChange: number;
  lastUpdated: string;
}

interface WalletState {
  address: string | null;
  connected: boolean;
  balance: string;
}

interface Notification {
  type: 'success' | 'error';
  message: string;
}

// Placeholder contract addresses (to be replaced when deployed)
const CONTRACT_ADDRESSES = {
  launchConfig: '0x0000000000000000000000000000000000000000000000000000000000000001',
  oracle: '0x0000000000000000000000000000000000000000000000000000000000000002',
  market: '0x0000000000000000000000000000000000000000000000000000000000000003',
  collateralVault: '0x0000000000000000000000000000000000000000000000000000000000000004',
};

// Growthepie API base URL
const GROWTHEPIE_API = 'https://api.growthepie.com/v1';

// Mock ecosystem data (used when API is unavailable)
const MOCK_ECOSYSTEM_STATS: EcosystemStats = {
  daw: 85432,
  dawChange: 12.5,
  transactions: 4521000,
  transactionsChange: 8.3,
  contracts: 892,
  contractsChange: 15.2,
  lastUpdated: new Date().toISOString(),
};

// Mock data for demonstration - in production this would come from the contracts
const MOCK_MARKETS: Market[] = [
  {
    id: '1',
    question: 'Will Starknet exceed 100K Daily Active Wallets this week?',
    category: 'DAW',
    yesPrice: 0.65,
    noPrice: 0.35,
    volume: 45000,
    endsAt: '2026-02-28',
    resolved: false,
  },
  {
    id: '2',
    question: 'Will total Starknet transactions exceed 5M this week?',
    category: 'Transactions',
    yesPrice: 0.42,
    noPrice: 0.58,
    volume: 32000,
    endsAt: '2026-02-28',
    resolved: false,
  },
  {
    id: '3',
    question: 'Will new contracts deployed exceed 1000 this week?',
    category: 'Contracts',
    yesPrice: 0.78,
    noPrice: 0.22,
    volume: 28000,
    endsAt: '2026-03-07',
    resolved: false,
  },
  {
    id: '4',
    question: 'Will Cairo 1.0 adoption reach 50 major projects?',
    category: 'Adoption',
    yesPrice: 0.55,
    noPrice: 0.45,
    volume: 15000,
    endsAt: '2026-03-14',
    resolved: false,
  },
  {
    id: '5',
    question: 'Will ETH strk staking participation exceed 50%?',
    category: 'Staking',
    yesPrice: 0.30,
    noPrice: 0.70,
    volume: 85000,
    endsAt: '2026-03-01',
    resolved: false,
  },
];

export default function Home() {
  const [wallet, setWallet] = useState<WalletState>({
    address: null,
    connected: false,
    balance: '0',
  });
  const [markets, setMarkets] = useState<Market[]>(MOCK_MARKETS);
  const [ecosystemStats, setEcosystemStats] = useState<EcosystemStats>(MOCK_ECOSYSTEM_STATS);
  const [dataStatus, setDataStatus] = useState<'loading' | 'live' | 'demo'>('loading');
  const [notification, setNotification] = useState<Notification | null>(null);
  const [tradeAmounts, setTradeAmounts] = useState<{ [key: string]: string }>({});
  const [loading, setLoading] = useState(false);

  // Fetch ecosystem stats from Growthepie API
  const fetchEcosystemStats = useCallback(async () => {
    setDataStatus('loading');
    try {
      // Try to fetch from all three endpoints in parallel
      const [dawRes, txRes, contractsRes] = await Promise.allSettled([
        fetch(`${GROWTHEPIE_API}/daily-active-wallets`),
        fetch(`${GROWTHEPIE_API}/transactions`),
        fetch(`${GROWTHEPIE_API}/contracts`),
      ]);

      let hasRealData = false;
      let newStats = { ...MOCK_ECOSYSTEM_STATS };

      // Process DAW data
      if (dawRes.status === 'fulfilled' && dawRes.value.ok) {
        const dawData = await dawRes.value.json();
        if (dawData.data && dawData.data.length > 0) {
          const latest = dawData.data[dawData.data.length - 1];
          newStats.daw = latest.daw || latest.value || 0;
          newStats.dawChange = calculateChange(dawData.data);
          hasRealData = true;
        }
      }

      // Process transactions data
      if (txRes.status === 'fulfilled' && txRes.value.ok) {
        const txData = await txRes.value.json();
        if (txData.data && txData.data.length > 0) {
          const latest = txData.data[txData.data.length - 1];
          newStats.transactions = latest.transactions || latest.value || 0;
          newStats.transactionsChange = calculateChange(txData.data);
          hasRealData = true;
        }
      }

      // Process contracts data
      if (contractsRes.status === 'fulfilled' && contractsRes.value.ok) {
        const contractsData = await contractsRes.value.json();
        if (contractsData.data && contractsData.data.length > 0) {
          const latest = contractsData.data[contractsData.data.length - 1];
          newStats.contracts = latest.contracts || latest.value || 0;
          newStats.contractsChange = calculateChange(contractsData.data);
          hasRealData = true;
        }
      }

      newStats.lastUpdated = new Date().toISOString();
      setEcosystemStats(newStats);
      setDataStatus(hasRealData ? 'live' : 'demo');
    } catch (error) {
      console.warn('Failed to fetch Growthepie data:', error);
      setDataStatus('demo');
    }
  }, []);

  // Helper to calculate percentage change from data array
  const calculateChange = (data: any[]): number => {
    if (!data || data.length < 2) return 0;
    const latest = data[data.length - 1];
    const previous = data[data.length - 2];
    const latestVal = latest.daw || latest.transactions || latest.contracts || latest.value || 0;
    const prevVal = previous.daw || previous.transactions || previous.contracts || previous.value || 0;
    if (prevVal === 0) return 0;
    return ((latestVal - prevVal) / prevVal) * 100;
  };

  // Fetch ecosystem stats on mount
  useEffect(() => {
    fetchEcosystemStats();
    // Refresh stats every 5 minutes
    const interval = setInterval(fetchEcosystemStats, 5 * 60 * 1000);
    return () => clearInterval(interval);
  }, [fetchEcosystemStats]);

  // Show notification helper
  const showNotification = useCallback((type: 'success' | 'error', message: string) => {
    setNotification({ type, message });
    setTimeout(() => setNotification(null), 3000);
  }, []);

  // Connect wallet - simulates Starknet wallet connection
  const connectWallet = useCallback(async () => {
    setLoading(true);
    try {
      // Simulate blockchain transaction delay
      await new Promise((resolve) => setTimeout(resolve, 1500));
      
      // In production, this would use getStarknet() or @starknet-io/cairo-js
      // For demo, we simulate a connected wallet
      const mockAddress = '0x7a250d5630B4cF539739dF2C5dAcb4c659F2488000000000000000000000000';
      
      setWallet({
        address: mockAddress,
        connected: true,
        balance: '1000.00', // Mock balance in STRK
      });
      
      showNotification('success', 'Wallet connected successfully!');
    } catch (error) {
      showNotification('error', 'Failed to connect wallet');
    } finally {
      setLoading(false);
    }
  }, [showNotification]);

  // Disconnect wallet
  const disconnectWallet = useCallback(() => {
    setWallet({
      address: null,
      connected: false,
      balance: '0',
    });
    showNotification('success', 'Wallet disconnected');
  }, [showNotification]);

  // Execute trade (buy/sell)
  const executeTrade = useCallback(async (marketId: string, outcome: 'yes' | 'no') => {
    if (!wallet.connected) {
      showNotification('error', 'Please connect your wallet first');
      return;
    }

    const amount = parseFloat(tradeAmounts[marketId] || '0');
    if (amount <= 0 || isNaN(amount)) {
      showNotification('error', 'Please enter a valid amount');
      return;
    }

    if (amount > parseFloat(wallet.balance)) {
      showNotification('error', 'Insufficient balance');
      return;
    }

    setLoading(true);
    try {
      // Simulate blockchain transaction delay
      await new Promise((resolve) => setTimeout(resolve, 1500));
      
      // In production, this would call the smart contract
      // const marketContract = new Contract(..., CONTRACT_ADDRESSES.market, provider);
      // await marketContract.buy(marketId, outcome === 'yes' ? 0 : 1, amount);
      
      // Update mock balance
      setWallet((prev) => ({
        ...prev,
        balance: (parseFloat(prev.balance) - amount).toFixed(2),
      }));
      
      // Update market volume
      setMarkets((prev) =>
        prev.map((m) =>
          m.id === marketId
            ? { ...m, volume: m.volume + amount }
            : m
        )
      );
      
      showNotification(
        'success',
        `Successfully bought ${amount} STRK of ${outcome.toUpperCase()}!`
      );
      
      // Clear input
      setTradeAmounts((prev) => ({ ...prev, [marketId]: '' }));
    } catch (error) {
      showNotification('error', 'Transaction failed');
    } finally {
      setLoading(false);
    }
  }, [wallet, tradeAmounts, showNotification]);

  // Handle input change
  const handleAmountChange = useCallback((marketId: string, value: string) => {
    // Only allow numbers and decimal point
    if (!/^\d*\.?\d*$/.test(value)) return;
    setTradeAmounts((prev) => ({ ...prev, [marketId]: value }));
  }, []);

  // Format address for display
  const formatAddress = (address: string) => {
    return `${address.slice(0, 6)}...${address.slice(-4)}`;
  };

  // Format date
  const formatDate = (dateStr: string) => {
    return new Date(dateStr).toLocaleDateString('en-US', {
      month: 'short',
      day: 'numeric',
      year: 'numeric',
    });
  };

  // Format volume
  const formatVolume = (volume: number) => {
    if (volume >= 1000) {
      return `$${(volume / 1000).toFixed(1)}K`;
    }
    return `$${volume}`;
  };

  return (
    <main>
      {/* Header */}
      <header className="header">
        <div className="container header-content">
          <div className="logo">Cairox</div>
          <button
            className={`connect-btn ${wallet.connected ? 'connected' : ''}`}
            onClick={wallet.connected ? disconnectWallet : connectWallet}
            disabled={loading}
          >
            {loading
              ? 'Connecting...'
              : wallet.connected
              ? formatAddress(wallet.address!)
              : 'Connect Wallet'}
          </button>
        </div>
      </header>

      {/* Main Content */}
      <div className="container main">
        <h1 className="page-title">Ecosystem Prediction Markets</h1>
        <p className="page-subtitle">
          Trade YES/NO tokens on Starknet ecosystem metrics and analytics
        </p>

        {/* Wallet Info */}
        {wallet.connected && (
          <div className="wallet-info">
            <h3>Your Wallet</h3>
            <div className="wallet-address">{wallet.address}</div>
            <div className="balance-row" style={{ marginTop: '1rem' }}>
              <span className="balance-label">STRK Balance</span>
              <span className="balance-value">{wallet.balance} STRK</span>
            </div>
            <div className="balance-row">
              <span className="balance-label">Markets</span>
              <span className="balance-value">{markets.length}</span>
            </div>
          </div>
        )}

        {/* Stats */}
        <div className="stats-grid">
          <div className="stat-card">
            <div className="stat-label">Active Markets</div>
            <div className="stat-value">{markets.filter((m) => !m.resolved).length}</div>
          </div>
          <div className="stat-card">
            <div className="stat-label">Total Volume</div>
            <div className="stat-value">
              ${(markets.reduce((sum, m) => sum + m.volume, 0) / 1000).toFixed(1)}K
            </div>
          </div>
          <div className="stat-card">
            <div className="stat-label">Avg. YES Price</div>
            <div className="stat-value yes">
              {(markets.reduce((sum, m) => sum + m.yesPrice, 0) / markets.length).toFixed(2)}
            </div>
          </div>
          <div className="stat-card">
            <div className="stat-label">Your Balance</div>
            <div className="stat-value">{wallet.connected ? wallet.balance : '--'}</div>
          </div>
        </div>

        {/* Ecosystem Stats from Growthepie */}
        <section className="markets-section">
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '1rem' }}>
            <h2 className="section-title">📈 Starknet Ecosystem Stats</h2>
            <span style={{ 
              fontSize: '0.75rem', 
              padding: '0.25rem 0.75rem', 
              borderRadius: '9999px',
              backgroundColor: dataStatus === 'live' ? '#22c55e20' : dataStatus === 'demo' ? '#f59e0b20' : '#3b82f620',
              color: dataStatus === 'live' ? '#22c55e' : dataStatus === 'demo' ? '#f59e0b' : '#3b82f6',
            }}>
              {dataStatus === 'loading' ? '⏳ Loading...' : dataStatus === 'live' ? '🟢 Live Data' : '⚠️ Demo Values'}
            </span>
          </div>
          
          {dataStatus === 'demo' && (
            <div style={{ 
              marginBottom: '1rem', 
              padding: '0.75rem 1rem', 
              backgroundColor: '#f59e0b10', 
              border: '1px solid #f59e0b30', 
              borderRadius: '0.5rem',
              fontSize: '0.875rem',
              color: '#f59e0b',
            }}>
              ℹ️ Real-time data unavailable - showing demo values
            </div>
          )}

          <div className="stats-grid" style={{ gridTemplateColumns: 'repeat(3, 1fr)' }}>
            <div className="stat-card">
              <div className="stat-label">Daily Active Wallets</div>
              <div className="stat-value">{ecosystemStats.daw.toLocaleString()}</div>
              <div style={{ 
                fontSize: '0.75rem', 
                color: ecosystemStats.dawChange >= 0 ? '#22c55e' : '#ef4444',
                marginTop: '0.25rem'
              }}>
                {ecosystemStats.dawChange >= 0 ? '↑' : '↓'} {Math.abs(ecosystemStats.dawChange).toFixed(1)}% (24h)
              </div>
            </div>
            <div className="stat-card">
              <div className="stat-label">Total Transactions</div>
              <div className="stat-value">{(ecosystemStats.transactions / 1000000).toFixed(2)}M</div>
              <div style={{ 
                fontSize: '0.75rem', 
                color: ecosystemStats.transactionsChange >= 0 ? '#22c55e' : '#ef4444',
                marginTop: '0.25rem'
              }}>
                {ecosystemStats.transactionsChange >= 0 ? '↑' : '↓'} {Math.abs(ecosystemStats.transactionsChange).toFixed(1)}% (24h)
              </div>
            </div>
            <div className="stat-card">
              <div className="stat-label">Active Contracts</div>
              <div className="stat-value">{ecosystemStats.contracts.toLocaleString()}</div>
              <div style={{ 
                fontSize: '0.75rem', 
                color: ecosystemStats.contractsChange >= 0 ? '#22c55e' : '#ef4444',
                marginTop: '0.25rem'
              }}>
                {ecosystemStats.contractsChange >= 0 ? '↑' : '↓'} {Math.abs(ecosystemStats.contractsChange).toFixed(1)}% (24h)
              </div>
            </div>
          </div>
          <div style={{ fontSize: '0.75rem', color: '#71717a', marginTop: '0.5rem', textAlign: 'right' }}>
            Last updated: {new Date(ecosystemStats.lastUpdated).toLocaleTimeString()}
          </div>
        </section>

        {/* Markets */}
        <section className="markets-section">
          <h2 className="section-title">📊 Available Markets</h2>
          
          {markets.length === 0 ? (
            <div className="empty-state">
              <h3>No markets available</h3>
              <p>Check back later for new prediction markets</p>
            </div>
          ) : (
            <div className="markets-grid">
              {markets.map((market) => (
                <div key={market.id} className="market-card">
                  <div className="market-question">{market.question}</div>
                  <div className="market-meta">
                    <span>📁 {market.category}</span>
                    <span>📈 {formatVolume(market.volume)} volume</span>
                    <span>⏰ Ends {formatDate(market.endsAt)}</span>
                  </div>
                  
                  <div className="market-odds">
                    <div className="odds-card">
                      <div className="odds-label">YES</div>
                      <div className="odds-value yes">{market.yesPrice.toFixed(2)}</div>
                    </div>
                    <div className="odds-card">
                      <div className="odds-label">NO</div>
                      <div className="odds-value no">{market.noPrice.toFixed(2)}</div>
                    </div>
                  </div>
                  
                  <div className="trade-form">
                    <input
                      type="text"
                      className="trade-input"
                      placeholder="Amount (STRK)"
                      value={tradeAmounts[market.id] || ''}
                      onChange={(e) => handleAmountChange(market.id, e.target.value)}
                      disabled={loading || market.resolved}
                    />
                    <button
                      className="trade-btn buy-yes"
                      onClick={() => executeTrade(market.id, 'yes')}
                      disabled={loading || market.resolved || !wallet.connected}
                    >
                      Buy YES
                    </button>
                    <button
                      className="trade-btn buy-no"
                      onClick={() => executeTrade(market.id, 'no')}
                      disabled={loading || market.resolved || !wallet.connected}
                    >
                      Buy NO
                    </button>
                  </div>
                </div>
              ))}
            </div>
          )}
        </section>

        {/* Contract Info */}
        <section className="markets-section" style={{ marginTop: '3rem' }}>
          <h2 className="section-title">⚙️ Contract Addresses</h2>
          <div className="market-card">
            <div className="balance-row">
              <span className="balance-label">LaunchConfig</span>
              <span className="balance-value" style={{ fontFamily: 'monospace', fontSize: '0.75rem' }}>
                {CONTRACT_ADDRESSES.launchConfig}
              </span>
            </div>
            <div className="balance-row">
              <span className="balance-label">Oracle</span>
              <span className="balance-value" style={{ fontFamily: 'monospace', fontSize: '0.75rem' }}>
                {CONTRACT_ADDRESSES.oracle}
              </span>
            </div>
            <div className="balance-row">
              <span className="balance-label">Market</span>
              <span className="balance-value" style={{ fontFamily: 'monospace', fontSize: '0.75rem' }}>
                {CONTRACT_ADDRESSES.market}
              </span>
            </div>
            <div className="balance-row">
              <span className="balance-label">CollateralVault</span>
              <span className="balance-value" style={{ fontFamily: 'monospace', fontSize: '0.75rem' }}>
                {CONTRACT_ADDRESSES.collateralVault}
              </span>
            </div>
            <p style={{ marginTop: '1rem', color: '#71717a', fontSize: '0.875rem' }}>
              * These are placeholder addresses. Replace with actual deployed contract addresses when ready.
            </p>
          </div>
        </section>
      </div>

      {/* Notification */}
      {notification && (
        <div className={`notification ${notification.type}`}>
          {notification.message}
        </div>
      )}
    </main>
  );
}
