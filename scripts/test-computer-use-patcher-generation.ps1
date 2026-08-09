[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$TemporaryRoot
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$patcherSourcePath = Join-Path $scriptRoot 'patch_codex_fast_mode_windows_msix.ps1'
$node = Get-Command node.exe -ErrorAction Stop | Select-Object -First 1
$temp = [System.IO.Path]::GetFullPath($TemporaryRoot)
New-Item -ItemType Directory -Force -Path $temp | Out-Null
$fixtureRoot = Join-Path $temp ('computer-use-patcher-' + [guid]::NewGuid().ToString('N'))

try {
  New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null
  $source = [System.IO.File]::ReadAllText($patcherSourcePath, [System.Text.UTF8Encoding]::new($false))
  $match = [regex]::Match(
    $source,
    '(?ms)Set-Content -LiteralPath \$computerUsePatcherPath -Encoding UTF8 -Value @''\r?\n(?<script>.*?)\r?\n''@\r?\n\s*Set-Content -LiteralPath \$browserUsePatcherPath'
  )
  if (-not $match.Success) {
    throw 'could not extract the generated Computer Use patcher from the MSIX patch script'
  }

  $generated = $match.Groups['script'].Value
  if (-not [regex]::IsMatch($generated, '(?ms)function hasFile\(file\) \{\s*return typeof file === ''string'' && file\.length > 0 && file !== ''__none__'' && fs\.existsSync\(file\);')) {
    throw 'generated Computer Use patcher is missing the safe hasFile helper'
  }

  $patcherPath = Join-Path $fixtureRoot 'PatchComputerUseGates.cjs'
  $availabilityPath = Join-Path $fixtureRoot 'availability.js'
  $setupPath = Join-Path $fixtureRoot 'setup.js'
  [System.IO.File]::WriteAllText($patcherPath, $generated, [System.Text.UTF8Encoding]::new($false))
  [System.IO.File]::WriteAllText($availabilityPath, 'featureName:`computer_use`,foo:!0;let a={enabled:!0,isLoading:!1},', [System.Text.UTF8Encoding]::new($false))
  [System.IO.File]::WriteAllText($setupPath, 'showComputerUseSetup', [System.Text.UTF8Encoding]::new($false))

  $checkOutput = @(& $node.Source --check $patcherPath 2>&1)
  if ($LASTEXITCODE -ne 0) {
    throw "generated Computer Use patcher fails node --check: $($checkOutput -join [Environment]::NewLine)"
  }

  $output = @(& $node.Source $patcherPath $availabilityPath '__none__' $setupPath 2>&1)
  if ($LASTEXITCODE -ne 0) {
    throw "generated Computer Use patcher failed with no install-flow file: $($output -join [Environment]::NewLine)"
  }
  if ((($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim() -ne 'already-patched') {
    throw "generated Computer Use patcher returned unexpected output: $($output -join [Environment]::NewLine)"
  }

  Write-Output 'Computer Use generated patcher regression passed'
} finally {
  if (Test-Path -LiteralPath $fixtureRoot) {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
