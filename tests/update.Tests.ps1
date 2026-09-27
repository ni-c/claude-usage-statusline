# The update segment of statusline.ps1, stamped as 1.1.0 the way stamp-release.sh
# stamps a release. Pester 5. The cache is fresh, or the check switched off, so
# nothing reaches the network - except where the cache line is broken or stale, and
# those cases look only at what the render printed or claimed before it returned.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  $root = Split-Path -Parent $PSScriptRoot
  $work = New-TestDirectory
  $source = [IO.File]::ReadAllText((Join-Path $root 'statusline.ps1'))
  $stamped = $source -replace "(?m)^\`$StatuslineVersion = ''$", "`$`$StatuslineVersion = '1.1.0'"
  if ($stamped -eq $source) { throw 'statusline.ps1 has no version line to stamp' }
  $stampedScript = Join-Path $work 'statusline.ps1'
  [IO.File]::WriteAllText($stampedScript, $stamped, (New-Object System.Text.UTF8Encoding($false)))
  $esc = [string][char]27
  $up = [string][char]0x2191

  # Environment and Path are case-insensitive names: the merged table needs its own.
  function Invoke-Update([hashtable]$Environment = @{}, [string]$Path = $stampedScript) {
    $merged = @{
      NO_COLOR                    = '1'
      CLAUDE_STATUSLINE_NOW       = '1800000000'
      CLAUDE_STATUSLINE_CACHE_DIR = $script:cache
      CLAUDE_STATUSLINE_SEGMENTS  = 'model,update'
    }
    foreach ($key in $Environment.Keys) { $merged[$key] = $Environment[$key] }
    $result = Invoke-Script -Script $Path `
      -InputBytes ([Text.Encoding]::UTF8.GetBytes('{"model":{"display_name":"M"}}')) `
      -Environment $merged -Unset $StatuslineVariables
    $result.Err | Should -BeNullOrEmpty
    $result.Code | Should -Be 0
    return $result.Out
  }

  function Set-Cache([string]$Line) {
    New-Item -ItemType Directory -Force $script:cache | Out-Null
    [IO.File]::WriteAllText((Join-Path $script:cache 'latest'), "$Line`n")
  }

  function Get-Cache { return [IO.File]::ReadAllText((Join-Path $script:cache 'latest')) }
}

AfterAll {
  Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Describe 'the update segment' {
  # A cache directory of its own for every case: a check an earlier case started may
  # still be writing to the last one, and Windows starts processes slowly.
  BeforeEach {
    $script:cache = Join-Path $work ('cache-' + [guid]::NewGuid().ToString('N'))
  }

  It 'a copy from a checkout is not stamped and never checks' {
    Invoke-Update -Path (Join-Path $root 'statusline.ps1') | Should -BeExactly "[M]`n"
    Test-Path $script:cache | Should -BeFalse
  }

  It 'a newer release in a fresh cache shows, and nothing is fetched' {
    Set-Cache '1799999000 1.2.0'
    Invoke-Update | Should -BeExactly "[M] | $up 1.2.0 available`n"
    Get-Cache | Should -BeExactly "1799999000 1.2.0`n"
  }

  It 'the notice is light blue' {
    Set-Cache '1799999000 1.2.0'
    Invoke-Update @{ NO_COLOR = '' } | Should -BeExactly "[M] | $esc[94m$up 1.2.0 available$esc[0m`n"
  }

  It 'without emoji the arrow goes' {
    Set-Cache '1799999000 1.2.0'
    Invoke-Update @{ CLAUDE_STATUSLINE_NO_EMOJI = '1' } | Should -BeExactly "[M] | 1.2.0 available`n"
  }

  It 'the default segment list ends with the notice' {
    Set-Cache '1799999000 1.2.0'
    Invoke-Update @{ CLAUDE_STATUSLINE_SEGMENTS = '' } | Should -BeExactly "[M] | $up 1.2.0 available`n"
  }

  It '<Version> is not newer than 1.1.0' -ForEach @(
    @{ Version = '1.1.0' }, @{ Version = '1.0.9' }, @{ Version = '0.9.99' }, @{ Version = '1.0.10' }
  ) {
    Set-Cache "1799999000 $Version"
    Invoke-Update | Should -BeExactly "[M]`n"
  }

  It '<Version> is newer than 1.1.0' -ForEach @(
    @{ Version = '1.10.0' }, @{ Version = '1.1.1' }, @{ Version = '2.0.0' },
    @{ Version = '1.1.08' }, @{ Version = '9999.9999.9999' }
  ) {
    Set-Cache "1799999000 $Version"
    Invoke-Update | Should -BeExactly "[M] | $up $Version available`n"
  }

  It 'a broken cache line shows nothing: <Line>' -ForEach @(
    @{ Line = '1799999000' }, @{ Line = '1799999000 ' }, @{ Line = '1799999000 1.2.0 x' },
    @{ Line = '1799999000 1.2.0{esc}[2J' }, @{ Line = '1799999000 9.9.9;rm' },
    @{ Line = '1799999000 12345.0.0' }, @{ Line = '1799999000 1.2' },
    @{ Line = '1799999000 1..2' }, @{ Line = '1799999000 v1.2.0' },
    @{ Line = '1799999000 1.2.0{cr}' }, @{ Line = '1799999000 1.2.0{nul}' }
  ) {
    Set-Cache ($Line.Replace('{esc}', $esc).Replace('{cr}', "`r").Replace('{nul}', [string][char]0))
    Invoke-Update | Should -BeExactly "[M]`n"
  }

  # The same fixed bytes tests/update.bats uses: invalid UTF-8, a high byte before
  # the timestamp, a valid non-ASCII digit, a tab, a CR line. Each one breaks the
  # timestamp at least, so each starts a check.
  It 'a cache of binary junk reads the same as in statusline.sh: <Hex>' -ForEach @(
    @{ Hex = 'FF FE 80 C0 20 C1 1B 5B 32 4A 0A'; Notice = $false },
    @{ Hex = 'FF 31 37 39 39 39 39 39 30 30 30 20 31 2E 32 2E 30 0A'; Notice = $true },
    @{ Hex = '31 37 39 39 39 39 39 30 30 30 20 31 2E 32 2E FF 30 0A'; Notice = $false },
    @{ Hex = 'E2 82 81 31 37 39 39 39 39 39 30 30 30 20 31 2E 32 2E 30 0A'; Notice = $true },
    @{ Hex = '31 37 39 39 39 39 39 30 30 30 09 31 2E 32 2E 30 0A'; Notice = $false },
    @{ Hex = '0D 0A 31 37 39 39 39 39 39 30 30 30 20 31 2E 32 2E 30 0A'; Notice = $false }
  ) {
    New-Item -ItemType Directory $script:cache | Out-Null
    $bytes = [byte[]]@($Hex -split ' ' | ForEach-Object { [Convert]::ToByte($_, 16) })
    [IO.File]::WriteAllBytes((Join-Path $script:cache 'latest'), $bytes)
    if ($Notice) { $expected = "[M] | $up 1.2.0 available`n" } else { $expected = "[M]`n" }
    Invoke-Update | Should -BeExactly $expected
  }

  It 'a directory as the cache file is left alone' {
    New-Item -ItemType Directory (Join-Path $script:cache 'latest') | Out-Null
    Invoke-Update | Should -BeExactly "[M]`n"
    @(Get-ChildItem -Force (Join-Path $script:cache 'latest')).Count | Should -Be 0
  }

  It '<Name>=<Value> stops both the notice and the check' -ForEach @(
    @{ Name = 'CLAUDE_STATUSLINE_UPDATE_CHECK'; Value = '0' },
    @{ Name = 'CLAUDE_STATUSLINE_UPDATE_CHECK'; Value = 'off' },
    @{ Name = 'DO_NOT_TRACK'; Value = '1' },
    @{ Name = 'DO_NOT_TRACK'; Value = 'true' },
    @{ Name = 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC'; Value = '1' }
  ) {
    Set-Cache '1700000000 1.2.0'
    Invoke-Update @{ $Name = $Value } | Should -BeExactly "[M]`n"
    Get-Cache | Should -BeExactly "1700000000 1.2.0`n"
  }

  It 'DO_NOT_TRACK=0 is no opt-out' {
    Set-Cache '1799999000 1.2.0'
    Invoke-Update @{ DO_NOT_TRACK = '0' } | Should -BeExactly "[M] | $up 1.2.0 available`n"
  }

  It 'CLAUDE_STATUSLINE_UPDATE_CHECK=1 wins over <Name>' -ForEach @(
    @{ Name = 'DO_NOT_TRACK' }, @{ Name = 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC' }
  ) {
    Set-Cache '1799999000 1.2.0'
    Invoke-Update @{ $Name = '1'; CLAUDE_STATUSLINE_UPDATE_CHECK = '1' } |
      Should -BeExactly "[M] | $up 1.2.0 available`n"
  }

  It 'without the update segment there is no check at all' {
    Set-Cache '1700000000 1.2.0'
    Invoke-Update @{ CLAUDE_STATUSLINE_SEGMENTS = 'model,dir,ctx' } | Should -BeExactly "[M]`n"
    Get-Cache | Should -BeExactly "1700000000 1.2.0`n"
  }

  # The one case that lets the background check start: it may already have replaced
  # the version by the time this looks, but never the time of the claim.
  It 'a check older than a day is claimed before the render returns' {
    Set-Cache '1700000000 1.2.0'
    Invoke-Update | Should -BeExactly "[M] | $up 1.2.0 available`n"
    (Get-Cache).Split(' ')[0] | Should -BeExactly '1800000000'
  }
}
