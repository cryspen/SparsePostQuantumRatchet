# SPQR: The Sparse Post Quantum Ratchet

## Table of Contents
- [Overview](#overview)
- [Testing](#testing)
- [Formal Verification](#formal-verification)
- [Contributing](#contributing)
- [License](#license)

## Overview
SPQR is a Rust implementation of Signal's post-quantum secure ratchet protocol.
It can be used with a messaging protocol to provide post-quantum Forward Secrecy
(FS) and Post Compromise Security (PCS). Rather than implementing a full secure
messaging protocol, this implementation outputs *message keys* that can be used
to encrypt messages being sent and decrypt messages being received. The allows
easy integration of SPQR into a *hybrid secure* protocol, as described in
Signal's online documentation.

Notable modules include:
* [`chain.rs`](src/chain.rs): Implements the symmetric ratchet that provides
  forward secrecy.
* [`encoding/polynomial.rs`](src/encoding/polynomial.rs): Implements
  Reed-Solomon based systematic erasure codes used to robustly turn a long
  messages into a stream of chunks so that, for *N*-chunk message, as long as
  *any* N chunks are received, the message can be reconstructed.
* [`v1`](src/v1/): Implements the *ML-KEM Braid Protocol*, which serves as the
  public ratchet part of this protocol, replacing the Diffie-Hellman ratchet in
  the classical Double Ratchet protocol. A detailed description of this protocol
  can be found in Signal's online documentation.


## Testing
To run unit tests:
```
cargo test
```
For benchmarks (requires Rust nightly):
```
cargo +nightly bench
```


## Formal Verification
This crate is machine-checked with [hax](https://github.com/cryspen/hax) and
[F*](https://fstar-lang.org/) for **panic-freedom** (plus functional correctness of the
finite-field arithmetic), and its public ratchet is analyzed symbolically with
[ProVerif](https://bblanche.gitlabpages.inria.fr/proverif/) for confidentiality,
forward secrecy, and mutual authentication. Both run as part of CI.

**What is actually proven — and the trust boundary — is documented in
[`proofs/PROOF_STATUS.md`](proofs/PROOF_STATUS.md);** read it before relying on any
guarantee. To reproduce each proof effort, see
[`proofs/fstar/REPRODUCING.md`](proofs/fstar/REPRODUCING.md) and
[`proofs/proverif/REPRODUCING.md`](proofs/proverif/REPRODUCING.md).

To run the F* verification locally:
1. Set up hax and F*
   [(instructions)](https://hacspec.org/book/quick_start/intro.html)
2. Ensure you have `python3` installed
3. In the root directory of this repository run `python3 hax.py extract` to
   extract F* from the Rust source code.
4. In the root directory of this repository run `python3 hax.py prove` to
   typecheck the extracted F* against the spec models.

## Contributing
Signal does accept external contributions to this project. However unless the
change is simple and easily understood, for example fixing a bug or portability
issue, adding a new test, or improving performance, first open an issue to
discuss your intended change as not all changes can be accepted.

Contributions that will not be used directly by one of Signal's official client
apps may still be considered, but only if they do not pose an undue maintenance
burden or conflict with the goals of the project.

Signing a [CLA (Contributor License Agreement)](https://signal.org/cla/) is
required for all contributions.

## License
This project is licensed under the [AGPLv3](LICENSE).
