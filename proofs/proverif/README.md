# ProVerif models for SPQR

This folder contains ProVerif models of the SPQR protocol.

- `spqr-cka.pv` models the continuous key agreement (the public ratchet,
  implemented in [`src/v1`](../../src/v1)): reachability, confidentiality
  (forward secrecy and post-compromise security) and mutual authentication,
  under a fixed compromise, for 6 epochs.
- `spqr-dr.pv` models the symmetric ratchet (implemented in
  [`src/chain.rs`](../../src/chain.rs)).
- `cryptolib.pvl` is the shared symbolic crypto.

Each model ends with a `(* EXPECTPV ... END *)` block listing the expected
ProVerif results. From the repository root, `python3 hax.py check-proverif`
runs ProVerif on both models and fails on any difference;
`python3 hax.py check-proverif update` rewrites the blocks.
