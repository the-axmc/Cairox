export type MarketPreview = {
  id: string;
  title: string;
  status: "Open" | "Resolving" | "Closed";
  volume: string;
  yes: number;
  no: number;
  resolution: string;
};

export const markets: MarketPreview[] = [
  {
    id: "mkt-001",
    title: "Starknet DAA ≥ 48,449 on 2026‑02‑23",
    status: "Resolving",
    volume: "1.2M cUSDC",
    yes: 62,
    no: 38,
    resolution: "Growthepie /v1/export/daa.json"
  },
  {
    id: "mkt-002",
    title: "Is L2 TVL > $25B by Q3?",
    status: "Open",
    volume: "640K cUSDC",
    yes: 48,
    no: 52,
    resolution: "Growthepie /v1/export/tvl.json"
  },
  {
    id: "mkt-003",
    title: "Starknet transactions > 3.5M this week",
    status: "Open",
    volume: "310K cUSDC",
    yes: 71,
    no: 29,
    resolution: "Growthepie /v1/export/txs.json"
  }
];
