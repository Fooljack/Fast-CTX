[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$wrapper = Join-Path $scriptRoot 'run-latest-fast-patch.ps1'
$wrapperText = Get-Content -LiteralPath $wrapper -Raw
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
  $wrapper,
  [ref]$tokens,
  [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
  throw "run-latest-fast-patch.ps1 does not parse: $($parseErrors.Message -join '; ')"
}

function Get-FunctionAst {
  param([Parameter(Mandatory = $true)][string]$Name)
  $functionAst = $ast.Find({
      param($node)
      $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $true)
  if (-not $functionAst) {
    throw "missing wrapper function: $Name"
  }
  return $functionAst
}

$eligibility = (Get-FunctionAst 'Get-PublishEligibilityBlockers').Body.GetScriptBlock()

function Assert-EligibilityBlockers {
  param(
    [bool]$DryRun,
    [bool]$NoDesktopLaunch,
    [bool]$SkipWireVerification,
    [string[]]$Expected
  )

  $DryRunOnly = $DryRun
  $NoLaunch = $NoDesktopLaunch
  $SkipFastVerify = $SkipWireVerification
  $actual = @(& $eligibility)
  if (($actual -join "`n") -cne ($Expected -join "`n")) {
    throw "unexpected publish blockers: expected=[$($Expected -join '; ')] actual=[$($actual -join '; ')]"
  }
}

Assert-EligibilityBlockers $false $false $false @()
Assert-EligibilityBlockers $true $false $false @('-DryRunOnly was used')
Assert-EligibilityBlockers $false $true $false @('-NoLaunch was used')
Assert-EligibilityBlockers $false $false $true @('-SkipFastVerify was used')
Assert-EligibilityBlockers $true $true $true @(
  '-DryRunOnly was used',
  '-NoLaunch was used',
  '-SkipFastVerify was used'
)

$publishText = (Get-FunctionAst 'Publish-VerifiedChain').Extent.Text
$eligibilityIndex = $publishText.IndexOf('Get-PublishEligibilityBlockers', [StringComparison]::Ordinal)
$publishScriptIndex = $publishText.IndexOf('publish-verified-chain.ps1', [StringComparison]::Ordinal)
if ($eligibilityIndex -lt 0 -or $publishScriptIndex -lt 0 -or $eligibilityIndex -gt $publishScriptIndex) {
  throw 'publish eligibility is not checked before invoking publish-verified-chain.ps1'
}
if (-not $publishText.Contains('-not $PublishOnProblems')) {
  throw 'publish eligibility does not preserve the explicit -PublishOnProblems override'
}

$completeText = (Get-FunctionAst 'Complete-Run').Extent.Text
if (-not $completeText.Contains('pending publish eligibility check')) {
  throw 'Complete-Run does not record a pending state before publication'
}
if ($completeText.Contains("`$script:ArchiveResult = 'archived'")) {
  throw 'Complete-Run still reports archived before publication succeeds'
}

$finalCleanupPattern = '(?ms)\$finalArgs = @\(''-DryRun'', ''-ForceRebuild''\)\s*if \(-not \$KeepBuild\) \{\s*\$finalArgs \+= ''-CleanupAfter''\s*\}'
if ([regex]::Matches($wrapperText, $finalCleanupPattern).Count -ne 2) {
  throw 'both final Fast verification paths must clean their temporary MSIX build root unless -KeepBuild is explicit'
}

Write-Output 'Run-latest publish eligibility regression passed'
