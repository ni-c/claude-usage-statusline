# Installs claude-usage-statusline as the Claude Code status line (Windows).
#
#   irm https://github.com/ni-c/claude-usage-statusline/releases/latest/download/install.ps1 | iex
#
# With options, run it as a script block instead:
#
#   & ([scriptblock]::Create((irm https://github.com/ni-c/claude-usage-statusline/releases/latest/download/install.ps1))) -Force
#   & ([scriptblock]::Create((irm https://github.com/ni-c/claude-usage-statusline/releases/latest/download/install.ps1))) -Uninstall
#
# What it does: downloads statusline.ps1 from the release this installer belongs
# to, checks it against the SHA-256 baked in below, puts it in
# %USERPROFILE%\.claude\claude-usage-statusline\ and sets `statusLine` in
# settings.json. Every other setting is left as it is. CLAUDE_CONFIG_DIR is
# respected. Runs on Windows PowerShell 5.1 and PowerShell 7 (also on Linux/macOS).
#
# Everything happens inside a function and failures are thrown, never `exit`ed:
# under `irm | iex` this runs in the caller's own session, and `exit` would close
# their window.

param(
  [switch]$Force,
  [switch]$Uninstall
)

# Stamped by scripts/stamp-release.sh when a release is built. An installer taken
# from a checkout has neither and installs only from CLAUDE_STATUSLINE_SOURCE.
$Version = ''
$Sha256 = ''

function Install-ClaudeUsageStatusline {
  param([bool]$Force, [bool]$Uninstall, [string]$Version, [string]$Sha256)

  $ErrorActionPreference = 'Stop'
  $ProgressPreference = 'SilentlyContinue'
  $name = 'claude-usage-statusline'
  $repo = 'ni-c/claude-usage-statusline'
  # How an installed status line is recognised as ours, on either OS.
  $marker = "$name/statusline."
  $onWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT

  if ($env:CLAUDE_CONFIG_DIR) { $configDir = $env:CLAUDE_CONFIG_DIR }
  else { $configDir = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.claude' }
  $installDir = Join-Path $configDir $name
  $target = Join-Path $installDir 'statusline.ps1'
  $settingsPath = Join-Path $configDir 'settings.json'
  $utf8 = New-Object System.Text.UTF8Encoding($false)

  # PowerShell 7.2+ edits settings.json through System.Text.Json's JsonNode, which
  # keeps every value exactly as it was. Windows PowerShell 5.1 has only
  # ConvertFrom-Json/ConvertTo-Json: the values survive, the formatting does not,
  # which is one reason the previous file is always kept next to the new one.
  if ($PSVersionTable.PSVersion.Major -ge 6) {
    # Part of .NET, but not necessarily loaded into the session yet.
    try { Add-Type -AssemblyName System.Text.Json, System.Text.Encodings.Web -ErrorAction Stop }
    catch { Write-Verbose 'System.Text.Json is not available; using ConvertFrom-Json.' }
  }
  $useJsonNode = ($null -ne ('System.Text.Json.Nodes.JsonNode' -as [type])) -and
    ($null -ne ('System.Text.Encodings.Web.JavaScriptEncoder' -as [type]))

  function Read-Settings {
    if (-not (Test-Path -LiteralPath $settingsPath)) { $text = '{}' }
    else { $text = [IO.File]::ReadAllText($settingsPath, $utf8) }
    if ($text.Trim() -eq '') { $text = '{}' }
    try {
      if ($useJsonNode) {
        $doc = [System.Text.Json.Nodes.JsonNode]::Parse($text)
        if ($doc -isnot [System.Text.Json.Nodes.JsonObject]) { throw 'not an object' }
      } else {
        $doc = $text | ConvertFrom-Json -ErrorAction Stop
        if ($doc -isnot [System.Management.Automation.PSCustomObject]) { throw 'not an object' }
      }
    } catch {
      throw "$settingsPath is not a JSON object. Fix it first; nothing was changed."
    }
    return , $doc
  }

  # The configured command, '' when there is none, or the entry as JSON when it has
  # no command at all, which still is not ours to overwrite.
  function Get-StatusCommand($Doc) {
    if ($useJsonNode) {
      $entry = $Doc['statusLine']
      if ($null -eq $entry) { return '' }
      if ($entry -is [System.Text.Json.Nodes.JsonObject] -and $null -ne $entry['command']) {
        return $entry['command'].ToString()
      }
      return $entry.ToJsonString()
    }
    $property = $Doc.PSObject.Properties['statusLine']
    if ($null -eq $property -or $null -eq $property.Value) { return '' }
    $entry = $property.Value
    if ($entry -is [System.Management.Automation.PSCustomObject] -and $null -ne $entry.PSObject.Properties['command']) {
      return [string]$entry.command
    }
    return (ConvertTo-Json -InputObject $entry -Compress -Depth 100)
  }

  # Sets statusLine to $Command, keeping refreshInterval and padding from an
  # earlier installation of ours. $Command '' removes the entry.
  function Set-StatusLine($Doc, [string]$Command, [bool]$KeepOld) {
    if ($useJsonNode) {
      if ($Command -eq '') { [void]$Doc.Remove('statusLine'); return }
      # Nodes are built by parsing: the constructors and JsonValue.Create take
      # optional arguments, which PowerShell's overload resolution cannot skip.
      $node = [System.Text.Json.Nodes.JsonNode]
      $entry = $node::Parse('{}')
      $old = $Doc['statusLine']
      if ($KeepOld -and $old -is [System.Text.Json.Nodes.JsonObject]) { $entry = $node::Parse($old.ToJsonString()) }
      $entry['type'] = $node::Parse('"command"')
      $entry['command'] = $node::Parse((ConvertTo-Json -InputObject $Command -Compress))
      if ($null -eq $entry['refreshInterval']) { $entry['refreshInterval'] = $node::Parse('30') }
      $Doc['statusLine'] = $entry
      return
    }
    if ($Command -eq '') { $Doc.PSObject.Properties.Remove('statusLine'); return }
    $entry = [pscustomobject]@{}
    $old = $null
    if ($Doc.PSObject.Properties['statusLine']) { $old = $Doc.statusLine }
    if ($KeepOld -and $old -is [System.Management.Automation.PSCustomObject]) {
      foreach ($p in $old.PSObject.Properties) { $entry | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value }
    }
    # Existing values are set in place: Add-Member -Force would remove the property
    # and append it again, so every reinstall would reorder the entry and rewrite
    # a file that had nothing to change.
    foreach ($pair in @(@('type', 'command'), @('command', $Command))) {
      if ($null -ne $entry.PSObject.Properties[$pair[0]]) { $entry.($pair[0]) = $pair[1] }
      else { $entry | Add-Member -NotePropertyName $pair[0] -NotePropertyValue $pair[1] }
    }
    if ($null -eq $entry.PSObject.Properties['refreshInterval']) {
      $entry | Add-Member -NotePropertyName refreshInterval -NotePropertyValue 30
    }
    $Doc | Add-Member -NotePropertyName statusLine -NotePropertyValue $entry -Force
  }

  function ConvertTo-SettingsText($Doc) {
    if ($useJsonNode) {
      $options = New-Object System.Text.Json.JsonSerializerOptions
      $options.WriteIndented = $true
      # Keep umlauts and "<" readable instead of \u-escaping them; this is a file
      # people edit by hand, not HTML.
      $options.Encoder = [System.Text.Encodings.Web.JavaScriptEncoder]::UnsafeRelaxedJsonEscaping
      return $Doc.ToJsonString($options) + "`n"
    }
    return (ConvertTo-Json -InputObject $Doc -Depth 100) + "`n"
  }

  # Written to a temporary file next to it and moved into place, so an interrupted
  # run never leaves half a file. The previous version is kept next to it.
  function Write-Settings([string]$Text) {
    if (-not (Test-Path -LiteralPath $configDir)) { New-Item -ItemType Directory -Path $configDir | Out-Null }
    if (Test-Path -LiteralPath $settingsPath) {
      if ([IO.File]::ReadAllText($settingsPath, $utf8) -ceq $Text) { return }
      $backup = "$settingsPath.before-$name"
      Copy-Item -LiteralPath $settingsPath -Destination $backup -Force
      Write-Host "Previous settings saved as $backup"
    }
    $tmp = "$settingsPath.tmp.$PID"
    [IO.File]::WriteAllText($tmp, $Text, $utf8)
    Move-Item -LiteralPath $tmp -Destination $settingsPath -Force
  }

  # Quoted so that both shells Claude Code may run it through read the same path:
  # Git Bash when it is installed, PowerShell otherwise. Single quotes are literal
  # in both. Forward slashes, because Git Bash eats backslashes.
  function Get-QuotedPath([string]$Path) {
    $p = $Path -replace '\\', '/'
    if ($p -notmatch "'") { return "'$p'" }
    if ($p -match '[$`"]') { throw "Cannot quote this path for both Git Bash and PowerShell: $p" }
    return '"' + $p + '"'
  }

  if ($Uninstall) {
    $doc = Read-Settings
    $command = Get-StatusCommand $doc
    if ($command.Contains($marker)) {
      Set-StatusLine $doc '' $false
      Write-Settings (ConvertTo-SettingsText $doc)
      Write-Host "Removed the statusLine entry from $settingsPath"
    } elseif ($command -ne '') {
      Write-Host "Left the statusLine entry alone, it belongs to something else: $command"
    }
    if (Test-Path -LiteralPath $installDir) {
      Remove-Item -LiteralPath $installDir -Recurse -Force
      Write-Host "Removed $installDir"
    }
    return
  }

  $doc = Read-Settings
  $command = Get-StatusCommand $doc
  $ours = $command.Contains($marker)
  if ($command -ne '' -and -not $ours -and -not $Force) {
    throw "Another status line is configured in ${settingsPath}:`n  $command`nRe-run with -Force to replace it (the old entry is kept in $settingsPath.before-$name)."
  }

  $tmpScript = Join-Path ([IO.Path]::GetTempPath()) "$name-$PID.ps1"
  try {
    if ($env:CLAUDE_STATUSLINE_SOURCE) {
      Copy-Item -LiteralPath (Join-Path $env:CLAUDE_STATUSLINE_SOURCE 'statusline.ps1') -Destination $tmpScript -Force
    } elseif ($Version -eq '') {
      throw "This installer does not belong to a release. Use the one-liner from the README, or set CLAUDE_STATUSLINE_SOURCE to a checkout to install from there."
    } else {
      # Windows PowerShell 5.1 on an older .NET may still default to TLS 1.0.
      if ($PSVersionTable.PSVersion.Major -lt 6) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
      }
      $url = "https://github.com/$repo/releases/download/v$Version/statusline.ps1"
      Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $tmpScript
    }

    if ($Sha256 -ne '') {
      $actual = (Get-FileHash -LiteralPath $tmpScript -Algorithm SHA256).Hash.ToLowerInvariant()
      if ($actual -ne $Sha256) {
        throw "Checksum mismatch for statusline.ps1: expected $Sha256, got $actual. Nothing was changed."
      }
    }

    if (-not (Test-Path -LiteralPath $installDir)) { New-Item -ItemType Directory -Path $installDir | Out-Null }
    Copy-Item -LiteralPath $tmpScript -Destination $target -Force
  } finally {
    Remove-Item -LiteralPath $tmpScript -Force -ErrorAction SilentlyContinue
  }

  # powershell.exe is on every Windows; pwsh where Windows PowerShell does not exist.
  if ($onWindows) { $shell = 'powershell' } else { $shell = 'pwsh' }
  $newCommand = "$shell -NoProfile -ExecutionPolicy Bypass -File $(Get-QuotedPath $target)"
  Set-StatusLine $doc $newCommand $ours
  Write-Settings (ConvertTo-SettingsText $doc)

  # Proves the installed line runs here before claiming success.
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = (Get-Command $shell).Source
  $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$target`""
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.StandardOutputEncoding = $utf8
  $psi.EnvironmentVariables['NO_COLOR'] = '1'
  $psi.EnvironmentVariables.Remove('CLAUDE_STATUSLINE_SEGMENTS')
  $probe = [Diagnostics.Process]::Start($psi)
  $probe.StandardInput.Write('{"model":{"display_name":"ok"}}')
  $probe.StandardInput.Close()
  $output = $probe.StandardOutput.ReadToEnd().Trim()
  $probe.WaitForExit()
  if ($output -ne '[ok]') { throw "Installed, but a test run printed: $output" }

  $suffix = ''
  if ($Version) { $suffix = " $Version" }
  Write-Host "Installed $name$suffix to $target"
  Write-Host 'Claude Code picks up the new status line within a few seconds; restart it if not.'
}

Install-ClaudeUsageStatusline -Force $Force.IsPresent -Uninstall $Uninstall.IsPresent -Version $Version -Sha256 $Sha256
