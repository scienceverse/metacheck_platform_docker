# install.ps1: installs metacheck on your own computer (Windows).
#
# Start it in PowerShell with:
#   irm https://raw.githubusercontent.com/scienceverse/metacheck_platform_docker/main/install.ps1 | iex
#
# It asks what to install, each time with "no" as the answer when you only
# press Enter, so the default is the lightest installation: PDFs are converted
# by TU/e's GROBID server, and the power check uses no language model, or
# Mistral with your own API key. The answers can also be given in advance:
#   & ([scriptblock]::Create((irm <address of this file>))) -Grobid yes -Ollama no -MistralKey skip
# It writes compose.yaml, the settings (.env) and start and stop files to a
# folder (default: metacheck in your user folder), and starts metacheck.

param(
  [string]$Folder = (Join-Path $env:USERPROFILE "metacheck"),
  [ValidateSet("", "yes", "no")] [string]$InstallDocker = "",
  [ValidateSet("", "yes", "no")] [string]$Grobid = "",
  [ValidateSet("", "yes", "no")] [string]$Ollama = "",
  [string]$MistralKey = "",             # a key, or "skip"
  [ValidateSet("", "yes", "no")] [string]$ReplaceSettings = "",
  [switch]$NoStart,
  [string]$Image = "",                  # an image built yourself, instead of the published one
  [string]$Source = "https://raw.githubusercontent.com/scienceverse/metacheck_platform_docker/main"
)

# "Continue": Windows PowerShell 5.1 turns what docker and winget write to
# their error channel (progress such as "Container ... Creating") into errors,
# which "Stop" would end the installer with; real failures are checked below.
$ErrorActionPreference = "Continue"
# Windows PowerShell 5.1 does not use TLS 1.2 by itself, which GitHub needs.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$Model = "qwen3.5:4b"
$MistralKeysPage = "https://console.mistral.ai/api-keys"

function Say([string]$text = "", [string]$ForegroundColor = "") {
  if ($ForegroundColor -ne "") { Write-Host $text -ForegroundColor $ForegroundColor } else { Write-Host $text }
}
function Heading([string]$text) { Write-Host ""; Write-Host $text -ForegroundColor Cyan }

# A yes/no question; Enter means no. $given: the answer given as a parameter.
function Ask([string]$question, [string]$given) {
  if ($given -ne "") { Say "$question $given"; return ($given -eq "yes") }
  $answer = Read-Host "$question [y/N]"
  return ($answer -match '^(y|yes|j|ja)$')
}

function Have([string]$command) { return [bool](Get-Command $command -ErrorAction SilentlyContinue) }

function DockerRuns {
  if (-not (Have "docker")) { return $false }
  & docker info --format '{{.ServerVersion}}' 2>$null | Out-Null
  return ($LASTEXITCODE -eq 0)
}

Say ""
Say "metacheck on your own computer" -ForegroundColor Cyan
Say "This installs metacheck's website and paper report app on this computer, in Docker."
Say "The lightest installation needs little memory, but sends some things to external servers:"
Say "  - a PDF is sent to the GROBID server of Eindhoven University of Technology (TU/e) to be converted;"
Say "  - the power check uses no language model, or Mistral (EU) with your own API key."
Say "Each part you add below does more on this computer instead. Press Enter for 'no'."

$memGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)

# ---- Docker -----------------------------------------------------------------
Heading "1. Docker"
if (Have "docker") {
  Say "Docker is installed."
} else {
  Say "metacheck runs in Docker, which is not installed. Docker Desktop is free for personal use,"
  Say "education, non-commercial open source and small businesses; larger companies need a subscription."
  if (-not (Ask "Install Docker Desktop now (with winget; Windows asks for administrator rights)?" $InstallDocker)) {
    Say "metacheck cannot run without Docker. Install Docker Desktop from"
    Say "https://www.docker.com/products/docker-desktop/ and run this installer again."
    return
  }
  if (-not (Have "winget")) {
    Say "winget is not available. Install Docker Desktop from https://www.docker.com/products/docker-desktop/"
    Say "and run this installer again."
    return
  }
  winget install --id Docker.DockerDesktop --exact --accept-package-agreements --accept-source-agreements
  Say "Docker Desktop is installed. If Windows asks you to restart, do so, and run this installer again."
  $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
}
if (-not (DockerRuns)) {
  Say "Start Docker Desktop (from the Start menu) and accept its terms. Waiting for Docker to answer..."
  $desktop = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"
  if (Test-Path $desktop) { Start-Process $desktop }
  $waited = 0
  while (-not (DockerRuns) -and $waited -lt 600) { Start-Sleep -Seconds 5; $waited += 5 }
  if (-not (DockerRuns)) {
    Say "Docker does not answer after 10 minutes. Start Docker Desktop, and run this installer again."
    return
  }
}
Say "Docker runs."

# ---- GROBID -----------------------------------------------------------------
Heading "2. GROBID on this computer (converts PDFs)"
Say "Without it, a PDF is sent to TU/e's GROBID server (GDPR compliant) to be converted."
Say "With it, PDFs stay on this computer, but GROBID needs about 4 GB of memory more"
Say "(a computer with 16 GB of memory; this one has $memGB GB)."
$useGrobid = Ask "Install GROBID on this computer?" $Grobid
if ($useGrobid -and $memGB -lt 16) {
  Say "Note: with $memGB GB of memory, GROBID may be stopped while converting a long PDF." -ForegroundColor Yellow
}

# ---- Language model -----------------------------------------------------------
Heading "3. Language model for the power check"
Say "The power check can use a language model to check whether power analyses report all"
Say "the required information. Ollama runs a model on this computer, so the paragraphs stay"
Say "here; it needs about 3.5 GB of disk space and memory (on the graphics card, if there is one)."
$useOllama = Ask "Install Ollama with the model ${Model}?" $Ollama
$mistral = ""
if ($useOllama) {
  if (-not (Have "ollama")) {
    if (-not (Have "winget")) {
      Say "winget is not available. Install Ollama from https://ollama.com and run this installer again."
      return
    }
    winget install --id Ollama.Ollama --exact --accept-package-agreements --accept-source-agreements
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
  }
  # A context of 16384 tokens, as on metacheck's SURF server; Ollama reads it
  # when it starts, so the Ollama app is started again below.
  [Environment]::SetEnvironmentVariable("OLLAMA_CONTEXT_LENGTH", "16384", "User")
  $env:OLLAMA_CONTEXT_LENGTH = "16384"
  Get-Process -Name "ollama app", "ollama" -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Seconds 2
  $app = Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama app.exe"
  if (Test-Path $app) { Start-Process $app } else { Start-Process ollama -ArgumentList "serve" -WindowStyle Hidden }
  $waited = 0
  do { Start-Sleep -Seconds 2; $waited += 2
       try { Invoke-RestMethod http://localhost:11434/api/version -TimeoutSec 2 | Out-Null; $up = $true } catch { $up = $false }
  } while (-not $up -and $waited -lt 60)
  Say "Downloading the model $Model (about 3.3 GB)..."
  ollama pull $Model
} else {
  Say ""
  Say "Instead, the power check can use Mistral (EU) with your own API key: the paragraphs about"
  Say "statistical power are then sent to Mistral. Mistral's free plan needs no credit card;"
  Say "check Mistral's terms for whether it may use what you send to improve its models."
  Say "Get a key at $MistralKeysPage (log in, choose 'API Keys', 'Create new key')."
  while ($true) {
    if ($MistralKey -ne "") { $answer = $MistralKey; $MistralKey = "skip" }
    else { $answer = Read-Host "Paste your Mistral API key, or press Enter to skip" }
    if ($answer -eq "" -or $answer -eq "skip") {
      Say "No language model. To add a key later, see the end of this installer."
      break
    }
    $key = $answer.Trim()
    try {
      Invoke-RestMethod https://api.mistral.ai/v1/models -Headers @{ Authorization = "Bearer $key" } -TimeoutSec 20 | Out-Null
      Say "Mistral accepts the key."
      $mistral = $key
      break
    } catch {
      $status = $null
      if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
      if ($status -eq 401) { Say "Mistral does not accept this key; try again, or press Enter to skip." -ForegroundColor Yellow }
      else {
        Say "Mistral could not be reached to check the key ($($_.Exception.Message)); the key is saved unchecked." -ForegroundColor Yellow
        $mistral = $key
        break
      }
    }
  }
}

# ---- bibr ----------------------------------------------------------------------
if (Have "nvidia-smi") {
  Heading "4. bibr"
  Say "This computer has an NVIDIA graphics card. bibr, which converts PDFs and Word files better"
  Say "than GROBID, needs a large one; it is not yet part of this installer."
}

# ---- Files ---------------------------------------------------------------------
Heading "Installing in $Folder"
New-Item -ItemType Directory -Force $Folder -ErrorAction Stop | Out-Null
try {
  Invoke-WebRequest -UseBasicParsing "$Source/compose.yaml" -OutFile (Join-Path $Folder "compose.yaml") -ErrorAction Stop
} catch {
  Say "compose.yaml could not be downloaded from $Source ($($_.Exception.Message))." -ForegroundColor Red
  return
}
$envFile = Join-Path $Folder ".env"
$writeSettings = $true
if (Test-Path $envFile) {
  $writeSettings = Ask "$envFile already holds settings. Replace them with these answers?" $ReplaceSettings
}
if ($writeSettings) {
  $lines = @(
    "# Settings of metacheck on this computer (written by install.ps1). Change a line, then",
    "# stop and start metacheck again. All settings: https://github.com/scienceverse/metacheck_platform_docker/blob/main/example.env",
    "METACHECK_SETTINGS_FILE=$envFile"
  )
  if ($Image -ne "") { $lines += "METACHECK_IMAGE=$Image" }
  if ($useGrobid) {
    $lines += "", "# GROBID on this computer", "COMPOSE_PROFILES=grobid",
              "GROBID_LOCAL_URL=http://grobid:8070", "METACHECK_GROBID_URL=http://grobid:8070"
  }
  if ($useOllama) {
    $lines += "", "# Ollama on this computer", "OLLAMA_BASE_URL=http://host.docker.internal:11434",
              "METACHECK_LLM_MODEL=$Model"
  } elseif ($mistral -ne "") {
    $lines += "", "# Mistral (EU) with your own API key", "MISTRAL_API_KEY=$mistral"
  } else {
    $lines += "", "# Mistral (EU) with your own API key ($MistralKeysPage): remove the # and add the key",
              "# MISTRAL_API_KEY="
  }
  # without a byte order mark, which Docker Compose would read as part of the first line
  [IO.File]::WriteAllLines($envFile, [string[]]$lines)
}

$start = @(
  "@echo off",
  "rem Starts metacheck and opens it in the browser (written by install.ps1).",
  "cd /d ""%~dp0""",
  "rem first stop every part, also one that the settings no longer choose (such as GROBID)",
  "docker compose --profile ""*"" down >nul 2>&1",
  "docker compose up -d || (echo Is Docker Desktop running? & pause & exit /b 1)",
  "echo Waiting for metacheck...",
  "powershell -NoProfile -Command ""`$i=0; do { Start-Sleep 2; `$i++; try { Invoke-RestMethod http://localhost:3838/api/health -TimeoutSec 2 | Out-Null; `$ok=`$true } catch { `$ok=`$false } } until (`$ok -or `$i -gt 90)""",
  "docker compose logs metacheck | findstr /c:""PDFs:"" /c:""Language model:"" /c:""WARNING"" /c:""try again""",
  "if not defined METACHECK_NO_BROWSER start http://localhost:3838",
  "echo metacheck runs at http://localhost:3838 - stop it with stop-metacheck.cmd",
  "timeout /t 10"
)
[IO.File]::WriteAllLines((Join-Path $Folder "start-metacheck.cmd"), [string[]]$start)
$stop = @(
  "@echo off",
  "rem Stops metacheck, every part of it (written by install.ps1). Reports that were not saved are gone.",
  "cd /d ""%~dp0""",
  "docker compose --profile ""*"" down",
  "timeout /t 5"
)
[IO.File]::WriteAllLines((Join-Path $Folder "stop-metacheck.cmd"), [string[]]$stop)

# ---- Start ---------------------------------------------------------------------
Heading "Downloading metacheck (the first time this takes a while)"
Push-Location $Folder
try {
  if ($Image -eq "") { docker compose pull }
  if ($NoStart) { Say "Not started (-NoStart)." }
  else { & (Join-Path $Folder "start-metacheck.cmd") }
} finally { Pop-Location }

Heading "Done"
Say "Start metacheck: $Folder\start-metacheck.cmd   Stop it: $Folder\stop-metacheck.cmd"
Say "Website: http://localhost:3838    Paper report app: http://localhost:3838/metacheck/"
if (-not $useOllama -and $mistral -eq "") {
  Say ""
  Say "To use Mistral later: get a key at $MistralKeysPage, open $envFile in a text"
  Say "editor, change the line '# MISTRAL_API_KEY=' into 'MISTRAL_API_KEY=' followed by your key,"
  Say "and stop and start metacheck again."
}
