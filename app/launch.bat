@echo off
REM Launch the Spatial De-identifier app (Windows). Double-click this file.
setlocal
cd /d "%~dp0"

set "PY="
where py >nul 2>nul && set "PY=py -3"
if not defined PY ( where python >nul 2>nul && set "PY=python" )

if defined PY (
  %PY% -c "import sys; sys.exit(0 if sys.version_info>=(3,9) else 1)" >nul 2>nul || set "PY="
)

if not defined PY (
  echo.
  echo  Python 3.9+ was not found on this computer.
  echo  Install it from https://www.python.org/downloads/  ^(tick "Add python.exe to PATH"^)
  echo  or run:  winget install Python.Python.3.12
  echo  Then double-click this launcher again.
  echo.
  start "" https://www.python.org/downloads/
  pause
  exit /b 1
)

echo Using: %PY%
%PY% "server.py" %*
pause
