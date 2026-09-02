#!/usr/bin/env bash
#
# Build the pinned hax ProVerif backend used to extract the SPQR model, and
# install it into a dedicated opam switch so `hax.py extract-proverif` works out
# of the box (no manual `opam env` needed).
#
# The ProVerif backend lives in hax's Rust engine, but extraction still runs its
# import phase through the OCaml `hax-engine` — and the Rust engine and the OCaml
# engine MUST be the same hax build (a version mismatch panics with "ocaml engine
# crashed"). So this builds the Rust binaries AND installs the matching OCaml
# `hax-engine` into the `hax-proverif` opam switch. (This is the per-switch
# install hax's local `setup-local.sh` performs, inlined here because that script
# is a local convention and is NOT part of the committed hax tree.)
#
# Requirements: git, rustup, opam, node, jq, and a C toolchain. The Rust nightly
# is pinned by hax's rust-toolchain.toml (rustup installs it automatically); the
# OCaml engine is built into the switch (this can take several minutes).
#
# Usage:
#   ./setup-hax.sh [DEST_DIR]      # default DEST_DIR: ./.hax-proverif
#
# Override the opam switch with $HAX_OPAM_SWITCH (default: hax-proverif); hax.py
# reads the same variable to locate the matching engine.

set -euo pipefail

# --- Pinned toolchain provenance (keep in sync with REPRODUCING.md) ----------
HAX_REPO="https://github.com/cryspen/hax.git"
HAX_BRANCH="proverif-rust-backend"
HAX_COMMIT="fffb0fedea9cf17ed6c74310f6291255c5d49061"   # proverif-rust-backend, rebased onto hax/main
HAX_OPAM_SWITCH="${HAX_OPAM_SWITCH:-hax-proverif}"       # holds the matched cargo-hax + OCaml hax-engine
OCAML_VERSION="${OCAML_VERSION:-5.3.0}"
# ----------------------------------------------------------------------------

DEST="${1:-$PWD/.hax-proverif}"

echo ">> hax ProVerif backend setup"
echo "   repo:   $HAX_REPO"
echo "   commit: $HAX_COMMIT"
echo "   switch: $HAX_OPAM_SWITCH"
echo "   dest:   $DEST"

for tool in git rustup opam node jq; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: '$tool' not found in PATH" >&2; exit 1; }
done

if [ ! -d "$DEST/.git" ]; then
    git clone "$HAX_REPO" "$DEST"
fi
cd "$DEST"
git fetch origin "$HAX_BRANCH" || git fetch origin
git checkout --detach "$HAX_COMMIT"

echo ">> building the Rust binaries (cargo-hax + hax-driver + hax-rust-engine)"
# --workspace is required: rust-engine is a workspace member but not a
# default-member, so a plain `cargo build` would skip it.
cargo build --release --workspace -p cargo-hax -p hax-driver -p hax-rust-engine

echo ">> ensuring opam switch '$HAX_OPAM_SWITCH' exists"
opam switch list --short 2>/dev/null | grep -qx "$HAX_OPAM_SWITCH" \
    || opam switch create "$HAX_OPAM_SWITCH" "$OCAML_VERSION" --yes

echo ">> building + installing the matching OCaml hax-engine into '$HAX_OPAM_SWITCH'"
echo "   (pins engine/ from this checkout and builds it; may take several minutes)"
export OPAMASSUMEDEPEXTS=1          # skip system-dep detection (matches setup-local.sh)
opam pin add --switch="$HAX_OPAM_SWITCH" --yes --kind=path hax-engine "$DEST/engine"
opam reinstall --switch="$HAX_OPAM_SWITCH" --yes --assume-depexts hax-engine \
    || opam install --switch="$HAX_OPAM_SWITCH" --yes --assume-depexts hax-engine

echo ">> verifying the install"
BIN="$DEST/target/release"
for b in cargo-hax driver-hax-frontend-exporter hax-rust-engine; do
    [ -x "$BIN/$b" ] || { echo "ERROR: expected rust binary not built: $BIN/$b" >&2; exit 1; }
done
ENGINE="$(opam var bin --switch="$HAX_OPAM_SWITCH" 2>/dev/null)/hax-engine"
[ -x "$ENGINE" ] || { echo "ERROR: OCaml hax-engine not installed in switch '$HAX_OPAM_SWITCH'" >&2; exit 1; }

echo
echo ">> Done."
echo "   rust binaries: $BIN"
echo "   OCaml engine:  $ENGINE"
echo
echo ">> From the SPQR repo root (hax.py auto-resolves the OCaml engine from the"
echo "   '$HAX_OPAM_SWITCH' switch — no \`opam env\` needed):"
echo "   export HAX_PROVERIF_DIR=\"$DEST\""
if [ "$HAX_OPAM_SWITCH" != "hax-proverif" ]; then
    echo "   export HAX_OPAM_SWITCH=\"$HAX_OPAM_SWITCH\""
fi
echo "   python3 hax.py extract-proverif   # regenerate proofs/proverif/extraction/lib.pvl"
echo "   python3 hax.py check-proverif     # run ProVerif + assert the EXPECTPV verdicts"
