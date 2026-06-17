#! /usr/bin/env python3

import os
import argparse
import subprocess
import sys


def shell(command, expect=0, cwd=None, env={}):
    subprocess_stdout = subprocess.DEVNULL

    print("Env:", env)
    print("Command: ", end="")
    for i, word in enumerate(command):
        if i == 4:
            print("'{}' ".format(word), end="")
        else:
            print("{} ".format(word), end="")

    print("\nDirectory: {}".format(cwd))

    os_env = os.environ
    os_env.update(env)

    ret = subprocess.run(command, cwd=cwd, env=os_env)
    if ret.returncode != expect:
        raise Exception("Error {}. Expected {}.".format(ret, expect))


class extractAction(argparse.Action):

    def __call__(self, parser, args, values, option_string=None) -> None:
        # Extract spqr
        include_str = "-**::proto::** +:**::proto::**" 
        if args.include:
            include_str = "-** +:**::proto::** " + args.include
        if args.encoding:
            include_str = "-** +:**::proto::** +**::encoding::**"
        interface_include = "+**::proto::**"
        cargo_hax_into = [
            "cargo",
            "hax",
            "into",
            "-i",
            include_str,
            "fstar",
            "--interfaces",
            interface_include,
        ]
        hax_env = {}
        shell(
            cargo_hax_into,
            cwd=".",
            env=hax_env,
        )
        return None


class proveAction(argparse.Action):

    def __call__(self, parser, args, values, option_string=None) -> None:
        admit_env = {}
        if args.admit:
            admit_env = {"OTHERFLAGS": "--admit_smt_queries true"}
        shell(["make", "-C", "proofs/fstar/extraction/"], env=admit_env)
        return None


# Location of the hax checkout that provides the ProVerif (uniform-bitstring)
# backend and the `pv_*` / `proverif::*` macros. `proofs/proverif/setup-hax.sh`
# clones and builds it at the pinned commit; override the location with
# HAX_PROVERIF_DIR. The dev `hax-lib` is injected at extraction time via
# `cargo --config` (see below) — NOT a committed `[patch.crates-io]` — so normal
# builds and CI are unaffected.
HAX_PROVERIF_DIR = os.environ.get(
    "HAX_PROVERIF_DIR", os.path.expanduser("~/hax-proverif-backend")
)
PROVERIF_DIR = "proofs/proverif"
# `extraction/` holds the pure hax output (lib.pvl); `extraction-model/` holds the
# hand-written composition (crypto idealization, process model, queries).
# extract-proverif writes lib.pvl into extraction/ (hax's default output dir);
# verify-proverif loads libraries from both.
PROVERIF_GEN_DIR = os.path.join(PROVERIF_DIR, "extraction")
PROVERIF_MODEL_DIR = os.path.join(PROVERIF_DIR, "extraction-model")
# Namespaces compiled to ProVerif: the unchunked v1 protocol state machine and
# its dependencies. Crypto primitives within are abstracted via source-level
# `proverif::replace_body` / `pv_extern` annotations gated on
# `cfg(hax_backend_proverif)`, which hax sets automatically during `into proverif`.
PROVERIF_INCLUDE = "-** +~spqr::v1::unchunked::**"


def _proverif_env():
    # Accept either a release or a debug build of the hax backend.
    for profile in ("release", "debug"):
        bin_dir = os.path.join(HAX_PROVERIF_DIR, "target", profile)
        cargo_hax = os.path.join(bin_dir, "cargo-hax")
        engine = os.path.join(bin_dir, "hax-rust-engine")
        if os.path.exists(cargo_hax) and os.path.exists(engine):
            return cargo_hax, {
                "HAX_RUST_ENGINE_BINARY": engine,
                "PATH": bin_dir + os.pathsep + os.environ["PATH"],
            }
    raise Exception(
        "hax ProVerif backend not found under {}/target/{{release,debug}}. "
        "Run proofs/proverif/setup-hax.sh (or set HAX_PROVERIF_DIR).".format(
            HAX_PROVERIF_DIR
        )
    )


class extractProverifAction(argparse.Action):

    def __call__(self, parser, args, values, option_string=None) -> None:
        cargo_hax, env = _proverif_env()
        include_str = args.include if args.include else PROVERIF_INCLUDE
        # Redirect hax-lib to the dev checkout (for the pv_* / proverif::replace
        # macros) via `cargo --config` instead of a committed [patch.crates-io],
        # so normal builds and CI stay portable. The checkout is version 0.3.6,
        # matching the crates.io dependency.
        lib = os.path.join(HAX_PROVERIF_DIR, "hax-lib")
        patch_flags = []
        for crate, path in [
            ("hax-lib", lib),
            ("hax-lib-macros", os.path.join(lib, "macros")),
            ("hax-lib-macros-types", os.path.join(lib, "macros", "types")),
        ]:
            patch_flags += [
                "--config",
                'patch.crates-io."{}".path="{}"'.format(crate, path),
            ]
        # The `--config` patch makes cargo rewrite hax-lib's entry in
        # Cargo.lock to a path dependency. Preserve the committed (crates.io)
        # lockfile so this dev-only step doesn't dirty the tree / break CI.
        lock_backup = None
        if os.path.exists("Cargo.lock"):
            with open("Cargo.lock", "rb") as f:
                lock_backup = f.read()
        # No `--features` needed: the annotations are gated on
        # `cfg(hax_backend_proverif)`, which hax sets itself for the proverif
        # backend.
        try:
            shell(
                [cargo_hax, "hax", "-C"]
                + patch_flags
                + [";", "into", "-i", include_str, "proverif"],
                cwd=".",
                env=env,
            )
        finally:
            if lock_backup is not None:
                with open("Cargo.lock", "wb") as f:
                    f.write(lock_backup)
        return None


class verifyProverifAction(argparse.Action):

    def __call__(self, parser, args, values, option_string=None) -> None:
        # Args are a free-form list: an optional `epochs=N` (NEPOCHS bound) and
        # any number of query files. Defaults: all three query files.
        epochs = None
        targets = []
        for v in values or []:
            if v.startswith("epochs=") or v.startswith("nepochs="):
                epochs = int(v.split("=", 1)[1])
            else:
                targets.append(v)
        if not targets:
            targets = ["reach.pv", "conf.pv", "auth.pv"]

        # Regenerate the NEPOCHS bound (nepochs.pvl) when epochs=N is given.
        if epochs is not None:
            if epochs < 1:
                raise Exception("epochs must be >= 1")
            nepochs = os.path.join(PROVERIF_MODEL_DIR, "nepochs.pvl")
            with open(nepochs, "w") as f:
                f.write(
                    "(* NEPOCHS bound; (re)generated by "
                    "`hax.py verify-proverif epochs=N`. *)\n"
                    "letfun max_epoch() = {}.\n".format(epochs)
                )
            print("Set NEPOCHS = {} (nepochs.pvl)".format(epochs))

        # Load order (run from proofs/proverif/): the hand-written composition in
        # extraction-model/ — `primitives.pvl` (vendored hax prelude with the
        # machine-int/nat-arithmetic fixes), `handwritten_lib.pvl` (symbolic
        # crypto) — then the GENERATED `extraction/lib.pvl`, then `nepochs.pvl`
        # (before model.pvl, which uses max_epoch()) and the `model.pvl` process
        # model. Each property is a separate query file in extraction-model/.
        libs = [
            "-lib", "extraction-model/primitives.pvl",
            "-lib", "extraction-model/handwritten_lib.pvl",
            "-lib", "extraction/lib.pvl",
            "-lib", "extraction-model/nepochs.pvl",
            "-lib", "extraction-model/model.pvl",
        ]
        for target in targets:
            shell(
                ["proverif"] + libs + [os.path.join("extraction-model", target)],
                cwd=PROVERIF_DIR,
            )
        return None


def parse_arguments():
    parser = argparse.ArgumentParser(
        description="SPQR prove script. "
        + "Make sure to separate sub-command arguments with --."
    )
    subparsers = parser.add_subparsers()

    extract_parser = subparsers.add_parser(
        "extract", help="Extract the F* code for the proofs."
    )
    extract_parser.add_argument(
        "--include",
        required=False,
        help="Include flag to pass to hax.",
    )
    extract_parser.add_argument(
        "--encoding",
        help="Extract only encoding module.",
        action="store_true",
    )
    extract_parser.add_argument("extract", nargs="*", action=extractAction)

    prover_parser = subparsers.add_parser(
        "prove",
        help="""
        Run F*.

        This typechecks the extracted code.
        To lax-typecheck use --admit.
        """,
    )
    prover_parser.add_argument(
        "--admit",
        help="Admit all smt queries to lax typecheck.",
        action="store_true",
    )
    prover_parser.add_argument(
        "prove",
        nargs="*",
        action=proveAction,
    )

    extract_pv_parser = subparsers.add_parser(
        "extract-proverif",
        help="Compile the unchunked v1 protocol to ProVerif (proofs/proverif/extraction/lib.pvl).",
    )
    extract_pv_parser.add_argument(
        "--include",
        required=False,
        help="Override the hax include namespaces for ProVerif extraction.",
    )
    extract_pv_parser.add_argument(
        "extract-proverif", nargs="*", action=extractProverifAction
    )

    verify_pv_parser = subparsers.add_parser(
        "verify-proverif",
        help="Run ProVerif on the extracted + handwritten model. "
        "Optionally set the epoch bound with epochs=N and/or pass specific "
        "query files, e.g. `verify-proverif epochs=3 conf.pv`.",
    )
    verify_pv_parser.add_argument(
        "verify-proverif", nargs="*", action=verifyProverifAction
    )

    if len(sys.argv) == 1:
        parser.print_help(sys.stderr)
        sys.exit(1)

    return parser.parse_args()


def main():
    # Don't print unnecessary Python stack traces.
    sys.tracebacklimit = 0
    parse_arguments()


if __name__ == "__main__":
    main()
