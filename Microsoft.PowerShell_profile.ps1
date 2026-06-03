
<#
Purpose:
Bootstrap interaktywnego środowiska PowerShell oraz lokalnych narzędzi developerskich.

What lives here today:
- ustawienia interfejsu sesji i historii polecen
- completions i integracje CLI
- aliasy i helpery do codziennej pracy
- funkcje automatyzujace GitHub PR i worktree
- skroty do narzedzi i repo lokalnych

Maintenance rules:
- ten plik powinien pozostac cienkim bootstrapem i punktem wejscia
- wieksza logika powinna byc przenoszona do osobnych plikow lub modulow
- funkcje zalezne od narzedzi zewnetrznych powinny same sprawdzac prerequisites
- zmiany powinny byc wersjonowane w repo Git, a nie utrzymywane tylko lokalnie

Recommended evolution path:
1. Zostawic ten plik jako loader konfiguracji z repo.
2. Rozdzielic kod na obszary, np. shell, completions, aliases, git, worktrees.
3. Wydzielic bardziej zlozone funkcje do modulow .psm1.
4. Dodac README z opisem setupu, zaleznosci i konwencji.
5. Dodac testy Pester dla logiki, ktora buduje nazwy branchy lub wykonuje automatyzacje git/gh.

Suggested structure:
- profile/bootstrap.ps1
- profile/shell.ps1
- profile/completions.ps1
- profile/aliases.ps1
- modules/GitHelpers/GitHelpers.psm1
- modules/WorktreeTools/WorktreeTools.psm1
- README.md

External dependencies used in this profile:
- PSReadLine
- az
- oh-my-posh
- git
- gh
- just

Machine-specific config:
- ten profil jest generyczny i wersjonowany; nie zawiera danych maszynowych ani prywatnych
- prywatna/maszynowa konfiguracja zyje w loaderze w lokalizacji $PROFILE (poza repo, nietrackowany)
- loader moze wypelnic $ExtraThemeCandidates PRZED dot-source'owaniem tego profilu oraz rejestrowac wlasne aliasy/funkcje (np. $repoRoot, gvrt, ctdm)
- funkcje przenoszalne powinny byc oddzielone od aliasow i sciezek zaleznych od lokalnego setupu

Notes:
- obecnie profil zawiera tez konfiguracje silnie zwiazana z lokalnymi sciezkami i repozytoriami
- przy dalszym wzroscie warto oddzielic rzeczy przenoszalne od maszyno-specyficznych
#>

$OutputEncoding = [console]::InputEncoding = [console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

# ===== Theme candidates =====
# $ExtraThemeCandidates may be pre-populated by the loader (the $PROFILE entry
# point) before this profile is dot-sourced - e.g. machine-specific theme paths.
if ($null -eq $ExtraThemeCandidates) {
    $ExtraThemeCandidates = @()
}

$themeCandidates = @(
    (Join-Path $HOME 'mytheme.omp.json'),
    (Join-Path $PSScriptRoot 'mytheme.omp.json')
)
$themeCandidates += $ExtraThemeCandidates

$ohMyPoshTheme = $themeCandidates |
    Where-Object { Test-Path -LiteralPath $_ } |
    Select-Object -First 1

# ===== Interactive shell =====
# This adds the feature that history popsup when you are writing anything in console
if (
    [Environment]::UserInteractive -and
    -not [Console]::IsInputRedirected -and
    -not [Console]::IsOutputRedirected -and
    $host.Name -eq 'ConsoleHost'
)
{
    # This adds the feature that history popsup when you are writing anything in console   
    Import-Module PSReadLine
    Set-PSReadLineOption -PredictionViewStyle ListView
    

    # This adds completition for az cli.
    Register-ArgumentCompleter -Native -CommandName az -ScriptBlock {
        param($commandName, $wordToComplete, $cursorPosition)
        $completion_file = New-TemporaryFile
        $env:ARGCOMPLETE_USE_TEMPFILES = 1
        $env:_ARGCOMPLETE_STDOUT_FILENAME = $completion_file
        $env:COMP_LINE = $wordToComplete
        $env:COMP_POINT = $cursorPosition
        $env:_ARGCOMPLETE = 1
        $env:_ARGCOMPLETE_SUPPRESS_SPACE = 0
        $env:_ARGCOMPLETE_IFS = "`n"
        $env:_ARGCOMPLETE_SHELL = 'powershell'
        az 2>&1 | Out-Null
        Get-Content $completion_file | Sort-Object | ForEach-Object {
            [System.Management.Automation.CompletionResult]::new($_, $_, "ParameterValue", $_)
        }
        Remove-Item $completion_file, Env:\_ARGCOMPLETE_STDOUT_FILENAME, Env:\ARGCOMPLETE_USE_TEMPFILES, Env:\COMP_LINE, Env:\COMP_POINT, Env:\_ARGCOMPLETE, Env:\_ARGCOMPLETE_SUPPRESS_SPACE, Env:\_ARGCOMPLETE_IFS, Env:\_ARGCOMPLETE_SHELL
    }
    
    # oh-my-posh
    if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
        if ($ohMyPoshTheme) {
            oh-my-posh init pwsh --config $ohMyPoshTheme | Invoke-Expression
        }
        else {
            oh-my-posh init pwsh --config powerlevel10k_rainbow | Invoke-Expression
        }
    }
}


# ===== PR and worktree helpers (MD.PrWorktreeTools) =====
$prWorktreeModulePath = Join-Path -Path $PSScriptRoot -ChildPath "Modules/MD.PrWorktreeTools/MD.PrWorktreeTools.psm1"
if (Test-Path -LiteralPath $prWorktreeModulePath -PathType Leaf) {
    Import-Module $prWorktreeModulePath
}
else {
    Write-Host "Nie znaleziono modułu MD.PrWorktreeTools: $prWorktreeModulePath" -ForegroundColor Yellow
}

# ===== PR prompting helpers (MD.PrPromptingTools) =====
$prPromptingModulePath = Join-Path -Path $PSScriptRoot -ChildPath "Modules/MD.PrPromptingTools/MD.PrPromptingTools.psm1"
if (Test-Path -LiteralPath $prPromptingModulePath -PathType Leaf) {
    Import-Module $prPromptingModulePath
}
else {
    Write-Host "Nie znaleziono modułu MD.PrPromptingTools: $prPromptingModulePath" -ForegroundColor Yellow
}


function gwl { 
    git worktree list
}

function gwlss {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Value
    )

    git worktree list | Select-String -Pattern $Value
}

function gwlsscd {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Value
    )

    $match = git worktree list `
                | %{ $_.Trim() -split '\s+'  | Select-Object -First 1 } `
                | Select-String -Pattern $Value `
                | Select-Object -First 1
                
    if ($match) {
        $path = ($match -split '\s+')[0]
        Set-Location $path
    }
    else {
        Write-Host "Nie znaleziono worktree pasującego do '$Value'" -ForegroundColor Yellow
    }
}

# Aliases for proper Select-String alias to start training the muscle memory
Set-Alias gwlsls gwlss
Set-Alias gwlslscd gwlsscd

function tgit {
    <#
    .SYNOPSIS
    Uruchamia TortoiseGitProc.exe z przekazanymi argumentami.

    .DESCRIPTION
    Funkcja jest cienkim wrapperem na TortoiseGitProc.exe /command.
    Wszystkie argumenty podane po `tgit` są przekazywane dalej bez zmian,
    więc możesz używać jej do dowolnych akcji obsługiwanych przez TortoiseGit,
    na przykład `log`, `commit`, `push` albo `pull`.

    .PARAMETER Args
    Lista argumentów przekazywana bezpośrednio do TortoiseGitProc.exe.

    .EXAMPLE
    tgit log
    Otwiera okno logu TortoiseGit dla bieżącego repozytorium.

    .EXAMPLE
    tgit commit
    Otwiera okno tworzenia commita w TortoiseGit.

    .EXAMPLE
    tgit push
    Uruchamia operację push z TortoiseGit.
    #>
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Args
    )

    TortoiseGitProc /command @Args
}

# ===== Machine-specific / private shortcuts =====
# Private and work-specific shortcuts (e.g. repo aliases) live in the loader at the
# $PROFILE location, which dot-sources this profile and is not part of this repo.
