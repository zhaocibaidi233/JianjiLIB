[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Stage,
    [string]$PortableDbScript = ''
)

$ErrorActionPreference = 'Stop'
$python = Join-Path $Stage 'runtime\python\python.exe'
$pgBin = Join-Path $Stage 'runtime\pgsql\bin'
$backend = Join-Path $Stage 'backend'
$port = 55439
$apiPort = 55440
$temp = Join-Path $env:TEMP ('jianji-portable-smoke-' + [guid]::NewGuid().ToString('N'))
$data = Join-Path $temp 'pgdata'
$log = Join-Path $temp 'postgresql.log'
$backendOut = Join-Path $temp 'backend.out.log'
$backendErr = Join-Path $temp 'backend.err.log'
if ([String]::IsNullOrEmpty($PortableDbScript)) {
    $PortableDbScript = Join-Path $backend 'scripts\portable_db.py'
}
$oldPath = $env:PATH
$oldPyPath = $env:PYTHONPATH
$oldPass = $env:JIANJI_PG_PASSWORD
$oldUrl = $env:JIANJI_DATABASE_URL
$oldPgBin = $env:JIANJI_PG_BIN
$proc = $null

try {
    if (-not (Test-Path $python)) { throw "缺少 Python：$python" }
    if (-not (Test-Path (Join-Path $pgBin 'postgres.exe'))) { throw "缺少 PostgreSQL：$pgBin" }
    if (-not (Test-Path $PortableDbScript)) { throw "缺少 portable_db.py：$PortableDbScript" }
    New-Item -ItemType Directory -Force -Path $temp | Out-Null
    $env:JIANJI_PG_PASSWORD = [guid]::NewGuid().ToString('N')
    $env:PATH = "$pgBin;$oldPath"
    $env:PYTHONPATH = $backend
    $env:PYTHONIOENCODING = 'utf-8'
    $env:JIANJI_PG_BIN = $pgBin

    & $python $PortableDbScript ensure --data-dir $data --port $port --log $log
    if ($LASTEXITCODE -ne 0) { throw 'portable_db.py ensure 失败' }

    $env:JIANJI_DATABASE_URL = "postgresql+psycopg2://postgres:$($env:JIANJI_PG_PASSWORD)@127.0.0.1:$port/jianji"
    & $python (Join-Path $backend 'scripts\init_db.py')
    if ($LASTEXITCODE -ne 0) { throw 'init_db.py 失败' }

    $proc = Start-Process -FilePath $python `
        -ArgumentList @('-m', 'uvicorn', 'app.main:app', '--host', '127.0.0.1', '--port', $apiPort) `
        -WorkingDirectory $backend -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $backendOut -RedirectStandardError $backendErr
    $ok = $false
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path $curl)) { $curl = 'curl.exe' }
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        try {
            $raw = & $curl --noproxy '*' -s -m 3 "http://127.0.0.1:$apiPort/api/health"
            if ($LASTEXITCODE -ne 0) { continue }
            $health = $raw | ConvertFrom-Json
            if ($health.status -eq 'ok' -and $health.db -eq $true -and $health.schema_ok -eq $true) {
                $ok = $true
                break
            }
        } catch { }
    }
    if (-not $ok) { throw '后端健康检查未通过' }
    Write-Host '[portable] smoke OK'
}
finally {
    if ($proc -and -not $proc.HasExited) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        $proc.WaitForExit(5000) | Out-Null
    }
    if (Test-Path $PortableDbScript) {
        & $python $PortableDbScript stop --data-dir $data --port $port --log $log 2>$null | Out-Null
    }
    $env:PATH = $oldPath
    $env:PYTHONPATH = $oldPyPath
    $env:JIANJI_PG_PASSWORD = $oldPass
    $env:JIANJI_DATABASE_URL = $oldUrl
    $env:JIANJI_PG_BIN = $oldPgBin
    Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
}
