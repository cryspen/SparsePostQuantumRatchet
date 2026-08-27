#!/usr/bin/env bash
#
# Build the pinned hax ProVerif backend used to extract the SPQR model.
#
# This clones cryspen/hax at the exact commit the artifact was produced with and
# builds ONLY the Rust components the ProVerif backend needs (the frontend driver
# + cargo-hax + the Rust engine). No OCaml/opam is required: on this branch the
# ProVerif backend lives in the Rust engine, not the OCaml engine.
#
# Requirements: git, rustup (the build uses the nightly pinned by hax's
# rust-toolchain.toml — nightly-2025-11-08 with rustc-dev/rust-src; rustup
# installs it automatically), and a C toolchain.
#
# Usage:
#   ./setup-hax.sh [DEST_DIR]      # default DEST_DIR: ./.hax-proverif
# Then follow the printed `export ...` lines (or pass HAX_PROVERIF_DIR to hax.py).

set -euo pipefail

# --- Pinned toolchain provenance (keep in sync with REPRODUCING.md) ----------
HAX_REPO="https://github.com/cryspen/hax.git"
HAX_BRANCH="proverif-rust-backend"
HAX_COMMIT="a881e92f344f75e1eb78ff2aaf43284589a4d6c8"   # proverif-rust-backend (cargo-hax-v0.3.7-277-ga881e92f3): nat2native bridge prelude
# ----------------------------------------------------------------------------

DEST="${1:-$PWD/.hax-proverif}"

echo ">> hax ProVerif backend setup"
echo "   repo:   $HAX_REPO"
echo "   commit: $HAX_COMMIT"
echo "   dest:   $DEST"

if [ ! -d "$DEST/.git" ]; then
    git clone "$HAX_REPO" "$DEST"
fi
cd "$DEST"
git fetch origin "$HAX_BRANCH" || git fetch origin
git checkout --detach "$HAX_COMMIT"

echo ">> building cargo-hax + hax-driver (frontend) + hax-rust-engine (release)"
# --workspace is required: rust-engine is a workspace member but not a
# default-member, so a plain `cargo build` would skip it.
cargo build --release --workspace \
    -p cargo-hax -p hax-driver -p hax-rust-engine

BIN="$DEST/target/release"
for b in cargo-hax driver-hax-frontend-exporter hax-rust-engine; do
    if [ ! -x "$BIN/$b" ]; then
        echo "ERROR: expected binary not built: $BIN/$b" >&2
        exit 1
    fi
done

echo
echo ">> Done. Binaries in $BIN"
echo ">> Add to your environment (hax.py reads HAX_PROVERIF_DIR):"
echo "   export HAX_PROVERIF_DIR=\"$DEST\""
echo
echo ">> Then, from the SPQR repo root:"
echo "   python3 hax.py extract-proverif   # regenerate proofs/proverif/extraction/lib.pvl"
echo "   python3 hax.py verify-proverif    # run ProVerif on the model"
