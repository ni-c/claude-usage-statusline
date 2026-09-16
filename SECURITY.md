# Security policy

## Reporting a vulnerability

Please use [GitHub private vulnerability reporting](https://github.com/ni-c/claude-usage-statusline/security/advisories/new).
Do not open a public issue for an unpatched vulnerability.

You can expect an initial response within a week. Fixed vulnerabilities are published
as a new release with a note in the CHANGELOG.

## Supported versions

Only the latest release and the current `main` branch receive security fixes.

## What the status line does

It reads the JSON Claude Code writes to its standard input and prints one line. It
reads no files, writes none, opens no network connection and keeps no state between
runs.

Text from that JSON reaches your terminal, and part of it is not under your control:
a directory name can contain anything a file system allows, including an escape
character. Both implementations drop every C0 and C1 control character from the model
name, the directory name and the branch name before printing them, so none of these can
become a terminal escape sequence.

The one program it starts is `git`, in the directory Claude Code reports, to read the
current branch: `git symbolic-ref --short -q HEAD`, and `git rev-parse --short HEAD`
on a detached HEAD. Neither reads the index or the working tree, so neither runs
`core.fsmonitor`, hooks or filters from the repository's configuration.
`GIT_OPTIONAL_LOCKS=0` keeps it from taking a lock away from a git you are running.

## What the installers do

`curl … | bash` and `irm … | iex` run code from the internet. Read `install.sh` or
`install.ps1` from the release first if you would rather not.

- The installers are release assets, and each has its version and the SHA-256 of the
  script it installs written into it at build time. It downloads that script from its
  own release over HTTPS and refuses to install it if the checksum does not match.
  `SHA256SUMS` in every release covers all four files.
- Every release asset carries a build provenance attestation: a Sigstore-signed
  statement that the file was built by this repository's release workflow from that
  tag. Check one before running it:
  `gh attestation verify install.sh --repo ni-c/claude-usage-statusline`.
  Those statements ship with the release as well, as
  `claude-usage-statusline.intoto.jsonl` — a single Sigstore bundle wrapping one
  in-toto statement that names every asset of the release, so the same file verifies
  any of them. Pass it with `--bundle` and the check reads that statement from a file you
  hold instead of GitHub's attestation API, so it survives that API being unreachable
  and the repository being gone. Sigstore's trust root is still fetched; cache it with
  `gh attestation trusted-root` and pass `--custom-trusted-root` to verify with no
  network at all.
- They change exactly one key in `settings.json`, `statusLine`, and keep a copy of the
  previous file as `settings.json.before-claude-usage-statusline`. They refuse a file
  that is not a JSON object instead of guessing, and they do not replace a status line
  that belongs to something else unless you pass `--force` / `-Force`.
- On Windows, the command they write runs `powershell -ExecutionPolicy Bypass` for this
  one script. The execution policy is a guard against running scripts by accident, not
  a security boundary. The installed file is the one whose checksum was just verified.
