# claude-usage-statusline

<!-- badges: start -->

[![CI](https://github.com/ni-c/claude-usage-statusline/actions/workflows/ci.yml/badge.svg)](https://github.com/ni-c/claude-usage-statusline/actions/workflows/ci.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/ni-c/claude-usage-statusline/badge)](https://scorecard.dev/viewer/?uri=github.com/ni-c/claude-usage-statusline)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/14672/badge)](https://www.bestpractices.dev/projects/14672)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

<!-- badges: end -->

A status line for [Claude Code](https://code.claude.com) that shows how much of your
rate limits you have used, and how long until they reset. It also shows the model,
the folder, the git branch and how full the context window is. It runs on Linux,
macOS and Windows.

<p align="center">
  <img src="docs/preview.svg" alt="Three examples of the status line: plenty left, getting busy, close to the limit" width="100%">
</p>

```text
[Opus 5] 📁 my-project ⎇ main | ctx 57% | 1h05 64% | 3d 41%
```

<!-- The dir row writes its sample folder with a no-break space and a
     non-breaking hyphen. Without them a narrow window splits the cell over
     two lines, because a table cannot be told not to wrap: GitHub strips
     style attributes and <nobr> alike. -->

| Segment         | Name    | Meaning                                                                                                                  |
| --------------- | ------- | ------------------------------------------------------------------------------------------------------------------------ |
| `[Opus 5]`      | `model` | The model answering in this session, under the name Claude Code gives it — or its bare model id if it sends no name at all. |
| `📁 my‑project` | `dir`   | The last segment of the directory Claude Code is working in, so that a deep path still costs one short word.               |
| `⎇ main`        | `git`   | The branch checked out in that directory, or the short commit hash on a detached HEAD. Outside a repository: nothing.      |
| `ctx 57%`       | `ctx`   | How full the context window is. Claude Code sends the percentage; the status line only decides what colour it gets.        |
| `1h05 64%`      | `5h`    | The five-hour limit: 64 % of it used, and 1 hour 5 minutes left until it resets.                                           |
| `3d 41%`        | `7d`    | The weekly limit: 41 % of it used, and at most 3 days until it resets — whole days, rounded up, so `1d` means today.       |

The names in the middle column are the ones `CLAUDE_STATUSLINE_SEGMENTS` takes, in
[Configuration](#configuration) below.

Each percentage turns yellow at 50 % and red with a `⚠` at 80 %.

The two rate limits only show up on a Claude Pro or Max subscription, and only after
the first answer of a session. Claude Code does not send them to people who use an API
key. Segments without data are left out, so the line never shows stale or made-up
numbers.

## Install

**Linux, macOS, WSL**

```sh
curl -fsSL https://github.com/ni-c/claude-usage-statusline/releases/latest/download/install.sh | bash
```

Needs [jq](https://jqlang.org/download/), both for the installer and for the status
line itself (`apt install jq`, `brew install jq`, `dnf install jq`, …).

**Windows (PowerShell)**

```powershell
irm https://github.com/ni-c/claude-usage-statusline/releases/latest/download/install.ps1 | iex
```

Needs nothing else: it runs on the Windows PowerShell that comes with every Windows,
and on PowerShell 7.

**Windows (cmd.exe)**

cmd.exe cannot pipe a download into an interpreter, so this one downloads first and then
runs — which also means you can read it before you do:

```bat
curl -fsSL -o "%TEMP%\install.cmd" https://github.com/ni-c/claude-usage-statusline/releases/latest/download/install.cmd && "%TEMP%\install.cmd"
```

This is the PowerShell-free way: it installs `statusline.sh` and points Claude Code at
it through Git Bash, so neither the installer nor the status line ever runs
`powershell.exe`. It needs [Git for Windows](https://git-scm.com/download/win) and
[jq](https://jqlang.org/download/) (`winget install jqlang.jq`) on the `PATH`, jq both
to install and every time the status line runs; `curl.exe` and `certutil` come with
Windows 10 1803 and newer. **If PowerShell works on your machine, `install.ps1` above is
the simpler choice — it needs nothing.**

The installer comes with a release. It downloads the status line script from that same
release and checks it against a SHA-256 checksum written into the installer —
`install.sh` and `install.cmd` install `statusline.sh`, `install.ps1` installs
`statusline.ps1`. The script goes into `~/.claude/claude-usage-statusline/`. The
installer then sets `statusLine` in
`~/.claude/settings.json` and leaves every other setting alone. A copy of your previous
settings is kept as `settings.json.before-claude-usage-statusline`. Claude Code picks up
the change within a few seconds.

To check an installer before running it, download it and verify its build provenance
with the [GitHub CLI](https://cli.github.com):

```sh
gh attestation verify install.sh --repo ni-c/claude-usage-statusline
```

Every release also carries `claude-usage-statusline.intoto.jsonl`: the same signed
statement as a file — one Sigstore bundle naming every asset of the release, so the
same file verifies any of them. Passing it with `--bundle` checks the
download against the file in your hands instead of GitHub's attestation API, so the
check still works when that API is unreachable — or when this repository is not
there any more:

```sh
gh attestation verify install.sh --bundle claude-usage-statusline.intoto.jsonl \
  --repo ni-c/claude-usage-statusline
```

Sigstore's trust root is still fetched over the network. Cache it once with
`gh attestation trusted-root > root.jsonl`, add `--custom-trusted-root root.jsonl`,
and the check needs no network at all.

If another status line is already configured, the installer stops and shows it to you.
To replace it:

```sh
curl -fsSL https://github.com/ni-c/claude-usage-statusline/releases/latest/download/install.sh | bash -s -- --force
```

```powershell
& ([scriptblock]::Create((irm https://github.com/ni-c/claude-usage-statusline/releases/latest/download/install.ps1))) -Force
```

```bat
"%TEMP%\install.cmd" --force
```

The `.cmd` is still where the install step downloaded it; if you cleared `%TEMP%`, fetch
it again with the `curl` line above.

`CLAUDE_CONFIG_DIR` is respected if you keep your Claude Code configuration somewhere else.

### Manual install

Download `statusline.sh` (or `statusline.ps1`) from the
[latest release](https://github.com/ni-c/claude-usage-statusline/releases/latest) and
point `statusLine` at it in `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/claude-usage-statusline/statusline.sh",
    "refreshInterval": 30
  }
}
```

On Windows:

```json
{
  "statusLine": {
    "type": "command",
    "command": "powershell -NoProfile -ExecutionPolicy Bypass -File 'C:/Users/you/.claude/claude-usage-statusline/statusline.ps1'",
    "refreshInterval": 30
  }
}
```

Use forward slashes and single quotes on Windows. Claude Code runs the command through
Git Bash if it is installed and through PowerShell if it is not, and that way the same
line works in both. `refreshInterval` makes the countdown keep moving while Claude Code
is idle.

Or, on Windows without PowerShell — this is what `install.cmd` writes, and it needs Git
Bash, where the line above works either way:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash 'C:/Users/you/.claude/claude-usage-statusline/statusline.sh'",
    "refreshInterval": 30
  }
}
```

## Configuration

Set these in the `env` block of `settings.json`, so they reach the status line on every
platform:

```json
{
  "env": {
    "CLAUDE_STATUSLINE_SEGMENTS": "model,dir,git,5h,7d",
    "CLAUDE_STATUSLINE_WARN": "90"
  }
}
```

| Variable                     | Default                    | Effect                                                                  |
| ---------------------------- | -------------------------- | ----------------------------------------------------------------------- |
| `CLAUDE_STATUSLINE_SEGMENTS` | `model,dir,git,ctx,5h,7d`  | Which segments to show, in this order. Unknown names are ignored.       |
| `CLAUDE_STATUSLINE_WARN`     | `80`                       | From this percentage on: red with `⚠`.                                  |
| `CLAUDE_STATUSLINE_NOTICE`   | `50`                       | From this percentage on: yellow.                                        |
| `CLAUDE_STATUSLINE_NO_EMOJI` | unset                      | `1` replaces `📁`, `⎇` and `⚠` with plain text, for fonts without them. |
| `NO_COLOR`                   | unset                      | Any value turns colours off ([no-color.org](https://no-color.org)).     |

## Uninstall

```sh
curl -fsSL https://github.com/ni-c/claude-usage-statusline/releases/latest/download/install.sh | bash -s -- --uninstall
```

```powershell
& ([scriptblock]::Create((irm https://github.com/ni-c/claude-usage-statusline/releases/latest/download/install.ps1))) -Uninstall
```

```bat
"%TEMP%\install.cmd" --uninstall
```

This removes the `statusLine` entry, but only if it points at this status line, and
deletes `~/.claude/claude-usage-statusline/`. Any of the three does that, whichever one
installed it.

## Troubleshooting

- **The line says `jq is required`.** Install jq, see above. On Windows, `install.ps1`
  needs no jq at all — `install.cmd` needs it both to install and every time the status
  line runs.
- **`install.cmd` says Git for Windows is required.** Install
  [Git for Windows](https://git-scm.com/download/win), or use `install.ps1`, which needs
  nothing. Claude Code runs the bash status line through Git Bash.
- **`install.cmd` says `curl.exe` is required.** Windows 8.1 and older do not ship it.
  Use `install.ps1`.
- **The `install.cmd` window closes before you can read it.** It was double-clicked. Run
  it from an open command prompt.
- **Boxes instead of icons.** Your terminal font has no `📁`, `⎇` or `⚠`. Set
  `CLAUDE_STATUSLINE_NO_EMOJI=1`.
- **No `5h`/`7d` segments.** Rate limits are only reported for Pro and Max
  subscriptions, and only after the first answer of a session.
- **No branch.** Git is not installed, or the folder is not inside a git repository.

## How it works

Claude Code pipes a JSON document into the status line command
([documentation](https://code.claude.com/docs/en/statusline)). This status line reads
`model.display_name`, `workspace.current_dir`, `context_window.used_percentage` and
`rate_limits.five_hour` / `rate_limits.seven_day` from it and prints one line. It reads
no files and writes none, and it sends nothing anywhere. The only thing it runs is
`git`, to read the branch name.

There are two implementations that print exactly the same bytes: `statusline.sh`
(bash 3.2 or newer, with jq) and `statusline.ps1` (Windows PowerShell 5.1 or
PowerShell 7). Both are tested against the same list of cases in
[`tests/cases.tsv`](tests/cases.tsv).

## Development

```sh
bats tests/                                   # statusline.sh, install.sh, install.cmd
pwsh -File tests/Invoke-Tests.ps1             # statusline.ps1 and install.ps1
shellcheck statusline.sh install.sh scripts/*.sh
scripts/render-preview.sh                     # after changing the output format
```

The `install.cmd` cases skip unless there is a `cmd.exe`; the checks on its bytes run
everywhere. CI runs all of this on Linux, on macOS with its own `/bin/bash` 3.2, and on
Windows with both Windows PowerShell 5.1 and PowerShell 7, plus `install.cmd` under
cmd.exe.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The short version: both scripts print the same
bytes, and every behaviour is a line in `tests/cases.tsv`.

## License

[MIT](LICENSE)
