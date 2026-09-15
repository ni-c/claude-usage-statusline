# Runs the Pester suites with a pinned Pester, in whichever PowerShell starts it:
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1
#   pwsh -NoProfile -File tests/Invoke-Tests.ps1

$ErrorActionPreference = 'Stop'
$pester = '5.9.1'

"PowerShell $($PSVersionTable.PSVersion) on $([Environment]::OSVersion.VersionString)"
if (-not (Get-Module -ListAvailable Pester | Where-Object { $_.Version -eq $pester })) {
  if ($PSVersionTable.PSVersion.Major -lt 6) {
    # PowerShellGet on Windows PowerShell 5.1 does not ask the gallery for TLS 1.2
    # by itself, and the gallery answers anything older with "no match was found".
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Install-PackageProvider NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
  }
  Install-Module Pester -RequiredVersion $pester -Repository PSGallery -Force -Scope CurrentUser -SkipPublisherCheck
}
Import-Module Pester -RequiredVersion $pester

$result = Invoke-Pester -Path $PSScriptRoot -Output Detailed -PassThru
if ($result.Result -ne 'Passed') { exit 1 }
