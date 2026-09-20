# Working notes for Claude in this repo

## Conventions (non-negotiable)

- **Do not add comments to Signal code without asking first.** No exceptions — not
  doc comments, not inline notes, not rationale. Ask, then add only what is approved.
- **No commentary about history, plans, or the verification campaign in source files.**
  Source is not scratch space. Anything of that kind goes here.
- **No `Co-Authored-By` trailers** on commits.

## Toolchain

- opam switch `hax-0.4.0` (cargo-hax `d19844c776`), F* 2026.03.24, z3 4.13.3.
- `hax-lib` is pinned in `Cargo.toml` to `cryspen/hax` branch
  `fix/while-loop-inner-let-rec` (lifts `while_loop_internal` to a top-level
  `let rec`; without it, loop proofs are vacuous on F* >= v2025.12.15).
- Extract: `eval $(opam env --switch=hax-0.4.0)` then
  `rm -f proofs/fstar/extraction/*.fst* && ./hax.py extract`.
- Verify: `make -C proofs/fstar/extraction all-keep-going`
  (`./hax.py prove` stops at the first failure).
- Tests need nightly: `cargo +nightly test` (`feature(assert_matches)`).

## Verification status (2026-09-20)

Every extracted module verifies, on this aarch64 host and (for the parts that are
arch-independent) as CI sees them. No `Core_arch` reference remains anywhere in the
extraction, so no host-specific intrinsic model is needed.

Hatch counts in `src/`: 31 `assume!`, 0 `v_assume`, 16 `#[hax_lib::opaque]`,
1 `#[hax_lib::exclude]`, 1 `verification_status(lax)`,
1 `verification_status(panic_free)`. Three of the opaque sites are new in `gf.rs`:
two intrinsic leaves carrying full postconditions (they displace an unmodelled
intrinsic) and one CPU-feature oracle.

## Notes on changes that carry no source comment

- `hax.py`: `cargo hax into ... fstar --z3rlimit 300` (libcrux uses 80). hax's
  default of 15 was far too low — `Poly::mult_xdiff_assign_trailing` needs ~26,
  `impl Decoder for PolyDecoder` ~44, `send_ct::recv_hdr_chunk` ~76, `lib.rs::recv`
  ~211 — and F* responded by splitting queries and then failing a split sub-query.
  The `decoded_message` failure was previously recorded as an assertion gap; it is
  not, it is a resource limit. Raising the default unblocked `Spqr.Encoding.Bundle`
  and with it `Spqr.Bundle` and everything downstream (previously nothing in
  `chain.rs`, `lib.rs` or `v1/**` was being checked at all).
- `encoding.rs`: the `Encoder for Option<T>` / `Decoder for Option<T>` impls were
  dead (nothing in the crate, tests or benches uses them) and existed only to carry
  three `Hax_lib.v_assume`s re-establishing the inner type's trait precondition,
  which is not expressible generically. Deleted.
- `v1/unchunked/send_ek.rs`: `EkSentCt1Received::recv_ct2` bumped `epoch + 1` under
  `hax_lib::assume!(epoch < u64::MAX)`. Epoch comes from the decoded state, which is
  treated as untrusted, so the assume was not justified. Replaced with
  `checked_add(1).ok_or(Error::EpochOutOfRange(epoch))?`. A `requires` was rejected:
  the invariant is not inductive (the increment itself can reach `u64::MAX`), so the
  boundary check has to exist somewhere regardless.
- `v1/chunked/states/serialize.rs`: `Message::deserialize`'s postcondition was
  `msg.epoch > 0`. Since `cb8a727` the epoch is a pass-through argument rather than
  parsed from the message, so nothing constrains it and the postcondition is
  unprovable — this was blocking `Spqr.Bundle`. Replaced with `msg.epoch == epoch`,
  which is provable and still lets a caller that knows `epoch > 0` conclude it. The
  `> 0` fact that `recv` relies on comes from `msg_preamble`, not from here.
- `lib.rs`: in `recv`'s version-downgrade branch,
  `msg.version.try_into().expect("should support all lower versions")` became
  `map_err(|_| Error::VersionMismatch)?`. The panic is in fact unreachable
  (`current_version` is 1 there, so `msg.version` is 0), but F* could not discharge
  it inside a function that large, and `msg.version` is attacker-supplied.
- `kdf.rs`: `hkdf_to_vec` de-opaqued. Its body is `vec![0u8; okm_len]` followed by
  `hkdf_to_slice`, whose `ensures` preserves length, so `res.len() >= okm_len` is
  provable; only `hkdf_to_slice` (which calls the `hkdf`/`sha2` crates) is genuinely
  external.
- `encoding/gf.rs`: both `accelerated::mul2_unreduced` (x86 pclmulqdq, aarch64
  `vmull_p64`) got `#[hax_lib::opaque]` plus a `poly_mul` postcondition. This is the
  entire intrinsic surface of the crate — the 32-bit ARM backend is inside a `/* */`
  block comment upstream, and `test::x86_barrett_reduction` is `#[cfg(test)]`, so
  neither reaches hax. With the bodies elided, `Core_arch` disappears from the
  extraction and `Spqr.Encoding.Gf.Accelerated` typechecks on any host; before this,
  aarch64 extraction referenced `Core_models.Core_arch.Aarch64.Neon.Generated`, which
  the hax proof-libs do not model (they have `Arm_shared.Neon` and `X86.Pclmulqdq`).
  The aarch64 leaf's return type changed from `u128` to `(u32, u32)` so both backends
  carry the *same* contract: they are two `cfg` alternatives of one logical function.
  That moved the shift/cast from `mul2` into the leaf — same two operations, same
  codegen, opposite side of an `#[inline]` boundary. `poly_mul` is `Spec.GF16`'s, the
  same function `unaccelerated::poly_mul` is specified against.

  This follows libcrux's `core-models` pattern (`crates/utils/core-models`, where
  `vmull_p64` is an `unimplemented!()` stub with an int-vec interpretation, a
  `mk_lift_lemma!` and a hardware differential test) but at a coarser grain: one
  trusted leaf per backend covering ~5 instructions, instead of per-intrinsic
  wrappers. Per-intrinsic specs are not possible locally — hax's `t_e_ee_m128i` is
  abstract, so there is no vocabulary to state what `_mm_set_epi64x` or
  `_mm_cvtsi128_si32` return without rebuilding a `BitVec<128>` model.

  With the leaves opaque, the `not(hax)` gates on the two dispatch sites came off,
  so the accelerated path is now extracted and verified rather than skipped. That
  needed `check_accelerated` (`LazyLock` + `cpufeatures`, not extractable) to move
  from `#[cfg(not(hax))]` to `#[hax_lib::exclude]`, plus an opaque
  `fn use_accelerated() -> bool` outside it for the dispatch to call. Extracted
  shape: `if uuse_accelerated () then mul2 a b1 b2 else <unaccelerated>`.

## Open

- `hkdf_to_slice` is still `#[hax_lib::opaque]`. The campaign wants external
  primitives as a named ledger — one documented interface `val` in
  `proofs/fstar/models/`, not an inline hatch. That means moving the `hkdf` crate
  call into its own Rust module, excluding it from extraction, and committing the
  model. Not done: it restructures the crate, so ask first.
- `recv` in `lib.rs` needs ~211 rlimit for a single query. It verifies, but that is
  a fragile proof; splitting the function would be the durable fix.
- `mul2_u16` and `MulAssign::mul_assign` now extract both branches, but neither
  carries a functional postcondition, so what is proven of the accelerated path is
  panic-freedom, not equivalence to `unaccelerated`. The pieces for equivalence are
  in place (`mul2_unreduced`'s `poly_mul` ensures + `poly_reduce`'s ensures); it
  needs an `ensures` on `mul2_u16`/`mul_assign` tying both branches to the same
  `Spec.GF16` value.
- A differential test (`accelerated::mul2` vs `unaccelerated::mul`) is still worth
  adding: the only current coverage is `gf.rs`'s `mul` test against
  `galois_field_2pm`, 100 random pairs, through whichever path the token picked.
