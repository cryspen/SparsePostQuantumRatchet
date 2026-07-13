// Copyright 2025 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

use crate::Epoch;

// ProVerif (DR experiment): model HKDF as an opaque, collision-free one-way
// function `extern__hkdf_to_vec(salt, ikm, info, okm_len)`. `pv_extern` emits a
// plain `fun` (NOT `[data]`), so the derived key material is genuinely one-way
// (the attacker cannot invert an output back to the chain key / epoch secret).
#[cfg_attr(hax_backend_proverif, hax_lib::pv_extern)]
#[cfg_attr(not(hax_backend_proverif), hax_lib::opaque)]
#[hax_lib::ensures(|res| res.len() >= okm_len)]
pub fn hkdf_to_vec(salt: &[u8], ikm: &[u8], info: &[u8], okm_len: usize) -> Vec<u8> {
    let mut out = vec![0u8; okm_len];
    hkdf_to_slice(salt, ikm, info, &mut out);
    out
}

/// Derive the per-epoch SCKA secret from a KEM shared secret, with
/// epoch-indexed domain separation. Both the CT generator (`send_ct1`) and the
/// EK generator (`recv_ct2`) call this on the same shared secret, so they
/// agree on the derived secret.
///
/// In the ProVerif model this is an opaque, collision-free one-way function
/// `extern__derive_scka_secret(secret, epoch)`.
#[cfg_attr(hax_backend_proverif, hax_lib::pv_extern)]
pub fn derive_scka_secret(kem_ss: &[u8], epoch: Epoch) -> Vec<u8> {
    let info = [
        b"Signal_PQCKA_V1_MLKEM768:SCKA Key".as_slice(),
        epoch.to_be_bytes().as_slice(),
    ]
    .concat();
    hkdf_to_vec(&[0u8; 32], kem_ss, &info, 32)
}

#[hax_lib::opaque]
#[hax_lib::ensures(|_| future(okm).len() == okm.len())]
pub fn hkdf_to_slice(salt: &[u8], ikm: &[u8], info: &[u8], okm: &mut [u8]) {
    hkdf::Hkdf::<sha2::Sha256>::new(Some(salt), ikm)
        .expand(info, okm)
        .expect("all lengths should work for SHA256");
}
