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


PROVERIF_DIR = "proofs/proverif"


def _handwritten_libs():
    return ["-lib", "cryptolib.pvl"]


# ProVerif check targets: name -> (path under proofs/proverif, ProVerif libs).
PROVERIF_CHECK_TARGETS = {
    "spqr-cka.pv": ("spqr-cka.pv", _handwritten_libs),
    "spqr-dr.pv":  ("spqr-dr.pv",  _handwritten_libs),
}
# Native ProVerif expected-results block: `(* EXPECTPV <RESULT lines> END *)`
# (ProVerif manual, section 6.9). The runtime line the manual mentions is
# machine-dependent, so only the RESULT lines are compared.
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
    """Run ProVerif and compare its `RESULT` lines with the
    `(* EXPECTPV ... END *)` block of each target; exit non-zero on any
    mismatch. With `update`, (re)write the blocks from ProVerif's output
    instead."""

    def __call__(self, parser, args, values, option_string=None) -> None:
        update = False
        targets = []
        for v in values or []:
            if v == "update":
                update = True
            else:
                targets.append(v)
        if not targets:
            targets = list(PROVERIF_CHECK_TARGETS.keys())

        failed = False
        grand_ok = 0
        grand_total = 0
        for target in targets:
            if target not in PROVERIF_CHECK_TARGETS:
                raise Exception("unknown proverif target: {}".format(target))
            relpath, libs = PROVERIF_CHECK_TARGETS[target]
            path = os.path.join(PROVERIF_DIR, relpath)
            actual = _proverif_result_lines(libs(), relpath)
            with open(path, encoding="utf-8") as f:
                text = f.read()

            if update:
                _write_expectpv(path, text, actual)
                print("  {:<18}  wrote {} RESULT line(s)".format(target, len(actual)))
                continue

            expected = _expectpv_result_lines(text)
            if expected is None:
                print("  {:<18}  no EXPECTPV block".format(target))
                failed = True
                continue
            n = min(len(expected), len(actual))
            ok = sum(1 for i in range(n) if _same_result(expected[i], actual[i]))
            grand_ok += ok
            grand_total += len(expected)
            file_ok = len(expected) == len(actual) and ok == len(expected)
            failed = failed or not file_ok
            print(
                "  {:<18}  {}/{} match   [{}]".format(
                    target, ok, len(expected), "OK" if file_ok else "FAIL"
                )
            )
            if not file_ok:
                for i in range(max(len(expected), len(actual))):
                    e = expected[i] if i < len(expected) else "(none)"
                    a = actual[i] if i < len(actual) else "(none)"
                    if not _same_result(e, a):
                        print("      #{} EXPECTPV: {}".format(i + 1, e))
                        print("              got: {}".format(a))

        if update:
            return None
        print("\n{}/{} RESULT lines match EXPECTPV.".format(grand_ok, grand_total))
        if failed:
            print("CHECK FAILED")
            sys.exit(1)
        print("CHECK PASSED")
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

    check_pv_parser = subparsers.add_parser(
        "check-proverif",
        help="Run ProVerif on the models and compare each RESULT line with the "
        "file's `(* EXPECTPV ... END *)` block; exit non-zero on a mismatch. "
        "Pass target names (default: all) and/or `update` to rewrite the blocks.",
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
