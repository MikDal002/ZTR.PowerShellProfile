
<#
.SYNOPSIS
Tworzy draft PR z pustym commitem oraz worktree powiązany z numerem PR.

.DESCRIPTION
Funkcja automatyzuje przygotowanie „pustego” PR-a do rozpoczęcia pracy.
Wykonuje: walidację środowiska (git/gh), odświeżenie origin, wyznaczenie
gałęzi bazowej, normalizację nazwy zadania, utworzenie lokalnej gałęzi bez
checkouta, wypchnięcie jej na origin, utworzenie draft PR w GitHub CLI oraz
założenie worktree w katalogu domyślnym `{repo}.worktrees\pr-<numerPR>`.

Parametry są opcjonalne i mogą służyć jako wartości domyślne dla promptów.
Gdy parametr nie zostanie podany, użytkownik zostanie poproszony o wartość.

Tytuł wynikowego PR-a ma format: `[AB#<adoNumber>] <shortName>`, gdzie `adoNumber` to
wartość parametru `adoNumber`, a `shortName` to wartość parametru `shortName`.

Gałąź natomiast to `task/<adoNumber>/<shortNameNormalized>`, gdzie 
`shortNameNormalized` to znormalizowana wartość `shortName` (małe litery, 
spacje na '-', usunięcie niedozwolonych znaków).

.PARAMETER adoNumber
Numer zadania ADO. Wartość musi składać się z samych cyfr. Jest następnie 
używana w nazwie gałęzi oraz tytule PR.

.PARAMETER shortName
Krótka nazwa zadania używana do budowy nazwy gałęzi i tytułu PR.
Bezposrednia wartość bedzie uzyta w tytle PRka, wiec powinna być zrozumiała dla człowieka.
Podana Wartość po nrmalizacji: konwersja na(małe litery, spacje na '-', usunięcie
niedozwolonych znaków) będzie użyta w nazwie gałęzi. 

.EXAMPLE
New-EmptyPrWorktree

Interaktywnie pyta o numer ADO i krótką nazwę, tworzy draft PR,
a następnie tworzy i otwiera worktree `pr-<numerPR>`.

.EXAMPLE
New-EmptyPrWorktree -adoNumber "123456" -shortName "Fix tax mapping"

Używa podanych wartości jako domyślnych w promptach, tworzy gałąź
`task/123456/fix-tax-mapping`, draft PR i odpowiadający worktree.

.NOTES
Wymagania: aktywne repozytorium git, skonfigurowany remote `origin`,
zalogowane `gh auth status` oraz uprawnienia do push i tworzenia PR.
#>
function New-EmptyPrWorktree {
    [CmdletBinding()]
    param(
        [string] $adoNumber,
        [string] $shortName
    )
    $ErrorActionPreference = "Stop"

    function Normalize-ShortName {
        param([string]$Text)

        if ([string]::IsNullOrWhiteSpace($Text)) {
            return ""
        }

        $normalized = $Text.Trim().ToLower()
        $normalized = $normalized -replace '\s+', '-'
        $normalized = $normalized -replace '[^a-z0-9\-_\/]', ''
        $normalized = $normalized -replace '-{2,}', '-'
        $normalized = $normalized.Trim('-', '/')

        return $normalized
    }

    function Read-HostWithDefault {
        param(
            [Parameter(Mandatory = $true)]
            [string] $Prompt,

            [string] $DefaultValue
        )

        if ([string]::IsNullOrWhiteSpace($DefaultValue)) {
            return Read-Host $Prompt
        }

        $userInput = Read-Host "$Prompt [$DefaultValue]"

        if ([string]::IsNullOrWhiteSpace($userInput)) {
            return $DefaultValue
        }

        return $userInput
    }

    function Resolve-TargetBranch {

        # Refresh remote refs first; branch discovery below depends on current metadata.
        Invoke-Git "fetch origin" @("fetch", "origin")

        $originHead = (& git symbolic-ref --short refs/remotes/origin/HEAD 2>$null | Select-Object -First 1)
        if (-not [string]::IsNullOrWhiteSpace($originHead) -and $originHead -match '^origin/(.+)$') {
            return $Matches[1]
        }

        $manualBranch = Read-HostWithDefault -Prompt "Podaj branch bazowy (origin/...)" -DefaultValue "main"
        if ([string]::IsNullOrWhiteSpace($manualBranch)) {
            throw "Nie podano gałęzi bazowej."
        }

        return $manualBranch.Trim()
    }

    # ---- CONFIG ----
    $commitMessage = "empty commit to create PR to start discussion"

    # ---- Basic checks ----
    git rev-parse --is-inside-work-tree *> $null
    Check-LastExitCode "verify git repository"

    gh auth status *> $null
    Check-LastExitCode "verify gh auth"

    $targetBranch = Resolve-TargetBranch

    # ---- Input ----
    $adoNumber = Read-HostWithDefault -Prompt "Podaj numer ADO" -DefaultValue $adoNumber
    $adoNumberClean = Resolve-AdoNumber -Value $adoNumber
    $shortName = Read-HostWithDefault -Prompt "Podaj krótką nazwę" -DefaultValue $shortName

    if ([string]::IsNullOrWhiteSpace($shortName)) {
        throw "Krótka nazwa nie może być pusta."
    }

    $shortNameClean = Normalize-ShortName $shortName

    if ([string]::IsNullOrWhiteSpace($shortNameClean)) {
        throw "Po normalizacji krótka nazwa jest pusta."
    }

    $branchName = if ($adoNumberClean) { "task/$adoNumberClean/$shortNameClean" } else { "devWorktree/$shortNameClean" }
    $prTitle = if ($adoNumberClean) { "[AB#$adoNumberClean] $shortName" } else { $shortName }

    Write-Host ""
    Write-Host "Tworzę branch bez checkouta i bez worktree..." -ForegroundColor Cyan
    Write-Host "Branch: $branchName" -ForegroundColor Cyan
    Write-Host "Base:   refs/remotes/origin/$targetBranch" -ForegroundColor Cyan
    Write-Host ""

    # ---- Verify resolved origin target branch exists ----
    git show-ref --verify --quiet "refs/remotes/origin/$targetBranch"
    Check-LastExitCode "verify origin target branch"

    # ---- Verify branch does not already exist locally ----
    git show-ref --verify --quiet "refs/heads/$branchName"
    if ($LASTEXITCODE -eq 0) {
        throw "Lokalny branch '$branchName' już istnieje."
    }

    # ---- Verify branch does not already exist remotely ----
    git ls-remote --exit-code --heads origin $branchName *> $null
    if ($LASTEXITCODE -eq 0) {
        throw "Zdalny branch '$branchName' już istnieje na origin."
    }

    # ---- Read base commit/tree from resolved target branch ----
    $baseCommit = (git rev-parse "refs/remotes/origin/$targetBranch").Trim()
    Check-LastExitCode "read target commit"

    $baseTree = (git show -s --format=%T "refs/remotes/origin/$targetBranch").Trim()
    Check-LastExitCode "read target tree"

    if ([string]::IsNullOrWhiteSpace($baseCommit)) {
        throw "Nie udało się odczytać SHA origin/$targetBranch."
    }

    if ([string]::IsNullOrWhiteSpace($baseTree)) {
        throw "Nie udało się odczytać tree lokalnego origin/$targetBranch."
    }

    # ---- Create empty commit object without checkout ----
    $newCommit = (Invoke-Git "create empty commit object" @("commit-tree", $baseTree, "-p", $baseCommit, "-m", $commitMessage)).Trim()

    if ([string]::IsNullOrWhiteSpace($newCommit)) {
        throw "Nie udało się utworzyć pustego commita."
    }

    # ---- Create local branch ref pointing to new commit ----
    Invoke-Git "create local branch ref" @("update-ref", "refs/heads/$branchName", $newCommit)

    # ---- Push branch without checkout ----
    Invoke-Git "push branch" @("push", "-u", "origin", "refs/heads/${branchName}:refs/heads/$branchName")

    # ---- Create draft PR ----
    $prUrl = gh pr create `
        --base $targetBranch `
        --head $branchName `
        --title $prTitle `
        --body "Auto-generated draft for PR about '$shortName'." `
        --draft
    Check-LastExitCode "create draft PR"

    $prNumber = gh pr view $prUrl --json number --jq '.number'
    Check-LastExitCode "get PR number"

    if ([string]::IsNullOrWhiteSpace($prNumber) -or $prNumber -notmatch '^\d+$') {
        throw "Nie udało się pobrać numeru PR."
    }

    # ---- Create worktree ----
    $worktreesRoot = Get-DefaultWorktreesRoot
    $worktreePath = Join-Path $worktreesRoot "pr-$prNumber"
    Invoke-Git "create worktree" @("worktree", "add", $worktreePath, $branchName)

    Write-Host ""
    Write-Host "Gotowe ✅" -ForegroundColor Green
    Write-Host "Branch:   $branchName"
    Write-Host "PR:       $prUrl"
    Write-Host "Worktree: $worktreePath"

    Set-Location $worktreePath
}
