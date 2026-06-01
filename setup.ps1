<#
.SYNOPSIS
    Skrypt instalacyjny dla ZTR.PowerShellProfile.
    Sprawdza wymagane narzędzia i instaluje brakujące za pomocą winget po potwierdzeniu.
#>

$dependencies = @(
    @{ Name = "Git"; Check = "git"; WingetId = "Git.Git" },
    @{ Name = "GitHub CLI"; Check = "gh"; WingetId = "GitHub.cli" },
    @{ Name = "oh-my-posh"; Check = "oh-my-posh"; WingetId = "JanDeDobbeleer.OhMyPosh" },
    @{ Name = "just"; Check = "just"; WingetId = "casey.just" },
    @{ Name = "PwshSpectreConsole"; Check = "Write-SpectreHost"; Module = "PwshSpectreConsole" }
)

Write-Host "Rozpoczynam sprawdzanie zależności..." -ForegroundColor Cyan

foreach ($dep in $dependencies) {
    Write-Host "Sprawdzam $($dep.Name)... " -NoNewline
    
    $isInstalled = $false
    if ($dep.Module) {
        $isInstalled = $null -ne (Get-Module -ListAvailable $dep.Module)
    } else {
        $isInstalled = $null -ne (Get-Command $dep.Check -ErrorAction SilentlyContinue)
    }

    if ($isInstalled) {
        Write-Host "Zainstalowano." -ForegroundColor Green
    }
    else {
        Write-Host "Brak." -ForegroundColor Yellow
        $confirmation = Read-Host "Czy chcesz zainstalować $($dep.Name)? (y/n)"
        if ($confirmation -eq 'y') {
            $exitCode = 0
            if ($dep.WingetId) {
                Write-Host "Instaluję $($dep.Name) (Winget ID: $($dep.WingetId))..." -ForegroundColor Cyan
                $process = Start-Process winget -ArgumentList "install --id $($dep.WingetId) --silent --accept-package-agreements --accept-source-agreements" -Wait -PassThru -NoNewWindow
                $exitCode = $process.ExitCode
            }
            elseif ($dep.Module) {
                Write-Host "Instaluję moduł PowerShell $($dep.Name)..." -ForegroundColor Cyan
                Install-Module -Name $dep.Module -Scope CurrentUser -Force -Confirm:$false
                $exitCode = if ($?) { 0 } else { 1 }
            }
            
            if ($exitCode -eq 0) {
                Write-Host "Pomyślnie zainstalowano $($dep.Name)." -ForegroundColor Green
            }
            else {
                Write-Warning "Nie udało się zainstalować $($dep.Name). Kod wyjścia/status: $exitCode."
            }
        }
        else {
            Write-Host "Pominięto instalację $($dep.Name)." -ForegroundColor Gray
        }
    }
}

Write-Host "`nZależności sprawdzone." -ForegroundColor Cyan

# Konfiguracja środowiska agenta dla Invoke-Prompt
Write-Host "`n[Konfiguracja domyślnego asystenta AI]" -ForegroundColor Cyan

Import-Module PwshSpectreConsole

Write-SpectreHost "Moduł MD.PrPromptingTools (komenda Invoke-Prompt) wspiera obecnie dwa silniki:"
Write-SpectreHost "1) [cyan]droid[/]  - używa 'droid exec' jako głównego runnera."
Write-SpectreHost "2) [cyan]gemini[/] - używa natywnego 'gemini' CLI (eksperymentalne/lekkie wywołania)."
Write-SpectreHost "Brak konfiguracji domyślnie użyje [cyan]droid[/]."

$choices = @("droid", "gemini", "Pomiń ustawianie")
$runnerChoice = Read-SpectreSelection -Message "Wybierz domyślnego runnera dla swojej maszyny:" -Choices $choices

if ($runnerChoice -eq 'Pomiń ustawianie') {
    Write-SpectreHost "[grey]Pominięto ustawianie domyślnego runnera. Możesz to zrobić później ustawiając zmienną środowiskową ZTR_DEFAULT_RUNNER.[/]"
}
elseif ($runnerChoice -eq 'droid') {
    [Environment]::SetEnvironmentVariable('ZTR_DEFAULT_RUNNER', 'droid', 'User')
    $env:ZTR_DEFAULT_RUNNER = 'droid'
    Write-SpectreHost "[green]Ustawiono 'droid' jako domyślnego runnera w ZTR_DEFAULT_RUNNER.[/]"
}
elseif ($runnerChoice -eq 'gemini') {
    [Environment]::SetEnvironmentVariable('ZTR_DEFAULT_RUNNER', 'gemini', 'User')
    $env:ZTR_DEFAULT_RUNNER = 'gemini'
    Write-SpectreHost "[green]Ustawiono 'gemini' jako domyślnego runnera w ZTR_DEFAULT_RUNNER.[/]"
}

# Konfiguracja wymagania numeru ADO
Write-Host "`n[Konfiguracja wymagania numeru ADO]" -ForegroundColor Cyan

Write-SpectreHost "[bold]true (wymagane)[/]  - Galaz: [cyan]task/<ado>/<name>[/], tytul PR: [cyan][[AB#<ado>]] <name>[/]."
Write-SpectreHost "[bold]false (opcjonalne)[/] - Galaz: [cyan]devWorktree/<name>[/], tytul PR: [cyan]<name>[/]."
Write-SpectreHost ""
Write-SpectreHost "Brak konfiguracji → ADO domyslnie [cyan]wymagane[/] + jednorazowy HINT przy pierwszym wywolaniu."

$adoChoices = @("true (wymagane)", "false (opcjonalne)", "Pomiń ustawianie")
$adoChoice = Read-SpectreSelection -Message "Czy numer ADO ma być wymagany?" -Choices $adoChoices

if ($adoChoice -eq 'Pomiń ustawianie') {
    Write-SpectreHost "[grey]Pominięto. Możesz to ustawić później przez `$env:ZTR_ADO_REQUIRED = 'true'/'false'.[/]"
}
elseif ($adoChoice -eq 'true (wymagane)') {
    [Environment]::SetEnvironmentVariable('ZTR_ADO_REQUIRED', 'true', 'User')
    $env:ZTR_ADO_REQUIRED = 'true'
    Write-SpectreHost "[green]Ustawiono ADO jako wymagane (ZTR_ADO_REQUIRED=true).[/]"
}
elseif ($adoChoice -eq 'false (opcjonalne)') {
    [Environment]::SetEnvironmentVariable('ZTR_ADO_REQUIRED', 'false', 'User')
    $env:ZTR_ADO_REQUIRED = 'false'
    Write-SpectreHost "[green]Ustawiono ADO jako opcjonalne (ZTR_ADO_REQUIRED=false).[/]"
}

Write-Host "`nPamiętaj, aby zrestartować terminal po instalacji nowych narzędzi, aby zmiany w PATH weszły w życie." -ForegroundColor Yellow

