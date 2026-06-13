
<#
Open-PrDirs:
- domyślnie dla każdego katalogu pr-XXX otwiera odpowiadający mu PR na GitHubie,
- -Repo: repozytorium w formacie 'owner/name'. Domyślnie puste — wtedy repo jest
  ustalane przez `gh repo view --json nameWithOwner` z bieżącego katalogu, a gdy się
  nie uda (brak `gh` lub brak remote), użytkownik zostaje o nie zapytany. Podanie
  jawnej wartości 'owner/name' nadpisuje tę logikę,
- -NotOpen: filtr — z dalszego przetwarzania wyklucza PR-y o stanie OPEN
  (żadna akcja, w tym otwarcie strony, nie zostanie na nich uruchomiona),
- -Remove: akcja uruchamiana per pozostały element PO otwarciu strony PR-a
  (pyta o potwierdzenie usunięcia worktree),
- -SkipBrowser: pomija otwieranie strony PR-a w przeglądarce; akcja Remove jest nadal wykonywana,
- -Force: używane razem z -Remove; dodaje --force do `git worktree remove`,
- gdy nie uda się otworzyć strony PR-a lub usunąć worktree, pyta gdzie otworzyć
  katalog worktree: Eksplorator, VS Code (`code`), albo nic.
UI: bannery, prompty i podsumowanie korzystają z PwshSpectreConsole.
#>
function Open-PrDirs {
    [CmdletBinding()]
    param(
        [string]$Path,
        [string]$Repo,
        [switch]$NotOpen,
        [switch]$SkipBrowser,
        [switch]$Remove,
        [switch]$Force
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Get-DefaultWorktreesRoot
    }

    if (-not $env:IgnoreSpectreEncoding) {
        $env:IgnoreSpectreEncoding = $true
    }
    Import-Module PwshSpectreConsole -ErrorAction Stop

    $dirs = Get-ChildItem -Path $Path -Directory |
    Where-Object { $_.Name -match '^pr-(\d+)$' } |
    Sort-Object {
        $m = [regex]::Match($_.Name, '^pr-(\d+)$')
        if ($m.Success) { [int]$m.Groups[1].Value } else { [int]::MaxValue }
    }

    if (-not $dirs) {
        Write-SpectreHost "[yellow]Nie znalazłem katalogów pasujących do wzorca pr-XXX w: $(Esc $Path)[/]"
        return
    }

    $ghExists = $null -ne (Get-Command gh -ErrorAction SilentlyContinue)
    $gitExists = $null -ne (Get-Command git -ErrorAction SilentlyContinue)
    $codeExists = $null -ne (Get-Command code -ErrorAction SilentlyContinue)

    if ([string]::IsNullOrWhiteSpace($Repo)) {
        $Repo = Resolve-RepoNameWithOwner
    }

    if ($NotOpen -and -not $ghExists) {
        Write-SpectreHost "[red]Flaga -NotOpen wymaga zainstalowanego 'gh' (GitHub CLI).[/]"
        return
    }

    if ($Remove -and -not $gitExists) {
        Write-SpectreHost "[red]Flaga -Remove wymaga zainstalowanego 'git'.[/]"
        return
    }

    function Write-StatusOk { param([string]$Msg) Write-SpectreHost "   [green]$Msg[/]" }
    function Write-StatusWarn { param([string]$Msg) Write-SpectreHost "   [yellow]$Msg[/]" }
    function Write-StatusDim { param([string]$Msg) Write-SpectreHost "   [grey]$Msg[/]" }
    function Write-StatusErr { param([string]$Msg) Write-SpectreHost "   [red]$Msg[/]" }

    $bannerData = @(
        "[bold]Path[/]       : $(Esc $Path)"
        "[bold]Repo[/]       : $(Esc $Repo)"
        "[bold]Katalogów[/]  : $($dirs.Count)"
        "[bold]NotOpen[/]    : $NotOpen"
        "[bold]SkipBrowser[/]: $SkipBrowser"
        "[bold]Remove[/]     : $Remove"
        "[bold]Force[/]      : $Force"
    ) -join "`n"
    Format-SpectrePanel -Data $bannerData -Header "[blue]Open-PrDirs[/]" -Color "Blue"

    function Get-PrInfo {
        param([string]$PrNumber)
        
        Write-Debug "Getting PR info for #$PrNumber using gh CLI..."

        try {
            $json = gh pr view $PrNumber --repo $Repo --json number,state,isDraft,url,mergedAt

            if ($LASTEXITCODE -eq 0 -and $json) {
                return $json | ConvertFrom-Json
            } else {
                throw "gh pr view zwrócił błąd ($LASTEXITCODE) lub pusty wynik ($json)"
            }
        }
        catch {
            Write-StatusErr "nie udało się pobrać info o PR #$PrNumber $(Esc $_.Exception.Message)"
        }
        return $null
    }

    function Get-PrStatusLabel {
        param($PrInfo)

        if (-not $PrInfo) {
            return 'brak danych'
        }

        $state = if ($PrInfo.state) { $PrInfo.state.ToString().ToUpperInvariant() } else { '' }

        switch ($state) {
            'OPEN' {
                if ($PrInfo.isDraft) { return 'draft/open' }
                return 'open'
            }
            'MERGED' {
                return 'merged'
            }
            'CLOSED' {
                if ($PrInfo.PSObject.Properties.Name -contains 'mergedAt' -and $PrInfo.mergedAt) {
                    return 'merged'
                }
                return 'closed'
            }
            default {
                if ([string]::IsNullOrWhiteSpace($state)) {
                    return 'brak danych'
                }
                return $state.ToLowerInvariant()
            }
        }
    }

    function Invoke-DirOpenPrompt {
        param([string]$DirPath)

        $choices = @('Eksplorator', 'VS Code', 'Pomiń')
        $choice = Read-SpectreSelection `
            -Message "Otworzyć katalog '$(Esc $DirPath)'?" `
            -Choices $choices `
            -PageSize 3

        switch ($choice) {
            'Eksplorator' {
                try {
                    Start-Process explorer.exe -ArgumentList $DirPath -ErrorAction Stop
                    Write-StatusWarn "otwarto w Eksploratorze: $(Esc $DirPath)"
                }
                catch {
                    Write-StatusErr "nie udało się otworzyć Eksploratora: $(Esc $_.Exception.Message)"
                }
            }
            'VS Code' {
                if (-not $codeExists) {
                    Write-StatusErr "brak komendy 'code'"
                    return
                }
                try {
                    & code $DirPath 2>$null
                    Write-StatusWarn "otwarto w VS Code: $(Esc $DirPath)"
                }
                catch {
                    Write-StatusErr "nie udało się uruchomić 'code' dla: $(Esc $DirPath)"
                }
            }
            default {
                Write-StatusDim "pominięto otwarcie katalogu"
            }
        }
    }

    function Open-PrPage {
        param(
            [System.IO.DirectoryInfo]$Dir,
            [string]$PrNumber,
            $PrInfo
        )

        if ($SkipBrowser) {
            return $false
        }

        $url = if ($PrInfo -and $PrInfo.url) { $PrInfo.url } else { "https://github.com/$Repo/pull/$PrNumber" }
        $opened = $false

        if ($ghExists -and $gitExists) {
            Push-Location $Dir.FullName
            try {
                git rev-parse --is-inside-work-tree
                if ($LASTEXITCODE -eq 0) {
                    gh pr view --web
                    if ($LASTEXITCODE -eq 0) {
                        $opened = $true
                        Write-StatusOk "otwarto przez gh z kontekstu katalogu -> $(Esc $url)"
                    }
                }
            }
            catch {
                # fallback niżej
            }
            finally {
                Pop-Location
            }
        }

        if (-not $opened -and $ghExists) {
            try {
                gh pr view $PrNumber -R $Repo --web
                if ($LASTEXITCODE -eq 0) {
                    $opened = $true
                    Write-StatusOk "otwarto przez gh po numerze PR -> $(Esc $url)"
                }
            }
            catch {
                # fallback niżej
            }
        }

        if (-not $opened) {
            try {
                Start-Process $url -ErrorAction Stop
                $opened = $true
                Write-StatusWarn "fallback URL: $(Esc $url)"
            }
            catch {
                Write-StatusErr "nie udało się otworzyć URL: $(Esc $url)"
            }
        }

        if (-not $opened) {
            Invoke-DirOpenPrompt -DirPath $Dir.FullName
        }

        return $opened
    }

    function Remove-PrWorktree {
        param(
            [System.IO.DirectoryInfo]$Dir,
            [switch]$Force
        )

        $confirm = Read-SpectreConfirm `
            -Message "Usunąć worktree '$(Esc $Dir.Name)'?" `
            -DefaultAnswer "y" `
            -ConfirmSuccess "" `
            -ConfirmFailure ""

        if (-not $confirm) {
            Write-StatusDim "pominięto usuwanie"
            return 'pominięte'
        }

        $dirFullName = $Dir.FullName

        $gitCommonDir = (& git -C $dirFullName rev-parse --path-format=absolute --git-common-dir 2>$null | Select-Object -First 1)
        if ($gitCommonDir) { $gitCommonDir = $gitCommonDir.Trim() }

        if ([string]::IsNullOrWhiteSpace($gitCommonDir) -or -not (Test-Path -LiteralPath $gitCommonDir)) {
            Write-StatusErr "nie udało się ustalić głównego katalogu repozytorium"
            Invoke-DirOpenPrompt -DirPath $dirFullName
            return 'błąd'
        }

        $mainRepoRoot = Split-Path $gitCommonDir -Parent

        Push-Location -LiteralPath $mainRepoRoot
        try {
            $result = Invoke-SpectreCommandWithStatus `
                -Title "Usuwam worktree $($Dir.Name)" `
                -Spinner "Dots" `
                -ScriptBlock ({
                    try {
                        $repoRoot = (& git -C $dirFullName rev-parse --show-toplevel 2>$null | Select-Object -First 1).Trim()
                        if ([string]::IsNullOrWhiteSpace($repoRoot)) {
                            return @{ Ok = $false; Err = 'nie udało się ustalić katalogu repozytorium' }
                        }

                        $currentPath = (Get-Location).Path
                        $pwdBeforeRemove = $currentPath
                        $pwdChanged = $false
                        if ($currentPath -like "$dirFullName*") {
                            Set-Location -LiteralPath $mainRepoRoot
                            $pwdChanged = $true
                        }

                        $removeArgs = @('-C', $repoRoot, 'worktree', 'remove')
                        if ($Force) {
                            $removeArgs += '--force'
                        }
                        $removeArgs += $dirFullName

                        $removeOut = & git @removeArgs 2>&1
                        if ($LASTEXITCODE -ne 0) {
                            $msg = ($removeOut | ForEach-Object { "$_" }) -join "`n"
                            return @{
                                Ok              = $false
                                Err             = "git worktree remove zwrócił błąd: $msg"
                                PwdBeforeRemove = $pwdBeforeRemove
                                PwdChanged      = $pwdChanged
                            }
                        }

                        return @{
                            Ok              = $true
                            PwdBeforeRemove = $pwdBeforeRemove
                            PwdChanged      = $pwdChanged
                        }
                    }
                    catch {
                        return @{ Ok = $false; Err = $_.Exception.Message }
                    }
                }.GetNewClosure())
        }
        finally {
            Pop-Location -ErrorAction SilentlyContinue
        }
        
        Write-SpectreHost "[grey]PWD before remove: $(Esc $result.PwdBeforeRemove)[/]"
        
        Write-StatusDim "zmieniono PWD przed usuwaniem: $(Esc $mainRepoRoot)"
        
        if ($result -and $result.Ok) {
            Write-StatusOk "usunięto worktree: $(Esc $dirFullName)"
            return 'usunięte'
        }

        $errMsg = if ($result) { $result.Err } else { 'nieznany błąd' }
        Write-StatusErr "nie udało się usunąć: $(Esc $errMsg)"
        Invoke-DirOpenPrompt -DirPath $dirFullName
        return 'błąd'
    }

    # ---- Faza 1: filtrowanie ----
    Write-SpectreRule -Title "[blue]Faza 1: filtrowanie[/]" -Alignment "Left" -Color "Blue"

    $items = [System.Collections.Generic.List[object]]::new()

    foreach ($dir in $dirs) {
        $m = [regex]::Match($dir.Name, '^pr-(\d+)$')
        if (-not $m.Success) { continue }
        $prNumber = $m.Groups[1].Value

        $prInfo = $null

        if ($ghExists) {
            $prInfo = Get-PrInfo -PrNumber $prNumber
        }

        $status = Get-PrStatusLabel -PrInfo $prInfo

        if ($NotOpen) {
            if (-not $prInfo) {
                Write-SpectreRule -Title "[cyan]$(Esc $dir.Name)[/]" -Alignment "Left"
                Write-StatusWarn "pominięto (filtr -NotOpen): brak statusu PR z gh"
                continue
            }

            if ($status -like "*open*") {
                Write-SpectreRule -Title "[cyan]$(Esc $dir.Name)[/]" -Alignment "Left"
                Write-StatusDim "pominięto (filtr -NotOpen): $status"
                continue
            }
            
            if ($status -eq "closed" -or $status -eq "merged") {
                Write-SpectreRule -Title "[cyan]$(Esc $dir.Name)[/]" -Alignment "Left"
                Write-StatusOk "uwzględniono (filtr -NotOpen): $status"
            }
        }

        $items.Add([pscustomobject]@{
                Dir      = $dir
                PrNumber = $prNumber
                PrInfo   = $prInfo
            })
    }

    if ($items.Count -eq 0) {
        Write-SpectreHost "[yellow]Brak elementów do przetworzenia po filtrach.[/]"
        return
    }

    # ---- Faza 2: akcje per element ----
    Write-SpectreRule -Title "[blue]Faza 2: akcje[/]" -Alignment "Left" -Color "Blue"

    $summary = [System.Collections.Generic.List[object]]::new()

    foreach ($item in $items) {
        if ($null -eq $item -or $null -eq $item.Dir) { continue }

        Write-SpectreRule -Title "[cyan]$(Esc $item.Dir.Name)[/]" -Alignment "Left"

        $prStatus = Get-PrStatusLabel -PrInfo $item.PrInfo
        Write-StatusDim "Stan: $prStatus"

        $opened = Open-PrPage -Dir $item.Dir -PrNumber $item.PrNumber -PrInfo $item.PrInfo
        
        $removeStatus = '-'
        if ($Remove) {
            $removeStatus = Remove-PrWorktree -Dir $item.Dir -Force:$Force
        }

        $summary.Add([pscustomobject]@{
                Worktree = $item.Dir.Name
                PRStatus = $prStatus
                Otwarcie = if ($opened) { 'OK' } else { 'błąd' }
                Usuwanie = $removeStatus
            })
    }

    Write-SpectreRule -Title "[blue]Podsumowanie[/]" -Alignment "Left" -Color "Blue"
    $summary | Format-SpectreTable -Color "Blue" -HeaderColor "Blue"
}