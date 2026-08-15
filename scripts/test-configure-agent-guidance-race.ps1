[CmdletBinding()]
param(
  [string]$TemporaryRoot = ([System.IO.Path]::GetTempPath())
)

$ErrorActionPreference = 'Stop'
$helper = Join-Path $PSScriptRoot 'configure-agent-integrations.ps1'
$root = Join-Path ([System.IO.Path]::GetFullPath($TemporaryRoot)) ('fastctx-guidance-race-' + [guid]::NewGuid().ToString('N'))
$savedDelay = [Environment]::GetEnvironmentVariable('FASTCTX_TEST_GUIDANCE_COMMIT_DELAY_MS', 'Process')

function Start-IntegrationJob {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)
  return Start-Job -ScriptBlock {
    param([string[]]$ChildArguments)
    $output = @(& powershell.exe @ChildArguments 2>&1)
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
  } -ArgumentList (,$Arguments)
}

function Wait-TemporaryGuidance {
  param([Parameter(Mandatory = $true)][string]$Directory)
  for ($attempt = 1; $attempt -le 120; $attempt++) {
    $temporary = @(Get-ChildItem -LiteralPath $Directory -Filter '.fastctx-guidance-*.tmp' -File -ErrorAction SilentlyContinue)
    if ($temporary.Count -eq 1) { return $temporary[0].FullName }
    Start-Sleep -Milliseconds 50
  }
  throw "timed out waiting for guidance temporary file in $Directory"
}

function Finish-Job {
  param(
    [Parameter(Mandatory = $true)]$Job,
    [Parameter(Mandatory = $true)][string]$Name
  )
  if ($null -eq (Wait-Job -Job $Job -Timeout 45)) {
    Stop-Job -Job $Job -ErrorAction SilentlyContinue
    throw "$Name did not finish"
  }
  $result = @(Receive-Job -Job $Job)
  Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
  if ($result.Count -eq 0) { throw "$Name returned no result" }
  return $result[-1]
}

function New-CommonArguments {
  param(
    [Parameter(Mandatory = $true)][string]$FixtureHome,
    [Parameter(Mandatory = $true)][string]$Bash
  )
  return @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $helper,
    '-FastCtxBinary', (Join-Path $FixtureHome 'fastctx.exe'),
    '-GitBash', $Bash,
    '-NativeHome', $FixtureHome,
    '-CodexHome', (Join-Path $FixtureHome '.codex'),
    '-SkipClaudeCode', '-SkipCcSwitch'
  )
}

try {
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  [Environment]::SetEnvironmentVariable('FASTCTX_TEST_GUIDANCE_COMMIT_DELAY_MS', '3000', 'Process')

  $existingRoot = Join-Path $root 'existing'
  $existingHome = Join-Path $existingRoot 'home'
  $existingCodex = Join-Path $existingHome '.codex'
  $existingAgents = Join-Path $existingCodex 'AGENTS.md'
  $existingBash = Join-Path $existingRoot 'bash.exe'
  New-Item -ItemType Directory -Force -Path $existingCodex | Out-Null
  [System.IO.File]::WriteAllText($existingAgents, "user-owned-before-race`r`n", [System.Text.UTF8Encoding]::new($false))
  [System.IO.File]::WriteAllBytes($existingBash, [byte[]](0x42, 0x41, 0x53, 0x48))
  $existingJob = Start-IntegrationJob -Arguments (New-CommonArguments -FixtureHome $existingHome -Bash $existingBash)
  $temporary = Wait-TemporaryGuidance -Directory $existingCodex
  $writeBlocked = $false
  try {
    [System.IO.File]::WriteAllText($existingAgents, 'concurrent-writer-should-be-blocked', [System.Text.UTF8Encoding]::new($false))
  } catch {
    $writeBlocked = $true
  }
  $existingResult = Finish-Job -Job $existingJob -Name 'existing-file guidance race'
  if (-not $writeBlocked) { throw 'concurrent guidance writer was not blocked while the CAS guard was held' }
  if ($existingResult.ExitCode -ne 0) { throw "existing-file guidance update failed: $($existingResult.Output -join [Environment]::NewLine)" }
  $existingText = [System.IO.File]::ReadAllText($existingAgents, [System.Text.UTF8Encoding]::new($false))
  if (-not $existingText.Contains('user-owned-before-race') -or
      [regex]::Matches($existingText, [regex]::Escape('<!-- fastctx:begin -->')).Count -ne 1) {
    throw 'existing-file guidance race lost user text or managed block'
  }

  $missingRoot = Join-Path $root 'missing'
  $missingHome = Join-Path $missingRoot 'home'
  $missingCodex = Join-Path $missingHome '.codex'
  $missingAgents = Join-Path $missingCodex 'AGENTS.md'
  $missingBash = Join-Path $missingRoot 'bash.exe'
  New-Item -ItemType Directory -Force -Path $missingCodex | Out-Null
  [System.IO.File]::WriteAllBytes($missingBash, [byte[]](0x42, 0x41, 0x53, 0x48))
  $missingJob = Start-IntegrationJob -Arguments (New-CommonArguments -FixtureHome $missingHome -Bash $missingBash)
  [void](Wait-TemporaryGuidance -Directory $missingCodex)
  [System.IO.File]::WriteAllText($missingAgents, 'concurrent-create-wins', [System.Text.UTF8Encoding]::new($false))
  $missingResult = Finish-Job -Job $missingJob -Name 'missing-file guidance race'
  if ($missingResult.ExitCode -eq 0) { throw 'guidance create-new race unexpectedly overwrote a concurrent file' }
  $missingText = [System.IO.File]::ReadAllText($missingAgents, [System.Text.UTF8Encoding]::new($false))
  if ($missingText -cne 'concurrent-create-wins') { throw 'concurrent create file was modified after the guidance race' }

  Write-Output 'FastCtx guidance existing-file lock and missing-file create-new race regressions passed'
} finally {
  [Environment]::SetEnvironmentVariable('FASTCTX_TEST_GUIDANCE_COMMIT_DELAY_MS', $savedDelay, 'Process')
  Get-Job | Where-Object { $_.State -eq 'Running' } | Stop-Job -ErrorAction SilentlyContinue
  Get-Job | Where-Object { $_.State -ne 'Running' } | Remove-Job -Force -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 500
  Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
