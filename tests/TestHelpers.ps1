# Shared by the Pester suites. Dot-source it.

# The PowerShell that runs the scripts under test: STATUSLINE_PWSH, or the one
# running the tests. CI runs the suites under both powershell.exe 5.1 and pwsh 7.
function Get-TestShell {
  if ($env:STATUSLINE_PWSH) { return $env:STATUSLINE_PWSH }
  return (Get-Process -Id $PID).Path
}

# Runs a script in a fresh PowerShell with exact bytes on stdin and an exact
# environment, and returns what came back as UTF-8. Piping a string into a native
# command would re-encode it through $OutputEncoding, which is ASCII on 5.1.
function Invoke-Script {
  param(
    [string]$Script,
    [string[]]$Arguments = @(),
    [byte[]]$InputBytes = @(),
    [hashtable]$Environment = @{},
    [string[]]$Unset = @()
  )
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = Get-TestShell
  $quoted = @($Arguments | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' })
  $psi.Arguments = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" {1}' -f $Script, ($quoted -join ' ')).Trim()
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  $psi.StandardOutputEncoding = $utf8
  $psi.StandardErrorEncoding = $utf8
  foreach ($name in $Unset) { $psi.EnvironmentVariables.Remove($name) }
  foreach ($name in $Environment.Keys) {
    $psi.EnvironmentVariables.Remove($name)
    if ($Environment[$name] -ne '') { $psi.EnvironmentVariables[$name] = [string]$Environment[$name] }
  }
  $process = [System.Diagnostics.Process]::Start($psi)
  $stdoutTask = $process.StandardOutput.ReadToEndAsync()
  $stderrTask = $process.StandardError.ReadToEndAsync()
  if ($InputBytes.Length -gt 0) { $process.StandardInput.BaseStream.Write($InputBytes, 0, $InputBytes.Length) }
  $process.StandardInput.Close()
  $process.WaitForExit()
  return [pscustomobject]@{
    Out  = $stdoutTask.Result
    Err  = $stderrTask.Result
    Code = $process.ExitCode
  }
}

# The same commit everywhere, fixed author, committer and dates, so the detached
# HEAD has the SHA cases.tsv spells out.
function New-TestRepo([string]$Path) {
  & git init -q $Path
  $env:GIT_AUTHOR_DATE = '2026-01-01T00:00:00Z'
  $env:GIT_COMMITTER_DATE = '2026-01-01T00:00:00Z'
  & git -C $Path -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false commit -q --allow-empty -m init
  Remove-Item Env:GIT_AUTHOR_DATE, Env:GIT_COMMITTER_DATE
}

# A temporary directory with forward slashes, which JSON, git and both shells
# all read the same way on every OS.
function New-TestDirectory {
  $path = Join-Path ([IO.Path]::GetTempPath()) ('cus-' + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $path | Out-Null
  return ((Resolve-Path $path).ProviderPath -replace '\\', '/')
}

function Initialize-GitFixtures([string]$Work) {
  # Keep the developer's git configuration out, and stop discovery at $Work.
  $env:GIT_CONFIG_NOSYSTEM = '1'
  $env:GIT_CONFIG_GLOBAL = if ($IsWindows -or $env:OS -eq 'Windows_NT') { 'NUL' } else { '/dev/null' }
  $env:GIT_CEILING_DIRECTORIES = $Work
  New-TestRepo "$Work/proj"
  & git -C "$Work/proj" checkout -q -b feature/x
  New-Item -ItemType Directory -Path "$Work/proj/sub" | Out-Null
  New-TestRepo "$Work/detached"
  & git -C "$Work/detached" checkout -q --detach 2>$null
  New-Item -ItemType Directory -Path "$Work/plain" | Out-Null
}

function Get-FixtureBytes([string]$Root, [string]$Name, [string]$Work) {
  $path = Join-Path $Root "tests/fixtures/$Name.json"
  $bytes = [IO.File]::ReadAllBytes($path)
  $text = (New-Object System.Text.UTF8Encoding($false)).GetString($bytes)
  $text = $text.Replace('__REPO__', "$Work/proj").Replace('__DETACHED__', "$Work/detached").Replace('__PLAIN__', "$Work/plain")
  return (New-Object System.Text.UTF8Encoding($false)).GetBytes($text)
}

function Expand-Colours([string]$Text) {
  $esc = [string][char]27
  return $Text.Replace('{green}', "$esc[32m").Replace('{yellow}', "$esc[33m").Replace('{red}', "$esc[31m").Replace('{reset}', "$esc[0m")
}

# cases.tsv's env column, as the environment for Invoke-Script.
function ConvertFrom-EnvSpec([string]$Spec) {
  $environment = @{ NO_COLOR = '1'; CLAUDE_STATUSLINE_NOW = '1800000000' }
  if ($Spec -ne '-') {
    foreach ($pair in $Spec -split ';') {
      $key, $value = $pair -split '=', 2
      $environment[$key] = $value
    }
  }
  return $environment
}

$script:StatuslineVariables = @(
  'NO_COLOR', 'CLAUDE_STATUSLINE_WARN', 'CLAUDE_STATUSLINE_NOTICE',
  'CLAUDE_STATUSLINE_SEGMENTS', 'CLAUDE_STATUSLINE_NO_EMOJI', 'CLAUDE_STATUSLINE_NOW'
)
