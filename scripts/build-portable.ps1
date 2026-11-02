[CmdletBinding()]
param(
    [string]$PackageRoot = '',
    [string]$WorkDir = '',
    [string]$OutDir = '',
    [string]$BuildPython = ''
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([String]::IsNullOrEmpty($PackageRoot)) { $PackageRoot = Join-Path $here '..' }
if ([String]::IsNullOrEmpty($WorkDir)) { $WorkDir = Join-Path $here '..\..\_portable-build' }
if ([String]::IsNullOrEmpty($OutDir)) { $OutDir = Join-Path $here '..\..\dist' }
if ([String]::IsNullOrEmpty($BuildPython)) { $BuildPython = 'python' }
if (-not (Test-Path $BuildPython)) {
    $buildCmd = Get-Command $BuildPython -ErrorAction Stop
    $BuildPython = $buildCmd.Source
}
$pyVersion = '3.13.14'
$pgVersion = '17.8'
$pyUrl = "https://www.python.org/ftp/python/$pyVersion/python-$pyVersion-embed-amd64.zip"
$pgUrl = "https://get.enterprisedb.com/postgresql/postgresql-$pgVersion-1-windows-x64-binaries.zip"
$pySha = '90b4e5b9898b72d744650524bff92377c367f44bd5fbd09e3148656c080ad907'
$pgSha = '46e7e920318fec3b37bb8490f249c5639bf18f4963b2938010588b81cc5ef03a'
$stage = Join-Path $WorkDir 'stage'
$app = Join-Path $stage 'Jianji'
$dl = Join-Path $WorkDir 'downloads'

if (-not (Test-Path (Join-Path $PackageRoot 'backend\app\main.py'))) {
    throw "部署仓库不存在或未同步：$PackageRoot"
}
if (-not (Test-Path (Join-Path $PackageRoot 'frontend\dist\index.html'))) {
    throw "缺少 frontend/dist，请先构建前端：$PackageRoot"
}
if (-not (Test-Path $BuildPython)) {
    throw "构建 Python 不存在：$BuildPython"
}
& $BuildPython -c "import sys; assert sys.version_info[:2] == (3, 13), sys.version" | Out-Null
if ($LASTEXITCODE -ne 0) { throw '构建 Python 必须是 3.13' }

New-Item -ItemType Directory -Force -Path $dl, $app | Out-Null
function Get-Archive([string]$url, [string]$dest, [string]$sha) {
    if (-not (Test-Path $dest)) {
        Write-Host "[portable] download $url"
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $dest
    }
    $actual = (Get-FileHash $dest -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $sha) {
        throw "SHA256 不匹配：$dest`n期望 $sha`n实际 $actual"
    }
}
Get-Archive $pyUrl (Join-Path $dl 'python-embed.zip') $pySha
Get-Archive $pgUrl (Join-Path $dl 'pgsql.zip') $pgSha

Remove-Item $app -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $app | Out-Null
robocopy $PackageRoot $app /E /XD "$PackageRoot\.git" "$PackageRoot\data" "$PackageRoot\runtime" __pycache__ /XF *.pyc | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy 失败：$LASTEXITCODE" }

# The deployment repo may not have this helper yet (Task 6 syncs it).
$portableDb = Join-Path $here '..\backend\scripts\portable_db.py'
if (-not (Test-Path $portableDb)) { throw "缺少 portable_db.py：$portableDb" }
Copy-Item $portableDb (Join-Path $app 'backend\scripts\portable_db.py') -Force

# Defensive cleanup: a previous smoke run or a locked file can leave local state
# in the staging tree even when robocopy excluded it.
Remove-Item (Join-Path $app 'data') -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $app 'runtime') -Recurse -Force -ErrorAction SilentlyContinue

$pyDir = Join-Path $app 'runtime\python'
Expand-Archive -LiteralPath (Join-Path $dl 'python-embed.zip') -DestinationPath $pyDir -Force
$pth = Join-Path $pyDir 'python313._pth'
$lines = @('python313.zip', '.', 'Lib\site-packages', 'import site')
[System.IO.File]::WriteAllLines($pth, $lines, (New-Object System.Text.UTF8Encoding $false))
New-Item -ItemType Directory -Force -Path (Join-Path $pyDir 'Lib\site-packages') | Out-Null

& $BuildPython -m pip install --upgrade --target (Join-Path $pyDir 'Lib\site-packages') `
    --no-warn-script-location -r (Join-Path $app 'backend\requirements.lock.txt')
if ($LASTEXITCODE -ne 0) { throw '安装后端依赖失败' }

$pgDir = Join-Path $app 'runtime\pgsql'
$pgExtract = Join-Path $WorkDir 'pgsql-extract'
Remove-Item $pgExtract -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive -LiteralPath (Join-Path $dl 'pgsql.zip') -DestinationPath $pgExtract -Force
New-Item -ItemType Directory -Force -Path $pgDir | Out-Null
Copy-Item (Join-Path $pgExtract 'pgsql\bin') (Join-Path $pgDir 'bin') -Recurse -Force
Copy-Item (Join-Path $pgExtract 'pgsql\lib') (Join-Path $pgDir 'lib') -Recurse -Force
Copy-Item (Join-Path $pgExtract 'pgsql\share') (Join-Path $pgDir 'share') -Recurse -Force
Remove-Item (Join-Path $pgDir 'bin\stackbuilder.exe') -Force -ErrorAction SilentlyContinue
foreach ($dll in 'VCRUNTIME140.dll', 'VCRUNTIME140_1.dll', 'MSVCP140.dll') {
    $src = Join-Path $env:SystemRoot "System32\$dll"
    if (-not (Test-Path $src)) { throw "缺少 VC 运行库：$src" }
    Copy-Item $src (Join-Path $pgDir 'bin') -Force
}
Copy-Item (Join-Path $here 'portable\POSTGRESQL-COPYRIGHT.txt') (Join-Path $pgDir 'COPYRIGHT') -Force
Copy-Item (Join-Path $here 'portable\VC-RUNTIME-NOTICE.txt') (Join-Path $pgDir 'VC_RUNTIME_NOTICE.txt') -Force

$version = (Get-Content (Join-Path $app 'VERSION') -Raw).Trim()
$manifest = [ordered]@{
    built_at = (Get-Date).ToString('s')
    version = $version
    python = @{ version = $pyVersion; archive_sha256 = $pySha; url = $pyUrl }
    postgresql = @{ version = $pgVersion; archive_sha256 = $pgSha; url = $pgUrl }
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $app 'runtime\MANIFEST.json') -Encoding UTF8

& (Join-Path $here 'verify-portable.ps1') -Stage $app
if ($LASTEXITCODE -ne 0) { throw '便携运行时 smoke 验证失败' }

# The smoke run creates __pycache__ inside the staged backend; never ship it.
Get-ChildItem $app -Recurse -Directory -Filter '__pycache__' -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force
Get-ChildItem $app -Recurse -File -Filter '*.pyc' -ErrorAction SilentlyContinue |
    Remove-Item -Force

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$zip = Join-Path $OutDir "Jianji-$version-portable.zip"
Remove-Item $zip -Force -ErrorAction SilentlyContinue
Compress-Archive -Path $app -DestinationPath $zip -CompressionLevel Optimal -Force
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
Set-Content -Path ($zip + '.sha256') -Value "$hash  $(Split-Path -Leaf $zip)" -Encoding ASCII
Write-Host "[portable] OK: $zip"
