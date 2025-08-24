param(
    [string]$IgnoreFile = ".ignoredropbox",
    [string]$Root = "$env:USERPROFILE\Dropbox",     # default Dropbox folder
    [Alias("c")][switch]$Check,                      # dry-run (no ADS changes)
    [Alias("u")][switch]$Unsafe                     # include symlinks/junctions
)

# ---------- Helpers ----------
function Get-IgnoreLines {
    param([string]$path)
    if (Test-Path -LiteralPath $path) {
        Get-Content -LiteralPath $path | ForEach-Object {
            $_.Trim()
        } | Where-Object { $_ -and ($_ -notmatch '^\s*#') }
    }
}

function Convert-Pattern {
    param([string]$pat)

    # negation
    $neg = $pat.StartsWith('!')
    if ($neg) { $pat = $pat.Substring(1) }

    # root-anchored (like .gitignore leading "/") — relative to the effective root
    $rootAnchored = $false
    if ($pat.StartsWith('/')) {
        $rootAnchored = $true
        $pat = $pat.Substring(1)
    }

    # normalize slashes and detect dir-only / has-slash
    $pat = $pat.Replace('\', '/')
    $dirOnly = $pat.EndsWith('/')
    if ($dirOnly) { $pat = $pat.TrimEnd('/') }
    $hasSlash = $pat.Contains('/')

    # escape regex, then restore glob tokens
    $escaped = [Regex]::Escape($pat).Replace('\*', '*').Replace('\?', '?')

    # mark ** so we can handle it after single-level replacements
    $escaped = $escaped.Replace('**', '###DS###')

    # single-level: * -> [^/]*, ? -> [^/]
    $escaped = $escaped.Replace('*', '[^/]*').Replace('?', '[^/]')

    # multi-level:
    #   "###DS###/" -> "(?:.*/)?"   (zero or more directories)
    #   "###DS###"  -> ".*"         (any depth, including none)
    $escaped = $escaped.Replace('###DS###/', '(?:.*/)?')
    $escaped = $escaped.Replace('###DS###', '.*')

    # baseline core:
    # - path rules (contain "/"): match as-is
    # - basename rules (no "/"): match at ANY depth (zero or more directories)
    $core = if ($hasSlash) { $escaped } else { "(?:.*/)*$escaped" }

    # default regex: dir-only matches the dir and its contents; file rule matches exactly
    $rx = if ($dirOnly) { "^$core(?:/.*)?$" } else { "^$core$" }

    # root-anchored: match only from the effective root (drop any leading ".*")
    if ($rootAnchored) {
        if ($dirOnly) {
            $rx = "^$escaped(?:/.*)?$"
        }
        else {
            $rx = "^$escaped$"
        }
    }

    # compile case-insensitive + culture-invariant (Windows-friendly)
    $opts = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase `
        -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant

    [pscustomobject]@{
        Regex   = New-Object System.Text.RegularExpressions.Regex($rx, $opts)
        Negate  = $neg
        DirOnly = $dirOnly
    }
}

function ShouldIgnore {
    param([string]$rel, [bool]$isDir, [object[]]$rules)
    $rel = $rel.Replace('\', '/')
    $ignore = $false
    foreach ($r in $rules) {
        if ($rel -match $r.Regex) {
            if ($r.DirOnly -and -not $isDir) { continue }
            $ignore = -not $r.Negate   # last match wins
        }
    }
    return $ignore
}

function IsIgnoredActive {
    param([string]$path)
    try {
        $content = Get-Content -LiteralPath $path -Stream com.dropbox.ignored -ErrorAction Stop
        (($content -join "`n").Trim() -eq '1')
    }
    catch { $false }
}

function Set-Ignored {
    param([string]$Full, [string]$Rel, [switch]$Dry)
    if ($Dry) { Write-Host "[CHECK] Would IGNORE $Rel"; return }
    Set-Content -LiteralPath $Full -Stream com.dropbox.ignored -Value 1 -ErrorAction SilentlyContinue
    Write-Host "Ignoring $Rel"
}

function Clear-Ignored {
    param([string]$Full, [string]$Rel, [switch]$Dry)
    if ($Dry) { Write-Host "[CHECK] Would UNIGNORE $Rel"; return }
    try {
        Remove-Item -LiteralPath $Full -Stream com.dropbox.ignored -ErrorAction Stop
    }
    catch {
        Clear-Content -LiteralPath $Full -Stream com.dropbox.ignored -ErrorAction SilentlyContinue
    }
    Write-Host "Unignoring $Rel"
}

# ---------- Walk ----------
function ApplyIgnore {
    param(
        [string]$root,
        [object[]]$rules,
        [string]$base = $null,
        $stats
    )
    if (-not $base) { $base = $root }
    $base = $base.TrimEnd('\')

    foreach ($e in Get-ChildItem -LiteralPath $root -Force) {
        # By default skip reparse points (symlinks/junctions); include them if -Unsafe was set.
        if (-not $script:Unsafe) {
            if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        }

        $rel = $e.FullName.Substring($base.Length).TrimStart('\').Replace('\', '/')
        $wantIgnore = ShouldIgnore -rel $rel -isDir $e.PSIsContainer -rules $rules
        $isActive = IsIgnoredActive -path $e.FullName

        if ($wantIgnore -and -not $isActive) {
            Set-Ignored -Full $e.FullName -Rel $rel -Dry:$Check
            $stats.Ignored++
            if ($e.PSIsContainer) { continue }   # don't descend into dirs we (will) ignore
        }
        elseif (-not $wantIgnore -and $isActive) {
            Clear-Ignored -Full $e.FullName -Rel $rel -Dry:$Check
            $stats.Unignored++
            if ($e.PSIsContainer) {
                # was ignored dir; clean children now
                ApplyIgnore -root $e.FullName -rules $rules -base $base -stats $stats
            }
            continue
        }
        else {
            $stats.Unchanged++
            if ($e.PSIsContainer -and -not $wantIgnore) {
                # walk unignored dirs to correct any stale children
                ApplyIgnore -root $e.FullName -rules $rules -base $base -stats $stats
            }
            continue
        }
    }
}

# ---------- Main ----------
# Ensure ignore file exists
if (-not (Test-Path -LiteralPath $IgnoreFile)) {
    Write-Error "Ignore file not found: $IgnoreFile"
    exit 1
}
$ignorePath = Resolve-Path -LiteralPath $IgnoreFile

# Ensure -Root exists and resolve it
if (-not (Test-Path -LiteralPath $Root)) {
    Write-Error "The specified -Root does not exist: $Root"
    exit 1
}
$effectiveRoot = Resolve-Path -LiteralPath $Root

$lines = Get-IgnoreLines $ignorePath
if (-not $lines) { Write-Host "No patterns found in $ignorePath"; exit }

$rules = foreach ($l in $lines) { Convert-Pattern $l }

# never ignore these (optional but sensible)
$rules += Convert-Pattern "!" + (Split-Path -Leaf $ignorePath)
$rules += Convert-Pattern "!" + (Split-Path -Leaf $PSCommandPath)

if ($Check) {
    Write-Host "Running in CHECK mode (no changes applied)"
    Write-Host "Ignore file : $ignorePath"
    Write-Host "Root        : $effectiveRoot"
    if ($Unsafe) { Write-Host "Unsafe     : traversing symlinks/junctions" }
}

# expose -Unsafe to Apply-Ignore (read via $script:Unsafe)
$script:Unsafe = $Unsafe.IsPresent

$stats = [pscustomobject]@{ Ignored = 0; Unignored = 0; Unchanged = 0 }
ApplyIgnore -root $effectiveRoot -rules $rules -stats $stats

Write-Host "Done."
Write-Host "Summary: $($stats.Ignored) ignored, $($stats.Unignored) unignored, $($stats.Unchanged) unchanged"
