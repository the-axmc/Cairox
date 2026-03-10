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
    id: "Q1",
    title: "Market Q1",
    status: "Open",
    volume: "—",
    yes: 50,
    no: 50,
    resolution: "0x011ff55025f361a7e8e99be04706d764b9c8f2d0874b5c6fa063f4f68899b644"
  },
  {
    id: "Q2",
    title: "Market Q2",
    status: "Open",
    volume: "—",
    yes: 50,
    no: 50,
    resolution: "0x0588bc5117c11e39e08b6fecffbf87ab036e87f9369ef8032b45be5175ff8306"
  },
  {
    id: "Q3",
    title: "Market Q3",
    status: "Open",
    volume: "—",
    yes: 50,
    no: 50,
    resolution: "0x0649d34baef02596956b2192967c0eb76c9faf1a0db428de9bd6ccfba952f3ea"
  },
  {
    id: "Q4",
    title: "Market Q4",
    status: "Open",
    volume: "—",
    yes: 50,
    no: 50,
    resolution: "0x066eb5dfc35c75960573fe204ec3b2e95307be959936282d621d50b25bbb76c6"
  },
  {
    id: "Q5",
    title: "Market Q5",
    status: "Open",
    volume: "—",
    yes: 50,
    no: 50,
    resolution: "0x0334c6fd8069f23b353427b04742a47c36a2163212c38b1a15e696b244b1519f"
  },
  {
    id: "Q6",
    title: "Market Q6",
    status: "Open",
    volume: "—",
    yes: 50,
    no: 50,
    resolution: "0x01223e9ddc85476efea39b4c99ba818033893ddad3e8aa45ca3ec6b58bc795cb"
  }
];
