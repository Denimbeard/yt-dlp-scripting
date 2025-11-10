# ─────────────────────────────────────────────────────────────────────────────
# PARALLEL TRAILER DOWNLOADER
# Requires PowerShell 7+ (for ForEach-Object -Parallel)
# ─────────────────────────────────────────────────────────────────────────────

# CONFIGURATION
$moviesRoot   = 'E:\Plex Server\Movies'
$ytOptions    = @(
  '--no-playlist',
  '-f', 'bestvideo[height>=720][height<=2160]+bestaudio/best',
  '--merge-output-format', 'mp4'
)
$maxParallel  = 4
$logFile      = Join-Path $moviesRoot 'trailer-download.log'

# ─────────────────────────────────────────────────────────────────────────────
# Initialize (or reset) the central log
"$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [INFO] Starting parallel trailer-download run" |
  Out-File -FilePath $logFile -Encoding UTF8

# Thread-safe logging function (uses atomic byte-stream append)
function Write-Log {
  param(
    [string] $Message,
    [ValidateSet('INFO','WARN','ERROR')] [string] $Level = 'INFO'
  )
  $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  $entry     = "$timestamp [$Level] $Message`r`n"
  Add-Content -Path $logFile -Value $entry -Encoding UTF8 -AsByteStream
}

# ─────────────────────────────────────────────────────────────────────────────
# Gather and process each movie folder in parallel
Get-ChildItem $moviesRoot -Directory |
  Where-Object { $_.Name -ine '0 Blank Folder Template ()' } |
  ForEach-Object -Parallel {

    # Bring in outside vars
    $movieName      = $_.Name
    $movieFolder    = $_.FullName
    $trailersFolder = Join-Path $movieFolder 'Trailers'
    $ytOptions      = $using:ytOptions

    Write-Log "Starting processing: '$movieName'" 'INFO'

    # 1) Skip template folder if ever hit
    if ($movieName -ieq '0 Blank Folder Template ()') {
      Write-Log "Skipped template folder: $movieName" 'WARN'
      return
    }

    # 2) Ensure Trailers folder exists
    if (-not (Test-Path $trailersFolder)) {
      New-Item -Path $trailersFolder -ItemType Directory | Out-Null
      Write-Log "Created Trailers folder for '$movieName'" 'INFO'
    }

    # 3) Skip if any common video type already exists
    $exists = Get-ChildItem -Path $trailersFolder -File -Recurse `
              -ErrorAction SilentlyContinue |
            Where-Object {
              $_.Extension -match '^(?i)\.(mp4|mkv|avi|mov|wmv|flv|webm)$'
            }
    if ($exists) {
      Write-Log "Already has trailer – skipping '$movieName'" 'INFO'
      return
    }

    try {
      # 4) Search YouTube and get video ID
      $query = "ytsearch1:`"$movieName Official Trailer`""
      Write-Log "Searching YouTube: $movieName Official Trailer" 'INFO'
      $ytID = (& yt-dlp.exe --get-id $query 2>&1).Trim()
      if (-not $ytID) { throw "No video ID returned" }

      # 5) Download and force filename to Trailer.<ext>
      $output = Join-Path $trailersFolder 'Trailer.%(ext)s'
      Write-Log "Downloading trailer for '$movieName' (ID: $ytID)" 'INFO'
      & yt-dlp.exe @ytOptions --output $output `
          "https://www.youtube.com/watch?v=$ytID"

      Write-Log "Completed download for '$movieName'" 'INFO'
    }
    catch {
      Write-Log "Error processing '$movieName': $_" 'ERROR'
    }

  } -ThrottleLimit $maxParallel

Write-Log "Parallel run finished" 'INFO'