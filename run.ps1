# ===========================
# run.ps1  (PowerShell 5.1+)
# ===========================
# What it does (every run):
# 1) Scans D:\VS Code (excluding noisy folders + this repo)
# 2) Builds a new snapshot (path, size, mtime, hash for small files)
# 3) Diffs vs previous snapshot
# 4) Writes 5 timestamped reports
# 5) Makes 5 separate commits (one per report) and pushes to GitHub

$ErrorActionPreference = "Stop"

# ---- CONFIG (edit if needed) ----
$ScanRoot  = "D:\VS Code"
$RepoRoot  = "D:\VS Code\PC-Change-Tracker"   # this is the Git repo folder
$ReportsDir = Join-Path $RepoRoot "reports"
$StateDir   = Join-Path $RepoRoot "state"

$PrevSnapshot = Join-Path $StateDir "snapshot_prev.csv"
$NewSnapshot  = Join-Path $StateDir "snapshot_new.csv"

# Folders to exclude anywhere in the tree:
$ExcludeDirNames = @(
  ".git","node_modules",".next","dist","build","out",".venv","venv","__pycache__",
  ".idea",".vs",".cache","target"
)

# File extensions to skip (big/noisy):
$ExcludeExt = @(".zip",".rar",".7z",".iso",".mp4",".mkv",".exe",".msi",".dll",".bin",".tmp",".log")

# Hash only files <= this many MB (speeds up scan):
$HashMaxMB = 10

# ---- SAFETY ----
if (-not (Test-Path $ScanRoot)) { throw "Scan root not found: $ScanRoot" }
if (-not (Test-Path $RepoRoot)) { throw "Repo root not found: $RepoRoot" }

New-Item -ItemType Directory -Force -Path $ReportsDir | Out-Null
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

# ---- Helpers ----
function Is-ExcludedPath([string]$fullPath) {
  # Exclude the repo itself from scanning
  if ($fullPath.StartsWith($RepoRoot, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }

  # Exclude by folder name anywhere in the path
  foreach ($d in $ExcludeDirNames) {
    if ($fullPath -match "(\\|/)$([Regex]::Escape($d))(\\|/)") { return $true }
  }
  return $false
}

function Is-ExcludedFile([System.IO.FileInfo]$fi) {
  if (Is-ExcludedPath $fi.FullName) { return $true }
  if ($ExcludeExt -contains $fi.Extension.ToLowerInvariant()) { return $true }
  return $false
}

function Safe-RelativePath([string]$fullPath, [string]$root) {
  $rel = $fullPath.Substring($root.Length).TrimStart('\','/')
  return $rel
}

function File-Fingerprint([System.IO.FileInfo]$fi) {
  # For speed: hash only up to $HashMaxMB; larger files use metadata signature.
  $sizeMB = [math]::Round($fi.Length / 1MB, 3)
  $mtime  = $fi.LastWriteTimeUtc.ToString("o")
  $rel    = Safe-RelativePath $fi.FullName $ScanRoot

  $hash = ""
  if ($fi.Length -le ($HashMaxMB * 1MB)) {
    try {
      $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $fi.FullName).Hash
    } catch {
      # If locked, fall back to metadata signature
      $hash = ""
    }
  }
  if ([string]::IsNullOrWhiteSpace($hash)) {
    # Metadata signature to still detect changes for large/locked files
    $hash = "META:$($fi.Length):$mtime"
  }

  [PSCustomObject]@{
    RelPath = $rel
    SizeBytes = $fi.Length
    LastWriteUtc = $mtime
    Fingerprint = $hash
    FullPath = $fi.FullName
    SizeMB = $sizeMB
  }
}

# ---- Scan ----
Write-Host "Scanning: $ScanRoot"
$files = Get-ChildItem -LiteralPath $ScanRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
  Where-Object { -not (Is-ExcludedFile $_) }

$rows = foreach ($f in $files) { File-Fingerprint $f }

# Save new snapshot (CSV)
$rows | Select-Object RelPath,SizeBytes,LastWriteUtc,Fingerprint |
  Sort-Object RelPath |
  Export-Csv -NoTypeInformation -Encoding UTF8 -Path $NewSnapshot

# Load previous snapshot if exists
$prev = @{}
if (Test-Path $PrevSnapshot) {
  Import-Csv -Path $PrevSnapshot | ForEach-Object { $prev[$_.RelPath] = $_ }
}

# Map new snapshot
$new = @{}
Import-Csv -Path $NewSnapshot | ForEach-Object { $new[$_.RelPath] = $_ }

# ---- Diff ----
$added    = New-Object System.Collections.Generic.List[object]
$modified = New-Object System.Collections.Generic.List[object]
$deleted  = New-Object System.Collections.Generic.List[object]

foreach ($k in $new.Keys) {
  if (-not $prev.ContainsKey($k)) {
    $added.Add($new[$k]) | Out-Null
  } else {
    if ($new[$k].Fingerprint -ne $prev[$k].Fingerprint) {
      $modified.Add([PSCustomObject]@{
        RelPath = $k
        OldFingerprint = $prev[$k].Fingerprint
        NewFingerprint = $new[$k].Fingerprint
        OldSize = $prev[$k].SizeBytes
        NewSize = $new[$k].SizeBytes
        OldMtime = $prev[$k].LastWriteUtc
        NewMtime = $new[$k].LastWriteUtc
      }) | Out-Null
    }
  }
}

foreach ($k in $prev.Keys) {
  if (-not $new.ContainsKey($k)) {
    $deleted.Add($prev[$k]) | Out-Null
  }
}

# ---- Rename detection (best-effort) ----
# Renamed = deleted + added with same Fingerprint
$renamed = New-Object System.Collections.Generic.List[object]

# Build lookup by fingerprint for added/deleted
$addedByFp = @{}
foreach ($a in $added) {
  if (-not $addedByFp.ContainsKey($a.Fingerprint)) { $addedByFp[$a.Fingerprint] = New-Object System.Collections.Generic.List[object] }
  $addedByFp[$a.Fingerprint].Add($a) | Out-Null
}
$deletedByFp = @{}
foreach ($d in $deleted) {
  if (-not $deletedByFp.ContainsKey($d.Fingerprint)) { $deletedByFp[$d.Fingerprint] = New-Object System.Collections.Generic.List[object] }
  $deletedByFp[$d.Fingerprint].Add($d) | Out-Null
}

# Pair them
foreach ($fp in $deletedByFp.Keys) {
  if ($addedByFp.ContainsKey($fp)) {
    $dList = $deletedByFp[$fp]
    $aList = $addedByFp[$fp]
    $pairs = [Math]::Min($dList.Count, $aList.Count)
    for ($i=0; $i -lt $pairs; $i++) {
      $renamed.Add([PSCustomObject]@{
        From = $dList[$i].RelPath
        To   = $aList[$i].RelPath
        Fingerprint = $fp
      }) | Out-Null
    }
  }
}

# Remove rename-paired items from added/deleted to avoid double-reporting
if ($renamed.Count -gt 0) {
  $renamedFrom = @($renamed | ForEach-Object { $_.From })
  $renamedTo   = @($renamed | ForEach-Object { $_.To })

  $added    = $added    | Where-Object { $renamedTo   -notcontains $_.RelPath }
  $deleted  = $deleted  | Where-Object { $renamedFrom -notcontains $_.RelPath }
}

# ---- Write 5 reports (always new files => always 5 commits) ----
$ts = Get-Date -Format "yyyyMMdd-HHmmss"
$r1 = Join-Path $ReportsDir "01-summary-$ts.txt"
$r2 = Join-Path $ReportsDir "02-added-$ts.txt"
$r3 = Join-Path $ReportsDir "03-modified-$ts.txt"
$r4 = Join-Path $ReportsDir "04-deleted-$ts.txt"
$r5 = Join-Path $ReportsDir "05-renamed-$ts.txt"

$summary = @()
$summary += "PC Change Tracker"
$summary += "Timestamp: $ts"
$summary += "ScanRoot:  $ScanRoot"
$summary += "ExcludedDirs: " + ($ExcludeDirNames -join ", ")
$summary += "ExcludedExt:  " + ($ExcludeExt -join ", ")
$summary += "HashMaxMB:    $HashMaxMB"
$summary += ""
$summary += "Counts:"
$summary += ("  Added:    {0}" -f ($added.Count))
$summary += ("  Modified: {0}" -f ($modified.Count))
$summary += ("  Deleted:  {0}" -f ($deleted.Count))
$summary += ("  Renamed:  {0}" -f ($renamed.Count))
$summary += ""
$summary += "Note: Rename detection is best-effort (fingerprint match)."

Set-Content -Encoding UTF8 -Path $r1 -Value $summary

# Added
$addedLines = @()
$addedLines += "Added files ($($added.Count)) - $ts"
$addedLines += ""
if ($added.Count -eq 0) { $addedLines += "(none)" }
else {
  $added | Sort-Object RelPath | ForEach-Object {
    $addedLines += ("{0} | {1} bytes | {2}" -f $_.RelPath, $_.SizeBytes, $_.LastWriteUtc)
  }
}
Set-Content -Encoding UTF8 -Path $r2 -Value $addedLines

# Modified
$modLines = @()
$modLines += "Modified files ($($modified.Count)) - $ts"
$modLines += ""
if ($modified.Count -eq 0) { $modLines += "(none)" }
else {
  $modified | Sort-Object RelPath | ForEach-Object {
    $modLines += ("{0}" -f $_.RelPath)
    $modLines += ("  Old: {0} | {1} bytes | {2}" -f $_.OldFingerprint, $_.OldSize, $_.OldMtime)
    $modLines += ("  New: {0} | {1} bytes | {2}" -f $_.NewFingerprint, $_.NewSize, $_.NewMtime)
    $modLines += ""
  }
}
Set-Content -Encoding UTF8 -Path $r3 -Value $modLines

# Deleted
$delLines = @()
$delLines += "Deleted files ($($deleted.Count)) - $ts"
$delLines += ""
if ($deleted.Count -eq 0) { $delLines += "(none)" }
else {
  $deleted | Sort-Object RelPath | ForEach-Object {
    $delLines += ("{0} | {1} bytes | {2} | {3}" -f $_.RelPath, $_.SizeBytes, $_.LastWriteUtc, $_.Fingerprint)
  }
}
Set-Content -Encoding UTF8 -Path $r4 -Value $delLines

# Renamed
$renLines = @()
$renLines += "Renamed files ($($renamed.Count)) - $ts"
$renLines += ""
if ($renamed.Count -eq 0) { $renLines += "(none)" }
else {
  $renamed | Sort-Object From | ForEach-Object {
    $renLines += ("{0}  -->  {1} | {2}" -f $_.From, $_.To, $_.Fingerprint)
  }
}
Set-Content -Encoding UTF8 -Path $r5 -Value $renLines

# ---- Rotate snapshots ----
# Move new snapshot into prev for next run
Copy-Item -Force -LiteralPath $NewSnapshot -Destination $PrevSnapshot

# ---- Git: 5 commits + push ----
Set-Location $RepoRoot

# Ensure repo initialized
if (-not (Test-Path (Join-Path $RepoRoot ".git"))) {
  git init | Out-Null
}

# Make sure git knows this directory
git config --global --add safe.directory $RepoRoot | Out-Null

# Commit each report file separately (guarantees >= 5 commits per run)
function Commit-One([string]$filePath, [string]$message) {
  git add -- "$filePath" | Out-Null
  git commit -m $message | Out-Null
}

Commit-One ("reports\01-summary-$ts.txt")  "Report: summary $ts"
Commit-One ("reports\02-added-$ts.txt")    "Report: added $ts"
Commit-One ("reports\03-modified-$ts.txt") "Report: modified $ts"
Commit-One ("reports\04-deleted-$ts.txt")  "Report: deleted $ts"
Commit-One ("reports\05-renamed-$ts.txt")  "Report: renamed $ts"

# Push (requires remote already set + auth already working)
git push | Out-Null

Write-Host "DONE ✅ Reports created + 5 commits pushed."
