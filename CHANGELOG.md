# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

<!-- The release workflow extracts the section of the version being tagged with awk,
     matching "## [x.y.z]". Keep that heading shape exactly. -->

## [Unreleased]

## [1.1.0] - 2026-09-17

### Added

- `install.cmd`, a third installer: native cmd.exe, no PowerShell anywhere. It downloads
  `statusline.sh` from its own release, checks it against the SHA-256 written into it
  with `certutil`, and points `statusLine` at `bash '<path>/statusline.sh'` — so the
  status line runs through Git Bash and `powershell.exe` is never involved. For machines
  where PowerShell is locked down, and for anyone who lives in the command prompt. Needs
  `curl.exe` and `certutil` (Windows 10 1803 and newer), jq on the `PATH`, and Git for
  Windows. `SHA256SUMS` now covers five files.

## [1.0.1] - 2026-09-16

### Added

- An OpenSSF Scorecard run, weekly and on every push to `main`, reporting into the
  Security tab next to CodeQL. The badge is the second in the row.
- ClusterFuzzLite over the JSON Claude Code pipes in: on every pull request, and for
  half an hour every Monday. `python3 fuzz/fuzz_statusline.py --selftest` runs the
  same checks without a fuzzing engine.
- `claude-usage-statusline.intoto.jsonl` as a release asset: the signed build
  provenance statement naming every other asset, so `gh attestation verify --bundle`
  can check a download without GitHub's attestation API — and with a cached trust
  root, without any network at all. Also attached to the 1.0.0 release.

### Fixed

- A NUL byte anywhere in the input made bash print `warning: command substitution:
  ignored null byte in input` into the prompt. Both implementations now drop NUL
  bytes silently, and still print the same bytes as each other. Found by the fuzzer.

### Changed

- The picture in the README spans its full width, and the segment table names the
  key each segment answers to in `CLAUDE_STATUSLINE_SEGMENTS`.

## [1.0.0] - 2026-09-15

### Added

- A status line for Claude Code showing the model, the folder, the git branch, how
  full the context window is, and the 5-hour and weekly rate limits with a countdown
  to their reset.
- Colours by usage (yellow from 50 %, red with `⚠` from 80 %), configurable with
  `CLAUDE_STATUSLINE_NOTICE` and `CLAUDE_STATUSLINE_WARN`, and switched off by
  `NO_COLOR`.
- `CLAUDE_STATUSLINE_SEGMENTS` to choose and order the segments, and
  `CLAUDE_STATUSLINE_NO_EMOJI` for fonts without `📁`, `⎇` and `⚠`.
- Two implementations with identical output: `statusline.sh` for Linux, macOS and WSL
  (bash 3.2 or newer, jq), and `statusline.ps1` for Windows PowerShell 5.1 and
  PowerShell 7 with nothing to install.
- One-line installers, `install.sh` and `install.ps1`. Each installs the script of
  its own release, checked against a SHA-256 written into the installer. It sets
  `statusLine` in `settings.json`, keeps every other setting and a copy of the
  previous file, refuses to replace another status line without `--force` / `-Force`,
  and removes itself with `--uninstall` / `-Uninstall`.
- A build provenance attestation for every release asset, checkable with
  `gh attestation verify <file> --repo ni-c/claude-usage-statusline`.

[Unreleased]: https://github.com/ni-c/claude-usage-statusline/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/ni-c/claude-usage-statusline/releases/tag/v1.1.0
[1.0.1]: https://github.com/ni-c/claude-usage-statusline/releases/tag/v1.0.1
[1.0.0]: https://github.com/ni-c/claude-usage-statusline/releases/tag/v1.0.0
