# SPQR — formal-verification status

SPQR is analyzed by **two independent, complementary proof efforts**:

- **F\*** (via [hax](https://github.com/cryspen/hax)) — machine-checks the Rust
  *implementation* for **panic-freedom / totality**, plus **functional correctness of
  the finite-field arithmetic**.
- **ProVerif** (via hax's ProVerif backend) — machine-checks a symbolic (Dolev–Yao)
  *model compiled from the Rust source* for **reachability, confidentiality with forward
  secrecy, and mutual authentication** of the public ratchet.

This document is the **single source of truth for _what_ is established and the _trust
boundary_** — read it before relying on any security claim. It intentionally does **not**
duplicate the reproduction recipes: for *how to re-run* each system see
[`fstar/REPRODUCING.md`](fstar/REPRODUCING.md) and
[`proverif/REPRODUCING.md`](proverif/REPRODUCING.md).

---

## TL;DR

| | F\* | ProVerif |
|---|---|---|
| **Object** | the real Rust (`src/**`, extracted fresh) | a model *compiled* from `src/v1/unchunked` |
| **Establishes** | panic-freedom + GF(2¹⁶) arithmetic correctness | reachability, confidentiality + FS, mutual auth |
| **Scope** | whole crate (panic-freedom); GF16 only (functional) | the CKA / public ratchet, bounded epochs |
| **Trusted** | ML-KEM interface; hash/PRF/XOF; GF16 reduction; see below | symbolic crypto; `ek_matches` binding; see below |

Neither effort proves ML-KEM itself, the message-key double ratchet, chunking, or version
negotiation. Post-compromise *healing* holds against a key-only compromise but **not**
against an authenticator compromise. Details and exact counts below.

---

## F\* — panic-freedom + finite-field correctness

`python3 hax.py extract` compiles the Rust to F\*; `python3 hax.py prove` typechecks it
(full SMT) against the hand-written spec models in
[`fstar/models/`](fstar/models/). CI (`.github/workflows/hax.yml`) runs both on every
push. See [`fstar/REPRODUCING.md`](fstar/REPRODUCING.md) to reproduce.

**What is proven.**

- **Panic-freedom / totality for most of the crate** — no out-of-bounds indexing, no
  integer overflow, exhaustive matches, termination. This is the hax→F\* default
  obligation and it is discharged for the bulk of `src/**`.
- **Functional correctness of the GF(2¹⁶) finite-field arithmetic** — the add/sub and
  carry-less multiply in `src/encoding/gf.rs` are proven equal to a bit-vector field spec
  (`Spec.GF16.fst`). This is the "finite field arithmetic is machine verified to be
  correct" claim, and it is the *only* deep functional-correctness result: 13 of the
  crate's 39 `ensures` clauses are genuine GF16 correctness couplings; the other 26 are
  length/shape/epoch **invariants** (e.g. `res.len() == MACSIZE`) that support
  panic-freedom, not protocol correctness.

**What is trusted or axiomatized (the F\* trust boundary).**

- **ML-KEM is trusted as an interface, not re-verified.** Every `Libcrux_ml_kem.*` model
  in `fstar/models/` is an **interface-only `.fsti` with no implementation** — its
  functional-correctness postconditions (relating libcrux's output to `Spec.MLKEM`) are
  **assumed**. Sampling (`sample_poly_cbd`) and the hash/PRF/XOF primitives are abstract
  oracles. SPQR *trusts* libcrux's ML-KEM; it does not machine-check it.
- **The GF16 field reduction is axiomatized.** Addition and carry-less multiplication are
  proven against the bit-vector spec, but the **reduction modulo the irreducible
  polynomial** — the step that actually makes the ring a *field* — bottoms out in an
  `assume val` (`poly_reduce`) plus 5 `admit()`-ed field laws in `Spec.GF16.fst`.
- **In-source escape hatches weaken even panic-freedom.** The Rust carries **30
  `hax_lib::assume!` in-body assumptions**, **14 `#[hax_lib::opaque]`** unverified
  function bodies, and **one `verification_status(lax)`** function — the top-level
  `send` entry point in `lib.rs`, which is not verified at all. "Panic-free" therefore
  holds *modulo* these admitted obligations, not unconditionally.

**Headline number.** 13 `assume val` + 5 live `admit()` in `fstar/models/` (concentrated
in `Spec.GF16.fst`: 11 assumes + 5 admits; plus 2 assumes in `Spec.MLKEM.fst`), on top of
~300 trusted `val`s across 23 interface-only `.fsti` modules (libcrux, prost, sorted_vec,
bytes), plus 30 `assume!` + 14 `opaque` + 1 `lax` in the Rust source.

**Do not read the F\* proof as:** ML-KEM correctness, Reed-Solomon / polynomial encoding
correctness, KDF or authenticator correctness, or protocol-state-machine functional
correctness — none of these are proven; only panic-freedom (modulo the above) is.

---

## ProVerif — symbolic security of the public ratchet (CKA)

The **public ratchet / continuous key agreement (CKA)** of SPQR (`spqr::v1::unchunked`)
is analyzed in ProVerif via a model **compiled from the Rust source** by hax's ProVerif
backend, and cross-checked against a hand-written reference. Checked via `python3 hax.py
check-proverif` (default bound `NEPOCHS = 4`, canonical up to 6). See
[`proverif/REPRODUCING.md`](proverif/REPRODUCING.md) to reproduce and
[`proverif/README.md`](proverif/README.md) for the model design.

| Property | Query | Result |
|---|---|---|
| State machine is reachable (non-vacuity control) | `reach.pv` | ✅ all reachable |
| Confidentiality of the epoch secret | `conf.pv` | ✅ holds — *see FS/PCS below* |
| Mutual authentication (injective agreement) | `auth.pv` | ✅ holds at uncompromised epochs |
| Compromise model "bites" (non-vacuity) | `sanity.pv` | ✅ epoch 2 secret **holds** while epochs 1/3/4 **leak** |
| Hand-written CKA reference | `handwritten/spqr-cka.pv` | ✅ |
| Hand-written symmetric ratchet (idealized CKA) | `handwritten/spqr-dr.pv` | ✅ |

**Forward secrecy: yes.** A secret established at epoch *e* stays secret against a
compromise *after* epoch *e* (`sanity.pv`: epoch-2's secret holds even though later
epochs are compromised).

**Post-compromise security: partial — read carefully.** The `conf.pv` verdict is **sound
but *permissive***: its conclusion *excuses* every epoch ≥ the epoch of an authenticator
compromise, so a passing verdict must **not** be read as post-compromise healing.

- Healing from a **KEM-key** compromise **does** hold (a fresh epoch recovers secrecy).
- Healing from an **authenticator** compromise **does not**: because the epoch header MAC
  is keyed by the (chained) authenticator, an active attacker who learns it can forge the
  next header MAC, inject its own KEM keypair (which passes `ek_matches`), and
  decapsulate — a **persistent MITM** from that epoch onward. This is a property of
  MAC-chain authentication and is **shared by the hand-written `spqr-cka.pv`**; it is not
  an artifact of the extraction.

**Trust boundary.**

- **Cryptographic primitives are trusted symbolic abstractions** (split-KEM, chaining
  MAC, KDF) — only the crypto *leaves* are hand-modelled (via
  `#[proverif::replace_body]` / `#[pv_extern]`); the state machine is the real Rust.
- **Highest-leverage assumption: `ek_matches` / `validate_pk_bytes` is fully binding** —
  for a MAC-authenticated header, at most one encapsulation key validates. The whole
  ek-authenticity argument rests on this; it is faithful to the Rust but should be
  validated separately (e.g. in a computational proof).
- **Scope is CKA-only, and bounded.** The message-key double ratchet, chunked reassembly,
  and V0/V1 version negotiation are out of scope; the ratchet is unrolled to `max_epoch()`
  (guarantees hold for that many epochs, not inductively for all).

Both the extracted and hand-written models were reviewed by an independent, adversarial
ProVerif audit (no dropped checks, no vacuity from the reachability pruning). An
independent Aeneas-Pure-IR ProVerif backend reproduces the same verdicts as a cross-check.

**Experimental (not part of the headline result).** Unbounded-epoch CKA *secrecy + mutual
authentication* have been proved via ProVerif inductive lemmas on a faithful *abstraction*
of the CKA core (branch `proverif-cka-inductive`); a partial message-key double-ratchet
extraction is on branch `dr-proverif-experiment`. Lifting either to the extraction-grade
model is open.

---

## What is NOT proven (combined)

- **ML-KEM** itself — trusted as an interface in F\* and as a symbolic abstraction in
  ProVerif.
- **The message-key double ratchet, chunking/erasure-coding, and version negotiation** —
  out of scope of both the ProVerif security proof and the F\* functional proof (the DR
  is analyzed only abstractly and experimentally).
- **Functional correctness of the protocol state machines, KDF, or authenticator** — F\*
  proves only panic-freedom for these (modulo the in-source assumptions above); ProVerif
  proves symbolic *security*, not functional correctness.
- **Post-compromise healing after an authenticator compromise** — does not hold (see
  above).
