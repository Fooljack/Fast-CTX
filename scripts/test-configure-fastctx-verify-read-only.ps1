[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$TemporaryRoot
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$configurator = Join-Path $scriptRoot 'configure-fastctx.ps1'
$codexConfig = Join-Path $env:USERPROFILE '.codex\config.toml'
$fastCtxConfig = Join-Path $env:USERPROFILE '.fastctx\config.toml'
$fastCtxBinary = Join-Path $env:USERPROFILE '.fastctx\bin\fastctx.exe'
$tracked = @($codexConfig, $fastCtxConfig, $fastCtxBinary)
$before = @{}
foreach ($path in $tracked) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "required FastCtx verification input is missing: $path"
  }
  $before[$path] = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash
}

$output = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $configurator -VerifyOnly 2>&1)
if ($LASTEXITCODE -ne 0) {
  throw "FastCtx VerifyOnly failed: $($output -join [Environment]::NewLine)"
}
$outputText = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
if ($outputText -notmatch 'MCP initialize/tools-list passed: glob, grep, job_kill, job_list, job_output, read, replace, run, run_background') {
  throw "FastCtx VerifyOnly did not report the strict nine-tool handshake: $outputText"
}
foreach ($path in $tracked) {
  $after = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash
  if ($after -cne $before[$path]) {
    throw "FastCtx VerifyOnly modified a tracked configuration/runtime file: $path"
  }
}

$temp = [System.IO.Path]::GetFullPath($TemporaryRoot)
New-Item -ItemType Directory -Force -Path $temp | Out-Null
$fixtureRoot = Join-Path $temp ('fastctx-verify-only-' + [guid]::NewGuid().ToString('N'))
$missingCodexHome = Join-Path $fixtureRoot 'missing-codex-home'
$missingFastCtxHome = Join-Path $fixtureRoot 'missing-fastctx-home'
try {
  $previousErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $missingOutput = @(
      & powershell -NoProfile -ExecutionPolicy Bypass -File $configurator `
        -VerifyOnly -CodexHome $missingCodexHome -FastCtxHome $missingFastCtxHome 2>&1
    )
    $missingExitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }
  if ($missingExitCode -eq 0) {
    throw 'FastCtx VerifyOnly unexpectedly accepted missing configuration roots'
  }
  if ((Test-Path -LiteralPath $missingCodexHome) -or (Test-Path -LiteralPath $missingFastCtxHome)) {
    throw 'FastCtx VerifyOnly created a missing configuration root'
  }
  Write-Output 'FastCtx VerifyOnly read-only and nine-tool handshake regression passed'
} finally {
  if (Test-Path -LiteralPath $fixtureRoot) {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
