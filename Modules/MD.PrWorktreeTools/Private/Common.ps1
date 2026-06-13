
function Get-MainRepoPath {
    Write-Debug "Get-MainRepoPath: Invoked in directory: $(Get-Location)"

    $gitCommonDir = (& git rev-parse --path-format=absolute --git-common-dir 2>$null | Select-Object -First 1)
    if (-not [string]::IsNullOrWhiteSpace($gitCommonDir)) {
        $gitCommonDir = $gitCommonDir.Trim()
        if (Test-Path -LiteralPath $gitCommonDir) {
            $resolvedPath = Split-Path -Path $gitCommonDir -Parent
            Write-Debug "Resolved main repo path: $resolvedPath"
            return $resolvedPath
        }
    }

    throw "Nie udało się ustalić głównego katalogu repozytorium. Uruchom komendę w repo lub podaj ścieżkę jawnie."
}


function Get-DefaultWorktreesRoot {
    $repoRoot = Get-MainRepoPath

    if ([string]::IsNullOrWhiteSpace($repoRoot)) {
        throw "Nie udało się ustalić głównego katalogu repozytorium. Uruchom komendę w repo lub podaj ścieżkę jawnie."
    }

    if (-not [System.IO.Path]::IsPathRooted($repoRoot)) {
        try {
            $repoRoot = (Resolve-Path -LiteralPath $repoRoot -ErrorAction Stop).Path
        }
        catch {
            $repoRoot = [System.IO.Path]::GetFullPath($repoRoot)
        }
    }

    if (-not (Test-Path -LiteralPath $repoRoot)) {
        throw "Katalog git-common-dir nie istnieje: $repoRoot"
    }

    $worktreesRoot = "$repoRoot.worktrees"
    Write-Debug "Resolved worktrees root: $worktreesRoot"
    return $worktreesRoot
}

function Check-LastExitCode {
    param([string]$StepName)

    if ($LASTEXITCODE -ne 0) {
        throw "Błąd podczas kroku: $StepName"
    }
}

function Invoke-Git {
    param([string]$StepName, [string[]]$GitArgs)

    Write-Debug "Running git command: git $($GitArgs -join ' ')"

    $output = & git @GitArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        $errMsg = $output | ForEach-Object { "$_" } | Out-String
        throw "Błąd podczas '$StepName':`n$($errMsg.Trim())"
    }
    return ($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
}


<#
Resolve-RepoNameWithOwner:
- domyślnie ustala repo w formacie 'owner/name' na podstawie bieżącego katalogu
  przez `gh repo view --json nameWithOwner`,
- gdy gh nie jest dostępne lub nie da się ustalić repo, pyta użytkownika.
#>
function Resolve-RepoNameWithOwner {
    [CmdletBinding()]
    param()
    Write-Debug "Resolve-RepoNameWithOwner: In directory $(Get-Location)"
    
    $nwo = & gh repo view --json nameWithOwner --jq '.nameWithOwner' | Select-Object -First 1
    Write-Debug "Resolve-RepoNameWithOwner: Retrieved nameWithOwner: $nwo (ExitCode: $LASTEXITCODE)"
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($nwo)) {
        return $nwo.Trim()
    }
    else {
        throw "Nie podano repozytorium (owner/name)."
    }
}

function Is-True($value) {
    # Normalize the value to string for comparison
    if ($null -eq $value) { return $false }

    # Trim and lowercase for consistent matching
    $strValue = "$value".Trim().ToLower()

    # Acceptable "true" values
    $trueValues = @("true", "yes", "1")

    return $trueValues -contains $strValue
}

