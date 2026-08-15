[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Archive,
  [string]$TemporaryRoot = ([System.IO.Path]::GetTempPath())
)

$ErrorActionPreference = 'Stop'

function Get-Sha256 {
  param([Parameter(Mandatory = $true)][string]$Path)
  $stream = [System.IO.File]::OpenRead($Path)
  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  try {
    return ([System.BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
  } finally {
    $sha256.Dispose()
    $stream.Dispose()
  }
}

function Assert-TamperedPayloadRejected {
  param(
    [Parameter(Mandatory = $true)][string]$PayloadName,
    [Parameter(Mandatory = $true)][string]$Label
  )
  $tampered = Join-Path $root "tampered-$Label"
  $tamperedHome = Join-Path $tampered 'home'
  New-Item -ItemType Directory -Force -Path $tampered | Out-Null
  Get-ChildItem -LiteralPath $extracted -File | Copy-Item -Destination $tampered -Force
  $payloadPath = Join-Path $tampered $PayloadName
  [System.IO.File]::AppendAllText($payloadPath, "`n# tampered payload`n", [System.Text.UTF8Encoding]::new($false))
  $tamperedInstaller = Join-Path $tampered 'install-fastctx-windows.ps1'
  $rejected = $false
  try {
    & $tamperedInstaller `
      -NativeHome $tamperedHome `
      -CodexHome (Join-Path $tamperedHome '.codex') `
      -FastCtxHome (Join-Path $tamperedHome '.fastctx') `
      -SkipClaudeCode `
      -NoLaunchCcSwitch `
      -SkipMcpSmoke
  } catch {
    $rejected = $_.Exception.Message -match 'release package SHA-256 mismatch' -and
      $_.Exception.Message -match [regex]::Escape($PayloadName)
  }
  if (-not $rejected) { throw "release installer accepted a tampered $Label payload" }
  if (Test-Path -LiteralPath $tamperedHome) { throw "tampered $Label package created an installation root before authentication" }
}

if (-not [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
  throw 'The Windows release installer contract must run on Windows.'
}
$archivePath = (Resolve-Path -LiteralPath $Archive -ErrorAction Stop).Path
$root = Join-Path ([System.IO.Path]::GetFullPath($TemporaryRoot)) ('fastctx-release-install-' + [guid]::NewGuid().ToString('N'))
$extracted = Join-Path $root 'archive'
$fixtureHome = Join-Path $root 'home'
$savedIdle = [Environment]::GetEnvironmentVariable('FASTCTX_TEST_RUNTIME_IDLE_MS', 'Process')
$savedBuild = [Environment]::GetEnvironmentVariable('FASTCTX_TEST_BUILD_ID', 'Process')

try {
  New-Item -ItemType Directory -Force -Path $extracted, $fixtureHome | Out-Null
  Expand-Archive -LiteralPath $archivePath -DestinationPath $extracted
  $manifest = Join-Path $extracted 'SHA256SUMS'
  if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { throw 'release archive is missing SHA256SUMS' }
  foreach ($line in (Get-Content -LiteralPath $manifest)) {
    if ($line -notmatch '^([0-9a-f]{64})  ([^/\\]+)$') { throw "invalid archive checksum line: $line" }
    $payload = Join-Path $extracted $Matches[2]
    if (-not (Test-Path -LiteralPath $payload -PathType Leaf)) { throw "archive checksum payload is missing: $($Matches[2])" }
    if ((Get-Sha256 $payload) -cne $Matches[1]) { throw "archive checksum mismatch: $($Matches[2])" }
  }

  $installer = Join-Path $extracted 'install-fastctx-windows.ps1'
  $codexHome = Join-Path $fixtureHome '.codex'
  $fastctxHome = Join-Path $fixtureHome '.fastctx'
  [Environment]::SetEnvironmentVariable('FASTCTX_TEST_RUNTIME_IDLE_MS', '300', 'Process')
  [Environment]::SetEnvironmentVariable('FASTCTX_TEST_BUILD_ID', 'release-install-' + [guid]::NewGuid().ToString('N'), 'Process')
  $installParams = @{
    NativeHome = $fixtureHome
    CodexHome = $codexHome
    FastCtxHome = $fastctxHome
    SkipClaudeCode = $true
    NoLaunchCcSwitch = $true
  }
  & $installer @installParams
  & $installer @installParams -VerifyOnly

  $stableBinary = Join-Path $fastctxHome 'bin\fastctx.exe'
  $agents = Join-Path $codexHome 'AGENTS.md'
  if (-not (Test-Path -LiteralPath $stableBinary -PathType Leaf)) { throw 'release installer did not publish the stable binary' }
  if (-not (Test-Path -LiteralPath $agents -PathType Leaf)) { throw 'release installer did not create Codex global guidance' }
  $agentsText = [System.IO.File]::ReadAllText($agents, [System.Text.UTF8Encoding]::new($true))
  if ([regex]::Matches($agentsText, [regex]::Escape('<!-- fastctx:begin -->')).Count -ne 1 -or
      -not $agentsText.Contains('three consecutive, reasonable FastCtx attempts')) {
    throw 'release installer did not apply the exact managed guidance contract'
  }
  Assert-TamperedPayloadRejected -PayloadName 'configure-agent-integrations.ps1' -Label 'helper'
  Assert-TamperedPayloadRejected -PayloadName 'fastctx-agent-guidance.md' -Label 'guidance'
  Write-Output 'FastCtx flat Windows release install, VerifyOnly, and internal payload-authentication contract passed'
} finally {
  [Environment]::SetEnvironmentVariable('FASTCTX_TEST_RUNTIME_IDLE_MS', $savedIdle, 'Process')
  [Environment]::SetEnvironmentVariable('FASTCTX_TEST_BUILD_ID', $savedBuild, 'Process')
  Start-Sleep -Milliseconds 1000
  for ($attempt = 1; $attempt -le 20 -and (Test-Path -LiteralPath $root); $attempt++) {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $root) { Start-Sleep -Milliseconds 250 }
  }
  if (Test-Path -LiteralPath $root) { throw "test fixture could not be cleaned: $root" }
}
