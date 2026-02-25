import express from "express";
import cors from "cors";
import fs from "fs";
import path from "path";

const app = express();
const port = process.env.PORT || 8787;

app.use(cors());
app.use(express.json());

app.get("/health", (_req, res) => {
  res.json({ ok: true, service: "cairox-middleware" });
});

app.get("/api/markets", (_req, res) => {
  try {
    const specsPath = path.resolve("../specs/markets.json");
    const raw = fs.readFileSync(specsPath, "utf-8");
    const markets = JSON.parse(raw);
    res.json({ markets });
  } catch (err) {
    res.status(500).json({ error: "Failed to load market specs." });
  }
});

app.get("/api/markets/preview", (_req, res) => {
  res.json({
    markets: [
      {
        id: "mkt-001",
        title: "Starknet DAA ≥ 48,449 on 2026‑02‑23",
        status: "Resolving",
        volume: "1.2M cUSDC",
        yes: 62,
        no: 38
      }
    ]
  });
});

app.listen(port, () => {
  // eslint-disable-next-line no-console
  console.log(`Middleware listening on http://localhost:${port}`);
});
