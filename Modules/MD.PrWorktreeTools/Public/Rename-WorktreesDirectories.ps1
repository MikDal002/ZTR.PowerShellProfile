
function Rename-WorktreesDirectories {
    [CmdletBinding()]
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Get-Location
    }
    else {
        Set-Location -Path $Path
    }
    
    $MainRepoPath = Get-MainRepoPath

    Set-Location $MainRepoPath

    $worktrees = Get-AllWorktrees -RepoPath $MainRepoPath

    $mainWorktree = $worktrees | Where-Object { $_.IsMain } | Select-Object -First 1
    Write-Debug "Main worktree: $($mainWorktree.Path)"
    Write-Host "${ConvertTo-Json $worktrees -Depth 5}"

    $workTreeDirectory = Get-DefaultWorktreesRoot
    $workTreeDirectory = $workTreeDirectory.Replace("\", "/")
    Write-Debug "Normalized (\ -> /) worktree directory: $($workTreeDirectory)"

    foreach ($wt in $worktrees) {
        if ($wt.IsMain) { continue }
        
        try {
            Push-Location $wt.Path

            $wt.PrNumber = gh pr view --json number 
            | ConvertFrom-Json 2>$null 
            | Select-Object -ExpandProperty number 2>$null
        }
        catch {
            Pop-Location
        }

        Write-Host "Worktree: $($wt.Path)"
        if (-not $wt.PrNumber) {
            Write-Host "`tdoes not seem to be associated with a PR (gh pr view failed), skipping." -ForegroundColor Gray
            continue;
        }
        else {
            Write-Host "'$($wt.Path)'"
            Write-Host "`tis associated with PR #$($wt.PrNumber)." -ForegroundColor Green
        }

        if (-not ($wt.Path -like "$workTreeDirectory*")) {
            $wt.ToMove = $true
            Write-Host "`tis in incorrect root location" -ForegroundColor Yellow
        }
        else {
            Write-Host "`tis in correct root location" -ForegroundColor Green
        }

        if (-not ($wt.Path -match "pr-\d+$") ) {
            $wt.ToMove = $true
            Write-Host "`thas a non-standard name" -ForegroundColor Yellow
        }
        else {
            Write-Host "`thas a standard name" -ForegroundColor Green
        }

        if ($wt.ToMove) {
            Write-Host "`tso will be moved." -ForegroundColor Yellow
        }
        else {
            Write-Host "`tso will be left as is." -ForegroundColor Green
        }
        
    }

    Set-Location $MainRepoPath
    $worktreesToMove = $worktrees | Where-Object { $_.ToMove }

    foreach ($wt in $worktreesToMove) {
        
        $prDirName = "pr-$($wt.PrNumber)"
        $newPath = Join-Path $workTreeDirectory $prDirName
        Write-Host "Renaming '$($wt.Path)' to '$newPath'..." -ForegroundColor Cyan
        
        if (Test-Path -LiteralPath $newPath) {
            Write-Host "Cannot rename '$($wt.Path)' to '$newPath' because the target already exists. Skipping." -ForegroundColor Red
            continue;
        }

        git worktree move $wt.Path $newPath
    }


}
