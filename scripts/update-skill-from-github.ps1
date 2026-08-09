[CmdletBinding()]
param(
  [string]$Owner = 'chen0416ccc-cpu',
  [string]$Repo = 'codex-windows-fast-patch-skill',
  [string]$Branch = 'main',
  [string]$SkillDir,
  [string[]]$ProtectedRelativePath = @(
    '.gitignore',
    'agents/openai.yaml',
    'scripts/update-skill-from-github.ps1',
    'scripts/run-latest-fast-patch.ps1',
    'scripts/apply-local-hardening.ps1',
    'scripts/publish-verified-chain.ps1',
    'scripts/configure-fastctx.ps1',
    'scripts/test-bundled-plugin-version-drift.ps1',
    'scripts/test-chrome-app-server-config.ps1',
    'scripts/test-chrome-native-host-origin-drift.ps1',
    'scripts/test-chrome-native-host-v2-state.ps1',
    'scripts/test-computer-use-patcher-generation.ps1',
    'scripts/test-configure-fastctx-verify-read-only.ps1',
    'scripts/test-local-hardening-idempotence.ps1',
    'scripts/test-publish-git-identity-fallback.ps1',
    'scripts/test-repatch-dry-run-cleanup-arguments.ps1',
    'scripts/test-run-latest-publish-eligibility.ps1',
    'references/fastctx-windows-integration.md',
    'references/fastctx-local-hardening.patch'
  ),
  [switch]$CheckOnly,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
$LogPrefix = '[codex-skill-self-update]'

function Write-Log {
  param([string]$Message)
  Write-Host "$LogPrefix $Message"
}

function Get-GitCommand {
  return (Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Test-GitHubProxyFailure {
  param([string]$Output)
  return ($Output -match '127\.0\.0\.1' -or
    $Output -match 'Could not connect to server' -or
    $Output -match 'Failed to connect to github\.com' -or
    $Output -match '(?i)socks|proxy')
}

function Invoke-GitHubGit {
  param(
    [string[]]$Arguments,
    [switch]$RetryWithoutDeadProxy
  )

  $git = Get-GitCommand
  if (-not $git) {
    return [pscustomobject]@{
      ExitCode = 127
      Output = 'git.exe not found'
    }
  }

  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = (& $git.Source @Arguments 2>&1 | Out-String).TrimEnd()
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }

  if ($exitCode -ne 0 -and $RetryWithoutDeadProxy -and (Test-GitHubProxyFailure $output)) {
    Write-Log 'git command hit a dead GitHub proxy; retrying this command without GitHub proxy'
    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      $output = (& $git.Source -c 'http.https://github.com.proxy=' -c 'https.https://github.com.proxy=' @Arguments 2>&1 | Out-String).TrimEnd()
      $exitCode = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $oldErrorActionPreference
    }
  }

  return [pscustomobject]@{
    ExitCode = $exitCode
    Output = $output
  }
}

function Resolve-OrCreateDirectory {
  param([string]$Path)
  New-Item -ItemType Directory -Force -Path $Path | Out-Null
  return (Resolve-Path -LiteralPath $Path).ProviderPath
}

function Assert-UnderPath {
  param(
    [string]$Path,
    [string]$Parent
  )
  $full = [System.IO.Path]::GetFullPath($Path)
  $root = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
  if (-not $full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "refusing to update path outside skill root: $full"
  }
}

function Get-RemoteHeadSha {
  param(
    [string]$Owner,
    [string]$Repo,
    [string]$Branch
  )

  $apiUrl = "https://api.github.com/repos/$Owner/$Repo/commits/$Branch"
  try {
    $response = Invoke-RestMethod -Uri $apiUrl -Headers @{ 'User-Agent' = 'codex-skill-self-update' } -ErrorAction Stop
    if ($response.sha) {
      return [string]$response.sha
    }
  } catch {
    Write-Log "GitHub API check failed, trying git ls-remote: $($_.Exception.Message)"
  }

  $remote = "https://github.com/$Owner/$Repo.git"
  $lsRemote = Invoke-GitHubGit -Arguments @('ls-remote', $remote, "refs/heads/$Branch") -RetryWithoutDeadProxy
  if ($lsRemote.ExitCode -eq 0) {
    $line = ($lsRemote.Output -split "\r?\n" | Select-Object -First 1)
    if ($line -match '^([0-9a-fA-F]{40})\s+') {
      return $matches[1]
    }
  }

  throw "could not resolve remote head for $Owner/$Repo@$Branch"
}

function Sync-Directory {
  param(
    [string]$Source,
    [string]$Destination,
    [string]$AllowedRoot,
    [string[]]$ExcludeFileNames = @()
  )

  if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
    return
  }

  Assert-UnderPath $Destination $AllowedRoot
  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  $args = @($Source, $Destination, '/MIR', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
  if ($ExcludeFileNames.Count -gt 0) {
    $args += '/XF'
    $args += $ExcludeFileNames
  }
  & robocopy.exe @args | Out-Null
  if ($LASTEXITCODE -gt 7) {
    throw "robocopy failed while syncing $Source to $Destination (exit code $LASTEXITCODE)"
  }
}

function Copy-AllowedFile {
  param(
    [string]$Source,
    [string]$Destination,
    [string]$AllowedRoot
  )

  if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
    return
  }

  Assert-UnderPath $Destination $AllowedRoot
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
  Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function Invoke-LocalHardening {
  param([string]$Root)

  $hardeningScript = Join-Path $Root 'scripts\apply-local-hardening.ps1'
  if (-not (Test-Path -LiteralPath $hardeningScript -PathType Leaf)) {
    return
  }

  Write-Log 'applying local hardening overlay after upstream sync'
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hardeningScript -SkillDir $Root
  if ($LASTEXITCODE -ne 0) {
    throw "local hardening overlay failed with exit code $LASTEXITCODE"
  }
}

try {
  if ([string]::IsNullOrWhiteSpace($SkillDir)) {
    if (-not $PSScriptRoot) {
      throw 'cannot infer skill directory because PSScriptRoot is empty'
    }
    $SkillDir = Split-Path -Parent $PSScriptRoot
  }

  $skillRoot = Resolve-OrCreateDirectory $SkillDir
  $versionPath = Join-Path $skillRoot '.skill-version'
  $remoteSha = Get-RemoteHeadSha -Owner $Owner -Repo $Repo -Branch $Branch
  $localSha = ''
  if (Test-Path -LiteralPath $versionPath -PathType Leaf) {
    $localSha = (Get-Content -LiteralPath $versionPath -Raw).Trim()
  } elseif (Test-Path -LiteralPath (Join-Path $skillRoot '.git') -PathType Container) {
    $git = Get-GitCommand
    if ($git) {
      Push-Location $skillRoot
      try {
        $localSha = (& $git.Source rev-parse HEAD 2>$null).Trim()
      } finally {
        Pop-Location
      }
    }
  }

  if ($CheckOnly) {
    if ($localSha -eq $remoteSha) {
      Write-Log "already up to date: $remoteSha"
    } else {
      Write-Log "update available: local=$(if ($localSha) { $localSha } else { '<unknown>' }) remote=$remoteSha"
    }
    exit 0
  }

  if (-not $Force -and $localSha -eq $remoteSha) {
    try {
      Invoke-LocalHardening -Root $skillRoot
      Write-Log "already up to date: $remoteSha"
      exit 0
    } catch {
      Write-Log "local content verification failed; forcing a clean upstream refresh: $($_.Exception.Message)"
      $Force = $true
    }
  }

  $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('codex-skill-update-' + [guid]::NewGuid().ToString('N'))
  $zipPath = Join-Path $tempRoot 'source.zip'
  New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
  try {
    $sourceRoot = $null
    $git = Get-GitCommand
    if ($git) {
      $remote = "https://github.com/$Owner/$Repo.git"
      $cloneRoot = Join-Path $tempRoot 'source'
      Write-Log "cloning latest skill: $Owner/$Repo@$Branch"
      $clone = Invoke-GitHubGit -Arguments @('clone', '--depth', '1', '--branch', $Branch, $remote, $cloneRoot) -RetryWithoutDeadProxy
      if ($clone.ExitCode -eq 0 -and (Test-Path -LiteralPath (Join-Path $cloneRoot 'SKILL.md') -PathType Leaf)) {
        $sourceRoot = Get-Item -LiteralPath $cloneRoot
        $cloneSha = (& $git.Source -C $cloneRoot rev-parse HEAD 2>$null).Trim()
        if ($cloneSha -match '^[0-9a-fA-F]{40}$') {
          $remoteSha = $cloneSha
        }
      } else {
        Write-Log "git clone update path failed, trying GitHub archive download: $($clone.Output)"
      }
    }

    if (-not $sourceRoot) {
      $archiveUrl = "https://codeload.github.com/$Owner/$Repo/zip/refs/heads/$Branch"
      Write-Log "downloading latest skill: $Owner/$Repo@$Branch"
      Invoke-WebRequest -Uri $archiveUrl -OutFile $zipPath -UseBasicParsing -Headers @{ 'User-Agent' = 'codex-skill-self-update' }
      Expand-Archive -LiteralPath $zipPath -DestinationPath $tempRoot -Force
      $sourceRoot = Get-ChildItem -LiteralPath $tempRoot -Directory | Where-Object { $_.Name -ne 'source' } | Select-Object -First 1
    }
    if (-not $sourceRoot) {
      throw 'downloaded archive did not contain a source directory'
    }

    $sourceSkill = Join-Path $sourceRoot.FullName 'SKILL.md'
    if (-not (Test-Path -LiteralPath $sourceSkill -PathType Leaf)) {
      throw 'downloaded archive is missing SKILL.md'
    }

    foreach ($fileName in @('SKILL.md')) {
      if ($ProtectedRelativePath -contains $fileName) {
        Write-Log "preserving local protected file: $fileName"
        continue
      }
      Copy-AllowedFile -Source (Join-Path $sourceRoot.FullName $fileName) -Destination (Join-Path $skillRoot $fileName) -AllowedRoot $skillRoot
    }

    foreach ($dirName in @('agents', 'scripts', 'references', 'assets')) {
      $excludeNames = @(
        $ProtectedRelativePath |
          Where-Object { (Split-Path -Parent $_) -eq $dirName } |
          ForEach-Object { Split-Path -Leaf $_ }
      )
      Sync-Directory -Source (Join-Path $sourceRoot.FullName $dirName) -Destination (Join-Path $skillRoot $dirName) -AllowedRoot $skillRoot -ExcludeFileNames $excludeNames
    }

    Invoke-LocalHardening -Root $skillRoot

    Set-Content -LiteralPath $versionPath -Value ($remoteSha + "`n") -Encoding UTF8
    Write-Log "updated skill from GitHub: $remoteSha"
    Write-Log 'reload SKILL.md before continuing'
  } finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
} catch {
  Write-Log "warning: self-update skipped: $($_.Exception.Message)"
  exit 1
}
