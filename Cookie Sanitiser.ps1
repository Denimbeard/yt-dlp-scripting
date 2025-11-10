$cookiePath = "C:\Users\chetm\OneDrive\Documents\Scripts\yt cookies\yt-cookies.txt"

$cleanLines = Get-Content $cookiePath | Where-Object {
    ($_ -match "^\S+\t(TRUE|FALSE)\t\S+\t(TRUE|FALSE)\t\d+\t\S+\t\S+$")
}

Set-Content -Path $cookiePath -Value $cleanLines -Encoding Ascii