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
$previousIdle = [Environment]::GetEnvironmentVariable('FASTCTX_TEST_RUNTIME_IDLE_MS', 'Process')
$previousBuild = [Environment]::GetEnvironmentVariable('FASTCTX_TEST_BUILD_ID', 'Process')

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

[mcp_servers.fastctx]
command = "retired-fastctx.exe"
args = ["serve"]

[mcp_servers.fastctx.env]
FASTCTX_TOKEN_BUDGET = "77777"
FASTCTX_GREP_TOKEN_BUDGET = "7777"

[windows]
sandbox = "unelevated"
'@
  [System.IO.File]::WriteAllText($config, $before.TrimStart() + "`r`n", [System.Text.UTF8Encoding]::new($false))

  [Environment]::SetEnvironmentVariable('FASTCTX_TEST_RUNTIME_IDLE_MS', '300', 'Process')
  [Environment]::SetEnvironmentVariable('FASTCTX_TEST_BUILD_ID', 'config-preserve-' + [guid]::NewGuid().ToString('N'), 'Process')
  $arguments = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $configurator,
    '-FastCtxBinary', (Resolve-Path -LiteralPath $FastCtxBinary).Path,
    '-NativeHome', $fixtureHome,
    '-CodexHome', $codexHome,
    '-FastCtxHome', $fastCtxHome
  )
  if ($GitBash) { $arguments += @('-GitBash', $GitBash) }

  $firstOutput = @(& powershell.exe @arguments 2>&1)
  if ($LASTEXITCODE -ne 0) {
    throw "first configurator run failed: $($firstOutput -join [Environment]::NewLine)"
  }
  $after = [System.IO.File]::ReadAllText($config, [System.Text.UTF8Encoding]::new($false))
  foreach ($marker in @(
    '# unrelated-sentinel',
    'model_provider = "custom-provider"',
    '[features]',
    'computer_use = true',
    '[mcp_servers.existing]',
    'command = "keep-me.exe"',
    '[windows]',
    'sandbox = "unelevated"',
    'FASTCTX_TOKEN_BUDGET = "77777"',
    'FASTCTX_GREP_TOKEN_BUDGET = "7777"'
  )) {
    if (-not $after.Contains($marker)) { throw "configurator removed unrelated or preserved content: $marker" }
  }
  if ([regex]::Matches($after, '(?m)^\[mcp_servers\.fastctx\]\s*$').Count -ne 1 -or
      [regex]::Matches($after, '(?m)^\[mcp_servers\.fastctx\.env\]\s*$').Count -ne 1) {
    throw 'configurator duplicated a FastCtx TOML table'
  }
  $backups = @(Get-ChildItem -LiteralPath (Join-Path $codexHome 'backups\config') -Filter '*.fastctx.bak' -File)
  if ($backups.Count -ne 1) { throw "expected one config backup, found $($backups.Count)" }

  $firstHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $config).Hash
  $secondOutput = @(& powershell.exe @arguments 2>&1)
  if ($LASTEXITCODE -ne 0) {
    throw "second configurator run failed: $($secondOutput -join [Environment]::NewLine)"
  }
  $secondHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $config).Hash
  if ($secondHash -cne $firstHash) { throw 'second configurator run was not idempotent' }
  $backupsAfter = @(Get-ChildItem -LiteralPath (Join-Path $codexHome 'backups\config') -Filter '*.fastctx.bak' -File)
  if ($backupsAfter.Count -ne 1) { throw 'idempotent run created an unnecessary backup' }

  Write-Output 'FastCtx config preservation, backup, and idempotence regression passed'
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
