const fs = require('fs');
const path = require('path');
const { buildPoseidon } = require('circomlibjs');

const DEPTH = 32;

function toBigInt(val) {
  if (typeof val === 'bigint') return val;
  if (typeof val === 'number') return BigInt(val);
  const s = String(val).trim();
  return s.startsWith('0x') ? BigInt(s) : BigInt(s);
}

function ensureArrayLength(arr, len) {
  if (!Array.isArray(arr)) return Array(len).fill(0);
  if (arr.length === len) return arr;
  if (arr.length > len) return arr.slice(0, len);
  return arr.concat(Array(len - arr.length).fill(0));
}

async function computeRootsAndNullifiers(file, mode) {
  const poseidon = await buildPoseidon();
  const F = poseidon.F;
  const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
  // Guard: circuit does not include out_nullifier_secret* signals.
  delete raw.out_nullifier_secret1;
  delete raw.out_nullifier_secret2;

  function poseidonHash(values) {
    const inputs = values.map(toBigInt);
    const out = poseidon(inputs);
    return F.toString(out);
  }

  function merkleRoot(leaf, pathElements, pathIndices) {
    let cur = toBigInt(leaf);
    for (let i = 0; i < DEPTH; i++) {
      const idx = BigInt(pathIndices[i] || 0);
      const elem = toBigInt(pathElements[i] || 0);
      const left = idx === 0n ? cur : elem;
      const right = idx === 0n ? elem : cur;
      cur = poseidon([left, right]);
      cur = toBigInt(F.toString(cur));
    }
    return cur.toString();
  }

  raw.in_path_elements1 = ensureArrayLength(raw.in_path_elements1, DEPTH);
  raw.in_path_elements2 = ensureArrayLength(raw.in_path_elements2, DEPTH);
  raw.in_path_indices1 = ensureArrayLength(raw.in_path_indices1, DEPTH);
  raw.in_path_indices2 = ensureArrayLength(raw.in_path_indices2, DEPTH);
  raw.out_path_elements1 = ensureArrayLength(raw.out_path_elements1, DEPTH);
  raw.out_path_elements2 = ensureArrayLength(raw.out_path_elements2, DEPTH);
  raw.out_path_indices1 = ensureArrayLength(raw.out_path_indices1, DEPTH);
  raw.out_path_indices2 = ensureArrayLength(raw.out_path_indices2, DEPTH);

  // For non-trade actions we still compute MulDiv; ensure denominators are non-zero.
  if (!raw.price_yes || raw.price_yes === "0") raw.price_yes = "1000000000000000000";
  if (!raw.price_no || raw.price_no === "0") raw.price_no = "1000000000000000000";

  if (mode === 'deposit') {
    const net = toBigInt(raw.amount_low) - toBigInt(raw.fee_low);
    const half = net / 2n;
    raw.out_amount1 = half.toString();
    raw.out_amount2 = half.toString();
    raw.out_owner_pubkey2 = raw.out_owner_pubkey1;
    raw.out_asset_id2 = raw.out_asset_id1;
    raw.out_market_id2 = raw.out_market_id1;
    raw.out_outcome2 = raw.out_outcome1;
    raw.out_nonce2 = raw.out_nonce1;
  }

  if (mode === 'withdraw') {
    const total = toBigInt(raw.in_amount1) + toBigInt(raw.in_amount2);
    const expected = total - toBigInt(raw.amount_low);
    const half = expected / 2n;
    raw.out_amount1 = half.toString();
    raw.out_amount2 = half.toString();
    raw.out_owner_pubkey2 = raw.out_owner_pubkey1;
    raw.out_asset_id2 = raw.out_asset_id1;
    raw.out_market_id2 = raw.out_market_id1;
    raw.out_outcome2 = raw.out_outcome1;
    raw.out_nonce2 = raw.out_nonce1;

    raw.in_owner_pubkey2 = raw.in_owner_pubkey1;
    raw.in_asset_id2 = raw.in_asset_id1;
    raw.in_market_id2 = raw.in_market_id1;
    raw.in_outcome2 = raw.in_outcome1;
    raw.in_amount2 = raw.in_amount1;
    raw.in_nonce2 = raw.in_nonce1;
  }

  const in1 = [raw.in_owner_pubkey1, raw.in_asset_id1, raw.in_market_id1, raw.in_outcome1, raw.in_amount1, raw.in_nonce1];
  const in2 = [raw.in_owner_pubkey2, raw.in_asset_id2, raw.in_market_id2, raw.in_outcome2, raw.in_amount2, raw.in_nonce2];
  const out1 = [raw.out_owner_pubkey1, raw.out_asset_id1, raw.out_market_id1, raw.out_outcome1, raw.out_amount1, raw.out_nonce1];
  const out2 = [raw.out_owner_pubkey2, raw.out_asset_id2, raw.out_market_id2, raw.out_outcome2, raw.out_amount2, raw.out_nonce2];

  const commit1 = poseidonHash(in1);
  const commit2 = poseidonHash(in2);
  const outCommit1 = poseidonHash(out1);
  const outCommit2 = poseidonHash(out2);

  raw.nullifier1 = poseidonHash([commit1, raw.in_nullifier_secret1]);
  raw.nullifier2 = poseidonHash([commit2, raw.in_nullifier_secret2]);

  if (mode === 'withdraw') {
    raw.old_root = merkleRoot(commit1, raw.in_path_elements1, raw.in_path_indices1);
  }

  raw.new_root = merkleRoot(outCommit1, raw.out_path_elements1, raw.out_path_indices1);

  fs.writeFileSync(file, JSON.stringify(raw, null, 2));
  console.log(`Updated ${path.basename(file)} (mode=${mode})`);
}

(async () => {
  await computeRootsAndNullifiers(path.join(__dirname, '..', 'examples', 'input_deposit.json'), 'deposit');
  await computeRootsAndNullifiers(path.join(__dirname, '..', 'examples', 'input_withdraw.json'), 'withdraw');
})();
