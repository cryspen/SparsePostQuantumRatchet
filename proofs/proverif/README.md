# ProVerif models for SPQR

This folder contains symbolic (Dolev–Yao) ProVerif models of the SPQR protocol.

## Hand-written models

The [`handwritten/`](handwritten) folder holds the by-hand models:

- [`handwritten/spqr-cka.pv`](handwritten/spqr-cka.pv) — the ML-KEM Braid /
  continuous key agreement (the public ratchet, implemented in
  [`src/v1`](../../src/v1)). Proves reachability, confidentiality (forward
  secrecy + post-compromise security), and mutual authentication.
- [`handwritten/spqr-dr.pv`](handwritten/spqr-dr.pv) — the symmetric ratchet
  (implemented in [`src/chain.rs`](../../src/chain.rs)).
- [`handwritten/cryptolib.pvl`](handwritten/cryptolib.pvl) — shared symbolic crypto.

Run, e.g. (from this folder): `proverif -lib handwritten/cryptolib.pvl handwritten/spqr-cka.pv`.

## Extracted model (`extraction/` + `extraction-model/`)

The protocol logic is **compiled directly from the Rust source**
(`spqr::v1::unchunked`) by [hax](https://github.com/cryspen/hax)'s ProVerif
backend, rather than written by hand. The pure hax output is
[`extraction/lib.pvl`](extraction/lib.pvl) (never hand-edited); the hand-written
composition that wraps it — symbolic crypto, process/compromise model, queries —
is in [`extraction-model/`](extraction-model). Only the cryptographic primitives
are abstracted; the state machine is the real code, keeping the analyzed model in
lock-step with the implementation. See
[`extraction-model/README.md`](extraction-model/README.md) for details.

From the repository root:

```
python3 hax.py extract-proverif        # Rust -> proofs/proverif/extraction/lib.pvl
python3 hax.py verify-proverif epochs=6 # run ProVerif on the composed model
```

Both the hand-written `spqr-cka.pv` and the extracted model prove reachability,
confidentiality (FS + PCS), and mutual authentication under a fixed compromise to
6–7 epochs.

`extract-proverif` needs the pinned hax ProVerif backend; build it with
[`setup-hax.sh`](setup-hax.sh). For exact toolchain versions, the trust
boundary, and a step-by-step (ProVerif-only and full re-extraction) reproduction
recipe, see [`REPRODUCING.md`](REPRODUCING.md).
