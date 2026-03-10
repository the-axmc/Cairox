import { useEffect, useMemo, useState } from "react";
import NileRunner from "../components/NileRunner";

const API_BASE = import.meta.env.VITE_MIDDLEWARE_URL || "http://localhost:8787";

type AccountHistoryItem = {
  id: string;
  type: string;
  amount: string;
  market_id?: string;
  outcome?: string;
  action?: string;
  recipient?: string;
  tx_hash?: string;
  created_at: string;
  status?: string;
  note?: string;
};

type AccountRecord = {
  wallet: string;
  created_at: string;
  updated_at: string;
  last_seen_at: string;
  usdc_deposit_happened: boolean;
  shieldpool_hashes: string[];
  history: AccountHistoryItem[];
};

type AccountResponse = {
  exists: boolean;
  wallet: string;
  account: AccountRecord | null;
  closed_market_resolutions?: Array<{
    market_id: string;
    title: string;
    status: string;
    outcome?: string;
    settled_at?: string;
    threshold_value?: number | null;
    threshold_operator?: string;
    threshold_unit?: string;
    final_value?: number | null;
    trading_date?: string;
    position?: {
      yes_position?: string;
      no_position?: string;
      trades?: number;
    };
    resolution_note?: string;
  }>;
  balances?: {
    cairox_available: string;
    cairox_total: string;
    vault_usdc: string;
  };
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

const formatDate = (value?: string) => {
  if (!value) return "-";
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) return value;
  return d.toLocaleString();
};

export default function Access() {
  const [wallet, setWallet] = useState("");
  const [connectedWallet, setConnectedWallet] = useState("");
  const [accountData, setAccountData] = useState<AccountResponse | null>(null);
  const [accountStatus, setAccountStatus] = useState<"idle" | "loading" | "error">("idle");
  const [accountError, setAccountError] = useState("");
  const [activationStatus, setActivationStatus] = useState<"idle" | "submitting" | "success" | "error">(
    "idle"
  );
  const [activationError, setActivationError] = useState("");
  const [showNileRunner, setShowNileRunner] = useState(false);

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

  const loadAccount = async (walletAddress: string) => {
    const trimmed = walletAddress.trim();
    if (!trimmed) return;
    setAccountStatus("loading");
    setAccountError("");
    try {
      const response = await fetch(`${API_BASE}/api/account?wallet=${encodeURIComponent(trimmed)}`);
      const data = (await response.json().catch(() => ({}))) as AccountResponse | { error?: string };
      if (!response.ok) {
        throw new Error((data as { error?: string }).error || "Failed to load account.");
      }
      setAccountData(data as AccountResponse);
      setAccountStatus("idle");
    } catch (err) {
      const message = err instanceof Error ? err.message : "Failed to load account.";
      setAccountError(message);
      setAccountStatus("error");
    }
  };

  useEffect(() => {
    const stored = localStorage.getItem("cairox_wallet") || "";
    if (stored) {
      setWallet(stored);
      loadAccount(stored);
    }
    syncConnectedWallet();
  }, []);

  useEffect(() => {
    if (!wallet) return;
    localStorage.setItem("cairox_wallet", wallet);
    loadAccount(wallet);
  }, [wallet]);

  const connectWallet = async () => {
    const active = await syncConnectedWallet();
    if (active) {
      await loadAccount(active);
    }
  };

  const handleActivate = async () => {
    const active = (connectedWallet || wallet).trim();
    if (!active) {
      setActivationStatus("error");
      setActivationError("Connect a wallet first.");
      return;
    }
    setActivationStatus("submitting");
    setActivationError("");
    try {
      const response = await fetch(`${API_BASE}/api/account/activate`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ wallet: active })
      });
      const data = await response.json().catch(() => ({}));
      if (!response.ok) {
        throw new Error(data?.error || "Failed to activate account.");
      }
      setActivationStatus("success");
      await loadAccount(active);
    } catch (err) {
      const message = err instanceof Error ? err.message : "Failed to activate account.";
      setActivationStatus("error");
      setActivationError(message);
    }
  };

  const account = accountData?.account;
  const isExistingAccount = Boolean(accountData?.exists && account);
  const history = useMemo(
    () => [...(account?.history || [])].sort((a, b) => (a.created_at < b.created_at ? 1 : -1)),
    [account?.history]
  );
  const closedResolutions = useMemo(
    () => [...(accountData?.closed_market_resolutions || [])],
    [accountData?.closed_market_resolutions]
  );

  return (
    <main className="access">
      <section className="access__hero">
        <div className="hero__eyebrow">Access account</div>
        <h1>Restore your Cairox account</h1>
        <p>
          Connect your Starknet wallet once. If your wallet is activated, we restore your session
          with CAIROX balance and full account history.
        </p>
        <div className="hero__actions">
          <button className="btn btn--ghost" type="button" onClick={connectWallet}>
            Connect wallet
          </button>
          <a className="btn btn--primary" href="/markets">
            Browse markets
          </a>
        </div>
        {wallet && (
          <div className="access__status">
            Wallet: {wallet.slice(0, 10)}...{wallet.slice(-6)}
          </div>
        )}
        {connectedWallet && (
          <div className="access__status">
            Session restored for connected wallet.
          </div>
        )}
        {accountStatus === "loading" && <div className="access__status">Loading account...</div>}
        {accountStatus === "error" && <div className="access__status error">{accountError}</div>}
      </section>

      {isExistingAccount && account ? (
        <>
          <section className="access__card">
            <h2>Account Overview</h2>
            <div className="access__status">
              Available to trade: {formatUnits(accountData?.balances?.cairox_available || "0")} CAIROX
            </div>
            <div className="access__status">
              Total shielded: {formatUnits(accountData?.balances?.cairox_total || "0")} CAIROX
            </div>
            <div className="access__status">
              Vault USDC: {formatUnits(accountData?.balances?.vault_usdc || "0")} USDC
            </div>
            <div className="access__status">Activated: {formatDate(account.created_at)}</div>
            <div className="access__status">Last seen: {formatDate(account.last_seen_at)}</div>
            <div className="access__status">
              Deposit activated: {account.usdc_deposit_happened ? "Yes" : "Not yet"}
            </div>
            {account.shieldpool_hashes.length > 0 && (
              <div className="access__status">
                ShieldPool hashes: {account.shieldpool_hashes.length}
              </div>
            )}
            <div className="hero__actions">
              <a className="btn btn--primary" href="/markets">
                Trade markets
              </a>
              <button className="btn btn--ghost" type="button" onClick={() => setShowNileRunner(true)}>
                Play Nile Runner
              </button>
            </div>
          </section>

          <section className="access__card">
            <h2>History</h2>
            {history.length === 0 ? (
              <div className="access__status">No account activity yet.</div>
            ) : (
              <div className="access__pending">
                {history.map((item) => (
                  <div key={item.id}>
                    <strong>{item.type.toUpperCase()}</strong> {item.action ? `${item.action} ` : ""}
                    {item.outcome ? `${item.outcome.toUpperCase()} ` : ""}
                    {formatUnits(item.amount)}
                    {" "}
                    {item.type === "withdraw" ? "USDC" : "CAIROX"}
                    {item.market_id ? ` • market ${item.market_id}` : ""}
                    {item.tx_hash ? ` • ${item.tx_hash.slice(0, 10)}...${item.tx_hash.slice(-6)}` : ""}
                    {item.recipient ? ` • to ${item.recipient.slice(0, 10)}...${item.recipient.slice(-6)}` : ""}
                    {` • ${formatDate(item.created_at)}`}
                  </div>
                ))}
              </div>
            )}
          </section>

          <section className="access__card">
            <h2>Closed Market Resolutions</h2>
            {closedResolutions.length === 0 ? (
              <div className="access__status">
                No closed market resolutions yet for this wallet.
              </div>
            ) : (
              <div className="access__pending">
                {closedResolutions.map((item) => (
                  <div key={item.market_id}>
                    <strong>{item.title}</strong>
                    {` • ${item.status || "Closed"}`}
                    {item.outcome ? ` • Outcome: ${item.outcome}` : ""}
                    {item.settled_at ? ` • Settled: ${formatDate(item.settled_at)}` : ""}
                    {typeof item.threshold_value === "number"
                      ? ` • Threshold: ${item.threshold_operator || ">="} ${item.threshold_value}${item.threshold_unit ? ` ${item.threshold_unit}` : ""}`
                      : ""}
                    {typeof item.final_value === "number" ? ` • Final: ${item.final_value}` : ""}
                    {item.position
                      ? ` • Your YES: ${formatUnits(item.position.yes_position || "0")} | NO: ${formatUnits(item.position.no_position || "0")} | Trades: ${item.position.trades ?? 0}`
                      : ""}
                    {item.resolution_note ? ` • Note: ${item.resolution_note}` : ""}
                  </div>
                ))}
              </div>
            )}
          </section>
        </>
      ) : (
        <section className="access__card">
          <h2>Activate Once</h2>
          <p>
            Your wallet is not in the Cairox account database yet. Activate once, then deposit USDC,
            mint CAIROX, and trade on markets. Future wallet connections will restore this account
            automatically.
          </p>
          <ol className="access__steps">
            <li>Connect your wallet.</li>
            <li>Activate account one time.</li>
            <li>Go to /markets, open a market, and deposit + mint CAIROX.</li>
            <li>Buy or sell YES/NO and withdraw USDC when exiting.</li>
          </ol>
          <div className="hero__actions">
            <button
              className="btn btn--primary"
              type="button"
              onClick={handleActivate}
              disabled={activationStatus === "submitting" || !wallet}
            >
              {activationStatus === "submitting" ? "Activating..." : "Activate account"}
            </button>
            <a className="btn btn--ghost" href="/markets">
              Open markets
            </a>
          </div>
          {activationStatus === "success" && (
            <div className="access__status">Account activated. You can now trade.</div>
          )}
          {activationStatus === "error" && (
            <div className="access__status error">{activationError}</div>
          )}
        </section>
      )}

      <NileRunner open={showNileRunner} onClose={() => setShowNileRunner(false)} />
    </main>
  );
}
