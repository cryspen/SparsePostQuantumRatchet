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


# The hax checkout matching the installed `cargo-hax`: it provides the `hax-lib`
# the extraction compiles against and the shipped ProVerif libraries.
def _hax_home():
    home = os.environ.get("HAX_HOME")
    if not home:
        raise Exception(
            "Set HAX_HOME to the hax checkout matching the installed cargo-hax "
            "(see proofs/proverif/setup-hax.sh)."
        )
    return home


PROVERIF_DIR = "proofs/proverif"
# `extraction/` holds the pure hax output (lib.pvl); `extraction-model/` holds the
# hand-written composition (crypto idealization, process model, queries).
# extract-proverif writes lib.pvl into extraction/ (hax's default output dir);
# verify-proverif loads libraries from both.
PROVERIF_GEN_DIR = os.path.join(PROVERIF_DIR, "extraction")
PROVERIF_MODEL_DIR = os.path.join(PROVERIF_DIR, "extraction-model")
# ProVerif extraction roots: the send/recv-ek/ct state-machine entry points (like
# Aeneas's --keep-from). `+` pulls in their FULL transitive deps — exactly the
# reachable protocol + crypto — and NOT the dead protobuf-serialization tree that a
# whole-module `+~…::**` glob would sweep in (halves lib.pvl, verdicts unchanged).
# `new` is the Rust name (the backend renames it `new_kw`); `*` matches the
# `Impl`/`Impl_N` block. Crypto primitives are abstracted via source-level
# `proverif::replace_body` / `pv_extern` annotations gated on
# `cfg(hax_backend_proverif)`, which hax sets automatically during `into proverif`.
_PROVERIF_ROOTS = [("send_ek", m) for m in
                   ("new", "send_header", "send_ek", "recv_ct1", "recv_ct2")] + \
                  [("send_ct", m) for m in
                   ("new", "recv_header", "send_ct1", "recv_ek", "send_ct2", "recv_next_epoch")]
PROVERIF_INCLUDE = "-** " + " ".join(
    "+spqr::v1::unchunked::{}::*::{}".format(mod, meth) for mod, meth in _PROVERIF_ROOTS
)


def _proverif_libs():
    return os.path.abspath(os.path.join(_hax_home(), "hax-lib", "proof-libs", "proverif"))


class extractProverifAction(argparse.Action):

    def __call__(self, parser, args, values, option_string=None) -> None:
        include_str = args.include if args.include else PROVERIF_INCLUDE
        # Point the git `hax-lib` dependency at the checkout matching
        # `cargo-hax`. The patch goes in a temporary `.cargo/config.toml` rather
        # than `cargo --config`, so that cargo-hax's own dependency resolution
        # sees it too; `Cargo.lock` is restored afterwards.
        lib = os.path.join(_hax_home(), "hax-lib")
        config = os.path.join(".cargo", "config.toml")
        if os.path.exists(config):
            raise Exception("{} exists; refusing to overwrite it".format(config))
        with open("Cargo.lock", "rb") as f:
            lock_backup = f.read()
        os.makedirs(".cargo", exist_ok=True)
        with open(config, "w") as f:
            f.write("[patch.'https://github.com/cryspen/hax.git']\n")
            for crate, path in [
                ("hax-lib", lib),
                ("hax-lib-macros", os.path.join(lib, "macros")),
                ("hax-lib-macros-types", os.path.join(lib, "macros", "types")),
            ]:
                f.write('{} = {{ path = "{}" }}\n'.format(crate, path))
        try:
            locked = re.findall(
                r'name = "hax-lib"\nversion = "([^"]+)"\n'
                r'source = "git\+https://github\.com/cryspen/hax\.git',
                lock_backup.decode(),
            )
            for version in locked:
                shell(["cargo", "update", "-p", "hax-lib@" + version], cwd=".")
            shell(
                ["cargo", "hax", "into", "-i", include_str, "proverif"],
                cwd=".",
            )
        finally:
            os.remove(config)
            if not os.listdir(".cargo"):
                os.rmdir(".cargo")
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

        libs = _extraction_libs()
        for target in targets:
            shell(
                ["proverif"] + libs + [os.path.join("extraction-model", target)],
                cwd=PROVERIF_DIR,
            )
        return None


# Load order: hax's shipped prelude and its default (Ok-only) Result library,
# the symbolic crypto `handwritten_lib.pvl`, the generated `lib.pvl`, then
# `nepochs.pvl` (before `model.pvl`, which uses `max_epoch()`).
def _extraction_libs():
    libs = _proverif_libs()
    return [
        "-lib", os.path.join(libs, "primitives.pvl"),
        "-lib", os.path.join(libs, "result.pvl"),
        "-lib", "extraction-model/handwritten_lib.pvl",
        "-lib", "extraction/lib.pvl",
        "-lib", "extraction-model/nepochs.pvl",
        "-lib", "extraction-model/model.pvl",
    ]


def _handwritten_libs():
    return ["-lib", "handwritten/cryptolib.pvl"]


# ProVerif check targets: name -> (path under proofs/proverif, ProVerif libs).
# The generated model loads the extraction libs (its NEPOCHS bound lives in
# nepochs.pvl); the hand-written models load only cryptolib.pvl and carry their
# own `max_epoch()` inline.
PROVERIF_CHECK_TARGETS = {
    "reach.pv":    ("extraction-model/reach.pv",  _extraction_libs),
    "auth.pv":     ("extraction-model/auth.pv",   _extraction_libs),
    "conf.pv":     ("extraction-model/conf.pv",   _extraction_libs),
    "sanity.pv":   ("extraction-model/sanity.pv", _extraction_libs),
    "spqr-cka.pv": ("handwritten/spqr-cka.pv",    _handwritten_libs),
    "spqr-dr.pv":  ("handwritten/spqr-dr.pv",     _handwritten_libs),
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


_IDENT_RE = re.compile(r"\b([A-Za-z][A-Za-z0-9_]*?)(_[0-9]+)?\b")


def _canonical_result(line):
    """`line` with ProVerif's variable numbering replaced by the order of first
    appearance of each variant of a name, as that numbering shifts with the
    declarations of the loaded libraries (`x_21`, `y` vs `x_22`, `y_1`)."""
    variants = {}

    def rename(m):
        seen = variants.setdefault(m.group(1), {})
        return "{}#{}".format(m.group(1), seen.setdefault(m.group(0), len(seen)))

    return _IDENT_RE.sub(rename, line)


def _same_result(expected, actual):
    return _canonical_result(expected) == _canonical_result(actual)


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
            libs = libs()
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
            ok = sum(1 for i in range(n) if _same_result(expected[i], actual[i]))
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
                    if not _same_result(e, a):
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


class setupAction(argparse.Action):
    """Install hax with the ProVerif backend by delegating to
    proofs/proverif/setup-hax.sh. Optional DEST_DIR."""

    def __call__(self, parser, args, values, option_string=None) -> None:
        script = os.path.join(PROVERIF_DIR, "setup-hax.sh")
        shell(["bash", script] + list(values or []), cwd=".")
        return None


def parse_arguments():
    parser = argparse.ArgumentParser(
        description="SPQR prove script. "
        + "Make sure to separate sub-command arguments with --."
    )
    subparsers = parser.add_subparsers()

    setup_parser = subparsers.add_parser(
        "setup",
        help="Install hax with the ProVerif backend from a checkout in "
        "./.hax-proverif (or DEST_DIR). Delegates to proofs/proverif/setup-hax.sh; "
        "run once before extract-proverif, then set HAX_HOME to that checkout.",
    )
    setup_parser.add_argument("setup", nargs="*", action=setupAction)

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
