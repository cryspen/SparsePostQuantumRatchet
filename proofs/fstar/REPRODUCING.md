# Reproducing the SPQR F\* verification

This documents **how to re-run** the F\* verification of SPQR — the Rust source is
compiled to F\* by [hax](https://github.com/cryspen/hax) and typechecked against the
hand-written spec models in [`models/`](models/).

For **what the F\* proof actually establishes and its trust boundary** (panic-freedom,
GF(2¹⁶) correctness, the ML-KEM interface, the assume/admit inventory), see the single
status doc: [`../PROOF_STATUS.md`](../PROOF_STATUS.md). This file is the recipe, not the
claims.

## Pinned toolchain

| Component | Version / pin |
|---|---|
| F\* | `v2025.10.06` (installed by `hacspec/hax-actions` in CI) |
| hax | `hax-lib-v0.3.6` (the `hax_reference` used in CI; provides `cargo-hax` + the F\* `proof-libs`) |
| Z3 | `4.13.3` (`--z3version 4.13.3` in the extraction Makefile) |
| Rust toolchain | the nightly pinned by hax's own `rust-toolchain.toml` (auto-installed by rustup) |
| HACL\* | cloned on demand into `$HACL_HOME` (default `~/.hax/hacl_home`) |
| protobuf | `protoc` (`protobuf-compiler`) — required; the crate builds `.proto` at compile time |

Also needed in `PATH`: `cargo`, `cargo-hax`, `jq`, `fstar.exe`.

## Reproduce

From the repository root:

```
# 1. Compile the Rust to F* (writes proofs/fstar/extraction/*.fst{,i}; gitignored)
python3 hax.py extract

# 2. Typecheck the extracted F* against the models (full SMT verification)
python3 hax.py prove

# lax-check only (admit all SMT queries — fast, checks well-formedness not proofs):
python3 hax.py prove --admit
```

- `extract` runs `cargo hax into fstar` including everything except the protobuf modules
  as implementations and the `proto::**` modules **interface-only** (`--interfaces
  +**::proto::**`) — protobuf (de)serialization is modelled as a trusted API, not proven.
- `prove` runs `make -C proofs/fstar/extraction/`, which discovers the F\* `proof-libs`
  and `../models` include dirs from `cargo metadata`, then verifies every extracted
  `*.fst`/`*.fsti` **with SMT queries discharged** (not lax). `--admit` sets
  `OTHERFLAGS=--admit_smt_queries true`.

**CI.** `.github/workflows/hax.yml` runs exactly this on every push: it installs hax +
F\* `v2025.10.06`, then `hax.py extract` followed by `hax.py prove`. The extracted `.fst`
files are **not committed** (they are regenerated); the committed, reviewable surface is
the `models/` directory.

## What is checked (and what is trusted)

The **extracted `.fst`/`.fsti` are generated fresh** each run and are gitignored — they
are compiler output, not the trust boundary. The **trust boundary is the committed
[`models/`](models/) directory**: 31 hand-written F\* spec files that the extracted code
is checked against, including the interface-only ML-KEM models and the `Spec.GF16` /
`Spec.MLKEM` math specs. Those models carry the assumes/admits and interface-only `val`s
that bound what the proof guarantees — enumerated in
[`../PROOF_STATUS.md`](../PROOF_STATUS.md).

## File manifest (`proofs/fstar/`)

```
REPRODUCING.md      this file (how to reproduce)
models/             hand-written F* spec models (the committed trust boundary)
  Spec.GF16.fst          bit-vector GF(2^16) field spec (finite-field correctness target)
  Spec.MLKEM*.fst        ML-KEM math spec (NTT, encode/decode; sampling axiomatized)
  Libcrux_ml_kem.*.fsti  interface-only models of libcrux's ML-KEM (trusted API)
  Prost.*.fsti           interface-only protobuf runtime models
  ...                    (see PROOF_STATUS.md for the assume/admit inventory)
extraction/         PURE hax output (regenerated; *.fst gitignored)
  Makefile          F* verification driver (invoked by `hax.py prove`)
```
