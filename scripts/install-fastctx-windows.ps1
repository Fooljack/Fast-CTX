[CmdletBinding()]
param(
  [string]$FastCtxBinary,
  [string]$GitBash,
  [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
  [string]$FastCtxHome = (Join-Path $env:USERPROFILE '.fastctx'),
  [switch]$BuildFromSource,
  [switch]$VerifyOnly,
  [switch]$ForceBinary,
  [switch]$SkipMcpSmoke
)

$ErrorActionPreference = 'Stop'
$LogPrefix = '[fastctx-windows-install]'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$configurator = Join-Path $PSScriptRoot 'configure-fastctx.ps1'
$smoke = Join-Path $PSScriptRoot 'verify-fastctx-mcp.ps1'
$bundledBinary = Join-Path $repositoryRoot 'packages\fastctx-win32-x64\bin\fastctx.exe'
$checksumFile = Join-Path $repositoryRoot 'checksums\SHA256SUMS'
$temporaryRoot = $null

function Write-Log {
  param([string]$Message)
  Write-Host "$LogPrefix $Message"
}

function Get-BundledSha256 {
  if (-not (Test-Path -LiteralPath $checksumFile -PathType Leaf)) {
    throw "bundled checksum manifest is missing: $checksumFile"
  }
  $relative = 'packages/fastctx-win32-x64/bin/fastctx.exe'
  foreach ($line in (Get-Content -LiteralPath $checksumFile)) {
    if ($line -match '^([0-9A-Fa-f]{64})\s+\*?(.+)$') {
      $path = $Matches[2].Trim().Replace('\', '/')
      if ($path -eq $relative) { return $Matches[1].ToUpperInvariant() }
    }
  }
  throw "bundled FastCtx checksum is missing from $checksumFile"
}

function Build-FastCtxRelease {
  $cargo = Get-Command cargo.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $cargo) {
    throw 'The bundled Windows binary is unavailable and cargo.exe was not found. Install Rust 1.88+ or use a checkout that includes the bundled binary.'
  }
  $versionOutput = (& $cargo.Source --version 2>&1 | Out-String).Trim()
  if ($LASTEXITCODE -ne 0 -or $versionOutput -notmatch '^cargo\s+(\d+)\.(\d+)\.') {
    throw "cargo version check failed: $versionOutput"
  }
  if ([int]$Matches[1] -lt 1 -or ([int]$Matches[1] -eq 1 -and [int]$Matches[2] -lt 88)) {
    throw "Rust 1.88 or newer is required; found $versionOutput"
  }

  $script:temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('fastctx-source-build-' + [guid]::NewGuid().ToString('N'))
  $target = Join-Path $script:temporaryRoot 'target'
  New-Item -ItemType Directory -Force -Path $target | Out-Null
  $previousTarget = [Environment]::GetEnvironmentVariable('CARGO_TARGET_DIR', 'Process')
  try {
    [Environment]::SetEnvironmentVariable('CARGO_TARGET_DIR', $target, 'Process')
    & $cargo.Source build --locked --release --manifest-path (Join-Path $repositoryRoot 'Cargo.toml')
    if ($LASTEXITCODE -ne 0) { throw "cargo release build failed with exit code $LASTEXITCODE" }
  } finally {
    [Environment]::SetEnvironmentVariable('CARGO_TARGET_DIR', $previousTarget, 'Process')
  }
  $built = Join-Path $target 'release\fastctx.exe'
  if (-not (Test-Path -LiteralPath $built -PathType Leaf)) {
    throw "cargo did not produce the expected binary: $built"
  }
  return $built
}

if (-not [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
  throw 'This installer supports Windows only.'
}
if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [System.Runtime.InteropServices.Architecture]::X64) {
  throw 'The bundled FastCtx binary supports Windows x64 only.'
}
if (-not (Test-Path -LiteralPath $configurator -PathType Leaf) -or -not (Test-Path -LiteralPath $smoke -PathType Leaf)) {
  throw 'FastCtx Windows installer files are incomplete.'
}

try {
  $stableBinary = Join-Path ([System.IO.Path]::GetFullPath($FastCtxHome)) 'bin\fastctx.exe'
  if ($VerifyOnly) {
    $expected = if (Test-Path -LiteralPath $bundledBinary -PathType Leaf) { Get-BundledSha256 } else { $null }
    $verifyParams = @{
      CodexHome = $CodexHome
      FastCtxHome = $FastCtxHome
      VerifyOnly = $true
    }
    if ($GitBash) { $verifyParams.GitBash = $GitBash }
    if ($expected) { $verifyParams.ExpectedSha256 = $expected }
    & $configurator @verifyParams
  } else {
    $source = $null
    $expected = $null
    if ($FastCtxBinary) {
      $source = (Resolve-Path -LiteralPath $FastCtxBinary -ErrorAction Stop).Path
      $expected = (Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash
    } elseif (-not $BuildFromSource -and (Test-Path -LiteralPath $bundledBinary -PathType Leaf)) {
      $source = $bundledBinary
      $expected = Get-BundledSha256
    } else {
      $source = Build-FastCtxRelease
      $expected = (Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash
    }

    $configureParams = @{
      FastCtxBinary = $source
      CodexHome = $CodexHome
      FastCtxHome = $FastCtxHome
      ExpectedSha256 = $expected
    }
    if ($GitBash) { $configureParams.GitBash = $GitBash }
    if ($ForceBinary) { $configureParams.ForceBinary = $true }
    & $configurator @configureParams
  }

  if (-not $SkipMcpSmoke) {
    $smokeParams = @{ FastCtxBinary = $stableBinary }
    if ($GitBash) { $smokeParams.GitBash = $GitBash }
    & $smoke @smokeParams
  }
  Write-Log 'installation and verification passed; restart Codex Desktop to load the MCP server'
} finally {
  if ($temporaryRoot -and (Test-Path -LiteralPath $temporaryRoot)) {
    $fullTemporary = [System.IO.Path]::GetFullPath($temporaryRoot)
    $tempPrefix = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $fullTemporary.StartsWith($tempPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "refusing to clean build path outside the system temp root: $fullTemporary"
    }
    Remove-Item -LiteralPath $fullTemporary -Recurse -Force -ErrorAction SilentlyContinue
  }
}
