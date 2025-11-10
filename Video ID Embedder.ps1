# Prompt for paths
$videoDir = Read-Host "📁 Enter the full path to your video folder"
$videoDir = $videoDir.Trim('"')
$archivePath = Read-Host "📄 Enter the full path to your archive file"
$archivePath = $archivePath.Trim('"')

# Validate paths
if (-not (Test-Path $videoDir -PathType Container)) {
    Write-Host "❌ Invalid video folder: $videoDir"
    return
}
if (-not (Test-Path $archivePath -PathType Leaf)) {
    Write-Host "❌ Invalid archive file: $archivePath"
    return
}

# Load archive entries
$archiveLines = Get-Content $archivePath | Where-Object { $_ -match '^youtube\s+[a-zA-Z0-9_-]{11}$' }
$videoIds = $archiveLines | ForEach-Object {
    ($_ -split '\s+')[1]
}

# Scan video files
$videos = Get-ChildItem -Path $videoDir -Filter *.mp4

foreach ($vid in $videos) {
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($vid.Name)

    # Skip if already tagged
    if ($baseName -match '\[[a-zA-Z0-9_-]{11}\]$') {
        Write-Host "⏩ Already tagged: $($vid.Name)"
        continue
    }

    # Try to match by episode number (e.g. S01E05)
    if ($baseName -match 'S\d{2}E\d{2}') {
        $episodeTag = $matches[0]
        $matchedId = $null

        foreach ($id in $videoIds) {
            if ($baseName -like "*$episodeTag*") {
                $matchedId = $id
                break
            }
        }

        if ($matchedId) {
            $newName = "$baseName [$matchedId]$($vid.Extension)"
            Rename-Item -Path $vid.FullName -NewName $newName
            Write-Host "✅ Renamed: $($vid.Name) → $newName"
        } else {
            Write-Host "❌ No matching ID found for: $($vid.Name)"
        }
    } else {
        Write-Host "❌ No episode tag found in: $($vid.Name)"
    }
}