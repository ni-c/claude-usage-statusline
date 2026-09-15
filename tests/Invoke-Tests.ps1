# Runs the Pester suites with a pinned Pester, in whichever PowerShell starts it:
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1
#   pwsh -NoProfile -File tests/Invoke-Tests.ps1

$ErrorActionPreference = 'Stop'
$pester = '5.9.1'

"PowerShell $($PSVersionTable.PSVersion) on $([Environment]::OSVersion.VersionString)"
if (-not (Get-Module -ListAvailable Pester | Where-Object { $_.Version -eq $pester })) {
  Install-Module Pester -RequiredVersion $pester -Force -Scope CurrentUser -SkipPublisherCheck
}
Import-Module Pester -RequiredVersion $pester

$result = Invoke-Pester -Path $PSScriptRoot -Output Detailed -PassThru
if ($result.Result -ne 'Passed') { exit 1 }
