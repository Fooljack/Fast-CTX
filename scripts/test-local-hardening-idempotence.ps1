[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$TemporaryRoot
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillRoot = Split-Path -Parent $scriptRoot
$temp = [System.IO.Path]::GetFullPath($TemporaryRoot)
New-Item -ItemType Directory -Force -Path $temp | Out-Null
$fixtureRoot = Join-Path $temp ('local-hardening-' + [guid]::NewGuid().ToString('N'))

function Invoke-Overlay {
  param([switch]$AllowFailure)
  $overlay = Join-Path $fixtureRoot 'scripts\apply-local-hardening.ps1'
  $previousErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = @(
      & powershell -NoProfile -ExecutionPolicy Bypass -File $overlay -SkillDir $fixtureRoot 2>&1
    )
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }
  if ($exitCode -ne 0 -and -not $AllowFailure) {
    throw "local hardening fixture failed: $($output -join [Environment]::NewLine)"
  }
  return [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
}

function Get-FixtureHashes {
  $hashes = [ordered]@{}
  foreach ($file in Get-ChildItem -LiteralPath $fixtureRoot -Recurse -File | Sort-Object FullName) {
    $relative = $file.FullName.Substring($fixtureRoot.Length).TrimStart('\')
    $hashes[$relative] = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash
  }
  return $hashes
}

try {
  New-Item -ItemType Directory -Force -Path @(
    (Join-Path $fixtureRoot 'scripts'),
    (Join-Path $fixtureRoot 'references')
  ) | Out-Null
  Copy-Item -LiteralPath (Join-Path $skillRoot 'SKILL.md') -Destination (Join-Path $fixtureRoot 'SKILL.md')
  Copy-Item -LiteralPath (Join-Path $skillRoot 'references\restriction-debug-cases.md') `
    -Destination (Join-Path $fixtureRoot 'references\restriction-debug-cases.md')
  Copy-Item -Path (Join-Path $skillRoot 'scripts\*') -Destination (Join-Path $fixtureRoot 'scripts') -Recurse

  [void](Invoke-Overlay)
  $computerUsePatcher = Join-Path $fixtureRoot 'scripts\patch_codex_fast_mode_windows_msix.ps1'
  $patcherContent = [System.IO.File]::ReadAllText($computerUsePatcher, [System.Text.UTF8Encoding]::new($false))
  $hasFilePattern = '(?ms)(const \[availabilityFile, installFlowFile, setupFile\] = process\.argv\.slice\(2\);\s*let changed = false;\s*function read\(file\) \{\s*return fs\.readFileSync\(file, ''utf8''\);\s*\}\s*)function hasFile\(file\) \{\s*return typeof file === ''string'' && file\.length > 0 && file !== ''__none__'' && fs\.existsSync\(file\);\s*\}\s*'
  $withoutHelper = [regex]::Replace($patcherContent, $hasFilePattern, '$1', 1)
  if ($withoutHelper -eq $patcherContent) {
    throw 'fixture lacks the generated Computer Use hasFile helper'
  }
  [System.IO.File]::WriteAllText($computerUsePatcher, $withoutHelper, [System.Text.UTF8Encoding]::new($false))
  [void](Invoke-Overlay)
  $repairedPatcher = [System.IO.File]::ReadAllText($computerUsePatcher, [System.Text.UTF8Encoding]::new($false))
  if (-not [regex]::IsMatch($repairedPatcher, $hasFilePattern)) {
    throw 'local hardening did not restore the generated Computer Use hasFile helper'
  }

  $repatchWrapper = Join-Path $fixtureRoot 'scripts\repatch-codex-windows.ps1'
  $repatchContent = ([System.IO.File]::ReadAllText($repatchWrapper, [System.Text.UTF8Encoding]::new($false)) -replace "\r?\n", "`r`n")
  $legacyInvokeChecked = @'
function Invoke-Checked {
  param(
    [string]$FilePath,
    [string[]]$Arguments,
    [string]$ErrorMessage
  )

  Write-Log "$FilePath $($Arguments -join ' ')"
  & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$ErrorMessage (exit code $LASTEXITCODE)"
  }
}
'@
  $withoutFinalizerGuard = [regex]::Replace(
    $repatchContent,
    '(?ms)^function Invoke-Checked \{.*?^\}\r?\n\s*(?=function Write-Utf8NoBom)',
    { param($match) $legacyInvokeChecked.TrimEnd() + "`r`n" },
    1
  )
  $withoutFinalizerGuard = [regex]::Replace(
    $withoutFinalizerGuard,
    '(?ms)^function Test-CompletedMsixFinalizerCrash \{.*?^\}\r?\n\s*(?=function )',
    '',
    1
  )
  $withoutFinalizerGuard = $withoutFinalizerGuard.Replace(' -AllowCompletedMsixFinalizerCrash', '')
  if ($withoutFinalizerGuard -eq $repatchContent -or $withoutFinalizerGuard.Contains('function Test-CompletedMsixFinalizerCrash')) {
    throw 'fixture failed to remove the MSIX finalizer crash guard'
  }
  [System.IO.File]::WriteAllText($repatchWrapper, $withoutFinalizerGuard, [System.Text.UTF8Encoding]::new($false))
  [void](Invoke-Overlay)
  $repairedRepatch = [System.IO.File]::ReadAllText($repatchWrapper, [System.Text.UTF8Encoding]::new($false))
  foreach ($requiredFinalizerGuardMarker in @(
    'function Test-CompletedMsixFinalizerCrash',
    'request wire service_tier=priority',
    'accepted known WinRT finalizer crash after verified Developer install and Fast wire capture',
    '-AllowCompletedMsixFinalizerCrash'
  )) {
    if (-not $repairedRepatch.Contains($requiredFinalizerGuardMarker)) {
      throw "local hardening did not restore the MSIX finalizer crash guard marker: $requiredFinalizerGuardMarker"
    }
  }

  $first = Get-FixtureHashes
  [void](Invoke-Overlay)
  $second = Get-FixtureHashes
  if (($first.Keys -join "`n") -cne ($second.Keys -join "`n")) {
    throw 'local hardening changed the fixture file set on its second run'
  }
  foreach ($path in $first.Keys) {
    if ($first[$path] -cne $second[$path]) {
      throw "local hardening is not idempotent: $path"
    }
  }

  $patcher = Join-Path $fixtureRoot 'scripts\patch_codex_fast_mode_windows_msix.ps1'
  $content = [System.IO.File]::ReadAllText($patcher, [System.Text.UTF8Encoding]::new($false))
  $current = '  $exe = Get-AppExecutablePath $workPackageRoot'
  $unknown = '  $exe = Get-UnknownExecutablePath $workPackageRoot'
  if (-not $content.Contains($current)) {
    throw 'fixture lacks the current work-package executable marker'
  }
  [System.IO.File]::WriteAllText(
    $patcher,
    $content.Replace($current, $unknown),
    [System.Text.UTF8Encoding]::new($false)
  )
  $drift = Invoke-Overlay -AllowFailure
  $driftText = ($drift.Output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
  if ($drift.ExitCode -eq 0 -or $driftText -notmatch 'unknown or ambiguous Desktop work-package executable lookup shape') {
    throw "local hardening did not reject an unknown executable shape: $driftText"
  }

  Write-Output 'Local hardening idempotence and drift rejection regression passed'
} finally {
  if (Test-Path -LiteralPath $fixtureRoot) {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
