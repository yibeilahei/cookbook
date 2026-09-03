# Installs the latest Cookbook release into %LOCALAPPDATA%\Programs\Cookbook
# and opens it. Invoke-WebRequest files get Mark of the Web; this script
# Unblock-Files them so SmartScreen does not treat the app as an unrecognized
# browser download. Usage (paste in PowerShell or cmd):
#
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/yibeilahei/cookbook/main/install.ps1 | iex"

$ErrorActionPreference = "Stop"

$Repo = "yibeilahei/cookbook"
$AppName = "Cookbook"
$DestDir = Join-Path $env:LOCALAPPDATA "Programs\$AppName"

function ohai([string]$Message) {
  Write-Host "==> $Message" -ForegroundColor Cyan
}
function abort([string]$Message) {
  Write-Host "Error: $Message" -ForegroundColor Red
  throw $Message
}

if ($env:OS -ne "Windows_NT") {
  abort "This installer is for Windows. On macOS, paste: /bin/bash -c `"`$(curl -fsSL https://raw.githubusercontent.com/$Repo/main/install.sh)`""
}

try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch { }

$Headers = @{
  Accept = "application/vnd.github+json"
  "User-Agent" = "cookbook-install"
}

ohai "Finding the latest Cookbook release…"
try {
  $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers $Headers
} catch {
  abort "could not reach GitHub"
}

if ($release.message -eq "Not Found") {
  abort "no GitHub release yet. Push a v*.*.* tag, or run from source (see README)."
}

$zipAsset = $release.assets | Where-Object { $_.name -like "*.zip" -and $_.name -match "win" } | Select-Object -First 1
$exeAsset = $release.assets | Where-Object { $_.name -like "*.exe" -and $_.name -notlike "*.blockmap" } | Select-Object -First 1
if (-not $zipAsset -and -not $exeAsset) {
  abort "latest release has no Windows .zip/.exe. See https://github.com/$Repo/releases/latest"
}

$tmp = Join-Path $env:TEMP ("cookbook-install-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
  $ProgressPreference = "SilentlyContinue"

  if (Get-Process -Name $AppName -ErrorAction SilentlyContinue) {
    abort "$AppName is running. Quit it and paste the install command again."
  }

  if ($zipAsset) {
    $zip = Join-Path $tmp "cookbook.zip"
    ohai "Downloading $($zipAsset.name)…"
    Invoke-WebRequest -Uri $zipAsset.browser_download_url -OutFile $zip -UseBasicParsing -Headers @{ "User-Agent" = "cookbook-install" }
    Unblock-File -Path $zip -ErrorAction SilentlyContinue

    $unpacked = Join-Path $tmp "unpacked"
    ohai "Installing to $DestDir…"
    Expand-Archive -Path $zip -DestinationPath $unpacked -Force
    $exe = Get-ChildItem -Path $unpacked -Filter "$AppName.exe" -Recurse -File | Select-Object -First 1
    if (-not $exe) { abort "$AppName.exe not found inside the zip" }
    $sourceDir = $exe.DirectoryName

    if (Test-Path $DestDir) { Remove-Item -LiteralPath $DestDir -Recurse -Force }
    New-Item -ItemType Directory -Path (Split-Path $DestDir) -Force | Out-Null
    Copy-Item -LiteralPath $sourceDir -Destination $DestDir -Recurse
  } else {
    $installer = Join-Path $tmp "CookbookSetup.exe"
    ohai "Downloading $($exeAsset.name)…"
    Invoke-WebRequest -Uri $exeAsset.browser_download_url -OutFile $installer -UseBasicParsing -Headers @{ "User-Agent" = "cookbook-install" }
    Unblock-File -Path $installer -ErrorAction SilentlyContinue

    ohai "Installing to $DestDir…"
    New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
    $p = Start-Process -FilePath $installer -ArgumentList @("/S", "/D=$DestDir") -PassThru -Wait
    if ($p.ExitCode -ne 0) { abort "installer exited with code $($p.ExitCode)" }
  }

  Get-ChildItem -LiteralPath $DestDir -Recurse -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue

  $launch = Join-Path $DestDir "$AppName.exe"
  if (-not (Test-Path -LiteralPath $launch)) { abort "install finished but $AppName.exe was not found at $DestDir" }

  $programs = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
  New-Item -ItemType Directory -Path $programs -Force | Out-Null
  $wsh = New-Object -ComObject WScript.Shell
  $shortcut = $wsh.CreateShortcut((Join-Path $programs "$AppName.lnk"))
  $shortcut.TargetPath = $launch
  $shortcut.WorkingDirectory = $DestDir
  $shortcut.Save()

  ohai "Launching $AppName…"
  Start-Process -FilePath $launch -WorkingDirectory $DestDir
  Write-Host ""
  Write-Host "Installed to $DestDir"
  Write-Host "Next time, start it from the Start menu."
} finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
