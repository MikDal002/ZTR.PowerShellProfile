class PromptConfig {
    [string]$OutpuDirectory
    hidden [string]$Prompt

    PromptConfig([string]$prompt, [string]$OutpuDirectory) {
        $this.Prompt = $prompt
        $this.OutpuDirectory = $OutpuDirectory
    }
}

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
        Ładuje template you-hate-this-implementation-md.md i wstawia
        podaną gałąź bazową. Wynikowy PromptConfig trafia do
        Invoke-LocalReview. Pliki review lądują w katalogu .review/.
    .PARAMETER Branch
        Gałąź bazowa do porównania przez git diff (np. 'main').
    .OUTPUTS
        PromptConfig
    .EXAMPLE
        Get-PromptYouHateThisImplementation -Branch main | Invoke-Prompt -Model Sonnet
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Branch
    )

    if ([string]::IsNullOrWhiteSpace($Branch)) {
        throw "Parametr Branch nie moze byc pusty."
    }

    $templatePath = Get-PromptTemplatePath -TemplateName 'you-hate-this-implementation-md'
    $template = Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8

    return [PromptConfig]::new($template.Replace('{{baseBranch}}', $Branch.Trim()), '.review')
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
    Write-Host 'Wybierz model:' -ForegroundColor Yellow
    for ($i = 0; $i -lt $models.Count; $i++) {
        Write-Host "  [$($i + 1)] $($models[$i])"
    }
    do {
        $raw = Read-Host "Model [1-$($models.Count)]"
        $idx = $raw -as [int]
    } while ($null -eq $idx -or $idx -lt 1 -or $idx -gt $models.Count)
    return $models[$idx - 1]
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

    Write-Host "Start droid exec: model=$Model, mode=$Auto" -ForegroundColor Cyan

    $startedAt = Get-Date
    $rawOutput = $null
    $exitCode = 0

    $spectreRunner = Get-Command Invoke-SpectreCommandWithStatus -ErrorAction SilentlyContinue
    if ($null -ne $spectreRunner) {
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
    }
    else {
        $rawOutput = & droid @droidArgs 2>&1
        $exitCode = $LASTEXITCODE
    }

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
    Write-Host "Koniec droid exec: model=$Model, session=$($result.session_id), czas=${elapsedSec}s" -ForegroundColor Green

    return [pscustomobject]@{
        Model = $Model
        SessionId = [string]$result.session_id
        Output = [string]$result.result
        DurationMs = if ($result.duration_ms) { [int]$result.duration_ms } else { $null }
    }
}

function Invoke-Prompt {
    <#
    .SYNOPSIS
        Uruchamia droid exec z podanym promptem i modelem AI.
    .DESCRIPTION
        Przyjmuje PromptConfig z Get-Prompt*, zapisuje prompt do
        pliku tymczasowego, wywołuje droid exec i zwraca wynik sesji.
        Jeśli PromptConfig.OutpuDirectory jest niepuste, katalog jest
        tworzony przed uruchomieniem droids — agent zapisze tam pliki .md.
    .PARAMETER PromptConfig
        Obiekt PromptConfig zwrócony przez Get-Prompt*.
    .PARAMETER Polish
        Dołącza instrukcję zapisu review po polsku.
    .PARAMETER Model
        Alias modelu AI: Gemini, Sonnet lub GPT.
    .PARAMETER WorkingDirectory
        Katalog roboczy przekazywany do droid exec (--cwd). Domyślnie bieżący.
    .PARAMETER Auto
        Poziom autonomii droids: readonly, low, medium (domyślny), high.
    .OUTPUTS
        PSCustomObject z polami: Model, ModelId, Mode, SessionId, Output, DurationMs.
    .EXAMPLE
        Get-PromptYouHateThisImplementation -Branch main | Invoke-Prompt -Model Sonnet
    .EXAMPLE
        Get-PromptImprovePendingReview | Invoke-LocalReview -Model Gemini -Polish -Auto high
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

        [switch]$ContinueInDroidShell,

        [switch]$SkipCode
    )

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

    if ($null -eq (Get-Command droid -ErrorAction SilentlyContinue)) {
        throw "Brak komendy 'droid'."
    }

    if (-not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
        throw "WorkingDirectory nie istnieje: $WorkingDirectory"
    }

    $modelId = Resolve-ModelId -Model $Model

    if (-not [string]::IsNullOrWhiteSpace($PromptConfig.OutpuDirectory)) {
        $reviewDirPath = Join-Path -Path $WorkingDirectory -ChildPath $PromptConfig.OutpuDirectory
        if (-not (Test-Path -LiteralPath $reviewDirPath -PathType Container)) {
            New-Item -Path $reviewDirPath -ItemType Directory -Force | Out-Null
            Write-Host "Utworzono katalog review: $reviewDirPath" -ForegroundColor Cyan
        }
    }

    Write-Host "Przygotowuje lokalny review: model=$Model ($modelId), mode=$Auto, cwd=$WorkingDirectory" -ForegroundColor Cyan

    $tempPromptFile = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ("local-review.{0}.md" -f ([Guid]::NewGuid().ToString('N')))
    Set-Content -LiteralPath $tempPromptFile -Value $promptText -Encoding UTF8

    try {
        $run = Invoke-DroidExecModelRun -Model $modelId -PromptFilePath $tempPromptFile -WorkingDirectory $WorkingDirectory -Auto $Auto
    }
    finally {
        if (Test-Path -LiteralPath $tempPromptFile -PathType Leaf) {
            Remove-Item -LiteralPath $tempPromptFile -Force -ErrorAction SilentlyContinue
        }
    }

    $result = [pscustomobject]@{
        Model = $Model
        ModelId = $modelId
        Mode = $Auto
        SessionId = $run.SessionId
        Output = $run.Output
        DurationMs = $run.DurationMs
    }

    if (-not $SkipCode -and -not [string]::IsNullOrWhiteSpace($PromptConfig.ReviewDirectory)) {
        $reviewDirPath = Join-Path -Path $WorkingDirectory -ChildPath $PromptConfig.ReviewDirectory
        Get-ChildItem -LiteralPath $reviewDirPath -Filter '*.md' -File -ErrorAction SilentlyContinue |
            ForEach-Object { & code $_.FullName }
    }

    if ($ContinueInDroidShell) {
        & droid --resume $run.SessionId
    }

    return $result
}

Export-ModuleMember -Function Get-PromptYouHateThisImplementation, Get-PromptImprovePendingReview, Invoke-Prompt, Invoke-YouHateThisImplementationFlow
