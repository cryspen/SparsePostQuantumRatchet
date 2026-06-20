# Extracted ProVerif model of the unchunked v1 protocol

This folder is the **hand-written composition layer** for the extracted proof:
the symbolic crypto, the process/compromise model, and the queries. The protocol
state machine itself is **compiled from the Rust source** by hax's ProVerif
backend and lives, untouched, in [`../extraction/lib.pvl`](../extraction/lib.pvl)
(pure hax output; never hand-edited). The query set mirrors the hand-written
[`../handwritten/spqr-cka.pv`](../handwritten/spqr-cka.pv).

## Files

| File | Origin | Contents |
|---|---|---|
| `../extraction/lib.pvl` | **generated** by hax | the `spqr::v1::unchunked` state machine (send_ek / send_ct transitions, state structs) — never hand-edited |
| `handwritten_lib.pvl` | hand-written | symbolic Dolev–Yao crypto (ML-KEM, chaining-MAC authenticator) the generated code calls |
| `primitives.pvl` | vendored from hax | hax's ProVerif prelude, with local fixes: machine-integer `==`/`!=` decidable and `+1` epoch arithmetic reductive |
| `model.pvl` | hand-written | process model: multi-epoch ping-pong (roles swap each epoch), fixed compromise (KEM keys at epochs 1/3 + a responder authenticator at epoch 4), mirroring `../handwritten/spqr-cka.pv` |
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
fixed `Compromise*` processes read (scenario mirrors `../handwritten/spqr-cka.pv`). Roles
remain separate concurrent processes over the public channel `c`, so the attacker
keeps full network control and authentication stays meaningful.

Transcript binding comes from the authenticator MAC chain, **not** the epoch KDF
(the epoch KDF takes the shared secret + epoch only — faithful to the published
spec and the Rust `kdf::derive_scka_secret`).

## Running

From the repository root:

```
python3 hax.py extract-proverif            # regenerate ../extraction/lib.pvl from Rust
python3 hax.py check-proverif epochs=6              # diff ProVerif RESULTs vs each file's (* EXPECTPV ... END *) block
python3 hax.py check-proverif update epochs=6       # (re)generate the EXPECTPV blocks from current ProVerif output
python3 hax.py verify-proverif epochs=6 reach.pv    # reachability + key agreement (raw output)
python3 hax.py verify-proverif epochs=6 conf.pv     # confidentiality (FS + PCS)
python3 hax.py verify-proverif epochs=6 auth.pv     # mutual authentication
python3 hax.py verify-proverif epochs=6 sanity.pv   # non-vacuity controls
```

`check-proverif` uses ProVerif's **native** expected-results convention (manual
sec. 6.9): each query file ends with a `(* EXPECTPV` … `END *)` comment holding
the verbatim `RESULT …` lines, and the checker diffs ProVerif's output against
them — for **both** the generated model (`reach/auth/conf/sanity.pv`) **and** the
hand-written models (`../handwritten/spqr-cka.pv`, `spqr-dr.pv`), so nothing is
eyeballed. Regenerate the blocks after any model change with `check-proverif
update`. The blocks are pinned to NEPOCHS=6 (generated) / each hand-written
model's inline `max_epoch()` (also 6).

The epoch bound (`max_epoch()`, i.e. NEPOCHS) lives in `nepochs.pvl`, which
`verify-proverif epochs=N` regenerates; it is loaded before `model.pvl`. All
properties verify to NEPOCHS=6 — see "Properties proven" below. The fixed
compromise lives in epochs 1/3/4; the bound 6 gives two uncompromised successor
epochs (5,6) that check the ratchet healing after the epoch-4 compromise.

`extract-proverif` requires the hax ProVerif backend checkout (see
`HAX_PROVERIF_DIR` in `hax.py`, default `~/hax-proverif-backend`); it injects the
dev `hax-lib` (for the `pv_*` / `proverif::replace` macros) via `cargo --config`
and restores `Cargo.lock`, so normal builds and CI are unaffected.

## Properties proven

Over the ping-pong (roles swap each epoch) with a fixed key/authenticator
compromise (`model.pvl`, mirroring `../handwritten/spqr-cka.pv`). The three properties:

- **reachability + key agreement** (`reach.pv`) — both roles complete each
  epoch and derive the *same* epoch secret (exercises the symbolic ML-KEM
  correctness reduction end-to-end);
- **mutual authentication** (`auth.pv`) — a completed session implies the peer
  started it at the same epoch, unless an authenticator key at some epoch
  `ep′ ≤ ep` was compromised (both directions);
- **confidentiality with forward secrecy + post-compromise security**
  (`conf.pv`) — if the attacker learns an epoch secret, then the ML-KEM keys at
  that epoch were compromised, or an authenticator key at some `ep′ ≤ ep` was
  compromised at some time `j < i` (before the secret was derived). This
  `ep′ ≤ ep` / `@i,@j, j < i` formulation is the paper's Def 2 (an authenticator
  "compromised for an epoch `≤ ep` at some time `t′ < t`") and the
  same query as `../handwritten/spqr-cka.pv`: `ep′ ≤ ep` gives forward secrecy
  (a later compromise does not help) and `j < i` gives post-compromise security
  (a too-late compromise cannot excuse a past secret).

These are the same queries as the hand-written `../handwritten/spqr-cka.pv` (no
simplification), and all four verify to **NEPOCHS=6**:

| property | reach + agreement | mutual auth | conf (FS/PCS) | sanity |
|---|---|---|---|---|
| verified to | NEPOCHS=6 | NEPOCHS=6 | NEPOCHS=6 | NEPOCHS=6 |

Each generated query takes ~40–60 s / ~1.7 GB at NEPOCHS=6, and `spqr-cka.pv`
~2 min / 3.5 GB. The bound 6 gives the fixed compromise (epochs 1/3/4) two
uncompromised successor epochs (5,6), under which the ratchet healing after the
epoch-4 compromise is checked. NEPOCHS=6 covers the paper's secrecy-to-4
(Def 2) and auth-to-5 (Def 3) bounds.

Non-vacuity is checked by `sanity.pv` (compromised epochs leak; an uncompromised
epoch between two leaking neighbours stays secret).

### Saturation control

Every query file carries `nounif` declarations that deprioritise the attacker
*constructing* symbolic ML-KEM ciphertexts / authenticator / MAC terms (the
decryption-oracle blow-up). `nounif` is **always sound** — it only changes
ProVerif's resolution order, never the verdict — and it is what makes the
multi-epoch runs converge. We use **no** `restriction`/`axiom` (those remove
traces — trust assumptions) and **no** induction lemmas.
