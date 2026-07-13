$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir
$version = (Get-Content (Join-Path $rootDir "VERSION") -Raw).Trim()
$distDir = Join-Path $rootDir "dist"
$publishDir = Join-Path $scriptDir ".publish"
$project = Join-Path $scriptDir "AIClockBridge\AIClockBridge.csproj"
$output = Join-Path $distDir "AIClockBridge-$version-Windows-x64.exe"

New-Item -ItemType Directory -Force $distDir | Out-Null
Remove-Item -Recurse -Force $publishDir -ErrorAction SilentlyContinue

dotnet publish $project -c Release -r win-x64 --self-contained true `
    -p:Version=$version `
    -p:PublishSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:DebugType=None `
    -o $publishDir

Copy-Item (Join-Path $publishDir "AIClockBridge.exe") $output -Force
Write-Host "Created: $output"
