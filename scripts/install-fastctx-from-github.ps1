[CmdletBinding()]
param(
  [string]$Repository = 'Fooljack/Fast-CTX',
  [string]$Tag = 'latest',
  [string]$GitBash,
  [string]$NativeHome,
  [string]$CodexHome,
  [string]$FastCtxHome,
  [string]$ClaudeConfigDir,
  [string]$ClaudeCommand,
  [switch]$VerifyOnly,
  [switch]$ForceBinary,
  [switch]$ForceMcpRegistration,
  [switch]$SkipClaudeCode,
  [string]$CcSwitchApps,
  [switch]$SkipCcSwitch,
  [switch]$NoLaunchCcSwitch,
  [switch]$RequireCcSwitch,
  [switch]$SkipMcpSmoke
)

$ErrorActionPreference = 'Stop'
$LogPrefix = '[fastctx-github-install]'

function Resolve-ProfilePath {
  param(
    [string]$Explicit,
    [string]$Ambient,
    [string]$Fallback,
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
$ArchiveName = 'fastctx-x86_64-pc-windows-msvc.zip'
$ManifestName = 'SHA256SUMS'
$temporaryRoot = $null

function Write-Log {
  param([Parameter(Mandatory = $true)][string]$Message)
  Write-Host "$LogPrefix $Message"
}

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

function Resolve-LatestReleaseTag {
  param(
    [Parameter(Mandatory = $true)][string]$RepositoryPath,
    [Parameter(Mandatory = $true)][hashtable]$Headers
  )
  $latestUri = "https://github.com/$RepositoryPath/releases/latest"
  $response = $null
  try {
    $response = Invoke-WebRequest -Uri $latestUri -Headers $Headers -MaximumRedirection 0 -TimeoutSec 30 -UseBasicParsing -ErrorAction Stop
  } catch {
    if ($null -ne $_.Exception.Response) {
      $response = $_.Exception.Response
    } else {
      throw "cannot resolve the latest FastCtx Release tag: $($_.Exception.Message)"
    }
  }
  $location = [string]$response.Headers['Location']
  if ([string]::IsNullOrWhiteSpace($location)) {
    throw 'GitHub latest Release response did not contain a redirect target'
  }
  $locationUri = if ([System.Uri]::IsWellFormedUriString($location, [System.UriKind]::Absolute)) {
    [System.Uri]$location
  } else {
    [System.Uri]::new([System.Uri]'https://github.com/', $location)
  }
  if ($locationUri.Scheme -cne 'https' -or $locationUri.Host -cne 'github.com') {
    throw "GitHub latest Release redirected to an unexpected host: $locationUri"
  }
  $prefix = "/$RepositoryPath/releases/tag/"
  if (-not $locationUri.AbsolutePath.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
    throw "GitHub latest Release returned an unexpected path: $($locationUri.AbsolutePath)"
  }
  $encodedTag = $locationUri.AbsolutePath.Substring($prefix.Length)
  if ([string]::IsNullOrWhiteSpace($encodedTag) -or $encodedTag.Contains('/')) {
    throw "GitHub latest Release returned an invalid tag path: $($locationUri.AbsolutePath)"
  }
  $resolvedTag = [System.Uri]::UnescapeDataString($encodedTag)
  if ($resolvedTag -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
    throw "GitHub latest Release returned an invalid tag: $resolvedTag"
  }
  return $resolvedTag
}

if (-not [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
  throw 'This repository-link installer supports Windows only.'
}
if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [System.Runtime.InteropServices.Architecture]::X64) {
  throw 'The published FastCtx Windows package supports x64 only.'
}
if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
  throw "invalid GitHub repository name: $Repository"
}
if ([string]::IsNullOrWhiteSpace($Tag)) { throw 'Tag cannot be empty.' }
if ($Tag -cne 'latest' -and $Tag -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
  throw "invalid GitHub Release tag: $Tag"
}

$previousProtocol = [System.Net.ServicePointManager]::SecurityProtocol
try {
  [System.Net.ServicePointManager]::SecurityProtocol = $previousProtocol -bor [System.Net.SecurityProtocolType]::Tls12
  $encodedRepository = $Repository.Split('/') | ForEach-Object { [System.Uri]::EscapeDataString($_) }
  $repositoryPath = $encodedRepository -join '/'
  $headers = @{ 'User-Agent' = 'Fooljack-FastCtx-Windows-Installer' }
  $resolvedTag = if ($Tag -ceq 'latest') {
    Resolve-LatestReleaseTag -RepositoryPath $repositoryPath -Headers $headers
  } else {
    $Tag
  }
  $releasePath = 'download/' + [System.Uri]::EscapeDataString($resolvedTag)
  $assetRoot = "https://github.com/$repositoryPath/releases/$releasePath"
  $archiveUrl = "$assetRoot/$ArchiveName"
  $manifestUrl = "$assetRoot/$ManifestName"
  $releaseLabel = if ($Tag -ceq 'latest') { "latest stable Release ($resolvedTag)" } else { "Release $resolvedTag" }
  Write-Log "downloading $releaseLabel from https://github.com/$Repository"
  $script:temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('fastctx-github-install-' + [guid]::NewGuid().ToString('N'))
  $archivePath = Join-Path $temporaryRoot $ArchiveName
  $manifestPath = Join-Path $temporaryRoot $ManifestName
  $extracted = Join-Path $temporaryRoot 'archive'
  New-Item -ItemType Directory -Force -Path $temporaryRoot, $extracted | Out-Null

  Invoke-WebRequest -Uri $manifestUrl -Headers $headers -OutFile $manifestPath -UseBasicParsing
  Invoke-WebRequest -Uri $archiveUrl -Headers $headers -OutFile $archivePath -UseBasicParsing

  $manifest = [System.IO.File]::ReadAllText($manifestPath, [System.Text.UTF8Encoding]::new($false, $true))
  $pattern = '(?m)^([0-9a-f]{64})  ' + [regex]::Escape($ArchiveName) + '\r?$'
  $entries = [regex]::Matches($manifest, $pattern)
  if ($entries.Count -ne 1) {
    throw "release SHA256SUMS must contain exactly one checksum for $ArchiveName"
  }
  $expected = $entries[0].Groups[1].Value
  $actual = Get-Sha256 $archivePath
  if ($actual -cne $expected) {
    throw "release archive SHA-256 mismatch: expected $expected, got $actual"
  }
  Write-Log "verified $ArchiveName from ${releaseLabel}: $actual"

  Expand-Archive -LiteralPath $archivePath -DestinationPath $extracted
  $installer = Join-Path $extracted 'install-fastctx-windows.ps1'
  if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
    throw "verified archive is missing install-fastctx-windows.ps1: $archivePath"
  }

  $parameters = @{
    NativeHome = $NativeHome
    CodexHome = $CodexHome
    FastCtxHome = $FastCtxHome
  }
  if ($GitBash) { $parameters.GitBash = $GitBash }
  if ($ClaudeConfigDir) { $parameters.ClaudeConfigDir = $ClaudeConfigDir }
  if ($ClaudeCommand) { $parameters.ClaudeCommand = $ClaudeCommand }
  if ($CcSwitchApps) { $parameters.CcSwitchApps = $CcSwitchApps }
  foreach ($name in @(
    'VerifyOnly', 'ForceBinary', 'ForceMcpRegistration', 'SkipClaudeCode',
    'SkipCcSwitch', 'NoLaunchCcSwitch', 'RequireCcSwitch', 'SkipMcpSmoke'
  )) {
    if ((Get-Variable -Name $name -ValueOnly)) { $parameters[$name] = $true }
  }
  & $installer @parameters
  Write-Log "FastCtx installation from $releaseLabel passed"
} finally {
  [System.Net.ServicePointManager]::SecurityProtocol = $previousProtocol
  if ($temporaryRoot -and (Test-Path -LiteralPath $temporaryRoot)) {
    $fullTemporary = [System.IO.Path]::GetFullPath($temporaryRoot)
    $tempPrefix = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $fullTemporary.StartsWith($tempPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "refusing to clean bootstrap path outside the system temp root: $fullTemporary"
    }
    Remove-Item -LiteralPath $fullTemporary -Recurse -Force -ErrorAction SilentlyContinue
  }
}
