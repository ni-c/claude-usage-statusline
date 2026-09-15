# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

<!-- The release workflow extracts the section of the version being tagged with awk,
     matching "## [x.y.z]". Keep that heading shape exactly. -->

## [Unreleased]

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

[Unreleased]: https://github.com/ni-c/claude-usage-statusline/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/ni-c/claude-usage-statusline/releases/tag/v1.0.0
