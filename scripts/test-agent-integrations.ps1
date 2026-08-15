[CmdletBinding()]
param(
  [string]$TemporaryRoot = (Join-Path ([System.IO.Path]::GetTempPath()) ('fastctx-agent-integrations-' + [guid]::NewGuid().ToString('N')))
)

$ErrorActionPreference = 'Stop'
$Helper = Join-Path $PSScriptRoot 'configure-agent-integrations.ps1'
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$BeginMarker = '<!-- fastctx:begin -->'
$EndMarker = '<!-- fastctx:end -->'

function Assert-True {
  param(
    [Parameter(Mandatory = $true)][bool]$Condition,
    [Parameter(Mandatory = $true)][string]$Message
  )
  if (-not $Condition) { throw $Message }
}

function Write-Utf8NoBom {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
  )
  $parent = Split-Path -Parent $Path
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  [System.IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
}

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

function Assert-SingleManagedBlock {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$UserText
  )
  $text = [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($true))
  Assert-True -Condition $text.Contains($UserText) -Message "user-owned text was not preserved in $Path"
  Assert-True -Condition ([regex]::Matches($text, [regex]::Escape($BeginMarker)).Count -eq 1) -Message "begin marker count is not one in $Path"
  Assert-True -Condition ([regex]::Matches($text, [regex]::Escape($EndMarker)).Count -eq 1) -Message "end marker count is not one in $Path"
  Assert-True -Condition $text.Contains('three consecutive, reasonable FastCtx attempts') -Message "three-attempt policy is missing from $Path"
  Assert-True -Condition $text.Contains('Never repeat an unchanged failing call') -Message "corrected-retry policy is missing from $Path"
  Assert-True -Condition $text.Contains('Specialized host tools such as `apply_patch` remain exempt') -Message "host-tool exemption is missing from $Path"
}

$TemporaryRoot = [System.IO.Path]::GetFullPath($TemporaryRoot)
$nativeHome = Join-Path $TemporaryRoot 'home'
$codexHome = Join-Path $nativeHome '.codex'
$claudeHome = Join-Path $nativeHome 'claude-config'
$fastctxBinary = Join-Path $nativeHome '.fastctx\bin\fastctx.exe'
$gitBash = Join-Path $TemporaryRoot 'bash.exe'
$fakeClaudeScript = Join-Path $TemporaryRoot 'fake-claude.ps1'
$fakeClaudeCommand = Join-Path $TemporaryRoot 'claude.cmd'
$fakeClaudeState = Join-Path $TemporaryRoot 'claude-state.json'
$agentsPath = Join-Path $codexHome 'AGENTS.md'
$overridePath = Join-Path $codexHome 'AGENTS.override.md'
$claudeGuidancePath = Join-Path $claudeHome 'CLAUDE.md'
$savedStateEnvironment = $env:FASTCTX_FAKE_CLAUDE_STATE

try {
  New-Item -ItemType Directory -Force -Path $codexHome, $claudeHome, (Split-Path -Parent $fastctxBinary) | Out-Null
  [System.IO.File]::WriteAllBytes($fastctxBinary, [byte[]](0x46, 0x43, 0x54, 0x58))
  [System.IO.File]::WriteAllBytes($gitBash, [byte[]](0x42, 0x41, 0x53, 0x48))
  Write-Utf8NoBom -Path $agentsPath -Content "codex-agents-user`n"
  Write-Utf8NoBom -Path $overridePath -Content "codex-override-user`r`n"

  $claudePrefix = [byte[]](0xEF, 0xBB, 0xBF) + $Utf8NoBom.GetBytes("claude-user`r`n")
  [System.IO.File]::WriteAllBytes($claudeGuidancePath, $claudePrefix)

  Write-Utf8NoBom -Path $fakeClaudeScript -Content @'
$ErrorActionPreference = 'Stop'
$statePath = $env:FASTCTX_FAKE_CLAUDE_STATE
if ([string]::IsNullOrWhiteSpace($statePath)) { throw 'FASTCTX_FAKE_CLAUDE_STATE is required' }
if ($args.Count -lt 2 -or $args[0] -ne 'mcp') { [Console]::Error.WriteLine('unsupported fake Claude command'); exit 2 }
$verb = $args[1]
if ($verb -eq 'get') {
  if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    [Console]::Error.WriteLine('No MCP server named "fastctx". Configured servers:')
    exit 1
  }
  $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
  [Console]::WriteLine('fastctx:')
  [Console]::WriteLine('  Scope: User config')
  [Console]::WriteLine('  Type: stdio')
  [Console]::WriteLine('  Command: ' + $state.Command)
  [Console]::WriteLine('  Args: ' + $state.Args)
  [Console]::WriteLine('  Environment:')
  foreach ($property in $state.Environment.psobject.Properties) {
    [Console]::WriteLine('    ' + $property.Name + '=' + [string]$property.Value)
  }
  exit 0
}
if ($verb -eq 'remove') {
  Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
  $configPath = Join-Path $env:CLAUDE_CONFIG_DIR '.claude.json'
  if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    Remove-Item -LiteralPath $configPath -Force
  }
  exit 0
}
if ($verb -eq 'add') {
  $separator = [Array]::IndexOf($args, '--')
  if ($separator -lt 0 -or $separator + 2 -ge $args.Count) { [Console]::Error.WriteLine('invalid add arguments'); exit 2 }
  $environment = [ordered]@{}
  for ($index = 2; $index -lt $separator; $index++) {
    if ($args[$index] -eq '-e') {
      $index++
      $pair = $args[$index]
      $equals = $pair.IndexOf('=')
      if ($equals -lt 1) { [Console]::Error.WriteLine('invalid environment argument'); exit 2 }
      $environment[$pair.Substring(0, $equals)] = $pair.Substring($equals + 1)
    }
  }
  $commandArguments = @()
  if ($separator + 2 -lt $args.Count) { $commandArguments = @($args[($separator + 2)..($args.Count - 1)]) }
  $state = [ordered]@{
    Command = $args[$separator + 1]
    Args = ($commandArguments -join ' ')
    Environment = $environment
    ObservedClaudeConfigDir = $env:CLAUDE_CONFIG_DIR
    ObservedHome = $env:HOME
  }
  [System.IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))
  $configDirectory = $env:CLAUDE_CONFIG_DIR
  if ([string]::IsNullOrWhiteSpace($configDirectory)) { $configDirectory = $env:HOME }
  New-Item -ItemType Directory -Force -Path $configDirectory | Out-Null
  $server = [ordered]@{
    type = 'stdio'
    command = $args[$separator + 1]
    args = $commandArguments
    env = $environment
  }
  $document = [ordered]@{ mcpServers = [ordered]@{ fastctx = $server } }
  [System.IO.File]::WriteAllText((Join-Path $configDirectory '.claude.json'), ($document | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
  exit 0
}
[Console]::Error.WriteLine('unsupported fake Claude MCP verb')
exit 2
'@
  Write-Utf8NoBom -Path $fakeClaudeCommand -Content "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0fake-claude.ps1`" %*`r`nexit /b %ERRORLEVEL%`r`n"
  $env:FASTCTX_FAKE_CLAUDE_STATE = $fakeClaudeState

  $parameters = @{
    FastCtxBinary = $fastctxBinary
    GitBash = $gitBash
    NativeHome = $nativeHome
    CodexHome = $codexHome
    ClaudeConfigDir = $claudeHome
    ClaudeCommand = $fakeClaudeCommand
    NoLaunchCcSwitch = $true
  }

  & $Helper @parameters
  Assert-True -Condition (Test-Path -LiteralPath $fakeClaudeState -PathType Leaf) -Message 'Claude MCP state was not created'
  Assert-SingleManagedBlock -Path $overridePath -UserText 'codex-override-user'
  Assert-SingleManagedBlock -Path $claudeGuidancePath -UserText 'claude-user'
  Assert-True -Condition ([System.IO.File]::ReadAllBytes($claudeGuidancePath)[0] -eq 0xEF) -Message 'Claude guidance UTF-8 BOM was not preserved'
  Assert-True -Condition ([System.IO.File]::ReadAllText($agentsPath, $Utf8NoBom) -eq "codex-agents-user`n") -Message 'inactive Codex AGENTS.md was modified'

  $state = Get-Content -LiteralPath $fakeClaudeState -Raw | ConvertFrom-Json
  Assert-True -Condition ($state.Command -eq $fastctxBinary) -Message 'Claude MCP command does not use the stable FastCtx binary'
  Assert-True -Condition ($state.Args -eq 'serve --enable-shell') -Message 'Claude MCP arguments are incorrect'
  Assert-True -Condition ($state.Environment.FASTCTX_TOKEN_BUDGET -eq '54000') -Message 'Claude global token budget is incorrect'
  Assert-True -Condition ($state.Environment.FASTCTX_GREP_TOKEN_BUDGET -eq '10800') -Message 'Claude grep token budget is incorrect'
  Assert-True -Condition ($state.Environment.FASTCTX_GLOB_TOKEN_BUDGET -eq '5400') -Message 'Claude glob token budget is incorrect'
  Assert-True -Condition ($state.Environment.FASTCTX_RUN_TOKEN_BUDGET -eq '10800') -Message 'Claude run token budget is incorrect'
  Assert-True -Condition ($state.Environment.FASTCTX_JOB_OUTPUT_TOKEN_BUDGET -eq '5400') -Message 'Claude job-output token budget is incorrect'
  Assert-True -Condition ($state.ObservedClaudeConfigDir -eq $claudeHome) -Message 'CLAUDE_CONFIG_DIR was not applied to the Claude CLI'
  Assert-True -Condition ($state.ObservedHome -eq $nativeHome) -Message 'HOME was not applied to the Claude CLI'

  $tracked = @($fakeClaudeState, $agentsPath, $overridePath, $claudeGuidancePath)
  $beforeNoOp = @{}
  foreach ($path in $tracked) { $beforeNoOp[$path] = Get-FileHashValue $path }
  & $Helper @parameters
  & $Helper @parameters -VerifyOnly
  foreach ($path in $tracked) {
    Assert-True -Condition ((Get-FileHashValue $path) -eq $beforeNoOp[$path]) -Message "idempotent or verify-only run changed $path"
  }

  $validOverride = [System.IO.File]::ReadAllBytes($overridePath)
  Write-Utf8NoBom -Path $overridePath -Content "codex-override-user`n$BeginMarker`n$BeginMarker`n$EndMarker`n"
  $stateBeforeMalformed = Get-FileHashValue $fakeClaudeState
  $malformedRejected = $false
  try {
    & $Helper @parameters -PreflightOnly
  } catch {
    $malformedRejected = $_.Exception.Message -match 'duplicate or unmatched FastCtx markers'
  }
  Assert-True -Condition $malformedRejected -Message 'duplicate FastCtx markers were not rejected during preflight'
  Assert-True -Condition ((Get-FileHashValue $fakeClaudeState) -eq $stateBeforeMalformed) -Message 'malformed-marker preflight changed Claude MCP state'
  [System.IO.File]::WriteAllBytes($overridePath, $validOverride)

  $conflict = Get-Content -LiteralPath $fakeClaudeState -Raw | ConvertFrom-Json
  $conflict.Command = (Join-Path $TemporaryRoot 'different-fastctx.exe')
  [System.IO.File]::WriteAllText($fakeClaudeState, ($conflict | ConvertTo-Json -Depth 5), $Utf8NoBom)
  $claudeConfigPath = Join-Path $claudeHome '.claude.json'
  $claudeConfig = Get-Content -LiteralPath $claudeConfigPath -Raw | ConvertFrom-Json
  $claudeConfig.mcpServers.fastctx.command = $conflict.Command
  [System.IO.File]::WriteAllText($claudeConfigPath, ($claudeConfig | ConvertTo-Json -Depth 8), $Utf8NoBom)
  $conflictRejected = $false
  try {
    & $Helper @parameters -PreflightOnly
  } catch {
    $conflictRejected = $_.Exception.Message -match 'different Claude Code MCP definition'
  }
  Assert-True -Condition $conflictRejected -Message 'conflicting Claude MCP definition was not rejected'

  & $Helper @parameters -ForceMcpRegistration
  $repaired = Get-Content -LiteralPath $fakeClaudeState -Raw | ConvertFrom-Json
  Assert-True -Condition ($repaired.Command -eq $fastctxBinary) -Message 'forced Claude MCP registration did not replace the conflict'
  & $Helper @parameters -VerifyOnly

  Write-Host '[test-agent-integrations] all checks passed'
} finally {
  $env:FASTCTX_FAKE_CLAUDE_STATE = $savedStateEnvironment
  if (Test-Path -LiteralPath $TemporaryRoot) {
    Remove-Item -LiteralPath $TemporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
