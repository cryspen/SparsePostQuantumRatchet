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
| `model.pvl` | hand-written | process model: multi-epoch ping-pong (roles swap each epoch), fixed compromise mirroring `../spqr-cka.pv` |
| `reach.pv` / `conf.pv` / `auth.pv` | hand-written | reachability / confidentiality / authentication queries (one per file; each carries the sound `nounif` block) |
| `sanity.pv` | hand-written | negative controls: confirm the compromise is non-vacuous (compromised epochs leak, others stay secret) |

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
fixed `Compromise*` processes read (scenario mirrors `../spqr-cka.pv`). Roles
remain separate concurrent processes over the public channel `c`, so the attacker
keeps full network control and authentication stays meaningful.

Transcript binding comes from the authenticator MAC chain, **not** the epoch KDF
(the epoch KDF takes the shared secret + epoch only — faithful to the published
spec and the Rust `kdf::derive_scka_secret`).

## Running

From the repository root:

```
python3 hax.py extract-proverif            # regenerate lib.pvl from Rust
python3 hax.py verify-proverif epochs=6 reach.pv    # reachability + key agreement
python3 hax.py verify-proverif epochs=6 conf.pv     # confidentiality (FS + PCS)
python3 hax.py verify-proverif epochs=6 auth.pv     # mutual authentication
python3 hax.py verify-proverif epochs=6 sanity.pv   # non-vacuity controls
```

The epoch bound (`max_epoch()`, i.e. NEPOCHS) lives in `nepochs.pvl`, which
`verify-proverif epochs=N` regenerates; it is loaded before `model.pvl`. All
properties verify to NEPOCHS=6 — see "Properties proven" below.

`extract-proverif` requires the hax ProVerif backend checkout (see
`HAX_PROVERIF_DIR` in `hax.py`, default `~/hax-proverif-backend`); it injects the
dev `hax-lib` (for the `pv_*` / `proverif::replace` macros) via `cargo --config`
and restores `Cargo.lock`, so normal builds and CI are unaffected.

## Properties proven

Over the ping-pong (roles swap each epoch) with a fixed key/authenticator
compromise (`model.pvl`, mirroring `../spqr-cka.pv`). The three properties:

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
simplification), and all three verify to NEPOCHS=6:

| property | reach + agreement | mutual auth | conf (FS/PCS) |
|---|---|---|---|
| verified to | NEPOCHS=6 | NEPOCHS=6 | NEPOCHS=6 |

Non-vacuity is checked by `sanity.pv` (compromised epochs leak; an uncompromised
epoch between two leaking neighbours stays secret).

### Saturation control

Every query file carries `nounif` declarations that deprioritise the attacker
*constructing* symbolic ML-KEM ciphertexts / authenticator / MAC terms (the
decryption-oracle blow-up). `nounif` is **always sound** — it only changes
ProVerif's resolution order, never the verdict — and it is what makes the
multi-epoch runs converge. We use **no** `restriction`/`axiom` (those remove
traces — trust assumptions) and **no** induction lemmas.
