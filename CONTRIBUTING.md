# Contributing

Thanks for taking the time. Small, focused changes with tests land fastest.

## The one rule

There are two implementations, `statusline.sh` and `statusline.ps1`, and they print
**the same bytes** for the same input. Every behaviour lives as a case in
[`tests/cases.tsv`](tests/cases.tsv), and both test suites run every case. A change to
what the status line prints is a new or changed line in that file plus the same change
in both scripts. A change to only one of them fails CI on the other.

`statusline.sh` has to keep running on bash 3.2 (macOS's `/bin/bash`): no
associative arrays, no `${var,,}`, no `mapfile`. `statusline.ps1`, `install.ps1` and
the PowerShell tests have to stay plain ASCII, because Windows PowerShell 5.1 reads a
script without a byte order mark in the ANSI code page.

Two status lines, but three installers: `install.sh`, `install.ps1` and `install.cmd`.
`install.cmd` installs `statusline.sh` and points Claude Code at it through Git Bash, so
that a machine without PowerShell has a way in. It has three rules of its own.
It is plain ASCII, because cmd.exe reads a batch file in the OEM code page. It is CRLF,
enforced in `.gitattributes` for the checkout and asserted byte for byte in
`tests/install.bats`, because cmd.exe is unreliable on LF-only line endings. And exactly
one line may begin with `set "VERSION="` and one with `set "SHA256="` — those two are
substituted at release time by `scripts/stamp-release.sh`, with an unanchored pattern
that a `$` or a `[[:space:]]*$` would either miss or quietly corrupt.

It also never lets text from outside into a cmd variable: an `&` or a `|` in a directory
name or in `settings.json` is syntax there, not data. jq reads and writes
`settings.json` file to file, jq renders every message that contains a path, and the
batch file branches only on exit codes and on words it chose itself. Keep it that way.

## Running the tests

```sh
bats tests/                                   # statusline.sh, install.sh, install.cmd
pwsh -File tests/Invoke-Tests.ps1             # statusline.ps1 and install.ps1
shellcheck statusline.sh install.sh scripts/*.sh .clusterfuzzlite/build.sh
scripts/render-preview.sh                     # after changing the output format
python3 fuzz/fuzz_statusline.py --selftest    # random documents, no fuzzer needed
```

The `install.cmd` cases in `tests/install-cmd.bats` skip unless there is a `cmd.exe`, so
they really run only on Windows, in CI's `git-bash` job. Nothing lints batch: shellcheck
covers bash and PSScriptAnalyzer covers PowerShell, and there is no equivalent worth
pinning for `install.cmd`. What stands in for it are the byte-level checks in
`tests/install.bats` — CRLF, plain ASCII, no tabs, a final newline, `@echo off` first,
and exactly one of each stamped placeholder. That last one turns a release-time failure
into a pull-request failure.

To check bash 3.2 without a Mac:

```sh
docker run --rm -v "$PWD:/w" -w /w bash:3.2 sh -c \
  'apk add -q jq git bats && STATUSLINE_BASH=/usr/local/bin/bash bats tests/'
```

CI runs all of it on Linux, on macOS with `/bin/bash` 3.2, on Windows under both
Windows PowerShell 5.1 and PowerShell 7, and `statusline.sh` under Git Bash with
`install.cmd` under cmd.exe next to it.

## The fuzzer

[`fuzz/fuzz_statusline.py`](fuzz/fuzz_statusline.py) throws random and
nearly-valid documents at `statusline.sh` and holds it to four promises that no
input may break: exit 0, nothing on stderr, exactly one line, and no control
characters while `NO_COLOR` is set. ClusterFuzzLite runs it on every pull request
and for half an hour every Monday; `--selftest` is the same oracle without a
fuzzing engine, and it is the quick way to check a change to the output.

It has already earned its place once: it found `statusline.sh` letting bash print
a warning about a NUL byte, straight into the prompt.

## Expectations

- **Tests.** Behaviour changes come with a case or test that fails without the change.
  Think of the edges: missing fields, empty input, 0 and 100 %, a reset in the past,
  Windows paths.
- **Comments** explain constraints the code cannot show, not what the next line does.
- **No new runtime dependencies.** The rule is about the status line: `statusline.sh`
  needs bash and jq, `statusline.ps1` needs nothing, and that is the point. The
  installers get the same treatment — `install.sh` needs jq, `install.ps1` needs
  nothing, `install.cmd` needs `curl.exe`, `certutil`, jq and Git Bash. A fifth one
  there would want a good reason.

## Questions and bugs

- Reproducible problems and ideas → [Issues](https://github.com/ni-c/claude-usage-statusline/issues)
- Vulnerabilities → [private reporting](https://github.com/ni-c/claude-usage-statusline/security/advisories/new),
  never a public issue — see [SECURITY.md](SECURITY.md)
