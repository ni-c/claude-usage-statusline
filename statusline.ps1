# claude-usage-statusline - https://github.com/ni-c/claude-usage-statusline
#
# The Windows PowerShell twin of statusline.sh. Reads the JSON Claude Code pipes
# into a status line command and prints the same line, byte for byte:
#
#   [Opus 5.5 <dot> high] <folder> my-repo <branch> main | ctx 30% | 2h15 42% | <warn> 3d 81%
#
# Runs on Windows PowerShell 5.1 and PowerShell 7, with nothing to install.
# This file is ASCII on purpose: 5.1 reads a script without a BOM as the ANSI code
# page, so every non-ASCII character is built from its code point instead.
# A status line must never fail: every problem degrades to a shorter line.

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

# The release this copy belongs to, stamped by scripts/stamp-release.sh. A copy taken
# from a checkout has none and never looks for updates.
$StatuslineVersion = ''

function Get-EnvInt([string]$Name, [int]$Default) {
  $value = [Environment]::GetEnvironmentVariable($Name)
  if ($value -match '^[0-9]+$' -and $value.Length -le 12) { return [long]$value }
  return $Default
}

function Test-True([string]$Value) {
  return $Value -match '^(1|true|yes|on)$'
}

function Test-False([string]$Value) {
  return $Value -match '^(0|false|no|off)$'
}

# Mirrors jq's `clean`: drop C0 and C1 control characters, so an ESC in a
# directory name cannot become a terminal escape sequence.
function Get-Clean($Value) {
  if ($null -eq $Value) { return '' }
  return ([string]$Value) -replace '[\x00-\x1f\x7f-\x9f]', ''
}

function Get-Number($Value) {
  if ($null -eq $Value) { return $null }
  if ($Value -is [string]) {
    $parsed = 0.0
    $style = [Globalization.NumberStyles]::Float
    $culture = [Globalization.CultureInfo]::InvariantCulture
    if (-not [double]::TryParse($Value, $style, $culture, [ref]$parsed)) { return $null }
    if ([double]::IsNaN($parsed) -or [double]::IsInfinity($parsed)) { return $null }
    return $parsed
  }
  if ($Value -is [bool]) { return $null }
  try { $n = [double]$Value } catch { return $null }
  if ([double]::IsNaN($n) -or [double]::IsInfinity($n)) { return $null }
  return $n
}

function Get-Percent($Value) {
  $n = Get-Number $Value
  if ($null -eq $n) { return $null }
  if ($n -lt 0) { return 0 }
  if ($n -gt 100) { return 100 }
  return [long][Math]::Floor($n)
}

function Get-Epoch($Value) {
  $n = Get-Number $Value
  if ($null -eq $n -or $n -lt 0 -or $n -ge 100000000000) { return $null }
  return [long][Math]::Floor($n)
}

function Get-BaseName([string]$Path) {
  if ($Path -eq '') { return '' }
  $trimmed = $Path -replace '[/\\]+$', ''
  if ($trimmed -eq '') { return '/' }
  return ($trimmed -split '[/\\]')[-1]
}

function Get-Field($Object, [string[]]$Path) {
  foreach ($key in $Path) {
    if ($Object -isnot [System.Management.Automation.PSCustomObject]) { return $null }
    $property = $Object.PSObject.Properties[$key]
    if ($null -eq $property) { return $null }
    $Object = $property.Value
  }
  return $Object
}

function Get-FirstField($Object, [string[][]]$Paths) {
  foreach ($path in $Paths) {
    $value = Get-Field $Object $path
    # jq's `//` skips null and false.
    if ($null -ne $value -and $value -isnot [bool]) { return $value }
    if ($value -is [bool] -and $value) { return $value }
  }
  return $null
}

# stdin and stdout as raw UTF-8 bytes. [Console]::In and Write-Output would go
# through the console code page, which mangles every emoji and umlaut on 5.1.
$utf8 = New-Object System.Text.UTF8Encoding($false)
$reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), $utf8)
$raw = $reader.ReadToEnd()
# statusline.sh drops NUL bytes before jq sees the document, because bash cannot
# carry one through a command substitution. Drop them here too, or the two
# implementations would disagree on an input that contains one.
$raw = $raw.Replace([string][char]0, '')

$data = $null
try {
  if ($raw.Trim() -ne '') { $data = $raw | ConvertFrom-Json -ErrorAction Stop }
} catch {
  $data = $null
}
# A JSON scalar or array is not an object with fields.
if ($data -isnot [System.Management.Automation.PSCustomObject]) { $data = $null }

# jq's `.model.display_name // .model.id // "?"`, and an empty name reads as "?" too.
$model = Get-Clean (Get-FirstField $data (@(, @('model', 'display_name')) + @(, @('model', 'id'))))
if ($model -eq '') { $model = '?' }
# The name without a trailing "(1M context)" or the like, unless that is all it is.
$modelShort = $model -replace ' *\([^()]*\)$', ''
if ($modelShort -eq '') { $modelShort = $model }
$dir = Get-Clean (Get-FirstField $data (@(, @('workspace', 'current_dir')) + @(, @('cwd'))))
$dirName = Get-BaseName $dir
$ctxPct = Get-Percent (Get-Field $data @('context_window', 'used_percentage'))
$fivePct = Get-Percent (Get-Field $data @('rate_limits', 'five_hour', 'used_percentage'))
$fiveReset = Get-Epoch (Get-Field $data @('rate_limits', 'five_hour', 'resets_at'))
$sevenPct = Get-Percent (Get-Field $data @('rate_limits', 'seven_day', 'used_percentage'))
$sevenReset = Get-Epoch (Get-Field $data @('rate_limits', 'seven_day', 'resets_at'))
$effort = Get-Field $data @('effort', 'level')
if ($effort -is [string]) { $effort = Get-Clean $effort } else { $effort = '' }
$fast = Get-Field $data @('fast_mode')
$fast = $fast -is [bool] -and $fast

$warn = Get-EnvInt 'CLAUDE_STATUSLINE_WARN' 80
$notice = Get-EnvInt 'CLAUDE_STATUSLINE_NOTICE' 50
$now = Get-EnvInt 'CLAUDE_STATUSLINE_NOW' ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())

# Both on unless switched off, so they read the "false" words rather than the "true" ones.
if (-not (Test-False $env:CLAUDE_STATUSLINE_SHORT_MODEL)) { $model = $modelShort }
if (Test-False $env:CLAUDE_STATUSLINE_EFFORT) { $effort = '' }

if (Test-True $env:CLAUDE_STATUSLINE_NO_EMOJI) {
  $folder = ''; $branchOpen = '('; $branchClose = ')'; $warnMark = '! '; $fastMark = 'fast'; $upMark = ''
} else {
  $folder = [char]::ConvertFromUtf32(0x1F4C1) + ' '
  $branchOpen = [string][char]0x2387 + ' '
  $branchClose = ''
  $warnMark = [string][char]0x26A0 + ' '
  $fastMark = [string][char]0x26A1
  $upMark = [string][char]0x2191 + ' '
}

# https://no-color.org: present and not empty disables colour.
if ($env:NO_COLOR) {
  $green = ''; $yellow = ''; $red = ''; $blue = ''; $reset = ''
} else {
  $esc = [string][char]27
  $green = "$esc[32m"; $yellow = "$esc[33m"; $red = "$esc[31m"; $blue = "$esc[94m"; $reset = "$esc[0m"
}

function Format-Metric([string]$Label, [long]$Percent) {
  $color = $green; $mark = ''
  if ($Percent -ge $warn) { $color = $red; $mark = $warnMark }
  elseif ($Percent -ge $notice) { $color = $yellow }
  return "$color$mark$Label $Percent%$reset"
}

function Get-UntilReset([long]$Epoch) {
  $diff = $Epoch - $now
  if ($diff -lt 0) { return [long]0 }
  return [long]$diff
}

function Get-GitBranch {
  if ($dir -eq '' -or -not (Get-Command git -ErrorAction SilentlyContinue)) { return '' }
  # GIT_OPTIONAL_LOCKS=0: never take index.lock away from a git the user is running.
  $env:GIT_OPTIONAL_LOCKS = '0'
  $branch = & git -C $dir symbolic-ref --short -q HEAD 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $branch) {
    $branch = & git -C $dir rev-parse --short HEAD 2>$null
    if ($LASTEXITCODE -ne 0) { return '' }
  }
  return Get-Clean (($branch | Select-Object -First 1))
}

# A release version: three parts of one to four digits. Whatever comes from the cache
# file or from the network passes through here before it is used anywhere. \z, not $:
# .NET's $ also matches before a final newline.
function Test-Version([string]$Value) {
  return $Value -cmatch '^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}\z'
}

function Get-VersionKey([string]$Value) {
  $parts = $Value.Split('.')
  return [long]$parts[0] * 100000000 + [long]$parts[1] * 10000 + [long]$parts[2]
}

# On by default. DO_NOT_TRACK and Claude Code's own switch for non-essential traffic
# turn it off too, unless CLAUDE_STATUSLINE_UPDATE_CHECK asks for it by name.
function Test-UpdateCheck {
  if (-not (Test-Version $StatuslineVersion)) { return $false }
  if (Test-False $env:CLAUDE_STATUSLINE_UPDATE_CHECK) { return $false }
  if (Test-True $env:CLAUDE_STATUSLINE_UPDATE_CHECK) { return $true }
  if ($env:DO_NOT_TRACK -and $env:DO_NOT_TRACK -ne '0') { return $false }
  return -not $env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC
}

function Get-CacheDir {
  if ($env:CLAUDE_STATUSLINE_CACHE_DIR) { return $env:CLAUDE_STATUSLINE_CACHE_DIR }
  if ($env:LOCALAPPDATA) { return Join-Path $env:LOCALAPPDATA 'claude-usage-statusline' }
  return ''
}

# "<now> <version>" into Dir\latest, whole or not at all.
# Move-Item would put the file inside a directory of that name: neither that nor a
# symlink is ours to touch.
function Write-UpdateCache([string]$Dir, [string]$Latest) {
  $target = Get-Item -LiteralPath (Join-Path $Dir 'latest') -Force -ErrorAction SilentlyContinue
  if ($null -ne $target -and ($target.PSIsContainer -or ($target.Attributes -band [IO.FileAttributes]::ReparsePoint))) {
    return $false
  }
  $tmp = Join-Path $Dir "latest.$PID.tmp"
  try {
    [IO.File]::WriteAllText($tmp, "$now $Latest`n", $utf8)
    Move-Item -LiteralPath $tmp -Destination (Join-Path $Dir 'latest') -Force -ErrorAction Stop
    return $true
  } catch {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    return $false
  }
}

# The background half of the update check: a hidden PowerShell of its own, so the
# status line never waits for the network. It reads only the redirect of
# /releases/latest and drops anything but the expected tag URL. Directory and time
# travel in the environment rather than in the code.
$updateFetch = @'
try {
  $repo = 'https://github.com/ni-c/claude-usage-statusline'
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $request = [Net.HttpWebRequest]::Create("$repo/releases/latest")
  $request.AllowAutoRedirect = $false
  $request.Timeout = 5000
  $request.UserAgent = 'claude-usage-statusline'
  $response = $request.GetResponse()
  $location = $response.Headers['Location']
  $response.Close()
  if ($location -cmatch ('^' + [regex]::Escape("$repo/releases/tag/v") + '([0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4})\z')) {
    $dir = $env:CLAUDE_STATUSLINE_FETCH_DIR
    $target = Get-Item -LiteralPath (Join-Path $dir 'latest') -Force -ErrorAction SilentlyContinue
    if ($null -ne $target -and ($target.PSIsContainer -or ($target.Attributes -band [IO.FileAttributes]::ReparsePoint))) { return }
    $tmp = Join-Path $dir "latest.$PID.tmp"
    [IO.File]::WriteAllText($tmp, $env:CLAUDE_STATUSLINE_FETCH_NOW + ' ' + $Matches[1] + "`n")
    Move-Item -LiteralPath $tmp -Destination (Join-Path $dir 'latest') -Force
  }
} catch {}
'@

# Claims the next check before it starts, so the renders of the next seconds do not
# each start one.
function Start-UpdateCheck([string]$Dir, [string]$Latest) {
  try { New-Item -ItemType Directory -Force -Path $Dir -ErrorAction Stop | Out-Null } catch { return }
  if (-not (Write-UpdateCache $Dir $Latest)) { return }
  $env:CLAUDE_STATUSLINE_FETCH_DIR = $Dir
  $env:CLAUDE_STATUSLINE_FETCH_NOW = [string]$now
  $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($updateFetch))
  try {
    Start-Process -FilePath (Get-Process -Id $PID).Path -WindowStyle Hidden -ErrorAction Stop `
      -ArgumentList '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded | Out-Null
  } catch {
    return
  }
}

# The latest release when it is newer than this copy. Reads only the cache; a check
# older than a day (or dated in the future) starts the next one.
function Get-UpdateNotice {
  if (-not (Test-UpdateCheck)) { return '' }
  $dir = Get-CacheDir
  if ($dir -eq '') { return '' }
  $file = Join-Path $dir 'latest'
  $line = ''
  $item = Get-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
  if ($null -ne $item) {
    # A symlink, a junction or anything but a plain file is not ours: never read
    # through it, never replace it.
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return '' }
    if ($item.PSIsContainer) { return '' }
    try {
      $stream = [IO.File]::OpenRead($file)
      try {
        $buffer = New-Object byte[] 64
        $count = $stream.Read($buffer, 0, 64)
      } finally { $stream.Dispose() }
      $line = ($utf8.GetString($buffer, 0, $count) -split "`n")[0]
    } catch { $line = '' }
  }
  # statusline.sh's ${line%% *} and ${line#* }: without a space, both are the line.
  $space = $line.IndexOf(' ')
  if ($space -lt 0) { $checked = $line; $latest = $line }
  else { $checked = $line.Substring(0, $space); $latest = $line.Substring($space + 1) }
  if ($checked -notmatch '^[0-9]{1,12}\z') { $checked = '' }
  if (-not (Test-Version $latest)) { $latest = '' }
  if ($checked -eq '' -or [long]$checked -gt $now -or $now - [long]$checked -ge 86400) {
    Start-UpdateCheck $dir $latest
  }
  if ($latest -ne '' -and (Get-VersionKey $latest) -gt (Get-VersionKey $StatuslineVersion)) { return $latest }
  return ''
}

function Get-Segment([string]$Name) {
  switch ($Name) {
    'model' {
      $dot = ' ' + [string][char]0x00B7 + ' '
      $text = $model
      if ($effort -ne '') { $text = "$text$dot$effort" }
      if ($fast) { $text = "$text$dot$fastMark" }
      return "[$text]"
    }
    'dir' { if ($dirName -ne '') { return "$folder$dirName" } }
    'git' {
      $branch = Get-GitBranch
      if ($branch -ne '') { return "$branchOpen$branch$branchClose" }
    }
    'ctx' { if ($null -ne $ctxPct) { return Format-Metric 'ctx' $ctxPct } }
    '5h' {
      if ($null -eq $fivePct) { return '' }
      $label = '5h'
      if ($null -ne $fiveReset) {
        $diff = Get-UntilReset $fiveReset
        $label = '{0}h{1:00}' -f [long][Math]::Floor($diff / 3600), [long][Math]::Floor(($diff % 3600) / 60)
      }
      return Format-Metric $label $fivePct
    }
    '7d' {
      if ($null -eq $sevenPct) { return '' }
      $label = '7d'
      if ($null -ne $sevenReset) {
        $diff = Get-UntilReset $sevenReset
        # Whole days, rounded up: "1d" means "resets within the next day".
        $label = '{0}d' -f [long][Math]::Floor(($diff + 86399) / 86400)
      }
      return Format-Metric $label $sevenPct
    }
    'update' {
      $latest = Get-UpdateNotice
      if ($latest -ne '') { return "$blue$upMark$latest available$reset" }
    }
  }
  return ''
}

# Keep the known names in the order given. A list with none of them falls back to
# the default rather than to an empty line.
$known = @('model', 'dir', 'git', 'ctx', '5h', '7d', 'update')
$segments = @()
if ($env:CLAUDE_STATUSLINE_SEGMENTS) {
  $segments = @($env:CLAUDE_STATUSLINE_SEGMENTS -split '[, ]+' | Where-Object { $known -ccontains $_ })
}
if ($segments.Count -eq 0) { $segments = $known }

$line = ''
foreach ($name in $segments) {
  $text = Get-Segment $name
  if (-not $text) { continue }
  if ($name -eq 'ctx' -or $name -eq '5h' -or $name -eq '7d' -or $name -eq 'update') { $sep = ' | ' } else { $sep = ' ' }
  if ($line -ne '') { $line = "$line$sep$text" } else { $line = $text }
}

$bytes = $utf8.GetBytes($line + "`n")
$stdout = [Console]::OpenStandardOutput()
$stdout.Write($bytes, 0, $bytes.Length)
$stdout.Flush()
