

<#
.SYNOPSIS
Tworzy pusty roboczy worktree od domyślnej gałęzi origin (origin/HEAD).

.DESCRIPTION
Skrót na `git worktree add` z ustalonymi domyślnymi wartościami:
- bazą jest domyślna gałąź origin (origin/HEAD, po `git fetch origin`),
- gdy `-AdoNumber` nie jest podany, gałąź jest tworzona jako `devWorktree/<normalizedBranchName>`;
  gdy `-AdoNumber` jest podany, jako `task/<adoNumber>/<normalizedBranchName>`,
- katalog worktree powstaje w `{repo}.worktrees\<sanitized-branch>`,
- po utworzeniu funkcja przełącza bieżącą lokalizację do nowego worktree.

Jeżeli nazwa gałęzi nie zostanie podana w parametrze, użytkownik zostanie
o nią poproszony.

.PARAMETER BranchName
Nazwa lokalnej gałęzi do utworzenia. Jeśli pominięta, funkcja zapyta o nią.
Jeśli podano `-AdoNumber`, ta wartość jest traktowana jako krótka nazwa
(sufiks po `task/<numerADO>/`) i przed użyciem zostaje znormalizowana
(małe litery, spacje na `-`, usunięcie niedozwolonych znaków).

.PARAMETER AdoNumber
Opcjonalny numer zadania ADO. Gdy podany, gałąź zostanie utworzona w formacie
`task/<numerADO>/<shortNameNormalized>`, a `BranchName` jest interpretowany
jako krótka nazwa (np. "Fix tax mapping" -> `task/123456/fix-tax-mapping`).

.EXAMPLE
New-DevWorktree

Zapyta o nazwę gałęzi (np. `quick-fix`) i utworzy worktree
`{repo}.worktrees\devWorktree-quick-fix` z gałęzią `devWorktree/quick-fix` pochodzącą
od `origin/HEAD` (domyślna gałąź remote).

.EXAMPLE
New-DevWorktree -BranchName task/123/quick-fix

Utworzy worktree od razu, bez pytania.

.EXAMPLE
New-DevWorktree -AdoNumber 123456

Zapyta o krótką nazwę (np. "Fix tax mapping") i utworzy gałąź
`task/123456/fix-tax-mapping` od `origin/HEAD` (domyślna gałąź remote).

.NOTES
Wymagania: aktywne repozytorium git, skonfigurowany `origin/HEAD` (domyślna gałąź remote), push nie
jest wykonywany — gałąź pozostaje lokalna do czasu pierwszego pusha.
#>
function New-DevWorktree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $BranchName,

        [string] $AdoNumber
    )

    $ErrorActionPreference = "Stop"

    function Get-SanitizedBranchSegment {
        param([string]$Text)
        if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
        $s = $Text.Trim()
        $s = $s -replace '[\\/]+', '-'
        $s = $s -replace '[^A-Za-z0-9._\-]', '-'
        $s = $s -replace '-{2,}', '-'
        return $s.Trim('-', '.', '_')
    }

    function Get-NormalizedBranchName {
        param([string]$Text)
        if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
        $n = $Text.Trim().ToLower()
        $n = $n -replace '\\+', '/'
        $n = $n -replace '\s+', '-'
        $n = $n -replace '[^a-z0-9\-_\/\.]', ''
        $n = $n -replace '/{2,}', '/'
        $n = $n -replace '-{2,}', '-'
        $n = $n -replace '\.{2,}', '.'
        $n = $n -replace '/\.', '/'
        $n = $n -replace '\./', '/'
        $n = $n.Trim('-', '/', '.')
        return $n
    }

    $gitExists = $null -ne (Get-Command git -ErrorAction SilentlyContinue)
    if (-not $gitExists) { throw "Wymagane jest narzędzie 'git'." }

    & git rev-parse --is-inside-work-tree *> $null
    Check-LastExitCode "verify git repository"

    $adoNumberClean = Resolve-AdoNumber -Value $AdoNumber

    if ([string]::IsNullOrWhiteSpace($BranchName)) {
        $prompt = if ($adoNumberClean) { "Podaj krótką nazwę" } else { "Podaj nazwę gałęzi" }
        $BranchName = Read-Host $prompt
    }

    if ([string]::IsNullOrWhiteSpace($BranchName)) {
        throw "Nazwa gałęzi nie może być pusta."
    }

    $rawInput = $BranchName.Trim()
    $normalizedInput = Get-NormalizedBranchName $rawInput
    if ([string]::IsNullOrWhiteSpace($normalizedInput)) {
        throw "Po normalizacji nazwa gałęzi jest pusta."
    }

    if ($adoNumberClean) {
        $BranchName = "task/$adoNumberClean/$normalizedInput"
    }
    else {
        $BranchName = "devWorktree/$normalizedInput"
    }

    if ($BranchName -ne $rawInput) {
        Write-Host "Znormalizowana nazwa gałęzi: $BranchName" -ForegroundColor DarkYellow
    }

    & git check-ref-format --branch $BranchName *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Nazwa gałęzi '$BranchName' jest nieprawidłowa dla git."
    }

    Invoke-Git "fetch origin" @('fetch', 'origin')
    
    $baseBranch = git symbolic-ref refs/remotes/origin/HEAD 2>$null | Select-Object -First 1
    & git show-ref --verify --quiet -- "$baseBranch"
    if ($LASTEXITCODE -ne 0) {
        throw "Gałąź bazowa '$baseBranch' nie istnieje."
    }

    & git show-ref --verify --quiet "refs/heads/$BranchName"
    if ($LASTEXITCODE -eq 0) {
        throw "Lokalna gałąź '$BranchName' już istnieje."
    }

    $folderName = Get-SanitizedBranchSegment $BranchName
    if ([string]::IsNullOrWhiteSpace($folderName)) {
        throw "Nazwa katalogu wyliczona z gałęzi jest pusta po normalizacji."
    }

    $worktreesRoot = Get-DefaultWorktreesRoot
    if (-not (Test-Path -LiteralPath $worktreesRoot)) {
        New-Item -ItemType Directory -Path $worktreesRoot -Force | Out-Null
    }

    $worktreePath = Join-Path $worktreesRoot $folderName
    if (Test-Path -LiteralPath $worktreePath) {
        throw "Katalog docelowy już istnieje: $worktreePath"
    }

    Write-Host ""
    Write-Host "Tworzę worktree od $baseBranch..." -ForegroundColor Cyan
    Write-Host "Branch:   $BranchName"
    Write-Host "Base:     $baseBranch"
    Write-Host "Worktree: $worktreePath"
    Write-Host ""

    Invoke-Git "create worktree" @('worktree', 'add', '-b', $BranchName, $worktreePath, $baseBranch)

    Write-Host "Gotowe ✅" -ForegroundColor Green

    Push-Location -LiteralPath $worktreePath
}
