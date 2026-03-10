import { useEffect, useState } from "react";

const API_BASE = import.meta.env.VITE_MIDDLEWARE_URL || "http://localhost:8787";

type MarketItem = {
  id: string;
  title: string;
  status?: string;
  volume?: string;
  yes?: number;
  no?: number;
  schedule?: {
    next_reopen_at?: string;
  } | null;
};

export default function MarketPreviewGrid() {
  const [marketItems, setMarketItems] = useState<MarketItem[]>([]);
  const [marketStatus, setMarketStatus] = useState<"idle" | "loading" | "error">("idle");
  const [marketError, setMarketError] = useState<string>("");

  useEffect(() => {
    let cancelled = false;
    let initial = true;

    const load = () => {
      if (initial && !cancelled) {
        setMarketStatus("loading");
        setMarketError("");
      }
      fetch(`${API_BASE}/api/markets`)
        .then((res) => res.json().then((data) => ({ ok: res.ok, data })))
        .then(({ ok, data }) => {
          if (cancelled) return;
          if (!ok) {
            throw new Error(data?.error || "Failed to load markets.");
          }
          setMarketItems(Array.isArray(data?.markets) ? data.markets : []);
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

    load();
    const interval = window.setInterval(load, 60000);
    return () => {
      cancelled = true;
      window.clearInterval(interval);
    };
  }, []);

  return (
    <section id="markets" className="markets">
      <div className="section__head">
        <h2>Active Markets</h2>
        <p>
          Data fetched from{" "}
          <a className="text-link" href="https://growthepie.com">
            growthepie.com
          </a>
        </p>
      </div>
      {marketStatus === "error" && <div className="access__status error">{marketError}</div>}
      {marketStatus === "loading" && <div className="access__status">Loading markets...</div>}
      <div className="market__grid">
        {marketItems.map((market) => (
          <article key={market.id} className="market__card">
            <div className="market__status">
              <span>{market.status || "Open"}</span>
              <span>{market.volume || "—"}</span>
            </div>
            <h3>{market.title || "Untitled market"}</h3>
            {market.status?.toLowerCase().includes("closed") && (
              <div className="access__status">Reopens: {market.schedule?.next_reopen_at || "-"}</div>
            )}
            <div className="market__bars">
              <div className="bar bar--yes" style={{ width: `${market.yes ?? 50}%` }}>
                YES {market.yes ?? 50}%
              </div>
              <div className="bar bar--no" style={{ width: `${market.no ?? 50}%` }}>
                NO {market.no ?? 50}%
              </div>
            </div>
          </article>
        ))}
      </div>
    </section>
  );
}
