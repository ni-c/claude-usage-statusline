@{
  Severity     = @('Error', 'Warning')
  ExcludeRules = @(
    # The installer talks to a person at a console; Write-Host is the right stream.
    'PSAvoidUsingWriteHost',
    # Internal helpers of a one-shot script, not cmdlets anyone calls with -WhatIf.
    'PSUseShouldProcessForStateChangingFunctions',
    'PSUseSingularNouns'
  )
}
