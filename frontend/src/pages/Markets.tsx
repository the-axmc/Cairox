import { useEffect, useMemo, useState } from "react";

const API_BASE = import.meta.env.VITE_MIDDLEWARE_URL || "http://localhost:8787";
const USDC_ADDRESS =
  import.meta.env.VITE_USDC_ADDRESS ||
  "0x0512feac6339ff7889822cb5aa2a86c848e9d392bb0e3e237c008674feed8343";
const VAULT_ADDRESS =
  import.meta.env.VITE_COLLATERAL_VAULT_ADDRESS ||
  "0x0731ab31c87880ee690833641dfef7f284dadc5210b0d04104baef41dad2c38d";

type MarketItem = {
  id: string;
  template_id?: string;
  address: string;
  market_id: string;
  slug?: string;
  title: string;
  status: string;
  volume?: string;
  yes_price?: string;
  no_price?: string;
  yes_supply?: string;
  no_supply?: string;
  source?: string;
  endpoint?: string;
  cutoff?: string;
  description?: string;
  resolution_rule?: string;
  aggregation?: string;
  outcomes?: string[];
  threshold_config?: {
    threshold_value?: number;
    threshold_operator?: string;
    threshold_unit?: string;
  } | null;
  settlement?: {
    status?: string;
    outcome?: string;
    settled_at?: string;
  } | null;
  schedule?: {
    timezone?: string;
    trading_date?: string;
    opens_at?: string;
    closes_at?: string;
    next_reopen_at?: string;
    next_close_at?: string;
  } | null;
  snapshot?: {
    value?: number;
    threshold_value?: number;
    captured_at?: string;
    source_date?: string;
    source_endpoint?: string;
    stale?: boolean;
    stale_reason?: string;
  } | null;
};

type WalletCall = {
  contractAddress: string;
  entrypoint: string;
  calldata: string[];
};

const formatUnits = (raw: string, decimals = 6) => {
  try {
    const value = BigInt(raw || "0");
    const factor = 10n ** BigInt(decimals);
    const whole = value / factor;
    const frac = value % factor;
    if (frac === 0n) return whole.toString();
    const fracStr = frac.toString().padStart(decimals, "0").replace(/0+$/, "");
    return `${whole.toString()}.${fracStr}`;
  } catch {
    return raw || "0";
  }
};

const formatPricePct = (raw?: string) => {
  if (!raw) return "-";
  try {
    const value = BigInt(raw);
    const pct = (value * 10000n) / 1000000000000000000n;
    const whole = pct / 100n;
    const frac = pct % 100n;
    return `${whole.toString()}.${frac.toString().padStart(2, "0")}%`;
  } catch {
    return "-";
  }
};

const priceToNumberPct = (raw?: string) => {
  if (!raw) return 50;
  try {
    const value = BigInt(raw);
    const pct = Number((value * 10000n) / 1000000000000000000n) / 100;
    if (Number.isFinite(pct)) {
      return Math.max(0, Math.min(100, pct));
    }
  } catch {
    // ignore
  }
  return 50;
};

const parseBaseAmount = (raw: string, decimals = 6) => {
  const trimmed = raw.trim();
  if (!trimmed) return 0n;
  if (!/^[0-9]+(\.[0-9]+)?$/.test(trimmed)) {
    throw new Error("Amount must be a positive number.");
  }
  if (!trimmed.includes(".")) return BigInt(trimmed) * 10n ** BigInt(decimals);
  const [whole, frac = ""] = trimmed.split(".");
  if (frac.length > decimals) {
    throw new Error(`Amount supports up to ${decimals} decimals.`);
  }
  const fracPadded = (frac + "0".repeat(decimals)).slice(0, decimals);
  return BigInt(whole || "0") * 10n ** BigInt(decimals) + BigInt(fracPadded || "0");
};

const toU256 = (value: bigint) => {
  const low = value & ((1n << 128n) - 1n);
  const high = value >> 128n;
  return { low, high };
};

const pathInfo = () => {
  const path = typeof window !== "undefined" ? window.location.pathname : "/markets";
  const normalized = path.replace(/\/+$/, "") || "/";
  if (normalized === "/markets") return { isDetail: false, token: "" };
  if (normalized.startsWith("/markets/")) {
    return {
      isDetail: true,
      token: decodeURIComponent(normalized.slice("/markets/".length))
    };
  }
  return { isDetail: false, token: "" };
};

export default function Markets() {
  const [{ isDetail, token }] = useState(pathInfo());
  const [wallet, setWallet] = useState("");
  const [connectedWallet, setConnectedWallet] = useState("");
  const [balance, setBalance] = useState("0");
  const [vaultBalance, setVaultBalance] = useState("0");
  const [marketBalance, setMarketBalance] = useState("0");
  const [balanceWarning, setBalanceWarning] = useState("");

  const [marketItems, setMarketItems] = useState<MarketItem[]>([]);
  const [market, setMarket] = useState<MarketItem | null>(null);
  const [marketStatus, setMarketStatus] = useState<"idle" | "loading" | "error">("idle");
  const [marketError, setMarketError] = useState("");

  const [tradeAmount, setTradeAmount] = useState("");
  const [tradeAction, setTradeAction] = useState<"buy" | "sell">("buy");
  const [tradeOutcome, setTradeOutcome] = useState<"yes" | "no">("yes");
  const [tradeStatus, setTradeStatus] = useState<"idle" | "submitting" | "success" | "error">("idle");
  const [tradeError, setTradeError] = useState("");
  const [tradeTx, setTradeTx] = useState("");

  const [depositAmount, setDepositAmount] = useState("");
  const [depositStatus, setDepositStatus] = useState<"idle" | "submitting" | "success" | "error">("idle");
  const [depositError, setDepositError] = useState("");
  const [depositTxHash, setDepositTxHash] = useState("");
  const [mintTxHash, setMintTxHash] = useState("");

  const [withdrawAmount, setWithdrawAmount] = useState("");
  const [withdrawRecipient, setWithdrawRecipient] = useState("");
  const [withdrawStatus, setWithdrawStatus] = useState<"idle" | "submitting" | "success" | "error">("idle");
  const [withdrawError, setWithdrawError] = useState("");
  const [withdrawTxHash, setWithdrawTxHash] = useState("");

  const syncConnectedWallet = async () => {
    const starknet = (window as any).starknet;
    if (!starknet) return "";
    try {
      if (typeof starknet.enable === "function") {
        await starknet.enable();
      }
      if (starknet.selectedAddress) {
        const selected = starknet.selectedAddress;
        setConnectedWallet(selected);
        setWallet(selected);
        localStorage.setItem("cairox_wallet", selected);
        return selected;
      }
    } catch {
      // ignore
    }
    return "";
  };

  const invokeWallet = async (calls: WalletCall[]) => {
    if (!calls.length) {
      throw new Error("No wallet call to execute.");
    }
    const starknet = (window as any).starknet;
    if (!starknet) {
      throw new Error("No Starknet wallet found. Install Argent or Braavos.");
    }
    await syncConnectedWallet();
    if (starknet.account?.execute) {
      await starknet.account.execute(calls);
      return;
    }
    if (starknet.request && calls.length === 1) {
      const call = calls[0];
      await starknet.request({
        method: "starknet_addInvokeTransaction",
        params: [
          {
            sender_address: starknet.selectedAddress,
            calldata: call.calldata,
            entry_point_selector: call.entrypoint,
            contract_address: call.contractAddress
          }
        ]
      });
      return;
    }
    throw new Error("Wallet API does not support this operation.");
  };

  const getApproveCall = (amountRaw: string): WalletCall | null => {
    if (!USDC_ADDRESS || !VAULT_ADDRESS) return null;
    try {
      const base = parseBaseAmount(amountRaw);
      if (base <= 0n) return null;
      const { low, high } = toU256(base);
      return {
        contractAddress: USDC_ADDRESS,
        entrypoint: "approve",
        calldata: [VAULT_ADDRESS, low.toString(), high.toString()]
      };
    } catch {
      return null;
    }
  };

  const getDepositCall = (amountRaw: string): WalletCall | null => {
    if (!VAULT_ADDRESS) return null;
    try {
      const base = parseBaseAmount(amountRaw);
      if (base <= 0n) return null;
      const { low, high } = toU256(base);
      return {
        contractAddress: VAULT_ADDRESS,
        entrypoint: "deposit",
        calldata: [low.toString(), high.toString()]
      };
    } catch {
      return null;
    }
  };

  const refreshBalances = async (walletAddress: string, marketId?: string) => {
    if (!walletAddress) return;
    try {
      const [balanceRes, vaultRes, marketRes] = await Promise.all([
        fetch(`${API_BASE}/api/balance?wallet=${encodeURIComponent(walletAddress)}`),
        fetch(`${API_BASE}/api/vault_balance?wallet=${encodeURIComponent(walletAddress)}`),
        marketId
          ? fetch(
              `${API_BASE}/api/balance?wallet=${encodeURIComponent(walletAddress)}&market_id=${encodeURIComponent(
                marketId
              )}`
            )
          : Promise.resolve(null)
      ]);
      const balanceData = await balanceRes.json().catch(() => ({}));
      const vaultData = await vaultRes.json().catch(() => ({}));
      const marketData = marketRes ? await marketRes.json().catch(() => ({})) : null;

      if (balanceRes.ok) {
        setBalance(balanceData?.tradeable_balance?.toString?.() ?? balanceData?.balance?.toString?.() ?? "0");
        setBalanceWarning(balanceData?.warning || "");
      }
      if (vaultRes.ok) {
        setVaultBalance(vaultData?.balance?.toString?.() ?? "0");
      }
      if (marketRes?.ok) {
        setMarketBalance(marketData?.tradeable_balance?.toString?.() ?? marketData?.balance?.toString?.() ?? "0");
      } else if (!marketId) {
        setMarketBalance("0");
      }
    } catch {
      // ignore periodic refresh errors
    }
  };

  useEffect(() => {
    const stored = localStorage.getItem("cairox_wallet") || "";
    if (stored) {
      setWallet(stored);
    }
    syncConnectedWallet();
  }, []);

  useEffect(() => {
    let cancelled = false;
    let initial = true;
    const endpoint = isDetail ? `/api/markets/${encodeURIComponent(token)}` : "/api/markets";

    const loadMarkets = () => {
      if (initial && !cancelled) {
        setMarketStatus("loading");
        setMarketError("");
      }
      fetch(`${API_BASE}${endpoint}`)
        .then((res) => res.json().then((data) => ({ ok: res.ok, data })))
        .then(({ ok, data }) => {
          if (cancelled) return;
          if (!ok) {
            throw new Error(data?.error || "Failed to load markets.");
          }
          if (isDetail) {
            setMarket(data?.market || null);
            setMarketItems([]);
          } else {
            setMarketItems(Array.isArray(data?.markets) ? data.markets : []);
            setMarket(null);
          }
          setMarketStatus("idle");
          setMarketError("");
        })
        .catch((err) => {
          if (cancelled) return;
          setMarketStatus("error");
          setMarketError(err instanceof Error ? err.message : "Failed to load markets.");
        })
        .finally(() => {
          initial = false;
        });
    };

    loadMarkets();
    const interval = window.setInterval(loadMarkets, 60000);
    return () => {
      cancelled = true;
      window.clearInterval(interval);
    };
  }, [isDetail, token]);

  useEffect(() => {
    if (!wallet) return;
    refreshBalances(wallet, market?.market_id);
  }, [wallet, market?.market_id]);

  const handleTrade = async () => {
    if (!wallet) {
      setTradeStatus("error");
      setTradeError("Connect wallet first.");
      return;
    }
    if (!market) {
      setTradeStatus("error");
      setTradeError("Market not loaded.");
      return;
    }
    if ((market.status || "").toLowerCase().includes("closed")) {
      setTradeStatus("error");
      setTradeError("Market is currently closed (23:59-00:01 Europe/Berlin).");
      return;
    }
    if (!tradeAmount.trim()) {
      setTradeStatus("error");
      setTradeError("Enter CAIROX amount.");
      return;
    }
    try {
      if (parseBaseAmount(tradeAmount) <= 0n) {
        throw new Error("Enter a valid CAIROX amount.");
      }
    } catch (err) {
      setTradeStatus("error");
      setTradeError(err instanceof Error ? err.message : "Invalid amount.");
      return;
    }

    setTradeStatus("submitting");
    setTradeError("");
    setTradeTx("");
    try {
      const response = await fetch(`${API_BASE}/api/trade`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          wallet,
          market_id: market.market_id,
          outcome: tradeOutcome,
          amount: tradeAmount,
          action: tradeAction
        })
      });
      const data = await response.json().catch(() => ({}));
      if (!response.ok) {
        throw new Error(data?.error || "Trade failed.");
      }
      setTradeStatus("success");
      if (data?.tx_hash) {
        setTradeTx(data.tx_hash);
      }
      await refreshBalances(wallet, market.market_id);
    } catch (err) {
      const message = err instanceof Error ? err.message : "Trade failed.";
      setTradeStatus("error");
      setTradeError(message);
    }
  };

  const handleDepositAndMint = async () => {
    if (!wallet) {
      setDepositStatus("error");
      setDepositError("Connect wallet first.");
      return;
    }
    if (!market) {
      setDepositStatus("error");
      setDepositError("Market not loaded.");
      return;
    }
    if ((market.status || "").toLowerCase().includes("closed")) {
      setDepositStatus("error");
      setDepositError("Market is currently closed (23:59-00:01 Europe/Berlin).");
      return;
    }

    let baseAmount = 0n;
    try {
      baseAmount = parseBaseAmount(depositAmount);
      if (baseAmount <= 0n) {
        throw new Error("Enter a valid USDC amount.");
      }
    } catch (err) {
      setDepositStatus("error");
      setDepositError(err instanceof Error ? err.message : "Invalid amount.");
      return;
    }

    setDepositStatus("submitting");
    setDepositError("");
    setDepositTxHash("");
    setMintTxHash("");

    try {
      const vaultResponse = await fetch(
        `${API_BASE}/api/vault_balance?wallet=${encodeURIComponent(wallet)}`
      );
      const vaultData = await vaultResponse.json().catch(() => ({}));
      if (!vaultResponse.ok) {
        throw new Error(vaultData?.error || "Failed to fetch vault balance.");
      }

      const currentVault = BigInt(vaultData?.balance || "0");
      const skipWalletFunding = Boolean(vaultData?.skip_wallet_deposit);
      if (!skipWalletFunding && currentVault < baseAmount) {
        const approveCall = getApproveCall(depositAmount);
        const depositCall = getDepositCall(depositAmount);
        if (!approveCall || !depositCall) {
          throw new Error("Invalid USDC amount for vault funding.");
        }
        await invokeWallet([approveCall, depositCall]);
      }

      const response = await fetch(`${API_BASE}/api/deposit`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          wallet,
          market_id: market.market_id,
          amount: depositAmount
        })
      });
      const data = await response.json().catch(() => ({}));
      if (!response.ok) {
        throw new Error(data?.error || "Deposit & mint failed.");
      }

      if (data?.tx_hash) {
        setDepositTxHash(data.tx_hash);
      }
      if (data?.mint_tx) {
        setMintTxHash(data.mint_tx);
      }
      setDepositStatus("success");
      await refreshBalances(wallet, market.market_id);
    } catch (err) {
      const message = err instanceof Error ? err.message : "Deposit & mint failed.";
      setDepositStatus("error");
      setDepositError(message);
    }
  };

  const handleWithdraw = async () => {
    if (!wallet) {
      setWithdrawStatus("error");
      setWithdrawError("Connect wallet first.");
      return;
    }
    if (!market) {
      setWithdrawStatus("error");
      setWithdrawError("Market not loaded.");
      return;
    }
    if (!withdrawAmount.trim()) {
      setWithdrawStatus("error");
      setWithdrawError("Enter USDC amount.");
      return;
    }

    let recipient = (withdrawRecipient || wallet).trim();
    if (!recipient.startsWith("0x")) {
      setWithdrawStatus("error");
      setWithdrawError("Recipient must be a Starknet address.");
      return;
    }

    try {
      if (parseBaseAmount(withdrawAmount) <= 0n) {
        throw new Error("Enter a valid USDC amount.");
      }
    } catch (err) {
      setWithdrawStatus("error");
      setWithdrawError(err instanceof Error ? err.message : "Invalid amount.");
      return;
    }

    setWithdrawStatus("submitting");
    setWithdrawError("");
    setWithdrawTxHash("");

    try {
      const response = await fetch(`${API_BASE}/api/withdraw`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          wallet,
          market_id: market.market_id,
          amount: withdrawAmount,
          recipient
        })
      });
      const data = await response.json().catch(() => ({}));
      if (!response.ok) {
        throw new Error(data?.error || "Withdraw failed.");
      }
      if (data?.tx_hash) {
        setWithdrawTxHash(data.tx_hash);
      }
      setWithdrawStatus("success");
      await refreshBalances(wallet, market.market_id);
    } catch (err) {
      const message = err instanceof Error ? err.message : "Withdraw failed.";
      setWithdrawStatus("error");
      setWithdrawError(message);
    }
  };

  const isSettled = useMemo(() => {
    const status = (market?.status || market?.settlement?.status || "").toLowerCase();
    return (
      Boolean(market?.settlement?.outcome) ||
      status.includes("settled") ||
      status.includes("resolved") ||
      status.includes("final")
    );
  }, [market?.status, market?.settlement?.outcome, market?.settlement?.status]);

  const isWindowClosed = useMemo(() => {
    const status = (market?.status || "").toLowerCase();
    return status.includes("closed");
  }, [market?.status]);

  const tradeDisabled = isSettled || isWindowClosed;

  return (
    <main className="access">
      <section className="access__hero">
        <div className="hero__eyebrow">Markets</div>
        {isDetail ? <h1>{market?.title || "Market"}</h1> : <h1>Available markets</h1>}
        <p>
          Select a market, open the detailed page, then deposit USDC, mint CAIROX, buy/sell YES or
          NO, and withdraw to USDC when exiting.
        </p>
        <div className="hero__actions">
          <button className="btn btn--ghost" type="button" onClick={syncConnectedWallet}>
            Connect wallet
          </button>
          <a className="btn btn--primary" href="/access">
            Access account
          </a>
          {isDetail && (
            <a className="btn btn--ghost" href="/markets">
              Back to markets
            </a>
          )}
        </div>
        {wallet && (
          <div className="access__status">
            Wallet: {wallet.slice(0, 10)}...{wallet.slice(-6)} | CAIROX: {formatUnits(balance)} | Vault:
            {" "}
            {formatUnits(vaultBalance)} USDC
          </div>
        )}
        {!wallet && (
          <div className="access__status">
            No wallet connected. Connect wallet to place bets and withdraw.
          </div>
        )}
        {balanceWarning && <div className="access__status error">{balanceWarning}</div>}
      </section>

      {!isDetail && (
        <section id="markets" className="markets">
          <div className="section__head">
            <h2>Open Markets</h2>
            <p>
              Click a market card to open full details, prices, liquidity, and trade controls.
            </p>
          </div>

          {marketStatus === "loading" && <div className="access__status">Loading markets...</div>}
          {marketStatus === "error" && <div className="access__status error">{marketError}</div>}

          <div className="market__grid">
            {marketItems.map((item) => (
              <a
                key={item.id}
                className="market__card market__card--link"
                href={`/markets/${encodeURIComponent(item.slug || item.id)}`}
              >
                <div className="market__status">
                  <span>{item.status || "Open"}</span>
                  <span>{item.volume ? `${formatUnits(item.volume)} CAIROX` : "-"}</span>
                </div>
                <h3>{item.title}</h3>
                <div className="market__bars">
                  <div className="bar bar--yes" style={{ width: `${priceToNumberPct(item.yes_price)}%` }}>
                    YES {formatPricePct(item.yes_price)}
                  </div>
                  <div className="bar bar--no" style={{ width: `${priceToNumberPct(item.no_price)}%` }}>
                    NO {formatPricePct(item.no_price)}
                  </div>
                </div>
                {item.settlement?.outcome && (
                  <div className="access__status">Result: {item.settlement.outcome}</div>
                )}
                <div className="access__status">Open market</div>
              </a>
            ))}
          </div>
        </section>
      )}

      {isDetail && (
        <section className="markets market-detail">
          {marketStatus === "loading" && <div className="access__status">Loading market...</div>}
          {marketStatus === "error" && <div className="access__status error">{marketError}</div>}
          {!market && marketStatus === "idle" && (
            <div className="access__status error">Market not found.</div>
          )}
          {market && (
            <>
              <div className="market__card market-detail__summary">
                <div className="market__status">
                  <span>{market.status || "Open"}</span>
                  <span>{market.volume ? `${formatUnits(market.volume)} CAIROX` : "-"}</span>
                </div>
                <h2>{market.title}</h2>
                <p>{market.description || "Prediction market powered by growthepie data."}</p>
                <div className="market__details">
                  <span>Source: {market.source || "growthepie"}</span>
                  <span>Endpoint: {market.endpoint || "-"}</span>
                  <span>Cutoff: {market.cutoff || "-"}</span>
                  <span>Rule: {market.resolution_rule || "-"}</span>
                  <span>Aggregation: {market.aggregation || "-"}</span>
                  <span>Timezone: {market.schedule?.timezone || "-"}</span>
                  <span>Trading date: {market.schedule?.trading_date || "-"}</span>
                  <span>Opens: {market.schedule?.opens_at || "-"}</span>
                  <span>Closes: {market.schedule?.closes_at || "-"}</span>
                  <span>Next reopen: {market.schedule?.next_reopen_at || "-"}</span>
                  <span>YES price: {formatPricePct(market.yes_price)}</span>
                  <span>NO price: {formatPricePct(market.no_price)}</span>
                  <span>YES supply: {formatUnits(market.yes_supply || "0")}</span>
                  <span>NO supply: {formatUnits(market.no_supply || "0")}</span>
                  <span>Your market CAIROX: {formatUnits(marketBalance)}</span>
                </div>
                {market.threshold_config && (
                  <div className="access__status">
                    Threshold: {market.threshold_config.threshold_operator || ""}
                    {" "}
                    {market.threshold_config.threshold_value ?? "-"}
                    {" "}
                    {market.threshold_config.threshold_unit || ""}
                  </div>
                )}
                {market.snapshot && (
                  <div className="access__status">
                    Snapshot: {market.snapshot.threshold_value ?? market.snapshot.value ?? "-"}
                    {" "}
                    at {market.snapshot.captured_at || "-"}
                    {market.snapshot.stale ? " (using latest cached value)" : ""}
                  </div>
                )}
                {market.settlement && (
                  <div className="access__status">
                    Settlement: {market.settlement.status || "Settled"}
                    {market.settlement.outcome ? ` | Result: ${market.settlement.outcome}` : ""}
                    {market.settlement.settled_at ? ` | At: ${market.settlement.settled_at}` : ""}
                  </div>
                )}
              </div>

              <div className="market__card market-detail__actions">
                <h3>Buy / Sell</h3>
                <div className="market__bet-row">
                  <button
                    className={`btn btn--ghost ${tradeAction === "buy" ? "active" : ""}`}
                    type="button"
                    onClick={() => setTradeAction("buy")}
                    disabled={tradeDisabled}
                  >
                    Buy
                  </button>
                  <button
                    className={`btn btn--ghost ${tradeAction === "sell" ? "active" : ""}`}
                    type="button"
                    onClick={() => setTradeAction("sell")}
                    disabled={tradeDisabled}
                  >
                    Sell
                  </button>
                  <button
                    className={`btn btn--ghost ${tradeOutcome === "yes" ? "active" : ""}`}
                    type="button"
                    onClick={() => setTradeOutcome("yes")}
                    disabled={tradeDisabled}
                  >
                    YES
                  </button>
                  <button
                    className={`btn btn--ghost ${tradeOutcome === "no" ? "active" : ""}`}
                    type="button"
                    onClick={() => setTradeOutcome("no")}
                    disabled={tradeDisabled}
                  >
                    NO
                  </button>
                  <input
                    type="text"
                    value={tradeAmount}
                    onChange={(event) => setTradeAmount(event.target.value)}
                    placeholder="CAIROX amount"
                    disabled={tradeDisabled}
                  />
                  <button
                    className="btn btn--primary"
                    type="button"
                    onClick={handleTrade}
                    disabled={tradeStatus === "submitting" || tradeDisabled}
                  >
                    {tradeStatus === "submitting" ? "Submitting..." : "Place order"}
                  </button>
                </div>
                {isSettled && (
                  <div className="access__status">Market settled. Trading is disabled.</div>
                )}
                {isWindowClosed && !isSettled && (
                  <div className="access__status">
                    Market is in daily close window (23:59-00:01 Europe/Berlin). Reopens at{" "}
                    {market.schedule?.next_reopen_at || "00:01 Europe/Berlin"}.
                  </div>
                )}
                {tradeStatus === "success" && <div className="access__status">Trade submitted.</div>}
                {tradeTx && (
                  <div className="access__status">
                    Trade tx: {tradeTx.slice(0, 10)}...{tradeTx.slice(-6)}
                  </div>
                )}
                {tradeError && <div className="access__status error">{tradeError}</div>}
              </div>

              <div className="market__card market-detail__actions">
                <h3>Deposit & Mint</h3>
                <div className="market__bet-row market__bet-row--simple">
                  <input
                    type="text"
                    value={depositAmount}
                    onChange={(event) => setDepositAmount(event.target.value)}
                    placeholder="USDC amount"
                  />
                  <button
                    className="btn btn--primary"
                    type="button"
                    onClick={handleDepositAndMint}
                    disabled={depositStatus === "submitting" || isWindowClosed}
                  >
                    {depositStatus === "submitting" ? "Processing..." : "Deposit USDC & Mint CAIROX"}
                  </button>
                </div>
                <div className="access__status">
                  Optimized flow: if vault balance is low, wallet auto-runs approve+deposit before mint.
                </div>
                {isWindowClosed && (
                  <div className="access__status">
                    Deposit & mint is paused during the daily close window.
                  </div>
                )}
                {depositStatus === "success" && (
                  <div className="access__status">Deposit and mint submitted.</div>
                )}
                {depositTxHash && (
                  <div className="access__status">
                    Shielded tx: {depositTxHash.slice(0, 10)}...{depositTxHash.slice(-6)}
                  </div>
                )}
                {mintTxHash && (
                  <div className="access__status">
                    Mint tx: {mintTxHash.slice(0, 10)}...{mintTxHash.slice(-6)}
                  </div>
                )}
                {depositError && <div className="access__status error">{depositError}</div>}
              </div>

              <div className="market__card market-detail__actions">
                <h3>Withdraw to USDC</h3>
                <div className="market__bet-row market__bet-row--simple">
                  <input
                    type="text"
                    value={withdrawAmount}
                    onChange={(event) => setWithdrawAmount(event.target.value)}
                    placeholder="USDC amount"
                  />
                  <input
                    type="text"
                    value={withdrawRecipient}
                    onChange={(event) => setWithdrawRecipient(event.target.value)}
                    placeholder="Recipient (defaults to wallet)"
                  />
                  <button
                    className="btn btn--primary"
                    type="button"
                    onClick={handleWithdraw}
                    disabled={withdrawStatus === "submitting"}
                  >
                    {withdrawStatus === "submitting" ? "Withdrawing..." : "Withdraw USDC"}
                  </button>
                </div>
                <div className="access__status">
                  Exit anytime: enter the net USDC you want to receive.
                </div>
                {withdrawTxHash && (
                  <div className="access__status">
                    Withdraw tx: {withdrawTxHash.slice(0, 10)}...{withdrawTxHash.slice(-6)}
                  </div>
                )}
                {withdrawError && <div className="access__status error">{withdrawError}</div>}
              </div>
            </>
          )}
        </section>
      )}
    </main>
  );
}
