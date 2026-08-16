[CmdletBinding()]
param(
  [string]$FastCtxBinary,
  [string]$GitBash,
  [string]$NativeHome,
  [string]$CodexHome,
  [string]$FastCtxHome,
  [string]$ClaudeConfigDir,
  [string]$ClaudeCommand,
  [switch]$BuildFromSource,
  [switch]$VerifyOnly,
  [switch]$ForceBinary,
  [switch]$ForceMcpRegistration,
  [switch]$SkipClaudeCode,
  [switch]$SkipCcSwitch,
  [string]$CcSwitchApps,
  [switch]$NoLaunchCcSwitch,
  [switch]$RequireCcSwitch,
  [switch]$SkipMcpSmoke
)

$ErrorActionPreference = 'Stop'
$LogPrefix = '[fastctx-windows-install]'

function Resolve-ProfilePath {
  param(
    [string]$Explicit,
    [string]$Ambient,
    [Parameter(Mandatory = $true)][string]$Fallback,
    [Parameter(Mandatory = $true)][string]$Name
  )
  $chosen = if (-not [string]::IsNullOrWhiteSpace($Explicit)) { $Explicit } elseif (-not [string]::IsNullOrWhiteSpace($Ambient)) { $Ambient } else { $Fallback }
  if ([string]::IsNullOrWhiteSpace($chosen)) { throw "$Name is required for a stable Windows FastCtx installation." }
  return [System.IO.Path]::GetFullPath($chosen)
}

$NativeHome = Resolve-ProfilePath -Explicit $NativeHome -Ambient $env:USERPROFILE -Fallback $env:USERPROFILE -Name 'NativeHome'
$CodexHome = Resolve-ProfilePath -Explicit $CodexHome -Ambient $env:CODEX_HOME -Fallback (Join-Path $NativeHome '.codex') -Name 'CodexHome'
$FastCtxHome = Resolve-ProfilePath -Explicit $FastCtxHome -Ambient $null -Fallback (Join-Path $NativeHome '.fastctx') -Name 'FastCtxHome'
if ($SkipCcSwitch -and $RequireCcSwitch) {
  throw 'SkipCcSwitch and RequireCcSwitch cannot be used together.'
}
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$configurator = Join-Path $PSScriptRoot 'configure-fastctx.ps1'
$agentIntegrator = Join-Path $PSScriptRoot 'configure-agent-integrations.ps1'
$ccSwitchHelper = Join-Path $PSScriptRoot 'configure-ccswitch-fastctx.ps1'
$smoke = Join-Path $PSScriptRoot 'verify-fastctx-mcp.ps1'
$flatGuidance = Join-Path $PSScriptRoot 'fastctx-agent-guidance.md'
$repositoryGuidance = Join-Path $repositoryRoot 'assets\fastctx-agent-guidance.md'
$flatBinary = Join-Path $PSScriptRoot 'fastctx.exe'
$repositoryBinary = Join-Path $repositoryRoot 'packages\fastctx-win32-x64\bin\fastctx.exe'
$flatChecksumFile = Join-Path $PSScriptRoot 'SHA256SUMS'
$repositoryChecksumFile = Join-Path $repositoryRoot 'checksums\SHA256SUMS'
$temporaryRoot = $null
$script:FlatChecksums = $null

function Write-Log {
  param([string]$Message)
  Write-Host "$LogPrefix $Message"
}

function Get-Sha256 {
  param([Parameter(Mandatory = $true)][string]$Path)
  $stream = [System.IO.File]::OpenRead($Path)
  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  try {
    return ([System.BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '')
  } finally {
    $sha256.Dispose()
    $stream.Dispose()
  }
}

function Assert-FlatPackageIntegrity {
  param([Parameter(Mandatory = $true)][string]$ManifestPath)
  $root = Split-Path -Parent $ManifestPath
  $items = @(Get-ChildItem -LiteralPath $root -Force)
  foreach ($item in $items) {
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "release package contains a reparse-point payload: $($item.Name)"
    }
    if ($item.PSIsContainer) {
      throw "release package must be flat and cannot contain a directory: $($item.Name)"
    }
  }
  $actualNames = @($items | Where-Object { $_.Name -cne 'SHA256SUMS' } | ForEach-Object { $_.Name } | Sort-Object)
  $bytes = [System.IO.File]::ReadAllBytes($ManifestPath)
  try {
    $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
  } catch {
    throw "release package SHA256SUMS is not valid UTF-8: $ManifestPath"
  }
  if ($text.Contains("`r")) { throw 'release package SHA256SUMS must use LF line endings' }
  if ($text.Length -eq 0) { throw 'release package SHA256SUMS cannot be empty' }
  $lines = @($text -split "`n")
  if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') {
    $lines = @($lines[0..($lines.Count - 2)])
  }
  $checksums = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::Ordinal)
  $caseInsensitiveNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($line in $lines) {
    if ($line -notmatch '^([0-9a-f]{64})  ([^/\\]+)$') {
      throw "invalid release package checksum line: $line"
    }
    $name = $Matches[2]
    if ($name -ceq 'SHA256SUMS' -or $name -eq '.' -or $name -eq '..') {
      throw "invalid release package checksum payload name: $name"
    }
    if ($checksums.ContainsKey($name) -or -not $caseInsensitiveNames.Add($name)) {
      throw "duplicate release package checksum entry: $name"
    }
    $checksums.Add($name, $Matches[1])
  }
  $manifestNames = @($checksums.Keys | Sort-Object)
  if ((Compare-Object -ReferenceObject $actualNames -DifferenceObject $manifestNames -CaseSensitive).Count -ne 0) {
    throw 'release package checksum set does not exactly cover every flat payload file'
  }
  foreach ($name in $actualNames) {
    $path = Join-Path $root $name
    if ((Get-Sha256 $path).ToLowerInvariant() -cne $checksums[$name]) {
      throw "release package SHA-256 mismatch: $name"
    }
  }
  Write-Log "authenticated every flat release payload: $($actualNames.Count) files"
  return $checksums
}

function Get-BundledBinary {
  if (Test-Path -LiteralPath $flatBinary -PathType Leaf) {
    return [pscustomobject]@{
      Binary = [System.IO.Path]::GetFullPath($flatBinary)
      ChecksumFile = $flatChecksumFile
      ManifestPath = 'fastctx.exe'
      Layout = 'release archive'
    }
  }
  if (Test-Path -LiteralPath $repositoryBinary -PathType Leaf) {
    return [pscustomobject]@{
      Binary = [System.IO.Path]::GetFullPath($repositoryBinary)
      ChecksumFile = $repositoryChecksumFile
      ManifestPath = 'packages/fastctx-win32-x64/bin/fastctx.exe'
      Layout = 'repository checkout'
    }
  }
  return $null
}

function Get-BundledSha256 {
  param([Parameter(Mandatory = $true)]$Bundle)
  if ($Bundle.Layout -ceq 'release archive' -and $null -ne $script:FlatChecksums) {
    if (-not $script:FlatChecksums.ContainsKey($Bundle.ManifestPath)) {
      throw "bundled FastCtx checksum is missing for $($Bundle.ManifestPath)"
    }
    return $script:FlatChecksums[$Bundle.ManifestPath].ToUpperInvariant()
  }
  if (-not (Test-Path -LiteralPath $Bundle.ChecksumFile -PathType Leaf)) {
    throw "bundled checksum manifest is missing: $($Bundle.ChecksumFile)"
  }
  foreach ($line in (Get-Content -LiteralPath $Bundle.ChecksumFile)) {
    if ($line -match '^([0-9A-Fa-f]{64})\s+\*?(.+)$') {
      $path = $Matches[2].Trim().Replace('\', '/')
      if ($path -eq $Bundle.ManifestPath) { return $Matches[1].ToUpperInvariant() }
    }
  }
  throw "bundled FastCtx checksum is missing for $($Bundle.ManifestPath) in $($Bundle.ChecksumFile)"
}

function Build-FastCtxRelease {
  $manifest = Join-Path $repositoryRoot 'Cargo.toml'
  if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
    throw 'Source compilation requires a FastCtx repository checkout containing Cargo.toml; it is not available in the release archive.'
  }
  $cargo = Get-Command cargo.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $cargo) {
    throw 'Source compilation was explicitly requested, but cargo.exe was not found. Install Rust 1.88+ or use the prebuilt Windows release archive.'
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
    & $cargo.Source build --locked --release --manifest-path $manifest
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
$flatBinaryExists = Test-Path -LiteralPath $flatBinary -PathType Leaf
$flatManifestExists = Test-Path -LiteralPath $flatChecksumFile -PathType Leaf
if ($flatBinaryExists -or $flatManifestExists) {
  if (-not $flatBinaryExists -or -not $flatManifestExists) {
    throw 'flat release package must contain both fastctx.exe and SHA256SUMS'
  }
  $script:FlatChecksums = Assert-FlatPackageIntegrity -ManifestPath $flatChecksumFile
}
foreach ($required in @($configurator, $agentIntegrator, $ccSwitchHelper, $smoke)) {
  if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
    throw "FastCtx Windows installer file is missing: $required"
  }
}
if (-not (Test-Path -LiteralPath $flatGuidance -PathType Leaf) -and
    -not (Test-Path -LiteralPath $repositoryGuidance -PathType Leaf)) {
  throw 'FastCtx agent guidance template is missing from the installer.'
}
if ([string]::IsNullOrWhiteSpace($NativeHome)) {
  throw 'NativeHome is required for a stable user-level installation.'
}

try {
  $stableBinary = Join-Path ([System.IO.Path]::GetFullPath($FastCtxHome)) 'bin\fastctx.exe'
  $bundle = Get-BundledBinary
  $commonParams = @{
    NativeHome = $NativeHome
    CodexHome = $CodexHome
    FastCtxHome = $FastCtxHome
  }
  if ($GitBash) { $commonParams.GitBash = $GitBash }
  if ($ClaudeConfigDir) { $commonParams.ClaudeConfigDir = $ClaudeConfigDir }
  if ($ClaudeCommand) { $commonParams.ClaudeCommand = $ClaudeCommand }
  if ($SkipClaudeCode) { $commonParams.SkipClaudeCode = $true }
  if ($SkipCcSwitch) { $commonParams.SkipCcSwitch = $true }
  if ($CcSwitchApps) { $commonParams.CcSwitchApps = $CcSwitchApps }
  if ($NoLaunchCcSwitch) { $commonParams.NoLaunchCcSwitch = $true }
  if ($RequireCcSwitch) { $commonParams.RequireCcSwitch = $true }
  if ($ForceMcpRegistration) { $commonParams.ForceMcpRegistration = $true }

  if ($VerifyOnly) {
    $verifyParams = @{} + $commonParams
    $verifyParams.VerifyOnly = $true
    if ($bundle) { $verifyParams.ExpectedSha256 = Get-BundledSha256 -Bundle $bundle }
    & $configurator @verifyParams
  } else {
    $source = $null
    $expected = $null
    if ($FastCtxBinary) {
      $source = (Resolve-Path -LiteralPath $FastCtxBinary -ErrorAction Stop).Path
      $expected = Get-Sha256 $source
      Write-Log "using explicit FastCtx binary: $source"
    } elseif ($bundle -and -not $BuildFromSource) {
      $source = $bundle.Binary
      $expected = Get-BundledSha256 -Bundle $bundle
      Write-Log "using prebuilt FastCtx binary from $($bundle.Layout): $source"
    } elseif ($BuildFromSource) {
      $source = Build-FastCtxRelease
      $expected = Get-Sha256 $source
      Write-Log "using explicitly requested local source build: $source"
    } else {
      throw 'No prebuilt FastCtx binary was found. Download and extract the Windows x64 release archive, pass -FastCtxBinary, or explicitly use -BuildFromSource in a repository checkout.'
    }

    $configureParams = @{} + $commonParams
    $configureParams.FastCtxBinary = $source
    $configureParams.ExpectedSha256 = $expected
    if ($ForceBinary) { $configureParams.ForceBinary = $true }
    & $configurator @configureParams
  }

  if (-not $SkipMcpSmoke) {
    $smokeParams = @{ FastCtxBinary = $stableBinary }
    if ($GitBash) { $smokeParams.GitBash = $GitBash }
    & $smoke @smokeParams
  }
  Write-Log 'installation and verification passed; restart installed MCP clients to load FastCtx and global guidance'
  if (-not $SkipCcSwitch -and -not $NoLaunchCcSwitch) {
    Write-Log 'if a CC Switch confirmation opened, review it and click Import to finish its application sync'
  }
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
