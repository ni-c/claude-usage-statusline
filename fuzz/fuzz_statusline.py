#!/usr/bin/env python3
"""Fuzz the JSON that Claude Code pipes into statusline.sh.

A status line reads a document nobody sanitised on the way in — a model name, a
working directory, percentages and reset timestamps — and prints one line into a
terminal. Two things can go wrong there and both are invisible in a unit test
that only uses inputs somebody thought of: the script can fail, which takes the
prompt down with it, and it can pass a control character through, which hands a
directory name the terminal's escape syntax.

So the oracle below is not "the output is right", it is the four promises the
script makes for *every* input:

  * it exits 0,
  * it says nothing on stderr,
  * it prints exactly one line, and
  * with NO_COLOR set that line carries no control characters at all.

Two honest notes about what this is. libFuzzer cannot see inside bash, so its
coverage feedback only reaches the generator in this file: it is structure-aware
random testing with a corpus, not coverage-guided fuzzing of the script. And
NO_COLOR stays pinned on, because that is what makes the control-character
promise sharp — with colour every line is full of escapes by design.

Run it without a fuzzing engine while developing:

    python3 fuzz/fuzz_statusline.py --selftest          # fixtures + random inputs
    python3 fuzz/fuzz_statusline.py --selftest -n 5000
"""

import json
import os
import random
import re
import subprocess
import sys
import tempfile

try:
    import atheris
except ImportError:  # --selftest runs without a fuzzing engine
    atheris = None

TIMEOUT_SECONDS = 10

# Everything C0 except the final newline, plus DEL. C1 is unreachable in UTF-8
# output, and the script's jq filter drops it at the source anyway.
_FORBIDDEN = re.compile(rb"[\x00-\x09\x0b-\x1f\x7f]")

# The knobs the README documents. NO_COLOR is not among them on purpose.
_SEGMENT_NAMES = ["model", "dir", "git", "ctx", "5h", "7d"]


class OracleError(AssertionError):
    """A promise the status line makes for every input was broken."""


def _find_statusline():
    """$OUT next to the fuzzer when ClusterFuzzLite runs it, the repo otherwise."""
    here = os.path.dirname(os.path.abspath(__file__))
    beside = os.path.dirname(os.path.abspath(sys.argv[0]))
    for candidate in (
        os.environ.get("STATUSLINE_SH"),
        os.path.join(beside, "statusline.sh"),
        os.path.join(here, os.pardir, "statusline.sh"),
    ):
        if candidate and os.path.isfile(candidate):
            return os.path.abspath(candidate)
    raise SystemExit("statusline.sh not found — set STATUSLINE_SH to its path")


STATUSLINE = _find_statusline()

# build.sh puts a static jq beside the script, because the runner image has none.
_TOOL_DIR = os.path.dirname(STATUSLINE)
# An empty directory to run in: no git repository, no dotfiles, nothing the
# script could read and make the result depend on this machine.
_SANDBOX = tempfile.mkdtemp(prefix="statusline-fuzz-")

_BASE_ENV = {
    "PATH": _TOOL_DIR + os.pathsep + os.environ.get("PATH", "/usr/bin:/bin"),
    "HOME": _SANDBOX,
    "LC_ALL": "C.UTF-8",
    "NO_COLOR": "1",
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_CONFIG_SYSTEM": os.devnull,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_TERMINAL_PROMPT": "0",
}


def check(payload, env_extra=None):
    """Run the status line over one input and hold it to its promises."""
    env = dict(_BASE_ENV)
    if env_extra:
        env.update(env_extra)

    try:
        done = subprocess.run(
            ["bash", STATUSLINE],
            input=payload,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            cwd=_SANDBOX,
            timeout=TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired:
        raise OracleError("did not finish within %d s" % TIMEOUT_SECONDS)

    if done.returncode != 0:
        raise OracleError(
            "exit status %d, stderr %r" % (done.returncode, done.stderr[:400])
        )
    if done.stderr:
        raise OracleError("wrote to stderr: %r" % done.stderr[:400])

    out = done.stdout
    if not out.endswith(b"\n"):
        raise OracleError("output does not end in a newline: %r" % out[:400])
    line = out[:-1]
    if b"\n" in line:
        raise OracleError("output is more than one line: %r" % out[:400])

    found = _FORBIDDEN.search(line)
    if found:
        raise OracleError(
            "control character %#04x in the output: %r"
            % (line[found.start()], line[:400])
        )
    try:
        line.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise OracleError("output is not UTF-8 (%s): %r" % (exc, line[:400]))
    return line


class _Draw:
    """The three draws the generator needs, from atheris or from random."""

    def __init__(self, data=None, rng=None):
        self._fdp = atheris.FuzzedDataProvider(data) if data is not None else None
        self._rng = rng

    def integer(self, low, high):
        if self._fdp is not None:
            return self._fdp.ConsumeIntInRange(low, high)
        return self._rng.randint(low, high)

    def text(self, limit):
        if self._fdp is not None:
            return self._fdp.ConsumeUnicodeNoSurrogates(limit)
        return "".join(
            chr(self._rng.randint(1, 0x2FFF)) for _ in range(self._rng.randint(0, limit))
        )

    def raw(self, limit):
        if self._fdp is not None:
            return self._fdp.ConsumeBytes(limit)
        return bytes(self._rng.randint(0, 255) for _ in range(self._rng.randint(0, limit)))


# Numbers jq parses but bash must never see: the overflows, the denormals and the
# strings that only look numeric. They live as raw JSON text so json.dumps cannot
# round them off on the way in.
_NUMBER_TOKENS = [
    "1e400",
    "-1e400",
    "1e-400",
    "-0",
    "9223372036854775808",
    "-9223372036854775809",
    "99999999999999999999999999",
    "0.5",
    "-1",
    "101",
    '"42"',
    '"  7  "',
    '"1e400"',
    '"not a number"',
    "null",
    "true",
    "[]",
    "{}",
]


def _scalar(draw):
    kind = draw.integer(0, 5)
    if kind == 0:
        return None
    if kind == 1:
        return draw.integer(-(2**40), 2**40)
    if kind == 2:
        return draw.integer(-5, 105)
    if kind == 3:
        return draw.text(48)
    if kind == 4:
        return [draw.text(8), draw.integer(-9, 9)]
    return {"unexpected": draw.text(8)}


def _document(draw):
    """A document shaped like Claude Code's, with every value fuzzed."""
    doc = {
        "model": {"display_name": _scalar(draw), "id": _scalar(draw)},
        "workspace": {"current_dir": _scalar(draw)},
        "cwd": _scalar(draw),
        "context_window": {"used_percentage": _scalar(draw)},
        "rate_limits": {
            "five_hour": {
                "used_percentage": _scalar(draw),
                "resets_at": _scalar(draw),
            },
            "seven_day": {
                "used_percentage": _scalar(draw),
                "resets_at": _scalar(draw),
            },
        },
    }
    text = json.dumps(doc)

    # Splice raw number tokens in, so the arithmetic guards see values that no
    # JSON encoder would produce.
    for _ in range(draw.integer(0, 3)):
        token = _NUMBER_TOKENS[draw.integer(0, len(_NUMBER_TOKENS) - 1)]
        field = ["used_percentage", "resets_at"][draw.integer(0, 1)]
        text = re.sub(
            r'"%s":\s*[^,}]+' % field, '"%s": %s' % (field, token), text, count=1
        )
    return text.encode("utf-8", "surrogatepass")


def _environment(draw):
    """Fuzz the documented knobs. NO_COLOR stays on — see the module docstring."""
    env = {}
    if draw.integer(0, 1):
        env["CLAUDE_STATUSLINE_WARN"] = draw.text(12).replace("\x00", "")
    if draw.integer(0, 1):
        env["CLAUDE_STATUSLINE_NOTICE"] = draw.text(12).replace("\x00", "")
    if draw.integer(0, 1):
        env["CLAUDE_STATUSLINE_NO_EMOJI"] = draw.text(6).replace("\x00", "")
    if draw.integer(0, 3):
        env["CLAUDE_STATUSLINE_NOW"] = str(draw.integer(0, 2**34))
    else:
        env["CLAUDE_STATUSLINE_NOW"] = draw.text(14).replace("\x00", "")
    if draw.integer(0, 1):
        picked = [
            _SEGMENT_NAMES[draw.integer(0, len(_SEGMENT_NAMES) - 1)]
            for _ in range(draw.integer(0, 7))
        ]
        if draw.integer(0, 4) == 0:
            picked.append(draw.text(8).replace("\x00", ""))
        env["CLAUDE_STATUSLINE_SEGMENTS"] = ",".join(picked)
    return env


def _one_case(draw):
    """One (stdin, environment) pair."""
    if draw.integer(0, 3) == 0:
        payload = draw.raw(4096)
    else:
        payload = _document(draw)
    return payload, _environment(draw)


def test_one_input(data):
    payload, env = _one_case(_Draw(data=data))
    check(payload, env)


def _selftest(rounds):
    """Every committed fixture, then random cases, through the same oracle."""
    fixtures = os.path.join(
        os.path.dirname(os.path.abspath(__file__)), os.pardir, "tests", "fixtures"
    )
    names = sorted(n for n in os.listdir(fixtures) if n.endswith(".json"))
    for name in names:
        with open(os.path.join(fixtures, name), "rb") as handle:
            try:
                check(handle.read(), {"CLAUDE_STATUSLINE_NOW": "1800000000"})
            except OracleError as exc:
                print("fixture %s: %s" % (name, exc), file=sys.stderr)
                return 1
    print("%d fixtures pass the oracle" % len(names))

    rng = random.Random(20260916)
    for index in range(rounds):
        payload, env = _one_case(_Draw(rng=rng))
        try:
            check(payload, env)
        except OracleError as exc:
            print("round %d: %s" % (index, exc), file=sys.stderr)
            print("  stdin: %r" % payload[:400], file=sys.stderr)
            print("  env:   %r" % env, file=sys.stderr)
            return 1
    print("%d random cases pass the oracle" % rounds)
    return 0


def main():
    if "--selftest" in sys.argv:
        rounds = 500
        if "-n" in sys.argv:
            rounds = int(sys.argv[sys.argv.index("-n") + 1])
        return _selftest(rounds)
    if atheris is None:
        raise SystemExit("atheris is not installed — use --selftest")
    atheris.Setup(sys.argv, test_one_input)
    atheris.Fuzz()
    return 0


if __name__ == "__main__":
    sys.exit(main())
