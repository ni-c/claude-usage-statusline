# claude-usage-statusline - https://github.com/ni-c/claude-usage-statusline
#
# The Windows PowerShell twin of statusline.sh. Reads the JSON Claude Code pipes
# into a status line command and prints the same line, byte for byte:
#
#   [Opus 5] <folder> my-repo <branch> main | ctx 30% | 2h15 42% | <warn> 3d 81%
#
# Runs on Windows PowerShell 5.1 and PowerShell 7, with nothing to install.
# This file is ASCII on purpose: 5.1 reads a script without a BOM as the ANSI code
# page, so every non-ASCII character is built from its code point instead.
# A status line must never fail: every problem degrades to a shorter line.

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

function Get-EnvInt([string]$Name, [int]$Default) {
  $value = [Environment]::GetEnvironmentVariable($Name)
  if ($value -match '^[0-9]+$' -and $value.Length -le 12) { return [long]$value }
  return $Default
}

function Test-True([string]$Value) {
  return $Value -match '^(1|true|yes|on)$'
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
$dir = Get-Clean (Get-FirstField $data (@(, @('workspace', 'current_dir')) + @(, @('cwd'))))
$dirName = Get-BaseName $dir
$ctxPct = Get-Percent (Get-Field $data @('context_window', 'used_percentage'))
$fivePct = Get-Percent (Get-Field $data @('rate_limits', 'five_hour', 'used_percentage'))
$fiveReset = Get-Epoch (Get-Field $data @('rate_limits', 'five_hour', 'resets_at'))
$sevenPct = Get-Percent (Get-Field $data @('rate_limits', 'seven_day', 'used_percentage'))
$sevenReset = Get-Epoch (Get-Field $data @('rate_limits', 'seven_day', 'resets_at'))

$warn = Get-EnvInt 'CLAUDE_STATUSLINE_WARN' 80
$notice = Get-EnvInt 'CLAUDE_STATUSLINE_NOTICE' 50
$now = Get-EnvInt 'CLAUDE_STATUSLINE_NOW' ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())

if (Test-True $env:CLAUDE_STATUSLINE_NO_EMOJI) {
  $folder = ''; $branchOpen = '('; $branchClose = ')'; $warnMark = '! '
} else {
  $folder = [char]::ConvertFromUtf32(0x1F4C1) + ' '
  $branchOpen = [string][char]0x2387 + ' '
  $branchClose = ''
  $warnMark = [string][char]0x26A0 + ' '
}

# https://no-color.org: present and not empty disables colour.
if ($env:NO_COLOR) {
  $green = ''; $yellow = ''; $red = ''; $reset = ''
} else {
  $esc = [string][char]27
  $green = "$esc[32m"; $yellow = "$esc[33m"; $red = "$esc[31m"; $reset = "$esc[0m"
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

function Get-Segment([string]$Name) {
  switch ($Name) {
    'model' { return "[$model]" }
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
  }
  return ''
}

# Keep the known names in the order given. A list with none of them falls back to
# the default rather than to an empty line.
$known = @('model', 'dir', 'git', 'ctx', '5h', '7d')
$segments = @()
if ($env:CLAUDE_STATUSLINE_SEGMENTS) {
  $segments = @($env:CLAUDE_STATUSLINE_SEGMENTS -split '[, ]+' | Where-Object { $known -ccontains $_ })
}
if ($segments.Count -eq 0) { $segments = $known }

$line = ''
foreach ($name in $segments) {
  $text = Get-Segment $name
  if (-not $text) { continue }
  if ($name -eq 'ctx' -or $name -eq '5h' -or $name -eq '7d') { $sep = ' | ' } else { $sep = ' ' }
  if ($line -ne '') { $line = "$line$sep$text" } else { $line = $text }
}

$bytes = $utf8.GetBytes($line + "`n")
$stdout = [Console]::OpenStandardOutput()
$stdout.Write($bytes, 0, $bytes.Length)
$stdout.Flush()
