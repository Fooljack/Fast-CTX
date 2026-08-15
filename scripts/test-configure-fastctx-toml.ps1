[CmdletBinding()]
param(
  [string]$TemporaryRoot = ([System.IO.Path]::GetTempPath())
)

$ErrorActionPreference = 'Stop'
$configurator = Join-Path $PSScriptRoot 'configure-fastctx.ps1'
$source = [System.IO.File]::ReadAllText($configurator)
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw "configurator parse failed: $($errors[0].Message)" }
foreach ($function in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
  Invoke-Expression $function.Extent.Text
}

$root = Join-Path ([System.IO.Path]::GetFullPath($TemporaryRoot)) ('fastctx-toml-edge-' + [guid]::NewGuid().ToString('N'))
$configPath = Join-Path $root 'config.toml'
$nativeHome = Join-Path $root 'home'
$profile = Join-Path $nativeHome '.codex'
$binary = Join-Path $root 'fastctx.exe'
$bash = Join-Path $root 'bash.exe'

function New-CanonicalToml {
  param(
    [Parameter(Mandatory = $true)][string]$ServerHeader,
    [Parameter(Mandatory = $true)][string]$EnvironmentHeader,
    [string]$ServerExtra = '',
    [string]$EnvironmentExtra = ''
  )
  return @"
# unrelated-sentinel
[mcp_servers.existing]
command = "keep-me.exe"

$ServerHeader
args = ["serve", "--enable-shell"]
command = $(ConvertTo-TomlBasicString $binary)
startup_timeout_sec = 120
tool_timeout_sec = 300$ServerExtra

$EnvironmentHeader
CODEX_HOME = $(ConvertTo-TomlBasicString $profile)
FASTCTX_BASH = $(ConvertTo-TomlBasicString $bash)
FASTCTX_GLOB_TOKEN_BUDGET = "5400"
FASTCTX_GREP_TOKEN_BUDGET = "10800"
FASTCTX_JOB_OUTPUT_TOKEN_BUDGET = "5400"
FASTCTX_RUN_TOKEN_BUDGET = "10800"
FASTCTX_TOKEN_BUDGET = "54000"
HOME = $(ConvertTo-TomlBasicString $nativeHome)
USERPROFILE = $(ConvertTo-TomlBasicString $nativeHome)$EnvironmentExtra
"@
}

function Assert-State {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Content,
    [Parameter(Mandatory = $true)][string]$Expected
  )
  [System.IO.File]::WriteAllText($configPath, $Content, [System.Text.UTF8Encoding]::new($false))
  $actual = Get-CodexFastCtxMcpState -ConfigPath $configPath -Binary $binary -NativeHome $nativeHome -Profile $profile -Bash $bash
  if ($actual -cne $Expected) { throw "$Name expected $Expected, got $actual" }
}

try {
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  $matching = @(
    [pscustomobject]@{ Name = 'quoted server and env headers'; Content = New-CanonicalToml -ServerHeader '[mcp_servers."fastctx"]' -EnvironmentHeader '[mcp_servers."fastctx"."env"]'; Expected = 'matching' },
    [pscustomobject]@{ Name = 'single quoted dotted headers'; Content = New-CanonicalToml -ServerHeader "[mcp_servers.'fastctx']" -EnvironmentHeader "[mcp_servers.'fastctx'.'env']"; Expected = 'matching' }
  )
  foreach ($case in $matching) {
    Assert-State -Name $case.Name -Content $case.Content -Expected $case.Expected
  }

  $conflicts = @(
    [pscustomobject]@{ Name = 'duplicate server table'; Content = (New-CanonicalToml -ServerHeader '[mcp_servers.fastctx]' -EnvironmentHeader '[mcp_servers.fastctx.env]') + "`r`n[mcp_servers.fastctx]`r`n" },
    [pscustomobject]@{ Name = 'duplicate assignment'; Content = (New-CanonicalToml -ServerHeader '[mcp_servers.fastctx]' -EnvironmentHeader '[mcp_servers.fastctx.env]') -replace 'tool_timeout_sec = 300', "tool_timeout_sec = 300`r`ntool_timeout_sec = 300" },
    [pscustomobject]@{ Name = 'server array table'; Content = (New-CanonicalToml -ServerHeader '[[mcp_servers.fastctx]]' -EnvironmentHeader '[mcp_servers.fastctx.env]') },
    [pscustomobject]@{ Name = 'environment array table'; Content = (New-CanonicalToml -ServerHeader '[mcp_servers.fastctx]' -EnvironmentHeader '[[mcp_servers.fastctx.env]]') },
    [pscustomobject]@{ Name = 'unexpected descendant'; Content = (New-CanonicalToml -ServerHeader '[mcp_servers.fastctx]' -EnvironmentHeader '[mcp_servers.fastctx.env]') + "`r`n[mcp_servers.fastctx.extra]`r`nvalue = true`r`n" },
    [pscustomobject]@{ Name = 'unknown environment key'; Content = New-CanonicalToml -ServerHeader '[mcp_servers.fastctx]' -EnvironmentHeader '[mcp_servers.fastctx.env]' -EnvironmentExtra "`r`nFASTCTX_READ_TOKEN_BUDGET = \"1\"" },
    [pscustomobject]@{ Name = 'multiline managed value'; Content = (New-CanonicalToml -ServerHeader '[mcp_servers.fastctx]' -EnvironmentHeader '[mcp_servers.fastctx.env]') -replace ('command = ' + [regex]::Escape((ConvertTo-TomlBasicString $binary))), "command = '''$binary`r`ncontinued'''" }
  )
  foreach ($case in $conflicts) {
    Assert-State -Name $case.Name -Content $case.Content -Expected 'conflict'
  }

  $removalInput = @"
# preserve-me
[mcp_servers."fastctx"]
command = "old"

[[mcp_servers.fastctx.extra]]
value = true

[unrelated]
keep = "yes"
"@
  $removed = Remove-FastCtxTomlSections -Content $removalInput
  if (-not $removed.Contains('# preserve-me') -or -not $removed.Contains('[unrelated]') -or $removed.Contains('mcp_servers."fastctx"') -or $removed.Contains('mcp_servers.fastctx.extra')) {
    throw 'semantic FastCtx section removal did not preserve unrelated TOML or remove all managed descendants'
  }

  Write-Output 'FastCtx semantic TOML quoted, duplicate, array, multiline, unknown-key, and removal regressions passed'
} finally {
  Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
