#!/usr/bin/env bash
# Reproduce the DR message-key ProVerif experiment.
#   HAX_PROVERIF_DIR: hax checkout @ proverif-rust-backend.
set -uo pipefail
cd "$(dirname "$0")"
ENG="${HAX_PROVERIF_DIR:?set HAX_PROVERIF_DIR}"
PRIM="$ENG/hax-lib/proof-libs/proverif/primitives.pvl"
LIB="../extraction/lib.pvl"
for q in dr_secrecy_concrete dr_forward_secrecy dr_secrecy; do
  echo "==== $q ===="
  proverif -lib "$PRIM" -lib dr_missing.pvl -lib "$LIB" "$q.pv" 2>&1 | grep -E '^RESULT|Error:'
done
