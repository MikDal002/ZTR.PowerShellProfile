class PromptConfig {
    [string]$OutpuDirectory
    hidden [string]$Prompt

    PromptConfig([string]$prompt, [string]$OutpuDirectory) {
        $this.Prompt = $prompt
        $this.OutpuDirectory = $OutpuDirectory
    }
}

Import-Module PwshSpectreConsole

function Get-PromptingModuleRoot {
    $module = $MyInvocation.MyCommand.Module
    if ($null -eq $module -or [string]::IsNullOrWhiteSpace($module.ModuleBase)) {
        throw "Nie udalo sie ustalic katalogu bazowego modulu MD.PrPromptingTools."
    }

    return $module.ModuleBase
}

function Get-PromptTemplatePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TemplateName
    )

    $moduleRoot = Get-PromptingModuleRoot
    $templatePath = Join-Path -Path $moduleRoot -ChildPath (Join-Path -Path 'Templates' -ChildPath "$TemplateName.md")

    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
        throw "Nie znaleziono pliku template promptu: $templatePath"
    }

    return $templatePath
}

function Get-PromptYouHateThisImplementation {
    <#
    .SYNOPSIS
        Buduje prompt do review w stylu „nienawidzę tej implementacji".
    .DESCRIPTION
        Ładuje template you-hate-this-implementation-md.md,
        dynamicznie rozwiązuje placeholdery {{HEAD}}
        i {{current_branch}} na podstawie bieżącego repozytorium
        git, a następnie wstawia wynikowy zakres do promptu.
        Wynikowy PromptConfig trafia do Invoke-Prompt.
        Pliki review lądują w katalogu .review/.
    .PARAMETER Scope
        Domyślnie "Do a `git diff {{HEAD}}...{{current_branch}}`".
        Zakres review do wstawienia do promptu (np. "Do a git diff" lub "Look at staged file(s)").
        Inny interesujacy przykład to "Do a `git diff --cached`" aby sprwadzić tylko i wyłącznie zmiany staged. 

        Wartości jak {{HEAD}} i {{current_branch}} w Scope są zastępowane odpowiednimi wartościami z repozytorium git.
    .OUTPUTS
        PromptConfig
    .EXAMPLE
        Get-PromptYouHateThisImplementation | Invoke-Prompt -Model Sonnet
    .EXAMPLE
        Get-PromptYouHateThisImplementation `
            -Scope "Do a ``git diff --cached``" |
            Invoke-Prompt -Model Sonnet
    #>
    [CmdletBinding()]
    param(
        [string]$Scope =  "Do a ``git diff {{HEAD}}...{{current_branch}}``"
    )

    $resolvedScope = $Scope.Trim()
    if ($resolvedScope.Contains('{{HEAD}}') -or $resolvedScope.Contains('{{current_branch}}')) {
        
        $head = "origin/HEAD"
        
        $currentBranch = (& git rev-parse --abbrev-ref HEAD 2>&1).Trim()
        
        $resolvedScope = $resolvedScope.Replace('{{HEAD}}', $head)
        $resolvedScope = $resolvedScope.Replace('{{current_branch}}', $currentBranch)
    }

    Write-SpectreHost "[cyan bold]Resolved review scope[/]"
    $resolvedScope -split "`n" | Where-Object { $_ } | ForEach-Object {
        Write-SpectreHost "> [white]$_[/]"
    }
    Write-SpectreHost ""

    $templatePath = Get-PromptTemplatePath -TemplateName 'you-hate-this-implementation-md'
    $template = Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8

    $prompt = $template.Replace('{{scope}}', $resolvedScope)

    return [PromptConfig]::new($prompt, '.review')
}

function Get-PromptImprovePendingReview {
    <#
    .SYNOPSIS
        Buduje prompt do ulepszenia moich oczekujących komentarzy review na PR.
    .DESCRIPTION
        Pobiera numer PR, repo i użytkownika przez gh CLI, wstawia je do
        template improve-my-pending-review-comments.md i zwraca gotowy
        PromptConfig. Wynikowe pliki .md lądują w .pr-review/.
    .PARAMETER WorkingDirectory
        Katalog roboczy zawierający repo git. Domyślnie bieżący katalog.
    .OUTPUTS
        PromptConfig
    .EXAMPLE
        Get-PromptImprovePendingReview | Invoke-Prompt -Model Sonnet
    .EXAMPLE
        Get-PromptImprovePendingReview -WorkingDirectory C:\repos\myapp | Invoke-Prompt -Model GPT -Polish
    #>
    [CmdletBinding()]
    param(
        [string]$WorkingDirectory = (Get-Location).Path
    )

    if ($null -eq (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "Brak komendy 'gh' (GitHub CLI)."
    }

    if (-not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
        throw "WorkingDirectory nie istnieje: $WorkingDirectory"
    }

    Push-Location -LiteralPath $WorkingDirectory
    try {
        $prRaw = & gh pr view --json number,headRepository,headRepositoryOwner 2>&1
        if ($LASTEXITCODE -ne 0) { throw "gh pr view nie powiodlo sie: $($prRaw | Out-String)" }
        $prInfo = ($prRaw | Out-String) | ConvertFrom-Json

        $currentUser = (& gh api user --jq '.login' 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { throw "gh api user nie powiodlo sie: $currentUser" }
    }
    finally {
        Pop-Location
    }

    $template = Get-Content -LiteralPath (Get-PromptTemplatePath -TemplateName 'improve-my-pending-review-comments') -Raw -Encoding UTF8
    $template = $template.Replace('{{prNumber}}',    [string]$prInfo.number)
    $template = $template.Replace('{{repoOwner}}',   [string]$prInfo.headRepositoryOwner.login)
    $template = $template.Replace('{{repoName}}',    [string]$prInfo.headRepository.name)
    $template = $template.Replace('{{currentUser}}', $currentUser)

    return [PromptConfig]::new($template, '.pr-review')
}

function Select-ModelInteractive {
    $models = @('Gemini', 'Sonnet', 'GPT')
    return Read-SpectreSelection -Message "Wybierz model" -Choices $models
}

function Resolve-ModelId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Gemini', 'Sonnet', 'GPT')]
        [string]$Model
    )

    switch ($Model) {
        'Gemini' { return 'gemini-3.1-pro-preview' }
        'Sonnet' { return 'claude-sonnet-4-6' }
        'GPT' { return 'gpt-5.4' }
        default { throw "Nieobslugiwany model alias: $Model" }
    }
}

function Invoke-DroidExecModelRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Model,

        [Parameter(Mandatory = $true)]
        [string]$PromptFilePath,

        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory,

        [ValidateSet('readonly', 'low', 'medium', 'high')]
        [string]$Auto = 'readonly'
    )

    $droidArgs = @(
        'exec'
        '--output-format', 'json'
        '--model', $Model
        '--cwd', $WorkingDirectory
        '-f', $PromptFilePath
    )

    if ($Auto -ne 'readonly') {
        $droidArgs += @('--auto', $Auto)
    }

    Write-SpectreHost "[cyan]Start droid exec: model=$Model, mode=$Auto[/]"

    $startedAt = Get-Date
    $rawOutput = $null
    $exitCode = 0

    $statusResult = Invoke-SpectreCommandWithStatus `
        -Title "Droid review ($Model)" `
        -Spinner "Dots" `
        -ScriptBlock ({
            $output = & droid @droidArgs 2>&1
            return [pscustomobject]@{
                Output = $output
                ExitCode = $LASTEXITCODE
            }
        }.GetNewClosure())

    $rawOutput = $statusResult.Output
    $exitCode = [int]$statusResult.ExitCode

    if ($exitCode -ne 0) {
        $errMsg = ($rawOutput | ForEach-Object { "$_" }) -join "`n"
        throw "droid exec zakonczyl sie bledem dla modelu '$Model': $errMsg"
    }

    $jsonText = ($rawOutput | ForEach-Object { "$_" }) -join "`n"
    $result = $null

    try {
        $result = $jsonText | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Nie udalo sie sparsowac JSON z droid exec dla modelu '$Model'. Raw output:`n$jsonText"
    }

    if ($null -eq $result.session_id -or [string]::IsNullOrWhiteSpace([string]$result.session_id)) {
        throw "Brak session_id w odpowiedzi droid exec dla modelu '$Model'."
    }

    $elapsedSec = [Math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1)
    Write-SpectreHost "[green]Koniec droid exec: model=$Model, session=$($result.session_id), czas=${elapsedSec}s[/]"

    return [pscustomobject]@{
        Model = $Model
        SessionId = [string]$result.session_id
        Output = [string]$result.result
        DurationMs = if ($result.duration_ms) { [int]$result.duration_ms } else { $null }
    }
}

function Invoke-GeminiRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PromptFilePath,

        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory
    )

    Write-SpectreHost "[cyan]Start gemini CLI: cwd=$WorkingDirectory[/]"

    $startedAt = Get-Date

    $promptText = Get-Content -LiteralPath $PromptFilePath -Raw
    
    $statusResult = Invoke-SpectreCommandWithStatus `
        -Title "Gemini CLI run" `
        -Spinner "Dots" `
        -ScriptBlock ({
            $output = & gemini --skip-trust --approval-mode auto_edit --model auto --output-format json --prompt $promptText 2>&1
            return [pscustomobject]@{
                Output = $output
                ExitCode = $LASTEXITCODE
            }
        }.GetNewClosure())

    $output = $statusResult.Output | ConvertFrom-Json -ErrorAction Stop
    $exitCode = $statusResult.ExitCode

    if ($exitCode -ne 0) {
        $errMsg = ($output | ForEach-Object { "$_" }) -join "`n"
        throw "gemini CLI zakonczyl sie bledem: $errMsg"
    }

    $elapsedSec = [Math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1)
    Write-SpectreHost "[green]Koniec gemini CLI: czas=${elapsedSec}s[/]"

    return [pscustomobject]@{
        SessionId = if ($output.session_id) { [string]$output.session_id } else { $null }
        Output = $output.response
        DurationMs = [int]((Get-Date) - $startedAt).TotalMilliseconds
    }
}

function Invoke-Prompt {
    <#
    .SYNOPSIS
        Uruchamia droid exec z podanym promptem i modelem AI.
    .DESCRIPTION
        Przyjmuje PromptConfig z Get-Prompt*, zapisuje prompt do pliku tymczasowego,
        wywołuje wybrany runner (droid exec lub gemini CLI, zależnie od parametru
        Runner / zmiennej $env:ZTR_DEFAULT_RUNNER) i zwraca wynik sesji.
        Jeśli PromptConfig.OutpuDirectory jest niepuste, katalog jest
        tworzony przed uruchomieniem Runnera — agent zapisze tam pliki .md.
    .PARAMETER PromptConfig
        Obiekt PromptConfig zwrócony przez Get-Prompt*.
    .PARAMETER Polish
        Dołącza instrukcję zapisu review po polsku.
    .PARAMETER Model
        Alias modelu AI: Gemini, Sonnet lub GPT.
    .PARAMETER WorkingDirectory
        Katalog roboczy przekazywany do droid exec (--cwd). Domyślnie bieżący.
    .PARAMETER Auto
        Poziom autonomii droid exec: readonly, low, medium (domyślny), high.
        Parametr ignorowany gdy Runner='gemini'.
    .OUTPUTS
        PSCustomObject z polami: Runner, Model, ModelId, Mode, SessionId, Output, DurationMs.
    .EXAMPLE
        Get-PromptYouHateThisImplementation -Branch main | Invoke-Prompt -Model Sonnet
    .EXAMPLE
        Get-PromptImprovePendingReview | Invoke-Prompt -Model Gemini -Polish -Auto high
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [PromptConfig]$PromptConfig,

        [switch]$Polish,

        [ValidateSet('Gemini', 'Sonnet', 'GPT')]
        [string]$Model = '',

        [string]$WorkingDirectory = (Get-Location).Path,

        [ValidateSet('readonly', 'low', 'medium', 'high')]
        [string]$Auto = 'medium',

        [switch]$ContinueInAgentCLI,

        [switch]$SkipCode,

        [string]$Runner = $(if ($env:ZTR_DEFAULT_RUNNER) { $env:ZTR_DEFAULT_RUNNER } else { 'droid' })
    )

    if ([string]::IsNullOrWhiteSpace($env:ZTR_DEFAULT_RUNNER) -and -not $script:ZtrDefaultRunnerHintShown) {
        Write-SpectreHost "[yellow]HINT: Obecnie Invoke-Prompt uzywa domyslnego runnera 'droid'. Mozesz przelaczyc sie na np. 'gemini' ustawiajac zmienna srodowiskowa `$env:ZTR_DEFAULT_RUNNER = 'gemini' w swoim profilu lub odpalajac setup.ps1.[/]"
        $script:ZtrDefaultRunnerHintShown = $true
    }

    if ([string]::IsNullOrWhiteSpace($Model)) {
        $Model = Select-ModelInteractive
    }

    $promptText = $PromptConfig.Prompt
    if ([string]::IsNullOrWhiteSpace($promptText)) {
        throw "Parametr PromptConfig.Prompt nie moze byc pusty."
    }

    if ($Polish) {
        $promptText = ($promptText.TrimEnd() + "`n`nSwoje review do plikow zapisz po polsku")
    }

    if ($Runner -eq 'droid' -and $null -eq (Get-Command droid -ErrorAction SilentlyContinue)) {
        throw "Brak komendy 'droid'."
    }
    if ($Runner -eq 'gemini' -and $null -eq (Get-Command gemini -ErrorAction SilentlyContinue)) {
        throw "Brak komendy 'gemini'."
    }

    if (-not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
        throw "WorkingDirectory nie istnieje: $WorkingDirectory"
    }

    $modelId = Resolve-ModelId -Model $Model

    if (-not [string]::IsNullOrWhiteSpace($PromptConfig.OutpuDirectory)) {
        $reviewDirPath = Join-Path -Path $WorkingDirectory -ChildPath $PromptConfig.OutpuDirectory
        if (-not (Test-Path -LiteralPath $reviewDirPath -PathType Container)) {
            New-Item -Path $reviewDirPath -ItemType Directory -Force
            Write-SpectreHost "[cyan]Utworzono katalog review: $(Esc $reviewDirPath)[/]"
        }
    }

    $outputDirectory = if ([string]::IsNullOrWhiteSpace($PromptConfig.OutpuDirectory)) {
        '(none)'
    }
    else {
        $PromptConfig.OutpuDirectory
    }

    $runSummary = @(
        [pscustomobject]@{ Parameter = 'Runner'; Value = $Runner }
        [pscustomobject]@{ Parameter = 'Model'; Value = "$Model ($modelId)" }
        [pscustomobject]@{ Parameter = 'Mode'; Value = $Auto }
        [pscustomobject]@{ Parameter = 'Working directory'; Value = $WorkingDirectory }
        [pscustomobject]@{ Parameter = 'Output directory'; Value = $outputDirectory }
    )

    Write-SpectreRule -Title "[cyan]Preparing local review[/]" -Alignment "Left" -Color "Cyan1"
    $runSummary | Format-SpectreTable -Color "Cyan1" -HeaderColor "Cyan1"

    $tempPromptFile = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ("local-review.{0}.md" -f ([Guid]::NewGuid().ToString('N')))
    Set-Content -LiteralPath $tempPromptFile -Value $promptText -Encoding UTF8

    try {
        switch ($Runner.ToLower()) {
            'droid' {
                $run = Invoke-DroidExecModelRun -Model $modelId -PromptFilePath $tempPromptFile -WorkingDirectory $WorkingDirectory -Auto $Auto
            }
            'gemini' {
                $run = Invoke-GeminiRun -PromptFilePath $tempPromptFile -WorkingDirectory $WorkingDirectory
            }
            default {
                throw "Nieobslugiwany runner: '$Runner'. Obecnie wspierane to 'droid' i 'gemini'."
            }
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempPromptFile -PathType Leaf) {
            Remove-Item -LiteralPath $tempPromptFile -Force -ErrorAction SilentlyContinue
        }
    }

    $result = [pscustomobject]@{
        Runner = $Runner
        Model = $Model
        ModelId = $modelId
        Mode = $Auto
        SessionId = $run.SessionId
        Output = $run.Output
        DurationMs = $run.DurationMs
    }

    Write-Host $run | ConvertTo-Json -Depth 10

    if (-not $SkipCode -and -not [string]::IsNullOrWhiteSpace($PromptConfig.ReviewDirectory)) {
        $reviewDirPath = Join-Path -Path $WorkingDirectory -ChildPath $PromptConfig.ReviewDirectory
        Get-ChildItem -LiteralPath $reviewDirPath -Filter '*.md' -File -ErrorAction SilentlyContinue |
            ForEach-Object { & code $_.FullName }
    }

    if ($ContinueInAgentCLI -and $Runner -eq 'droid') {
        & droid --resume $run.SessionId
    } elseif ($ContinueInAgentCLI -and $Runner -eq 'gemini') {
        & gemini --resume $run.SessionId
    }

    return $result
}

Export-ModuleMember -Function Get-PromptYouHateThisImplementation, Get-PromptImprovePendingReview, Invoke-Prompt
