# ProVerif models for SPQR

This folder contains symbolic (Dolev–Yao) ProVerif models of the SPQR protocol.

## Hand-written models

- [`spqr-cka.pv`](spqr-cka.pv) — the ML-KEM Braid / continuous key agreement
  (the public ratchet, implemented in [`src/v1`](../../src/v1)). Proves
  reachability, confidentiality (forward secrecy + post-compromise security),
  and mutual authentication.
- [`spqr-dr.pv`](spqr-dr.pv) — the symmetric ratchet (implemented in
  [`src/chain.rs`](../../src/chain.rs)).
- [`cryptolib.pvl`](cryptolib.pvl) — shared symbolic crypto library.

Run, e.g.: `proverif -lib cryptolib.pvl spqr-cka.pv`.

## Extracted model (`extraction/`)

[`extraction/`](extraction) holds a model whose protocol logic is **compiled
directly from the Rust source** (`spqr::v1::unchunked`) by
[hax](https://github.com/cryspen/hax)'s ProVerif backend, rather than written by
hand. Only the cryptographic primitives are abstracted; the state machine is the
real code. This keeps the analyzed model in lock-step with the implementation.
See [`extraction/README.md`](extraction/README.md) for details.

From the repository root:

```
python3 hax.py extract-proverif     # Rust -> proofs/proverif/extraction/lib.pvl
python3 hax.py verify-proverif      # run ProVerif on the composed model
```

`extract-proverif` needs the pinned hax ProVerif backend; build it with
[`setup-hax.sh`](setup-hax.sh). For exact toolchain versions, the trust
boundary, and a step-by-step (ProVerif-only and full re-extraction) reproduction
recipe, see [`REPRODUCING.md`](REPRODUCING.md).
