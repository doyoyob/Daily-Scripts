# Setup Encoding for Japanese Titles
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# Paths
$inputFolder  = "C:\Users\riku\Documents\books"
$outputFolder = "C:\Users\riku\Documents\KFX_Output"
$workDir      = "C:\Users\riku\Documents\kp_work" 

# Tools
$ebookConvert = "C:\Program Files\Calibre2\ebook-convert.exe"
$calibreDebug = "C:\Program Files\Calibre2\calibre-debug.exe"

# Create clean folders
if (!(Test-Path $outputFolder)) { New-Item -ItemType Directory -Path $outputFolder }
if (Test-Path $workDir) { Remove-Item $workDir -Recurse -Force }
New-Item -ItemType Directory -Path $workDir

$files = Get-ChildItem -Path $inputFolder -Filter *.cbz

foreach ($file in $files) {
    $originalName = $file.BaseName
    Write-Host "`n>>> Processing: $originalName" -ForegroundColor Cyan

    # Step 1: Copy CBZ to a simple name
    $tempCbz = Join-Path $workDir "source.cbz"
    Copy-Item $file.FullName -Destination $tempCbz -Force

    # Step 2: Convert CBZ -> EPUB using Calibre's converter
    $tempEpub = Join-Path $workDir "source.epub"
    Write-Host "--> Converting CBZ to EPUB..." -ForegroundColor Yellow
    & $ebookConvert "$tempCbz" "$tempEpub"

    if (!(Test-Path $tempEpub)) {
        Write-Host "--> ERROR: EPUB conversion failed." -ForegroundColor Red
        Get-ChildItem $workDir | Remove-Item -Recurse -Force
        continue
    }

    # Step 3: Convert EPUB -> KFX using the KFX Output plugin
    Write-Host "--> Converting EPUB to KFX..." -ForegroundColor Green
    & $calibreDebug -r "KFX Output" -- "$tempEpub"

    $tempKfx = Join-Path $workDir "source.kfx"

    if (Test-Path $tempKfx) {
        $finalPath = Join-Path $outputFolder "$originalName.kfx"
        Move-Item -Path $tempKfx -Destination $finalPath -Force
        Write-Host "--> SUCCESS!" -ForegroundColor Green
    } else {
        Write-Host "--> ERROR: KFX conversion failed." -ForegroundColor Red
    }

    # Clean up
    Get-ChildItem $workDir | Remove-Item -Recurse -Force
}