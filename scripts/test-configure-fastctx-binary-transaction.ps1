[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$FastCtxBinary,
  [string]$TemporaryRoot = ([System.IO.Path]::GetTempPath())
)

$ErrorActionPreference = 'Stop'
$configurator = Join-Path $PSScriptRoot 'configure-fastctx.ps1'
$baseBinary = (Resolve-Path -LiteralPath $FastCtxBinary -ErrorAction Stop).Path
$root = Join-Path ([System.IO.Path]::GetFullPath($TemporaryRoot)) ('fastctx-binary-transaction-' + [guid]::NewGuid().ToString('N'))
$savedFail = [Environment]::GetEnvironmentVariable('FASTCTX_TEST_FAIL_AFTER_BINARY_INSTALL', 'Process')
$savedCopySignal = [Environment]::GetEnvironmentVariable('FASTCTX_TEST_BEFORE_BINARY_COPY_SIGNAL', 'Process')
$savedCodexSignal = [Environment]::GetEnvironmentVariable('FASTCTX_TEST_BEFORE_CODEX_WRITE_SIGNAL', 'Process')
$savedIdle = [Environment]::GetEnvironmentVariable('FASTCTX_TEST_RUNTIME_IDLE_MS', 'Process')
$savedBuild = [Environment]::GetEnvironmentVariable('FASTCTX_TEST_BUILD_ID', 'Process')

function Get-Sha256 {
  param([Parameter(Mandatory = $true)][string]$Path)
  $stream = [System.IO.File]::OpenRead($Path)
  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  try { return ([System.BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '') }
  finally { $sha256.Dispose(); $stream.Dispose() }
}

function New-BinaryVariant {
  param(
    [Parameter(Mandatory = $true)][string]$Destination,
    [Parameter(Mandatory = $true)][byte[]]$Marker
  )
  Copy-Item -LiteralPath $baseBinary -Destination $Destination
  $stream = [System.IO.File]::Open($Destination, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
  try {
    $stream.Seek(0, [System.IO.SeekOrigin]::End) | Out-Null
    $stream.Write($Marker, 0, $Marker.Length)
  } finally { $stream.Dispose() }
}

function Get-Arguments {
  param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$FixtureHome
  )
  $codex = Join-Path $FixtureHome '.codex'
  $fastctx = Join-Path $FixtureHome '.fastctx'
  return @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $configurator,
    '-FastCtxBinary', $Source,
    '-NativeHome', $FixtureHome,
    '-CodexHome', $codex,
    '-FastCtxHome', $fastctx,
    '-SkipClaudeCode', '-NoLaunchCcSwitch'
  )
}

function Invoke-Configurator {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)
  $savedPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $output = @(& powershell.exe @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
  } finally { $ErrorActionPreference = $savedPreference }
  return [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
}

function Start-ConfiguratorAtSignal {
  param(
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [Parameter(Mandatory = $true)][string]$VariableName,
    [Parameter(Mandatory = $true)][string]$SignalPath
  )
  $argumentLiterals = @($Arguments | ForEach-Object { "'" + $_.Replace("'", "''") + "'" })
  $variableLiteral = "'" + $VariableName.Replace("'", "''") + "'"
  $signalLiteral = "'" + $SignalPath.Replace("'", "''") + "'"
  $command = "[Environment]::SetEnvironmentVariable($variableLiteral, $signalLiteral, 'Process'); & powershell.exe @($($argumentLiterals -join ', ')); exit `$LASTEXITCODE"
  $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($command))
  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = 'powershell.exe'
  $startInfo.Arguments = "-NoProfile -EncodedCommand $encoded"
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  if (-not $process.Start()) { throw 'could not start synchronized configurator process' }
  return [pscustomobject]@{ Process = $process }
}

function Wait-ForSignal {
  param(
    [Parameter(Mandatory = $true)]$Job,
    [Parameter(Mandatory = $true)][string]$SignalPath
  )
  for ($attempt = 1; $attempt -le 120; $attempt++) {
    if (Test-Path -LiteralPath $SignalPath -PathType Leaf) { return }
    if ($Job.Process.HasExited) {
      $stdout = $Job.Process.StandardOutput.ReadToEnd()
      $stderr = $Job.Process.StandardError.ReadToEnd()
      throw "configurator exited before signal (code $($Job.Process.ExitCode)): $stdout $stderr"
    }
    Start-Sleep -Milliseconds 50
  }
  throw "timed out waiting for configurator signal: $SignalPath"
}

function Finish-SignaledJob {
  param(
    [Parameter(Mandatory = $true)]$Job,
    [Parameter(Mandatory = $true)][string]$SignalPath
  )
  [System.IO.File]::WriteAllText($SignalPath + '.continue', 'continue', [System.Text.UTF8Encoding]::new($false))
  $process = $Job.Process
  if (-not $process.WaitForExit(45000)) {
    try { $process.Kill() } catch {}
    $process.Dispose()
    throw 'configurator did not finish after test signal continuation'
  }
  $standardOutput = $process.StandardOutput.ReadToEnd()
  $standardError = $process.StandardError.ReadToEnd()
  $exitCode = $process.ExitCode
  $process.Dispose()
  return [pscustomobject]@{ ExitCode = $exitCode; Output = @($standardOutput, $standardError) }
}

function Assert-NoTransactionArtifacts {
  param([Parameter(Mandatory = $true)][string]$BinDirectory)
  $leftovers = @(Get-ChildItem -LiteralPath $BinDirectory -Force -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '.fastctx-binary-*' })
  if ($leftovers.Count -ne 0) { throw "binary transaction left temporary artifacts: $($leftovers.Name -join ', ')" }
}

try {
  [Environment]::SetEnvironmentVariable('FASTCTX_TEST_RUNTIME_IDLE_MS', '300', 'Process')
  [Environment]::SetEnvironmentVariable('FASTCTX_TEST_BUILD_ID', 'binary-transaction-' + [guid]::NewGuid().ToString('N'), 'Process')
  New-Item -ItemType Directory -Force -Path $root | Out-Null

  $baselineRoot = Join-Path $root 'baseline'
  $baselineHome = Join-Path $baselineRoot 'home'
  $baselineA = Join-Path $baselineRoot 'source-a.exe'
  $baselineB = Join-Path $baselineRoot 'source-b.exe'
  New-Item -ItemType Directory -Force -Path $baselineRoot | Out-Null
  New-BinaryVariant -Destination $baselineA -Marker ([byte[]](0x41, 0x2D, 0x42, 0x41, 0x53, 0x45))
  New-BinaryVariant -Destination $baselineB -Marker ([byte[]](0x42, 0x2D, 0x4E, 0x45, 0x57))
  $first = Invoke-Configurator -Arguments (Get-Arguments -Source $baselineA -FixtureHome $baselineHome)
  if ($first.ExitCode -ne 0) { throw "baseline installation failed: $($first.Output -join [Environment]::NewLine)" }
  $stable = Join-Path $baselineHome '.fastctx\bin\fastctx.exe'
  $baselineHash = Get-Sha256 $stable
  if ($baselineHash -cne (Get-Sha256 $baselineA)) { throw 'baseline stable binary hash mismatch' }

  [Environment]::SetEnvironmentVariable('FASTCTX_TEST_FAIL_AFTER_BINARY_INSTALL', '1', 'Process')
  $failedReplacement = Invoke-Configurator -Arguments (Get-Arguments -Source $baselineB -FixtureHome $baselineHome)
  if ($failedReplacement.ExitCode -eq 0) { throw 'post-publication failure unexpectedly succeeded' }
  if ((Get-Sha256 $stable) -cne $baselineHash) { throw 'rollback did not restore the previous stable binary' }
  Assert-NoTransactionArtifacts -BinDirectory (Split-Path -Parent $stable)
  [Environment]::SetEnvironmentVariable('FASTCTX_TEST_FAIL_AFTER_BINARY_INSTALL', $null, 'Process')

  $freshRoot = Join-Path $root 'fresh-failure'
  $freshHome = Join-Path $freshRoot 'home'
  $freshSource = Join-Path $freshRoot 'source.exe'
  New-Item -ItemType Directory -Force -Path $freshRoot | Out-Null
  New-BinaryVariant -Destination $freshSource -Marker ([byte[]](0x46, 0x52, 0x45, 0x53, 0x48))
  [Environment]::SetEnvironmentVariable('FASTCTX_TEST_FAIL_AFTER_BINARY_INSTALL', '1', 'Process')
  $failedNew = Invoke-Configurator -Arguments (Get-Arguments -Source $freshSource -FixtureHome $freshHome)
  [Environment]::SetEnvironmentVariable('FASTCTX_TEST_FAIL_AFTER_BINARY_INSTALL', $null, 'Process')
  if ($failedNew.ExitCode -eq 0) { throw 'new-binary post-publication failure unexpectedly succeeded' }
  $freshStable = Join-Path $freshHome '.fastctx\bin\fastctx.exe'
  if (Test-Path -LiteralPath $freshStable) { throw 'rollback retained a newly published binary after failure' }
  Assert-NoTransactionArtifacts -BinDirectory (Split-Path -Parent $freshStable)

  $mutationRoot = Join-Path $root 'source-mutation'
  $mutationHome = Join-Path $mutationRoot 'home'
  $mutationSource = Join-Path $mutationRoot 'source.exe'
  $copySignal = Join-Path $mutationRoot 'copy.ready'
  New-Item -ItemType Directory -Force -Path $mutationRoot | Out-Null
  New-BinaryVariant -Destination $mutationSource -Marker ([byte[]](0x4D, 0x55, 0x54, 0x41, 0x54, 0x45))
  $mutationJob = Start-ConfiguratorAtSignal -Arguments (Get-Arguments -Source $mutationSource -FixtureHome $mutationHome) -VariableName 'FASTCTX_TEST_BEFORE_BINARY_COPY_SIGNAL' -SignalPath $copySignal
  try {
    Wait-ForSignal -Job $mutationJob -SignalPath $copySignal
    $stream = [System.IO.File]::Open($mutationSource, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    try { $stream.Seek(0, [System.IO.SeekOrigin]::End) | Out-Null; $stream.WriteByte(0x58) }
    finally { $stream.Dispose() }
    $mutationResult = Finish-SignaledJob -Job $mutationJob -SignalPath $copySignal
  } finally {
    [Environment]::SetEnvironmentVariable('FASTCTX_TEST_BEFORE_BINARY_COPY_SIGNAL', $null, 'Process')
  }
  if ($mutationResult.ExitCode -eq 0) { throw 'source mutation during copy unexpectedly succeeded' }
  $mutationStable = Join-Path $mutationHome '.fastctx\bin\fastctx.exe'
  if (Test-Path -LiteralPath $mutationStable) { throw 'source mutation published a binary despite hash mismatch' }

  $lateRoot = Join-Path $root 'late-conflict'
  $lateHome = Join-Path $lateRoot 'home'
  $lateA = Join-Path $lateRoot 'source-a.exe'
  $lateB = Join-Path $lateRoot 'source-b.exe'
  New-Item -ItemType Directory -Force -Path $lateRoot | Out-Null
  New-BinaryVariant -Destination $lateA -Marker ([byte[]](0x4C, 0x41, 0x54, 0x45, 0x2D, 0x41))
  New-BinaryVariant -Destination $lateB -Marker ([byte[]](0x4C, 0x41, 0x54, 0x45, 0x2D, 0x42))
  $lateInstall = Invoke-Configurator -Arguments (Get-Arguments -Source $lateA -FixtureHome $lateHome)
  if ($lateInstall.ExitCode -ne 0) { throw "late-conflict baseline failed: $($lateInstall.Output -join [Environment]::NewLine)" }
  $lateStable = Join-Path $lateHome '.fastctx\bin\fastctx.exe'
  $lateHash = Get-Sha256 $lateStable
  $lateConfig = Join-Path $lateHome '.codex\config.toml'
  $codexSignal = Join-Path $lateRoot 'codex.ready'
  $lateJob = Start-ConfiguratorAtSignal -Arguments (Get-Arguments -Source $lateB -FixtureHome $lateHome) -VariableName 'FASTCTX_TEST_BEFORE_CODEX_WRITE_SIGNAL' -SignalPath $codexSignal
  try {
    Wait-ForSignal -Job $lateJob -SignalPath $codexSignal
    [System.IO.File]::AppendAllText($lateConfig, "`r`n[mcp_servers.fastctx.extra]`r`nvalue = true`r`n", [System.Text.UTF8Encoding]::new($false))
    $lateResult = Finish-SignaledJob -Job $lateJob -SignalPath $codexSignal
  } finally {
    [Environment]::SetEnvironmentVariable('FASTCTX_TEST_BEFORE_CODEX_WRITE_SIGNAL', $null, 'Process')
  }
  if ($lateResult.ExitCode -eq 0) { throw 'late Codex conflict unexpectedly succeeded' }
  if ((Get-Sha256 $lateStable) -cne $lateHash) { throw 'late Codex conflict did not roll back the published binary' }
  $lateText = [System.IO.File]::ReadAllText($lateConfig, [System.Text.UTF8Encoding]::new($false))
  if (-not $lateText.Contains('[mcp_servers.fastctx.extra]')) { throw 'late Codex conflict was overwritten instead of preserved' }
  Assert-NoTransactionArtifacts -BinDirectory (Split-Path -Parent $lateStable)

  Write-Output 'FastCtx binary source-mutation, new-install rollback, replacement rollback, and late Codex conflict regressions passed'
} finally {
  [Environment]::SetEnvironmentVariable('FASTCTX_TEST_FAIL_AFTER_BINARY_INSTALL', $savedFail, 'Process')
  [Environment]::SetEnvironmentVariable('FASTCTX_TEST_BEFORE_BINARY_COPY_SIGNAL', $savedCopySignal, 'Process')
  [Environment]::SetEnvironmentVariable('FASTCTX_TEST_BEFORE_CODEX_WRITE_SIGNAL', $savedCodexSignal, 'Process')
  [Environment]::SetEnvironmentVariable('FASTCTX_TEST_RUNTIME_IDLE_MS', $savedIdle, 'Process')
  [Environment]::SetEnvironmentVariable('FASTCTX_TEST_BUILD_ID', $savedBuild, 'Process')
  Get-Job | Where-Object { $_.Name -like 'Job*' -and $_.State -eq 'Running' } | Stop-Job -ErrorAction SilentlyContinue
  Get-Job | Where-Object { $_.Name -like 'Job*' } | Remove-Job -Force -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 1000
  for ($attempt = 1; $attempt -le 20 -and (Test-Path -LiteralPath $root); $attempt++) {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $root) { Start-Sleep -Milliseconds 250 }
  }
  if (Test-Path -LiteralPath $root) { throw "test fixture could not be cleaned: $root" }
}
