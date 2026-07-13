# Experiment: unbounded-epoch SPQR-CKA via ProVerif inductive lemmas

**Status: partial success (experimental branch, not merged).** Unbounded-epoch **secrecy
and mutual authentication** for the SPQR continuous key agreement (CKA) are proved by
induction on a faithful *abstraction* of the CKA core; unbounded **forward-secrecy-under-
compromise** remains blocked. Tool: **ProVerif 2.05**.

This lifts the committed bounded proof (`extraction-model/`, unrolled to `max_epoch()`) to
`∀ epochs` for the honest-run security core.

## The technique

Blanchet–Cheval–Cortier inductive lemmas ("ProVerif with Lemmas, Induction, …", IEEE S&P
2022), i.e. proving `F ⇒ F′` by induction on trace length: when saturation orders `σ′F`
strictly before `σF`, the induction hypothesis `σ′F′` is added to the clause. Grouping
correspondences with `[induction]` gives **mutual induction**. Two ProVerif-manual §6.7.2
knobs are essential and non-obvious:

- `nounif table(d(…)) [ignoreAFewTimes]` — lets ProVerif resolve once on a blocking
  memory-cell fact, exposing the `insert` so the IH's earlier event becomes visible.
- `nounif F [inductionOn=ep]` — simplifies nat-indexed recursive clauses so saturation
  **terminates** for an unbounded counter.

## The inductive invariant

A **circular, mutually-inductive bundle** (all `[induction]`, one group):

1. **Authenticator-chain secrecy** — `event(UsesAuth(ep,a)) && attacker(a) ⇒ false`
   (`UsesAuth` is a shadow event tagging each epoch's chain authenticator, so the IH has a
   hook). Step: `auth_{e+1}=auth_update(auth_e,k_e)` needs `auth_e`, forbidden by the IH.
2. **Epoch-key secrecy** — `event(Completed·(ep,k)) && attacker(k) ⇒ false`.
3. **Authentication** — `event(CompletedR(ep,k)) ⇒ event(CompletedS(ep,k))` and
   `CompletedS ⇒ StartedR`.

They are circular — (1) prevents MAC forgery ⇒ (2); (2) denies the attacker a key to
ratchet the chain ⇒ (1) — so they must be one group, not separate lemmas.

## Files (the experimental progression)

| file | what it shows |
|---|---|
| `spqr-cka-baseline.pv` | the bounded model reproduced (matches EXPECTPV) |
| `unbounded-v1.pv`, `exp1`, `exp3`, `exp5a` | naive unbounding → **non-termination** (table read never linked to its `insert`) |
| `exp6b-authchain-fix.pv` | minimal authenticator chain; **auth-secrecy proved by induction** |
| **`exp8b-cka.pv`** | **the headline** — clean unbounded continuous-KEM ratchet; secrecy (both roles) + mutual authentication all `is true` |
| `exp9b-cka-fs.pv` | `exp8b` + per-epoch KEM-key compromise (forward secrecy) → **blocked** |
| `exp8-output.txt`, `exp9-output.txt`, … | captured ProVerif output |

## Observed result (`exp8b-cka.pv`, ProVerif 2.05)

```
not (event(UsesAuth(ep,a))   && attacker(a)) is true.     (auth-chain FS, ∀ epochs)
not (event(CompletedS(ep,k)) && attacker(k)) is true.     (sender key secrecy, ∀ epochs)
not (event(CompletedR(ep,k)) && attacker(k)) is true.     (receiver key secrecy, ∀ epochs)
event(CompletedR(ep,k)) ==> event(CompletedS(ep,k)) is true.   (key agreement, ∀ epochs)
event(CompletedS(ep,k)) ==> event(StartedR(ep,p))   is true.   (authentication, ∀ epochs)
not event(CompletedR(ep,k)) is false.                     (ratchet reachable / non-vacuous)
```

## Honest limits

- **Fidelity:** `exp8b` is **unidirectional** (no per-epoch role swap) and uses a clean
  `aenc/adec` KEM, not the split-KEM. The chain structure, per-epoch KEM freshness and MAC
  authentication are faithful; the role swap and split-KEM are not.
- **Forward-secrecy-under-compromise is blocked** (`exp9b`): ProVerif's Horn-clause table
  abstraction permits spurious cross-epoch aliasing of per-epoch fresh secrets, which
  becomes a false attack once a key leaks. This is the precise obstacle.
- **To reach the extraction-grade model** needs: (a) epoch as an explicit table column (so
  `inductionOn=ep` tames the split-KEM saturation loop) and (b) dropping the temporal
  `@j && j<i` refinement from the confidentiality query (ProVerif forbids temporal facts in
  an inductive-lemma conclusion, manual §6.2).

## Reproduce

```
proverif exp8b-cka.pv     # from this directory (ProVerif 2.05)
```
