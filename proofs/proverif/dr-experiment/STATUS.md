# Experiment: extracting the SPQR double ratchet to ProVerif

**Status: partial success (experimental branch, not merged).** The double-ratchet
*message-key* cryptographic core extracts to ProVerif via hax and verifies message-key
secrecy + forward secrecy; the *full* `src/chain.rs` does not extract (blocked by loops
in the out-of-order/GC bookkeeping, which is transport plumbing, not crypto).

> Branch base: `proverif-rust-backend @ 1a48d78` (pre-driver-consolidation). This is a
> throwaway exploration branch; it modifies `src/` and is **not** intended to merge as-is.

## What this branch adds

- **`src/dr_chain_model.rs`** — a loop-free, in-order re-expression of the DR chain that
  mirrors `chain.rs`'s crypto **byte-for-byte** (identical HKDF salts, `info` labels,
  96/64-byte output sizes, slice offsets `[0..32]/[32..64]/[64..96]`):
  - `chain_init` ⟷ `Chain::new` (salt `[0;32]`, label `"Signal PQ Ratchet V1 Chain  Start"`)
  - `chain_add_epoch` ⟷ `Chain::add_epoch` (salt = `next_root`, label `"…Chain Add Epoch"`)
  - `ratchet` ⟷ `ChainEpochDirection::next_key_internal` (salt `[0;32]`, info
    `ctr.to_be_bytes() ‖ "…Chain Next"`, `new_ck=out[0..32]`, `msg_key=out[32..64]`)
- **`src/kdf.rs`** — the HKDF wrapper switched from `#[hax_lib::opaque]` to `pv_extern`.
  **Finding:** under `#[opaque]` hax emits `fun …hkdf_to_slice(...) : bitstring [data]` — a
  `[data]` constructor is **invertible**, i.e. crypto-**unsound** for a KDF (the attacker
  could recover the chain key from an output). `pv_extern` instead emits a one-way
  `fun extern__hkdf_to_vec(...)` (no `[data]`) + a wrapper letfun.
- **`proofs/proverif/dr-experiment/`** — the generated `.pvl` is composed with queries here:
  - `dr_secrecy_concrete.pv` — message-key secrecy (fresh/secure CKA)
  - `dr_forward_secrecy.pv` — FS under a chain-key-state leak
  - `dr_secrecy.pv` — table-model reachability
  - `dr_missing.pvl`, `run.sh` — 3 undefined `info`-label helpers + the runner

## Observed ProVerif verdicts (ProVerif 2.05)

**Message-key secrecy** (`dr_secrecy_concrete.pv`, no compromise): `mk1`, `mk2`, `mk3` all
SECRET; `Made(1..3)` reachable.

**Forward secrecy** (`dr_forward_secrecy.pv`, leak the chain-key state `ck2`):
```
not (event(Made(1,mk)) && attacker(mk)) is true.    (mk1 SECRET despite ck2 leak — FS)
not (event(Made(2,mk)) && attacker(mk)) is true.    (mk2 SECRET despite ck2 leak — FS)
not (event(Made(3,mk)) && attacker(mk)) is false.   (mk3 reachable via ck2 — leak is real)
```
Leaking the persisted chain-key state reveals only *forward* keys (mk3+), never past keys
(mk1, mk2) — exactly the symmetric-ratchet FS property.

## Blockers to extracting the *whole* `chain.rs`

1. **Loops unsupported.** `while` in `Chain::send_key` (`chain.rs:391,396`) and
   `ChainEpochDirection::key` (`chain.rs:270`) → `"Loops not supported in ProVerif"`.
   `KeyHistory::get`/`gc` are already `#[opaque]` (step_by loops). Needs backend loop
   support, or `replace_body`/opaque on the four bookkeeping methods. **All of this is
   out-of-order / GC / trim plumbing — not crypto** — which is why abstracting it
   (this branch's approach) loses nothing cryptographically.
2. **`VecDeque` + byte-packed `KeyHistory`** (`push_back`/`pop_front`/`copy_within`/…) land
   in `missingdecl` — a faithful whole-`Chain` model would need Dolev-Yao models for them.
3. **Recursive-table precision.** The unbounded ratchet as a self-referential
   `Chains(ctr)→Chains(ctr+1)` table triggers a termination warning; worked around with
   concrete unrolled scenarios (as the hand-written `spqr-dr.pv` also does with `max_ctr=3`).

## Comparison to the hand-written `handwritten/spqr-dr.pv`

On the message-key KDF this model is **more faithful** — the salts, domain-separation
labels, output lengths and slice offsets are the real Signal constants compiled from
`chain.rs`, not hand-invented. It is **equally abstract** on the CKA (fresh keys) and on the
OOO/GC transport bookkeeping.

## Reproduce

```
export HAX_PROVERIF_DIR=~/hax-proverif-backend
eval "$(opam env --switch=hax-proverif)"
cd <this worktree>
cargo hax into -i '-** +~spqr::dr_chain_model::**' proverif   # -> extraction/lib.pvl
bash proofs/proverif/dr-experiment/run.sh
```
