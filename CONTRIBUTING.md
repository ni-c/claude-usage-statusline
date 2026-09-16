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

## Running the tests

```sh
bats tests/                                   # statusline.sh and install.sh
pwsh -File tests/Invoke-Tests.ps1             # statusline.ps1 and install.ps1
shellcheck statusline.sh install.sh scripts/*.sh .clusterfuzzlite/build.sh
scripts/render-preview.sh                     # after changing the output format
python3 fuzz/fuzz_statusline.py --selftest    # random documents, no fuzzer needed
```

To check bash 3.2 without a Mac:

```sh
docker run --rm -v "$PWD:/w" -w /w bash:3.2 sh -c \
  'apk add -q jq git bats && STATUSLINE_BASH=/usr/local/bin/bash bats tests/'
```

CI runs all of it on Linux, on macOS with `/bin/bash` 3.2, on Windows under both
Windows PowerShell 5.1 and PowerShell 7, and `statusline.sh` under Git Bash.

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
- **No new runtime dependencies.** `statusline.sh` needs bash and jq, `statusline.ps1`
  needs nothing, and that is the point.

## Questions and bugs

- Reproducible problems and ideas → [Issues](https://github.com/ni-c/claude-usage-statusline/issues)
- Vulnerabilities → [private reporting](https://github.com/ni-c/claude-usage-statusline/security/advisories/new),
  never a public issue — see [SECURITY.md](SECURITY.md)
