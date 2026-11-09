#Requires -Version 5.1
<#
.SYNOPSIS
  Izmir ArcGIS katmanlarini resultOffset ile SAYFALAYARAK eksiksiz indirir.
  maxRecordCount=1000 oldugu icin tek istek yetmez; bu script tum sayfalari birlestirir.
  Ornek 50'lik dosyalar ise yaramaz.
#>

$ErrorActionPreference = 'Stop'
$Arc = 'https://kentrehberi.izmir.bel.tr/arcgis/rest/services'
$Out = Join-Path $env:USERPROFILE 'Desktop\IZMIR_TAM'
$Page = 1000
$SleepMs = 800
New-Item -ItemType Directory -Force -Path $Out | Out-Null

$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) IzmirFullLayerDownloader/1.0'
$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession

function Get-RawJson([string]$Url) {
    $r = Invoke-WebRequest -Uri $Url -WebSession $session -UserAgent $UA -UseBasicParsing -TimeoutSec 600
    return $r.Content
}

function Get-LayerCount([string]$QueryBase) {
    $raw = Get-RawJson "$QueryBase`?where=1%3D1&returnCountOnly=true&f=json"
    $j = $raw | ConvertFrom-Json
    if ($j.error) { throw ($j.error | ConvertTo-Json -Compress) }
    return [int]$j.count
}

function Save-FullLayer {
    param(
        [string]$Name,
        [string]$MapServer,
        [int]$LayerId,
        [string]$OutFile
    )

    $query = "$MapServer/$LayerId/query"
    Write-Host "`n=== $Name (layer $LayerId) ===" -ForegroundColor Cyan

    $total = Get-LayerCount $query
    Write-Host "Toplam kayit (sunucu count): $total"

    $tmp = "$OutFile.partial"
    if (Test-Path $tmp) { Remove-Item $tmp -Force }
    if (Test-Path $OutFile) { Remove-Item $OutFile -Force }

    $utf8 = New-Object System.Text.UTF8Encoding $false
    $sw = New-Object System.IO.StreamWriter($tmp, $false, $utf8)
    try {
        $metaRaw = Get-RawJson "$MapServer/$LayerId`?f=json"
        $meta = $metaRaw | ConvertFrom-Json
        $srJson = 'null'
        if ($meta.extent -and $meta.extent.spatialReference) {
            $srJson = ($meta.extent.spatialReference | ConvertTo-Json -Compress -Depth 8)
        }

        $sw.Write('{')
        $sw.Write('"layerName":' + ($Name | ConvertTo-Json -Compress) + ',')
        $sw.Write('"layerId":' + $LayerId + ',')
        $sw.Write('"source":' + ($query | ConvertTo-Json -Compress) + ',')
        $sw.Write('"expectedCount":' + $total + ',')
        $sw.Write('"spatialReference":' + $srJson + ',')
        $sw.Write('"features":[')

        $offset = 0
        $got = 0
        $pageNo = 0
        $first = $true

        while ($offset -lt $total) {
            $pageNo++
            $url = "$query`?where=1%3D1&outFields=*&returnGeometry=true&resultOffset=$offset&resultRecordCount=$Page&orderByFields=OBJECTID ASC&f=json"
            $try = 0
            while ($true) {
                $try++
                try {
                    $raw = Get-RawJson $url
                    break
                }
                catch {
                    if ($try -ge 2) { throw }
                    Write-Host '  gecici hata, 1 ek deneme...' -ForegroundColor Yellow
                    Start-Sleep -Seconds 4
                }
            }

            # features dizisini ham JSON'dan kes (ConvertTo-Json bellek patlamasin)
            if ($raw -match '"error"\s*:') {
                $probe = $raw | ConvertFrom-Json
                if ($probe.error -and -not $probe.features) {
                    throw ('query error: ' + ($probe.error | ConvertTo-Json -Compress))
                }
            }

            $idx = $raw.IndexOf('"features"')
            if ($idx -lt 0) { throw 'features alani yok' }
            $lb = $raw.IndexOf('[', $idx)
            $rb = $raw.LastIndexOf(']')
            if ($lb -lt 0 -or $rb -le $lb) { throw 'features dizisi parse edilemedi' }
            $inner = $raw.Substring($lb + 1, $rb - $lb - 1).Trim()

            $exceeded = $raw -match '"exceededTransferLimit"\s*:\s*true'

            if ([string]::IsNullOrWhiteSpace($inner)) {
                Write-Host ("  sayfa {0}: bos; duruluyor" -f $pageNo) -ForegroundColor Yellow
                break
            }

            # sayfadaki feature sayisi
            $pageObj = $raw | ConvertFrom-Json
            $n = @($pageObj.features).Count
            if ($n -eq 0) { break }

            if (-not $first) { $sw.Write(',') }
            $sw.Write($inner)
            $first = $false
            $got += $n
            $offset += $n

            Write-Host ("  sayfa {0}: +{1} (biriken {2}/{3}) exceeded={4}" -f $pageNo, $n, $got, $total, $exceeded)

            if ($n -lt $Page -and -not $exceeded) { break }
            Start-Sleep -Milliseconds $SleepMs
        }

        $sw.Write('],')
        $sw.Write('"featureCount":' + $got + ',')
        $complete = ($got -eq $total)
        $sw.Write('"complete":' + ($(if ($complete) { 'true' } else { 'false' })))
        $sw.Write('}')
    }
    finally {
        $sw.Close()
    }

    if ($got -ne $total) {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        throw ("EKSIK: beklenen=$total gelen=$got — dosya yazilmadi")
    }

    Move-Item -Force $tmp $OutFile
    $len = (Get-Item $OutFile).Length
    Write-Host ("TAM OK {0} features={1} bytes={2}" -f (Split-Path $OutFile -Leaf), $got, $len) -ForegroundColor Green
}

$Hybrid = "$Arc/Rehber/CbsRehberGeoHybrid/MapServer"
$Gri    = "$Arc/Rehber/CbsRehberGeoGri/MapServer"

$jobs = @(
    @{ Name='Yol_Anayol';    Map=$Hybrid; Id=2;   File='FULL_CbsRehberGeoHybrid_Yol_Anayol_L2.json' }
    @{ Name='YolOrtaHatti'; Map=$Hybrid; Id=27;  File='FULL_CbsRehberGeoHybrid_YolOrtaHatti_L27.json' }
    @{ Name='Yapi';         Map=$Hybrid; Id=94;  File='FULL_CbsRehberGeoHybrid_Yapi_L94.json' }
    @{ Name='Ilce_Alani';    Map=$Gri;    Id=155; File='FULL_CbsRehberGeoGri_Ilce_Alani_L155.json' }
    @{ Name='IL_Alani';      Map=$Gri;    Id=151; File='FULL_CbsRehberGeoGri_IL_Alani_L151.json' }
    @{ Name='Mahalle';       Map=$Gri;    Id=157; File='FULL_CbsRehberGeoGri_Mahalle_L157.json' }
    @{ Name='Adalar';        Map=$Gri;    Id=189; File='FULL_CbsRehberGeoGri_Adalar_L189.json' }
)

Write-Host "Cikti: $Out"
Write-Host "UYARI: YolOrtaHatti ~230K, Yapi ~1.1M — saatler surebilir. Mevcut TAM dosyalar atlanir." -ForegroundColor Yellow

foreach ($job in $jobs) {
    $path = Join-Path $Out $job.File
    if ((Test-Path $path) -and ((Get-Item $path).Length -gt 1000)) {
        $probe = Get-Content -Path $path -TotalCount 1 -ErrorAction SilentlyContinue
        # complete bayragi dosya sonunda; boyut + isim ile skip
        Write-Host "SKIP (dosya var): $($job.File) — silersen yeniden ceker" -ForegroundColor DarkGray
        continue
    }
    try {
        Save-FullLayer -Name $job.Name -MapServer $job.Map -LayerId $job.Id -OutFile $path
    }
    catch {
        Write-Host ("FAIL {0}: {1}" -f $job.Name, $_.Exception.Message) -ForegroundColor Red
        Remove-Item "$path.partial" -Force -ErrorAction SilentlyContinue
        Remove-Item $path -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`nDOSYALAR:" -ForegroundColor Yellow
Get-ChildItem $Out -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object Name, Length | Format-Table

Write-Host @"

NOTLAR
- API proxy (ibbYollar/planlar/pafta/mulkiyet) query HTTP 500; ArcGIS Hybrid/Gri yol-yapi yukarida.
- Export PNG vektor degildir.
- 2021 ortofoto tam il tek dosyada maxImage yuzunden mumkun degil.
"@
