@echo off
setlocal EnableExtensions EnableDelayedExpansion

:: ==============================================================================
:: assistit.nvim - One-Click Windows CMD Setup & Local Model Installer
:: Double-click in Explorer or run `setup.bat` in Command Prompt (cmd.exe).
:: Lets you choose 1 of 10 curated local coding models (or offline mode),
:: installs prerequisites (Git, Neovim, Ollama), pulls the model, and sets up
:: assistit.nvim cleanly without overwriting your existing init.lua.
:: ==============================================================================

set "REPO_URL=https://github.com/Arvex-GH/assistit.nvim.git"
set "MODEL_CHOICE="
set "ASSUME_YES=0"
set "SKIP_PULL=0"
set "NVIM_CONFIG_DIR=%LOCALAPPDATA%\nvim"
set "NVIM_DATA_DIR=%LOCALAPPDATA%\nvim-data"

:parse_args
if "%~1"=="" goto args_done
if /I "%~1"=="-m" (
  set "MODEL_CHOICE=%~2"
  shift
  shift
  goto parse_args
)
if /I "%~1"=="--model" (
  set "MODEL_CHOICE=%~2"
  shift
  shift
  goto parse_args
)
if /I "%~1"=="-y" (
  set "ASSUME_YES=1"
  shift
  goto parse_args
)
if /I "%~1"=="--yes" (
  set "ASSUME_YES=1"
  shift
  goto parse_args
)
if /I "%~1"=="--skip-pull" (
  set "SKIP_PULL=1"
  shift
  goto parse_args
)
if /I "%~1"=="-h" goto show_help
if /I "%~1"=="--help" goto show_help
if /I "%~1"=="/?" goto show_help
echo [ERROR] Unknown option: %~1
goto show_help

:show_help
echo.
echo Usage: setup.bat [options]
echo.
echo Options:
echo   -m, --model ^<0-10^|tag^>  Choose model 1-10, 0 for offline mode, or custom Ollama tag
echo   -y, --yes               Run non-interactively with defaults
echo       --skip-pull         Configure Neovim plugin without pulling model via Ollama
echo   -h, --help              Show this help message
echo.
exit /b 0

:args_done
echo.
echo ======================================================================
echo   assistit.nvim - One-Click Windows CMD Setup ^& Model Installer
echo ======================================================================
echo.

if not "%MODEL_CHOICE%"=="" goto resolve_choice

echo Choose one of 10 local coding models to install via Ollama (100%% local):
echo.
echo   [1]  qwen2.5-coder:0.5b    [~400 MB ^| ~1 GB RAM]  Ultra-light CPU champion (4-8 GB laptops)
echo   [2]  deepseek-coder:1.3b   [~780 MB ^| ~2 GB RAM]  Fast multi-language FIM on CPU laptops
echo   [3]  yi-coder:1.5b         [~870 MB ^| ~2 GB RAM]  Compact 128K-context all-rounder
echo   [4]  qwen2.5-coder:1.5b    [~990 MB ^| ~2 GB RAM]  Everyday laptop sweet spot (8 GB+ RAM)
echo   [5]  codegemma:2b          [~1.6 GB ^| ~3 GB RAM]  Google fast FIM completion specialist
echo   [6]  starcoder2:3b         [~1.7 GB ^| ~4 GB RAM]  BigCode 600+ languages FIM model
echo   [7]  qwen2.5-coder:3b      [~1.9 GB ^| ~4 GB RAM]  Strong mid-size coder (8-16 GB RAM)
echo   [8]  deepseek-coder:6.7b   [~3.8 GB ^| ~6 GB RAM]  Desktop / GPU high-accuracy coder
echo   [9]  codellama:7b          [~3.8 GB ^| ~6 GB RAM]  Meta CodeLlama 7B FIM classic
echo   [10] qwen2.5-coder:7b      [~4.7 GB ^| ~8 GB RAM]  Workstation / GPU flagship coder
echo   ----------------------------------------------------------------------
echo   [0]  Offline Mode (none)   [   0 MB ^|   0 MB RAM]  Deterministic + LSP only (no AI download)
echo.

if "%ASSUME_YES%"=="1" (
  set "MODEL_CHOICE=1"
  goto resolve_choice
)

set /p "MODEL_CHOICE=Enter choice [0-10 or custom Ollama tag] (default: 4): "
if "%MODEL_CHOICE%"=="" set "MODEL_CHOICE=4"

:resolve_choice
set "SELECTED_PROVIDER=ollama"
set "SELECTED_MODEL=%MODEL_CHOICE%"
set "SELECTED_PROFILE=balanced"

if /I "%MODEL_CHOICE%"=="0" goto pick_0
if /I "%MODEL_CHOICE%"=="none" goto pick_0
if /I "%MODEL_CHOICE%"=="offline" goto pick_0
if "%MODEL_CHOICE%"=="1" goto pick_1
if "%MODEL_CHOICE%"=="2" goto pick_2
if "%MODEL_CHOICE%"=="3" goto pick_3
if "%MODEL_CHOICE%"=="4" goto pick_4
if "%MODEL_CHOICE%"=="5" goto pick_5
if "%MODEL_CHOICE%"=="6" goto pick_6
if "%MODEL_CHOICE%"=="7" goto pick_7
if "%MODEL_CHOICE%"=="8" goto pick_8
if "%MODEL_CHOICE%"=="9" goto pick_9
if "%MODEL_CHOICE%"=="10" goto pick_10
goto picked_done

:pick_0
set "SELECTED_PROVIDER=none"
set "SELECTED_MODEL=deterministic-only"
set "SELECTED_PROFILE=ultra_light"
goto picked_done

:pick_1
set "SELECTED_MODEL=qwen2.5-coder:0.5b"
set "SELECTED_PROFILE=ultra_light"
goto picked_done

:pick_2
set "SELECTED_MODEL=deepseek-coder:1.3b"
set "SELECTED_PROFILE=ultra_light"
goto picked_done

:pick_3
set "SELECTED_MODEL=yi-coder:1.5b"
set "SELECTED_PROFILE=balanced"
goto picked_done

:pick_4
set "SELECTED_MODEL=qwen2.5-coder:1.5b"
set "SELECTED_PROFILE=balanced"
goto picked_done

:pick_5
set "SELECTED_MODEL=codegemma:2b"
set "SELECTED_PROFILE=balanced"
goto picked_done

:pick_6
set "SELECTED_MODEL=starcoder2:3b"
set "SELECTED_PROFILE=balanced"
goto picked_done

:pick_7
set "SELECTED_MODEL=qwen2.5-coder:3b"
set "SELECTED_PROFILE=balanced"
goto picked_done

:pick_8
set "SELECTED_MODEL=deepseek-coder:6.7b"
set "SELECTED_PROFILE=performance"
goto picked_done

:pick_9
set "SELECTED_MODEL=codellama:7b"
set "SELECTED_PROFILE=performance"
goto picked_done

:pick_10
set "SELECTED_MODEL=qwen2.5-coder:7b"
set "SELECTED_PROFILE=performance"
goto picked_done

:picked_done
echo.
echo [assistit] Selected model: %SELECTED_MODEL% (provider: %SELECTED_PROVIDER%, profile: %SELECTED_PROFILE%)

:: Ensure common Windows install paths are visible in current session PATH
if exist "%ProgramFiles%\Git\cmd" set "PATH=%PATH%;%ProgramFiles%\Git\cmd"
if exist "%ProgramFiles%\Neovim\bin" set "PATH=%PATH%;%ProgramFiles%\Neovim\bin"
if exist "%LOCALAPPDATA%\Programs\Ollama" set "PATH=%PATH%;%LOCALAPPDATA%\Programs\Ollama"

:: 1. Check curl.exe
where curl.exe >nul 2>&1
if errorlevel 1 (
  echo [WARN] curl.exe was not found in PATH. Windows 10/11 includes curl.exe in System32.
)

:: 2. Check Git (needed only if cloning from GitHub)
where git >nul 2>&1
if not errorlevel 1 goto git_ok
if exist "%~dp0lua\assistit\init.lua" goto git_ok
echo [WARN] Git not found. Installing Git via winget...
where winget >nul 2>&1
if errorlevel 1 (
  echo [ERROR] winget not found. Please install Git from https://git-scm.com/download/win and re-run setup.bat.
  goto fail_exit
)
winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements
if exist "%ProgramFiles%\Git\cmd" set "PATH=%PATH%;%ProgramFiles%\Git\cmd"
:git_ok
echo [  OK  ] Git check complete.

:: 3. Check Neovim >= 0.10
where nvim >nul 2>&1
if not errorlevel 1 goto nvim_ok
echo [WARN] Neovim not found. Installing Neovim via winget...
where winget >nul 2>&1
if errorlevel 1 (
  echo [ERROR] winget not found. Please install Neovim ^>= 0.10 from https://neovim.io and re-run setup.bat.
  goto fail_exit
)
winget install --id Neovim.Neovim -e --source winget --accept-package-agreements --accept-source-agreements
if exist "%ProgramFiles%\Neovim\bin" set "PATH=%PATH%;%ProgramFiles%\Neovim\bin"
:nvim_ok
echo [  OK  ] Neovim is ready.

:: 4. Install Ollama & pull chosen model (unless Offline Mode or --skip-pull)
if /I "%SELECTED_PROVIDER%"=="none" goto skip_ollama
if "%SKIP_PULL%"=="1" goto skip_ollama

where ollama >nul 2>&1
if not errorlevel 1 goto ollama_installed

echo [assistit] Ollama not found. Installing Ollama...
where winget >nul 2>&1
if errorlevel 1 goto ollama_direct_dl
winget install --id Ollama.Ollama -e --source winget --accept-package-agreements --accept-source-agreements
if exist "%LOCALAPPDATA%\Programs\Ollama" set "PATH=%PATH%;%LOCALAPPDATA%\Programs\Ollama"
where ollama >nul 2>&1
if not errorlevel 1 goto ollama_installed

:ollama_direct_dl
echo [assistit] Downloading official Ollama installer...
curl.exe -fL "https://ollama.com/download/OllamaSetup.exe" -o "%TEMP%\OllamaSetup.exe"
if errorlevel 1 (
  echo [ERROR] Could not download OllamaSetup.exe. Install Ollama from https://ollama.com/download and re-run setup.bat.
  goto fail_exit
)
"%TEMP%\OllamaSetup.exe" /SILENT
if exist "%LOCALAPPDATA%\Programs\Ollama" set "PATH=%PATH%;%LOCALAPPDATA%\Programs\Ollama"

:ollama_installed
where ollama >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Ollama CLI still not found on PATH. Open a new cmd window after installing Ollama and re-run setup.bat.
  goto fail_exit
)
echo [  OK  ] Ollama CLI is ready.

:: Start local Ollama server if not already listening on 127.0.0.1:11434
curl.exe -fsS --max-time 2 "http://127.0.0.1:11434/api/tags" >nul 2>&1
if not errorlevel 1 goto ollama_running

echo [assistit] Starting local Ollama server on 127.0.0.1:11434...
start "" /B ollama serve >"%TEMP%\assistit-ollama.log" 2>&1
set /a WAIT_COUNT=0
:wait_ollama_loop
curl.exe -fsS --max-time 2 "http://127.0.0.1:11434/api/tags" >nul 2>&1
if not errorlevel 1 goto ollama_running
set /a WAIT_COUNT+=1
if !WAIT_COUNT! GEQ 20 goto ollama_running
timeout /t 1 /nobreak >nul
goto wait_ollama_loop

:ollama_running
echo [assistit] Pulling local model "%SELECTED_MODEL%" (downloads once)...
ollama pull "%SELECTED_MODEL%"
if errorlevel 1 (
  echo [ERROR] Failed to pull model "%SELECTED_MODEL%". Check your internet connection or model name.
  goto fail_exit
)
echo [  OK  ] Model "%SELECTED_MODEL%" is installed locally.
goto install_plugin

:skip_ollama
echo [  OK  ] Skipping Ollama model download.

:: 5. Install assistit.nvim plugin files
:install_plugin
set "PACK_DIR=%NVIM_DATA_DIR%\site\pack\assistit\start\assistit.nvim"
if not exist "%NVIM_DATA_DIR%\site\pack\assistit\start" mkdir "%NVIM_DATA_DIR%\site\pack\assistit\start"

if exist "%~dp0lua\assistit\init.lua" goto copy_local_repo

if exist "%PACK_DIR%\.git" (
  echo [assistit] Updating existing assistit.nvim checkout...
  git -C "%PACK_DIR%" pull --ff-only
  goto plugin_ready
)
if exist "%PACK_DIR%" rmdir /s /q "%PACK_DIR%"
echo [assistit] Cloning assistit.nvim into "%PACK_DIR%"...
git clone --depth 1 "%REPO_URL%" "%PACK_DIR%"
if errorlevel 1 (
  echo [ERROR] git clone failed.
  goto fail_exit
)
goto plugin_ready

:copy_local_repo
echo [assistit] Installing assistit.nvim from "%~dp0"...
if not exist "%PACK_DIR%" mkdir "%PACK_DIR%"
robocopy "%~dp0lua" "%PACK_DIR%\lua" /E /NFL /NDL /NJH /NJS /NC /NS >nul
if !ERRORLEVEL! GEQ 8 goto copy_failed
robocopy "%~dp0plugin" "%PACK_DIR%\plugin" /E /NFL /NDL /NJH /NJS /NC /NS >nul
if !ERRORLEVEL! GEQ 8 goto copy_failed
robocopy "%~dp0doc" "%PACK_DIR%\doc" /E /NFL /NDL /NJH /NJS /NC /NS >nul
if !ERRORLEVEL! GEQ 8 goto copy_failed
if exist "%~dp0README.md" copy /Y "%~dp0README.md" "%PACK_DIR%\README.md" >nul
if exist "%~dp0LICENSE" copy /Y "%~dp0LICENSE" "%PACK_DIR%\LICENSE" >nul
goto plugin_ready

:copy_failed
echo [ERROR] Failed to copy plugin files into "%PACK_DIR%".
goto fail_exit

:plugin_ready
echo [  OK  ] Plugin installed at "%PACK_DIR%".

:: 6. Write non-destructive Neovim configuration
set "USE_LAZY=0"
if exist "%NVIM_CONFIG_DIR%\lua\plugins" (
  if exist "%NVIM_CONFIG_DIR%\init.lua" (
    findstr /I /C:"lazy" "%NVIM_CONFIG_DIR%\init.lua" >nul 2>&1
    if not errorlevel 1 set "USE_LAZY=1"
  )
)

if "%USE_LAZY%"=="1" goto write_lazy_cfg

set "CFG_FILE=%NVIM_CONFIG_DIR%\after\plugin\assistit_setup.lua"
if not exist "%NVIM_CONFIG_DIR%\after\plugin" mkdir "%NVIM_CONFIG_DIR%\after\plugin"
(
  echo -- Generated by assistit.nvim setup.bat ^(safe to edit or re-run setup.bat anytime^)
  echo local ok, assistit = pcall^(require, "assistit"^)
  echo if ok and not assistit._initialized then
  echo   assistit.setup^({
  echo     profile = "%SELECTED_PROFILE%",
  echo     provider = "%SELECTED_PROVIDER%",
  echo     model = "%SELECTED_MODEL%",
  echo   }^)
  echo end
) > "%CFG_FILE%"
echo [  OK  ] Wrote Neovim config: "%CFG_FILE%" ^(existing init.lua untouched^).
goto build_helptags

:write_lazy_cfg
set "CFG_FILE=%NVIM_CONFIG_DIR%\lua\plugins\assistit.lua"
if not exist "%NVIM_CONFIG_DIR%\lua\plugins" mkdir "%NVIM_CONFIG_DIR%\lua\plugins"
(
  echo -- Generated by assistit.nvim setup.bat ^(safe to edit or re-run setup.bat anytime^)
  echo return {
  echo   "Arvex-GH/assistit.nvim",
  echo   event = { "InsertEnter", "CmdlineEnter" },
  echo   opts = {
  echo     profile = "%SELECTED_PROFILE%",
  echo     provider = "%SELECTED_PROVIDER%",
  echo     model = "%SELECTED_MODEL%",
  echo   },
  echo }
) > "%CFG_FILE%"
if exist "%NVIM_CONFIG_DIR%\after\plugin\assistit_setup.lua" del /f /q "%NVIM_CONFIG_DIR%\after\plugin\assistit_setup.lua"
echo [  OK  ] Wrote lazy.nvim plugin spec: "%CFG_FILE%".

:build_helptags
where nvim >nul 2>&1
if not errorlevel 1 (
  set "PACK_DOC_SLASH=%PACK_DIR:\=/%/doc"
  nvim --headless -u NONE "+helptags !PACK_DOC_SLASH!" +qa >nul 2>&1
  echo [  OK  ] Generated :help assistit documentation tags.
)

echo.
echo ======================================================================
echo   assistit.nvim is installed and ready!
echo ======================================================================
echo.
echo   Model:     %SELECTED_MODEL%
echo   Provider:  %SELECTED_PROVIDER%
echo   Profile:   %SELECTED_PROFILE%
echo   Config:    %CFG_FILE%
echo.
echo Open Neovim ("nvim") and use the short commands (lowercase or :Ai*):
echo   :ais              Open live status, privacy, ^& latency dashboard
echo   :aip ^<u^|b^|p^>      Switch profile (ultra_light / balanced / performance)
echo   :aim ^<1-10^|tag^>   Switch active local model on the fly
echo   :aif              Fix diagnostic / selection in a safe diff preview
echo   :aie              Explain error or code at cursor
echo   :aig ^<prompt^>     Generate code from natural language
echo   :air / :aio       Refactor or optimize selected code
echo   :aid / :ait       Generate docstrings or unit tests
echo   :aic              Clean duplicate imports ^& trailing spaces
echo   :checkhealth assistit
echo.

if "%ASSUME_YES%"=="0" pause
exit /b 0

:fail_exit
echo.
if "%ASSUME_YES%"=="0" pause
exit /b 1
