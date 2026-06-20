#!/usr/bin/env bash
# Reproduce the SPQR extraction-based ProVerif proofs on the hax proverif-rust
# backend (uniform-bitstring Rust engine). Extracts spqr::v1::unchunked, composes
# with the backend's primitives.pvl (which carries the reductive nat `+1` so
# epochs progress) + a de-duplicated missingdecl, runs ProVerif on
# reach/auth/conf/sanity and asserts each file's `(* EXPECTPV ... *)` verdicts.
# (The hand-written models spqr-cka.pv / spqr-dr.pv are backend-independent; run
#  them with `hax.py check-proverif spqr-cka.pv spqr-dr.pv`.)
#
#   HAX_PROVERIF_DIR : a hax checkout @ proverif-rust-backend.
set -uo pipefail
cd "$(dirname "$0")/../.."
ENG="${HAX_PROVERIF_DIR:?set HAX_PROVERIF_DIR}"
PRIM="$ENG/hax-lib/proof-libs/proverif/primitives.pvl"
PVD=proofs/proverif; M="$PVD/extraction-model"
eval "$(opam env --switch=hax-proverif 2>/dev/null)" 2>/dev/null || true
if ! command -v cargo-hax >/dev/null 2>&1; then export PATH="$ENG/target/release:$PATH"; fi
export HAX_RUST_ENGINE_BINARY="${HAX_RUST_ENGINE_BINARY:-$ENG/target/release/hax-rust-engine}"
cargo hax into -i '-** +~spqr::v1::unchunked::**' proverif
EPOCHS="${EPOCHS:-6}"; printf '(* NEPOCHS bound. *)\nletfun max_epoch() = %s.\n' "$EPOCHS" > "$M/nepochs.pvl"
python3 - "$PRIM" "$M/handwritten_lib.pvl" "$PVD/extraction/lib.pvl" "$M/model.pvl" "$PVD/extraction/missingdecl.pvl" > "$PVD/extraction/missingdecl.dedup.pvl" <<'PY'
import re,sys
defs=set()
for f in sys.argv[1:5]:
    try: t=open(f).read()
    except: continue
    for m in re.finditer(r'^(?:fun|letfun|const)\s+([A-Za-z0-9_]+)', t, re.M): defs.add(m.group(1))
    for m in re.finditer(r';\s*([A-Za-z0-9_]+)\s*\(', t.replace('\n',' ')): defs.add(m.group(1))
out=[l for l in open(sys.argv[5]) if not (re.match(r'^(fun|const)\s+([A-Za-z0-9_]+)',l) and re.match(r'^(fun|const)\s+([A-Za-z0-9_]+)',l).group(2) in defs)]
sys.stdout.write(''.join(out))
PY
fail=0
for q in reach auth conf sanity; do
  log=$(mktemp)
  proverif -lib "$PRIM" -lib "$PVD/extraction/missingdecl.dedup.pvl" -lib "$M/handwritten_lib.pvl" -lib "$PVD/extraction/lib.pvl" -lib "$M/nepochs.pvl" -lib "$M/model.pvl" "$M/$q.pv" > "$log" 2>&1
  got=$(grep '^RESULT' "$log" | grep -oE 'is (true|false)' | awk '{print $2}' | tr '\n' ' ')
  exp=$(awk '/EXPECTPV/,/END \*\)/' "$M/$q.pv" | grep -oE 'is (true|false)' | awk '{print $2}' | tr '\n' ' ')
  if [ "$got" = "$exp" ] && [ -n "$got" ]; then echo "  $q: PASS ($got)"; else echo "  $q: FAIL got[$got] exp[$exp]"; grep -m1 Error "$log"; fail=1; fi
done
[ "$fail" = 0 ] && echo "CHECK PASSED (reach/auth/conf/sanity)" || { echo "CHECK FAILED"; exit 1; }
