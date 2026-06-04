$script:ZtrAdoRequiredHintShown = $false

function Get-MainRepoPath {
    Write-Debug "Get-MainRepoPath: Invoked in directory: $(Get-Location)"

    $gitCommonDir = (& git rev-parse --path-format=absolute --git-common-dir 2>$null | Select-Object -First 1)
    if (-not [string]::IsNullOrWhiteSpace($gitCommonDir)) {
        $gitCommonDir = $gitCommonDir.Trim()
        if (Test-Path -LiteralPath $gitCommonDir) {
            return Split-Path -Path $gitCommonDir -Parent
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
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($nwo)) {
        return $nwo.Trim()
    }
    else {
        throw "Nie podano repozytorium (owner/name)."
    }
}

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

    function Esc {
        param([AllowEmptyString()][AllowNull()][string]$Text)
        if ([string]::IsNullOrEmpty($Text)) { return '' }
        return Get-SpectreEscapedText -Text $Text
    }

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

        try {
            $json = gh pr view $PrNumber -R $Repo --json number, state, isDraft, url, mergedAt 2>$null
            if ($LASTEXITCODE -eq 0 -and $json) {
                return $json | ConvertFrom-Json
            }
        }
        catch {
            # brak danych — wyżej obsłużymy null
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
                git rev-parse --is-inside-work-tree *> $null
                if ($LASTEXITCODE -eq 0) {
                    gh pr view --web *> $null
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
                gh pr view $PrNumber -R $Repo --web *> $null
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

        if ($NotOpen) {
            if (-not $prInfo) {
                Write-SpectreRule -Title "[cyan]$(Esc $dir.Name)[/]" -Alignment "Left"
                Write-StatusWarn "pominięto (filtr -NotOpen): brak statusu PR z gh"
                continue
            }

            if ($prInfo.state -eq "OPEN") {
                $label = if ($prInfo.isDraft) { "draft/open" } else { "open" }
                Write-SpectreRule -Title "[cyan]$(Esc $dir.Name)[/]" -Alignment "Left"
                Write-StatusDim "pominięto (filtr -NotOpen): $label"
                continue
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

function Is-True($value) {
    # Normalize the value to string for comparison
    if ($null -eq $value) { return $false }

    # Trim and lowercase for consistent matching
    $strValue = "$value".Trim().ToLower()

    # Acceptable "true" values
    $trueValues = @("true", "yes", "1")

    return $trueValues -contains $strValue
}


function Resolve-AdoNumber {
    <#
    .SYNOPSIS
        Zwraca oczyszczony numer ADO lub $null.
    .DESCRIPTION
        Jeśli Value jest niepuste — czyści go (tylko cyfry) i zwraca.
        Jeśli Value jest puste:
          - ZTR_ADO_REQUIRED=false → zwraca $null
          - ZTR_ADO_REQUIRED=true (lub brak zmiennej) → pyta interaktywnie
            jeśli sesja jest interaktywna, w przeciwnym razie rzuca wyjątek.
        Wyświetla HINT raz na sesję gdy ZTR_ADO_REQUIRED nie jest ustawiona.
    #>
    param(
        [string]$Value,
        [string]$Context = ''
    )
    
    function Sanitize-AdoNumber($value) {
        $c = ($value -replace '[^0-9]', '')
        return $c
    }

    if ($null -eq $env:ZTR_ADO_REQUIRED -and -not $script:ZtrAdoRequiredHintShown) {
        Write-Host "HINT: Numer ADO jest domyslnie wymagany. Mozesz to zmienic ustawiajac `$env:ZTR_ADO_REQUIRED = 'false' lub uruchamiajac setup.ps1." -ForegroundColor Yellow
        $script:ZtrAdoRequiredHintShown = $true
    }

    $adoRequired = Is-True $env:ZTR_ADO_REQUIRED
    
    $Value = Sanitize-AdoNumber $Value

    if ([string]::IsNullOrWhiteSpace($Value) -and $adoRequired) {

        $isInteractive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
        if (-not $isInteractive) {
            throw "Numer ADO jest wymagany (ZTR_ADO_REQUIRED=true), ale sesja nie jest interaktywna."
        }

        $prompt = "Podaj numer ADO" + $(if ($Context) { " (kontekst: $Context)" } else { "" })
        $raw = Read-Host $prompt
        if ([string]::IsNullOrWhiteSpace($raw)) { throw "Numer ADO nie moze byc pusty." }

        $Value = Sanitize-AdoNumber $raw
        if ([string]::IsNullOrWhiteSpace($Value)) { throw "Numer ADO musi zawierac cyfry." }
    }

    return $Value
}

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

Export-ModuleMember -Function Open-PrDirs, New-EmptyPrWorktree, New-WorktreeForPr, ConvertTo-PrWorktree, New-DevWorktree, Rename-WorktreesDirectories
