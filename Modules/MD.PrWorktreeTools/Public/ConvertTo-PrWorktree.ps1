
<#
.SYNOPSIS
Konwertuje istniejący worktree (bez PR) na worktree powiązany z PR.

.DESCRIPTION
Funkcja bierze worktree, którego gałąź nie ma jeszcze PR-a, i:
1. (opcjonalnie) pushuje gałąź na origin,
2. tworzy PR na GitHubie do gałęzi bazowej (domyślnie `development`),
3. przenosi worktree do katalogu zgodnego ze standardem
   `{repo}.worktrees\pr-<numerPR>` (`git worktree move`),
4. przełącza bieżącą lokalizację do nowego katalogu worktree.

Numer ADO jest wyciągany z nazwy gałęzi (wzorzec `task/<numer>/...` lub
pierwsza grupa cyfr w nazwie). Tytuł i opis PR-a są budowane z ostatniego
commita gałęzi: pierwsza linia (subject) -> tytuł, reszta (body) -> opis.
Jeśli udało się wyciągnąć numer ADO, a tytuł nie zawiera już znacznika
`[AB#...]`, prefiks `[AB#<numerADO>] ` zostanie dodany na początku tytułu.

.PARAMETER WorktreePath
Ścieżka do istniejącego worktree. Jeśli pominięta, używana jest bieżąca
lokalizacja (PWD), o ile znajduje się wewnątrz worktree.

.PARAMETER TargetBranch
Nazwa gałęzi bazowej (na origin), do której zostanie utworzony PR.
Domyślnie `development`.

.PARAMETER NotDraft
Tworzy PR jako gotowy do review. Domyślnie PR powstaje jako draft.

.EXAMPLE
ConvertTo-PrWorktree

Zakładając, że jesteś w katalogu worktree z gałęzią `task/123456/foo-bar`
i ostatnim commitem `Fix tax mapping`, utworzy PR `[AB#123456] Fix tax mapping`
do `development`, a następnie przeniesie worktree do
`{repo}.worktrees\pr-<numerPR>` i przełączy tam lokalizację.

.EXAMPLE
ConvertTo-PrWorktree -WorktreePath D:\repos\foo.worktrees\hotfix-x -TargetBranch main -NotDraft

Tworzy PR gotowy do review do `main` z worktree spod podanej ścieżki.

.NOTES
Wymagania: aktywne repozytorium git, dostępne narzędzia `git` i `gh`,
zalogowane `gh auth status`, push i tworzenie PR dozwolone na origin.
#>
function ConvertTo-PrWorktree {
    [CmdletBinding()]
    param(
        [string] $WorktreePath = (Get-Location).Path,
        [string] $TargetBranch = "development",
        [string] $AdoNumber,
        [switch] $NotDraft
    )

    $ErrorActionPreference = "Stop"

    $ghExists = $null -ne (Get-Command gh -ErrorAction SilentlyContinue)
    $gitExists = $null -ne (Get-Command git -ErrorAction SilentlyContinue)

    if (-not $gitExists) { throw "Wymagane jest narzędzie 'git'." }
    if (-not $ghExists) { throw "Wymagane jest narzędzie 'gh' (GitHub CLI)." }

    # ---- Resolve worktree path ----
    if (-not (Test-Path -LiteralPath $WorktreePath)) {
        throw "Wskazana ścieżka worktree nie istnieje: $WorktreePath"
    }

    $WorktreePath = (Resolve-Path -LiteralPath $WorktreePath).Path
    Write-Debug "Resolved worktree path: $WorktreePath"

    & git -C $WorktreePath rev-parse --is-inside-work-tree *> $null
    Check-LastExitCode "verify git repository at $WorktreePath"

    $worktreeRoot = (& git -C $WorktreePath rev-parse --show-toplevel 2>$null | Select-Object -First 1)
    if ($worktreeRoot) { $worktreeRoot = $worktreeRoot.Trim() }
    if ([string]::IsNullOrWhiteSpace($worktreeRoot)) {
        throw "Nie udało się ustalić katalogu top-level worktree dla: $WorktreePath"
    }

    $gitCommonDir = (& git -C $WorktreePath rev-parse --path-format=absolute --git-common-dir 2>$null | Select-Object -First 1)
    if ($gitCommonDir) { $gitCommonDir = $gitCommonDir.Trim() }
    if ([string]::IsNullOrWhiteSpace($gitCommonDir) -or -not (Test-Path -LiteralPath $gitCommonDir)) {
        throw "Nie udało się ustalić głównego katalogu repozytorium."
    }
    $mainRepoRoot = Split-Path -Path $gitCommonDir -Parent
    Write-Debug "Resolved main repository root: $mainRepoRoot"

    # ---- Check gh auth ----
    & gh auth status *> $null
    Check-LastExitCode "verify gh auth"

    # ---- Resolve branch on the worktree ----
    $branchName = (& git -C $worktreeRoot rev-parse --abbrev-ref HEAD 2>$null | Select-Object -First 1)
    if ($branchName) { $branchName = $branchName.Trim() }
    if ([string]::IsNullOrWhiteSpace($branchName) -or $branchName -eq 'HEAD') {
        throw "Worktree nie wskazuje na nazwaną gałąź (HEAD jest odłączone)."
    }

    if ($branchName -eq $TargetBranch) {
        throw "Gałąź worktree '$branchName' jest tożsama z gałęzią bazową '$TargetBranch'."
    }

    # ---- Verify target branch exists on origin ----
    & git fetch origin *> $null
    Check-LastExitCode "fetch origin"

    & git show-ref --verify --quiet "refs/remotes/origin/$TargetBranch"
    if ($LASTEXITCODE -ne 0) {
        throw "Gałąź bazowa 'origin/$TargetBranch' nie istnieje."
    }

    # ---- Check that no PR already exists for this branch ----
    $existingPr = & gh pr list --head $branchName --state open --json number --jq '.[0].number' 2>$null
    if (-not [string]::IsNullOrWhiteSpace($existingPr)) {
        throw "Dla gałęzi '$branchName' istnieje już otwarty PR #$existingPr."
    }

    # ---- Extract ADO number from branch name (best-effort) ----
    $adoExtracted = $null
    if ($AdoNumber) {
        $adoExtracted = $AdoNumber
        Write-Debug "Using ADO number from parameter: $adoExtracted"
    }
    else {
        if ($branchName -match 'task/(\d+)') { $adoExtracted = $Matches[1] }
        elseif ($branchName -match '(\d{3,})') { $adoExtracted = $Matches[1] }
        Write-Debug "Extracted ADO number from branch name: $adoExtracted"
    }

    $adoNumber = Resolve-AdoNumber -Value $adoExtracted -Context $branchName
    Write-Debug "Resolved ADO number: $adoNumber"

    # ---- Push branch if not on origin (or if local is ahead) ----
    & git ls-remote --exit-code --heads origin $branchName *> $null
    $remoteExists = ($LASTEXITCODE -eq 0)
    Write-Debug "Remote branch exists: $remoteExists"

    if (-not $remoteExists) {
        if ($adoNumber) {
            Invoke-Git "push branch" @('-C', $worktreeRoot, 'push', '-u', 'origin', "refs/heads/${branchName}:refs/heads/task/${adoNumber}/$branchName")
        }
        else {
            Invoke-Git "push branch" @('-C', $worktreeRoot, 'push', '-u', 'origin', "refs/heads/${branchName}:refs/heads/$branchName")
        }
    }
    else {
        Invoke-Git "push branch (sync)" @('-C', $worktreeRoot, 'push', 'origin', 'HEAD')
        
    }


    # ---- Build title/body from last commit on the branch ----
    $commitSubject = (& git -C $worktreeRoot log -1 --format=%s 2>$null | Out-String).Trim()
    $commitBody = (& git -C $worktreeRoot log -1 --format=%b 2>$null | Out-String).Trim()

    if ([string]::IsNullOrWhiteSpace($commitSubject)) {
        throw "Nie udało się odczytać subjectu ostatniego commita."
    }

    $title = $commitSubject
    if ($adoNumber -and $title -notmatch '\[AB#\d+\]') {
        $title = "[AB#$adoNumber] $commitSubject"
    }

    $body = if ([string]::IsNullOrWhiteSpace($commitBody)) { $title } else { $commitBody }

    Write-Host ""
    Write-Host "Tworzę PR dla istniejącego worktree..." -ForegroundColor Cyan
    Write-Host "Worktree:  $worktreeRoot"
    Write-Host "Branch:    $branchName"
    Write-Host "Base:      $TargetBranch"
    Write-Host "ADO #:     $(if ($adoNumber) { $adoNumber } else { '(brak — pomijam prefiks AB#)' })"
    Write-Host "Title:     $title"
    Write-Host "NotDraft:     $($NotDraft.IsPresent)"
    Write-Host ""

    # ---- Create PR ----
    $prArgs = @(
        'pr', 'create',
        '--base', $TargetBranch,
        '--head', $branchName,
        '--title', $title,
        '--body', $body
    )
    if (-not $NotDraft) { $prArgs += '--draft' }

    $prUrl = & gh @prArgs
    Check-LastExitCode "create PR"

    if ($prUrl -is [System.Array]) { $prUrl = ($prUrl | Where-Object { $_ -match 'https?://' } | Select-Object -Last 1) }
    $prUrl = ($prUrl | Out-String).Trim()

    if ([string]::IsNullOrWhiteSpace($prUrl)) {
        throw "Nie udało się odczytać URL utworzonego PR-a."
    }

    $prNumber = & gh pr view $prUrl --json number --jq '.number'
    Check-LastExitCode "get PR number"

    if ([string]::IsNullOrWhiteSpace($prNumber) -or $prNumber -notmatch '^\d+$') {
        throw "Nie udało się pobrać numeru PR z URL: $prUrl"
    }

    # ---- Compute new worktree path and move ----
    $worktreesRoot = Get-DefaultWorktreesRoot
    if (-not (Test-Path -LiteralPath $worktreesRoot)) {
        New-Item -ItemType Directory -Path $worktreesRoot -Force | Out-Null
    }

    $newWorktreePath = Join-Path $worktreesRoot "pr-$prNumber"

    if (Test-Path -LiteralPath $newWorktreePath) {
        $samePath = $false
        try { $samePath = ((Resolve-Path -LiteralPath $newWorktreePath).Path -eq $worktreeRoot) } catch {}
        if (-not $samePath) {
            throw "Katalog docelowy worktree już istnieje: $newWorktreePath"
        }
    }

    # Avoid 'git worktree move' refusing because PWD is inside the worktree being moved.
    $currentLocation = (Get-Location).Path
    $pwdInsideWorktree = $currentLocation -like "$worktreeRoot*"
    if ($pwdInsideWorktree) {
        Set-Location -LiteralPath $mainRepoRoot
    }

    try {
        if ((Resolve-Path -LiteralPath $worktreeRoot).Path -ne (Resolve-Path -LiteralPath $newWorktreePath -ErrorAction SilentlyContinue).Path) {
            Invoke-Git "move worktree" @('-C', $mainRepoRoot, 'worktree', 'move', $worktreeRoot, $newWorktreePath)
        }
    }
    catch {
        if ($pwdInsideWorktree -and (Test-Path -LiteralPath $worktreeRoot)) {
            Set-Location -LiteralPath $worktreeRoot
        }
        throw
    }

    Write-Host ""
    Write-Host "Gotowe ✅" -ForegroundColor Green
    Write-Host "Branch:   $branchName"
    Write-Host "PR:       $prUrl"
    Write-Host "Worktree: $newWorktreePath"

    Set-Location -LiteralPath $newWorktreePath
}
