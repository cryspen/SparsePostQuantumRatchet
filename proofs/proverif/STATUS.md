# SPQR ProVerif analysis — status

A precise summary of what the symbolic (Dolev–Yao) ProVerif analysis of SPQR
currently establishes, its trust boundary, and its limits. For *what is here* see
[`README.md`](README.md); for *how to reproduce* see [`REPRODUCING.md`](REPRODUCING.md).

## TL;DR

The **public ratchet / continuous key agreement (CKA)** of SPQR (`spqr::v1::unchunked`)
is analyzed in ProVerif via a model **compiled from the Rust source** by
[hax](https://github.com/cryspen/hax), and cross-checked against a hand-written
reference. It establishes **reachability, confidentiality with forward secrecy, and
mutual authentication** for a **bounded** number of epochs under an explicit
compromise model. Post-compromise *healing* holds against a key-only compromise but
**not** against an authenticator compromise (see below). The message-key double
ratchet, chunking, and version negotiation are **out of scope** of the extracted
proof.

## What is proven — and what is not

Checked via `python3 hax.py check-proverif` (asserts each query's `(* EXPECTPV *)`
block); default bound `NEPOCHS = 4`, canonical up to 6.

| Property | Query | Result |
|---|---|---|
| State machine is reachable (non-vacuity control) | `reach.pv` | ✅ all reachable |
| Confidentiality of the epoch secret | `conf.pv` | ✅ holds — *see FS/PCS below* |
| Mutual authentication (injective agreement) | `auth.pv` | ✅ holds at uncompromised epochs |
| Compromise model "bites" (non-vacuity) | `sanity.pv` | ✅ epoch 2 secret **holds** while epochs 1/3/4 **leak** |
| Hand-written CKA reference | `handwritten/spqr-cka.pv` | ✅ |
| Hand-written symmetric ratchet (idealized CKA) | `handwritten/spqr-dr.pv` | ✅ |

**Forward secrecy: yes.** A secret established at epoch *e* stays secret against a
compromise that happens *after* epoch *e* (`sanity.pv`: epoch-2's secret holds even
though later epochs are compromised).

**Post-compromise security: partial — read this carefully.** The `conf.pv` verdict is
**sound but *permissive***: its conclusion *excuses* every epoch ≥ the epoch of an
authenticator compromise, so a passing verdict must **not** be read as post-compromise
healing. Concretely:

- Healing from a **KEM-key** compromise **does** hold (a fresh epoch recovers secrecy).
- Healing from an **authenticator** compromise **does not**: because the epoch header
  MAC is keyed by the (chained) authenticator, an active attacker who learns it can
  forge the next header MAC, inject its own KEM keypair (which passes `ek_matches`),
  and decapsulate — a **persistent MITM** from that epoch onward. Under the committed
  compromise scenario the secrets of the post-compromise epochs are in fact
  attacker-reachable. This is a property of MAC-chain authentication and is **shared by
  the hand-written `spqr-cka.pv`**; it is not an artifact of the extraction.

## Model architecture

Two independent tracks, both under this folder:

- **Extracted model** (in lock-step with the code): `extraction/lib.pvl` is compiled
  from `spqr::v1::unchunked` by hax's ProVerif backend (never hand-edited).
  `extraction-model/` supplies the hand-written wrapper — symbolic crypto
  (`handwritten_lib.pvl`), the process + compromise model (`model.pvl`), the epoch
  bound (`nepochs.pvl`), and the queries. Only the **cryptographic primitives** are
  abstracted (via `#[proverif::replace_body]` / `#[pv_extern]` on the source); the
  **state machine is the real Rust**, so the analyzed protocol tracks the implementation.
- **Hand-written reference**: `handwritten/spqr-cka.pv` (CKA) and `handwritten/spqr-dr.pv`
  (symmetric ratchet, over an *idealized* fresh-key CKA), with `handwritten/cryptolib.pvl`.

Extraction is **rooted at the state-machine entry points** (send/recv-ek/ct), so the
generated `lib.pvl` contains only the reachable protocol + crypto (~600 lines) and not
the dead protobuf-serialization tree.

## Trust boundary & key assumptions

- **Cryptographic primitives are trusted symbolic abstractions** (split-KEM, chaining
  MAC, KDF) — their symbolic soundness is assumed, not proven here.
- **Highest-leverage assumption: `ek_matches` / `validate_pk_bytes` is fully binding** —
  for a MAC-authenticated header `hdr` (= pk1) at most one encapsulation key `ek` (= pk2)
  validates. The whole ek-authenticity argument rests on this; it is faithful to the
  Rust, but should be validated separately (e.g. in the computational proof).
- **Scope is CKA-only.** The message-key double ratchet, chunked reassembly, and V0/V1
  version negotiation are not covered by the extracted proof (the DR is analyzed
  separately and abstractly in `spqr-dr.pv`).

Both the extracted and hand-written models were reviewed by an independent, adversarial
ProVerif audit (no dropped checks, no vacuity introduced by the reachability pruning;
every MAC/KEM gate is present and enforced). An independent Aeneas-Pure-IR ProVerif
backend reproduces the same verdicts as a cross-check.

## Reproducing

```
# one-time: build the pinned hax ProVerif backend (or set HAX_PROVERIF_DIR)
python3 hax.py setup

python3 hax.py extract-proverif        # Rust -> extraction/lib.pvl
python3 hax.py check-proverif          # run ProVerif + assert every EXPECTPV block
```

`hax.py` is the single entry point (`setup` / `extract-proverif` / `verify-proverif` /
`check-proverif`). CI runs `check-proverif` on every push and re-extracts + drift-checks
nightly.

## Bounded vs. unbounded, and future work

- The extracted proof is **bounded** (the ratchet is unrolled to `max_epoch()`), so the
  guarantees are for that many epochs, not inductively for all epochs.
- **Experimental:** unbounded-epoch CKA *secrecy + mutual authentication* have been
  proved via ProVerif inductive lemmas (Blanchet–Cheval–Cortier) on a faithful
  *abstraction* of the CKA core; lifting this to the extraction-grade model
  (epoch-indexed tables, and the unbounded forward-secrecy-under-compromise case) is open.
- Minor: three libcrux ML-KEM length functions remain in the (unused, gitignored)
  `missingdecl` diagnostic; making that file empty is cosmetic.
