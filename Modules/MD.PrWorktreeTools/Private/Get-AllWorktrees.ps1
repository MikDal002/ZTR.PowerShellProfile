
function Get-AllWorktrees {
    [CmdletBinding()]
    param(
        [string]$RepoPath
    )
    
    $worktrees = @()
    $current = @{}
    $count = 0;

    git worktree list --porcelain | ForEach-Object {
        if ($_ -eq "") {
            if ($current.Count -gt 0) {
                $current.ToMove = $false
                $current.PrNumber = $null

                $worktrees += [PSCustomObject]($current)
                $current = @{}
            }
        }
        elseif ($_.StartsWith("worktree")) { 
            $current.Path = $_.Split(" ")[1]
            if ($count -eq 0) {
                $current.IsMain = $true
            }
            else {
                $current.IsMain = $false
            }
        }
        elseif ($_.StartsWith("branch")) { 
            $current.Branch = $_.Split(" ")[1]
        }
        else {
            Write-Debug "Skipping $_"
        }

        $count += 1;
    }
    
    Write-Debug "Get-AllWorktrees: Parsed worktrees: $($worktrees | Format-List | Out-String)"

    return ConvertTo-Json $worktrees | ConvertFrom-Json
}
