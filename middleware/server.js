import "dotenv/config";
import express from "express";
import cors from "cors";
import fs from "fs";
import path from "path";
import fetch from "node-fetch";
import { hash } from "starknet";
import { randomUUID } from "crypto";
import { fileURLToPath } from "url";

const app = express();
const port = process.env.PORT || 8787;
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT_DIR = path.resolve(__dirname, "..");

const DEFAULT_CORS_ORIGINS = "http://localhost:5173,http://127.0.0.1:5173";
const CORS_ORIGIN = process.env.CORS_ORIGIN || DEFAULT_CORS_ORIGINS;
const CORS_CREDENTIALS = (process.env.CORS_CREDENTIALS || "1") === "1" && CORS_ORIGIN !== "*";
const ALLOWED_ORIGINS =
  CORS_ORIGIN === "*"
    ? []
    : CORS_ORIGIN.split(",")
        .map((o) => o.trim())
        .filter(Boolean);
const MIDDLEWARE_RATE_LIMIT_WINDOW_MS = Number(
  process.env.MIDDLEWARE_RATE_LIMIT_WINDOW_MS || "60000"
);
const MIDDLEWARE_RATE_LIMIT_MAX = Number(process.env.MIDDLEWARE_RATE_LIMIT_MAX || "240");
const MARKETS_CACHE_TTL_MS = Number(process.env.MARKETS_CACHE_TTL_MS || "10000");

const resolveCorsOrigin = (origin, cb) => {
  if (CORS_ORIGIN === "*") {
    cb(null, true);
    return;
  }
  if (!origin || ALLOWED_ORIGINS.includes(origin)) {
    cb(null, true);
    return;
  }
  cb(new Error("Blocked by CORS policy."));
};

app.use(
  cors({
    origin: resolveCorsOrigin,
    credentials: CORS_CREDENTIALS
  })
);
app.use(express.json({ limit: "1mb" }));

const getClientIp = (req) => {
  const forwarded = (req.headers["x-forwarded-for"] || "").toString().split(",")[0].trim();
  if (forwarded) return forwarded;
  return req.ip || req.socket?.remoteAddress || "unknown";
};

const rateLimitState = new Map();
const applyRateLimit = (req, res, next) => {
  if (MIDDLEWARE_RATE_LIMIT_MAX <= 0 || MIDDLEWARE_RATE_LIMIT_WINDOW_MS <= 0) {
    next();
    return;
  }

  const now = Date.now();
  const key = `${getClientIp(req)}:${req.path}`;
  const current = rateLimitState.get(key);
  if (!current || current.resetAt <= now) {
    rateLimitState.set(key, { count: 1, resetAt: now + MIDDLEWARE_RATE_LIMIT_WINDOW_MS });
    next();
    return;
  }

  current.count += 1;
  if (current.count > MIDDLEWARE_RATE_LIMIT_MAX) {
    const retryAfter = Math.max(1, Math.ceil((current.resetAt - now) / 1000));
    res.setHeader("retry-after", retryAfter.toString());
    res.status(429).json({ error: "Rate limit exceeded. Please retry shortly." });
    return;
  }
  next();
};

setInterval(() => {
  const now = Date.now();
  for (const [key, value] of rateLimitState.entries()) {
    if (value.resetAt <= now) rateLimitState.delete(key);
  }
}, Math.max(30000, MIDDLEWARE_RATE_LIMIT_WINDOW_MS)).unref();

app.use((req, res, next) => {
  if (req.path === "/health") {
    next();
    return;
  }
  applyRateLimit(req, res, next);
});

const RPC_URL = process.env.STARKNET_RPC_URL || process.env.STARKNET_RPC;
const CAIROX_TOKEN_ADDRESS =
  process.env.CAIROX_TOKEN_ADDRESS || process.env.STABLECOIN_ADDRESS;
const RELAYER_URL = process.env.RELAYER_URL;
const RELAYER_BALANCE_PATH = process.env.RELAYER_BALANCE_PATH || "/balance";
const RELAYER_DEPOSIT_PATH = process.env.RELAYER_DEPOSIT_PATH || "/deposit";
const RELAYER_TRADE_PATH = process.env.RELAYER_TRADE_PATH || "/trade";
const RELAYER_WITHDRAW_PATH = process.env.RELAYER_WITHDRAW_PATH || "/withdraw";
const RELAYER_VAULT_PATH = process.env.RELAYER_VAULT_PATH || "/vault_balance";
const RELAYER_API_KEY = process.env.RELAYER_API_KEY;
const BALANCE_SELECTOR = hash.getSelectorFromName("balance_of");
const YES_PRICE_SELECTOR = hash.getSelectorFromName("get_yes_price");
const NO_PRICE_SELECTOR = hash.getSelectorFromName("get_no_price");
const YES_SUPPLY_SELECTOR = hash.getSelectorFromName("get_yes_supply");
const NO_SUPPLY_SELECTOR = hash.getSelectorFromName("get_no_supply");
const B_PARAM_SELECTOR = hash.getSelectorFromName("get_b_param");
const TOTAL_VOLUME_SELECTOR = hash.getSelectorFromName("get_total_volume");
const RPC_TIMEOUT_MS = Number(process.env.RPC_TIMEOUT_MS || "10000");
const RELAYER_TIMEOUT_MS = Number(process.env.RELAYER_TIMEOUT_MS || "120000");
const MIDDLEWARE_SIMPLE_FLOW = (process.env.MIDDLEWARE_SIMPLE_FLOW || "1") === "1";
const SIMPLE_FLOW_DECIMALS = Number(process.env.SIMPLE_FLOW_DECIMALS || "6");
const SIMPLE_FLOW_VAULT_BALANCE = (() => {
  const fallback = 1000000000000n;
  try {
    const parsed = BigInt(process.env.SIMPLE_FLOW_VAULT_BALANCE || fallback.toString());
    return parsed >= 0n ? parsed : fallback;
  } catch {
    return fallback;
  }
})();
const SIMPLE_FLOW_PRICE = "500000000000000000";
const GROWTHEPIE_BASE_URL = process.env.GROWTHEPIE_BASE_URL || "https://api.growthepie.com";
const GROWTHEPIE_TIMEOUT_MS = Number(process.env.GROWTHEPIE_TIMEOUT_MS || "12000");
const MARKET_TIMEZONE = process.env.MARKET_TIMEZONE || "Europe/Berlin";
const MARKET_REOPEN_MINUTE = 1;
const MARKET_CLOSE_MINUTE = 23 * 60 + 59;

const ADDRESS_RE = /^0x[0-9a-fA-F]{3,}$/;
let marketCache = { expiresAt: 0, markets: null };
const ACCOUNT_DB_PATH =
  process.env.ACCOUNT_DB_PATH || path.join(ROOT_DIR, "middleware", "data", "accounts.json");
const ACCOUNT_HISTORY_LIMIT = Math.max(1, Number(process.env.ACCOUNT_HISTORY_LIMIT || "250"));
const MARKETS_SPEC_PATH = path.join(ROOT_DIR, "specs", "markets.json");
const DAILY_MARKET_SNAPSHOT_PATH =
  process.env.DAILY_MARKET_SNAPSHOT_PATH ||
  path.join(ROOT_DIR, "middleware", "data", "daily_market_snapshots.json");
let accountDbWriteQueue = Promise.resolve();
let dailyMarketSnapshotWriteQueue = Promise.resolve();

const validateAmountString = (value) => {
  const raw = (value || "").toString().trim();
  if (!/^[0-9]+(\.[0-9]+)?$/.test(raw)) {
    throw new Error("Amount must be a positive number string.");
  }
  return raw;
};

const parseAmountToBaseUnits = (value, decimals = SIMPLE_FLOW_DECIMALS) => {
  const raw = validateAmountString(value);
  if (!raw.includes(".")) {
    return BigInt(raw) * 10n ** BigInt(decimals);
  }
  const [whole, fractional = ""] = raw.split(".");
  if (fractional.length > decimals) {
    throw new Error(`Amount supports up to ${decimals} decimals.`);
  }
  const padded = (fractional + "0".repeat(decimals)).slice(0, decimals);
  return BigInt(whole || "0") * 10n ** BigInt(decimals) + BigInt(padded || "0");
};

const parseAmountToBaseUnitsSafe = (value, decimals = SIMPLE_FLOW_DECIMALS) => {
  try {
    return parseAmountToBaseUnits(value, decimals);
  } catch {
    return 0n;
  }
};

const nonNegativeSub = (current, amount) => (current > amount ? current - amount : 0n);

const normalizeHex = (value) => {
  const trimmed = value.trim();
  if (!trimmed) return "";
  if (trimmed.startsWith("0x") || trimmed.startsWith("0X")) {
    return `0x${trimmed.slice(2).toLowerCase()}`;
  }
  return `0x${trimmed.toLowerCase()}`;
};

const normalizeAddress = (value) => {
  const hex = normalizeHex(value);
  if (!hex) return "";
  try {
    return `0x${BigInt(hex).toString(16)}`;
  } catch {
    return hex;
  }
};

const decodeShortString = (value) => {
  if (!value) return "";
  let hex = value.startsWith("0x") ? value.slice(2) : value;
  if (hex.length % 2 !== 0) hex = `0${hex}`;
  const bytes = Buffer.from(hex, "hex");
  const printable = bytes.filter((b) => b >= 32 && b <= 126);
  if (printable.length === 0) return "";
  return Buffer.from(printable).toString("utf8").trim();
};

const normalizeTitleKey = (value) =>
  (value || "")
    .toString()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim();

const createMarketSlug = (market) => {
  const suffix = normalizeTitleKey(market.title || `market-${market.market_id || "0"}`)
    .replace(/\s+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 60);
  return `${market.market_id || "0"}-${suffix || "market"}`;
};

const nowIso = () => new Date().toISOString();
const localTxHash = () =>
  `0x${randomUUID().replace(/-/g, "").toLowerCase().padEnd(64, "0").slice(0, 64)}`;

const sanitizeHistoryEntry = (event) => ({
  id: (event?.id || randomUUID()).toString(),
  type: (event?.type || "unknown").toString(),
  amount: (event?.amount || "0").toString(),
  market_id: (event?.market_id ?? "").toString(),
  outcome: (event?.outcome ?? "").toString(),
  action: (event?.action ?? "").toString(),
  recipient: (event?.recipient ?? "").toString(),
  tx_hash: (event?.tx_hash || event?.txHash || "").toString(),
  created_at: (event?.created_at || nowIso()).toString(),
  status: (event?.status || "submitted").toString(),
  note: (event?.note || "").toString()
});

const defaultAccountRecord = (wallet) => {
  const ts = nowIso();
  return {
    wallet,
    created_at: ts,
    updated_at: ts,
    last_seen_at: ts,
    usdc_deposit_happened: false,
    shieldpool_hashes: [],
    history: []
  };
};

const normalizeAccountRecord = (wallet, input) => {
  const account = input && typeof input === "object" ? input : {};
  const createdAt = account.created_at || nowIso();
  const updatedAt = account.updated_at || createdAt;
  const lastSeenAt = account.last_seen_at || updatedAt;
  const hashes = Array.isArray(account.shieldpool_hashes)
    ? account.shieldpool_hashes
    : account?.shieldpool_hash
      ? [account.shieldpool_hash]
      : [];
  const history = Array.isArray(account.history)
    ? account.history.slice(-ACCOUNT_HISTORY_LIMIT).map((entry) => sanitizeHistoryEntry(entry))
    : [];
  return {
    wallet,
    created_at: createdAt,
    updated_at: updatedAt,
    last_seen_at: lastSeenAt,
    usdc_deposit_happened: Boolean(account.usdc_deposit_happened),
    shieldpool_hashes: hashes
      .map((value) => normalizeHex((value || "").toString()))
      .filter((value) => value && value !== "0x"),
    history
  };
};

const ensureAccountDbDir = () => {
  const dir = path.dirname(ACCOUNT_DB_PATH);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
};

const readAccountDb = () => {
  try {
    if (!fs.existsSync(ACCOUNT_DB_PATH)) {
      return { accounts: {} };
    }
    const raw = fs.readFileSync(ACCOUNT_DB_PATH, "utf-8");
    const parsed = JSON.parse(raw || "{}");
    const accounts = {};
    Object.entries(parsed?.accounts || {}).forEach(([key, value]) => {
      const normalizedWallet = normalizeAddress(key);
      if (!normalizedWallet || !ADDRESS_RE.test(normalizedWallet)) return;
      accounts[normalizedWallet] = normalizeAccountRecord(normalizedWallet, value);
    });
    return { accounts };
  } catch {
    return { accounts: {} };
  }
};

const writeAccountDb = (db) => {
  ensureAccountDbDir();
  const tmpPath = `${ACCOUNT_DB_PATH}.tmp`;
  fs.writeFileSync(tmpPath, JSON.stringify(db, null, 2));
  fs.renameSync(tmpPath, ACCOUNT_DB_PATH);
};

const mutateAccountDb = async (mutator) => {
  const run = async () => {
    const db = readAccountDb();
    const result = await mutator(db);
    writeAccountDb(db);
    return result;
  };
  accountDbWriteQueue = accountDbWriteQueue.then(run, run);
  return accountDbWriteQueue;
};

const upsertAccount = async (wallet, mutator) =>
  mutateAccountDb((db) => {
    const existing = db.accounts[wallet] || defaultAccountRecord(wallet);
    const normalized = normalizeAccountRecord(wallet, existing);
    const next = mutator(normalized) || normalized;
    next.updated_at = nowIso();
    db.accounts[wallet] = normalizeAccountRecord(wallet, next);
    return db.accounts[wallet];
  });

const addAccountHistory = async (wallet, event) =>
  upsertAccount(wallet, (account) => {
    const nextHistory = [...(account.history || []), sanitizeHistoryEntry(event)].slice(
      -ACCOUNT_HISTORY_LIMIT
    );
    account.history = nextHistory;
    account.last_seen_at = nowIso();
    return account;
  });

const touchAccount = async (wallet, createIfMissing = false) =>
  mutateAccountDb((db) => {
    const existing = db.accounts[wallet];
    if (!existing && !createIfMissing) {
      return null;
    }
    const account = normalizeAccountRecord(wallet, existing || defaultAccountRecord(wallet));
    account.last_seen_at = nowIso();
    account.updated_at = nowIso();
    db.accounts[wallet] = account;
    return account;
  });

const computeSimpleBalances = (account, marketId = "") => {
  const normalizedMarketId = (marketId || "").toString().trim();
  let totalBalance = 0n;
  let tradeableBalance = 0n;
  let marketBalance = 0n;

  (account?.history || []).forEach((entry) => {
    const eventType = (entry?.type || "").toString().toLowerCase();
    const action = (entry?.action || "buy").toString().toLowerCase();
    const eventMarketId = (entry?.market_id || "").toString();
    const amount = parseAmountToBaseUnitsSafe(entry?.amount || "0");

    if (amount <= 0n) return;

    if (eventType === "deposit") {
      totalBalance += amount;
      tradeableBalance += amount;
      return;
    }

    if (eventType === "withdraw") {
      totalBalance = nonNegativeSub(totalBalance, amount);
      tradeableBalance = nonNegativeSub(tradeableBalance, amount);
      return;
    }

    if (eventType === "trade") {
      if (action === "sell") {
        tradeableBalance += amount;
        if (normalizedMarketId && eventMarketId === normalizedMarketId) {
          marketBalance = nonNegativeSub(marketBalance, amount);
        }
      } else {
        tradeableBalance = nonNegativeSub(tradeableBalance, amount);
        if (normalizedMarketId && eventMarketId === normalizedMarketId) {
          marketBalance += amount;
        }
      }
    }
  });

  if (!normalizedMarketId) {
    marketBalance = 0n;
  }

  return {
    totalBalance,
    tradeableBalance,
    marketBalance
  };
};

const readMarketsConfig = () => {
  if (!fs.existsSync(MARKETS_SPEC_PATH)) return {};
  try {
    const raw = fs.readFileSync(MARKETS_SPEC_PATH, "utf-8");
    return JSON.parse(raw || "{}");
  } catch {
    return {};
  }
};

const readMarketsSpec = () => {
  const parsed = readMarketsConfig();
  return Array.isArray(parsed?.markets) ? parsed.markets : [];
};

const readDailyMarketTemplates = () => {
  const parsed = readMarketsConfig();
  if (Array.isArray(parsed?.daily_templates)) return parsed.daily_templates;
  return [];
};

const ensureDailyMarketSnapshotDir = () => {
  const dir = path.dirname(DAILY_MARKET_SNAPSHOT_PATH);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
};

const readDailyMarketSnapshotDb = () => {
  try {
    if (!fs.existsSync(DAILY_MARKET_SNAPSHOT_PATH)) {
      return { snapshots: {} };
    }
    const raw = fs.readFileSync(DAILY_MARKET_SNAPSHOT_PATH, "utf-8");
    const parsed = JSON.parse(raw || "{}");
    return {
      snapshots: parsed?.snapshots && typeof parsed.snapshots === "object" ? parsed.snapshots : {}
    };
  } catch {
    return { snapshots: {} };
  }
};

const writeDailyMarketSnapshotDb = (db) => {
  ensureDailyMarketSnapshotDir();
  const tmpPath = `${DAILY_MARKET_SNAPSHOT_PATH}.tmp`;
  fs.writeFileSync(tmpPath, JSON.stringify(db, null, 2));
  fs.renameSync(tmpPath, DAILY_MARKET_SNAPSHOT_PATH);
};

const mutateDailyMarketSnapshotDb = async (mutator) => {
  const run = async () => {
    const db = readDailyMarketSnapshotDb();
    const result = await mutator(db);
    writeDailyMarketSnapshotDb(db);
    return result;
  };
  dailyMarketSnapshotWriteQueue = dailyMarketSnapshotWriteQueue.then(run, run);
  return dailyMarketSnapshotWriteQueue;
};

const toFiniteNumber = (value) => {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "bigint") return Number(value);
  if (typeof value === "string") {
    const normalized = value.replace(/,/g, "").trim();
    if (!normalized) return null;
    const parsed = Number(normalized);
    if (Number.isFinite(parsed)) return parsed;
  }
  return null;
};

const getValueByPath = (obj, pathExpr) => {
  if (!obj || typeof obj !== "object" || !pathExpr) return undefined;
  return pathExpr
    .toString()
    .split(".")
    .filter(Boolean)
    .reduce((acc, part) => (acc && typeof acc === "object" ? acc[part] : undefined), obj);
};

const collectDataPoints = (payload) => {
  if (Array.isArray(payload)) {
    return payload.filter((row) => row && typeof row === "object");
  }
  if (!payload || typeof payload !== "object") {
    return [];
  }

  const candidates = [];
  ["data", "result", "rows", "items", "list"].forEach((key) => {
    if (Array.isArray(payload[key])) candidates.push(...payload[key]);
  });
  if (payload.data && typeof payload.data === "object") {
    ["data", "result", "rows", "items", "list"].forEach((key) => {
      if (Array.isArray(payload.data[key])) candidates.push(...payload.data[key]);
    });
  }

  const filtered = candidates.filter((row) => row && typeof row === "object");
  if (filtered.length) return filtered;
  return [payload];
};

const resolvePointDateOnly = (point, template) => {
  const candidates = [
    template?.date_field,
    "date",
    "timestamp",
    "datetime",
    "time",
    "ts",
    "period"
  ].filter(Boolean);
  for (const field of candidates) {
    const raw = getValueByPath(point, field);
    if (!raw) continue;
    const text = raw.toString();
    const match = text.match(/[0-9]{4}-[0-9]{2}-[0-9]{2}/);
    if (match) return match[0];
  }
  return "";
};

const resolvePointTimestamp = (point, template) => {
  const candidates = [
    template?.timestamp_field,
    "timestamp",
    "datetime",
    "time",
    "date",
    "updated_at",
    "created_at"
  ].filter(Boolean);
  for (const field of candidates) {
    const raw = getValueByPath(point, field);
    if (!raw) continue;
    const ts = Date.parse(raw.toString());
    if (Number.isFinite(ts)) return ts;
  }
  return null;
};

const resolvePointNumericValue = (point, template) => {
  const candidates = [
    template?.value_field,
    "value",
    "count",
    "users",
    "daily_active_addresses",
    "total_active_users"
  ].filter(Boolean);
  for (const field of candidates) {
    const raw = getValueByPath(point, field);
    const parsed = toFiniteNumber(raw);
    if (parsed !== null) return parsed;
  }
  return null;
};

const filterPointsForTemplate = (points, template) => {
  const field = (template?.filter_field || "").toString().trim();
  const value = (template?.filter_value || "").toString().trim();
  if (!field || !value) return points;
  return points.filter((row) => {
    const actual = getValueByPath(row, field);
    return actual !== undefined && actual !== null && actual.toString().toLowerCase() === value.toLowerCase();
  });
};

const parseDateKeyInTz = (date = new Date()) => {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: MARKET_TIMEZONE,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23"
  }).formatToParts(date);
  const lookup = {};
  parts.forEach((part) => {
    if (part.type !== "literal") lookup[part.type] = part.value;
  });
  const dateKey = `${lookup.year || "1970"}-${lookup.month || "01"}-${lookup.day || "01"}`;
  const hour = Number(lookup.hour || "0");
  const minute = Number(lookup.minute || "0");
  const second = Number(lookup.second || "0");
  return {
    dateKey,
    hour,
    minute,
    second
  };
};

const shiftDateKey = (dateKey, deltaDays) => {
  const [year, month, day] = (dateKey || "").split("-").map((value) => Number(value));
  if (!year || !month || !day) return dateKey;
  const shifted = new Date(Date.UTC(year, month - 1, day + deltaDays, 12, 0, 0));
  return parseDateKeyInTz(shifted).dateKey;
};

const formatDateKeyForQuestion = (dateKey) => {
  const [year, month, day] = (dateKey || "").split("-").map((value) => Number(value));
  if (!year || !month || !day) return dateKey;
  const date = new Date(Date.UTC(year, month - 1, day, 12, 0, 0));
  return new Intl.DateTimeFormat("en-US", {
    timeZone: MARKET_TIMEZONE,
    year: "numeric",
    month: "long",
    day: "numeric"
  }).format(date);
};

const getMarketSchedule = (date = new Date()) => {
  const nowParts = parseDateKeyInTz(date);
  const minuteOfDay = nowParts.hour * 60 + nowParts.minute;
  const isClosedWindow = minuteOfDay >= MARKET_CLOSE_MINUTE || minuteOfDay < MARKET_REOPEN_MINUTE;
  const tradingDateKey =
    minuteOfDay >= MARKET_REOPEN_MINUTE ? nowParts.dateKey : shiftDateKey(nowParts.dateKey, -1);
  const nextReopenDateKey =
    minuteOfDay >= MARKET_CLOSE_MINUTE ? shiftDateKey(nowParts.dateKey, 1) : nowParts.dateKey;

  return {
    status: isClosedWindow ? "Closed" : "Open",
    tradingDateKey,
    timezone: MARKET_TIMEZONE,
    opens_at: `${tradingDateKey} 00:01 ${MARKET_TIMEZONE}`,
    closes_at: `${tradingDateKey} 23:59 ${MARKET_TIMEZONE}`,
    next_reopen_at: `${nextReopenDateKey} 00:01 ${MARKET_TIMEZONE}`,
    next_close_at: `${tradingDateKey} 23:59 ${MARKET_TIMEZONE}`
  };
};

const buildGrowthepieUrl = (endpoint) => {
  const raw = (endpoint || "").toString().trim();
  if (!raw) return "";
  if (raw.startsWith("http://") || raw.startsWith("https://")) return raw;
  const normalized = raw.startsWith("/") ? raw : `/${raw}`;
  return `${GROWTHEPIE_BASE_URL}${normalized}`;
};

const fetchGrowthepieJson = async (endpoint) => {
  const url = buildGrowthepieUrl(endpoint);
  if (!url) {
    throw new Error("Growthepie endpoint is missing.");
  }
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), GROWTHEPIE_TIMEOUT_MS);
  const response = await fetch(url, { signal: controller.signal }).finally(() => clearTimeout(timeout));
  const data = await response.json().catch(() => null);
  if (!response.ok || !data) {
    throw new Error(`Growthepie request failed for ${url} (${response.status}).`);
  }
  return { url, data };
};

const pickSnapshotPoint = (points, template, tradingDateKey) => {
  const normalized = points
    .map((point) => ({
      point,
      value: resolvePointNumericValue(point, template),
      dateOnly: resolvePointDateOnly(point, template),
      timestampMs: resolvePointTimestamp(point, template)
    }))
    .filter((item) => item.value !== null);

  if (!normalized.length) return null;

  const sameDay = normalized.filter((item) => item.dateOnly === tradingDateKey);
  if (sameDay.length) {
    sameDay.sort((a, b) => {
      const ta = a.timestampMs ?? Number.MAX_SAFE_INTEGER;
      const tb = b.timestampMs ?? Number.MAX_SAFE_INTEGER;
      return ta - tb;
    });
    return sameDay[0];
  }

  const withTimestamp = normalized.filter((item) => Number.isFinite(item.timestampMs));
  if (withTimestamp.length) {
    withTimestamp.sort((a, b) => (a.timestampMs || 0) - (b.timestampMs || 0));
    return withTimestamp[withTimestamp.length - 1];
  }
  return normalized[normalized.length - 1];
};

const pickFinalPoint = (points, template, tradingDateKey) => {
  const normalized = points
    .map((point) => ({
      point,
      value: resolvePointNumericValue(point, template),
      dateOnly: resolvePointDateOnly(point, template),
      timestampMs: resolvePointTimestamp(point, template)
    }))
    .filter((item) => item.value !== null);

  if (!normalized.length) return null;

  const sameDay = normalized.filter((item) => item.dateOnly === tradingDateKey);
  if (sameDay.length) {
    sameDay.sort((a, b) => {
      const ta = a.timestampMs ?? 0;
      const tb = b.timestampMs ?? 0;
      return tb - ta;
    });
    return sameDay[0];
  }

  const withTimestamp = normalized.filter((item) => Number.isFinite(item.timestampMs));
  if (withTimestamp.length) {
    withTimestamp.sort((a, b) => (b.timestampMs || 0) - (a.timestampMs || 0));
    return withTimestamp[0];
  }
  return normalized[normalized.length - 1];
};

const snapshotDbKey = (templateId, tradingDateKey) => `${templateId}:${tradingDateKey}`;

const readLatestTemplateSnapshot = (templateId) => {
  const db = readDailyMarketSnapshotDb();
  const keys = Object.keys(db.snapshots || {}).filter((key) => key.startsWith(`${templateId}:`)).sort();
  if (!keys.length) return null;
  return db.snapshots[keys[keys.length - 1]];
};

const fetchTemplateSnapshot = async (template, tradingDateKey) => {
  const defaultEndpoint = template?.endpoint || "";
  const candidates = Array.isArray(template?.endpoint_candidates)
    ? template.endpoint_candidates
    : defaultEndpoint
      ? [defaultEndpoint]
      : [];

  let lastErr = null;
  for (const endpoint of candidates) {
    try {
      const { url, data } = await fetchGrowthepieJson(endpoint);
      const points = filterPointsForTemplate(collectDataPoints(data), template);
      const picked = pickSnapshotPoint(points, template, tradingDateKey);
      if (!picked) {
        throw new Error(`No numeric datapoints found for ${endpoint}.`);
      }
      return {
        value: picked.value,
        source_endpoint: url,
        source_date: picked.dateOnly || "",
        captured_at: nowIso()
      };
    } catch (err) {
      lastErr = err;
    }
  }
  throw new Error(lastErr?.message || "Unable to fetch market snapshot from Growthepie.");
};

const fetchTemplateFinalValue = async (template, tradingDateKey) => {
  const defaultEndpoint = template?.endpoint || "";
  const candidates = Array.isArray(template?.endpoint_candidates)
    ? template.endpoint_candidates
    : defaultEndpoint
      ? [defaultEndpoint]
      : [];

  let lastErr = null;
  for (const endpoint of candidates) {
    try {
      const { url, data } = await fetchGrowthepieJson(endpoint);
      const points = filterPointsForTemplate(collectDataPoints(data), template);
      const picked = pickFinalPoint(points, template, tradingDateKey);
      if (!picked) {
        throw new Error(`No final datapoint found for ${endpoint}.`);
      }
      return {
        value: picked.value,
        source_endpoint: url,
        source_date: picked.dateOnly || "",
        captured_at: nowIso()
      };
    } catch (err) {
      lastErr = err;
    }
  }
  throw new Error(lastErr?.message || "Unable to fetch final market datapoint from Growthepie.");
};

const ensureDailyTemplateSnapshot = async (template, tradingDateKey) => {
  const templateId = (template?.id || template?.template_id || "daily-market").toString();
  const key = snapshotDbKey(templateId, tradingDateKey);
  const db = readDailyMarketSnapshotDb();
  if (db.snapshots[key]) {
    return db.snapshots[key];
  }

  try {
    const fetched = await fetchTemplateSnapshot(template, tradingDateKey);
    await mutateDailyMarketSnapshotDb((nextDb) => {
      nextDb.snapshots[key] = fetched;
      return fetched;
    });
    return fetched;
  } catch (err) {
    const latest = readLatestTemplateSnapshot(templateId);
    if (latest) {
      return {
        ...latest,
        stale: true,
        stale_reason: err?.message || "snapshot_fetch_failed"
      };
    }
    throw err;
  }
};

const roundThreshold = (value, precision) => {
  const digits = Number.isFinite(precision) ? Math.max(0, Number(precision)) : 0;
  const factor = 10 ** digits;
  return Math.round(value * factor) / factor;
};

const formatThreshold = (value, precision) => {
  const digits = Number.isFinite(precision) ? Math.max(0, Number(precision)) : 0;
  return new Intl.NumberFormat("en-US", {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits
  }).format(value);
};

const evaluateThreshold = (value, threshold, operator) => {
  if (operator === ">") return value > threshold;
  if (operator === ">=") return value >= threshold;
  if (operator === "<") return value < threshold;
  if (operator === "<=") return value <= threshold;
  return value >= threshold;
};

const extractSettlement = (spec) => {
  const direct =
    spec?.final_outcome ||
    spec?.resolved_outcome ||
    spec?.result ||
    spec?.outcome ||
    spec?.metadata?.result ||
    spec?.metadata?.resolved_outcome ||
    spec?.settlement?.outcome ||
    spec?.settlement?.result ||
    "";
  const settledAt =
    spec?.settled_at ||
    spec?.resolved_at ||
    spec?.settlement?.settled_at ||
    spec?.settlement?.resolved_at ||
    "";
  const isSettled =
    Boolean(direct) ||
    ["settled", "resolved", "finalized", "closed"].includes(
      (spec?.status || spec?.settlement?.status || "").toString().toLowerCase()
    );
  if (!isSettled && !settledAt) return null;
  return {
    status: (spec?.status || spec?.settlement?.status || (isSettled ? "Settled" : "")).toString(),
    outcome: direct ? direct.toString() : "",
    settled_at: settledAt ? settledAt.toString() : ""
  };
};

const attachSpecToMarket = (market, spec) => {
  if (!spec) return { ...market, slug: createMarketSlug(market) };
  const settlement = extractSettlement(spec);
  return {
    ...market,
    slug: createMarketSlug(market),
    source: spec.metric_source || "growthepie",
    endpoint: spec.endpoint || "",
    cutoff: spec.cutoff || "",
    market_type: spec.type || "",
    question: spec.name || market.title,
    description: spec.description || "",
    resolution_rule: spec.resolution_rule || "",
    aggregation: spec.aggregation || "",
    outcomes: Array.isArray(spec.outcomes) ? spec.outcomes : [],
    threshold_config: spec.threshold_config || null,
    metadata: spec.metadata || {},
    settlement
  };
};

const mergeWithSpecs = (markets) => {
  const specs = readMarketsSpec();
  if (!specs.length) {
    return markets.map((market) => attachSpecToMarket(market, null));
  }

  const byAddress = new Map();
  const byId = new Map();
  const byTitle = new Map();
  specs.forEach((spec) => {
    const addr = normalizeAddress((spec?.market_address || "").toString());
    if (addr) byAddress.set(addr, spec);
    const mid = (spec?.market_id || "").toString().toLowerCase();
    if (mid) byId.set(mid, spec);
    const titleKey = normalizeTitleKey(spec?.name || "");
    if (titleKey) byTitle.set(titleKey, spec);
  });

  return markets.map((market) => {
    const spec =
      byAddress.get(normalizeAddress(market.address || market.id || "")) ||
      byId.get((market.market_id || "").toString().toLowerCase()) ||
      byTitle.get(normalizeTitleKey(market.title || "")) ||
      null;
    return attachSpecToMarket(market, spec);
  });
};

const buildDailyTemplateMarket = async (template, index) => {
  const schedule = getMarketSchedule();
  const templateId = (template?.id || template?.template_id || `daily-${index + 1}`).toString();
  const metricLabel = (template?.metric_label || "DAA").toString();
  const thresholdOperator = (template?.threshold_operator || ">=").toString();
  const thresholdUnit = (template?.threshold_unit || metricLabel).toString();
  const thresholdPrecision = Number(template?.threshold_precision ?? 0);
  const fallbackAddress = `0x${(index + 1).toString(16).padStart(3, "0")}`;
  const address = normalizeAddress((template?.market_address || fallbackAddress).toString()) || fallbackAddress;

  const snapshot = await ensureDailyTemplateSnapshot(template, schedule.tradingDateKey);
  const thresholdValue = roundThreshold(Number(snapshot.value), thresholdPrecision);
  const thresholdText = formatThreshold(thresholdValue, thresholdPrecision);
  const dateLabel = formatDateKeyForQuestion(schedule.tradingDateKey);
  const title = `Will ${metricLabel} on ${dateLabel} be ${thresholdOperator} ${thresholdText}?`;

  return {
    id: templateId,
    template_id: templateId,
    address,
    market_id: `${templateId}:${schedule.tradingDateKey}`,
    title,
    slug: templateId,
    status: schedule.status,
    volume: "0",
    yes: 50,
    no: 50,
    yes_price: SIMPLE_FLOW_PRICE,
    no_price: SIMPLE_FLOW_PRICE,
    yes_supply: "0",
    no_supply: "0",
    b_param: "0",
    source: "growthepie",
    endpoint: snapshot.source_endpoint || "",
    cutoff: schedule.closes_at,
    market_type: "binary_threshold_daily",
    question: title,
    description:
      `Daily Berlin market. Baseline captured at 00:00 ${MARKET_TIMEZONE}, closes at 23:59 and reopens at 00:01.`,
    resolution_rule: "threshold",
    aggregation: `00:00 ${MARKET_TIMEZONE} snapshot for ${schedule.tradingDateKey}`,
    outcomes: ["YES", "NO"],
    threshold_config: {
      threshold_value: thresholdValue,
      threshold_operator: thresholdOperator,
      threshold_unit: thresholdUnit
    },
    schedule: {
      timezone: schedule.timezone,
      trading_date: schedule.tradingDateKey,
      opens_at: schedule.opens_at,
      closes_at: schedule.closes_at,
      next_reopen_at: schedule.next_reopen_at,
      next_close_at: schedule.next_close_at
    },
    snapshot: {
      value: snapshot.value,
      threshold_value: thresholdValue,
      captured_at: snapshot.captured_at,
      source_date: snapshot.source_date || "",
      source_endpoint: snapshot.source_endpoint || "",
      stale: Boolean(snapshot.stale),
      stale_reason: snapshot.stale_reason || ""
    },
    metadata: {
      template_id: templateId,
      metric_label: metricLabel,
      timezone: MARKET_TIMEZONE,
      source: "growthepie",
      ...(template?.metadata && typeof template.metadata === "object" ? template.metadata : {})
    }
  };
};

const buildSimpleMarkets = async () => {
  const templates = readDailyMarketTemplates();
  if (templates.length) {
    const generated = await Promise.all(
      templates.map(async (template, i) => {
        try {
          return await buildDailyTemplateMarket(template, i);
        } catch {
          return null;
        }
      })
    );
    const valid = generated.filter(Boolean);
    if (valid.length) return valid;
  }

  const specs = readMarketsSpec();
  if (!specs.length) {
    return [
      {
        id: "0x001",
        address: "0x001",
        market_id: "0",
        title: "Demo market",
        status: "Open",
        volume: "0",
        yes: 50,
        no: 50,
        yes_price: SIMPLE_FLOW_PRICE,
        no_price: SIMPLE_FLOW_PRICE,
        yes_supply: "0",
        no_supply: "0",
        b_param: "0",
        source: "simple_flow",
        endpoint: "",
        cutoff: "",
        description: "Local demo market. Replace specs/markets.json with your own markets."
      }
    ];
  }

  return specs.map((spec, i) => {
    const fallbackAddress = `0x${(i + 1).toString(16).padStart(3, "0")}`;
    const address = normalizeAddress((spec?.market_address || fallbackAddress).toString()) || fallbackAddress;
    const market_id = (spec?.market_id || i.toString()).toString();
    const title = (spec?.name || `Market ${i + 1}`).toString();
    const settlement = extractSettlement(spec);
    const status = settlement?.status || (settlement ? "Settled" : "Open");

    return attachSpecToMarket(
      {
        id: address,
        address,
        market_id,
        title,
        status,
        volume: "0",
        yes: 50,
        no: 50,
        yes_price: SIMPLE_FLOW_PRICE,
        no_price: SIMPLE_FLOW_PRICE,
        yes_supply: "0",
        no_supply: "0",
        b_param: "0",
        source: "simple_flow"
      },
      spec
    );
  });
};

const refreshDailySnapshotsIfNeeded = async () => {
  const templates = readDailyMarketTemplates();
  if (!templates.length) return;

  const nowParts = parseDateKeyInTz();
  const schedule = getMarketSchedule();
  const dateKeys = Array.from(new Set([schedule.tradingDateKey, nowParts.dateKey]));

  await Promise.all(
    templates.flatMap((template) =>
      dateKeys.map(async (dateKey) => {
        try {
          await ensureDailyTemplateSnapshot(template, dateKey);
        } catch {
          // Ignore background refresh errors; request path has fallback handling.
        }
      })
    )
  );
};

const readAddressConfig = () => {
  const configPath = path.join(ROOT_DIR, "config", "addresses.sepolia.json");
  if (!fs.existsSync(configPath)) return [];
  const raw = fs.readFileSync(configPath, "utf-8");
  const json = JSON.parse(raw);
  const contracts = json?.contracts || {};
  const markets = [];
  Object.keys(contracts)
    .filter((key) => key.startsWith("MARKET_ADDRESS_"))
    .sort()
    .forEach((key) => {
      markets.push(normalizeAddress(contracts[key]));
    });
  return markets;
};

const readMarketTitles = () => {
  const titlesPath = path.join(ROOT_DIR, "config", "market_titles.sepolia.json");
  if (!fs.existsSync(titlesPath)) return { byAddress: {}, byHash: {} };
  const raw = fs.readFileSync(titlesPath, "utf-8");
  const json = JSON.parse(raw);
  const normalizedByAddress = {};
  Object.entries(json?.byAddress || {}).forEach(([key, value]) => {
    const normalizedKey = normalizeAddress(key);
    if (normalizedKey) {
      normalizedByAddress[normalizedKey] = value;
    }
  });
  const normalizedByHash = {};
  Object.entries(json?.byHash || {}).forEach(([key, value]) => {
    normalizedByHash[normalizeHex(key)] = value;
  });
  return {
    byAddress: normalizedByAddress,
    byHash: normalizedByHash
  };
};

app.get("/health", (_req, res) => {
  res.json({
    ok: true,
    service: "cairox-middleware",
    mode: MIDDLEWARE_SIMPLE_FLOW ? "simple_flow" : "full",
    market_timezone: MARKET_TIMEZONE
  });
});

const loadMarkets = async () => {
  const now = Date.now();
  if (marketCache.markets && marketCache.expiresAt > now) {
    return { markets: marketCache.markets, cached: true };
  }

  if (MIDDLEWARE_SIMPLE_FLOW) {
    const markets = await buildSimpleMarkets();
    marketCache = {
      markets,
      expiresAt: now + Math.max(0, MARKETS_CACHE_TTL_MS)
    };
    return { markets, cached: false };
  }

  const addresses = readAddressConfig();
  const titles = readMarketTitles();
  const onchainMarkets = await Promise.all(
    addresses.map(async (addr, i) => {
      const [
        questionUriRaw,
        questionHashRaw,
        statusRaw,
        yesPriceRaw,
        noPriceRaw,
        yesSupplyRaw,
        noSupplyRaw,
        bParamRaw,
        volumeRaw
      ] = await Promise.all([
        rpcRequest("starknet_call", [
          {
            contract_address: addr,
            entry_point_selector: hash.getSelectorFromName("get_question_uri"),
            calldata: []
          },
          "latest"
        ]),
        rpcRequest("starknet_call", [
          {
            contract_address: addr,
            entry_point_selector: hash.getSelectorFromName("get_question_hash"),
            calldata: []
          },
          "latest"
        ]),
        rpcRequest("starknet_call", [
          {
            contract_address: addr,
            entry_point_selector: hash.getSelectorFromName("get_status"),
            calldata: []
          },
          "latest"
        ]),
        rpcRequest("starknet_call", [
          {
            contract_address: addr,
            entry_point_selector: YES_PRICE_SELECTOR,
            calldata: []
          },
          "latest"
        ]),
        rpcRequest("starknet_call", [
          {
            contract_address: addr,
            entry_point_selector: NO_PRICE_SELECTOR,
            calldata: []
          },
          "latest"
        ]),
        rpcRequest("starknet_call", [
          {
            contract_address: addr,
            entry_point_selector: YES_SUPPLY_SELECTOR,
            calldata: []
          },
          "latest"
        ]),
        rpcRequest("starknet_call", [
          {
            contract_address: addr,
            entry_point_selector: NO_SUPPLY_SELECTOR,
            calldata: []
          },
          "latest"
        ]),
        rpcRequest("starknet_call", [
          {
            contract_address: addr,
            entry_point_selector: B_PARAM_SELECTOR,
            calldata: []
          },
          "latest"
        ]),
        rpcRequest("starknet_call", [
          {
            contract_address: addr,
            entry_point_selector: TOTAL_VOLUME_SELECTOR,
            calldata: []
          },
          "latest"
        ])
      ]);

      const questionUri = normalizeHex(questionUriRaw?.[0] || "0x0");
      const questionHash = normalizeHex(questionHashRaw?.[0] || "0x0");
      const decoded = decodeShortString(questionUri);
      const overrideTitle = titles.byAddress[addr] || titles.byHash[questionHash] || "";
      const title = overrideTitle || decoded || `Market ${i + 1}`;
      const status = decodeShortString(statusRaw?.[0] || "") || "Open";

      return {
        id: addr,
        address: addr,
        market_id: i.toString(),
        title,
        question_uri: questionUri,
        question_hash: questionHash,
        status,
        volume: toU256(volumeRaw).toString(),
        yes: 50,
        no: 50,
        yes_price: toU256(yesPriceRaw).toString(),
        no_price: toU256(noPriceRaw).toString(),
        yes_supply: toU256(yesSupplyRaw).toString(),
        no_supply: toU256(noSupplyRaw).toString(),
        b_param: toU256(bParamRaw).toString(),
        resolution: overrideTitle ? "" : decoded
      };
    })
  );

  const markets = mergeWithSpecs(onchainMarkets);
  marketCache = {
    markets,
    expiresAt: now + Math.max(0, MARKETS_CACHE_TTL_MS)
  };
  return { markets, cached: false };
};

const findMarketByToken = (markets, tokenRaw) => {
  const token = decodeURIComponent((tokenRaw || "").toString()).trim().toLowerCase();
  if (!token) return null;
  return (
    markets.find((market) => {
      const candidates = [
        market.id,
        market.template_id,
        market.address,
        market.market_id,
        market.slug,
        `${market.market_id}`,
        `${market.address}`
      ]
        .filter(Boolean)
        .map((value) => value.toString().toLowerCase());
      return candidates.includes(token);
    }) || null
  );
};

const isClosedLikeStatus = (value) => {
  const status = (value || "").toString().toLowerCase();
  return (
    status.includes("closed") ||
    status.includes("settled") ||
    status.includes("resolved") ||
    status.includes("final")
  );
};

const parseDailyMarketId = (marketId) => {
  const raw = (marketId || "").toString().trim();
  const sep = raw.lastIndexOf(":");
  if (sep <= 0) return null;
  const templateId = raw.slice(0, sep);
  const dateKey = raw.slice(sep + 1);
  if (!/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(dateKey)) return null;
  return { templateId, dateKey };
};

const computeAccountMarketPosition = (account, marketId) => {
  let yes = 0n;
  let no = 0n;
  let tradeCount = 0;

  (account?.history || []).forEach((entry) => {
    if ((entry?.type || "").toString().toLowerCase() !== "trade") return;
    if ((entry?.market_id || "").toString() !== marketId.toString()) return;

    const amount = parseAmountToBaseUnitsSafe(entry?.amount || "0");
    if (amount <= 0n) return;
    const outcome = (entry?.outcome || "").toString().toLowerCase();
    const action = (entry?.action || "buy").toString().toLowerCase();
    const signed = action === "sell" ? -amount : amount;
    if (outcome === "yes") yes += signed;
    if (outcome === "no") no += signed;
    tradeCount += 1;
  });

  return {
    yes_position: yes.toString(),
    no_position: no.toString(),
    trades: tradeCount
  };
};

const resolveClosedDailyMarketForAccount = async (account, marketId, templateById) => {
  const parsed = parseDailyMarketId(marketId);
  if (!parsed) return null;
  const template = templateById.get(parsed.templateId);
  if (!template) return null;

  const schedule = getMarketSchedule();
  const isClosed =
    parsed.dateKey < schedule.tradingDateKey ||
    (parsed.dateKey === schedule.tradingDateKey && schedule.status === "Closed");
  if (!isClosed) return null;

  const thresholdOperator = (template?.threshold_operator || ">=").toString();
  const thresholdUnit = (template?.threshold_unit || template?.metric_label || "value").toString();
  const thresholdPrecision = Number(template?.threshold_precision ?? 0);
  const metricLabel = (template?.metric_label || "Metric").toString();
  const dateLabel = formatDateKeyForQuestion(parsed.dateKey);
  const position = computeAccountMarketPosition(account, marketId);

  let snapshot = null;
  try {
    snapshot = await ensureDailyTemplateSnapshot(template, parsed.dateKey);
  } catch {
    // Continue without snapshot; response will include pending resolution.
  }
  const thresholdValue = snapshot ? roundThreshold(Number(snapshot.value), thresholdPrecision) : null;

  let finalValue = null;
  let outcome = "";
  let settledAt = "";
  let resolutionStatus = "Closed";
  let resolutionNote = "";
  try {
    const final = await fetchTemplateFinalValue(template, parsed.dateKey);
    finalValue = final.value;
    settledAt = final.source_date || final.captured_at || "";
    if (thresholdValue !== null) {
      const yes = evaluateThreshold(finalValue, thresholdValue, thresholdOperator);
      outcome = yes ? "YES" : "NO";
      resolutionStatus = "Resolved";
    } else {
      resolutionStatus = "Pending";
      resolutionNote = "Baseline snapshot unavailable";
    }
  } catch (err) {
    resolutionStatus = "Pending";
    resolutionNote = err?.message || "Final datapoint unavailable";
  }

  const thresholdText = thresholdValue === null ? "-" : formatThreshold(thresholdValue, thresholdPrecision);
  return {
    market_id: marketId,
    title: `Will ${metricLabel} on ${dateLabel} be ${thresholdOperator} ${thresholdText}?`,
    status: resolutionStatus,
    outcome,
    settled_at: settledAt,
    threshold_value: thresholdValue,
    threshold_operator: thresholdOperator,
    threshold_unit: thresholdUnit,
    final_value: finalValue,
    trading_date: parsed.dateKey,
    position,
    resolution_note: resolutionNote
  };
};

const resolveClosedMarketsForAccount = async (account) => {
  const tradeMarketIds = Array.from(
    new Set(
      (account?.history || [])
        .filter((entry) => (entry?.type || "").toString().toLowerCase() === "trade")
        .map((entry) => (entry?.market_id || "").toString())
        .filter(Boolean)
    )
  );
  if (!tradeMarketIds.length) return [];

  const templateById = new Map();
  readDailyMarketTemplates().forEach((template) => {
    const id = (template?.id || template?.template_id || "").toString();
    if (id) templateById.set(id, template);
  });

  const resolved = await Promise.all(
    tradeMarketIds.map(async (marketId) => {
      const daily = await resolveClosedDailyMarketForAccount(account, marketId, templateById);
      if (daily) return daily;
      return null;
    })
  );

  const dailyResolved = resolved.filter(Boolean);
  const unresolvedIds = tradeMarketIds.filter(
    (marketId) => !dailyResolved.find((item) => item.market_id.toString() === marketId.toString())
  );

  if (!unresolvedIds.length) return dailyResolved;

  let markets = [];
  try {
    const loaded = await loadMarkets();
    markets = Array.isArray(loaded?.markets) ? loaded.markets : [];
  } catch {
    return dailyResolved;
  }

  const byMarketId = new Map(markets.map((market) => [(market.market_id || "").toString(), market]));
  unresolvedIds.forEach((marketId) => {
    const market = byMarketId.get(marketId);
    if (!market) return;
    const status = (market.status || market.settlement?.status || "").toString();
    const hasOutcome = Boolean(market.settlement?.outcome);
    if (!isClosedLikeStatus(status) && !hasOutcome) return;

    const position = computeAccountMarketPosition(account, marketId);
    dailyResolved.push({
      market_id: marketId,
      title: market.title || `Market ${marketId}`,
      status: market.settlement?.status || status || "Closed",
      outcome: (market.settlement?.outcome || "").toString(),
      settled_at: (market.settlement?.settled_at || "").toString(),
      threshold_value: market.threshold_config?.threshold_value ?? null,
      threshold_operator: market.threshold_config?.threshold_operator || "",
      threshold_unit: market.threshold_config?.threshold_unit || "",
      final_value: null,
      trading_date: "",
      position,
      resolution_note: ""
    });
  });

  return dailyResolved;
};

app.get("/api/markets", async (_req, res) => {
  try {
    const { markets, cached } = await loadMarkets();
    res.json({ markets, cached });
  } catch (err) {
    res.status(500).json({ error: err.message || "Failed to load markets." });
  }
});

app.get("/api/markets/:marketToken", async (req, res) => {
  if ((req.params.marketToken || "").toString().toLowerCase() === "preview") {
    res.json({
      markets: [
        {
          id: "mkt-001",
          title: "Starknet DAA >= 48,449 on 2026-02-23",
          status: "Resolving",
          volume: "1.2M cUSDC",
          yes: 62,
          no: 38
        }
      ]
    });
    return;
  }
  try {
    const { markets } = await loadMarkets();
    const market = findMarketByToken(markets, req.params.marketToken);
    if (!market) {
      res.status(404).json({ error: "Market not found." });
      return;
    }
    res.json({ market });
  } catch (err) {
    res.status(500).json({ error: err.message || "Failed to load market." });
  }
});

app.post("/api/account/activate", async (req, res) => {
  const walletRaw = (req.body?.wallet || "").toString().trim();
  if (!walletRaw) {
    res.status(400).json({ error: "Wallet address is required." });
    return;
  }
  const wallet = normalizeAddress(walletRaw);
  if (!ADDRESS_RE.test(wallet)) {
    res.status(400).json({ error: "Invalid wallet address." });
    return;
  }

  try {
    const account = await upsertAccount(wallet, (current) => {
      current.last_seen_at = nowIso();
      return current;
    });
    res.json({
      ok: true,
      account: {
        ...account,
        exists: true
      }
    });
  } catch (err) {
    res.status(500).json({ error: err.message || "Failed to activate account." });
  }
});

app.get("/api/account", async (req, res) => {
  const walletRaw = (req.query.wallet || "").toString().trim();
  if (!walletRaw) {
    res.status(400).json({ error: "Wallet address is required." });
    return;
  }
  const wallet = normalizeAddress(walletRaw);
  if (!ADDRESS_RE.test(wallet)) {
    res.status(400).json({ error: "Invalid wallet address." });
    return;
  }

  try {
    const account = await touchAccount(wallet, false);
    if (!account) {
      res.json({
        exists: false,
        account: null,
        wallet
      });
      return;
    }
    const closedMarketResolutions = await resolveClosedMarketsForAccount(account);

    if (MIDDLEWARE_SIMPLE_FLOW) {
      const balances = computeSimpleBalances(account);
      res.json({
        exists: true,
        wallet,
        account,
        closed_market_resolutions: closedMarketResolutions,
        balances: {
          cairox_available: balances.tradeableBalance.toString(),
          cairox_total: balances.totalBalance.toString(),
          vault_usdc: SIMPLE_FLOW_VAULT_BALANCE.toString()
        }
      });
      return;
    }

    const [balanceData, vaultData] = await Promise.all([
      fetchRelayerBalance(wallet).catch(() => null),
      fetchRelayerVaultBalance(wallet).catch(() => null)
    ]);

    res.json({
      exists: true,
      wallet,
      account,
      closed_market_resolutions: closedMarketResolutions,
      balances: {
        cairox_available: balanceData?.tradeable_balance?.toString?.() ?? balanceData?.balance?.toString?.() ?? "0",
        cairox_total: balanceData?.balance?.toString?.() ?? "0",
        vault_usdc: vaultData?.balance?.toString?.() ?? "0"
      }
    });
  } catch (err) {
    res.status(500).json({ error: err.message || "Failed to load account." });
  }
});

const toU256 = (feltArray) => {
  if (!Array.isArray(feltArray) || feltArray.length < 2) {
    throw new Error("Invalid balance response.");
  }
  const low = BigInt(feltArray[0]);
  const high = BigInt(feltArray[1]);
  return (high << 128n) + low;
};

const rpcRequest = async (method, params) => {
  if (!RPC_URL) {
    throw new Error("STARKNET_RPC_URL is not set.");
  }
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), RPC_TIMEOUT_MS);
  const payload = {
    jsonrpc: "2.0",
    method,
    params,
    id: 1
  };

  const response = await fetch(RPC_URL, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(payload),
    signal: controller.signal
  }).finally(() => clearTimeout(timeout));

  const data = await response.json();
  if (!response.ok || data.error) {
    const message = data?.error?.message || "RPC call failed.";
    throw new Error(message);
  }
  return data.result;
};

const fetchRelayerBalance = async (wallet, marketId) => {
  if (!RELAYER_URL) return null;
  const url = new URL(RELAYER_BALANCE_PATH, RELAYER_URL);
  url.searchParams.set("wallet", wallet);
  if (marketId) {
    url.searchParams.set("market_id", marketId);
  }

  const headers = { "content-type": "application/json" };
  if (RELAYER_API_KEY) {
    headers.authorization = `Bearer ${RELAYER_API_KEY}`;
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), RELAYER_TIMEOUT_MS);
  const response = await fetch(url.toString(), { headers, signal: controller.signal }).finally(() =>
    clearTimeout(timeout)
  );
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    const message = data?.error || "Relayer balance request failed.";
    throw new Error(message);
  }
  return data;
};

const fetchRelayerVaultBalance = async (wallet) => {
  if (!RELAYER_URL) return null;
  const url = new URL(RELAYER_VAULT_PATH, RELAYER_URL);
  url.searchParams.set("wallet", wallet);

  const headers = { "content-type": "application/json" };
  if (RELAYER_API_KEY) {
    headers.authorization = `Bearer ${RELAYER_API_KEY}`;
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), RELAYER_TIMEOUT_MS);
  const response = await fetch(url.toString(), { headers, signal: controller.signal }).finally(() =>
    clearTimeout(timeout)
  );
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    const message = data?.error || "Relayer vault balance request failed.";
    throw new Error(message);
  }
  return data;
};

const requestRelayerDeposit = async ({ wallet, amount, market_id }) => {
  if (!RELAYER_URL) {
    throw new Error("Relayer not configured.");
  }
  const url = new URL(RELAYER_DEPOSIT_PATH, RELAYER_URL);
  const headers = { "content-type": "application/json" };
  if (RELAYER_API_KEY) {
    headers.authorization = `Bearer ${RELAYER_API_KEY}`;
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), RELAYER_TIMEOUT_MS);
  const response = await fetch(url.toString(), {
    method: "POST",
    headers,
    body: JSON.stringify({ wallet, amount, market_id }),
    signal: controller.signal
  }).finally(() => clearTimeout(timeout));
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    const message = data?.error || "Relayer deposit request failed.";
    throw new Error(message);
  }
  return data;
};

const requestRelayerTrade = async ({ wallet, market_id, outcome, amount, action }) => {
  if (!RELAYER_URL) {
    throw new Error("Relayer not configured.");
  }
  const url = new URL(RELAYER_TRADE_PATH, RELAYER_URL);
  const headers = { "content-type": "application/json" };
  if (RELAYER_API_KEY) {
    headers.authorization = `Bearer ${RELAYER_API_KEY}`;
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), RELAYER_TIMEOUT_MS);
  const response = await fetch(url.toString(), {
    method: "POST",
    headers,
    body: JSON.stringify({ wallet, market_id, outcome, amount, action }),
    signal: controller.signal
  }).finally(() => clearTimeout(timeout));
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    const message = data?.error || "Relayer trade request failed.";
    throw new Error(message);
  }
  return data;
};

const requestRelayerWithdraw = async ({ wallet, market_id, amount, recipient }) => {
  if (!RELAYER_URL) {
    throw new Error("Relayer not configured.");
  }
  const url = new URL(RELAYER_WITHDRAW_PATH, RELAYER_URL);
  const headers = { "content-type": "application/json" };
  if (RELAYER_API_KEY) {
    headers.authorization = `Bearer ${RELAYER_API_KEY}`;
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), RELAYER_TIMEOUT_MS);
  const response = await fetch(url.toString(), {
    method: "POST",
    headers,
    body: JSON.stringify({ wallet, market_id, amount, recipient }),
    signal: controller.signal
  }).finally(() => clearTimeout(timeout));
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    const message = data?.error || "Relayer withdraw request failed.";
    throw new Error(message);
  }
  return data;
};

app.get("/api/balance", (req, res) => {
  const wallet = (req.query.wallet || "").toString();
  const marketId = (req.query.market_id || "").toString().trim();
  if (!wallet) {
    res.status(400).json({ error: "Wallet address is required." });
    return;
  }

  const accountAddress = normalizeHex(wallet);
  if (!ADDRESS_RE.test(accountAddress)) {
    res.status(400).json({ error: "Invalid wallet address." });
    return;
  }

  const resolveViaRelayer = async () => {
    const relayer = await fetchRelayerBalance(accountAddress, marketId);
    if (!relayer) return null;
    const confirmed = relayer.confirmed !== false;
    const pending = Array.isArray(relayer.pending) ? relayer.pending : [];
    return {
      wallet: accountAddress,
      balance: relayer.balance?.toString?.() ?? "0",
      tradeable_balance: relayer.tradeable_balance?.toString?.() ?? relayer.balance?.toString?.() ?? "0",
      legacy_balance: relayer.legacy_balance?.toString?.() ?? "0",
      notes_count: relayer.notes_count ?? 0,
      warning: relayer.warning ?? null,
      unit: relayer.unit || "CAIROX",
      mechanism: relayer.mechanism || "shielded_pool",
      source: "relayer",
      confirmed,
      pending,
      pending_count: relayer.pending_count ?? pending.length
    };
  };

  const resolveViaSimpleFlow = async () => {
    const account = await touchAccount(accountAddress, true);
    const balances = computeSimpleBalances(account, marketId);
    const balanceForRequest = marketId ? balances.marketBalance : balances.totalBalance;
    const tradeableForRequest = marketId ? balances.marketBalance : balances.tradeableBalance;
    return {
      wallet: accountAddress,
      balance: balanceForRequest.toString(),
      tradeable_balance: tradeableForRequest.toString(),
      unit: "CAIROX",
      mechanism: "simple_flow",
      source: "simple_flow",
      confirmed: true,
      pending: [],
      pending_count: 0
    };
  };

  const resolveViaRpc = async () => {
    if (!CAIROX_TOKEN_ADDRESS) {
      throw new Error("CAIROX_TOKEN_ADDRESS is not set.");
    }
    const contractAddress = normalizeHex(CAIROX_TOKEN_ADDRESS);
    const result = await rpcRequest("starknet_call", [
      {
        contract_address: contractAddress,
        entry_point_selector: BALANCE_SELECTOR,
        calldata: [accountAddress]
      },
      "latest"
    ]);
    const balance = toU256(result);
    return {
      wallet: accountAddress,
      balance: balance.toString(),
      unit: "CAIROX",
      mechanism: "stablecoin",
      source: "rpc",
      confirmed: true
    };
  };

  (async () => {
    try {
      if (MIDDLEWARE_SIMPLE_FLOW) {
        const simpleResult = await resolveViaSimpleFlow();
        res.json(simpleResult);
        return;
      }

      await touchAccount(accountAddress, false);
      if (RELAYER_URL) {
        const relayerResult = await resolveViaRelayer();
        if (relayerResult) {
          res.json(relayerResult);
          return;
        }
      }

      const rpcResult = await resolveViaRpc();
      res.json(rpcResult);
    } catch (err) {
      res.status(500).json({ error: err.message || "Failed to fetch balance." });
    }
  })();
});

app.get("/api/vault_balance", (req, res) => {
  const wallet = (req.query.wallet || "").toString();
  if (!wallet) {
    res.status(400).json({ error: "Wallet address is required." });
    return;
  }

  const accountAddress = normalizeHex(wallet);
  if (!ADDRESS_RE.test(accountAddress)) {
    res.status(400).json({ error: "Invalid wallet address." });
    return;
  }

  (async () => {
    try {
      await touchAccount(accountAddress, MIDDLEWARE_SIMPLE_FLOW);
      if (MIDDLEWARE_SIMPLE_FLOW) {
        res.json({
          wallet: accountAddress,
          balance: SIMPLE_FLOW_VAULT_BALANCE.toString(),
          source: "simple_flow",
          skip_wallet_deposit: true
        });
        return;
      }

      if (!RELAYER_URL) {
        res.status(503).json({ error: "Relayer not configured." });
        return;
      }
      const result = await fetchRelayerVaultBalance(accountAddress);
      res.json({
        wallet: accountAddress,
        balance: result?.balance?.toString?.() ?? "0",
        source: "relayer"
      });
    } catch (err) {
      res.status(500).json({ error: err.message || "Failed to fetch vault balance." });
    }
  })();
});

app.post("/api/deposit", async (req, res) => {
  const wallet = (req.body?.wallet || "").toString().trim();
  const amount = (req.body?.amount || "").toString().trim();
  const marketId = (req.body?.market_id || req.body?.marketId || "").toString().trim();

  if (!wallet || !amount) {
    res.status(400).json({ error: "Wallet and amount are required." });
    return;
  }

  const accountAddress = normalizeHex(wallet);
  if (!ADDRESS_RE.test(accountAddress)) {
    res.status(400).json({ error: "Invalid wallet address." });
    return;
  }

  try {
    validateAmountString(amount);
    if (MIDDLEWARE_SIMPLE_FLOW) {
      parseAmountToBaseUnits(amount);
    }
  } catch (err) {
    res.status(400).json({ error: err.message || "Amount must be a positive number string." });
    return;
  }

  try {
    if (MIDDLEWARE_SIMPLE_FLOW) {
      const txHash = localTxHash();
      const mintTx = localTxHash();

      await upsertAccount(accountAddress, (account) => {
        account.last_seen_at = nowIso();
        account.usdc_deposit_happened = true;
        const unique = new Set([...(account.shieldpool_hashes || []), txHash]);
        account.shieldpool_hashes = Array.from(unique);
        return account;
      });
      await addAccountHistory(accountAddress, {
        type: "deposit",
        amount,
        market_id: marketId || "0",
        tx_hash: txHash,
        status: "submitted",
        note: "USDC deposit simulated in simple flow mode"
      });

      res.json({
        ok: true,
        wallet: accountAddress,
        amount,
        market_id: marketId || null,
        mechanism: "simple_flow",
        tx_hash: txHash,
        mint_tx: mintTx,
        demo_mode: true
      });
      return;
    }

    if (!RELAYER_URL) {
      res.status(503).json({ error: "Relayer not configured." });
      return;
    }

    const data = await requestRelayerDeposit({
      wallet: accountAddress,
      amount,
      market_id: marketId || undefined
    });
    const txHash = data?.tx_hash || data?.transaction_hash || data?.hash || data?.txHash || null;
    const normalizedHash = txHash ? normalizeHex(txHash.toString()) : "";

    await upsertAccount(accountAddress, (account) => {
      account.last_seen_at = nowIso();
      account.usdc_deposit_happened = true;
      if (normalizedHash && normalizedHash !== "0x") {
        const unique = new Set([...(account.shieldpool_hashes || []), normalizedHash]);
        account.shieldpool_hashes = Array.from(unique);
      }
      return account;
    });
    await addAccountHistory(accountAddress, {
      type: "deposit",
      amount,
      market_id: marketId || data?.market_id || "0",
      tx_hash: normalizedHash || txHash || "",
      status: "submitted",
      note: "USDC deposit relayed to shielded pool"
    });

    res.json({
      ok: true,
      wallet: accountAddress,
      amount,
      market_id: marketId || data?.market_id || null,
      mechanism: "shielded_pool",
      tx_hash: txHash,
      mint_tx: data?.mint_tx || null,
      vault_settle_tx: data?.vault_settle_tx || null,
      relayer: data
    });
  } catch (err) {
    res.status(500).json({ error: err.message || "Failed to initiate deposit." });
  }
});

app.post("/api/trade", async (req, res) => {
  const wallet = (req.body?.wallet || "").toString().trim();
  const amount = (req.body?.amount || "").toString().trim();
  const marketId = (req.body?.market_id || "").toString().trim();
  const outcome = (req.body?.outcome || "").toString().trim();
  const action = (req.body?.action || req.body?.side || "").toString().trim();

  if (!wallet || !amount || marketId === "" || !outcome) {
    res.status(400).json({ error: "Wallet, market_id, outcome, and amount are required." });
    return;
  }

  const accountAddress = normalizeHex(wallet);
  if (!ADDRESS_RE.test(accountAddress)) {
    res.status(400).json({ error: "Invalid wallet address." });
    return;
  }

  try {
    validateAmountString(amount);
    if (MIDDLEWARE_SIMPLE_FLOW) {
      parseAmountToBaseUnits(amount);
    }
  } catch (err) {
    res.status(400).json({ error: err.message || "Amount must be a positive number string." });
    return;
  }

  try {
    if (MIDDLEWARE_SIMPLE_FLOW) {
      const normalizedAction = action.toLowerCase() === "sell" ? "sell" : "buy";
      const amountBase = parseAmountToBaseUnits(amount);
      const account = await touchAccount(accountAddress, true);
      const balances = computeSimpleBalances(account, marketId);

      if (normalizedAction === "buy" && balances.tradeableBalance < amountBase) {
        res.status(400).json({
          error: "Insufficient CAIROX balance for buy. Deposit first in simple flow mode."
        });
        return;
      }
      if (normalizedAction === "sell" && balances.marketBalance < amountBase) {
        res.status(400).json({
          error: "Insufficient market position for sell in simple flow mode."
        });
        return;
      }

      const txHash = localTxHash();
      await addAccountHistory(accountAddress, {
        type: "trade",
        amount,
        market_id: marketId,
        outcome,
        action: normalizedAction,
        tx_hash: txHash,
        status: "submitted",
        note: `Trade ${normalizedAction} ${outcome.toUpperCase()} (simple flow)`
      });
      res.json({
        ok: true,
        wallet: accountAddress,
        market_id: marketId,
        outcome,
        amount,
        tx_hash: txHash,
        mechanism: "simple_flow",
        demo_mode: true
      });
      return;
    }

    if (!RELAYER_URL) {
      res.status(503).json({ error: "Relayer not configured." });
      return;
    }

    const data = await requestRelayerTrade({
      wallet: accountAddress,
      market_id: marketId,
      outcome,
      amount,
      action
    });
    const txHash = data?.tx_hash || data?.transaction_hash || data?.hash || data?.txHash || null;
    await touchAccount(accountAddress, true);
    await addAccountHistory(accountAddress, {
      type: "trade",
      amount,
      market_id: marketId,
      outcome,
      action: action || "buy",
      tx_hash: txHash || "",
      status: "submitted",
      note: `Trade ${action || "buy"} ${outcome.toUpperCase()}`
    });
    res.json({
      ok: true,
      wallet: accountAddress,
      market_id: marketId,
      outcome,
      amount,
      tx_hash: txHash,
      mechanism: "shielded_pool"
    });
  } catch (err) {
    res.status(500).json({ error: err.message || "Trade failed." });
  }
});

app.post("/api/withdraw", async (req, res) => {
  const wallet = (req.body?.wallet || "").toString().trim();
  const amount = (req.body?.amount || "").toString().trim();
  const marketId = (req.body?.market_id || req.body?.marketId || "").toString().trim();
  const recipient = (req.body?.recipient || req.body?.to || wallet).toString().trim();

  if (!wallet || !amount || marketId === "") {
    res.status(400).json({ error: "Wallet, market_id, and amount are required." });
    return;
  }

  const accountAddress = normalizeHex(wallet);
  if (!ADDRESS_RE.test(accountAddress)) {
    res.status(400).json({ error: "Invalid wallet address." });
    return;
  }
  const recipientAddress = normalizeHex(recipient);
  if (!ADDRESS_RE.test(recipientAddress)) {
    res.status(400).json({ error: "Invalid recipient address." });
    return;
  }
  try {
    validateAmountString(amount);
    if (MIDDLEWARE_SIMPLE_FLOW) {
      parseAmountToBaseUnits(amount);
    }
  } catch (err) {
    res.status(400).json({ error: err.message || "Amount must be a positive number string." });
    return;
  }

  try {
    if (MIDDLEWARE_SIMPLE_FLOW) {
      const amountBase = parseAmountToBaseUnits(amount);
      const account = await touchAccount(accountAddress, true);
      const balances = computeSimpleBalances(account);
      if (balances.tradeableBalance < amountBase) {
        res.status(400).json({ error: "Insufficient CAIROX balance to withdraw in simple flow mode." });
        return;
      }

      const txHash = localTxHash();
      await addAccountHistory(accountAddress, {
        type: "withdraw",
        amount,
        market_id: marketId,
        recipient: recipientAddress,
        tx_hash: txHash,
        status: "submitted",
        note: "USDC withdrawal simulated in simple flow mode"
      });
      res.json({
        ok: true,
        wallet: accountAddress,
        market_id: marketId,
        recipient: recipientAddress,
        amount,
        mechanism: "simple_flow",
        tx_hash: txHash,
        demo_mode: true
      });
      return;
    }

    if (!RELAYER_URL) {
      res.status(503).json({ error: "Relayer not configured." });
      return;
    }

    const data = await requestRelayerWithdraw({
      wallet: accountAddress,
      market_id: marketId,
      amount,
      recipient: recipientAddress
    });
    const txHash = data?.tx_hash || data?.transaction_hash || data?.hash || data?.txHash || null;
    await touchAccount(accountAddress, true);
    await addAccountHistory(accountAddress, {
      type: "withdraw",
      amount,
      market_id: marketId,
      recipient: recipientAddress,
      tx_hash: txHash || "",
      status: "submitted",
      note: "USDC withdrawal requested"
    });
    res.json({
      ok: true,
      wallet: accountAddress,
      market_id: marketId,
      recipient: recipientAddress,
      amount,
      mechanism: "shielded_pool",
      tx_hash: txHash,
      relayer: data
    });
  } catch (err) {
    res.status(500).json({ error: err.message || "Withdrawal failed." });
  }
});

if (MIDDLEWARE_SIMPLE_FLOW) {
  refreshDailySnapshotsIfNeeded().catch(() => {
    // Ignore startup refresh failures; on-demand market loading will retry.
  });
  setInterval(() => {
    refreshDailySnapshotsIfNeeded().catch(() => {
      // Ignore background refresh failures; on-demand market loading will retry.
    });
  }, 60000).unref();
}

app.listen(port, () => {
  // eslint-disable-next-line no-console
  console.log(
    `Middleware listening on http://localhost:${port} (${MIDDLEWARE_SIMPLE_FLOW ? "simple_flow" : "full"})`
  );
});
