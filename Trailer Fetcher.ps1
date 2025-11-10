# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
$moviesRoot = 'E:\Plex Server\Movies'
$ytOptions  = @(
  '--no-playlist',
  '-f', 'bestvideo[height>=720][height<=2160]+bestaudio/best',
  '--merge-output-format', 'mp4'
)

# Path to the central log file
$logFile = Join-Path $moviesRoot 'trailer-download.log'

# Initialize (or reset) the log
"$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [INFO] Starting trailer‐download run" |
  Out-File -FilePath $logFile -Encoding UTF8

# Helper to write to the log
function Write-Log {
  param(
    [string]$Message,
    [ValidateSet('INFO','WARN','ERROR')] [string]$Level = 'INFO'
  )
  $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  "$timestamp [$Level] $Message" |
    Add-Content -Path $logFile -Encoding UTF8
}

# 1) Enumerate directories and log count
$allDirs = Get-ChildItem $moviesRoot -Directory -ErrorAction Stop
Write-Log "Found $($allDirs.Count) folders under '$moviesRoot'"

# 2) Process each folder
foreach ($dir in $allDirs) {
  $movieName      = $dir.Name
  $movieFolder    = $dir.FullName
  $trailersFolder = Join-Path $movieFolder 'Trailers'

  # 2.a) Log start of iteration
  Write-Log "---- Processing folder: '$movieName'" 'INFO'

  # 2.b) Skip the template
  if ($movieName -ieq '0 Blank Folder Template ()') {
    Write-Host "⚠️  Skipping template folder: $movieName"
    Write-Log "Skipping template folder: $movieName" 'WARN'
    continue
  }

  # 2.c) Ensure Trailers folder exists
  if (-not (Test-Path $trailersFolder)) {
    Write-Host "🆕 Creating Trailers folder for '$movieName'"
    Write-Log "Creating Trailers folder for '$movieName'" 'INFO'
    New-Item -Path $trailersFolder -ItemType Directory | Out-Null
  }

  # 2.d) Skip if any video already exists
  $existing = Get-ChildItem -Path $trailersFolder -File -Recurse `
                -ErrorAction SilentlyContinue |
              Where-Object {
                $_.Extension -match '^(?i)\.(mp4|mkv|avi|mov|wmv|flv|webm)$'
              }

  if ($existing) {
    Write-Host "✅ Trailer already exists for '$movieName'"
    Write-Log "Trailer already exists – skipping '$movieName'" 'INFO'
    continue
  }

  try {
    # 2.e) Fetch YouTube ID
    $query = "ytsearch1:`"$movieName Official Trailer`""
    Write-Host "🔍 Searching YouTube for: $movieName Official Trailer"
    Write-Log "Searching YouTube for: $movieName Official Trailer" 'INFO'

    $ytID = ( & yt-dlp.exe --get-id $query 2>&1 | Out-String ).Trim()

	if ($ytID -match 'ERROR:' -or $ytID -eq '') {
		throw "No valid video ID returned"
	}

    # 2.f) Download trailer
    $outputPath = Join-Path $trailersFolder 'Trailer.%(ext)s'
    Write-Host "▶️ Downloading trailer for '$movieName' (ID: $ytID)"
    Write-Log "Downloading trailer for '$movieName' (ID: $ytID)" 'INFO'

    & yt-dlp.exe @ytOptions --output $outputPath `
      "https://www.youtube.com/watch?v=$ytID"

    Write-Host "✅ Completed: '$movieName'"
    Write-Log "Successfully downloaded trailer for '$movieName'" 'INFO'

  } catch {
    Write-Host "❌ Error processing '$movieName': $_" -ForegroundColor Red
    Write-Log "Error processing '$movieName': $_" 'ERROR'
  }
}

Write-Log "Run finished" 'INFO'