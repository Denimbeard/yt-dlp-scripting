function Sync-Playlist {
    param(
        [string]$PlaylistUrl = "https://www.youtube.com/playlist?list=PLJ49NV73ttrucP6jJ1gjSqHmhlmvkdZuf",
        [string]$OutputDir = "E:\Plex Server\TV Programs\GMM Will It (2008)\Season 01",
        [string]$LogDir = "E:\Plex Server\TV Programs\GMM Will It (2008)\Logs",
        [string]$Format = "bestvideo[height<=720]+bestaudio/best",
        [string]$SubLang = "en"
    )

    $LogPath     = Join-Path $LogDir "sync-log.txt"
    $ArchivePath = Join-Path $LogDir "archive.txt"
    $Timestamp   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $LogPath -Value "`n[$Timestamp] ➤ Starting sync..."

    try {
        & yt-dlp.exe `
            -f $Format `
            --merge-output-format mp4 `
            -P $OutputDir `
            --add-metadata `
            --embed-thumbnail `
            --embed-subs `
            --sub-lang $SubLang `
            --yes-playlist `
            --download-archive $ArchivePath `
            --output "GMM Will It - S01E%(playlist_index)02d - %(title)s.%(ext)s" `
            $PlaylistUrl

        if ($LASTEXITCODE -eq 0) {
            Add-Content -Path $LogPath -Value "✅ Sync completed successfully at $(Get-Date -Format 'HH:mm:ss')"
        } 
		else {
            Add-Content -Path $LogPath -Value "❌ yt-dlp exited with code $LASTEXITCODE"
			 }
		}
    catch {
        Add-Content -Path $LogPath -Value "🚨 Exception during sync: $_"
    }
}
Sync-Playlist