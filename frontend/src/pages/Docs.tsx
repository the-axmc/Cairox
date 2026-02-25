import React from "react";

export default function Docs() {
  const handleSubmit = (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
  };

  return (
    <main className="docs">
      <section className="docs__hero">
        <div className="hero__eyebrow">Documentation</div>
        <h1>How Cairox works</h1>
        <p>
          These docs explain how to deposit USDC to receive CAIROX credits, set up
          a Starknet account, trade in prediction markets, and withdraw back to USDC.
        </p>
      </section>

      <section className="docs__grid">
        <article id="docs-deposit" className="docs__card">
          <h2>Deposits: USDC in, CAIROX out</h2>
          <p>
            Deposits are 1:1. When you deposit USDC, the protocol mints the same
            amount of CAIROX credits to your account.
          </p>
          <ul className="docs__list">
            <li>Connect your Starknet wallet.</li>
            <li>Select a USDC amount and confirm the transaction.</li>
            <li>Receive CAIROX credits for trading and payouts.</li>
          </ul>
        </article>

        <article id="docs-account" className="docs__card">
          <h2>Bridge and create a Starknet account</h2>
          <p>
            You need a Starknet wallet and funds on Starknet to pay gas. Bridge
            USDC and a small amount of the network gas token from another network.
          </p>
          <ul className="docs__list">
            <li>Create a Starknet wallet and back up your recovery info.</li>
            <li>Bridge USDC to Starknet and fund gas for transactions.</li>
            <li>Connect your wallet to Cairox to open your account.</li>
          </ul>
        </article>

        <article id="docs-markets" className="docs__card">
          <h2>Markets: data + betting</h2>
          <p>
            Each market tracks a real-world metric. Market resolution is based on
            published data from trusted sources and verified by oracle signatures.
          </p>
          <ul className="docs__list">
            <li>Buy YES or NO shares using CAIROX credits.</li>
            <li>Prices move with demand and implied probability.</li>
            <li>On resolution, winning shares redeem to CAIROX.</li>
          </ul>
        </article>

        <article id="docs-withdraw" className="docs__card">
          <h2>Withdrawals: CAIROX back to USDC</h2>
          <p>
            To withdraw, you burn CAIROX credits and receive the same amount of
            USDC to your Starknet wallet.
          </p>
          <ul className="docs__list">
            <li>Choose the CAIROX amount to redeem.</li>
            <li>Confirm the burn transaction in your wallet.</li>
            <li>Receive USDC in your Starknet wallet.</li>
          </ul>
        </article>
      </section>

      <section className="docs__support">
        <div>
          <h2>Contact support</h2>
          <p>
            Need help? Send us a message and include your email address, wallet
            address, and a short description of the issue.
          </p>
        </div>
        <form className="support-form" onSubmit={handleSubmit}>
          <label htmlFor="support-email">Email address</label>
          <input
            id="support-email"
            name="email"
            type="email"
            placeholder="you@company.com"
            required
          />

          <label htmlFor="support-wallet">Wallet address</label>
          <input
            id="support-wallet"
            name="wallet"
            type="text"
            placeholder="0x..."
            required
          />

          <label htmlFor="support-message">Message</label>
          <textarea
            id="support-message"
            name="message"
            placeholder="Describe your issue"
            required
          />

          <button className="btn btn--primary" type="submit">
            Submit request
          </button>
        </form>
      </section>
    </main>
  );
}
