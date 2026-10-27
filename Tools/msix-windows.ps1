# Crea il pacchetto MSIX di OrbitLR per il Microsoft Store (dopo «tauri build»).
# uso: pwsh Tools/msix-windows.ps1 -Out OrbitLR-Store.msix
# Il pacchetto non è firmato: lo firma Microsoft dopo l'approvazione. Per provarlo sul computer di prova
# lo si firma con un certificato temporaneo (vedi windows.yml).
param([string]$Out = "OrbitLR-Store.msix")
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$win = Join-Path $root "Windows"
$id = Get-Content (Join-Path $win "store\identita.json") -Raw | ConvertFrom-Json
$ver = (Get-Content (Join-Path $win "src-tauri\tauri.conf.json") -Raw | ConvertFrom-Json).version
# Lo Store vuole quattro numeri e l'ultimo a zero
$msixVer = "$ver.0"

$sdk = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\10.*\x64\makeappx.exe" | Sort-Object FullName -Descending | Select-Object -First 1
if (-not $sdk) { throw "makeappx.exe non trovato (Windows SDK)" }
$bin = $sdk.DirectoryName
Write-Output "Windows SDK: $bin"

$lay = Join-Path $env:RUNNER_TEMP "msix-layout"
if (-not $env:RUNNER_TEMP) { $lay = Join-Path $env:TEMP "msix-layout" }
if (Test-Path $lay) { Remove-Item $lay -Recurse -Force }
New-Item -ItemType Directory -Path $lay | Out-Null
Copy-Item (Join-Path $win "target\release\orbitlr.exe") $lay
Copy-Item (Join-Path $win "src-tauri\motori") (Join-Path $lay "motori") -Recurse
Copy-Item (Join-Path $win "store\Assets") (Join-Path $lay "Assets") -Recurse

$m = Get-Content (Join-Path $win "store\AppxManifest.xml") -Raw
$m = $m.Replace("@NAME@", $id.name).Replace("@PUBLISHER@", [Security.SecurityElement]::Escape($id.publisher)).Replace("@PUBLISHER_DISPLAY@", [Security.SecurityElement]::Escape($id.publisherDisplay)).Replace("@VERSION@", $msixVer)
if ($m -match "@[A-Z_]+@") { throw "Manca un valore nel manifesto: $($Matches[0])" }
[IO.File]::WriteAllText((Join-Path $lay "AppxManifest.xml"), $m, (New-Object Text.UTF8Encoding $false))

# Le icone nelle varie misure (scale-200, targetsize-…) si trovano tramite resources.pri
Push-Location $env:RUNNER_TEMP
& "$bin\makepri.exe" createconfig /cf priconfig.xml /dq it-IT_en-US /o | Out-Null
if ($LASTEXITCODE) { throw "makepri createconfig: $LASTEXITCODE" }
& "$bin\makepri.exe" new /pr $lay /cf priconfig.xml /mn (Join-Path $lay "AppxManifest.xml") /of (Join-Path $lay "resources.pri") /o
if ($LASTEXITCODE) { throw "makepri new: $LASTEXITCODE" }
Pop-Location

& "$bin\makeappx.exe" pack /d $lay /p $Out /o
if ($LASTEXITCODE) { throw "makeappx: $LASTEXITCODE" }
$size = [math]::Round((Get-Item $Out).Length / 1MB, 1)
Write-Output "::notice::Pacchetto per lo Store pronto: $Out ($size MB, versione $msixVer, identità $($id.name)$(if ($id.prova) { ' — DI PROVA' }))"
