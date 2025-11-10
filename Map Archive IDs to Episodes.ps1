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

# Load archive video IDs
$archiveLines = Get-Content $archivePath | Where-Object { $_ -match '^youtube\s+[a-zA-Z0-9_-]{11}$' }
$videoIds = $archiveLines | ForEach-Object { ($_ -split '\s+')[1] }

# Get sorted video files
$sortedVideos = Get-ChildItem -Path $videoDir -Filter *.mp4 | Sort-Object {
    if ($_.Name -match 'S(\d{2})E(\d{2})') {
        [int]$matches[1] * 100 + [int]$matches[2]
    } else {
        $_.Name
    }
}

# Apply video IDs in order
$i = 0
foreach ($vid in $sortedVideos) {
    $originalName = $vid.Name
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($originalName)

    # Strip existing [ID] if present
    $cleanBase = $baseName -replace '\s*\[[a-zA-Z0-9_-]{11}\]$', ''
    $oldName = "$cleanBase$($vid.Extension)"
    $oldPath = Join-Path $videoDir $oldName

    if ($i -lt $videoIds.Count) {
        $id = $videoIds[$i]
        $newName = "$cleanBase [$id]$($vid.Extension)"
        $newPath = Join-Path $videoDir $newName

        if (Test-Path $oldPath) {
            Rename-Item -Path $oldPath -NewName $newName
            Write-Host "✅ Retagged: $oldName → $newName"
        } else {
            Write-Host "⚠️ Skipped: $oldName not found (may have been renamed already)"
        }
    } else {
        Write-Host "❌ Not enough video IDs for: $oldName"
    }

    $i++
}
