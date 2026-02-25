# ZK Input Templates

These templates are used to build a **witness** and **proof** for the ShieldedPool circuit.
Copy the template you need into `zk/build/input.json`, fill the fields, then run the
`generate_witness` + `snarkjs groth16 prove` commands.

Files:
- `input_deposit.json` for `action=4` (DEPOSIT)
- `input_withdraw.json` for `action=5` (WITHDRAW)

Notes:
- `nullifier1`/`nullifier2` **must match** Poseidon(in_commitment, in_nullifier_secret).
  They are public inputs, so you need to compute them off‑chain.
- The templates now include **pre‑computed nullifiers** for their dummy inputs. If you
  change any input note fields or secrets, recompute the nullifiers.
- `old_root` and `new_root` must match your Merkle tree state.
- `recipient` must be **non‑zero** for withdraw and **zero** for non‑withdraw actions.
- `amount_low`, `fee_low`, and output amounts must match the constraints:
  - Deposit: `out_amount1 + out_amount2 = amount_low - fee_low`
  - Withdraw: `out_amount1 + out_amount2 = in_total - amount_low - fee_low`
