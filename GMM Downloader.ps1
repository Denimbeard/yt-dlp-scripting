<#
.SYNOPSIS
Write a timestamped UTF-8 log entry and optionally tail all logs in the same folder.
#>
function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $LogFile,
        [Parameter(Mandatory)][string] $Message,
        [switch] $ViewAll
    )

    # Ensure BOM on first write
    if (-not (Test-Path $LogFile)) {
        [IO.File]::WriteAllBytes($LogFile, [Text.Encoding]::UTF8.GetPreamble())
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry     = "$timestamp`t$Message"

    # Write and flush
    $sw = [IO.File]::AppendText($LogFile)
    $sw.WriteLine($entry); $sw.Dispose()

    # Optional tail all .txt logs in same folder
    if ($ViewAll) {
        $dir = Split-Path $LogFile
        Get-ChildItem "$dir\*.txt" | ForEach-Object {
            Start-Process powershell `
                -ArgumentList "-NoExit","-Command","Get-Content -Path '$($_.FullName)' -Wait"
        }
    }
}

<#
.SYNOPSIS
Download a single video with fallback quality and SABR-streaming detection.
#>
function Download-Video {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Url,
        [Parameter(Mandatory)][string] $OutputFile,
        [Parameter(Mandatory)][string] $ArchiveFile,
        [Parameter(Mandatory)][string] $LogPath
    )

    # Formats to try in order
    $formats = @(
        'bestvideo[height<=720][vcodec^=avc1]+bestaudio',
        'bestvideo[height<=460][vcodec^=avc1]+bestaudio'
    )

    # Target combined rate limit (adjust per-stream if needed)
    $combinedLimit = '1M'  # per stream; lower if you want total cap across video+audio

    foreach ($fmt in $formats) {
        Write-Log -LogFile $LogPath -Message "⏬ Downloading ($fmt): $Url"

        $ytArgs = @(
            "--embed-metadata",
            "--download-archive", $ArchiveFile,
            "-f", $fmt,
            "--merge-output-format", "mp4",
            "--limit-rate", $combinedLimit,
            "--socket-timeout", "30",
            "--extractor-args", "youtube:player_client=web",
            "-o", $OutputFile,
            $Url
        )

        $output = & yt-dlp.exe @ytArgs 2>&1

        if ($output -match 'SABR streaming') {
            Write-Log -LogFile $LogPath -Message "⚠️ SABR streaming, skipping $Url"
            return $false
        }

        if ($LASTEXITCODE -eq 0 -and (Test-Path $OutputFile)) {
            Write-Log -LogFile $LogPath -Message "✅ Downloaded: $(Split-Path $OutputFile -Leaf)"
            return $true
        }

        Write-Log -LogFile $LogPath -Message "❌ Failed format $fmt, trying next after delay"
        Start-Sleep -Seconds 5  # PowerShell-side pause between retries
    }

    return $false
}

<#
.SYNOPSIS
Run ffprobe to verify H264/AAC ≤1080p compatibility.
#>
function Test-Compatibility {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter(Mandatory)][string] $LogPath,
        [Parameter(Mandatory)][string] $CompatLog
    )

    $streams = & ffprobe.exe -v error `
               -select_streams v:0 -show_entries stream=codec_name,height `
               -of default=nokey=1:noprint_wrappers=1 $FilePath
    $vCodec, $vHeight = $streams
    $aCodec = (& ffprobe.exe -v error `
               -select_streams a:0 -show_entries stream=codec_name `
               -of default=nokey=1:noprint_wrappers=1 $FilePath)[0]

    if ($vCodec -ne 'h264' -or [int]$vHeight -gt 1080 -or $aCodec -ne 'aac') {
        $msg = "⚠️ Incompatible ($vCodec/$aCodec/${vHeight}p): $(Split-Path $FilePath -Leaf)"
        Write-Log -LogFile $LogPath -Message $msg
        Add-Content -Path $CompatLog -Value $msg
        return $false
    }
    Write-Log -LogFile $LogPath -Message "✅ Format OK"
    return $true
}

<#
.SYNOPSIS
Embed metadata via ffmpeg into the MP4 file.
#>
<#
function Tag-MediaMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]   $FilePath,
        [Parameter(Mandatory)][psobject] $VideoMetadata,
        [Parameter(Mandatory)][string]   $LogPath
    )

    $tags = @{
        title   = $VideoMetadata.title
        artist  = $VideoMetadata.uploader
        album   = "$($VideoMetadata.uploader) $($VideoMetadata.upload_date)"
        comment = $VideoMetadata.description
        date    = [datetime]::ParseExact($VideoMetadata.upload_date,'yyyyMMdd',$null).ToString('yyyy-MM-dd')
        genre   = ($VideoMetadata.tags -join ', ')
    }
    $metaArgs = $tags.GetEnumerator() | ForEach-Object { '-metadata', "$($_.Key)=$($_.Value)" }

    $temp = [IO.Path]::ChangeExtension($FilePath, '.temp.mp4')
    & ffmpeg.exe -i $FilePath @metaArgs -c copy -y $temp | Out-Null
    if (Test-Path $temp) {
        Remove-Item $FilePath -Force
        Rename-Item -Path $temp -NewName (Split-Path $FilePath -Leaf)
        Write-Log -LogFile $LogPath -Message "✅ Tagged: $(Split-Path $FilePath -Leaf)"
    } else {
        Write-Log -LogFile $LogPath -Message "⚠️ Tagging failed: $(Split-Path $FilePath -Leaf)"
    }
}
#>
<#
.SYNOPSIS
Recover subtitles (en-en, then en) only if none exist.
#>
function Recover-Subtitles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $BaseName,
        [Parameter(Mandatory)][string] $OutputDir,
        [Parameter(Mandatory)][string] $LogPath,
        [Parameter(Mandatory)][string] $FailLogPath
    )

    # 1. Load cache of previously failed bases
    $failedCache = @{}
    if (Test-Path $FailLogPath) {
        Get-Content $FailLogPath | ForEach-Object { $failedCache[$_] = $true }
    }

    # 2. Skip if already failed
    if ($failedCache.ContainsKey($BaseName)) {
        Write-Log -LogFile $LogPath -Message "⏭️ Skipping cached failure: $BaseName"
        return
    }

    # 3. Check if any subtitles already exist
    $subsExist = Get-ChildItem $OutputDir -Filter "$BaseName*.srt"
    if ($subsExist) {
        Write-Log -LogFile $LogPath -Message "📄 Subtitles already exist for: $BaseName"
        return
    }

    # 4. Extract video ID
    if ($BaseName -notmatch '\[(?<id>[A-Za-z0-9_-]{11})\]') {
        Write-Log -LogFile $LogPath -Message "⚠️ No valid video ID in: $BaseName"
        return
    }
    $videoId = $matches.id
    $url     = "https://www.youtube.com/watch?v=$videoId"
    $langs   = 'en-en','en'

    # 5. Attempt recovery
    $succeeded = $false
    foreach ($lang in $langs) {
        Write-Log -LogFile $LogPath -Message "🧪 Attempting subtitle ($lang) for: $BaseName"
        & yt-dlp.exe --write-subs --write-auto-subs --sub-lang $lang `
                     --convert-subs srt --skip-download `
					 --limit-rate 1M --sleep-interval 5 `
                     -o "$OutputDir\$BaseName.%(ext)s" $url | Out-Null

        if (Test-Path "$OutputDir\$BaseName.$lang.srt") {
            Write-Log -LogFile $LogPath -Message "✅ Recovered ($lang) for: $BaseName"
            $succeeded = $true
            break
        }
    }

    # 6. Log failure if nothing was recovered
    if (-not $succeeded) {
        Write-Log -LogFile $LogPath -Message "❌ Subtitle recovery failed for: $BaseName"
        Add-Content -Path $FailLogPath -Value $BaseName
    }
}

<#
.SYNOPSIS
Perform full sync of a playlist.
#>
function Sync-Playlist {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable] $Config
    )

    # Unpack config
    $url       = $Config.Url
    $odir      = $Config.OutputDir
    $ldir      = $Config.LogDir
    $season    = $Config.SeasonTag
    $show      = $Config.ShowName
    $logFile   = Join-Path $ldir "$show-$season.log"
    $archFile  = Join-Path $ldir 'download_archive.txt'
    $compFile  = Join-Path $ldir 'PlexCompatibilityIssues.log'
	$subFailLog = Join-Path $ldir 'SubtitleRecoveryFailures.log'
    $archFile = Join-Path $ldir 'download_archive.txt'
    $compFile = Join-Path $ldir 'PlexCompatibilityIssues.log'

	
	# Ensure directories exist
    New-Item -Path $odir,$ldir -ItemType Directory -Force | Out-Null

    # Preflight
    New-Item -Path $odir,$ldir -ItemType Directory -Force | Out-Null
    Write-Log -LogFile $logFile -Message "▶️ Starting sync: $show ($season)"

    # Build flat playlist
    $videos = (& yt-dlp.exe $url --flat-playlist --print-json) `
              | ConvertFrom-Json
   Write-Log -LogFile $logFile -Message "🔍 Retrieved $($videos.Count) playlist items."

	if ($videos.Count -eq 0) {
		Write-Log -LogFile $logFile -Message "⚠️ yt-dlp returned no items — check your URL/flags"
		return
	}

	# 1) Scan .mp4 files and pull out any “E###” numbers
	$numResult = Get-ChildItem $odir -Filter '*.mp4' |
	ForEach-Object {
		if ($_ -match "${season}E(?<n>\d+)") {
		[int]$matches.n
		}
	} |
	Measure-Object -Maximum

	# 2) Default to 0 when there were no matches
	$maxOnDisk  = [int]$numResult.Maximum

	# 3) Now the format operator always has a number
	$epFormatted = "E{0:D3}" -f $maxOnDisk

	# 4) Log to the real $logFile variable
	Write-Log -LogFile $logFile -Message "🔢 Highest on disk: $epFormatted"
    
	# Download queue
    $queue = $videos | Where-Object { [int]$_.playlist_index -gt $maxOnDisk }
    Write-Log -LogFile $logFile -Message "✅ To download: $($queue.Count) episodes"

    # 4) Loop using playlist_index instead of position
foreach ($vid in $queue) {
    $idx  = [int]$vid.playlist_index
    $tag  = $idx.ToString('D2')
    $safe = ($vid.title -replace '[\/:*?"<>|]','').Trim()
    $base = "$show-${season}E${tag} - $safe [$($vid.id)]"
    $file = Join-Path $odir "$base.mp4"

    if (Download-Video -Url $vid.url `
                       -OutputFile $file `
                       -ArchiveFile $archFile `
                       -LogPath $logFile) {


            Test-Compatibility -FilePath $file `
                               -LogPath $logFile `
                               -CompatLog $compFile

            $metaJson = & yt-dlp.exe $vid.url --dump-json | ConvertFrom-Json
            Tag-MediaMetadata -FilePath $file `
                              -VideoMetadata $metaJson `
                              -LogPath $logFile
        }
    }

# Subtitle recovery pass
    Write-Log -LogFile $logFile -Message "`n🛠️ Subtitle recovery pass starting..."
    Get-ChildItem $odir -Filter '*.mp4' | ForEach-Object {
        Recover-Subtitles `
            -BaseName    $_.BaseName `
            -OutputDir   $odir `
            -LogPath     $logFile `
            -FailLogPath $subFailLog
    }
    Write-Log -LogFile $logFile -Message "🔚 Subtitle recovery pass complete!"
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
    },
	@{
        Url       = 'https://www.youtube.com/playlist?list=PLeImKFecYFCxFiDzdK_yWcC8KmkayBwmn'
        OutputDir = "E:\Plex Server\TV Programs\Smosh Games (2011)\Season 01"
        ShowName  = 'Shayne Guesses'
        SeasonTag = 'S01'
        LogDir    = "E:\Plex Server\TV Programs\Smosh Games (2011)\Logs"
    },
	@{
        Url       = 'https://www.youtube.com/playlist?list=PLeImKFecYFCwD2jmfCh9jMaN4LW6kJ9yE'
        OutputDir = "E:\Plex Server\TV Programs\Smosh Games (2011)\Season 02"
        ShowName  = 'Ultimate Werewolf'
        SeasonTag = 'S02'
        LogDir    = "E:\Plex Server\TV Programs\Smosh Games (2011)\Logs"
    },
	@{
        Url       = 'https://www.youtube.com/playlist?list=PLeImKFecYFCzND2l_ZhAwI9WGNIzELt5g'
        OutputDir = "E:\Plex Server\TV Programs\Smosh Games (2011)\Season 03"
        ShowName  = 'Smosh Dungeons and Dragons'
        SeasonTag = 'S03'
        LogDir    = "E:\Plex Server\TV Programs\Smosh Games (2011)\Logs"
    },
	@{
        Url       = 'https://www.youtube.com/playlist?list=PLeImKFecYFCy5ZfKcR7i7VWLI4D1T62k4'
        OutputDir = "E:\Plex Server\TV Programs\Smosh Games (2011)\Season 04"
        ShowName  = 'Smosh Games Marathons'
        SeasonTag = 'S04'
        LogDir    = "E:\Plex Server\TV Programs\Smosh Games (2011)\Logs"
    }
)
# ========================================================================
# REGION: Begin Sync
# ========================================================================
# Define helper first
function Open-LogUntilFinish {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]   $LogPath,
        [Parameter()][string[]]          $FinishPattern = @(
                                            '🔚 Finished sync:'
                                            '🔚 Subtitle recovery pass complete!'
                                         )
    )

    # escape each literal for regex and join with |
    $escaped     = $FinishPattern | ForEach-Object { [regex]::Escape($_) }
    $finishRegex = $escaped -join '|'

    # build the inline script—use backtick to escape $_
    $script = @"
Get-Content -Path '$LogPath' -Wait |
  ForEach-Object {
    Write-Host `$_
    if (`$_ -match '$finishRegex') {
      exit
    }
  }
"@

    # encode to avoid any quoting hell
    $bytes          = [Text.Encoding]::Unicode.GetBytes($script)
    $encodedCommand = [Convert]::ToBase64String($bytes)

    # launch new window with proper commas
    Start-Process powershell -ArgumentList @(
        '-NoProfile',
        '-NoLogo',
        '-WindowStyle', 'Normal',
        '-EncodedCommand', $encodedCommand
    )
}


# Kick off each playlist
foreach ($cfg in $playlists) {
    $logPath = Join-Path $cfg.LogDir "$($cfg.ShowName)-$($cfg.SeasonTag).log"

    if (Test-Path $logPath) {
        Open-LogUntilFinish -LogPath $logPath
    }

    Sync-Playlist -Config $cfg
}