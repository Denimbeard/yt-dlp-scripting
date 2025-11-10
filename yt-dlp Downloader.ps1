function Download-YouTubeVideo {
    param(
        [string]$OutputDir = 'C:\Users\editor\Downloads',
        [string]$Format   = 'bestvideo+bestaudio/best',
		[string]$SubLang ='en'
    )

    # 1. Prompt for the URL
    $Url = Read-Host 'Enter the YouTube URL'

    # 2. Download best video+audio and merge into MP4
    & yt-dlp.exe `
        -f $Format `
        --merge-output-format mp4 `
        -P $OutputDir `
		--add-metadata `
		--embed-thumbnail `
		--embed-subs `
        $Url

    $exitCode = $LASTEXITCODE

    # 3. Open folder on success
    if ($exitCode -eq 0) {
        Write-Host "✅ Download complete. Opening folder…"
        Start-Process explorer.exe $OutputDir
    }
    else {
        Write-Host "❌ Download failed with exit code $exitCode."
    }
}

# Run it:

Download-YouTubeVideo
