# statusline.ps1 against every case in cases.tsv - the same cases, and the same
# bytes, that statusline.bats holds statusline.sh to. Pester 5.

BeforeDiscovery {
  $cases = Get-Content -Encoding UTF8 (Join-Path $PSScriptRoot 'cases.tsv') |
    Where-Object { $_ -ne '' -and -not $_.StartsWith('#') } |
    ForEach-Object {
      $cells = $_ -split "`t"
      @{ Name = $cells[0]; Fixture = $cells[1]; EnvSpec = $cells[2]; Expected = $cells[3] }
    }
}

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  $root = Split-Path -Parent $PSScriptRoot
  $script = Join-Path $root 'statusline.ps1'
  $work = New-TestDirectory
  Initialize-GitFixtures $work
}

AfterAll {
  Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Describe 'statusline.ps1' {
  It '<Name>' -ForEach $cases {
    $result = Invoke-Script -Script $script `
      -InputBytes (Get-FixtureBytes $root $Fixture $work) `
      -Environment (ConvertFrom-EnvSpec $EnvSpec) `
      -Unset $StatuslineVariables
    $result.Out | Should -BeExactly ((Expand-Colours $Expected) + "`n")
    $result.Err | Should -BeNullOrEmpty
    $result.Code | Should -Be 0
  }

  It 'uses the current time when CLAUDE_STATUSLINE_NOW is not set' {
    $reset = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 7200 + 30
    $json = '{"rate_limits":{"five_hour":{"used_percentage":1,"resets_at":' + $reset + '}}}'
    $result = Invoke-Script -Script $script `
      -InputBytes ([Text.Encoding]::UTF8.GetBytes($json)) `
      -Environment @{ NO_COLOR = '1' } -Unset $StatuslineVariables
    $result.Out | Should -BeExactly "[?] | 2h00 1%`n"
  }

  It 'is plain ASCII, because Windows PowerShell 5.1 reads a BOM-less script as ANSI' {
    $bytes = [IO.File]::ReadAllBytes($script)
    @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
  }
}
