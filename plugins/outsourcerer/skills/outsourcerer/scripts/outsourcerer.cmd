@echo off
rem outsourcerer.cmd — Windows launcher, NO WSL REQUIRED.
rem Runs outsourcerer.sh under Git Bash (ships with Git for Windows, which you almost
rem certainly already have). WSL is NOT needed and never was: only the optional tmux
rem "session" mode is unavailable on Windows; run/edit/yolo/bg/fanout all work.
setlocal EnableDelayedExpansion
set "SCRIPT_DIR=%~dp0"

rem -- locate Git Bash: common install paths first, then derive from git.exe on PATH --
set "BASH="
if exist "%ProgramFiles%\Git\bin\bash.exe" set "BASH=%ProgramFiles%\Git\bin\bash.exe"
if not defined BASH if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" set "BASH=%ProgramFiles(x86)%\Git\bin\bash.exe"
if not defined BASH if exist "%LocalAppData%\Programs\Git\bin\bash.exe" set "BASH=%LocalAppData%\Programs\Git\bin\bash.exe"
if not defined BASH (
  for /f "delims=" %%G in ('where git 2^>nul') do (
    if not defined BASH (
      for %%P in ("%%~dpG..") do if exist "%%~fP\bin\bash.exe" set "BASH=%%~fP\bin\bash.exe"
    )
  )
)
if not defined BASH (
  echo ERROR: Git Bash not found. Install Git for Windows ^(no WSL needed^):
  echo   winget install Git.Git
  echo then re-run this command from a new terminal.
  exit /b 1
)

"%BASH%" "%SCRIPT_DIR%outsourcerer.sh" %*
exit /b %ERRORLEVEL%
