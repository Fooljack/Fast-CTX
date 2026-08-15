[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$FastCtxBinary,
  [string]$GitBash,
  [string]$TemporaryRoot = ([System.IO.Path]::GetTempPath())
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$configurator = Join-Path $scriptRoot 'configure-fastctx.ps1'
$root = Join-Path ([System.IO.Path]::GetFullPath($TemporaryRoot)) ('fastctx-config-preserve-' + [guid]::NewGuid().ToString('N'))
$fixtureHome = Join-Path $root 'home'
$codexHome = Join-Path $fixtureHome '.codex'
$fastCtxHome = Join-Path $fixtureHome '.fastctx'
$config = Join-Path $codexHome 'config.toml'
$agents = Join-Path $codexHome 'AGENTS.md'
$previousIdle = [Environment]::GetEnvironmentVariable('FASTCTX_TEST_RUNTIME_IDLE_MS', 'Process')
$previousBuild = [Environment]::GetEnvironmentVariable('FASTCTX_TEST_BUILD_ID', 'Process')

function Get-FileHashValue {
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

try {
  New-Item -ItemType Directory -Force -Path $codexHome | Out-Null
  $before = @'
# unrelated-sentinel
model_provider = "custom-provider"

[features]
computer_use = true

[mcp_servers.existing]
command = "keep-me.exe"
args = ["serve"]

[mcp_servers.fastctx] # managed-server-comment
command = "retired-fastctx.exe"
args = ["serve"]

[mcp_servers.fastctx.env] # managed-env-comment
FASTCTX_TOKEN_BUDGET = "77777"
FASTCTX_GREP_TOKEN_BUDGET = "7777"

[windows]
sandbox = "unelevated"
'@
  [System.IO.File]::WriteAllText($config, $before.TrimStart() + "`r`n", [System.Text.UTF8Encoding]::new($true))
  [System.IO.File]::WriteAllText($agents, "user-agent-sentinel`r`n", [System.Text.UTF8Encoding]::new($false))

  [Environment]::SetEnvironmentVariable('FASTCTX_TEST_RUNTIME_IDLE_MS', '300', 'Process')
  [Environment]::SetEnvironmentVariable('FASTCTX_TEST_BUILD_ID', 'config-preserve-' + [guid]::NewGuid().ToString('N'), 'Process')
  $arguments = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $configurator,
    '-FastCtxBinary', (Resolve-Path -LiteralPath $FastCtxBinary).Path,
    '-NativeHome', $fixtureHome,
    '-CodexHome', $codexHome,
    '-FastCtxHome', $fastCtxHome,
    '-SkipClaudeCode',
    '-NoLaunchCcSwitch'
  )
  if ($GitBash) { $arguments += @('-GitBash', $GitBash) }

  $beforeConflictHash = Get-FileHashValue $config
  $beforeConflictAgentsHash = Get-FileHashValue $agents
  $conflictResult = Invoke-Configurator -Arguments $arguments
  $conflictText = ($conflictResult.Output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
  if ($conflictResult.ExitCode -eq 0 -or $conflictText -notmatch 'different Codex MCP definition') {
    throw "configurator did not reject the conflicting Codex FastCtx definition: $conflictText"
  }
  if ((Get-FileHashValue $config) -cne $beforeConflictHash -or
      (Get-FileHashValue $agents) -cne $beforeConflictAgentsHash -or
      (Test-Path -LiteralPath $fastCtxHome)) {
    throw 'Codex conflict preflight changed files before explicit force'
  }
  $arguments += '-ForceMcpRegistration'

  $firstResult = Invoke-Configurator -Arguments $arguments
  if ($firstResult.ExitCode -ne 0) {
    throw "first configurator run failed: $($firstResult.Output -join [Environment]::NewLine)"
  }
  $after = [System.IO.File]::ReadAllText($config, [System.Text.UTF8Encoding]::new($false))
  $afterBytes = [System.IO.File]::ReadAllBytes($config)
  if ($afterBytes.Length -lt 3 -or $afterBytes[0] -ne 0xEF -or $afterBytes[1] -ne 0xBB -or $afterBytes[2] -ne 0xBF) {
    throw 'configurator did not preserve the Codex config UTF-8 BOM'
  }
  foreach ($marker in @(
    '# unrelated-sentinel',
    'model_provider = "custom-provider"',
    '[features]',
    'computer_use = true',
    '[mcp_servers.existing]',
    'command = "keep-me.exe"',
    '[windows]',
    'sandbox = "unelevated"',
    'FASTCTX_TOKEN_BUDGET = "54000"',
    'FASTCTX_GREP_TOKEN_BUDGET = "10800"',
    'FASTCTX_GLOB_TOKEN_BUDGET = "5400"',
    'FASTCTX_RUN_TOKEN_BUDGET = "10800"',
    'FASTCTX_JOB_OUTPUT_TOKEN_BUDGET = "5400"'
  )) {
    if (-not $after.Contains($marker)) { throw "configurator removed unrelated content or omitted managed content: $marker" }
  }
  foreach ($retired in @('FASTCTX_TOKEN_BUDGET = "77777"', 'FASTCTX_GREP_TOKEN_BUDGET = "7777"')) {
    if ($after.Contains($retired)) { throw "configurator retained a stale managed budget: $retired" }
  }
  if ([regex]::Matches($after, '(?m)^\[mcp_servers\.fastctx\]\s*(?:#.*)?$').Count -ne 1 -or
      [regex]::Matches($after, '(?m)^\[mcp_servers\.fastctx\.env\]\s*(?:#.*)?$').Count -ne 1) {
    throw 'configurator duplicated a FastCtx TOML table'
  }
  $agentsText = [System.IO.File]::ReadAllText($agents, [System.Text.UTF8Encoding]::new($false))
  if (-not $agentsText.Contains('user-agent-sentinel') -or
      [regex]::Matches($agentsText, [regex]::Escape('<!-- fastctx:begin -->')).Count -ne 1) {
    throw 'configurator did not preserve Codex guidance while adding one managed block'
  }
  $backups = @(Get-ChildItem -LiteralPath (Join-Path $codexHome 'backups\config') -Filter '*.fastctx.bak' -File)
  if ($backups.Count -ne 1) { throw "expected one config backup, found $($backups.Count)" }

  $firstConfigHash = Get-FileHashValue $config
  $firstAgentsHash = Get-FileHashValue $agents
  $secondResult = Invoke-Configurator -Arguments $arguments
  if ($secondResult.ExitCode -ne 0) {
    throw "second configurator run failed: $($secondResult.Output -join [Environment]::NewLine)"
  }
  if ((Get-FileHashValue $config) -cne $firstConfigHash) { throw 'second configurator run changed Codex config' }
  if ((Get-FileHashValue $agents) -cne $firstAgentsHash) { throw 'second configurator run changed Codex guidance' }
  $backupsAfter = @(Get-ChildItem -LiteralPath (Join-Path $codexHome 'backups\config') -Filter '*.fastctx.bak' -File)
  if ($backupsAfter.Count -ne 1) { throw 'idempotent run created an unnecessary backup' }

  Write-Output 'FastCtx config/guidance preservation, standard profile, backup, and idempotence regression passed'
} finally {
  [Environment]::SetEnvironmentVariable('FASTCTX_TEST_RUNTIME_IDLE_MS', $previousIdle, 'Process')
  [Environment]::SetEnvironmentVariable('FASTCTX_TEST_BUILD_ID', $previousBuild, 'Process')
  Start-Sleep -Milliseconds 1000
  for ($attempt = 1; $attempt -le 20 -and (Test-Path -LiteralPath $root); $attempt++) {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $root) { Start-Sleep -Milliseconds 250 }
  }
  if (Test-Path -LiteralPath $root) { throw "test fixture could not be cleaned: $root" }
}
