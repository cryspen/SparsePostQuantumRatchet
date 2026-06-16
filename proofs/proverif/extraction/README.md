# Extracted ProVerif model of the unchunked v1 protocol

The protocol state machine here is **compiled from the Rust source** by hax's
ProVerif backend, so the analyzed model tracks the implementation rather than a
hand-transcription of it. The query set mirrors the hand-written
[`../spqr-cka.pv`](../spqr-cka.pv).

## Files

| File | Origin | Contents |
|---|---|---|
| `lib.pvl` | **generated** by hax | the `spqr::v1::unchunked` state machine (send_ek / send_ct transitions, state structs) — never hand-edited |
| `handwritten_lib.pvl` | hand-written | symbolic Dolev–Yao crypto (ML-KEM, chaining-MAC authenticator) the generated code calls |
| `primitives.pvl` | vendored from hax | hax's ProVerif prelude, with local fixes: machine-integer `==`/`!=` decidable and `+1` epoch arithmetic reductive |
| `model.pvl` | hand-written | aliases, the multi-epoch ping-pong (roles swap each epoch), and attacker-scheduled compromise |
| `reach.pv` / `conf.pv` / `auth.pv` | hand-written | the reachability / confidentiality / authentication queries (one file per property; run independently for tractability) |

## What is compiled vs. abstracted

- **Compiled:** the full protocol state machine — header/EK/CT1/CT2 message
  flow, epoch handling, MAC verification points, the linear per-epoch
  transitions, and the role swap each epoch.
- **Abstracted** (symbolic models in `handwritten_lib.pvl`, selected via
  `proverif::replace_body` / `pv_extern` annotations in the Rust source, gated on
  `cfg(hax_backend_proverif)`, which hax sets only during `into proverif`):
  - incremental ML-KEM (`generate`, `encaps1`, `encaps2`, `decaps`,
    `ek_matches_header`) — split-ciphertext KEM with a correctness reduction;
  - the `Authenticator` (transcript-binding chaining MAC);
  - the SCKA key-derivation KDF (`kdf::derive_scka_secret`).

The chunked/erasure-coding transport carries no security and is not modelled
(the unchunked layer is the cryptographic core; message reordering lives in the
chunked layer, so the extracted model is strictly in-order).

## Model structure (why it looks the way it does)

Each role runs a *full epoch* in one process (`Requestor` / `Responder` in
`model.pvl`): one table `get` + one `insert`, so the large mid-protocol states
(carrying `dk`/`es`/`ct1`) stay in local bindings and never enter the persistent
tables — only the small hand-off states (epoch + authenticator) are tabled. This
is what keeps the multi-epoch analysis tractable for ProVerif's saturation.
Compromisable key material is published into flat compromise tables that the
replicated attacker-scheduled `Compromise*` processes read. Roles remain
separate concurrent processes over the public channel `c`, so the attacker keeps
full network control and authentication stays meaningful.

Transcript binding comes from the authenticator MAC chain, **not** the epoch KDF
(faithful to the published spec; the hand-written `../spqr-cka.pv` additionally
mixes `h(ekseed,ek)` into the KDF, which neither the spec nor the code does).

## Running

From the repository root:

```
python3 hax.py extract-proverif            # regenerate lib.pvl from Rust
python3 hax.py verify-proverif             # run all query files (epoch bound from nepochs.pvl)
python3 hax.py verify-proverif epochs=3    # set the NEPOCHS bound, then run all
python3 hax.py verify-proverif epochs=2 conf.pv  # set bound + run a single property
```

The epoch bound (`max_epoch()`, i.e. NEPOCHS) lives in `nepochs.pvl`, which
`verify-proverif epochs=N` regenerates; it is loaded before `model.pvl`. Raising
NEPOCHS quickly makes the confidentiality (secrecy) queries very expensive for
ProVerif on the verbose extracted terms — see "Properties proven" below.

`extract-proverif` requires the hax ProVerif backend checkout (see
`HAX_PROVERIF_DIR` in `hax.py`, default `~/hax-proverif-backend`); it injects the
dev `hax-lib` (for the `pv_*` / `proverif::replace` macros) via `cargo --config`
and restores `Cargo.lock`, so normal builds and CI are unaffected.

## Properties proven

Over the ping-pong with attacker-scheduled key/authenticator compromise. The
three properties:

- **reachability + key agreement** (`reach.pv`) — both roles complete each
  epoch and derive the *same* epoch secret (exercises the symbolic ML-KEM
  correctness reduction end-to-end);
- **mutual authentication** (`auth.pv`) — a completed session implies the peer
  started it at the same epoch, unless an authenticator key at some epoch
  `ep′ ≤ ep` was compromised (both directions);
- **confidentiality with forward secrecy + post-compromise security**
  (`conf.pv`) — if the attacker learns an epoch secret, then the ML-KEM keys at
  that epoch were compromised, or an authenticator key at some `ep′ ≤ ep` was
  compromised before the secret was derived (`@i`/`@j`, `j < i`, `ep′ ≤ ep`).

These are the same queries as the hand-written `../spqr-cka.pv` (no
simplification). ProVerif's tractability on the verbose *extracted* terms,
however, degrades sharply with the NEPOCHS bound — the cost is in saturation,
not the queries:

| NEPOCHS | reach | auth | conf (FS/PCS) |
|---|---|---|---|
| 1 | ✅ | ✅ | ✅ (all forms) |
| 2 | ✅ | ✅ (both directions) | ✗ saturation does not converge |
| 3 | ✅ | ✗ queue diverges | ✗ |

So `verify-proverif` (committed default NEPOCHS=1) is a complete, terminating
pass of all three properties; `verify-proverif epochs=2 reach.pv auth.pv` adds
the multi-epoch (role-swapping) reachability and mutual authentication. The
cross-epoch secrecy at NEPOCHS≥2 is the prover-scalability frontier for this
approach — the compact hand-written `../spqr-cka.pv` reaches 5 epochs because its
state terms are tiny, whereas the faithful compiler-extracted states are large.

### Saturation control

`conf.pv` carries `nounif` declarations that deprioritise the attacker
*constructing* symbolic ML-KEM ciphertexts / authenticator terms (the
decryption-oracle blow-up). `nounif` is **always sound** — it only changes
ProVerif's resolution order, never the verdict — and it noticeably extends how
far the NEPOCHS≥2 confidentiality saturation gets before stalling.

We deliberately do **not** use a `restriction` to bound epochs: a `restriction`
*removes traces*, i.e. it is a trust assumption that must be separately
justified, and an epoch-bound restriction did not unblock the proof in any case.
The sound way to push cross-epoch secrecy further is the Cheval–Jacomme–Richards
recipe (their Double-Ratchet ProVerif analysis): proven state-uniqueness
**lemmas** + proof by **`[induction]`** over the epoch counter + the GSVerif
library for monotonic counters. That is a substantial undertaking (their paper:
16 lemmas, person-months, a 378 GB / 20-core machine), out of scope here.
