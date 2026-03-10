import dotenv from "dotenv";
import express from "express";
import cors from "cors";
import fs from "fs";
import path from "path";
import crypto from "crypto";
import fetch from "node-fetch";
import { buildPoseidon } from "circomlibjs";
import { hash } from "starknet";
import { fileURLToPath } from "url";
import { spawn } from "child_process";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const ROOT_DIR = path.resolve(__dirname, "..");

dotenv.config({ path: path.join(ROOT_DIR, ".env") });

const app = express();
const port = process.env.PORT || 8788;

const DEFAULT_CORS_ORIGINS = "http://localhost:5173,http://127.0.0.1:5173";
const CORS_ORIGIN = process.env.CORS_ORIGIN || DEFAULT_CORS_ORIGINS;
const CORS_CREDENTIALS = (process.env.CORS_CREDENTIALS || "1") === "1" && CORS_ORIGIN !== "*";
const ALLOWED_ORIGINS =
  CORS_ORIGIN === "*"
    ? []
    : CORS_ORIGIN.split(",")
        .map((o) => o.trim())
        .filter(Boolean);
const RELAYER_API_KEY = process.env.RELAYER_API_KEY || "";
const RELAYER_REQUIRE_API_KEY =
  (process.env.RELAYER_REQUIRE_API_KEY || (process.env.NODE_ENV === "production" ? "1" : "0")) ===
  "1";
const RELAYER_ENABLE_DEBUG_ROUTES = (process.env.RELAYER_ENABLE_DEBUG_ROUTES || "0") === "1";
const RELAYER_RATE_LIMIT_WINDOW_MS = Number(process.env.RELAYER_RATE_LIMIT_WINDOW_MS || "60000");
const RELAYER_RATE_LIMIT_MAX = Number(process.env.RELAYER_RATE_LIMIT_MAX || "120");

if (RELAYER_REQUIRE_API_KEY && !RELAYER_API_KEY) {
  throw new Error("RELAYER_API_KEY is required when RELAYER_REQUIRE_API_KEY=1.");
}

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
app.use(express.json({ limit: "2mb" }));

const getClientIp = (req) => {
  const forwarded = (req.headers["x-forwarded-for"] || "").toString().split(",")[0].trim();
  if (forwarded) return forwarded;
  return req.ip || req.socket?.remoteAddress || "unknown";
};

const rateLimitState = new Map();

const applyRateLimit = (req, res, next) => {
  if (RELAYER_RATE_LIMIT_MAX <= 0 || RELAYER_RATE_LIMIT_WINDOW_MS <= 0) {
    next();
    return;
  }

  const now = Date.now();
  const key = `${getClientIp(req)}:${req.path}`;
  const current = rateLimitState.get(key);
  if (!current || current.resetAt <= now) {
    rateLimitState.set(key, { count: 1, resetAt: now + RELAYER_RATE_LIMIT_WINDOW_MS });
    next();
    return;
  }

  current.count += 1;
  if (current.count > RELAYER_RATE_LIMIT_MAX) {
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
    if (value.resetAt <= now) {
      rateLimitState.delete(key);
    }
  }
}, Math.max(30000, RELAYER_RATE_LIMIT_WINDOW_MS)).unref();

const requireRelayerAuth = (req, res, next) => {
  if (!RELAYER_REQUIRE_API_KEY) {
    next();
    return;
  }
  const authHeader = (req.headers.authorization || "").toString().trim();
  const bearer = authHeader.startsWith("Bearer ") ? authHeader.slice(7).trim() : "";
  const xApiKey = (req.headers["x-api-key"] || "").toString().trim();
  const token = bearer || xApiKey;
  if (!token || token !== RELAYER_API_KEY) {
    res.status(401).json({ error: "Unauthorized." });
    return;
  }
  next();
};

const requireDebugEnabled = (_req, res, next) => {
  if (!RELAYER_ENABLE_DEBUG_ROUTES) {
    res.status(404).json({ error: "Not found." });
    return;
  }
  next();
};

app.use((req, res, next) => {
  if (req.path === "/health") {
    next();
    return;
  }
  applyRateLimit(req, res, next);
});

const RPC_URL = process.env.STARKNET_RPC_URL || process.env.STARKNET_RPC;
const SHIELDED_POOL_ADDRESS = process.env.SHIELDED_POOL_ADDRESS;
const CAIROX_TOKEN_ADDRESS =
  process.env.CAIROX_TOKEN_ADDRESS || process.env.STABLECOIN_ADDRESS;
const COLLATERAL_VAULT_ADDRESS = process.env.COLLATERAL_VAULT_ADDRESS;
const USDC_ADDRESS = process.env.USDC_ADDRESS || process.env.COLLATERAL_TOKEN_ADDRESS;
const RELAYER_FEE_LOW = process.env.RELAYER_FEE_LOW || "1000";
const RELAYER_FEE_HIGH = process.env.RELAYER_FEE_HIGH || "0";
const RELAYER_TIMEOUT_MS = Number(process.env.RELAYER_TIMEOUT_MS || "15000");
const STARKLI_ACCOUNT_RAW = process.env.STARKLI_ACCOUNT;
const STARKLI_KEYSTORE_RAW = process.env.STARKLI_KEYSTORE;
const RELAYER_AMOUNT_DECIMALS = Number(process.env.RELAYER_AMOUNT_DECIMALS || "6");
const RELAYER_AMOUNT_IN_BASE_UNITS =
  (process.env.RELAYER_AMOUNT_IN_BASE_UNITS || "0") === "1";
const RELAYER_ALLOW_RESET = (process.env.RELAYER_ALLOW_RESET || "0") === "1";
const RELAYER_USDC_ALLOW_MAX = (process.env.RELAYER_USDC_ALLOW_MAX || "1") === "1";
const RELAYER_USDC_ALLOWANCE_TARGET = process.env.RELAYER_USDC_ALLOWANCE_TARGET || "";
const RELAYER_CAIROX_ALLOW_MAX = (process.env.RELAYER_CAIROX_ALLOW_MAX || "1") === "1";
const RELAYER_CAIROX_ALLOWANCE_TARGET = process.env.RELAYER_CAIROX_ALLOWANCE_TARGET || "";
const RELAYER_AUTO_APPROVE = (process.env.RELAYER_AUTO_APPROVE || "1") === "1";
const RELAYER_TRADES_ENABLED = (process.env.RELAYER_TRADES_ENABLED || "1") === "1";
const RELAYER_ENFORCE_PEG = (process.env.RELAYER_ENFORCE_PEG || "1") === "1";
const RELAYER_LOCK_PRICE = (process.env.RELAYER_LOCK_PRICE || "0") === "1";

const resolveHome = (value) => {
  if (!value) return value;
  if (value.startsWith("~/")) {
    const home = process.env.HOME || process.env.USERPROFILE || "";
    return path.join(home, value.slice(2));
  }
  return value;
};

const STARKLI_ACCOUNT = STARKLI_ACCOUNT_RAW ? resolveHome(STARKLI_ACCOUNT_RAW) : "";
const STARKLI_KEYSTORE = STARKLI_KEYSTORE_RAW ? resolveHome(STARKLI_KEYSTORE_RAW) : "";

const INPUT_TEMPLATE = process.env.RELAYER_INPUT_TEMPLATE
  ? path.resolve(ROOT_DIR, process.env.RELAYER_INPUT_TEMPLATE)
  : path.resolve(ROOT_DIR, "zk/examples/input_deposit.json");

const WASM_PATH = process.env.RELAYER_WASM
  ? path.resolve(ROOT_DIR, process.env.RELAYER_WASM)
  : path.resolve(ROOT_DIR, "zk/build/shielded_transact_js/shielded_transact.wasm");
const ZKEY_PATH = process.env.RELAYER_ZKEY
  ? path.resolve(ROOT_DIR, process.env.RELAYER_ZKEY)
  : path.resolve(ROOT_DIR, "zk/build/shielded_transact_final.zkey");
const VK_PATH = process.env.RELAYER_VK
  ? path.resolve(ROOT_DIR, process.env.RELAYER_VK)
  : path.resolve(ROOT_DIR, "zk/build/verification_key.json");
const SNARKJS_BIN = process.env.RELAYER_SNARKJS_BIN
  ? path.resolve(ROOT_DIR, process.env.RELAYER_SNARKJS_BIN)
  : path.resolve(ROOT_DIR, "zk/node_modules/.bin/snarkjs");

const GARAGA_BIN = (() => {
  if (process.env.RELAYER_GARAGA_BIN) return path.resolve(ROOT_DIR, process.env.RELAYER_GARAGA_BIN);
  const venv = path.resolve(ROOT_DIR, "oracle-agent/venv/bin/garaga");
  if (fs.existsSync(venv)) return venv;
  return "garaga";
})();

const LEDGER_DIR = path.resolve(__dirname, "data");
const LEDGER_PATH = path.join(LEDGER_DIR, "ledger.json");
const TMP_DIR = path.join(LEDGER_DIR, "tmp");
const ADDRESS_RE = /^0x[0-9a-fA-F]{3,}$/;
const DEPTH = 32;
const BALANCE_SELECTOR = hash.getSelectorFromName("balance_of");
const ALLOWANCE_SELECTOR = hash.getSelectorFromName("allowance");
const VAULT_BALANCE_SELECTOR = hash.getSelectorFromName("get_balance");
const ROOT_SELECTOR = hash.getSelectorFromName("get_root");
const COLLATERAL_TOKEN_SELECTOR = hash.getSelectorFromName("get_collateral_token");
const PRICE_FEED_SELECTOR = hash.getSelectorFromName("get_price_feed");
const PRICE_FEED_TYPE_SELECTOR = hash.getSelectorFromName("get_price_feed_type");
const MAX_PRICE_AGE_SELECTOR = hash.getSelectorFromName("get_max_price_age");
const ORACLE_UPDATED_AT_SELECTOR = hash.getSelectorFromName("get_updated_at");
const ORACLE_UPDATE_PRICE_SELECTOR = hash.getSelectorFromName("update_price");
const PRICE_DECIMALS_SELECTOR = hash.getSelectorFromName("get_price_decimals");
const PRICE_UPDATED_AT_SELECTOR = hash.getSelectorFromName("get_price_updated_at");
const LATEST_PRICE_SELECTOR = hash.getSelectorFromName("get_latest_price");
const CAIROX_DECIMALS_SELECTOR = hash.getSelectorFromName("decimals");
const COLLATERAL_DECIMALS_SELECTOR = hash.getSelectorFromName("get_collateral_decimals");
const MINTED_EVENT_SELECTOR = hash.getSelectorFromName("Minted");
const PRICE_LOCKED_SELECTOR = hash.getSelectorFromName("is_price_locked");
const LOCKED_PRICE_SELECTOR = hash.getSelectorFromName("get_locked_price");
const COMMITMENT_SELECTOR = hash.getSelectorFromName("get_commitment");
const COMMITMENT_UPDATED_AT_SELECTOR = hash.getSelectorFromName("get_updated_at");
const YES_SUPPLY_SELECTOR = hash.getSelectorFromName("get_yes_supply");
const NO_SUPPLY_SELECTOR = hash.getSelectorFromName("get_no_supply");
const B_PARAM_SELECTOR = hash.getSelectorFromName("get_b_param");
const YES_PRICE_SELECTOR = hash.getSelectorFromName("get_yes_price");
const NO_PRICE_SELECTOR = hash.getSelectorFromName("get_no_price");
const LMSR_BUY_SELECTOR = hash.getSelectorFromName("calculate_buy_amount");
const LMSR_SELL_SELECTOR = hash.getSelectorFromName("calculate_sell_amount");
const PRICE_FEED_ORACLE = 1;
const MAX_U256 = (1n << 256n) - 1n;
const TX_HASH_RE = /^0x[0-9a-fA-F]{64}$/;
const STATE_TS_WINDOW = Number(process.env.RELAYER_STATE_TS_WINDOW || "900");

const ADDRESS_CONFIG_PATH = path.resolve(ROOT_DIR, "config", "addresses.sepolia.json");
let ADDRESS_CONFIG_CACHE = null;

const loadAddressConfig = () => {
  if (ADDRESS_CONFIG_CACHE) return ADDRESS_CONFIG_CACHE;
  if (!fs.existsSync(ADDRESS_CONFIG_PATH)) {
    ADDRESS_CONFIG_CACHE = { contracts: {} };
    return ADDRESS_CONFIG_CACHE;
  }
  try {
    const raw = fs.readFileSync(ADDRESS_CONFIG_PATH, "utf-8");
    ADDRESS_CONFIG_CACHE = JSON.parse(raw) || { contracts: {} };
  } catch {
    ADDRESS_CONFIG_CACHE = { contracts: {} };
  }
  return ADDRESS_CONFIG_CACHE;
};

const getConfigContract = (key) => {
  const cfg = loadAddressConfig();
  return normalizeAddress(cfg?.contracts?.[key] || "");
};

const DATA_COMMITMENT_ADDRESS =
  process.env.DATA_COMMITMENT_ADDRESS || getConfigContract("DATA_COMMITMENT_ADDRESS");
const LMSR_ADDRESS = process.env.LMSR_ADDRESS || getConfigContract("LMSR_ADDRESS");

const poseidon = await buildPoseidon();
const F = poseidon.F;

const ensureDir = (dir, mode = 0o700) => {
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true, mode });
  }
};

const safeRmDir = (dir) => {
  if (!dir) return;
  try {
    fs.rmSync(dir, { recursive: true, force: true });
  } catch {
    // best effort cleanup
  }
};

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

const canonicalWallet = (value) => normalizeAddress(value);

const normalizeFelt = (value, fallback = "0") => {
  const raw = value === undefined || value === null ? "" : value.toString().trim();
  if (!raw) return fallback;
  if (!/^(0x)?[0-9a-fA-F]+$/.test(raw)) {
    throw new Error("Invalid felt value.");
  }
  return BigInt(raw).toString();
};

const isLedgerTxHash = (value) => {
  if (!value) return false;
  const normalized = normalizeHex(value);
  if (!TX_HASH_RE.test(normalized)) return false;
  if (SHIELDED_POOL_ADDRESS && normalized === normalizeHex(SHIELDED_POOL_ADDRESS)) return false;
  return true;
};

const mergeWalletEntries = (left = {}, right = {}) => {
  const confirmedLeft = BigInt(left.confirmed || "0");
  const confirmedRight = BigInt(right.confirmed || "0");
  const confirmed =
    confirmedLeft >= confirmedRight ? confirmedLeft : confirmedRight;

  const pendingMap = new Map();
  const collect = (entry) => {
    if (!entry || !entry.tx_hash) return;
    if (!isLedgerTxHash(entry.tx_hash)) return;
    const txHash = normalizeHex(entry.tx_hash);
    if (pendingMap.has(txHash)) return;
    pendingMap.set(txHash, {
      ...entry,
      tx_hash: txHash
    });
  };

  (left.pending || []).forEach(collect);
  (right.pending || []).forEach(collect);

  return {
    confirmed: confirmed.toString(),
    pending: Array.from(pendingMap.values())
  };
};

const normalizeLedger = (ledger) => {
  const wallets = ledger?.wallets || {};
  const normalized = { wallets: {}, merkle: ledger?.merkle };
  for (const [key, entry] of Object.entries(wallets)) {
    const canonical = canonicalWallet(key);
    if (!canonical || !ADDRESS_RE.test(canonical)) continue;
    const existing = normalized.wallets[canonical];
    const merged = existing ? mergeWalletEntries(existing, entry) : mergeWalletEntries(entry, {});
    const notes = Array.isArray(entry?.notes) ? entry.notes : [];
    const existingNotes = Array.isArray(existing?.notes) ? existing.notes : [];
    const combinedNotes = [...existingNotes, ...notes].filter(Boolean);
    const noteMap = new Map();
    for (const note of combinedNotes) {
      const id = note?.commitment || note?.id;
      if (!id) continue;
      if (noteMap.has(id)) continue;
      noteMap.set(id, note);
    }
    merged.notes = Array.from(noteMap.values());
    normalized.wallets[canonical] = merged;
  }
  return normalized;
};

const loadLedger = () => {
  ensureDir(LEDGER_DIR);
  if (!fs.existsSync(LEDGER_PATH)) {
    return { wallets: {} };
  }
  try {
    const parsed = JSON.parse(fs.readFileSync(LEDGER_PATH, "utf-8"));
    return normalizeLedger(parsed);
  } catch {
    return { wallets: {} };
  }
};

const saveLedger = (ledger) => {
  ensureDir(LEDGER_DIR);
  const tmpPath = path.join(
    LEDGER_DIR,
    `ledger.tmp-${process.pid}-${Date.now()}-${crypto.randomBytes(4).toString("hex")}.json`
  );
  fs.writeFileSync(tmpPath, JSON.stringify(ledger, null, 2), { mode: 0o600 });
  fs.renameSync(tmpPath, LEDGER_PATH);
};

const toU256 = (feltArray) => {
  if (!Array.isArray(feltArray) || feltArray.length < 2) {
    throw new Error("Invalid u256 response.");
  }
  const low = BigInt(feltArray[0]);
  const high = BigInt(feltArray[1]);
  return (high << 128n) + low;
};

const toU256Parts = (value) => splitU256(value);

const getLatestBlockTimestamp = async () => {
  const result = await rpcRequest("starknet_getBlockWithTxHashes", ["latest"]);
  return BigInt(result?.timestamp ?? 0);
};

const getPriceFeedInfo = async () => {
  const [feed] = await rpcRequest("starknet_call", [
    {
      contract_address: normalizeHex(CAIROX_TOKEN_ADDRESS),
      entry_point_selector: PRICE_FEED_SELECTOR,
      calldata: []
    },
    "latest"
  ]);
  const [feedType] = await rpcRequest("starknet_call", [
    {
      contract_address: normalizeHex(CAIROX_TOKEN_ADDRESS),
      entry_point_selector: PRICE_FEED_TYPE_SELECTOR,
      calldata: []
    },
    "latest"
  ]);
  const maxAge = await rpcRequest("starknet_call", [
    {
      contract_address: normalizeHex(CAIROX_TOKEN_ADDRESS),
      entry_point_selector: MAX_PRICE_AGE_SELECTOR,
      calldata: []
    },
    "latest"
  ]);
  return {
    feed: normalizeAddress(feed),
    feedType: Number(BigInt(feedType)),
    maxAge: toU256(maxAge)
  };
};

const getCairoxPriceDecimals = async () => {
  const result = await rpcRequest("starknet_call", [
    {
      contract_address: normalizeHex(CAIROX_TOKEN_ADDRESS),
      entry_point_selector: PRICE_DECIMALS_SELECTOR,
      calldata: []
    },
    "latest"
  ]);
  return Number(BigInt(result?.[0] ?? 0));
};

const getCairoxLatestPrice = async () => {
  const result = await rpcRequest("starknet_call", [
    {
      contract_address: normalizeHex(CAIROX_TOKEN_ADDRESS),
      entry_point_selector: LATEST_PRICE_SELECTOR,
      calldata: []
    },
    "latest"
  ]);
  return toU256(result);
};

const getCairoxPriceUpdatedAt = async () => {
  const result = await rpcRequest("starknet_call", [
    {
      contract_address: normalizeHex(CAIROX_TOKEN_ADDRESS),
      entry_point_selector: PRICE_UPDATED_AT_SELECTOR,
      calldata: []
    },
    "latest"
  ]);
  return toU256(result);
};

const getCairoxDecimals = async () => {
  const result = await rpcRequest("starknet_call", [
    {
      contract_address: normalizeHex(CAIROX_TOKEN_ADDRESS),
      entry_point_selector: CAIROX_DECIMALS_SELECTOR,
      calldata: []
    },
    "latest"
  ]);
  return Number(BigInt(result?.[0] ?? 0));
};

const getCollateralDecimals = async () => {
  const result = await rpcRequest("starknet_call", [
    {
      contract_address: normalizeHex(CAIROX_TOKEN_ADDRESS),
      entry_point_selector: COLLATERAL_DECIMALS_SELECTOR,
      calldata: []
    },
    "latest"
  ]);
  return Number(BigInt(result?.[0] ?? 0));
};

const getPriceLockStatus = async () => {
  const [locked] = await rpcRequest("starknet_call", [
    {
      contract_address: normalizeHex(CAIROX_TOKEN_ADDRESS),
      entry_point_selector: PRICE_LOCKED_SELECTOR,
      calldata: []
    },
    "latest"
  ]);
  let lockedPrice = 0n;
  if (BigInt(locked || 0) === 1n) {
    const price = await rpcRequest("starknet_call", [
      {
        contract_address: normalizeHex(CAIROX_TOKEN_ADDRESS),
        entry_point_selector: LOCKED_PRICE_SELECTOR,
        calldata: []
      },
      "latest"
    ]);
    lockedPrice = toU256(price);
  }
  return { locked: BigInt(locked || 0) === 1n, lockedPrice };
};

const normalizeOraclePrice = (raw, priceDecimals) => {
  const value = BigInt(raw);
  if (priceDecimals >= 18) return value.toString();
  const scale = 10n ** BigInt(18 - priceDecimals);
  if (scale > 1n && value % scale === 0n) {
    return (value / scale).toString();
  }
  return value.toString();
};

const getPegPrice = async () => {
  const priceRaw = process.env.RELAYER_ORACLE_PRICE;
  if (!priceRaw) return null;
  const priceDecimals = await getCairoxPriceDecimals();
  return normalizeOraclePrice(priceRaw, priceDecimals);
};

const updateOraclePrice = async () => {
  if (!CAIROX_TOKEN_ADDRESS) return null;
  const { feed, feedType } = await getPriceFeedInfo();
  if (feedType !== PRICE_FEED_ORACLE) {
    return null;
  }
  const priceRaw = process.env.RELAYER_ORACLE_PRICE;
  if (!priceRaw) {
    throw new Error("RELAYER_ORACLE_PRICE is required to update price.");
  }
  const priceDecimals = await getCairoxPriceDecimals();
  const price = normalizeOraclePrice(priceRaw, priceDecimals);
  const [low, high] = toU256Parts(price);
  await runCommand("starkli", [
    "invoke",
    feed,
    "update_price",
    low,
    high,
    "--watch",
    "--account",
    STARKLI_ACCOUNT,
    "--keystore",
    STARKLI_KEYSTORE,
    "--rpc",
    RPC_URL
  ]);
  return price;
};

const ensurePriceLocked = async () => {
  if (!RELAYER_LOCK_PRICE) return;
  const { locked, lockedPrice } = await getPriceLockStatus();
  const pegPrice = await getPegPrice();
  if (locked) {
    if (RELAYER_ENFORCE_PEG && pegPrice && BigInt(pegPrice) !== lockedPrice) {
      throw new Error(
        `Price is locked to ${lockedPrice.toString()}, expected ${pegPrice}. Unlock price before continuing.`
      );
    }
    return;
  }

  await runCommand("starkli", [
    "invoke",
    CAIROX_TOKEN_ADDRESS,
    "lock_price",
    "--watch",
    "--account",
    STARKLI_ACCOUNT,
    "--keystore",
    STARKLI_KEYSTORE,
    "--rpc",
    RPC_URL
  ]);
};

const estimateMintedAmount = async (collateralAmount) => {
  const amount = BigInt(collateralAmount);
  const price = await getCairoxLatestPrice();
  const priceDecimals = await getCairoxPriceDecimals();
  const collateralDecimals = await getCollateralDecimals();
  const stableDecimals = await getCairoxDecimals();

  const scaleStable = 10n ** BigInt(stableDecimals);
  const scalePrice = 10n ** BigInt(priceDecimals);
  const scaleCollateral = 10n ** BigInt(collateralDecimals);

  if (price === 0n) return 0n;
  const numerator = amount * scaleStable * scalePrice;
  const denom = scaleCollateral * price;
  return numerator / denom;
};

const ensureFreshPrice = async () => {
  if (!CAIROX_TOKEN_ADDRESS) return;
  const { feed, feedType, maxAge } = await getPriceFeedInfo();
  if (maxAge === 0n) return;
  if (feedType !== PRICE_FEED_ORACLE) {
    return;
  }
  const updatedAt = await rpcRequest("starknet_call", [
    {
      contract_address: normalizeHex(feed),
      entry_point_selector: ORACLE_UPDATED_AT_SELECTOR,
      calldata: []
    },
    "latest"
  ]);
  const updated = toU256(updatedAt);
  const now = await getLatestBlockTimestamp();
  if (now < updated) return;
  if (now - updated <= maxAge) return;

  await updateOraclePrice();
};

const rpcRequest = async (method, params) => {
  if (!RPC_URL) {
    throw new Error("STARKNET_RPC_URL is not set.");
  }
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), RELAYER_TIMEOUT_MS);
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

const getPoolRoot = async () => {
  if (!SHIELDED_POOL_ADDRESS) {
    throw new Error("SHIELDED_POOL_ADDRESS is not set.");
  }
  const result = await rpcRequest("starknet_call", [
    {
      contract_address: normalizeHex(SHIELDED_POOL_ADDRESS),
      entry_point_selector: ROOT_SELECTOR,
      calldata: []
    },
    "latest"
  ]);
  return toU256(result);
};

const getVaultBalance = async (user) => {
  if (!COLLATERAL_VAULT_ADDRESS) {
    throw new Error("COLLATERAL_VAULT_ADDRESS is not set.");
  }
  const result = await rpcRequest("starknet_call", [
    {
      contract_address: normalizeHex(COLLATERAL_VAULT_ADDRESS),
      entry_point_selector: VAULT_BALANCE_SELECTOR,
      calldata: [user]
    },
    "latest"
  ]);
  return toU256(result);
};

const getCairoxCollateralToken = async () => {
  if (!CAIROX_TOKEN_ADDRESS) {
    throw new Error("CAIROX_TOKEN_ADDRESS is not set.");
  }
  const result = await rpcRequest("starknet_call", [
    {
      contract_address: normalizeHex(CAIROX_TOKEN_ADDRESS),
      entry_point_selector: COLLATERAL_TOKEN_SELECTOR,
      calldata: []
    },
    "latest"
  ]);
  if (!Array.isArray(result) || result.length < 1) {
    throw new Error("Failed to read collateral token from CAIROX.");
  }
  return normalizeAddress(result[0]);
};

const settleFromVault = async (user, amount, to) => {
  if (!COLLATERAL_VAULT_ADDRESS) {
    throw new Error("COLLATERAL_VAULT_ADDRESS is not set.");
  }
  if (!STARKLI_ACCOUNT || !STARKLI_KEYSTORE || !RPC_URL) {
    throw new Error("STARKLI_ACCOUNT/STARKLI_KEYSTORE/STARKNET_RPC_URL not set.");
  }
  const [low, high] = splitU256(amount);
  const { stdout, stderr } = await runCommand("starkli", [
    "invoke",
    COLLATERAL_VAULT_ADDRESS,
    "settle_to_relayer",
    user,
    low,
    high,
    to,
    "--watch",
    "--account",
    STARKLI_ACCOUNT,
    "--keystore",
    STARKLI_KEYSTORE,
    "--rpc",
    RPC_URL
  ]);
  const combined = `${stdout}\n${stderr}`;
  const match = combined.match(/0x[0-9a-fA-F]{64}/);
  return match ? match[0] : null;
};

const ensureUsdcAllowance = async ({ relayerAddr, minAmount, tokenAddress }) => {
  const current = await getErc20Allowance(tokenAddress, relayerAddr, CAIROX_TOKEN_ADDRESS);
  if (current >= BigInt(minAmount)) return current;

  if (RELAYER_ALLOW_RESET) {
    await runCommand("starkli", [
      "invoke",
      tokenAddress,
      "approve",
      CAIROX_TOKEN_ADDRESS,
      "0",
      "0",
      "--watch",
      "--account",
      STARKLI_ACCOUNT,
      "--keystore",
      STARKLI_KEYSTORE,
      "--rpc",
      RPC_URL
    ]);
  }

  const target =
    RELAYER_USDC_ALLOWANCE_TARGET !== ""
      ? BigInt(RELAYER_USDC_ALLOWANCE_TARGET)
      : RELAYER_USDC_ALLOW_MAX
        ? MAX_U256
        : BigInt(minAmount);
  const [low, high] = splitU256(target);
  await runCommand("starkli", [
    "invoke",
    tokenAddress,
    "approve",
    CAIROX_TOKEN_ADDRESS,
    low,
    high,
    "--watch",
    "--account",
    STARKLI_ACCOUNT,
    "--keystore",
    STARKLI_KEYSTORE,
    "--rpc",
    RPC_URL
  ]);

  const updated = await getErc20Allowance(tokenAddress, relayerAddr, CAIROX_TOKEN_ADDRESS);
  if (updated < BigInt(minAmount)) {
    throw new Error(
      `USDC allowance to CAIROX is still too low. allowance=${updated.toString()} need=${minAmount}`
    );
  }
  return updated;
};

const ensureCairoxAllowance = async ({ relayerAddr, minAmount }) => {
  if (!CAIROX_TOKEN_ADDRESS || !SHIELDED_POOL_ADDRESS) {
    throw new Error("CAIROX_TOKEN_ADDRESS/SHIELDED_POOL_ADDRESS not set.");
  }
  if (!STARKLI_ACCOUNT || !STARKLI_KEYSTORE || !RPC_URL) {
    throw new Error("STARKLI_ACCOUNT/STARKLI_KEYSTORE/STARKNET_RPC_URL not set.");
  }

  const current = await getErc20Allowance(
    CAIROX_TOKEN_ADDRESS,
    relayerAddr,
    normalizeHex(SHIELDED_POOL_ADDRESS)
  );
  if (current >= BigInt(minAmount)) return current;

  if (RELAYER_ALLOW_RESET) {
    await runCommand("starkli", [
      "invoke",
      CAIROX_TOKEN_ADDRESS,
      "approve",
      SHIELDED_POOL_ADDRESS,
      "0",
      "0",
      "--watch",
      "--account",
      STARKLI_ACCOUNT,
      "--keystore",
      STARKLI_KEYSTORE,
      "--rpc",
      RPC_URL
    ]);
  }

  const target =
    RELAYER_CAIROX_ALLOWANCE_TARGET !== ""
      ? BigInt(RELAYER_CAIROX_ALLOWANCE_TARGET)
      : RELAYER_CAIROX_ALLOW_MAX
        ? MAX_U256
        : BigInt(minAmount);
  const [low, high] = splitU256(target);
  await runCommand("starkli", [
    "invoke",
    CAIROX_TOKEN_ADDRESS,
    "approve",
    SHIELDED_POOL_ADDRESS,
    low,
    high,
    "--watch",
    "--account",
    STARKLI_ACCOUNT,
    "--keystore",
    STARKLI_KEYSTORE,
    "--rpc",
    RPC_URL
  ]);

  const updated = await getErc20Allowance(
    CAIROX_TOKEN_ADDRESS,
    relayerAddr,
    normalizeHex(SHIELDED_POOL_ADDRESS)
  );
  if (updated < BigInt(minAmount)) {
    throw new Error(
      `CAIROX allowance to ShieldedPool is still too low. allowance=${updated.toString()} need=${minAmount}`
    );
  }
  return updated;
};

const mintCairox = async (amount, relayerAddr) => {
  if (!CAIROX_TOKEN_ADDRESS) {
    throw new Error("CAIROX_TOKEN_ADDRESS not set.");
  }
  if (!STARKLI_ACCOUNT || !STARKLI_KEYSTORE || !RPC_URL) {
    throw new Error("STARKLI_ACCOUNT/STARKLI_KEYSTORE/STARKNET_RPC_URL not set.");
  }

  const collateralToken = await getCairoxCollateralToken();
  if (USDC_ADDRESS && normalizeAddress(USDC_ADDRESS) !== collateralToken) {
    throw new Error(
      `Collateral token mismatch. CAIROX expects ${collateralToken} but USDC_ADDRESS is ${normalizeAddress(
        USDC_ADDRESS
      )}.`
    );
  }

  await ensureUsdcAllowance({ relayerAddr, minAmount: amount, tokenAddress: collateralToken });

  const [low, high] = splitU256(amount);
  const { stdout, stderr } = await runCommand("starkli", [
    "invoke",
    CAIROX_TOKEN_ADDRESS,
    "deposit_collateral",
    low,
    high,
    "--watch",
    "--account",
    STARKLI_ACCOUNT,
    "--keystore",
    STARKLI_KEYSTORE,
    "--rpc",
    RPC_URL
  ]);
  const combined = `${stdout}\n${stderr}`;
  const match = combined.match(/0x[0-9a-fA-F]{64}/);
  return match ? match[0] : null;
};
const getErc20Balance = async (tokenAddress, owner) => {
  if (!tokenAddress) {
    throw new Error("Token address is not set.");
  }
  const result = await rpcRequest("starknet_call", [
    {
      contract_address: normalizeHex(tokenAddress),
      entry_point_selector: BALANCE_SELECTOR,
      calldata: [owner]
    },
    "latest"
  ]);
  return toU256(result);
};

const getMintedAmountFromReceipt = async (txHash) => {
  if (!txHash) return null;
  const receipt = await rpcRequest("starknet_getTransactionReceipt", [txHash]);
  const events = receipt?.events || [];
  const targetAddr = normalizeAddress(CAIROX_TOKEN_ADDRESS || "");
  const selector = normalizeHex(MINTED_EVENT_SELECTOR);
  for (const event of events) {
    const from = normalizeAddress(event.from_address || event.fromAddress || "");
    if (from !== targetAddr) continue;
    const keys = event.keys || [];
    if (!keys.length || normalizeHex(keys[0]) !== selector) continue;
    const data = event.data || [];
    if (data.length >= 2) {
      return toU256([data[0], data[1]]);
    }
  }
  return null;
};

const getErc20Allowance = async (tokenAddress, owner, spender) => {
  if (!tokenAddress) {
    throw new Error("Token address is not set.");
  }
  const result = await rpcRequest("starknet_call", [
    {
      contract_address: normalizeHex(tokenAddress),
      entry_point_selector: ALLOWANCE_SELECTOR,
      calldata: [owner, spender]
    },
    "latest"
  ]);
  return toU256(result);
};

const getRelayerAddress = () => {
  if (!STARKLI_ACCOUNT) {
    throw new Error("STARKLI_ACCOUNT is not set.");
  }
  const raw = JSON.parse(fs.readFileSync(STARKLI_ACCOUNT, "utf-8"));
  const addr = raw?.deployment?.address;
  if (!addr) {
    throw new Error("Failed to read relayer address from STARKLI_ACCOUNT.");
  }
  return normalizeHex(addr);
};

const toDecimalString = (hex) => {
  if (!hex) return "0";
  if (hex.startsWith("0x") || hex.startsWith("0X")) {
    return BigInt(hex).toString();
  }
  return BigInt(`0x${hex}`).toString();
};

const splitU256 = (value) => {
  const v = BigInt(value);
  const low = v & ((1n << 128n) - 1n);
  const high = v >> 128n;
  return [low.toString(), high.toString()];
};

const randBigIntStr = () => {
  const buf = crypto.randomBytes(31);
  return BigInt(`0x${buf.toString("hex")}`).toString();
};

const poseidonHash = (values) => {
  const inputs = values.map((v) => BigInt(v));
  const out = poseidon(inputs);
  return BigInt(F.toString(out));
};

const toBigInt = (value) => {
  if (typeof value === "bigint") return value;
  if (typeof value === "number") return BigInt(value);
  if (typeof value === "string") {
    const trimmed = value.trim();
    if (trimmed.startsWith("0x")) return BigInt(trimmed);
    return BigInt(trimmed || "0");
  }
  return BigInt(value || 0);
};

const computeCommitment = (note) =>
  poseidonHash([
    toBigInt(note.owner),
    toBigInt(note.asset_id),
    toBigInt(note.market_id),
    toBigInt(note.outcome),
    toBigInt(note.amount),
    toBigInt(note.nonce)
  ]);

const computeNullifier = (commitment, secret) =>
  poseidonHash([toBigInt(commitment), toBigInt(secret)]).toString();

const computeCollateralBalance = (notes = [], marketId = null) => {
  let total = 0n;
  const marketFilter = marketId !== null && marketId !== undefined ? marketId.toString() : null;
  for (const note of notes) {
    if (note?.spent) continue;
    if (note?.asset_id !== "0" || note?.outcome !== "0") continue;
    if (marketFilter !== null && note?.market_id !== marketFilter) continue;
    total += BigInt(note.amount || "0");
  }
  return total;
};

const ensureWalletEntry = (ledger, wallet) => {
  if (!ledger.wallets) ledger.wallets = {};
  const entry = ledger.wallets[wallet] || { confirmed: "0", pending: [], notes: [] };
  entry.pending = Array.isArray(entry.pending) ? entry.pending : [];
  entry.notes = Array.isArray(entry.notes) ? entry.notes : [];
  ledger.wallets[wallet] = entry;
  return entry;
};

const addNotes = (entry, notes = []) => {
  if (!Array.isArray(entry.notes)) entry.notes = [];
  const existing = new Set(entry.notes.map((note) => note?.commitment).filter(Boolean));
  for (const note of notes) {
    if (!note || !note.commitment) continue;
    if (existing.has(note.commitment)) continue;
    entry.notes.push(note);
    existing.add(note.commitment);
  }
};

const markNotesSpent = (entry, notes = [], txHash = null) => {
  if (!Array.isArray(entry.notes)) entry.notes = [];
  const spentIds = new Set(notes.map((note) => note?.commitment).filter(Boolean));
  if (!spentIds.size) return;
  const now = new Date().toISOString();
  entry.notes = entry.notes.map((note) => {
    if (!note || !spentIds.has(note.commitment)) return note;
    return {
      ...note,
      spent: true,
      spent_at: now,
      spent_tx: txHash || note.spent_tx || null
    };
  });
};

const buildTree = (leaves) => {
  let level = leaves.map((v) => BigInt(v));
  if (level.length === 0) level = [0n];
  const levels = [level];
  for (let depth = 0; depth < DEPTH; depth += 1) {
    const prev = levels[levels.length - 1];
    const next = [];
    for (let i = 0; i < prev.length; i += 2) {
      const left = prev[i];
      const right = i + 1 < prev.length ? prev[i + 1] : 0n;
      next.push(poseidonHash([left, right]));
    }
    levels.push(next.length ? next : [0n]);
  }
  return { levels, root: levels[levels.length - 1][0] };
};

const getPath = (levels, index) => {
  const elements = [];
  const indices = [];
  let idx = index;
  for (let depth = 0; depth < DEPTH; depth += 1) {
    const level = levels[depth];
    const isRight = idx % 2 === 1;
    const siblingIndex = isRight ? idx - 1 : idx + 1;
    const sibling = siblingIndex < level.length ? level[siblingIndex] : 0n;
    elements.push(sibling);
    indices.push(isRight ? 1 : 0);
    idx = Math.floor(idx / 2);
  }
  return { elements, indices };
};

const getMarketAddress = (marketId) => {
  const key = `MARKET_ADDRESS_${marketId}`;
  const addr = process.env[key] || getConfigContract(key);
  if (!addr) return "";
  return normalizeAddress(addr);
};

const getMarketState = async (marketAddr) => {
  const [yesSupply, noSupply, bParam, yesPrice, noPrice] = await Promise.all([
    rpcRequest("starknet_call", [
      { contract_address: normalizeHex(marketAddr), entry_point_selector: YES_SUPPLY_SELECTOR, calldata: [] },
      "latest"
    ]),
    rpcRequest("starknet_call", [
      { contract_address: normalizeHex(marketAddr), entry_point_selector: NO_SUPPLY_SELECTOR, calldata: [] },
      "latest"
    ]),
    rpcRequest("starknet_call", [
      { contract_address: normalizeHex(marketAddr), entry_point_selector: B_PARAM_SELECTOR, calldata: [] },
      "latest"
    ]),
    rpcRequest("starknet_call", [
      { contract_address: normalizeHex(marketAddr), entry_point_selector: YES_PRICE_SELECTOR, calldata: [] },
      "latest"
    ]),
    rpcRequest("starknet_call", [
      { contract_address: normalizeHex(marketAddr), entry_point_selector: NO_PRICE_SELECTOR, calldata: [] },
      "latest"
    ])
  ]);

  return {
    yes_supply: toU256(yesSupply),
    no_supply: toU256(noSupply),
    b_param: toU256(bParam),
    price_yes: toU256(yesPrice),
    price_no: toU256(noPrice)
  };
};

const getMarketStateHash = (state, timestamp) =>
  poseidonHash([
    state.yes_supply,
    state.no_supply,
    state.b_param,
    state.price_yes,
    state.price_no,
    timestamp
  ]);

const getCommitmentForMarket = async (marketId) => {
  if (!DATA_COMMITMENT_ADDRESS) return null;
  const commitment = await rpcRequest("starknet_call", [
    {
      contract_address: normalizeHex(DATA_COMMITMENT_ADDRESS),
      entry_point_selector: COMMITMENT_SELECTOR,
      calldata: [marketId]
    },
    "latest"
  ]);
  return toU256(commitment);
};

const getCommitmentUpdatedAt = async (marketId) => {
  if (!DATA_COMMITMENT_ADDRESS) return null;
  const updated = await rpcRequest("starknet_call", [
    {
      contract_address: normalizeHex(DATA_COMMITMENT_ADDRESS),
      entry_point_selector: COMMITMENT_UPDATED_AT_SELECTOR,
      calldata: [marketId]
    },
    "latest"
  ]);
  return toU256(updated);
};

const findStateTimestamp = (state, targetHash, updatedAt) => {
  const base = updatedAt ? Number(updatedAt) : Math.floor(Date.now() / 1000);
  const maxDelta = STATE_TS_WINDOW;
  for (let delta = 0; delta <= maxDelta; delta += 1) {
    const t1 = base - delta;
    const h1 = getMarketStateHash(state, t1);
    if (h1 === targetHash) return t1;
    if (delta === 0) continue;
    const t2 = base + delta;
    const h2 = getMarketStateHash(state, t2);
    if (h2 === targetHash) return t2;
  }
  return null;
};

const calculateBuyTokens = async ({ outcome, amount, state }) => {
  if (!LMSR_ADDRESS) {
    throw new Error("LMSR_ADDRESS not set.");
  }
  const [low, high] = splitU256(amount);
  const [bLow, bHigh] = splitU256(state.b_param);
  const [yesLow, yesHigh] = splitU256(state.yes_supply);
  const [noLow, noHigh] = splitU256(state.no_supply);
  const result = await rpcRequest("starknet_call", [
    {
      contract_address: normalizeHex(LMSR_ADDRESS),
      entry_point_selector: LMSR_BUY_SELECTOR,
      calldata: [
        bLow,
        bHigh,
        yesLow,
        yesHigh,
        noLow,
        noHigh,
        outcome.toString(),
        low,
        high
      ]
    },
    "latest"
  ]);
  return toU256(result);
};

const calculateSellCollateral = async ({ outcome, amount, state }) => {
  if (!LMSR_ADDRESS) {
    throw new Error("LMSR_ADDRESS not set.");
  }
  const [low, high] = splitU256(amount);
  const [bLow, bHigh] = splitU256(state.b_param);
  const [yesLow, yesHigh] = splitU256(state.yes_supply);
  const [noLow, noHigh] = splitU256(state.no_supply);
  const result = await rpcRequest("starknet_call", [
    {
      contract_address: normalizeHex(LMSR_ADDRESS),
      entry_point_selector: LMSR_SELL_SELECTOR,
      calldata: [
        bLow,
        bHigh,
        yesLow,
        yesHigh,
        noLow,
        noHigh,
        outcome.toString(),
        low,
        high
      ]
    },
    "latest"
  ]);
  return toU256(result);
};

const pickCollateralNotes = (notes, marketId, minTotal) => {
  const candidates = notes.filter(
    (note) =>
      !note.spent &&
      note.market_id === marketId &&
      note.asset_id === "0" &&
      note.outcome === "0"
  );
  candidates.sort((a, b) => {
    const left = BigInt(a.amount || "0");
    const right = BigInt(b.amount || "0");
    if (left === right) return 0;
    return left > right ? -1 : 1;
  });
  if (candidates.length < 2) {
    throw new Error("Not enough collateral notes for this market. Deposit CAIROX first.");
  }
  const first = candidates[0];
  const second = candidates[1];
  const total = BigInt(first.amount) + BigInt(second.amount);
  if (total < BigInt(minTotal)) {
    throw new Error("Collateral notes are too small for this trade.");
  }
  return [first, second];
};

const pickExitNotes = (notes, marketId, outcome, amount, fee, collateralOut) => {
  const candidates = notes.filter(
    (note) =>
      !note.spent &&
      note.market_id === marketId &&
      (note.asset_id === "0" ||
        (note.asset_id === (2n - BigInt(outcome)).toString() && note.outcome === outcome))
  );
  if (candidates.length < 2) {
    throw new Error("Not enough notes to exit this market.");
  }
  for (let i = 0; i < candidates.length; i += 1) {
    for (let j = i + 1; j < candidates.length; j += 1) {
      const n1 = candidates[i];
      const n2 = candidates[j];
      const inOutcomeTotal =
        (n1.asset_id !== "0" ? BigInt(n1.amount) : 0n) +
        (n2.asset_id !== "0" ? BigInt(n2.amount) : 0n);
      const inCollateralTotal =
        (n1.asset_id === "0" ? BigInt(n1.amount) : 0n) +
        (n2.asset_id === "0" ? BigInt(n2.amount) : 0n);
      if (inOutcomeTotal < BigInt(amount)) continue;
      if (inCollateralTotal + BigInt(collateralOut) < BigInt(fee)) continue;
      return [n1, n2];
    }
  }
  throw new Error("No valid note pair found for this exit trade.");
};

const pickWithdrawNotes = (notes, marketId, minTotal) => {
  const threshold = BigInt(minTotal);
  const candidates = notes.filter(
    (note) =>
      !note.spent &&
      note.market_id === marketId &&
      note.asset_id === "0" &&
      note.outcome === "0"
  );
  if (candidates.length < 2) {
    throw new Error("Not enough collateral notes in this market. Deposit more CAIROX first.");
  }

  let best = null;
  let bestTotal = null;
  for (let i = 0; i < candidates.length; i += 1) {
    for (let j = i + 1; j < candidates.length; j += 1) {
      const first = candidates[i];
      const second = candidates[j];
      const total = BigInt(first.amount || "0") + BigInt(second.amount || "0");
      if (total < threshold) continue;
      if (bestTotal === null || total < bestTotal) {
        best = [first, second];
        bestTotal = total;
      }
    }
  }
  if (!best) {
    throw new Error("Collateral notes are too small for this withdrawal.");
  }
  return best;
};

const buildTradeInput = async ({
  wallet,
  marketId,
  outcome,
  amount,
  fee,
  action,
  notes,
  outputPath
}) => {
  const ledger = loadLedger();
  const existingLeaves = (ledger.merkle?.leaves || []).map((v) => BigInt(v));
  const { root: localRoot, levels: localLevels } = buildTree(existingLeaves);
  const onchainRoot = await getPoolRoot();
  if (existingLeaves.length > 0 && BigInt(onchainRoot) !== BigInt(localRoot)) {
    if (!RELAYER_ALLOW_RESET) {
      throw new Error("Relayer out of sync with pool root. Set RELAYER_ALLOW_RESET=1 to reset.");
    }
    existingLeaves.length = 0;
  }

  const marketAddr = getMarketAddress(marketId);
  if (!marketAddr) {
    throw new Error("Unknown market id.");
  }
  const state = await getMarketState(marketAddr);
  let stateTimestamp = Math.floor(Date.now() / 1000);
  let stateHash = getMarketStateHash(state, stateTimestamp);

  if (DATA_COMMITMENT_ADDRESS) {
    const commitment = await getCommitmentForMarket(marketId);
    if (!commitment || commitment === 0n) {
      throw new Error(
        "No market state commitment found on-chain. Run the oracle agent to commit state."
      );
    }
    const updatedAt = await getCommitmentUpdatedAt(marketId);
    const matched = findStateTimestamp(state, commitment, updatedAt);
    if (!matched) {
      throw new Error(
        "Unable to match on-chain commitment. Market state timestamp mismatch."
      );
    }
    stateTimestamp = matched;
    stateHash = commitment;
  }

  const outcomeId = BigInt(outcome);
  const outcomeAssetId = (2n - outcomeId).toString();
  let limit;
  if (action === 1n) {
    limit = await calculateBuyTokens({ outcome: outcomeId, amount, state });
  } else if (action === 2n) {
    limit = await calculateSellCollateral({ outcome: outcomeId, amount, state });
  } else {
    limit = BigInt(amount);
  }

  const feeLow = BigInt(fee);
  let inputNotes;
  if (action === 1n) {
    inputNotes = pickCollateralNotes(notes, marketId, BigInt(amount) + feeLow);
  } else {
    inputNotes = pickExitNotes(notes, marketId, outcome.toString(), amount, feeLow, limit);
  }

  const [note1, note2] = inputNotes;
  if (!note1.nullifier_secret) {
    note1.nullifier_secret = randBigIntStr();
  }
  if (!note2.nullifier_secret) {
    note2.nullifier_secret = randBigIntStr();
  }

  const commitment1 = computeCommitment(note1);
  const commitment2 = computeCommitment(note2);

  const idx1 = note1.index ?? existingLeaves.findIndex((v) => v === commitment1);
  const idx2 = note2.index ?? existingLeaves.findIndex((v) => v === commitment2);
  if (idx1 < 0 || idx2 < 0) {
    throw new Error("Input notes not found in merkle tree.");
  }

  const path1 = getPath(localLevels, idx1);
  const path2 = getPath(localLevels, idx2);

  const inOutcomeTotal =
    (note1.asset_id !== "0" ? BigInt(note1.amount) : 0n) +
    (note2.asset_id !== "0" ? BigInt(note2.amount) : 0n);
  const inCollateralTotal =
    (note1.asset_id === "0" ? BigInt(note1.amount) : 0n) +
    (note2.asset_id === "0" ? BigInt(note2.amount) : 0n);

  let outAmount1;
  let outAmount2;
  let outAsset1;
  let outOutcome1;
  let outAsset2;
  let outOutcome2;

  if (action === 1n) {
    outAmount1 = limit;
    outAmount2 = inCollateralTotal - BigInt(amount) - feeLow;
    outAsset1 = outcomeAssetId;
    outOutcome1 = outcome.toString();
    outAsset2 = "0";
    outOutcome2 = "0";
  } else {
    outAmount1 = inCollateralTotal + BigInt(limit) - feeLow;
    outAmount2 = inOutcomeTotal - BigInt(amount);
    outAsset1 = "0";
    outOutcome1 = "0";
    outAsset2 = outcomeAssetId;
    outOutcome2 = outcome.toString();
  }

  const outNonce1 = randBigIntStr();
  const outNonce2 = randBigIntStr();
  const outCommit1 = poseidonHash([
    wallet,
    outAsset1,
    marketId,
    outOutcome1,
    outAmount1.toString(),
    outNonce1
  ]);
  const outCommit2 = poseidonHash([
    wallet,
    outAsset2,
    marketId,
    outOutcome2,
    outAmount2.toString(),
    outNonce2
  ]);

  const newLeaves = existingLeaves.concat([outCommit1, outCommit2]);
  const { levels, root: newRoot } = buildTree(newLeaves);
  const newIndex1 = existingLeaves.length;
  const newIndex2 = existingLeaves.length + 1;
  const outPath1 = getPath(levels, newIndex1);
  const outPath2 = getPath(levels, newIndex2);

  const input = {
    old_root: BigInt(onchainRoot).toString(),
    new_root: newRoot.toString(),
    nullifier1: computeNullifier(commitment1, note1.nullifier_secret),
    nullifier2: computeNullifier(commitment2, note2.nullifier_secret),
    market_state_hash: stateHash.toString(),
    action: action.toString(),
    market_id: marketId,
    outcome: outcome.toString(),
    amount_low: amount.toString(),
    amount_high: "0",
    limit_low: limit.toString(),
    limit_high: "0",
    relayer: toDecimalString(getRelayerAddress()),
    fee_low: feeLow.toString(),
    fee_high: "0",
    recipient: "0",

    in_owner_pubkey1: note1.owner,
    in_asset_id1: note1.asset_id,
    in_market_id1: note1.market_id,
    in_outcome1: note1.outcome,
    in_amount1: note1.amount,
    in_nonce1: note1.nonce,
    in_owner_pubkey2: note2.owner,
    in_asset_id2: note2.asset_id,
    in_market_id2: note2.market_id,
    in_outcome2: note2.outcome,
    in_amount2: note2.amount,
    in_nonce2: note2.nonce,
    in_nullifier_secret1: note1.nullifier_secret,
    in_nullifier_secret2: note2.nullifier_secret,
    in_path_elements1: path1.elements.map((v) => v.toString()),
    in_path_elements2: path2.elements.map((v) => v.toString()),
    in_path_indices1: path1.indices,
    in_path_indices2: path2.indices,

    out_owner_pubkey1: wallet,
    out_asset_id1: outAsset1,
    out_market_id1: marketId,
    out_outcome1: outOutcome1,
    out_amount1: outAmount1.toString(),
    out_nonce1: outNonce1,
    out_owner_pubkey2: wallet,
    out_asset_id2: outAsset2,
    out_market_id2: marketId,
    out_outcome2: outOutcome2,
    out_amount2: outAmount2.toString(),
    out_nonce2: outNonce2,
    out_path_elements1: outPath1.elements.map((v) => v.toString()),
    out_path_elements2: outPath2.elements.map((v) => v.toString()),
    out_path_indices1: outPath1.indices,
    out_path_indices2: outPath2.indices,

    yes_supply: state.yes_supply.toString(),
    no_supply: state.no_supply.toString(),
    b_param: state.b_param.toString(),
    price_yes: state.price_yes.toString(),
    price_no: state.price_no.toString(),
    state_timestamp: stateTimestamp.toString()
  };

  fs.writeFileSync(outputPath, JSON.stringify(input, null, 2));

  return {
    input,
    newLeaves,
    newRoot,
    inputNotes: [note1, note2],
    outputNotes: [
      {
        owner: wallet,
        asset_id: outAsset1,
        market_id: marketId,
        outcome: outOutcome1,
        amount: outAmount1.toString(),
        nonce: outNonce1,
        commitment: outCommit1.toString(),
        nullifier_secret: randBigIntStr(),
        spent: false,
        index: newIndex1
      },
      {
        owner: wallet,
        asset_id: outAsset2,
        market_id: marketId,
        outcome: outOutcome2,
        amount: outAmount2.toString(),
        nonce: outNonce2,
        commitment: outCommit2.toString(),
        nullifier_secret: randBigIntStr(),
        spent: false,
        index: newIndex2
      }
    ]
  };
};

const buildWithdrawInput = async ({
  wallet,
  marketId,
  amount,
  fee,
  recipient,
  notes,
  outputPath
}) => {
  const ledger = loadLedger();
  const existingLeaves = (ledger.merkle?.leaves || []).map((v) => BigInt(v));
  const { root: localRoot, levels: localLevels } = buildTree(existingLeaves);
  const onchainRoot = await getPoolRoot();
  if (existingLeaves.length > 0 && BigInt(onchainRoot) !== BigInt(localRoot)) {
    if (!RELAYER_ALLOW_RESET) {
      throw new Error("Relayer out of sync with pool root. Set RELAYER_ALLOW_RESET=1 to reset.");
    }
    existingLeaves.length = 0;
  }

  const [note1, note2] = pickWithdrawNotes(
    notes,
    marketId,
    BigInt(amount)
  );

  if (!note1.nullifier_secret) note1.nullifier_secret = randBigIntStr();
  if (!note2.nullifier_secret) note2.nullifier_secret = randBigIntStr();

  const commitment1 = computeCommitment(note1);
  const commitment2 = computeCommitment(note2);
  const idx1 = note1.index ?? existingLeaves.findIndex((v) => v === commitment1);
  const idx2 = note2.index ?? existingLeaves.findIndex((v) => v === commitment2);
  if (idx1 < 0 || idx2 < 0) {
    throw new Error("Input notes not found in merkle tree.");
  }

  const path1 = getPath(localLevels, idx1);
  const path2 = getPath(localLevels, idx2);
  const inCollateralTotal = BigInt(note1.amount || "0") + BigInt(note2.amount || "0");
  const outTotal = inCollateralTotal - BigInt(amount);
  if (outTotal < 0n) {
    throw new Error("Withdrawal exceeds spendable collateral notes.");
  }
  const outAmount1 = outTotal / 2n;
  const outAmount2 = outTotal - outAmount1;

  const outNonce1 = randBigIntStr();
  const outNonce2 = randBigIntStr();
  const outCommit1 = poseidonHash([wallet, "0", marketId, "0", outAmount1.toString(), outNonce1]);
  const outCommit2 = poseidonHash([wallet, "0", marketId, "0", outAmount2.toString(), outNonce2]);

  const newLeaves = existingLeaves.concat([outCommit1, outCommit2]);
  const { levels, root: newRoot } = buildTree(newLeaves);
  const newIndex1 = existingLeaves.length;
  const newIndex2 = existingLeaves.length + 1;
  const outPath1 = getPath(levels, newIndex1);
  const outPath2 = getPath(levels, newIndex2);

  const input = {
    old_root: BigInt(onchainRoot).toString(),
    new_root: newRoot.toString(),
    nullifier1: computeNullifier(commitment1, note1.nullifier_secret),
    nullifier2: computeNullifier(commitment2, note2.nullifier_secret),
    market_state_hash: "0",
    action: "5",
    market_id: marketId,
    outcome: "0",
    amount_low: BigInt(amount).toString(),
    amount_high: "0",
    limit_low: "0",
    limit_high: "0",
    relayer: toDecimalString(getRelayerAddress()),
    fee_low: BigInt(fee).toString(),
    fee_high: "0",
    recipient: toDecimalString(recipient),

    in_owner_pubkey1: note1.owner,
    in_asset_id1: note1.asset_id,
    in_market_id1: note1.market_id,
    in_outcome1: note1.outcome,
    in_amount1: note1.amount,
    in_nonce1: note1.nonce,
    in_owner_pubkey2: note2.owner,
    in_asset_id2: note2.asset_id,
    in_market_id2: note2.market_id,
    in_outcome2: note2.outcome,
    in_amount2: note2.amount,
    in_nonce2: note2.nonce,
    in_nullifier_secret1: note1.nullifier_secret,
    in_nullifier_secret2: note2.nullifier_secret,
    in_path_elements1: path1.elements.map((v) => v.toString()),
    in_path_elements2: path2.elements.map((v) => v.toString()),
    in_path_indices1: path1.indices,
    in_path_indices2: path2.indices,

    out_owner_pubkey1: wallet,
    out_asset_id1: "0",
    out_market_id1: marketId,
    out_outcome1: "0",
    out_amount1: outAmount1.toString(),
    out_nonce1: outNonce1,
    out_owner_pubkey2: wallet,
    out_asset_id2: "0",
    out_market_id2: marketId,
    out_outcome2: "0",
    out_amount2: outAmount2.toString(),
    out_nonce2: outNonce2,
    out_path_elements1: outPath1.elements.map((v) => v.toString()),
    out_path_elements2: outPath2.elements.map((v) => v.toString()),
    out_path_indices1: outPath1.indices,
    out_path_indices2: outPath2.indices,

    yes_supply: "0",
    no_supply: "0",
    b_param: "1",
    price_yes: "1000000000000000000",
    price_no: "1000000000000000000",
    state_timestamp: "0"
  };

  fs.writeFileSync(outputPath, JSON.stringify(input, null, 2));

  return {
    input,
    newLeaves,
    newRoot,
    inputNotes: [note1, note2],
    outputNotes: [
      {
        owner: wallet,
        asset_id: "0",
        market_id: marketId,
        outcome: "0",
        amount: outAmount1.toString(),
        nonce: outNonce1,
        commitment: outCommit1.toString(),
        nullifier_secret: randBigIntStr(),
        spent: false,
        index: newIndex1
      },
      {
        owner: wallet,
        asset_id: "0",
        market_id: marketId,
        outcome: "0",
        amount: outAmount2.toString(),
        nonce: outNonce2,
        commitment: outCommit2.toString(),
        nullifier_secret: randBigIntStr(),
        spent: false,
        index: newIndex2
      }
    ]
  };
};

const parseAmountToBaseUnits = (raw) => {
  const trimmed = (raw || "").toString().trim();
  if (!trimmed) return "";
  if (!/^[0-9]+(\.[0-9]+)?$/.test(trimmed)) {
    throw new Error("Amount must be a positive number.");
  }
  if (RELAYER_AMOUNT_IN_BASE_UNITS) {
    if (trimmed.includes(".")) {
      throw new Error("Amount must be an integer in base units.");
    }
    return BigInt(trimmed).toString();
  }
  if (!trimmed.includes(".")) {
    const scale = BigInt(10) ** BigInt(RELAYER_AMOUNT_DECIMALS);
    return (BigInt(trimmed) * scale).toString();
  }

  const [whole, frac = ""] = trimmed.split(".");
  if (frac.length > RELAYER_AMOUNT_DECIMALS) {
    throw new Error(`Amount supports up to ${RELAYER_AMOUNT_DECIMALS} decimal places.`);
  }
  const fracPadded = (frac + "0".repeat(RELAYER_AMOUNT_DECIMALS)).slice(0, RELAYER_AMOUNT_DECIMALS);
  const wholeValue = BigInt(whole || "0") * (BigInt(10) ** BigInt(RELAYER_AMOUNT_DECIMALS));
  const fracValue = BigInt(fracPadded || "0");
  return (wholeValue + fracValue).toString();
};

const validateAmountString = (raw) => {
  const trimmed = (raw || "").toString().trim();
  if (!/^[0-9]+(\.[0-9]+)?$/.test(trimmed)) {
    throw new Error("Amount must be a positive number.");
  }
  if (RELAYER_AMOUNT_IN_BASE_UNITS && trimmed.includes(".")) {
    throw new Error("Amount must be an integer in base units.");
  }
  if (!RELAYER_AMOUNT_IN_BASE_UNITS && trimmed.includes(".")) {
    const [whole, frac = ""] = trimmed.split(".");
    if (frac.length > RELAYER_AMOUNT_DECIMALS) {
      throw new Error(`Amount supports up to ${RELAYER_AMOUNT_DECIMALS} decimal places.`);
    }
    if (!whole.length) {
      throw new Error("Amount must include a whole-number component.");
    }
  }
  return trimmed;
};

const parseOutcome = (value) => {
  const raw = (value || "").toString().trim().toLowerCase();
  if (raw === "yes" || raw === "1") return "1";
  if (raw === "no" || raw === "0") return "0";
  throw new Error("Outcome must be yes/no or 1/0.");
};

const parseTradeAction = (value) => {
  const raw = (value || "").toString().trim().toLowerCase();
  if (!raw || raw === "buy" || raw === "1") return 1n;
  if (raw === "sell" || raw === "2") return 2n;
  if (raw === "redeem" || raw === "3") return 3n;
  throw new Error("Action must be buy/sell/redeem or 1/2/3.");
};

const buildStarkliEnv = () => {
  const env = { ...process.env };
  if (RPC_URL) {
    env.STARKNET_RPC = RPC_URL;
    env.STARKNET_RPC_URL = RPC_URL;
  }
  delete env.STARKNET_NETWORK;
  return env;
};

const runCommand = (cmd, args, opts = {}) =>
  new Promise((resolve, reject) => {
    const spawnOpts = { ...opts, stdio: ["ignore", "pipe", "pipe"] };
    if (cmd === "starkli") {
      spawnOpts.env = { ...buildStarkliEnv(), ...(opts.env || {}) };
    }
    const child = spawn(cmd, args, spawnOpts);
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => {
      stdout += d.toString();
    });
    child.stderr.on("data", (d) => {
      stderr += d.toString();
    });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) {
        resolve({ stdout, stderr });
      } else {
        reject(new Error(stderr || `Command failed (${cmd})`));
      }
    });
  });

const createDepositInput = async ({ wallet, amount, outputPath, marketId = "0" }) => {
  const template = JSON.parse(fs.readFileSync(INPUT_TEMPLATE, "utf-8"));
  const relayerHex = getRelayerAddress();

  const ledger = loadLedger();
  const merkle = ledger.merkle || { leaves: [] };
  const existingLeaves = (merkle.leaves || []).map((v) => BigInt(v));
  const { root: localRoot, levels: localLevels } = buildTree(existingLeaves);
  const onchainRoot = await getPoolRoot();

  if (existingLeaves.length > 0 && BigInt(onchainRoot) !== BigInt(localRoot)) {
    if (!RELAYER_ALLOW_RESET) {
      throw new Error("Relayer out of sync with pool root. Set RELAYER_ALLOW_RESET=1 to reset.");
    }
    existingLeaves.length = 0;
  }

  const marketIdStr = marketId.toString();
  template.market_id = marketIdStr;
  template.in_market_id1 = marketIdStr;
  template.in_market_id2 = marketIdStr;
  template.out_market_id1 = marketIdStr;
  template.out_market_id2 = marketIdStr;

  template.amount_low = amount;
  template.amount_high = "0";
  template.fee_low = RELAYER_FEE_LOW;
  template.fee_high = RELAYER_FEE_HIGH;
  template.relayer = toDecimalString(relayerHex);
  template.recipient = "0";
  template.old_root = BigInt(onchainRoot).toString();

  const net = BigInt(template.amount_low) - BigInt(template.fee_low);
  const out1Amount = net / 2n;
  const out2Amount = net - out1Amount;

  template.out_owner_pubkey1 = wallet;
  template.out_owner_pubkey2 = wallet;
  template.out_amount1 = out1Amount.toString();
  template.out_amount2 = out2Amount.toString();

  template.out_nonce1 = randBigIntStr();
  template.out_nonce2 = randBigIntStr();
  template.in_nonce1 = randBigIntStr();
  template.in_nonce2 = randBigIntStr();
  template.in_nullifier_secret1 = randBigIntStr();
  template.in_nullifier_secret2 = randBigIntStr();

  delete template.out_nullifier_secret1;
  delete template.out_nullifier_secret2;

  const in1 = [
    template.in_owner_pubkey1,
    template.in_asset_id1,
    template.in_market_id1,
    template.in_outcome1,
    template.in_amount1,
    template.in_nonce1
  ];
  const in2 = [
    template.in_owner_pubkey2,
    template.in_asset_id2,
    template.in_market_id2,
    template.in_outcome2,
    template.in_amount2,
    template.in_nonce2
  ];

  const commit1 = poseidonHash(in1);
  const commit2 = poseidonHash(in2);
  template.nullifier1 = poseidonHash([commit1, template.in_nullifier_secret1]).toString();
  template.nullifier2 = poseidonHash([commit2, template.in_nullifier_secret2]).toString();

  const out1 = [
    template.out_owner_pubkey1,
    template.out_asset_id1,
    template.out_market_id1,
    template.out_outcome1,
    template.out_amount1,
    template.out_nonce1
  ];
  const out2 = [
    template.out_owner_pubkey2,
    template.out_asset_id2,
    template.out_market_id2,
    template.out_outcome2,
    template.out_amount2,
    template.out_nonce2
  ];
  const leaf1 = poseidonHash(out1);
  const leaf2 = poseidonHash(out2);

  const newLeaves = existingLeaves.concat([leaf1, leaf2]);
  const { levels, root: newRoot } = buildTree(newLeaves);
  const index1 = existingLeaves.length;
  const index2 = existingLeaves.length + 1;
  const path1 = getPath(levels, index1);
  const path2 = getPath(levels, index2);

  template.out_path_elements1 = path1.elements.map((v) => v.toString());
  template.out_path_elements2 = path2.elements.map((v) => v.toString());
  template.out_path_indices1 = path1.indices;
  template.out_path_indices2 = path2.indices;
  template.new_root = newRoot.toString();

  fs.writeFileSync(outputPath, JSON.stringify(template, null, 2));

  const outputNotes = [
    {
      owner: wallet,
      asset_id: template.out_asset_id1.toString(),
      market_id: marketIdStr,
      outcome: template.out_outcome1.toString(),
      amount: template.out_amount1.toString(),
      nonce: template.out_nonce1.toString(),
      commitment: leaf1.toString(),
      nullifier_secret: randBigIntStr(),
      spent: false,
      index: index1
    },
    {
      owner: wallet,
      asset_id: template.out_asset_id2.toString(),
      market_id: marketIdStr,
      outcome: template.out_outcome2.toString(),
      amount: template.out_amount2.toString(),
      nonce: template.out_nonce2.toString(),
      commitment: leaf2.toString(),
      nullifier_secret: randBigIntStr(),
      spent: false,
      index: index2
    }
  ];

  return { newLeaves, newRoot, outputNotes };
};

const generateProof = async ({ inputPath, proofDir }) => {
  const wtnsPath = path.join(proofDir, "witness.wtns");
  const proofJson = path.join(proofDir, "proof.json");
  const publicJson = path.join(proofDir, "public.json");
  const calldataPath = path.join(proofDir, "proof.calldata");

  await runCommand("node", [
    path.resolve(ROOT_DIR, "zk/build/shielded_transact_js/generate_witness.js"),
    WASM_PATH,
    inputPath,
    wtnsPath
  ]);

  await runCommand("node", [
    SNARKJS_BIN,
    "groth16",
    "prove",
    ZKEY_PATH,
    wtnsPath,
    proofJson,
    publicJson
  ]);

  const { stdout } = await runCommand(GARAGA_BIN, [
    "calldata",
    "--system",
    "groth16",
    "--vk",
    VK_PATH,
    "--proof",
    proofJson,
    "--public-inputs",
    publicJson,
    "--format",
    "starkli"
  ]);
  fs.writeFileSync(calldataPath, stdout.trim() + "\n");

  return { proofJson, publicJson, calldataPath };
};

const submitDeposit = async ({ publicJson, calldataPath }) => {
  if (!SHIELDED_POOL_ADDRESS) {
    throw new Error("SHIELDED_POOL_ADDRESS is not set.");
  }
  if (!STARKLI_ACCOUNT || !STARKLI_KEYSTORE || !RPC_URL) {
    throw new Error("STARKLI_ACCOUNT/STARKLI_KEYSTORE/STARKNET_RPC_URL not set.");
  }
  const { stdout, stderr } = await runCommand("python3", [
    path.resolve(ROOT_DIR, "scripts/relayer_transact.py"),
    "--pool",
    SHIELDED_POOL_ADDRESS,
    "--public-inputs",
    publicJson,
    "--proof",
    calldataPath,
    "--action",
    "deposit",
    "--proof-has-len",
    "--watch",
    "--account",
    STARKLI_ACCOUNT,
    "--keystore",
    STARKLI_KEYSTORE,
    "--rpc",
    RPC_URL
  ]);
  const combined = `${stdout}\n${stderr}`;
  const invokeMatch = combined.match(/Invoke transaction:\s*(0x[0-9a-fA-F]{64})/);
  if (invokeMatch) {
    return invokeMatch[1];
  }
  const all = combined.match(/0x[0-9a-fA-F]{64}/g) || [];
  return all.length ? all[all.length - 1] : null;
};

const submitTrade = async ({ publicJson, calldataPath }) => {
  if (!SHIELDED_POOL_ADDRESS) {
    throw new Error("SHIELDED_POOL_ADDRESS is not set.");
  }
  if (!STARKLI_ACCOUNT || !STARKLI_KEYSTORE || !RPC_URL) {
    throw new Error("STARKLI_ACCOUNT/STARKLI_KEYSTORE/STARKNET_RPC_URL not set.");
  }
  const { stdout, stderr } = await runCommand("python3", [
    path.resolve(ROOT_DIR, "scripts/relayer_transact.py"),
    "--pool",
    SHIELDED_POOL_ADDRESS,
    "--public-inputs",
    publicJson,
    "--proof",
    calldataPath,
    "--action",
    "trade",
    "--proof-has-len",
    "--watch",
    "--account",
    STARKLI_ACCOUNT,
    "--keystore",
    STARKLI_KEYSTORE,
    "--rpc",
    RPC_URL
  ]);
  const combined = `${stdout}\n${stderr}`;
  const invokeMatch = combined.match(/Invoke transaction:\s*(0x[0-9a-fA-F]{64})/);
  if (invokeMatch) {
    return invokeMatch[1];
  }
  const all = combined.match(/0x[0-9a-fA-F]{64}/g) || [];
  return all.length ? all[all.length - 1] : null;
};

const submitWithdraw = async ({ publicJson, calldataPath }) => {
  if (!SHIELDED_POOL_ADDRESS) {
    throw new Error("SHIELDED_POOL_ADDRESS is not set.");
  }
  if (!STARKLI_ACCOUNT || !STARKLI_KEYSTORE || !RPC_URL) {
    throw new Error("STARKLI_ACCOUNT/STARKLI_KEYSTORE/STARKNET_RPC_URL not set.");
  }
  const { stdout, stderr } = await runCommand("python3", [
    path.resolve(ROOT_DIR, "scripts/relayer_transact.py"),
    "--pool",
    SHIELDED_POOL_ADDRESS,
    "--public-inputs",
    publicJson,
    "--proof",
    calldataPath,
    "--action",
    "withdraw",
    "--proof-has-len",
    "--watch",
    "--account",
    STARKLI_ACCOUNT,
    "--keystore",
    STARKLI_KEYSTORE,
    "--rpc",
    RPC_URL
  ]);
  const combined = `${stdout}\n${stderr}`;
  const invokeMatch = combined.match(/Invoke transaction:\s*(0x[0-9a-fA-F]{64})/);
  if (invokeMatch) {
    return invokeMatch[1];
  }
  const all = combined.match(/0x[0-9a-fA-F]{64}/g) || [];
  return all.length ? all[all.length - 1] : null;
};

const isValidTxHash = (value) => {
  if (!value) return false;
  if (!TX_HASH_RE.test(value)) return false;
  if (!SHIELDED_POOL_ADDRESS) return true;
  return normalizeHex(value) !== normalizeHex(SHIELDED_POOL_ADDRESS);
};

const updateWalletFromReceipts = async (wallet, walletData) => {
  if (!walletData?.pending?.length) {
    return walletData;
  }
  const filtered = walletData.pending.filter((p) => isValidTxHash(p.tx_hash));
  if (filtered.length !== walletData.pending.length) {
    walletData = { ...walletData, pending: filtered };
  }
  const remaining = [];
  let confirmedBalance = BigInt(walletData.confirmed || "0");

  for (const pending of walletData.pending) {
    try {
      const receipt = await rpcRequest("starknet_getTransactionReceipt", [
        pending.tx_hash
      ]);
      const finality = receipt.finality_status || receipt.status;
      const execution = receipt.execution_status || receipt.status;
      const okFinal = finality === "ACCEPTED_ON_L2" || finality === "ACCEPTED_ON_L1";
      const okExec = execution === "SUCCEEDED" || execution === "ACCEPTED_ON_L2";
      // Treat L2 acceptance as confirmed for UX. L1 finality will lag.
      if (okFinal && okExec) {
        const kind = (pending.kind || pending.type || "deposit").toString();
        if (kind === "deposit") {
          confirmedBalance += BigInt(pending.amount || "0");
        }
        continue;
      }
      remaining.push(pending);
    } catch {
      remaining.push(pending);
    }
  }

  return {
    ...walletData,
    confirmed: confirmedBalance.toString(),
    pending: remaining
  };
};

app.get("/health", (_req, res) => {
  res.json({ ok: true, service: "cairox-relayer" });
});

app.get("/debug/allowance", requireRelayerAuth, requireDebugEnabled, async (_req, res) => {
  try {
    const relayerAddr = getRelayerAddress();
    const collateralToken = await getCairoxCollateralToken();
    const usdcAllowance = await getErc20Allowance(
      collateralToken,
      relayerAddr,
      normalizeHex(CAIROX_TOKEN_ADDRESS || "")
    );
    const usdcBalance = await getErc20Balance(collateralToken, relayerAddr);
    const cairoxBalance = await getErc20Balance(CAIROX_TOKEN_ADDRESS, relayerAddr);
    res.json({
      relayer: relayerAddr,
      usdc: collateralToken,
      cairox: CAIROX_TOKEN_ADDRESS,
      vault: COLLATERAL_VAULT_ADDRESS,
      shielded_pool: SHIELDED_POOL_ADDRESS,
      usdc_allowance_to_cairox: usdcAllowance.toString(),
      usdc_balance: usdcBalance.toString(),
      cairox_balance: cairoxBalance.toString()
    });
  } catch (err) {
    res.status(500).json({ error: err.message || "Failed to fetch allowance." });
  }
});

app.get("/vault_balance", requireRelayerAuth, async (req, res) => {
  const wallet = (req.query.wallet || "").toString().trim();
  if (!wallet) {
    res.status(400).json({ error: "Wallet address is required." });
    return;
  }
  try {
    const account = normalizeAddress(wallet);
    const balance = await getVaultBalance(account);
    res.json({ wallet: account, balance: balance.toString() });
  } catch (err) {
    res.status(500).json({ error: err.message || "Failed to fetch vault balance." });
  }
});

app.get("/debug/price", requireRelayerAuth, requireDebugEnabled, async (_req, res) => {
  try {
    if (!CAIROX_TOKEN_ADDRESS) {
      res.status(400).json({ error: "CAIROX_TOKEN_ADDRESS not set." });
      return;
    }
    const { feed, feedType, maxAge } = await getPriceFeedInfo();
    const decimals = await getCairoxPriceDecimals();
    const latestPrice = await getCairoxLatestPrice();
    const updatedAt = await getCairoxPriceUpdatedAt();
    const lock = await getPriceLockStatus();
    const now = await getLatestBlockTimestamp();
    const stale =
      maxAge !== 0n && now >= updatedAt ? now - updatedAt > maxAge : false;

    res.json({
      cairox: normalizeAddress(CAIROX_TOKEN_ADDRESS),
      feed,
      feed_type: feedType,
      price_decimals: decimals,
      latest_price: latestPrice.toString(),
      updated_at: updatedAt.toString(),
      max_age: maxAge.toString(),
      price_locked: lock.locked,
      locked_price: lock.lockedPrice.toString(),
      now: now.toString(),
      stale
    });
  } catch (err) {
    res.status(500).json({ error: err.message || "Failed to fetch price info." });
  }
});

app.get("/balance", requireRelayerAuth, async (req, res) => {
  const wallet = (req.query.wallet || "").toString();
  if (!wallet) {
    res.status(400).json({ error: "Wallet address is required." });
    return;
  }
  const accountAddress = canonicalWallet(wallet);
  if (!ADDRESS_RE.test(accountAddress)) {
    res.status(400).json({ error: "Invalid wallet address." });
    return;
  }

  try {
    const marketIdRaw = (req.query.market_id || "").toString().trim();
    let marketId = "";
    if (marketIdRaw) {
      try {
        marketId = normalizeFelt(marketIdRaw, "");
      } catch {
        res.status(400).json({ error: "Invalid market_id." });
        return;
      }
    }
    const ledger = loadLedger();
    const entry = ensureWalletEntry(ledger, accountAddress);
    const updated = await updateWalletFromReceipts(accountAddress, entry);
    ledger.wallets[accountAddress] = updated;
    saveLedger(ledger);

    const notes = Array.isArray(updated.notes) ? updated.notes : [];
    const noteBalance = computeCollateralBalance(
      notes,
      marketId === "" ? null : marketId
    );
    const legacyBalance = updated.confirmed || "0";
    const tradeableBalance = noteBalance.toString();
    const confirmedBalance = tradeableBalance;

    const pending = Array.isArray(updated.pending) ? updated.pending : [];
    const confirmed = pending.length === 0;
    res.json({
      wallet: accountAddress,
      balance: confirmedBalance,
      tradeable_balance: tradeableBalance,
      legacy_balance: legacyBalance,
      notes_count: notes.length,
      market_id: marketId || null,
      unit: "CAIROX",
      mechanism: "shielded_pool",
      source: "relayer",
      confirmed,
      pending,
      pending_count: pending.length,
      warning:
        notes.length === 0 && BigInt(legacyBalance || "0") > 0n
          ? "Legacy shielded balance detected without spendable notes. New deposits are required for trading."
          : null
    });
  } catch (err) {
    res.status(500).json({ error: err.message || "Failed to fetch balance." });
  }
});

app.post("/deposit", requireRelayerAuth, async (req, res) => {
  const wallet = (req.body?.wallet || "").toString().trim();
  const amountRaw = (req.body?.amount || "").toString().trim();
  const marketIdRaw = (req.body?.market_id || req.body?.marketId || "").toString().trim();

  if (!wallet || !amountRaw) {
    res.status(400).json({ error: "Wallet and amount are required." });
    return;
  }
  try {
    validateAmountString(amountRaw);
  } catch (err) {
    res.status(400).json({ error: err.message || "Amount must be a positive number." });
    return;
  }

  const accountAddress = canonicalWallet(wallet);
  if (!ADDRESS_RE.test(accountAddress)) {
    res.status(400).json({ error: "Invalid wallet address." });
    return;
  }

  let tmpDir = "";
  try {
    if (!marketIdRaw) {
      res.status(400).json({ error: "market_id is required to mint shielded CAIROX." });
      return;
    }
    const marketId = normalizeFelt(marketIdRaw, "0");
    ensureDir(TMP_DIR);
    tmpDir = fs.mkdtempSync(path.join(TMP_DIR, "job-"));
    const inputPath = path.join(tmpDir, "input.json");

    const amount = parseAmountToBaseUnits(amountRaw);
    if (!amount || BigInt(amount) <= 0n) {
      res.status(400).json({ error: "Amount must be greater than zero." });
      return;
    }
    if (BigInt(amount) < BigInt(RELAYER_FEE_LOW)) {
      res.status(400).json({ error: "Amount must be greater than relayer fee." });
      return;
    }

    const relayerAddr = getRelayerAddress();
    const collateralToken = await getCairoxCollateralToken();
    if (USDC_ADDRESS && normalizeAddress(USDC_ADDRESS) !== collateralToken) {
      res.status(400).json({
        error: `Collateral token mismatch. CAIROX expects ${collateralToken} but USDC_ADDRESS is ${normalizeAddress(
          USDC_ADDRESS
        )}.`
      });
      return;
    }

    await ensureFreshPrice();
    await ensurePriceLocked();

    let estimatedMint = await estimateMintedAmount(amount);
    if (estimatedMint <= 0n && process.env.RELAYER_ORACLE_PRICE) {
      await updateOraclePrice();
      estimatedMint = await estimateMintedAmount(amount);
    }
    if (estimatedMint <= 0n) {
      res.status(400).json({
        error:
          "Minted amount is zero at current oracle price. Try a larger deposit or refresh the oracle price."
      });
      return;
    }
    if (RELAYER_ENFORCE_PEG && estimatedMint !== BigInt(amount)) {
      res.status(400).json({
        error:
          "Oracle price is not 1:1. Set RELAYER_ORACLE_PRICE to the 1.0 peg and retry."
      });
      return;
    }

    let settleTx;
    try {
      settleTx = await settleFromVault(accountAddress, amount, relayerAddr);
    } catch (err) {
      const message = err instanceof Error ? err.message : "Vault settlement failed.";
      if (message.includes("Insufficient balance")) {
        res.status(400).json({
          error: "Vault balance too low. Deposit USDC into the vault first."
        });
        return;
      }
      res.status(400).json({ error: message });
      return;
    }

    const relayerUsdc = await getErc20Balance(collateralToken, relayerAddr);
    if (relayerUsdc < BigInt(amount)) {
      res.status(400).json({
        error: "Relayer USDC balance too low after vault settlement."
      });
      return;
    }

    const cairoxBefore = await getErc20Balance(CAIROX_TOKEN_ADDRESS, relayerAddr);
    const mintTx = await mintCairox(amount, relayerAddr);
    const receiptMinted = await getMintedAmountFromReceipt(mintTx).catch(() => null);
    const cairoxAfter = await getErc20Balance(CAIROX_TOKEN_ADDRESS, relayerAddr);
    const balanceDiff = cairoxAfter - cairoxBefore;
    const mintedAmount =
      receiptMinted !== null ? receiptMinted : balanceDiff;
    if (mintedAmount <= 0n) {
      res.status(400).json({
        error:
          "Minted amount is zero at current oracle price. Try a larger deposit or refresh the oracle price."
      });
      return;
    }

    const depositAmount = mintedAmount;
    if (depositAmount < BigInt(RELAYER_FEE_LOW)) {
      res.status(400).json({
        error: "Minted amount is too small to cover the relayer fee."
      });
      return;
    }

    if (RELAYER_AUTO_APPROVE) {
      await ensureCairoxAllowance({ relayerAddr, minAmount: depositAmount });
    }
    const allowance = await getErc20Allowance(
      CAIROX_TOKEN_ADDRESS,
      relayerAddr,
      normalizeHex(SHIELDED_POOL_ADDRESS)
    );
    if (allowance < depositAmount) {
      res.status(400).json({
        error:
          "Relayer allowance too low. Approve CAIROX to ShieldedPool from the relayer account."
      });
      return;
    }

    const { newLeaves, newRoot, outputNotes } = await createDepositInput({
      wallet: accountAddress,
      amount: depositAmount.toString(),
      outputPath: inputPath,
      marketId
    });
    const { publicJson, calldataPath } = await generateProof({ inputPath, proofDir: tmpDir });
    const txHash = await submitDeposit({ publicJson, calldataPath });
    if (txHash && !isValidTxHash(txHash)) {
      throw new Error("Failed to parse ShieldedPool deposit tx hash. Please retry.");
    }

    const ledger = loadLedger();
    const entry = ensureWalletEntry(ledger, accountAddress);
    if (txHash) {
      entry.pending = entry.pending.filter((item) => item?.tx_hash !== txHash);
      entry.pending.push({
        tx_hash: txHash,
        amount: depositAmount.toString(),
        submitted_at: new Date().toISOString(),
        kind: "deposit",
        market_id: marketId
      });
    }
    addNotes(entry, outputNotes);
    ledger.wallets[accountAddress] = entry;
    ledger.merkle = {
      leaves: newLeaves.map((v) => v.toString()),
      root: newRoot.toString()
    };
    saveLedger(ledger);

    res.json({
      ok: true,
      wallet: accountAddress,
      amount: depositAmount.toString(),
      amount_raw: amountRaw,
      minted_amount: mintedAmount.toString(),
      market_id: marketId,
      vault_settle_tx: settleTx,
      mint_tx: mintTx,
      tx_hash: txHash,
      confirmed: false
    });
  } catch (err) {
    res.status(500).json({ error: err.message || "Deposit failed." });
  } finally {
    safeRmDir(tmpDir);
  }
});

app.post("/withdraw", requireRelayerAuth, async (req, res) => {
  const wallet = (req.body?.wallet || "").toString().trim();
  const amountRaw = (req.body?.amount || "").toString().trim();
  const marketIdRaw = (req.body?.market_id || req.body?.marketId || "").toString().trim();
  const recipientRaw = (req.body?.recipient || req.body?.to || wallet).toString().trim();

  if (!wallet || !amountRaw || marketIdRaw === "") {
    res.status(400).json({ error: "Wallet, market_id, and amount are required." });
    return;
  }

  try {
    validateAmountString(amountRaw);
  } catch (err) {
    res.status(400).json({ error: err.message || "Amount must be a positive number." });
    return;
  }

  const accountAddress = canonicalWallet(wallet);
  if (!ADDRESS_RE.test(accountAddress)) {
    res.status(400).json({ error: "Invalid wallet address." });
    return;
  }
  const recipientAddress = canonicalWallet(recipientRaw);
  if (!ADDRESS_RE.test(recipientAddress)) {
    res.status(400).json({ error: "Invalid recipient address." });
    return;
  }

  let marketId;
  let tmpDir = "";
  try {
    marketId = normalizeFelt(marketIdRaw, "0");
  } catch (err) {
    res.status(400).json({ error: err.message || "Invalid market_id." });
    return;
  }

  try {
    ensureDir(TMP_DIR);
    tmpDir = fs.mkdtempSync(path.join(TMP_DIR, "withdraw-"));
    const inputPath = path.join(tmpDir, "input.json");

    const netAmount = BigInt(parseAmountToBaseUnits(amountRaw));
    if (netAmount <= 0n) {
      res.status(400).json({ error: "Amount must be greater than zero." });
      return;
    }
    const fee = BigInt(RELAYER_FEE_LOW || "0");
    const grossAmount = netAmount + fee;

    const ledger = loadLedger();
    const entry = ensureWalletEntry(ledger, accountAddress);
    const updated = await updateWalletFromReceipts(accountAddress, entry);
    ledger.wallets[accountAddress] = updated;

    const notes = Array.isArray(updated.notes) ? updated.notes : [];
    if (!notes.length) {
      res.status(400).json({ error: "No shielded notes found. Deposit CAIROX first." });
      return;
    }

    const { input, newLeaves, newRoot, inputNotes, outputNotes } = await buildWithdrawInput({
      wallet: accountAddress,
      marketId,
      amount: grossAmount.toString(),
      fee: fee.toString(),
      recipient: recipientAddress,
      notes,
      outputPath: inputPath
    });

    const { publicJson, calldataPath } = await generateProof({ inputPath, proofDir: tmpDir });
    const txHash = await submitWithdraw({ publicJson, calldataPath });
    if (txHash && !isValidTxHash(txHash)) {
      throw new Error("Failed to parse ShieldedPool withdraw tx hash. Please retry.");
    }

    markNotesSpent(updated, inputNotes, txHash);
    addNotes(updated, outputNotes);

    updated.pending = updated.pending || [];
    if (txHash) {
      updated.pending = updated.pending.filter((item) => item?.tx_hash !== txHash);
      updated.pending.push({
        tx_hash: txHash,
        amount: netAmount.toString(),
        gross_amount: grossAmount.toString(),
        submitted_at: new Date().toISOString(),
        kind: "withdraw",
        market_id: marketId,
        recipient: recipientAddress
      });
    }

    ledger.wallets[accountAddress] = updated;
    ledger.merkle = {
      leaves: newLeaves.map((v) => v.toString()),
      root: newRoot.toString()
    };
    saveLedger(ledger);

    res.json({
      ok: true,
      wallet: accountAddress,
      market_id: marketId,
      recipient: recipientAddress,
      amount: netAmount.toString(),
      gross_amount: grossAmount.toString(),
      relayer_fee: fee.toString(),
      tx_hash: txHash,
      limit: input.limit_low?.toString?.() ?? input.limit_low,
      confirmed: false
    });
  } catch (err) {
    res.status(500).json({ error: err.message || "Withdrawal failed." });
  } finally {
    safeRmDir(tmpDir);
  }
});

app.post("/trade", requireRelayerAuth, async (req, res) => {
  if (!RELAYER_TRADES_ENABLED) {
    res.status(501).json({
      error:
        "Shielded trade relayer is not enabled. Set RELAYER_TRADES_ENABLED=1 to enable trades."
    });
    return;
  }
  const wallet = (req.body?.wallet || "").toString().trim();
  const amountRaw = (req.body?.amount || "").toString().trim();
  const marketIdRaw = (req.body?.market_id || req.body?.marketId || "").toString().trim();
  const outcomeRaw = (req.body?.outcome || "").toString().trim();
  const actionRaw = (req.body?.action || req.body?.side || "").toString().trim();

  if (!wallet || !amountRaw || marketIdRaw === "" || !outcomeRaw) {
    res.status(400).json({ error: "Wallet, market_id, outcome, and amount are required." });
    return;
  }

  try {
    validateAmountString(amountRaw);
  } catch (err) {
    res.status(400).json({ error: err.message || "Amount must be a positive number." });
    return;
  }

  const accountAddress = canonicalWallet(wallet);
  if (!ADDRESS_RE.test(accountAddress)) {
    res.status(400).json({ error: "Invalid wallet address." });
    return;
  }

  let marketId;
  let outcome;
  let action;
  try {
    marketId = normalizeFelt(marketIdRaw, "0");
    outcome = parseOutcome(outcomeRaw);
    action = parseTradeAction(actionRaw);
  } catch (err) {
    res.status(400).json({ error: err.message || "Invalid trade parameters." });
    return;
  }

  let tmpDir = "";
  try {
    ensureDir(TMP_DIR);
    tmpDir = fs.mkdtempSync(path.join(TMP_DIR, "trade-"));
    const inputPath = path.join(tmpDir, "input.json");

    const amount = parseAmountToBaseUnits(amountRaw);
    if (!amount || BigInt(amount) <= 0n) {
      res.status(400).json({ error: "Amount must be greater than zero." });
      return;
    }

    const ledger = loadLedger();
    const entry = ensureWalletEntry(ledger, accountAddress);
    const updated = await updateWalletFromReceipts(accountAddress, entry);
    ledger.wallets[accountAddress] = updated;

    const notes = Array.isArray(updated.notes) ? updated.notes : [];
    if (!notes.length) {
      res.status(400).json({ error: "No shielded notes found. Deposit CAIROX first." });
      return;
    }

    const fee = BigInt(RELAYER_FEE_LOW || "0").toString();
    const { input, newLeaves, newRoot, inputNotes, outputNotes } = await buildTradeInput({
      wallet: accountAddress,
      marketId,
      outcome,
      amount,
      fee,
      action,
      notes,
      outputPath: inputPath
    });

    const { publicJson, calldataPath } = await generateProof({ inputPath, proofDir: tmpDir });
    const txHash = await submitTrade({ publicJson, calldataPath });
    if (txHash && !isValidTxHash(txHash)) {
      throw new Error("Failed to parse ShieldedPool trade tx hash. Please retry.");
    }

    markNotesSpent(updated, inputNotes, txHash);
    addNotes(updated, outputNotes);

    updated.pending = updated.pending || [];
    if (txHash) {
      updated.pending = updated.pending.filter((item) => item?.tx_hash !== txHash);
      updated.pending.push({
        tx_hash: txHash,
        amount: amount.toString(),
        submitted_at: new Date().toISOString(),
        kind: "trade",
        market_id: marketId,
        outcome,
        action: action.toString(),
        limit: input.limit_low?.toString?.() ?? input.limit_low
      });
    }

    ledger.wallets[accountAddress] = updated;
    ledger.merkle = {
      leaves: newLeaves.map((v) => v.toString()),
      root: newRoot.toString()
    };
    saveLedger(ledger);

    res.json({
      ok: true,
      wallet: accountAddress,
      market_id: marketId,
      outcome,
      action: action.toString(),
      amount: amount.toString(),
      limit: input.limit_low?.toString?.() ?? input.limit_low,
      tx_hash: txHash,
      confirmed: true
    });
  } catch (err) {
    res.status(500).json({ error: err.message || "Trade failed." });
  } finally {
    safeRmDir(tmpDir);
  }
});

app.listen(port, () => {
  // eslint-disable-next-line no-console
  console.log(`Relayer listening on http://localhost:${port}`);
  if (RELAYER_AUTO_APPROVE) {
    const min = BigInt(RELAYER_FEE_LOW || "0");
    Promise.resolve()
      .then(() => ensureCairoxAllowance({ relayerAddr: getRelayerAddress(), minAmount: min }))
      .catch((err) => {
        // eslint-disable-next-line no-console
        console.warn("Relayer auto-approve failed:", err?.message || err);
      });
  }
});
