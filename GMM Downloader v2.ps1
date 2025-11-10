# ========================================================================
# REGION: Settings & Mode Toggles
# ========================================================================
$EnableParallelDownload = $true
$UrlDumpFilePath        = "C:\Scripts\gmm_urls.txt"
$ParallelOutDir         = "D:\Media\GMM"
$CookiePath             = "C:\Users\chetm\OneDrive\Documents\Scripts\yt cookies\yt-cookies.txt"

# ========================================================================
# REGION: Logging Utility
# ========================================================================
function Write-Log {
    param([string] $LogFile, [string] $Message)
    if (-not (Test-Path $LogFile)) {
        New-Item -ItemType File -Force -Path $LogFile | Out-Null
    }
    Add-Content -Path $LogFile -Value "$((Get-Date).ToString('u'))  $Message"
}

# ========================================================================
# REGION: Metadata Tagging
# ========================================================================
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

    $metaArgs = foreach ($kv in $tags.GetEnumerator()) { '-metadata', "$($kv.Key)=$($kv.Value)" }
    $dir  = Split-Path $FilePath -Parent
    $temp = Join-Path $dir "$([IO.Path]::GetFileNameWithoutExtension($FilePath)).temp.mp4"

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
function Sync-Playlist {
    param(
        [string] $PlaylistUrl,
        [string] $OutputDir,
        [string] $LogDir,
        [string] $SeasonTag,
        [string] $ShowName
    )

    New-Item -ItemType Directory -Force -Path $OutputDir, $LogDir | Out-Null
    $LogPath   = Join-Path $LogDir "$ShowName-$SeasonTag.log"
    $Archive   = Join-Path $LogDir "download_archive.txt"
    $CompatLog = Join-Path $LogDir "PlexCompatibilityIssues.log"

    Write-Log -LogFile $LogPath -Message "▶️ Sync start: $ShowName ($SeasonTag)"

    foreach ($tool in 'yt-dlp.exe','ffmpeg.exe','ffprobe.exe') {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw "$tool not found in PATH"
        }
    }

    $pattern = [regex] "${SeasonTag}E(?<num>\d{2})"
    $current = Get-ChildItem -Path $OutputDir -Filter '*.mp4' | ForEach-Object {
        if ($pattern.IsMatch($_.BaseName)) {
            [int]$pattern.Match($_.BaseName).Groups['num'].Value
        }
    }
    $maxOnDisk = ($current | Measure-Object -Maximum).Maximum
    if (-not $maxOnDisk) { $maxOnDisk = 0 }
    Write-Log -LogFile $LogPath -Message "🔢 Highest on disk: E{0:D2}" -f $maxOnDisk

    $raw = & yt-dlp.exe $PlaylistUrl --flat-playlist --print-json 2>&1
    $videos = $raw | ForEach-Object {
        try { $_ | ConvertFrom-Json } catch { $null }
    } | Where-Object { $_ }

    if ($videos.Count -eq 0) {
        Write-Log -LogFile $LogPath -Message "⚠️ Playlist empty — aborting."
        return
    }

    $indexed = $videos | ForEach-Object -Begin { $i = 0 } -Process {
        $i++
        [PSCustomObject]@{
            Position = $i
            Url      = "https://www.youtube.com/watch?v=$($_.id)"
            Title    = $_.title
        }
    }
    $queue = $indexed | Where-Object { $_.Position -gt $maxOnDisk }
    Write-Log -LogFile $LogPath -Message "✅ Episodes to download: $($queue.Count)"
    Add-Content -Path $UrlDumpFilePath -Value ($queue.Url)

    foreach ($v in $queue) {
        $epTag = $v.Position.ToString('D2')
        $safe  = $v.Title -replace '[\\/:*?"<>|]', ''
        $base  = "$ShowName - ${SeasonTag}E${epTag} - $safe"
        $file  = Join-Path $OutputDir "$base.mp4"
        Write-Log -LogFile $LogPath -Message "🚀 E${epTag} → downloading"

        $primary  = "bestvideo[height<=720][vcodec^=avc1]+bestaudio[ext=m4a]"
        $fallback = "bestvideo[height<=1080][vcodec^=avc1]+bestaudio[ext=m4a]"

        try {
            & yt-dlp.exe --cookies $CookiePath --download-archive $Archive -f $primary --merge-output-format mp4 -o $file $v.Url | Out-Null
            Write-Log -LogFile $LogPath -Message "✅ 720p grabbed"
        } catch {
            Write-Log -LogFile $LogPath -Message "⚠️ 720p failed — trying 1080p"
            & yt-dlp.exe --cookies $CookiePath --download-archive $Archive -f $fallback --merge-output-format mp4 -o $file $v.Url | Out-Null
            Write-Log -LogFile $LogPath -Message "✅ 1080p grabbed"
        }

        if (-not (Test-Path $file) -or ((Get-Item $file).Length -lt 5MB)) {
            Write-Log -LogFile $LogPath -Message "❌ Download failed: $base.mp4"
            continue
        }

        Write-Log -LogFile $LogPath -Message "✅ Saved $base.mp4"
        try {
            $vInfo   = & ffprobe.exe -v error -select_streams v:0 -show_entries stream=codec_name,height -of default=nokey=1:noprint_wrappers=1 $file
            $vCodec, $vHeight = $vInfo
            $aCodec = (& ffprobe.exe -v error -select_streams a:0 -show_entries stream=codec_name -of default=nokey=1:noprint_wrappers=1 $file)[0]

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

                $metaJson = & yt-dlp.exe $v.Url --dump-json | ConvertFrom-Json
        Tag-MediaMetadata -FilePath $file -VideoMetadata $metaJson `
                          -LogDir $LogDir -ShowName $ShowName `
                          -SeasonTag $SeasonTag -LogPath $LogPath
        $tagged++
    }

    # Summary
    Write-Log -LogFile $LogPath -Message "`n📊 SUMMARY"
    Write-Log -LogFile $LogPath -Message "Total:     $total"
    Write-Log -LogFile $LogPath -Message "Success:   $success"
    Write-Log -LogFile $LogPath -Message "Tagged:    $tagged"
    Write-Log -LogFile $LogPath -Message "CompatErr: $compatErr"
    Write-Log -LogFile $LogPath -Message "Finished:  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n"
}

# Run parallel batch download if enabled
if ($EnableParallelDownload -and (Test-Path $UrlDumpFilePath)) {
    Invoke-GmmBatchDownload -UrlListPath $UrlDumpFilePath `
                            -Throttle      6 `
                            -CookiePath    $CookiePath `
                            -OutDir        $ParallelOutDir
}