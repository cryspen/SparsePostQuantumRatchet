#!/usr/bin/env bash
#
# Install the hax toolchain with the ProVerif backend used to extract the SPQR
# model.
#
# This clones cryspen/hax on the ProVerif backend branch and runs its
# `setup.sh`, which installs `cargo-hax`, the frontend driver and the engines
# (it needs rustup and opam). `hax.py` then uses `cargo-hax` from PATH, and
# reads the matching `hax-lib` and ProVerif libraries from the checkout named
# by HAX_HOME.
#
# Usage:
#   ./setup-hax.sh [DEST_DIR]      # default DEST_DIR: ./.hax-proverif
# Then follow the printed `export ...` line.

set -euo pipefail

HAX_REPO="https://github.com/cryspen/hax.git"
HAX_BRANCH="proverif-rust-backend"

DEST="${1:-$PWD/.hax-proverif}"

echo ">> hax ProVerif backend setup"
echo "   repo:   $HAX_REPO"
echo "   branch: $HAX_BRANCH"
echo "   dest:   $DEST"

if [ ! -d "$DEST/.git" ]; then
    git clone --branch "$HAX_BRANCH" "$HAX_REPO" "$DEST"
fi
cd "$DEST"
git fetch origin "$HAX_BRANCH"
git checkout --detach FETCH_HEAD
echo "   commit: $(git rev-parse HEAD)"

./setup.sh

echo
echo ">> Done. Add to your environment (hax.py reads HAX_HOME):"
echo "   export HAX_HOME=\"$DEST\""
echo
echo ">> Then, from the SPQR repo root:"
echo "   python3 hax.py extract-proverif   # regenerate proofs/proverif/extraction/lib.pvl"
echo "   python3 hax.py check-proverif     # run ProVerif on the model"
