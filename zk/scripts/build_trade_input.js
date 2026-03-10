const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { buildPoseidon } = require('circomlibjs');

const DEPTH = 32;
const SCALE = 1000000000000000000n;
const E_SCALED = 2718281828459045235n;
const MAX_EXP_INPUT = 10000000000000000000n;
const EXP_TERMS = 10n;
const MAX_U128 = (1n << 128n) - 1n;
const MAX_Q = MAX_U128 / SCALE;

function arg(name, def = null) {
  const idx = process.argv.indexOf(name);
  if (idx === -1) return def;
  return process.argv[idx + 1];
}

function toBigInt(val) {
  if (typeof val === 'bigint') return val;
  const s = String(val).trim();
  return s.startsWith('0x') ? BigInt(s) : BigInt(s);
}

function zeroArray(len, asString = false) {
  return Array(len).fill(asString ? "0" : 0);
}

function randBigInt() {
  const buf = crypto.randomBytes(31);
  return BigInt(`0x${buf.toString('hex')}`);
}

function mulDiv(a, b, denom) {
  if (denom === 0n) throw new Error('div by zero');
  if (a === 0n || b === 0n) return 0n;
  if (a > MAX_U128 / b) throw new Error('mul overflow');
  return (a * b) / denom;
}

function expSeries(r) {
  let term = SCALE;
  let sum = SCALE;
  for (let i = 1n; i <= EXP_TERMS; i++) {
    term = mulDiv(term, r, SCALE);
    term = term / i;
    sum = sum + term;
  }
  return sum;
}

function expFp(x) {
  const k = x / SCALE;
  if (k > 10n) throw new Error('exp overflow');
  const r = x - k * SCALE;
  let result = expSeries(r);
  for (let i = 0n; i < k; i++) {
    result = mulDiv(result, E_SCALED, SCALE);
  }
  return result;
}

function lnFp(y) {
  if (y <= 0n) throw new Error('ln undefined');
  let low = 0n;
  let high = MAX_EXP_INPUT;
  for (let i = 0; i < 64; i++) {
    const mid = (low + high) / 2n;
    const expMid = expFp(mid);
    if (expMid > y) {
      high = mid;
    } else {
      low = mid;
    }
  }
  return low;
}

function expRatio(q, b) {
  const x = mulDiv(q, SCALE, b);
  if (x > MAX_EXP_INPUT) throw new Error('exp overflow');
  return expFp(x);
}

function cost(b, qYes, qNo) {
  if (qYes > MAX_Q || qNo > MAX_Q) throw new Error('supply too large');
  const expYes = expRatio(qYes, b);
  const expNo = expRatio(qNo, b);
  const sum = expYes + expNo;
  const lnSum = lnFp(sum);
  return mulDiv(b, lnSum, SCALE);
}

function calculateBuyAmount(b, yesSupply, noSupply, outcome, collateral) {
  if (!(outcome === 0n || outcome === 1n)) throw new Error('Invalid outcome');
  if (b <= 0n) throw new Error('b=0');
  if (yesSupply > MAX_Q || noSupply > MAX_Q) throw new Error('supply too large');
  if (collateral > MAX_Q) throw new Error('collateral too large');

  const qBuy = outcome === 1n ? yesSupply : noSupply;
  const qOther = outcome === 1n ? noSupply : yesSupply;
  const expBuy = expRatio(qBuy, b);
  const expOther = expRatio(qOther, b);
  const sum = expBuy + expOther;

  const costFp = mulDiv(collateral, SCALE, b);
  if (costFp > MAX_EXP_INPUT) throw new Error('exp overflow');
  const expCost = expFp(costFp);
  const term = mulDiv(expCost, sum, SCALE);
  if (term <= expOther) throw new Error('Invalid collateral');
  const numerator = term - expOther;
  const ratio = mulDiv(numerator, SCALE, expBuy);
  const lnRatio = lnFp(ratio);
  const delta = mulDiv(b, lnRatio, SCALE);
  return delta;
}

function calculateSellAmount(b, yesSupply, noSupply, outcome, tokens) {
  if (!(outcome === 0n || outcome === 1n)) throw new Error('Invalid outcome');
  if (b <= 0n) throw new Error('b=0');
  if (yesSupply > MAX_Q || noSupply > MAX_Q) throw new Error('supply too large');
  if (tokens > MAX_Q) throw new Error('tokens too large');

  const qSell = outcome === 1n ? yesSupply : noSupply;
  const qOther = outcome === 1n ? noSupply : yesSupply;
  if (qSell < tokens) throw new Error('Insufficient supply');

  const costBefore = cost(b, qSell, qOther);
  const costAfter = cost(b, qSell - tokens, qOther);
  if (costBefore < costAfter) throw new Error('Invalid cost');
  return costBefore - costAfter;
}

function getPrice(b, yesSupply, noSupply, outcome) {
  const expYes = expRatio(yesSupply, b);
  const expNo = expRatio(noSupply, b);
  const sum = expYes + expNo;
  return outcome === 1n ? mulDiv(expYes, SCALE, sum) : mulDiv(expNo, SCALE, sum);
}

async function main() {
  const actionArg = String(arg('--action', 'buy')).toLowerCase();
  const marketId = arg('--market-id', '0');
  const outcomeStr = arg('--outcome', '1'); // 1 = YES, 0 = NO
  const amountStr = arg('--amount');
  const feeStr = arg('--fee', '0');
  const relayer = arg('--relayer', '0');
  const limitStr = arg('--limit');
  const priceYesArg = arg('--price-yes');
  const priceNoArg = arg('--price-no');
  const yesSupplyStr = arg('--yes-supply');
  const noSupplyStr = arg('--no-supply');
  const bParamStr = arg('--b-param');
  const ts = arg('--timestamp', String(Math.floor(Date.now() / 1000)));
  const inputPathArg = arg('--input');
  const oldRootArg = arg('--old-root');

  if (!amountStr) {
    console.error('Missing args. Required: --amount');
    process.exit(1);
  }
  if (!yesSupplyStr || !noSupplyStr || !bParamStr) {
    console.error('Missing args. Required: --yes-supply --no-supply --b-param');
    process.exit(1);
  }

  const actionMap = { buy: 1n, sell: 2n, redeem: 3n, '1': 1n, '2': 2n, '3': 3n };
  const action = actionMap[actionArg];
  if (!action) {
    console.error(`Invalid --action ${actionArg}. Use buy|sell|redeem`);
    process.exit(1);
  }

  const inputPath = inputPathArg
    ? inputPathArg
    : path.join(__dirname, '..', 'examples', action === 1n ? 'input_deposit.json' : 'input_trade.json');

  const prev = JSON.parse(fs.readFileSync(inputPath, 'utf8'));
  const poseidon = await buildPoseidon();
  const F = poseidon.F;

  function poseidonHash(values) {
    const inputs = values.map(toBigInt);
    const out = poseidon(inputs);
    return toBigInt(F.toString(out));
  }

  const outcome = toBigInt(outcomeStr);
  const outcomeAssetId = 2n - outcome;
  const amount = toBigInt(amountStr);
  const feeLow = toBigInt(feeStr);
  const yesSupply = toBigInt(yesSupplyStr);
  const noSupply = toBigInt(noSupplyStr);
  const bParam = toBigInt(bParamStr);

  const note1 = {
    owner: prev.out_owner_pubkey1 ?? prev.in_owner_pubkey1 ?? "0",
    asset: prev.out_asset_id1 ?? prev.in_asset_id1 ?? "0",
    market: prev.out_market_id1 ?? prev.in_market_id1 ?? marketId,
    outcome: prev.out_outcome1 ?? prev.in_outcome1 ?? "0",
    amount: prev.out_amount1 ?? prev.in_amount1 ?? "0",
    nonce: prev.out_nonce1 ?? prev.in_nonce1 ?? "0",
    nullifierSecret: prev.out_nullifier_secret1 ?? prev.in_nullifier_secret1 ?? "111",
  };
  const note2 = {
    owner: prev.out_owner_pubkey2 ?? prev.in_owner_pubkey2 ?? "0",
    asset: prev.out_asset_id2 ?? prev.in_asset_id2 ?? "0",
    market: prev.out_market_id2 ?? prev.in_market_id2 ?? marketId,
    outcome: prev.out_outcome2 ?? prev.in_outcome2 ?? "0",
    amount: prev.out_amount2 ?? prev.in_amount2 ?? "0",
    nonce: prev.out_nonce2 ?? prev.in_nonce2 ?? "0",
    nullifierSecret: prev.out_nullifier_secret2 ?? prev.in_nullifier_secret2 ?? "222",
  };

  if (note1.market !== marketId || note2.market !== marketId) {
    console.error('Input notes market_id mismatch');
    process.exit(1);
  }

  const n1Asset = toBigInt(note1.asset);
  const n2Asset = toBigInt(note2.asset);
  const n1Outcome = toBigInt(note1.outcome);
  const n2Outcome = toBigInt(note2.outcome);
  const n1Amount = toBigInt(note1.amount);
  const n2Amount = toBigInt(note2.amount);

  function noteIsCollateral(asset, outc) {
    return asset === 0n && outc === 0n;
  }
  function noteIsOutcome(asset, outc) {
    return asset === outcomeAssetId && outc === outcome;
  }

  const inColl1 = noteIsCollateral(n1Asset, n1Outcome);
  const inColl2 = noteIsCollateral(n2Asset, n2Outcome);
  const inOut1 = noteIsOutcome(n1Asset, n1Outcome);
  const inOut2 = noteIsOutcome(n2Asset, n2Outcome);

  if (action === 1n && (!inColl1 || !inColl2)) {
    console.error('Buy requires both input notes to be collateral');
    process.exit(1);
  }
  if ((action === 2n || action === 3n) && (!(inColl1 || inOut1) || !(inColl2 || inOut2))) {
    console.error('Sell/Redeem inputs must be collateral or outcome notes');
    process.exit(1);
  }

  const inOutcomeTotal = (inOut1 ? n1Amount : 0n) + (inOut2 ? n2Amount : 0n);
  const inCollateralTotal = (inColl1 ? n1Amount : 0n) + (inColl2 ? n2Amount : 0n);

  let computedOut = 0n;
  if (action === 1n) {
    computedOut = calculateBuyAmount(bParam, yesSupply, noSupply, outcome, amount);
  } else if (action === 2n) {
    computedOut = calculateSellAmount(bParam, yesSupply, noSupply, outcome, amount);
  } else {
    computedOut = amount; // redeem 1:1
  }

  if (limitStr) {
    const provided = toBigInt(limitStr);
    if (provided !== computedOut) {
      console.error(`--limit ${provided.toString()} does not match computed output ${computedOut.toString()}`);
      process.exit(1);
    }
  }

  const priceYes = priceYesArg ? toBigInt(priceYesArg) : getPrice(bParam, yesSupply, noSupply, 1n);
  const priceNo = priceNoArg ? toBigInt(priceNoArg) : getPrice(bParam, yesSupply, noSupply, 0n);
  if (priceYesArg && priceYes !== getPrice(bParam, yesSupply, noSupply, 1n)) {
    console.error('price_yes does not match LMSR state');
    process.exit(1);
  }
  if (priceNoArg && priceNo !== getPrice(bParam, yesSupply, noSupply, 0n)) {
    console.error('price_no does not match LMSR state');
    process.exit(1);
  }

  let outAmount1 = 0n;
  let outAmount2 = 0n;
  let outAsset1 = "0";
  let outOutcome1 = "0";
  let outAsset2 = "0";
  let outOutcome2 = "0";

  if (action === 1n) {
    if (inCollateralTotal < amount + feeLow) {
      console.error('Insufficient collateral for buy');
      process.exit(1);
    }
    outAmount1 = computedOut;
    outAmount2 = inCollateralTotal - amount - feeLow;
    outAsset1 = outcomeAssetId.toString();
    outOutcome1 = outcome.toString();
    outAsset2 = "0";
    outOutcome2 = "0";
  } else {
    if (inOutcomeTotal < amount) {
      console.error('Insufficient outcome tokens for sell/redeem');
      process.exit(1);
    }
    if (inCollateralTotal + computedOut < feeLow) {
      console.error('Fee exceeds collateral out');
      process.exit(1);
    }
    outAmount1 = inCollateralTotal + computedOut - feeLow;
    outAmount2 = inOutcomeTotal - amount;
    outAsset1 = "0";
    outOutcome1 = "0";
    outAsset2 = outcomeAssetId.toString();
    outOutcome2 = outcome.toString();
  }

  const outNonce1 = randBigInt().toString();
  const outNonce2 = randBigInt().toString();
  const outNullifierSecret1 = randBigInt().toString();
  const outNullifierSecret2 = randBigInt().toString();

  const inCommit1 = poseidonHash([note1.owner, note1.asset, note1.market, note1.outcome, note1.amount, note1.nonce]);
  const inCommit2 = poseidonHash([note2.owner, note2.asset, note2.market, note2.outcome, note2.amount, note2.nonce]);

  const nullifier1 = poseidonHash([inCommit1, note1.nullifierSecret]);
  const nullifier2 = poseidonHash([inCommit2, note2.nullifierSecret]);

  const outCommit1 = poseidonHash([note1.owner, outAsset1, marketId, outOutcome1, outAmount1.toString(), outNonce1]);
  const outCommit2 = poseidonHash([note1.owner, outAsset2, marketId, outOutcome2, outAmount2.toString(), outNonce2]);

  const level0In = poseidonHash([inCommit1, inCommit2]);
  let oldRootComputed = level0In;
  for (let i = 1; i < DEPTH; i++) {
    oldRootComputed = poseidonHash([oldRootComputed, 0n]);
  }
  const oldRootBn = oldRootArg ? toBigInt(oldRootArg) : oldRootComputed;
  if (oldRootArg && oldRootBn !== oldRootComputed) {
    console.error(`Old root mismatch. Computed ${oldRootComputed.toString()} != provided ${oldRootBn.toString()}`);
    process.exit(1);
  }

  const level0Out = poseidonHash([outCommit1, outCommit2]);
  let cur = level0Out;
  for (let i = 1; i < DEPTH; i++) {
    cur = poseidonHash([cur, 0n]);
  }
  const newRoot = cur;

  const inPathElements1 = [inCommit2.toString(), ...zeroArray(DEPTH - 1, true)];
  const inPathIndices1 = [0, ...zeroArray(DEPTH - 1)];
  const inPathElements2 = [inCommit1.toString(), ...zeroArray(DEPTH - 1, true)];
  const inPathIndices2 = [1, ...zeroArray(DEPTH - 1)];

  const outPathElements1 = [outCommit2.toString(), ...zeroArray(DEPTH - 1, true)];
  const outPathIndices1 = [0, ...zeroArray(DEPTH - 1)];
  const outPathElements2 = [outCommit1.toString(), ...zeroArray(DEPTH - 1, true)];
  const outPathIndices2 = [1, ...zeroArray(DEPTH - 1)];

  const marketStateHash = poseidonHash([
    yesSupply, noSupply, bParam, priceYes, priceNo, ts
  ]);

  const input = {
    old_root: oldRootBn.toString(),
    new_root: newRoot.toString(),
    nullifier1: nullifier1.toString(),
    nullifier2: nullifier2.toString(),
    market_state_hash: marketStateHash.toString(),
    action: action.toString(),
    market_id: marketId,
    outcome: outcome.toString(),
    amount_low: amount.toString(),
    amount_high: "0",
    limit_low: computedOut.toString(),
    limit_high: "0",
    relayer: relayer,
    fee_low: feeLow.toString(),
    fee_high: "0",
    recipient: "0",

    in_owner_pubkey1: note1.owner,
    in_asset_id1: note1.asset,
    in_market_id1: note1.market,
    in_outcome1: note1.outcome,
    in_amount1: n1Amount.toString(),
    in_nonce1: note1.nonce,
    in_owner_pubkey2: note2.owner,
    in_asset_id2: note2.asset,
    in_market_id2: note2.market,
    in_outcome2: note2.outcome,
    in_amount2: n2Amount.toString(),
    in_nonce2: note2.nonce,
    in_nullifier_secret1: note1.nullifierSecret.toString(),
    in_nullifier_secret2: note2.nullifierSecret.toString(),
    in_path_elements1: inPathElements1,
    in_path_elements2: inPathElements2,
    in_path_indices1: inPathIndices1,
    in_path_indices2: inPathIndices2,

    out_owner_pubkey1: note1.owner,
    out_asset_id1: outAsset1,
    out_market_id1: marketId,
    out_outcome1: outOutcome1,
    out_amount1: outAmount1.toString(),
    out_nonce1: outNonce1,
    out_owner_pubkey2: note1.owner,
    out_asset_id2: outAsset2,
    out_market_id2: marketId,
    out_outcome2: outOutcome2,
    out_amount2: outAmount2.toString(),
    out_nonce2: outNonce2,
    out_path_elements1: outPathElements1,
    out_path_elements2: outPathElements2,
    out_path_indices1: outPathIndices1,
    out_path_indices2: outPathIndices2,

    yes_supply: yesSupply.toString(),
    no_supply: noSupply.toString(),
    b_param: bParam.toString(),
    price_yes: priceYes.toString(),
    price_no: priceNo.toString(),
    state_timestamp: ts,
  };
  // Guard: circuit does not include out_nullifier_secret* signals.
  delete input.out_nullifier_secret1;
  delete input.out_nullifier_secret2;

  const outPath = path.join(__dirname, '..', 'examples', 'input_trade.json');
  fs.writeFileSync(outPath, JSON.stringify(input, null, 2));
  console.log(`Wrote ${outPath}`);
  if (action === 1n) {
    console.log(`tokens_out=${computedOut.toString()} change=${outAmount2.toString()}`);
  } else {
    console.log(`collateral_out=${computedOut.toString()} change=${outAmount2.toString()}`);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
