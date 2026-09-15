# install.ps1, run the way a release runs it: stamped by scripts/stamp-release.sh,
# with CLAUDE_STATUSLINE_SOURCE standing in for the download. Pester 5.
#
# CUS_DIST may point at a directory stamp-release.sh already built (CI does that
# in a bash step, because Windows has no bash that is reliably first on PATH);
# otherwise the suite stamps one itself.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  $root = Split-Path -Parent $PSScriptRoot
  $rich = Join-Path $root 'tests/fixtures/settings-rich.json'
  $onWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT

  if ($env:CUS_DIST) { $sourceDist = $env:CUS_DIST }
  else {
    $sourceDist = Join-Path (New-TestDirectory) 'dist'
    & bash (Join-Path $root 'scripts/stamp-release.sh') 9.9.9 $sourceDist
    if ($LASTEXITCODE -ne 0) { throw 'stamp-release.sh failed' }
  }

  function Invoke-Installer([string[]]$Arguments = @(), [string]$Installer) {
    if (-not $Installer) { $Installer = Join-Path $dist 'install.ps1' }
    return Invoke-Script -Script $Installer -Arguments $Arguments -Environment @{
      CLAUDE_CONFIG_DIR        = $config
      CLAUDE_STATUSLINE_SOURCE = $dist
    }
  }

  function Get-Settings { return [IO.File]::ReadAllText($settings) | ConvertFrom-Json }

  # Semantic comparison through jq when there is one: it is independent of the
  # PowerShell under test, which could otherwise agree with its own mistakes.
  function Get-Canonical([string]$Path, [string]$Filter = '.') {
    if (Get-Command jq -ErrorAction SilentlyContinue) { return (& jq -S -c $Filter $Path) -join "`n" }
    $object = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    if ($Filter -ne '.') { $object.PSObject.Properties.Remove('statusLine') }
    return ConvertTo-Json -InputObject $object -Depth 100 -Compress
  }
}

Describe 'install.ps1' {
  BeforeEach {
    $tmp = New-TestDirectory
    $dist = "$tmp/dist"
    Copy-Item -Recurse $sourceDist $dist
    $config = "$tmp/config dir"
    $settings = "$config/settings.json"
  }

  AfterEach {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
  }

  It 'installs into an empty config directory' {
    $result = Invoke-Installer
    $result.Code | Should -Be 0
    "$config/claude-usage-statusline/statusline.ps1" | Should -Exist
    $entry = (Get-Settings).statusLine
    $entry.type | Should -Be 'command'
    $entry.refreshInterval | Should -Be 30
    $entry.command | Should -BeLike "* -NoProfile -ExecutionPolicy Bypass -File '*config dir/claude-usage-statusline/statusline.ps1'"
  }

  It 'installs the exact bytes of the release' {
    Invoke-Installer | Out-Null
    (Get-FileHash "$config/claude-usage-statusline/statusline.ps1").Hash | Should -Be (Get-FileHash "$dist/statusline.ps1").Hash
  }

  It 'writes a command that runs through <_>' -ForEach @('bash', 'powershell', 'pwsh') {
    $shell = $_
    if (-not (Get-Command $shell -ErrorAction SilentlyContinue)) { Set-ItResult -Skipped -Because "$shell is not installed"; return }
    if ($shell -eq 'powershell' -and -not $onWindows) { Set-ItResult -Skipped -Because 'Windows only'; return }
    Invoke-Installer | Out-Null
    $command = (Get-Settings).statusLine.command
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Command $shell).Source
    # Claude Code uses Git Bash, not whatever bash.exe (WSL's, say) is first on PATH.
    if ($shell -eq 'bash' -and $onWindows) {
      $gitBash = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
      if (Test-Path $gitBash) { $psi.FileName = $gitBash }
    }
    if ($shell -eq 'bash') { $psi.Arguments = '-c "' + ($command -replace '"', '\"') + '"' }
    else { $psi.Arguments = '-NoProfile -Command "' + ($command -replace '"', '\"') + '"' }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $psi.EnvironmentVariables['NO_COLOR'] = '1'
    $process = [Diagnostics.Process]::Start($psi)
    $process.StandardInput.Write('{"model":{"display_name":"Opus 5"},"context_window":{"used_percentage":12}}')
    $process.StandardInput.Close()
    $output = $process.StandardOutput.ReadToEnd()
    $process.WaitForExit()
    $output.Trim() | Should -BeExactly '[Opus 5] | ctx 12%'
  }

  It 'keeps every other setting as it was' {
    New-Item -ItemType Directory $config | Out-Null
    Copy-Item $rich $settings
    (Invoke-Installer).Code | Should -Be 0
    Get-Canonical $settings 'del(.statusLine)' | Should -BeExactly (Get-Canonical $rich)
    (Get-FileHash "$settings.before-claude-usage-statusline").Hash | Should -Be (Get-FileHash $rich).Hash
  }

  It 'refuses to replace another status line without -Force' {
    New-Item -ItemType Directory $config | Out-Null
    [IO.File]::WriteAllText($settings, '{"statusLine":{"type":"command","command":"~/mine.sh"}}')
    $result = Invoke-Installer
    $result.Code | Should -Not -Be 0
    $result.Err | Should -Match 'Another status line is configured'
    [IO.File]::ReadAllText($settings) | Should -BeExactly '{"statusLine":{"type":"command","command":"~/mine.sh"}}'
    "$config/claude-usage-statusline" | Should -Not -Exist
  }

  It 'treats a status line without a command as someone else''s' {
    New-Item -ItemType Directory $config | Out-Null
    [IO.File]::WriteAllText($settings, '{"statusLine":{"type":"static"}}')
    (Invoke-Installer).Code | Should -Not -Be 0
  }

  It '-Force replaces another status line whole' {
    New-Item -ItemType Directory $config | Out-Null
    [IO.File]::WriteAllText($settings, '{"statusLine":{"type":"command","command":"~/mine.sh","padding":4}}')
    (Invoke-Installer @('-Force')).Code | Should -Be 0
    $entry = (Get-Settings).statusLine
    @($entry.PSObject.Properties.Name | Sort-Object) -join ',' | Should -Be 'command,refreshInterval,type'
  }

  It 'reinstalling keeps refreshInterval and padding and changes nothing else' {
    Invoke-Installer | Out-Null
    $doc = Get-Settings
    $doc.statusLine.refreshInterval = 5
    $doc.statusLine | Add-Member -NotePropertyName padding -NotePropertyValue 2
    [IO.File]::WriteAllText($settings, (ConvertTo-Json -InputObject $doc -Depth 10))
    $installed = Get-Canonical $settings
    $result = Invoke-Installer
    $result.Code | Should -Be 0
    Get-Canonical $settings | Should -BeExactly $installed
  }

  It 'running it twice leaves the file byte for byte the same' {
    Invoke-Installer | Out-Null
    $first = [IO.File]::ReadAllText($settings)
    $result = Invoke-Installer
    [IO.File]::ReadAllText($settings) | Should -BeExactly $first
    $result.Out | Should -Not -Match 'Previous settings saved'
  }

  It '-Uninstall removes its entry and files and keeps the rest' {
    New-Item -ItemType Directory $config | Out-Null
    Copy-Item $rich $settings
    Invoke-Installer | Out-Null
    (Invoke-Installer @('-Uninstall')).Code | Should -Be 0
    Get-Canonical $settings | Should -BeExactly (Get-Canonical $rich)
    "$config/claude-usage-statusline" | Should -Not -Exist
  }

  It '-Uninstall leaves another status line alone' {
    New-Item -ItemType Directory $config | Out-Null
    [IO.File]::WriteAllText($settings, '{"statusLine":{"type":"command","command":"~/mine.sh"}}')
    $result = Invoke-Installer @('-Uninstall')
    $result.Code | Should -Be 0
    $result.Out | Should -Match 'belongs to something else'
    [IO.File]::ReadAllText($settings) | Should -BeExactly '{"statusLine":{"type":"command","command":"~/mine.sh"}}'
  }

  It '-Uninstall with nothing installed is a no-op' {
    (Invoke-Installer @('-Uninstall')).Code | Should -Be 0
    $settings | Should -Not -Exist
  }

  It 'refuses a script that does not match the release checksum' {
    Add-Content -Path "$dist/statusline.ps1" -Value '# tampered'
    $result = Invoke-Installer
    $result.Code | Should -Not -Be 0
    $result.Err | Should -Match 'Checksum mismatch'
    $settings | Should -Not -Exist
    "$config/claude-usage-statusline" | Should -Not -Exist
  }

  It 'refuses a settings file that is not a JSON object' {
    New-Item -ItemType Directory $config | Out-Null
    [IO.File]::WriteAllText($settings, '[1]')
    $result = Invoke-Installer
    $result.Code | Should -Not -Be 0
    $result.Err | Should -Match 'is not a JSON object'
    [IO.File]::ReadAllText($settings) | Should -BeExactly '[1]'
  }

  It 'an installer from a checkout refuses to download' {
    $result = Invoke-Script -Script (Join-Path $root 'install.ps1') -Environment @{ CLAUDE_CONFIG_DIR = $config } -Unset @('CLAUDE_STATUSLINE_SOURCE')
    $result.Code | Should -Not -Be 0
    $result.Err | Should -Match 'does not belong to a release'
  }

  It 'is plain ASCII, because Windows PowerShell 5.1 reads a BOM-less script as ANSI' {
    $bytes = [IO.File]::ReadAllBytes((Join-Path $root 'install.ps1'))
    @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
  }

  It 'does not call exit, which would close the window of anyone running it through iex' {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'install.ps1'), [ref]$tokens, [ref]$errors)
    $errors.Count | Should -Be 0
    $exits = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.ExitStatementAst] }, $true)
    @($exits).Count | Should -Be 0
  }
}
