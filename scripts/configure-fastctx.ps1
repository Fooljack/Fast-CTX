[CmdletBinding()]
param(
  [string]$FastCtxBinary,
  [string]$GitBash,
  [string]$NativeHome,
  [string]$CodexHome,
  [string]$FastCtxHome,
  [string]$ClaudeConfigDir,
  [string]$ClaudeCommand,
  [string]$ExpectedSha256,
  [switch]$SkipClaudeCode,
  [switch]$SkipCcSwitch,
  [switch]$NoLaunchCcSwitch,
  [switch]$RequireCcSwitch,
  [switch]$ForceMcpRegistration,
  [switch]$VerifyOnly,
  [switch]$ForceBinary
)

$ErrorActionPreference = 'Stop'
$LogPrefix = '[fastctx-configure]'

function Resolve-ProfilePath {
  param(
    [string]$Explicit,
    [string]$Ambient,
    [Parameter(Mandatory = $true)][string]$Fallback,
    [Parameter(Mandatory = $true)][string]$Name
  )
  $chosen = if (-not [string]::IsNullOrWhiteSpace($Explicit)) { $Explicit } elseif (-not [string]::IsNullOrWhiteSpace($Ambient)) { $Ambient } else { $Fallback }
  if ([string]::IsNullOrWhiteSpace($chosen)) { throw "$Name is required for a stable Windows FastCtx installation." }
  return [System.IO.Path]::GetFullPath($chosen)
}

$NativeHome = Resolve-ProfilePath -Explicit $NativeHome -Ambient $env:USERPROFILE -Fallback $env:USERPROFILE -Name 'NativeHome'
$CodexHome = Resolve-ProfilePath -Explicit $CodexHome -Ambient $env:CODEX_HOME -Fallback (Join-Path $NativeHome '.codex') -Name 'CodexHome'
$FastCtxHome = Resolve-ProfilePath -Explicit $FastCtxHome -Ambient $null -Fallback (Join-Path $NativeHome '.fastctx') -Name 'FastCtxHome'
if ($SkipCcSwitch -and $RequireCcSwitch) {
  throw 'SkipCcSwitch and RequireCcSwitch cannot be used together.'
}
$script:ConfigBackedUp = $false
$script:BinaryTransaction = $null

function Write-Log {
  param([string]$Message)
  Write-Host "$LogPrefix $Message"
}

function Resolve-FullPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  return [System.IO.Path]::GetFullPath($Path)
}

function ConvertTo-TomlBasicString {
  param([Parameter(Mandatory = $true)][string]$Value)
  return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

function Get-Utf8Snapshot {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [switch]$AllowMissing
  )
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    if ($AllowMissing) {
      return [pscustomobject]@{ Exists = $false; Bytes = [byte[]]@(); Text = ''; HasBom = $false }
    }
    throw "required UTF-8 file does not exist: $Path"
  }
  $item = Get-Item -LiteralPath $Path -Force
  if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "refusing to edit a reparse-point configuration file: $Path"
  }
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
  $offset = if ($hasBom) { 3 } else { 0 }
  try {
    $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes, $offset, $bytes.Length - $offset)
  } catch {
    throw "cannot edit $($Path): the file is not valid UTF-8"
  }
  return [pscustomobject]@{ Exists = $true; Bytes = [byte[]]$bytes; Text = $text; HasBom = $hasBom }
}

function Read-Utf8NoBom {
  param([Parameter(Mandatory = $true)][string]$Path)
  return (Get-Utf8Snapshot -Path $Path).Text
}

function Test-ByteArrayEqual {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Left,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Right
  )
  if ($Left.Length -ne $Right.Length) { return $false }
  for ($index = 0; $index -lt $Left.Length; $index++) {
    if ($Left[$index] -ne $Right[$index]) { return $false }
  }
  return $true
}

function ConvertTo-Utf8Bytes {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content,
    [Parameter(Mandatory = $true)][bool]$WithBom
  )
  $body = [System.Text.UTF8Encoding]::new($false).GetBytes($Content)
  if (-not $WithBom) { return [byte[]]$body }
  $bytes = New-Object byte[] ($body.Length + 3)
  $bytes[0] = 0xEF
  $bytes[1] = 0xBB
  $bytes[2] = 0xBF
  [System.Array]::Copy($body, 0, $bytes, 3, $body.Length)
  return [byte[]]$bytes
}

function Write-Utf8NoBomAtomic {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content,
    [Parameter(Mandatory = $true)][bool]$ExpectedExists,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$ExpectedBytes,
    [Parameter(Mandatory = $true)][bool]$WithBom
  )

  $current = Get-Utf8Snapshot -Path $Path -AllowMissing
  if ($current.Exists -ne $ExpectedExists -or -not (Test-ByteArrayEqual -Left $current.Bytes -Right $ExpectedBytes)) {
    throw "configuration file changed after it was read; no update was published: $Path"
  }
  $bytes = ConvertTo-Utf8Bytes -Content $Content -WithBom $WithBom

  $parent = Split-Path -Parent $Path
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  $temporary = Join-Path $parent ('.fastctx-config-' + [guid]::NewGuid().ToString('N') + '.tmp')
  $replacementBackup = Join-Path $parent ('.fastctx-config-' + [guid]::NewGuid().ToString('N') + '.bak')
  try {
    [System.IO.File]::WriteAllBytes($temporary, $bytes)
    $current = Get-Utf8Snapshot -Path $Path -AllowMissing
    if ($current.Exists -ne $ExpectedExists -or -not (Test-ByteArrayEqual -Left $current.Bytes -Right $ExpectedBytes)) {
      throw "configuration file changed before atomic publication; no update was published: $Path"
    }
    if ($ExpectedExists) {
      [System.IO.File]::Replace($temporary, $Path, $replacementBackup)
      Remove-Item -LiteralPath $replacementBackup -Force
    } else {
      [System.IO.File]::Move($temporary, $Path)
    }
  } finally {
    foreach ($artifact in @($temporary, $replacementBackup)) {
      if (Test-Path -LiteralPath $artifact) {
        Remove-Item -LiteralPath $artifact -Force -ErrorAction SilentlyContinue
      }
    }
  }
}

function Backup-CodexConfig {
  param([Parameter(Mandatory = $true)][string]$ConfigPath)
  if ($script:ConfigBackedUp -or -not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    return
  }

  $backupRoot = Join-Path (Split-Path -Parent $ConfigPath) 'backups\config'
  New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
  $backupPath = Join-Path $backupRoot "config.toml.$stamp.fastctx.bak"
  Copy-Item -LiteralPath $ConfigPath -Destination $backupPath -Force
  $script:ConfigBackedUp = $true
  Write-Log "config backup: $backupPath"
}

function Get-Newline {
  param([string]$Content)
  if ($Content.Contains("`r`n")) { return "`r`n" }
  return "`n"
}

function ConvertFrom-TomlKeySegment {
  param([Parameter(Mandatory = $true)][string]$Raw)
  $segment = $Raw.Trim()
  if ($segment.Length -ge 2 -and $segment[0] -eq [char]34 -and $segment[$segment.Length - 1] -eq [char]34) {
    try {
      return [string]($segment | ConvertFrom-Json -ErrorAction Stop)
    } catch {
      throw "invalid TOML quoted key segment: $Raw"
    }
  }
  if ($segment.Length -ge 2 -and $segment[0] -eq [char]39 -and $segment[$segment.Length - 1] -eq [char]39) {
    return $segment.Substring(1, $segment.Length - 2)
  }
  if ($segment -notmatch '^[A-Za-z0-9_-]+$') {
    throw "invalid TOML bare key segment: $Raw"
  }
  return $segment
}

function ConvertFrom-TomlKeyPath {
  param([Parameter(Mandatory = $true)][string]$Raw)
  $segments = New-Object System.Collections.Generic.List[string]
  $start = 0
  $quote = [char]0
  $escaped = $false
  for ($index = 0; $index -lt $Raw.Length; $index++) {
    $character = $Raw[$index]
    if ($quote -ne [char]0) {
      if ($quote -eq [char]34 -and $escaped) {
        $escaped = $false
        continue
      }
      if ($quote -eq [char]34 -and $character -eq [char]92) {
        $escaped = $true
        continue
      }
      if ($character -eq $quote) { $quote = [char]0 }
      continue
    }
    if ($character -eq [char]34 -or $character -eq [char]39) {
      $quote = $character
    } elseif ($character -eq [char]46) {
      $segments.Add((ConvertFrom-TomlKeySegment $Raw.Substring($start, $index - $start)))
      $start = $index + 1
    }
  }
  if ($quote -ne [char]0) { throw "unterminated TOML quoted key: $Raw" }
  $segments.Add((ConvertFrom-TomlKeySegment $Raw.Substring($start)))
  return $segments.ToArray()
}

function Get-TomlHeaderInfo {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Line)
  $trimmed = $Line.Trim()
  $array = $false
  $openingLength = 0
  $closing = $null
  if ($trimmed.StartsWith('[[')) {
    $array = $true
    $openingLength = 2
    $closing = ']]'
  } elseif ($trimmed.StartsWith('[')) {
    $openingLength = 1
    $closing = ']'
  } else {
    return $null
  }
  $quote = [char]0
  $escaped = $false
  $closeIndex = -1
  for ($index = $openingLength; $index -lt $trimmed.Length; $index++) {
    $character = $trimmed[$index]
    if ($quote -ne [char]0) {
      if ($quote -eq [char]34 -and $escaped) {
        $escaped = $false
        continue
      }
      if ($quote -eq [char]34 -and $character -eq [char]92) {
        $escaped = $true
        continue
      }
      if ($character -eq $quote) { $quote = [char]0 }
      continue
    }
    if ($character -eq [char]34 -or $character -eq [char]39) {
      $quote = $character
      continue
    }
    if ($trimmed.Substring($index).StartsWith($closing)) {
      $closeIndex = $index
      break
    }
  }
  if ($closeIndex -lt 0 -or $quote -ne [char]0) { return $null }
  $tail = $trimmed.Substring($closeIndex + $closing.Length).Trim()
  if ($tail.Length -gt 0 -and -not $tail.StartsWith('#')) { return $null }
  try {
    $segments = @(ConvertFrom-TomlKeyPath $trimmed.Substring($openingLength, $closeIndex - $openingLength))
  } catch {
    return $null
  }
  return [pscustomobject]@{
    IsArray = $array
    Segments = $segments
    Canonical = $segments -join '.'
  }
}

function Get-TomlDocumentSections {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content)
  $lines = @($Content -split "\r?\n", -1)
  $sections = New-Object System.Collections.Generic.List[object]
  for ($index = 0; $index -lt $lines.Count; $index++) {
    $header = Get-TomlHeaderInfo -Line $lines[$index]
    if ($null -ne $header) {
      if ($sections.Count -gt 0) { $sections[$sections.Count - 1].End = $index }
      $sections.Add([pscustomobject]@{
          Start = $index
          End = $lines.Count
          Header = $header
      })
    }
  }
  return [pscustomobject]@{ Lines = $lines; Sections = $sections.ToArray() }
}

function Find-TomlDelimiter {
  param(
    [Parameter(Mandatory = $true)][string]$Text,
    [Parameter(Mandatory = $true)][char]$Delimiter
  )
  $quote = [char]0
  $escaped = $false
  for ($index = 0; $index -lt $Text.Length; $index++) {
    $character = $Text[$index]
    if ($quote -ne [char]0) {
      if ($quote -eq [char]34 -and $escaped) { $escaped = $false; continue }
      if ($quote -eq [char]34 -and $character -eq [char]92) { $escaped = $true; continue }
      if ($character -eq $quote) { $quote = [char]0 }
      continue
    }
    if ($character -eq [char]34 -or $character -eq [char]39) { $quote = $character; continue }
    if ($character -eq $Delimiter) { return $index }
  }
  return -1
}

function Remove-TomlInlineComment {
  param([Parameter(Mandatory = $true)][string]$Value)
  $index = Find-TomlDelimiter -Text $Value -Delimiter ([char]35)
  if ($index -lt 0) { return $Value.Trim() }
  return $Value.Substring(0, $index).Trim()
}

function Get-TomlAssignments {
  param(
    [Parameter(Mandatory = $true)]$Document,
    [Parameter(Mandatory = $true)]$Section
  )
  $assignments = New-Object System.Collections.Generic.List[object]
  $invalid = $false
  for ($index = $Section.Start + 1; $index -lt $Section.End; $index++) {
    $line = [string]$Document.Lines[$index]
    $trimmed = $line.Trim()
    if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#')) { continue }
    $equals = Find-TomlDelimiter -Text $line -Delimiter ([char]61)
    if ($equals -lt 0) { $invalid = $true; continue }
    try {
      $keySegments = @(ConvertFrom-TomlKeyPath $line.Substring(0, $equals))
      if ($keySegments.Count -ne 1) { $invalid = $true; continue }
    } catch {
      $invalid = $true
      continue
    }
    $assignments.Add([pscustomobject]@{
        Key = $keySegments[0]
        Value = Remove-TomlInlineComment $line.Substring($equals + 1)
    })
  }
  return [pscustomobject]@{ Assignments = $assignments.ToArray(); Invalid = $invalid }
}

function Test-TomlAssignmentsExact {
  param(
    [Parameter(Mandatory = $true)]$Parsed,
    [Parameter(Mandatory = $true)][hashtable]$Expected
  )
  if ($Parsed.Invalid -or $Parsed.Assignments.Count -ne $Expected.Count) { return $false }
  $seen = @{}
  foreach ($assignment in $Parsed.Assignments) {
    if (-not $Expected.ContainsKey($assignment.Key) -or $seen.ContainsKey($assignment.Key)) { return $false }
    if ($assignment.Value -cne [string]$Expected[$assignment.Key]) { return $false }
    $seen[$assignment.Key] = $true
  }
  return $seen.Count -eq $Expected.Count
}

function Test-FastCtxSection {
  param(
    [Parameter(Mandatory = $true)]$Section,
    [Parameter(Mandatory = $true)]$Document,
    [Parameter(Mandatory = $true)][hashtable]$Expected
  )
  return Test-TomlAssignmentsExact -Parsed (Get-TomlAssignments -Document $Document -Section $Section) -Expected $Expected
}

function Test-IsFastCtxSection {
  param([Parameter(Mandatory = $true)]$Section)
  $segments = $Section.Header.Segments
  return $segments.Count -ge 2 -and $segments[0] -ceq 'mcp_servers' -and $segments[1] -ceq 'fastctx'
}

function Remove-FastCtxTomlSections {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content)
  $document = Get-TomlDocumentSections -Content $Content
  $remove = New-Object bool[] $document.Lines.Count
  foreach ($section in $document.Sections) {
    if (Test-IsFastCtxSection -Section $section) {
      for ($index = $section.Start; $index -lt $section.End; $index++) { $remove[$index] = $true }
    }
  }
  $kept = New-Object System.Collections.Generic.List[string]
  for ($index = 0; $index -lt $document.Lines.Count; $index++) {
    if (-not $remove[$index]) { $kept.Add($document.Lines[$index]) }
  }
  $newline = Get-Newline $Content
  $result = [string]::Join($newline, [string[]]$kept)
  if ($Content.EndsWith($newline) -and -not $result.EndsWith($newline)) { $result += $newline }
  return $result
}

function Update-TomlSection {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content,
    [Parameter(Mandatory = $true)][string]$Header,
    [Parameter(Mandatory = $true)][hashtable]$Values,
    [string[]]$PreserveExistingKeys = @()
  )

  $newline = Get-Newline $Content
  $hadTrailingNewline = $Content.EndsWith($newline)
  $lines = New-Object System.Collections.Generic.List[string]
  foreach ($line in ($Content -split "\r?\n", -1)) {
    $lines.Add($line)
  }
  if ($hadTrailingNewline -and $lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') {
    $lines.RemoveAt($lines.Count - 1)
  }

  $start = -1
  for ($index = 0; $index -lt $lines.Count; $index++) {
    if ($lines[$index] -match ('^\s*' + [regex]::Escape($Header) + '\s*(?:#.*)?$')) {
      $start = $index
      break
    }
  }

  if ($start -lt 0) {
    while ($lines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1])) {
      $lines.RemoveAt($lines.Count - 1)
    }
    if ($lines.Count -gt 0) { $lines.Add('') }
    $lines.Add($Header)
    foreach ($key in ($Values.Keys | Sort-Object)) {
      $lines.Add("$key = $($Values[$key])")
    }
  } else {
    $end = $lines.Count
    for ($index = $start + 1; $index -lt $lines.Count; $index++) {
      if ($lines[$index] -match '^\s*\[.*\]\s*(?:#.*)?$') {
        $end = $index
        break
      }
    }

    $body = New-Object System.Collections.Generic.List[string]
    for ($index = $start + 1; $index -lt $end; $index++) {
      $body.Add($lines[$index])
    }

    foreach ($key in ($Values.Keys | Sort-Object)) {
      $keyPattern = '^\s*' + [regex]::Escape([string]$key) + '\s*='
      $matchIndexes = @()
      for ($index = 0; $index -lt $body.Count; $index++) {
        if ($body[$index] -match $keyPattern) { $matchIndexes += $index }
      }
      if ($matchIndexes.Count -gt 0) {
        if ($PreserveExistingKeys -contains [string]$key) { continue }
        $body[$matchIndexes[0]] = "$key = $($Values[$key])"
        for ($index = $matchIndexes.Count - 1; $index -ge 1; $index--) {
          $body.RemoveAt($matchIndexes[$index])
        }
      } else {
        $body.Add("$key = $($Values[$key])")
      }
    }

    $rebuilt = New-Object System.Collections.Generic.List[string]
    for ($index = 0; $index -lt $start; $index++) { $rebuilt.Add($lines[$index]) }
    $rebuilt.Add($lines[$start])
    foreach ($line in $body) { $rebuilt.Add($line) }
    for ($index = $end; $index -lt $lines.Count; $index++) { $rebuilt.Add($lines[$index]) }
    $lines = $rebuilt
  }

  $result = [string]::Join($newline, [string[]]$lines)
  if ($hadTrailingNewline -or $result.Length -gt 0) { $result += $newline }
  return $result
}

function Get-TomlSectionBody {
  param(
    [Parameter(Mandatory = $true)][string]$Content,
    [Parameter(Mandatory = $true)][string]$Header
  )
  $pattern = '(?ms)^[^\S\r\n]*' + [regex]::Escape($Header) + '[^\S\r\n]*(?:#[^\r\n]*)?\r?\n(?<body>(?:(?!^[^\S\r\n]*\[).)*)'
  $match = [regex]::Match($Content, $pattern)
  if (-not $match.Success) {
    throw "missing TOML table: $Header"
  }
  return $match.Groups['body'].Value
}

function Get-ConfiguredFastCtxBash {
  param([Parameter(Mandatory = $true)][string]$ConfigPath)
  if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    return $null
  }
  $content = Read-Utf8NoBom $ConfigPath
  $document = Get-TomlDocumentSections -Content $content
  $sections = @($document.Sections | Where-Object {
      $segments = $_.Header.Segments
      $segments.Count -eq 3 -and $segments[0] -ceq 'mcp_servers' -and
        $segments[1] -ceq 'fastctx' -and $segments[2] -ceq 'env' -and -not $_.Header.IsArray
    })
  if ($sections.Count -ne 1) { return $null }
  $parsed = Get-TomlAssignments -Document $document -Section $sections[0]
  $matches = @($parsed.Assignments | Where-Object { $_.Key -ceq 'FASTCTX_BASH' })
  if ($parsed.Invalid -or $matches.Count -ne 1) { return $null }
  try {
    return [string]($matches[0].Value | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    throw "configured FASTCTX_BASH is not a valid TOML basic string: $ConfigPath"
  }
}

function Assert-TomlValue {
  param(
    [Parameter(Mandatory = $true)][string]$Body,
    [Parameter(Mandatory = $true)][string]$Key,
    [Parameter(Mandatory = $true)][string]$Expected
  )
  $pattern = '(?m)^\s*' + [regex]::Escape($Key) + '\s*=\s*' + [regex]::Escape($Expected) + '\s*(?:#.*)?$'
  if (-not [regex]::IsMatch($Body, $pattern)) {
    throw "unexpected or missing TOML value: $Key = $Expected"
  }
}

function Get-CodexFastCtxMcpState {
  param(
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [Parameter(Mandatory = $true)][string]$Binary,
    [Parameter(Mandatory = $true)][string]$NativeHome,
    [Parameter(Mandatory = $true)][string]$Profile,
    [Parameter(Mandatory = $true)][string]$Bash
  )
  if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return 'absent' }
  $content = Read-Utf8NoBom $ConfigPath
  $document = Get-TomlDocumentSections -Content $content
  $managed = @($document.Sections | Where-Object { Test-IsFastCtxSection -Section $_ })
  if ($managed.Count -eq 0) { return 'absent' }
  if (@($managed | Where-Object { $_.Header.IsArray }).Count -gt 0) { return 'conflict' }

  $serverSections = @($managed | Where-Object {
      $_.Header.Segments.Count -eq 2
    })
  $environmentSections = @($managed | Where-Object {
      $_.Header.Segments.Count -eq 3 -and $_.Header.Segments[2] -ceq 'env'
    })
  $unexpectedSections = @($managed | Where-Object {
      -not (($_.Header.Segments.Count -eq 2) -or
        ($_.Header.Segments.Count -eq 3 -and $_.Header.Segments[2] -ceq 'env'))
    })
  if ($serverSections.Count -ne 1 -or $environmentSections.Count -ne 1 -or $unexpectedSections.Count -ne 0) {
    return 'conflict'
  }

  $expectedServer = [ordered]@{
    command = ConvertTo-TomlBasicString $Binary
    args = '["serve", "--enable-shell"]'
    startup_timeout_sec = '120'
    tool_timeout_sec = '300'
  }
  $expectedEnvironment = [ordered]@{
    CODEX_HOME = ConvertTo-TomlBasicString $Profile
    FASTCTX_BASH = ConvertTo-TomlBasicString $Bash
    FASTCTX_GLOB_TOKEN_BUDGET = '"5400"'
    FASTCTX_GREP_TOKEN_BUDGET = '"10800"'
    FASTCTX_JOB_OUTPUT_TOKEN_BUDGET = '"5400"'
    FASTCTX_RUN_TOKEN_BUDGET = '"10800"'
    FASTCTX_TOKEN_BUDGET = '"54000"'
    HOME = ConvertTo-TomlBasicString $NativeHome
    USERPROFILE = ConvertTo-TomlBasicString $NativeHome
  }
  if (-not (Test-FastCtxSection -Section $serverSections[0] -Document $document -Expected $expectedServer)) {
    return 'conflict'
  }
  if (-not (Test-FastCtxSection -Section $environmentSections[0] -Document $document -Expected $expectedEnvironment)) {
    return 'conflict'
  }
  return 'matching'
}

function Assert-CodexMcpPreflight {
  param(
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [Parameter(Mandatory = $true)][string]$Binary,
    [Parameter(Mandatory = $true)][string]$NativeHome,
    [Parameter(Mandatory = $true)][string]$Profile,
    [Parameter(Mandatory = $true)][string]$Bash
  )
  $state = Get-CodexFastCtxMcpState -ConfigPath $ConfigPath -Binary $Binary -NativeHome $NativeHome -Profile $Profile -Bash $Bash
  if ($state -eq 'conflict' -and -not $ForceMcpRegistration) {
    throw 'A different Codex MCP definition named fastctx already exists. Re-run with -ForceMcpRegistration only after reviewing that conflict.'
  }
  if ($state -eq 'conflict') {
    Write-Log 'explicit force accepted the conflicting Codex FastCtx MCP definition'
  } elseif ($state -eq 'matching') {
    Write-Log 'Codex FastCtx MCP definition already matches the verified standard profile'
  }
}

function Assert-FastCtxMcpConfig {
  param(
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [Parameter(Mandatory = $true)][string]$Binary,
    [Parameter(Mandatory = $true)][string]$NativeHome,
    [Parameter(Mandatory = $true)][string]$Profile,
    [Parameter(Mandatory = $true)][string]$Bash
  )
  if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Codex config does not exist: $ConfigPath"
  }
  if (-not (Test-Path -LiteralPath $Binary -PathType Leaf)) {
    throw "configured FastCtx binary does not exist: $Binary"
  }
  if (-not (Test-Path -LiteralPath $Bash -PathType Leaf)) {
    throw "configured Git Bash does not exist: $Bash"
  }

  $state = Get-CodexFastCtxMcpState -ConfigPath $ConfigPath -Binary $Binary -NativeHome $NativeHome -Profile $Profile -Bash $Bash
  if ($state -ne 'matching') {
    throw "FastCtx MCP tables do not match the verified standard profile: $ConfigPath"
  }
  Write-Log 'FastCtx MCP tables and verified standard budgets are valid'
}

function Write-MinimalFastCtxConfig {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$Binary
  )
  $snapshot = Get-Utf8Snapshot -Path $Path -AllowMissing
  if ($snapshot.Exists) {
    return
  }
  $content = @"
schema_version = 1
last_seen_version = "$Version"
tool_budget_epoch = 2
language = "zh-CN"
tier = "standard"

[fastshell]
enabled = true
job_storage_limit_mib = 1024
max_running_jobs = 128
job_list_limit = 20

[update]
auto_check = false
source = "auto"
"@
  $finalContent = $content.TrimStart() + "`r`n"
  $candidateBytes = ConvertTo-Utf8Bytes -Content $finalContent -WithBom $snapshot.HasBom
  Invoke-TomlBytesValidation -Bytes $candidateBytes -Binary $Binary -Kind FastCtx -Label $Path
  Write-Utf8NoBomAtomic `
    -Path $Path `
    -Content $finalContent `
    -ExpectedExists $snapshot.Exists `
    -ExpectedBytes $snapshot.Bytes `
    -WithBom $snapshot.HasBom
  Write-Log "created minimal FastCtx config: $Path"
}

function Get-GitBashPath {
  param([string]$Override)
  $candidates = New-Object System.Collections.Generic.List[string]
  if (-not [string]::IsNullOrWhiteSpace($Override)) { $candidates.Add($Override) }
  if (-not [string]::IsNullOrWhiteSpace($env:FASTCTX_BASH)) { $candidates.Add($env:FASTCTX_BASH) }

  $git = Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($git) {
    $gitBin = Split-Path -Parent $git.Source
    $gitRoot = Split-Path -Parent $gitBin
    $candidates.Add((Join-Path $gitRoot 'bin\bash.exe'))
    $candidates.Add((Join-Path $gitRoot 'usr\bin\bash.exe'))
  }
  foreach ($registryPath in @(
    'HKCU:\SOFTWARE\GitForWindows',
    'HKLM:\SOFTWARE\GitForWindows',
    'HKLM:\SOFTWARE\WOW6432Node\GitForWindows'
  )) {
    $installPath = (Get-ItemProperty -LiteralPath $registryPath -Name InstallPath -ErrorAction SilentlyContinue).InstallPath
    if (-not [string]::IsNullOrWhiteSpace($installPath)) {
      $candidates.Add((Join-Path $installPath 'bin\bash.exe'))
      $candidates.Add((Join-Path $installPath 'usr\bin\bash.exe'))
    }
  }
  if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    $candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe'))
    $candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\Git\usr\bin\bash.exe'))
  }
  foreach ($programRoot in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if (-not [string]::IsNullOrWhiteSpace($programRoot)) {
      $candidates.Add((Join-Path $programRoot 'Git\bin\bash.exe'))
    }
  }

  foreach ($candidate in ($candidates | Select-Object -Unique)) {
    if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
      $resolved = Resolve-FullPath $candidate
      $versionOutput = (& $resolved --version 2>&1 | Out-String)
      if ($LASTEXITCODE -eq 0 -and $versionOutput -match 'GNU bash') {
        return $resolved
      }
    }
  }
  throw 'Git Bash was not found. Install Git for Windows or pass -GitBash <path>.'
}

function Get-FastCtxBinaryCandidates {
  $candidates = New-Object System.Collections.Generic.List[string]
  if (-not [string]::IsNullOrWhiteSpace($FastCtxBinary)) { $candidates.Add($FastCtxBinary) }

  $target = Join-Path $FastCtxHome 'bin\fastctx.exe'
  $candidates.Add($target)

  $git = Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($git) {
    $gitBin = Split-Path -Parent $git.Source
    $gitRoot = Split-Path -Parent $gitBin
    $customRoot = Join-Path $gitRoot '.fastctx\custom'
    if (Test-Path -LiteralPath $customRoot -PathType Container) {
      foreach ($item in (Get-ChildItem -LiteralPath $customRoot -Recurse -Filter 'fastctx.exe' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
        $candidates.Add($item.FullName)
      }
    }
  }

  $node = Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($node) {
    $nodeRoot = Split-Path -Parent $node.Source
    $candidates.Add((Join-Path $nodeRoot 'node_modules\fastctx\node_modules\@fastctx\win32-x64\bin\fastctx.exe'))
    $candidates.Add((Join-Path $nodeRoot 'node_global\node_modules\fastctx\node_modules\@fastctx\win32-x64\bin\fastctx.exe'))
  }

  foreach ($root in @($env:APPDATA, $env:LOCALAPPDATA, $env:USERPROFILE)) {
    if ([string]::IsNullOrWhiteSpace($root)) { continue }
    $candidateRoot = Join-Path $root 'npm\node_modules\fastctx\node_modules\@fastctx\win32-x64\bin\fastctx.exe'
    $candidates.Add($candidateRoot)
  }
  return $candidates | Select-Object -Unique
}

function Resolve-FastCtxBinary {
  foreach ($candidate in (Get-FastCtxBinaryCandidates)) {
    if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
      return (Resolve-FullPath $candidate)
    }
  }
  throw 'FastCtx binary was not found. Install fastctx or pass -FastCtxBinary <path>.'
}

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

function Get-StreamSha256 {
  param([Parameter(Mandatory = $true)][System.IO.Stream]$Stream)
  $position = $Stream.Position
  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  try {
    $Stream.Position = 0
    return ([System.BitConverter]::ToString($sha256.ComputeHash($Stream))).Replace('-', '')
  } finally {
    $Stream.Position = $position
    $sha256.Dispose()
  }
}

function Invoke-FastCtxTestSignal {
  param([Parameter(Mandatory = $true)][string]$VariableName)
  $signal = [Environment]::GetEnvironmentVariable($VariableName, 'Process')
  if ([string]::IsNullOrWhiteSpace($signal)) { return }
  $signal = [System.IO.Path]::GetFullPath($signal)
  [System.IO.File]::WriteAllText($signal, 'ready', [System.Text.UTF8Encoding]::new($false))
  $continuation = $signal + '.continue'
  for ($attempt = 1; $attempt -le 100; $attempt++) {
    if (Test-Path -LiteralPath $continuation -PathType Leaf) { return }
    Start-Sleep -Milliseconds 50
  }
  throw "test synchronization timed out: $VariableName"
}

function Install-FastCtxBinary {
  param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Destination,
    [Parameter(Mandatory = $true)][string]$SourceSnapshot
  )
  if ($Source -ieq $Destination) { return }
  $destinationExisted = Test-Path -LiteralPath $Destination -PathType Leaf
  $destinationSnapshot = if ($destinationExisted) { Get-Sha256 $Destination } else { $null }
  if ($destinationExisted -and -not $ForceBinary) {
    if ($SourceSnapshot -eq $destinationSnapshot) {
      Write-Log "stable FastCtx binary already matches source SHA-256: $SourceSnapshot"
      return
    }
    Write-Log "updating stable FastCtx binary because SHA-256 changed: $destinationSnapshot -> $SourceSnapshot"
  }
  $parent = Split-Path -Parent $Destination
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  $temporary = Join-Path $parent ('.fastctx-binary-' + [guid]::NewGuid().ToString('N') + '.tmp')
  $replacementBackup = Join-Path $parent ('.fastctx-binary-' + [guid]::NewGuid().ToString('N') + '.bak')
  $guard = $null
  try {
    Invoke-FastCtxTestSignal -VariableName 'FASTCTX_TEST_BEFORE_BINARY_COPY_SIGNAL'
    [System.IO.File]::Copy($Source, $temporary, $true)
    $temporarySnapshot = Get-Sha256 $temporary
    if ($temporarySnapshot -cne $SourceSnapshot) {
      throw "FastCtx source changed during installation; no replacement was published: $Source"
    }
    if ($destinationExisted) {
      try {
        $share = [System.IO.FileShare]::Read -bor [System.IO.FileShare]::Delete
        $guard = [System.IO.File]::Open($Destination, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
      } catch {
        throw "stable FastCtx binary could not be locked for atomic publication: $Destination"
      }
      $lockedSnapshot = Get-StreamSha256 -Stream $guard
      if ($lockedSnapshot -cne $destinationSnapshot) {
        throw "stable FastCtx binary changed during installation; no replacement was published: $Destination"
      }
      [System.IO.File]::Replace($temporary, $Destination, $replacementBackup)
      $guard.Dispose()
      $guard = $null
      $backupSnapshot = Get-Sha256 $replacementBackup
      if ($backupSnapshot -cne $destinationSnapshot) {
        $rollbackDiscard = Join-Path $parent ('.fastctx-binary-rollback-' + [guid]::NewGuid().ToString('N') + '.tmp')
        [System.IO.File]::Replace($replacementBackup, $Destination, $rollbackDiscard)
        Remove-Item -LiteralPath $rollbackDiscard -Force -ErrorAction SilentlyContinue
        throw "stable FastCtx binary changed during publication; the previous binary was restored: $Destination"
      }
    } else {
      if (Test-Path -LiteralPath $Destination) {
        throw "stable FastCtx binary appeared during installation; no replacement was published: $Destination"
      }
      [System.IO.File]::Move($temporary, $Destination)
    }
    $script:BinaryTransaction = [pscustomobject]@{
      Destination = [System.IO.Path]::GetFullPath($Destination)
      DestinationExisted = $destinationExisted
      DestinationSnapshot = $destinationSnapshot
      InstalledSnapshot = $SourceSnapshot
      ReplacementBackup = if ($destinationExisted) { $replacementBackup } else { $null }
    }
    Write-Log "installed stable FastCtx binary: $Destination"
  } finally {
    if ($null -ne $guard) { $guard.Dispose() }
    if (Test-Path -LiteralPath $temporary) {
      Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
    if (-not $script:BinaryTransaction -or $script:BinaryTransaction.ReplacementBackup -ne $replacementBackup) {
      if (Test-Path -LiteralPath $replacementBackup) {
        Remove-Item -LiteralPath $replacementBackup -Force -ErrorAction SilentlyContinue
      }
    }
  }
}

function Complete-FastCtxBinaryInstall {
  if ($null -eq $script:BinaryTransaction) { return }
  if (-not (Test-Path -LiteralPath $script:BinaryTransaction.Destination -PathType Leaf) -or
      (Get-Sha256 $script:BinaryTransaction.Destination) -cne $script:BinaryTransaction.InstalledSnapshot) {
    throw "stable FastCtx binary changed before installation could be committed: $($script:BinaryTransaction.Destination)"
  }
  if ($script:BinaryTransaction.ReplacementBackup -and (Test-Path -LiteralPath $script:BinaryTransaction.ReplacementBackup)) {
    Remove-Item -LiteralPath $script:BinaryTransaction.ReplacementBackup -Force
  }
  $script:BinaryTransaction = $null
}

function Rollback-FastCtxBinaryInstall {
  if ($null -eq $script:BinaryTransaction) { return }
  $transaction = $script:BinaryTransaction
  $completed = $false
  try {
    if ($transaction.DestinationExisted) {
      if (-not (Test-Path -LiteralPath $transaction.ReplacementBackup -PathType Leaf)) { return }
      if (-not (Test-Path -LiteralPath $transaction.Destination -PathType Leaf) -or
          (Get-Sha256 $transaction.Destination) -cne $transaction.InstalledSnapshot) {
        Write-Log "stable FastCtx binary changed after publication; preserved rollback backup without overwriting the newer file: $($transaction.ReplacementBackup)"
        return
      }
      $discard = Join-Path (Split-Path -Parent $transaction.Destination) ('.fastctx-binary-rollback-' + [guid]::NewGuid().ToString('N') + '.tmp')
      for ($attempt = 1; $attempt -le 20; $attempt++) {
        try {
          [System.IO.File]::Replace($transaction.ReplacementBackup, $transaction.Destination, $discard)
          $completed = $true
          break
        } catch {
          if ($attempt -eq 20) { throw }
          Start-Sleep -Milliseconds 100
        }
      }
      Remove-Item -LiteralPath $discard -Force -ErrorAction SilentlyContinue
      Write-Log "rolled back stable FastCtx binary: $($transaction.Destination)"
    } elseif (Test-Path -LiteralPath $transaction.Destination -PathType Leaf) {
      if ((Get-Sha256 $transaction.Destination) -cne $transaction.InstalledSnapshot) {
        Write-Log "new FastCtx binary changed after publication; rollback left it untouched: $($transaction.Destination)"
        return
      }
      for ($attempt = 1; $attempt -le 20; $attempt++) {
        try {
          Remove-Item -LiteralPath $transaction.Destination -Force -ErrorAction Stop
          $completed = $true
          break
        } catch {
          if ($attempt -eq 20) { throw }
          Start-Sleep -Milliseconds 100
        }
      }
      Write-Log "removed newly published FastCtx binary after failed installation: $($transaction.Destination)"
    } else {
      $completed = $true
    }
  } finally {
    if ($completed -and $transaction.ReplacementBackup -and (Test-Path -LiteralPath $transaction.ReplacementBackup)) {
      Remove-Item -LiteralPath $transaction.ReplacementBackup -Force -ErrorAction SilentlyContinue
    }
    $script:BinaryTransaction = $null
  }
}

function Assert-BinarySha256 {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$Expected
  )
  if ([string]::IsNullOrWhiteSpace($Expected)) {
    return
  }
  $normalized = $Expected.Trim().ToUpperInvariant()
  if ($normalized -notmatch '^[0-9A-F]{64}$') {
    throw "invalid expected SHA-256: $Expected"
  }
  $actual = (Get-Sha256 $Path).ToUpperInvariant()
  if ($actual -cne $normalized) {
    throw "FastCtx binary SHA-256 mismatch for $($Path): expected=$normalized actual=$actual"
  }
  Write-Log "binary SHA-256 verified: $actual"
}

function Invoke-FastCtxVersion {
  param([Parameter(Mandatory = $true)][string]$Binary)
  $output = (& $Binary --version 2>&1 | Out-String).Trim()
  if ($LASTEXITCODE -ne 0 -or $output -notmatch '^fastctx\s+(\d+\.\d+\.\d+)') {
    throw "FastCtx version check failed for $($Binary): $output"
  }
  Write-Log "binary: $output"
  return $Matches[1]
}

function Invoke-FastCtxStatus {
  param(
    [Parameter(Mandatory = $true)][string]$Binary,
    [Parameter(Mandatory = $true)][string]$NativeHome,
    [Parameter(Mandatory = $true)][string]$Profile,
    [Parameter(Mandatory = $true)][string]$Bash
  )
  $old = @{}
  foreach ($name in @('HOME', 'USERPROFILE', 'CODEX_HOME', 'FASTCTX_BASH', 'FASTCTX_DISABLE_UPDATE_CHECK', 'FASTCTX_READ_ONLY_VERIFY')) {
    $old[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
  }
  try {
    [Environment]::SetEnvironmentVariable('HOME', $NativeHome, 'Process')
    [Environment]::SetEnvironmentVariable('USERPROFILE', $NativeHome, 'Process')
    [Environment]::SetEnvironmentVariable('CODEX_HOME', $Profile, 'Process')
    [Environment]::SetEnvironmentVariable('FASTCTX_BASH', $Bash, 'Process')
    [Environment]::SetEnvironmentVariable('FASTCTX_DISABLE_UPDATE_CHECK', '1', 'Process')
    [Environment]::SetEnvironmentVariable('FASTCTX_READ_ONLY_VERIFY', '1', 'Process')
    $output = (& $Binary status --codex-home $Profile 2>&1 | Out-String).TrimEnd()
    if ($LASTEXITCODE -ne 0) {
      throw "FastCtx status failed (exit code $LASTEXITCODE): $output"
    }
    Write-Log "status passed: $($output -split "`r?`n" | Select-Object -First 1)"
  } finally {
    foreach ($name in $old.Keys) {
      [Environment]::SetEnvironmentVariable($name, $old[$name], 'Process')
    }
  }
}

function Invoke-FastCtxToolsList {
  param(
    [Parameter(Mandatory = $true)][string]$Binary,
    [Parameter(Mandatory = $true)][string]$NativeHome,
    [Parameter(Mandatory = $true)][string]$Profile,
    [Parameter(Mandatory = $true)][string]$Bash
  )

  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $Binary
  $startInfo.Arguments = 'serve --enable-shell'
  $startInfo.WorkingDirectory = $Profile
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardInput = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $utf8 = [System.Text.UTF8Encoding]::new($false)
  $startInfo.StandardOutputEncoding = $utf8
  $startInfo.StandardErrorEncoding = $utf8
  $startInfo.EnvironmentVariables['HOME'] = $NativeHome
  $startInfo.EnvironmentVariables['USERPROFILE'] = $NativeHome
  $startInfo.EnvironmentVariables['CODEX_HOME'] = $Profile
  $startInfo.EnvironmentVariables['FASTCTX_BASH'] = $Bash
  $startInfo.EnvironmentVariables['FASTCTX_DISABLE_UPDATE_CHECK'] = '1'
  $startInfo.EnvironmentVariables['FASTCTX_READ_ONLY_VERIFY'] = '1'

  $requests = @(
    (@{
      jsonrpc = '2.0'
      id = 1
      method = 'initialize'
      params = @{
        protocolVersion = '2025-03-26'
        capabilities = @{}
        clientInfo = @{ name = 'configure-fastctx'; version = '1.0' }
      }
    } | ConvertTo-Json -Compress -Depth 10),
    (@{
      jsonrpc = '2.0'
      method = 'notifications/initialized'
      params = @{}
    } | ConvertTo-Json -Compress -Depth 10),
    (@{
      jsonrpc = '2.0'
      id = 2
      method = 'tools/list'
      params = @{}
    } | ConvertTo-Json -Compress -Depth 10)
  )

  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  $started = $false
  try {
    $started = $process.Start()
    if (-not $started) {
      throw 'FastCtx MCP handshake process did not start.'
    }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    foreach ($request in $requests) {
      $process.StandardInput.WriteLine($request)
    }
    $process.StandardInput.Close()

    if (-not $process.WaitForExit(30000)) {
      try { $process.Kill() } catch {}
      throw 'FastCtx MCP handshake timed out after 30 seconds.'
    }
    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) {
      throw "FastCtx MCP handshake failed (exit code $($process.ExitCode)): $stderr"
    }

    $responses = @()
    foreach ($line in ($stdout -split "`r?`n")) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      try {
        $responses += ($line | ConvertFrom-Json -ErrorAction Stop)
      } catch {
        throw "FastCtx MCP handshake returned non-JSON output: $line"
      }
    }
    $initializeResponse = @($responses | Where-Object { $_.id -eq 1 }) | Select-Object -First 1
    $toolsResponse = @($responses | Where-Object { $_.id -eq 2 }) | Select-Object -First 1
    if (-not $initializeResponse -or $initializeResponse.error) {
      throw 'FastCtx MCP initialize response is missing or contains an error.'
    }
    if (-not $toolsResponse -or $toolsResponse.error) {
      throw 'FastCtx MCP tools/list response is missing or contains an error.'
    }

    $expected = @('glob', 'grep', 'job_kill', 'job_list', 'job_output', 'read', 'replace', 'run', 'run_background') | Sort-Object
    $actual = @($toolsResponse.result.tools | ForEach-Object { [string]$_.name }) | Sort-Object
    $difference = @(Compare-Object -ReferenceObject $expected -DifferenceObject $actual)
    if ($actual.Count -ne $expected.Count -or $difference.Count -gt 0) {
      throw "FastCtx MCP tools/list mismatch. Expected: $($expected -join ', '); actual: $($actual -join ', ')"
    }
    Write-Log "MCP initialize/tools-list passed: $($actual -join ', ')"
  } finally {
    if ($started -and -not $process.HasExited) {
      try { $process.Kill() } catch {}
    }
    $process.Dispose()
  }
}

function Invoke-TomlValidation {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Binary,
    [Parameter(Mandatory = $true)][ValidateSet('FastCtx', 'Codex')][string]$Kind
  )
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "TOML validation target does not exist: $Path"
  }
  $switch = if ($Kind -eq 'FastCtx') { '--fastctx-config' } else { '--codex-config' }
  & $Binary validate-config $switch $Path
  if ($LASTEXITCODE -ne 0) {
    throw "FastCtx TOML validation failed: $Path"
  }
  Write-Log "TOML valid via bundled FastCtx parser: $Path"
}

function Invoke-TomlBytesValidation {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes,
    [Parameter(Mandatory = $true)][string]$Binary,
    [Parameter(Mandatory = $true)][ValidateSet('FastCtx', 'Codex')][string]$Kind,
    [Parameter(Mandatory = $true)][string]$Label
  )
  $temporary = Join-Path ([System.IO.Path]::GetTempPath()) ('.fastctx-toml-' + [guid]::NewGuid().ToString('N') + '.toml')
  try {
    [System.IO.File]::WriteAllBytes($temporary, $Bytes)
    Invoke-TomlValidation -Path $temporary -Binary $Binary -Kind $Kind
  } finally {
    if (Test-Path -LiteralPath $temporary) {
      Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
  }
}

function Set-FastCtxMcpConfig {
  param(
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [Parameter(Mandatory = $true)][string]$Binary,
    [Parameter(Mandatory = $true)][string]$NativeHome,
    [Parameter(Mandatory = $true)][string]$Profile,
    [Parameter(Mandatory = $true)][string]$Bash
  )
  $snapshot = Get-Utf8Snapshot -Path $ConfigPath -AllowMissing
  $state = Get-CodexFastCtxMcpState -ConfigPath $ConfigPath -Binary $Binary -NativeHome $NativeHome -Profile $Profile -Bash $Bash
  if ($state -eq 'matching') {
    Write-Log 'Codex FastCtx MCP config already matches the requested chain'
    return
  }
  if ($state -eq 'conflict' -and -not $ForceMcpRegistration) {
    throw 'A different Codex MCP definition named fastctx already exists. Re-run with -ForceMcpRegistration only after reviewing that conflict.'
  }
  $base = if ($state -eq 'conflict') {
    Remove-FastCtxTomlSections -Content $snapshot.Text
  } else {
    $snapshot.Text
  }
  $newline = Get-Newline $base
  $serverBlock = @(
    '[mcp_servers.fastctx]'
    'args = ["serve", "--enable-shell"]'
    "command = $(ConvertTo-TomlBasicString $Binary)"
    'startup_timeout_sec = 120'
    'tool_timeout_sec = 300'
  ) -join $newline
  $environmentBlock = @(
    '[mcp_servers.fastctx.env]'
    "CODEX_HOME = $(ConvertTo-TomlBasicString $Profile)"
    "FASTCTX_BASH = $(ConvertTo-TomlBasicString $Bash)"
    'FASTCTX_GLOB_TOKEN_BUDGET = "5400"'
    'FASTCTX_GREP_TOKEN_BUDGET = "10800"'
    'FASTCTX_JOB_OUTPUT_TOKEN_BUDGET = "5400"'
    'FASTCTX_RUN_TOKEN_BUDGET = "10800"'
    'FASTCTX_TOKEN_BUDGET = "54000"'
    "HOME = $(ConvertTo-TomlBasicString $NativeHome)"
    "USERPROFILE = $(ConvertTo-TomlBasicString $NativeHome)"
  ) -join $newline
  $managedBlock = $serverBlock + $newline + $newline + $environmentBlock
  $base = $base.TrimEnd("`r", "`n")
  $after = if ([string]::IsNullOrWhiteSpace($base)) {
    $managedBlock + $newline
  } else {
    $base + $newline + $newline + $managedBlock + $newline
  }
  $candidateBytes = ConvertTo-Utf8Bytes -Content $after -WithBom $snapshot.HasBom
  Invoke-TomlBytesValidation -Bytes $candidateBytes -Binary $Binary -Kind Codex -Label $ConfigPath
  Backup-CodexConfig $ConfigPath
  Write-Utf8NoBomAtomic `
    -Path $ConfigPath `
    -Content $after `
    -ExpectedExists $snapshot.Exists `
    -ExpectedBytes $snapshot.Bytes `
    -WithBom $snapshot.HasBom
  Write-Log "updated only FastCtx MCP tables: $ConfigPath"
}

try {
if ([string]::IsNullOrWhiteSpace($NativeHome)) {
  throw 'NativeHome is required for a stable Windows FastCtx installation.'
}
$nativeHome = Resolve-FullPath $NativeHome
$CodexHome = Resolve-FullPath $CodexHome
$FastCtxHome = Resolve-FullPath $FastCtxHome
$configPath = Join-Path $CodexHome 'config.toml'
$fastctxConfigPath = Join-Path $FastCtxHome 'config.toml'
$targetBinary = Join-Path $FastCtxHome 'bin\fastctx.exe'
$agentIntegrationScript = Join-Path $PSScriptRoot 'configure-agent-integrations.ps1'
if (-not (Test-Path -LiteralPath $agentIntegrationScript -PathType Leaf)) {
  throw "agent integration helper is missing: $agentIntegrationScript"
}
$bashOverride = $GitBash
if ($VerifyOnly -and [string]::IsNullOrWhiteSpace($bashOverride)) {
  $bashOverride = Get-ConfiguredFastCtxBash -ConfigPath $configPath
}
$bash = Get-GitBashPath $bashOverride
$agentParameters = @{
  FastCtxBinary = $targetBinary
  GitBash = $bash
  NativeHome = $nativeHome
  CodexHome = $CodexHome
}
if (-not [string]::IsNullOrWhiteSpace($ClaudeConfigDir)) {
  $agentParameters.ClaudeConfigDir = $ClaudeConfigDir
}
if (-not [string]::IsNullOrWhiteSpace($ClaudeCommand)) {
  $agentParameters.ClaudeCommand = $ClaudeCommand
}
if ($SkipClaudeCode) { $agentParameters.SkipClaudeCode = $true }
if ($SkipCcSwitch) { $agentParameters.SkipCcSwitch = $true }
if ($NoLaunchCcSwitch) { $agentParameters.NoLaunchCcSwitch = $true }
if ($RequireCcSwitch) { $agentParameters.RequireCcSwitch = $true }
if ($ForceMcpRegistration) { $agentParameters.ForceMcpRegistration = $true }

if ($VerifyOnly) {
  if (-not (Test-Path -LiteralPath $targetBinary -PathType Leaf)) {
    throw "stable FastCtx binary does not exist: $targetBinary"
  }
} else {
  Assert-CodexMcpPreflight -ConfigPath $configPath -Binary $targetBinary -NativeHome $nativeHome -Profile $CodexHome -Bash $bash
  $source = Resolve-FastCtxBinary
  $sourceSnapshot = Get-Sha256 $source
  Assert-BinarySha256 -Path $source -Expected $ExpectedSha256
  if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    Invoke-TomlValidation -Path $configPath -Binary $source -Kind Codex
  }
  if (Test-Path -LiteralPath $fastctxConfigPath -PathType Leaf) {
    Invoke-TomlValidation -Path $fastctxConfigPath -Binary $source -Kind FastCtx
  }
  & $agentIntegrationScript @agentParameters -PreflightOnly
  New-Item -ItemType Directory -Force -Path $CodexHome, $FastCtxHome | Out-Null
  Install-FastCtxBinary -Source $source -Destination $targetBinary -SourceSnapshot $sourceSnapshot
  if ($env:FASTCTX_TEST_FAIL_AFTER_BINARY_INSTALL -eq '1') {
    throw 'test failure after binary publication'
  }
}
$binary = $targetBinary
Assert-BinarySha256 -Path $binary -Expected $ExpectedSha256
$version = Invoke-FastCtxVersion $binary

if ($VerifyOnly) {
  if (-not (Test-Path -LiteralPath $fastctxConfigPath -PathType Leaf)) {
    throw "FastCtx config does not exist: $fastctxConfigPath"
  }
} else {
  Write-MinimalFastCtxConfig -Path $fastctxConfigPath -Version $version -Binary $binary
}
Invoke-TomlValidation -Path $fastctxConfigPath -Binary $binary -Kind FastCtx
if (-not $VerifyOnly) {
  Invoke-FastCtxTestSignal -VariableName 'FASTCTX_TEST_BEFORE_CODEX_WRITE_SIGNAL'
  Set-FastCtxMcpConfig -ConfigPath $configPath -Binary $targetBinary -NativeHome $nativeHome -Profile $CodexHome -Bash $bash
  Invoke-TomlValidation -Path $configPath -Binary $binary -Kind Codex
  & $agentIntegrationScript @agentParameters
} else {
  Invoke-TomlValidation -Path $configPath -Binary $binary -Kind Codex
  & $agentIntegrationScript @agentParameters -VerifyOnly
}
Assert-FastCtxMcpConfig -ConfigPath $configPath -Binary $targetBinary -NativeHome $nativeHome -Profile $CodexHome -Bash $bash
Invoke-FastCtxStatus -Binary $binary -NativeHome $nativeHome -Profile $CodexHome -Bash $bash
Invoke-FastCtxToolsList -Binary $binary -NativeHome $nativeHome -Profile $CodexHome -Bash $bash
Complete-FastCtxBinaryInstall
Write-Log 'FastCtx chain is ready; restart Claude Code and Codex once to reload MCP and global guidance.'
} catch {
  $installationError = $_
  try {
    Rollback-FastCtxBinaryInstall
  } catch {
    Write-Log "binary rollback failed: $($_.Exception.Message)"
  }
  throw $installationError
}
