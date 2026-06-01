# ZTR.PowerShellProfile

Ten projekt zawiera konfigurację PowerShell, moduły i helpery ułatwiające codzienną pracę z Git, GitHub PR oraz automatyzację workflow.

## Jak zainstalować (Setup)

Aby używać tej konfiguracji jako dodatku do swojego lokalnego profilu, zaleca się poniższe kroki:

### 1. Zainstaluj wymagane narzędzia
Uruchom interaktywny skrypt `setup.ps1`, który sprawdzi i zapyta o instalację brakujących zależności (Git, gh, oh-my-posh, just via winget; PwshSpectreConsole via Install-Module) oraz skonfiguruje zmienną `ZTR_DEFAULT_RUNNER`:
```powershell
./setup.ps1
```

### 2. Sklonuj repozytorium i podepnij loader
1. Sklonuj to repozytorium w dogodne miejsce (np. `C:\source\repos\ZTR.PowerShellProfile`).
2. Otwórz swój profil PowerShell do edycji:
   ```powershell
   code $PROFILE
   ```
3. Dodaj poniższą linię na początku (lub końcu) swojego pliku profilu, wskazując na ścieżkę do pliku `Microsoft.PowerShell_profile.ps1` w tym repozytorium:
   ```powershell
   # Ładowanie głównej konfiguracji z repozytorium
   . "C:\source\repos\ZTR.PowerShellProfile\Microsoft.PowerShell_profile.ps1"
   ```
4. Zrestartuj terminal lub przeładuj profil:
   ```powershell
   . $PROFILE
   ```

## Wymagania (Prerequisites)

Profil korzysta z następujących narzędzi zewnętrznych. Skrypt `setup.ps1` pomoże Ci je zainstalować:

- [Git](https://git-scm.com/)
- [GitHub CLI (gh)](https://cli.github.com/)
- [oh-my-posh](https://ohmyposh.dev/) - dla ładnego promptu.
- [PSReadLine](https://github.com/PowerShell/PSReadLine) - dla predykcji i historii (zazwyczaj wbudowany w PWSH).
- [PwshSpectreConsole](https://pwshspectreconsole.com/) - wymagany przez moduły.
- `droid` lub `gemini` CLI - wymagany przez `Invoke-Prompt` (co najmniej jeden).
- [just](https://github.com/casey/just) - opcjonalnie.

## Co zawiera ten profil?

- **Bootstrap**: Ładuje moduły `MD.PrWorktreeTools` i `MD.PrPromptingTools` ze znanych ścieżek w `Modules/`.
- **Integracja oh-my-posh**: Wykrywa motyw `mytheme.omp.json` w `$HOME`, `$PSScriptRoot` lub `$ExtraThemeCandidates` (lista dokładana przez loader przed dot-source). Fallback: `powerlevel10k_rainbow`.
- **Predykcja PSReadLine**: Ustawia styl `ListView` dla podpowiedzi historii (tylko sesje interaktywne).
- **Moduły**:
  - `MD.PrWorktreeTools`: Narzędzia do pracy z Git Worktrees — tworzenie, checkout i zarządzanie worktrees powiązanymi z PRami.
  - `MD.PrPromptingTools`: Helpery do promptowania AI (szablony w `Templates/`). Runner (`droid`/`gemini`) sterowany przez zmienną `ZTR_DEFAULT_RUNNER`.
- **Helpery Worktree**:
  - `gwl`: Lista worktrees.
  - `gwlss <pattern>`: Szukanie w liście worktrees.
  - `gwlsscd <pattern>`: Szybkie przejście (cd) do worktree pasującego do wzorca.

## Konfiguracja specyficzna dla maszyny

Jeśli chcesz dodać własne aliasy, ścieżki lub `$ExtraThemeCandidates`, które nie powinny być częścią repozytorium, dodaj je w swoim pliku `$PROFILE` przed lub po linii dot-source'ującej ten projekt.
