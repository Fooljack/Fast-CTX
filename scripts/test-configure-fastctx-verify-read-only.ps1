[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$TemporaryRoot,
  [string]$FastCtxBinary = (Join-Path $env:USERPROFILE '.fastctx\bin\fastctx.exe'),
  [string]$GitBash
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$configurator = Join-Path $scriptRoot 'configure-fastctx.ps1'
$temp = [System.IO.Path]::GetFullPath($TemporaryRoot)
$fixtureRoot = Join-Path $temp ('fastctx-verify-only-' + [guid]::NewGuid().ToString('N'))
$fixtureHome = Join-Path $fixtureRoot 'home'
$codexHome = Join-Path $fixtureHome '.codex'
$fastCtxHome = Join-Path $fixtureHome '.fastctx'
$savedIdle = [Environment]::GetEnvironmentVariable('FASTCTX_TEST_RUNTIME_IDLE_MS', 'Process')
$savedBuild = [Environment]::GetEnvironmentVariable('FASTCTX_TEST_BUILD_ID', 'Process')

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

function Invoke-Configurator {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)
  $savedPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $output = @(& powershell.exe @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $savedPreference
  }
  return [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
}

New-Item -ItemType Directory -Force -Path $temp | Out-Null
[Environment]::SetEnvironmentVariable('FASTCTX_TEST_RUNTIME_IDLE_MS', '300', 'Process')
[Environment]::SetEnvironmentVariable('FASTCTX_TEST_BUILD_ID', 'verify-only-' + [guid]::NewGuid().ToString('N'), 'Process')
try {
  $sourceBinary = (Resolve-Path -LiteralPath $FastCtxBinary -ErrorAction Stop).Path
  $baseArguments = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $configurator,
    '-NativeHome', $fixtureHome,
    '-CodexHome', $codexHome,
    '-FastCtxHome', $fastCtxHome,
    '-SkipClaudeCode',
    '-NoLaunchCcSwitch'
  )
  if ($GitBash) { $baseArguments += @('-GitBash', $GitBash) }
  $installArguments = $baseArguments + @('-FastCtxBinary', $sourceBinary)
  $install = Invoke-Configurator -Arguments $installArguments
  if ($install.ExitCode -ne 0) {
    throw "FastCtx fixture installation failed: $($install.Output -join [Environment]::NewLine)"
  }

  $staleSibling = Join-Path $fastCtxHome 'bin\fastctx.exe~RF1A2B.TMP'
  [System.IO.File]::WriteAllBytes($staleSibling, [byte[]](0x46, 0x41, 0x53, 0x54, 0x43, 0x54, 0x58))
  $tracked = @(
    (Join-Path $codexHome 'config.toml'),
    (Join-Path $codexHome 'AGENTS.md'),
    (Join-Path $fastCtxHome 'config.toml'),
    (Join-Path $fastCtxHome 'bin\fastctx.exe'),
    $staleSibling
  )
  $before = @{}
  foreach ($path in $tracked) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "fixture output is missing: $path" }
    $before[$path] = Get-Sha256 $path
  }

  $verify = Invoke-Configurator -Arguments ($baseArguments + @('-VerifyOnly'))
  if ($verify.ExitCode -ne 0) {
    throw "FastCtx VerifyOnly failed: $($verify.Output -join [Environment]::NewLine)"
  }
  $outputText = ($verify.Output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
  if ($outputText -notmatch 'MCP initialize/tools-list passed: glob, grep, job_kill, job_list, job_output, read, replace, run, run_background') {
    throw "FastCtx VerifyOnly did not report the strict nine-tool handshake: $outputText"
  }
  foreach ($path in $tracked) {
    if ((Get-Sha256 $path) -cne $before[$path]) {
      throw "FastCtx VerifyOnly modified a tracked configuration/runtime file: $path"
    }
  }

  $missingRoot = Join-Path $fixtureRoot 'missing'
  $missingCodexHome = Join-Path $missingRoot '.codex'
  $missingFastCtxHome = Join-Path $missingRoot '.fastctx'
  $missingArguments = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $configurator,
    '-VerifyOnly',
    '-NativeHome', $missingRoot,
    '-CodexHome', $missingCodexHome,
    '-FastCtxHome', $missingFastCtxHome,
    '-SkipClaudeCode',
    '-NoLaunchCcSwitch'
  )
  if ($GitBash) { $missingArguments += @('-GitBash', $GitBash) }
  $missing = Invoke-Configurator -Arguments $missingArguments
  if ($missing.ExitCode -eq 0) { throw 'FastCtx VerifyOnly unexpectedly accepted missing configuration roots' }
  if ((Test-Path -LiteralPath $missingCodexHome) -or (Test-Path -LiteralPath $missingFastCtxHome)) {
    throw 'FastCtx VerifyOnly created a missing configuration root'
  }

  Write-Output 'FastCtx VerifyOnly read-only guidance/config/binary and nine-tool handshake regression passed'
} finally {
  [Environment]::SetEnvironmentVariable('FASTCTX_TEST_RUNTIME_IDLE_MS', $savedIdle, 'Process')
  [Environment]::SetEnvironmentVariable('FASTCTX_TEST_BUILD_ID', $savedBuild, 'Process')
  Start-Sleep -Milliseconds 1000
  for ($attempt = 1; $attempt -le 20 -and (Test-Path -LiteralPath $fixtureRoot); $attempt++) {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $fixtureRoot) { Start-Sleep -Milliseconds 250 }
  }
  if (Test-Path -LiteralPath $fixtureRoot) { throw "test fixture could not be cleaned: $fixtureRoot" }
}
