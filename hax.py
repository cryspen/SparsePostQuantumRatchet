#! /usr/bin/env python3

import os
import argparse
import re
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


# ProVerif check targets: name -> (path under proofs/proverif, ProVerif libs).
# The generated model loads the extraction libs (its NEPOCHS bound lives in
# nepochs.pvl); the hand-written models load only cryptolib.pvl and carry their
# own `max_epoch()` inline.
_EXTRACTION_LIBS = [
    "-lib", "extraction-model/primitives.pvl",
    "-lib", "extraction-model/handwritten_lib.pvl",
    "-lib", "extraction/lib.pvl",
    "-lib", "extraction-model/nepochs.pvl",
    "-lib", "extraction-model/model.pvl",
]
_HANDWRITTEN_LIBS = ["-lib", "handwritten/cryptolib.pvl"]
PROVERIF_CHECK_TARGETS = {
    "reach.pv":    ("extraction-model/reach.pv",  _EXTRACTION_LIBS),
    "auth.pv":     ("extraction-model/auth.pv",   _EXTRACTION_LIBS),
    "conf.pv":     ("extraction-model/conf.pv",   _EXTRACTION_LIBS),
    "sanity.pv":   ("extraction-model/sanity.pv", _EXTRACTION_LIBS),
    "spqr-cka.pv": ("handwritten/spqr-cka.pv",    _HANDWRITTEN_LIBS),
    "spqr-dr.pv":  ("handwritten/spqr-dr.pv",     _HANDWRITTEN_LIBS),
}
# Native ProVerif expected-results block: `(* EXPECTPV <RESULT lines> END *)`
# (ProVerif manual, section 6.9). The runtime line the manual mentions is
# machine-dependent, so we keep only the RESULT lines and diff those.
_EXPECTPV_RE = re.compile(r"\(\*\s*EXPECTPV\b.*?\bEND\s*\*\)", re.DOTALL)


def _proverif_result_lines(libs, relpath):
    """Run ProVerif on `relpath` (relative to proofs/proverif) with `libs` and
    return its verbatim `RESULT ...` lines."""
    ret = subprocess.run(
        ["proverif"] + libs + [relpath],
        cwd=PROVERIF_DIR, capture_output=True, text=True, encoding="utf-8",
    )
    out = (ret.stdout or "") + (ret.stderr or "")
    return [ln.strip() for ln in out.splitlines() if ln.strip().startswith("RESULT")]


def _expectpv_result_lines(text):
    """The `RESULT ...` lines inside a file's `(* EXPECTPV ... END *)` block, or
    None when the file has no such block."""
    m = _EXPECTPV_RE.search(text)
    if not m:
        return None
    return [ln.strip() for ln in m.group(0).splitlines() if ln.strip().startswith("RESULT")]


def _write_expectpv(path, text, result_lines):
    """Insert or replace the `(* EXPECTPV ... END *)` block in `text`."""
    block = "(* EXPECTPV\n" + "\n".join(result_lines) + "\nEND *)\n"
    if _EXPECTPV_RE.search(text):
        new = _EXPECTPV_RE.sub(lambda _m: block.rstrip("\n"), text, count=1)
    else:
        new = text.rstrip("\n") + "\n\n" + block
    with open(path, "w", encoding="utf-8") as f:
        f.write(new)


class checkProverifAction(argparse.Action):
    """Run ProVerif and diff its `RESULT` lines against the native
    `(* EXPECTPV ... END *)` expected-results block embedded in each query file
    (ProVerif manual, section 6.9), so the artifact asserts *what was proved*
    rather than eyeballing output. Pass `update` to (re)generate those blocks
    from the current ProVerif output instead of checking. Exits non-zero on any
    mismatch. The generated-model bound is set via `epochs=N` (default 4, written
    to nepochs.pvl); the hand-written models carry `max_epoch()` inline."""

    def __call__(self, parser, args, values, option_string=None) -> None:
        update = False
        epochs = None
        targets = []
        for v in values or []:
            if v == "update":
                update = True
            elif v.startswith("epochs=") or v.startswith("nepochs="):
                epochs = int(v.split("=", 1)[1])
            else:
                targets.append(v)
        if not targets:
            targets = list(PROVERIF_CHECK_TARGETS.keys())
        if epochs is None:
            epochs = 4

        nepochs = os.path.join(PROVERIF_MODEL_DIR, "nepochs.pvl")
        with open(nepochs, "w") as f:
            f.write(
                "(* NEPOCHS bound; (re)generated by `hax.py check-proverif`. *)\n"
                "letfun max_epoch() = {}.\n".format(epochs)
            )

        print(
            "{} ProVerif EXPECTPV blocks (generated-model NEPOCHS={}):\n".format(
                "Updating" if update else "Checking", epochs
            )
        )
        grand_ok = 0
        grand_total = 0
        failed = False
        for target in targets:
            if target not in PROVERIF_CHECK_TARGETS:
                raise Exception("unknown proverif target: {}".format(target))
            relpath, libs = PROVERIF_CHECK_TARGETS[target]
            path = os.path.join(PROVERIF_DIR, relpath)
            actual = _proverif_result_lines(libs, relpath)
            with open(path, encoding="utf-8") as f:
                text = f.read()

            if update:
                _write_expectpv(path, text, actual)
                print("  {:<12}  wrote {} RESULT line(s)".format(target, len(actual)))
                continue

            expected = _expectpv_result_lines(text)
            if expected is None:
                print("  {:<12}  no EXPECTPV block — skipped".format(target))
                continue
            n = min(len(expected), len(actual))
            ok = sum(1 for i in range(n) if expected[i] == actual[i])
            grand_ok += ok
            grand_total += len(expected)
            file_ok = len(expected) == len(actual) and ok == len(expected)
            failed = failed or not file_ok
            print(
                "  {:<12}  {}/{} match   [{}]".format(
                    target, ok, len(expected), "OK" if file_ok else "FAIL"
                )
            )
            if not file_ok:
                if len(expected) != len(actual):
                    print(
                        "      count mismatch: EXPECTPV has {}, ProVerif "
                        "produced {}".format(len(expected), len(actual))
                    )
                for i in range(max(len(expected), len(actual))):
                    e = expected[i] if i < len(expected) else "(none)"
                    a = actual[i] if i < len(actual) else "(none)"
                    if e != a:
                        print("      #{} EXPECTPV: {}".format(i + 1, e))
                        print("              got: {}".format(a))

        if update:
            print("\nEXPECTPV blocks updated. Re-run `check-proverif` to verify.")
            return None
        print("\n{}/{} RESULT lines match EXPECTPV.".format(grand_ok, grand_total))
        if failed:
            print("CHECK FAILED — see mismatches above.")
            sys.exit(1)
        print("CHECK PASSED — all ProVerif RESULT lines match the EXPECTPV blocks.")
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

    check_pv_parser = subparsers.add_parser(
        "check-proverif",
        help="Run ProVerif and diff its RESULT lines against the native "
        "`(* EXPECTPV ... END *)` expected-results block in each query file "
        "(ProVerif manual sec. 6.9); print PASS/FAIL and exit non-zero on "
        "mismatch. Covers the generated model (reach/auth/conf/sanity.pv) and "
        "the hand-written models (spqr-cka.pv, spqr-dr.pv). Pass `update` to "
        "(re)generate the EXPECTPV blocks, `epochs=N` (default 4) to set the "
        "generated-model bound, and/or specific target names.",
    )
    check_pv_parser.add_argument(
        "check-proverif", nargs="*", action=checkProverifAction
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
