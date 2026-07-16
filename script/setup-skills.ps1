#Requires -Version 5.1

# Links .claude\skills -> .agents\skills so that Claude Code discovers the
# skills that live under .agents\ (the canonical location shared with Zed's
# agent). The junction is not committed to git, so run this once after cloning.

$ErrorActionPreference = "Stop"

# Resolve the repo root from this script's location so it works regardless of
# the current working directory.
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

$Source = Join-Path $RepoRoot ".agents\skills"
$Link = Join-Path $RepoRoot ".claude\skills"

if (-not (Test-Path $Source -PathType Container)) {
    Write-Host "ERROR: source directory does not exist: $Source"
    exit 1
}

$existing = Get-Item $Link -Force -ErrorAction SilentlyContinue
if ($existing) {
    if ($existing.LinkType) {
        # Already a junction/symlink. Check whether it points at the source.
        $target = $existing.Target | Select-Object -First 1
        if ((Resolve-Path $target).Path -eq $Source) {
            Write-Host ".claude\skills already links to .agents\skills"
            exit 0
        }
        Write-Host "Replacing existing link .claude\skills (-> $target)"
        Remove-Item $Link -Force
    }
    else {
        Write-Host "ERROR: $Link already exists and is not a link; refusing to overwrite"
        Write-Host "Move or remove it, then re-run this script."
        exit 1
    }
}

New-Item -ItemType Directory -Path (Join-Path $RepoRoot ".claude") -Force | Out-Null

# Junctions do not require Developer Mode or admin, unlike symbolic links.
New-Item -ItemType Junction -Path $Link -Target $Source | Out-Null
Write-Host "Linked .claude\skills -> .agents\skills"
