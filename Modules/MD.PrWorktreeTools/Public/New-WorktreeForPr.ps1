
<#
.SYNOPSIS
Tworzy lokalny worktree dla istniejącego Pull Requesta.

.DESCRIPTION
Funkcja pobiera z GitHuba informacje o wskazanym PR (numer, gałąź źródłowa,
URL), a następnie tworzy katalog worktree w postaci `pr-<numerPR>`.

Domyślnie katalog docelowy jest wyznaczany przez Get-DefaultWorktreesRoot,
czyli `{repo}.worktrees`. Jeśli katalog root nie istnieje, zostanie utworzony.
Po utworzeniu worktree funkcja przełącza bieżącą lokalizację do nowego katalogu.

.PARAMETER PrNumber
Numer Pull Requesta w GitHubie. Parametr wymagany; akceptuje wyłącznie cyfry.

.PARAMETER WorktreesRoot
Opcjonalna ścieżka katalogu, w którym ma zostać utworzony worktree.
Jeśli nie zostanie podana, użyty będzie katalog domyślny z
Get-DefaultWorktreesRoot.

.EXAMPLE
New-WorktreeForPr -PrNumber 1234

Tworzy worktree dla PR #1234 w katalogu domyślnym `{repo}.worktrees\pr-1234`.

.EXAMPLE
New-WorktreeForPr -PrNumber 1234 -WorktreesRoot "D:\worktrees"

Tworzy worktree dla PR #1234 w katalogu `D:\worktrees\pr-1234`.

.NOTES
Wymagania: aktywne repozytorium git, dostępne narzędzia `git` i `gh`,
zalogowane `gh auth status` oraz dostęp do odczytu PR-a i gałęzi źródłowej.
#>
function New-WorktreeForPr {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidatePattern('^\d+$')]
        [string] $PrNumber,

        [string] $WorktreesRoot
    )

    $ErrorActionPreference = "Stop"

    $ghExists = $null -ne (Get-Command gh -ErrorAction SilentlyContinue)
    $gitExists = $null -ne (Get-Command git -ErrorAction SilentlyContinue)

    if (-not $ghExists) {
        throw "Wymagane jest narzędzie 'gh' (GitHub CLI)."
    }

    if (-not $gitExists) {
        throw "Wymagane jest narzędzie 'git'."
    }

    git rev-parse --is-inside-work-tree *> $null
    Check-LastExitCode "verify git repository"

    gh auth status *> $null
    Check-LastExitCode "verify gh auth"

    if ([string]::IsNullOrWhiteSpace($WorktreesRoot)) {
        $WorktreesRoot = Get-DefaultWorktreesRoot
    }

    if (-not (Test-Path -LiteralPath $WorktreesRoot)) {
        New-Item -ItemType Directory -Path $WorktreesRoot -Force | Out-Null
    }

    $ghArgs = @('pr', 'view', $PrNumber, '--json', 'number,headRefName,url')

    $prJson = & gh @ghArgs 2>&1
    if ($LASTEXITCODE -ne 0 -or -not $prJson) {
        $msg = $prJson | ForEach-Object { "$_" } | Out-String
        throw "Nie udało się pobrać danych PR #$PrNumber z GitHuba.`n$($msg.Trim())"
    }

    $prInfo = $prJson | ConvertFrom-Json
    if (-not $prInfo -or [string]::IsNullOrWhiteSpace($prInfo.headRefName)) {
        throw "Brak nazwy gałęzi źródłowej dla PR #$PrNumber."
    }

    $sourceBranch = $prInfo.headRefName
    $worktreePath = Join-Path $WorktreesRoot "pr-$PrNumber"

    if (Test-Path -LiteralPath $worktreePath) {
        throw "Katalog docelowy już istnieje: $worktreePath"
    }

    Write-Host ""
    Write-Host "Pobieram dane dla PR #$PrNumber" -ForegroundColor Cyan
    Write-Host "Source branch: $sourceBranch" -ForegroundColor Cyan
    Write-Host "Worktree path: $worktreePath" -ForegroundColor Cyan
    Write-Host ""

    Invoke-Git "fetch origin" @('fetch', 'origin')

    Invoke-Git "create worktree" @('worktree', 'add', $worktreePath, "$sourceBranch")

    Write-Host "Gotowe ✅" -ForegroundColor Green
    Write-Host "PR URL:       $($prInfo.url)"
    Write-Host "Source branch: $sourceBranch"
    Write-Host "Worktree:      $worktreePath"

    Set-Location $worktreePath
}