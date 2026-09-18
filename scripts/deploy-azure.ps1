# TagReaderApi Azure App Service ZIP deploy
# Usage: cd C:\dev\TagReaderApi; .\scripts\deploy-azure.ps1
#
# Script rules (do not change without reason):
# - Keep messages ASCII-only (Windows PowerShell 5.1 encoding issues with UTF-8 without BOM)
# - Do not use [n/n] inside double-quoted strings ([...] is parsed as a type literal)
# - Publish to a unique temp folder (project-root publish/ can be locked by AV or local dotnet run)
# - Use tar for ZIP creation (Compress-Archive fails on locked nested files)

#Requires -Version 5.1
$ErrorActionPreference = "Stop"

$ResourceGroup = "rg-ohmiyakoki-tagapp-api"
$AppName = "ohmiyakoki-tagapp-api"
$HealthCheckPath = "/api/environment"
$HealthCheckMaxAttempts = 6
$HealthCheckIntervalSec = 10

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$Csproj = Join-Path $ProjectRoot "TagReaderApi.csproj"
$PublishDir = Join-Path $env:TEMP ("tagreaderapi-publish-" + [guid]::NewGuid().ToString("N"))
$ZipPath = Join-Path $ProjectRoot "deploy.zip"
$LegacyPublishDir = Join-Path $ProjectRoot "publish"

function Write-Step([string]$Message) {
    Write-Host $Message -ForegroundColor Yellow
}

function Ensure-Command([string]$Name, [string]$Hint) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name not found. $Hint"
    }
}

function Remove-LocalSettingsFromPublish([string]$Dir) {
    $patterns = @(
        "appsettings.Development.json",
        "appsettings.Production.json",
        "appsettings.*.local.json"
    )
    foreach ($pattern in $patterns) {
        Get-ChildItem -Path $Dir -Filter $pattern -File -ErrorAction SilentlyContinue |
            ForEach-Object {
                Remove-Item $_.FullName -Force
                Write-Host "Removed from deploy package: $($_.Name)" -ForegroundColor DarkGray
            }
    }
}

function Invoke-HealthCheck([string]$Url) {
    for ($attempt = 1; $attempt -le $HealthCheckMaxAttempts; $attempt++) {
        try {
            return Invoke-RestMethod -Uri $Url -Method Get -TimeoutSec 30
        }
        catch {
            if ($attempt -ge $HealthCheckMaxAttempts) {
                throw "Health check failed after $HealthCheckMaxAttempts attempts: $Url`n$($_.Exception.Message)"
            }
            Write-Host "Health check attempt $attempt failed. Retrying in ${HealthCheckIntervalSec}s..." -ForegroundColor DarkYellow
            Start-Sleep -Seconds $HealthCheckIntervalSec
        }
    }
}

Write-Host "=== TagReaderApi Azure Deploy ===" -ForegroundColor Cyan

Ensure-Command "dotnet" "Install .NET SDK from https://dotnet.microsoft.com/download"
Ensure-Command "az" "Install Azure CLI from https://aka.ms/installazurecliwindows"
Ensure-Command "tar" "tar is included in Windows 10+. Update Windows if missing."

$accountJson = az account show 2>$null
if (-not $accountJson) {
    throw "Not logged in to Azure. Run: az login"
}

Push-Location $ProjectRoot
try {
    if (Test-Path $LegacyPublishDir) {
        Write-Host "Cleaning legacy publish folder: $LegacyPublishDir" -ForegroundColor DarkGray
        Remove-Item $LegacyPublishDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $ZipPath) {
        Remove-Item $ZipPath -Force
    }

    Write-Step "(1/5) dotnet publish (Release)..."
    New-Item -ItemType Directory -Path $PublishDir -Force | Out-Null
    dotnet publish $Csproj -c Release -o $PublishDir --no-self-contained
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet publish failed (exit $LASTEXITCODE)"
    }
    Remove-LocalSettingsFromPublish $PublishDir

    Write-Step "(2/5) Create ZIP..."
    Push-Location $PublishDir
    try {
        tar -a -c -f $ZipPath *
        if ($LASTEXITCODE -ne 0) {
            throw "tar failed to create deploy.zip (exit $LASTEXITCODE)"
        }
    }
    finally {
        Pop-Location
    }

    if (-not (Test-Path $ZipPath)) {
        throw "deploy.zip was not created: $ZipPath"
    }
    $zipSize = (Get-Item $ZipPath).Length
    if ($zipSize -lt 1024) {
        throw "deploy.zip looks too small ($zipSize bytes): $ZipPath"
    }
    Write-Host "deploy.zip size: $([math]::Round($zipSize / 1MB, 2)) MB" -ForegroundColor DarkGray

    Write-Step "(3/5) Deploy to Azure..."
    az webapp deploy `
        --resource-group $ResourceGroup `
        --name $AppName `
        --src-path $ZipPath `
        --type zip
    if ($LASTEXITCODE -ne 0) {
        throw "az webapp deploy failed (exit $LASTEXITCODE)"
    }

    Write-Step "(4/5) Restart App Service..."
    az webapp restart `
        --resource-group $ResourceGroup `
        --name $AppName
    if ($LASTEXITCODE -ne 0) {
        throw "az webapp restart failed (exit $LASTEXITCODE)"
    }

    Write-Step "(5/5) Health check ($HealthCheckPath)..."
    Start-Sleep -Seconds 5

    $hostname = az webapp show `
        --resource-group $ResourceGroup `
        --name $AppName `
        --query "defaultHostName" `
        -o tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($hostname)) {
        throw "Failed to get App Service hostname"
    }

    $healthUrl = "https://$hostname$HealthCheckPath"
    $response = Invoke-HealthCheck $healthUrl
    Write-Host "OK: $healthUrl" -ForegroundColor Green
    $response | ConvertTo-Json -Depth 5
}
finally {
    Pop-Location
    if (Test-Path $PublishDir) {
        Remove-Item $PublishDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "=== Deploy complete ===" -ForegroundColor Green
