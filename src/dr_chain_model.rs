// Copyright 2025 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

//! DR-EXPERIMENT (not part of the shipped library).
//!
//! A loop-free, in-order re-expression of the SPQR Double-Ratchet *message-key*
//! chain (`src/chain.rs`), written so the hax ProVerif backend can extract it.
//!
//! It keeps the cryptographic core of `chain.rs` byte-for-byte faithful:
//!   * `chain_init`      mirrors `Chain::new`                 (src/chain.rs:329)
//!   * `chain_add_epoch` mirrors `Chain::add_epoch`           (src/chain.rs:350)
//!   * `ratchet`         mirrors `ChainEpochDirection::next_key_internal`
//!                                                            (src/chain.rs:228)
//! — identical HKDF salts, `info` labels, output sizes and slice offsets.
//!
//! What it deliberately drops (all *non-cryptographic* transport bookkeeping
//! that forces the two `while` loops the ProVerif backend cannot compile):
//!   * out-of-order key history / `KeyHistory` byte-packed storage
//!   * garbage collection / trimming
//!   * the `VecDeque<ChainEpoch>` epoch collection (CKA plumbing; abstracted as
//!     fresh epoch secrets, see the process model)
//! The chain advances exactly ONE step per `ratchet` call; ProVerif's process
//! replication unrolls the counter (as in the hand-written spqr-dr.pv).

use crate::kdf;

/// A per-direction message chain key (`chain.rs`: `ChainEpochDirection.next`, 32 bytes).
pub type ChainKey = Vec<u8>;
/// A derived message key (32 bytes).
pub type MsgKey = Vec<u8>;
/// The chain root key (`chain.rs`: `Chain.next_root`, 32 bytes).
pub type RootKey = Vec<u8>;

/// Mirror of `Chain::new` (src/chain.rs:329-348): from the initial CKA key derive
/// `(next_root, send_chain_key, recv_chain_key)`.
/// Faithful: `hkdf(salt=[0;32], ikm=initial_key, info="Signal PQ Ratchet V1 Chain  Start", 96)`,
/// then `next_root = out[0..32]`, and the two directions are `out[32..64]` / `out[64..96]`
/// (see `Chain::ced_for_direction`, src/chain.rs:322).
pub fn chain_init(initial_key: &[u8]) -> (RootKey, ChainKey, ChainKey) {
    let g = kdf::hkdf_to_vec(
        &[0u8; 32],
        initial_key,
        b"Signal PQ Ratchet V1 Chain  Start",
        96,
    );
    (g[0..32].to_vec(), g[32..64].to_vec(), g[64..96].to_vec())
}

/// Mirror of `Chain::add_epoch` (src/chain.rs:350-369): ratchet the root with the
/// next CKA epoch secret to derive the new `(next_root, send_ck, recv_ck)`.
/// Faithful: `hkdf(salt=next_root, ikm=epoch_secret, info="Signal PQ Ratchet V1 Chain Add Epoch", 96)`.
pub fn chain_add_epoch(next_root: &[u8], epoch_secret: &[u8]) -> (RootKey, ChainKey, ChainKey) {
    let g = kdf::hkdf_to_vec(
        next_root,
        epoch_secret,
        b"Signal PQ Ratchet V1 Chain Add Epoch",
        96,
    );
    (g[0..32].to_vec(), g[32..64].to_vec(), g[64..96].to_vec())
}

/// Mirror of `ChainEpochDirection::next_key_internal` (src/chain.rs:228-245): one
/// symmetric-ratchet step. Faithful: `hkdf(salt=[0;32], ikm=chain_key,
/// info=ctr.to_be_bytes()||"Signal PQ Ratchet V1 Chain Next", 64)`, then
/// `new_chain_key = out[0..32]`, `msg_key = out[32..64]`.
/// Returns `(new_chain_key, msg_key)`; the caller supplies `ctr+1` (as the real
/// code increments `ctr` before deriving).
pub fn ratchet(chain_key: &[u8], ctr: u32) -> (ChainKey, MsgKey) {
    let info = [
        ctr.to_be_bytes().as_slice(),
        b"Signal PQ Ratchet V1 Chain Next",
    ]
    .concat();
    let g = kdf::hkdf_to_vec(&[0u8; 32], chain_key, &info, 64);
    (g[0..32].to_vec(), g[32..64].to_vec())
}
