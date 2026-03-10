import { useState } from "react";
import backgroundQueen from "./assets/background_queen.png";
import Navbar from "./components/Navbar";
import Footer from "./components/Footer";
import Docs from "./pages/Docs";
import Access from "./pages/Access";
import Markets from "./pages/Markets";
import MarketPreviewGrid from "./components/MarketPreviewGrid";
import NileRunner from "./components/NileRunner";

export default function App() {
  const [showNileRunner, setShowNileRunner] = useState(false);
  const path = typeof window !== "undefined" ? window.location.pathname : "/";
  const normalizedPath = path.replace(/\/+$/, "") || "/";
  const isDocs = normalizedPath === "/docs" || normalizedPath.startsWith("/docs/");
  const isAccess = normalizedPath === "/access" || normalizedPath.startsWith("/access/");
  const isMarkets = normalizedPath === "/markets" || normalizedPath.startsWith("/markets/");

  return (
    <div className="page">
      <div className="page__glow" />
      <Navbar />

      {isDocs ? (
        <Docs />
      ) : isAccess ? (
        <Access />
      ) : isMarkets ? (
        <Markets />
      ) : (
        <main>
        <section className="hero">
          <div className="hero__content">
            <div className="hero__eyebrow">Built on Starknet</div>
            <h1>
              Private bets.
              <br />
              Public outcomes.
            </h1>
            <p>
              Cairox lets teams hedge business‑critical metrics without leaking who
              is betting what.
            </p>
            <div className="hero__actions">
              <a className="btn btn--primary" href="/access">
                Access account
              </a>
              <a className="btn btn--secondary" href="/docs">
                How it works
              </a>
            </div>
          </div>
          <div className="hero__art">
            <div className="hero__backdrop">
              <img
                className="hero__backdrop-image"
                src={backgroundQueen}
                alt="Pixel queen in temple"
              />
            </div>
          </div>
        </section>

        <div className="section-divider" />

        <MarketPreviewGrid />

        <section id="activate" className="activate">
          <div className="activate__panel">
            <div className="hero__eyebrow">Account privacy layer</div>
            <h2>Activate Account</h2>
            <p>
              Create a private account layer where deposits, trades, and withdrawals
              are transformed into ZK proofs. Observers can verify market integrity
              without linking actions to your public wallet identity.
            </p>
            <div className="hero__stats activate__stats">
              <div>
                <div className="stat__label">Privacy mode</div>
                <div className="stat__value">ZK notes</div>
              </div>
              <div>
                <div className="stat__label">Collateral</div>
                <div className="stat__value">USDC 1:1</div>
              </div>
              <div>
                <div className="stat__label">Resolution</div>
                <div className="stat__value">Oracle-signed</div>
              </div>
            </div>
            <div className="activate__explain">
              <article className="activate__step">
                <h3>𓋹 Fund</h3>
                <p>Deposit collateral once, then interact through shielded account state.</p>
              </article>
              <article className="activate__step">
                <h3>𓂀 Trade privately</h3>
                <p>Orders are submitted with proof-backed balance checks instead of plain account history.</p>
              </article>
              <article className="activate__step">
                <h3>𓆣 Resolve publicly</h3>
                <p>Outcomes are published from objective oracle data while individual bet history stays private.</p>
              </article>
            </div>
            <div className="activate__actions">
              <button className="btn btn--secondary" type="button" onClick={() => setShowNileRunner(true)}>
                Play Nile Runner
              </button>
            </div>
          </div>
        </section>
        <NileRunner open={showNileRunner} onClose={() => setShowNileRunner(false)} />
        </main>
      )}

      <Footer />
    </div>
  );
}
