[CmdletBinding()]
param(
  [string]$TemporaryRoot = (Join-Path ([System.IO.Path]::GetTempPath()) ('fastctx-ccswitch-' + [guid]::NewGuid().ToString('N')))
)

$ErrorActionPreference = 'Stop'
$Helper = Join-Path $PSScriptRoot 'configure-ccswitch-fastctx.ps1'

function Assert-True {
  param(
    [Parameter(Mandatory = $true)][bool]$Condition,
    [Parameter(Mandatory = $true)][string]$Message
  )
  if (-not $Condition) { throw $Message }
}

try {
  $TemporaryRoot = [System.IO.Path]::GetFullPath($TemporaryRoot)
  $nativeHome = Join-Path $TemporaryRoot 'home'
  $codexHome = Join-Path $nativeHome '.codex'
  $binary = Join-Path $nativeHome '.fastctx\bin\fastctx.exe'
  $bash = Join-Path $TemporaryRoot 'bash.exe'
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $binary) | Out-Null
  [System.IO.File]::WriteAllBytes($binary, [byte[]](0x46, 0x43, 0x54, 0x58))
  [System.IO.File]::WriteAllBytes($bash, [byte[]](0x42, 0x41, 0x53, 0x48))

  $link = & $Helper `
    -FastCtxBinary $binary `
    -GitBash $bash `
    -NativeHome $nativeHome `
    -CodexHome $codexHome `
    -NoLaunch `
    -PassThru
  Assert-True -Condition ($link -is [string] -and $link.StartsWith('ccswitch://v1/import?')) -Message 'CC Switch helper did not emit one import URI'

  $query = @{}
  foreach ($part in ([System.Uri]$link).Query.TrimStart('?').Split('&')) {
    $pair = $part.Split('=', 2)
    Assert-True -Condition ($pair.Count -eq 2) -Message "invalid CC Switch query component: $part"
    $query[[System.Uri]::UnescapeDataString($pair[0])] = [System.Uri]::UnescapeDataString($pair[1])
  }
  Assert-True -Condition ($query.resource -ceq 'mcp') -Message 'CC Switch resource is not MCP'
  Assert-True -Condition ($query.apps -ceq 'claude,codex') -Message 'CC Switch default target app set is not claude,codex'

  $json = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($query.config))
  $payload = $json | ConvertFrom-Json
  $server = $payload.mcpServers.fastctx
  Assert-True -Condition ($server.type -ceq 'stdio') -Message 'CC Switch FastCtx transport is not stdio'
  Assert-True -Condition ($server.command -ceq $binary) -Message 'CC Switch FastCtx command does not use the stable binary'
  Assert-True -Condition (($server.args -join ' ') -ceq 'serve --enable-shell') -Message 'CC Switch FastCtx arguments are incorrect'
  Assert-True -Condition ($server.startup_timeout_sec -eq 120) -Message 'CC Switch FastCtx startup_timeout_sec must match the canonical Codex profile'
  Assert-True -Condition ($server.tool_timeout_sec -eq 300) -Message 'CC Switch FastCtx tool_timeout_sec must match the canonical Codex profile'

  $expectedEnvironment = [ordered]@{
    CODEX_HOME = $codexHome
    FASTCTX_BASH = $bash
    FASTCTX_GLOB_TOKEN_BUDGET = '5400'
    FASTCTX_GREP_TOKEN_BUDGET = '10800'
    FASTCTX_JOB_OUTPUT_TOKEN_BUDGET = '5400'
    FASTCTX_RUN_TOKEN_BUDGET = '10800'
    FASTCTX_TOKEN_BUDGET = '54000'
    HOME = $nativeHome
    USERPROFILE = $nativeHome
  }
  $properties = @($server.env.psobject.Properties)
  Assert-True -Condition ($properties.Count -eq $expectedEnvironment.Count) -Message 'CC Switch environment contains unexpected keys'
  foreach ($entry in $expectedEnvironment.GetEnumerator()) {
    Assert-True -Condition ($server.env.($entry.Key) -ceq $entry.Value) -Message "CC Switch environment mismatch: $($entry.Key)"
  }

  & $Helper `
    -FastCtxBinary $binary `
    -GitBash $bash `
    -NativeHome $nativeHome `
    -CodexHome $codexHome `
    -VerifyOnly | Out-Null

  # -Apps opts into a wider set, is normalised to the canonical order, and de-duplicates.
  $widened = & $Helper `
    -FastCtxBinary $binary `
    -GitBash $bash `
    -NativeHome $nativeHome `
    -CodexHome $codexHome `
    -Apps ' HERMES , codex ,claude,codex ' `
    -NoLaunch `
    -PassThru
  $widenedApps = ([System.Uri]$widened).Query -replace '^.*[?&]apps=([^&]*).*$', '$1'
  Assert-True -Condition ([System.Uri]::UnescapeDataString($widenedApps) -ceq 'claude,codex,hermes') -Message 'CC Switch -Apps was not normalised to the canonical order'

  $unknownRejected = $false
  try {
    & $Helper `
      -FastCtxBinary $binary `
      -GitBash $bash `
      -NativeHome $nativeHome `
      -CodexHome $codexHome `
      -Apps 'claude,notanapp' `
      -NoLaunch | Out-Null
  } catch {
    $unknownRejected = $_.Exception.Message -match 'unsupported CC Switch application'
  }
  Assert-True -Condition $unknownRejected -Message 'CC Switch helper accepted an unknown application name'

  $emptyRejected = $false
  try {
    & $Helper `
      -FastCtxBinary $binary `
      -GitBash $bash `
      -NativeHome $nativeHome `
      -CodexHome $codexHome `
      -Apps ' , ' `
      -NoLaunch | Out-Null
  } catch {
    $emptyRejected = $_.Exception.Message -match 'must name at least one'
  }
  Assert-True -Condition $emptyRejected -Message 'CC Switch helper accepted an empty application set'
  & $Helper `
    -FastCtxBinary (Join-Path $TemporaryRoot 'not-yet-installed-fastctx.exe') `
    -GitBash (Join-Path $TemporaryRoot 'not-yet-resolved-bash.exe') `
    -NativeHome $nativeHome `
    -CodexHome $codexHome `
    -PreflightOnly | Out-Null

  $missingRejected = $false
  try {
    & $Helper `
      -FastCtxBinary (Join-Path $TemporaryRoot 'missing-fastctx.exe') `
      -GitBash $bash `
      -NativeHome $nativeHome `
      -CodexHome $codexHome `
      -NoLaunch | Out-Null
  } catch {
    $missingRejected = $_.Exception.Message -match 'requires this file'
  }
  Assert-True -Condition $missingRejected -Message 'CC Switch helper accepted a missing FastCtx binary'

  Write-Output 'FastCtx CC Switch deep-link contract passed'
} finally {
  if (Test-Path -LiteralPath $TemporaryRoot) {
    Remove-Item -LiteralPath $TemporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
