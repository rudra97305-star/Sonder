@echo off
setlocal
cd /d "%~dp0"
set "PIP_DISABLE_PIP_VERSION_CHECK=1"
set "SONDER_PYTHON=.venv310\Scripts\python.exe"
if not exist "%SONDER_PYTHON%" (
  py -3.10 -m venv .venv310
  if errorlevel 1 (
    echo Could not create the Python 3.10 environment. Confirm Python 3.10 is installed.
    pause
    exit /b 1
  )
)
"%SONDER_PYTHON%" -m pip --version >nul 2>&1
if errorlevel 1 "%SONDER_PYTHON%" -m ensurepip --upgrade
if errorlevel 1 (
  echo Python could not bootstrap pip. Reinstall Python 3.10 from python.org with pip and venv enabled.
  pause
  exit /b 1
)
set "UVR_BASE_PATH=%CD%\vendor\uvr-headless-master"
if not exist "%UVR_BASE_PATH%\gui_data\constants.py" (
  echo Downloading the UVR source tree...
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; New-Item -ItemType Directory -Force -Path 'vendor' | Out-Null; Invoke-WebRequest -Uri 'https://github.com/hiroaki222/uvr-headless/archive/refs/heads/master.zip' -OutFile 'vendor\uvr-headless.zip'; Expand-Archive -LiteralPath 'vendor\uvr-headless.zip' -DestinationPath 'vendor' -Force; Remove-Item 'vendor\uvr-headless.zip'"
  if errorlevel 1 (
    echo Could not download UVR. Check your internet connection and rerun.
    pause
    exit /b 1
  )
)
"%SONDER_PYTHON%" -c "import fastapi, uvicorn, pyrubberband; from importlib.util import find_spec; raise SystemExit(not all(find_spec(module) for module in ('pkg_resources', 'scipy')))" >nul 2>&1
if errorlevel 1 (
  "%SONDER_PYTHON%" -m pip install -r requirements.txt
  if errorlevel 1 (
    echo Dependency installation failed. Scroll up for the pip error details.
    pause
    exit /b 1
  )
)
"%SONDER_PYTHON%" -c "from importlib.metadata import version; version('uvr-headless')" >nul 2>&1
if errorlevel 1 (
  "%SONDER_PYTHON%" -m pip install "%UVR_BASE_PATH%"
  if errorlevel 1 (
    echo UVR installation failed. Scroll up for the pip error details.
    pause
    exit /b 1
  )
)
"%SONDER_PYTHON%" -m uvicorn app:app --host 127.0.0.1 --port 8765
