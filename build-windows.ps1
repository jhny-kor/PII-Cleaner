[CmdletBinding()]
param(
    [string]$PythonExe = "",
    [string]$InnoSetupExe = "",
    [string]$KordocRoot = "",
    [string]$NodeRoot = "",
    [string]$LibreOfficeRoot = ""
)

$ErrorActionPreference = "Stop"
$ProjectRoot = $PSScriptRoot
$BuildRoot = Join-Path $ProjectRoot "build"
$VenvRoot = Join-Path $BuildRoot ".venv"
$PyInstallerWork = Join-Path $BuildRoot "w"
$PyInstallerDist = Join-Path $BuildRoot "p"
$InstallerOutputDir = Join-Path $ProjectRoot "dist"
$Requirements = Join-Path $ProjectRoot "requirements.txt"
$EntryPoint = Join-Path $ProjectRoot "app\main.py"
$InstallerScript = Join-Path $ProjectRoot "installer\PII-Cleaner.iss"
$ProjectLicense = Join-Path $ProjectRoot "LICENSE"
$ProjectNotice = Join-Path $ProjectRoot "NOTICE"
$ThirdPartyNotices = Join-Path $ProjectRoot "THIRD_PARTY_NOTICES.md"
$DocumentRuntimeVerifier = Join-Path $ProjectRoot "tools\verify-kordoc-runtime.mjs"
$AppIcon = Join-Path $ProjectRoot "resources\icons\branding\pii-cleaner-icon.ico"
$BundledModelPath = Join-Path $ProjectRoot "models\schift-ko-pii-v7"
$DefaultKordocRoot = Join-Path $ProjectRoot "vendor\kordoc-runtime"
$DefaultNodeRoot = Join-Path $ProjectRoot "vendor\node"
$DefaultLibreOfficeRoot = Join-Path $ProjectRoot "vendor\libreoffice"

function Test-PythonRuntime {
    param(
        [string]$Command,
        [string[]]$Prefix = @()
    )
    & $Command @Prefix -c "import sys; assert sys.version_info >= (3, 10) and sys.maxsize > 2**32" 1>$null 2>$null
    return $LASTEXITCODE -eq 0
}

function Get-PythonApplications {
    param([string[]]$Names)
    $paths = foreach ($name in $Names) {
        Get-Command -Name $name -CommandType Application -All -ErrorAction SilentlyContinue |
            ForEach-Object {
                if ($_.Path) { $_.Path } elseif ($_.Source) { $_.Source }
            }
    }
    return @($paths | Where-Object { $_ } | Select-Object -Unique)
}

function Resolve-Python {
    if ($PythonExe) {
        $candidate = if (Test-Path -LiteralPath $PythonExe -PathType Leaf) {
            (Resolve-Path -LiteralPath $PythonExe).Path
        } else {
            @(Get-PythonApplications @($PythonExe) | Select-Object -First 1)
        }
        if (-not $candidate) {
            throw "지정한 Python 실행 파일을 찾지 못했습니다: $PythonExe"
        }
        $script:PythonArguments = @()
        if (-not (Test-PythonRuntime -Command $candidate)) {
            throw "지정한 Python은 64-bit Python 3.10 이상이 아닙니다: $candidate"
        }
        return $candidate
    }
    foreach ($launcher in (Get-PythonApplications @("py.exe", "py"))) {
        if (Test-PythonRuntime -Command $launcher -Prefix @("-3")) {
            $script:PythonArguments = @("-3")
            return $launcher
        }
    }
    foreach ($python in (Get-PythonApplications @("python.exe", "python", "python3.exe", "python3"))) {
        if (Test-PythonRuntime -Command $python) {
            $script:PythonArguments = @()
            return $python
        }
    }
    throw "64-bit Python 3.10 이상을 찾지 못했습니다. 'python -V'를 확인하거나 -PythonExe로 python.exe 경로를 지정해주세요."
}

function Invoke-Python {
    param([string[]]$Arguments)
    & $script:PythonCommand @script:PythonArguments @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Python 명령이 실패했습니다: $Arguments" }
}

function Resolve-Iscc {
    if ($InnoSetupExe) { return $InnoSetupExe }
    $command = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    foreach ($candidate in @(
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
    )) {
        if ($candidate -and (Test-Path $candidate)) { return $candidate }
    }
    throw "Inno Setup 6의 ISCC.exe를 찾지 못했습니다. 설치하거나 -InnoSetupExe로 경로를 지정해주세요."
}

function Resolve-RequiredDirectory {
    param(
        [string]$ExplicitPath,
        [string]$EnvironmentName,
        [string]$Label,
        [string]$DefaultPath
    )
    $candidate = if ($ExplicitPath) {
        $ExplicitPath
    } elseif ([Environment]::GetEnvironmentVariable($EnvironmentName)) {
        [Environment]::GetEnvironmentVariable($EnvironmentName)
    } else {
        $DefaultPath
    }
    if (-not $candidate) {
        throw "$Label 경로가 필요합니다. -$Label, $EnvironmentName 또는 기본 vendor 경로를 확인해주세요."
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Container)) {
        throw "$Label 폴더를 찾지 못했습니다: $candidate"
    }
    return (Resolve-Path -LiteralPath $candidate).Path
}

function Assert-DocumentRuntimes {
    $resolvedKordocRoot = Resolve-RequiredDirectory $KordocRoot "PII_CLEANER_KORDOC_ROOT" "KordocRoot" $DefaultKordocRoot
    $resolvedNodeRoot = Resolve-RequiredDirectory $NodeRoot "PII_CLEANER_NODE_ROOT" "NodeRoot" $DefaultNodeRoot
    $resolvedLibreOfficeRoot = Resolve-RequiredDirectory $LibreOfficeRoot "PII_CLEANER_LIBREOFFICE_ROOT" "LibreOfficeRoot" $DefaultLibreOfficeRoot
    $nodeExe = Join-Path $resolvedNodeRoot "node.exe"
    $kordocPackage = Join-Path $resolvedKordocRoot "node_modules\kordoc\package.json"
    $kordocLock = Join-Path $resolvedKordocRoot "package-lock.json"
    if (-not (Test-Path -LiteralPath $nodeExe -PathType Leaf)) { throw "Node.js node.exe를 찾지 못했습니다: $nodeExe" }
    if (-not (Test-Path -LiteralPath $kordocPackage -PathType Leaf)) { throw "Kordoc production node_modules가 없습니다: $kordocPackage" }
    if (-not (Test-Path -LiteralPath $kordocLock -PathType Leaf)) { throw "Kordoc package-lock.json이 없습니다: $kordocLock" }
    if (-not (Test-Path -LiteralPath (Join-Path $resolvedNodeRoot "LICENSE") -PathType Leaf)) {
        throw "Node.js LICENSE 파일이 없습니다: $resolvedNodeRoot"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $resolvedNodeRoot "README.md") -PathType Leaf)) {
        throw "Node.js README.md 파일이 없습니다: $resolvedNodeRoot"
    }
    $soffice = @(
        (Join-Path $resolvedLibreOfficeRoot "program\soffice.com"),
        (Join-Path $resolvedLibreOfficeRoot "program\soffice.exe"),
        (Join-Path $resolvedLibreOfficeRoot "program\soffice")
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $soffice) { throw "LibreOffice program\soffice 실행 파일을 찾지 못했습니다: $resolvedLibreOfficeRoot" }
    $loLegal = Get-ChildItem -LiteralPath $resolvedLibreOfficeRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(LICENSE|NOTICE|readlicense)' } | Select-Object -First 1
    if (-not $loLegal) { throw "LibreOffice 라이선스/고지 파일을 찾지 못했습니다: $resolvedLibreOfficeRoot" }

    $nodeVersion = (& $nodeExe --version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $nodeVersion -notmatch '^v(\d+)') { throw "Node.js 버전을 확인하지 못했습니다: $nodeVersion" }
    if ([int]$Matches[1] -lt 18) { throw "Kordoc에는 Node.js 18 이상이 필요합니다: $nodeVersion" }

    $verificationOutput = & $nodeExe $DocumentRuntimeVerifier $resolvedKordocRoot 2>&1
    $verificationOutput | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw "Kordoc production 의존성·라이선스 검증에 실패했습니다." }

    return [pscustomobject]@{
        KordocRoot = $resolvedKordocRoot
        NodeRoot = $resolvedNodeRoot
        LibreOfficeRoot = $resolvedLibreOfficeRoot
    }
}

function Copy-DirectoryContents {
    param(
        [string]$Source,
        [string]$Destination
    )
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force
    }
}

function Assert-BundledDocumentRuntimes {
    param([string]$Root)
    $nodeExe = Join-Path $Root "node\node.exe"
    $kordocRoot = Join-Path $Root "kordoc"
    $kordocCli = Join-Path $kordocRoot "node_modules\kordoc\dist\cli.js"
    $soffice = @(
        (Join-Path $Root "libreoffice\program\soffice.com"),
        (Join-Path $Root "libreoffice\program\soffice.exe"),
        (Join-Path $Root "libreoffice\program\soffice")
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    $missing = @($nodeExe, $kordocCli, (Join-Path $kordocRoot "package-lock.json")) |
        Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }
    if ($missing) { throw "번들된 문서 엔진 파일이 누락되었습니다: $($missing -join ', ')" }
    if (-not $soffice) { throw "번들된 LibreOffice 실행 파일이 누락되었습니다: $Root\libreoffice" }

    $verificationOutput = & $nodeExe $DocumentRuntimeVerifier $kordocRoot 2>&1
    $verificationOutput | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw "번들된 Kordoc production 의존성·라이선스 검증에 실패했습니다." }

    $kordocVersion = (& $nodeExe $kordocCli --version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $kordocVersion -ne "4.13.1") {
        throw "번들된 Kordoc 실행 검증에 실패했습니다: $kordocVersion"
    }
    $libreOfficeVersion = (& $soffice --headless --version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $libreOfficeVersion) {
        throw "번들된 LibreOffice 실행 검증에 실패했습니다."
    }
    Write-Host "번들 문서 엔진 확인: Kordoc $kordocVersion / $libreOfficeVersion"
}

function Restore-ModelWeights {
    param([string]$Snapshot)
    $weights = Join-Path $Snapshot "model.safetensors"
    $checksumPath = Join-Path $Snapshot "model.safetensors.sha256"
    if (-not (Test-Path -LiteralPath $checksumPath -PathType Leaf)) {
        throw "번들 모델 SHA-256 파일을 찾지 못했습니다: $checksumPath"
    }
    $expected = ((Get-Content -LiteralPath $checksumPath -Raw).Trim() -split "\s+")[0].ToLowerInvariant()
    if ($expected -notmatch "^[a-f0-9]{64}$") {
        throw "번들 모델 SHA-256 형식이 올바르지 않습니다: $checksumPath"
    }
    if (Test-Path -LiteralPath $weights -PathType Leaf) {
        $actual = (Get-FileHash -LiteralPath $weights -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) {
            throw "기존 모델 가중치의 SHA-256 검증에 실패했습니다. model.safetensors를 삭제하고 다시 빌드해주세요."
        }
        return
    }

    $parts = @(Get-ChildItem -LiteralPath $Snapshot -File -Filter "model.safetensors.part-*" -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($parts.Count -eq 0) {
        throw "번들 모델 가중치 조각을 찾지 못했습니다: $Snapshot"
    }

    $partial = "$weights.$PID.partial"
    $target = [System.IO.File]::Open($partial, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
    try {
        foreach ($part in $parts) {
            $source = [System.IO.File]::OpenRead($part.FullName)
            try { $source.CopyTo($target) } finally { $source.Dispose() }
        }
    } finally {
        $target.Dispose()
    }
    $actual = (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        throw "번들 모델 SHA-256 검증에 실패했습니다. 저장소를 다시 받아주세요."
    }
    Move-Item -LiteralPath $partial -Destination $weights
}

function Assert-ModelSnapshot {
    param([string]$Snapshot)
    if (-not (Test-Path -LiteralPath $Snapshot -PathType Container)) {
        throw "모델 스냅샷 폴더가 없습니다: $Snapshot`nmodels\schift-ko-pii-v7 폴더를 포함한 저장소를 다시 받아주세요."
    }
    $required = @("config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors", "modeling_lfm2_bidirectional.py", "schift_heads.json")
    $missing = $required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Snapshot $_) -PathType Leaf) }
    if ($missing) {
        throw "모델 스냅샷에 필수 파일이 없습니다: $($missing -join ', ')"
    }
    if (-not (Get-ChildItem -LiteralPath $Snapshot -File -Filter "LICENSE*" | Select-Object -First 1)) {
        throw "모델 라이선스 파일(LICENSE*)이 없습니다. 라이선스를 포함한 스냅샷을 사용해주세요."
    }
}

if ($env:OS -ne "Windows_NT") { throw "이 스크립트는 Windows에서만 실행할 수 있습니다." }
$ModelSnapshot = $BundledModelPath
Restore-ModelWeights $ModelSnapshot
Assert-ModelSnapshot $ModelSnapshot
$ModelSnapshot = (Resolve-Path -LiteralPath $ModelSnapshot).Path
$script:PythonArguments = @()
$script:PythonCommand = Resolve-Python

$missingLegalFiles = @($ProjectLicense, $ProjectNotice, $ThirdPartyNotices) | Where-Object { -not (Test-Path $_ -PathType Leaf) }
if ($missingLegalFiles) {
    throw "배포 고지 파일이 없습니다: $($missingLegalFiles -join ', ')"
}
if (-not (Test-Path $AppIcon -PathType Leaf)) { throw "앱 아이콘 파일을 찾지 못했습니다: $AppIcon" }
$DocumentRuntimes = Assert-DocumentRuntimes
New-Item -ItemType Directory -Force -Path $BuildRoot, $PyInstallerWork, $PyInstallerDist, $InstallerOutputDir | Out-Null

if (-not (Test-Path (Join-Path $VenvRoot "Scripts\python.exe"))) {
    Invoke-Python @("-m", "venv", $VenvRoot)
}
$VenvPython = Join-Path $VenvRoot "Scripts\python.exe"
& $VenvPython -m pip install --upgrade pip
if ($LASTEXITCODE -ne 0) { throw "pip 업그레이드에 실패했습니다." }

# The released installer is CPU-only; no GPU runtime is pulled into the bundle.
& $VenvPython -m pip install --index-url https://download.pytorch.org/whl/cpu "torch>=2.10.0"
if ($LASTEXITCODE -ne 0) { throw "CPU 전용 PyTorch 설치에 실패했습니다." }
& $VenvPython -m pip install -r $Requirements
if ($LASTEXITCODE -ne 0) { throw "패키지 설치에 실패했습니다." }

$env:HF_HUB_OFFLINE = "1"
$env:TRANSFORMERS_OFFLINE = "1"
& $VenvPython -m PyInstaller `
    --noconfirm --clean --windowed `
    --name "PII Cleaner" `
    --icon $AppIcon `
    --paths $ProjectRoot `
    --workpath $PyInstallerWork `
    --distpath $PyInstallerDist `
    --specpath $BuildRoot `
    --add-data "$ModelSnapshot;models\schift-ko-pii-v7" `
    --add-data "$(Join-Path $ProjectRoot 'resources');resources" `
    --add-data "$ProjectLicense;." `
    --add-data "$ProjectNotice;." `
    --add-data "$ThirdPartyNotices;." `
    --collect-all PySide6 `
    --collect-all schift_ko_pii `
    --hidden-import transformers.models.lfm2 `
    --hidden-import transformers.models.lfm2.configuration_lfm2 `
    --hidden-import transformers.models.lfm2.modeling_lfm2 `
    --hidden-import safetensors.torch `
    $EntryPoint
if ($LASTEXITCODE -ne 0) { throw "PyInstaller 빌드에 실패했습니다." }

$AppExe = Join-Path $PyInstallerDist "PII Cleaner\PII Cleaner.exe"
if (-not (Test-Path $AppExe -PathType Leaf)) { throw "빌드된 실행 파일을 찾지 못했습니다: $AppExe" }

$EngineBundleRoot = Join-Path $PyInstallerDist "PII Cleaner\engines"
if (Test-Path -LiteralPath $EngineBundleRoot -PathType Container) {
    Remove-Item -LiteralPath $EngineBundleRoot -Recurse -Force
}
Copy-DirectoryContents $DocumentRuntimes.KordocRoot (Join-Path $EngineBundleRoot "kordoc")
Copy-DirectoryContents $DocumentRuntimes.NodeRoot (Join-Path $EngineBundleRoot "node")
Copy-DirectoryContents $DocumentRuntimes.LibreOfficeRoot (Join-Path $EngineBundleRoot "libreoffice")
Assert-BundledDocumentRuntimes $EngineBundleRoot

$Iscc = Resolve-Iscc
& $Iscc $InstallerScript
if ($LASTEXITCODE -ne 0) { throw "Inno Setup 빌드에 실패했습니다." }

$Installer = Join-Path $InstallerOutputDir "PII-Cleaner-Setup.exe"
if (-not (Test-Path $Installer -PathType Leaf)) { throw "설치 파일을 찾지 못했습니다: $Installer" }
Write-Host "완료: $Installer"
