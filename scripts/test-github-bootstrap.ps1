[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Archive,
  [string]$TemporaryRoot = ([System.IO.Path]::GetTempPath())
)

$ErrorActionPreference = 'Stop'
$Bootstrap = Join-Path $PSScriptRoot 'install-fastctx-from-github.ps1'
$ArchivePath = (Resolve-Path -LiteralPath $Archive -ErrorAction Stop).Path
$global:FastCtxBootstrapTestArchivePath = $ArchivePath
$ArchiveName = 'fastctx-x86_64-pc-windows-msvc.zip'
$ManifestName = 'SHA256SUMS'
$ResolvedTag = 'v0.3.0'
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$root = Join-Path ([System.IO.Path]::GetFullPath($TemporaryRoot)) ('fastctx-github-bootstrap-' + [guid]::NewGuid().ToString('N'))
$fixtureHome = Join-Path $root 'home'
$manifestPath = Join-Path $root $ManifestName
$savedIdle = [Environment]::GetEnvironmentVariable('FASTCTX_TEST_RUNTIME_IDLE_MS', 'Process')
$savedBuild = [Environment]::GetEnvironmentVariable('FASTCTX_TEST_BUILD_ID', 'Process')
$savedCodexHome = [Environment]::GetEnvironmentVariable('CODEX_HOME', 'Process')
$global:FastCtxBootstrapTestRequestedUrls = @()
$global:FastCtxBootstrapTestLatestLocation = "https://github.com/Fooljack/Fast-CTX/releases/tag/$ResolvedTag"
$global:FastCtxBootstrapTestManifestPath = $manifestPath
$initialBootstrapDirectories = @(
  Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Directory -Filter 'fastctx-github-install-*' -ErrorAction SilentlyContinue |
    ForEach-Object { $_.FullName }
)

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

function Assert-True {
  param(
    [Parameter(Mandatory = $true)][bool]$Condition,
    [Parameter(Mandatory = $true)][string]$Message
  )
  if (-not $Condition) { throw $Message }
}

function Assert-ExactUrls {
  param([Parameter(Mandatory = $true)][string[]]$Expected)
  Assert-True -Condition ($global:FastCtxBootstrapTestRequestedUrls.Count -eq $Expected.Count) -Message "bootstrap requested $($global:FastCtxBootstrapTestRequestedUrls.Count) URLs instead of $($Expected.Count)"
  for ($index = 0; $index -lt $Expected.Count; $index++) {
    Assert-True -Condition ($global:FastCtxBootstrapTestRequestedUrls[$index] -ceq $Expected[$index]) -Message "bootstrap URL mismatch at $($index): expected $($Expected[$index]), got $($global:FastCtxBootstrapTestRequestedUrls[$index])"
  }
}

function Invoke-WebRequest {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][uri]$Uri,
    [hashtable]$Headers,
    [string]$OutFile,
    [int]$MaximumRedirection,
    [int]$TimeoutSec,
    [switch]$UseBasicParsing
  )
  $global:FastCtxBootstrapTestRequestedUrls += $Uri.AbsoluteUri
  if ($Uri.AbsolutePath -ceq '/Fooljack/Fast-CTX/releases/latest') {
    if ($MaximumRedirection -ne 0 -or -not [string]::IsNullOrEmpty($OutFile)) {
      throw 'bootstrap latest resolver did not request a redirect-only response'
    }
    return [pscustomobject]@{
      Headers = @{ Location = $global:FastCtxBootstrapTestLatestLocation }
    }
  }
  if ([string]::IsNullOrWhiteSpace($OutFile)) {
    throw "bootstrap asset request omitted OutFile: $Uri"
  }
  $source = switch ([System.IO.Path]::GetFileName($Uri.AbsolutePath)) {
    $ArchiveName { $global:FastCtxBootstrapTestArchivePath }
    $ManifestName { $global:FastCtxBootstrapTestManifestPath }
    default { throw "bootstrap requested an unexpected asset: $Uri" }
  }
  Copy-Item -LiteralPath $source -Destination $OutFile
}

try {
  New-Item -ItemType Directory -Force -Path $fixtureHome | Out-Null
  $archiveHash = Get-Sha256 $ArchivePath
  [System.IO.File]::WriteAllText($manifestPath, "$archiveHash  $ArchiveName`n", $Utf8NoBom)
  [Environment]::SetEnvironmentVariable('FASTCTX_TEST_RUNTIME_IDLE_MS', '300', 'Process')
  [Environment]::SetEnvironmentVariable('FASTCTX_TEST_BUILD_ID', 'github-bootstrap-' + [guid]::NewGuid().ToString('N'), 'Process')
  $ambientCodexHome = Join-Path $fixtureHome 'ambient-codex'
  [Environment]::SetEnvironmentVariable('CODEX_HOME', $ambientCodexHome, 'Process')

  $parameters = @{
    NativeHome = $fixtureHome
    FastCtxHome = (Join-Path $fixtureHome '.fastctx')
    SkipClaudeCode = $true
    NoLaunchCcSwitch = $true
    SkipMcpSmoke = $true
  }

  & $Bootstrap @parameters
  Assert-ExactUrls -Expected @(
    'https://github.com/Fooljack/Fast-CTX/releases/latest',
    "https://github.com/Fooljack/Fast-CTX/releases/download/$ResolvedTag/$ManifestName",
    "https://github.com/Fooljack/Fast-CTX/releases/download/$ResolvedTag/$ArchiveName"
  )
  Assert-True -Condition (Test-Path -LiteralPath (Join-Path $parameters.FastCtxHome 'bin\fastctx.exe') -PathType Leaf) -Message 'bootstrap did not install the stable FastCtx binary'
  Assert-True -Condition (Test-Path -LiteralPath (Join-Path $ambientCodexHome 'config.toml') -PathType Leaf) -Message 'bootstrap did not honor ambient CODEX_HOME'
  Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $fixtureHome '.codex'))) -Message 'bootstrap ignored ambient CODEX_HOME and created the derived Codex profile'

  foreach ($redirectCase in @(
    [pscustomobject]@{ Location = 'https://example.com/Fooljack/Fast-CTX/releases/tag/v0.3.0'; Pattern = 'unexpected host' },
    [pscustomobject]@{ Location = 'https://github.com/Fooljack/Other/releases/tag/v0.3.0'; Pattern = 'unexpected path' },
    [pscustomobject]@{ Location = 'https://github.com/Fooljack/Fast-CTX/releases/tag/v0.3.0%2Fextra'; Pattern = 'invalid tag' }
  )) {
    $global:FastCtxBootstrapTestRequestedUrls = @()
    $global:FastCtxBootstrapTestLatestLocation = $redirectCase.Location
    $redirectRejected = $false
    try {
      & $Bootstrap @parameters -VerifyOnly
    } catch {
      $redirectRejected = $_.Exception.Message -match $redirectCase.Pattern
    }
    Assert-True -Condition $redirectRejected -Message "bootstrap accepted invalid latest redirect: $($redirectCase.Location)"
    Assert-ExactUrls -Expected @('https://github.com/Fooljack/Fast-CTX/releases/latest')
  }
  $global:FastCtxBootstrapTestLatestLocation = "https://github.com/Fooljack/Fast-CTX/releases/tag/$ResolvedTag"

  $global:FastCtxBootstrapTestRequestedUrls = @()
  & $Bootstrap @parameters -Tag 'v0.3.0' -VerifyOnly
  Assert-ExactUrls -Expected @(
    "https://github.com/Fooljack/Fast-CTX/releases/download/v0.3.0/$ManifestName",
    "https://github.com/Fooljack/Fast-CTX/releases/download/v0.3.0/$ArchiveName"
  )

  [System.IO.File]::WriteAllText($manifestPath, "$('0' * 64)  $ArchiveName`n", $Utf8NoBom)
  $checksumRejected = $false
  try {
    & $Bootstrap @parameters -Tag 'v0.3.0' -VerifyOnly
  } catch {
    $checksumRejected = $_.Exception.Message -match 'release archive SHA-256 mismatch'
  }
  Assert-True -Condition $checksumRejected -Message 'bootstrap accepted an archive that did not match Release SHA256SUMS'

  $repositoryRejected = $false
  try {
    & $Bootstrap @parameters -Repository 'Fooljack/Fast-CTX/extra'
  } catch {
    $repositoryRejected = $_.Exception.Message -match 'invalid GitHub repository name'
  }
  Assert-True -Condition $repositoryRejected -Message 'bootstrap accepted a non-canonical GitHub repository name'

  $tagRejected = $false
  try {
    & $Bootstrap @parameters -Tag '../v0.3.0'
  } catch {
    $tagRejected = $_.Exception.Message -match 'invalid GitHub Release tag'
  }
  Assert-True -Condition $tagRejected -Message 'bootstrap accepted a non-canonical GitHub Release tag'

  $remainingBootstrapDirectories = @(
    Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Directory -Filter 'fastctx-github-install-*' -ErrorAction SilentlyContinue |
      Where-Object { $initialBootstrapDirectories -notcontains $_.FullName }
  )
  Assert-True -Condition ($remainingBootstrapDirectories.Count -eq 0) -Message "bootstrap left temporary directories behind: $($remainingBootstrapDirectories.FullName -join ', ')"
  Write-Output 'FastCtx repository-link bootstrap offline contract passed'
} finally {
  [Environment]::SetEnvironmentVariable('FASTCTX_TEST_RUNTIME_IDLE_MS', $savedIdle, 'Process')
  [Environment]::SetEnvironmentVariable('FASTCTX_TEST_BUILD_ID', $savedBuild, 'Process')
  [Environment]::SetEnvironmentVariable('CODEX_HOME', $savedCodexHome, 'Process')
  foreach ($name in @('FastCtxBootstrapTestRequestedUrls', 'FastCtxBootstrapTestLatestLocation', 'FastCtxBootstrapTestManifestPath', 'FastCtxBootstrapTestArchivePath')) {
    Remove-Variable -Name $name -Scope Global -Force -ErrorAction SilentlyContinue
  }
  if (Test-Path -LiteralPath $root) {
    $fullRoot = [System.IO.Path]::GetFullPath($root)
    $tempPrefix = [System.IO.Path]::GetFullPath($TemporaryRoot).TrimEnd('\') + '\'
    if ($fullRoot.StartsWith($tempPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      Remove-Item -LiteralPath $fullRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
