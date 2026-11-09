# --- AYARLAR ---
$Api = "https://kentrehberi.izmir.bel.tr"
$Arc = "https://kentrehberi.izmir.bel.tr/arcgis/rest/services"
$Out = "$env:USERPROFILE\Desktop\IZMIR_TEST"
New-Item -ItemType Directory -Force -Path $Out | Out-Null

Write-Host "`nINDIRME BASLIYOR..." -ForegroundColor Cyan

function Save-Ok($Path, $Bytes) {
    if (-not (Test-Path $Path)) { throw "Dosya yazilmadi: $Path" }
    $len = (Get-Item $Path).Length
    if ($len -le 0) { throw "Bos dosya: $Path" }
    Write-Host ("OK  {0} ({1} bytes)" -f (Split-Path $Path -Leaf), $len) -ForegroundColor Green
}

# 1) ibbYollar Metadata  (NOT: ibbYolars DEGIL — ibbYollar)
try {
    $m = Invoke-RestMethod "$Api/api/map/services/ibbYollar/MapServer?f=pjson"
    if ($m.ok -eq $false) { throw ($m.error | ConvertTo-Json -Compress) }
    $m | ConvertTo-Json -Depth 8 | Out-File "$Out\ibbYollar_metadata.json" -Encoding utf8
    Save-Ok "$Out\ibbYollar_metadata.json"
    Write-Host ("     mapName={0} capabilities={1}" -f $m.mapName, $m.capabilities)
}
catch {
    Write-Host ("FAIL ibbYollar metadata: {0}" -f $_.Exception.Message) -ForegroundColor Red
}

# 2) ibbYollar Export PNG  (export gorseldir; vektor degildir)
try {
    Invoke-WebRequest `
        "$Api/api/map/services/ibbYollar/MapServer/export?bbox=512000,4254000,513000,4255000&size=800,600&format=png&f=image&transparent=true" `
        -OutFile "$Out\ibbYollar_export.png"
    Save-Ok "$Out\ibbYollar_export.png"
}
catch {
    Write-Host ("FAIL ibbYollar export: {0}" -f $_.Exception.Message) -ForegroundColor Red
}

# 3) ArcGIS Raster 2021 (kucuk bbox ornek JPG; tam il kapsami degil)
try {
    Invoke-WebRequest `
        "$Arc/Raster/IzmirRaster2021/ImageServer/exportImage?bbox=512000,4254000,513000,4255000&bboxSR=&imageSR=&size=800,600&format=jpg&f=image" `
        -OutFile "$Out\raster2021_sample.jpg"
    Save-Ok "$Out\raster2021_sample.jpg"
}
catch {
    Write-Host ("FAIL IzmirRaster2021: {0}" -f $_.Exception.Message) -ForegroundColor Red
}

# 4) ArcGIS Hybrid Yol_Anayol (Layer 2) — ornek 50 kayit
try {
    $q = Invoke-RestMethod "$Arc/Rehber/CbsRehberGeoHybrid/MapServer/2/query?where=1%3D1&outFields=*&returnGeometry=true&resultRecordCount=50&f=json"
    if ($q.error) { throw ($q.error | ConvertTo-Json -Compress) }
    $n = @($q.features).Count
    $q | ConvertTo-Json -Depth 8 | Out-File "$Out\Hybrid_Yol_Anayol_sample50.json" -Encoding utf8
    Save-Ok "$Out\Hybrid_Yol_Anayol_sample50.json"
    Write-Host ("     features={0} exceededTransferLimit={1}" -f $n, $q.exceededTransferLimit)
}
catch {
    Write-Host ("FAIL Hybrid Yol_Anayol: {0}" -f $_.Exception.Message) -ForegroundColor Red
}

# 5) ArcGIS Gri YolOrtaHatti (Layer 43) — ornek 50 kayit
try {
    $g = Invoke-RestMethod "$Arc/Rehber/CbsRehberGeoGri/MapServer/43/query?where=1%3D1&outFields=*&returnGeometry=true&resultRecordCount=50&f=json"
    if ($g.error) { throw ($g.error | ConvertTo-Json -Compress) }
    $n = @($g.features).Count
    $g | ConvertTo-Json -Depth 8 | Out-File "$Out\Gri_YolOrtaHatti_sample50.json" -Encoding utf8
    Save-Ok "$Out\Gri_YolOrtaHatti_sample50.json"
    Write-Host ("     features={0} exceededTransferLimit={1}" -f $n, $g.exceededTransferLimit)
}
catch {
    Write-Host ("FAIL Gri YolOrtaHatti: {0}" -f $_.Exception.Message) -ForegroundColor Red
}

Write-Host "`nDOSYALAR:" -ForegroundColor Yellow
Get-ChildItem $Out | Select-Object Name, Length | Format-Table
