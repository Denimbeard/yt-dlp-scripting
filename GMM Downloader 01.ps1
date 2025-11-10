# ========================================================================
# REGION: Logging Utility
# ========================================================================
function Write-Log {
    param (
        [Parameter(Mandatory)][string] $LogFile,
        [Parameter(Mandatory)][string] $Message,
        [switch] $ViewAll
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry     = "$timestamp`t$Message"

    # Ensure UTF-8 with BOM on first write
    if (-not (Test-Path $LogFile)) {
        $bom = [System.Text.Encoding]::UTF8.GetPreamble()
        [System.IO.File]::WriteAllBytes($LogFile, $bom)
    }

    # Use StreamWriter with AutoFlush for real-time logging
    $stream = New-Object System.IO.StreamWriter($LogFile, $true, [System.Text.Encoding]::UTF8)
    $stream.AutoFlush = $true
    $stream.WriteLine($entry)
    $stream.Close()

    # Optional: Open all log files in viewer
    if ($ViewAll) {
        $logDir = Split-Path $LogFile
        $logFiles = Get-ChildItem -Path $logDir -Filter *.txt

        foreach ($file in $logFiles) {
            Start-Process powershell -ArgumentList "-NoExit", "-Command", "Get-Content -Path '$($file.FullName)' -Wait"
        }
    }
}
function Open-AllLogsLive {
    param (
        [Parameter(Mandatory)][array] $ShowConfigs
    )

    foreach ($show in $ShowConfigs) {
        $logFile = Join-Path $show.LogDir "$($show.ShowName)-$($show.SeasonTag).log"
        if (Test-Path $logFile) {
            Start-Process powershell -ArgumentList "-NoExit", "-Command", "Get-Content -Path '$logFile' -Wait"
        } else {
            Write-Host "⚠️ Log file not found: $logFile"
        }
    }
}

# ========================================================================
# REGION: Metadata Tagging
# ========================================================================
<#
.DESCRIPTION
Embed metadata into an MP4 using ffmpeg.
Requires: JSON from yt-dlp plus show/season info.
#>
function Tag-MediaMetadata {
    param(
        [string]   $FilePath,
        [psobject] $VideoMetadata,
        [string]   $LogDir,
        [string]   $ShowName,
        [string]   $SeasonTag,
        [string]   $LogPath
    )

    $rawDate = $VideoMetadata.upload_date
    $dt      = [datetime]::ParseExact($rawDate, 'yyyyMMdd', $null)
    $dateTag = $dt.ToString('yyyy-MM-dd')

    $tags = @{
        title   = $VideoMetadata.title
        artist  = $VideoMetadata.uploader
        album   = "$ShowName $SeasonTag"
        comment = $VideoMetadata.description
        date    = $dateTag
        genre   = ($VideoMetadata.tags -join ', ')
    }

    $metaArgs = foreach ($kv in $tags.GetEnumerator()) {
        '-metadata', "$($kv.Key)=$($kv.Value)"
    }

    $dir  = Split-Path $FilePath -Parent
    $baseName = [IO.Path]::GetFileNameWithoutExtension($FilePath)
	$temp     = Join-Path $dir "$baseName.temp.mp4"

	if (-not ($FilePath -match '\.mp4$')) {
		Write-Log -LogFile $LogPath -Message "❌ Skipping tagging — unsupported format: $FilePath"
		return
	}
    if ($FilePath -notmatch '\.mp4$') {
        Write-Log -LogFile $LogPath -Message "❌ Invalid input file: $FilePath"
        return
    }

    & ffmpeg.exe -i $FilePath @metaArgs -c copy -y $temp | Out-Null

    if (Test-Path $temp) {
        Remove-Item $FilePath -Force
        Rename-Item -Path $temp -NewName (Split-Path $FilePath -Leaf)
        Write-Log -LogFile $LogPath -Message "✅ Tagged: $(Split-Path $FilePath -Leaf)"
    } else {
        Write-Log -LogFile $LogPath -Message "⚠️ Tagging failed: $(Split-Path $FilePath -Leaf)"
    }
}

# ========================================================================
# REGION: Playlist Sync Logic
# ========================================================================
<#
.DESCRIPTION
Download, validate, and tag new playlist episodes.
#>
<#
.DESCRIPTION
Log messages with timestamps in a UTF-8-safe format.
#>
function Sync-Playlist {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $PlaylistUrl,
        [Parameter(Mandatory)][string] $OutputDir,
        [Parameter(Mandatory)][string] $LogDir,
        [Parameter(Mandatory)][string] $SeasonTag,
        [Parameter(Mandatory)][string] $ShowName
    )

    # Ensure directories exist
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    New-Item -ItemType Directory -Force -Path $LogDir    | Out-Null
    $LogPath   = Join-Path $LogDir "$ShowName-$SeasonTag.log"
    $Archive   = Join-Path $LogDir "download_archive.txt"
    $CompatLog = Join-Path $LogDir "PlexCompatibilityIssues.log"
    Write-Log -LogFile $LogPath -Message "▶️ Sync start: $ShowName ($SeasonTag)"

    # Tool sanity checks
    foreach ($tool in 'yt-dlp.exe','ffmpeg.exe','ffprobe.exe') {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw "$tool not found in PATH"
        }
    }

    # Extract max episode number as integer
    $pattern = [regex]"${SeasonTag}E(?<num>\d{1,3})"
    $current = Get-ChildItem -Path $OutputDir -Filter '*.mp4' |
               ForEach-Object {
                   if ($pattern.IsMatch($_.BaseName)) {
                       [int]$pattern.Match($_.BaseName).Groups['num'].Value
                   }
               }
    $maxOnDisk = [int]($current | Measure-Object -Maximum).Maximum
	if (-not $maxOnDisk) {
		$maxOnDisk = 0
		$typeName = "null"
	} else {
		$typeName = $maxOnDisk.GetType().Name
	}

	Write-Log -LogFile $LogPath -Message "🧪 maxOnDisk raw: $maxOnDisk (type: $typeName)"

    # Format for logging only
    $epFormatted = "E" + $maxOnDisk.ToString("D3")
    Write-Log -LogFile $LogPath -Message "🔢 Highest on disk: $epFormatted"

    # Retrieve flat playlist
    $raw = & yt-dlp.exe $PlaylistUrl --flat-playlist --print-json 2>&1
    $videos = $raw | ForEach-Object {
        try { $_ | ConvertFrom-Json } catch { $null }
    } | Where-Object { $_ }

    if ($videos.Count -eq 0) {
        Write-Log -LogFile $LogPath -Message "⚠️ Playlist empty — aborting."
        return
    }

    # Index + filter
    $indexed = $videos | ForEach-Object -Begin { $i = 0 } -Process {
        $i++
        [PSCustomObject]@{
            Position = $i
            Url      = "https://www.youtube.com/watch?v=$($_.id)"
            Title    = $_.title
            Id       = $_.id
        }
    }
    $queue = $indexed | Where-Object { $_.Position -gt $maxOnDisk }
    Write-Log -LogFile $LogPath -Message "✅ Episodes to download: $($queue.Count)"
    if ($queue.Count -eq 0) {
        Write-Log -LogFile $LogPath -Message "📦 Up to date as of $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') — last episode: $epFormatted"
    }

    # Counters
    $total = $success = $compatErr = $tagged = 0

    foreach ($v in $queue) {
        $total++
        $epTag = $v.Position.ToString('D2')
        $safe  = $v.Title -replace '[\\/:*?"<>|]', ''
        $base  = "$ShowName - ${SeasonTag}E${epTag} - $safe [$($v.Id)]"
        $file  = Join-Path $OutputDir "$base.mp4"
        Write-Log -LogFile $LogPath -Message "🚀 E${epTag} → downloading"

        # quality strategy
        $primary  = "bestvideo[height<=720][vcodec^=avc1]+bestaudio[ext=m4a]"
        $fallback = "bestvideo[height<=1080][vcodec^=avc1]+bestaudio[ext=m4a]"

# Download attempt with SABR streaming warning detection
try {
    Write-Log -LogFile $LogPath -Message "🚀 Starting download for: $($v.Url)"
    $ytOutput = & yt-dlp.exe --download-archive $Archive `
                             -f $primary `
                             --merge-output-format mp4 `
                             -o $file `
                             $v.Url 2>&1

    if ($ytOutput -match "SABR streaming") {
        Write-Log -LogFile $LogPath -Message "⚠️ SABR streaming warning detected for: $($v.Url) — skipping"

        # Extract video ID from URL
        if ($v.Url -match "v=([a-zA-Z0-9_-]{11})") {
            $videoId = $matches[1]
            Add-Content -Path $Archive -Value "youtube $videoId"
            Write-Log -LogFile $LogPath -Message "📁 Added to archive: youtube $videoId"
        } else {
            Write-Log -LogFile $LogPath -Message "⚠️ Could not extract video ID from: $($v.Url)"
        }

        continue
    }

    Write-Log -LogFile $LogPath -Message "✅ 720p grabbed"
    if ($ytOutput -notmatch "ERROR:") {
        Write-Log -LogFile $LogPath -Message "✅ Download completed successfully for: $($v.Url)"
    } else {
        Write-Log -LogFile $LogPath -Message "❌ Download failed for: $($v.Url)"
    }
} catch {
    Write-Log -LogFile $LogPath -Message "⚠️ 720p failed — trying 1080p"
    try {
        Write-Log -LogFile $LogPath -Message "🚀 Retrying download for: $($v.Url) at 1080p"
        & yt-dlp.exe --download-archive $Archive `
                     -f $fallback `
                     --merge-output-format mp4 `
                     -o $file `
                     $v.Url | Out-Null
        Write-Log -LogFile $LogPath -Message "✅ 1080p grabbed"
    } catch {
        Write-Log -LogFile $LogPath -Message "❌ 1080p download failed for: $($v.Url) - Error: $_"
    }
}


    # Compatibility probe
    try {
        $vInfo   = & ffprobe.exe -v error -select_streams v:0 -show_entries stream=codec_name,height -of default=nokey=1:noprint_wrappers=1 $file
        $vCodec, $vHeight = $vInfo
        $aInfo   = & ffprobe.exe -v error -select_streams a:0 -show_entries stream=codec_name -of default=nokey=1:noprint_wrappers=1 $file
        $aCodec  = if ($aInfo.Count -gt 0) { $aInfo[0] } else { "unknown" }

    if ($vCodec -ne 'h264' -or [int]$vHeight -gt 1080 -or $aCodec -ne 'aac') {
        $msg = "⚠️ Incompatible ($vCodec / $aCodec / ${vHeight}p) → $base.mp4"
        Write-Log -LogFile $LogPath   -Message $msg
        Write-Log -LogFile $CompatLog -Message $msg
    } else {
			Write-Log -LogFile $LogPath -Message "✅ Format OK"
		}
    } catch {
        Write-Log -LogFile $LogPath -Message "⚠️ ffprobe failed on $base.mp4"
    }

	# Metadata tagging
        Write-Log -LogFile $LogPath -Message "🔍 Starting metadata tagging for: $($file)"
        try {
            $metaJson = & yt-dlp.exe $v.Url --dump-json | ConvertFrom-Json
            Write-Log -LogFile $LogPath -Message "✅ Metadata JSON retrieved successfully for: $($file)"
            Tag-MediaMetadata -FilePath $file -VideoMetadata $metaJson `
                              -LogDir $LogDir -ShowName $ShowName `
                              -SeasonTag $SeasonTag -LogPath $LogPath
            $tagged++
            Write-Log -LogFile $LogPath -Message "✅ Metadata tagging completed for: $($file)"
        } catch {
            Write-Log -LogFile $LogPath -Message "❌ Metadata tagging failed for: $($file) - Error: $_"
        }

        # Log Metadata Fields
        Write-Log -LogFile $LogPath -Message "🧾 Metadata fields: title=$($metaJson.title), uploader=$($metaJson.uploader)"

        # Compatibility Check Logging
        Write-Log -LogFile $LogPath -Message "⚠️ Format check failed: codec=$codec, resolution=$resolution"

    # Subtitle availability log
    $subs = @()
    if ($metaJson.subtitles) {
        $subs = $metaJson.subtitles.Keys
    } elseif ($metaJson.automatic_captions) {
        $subs = $metaJson.automatic_captions.Keys
    }

    if ($subs.Count -gt 0) {
        Write-Log -LogFile $LogPath -Message "📝 Subtitles available: $($subs -join ', ')"
    } else {
        Write-Log -LogFile $LogPath -Message "🚫 No subtitles found for: $($v.Title)"
		}
}

# Subtitle recovery pass
Write-Log -LogFile $LogPath -Message "`n🛠️ Subtitle recovery pass starting..."
$videoFiles = Get-ChildItem -Path $OutputDir -Filter "*.mp4"

# Initialize counters
$subFound   = 0
$subUpdated = 0
$subErrored = 0

foreach ($vid in $videoFiles) {
    $baseName = $vid.BaseName

    # Check for existing subtitles
    $subExists = Get-ChildItem -Path $OutputDir -Filter "*.srt" | Where-Object {
        $_.BaseName.StartsWith($baseName) -and (
            $_.Name.EndsWith(".en.srt") -or
            $_.Name.EndsWith(".en-en.srt") -or
            $_.Name.EndsWith(".en-US.srt")
        )
    }

    if (-not $subExists) {
        Write-Log -LogFile $LogPath -Message "🔍 No subtitles found for: $baseName — attempting recovery"

        $videoId = $null
        if ($baseName -match '\[(?<id>[a-zA-Z0-9_-]{11})\]') {
            $videoId = $matches["id"]
        }

        if ($videoId -and $videoId.Length -eq 11) {
            $url = "https://www.youtube.com/watch?v=$videoId"
            Write-Log -LogFile $LogPath -Message "🧪 Attempting subtitle recovery — videoId: $videoId"
            try {
                & yt-dlp.exe `
                    --write-subs `
                    --write-auto-subs `
                    --sub-lang "en-en" `
                    --convert-subs srt `
                    --skip-download `
                    -o "$OutputDir/$baseName.%(ext)s" `
                    $url | Out-Null
                Write-Log -LogFile $LogPath -Message "✅ Subtitles recovered for: $baseName"
            } catch {
                $subErrored++
                Write-Log -LogFile $LogPath -Message "❌ Subtitle recovery failed for: $baseName"
            }
        } else {
            Write-Log -LogFile $LogPath -Message "⚠️ Invalid or missing video ID for: $baseName — skipping"
        }
    } else {
        $subFound += $subExists.Count
        Write-Log -LogFile $LogPath -Message "✅ Subtitles already exist for: $baseName"
        foreach ($sub in $subExists) {
            Write-Log -LogFile $LogPath -Message "📄 Detected subtitle: $($sub.Name)"
        }
    }
}

# Summary log
Write-Log -LogFile $LogPath -Message "`n🛠️ Subtitle recovery pass complete!"
Write-Log -LogFile $LogPath -Message "📊 Summary:"
Write-Log -LogFile $LogPath -Message "✅ Subtitles found: $subFound"
Write-Log -LogFile $LogPath -Message "✅ Subtitles updated: $subUpdated"
Write-Log -LogFile $LogPath -Message "❌ Subtitles errored: $subErrored"
}

# ========================================================================
# REGION: Invocation
# ========================================================================
$playlists = @(
    @{
        Url       = 'https://www.youtube.com/playlist?list=PLJ49NV73ttrt60yAQUx-WoaQM3-MksNE3'
        OutputDir = 'E:\Plex Server\TV Programs\GMM Gut Check (2008)\Season 01'
        ShowName  = 'GMM Gut Check'
        SeasonTag = 'S01'
        LogDir    = 'E:\Plex Server\TV Programs\GMM Gut Check (2008)\Logs'
    },
    @{
        Url       = 'https://www.youtube.com/playlist?list=PLJ49NV73ttrs67L-YJjl0UGF1vsWC7tH8'
        OutputDir = 'E:\Plex Server\TV Programs\GMM Frozen vs Fast vs Fancy Food (2008)\Season 01'
        ShowName  = 'GMM FFF'
        SeasonTag = 'S01'
        LogDir    = 'E:\Plex Server\TV Programs\GMM Frozen vs Fast vs Fancy Food (2008)\Logs'
    },
    @{
        Url       = 'https://www.youtube.com/playlist?list=PLJ49NV73ttrvzyYLLkhoyqe51ptzxCROA'
        OutputDir = 'E:\Plex Server\TV Programs\GMM International Taste Tests (2008)\Season 01'
        ShowName  = 'GMM International Taste Tests'
        SeasonTag = 'S01'
        LogDir    = 'E:\Plex Server\TV Programs\GMM International Taste Tests (2008)\Logs'
    },
    @{
        Url       = 'https://www.youtube.com/playlist?list=PLJ49NV73ttrucP6jJ1gjSqHmhlmvkdZuf'
        OutputDir = 'E:\Plex Server\TV Programs\GMM Will It (2008)\Season 01'
        ShowName  = 'GMM Will It'
        SeasonTag = 'S01'
        LogDir    = 'E:\Plex Server\TV Programs\GMM Will It (2008)\Logs'
    },
	@{
        Url       = 'https://www.youtube.com/playlist?list=PLwU43tJ71iG1q0et0FUO4-s7nOdtzA4l9'
        OutputDir = 'E:\Plex Server\TV Programs\Dreamhop Music (2017)\Season 02'
        ShowName  = 'Dreamhop Spring'
        SeasonTag = 'S02'
        LogDir    = 'E:\Plex Server\TV Programs\Dreamhop Music (2017)\Season 02\Logs'
    },
	@{
        Url       = 'https://www.youtube.com/playlist?list=PLwU43tJ71iG1tFZu4O2ew4ew_pysMoP35'
        OutputDir = 'E:\Plex Server\TV Programs\Dreamhop Music (2017)\Season 03'
        ShowName  = 'Dreamhop Summer'
        SeasonTag = 'S03'
        LogDir    = 'E:\Plex Server\TV Programs\Dreamhop Music (2017)\Season 03\Logs'
    },
	@{
        Url       = 'https://www.youtube.com/playlist?list=PLwU43tJ71iG24-_VG4vW0plvF-iyki-oF'
        OutputDir = 'E:\Plex Server\TV Programs\Dreamhop Music (2017)\Season 04'
        ShowName  = 'Dreamhop Autumn'
        SeasonTag = 'S04'
        LogDir    = 'E:\Plex Server\TV Programs\Dreamhop Music (2017)\Season 04\Logs'
    },
	@{
        Url       = 'https://www.youtube.com/playlist?list=PLwU43tJ71iG2TVSZ-7KNFeAt8drDZSKBl'
        OutputDir = 'E:\Plex Server\TV Programs\Dreamhop Music (2017)\Season 05'
        ShowName  = 'Dreamhop Winter'
        SeasonTag = 'S05'
        LogDir    = 'E:\Plex Server\TV Programs\Dreamhop Music (2017)\Season 05\Logs'
    }
)
# ========================================================================
# REGION: Begin Sync
# ========================================================================
foreach ($config in $playlists) {
    Write-Host "Starting sync for $($config.ShowName) [$($config.SeasonTag)]..."
    # 🧪 Start tailing the log file for this playlist
    $logPath = Join-Path $config.LogDir "$($config.ShowName)-$($config.SeasonTag).log"
    if (Test-Path $logPath) {
        Start-Job -ScriptBlock {
            param($path)
            Get-Content -Path $path -Wait
        } -ArgumentList $logPath | Out-Null
    }

    # 🛠️ Run the sync
    Sync-Playlist -PlaylistUrl $config.Url `
                  -OutputDir  $config.OutputDir `
                  -LogDir     $config.LogDir `
                  -SeasonTag  $config.SeasonTag `
                  -ShowName   $config.ShowName

    Write-Host "Finished sync for $($config.ShowName) [$($config.SeasonTag)]`n"
}