<#
.SYNOPSIS
    Skrypt instalacyjny dla ZTR.PowerShellProfile.
    Sprawdza wymagane narzędzia i instaluje brakujące za pomocą winget po potwierdzeniu.
#>

$dependencies = @(
    @{ Name = "Git"; Check = "git"; WingetId = "Git.Git" },
    @{ Name = "GitHub CLI"; Check = "gh"; WingetId = "GitHub.cli" },
    @{ Name = "oh-my-posh"; Check = "oh-my-posh"; WingetId = "JanDeDobbeleer.OhMyPosh" },
    @{ Name = "just"; Check = "just"; WingetId = "casey.just" }
)

Write-Host "Rozpoczynam sprawdzanie zależności..." -ForegroundColor Cyan

foreach ($dep in $dependencies) {
    Write-Host "Sprawdzam $($dep.Name)... " -NoNewline
    if (Get-Command $dep.Check -ErrorAction SilentlyContinue) {
        Write-Host "Zainstalowano." -ForegroundColor Green
    }
    else {
        Write-Host "Brak." -ForegroundColor Yellow
        $confirmation = Read-Host "Czy chcesz zainstalować $($dep.Name)? (y/n)"
        if ($confirmation -eq 'y') {
            Write-Host "Instaluję $($dep.Name) (Winget ID: $($dep.WingetId))..." -ForegroundColor Cyan
            
            $process = Start-Process winget -ArgumentList "install --id $($dep.WingetId) --silent --accept-package-agreements --accept-source-agreements" -Wait -PassThru -NoNewWindow
            
            if ($process.ExitCode -eq 0) {
                Write-Host "Pomyślnie zainstalowano $($dep.Name)." -ForegroundColor Green
            }
            else {
                Write-Warning "Nie udało się zainstalować $($dep.Name). Kod wyjścia: $($process.ExitCode)."
            }
        }
        else {
            Write-Host "Pominięto instalację $($dep.Name)." -ForegroundColor Gray
        }
    }
}

Write-Host "`nZależności sprawdzone." -ForegroundColor Cyan
Write-Host "Pamiętaj, aby zrestartować terminal po instalacji nowych narzędzi, aby zmiany w PATH weszły w życie." -ForegroundColor Yellow
