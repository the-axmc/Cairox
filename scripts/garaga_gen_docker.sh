#!/usr/bin/env bash
set -euo pipefail

UID_GID="$(id -u):$(id -g)"

docker run --rm \
  -v "$PWD":/w -w /w/zk/build \
  python:3.10-bookworm \
  bash -lc 'apt-get update -y >/dev/null && \
    apt-get install -y build-essential libgmp-dev pkg-config >/dev/null && \
    # Garaga only needs `scarb fmt .`. Point scarb to a no-op binary.
    ln -sf /bin/true /usr/local/bin/scarb && \
    pip install -q garaga && \
    garaga gen --system groth16 \
      --vk /w/zk/build/verification_key.json \
      --project-name shielded_pool_verifier && \
    # Scarb 2.8 does not accept numeric inlining-strategy. Remove it for compatibility.
    sed -i "/^inlining-strategy = /d" /w/zk/build/shielded_pool_verifier/Scarb.toml && \
    # Remove dev-dependencies that aren't needed for contract build and often fail to resolve.
    python - << "PY" && \
from pathlib import Path
path = Path("/w/zk/build/shielded_pool_verifier/Scarb.toml")
lines = path.read_text().splitlines()
out = []
skip = False
for line in lines:
    if line.strip() == "[dev-dependencies]":
        skip = True
        continue
    if skip and line.startswith("[") and line.strip() != "[dev-dependencies]":
        skip = False
    if not skip:
        out.append(line)
path.write_text("\n".join(out).rstrip() + "\n")
PY
    chown -R '"$UID_GID"' /w/zk/build/shielded_pool_verifier'

echo "Verifier project generated at zk/build/shielded_pool_verifier"
