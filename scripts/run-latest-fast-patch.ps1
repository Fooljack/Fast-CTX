[CmdletBinding()]
param(
  [string]$SkillDir,
  [Alias('Owner')]
  [string]$UpstreamOwner = 'chen0416ccc-cpu',
  [Alias('Repo')]
  [string]$UpstreamRepo = 'codex-windows-fast-patch-skill',
  [Alias('Branch')]
  [string]$UpstreamBranch = 'main',
  [string]$ReportRemoteUrl = 'https://github.com/Fooljack/Fast-CTX.git',
  [string]$ReportBranch = 'main',
  [string]$ReportCheckout,
  [string]$OutputRoot,
  [switch]$DryRunOnly,
  [switch]$SkipFastVerify,
  [switch]$SkipPublish,
  [switch]$PublishOnProblems,
  [switch]$KeepBuild,
  [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
$LogPrefix = '[codex-fast-patch-run]'
$StartTime = Get-Date
$Problems = New-Object System.Collections.Generic.List[string]
$MainScriptExitCode = $null
$DryRunOutput = ''
$InstallOutput = ''
$FinalDryRunOutput = ''
$ComputerUseOutput = ''
$StrictOutput = ''
$PluginListOutput = ''
$SandboxOutput = ''
$SandboxCommand = ''
$HardeningOutput = ''
$FastCtxOutput = ''
$ArchiveOutput = ''
$ArchiveResult = 'not-run'
$PackageBefore = $null
$PackageAfter = $null
$SelfUpdateResult = 'not-run'
$SkillSha = ''
$RunRecordPath = ''

function Write-Log {
  param([string]$Message)
  Write-Host "$LogPrefix $Message"
}

function Add-Problem {
  param([string]$Message)
  $Problems.Add($Message) | Out-Null
  Write-Log "problem: $Message"
}

function Get-PublishEligibilityBlockers {
  $blockers = New-Object System.Collections.Generic.List[string]
  if ($DryRunOnly) { $blockers.Add('-DryRunOnly was used') | Out-Null }
  if ($NoLaunch) { $blockers.Add('-NoLaunch was used') | Out-Null }
  if ($SkipFastVerify) { $blockers.Add('-SkipFastVerify was used') | Out-Null }
  return @($blockers)
}

function Resolve-SkillRoot {
  if (-not [string]::IsNullOrWhiteSpace($SkillDir)) {
    return (Resolve-Path -LiteralPath $SkillDir -ErrorAction Stop).ProviderPath
  }
  if ($PSScriptRoot) {
    return (Resolve-Path -LiteralPath (Split-Path -Parent $PSScriptRoot) -ErrorAction Stop).ProviderPath
  }
  return (Resolve-Path -LiteralPath (Join-Path $env:USERPROFILE '.codex\skills\codex-windows-fast-patch') -ErrorAction Stop).ProviderPath
}

function Get-WindowsPowerShell {
  $path = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Windows PowerShell not found: $path"
  }
  return $path
}

function Invoke-WindowsPowerShell {
  param(
    [string]$ScriptPath,
    [string[]]$Arguments = @(),
    [switch]$AllowFailure
  )

  $ps = Get-WindowsPowerShell
  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = & $ps -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments 2>&1 | Out-String
    $exit = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }
  if ($exit -ne 0 -and -not $AllowFailure) {
    throw "command failed ($exit): $ScriptPath $($Arguments -join ' ')`n$output"
  }
  return [pscustomobject]@{
    ExitCode = $exit
    Output = $output.TrimEnd()
  }
}

function Invoke-WindowsPowerShellCommand {
  param(
    [string]$Command,
    [switch]$AllowFailure
  )

  $ps = Get-WindowsPowerShell
  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = & $ps -NoProfile -ExecutionPolicy Bypass -Command $Command 2>&1 | Out-String
    $exit = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }
  if ($exit -ne 0 -and -not $AllowFailure) {
    throw "command failed ($exit): $Command`n$output"
  }
  return [pscustomobject]@{
    ExitCode = $exit
    Output = $output.TrimEnd()
  }
}

function Get-CodexPackageStatus {
  $command = @'
$pkg = Get-AppxPackage -Name OpenAI.Codex -ErrorAction Stop | Select-Object -First 1
[pscustomobject]@{
  PackageFullName = $pkg.PackageFullName
  PackageFamilyName = $pkg.PackageFamilyName
  Version = [string]$pkg.Version
  SignatureKind = [string]$pkg.SignatureKind
  InstallLocation = $pkg.InstallLocation
} | ConvertTo-Json -Compress
'@
  $result = Invoke-WindowsPowerShellCommand -Command $command
  return $result.Output | ConvertFrom-Json
}

function Start-CodexDesktop {
  $pkg = Get-CodexPackageStatus
  $family = $pkg.PackageFamilyName
  $appId = "$family!App"
  Start-Process explorer.exe "shell:AppsFolder\$appId"
  Start-Sleep -Seconds 10
}

function Get-DesktopProcessSummary {
  $processes = Get-Process -Name Codex,ChatGPT -ErrorAction SilentlyContinue |
    Where-Object {
      $_.Path -and
      $_.Path -like '*\WindowsApps\OpenAI.Codex_*\app\*.exe' -and
      (Split-Path -Leaf $_.Path) -in @('Codex.exe', 'ChatGPT.exe')
    } |
    Select-Object -First 5 Id, Path
  if (-not $processes) {
    return 'no WindowsApps Codex/ChatGPT desktop process found'
  }
  return (($processes | ForEach-Object { "pid=$($_.Id) path=$($_.Path)" }) -join "`n")
}

function Invoke-SandboxSmokeTest {
  $help = codex sandbox --help 2>&1 | Out-String
  $useWindowsSubcommand = $false
  if ($LASTEXITCODE -eq 0) {
    $useWindowsSubcommand = (
      ($help -match '(?im)^\s+windows(?:\s|$)') -or
      ($help -match '(?i)Usage:\s+codex sandbox windows\b')
    )
  }

  if ($useWindowsSubcommand) {
    $script:SandboxCommand = 'codex sandbox windows "C:\Windows\System32\cmd.exe" /c echo OK'
    $output = codex sandbox windows 'C:\Windows\System32\cmd.exe' /c echo OK 2>&1 | Out-String
  } else {
    $script:SandboxCommand = 'codex sandbox "C:\Windows\System32\cmd.exe" /c echo OK'
    $output = codex sandbox 'C:\Windows\System32\cmd.exe' /c echo OK 2>&1 | Out-String
  }

  return [pscustomobject]@{
    ExitCode = $LASTEXITCODE
    Command = $script:SandboxCommand
    Output = $output.TrimEnd()
  }
}

function Get-SkillSha {
  param([string]$Root)
  $path = Join-Path $Root '.skill-version'
  if (Test-Path -LiteralPath $path -PathType Leaf) {
    return (Get-Content -Raw -LiteralPath $path).Trim()
  }
  return '<missing>'
}

function Write-RunRecord {
  $finish = Get-Date
  $runRoot = Join-Path $env:USERPROFILE '.codex\codex-windows-fast-patch-runs'
  New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
  if ([string]::IsNullOrWhiteSpace($script:RunRecordPath)) {
    $stamp = $finish.ToString('yyyyMMdd-HHmmss')
    $script:RunRecordPath = Join-Path $runRoot "$stamp.md"
  }
  $latestPath = Join-Path $runRoot 'latest.md'
  $problemsText = if ($Problems.Count) {
    ($Problems | ForEach-Object { "- $_" }) -join "`r`n"
  } else {
    '- None'
  }
  $beforeText = if ($PackageBefore) {
    @"
- PackageFullName: $($PackageBefore.PackageFullName)
- Version: $($PackageBefore.Version)
- SignatureKind: $($PackageBefore.SignatureKind)
- InstallLocation: $($PackageBefore.InstallLocation)
"@
  } else {
    '- unavailable'
  }
  $afterText = if ($PackageAfter) {
    @"
- PackageFullName: $($PackageAfter.PackageFullName)
- Version: $($PackageAfter.Version)
- SignatureKind: $($PackageAfter.SignatureKind)
- InstallLocation: $($PackageAfter.InstallLocation)
"@
  } else {
    '- unavailable'
  }
  $workflowMode = if ($DryRunOnly) {
    'run-latest-fast-patch.ps1 DryRunOnly validation'
  } else {
    'run-latest-fast-patch.ps1 default Fast/browser/Computer Use repair'
  }
  $sandboxCommandText = if ([string]::IsNullOrWhiteSpace($SandboxCommand)) {
    'codex sandbox <auto-detected> "C:\Windows\System32\cmd.exe" /c echo OK'
  } else {
    $SandboxCommand
  }
  $content = @"
# Codex Windows Fast Patch Run

- Started: $($StartTime.ToString('yyyy-MM-dd HH:mm:ss zzz'))
- Finished: $($finish.ToString('yyyy-MM-dd HH:mm:ss zzz'))
- Active skill root: $SkillRoot
- Upstream skill source: $UpstreamOwner/$UpstreamRepo@$UpstreamBranch
- Private archive remote: $ReportRemoteUrl@$ReportBranch
- Final skill SHA: $SkillSha
- Self-update result: $SelfUpdateResult
- Private archive result: $ArchiveResult
- Selected workflow: $workflowMode
- Main install exit code: $MainScriptExitCode

## Codex Package Before

$beforeText

## Codex Package After

$afterText

## Version Correspondence

- MSIX dry run was executed before install.
- Dry-run summary:
``````text
$DryRunOutput
``````

## Commands Used

- scripts\update-skill-from-github.ps1 -SkillDir "$SkillRoot" -Owner "$UpstreamOwner" -Repo "$UpstreamRepo" -Branch "$UpstreamBranch"
- scripts\apply-local-hardening.ps1 -SkillDir "$SkillRoot"
- scripts\configure-fastctx.ps1 -VerifyOnly
- scripts\manage-codex-backups.ps1 -Action Backup
- codex plugin list
- scripts\install-computer-use-local.ps1 -VerifyOnly
- scripts\install-computer-use-local.ps1 -StrictVerifyOnly -VerifyAllBundledPluginsAvailable
- scripts\repatch-codex-windows.ps1 -DryRun
- scripts\repatch-codex-windows.ps1 -SkipComputerUse (skipped when -DryRunOnly is set)
- shell:AppsFolder launch fallback when needed
- scripts\patch_codex_fast_mode_windows_msix.ps1 -DryRun -ForceRebuild -VerifyFastModeRequest
- $sandboxCommandText

## Problems And Resolutions

$problemsText

## Final Validation

- Package status:
``````text
$afterText
``````
- Plugin list:
``````text
$PluginListOutput
``````
- Computer Use final strict verification:
``````text
$StrictOutput
``````
- Final live patch and Fast wire verification:
``````text
$FinalDryRunOutput
``````
- Sandbox smoke test:
``````text
$SandboxOutput
``````
- Desktop process summary:
``````text
$(Get-DesktopProcessSummary)
``````
- Local hardening output:
``````text
$HardeningOutput
``````
- FastCtx verification:
``````text
$FastCtxOutput
``````
- Private archive output:
``````text
$ArchiveOutput
``````
"@
  Set-Content -LiteralPath $RunRecordPath -Value $content -Encoding UTF8
  Set-Content -LiteralPath $latestPath -Value $content -Encoding UTF8
  Write-Log "run record written: $RunRecordPath"
}

function Publish-VerifiedChain {
  if ($SkipPublish) {
    $script:ArchiveResult = 'skipped by -SkipPublish'
    return
  }
  $eligibilityBlockers = @(Get-PublishEligibilityBlockers)
  if ($eligibilityBlockers.Count -gt 0 -and -not $PublishOnProblems) {
    $script:ArchiveResult = 'skipped because the run is not publishable: ' + ($eligibilityBlockers -join '; ')
    return
  }
  if ($Problems.Count -gt 0 -and -not $PublishOnProblems) {
    $script:ArchiveResult = "skipped because $($Problems.Count) problem(s) were recorded"
    return
  }

  $publishScript = Join-Path $SkillRoot 'scripts\publish-verified-chain.ps1'
  if (-not (Test-Path -LiteralPath $publishScript -PathType Leaf)) {
    $script:ArchiveResult = 'skipped because publish-verified-chain.ps1 is missing'
    Add-Problem $script:ArchiveResult
    return
  }

  $publishArgs = @(
    '-SkillDir', $SkillRoot,
    '-ReportRemoteUrl', $ReportRemoteUrl,
    '-ReportBranch', $ReportBranch,
    '-RunRecordPath', $RunRecordPath
  )
  if (-not [string]::IsNullOrWhiteSpace($ReportCheckout)) {
    $publishArgs += @('-ReportCheckout', $ReportCheckout)
  }
  $publish = Invoke-WindowsPowerShell -ScriptPath $publishScript -Arguments $publishArgs -AllowFailure
  $script:ArchiveOutput = $publish.Output
  if ($publish.ExitCode -eq 0) {
    $script:ArchiveResult = 'archived'
  } else {
    $script:ArchiveResult = "failed with exit code $($publish.ExitCode)"
    Add-Problem "private archive failed: $script:ArchiveOutput"
  }
}

function Complete-Run {
  $script:ArchiveResult = if ($SkipPublish) { 'skipped by -SkipPublish' } else { 'pending publish eligibility check' }
  Write-RunRecord
  Publish-VerifiedChain
  Write-RunRecord
}

$SkillRoot = Resolve-SkillRoot
try {
  Write-Log "active skill root: $SkillRoot"

  $updateScript = Join-Path $SkillRoot 'scripts\update-skill-from-github.ps1'
  $update = Invoke-WindowsPowerShell -ScriptPath $updateScript -Arguments @('-SkillDir', $SkillRoot, '-Owner', $UpstreamOwner, '-Repo', $UpstreamRepo, '-Branch', $UpstreamBranch) -AllowFailure
  $SelfUpdateResult = if ($update.Output -match 'updated skill from GitHub') {
    'updated'
  } elseif ($update.Output -match 'already up to date') {
    'already up to date'
  } else {
    "failed or skipped: $($update.Output)"
  }
  if ($update.ExitCode -ne 0) {
    Add-Problem "self-update returned exit code $($update.ExitCode); continued with local copy"
  }

  $hardeningScript = Join-Path $SkillRoot 'scripts\apply-local-hardening.ps1'
  if (Test-Path -LiteralPath $hardeningScript -PathType Leaf) {
    $hardening = Invoke-WindowsPowerShell -ScriptPath $hardeningScript -Arguments @('-SkillDir', $SkillRoot) -AllowFailure
    $HardeningOutput = $hardening.Output
    if ($hardening.ExitCode -ne 0) {
      Add-Problem "local hardening returned exit code $($hardening.ExitCode): $($hardening.Output)"
    }
  }

  $fastCtxScript = Join-Path $SkillRoot 'scripts\configure-fastctx.ps1'
  if (Test-Path -LiteralPath $fastCtxScript -PathType Leaf) {
    $fastCtx = Invoke-WindowsPowerShell -ScriptPath $fastCtxScript -Arguments @('-VerifyOnly') -AllowFailure
    $FastCtxOutput = $fastCtx.Output
    if ($fastCtx.ExitCode -ne 0) {
      Add-Problem "FastCtx verification returned exit code $($fastCtx.ExitCode): $($fastCtx.Output)"
    }
  } else {
    Add-Problem 'FastCtx verification script is missing'
  }

  $SkillSha = Get-SkillSha $SkillRoot
  $PackageBefore = Get-CodexPackageStatus
  Write-Log "Codex before: $($PackageBefore.PackageFullName) signature=$($PackageBefore.SignatureKind)"

  $backup = Invoke-WindowsPowerShell -ScriptPath (Join-Path $SkillRoot 'scripts\manage-codex-backups.ps1') -Arguments @('-Action', 'Backup') -AllowFailure
  if ($backup.ExitCode -ne 0) {
    Add-Problem "backup returned exit code $($backup.ExitCode): $($backup.Output)"
  }

  $PluginListOutput = (codex plugin list 2>&1 | Out-String).TrimEnd()
  if ($LASTEXITCODE -ne 0) {
    Add-Problem "initial codex plugin list failed; Computer Use local repair will rebuild bundled marketplace"
  }

  $verify = Invoke-WindowsPowerShell -ScriptPath (Join-Path $SkillRoot 'scripts\install-computer-use-local.ps1') -Arguments @('-VerifyOnly') -AllowFailure
  $ComputerUseOutput = $verify.Output
  if ($verify.ExitCode -ne 0) {
    Add-Problem "Computer Use VerifyOnly returned exit code $($verify.ExitCode): $($verify.Output)"
  }

  $strict = Invoke-WindowsPowerShell -ScriptPath (Join-Path $SkillRoot 'scripts\install-computer-use-local.ps1') -Arguments @('-StrictVerifyOnly', '-VerifyAllBundledPluginsAvailable') -AllowFailure
  $StrictOutput = $strict.Output
  if ($strict.ExitCode -ne 0) {
    Add-Problem "Computer Use StrictVerifyOnly returned exit code $($strict.ExitCode) after VerifyOnly"
  }

  $dryArgs = @('-DryRun')
  if (-not [string]::IsNullOrWhiteSpace($OutputRoot)) {
    $dryArgs += @('-OutputRoot', $OutputRoot)
  }
  $dry = Invoke-WindowsPowerShell -ScriptPath (Join-Path $SkillRoot 'scripts\repatch-codex-windows.ps1') -Arguments $dryArgs
  $DryRunOutput = $dry.Output

  if ($DryRunOnly) {
    Write-Log 'DryRunOnly set; skipping package reinstall and desktop relaunch'
    $MainScriptExitCode = 0

    $finalArgs = @('-DryRun', '-ForceRebuild')
    if (-not $KeepBuild) {
      $finalArgs += '-CleanupAfter'
    }
    if (-not $SkipFastVerify) {
      $finalArgs += '-VerifyFastModeRequest'
    }
    if (-not [string]::IsNullOrWhiteSpace($OutputRoot)) {
      $finalArgs += @('-OutputRoot', $OutputRoot)
    }
    $final = Invoke-WindowsPowerShell -ScriptPath (Join-Path $SkillRoot 'scripts\patch_codex_fast_mode_windows_msix.ps1') -Arguments $finalArgs -AllowFailure
    $FinalDryRunOutput = $final.Output
    if ($final.ExitCode -ne 0) {
      Add-Problem "final live dry run returned exit code $($final.ExitCode)"
    }

    $PluginListOutput = (codex plugin list 2>&1 | Out-String).TrimEnd()
    if ($LASTEXITCODE -ne 0) {
      Add-Problem "final codex plugin list failed"
    }

    $sandbox = Invoke-SandboxSmokeTest
    $SandboxOutput = "Command: $($sandbox.Command)`n$($sandbox.Output)"
    if ($sandbox.ExitCode -ne 0) {
      Add-Problem "Windows sandbox smoke test failed: $($sandbox.Command)"
    }

    $PackageAfter = Get-CodexPackageStatus
    Complete-Run
    if ($Problems.Count -gt 0) {
      Write-Log "dry-run completed with recorded problems: $($Problems.Count)"
    } else {
      Write-Log 'dry-run completed successfully'
    }
    return
  }

  $installArgs = @('-SkipComputerUse')
  if ($NoLaunch) {
    $installArgs += '-NoLaunch'
  }
  if ($KeepBuild) {
    $installArgs += '-KeepBuild'
  }
  if ($SkipFastVerify) {
    $installArgs += '-SkipFastVerify'
  }
  if (-not [string]::IsNullOrWhiteSpace($OutputRoot)) {
    $installArgs += @('-OutputRoot', $OutputRoot)
  }
  $install = Invoke-WindowsPowerShell -ScriptPath (Join-Path $SkillRoot 'scripts\repatch-codex-windows.ps1') -Arguments $installArgs -AllowFailure
  $MainScriptExitCode = $install.ExitCode
  $InstallOutput = $install.Output
  if ($install.ExitCode -ne 0) {
    Add-Problem "main repatch returned exit code $($install.ExitCode). If output shows only a launch denial after installed package, launch fallback is used. Output: $($install.Output)"
  }

  if (-not $NoLaunch) {
    Start-CodexDesktop
  }

  $postVerify = Invoke-WindowsPowerShell -ScriptPath (Join-Path $SkillRoot 'scripts\install-computer-use-local.ps1') -Arguments @('-VerifyOnly') -AllowFailure
  if ($postVerify.ExitCode -ne 0) {
    Add-Problem "post-launch Computer Use VerifyOnly returned exit code $($postVerify.ExitCode): $($postVerify.Output)"
  }
  $postStrict = Invoke-WindowsPowerShell -ScriptPath (Join-Path $SkillRoot 'scripts\install-computer-use-local.ps1') -Arguments @('-StrictVerifyOnly', '-VerifyAllBundledPluginsAvailable') -AllowFailure
  $StrictOutput = $postStrict.Output
  if ($postStrict.ExitCode -ne 0) {
    Add-Problem "post-launch Computer Use StrictVerifyOnly returned exit code $($postStrict.ExitCode)"
  }

  $PluginListOutput = (codex plugin list 2>&1 | Out-String).TrimEnd()
  if ($LASTEXITCODE -ne 0) {
    Add-Problem "final codex plugin list failed"
  }

  $finalArgs = @('-DryRun', '-ForceRebuild')
  if (-not $KeepBuild) {
    $finalArgs += '-CleanupAfter'
  }
  if (-not $SkipFastVerify) {
    $finalArgs += '-VerifyFastModeRequest'
  }
  if (-not [string]::IsNullOrWhiteSpace($OutputRoot)) {
    $finalArgs += @('-OutputRoot', $OutputRoot)
  }
  $final = Invoke-WindowsPowerShell -ScriptPath (Join-Path $SkillRoot 'scripts\patch_codex_fast_mode_windows_msix.ps1') -Arguments $finalArgs -AllowFailure
  $FinalDryRunOutput = $final.Output
  if ($final.ExitCode -ne 0) {
    Add-Problem "final live dry run returned exit code $($final.ExitCode)"
  }

  $sandbox = Invoke-SandboxSmokeTest
  $SandboxOutput = "Command: $($sandbox.Command)`n$($sandbox.Output)"
  if ($sandbox.ExitCode -ne 0) {
    Add-Problem "Windows sandbox smoke test failed: $($sandbox.Command)"
  }

  $PackageAfter = Get-CodexPackageStatus
  if ($PackageAfter.SignatureKind -ne 'Developer') {
    Add-Problem "final package signature is not Developer: $($PackageAfter.SignatureKind)"
  }

  Complete-Run
  if ($Problems.Count -gt 0) {
    Write-Log "completed with recorded problems: $($Problems.Count)"
  } else {
    Write-Log 'completed successfully'
  }
} catch {
  Add-Problem $_.Exception.Message
  try {
    $PackageAfter = Get-CodexPackageStatus
  } catch {
  }
  Complete-Run
  throw
}
