# outsourcerer.ps1 — PowerShell launcher, NO WSL REQUIRED.
# Runs outsourcerer.sh under Git Bash (ships with Git for Windows). WSL is NOT needed:
# only the optional tmux "session" mode is unavailable on Windows; run/edit/yolo/bg/fanout
# all work. Usage:  ./outsourcerer.ps1 doctor   |   ./outsourcerer.ps1 run "map this repo"
$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$sh = Join-Path $scriptDir 'outsourcerer.sh'

# Locate Git Bash: common install paths first, then derive from git.exe on PATH.
$candidates = @(
  "$env:ProgramFiles\Git\bin\bash.exe",
  "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
  "$env:LocalAppData\Programs\Git\bin\bash.exe"
)
$bash = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $bash) {
  $git = Get-Command git -ErrorAction SilentlyContinue
  if ($git) {
    $probe = Join-Path (Split-Path -Parent (Split-Path -Parent $git.Source)) 'bin\bash.exe'
    if (Test-Path $probe) { $bash = $probe }
  }
}
if (-not $bash) {
  Write-Error @"
Git Bash not found. Install Git for Windows (no WSL needed):
  winget install Git.Git
then re-run this command from a new terminal.
"@
  exit 1
}

& $bash $sh @args
exit $LASTEXITCODE
