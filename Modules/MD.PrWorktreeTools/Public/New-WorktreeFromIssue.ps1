<#
.SYNOPSIS
    Tworzy nowy worktree na podstawie GitHub Issue.

.DESCRIPTION
    Pobiera tytuł issue, normalizuje go na nazwę gałęzi i tworzy nowy worktree.
    Format gałęzi: task/<adoNumber>/<normalized-issue-title>

.PARAMETER IssueNumber
    Numer GitHub Issue.

.PARAMETER TaskNumber
    Opcjonalny numer zadania (np. ADO). Jeśli nie podany i nie wymagany przez środowisko,
    zostanie użyty IssueNumber jako identyfikator zadania.

.PARAMETER Base
    Opcjonalna nazwa gałęzi bazowej, z której ma zostać utworzona nowa gałąź.
#>
function New-WorktreeFromIssue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$IssueNumber,

        [string]$TaskNumber,

        [string]$Base
    )

    # 1. Pobierz info o issue
    $issue = gh issue view $IssueNumber --json title | ConvertFrom-Json
    $title = $issue.title

    # 2. Ustal numer zadania (ADO jeśli wymagane/podane, w przeciwnym razie IssueNumber)
    $resolvedAdo = Resolve-AdoNumber -Value $TaskNumber -Context "Issue #${IssueNumber}: $title"
    $idToUse = if ($resolvedAdo) { $resolvedAdo } else { $IssueNumber }

    # 3. Normalizacja nazwy gałęzi (wyciągnięta z logiki New-DevWorktree)
    $normalizedTitle = $title.Trim().ToLower() -replace '\s+', '-' -replace '[^a-z0-9\-]', '' -replace '-{2,}', '-' -replace '^-|-$', ''
    $branchName = "task/$idToUse/$normalizedTitle"

    # 4. Ścieżka worktree
    $worktreesRoot = Get-DefaultWorktreesRoot
    $folderName = "issue-$IssueNumber"
    $worktreePath = Join-Path $worktreesRoot $folderName

    Write-Host "Tworzę worktree z Issue #$IssueNumber" -ForegroundColor Cyan
    Write-Host "Tytuł:   $title"
    Write-Host "Branch:  $branchName"
    Write-Host "Ścieżka: $worktreePath"

    # 5. Akcja (gh issue develop tworzy branch i linkuje go do issue)
    Write-Host "Linkuję branch do issue na GitHubie..." -ForegroundColor Gray
    $ghArgs = @($IssueNumber, "--name", $branchName)
    if (-not [string]::IsNullOrWhiteSpace($Base)) {
        $ghArgs += "--base"
        $ghArgs += $Base
    }
    gh issue develop @ghArgs

    git fetch origin
    git worktree add $worktreePath $branchName

    # 6. Wejdź do środka
    Set-Location $worktreePath
}
