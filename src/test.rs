// Copyright 2025 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

#![cfg(any(test, feature = "test-utils"))]
pub mod basic_messaging_behavior;
pub mod generic_dr;
pub mod messaging_behavior;
pub mod messaging_scka;
pub mod onlineoffline;
pub mod orchestrator;
pub mod scka;
pub mod v1_impls;

/// Re-export of the concrete V1-chunked state/message types so external
/// consumers (e.g. the `spqr-trace-adapter`) can name the
/// [`scka::Scka`] / [`messaging_scka::MessagingScka`] implementor without
/// widening the public surface to all of `v1`.
pub mod v1_states {
    pub use crate::v1::chunked::states::{Message, MessagePayload, Recv, Send, States};
}

// pingpong_messaging_behavior pulls in `rand_distr` and x25519_scka pulls in
// `rand_08`; both live in dev-dependencies and aren't available when the
// `test-utils` feature is enabled outside of cargo-test. They are only used
// by SPQR's own unit tests and aren't part of the public orchestrator
// surface, so gate them on cfg(test) only.
#[cfg(test)]
pub mod pingpong_messaging_behavior;
#[cfg(test)]
pub mod x25519_scka;
