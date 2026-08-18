# Install zip for Git Bash on Windows
# Run this in PowerShell as Administrator

$ErrorActionPreference = "Stop"
$tmpDir = "$env:TEMP\gnuwin32-zip"
$gitBashBin = "C:\Program Files\Git\usr\bin"

# Verify Git Bash exists
if (-not (Test-Path $gitBashBin)) {
    Write-Error "Git Bash not found at: $gitBashBin`nAdjust the `$gitBashBin path if your Git install is elsewhere."
    exit 1
}

Write-Host "Creating temp directory..." -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

# Download zip binary package and its bzip2 dependency
# Using curl.exe (built into Windows 10+) — handles SourceForge redirects correctly
$downloads = @(
    @{
        Url  = "https://downloads.sourceforge.net/project/gnuwin32/zip/3.0/zip-3.0-bin.zip"
        Dest = "$tmpDir\zip-bin.zip"
    },
    @{
        Url  = "https://downloads.sourceforge.net/project/gnuwin32/bzip2/1.0.5/bzip2-1.0.5-bin.zip"
        Dest = "$tmpDir\bzip2-bin.zip"
    }
)

foreach ($dl in $downloads) {
    Write-Host "Downloading $($dl.Url)..." -ForegroundColor Cyan
    & curl.exe -L -o $dl.Dest $dl.Url
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Download failed for $($dl.Url)"
        exit 1
    }
}

# Extract both archives
Write-Host "Extracting..." -ForegroundColor Cyan
Expand-Archive -Path "$tmpDir\zip-bin.zip"  -DestinationPath "$tmpDir\zip-bin"  -Force
Expand-Archive -Path "$tmpDir\bzip2-bin.zip" -DestinationPath "$tmpDir\bzip2-bin" -Force

# Copy zip.exe and required DLLs into Git Bash bin
Write-Host "Copying files to $gitBashBin..." -ForegroundColor Cyan
Copy-Item "$tmpDir\zip-bin\bin\zip.exe"       -Destination $gitBashBin -Force
Copy-Item "$tmpDir\bzip2-bin\bin\bzip2.dll"   -Destination $gitBashBin -Force

# Clean up
Remove-Item -Recurse -Force $tmpDir

Write-Host "`nDone! Open a new Git Bash window and run: zip --version" -ForegroundColor Green