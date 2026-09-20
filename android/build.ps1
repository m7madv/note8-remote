$ErrorActionPreference = 'Stop'
$moduleRoot = $PSScriptRoot
$buildPath = Join-Path $moduleRoot 'build'
$sdkPath = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
$toolsPath = Join-Path $sdkPath 'build-tools\35.0.0'
$androidJar = Join-Path $sdkPath 'platforms\android-35\android.jar'
$xposedJar = ((Get-ChildItem -LiteralPath (Join-Path $moduleRoot 'libs') -Filter '*.jar').FullName -join ';' )
foreach ($generatedName in @('classes', 'dex')) {
    $generatedPath = [System.IO.Path]::GetFullPath((Join-Path $buildPath $generatedName))
    $buildPrefix = [System.IO.Path]::GetFullPath($buildPath) + [System.IO.Path]::DirectorySeparatorChar
    if (!$generatedPath.StartsWith($buildPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Generated path escaped the build directory' }
    if (Test-Path -LiteralPath $generatedPath) { Remove-Item -LiteralPath $generatedPath -Recurse -Force }
}
New-Item -ItemType Directory -Path $buildPath,(Join-Path $buildPath 'classes'),(Join-Path $buildPath 'dex') -Force | Out-Null
$javaSources = @(Get-ChildItem -LiteralPath (Join-Path $moduleRoot 'src') -Recurse -Filter '*.java' | Select-Object -ExpandProperty FullName)
& javac -encoding UTF-8 -source 8 -target 8 -classpath "$androidJar;$xposedJar" -d (Join-Path $buildPath 'classes') @javaSources
if ($LASTEXITCODE) { throw 'Java compilation failed' }
& jar cf (Join-Path $buildPath 'module-classes.jar') -C (Join-Path $buildPath 'classes') .
& (Join-Path $toolsPath 'd8.bat') --min-api 28 --lib $androidJar --output (Join-Path $buildPath 'dex') (Join-Path $buildPath 'module-classes.jar') @((Get-ChildItem -LiteralPath (Join-Path $moduleRoot 'libs') -Filter '*.jar').FullName)
if ($LASTEXITCODE) { throw 'DEX compilation failed' }
& (Join-Path $toolsPath 'aapt.exe') package -f -M (Join-Path $moduleRoot 'AndroidManifest.xml') -I $androidJar -S (Join-Path $moduleRoot 'res') -F (Join-Path $buildPath 'unsigned.apk')
if ($LASTEXITCODE) { throw 'APK packaging failed' }
Push-Location (Join-Path $buildPath 'dex')
try { & (Join-Path $toolsPath 'aapt.exe') add (Join-Path $buildPath 'unsigned.apk') classes.dex; if ($LASTEXITCODE) { throw 'DEX packaging failed' } }
finally { Pop-Location }
& (Join-Path $toolsPath 'zipalign.exe') -f 4 (Join-Path $buildPath 'unsigned.apk') (Join-Path $buildPath 'aligned.apk')
if ($LASTEXITCODE) { throw 'APK alignment failed' }
$keyPath = Join-Path $moduleRoot 'development-signing.jks'
if (!(Test-Path -LiteralPath $keyPath)) {
    & keytool -genkeypair -keystore $keyPath -storepass android -keypass android -alias note8-remote -keyalg RSA -keysize 2048 -validity 3650 -dname 'CN=Note8 Remote Development'
    if ($LASTEXITCODE) { throw 'Signing key creation failed' }
}
& (Join-Path $toolsPath 'apksigner.bat') sign --ks $keyPath --ks-key-alias note8-remote --ks-pass pass:android --key-pass pass:android --out (Join-Path $buildPath 'note8-remote.apk') (Join-Path $buildPath 'aligned.apk')
if ($LASTEXITCODE) { throw 'APK signing failed' }
& (Join-Path $toolsPath 'apksigner.bat') verify --verbose (Join-Path $buildPath 'note8-remote.apk')
if ($LASTEXITCODE) { throw 'APK signature verification failed' }

