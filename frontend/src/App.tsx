import { markets } from "./data/markets";
import backgroundQueen from "./assets/background_queen.png";
import Navbar from "./components/Navbar";
import Footer from "./components/Footer";
import Docs from "./pages/Docs";

export default function App() {
  const path = typeof window !== "undefined" ? window.location.pathname : "/";
  const isDocs = path.startsWith("/docs");

  return (
    <div className="page">
      <div className="page__glow" />
      <Navbar />

      {isDocs ? (
        <Docs />
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
              <a className="btn btn--primary" href="#activate">
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
          <div className="market__grid">
            {markets.map((market) => (
              <article key={market.id} className="market__card">
                <div className="market__status">
                  <span>{market.status}</span>
                  <span>{market.volume}</span>
                </div>
                <h3>{market.title}</h3>
                <div className="market__resolution">{market.resolution}</div>
                <div className="market__bars">
                  <div className="bar bar--yes" style={{ width: `${market.yes}%` }}>
                    YES {market.yes}%
                  </div>
                  <div className="bar bar--no" style={{ width: `${market.no}%` }}>
                    NO {market.no}%
                  </div>
                </div>
              </article>
            ))}
          </div>
        </section>

        <section id="activate" className="activate">
          <div className="activate__panel">
            <h2>Activate Account</h2>
            <p>
              Create an account layer where deposits, trades, and withdrawals
              are transparently transformed into ZK proofs so anonymity is maintained.
            </p>
            <div className="activate__actions">
              <a className="btn btn--primary" href="/docs">
                Read the docs
              </a>
              <a className="btn btn--ghost" href="mailto:team@cairox.xyz">
                Request access
              </a>
              
            </div>
            <div className="hero__stats">
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
                <div className="stat__value">Oracle‑signed</div>
              </div>
            </div>
          </div>
          <div className="activate__pillar">
            <div className="rune">𓋹</div>
            <div className="rune">𓂀</div>
            <div className="rune">𓆣</div>
          </div>
        </section>
        </main>
      )}

      <Footer />
    </div>
  );
}
