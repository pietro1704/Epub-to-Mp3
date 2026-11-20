# Provision the pinned ONNX Runtime and the runner's libclang for a Windows build
# of converter-ffi (ort-sys with ORT_SKIP_DOWNLOAD). Shared by the Windows package
# validation (flutter-rust-faber.yml) and the Windows release (release-desktop.yml)
# so the two cannot drift: the v0.9.0 release failed in ort-sys because only the
# validation job provisioned the runtime.
#
# Writes ORT_LIB_LOCATION and LIBCLANG_PATH to GITHUB_ENV and libclang to GITHUB_PATH.
param([Parameter(Mandatory = $true)][string]$Owned)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $Owned | Out-Null

function Get-VerifiedFile($url, $path, $bytes, $sha256) {
  Invoke-WebRequest -Uri $url -OutFile $path -TimeoutSec 180
  if ((Get-Item $path).Length -ne $bytes) { throw "Unexpected artifact size: $path" }
  if ((Get-FileHash -Algorithm SHA256 $path).Hash.ToLowerInvariant() -ne $sha256) {
    throw "Artifact checksum mismatch: $path"
  }
}

$ortZip = Join-Path $Owned 'ort.zip'
# Official CPU NuGet package; rebuild the former release-archive layout.
Get-VerifiedFile 'https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime/1.24.4/microsoft.ml.onnxruntime.1.24.4.nupkg' $ortZip 125194303 '4b978d5065b85e7004b6c6f60ca494bd978fbe6836cbf0a0b52d82b61ab99638'
$ortPackage = Join-Path $Owned 'ort-nupkg'
Expand-Archive -LiteralPath $ortZip -DestinationPath $ortPackage
$ort = Join-Path $Owned 'ort/onnxruntime-win-x64-1.24.4'
New-Item -ItemType Directory -Force (Join-Path $ort 'lib') | Out-Null
Copy-Item (Join-Path $ortPackage 'runtimes/win-x64/native/*') (Join-Path $ort 'lib')
Copy-Item -Recurse (Join-Path $ortPackage 'build/native/include') (Join-Path $ort 'include')
if ((Get-FileHash -Algorithm SHA256 (Join-Path $ort 'lib/onnxruntime.dll')).Hash.ToLowerInvariant() -ne 'b95efb2113b603bbbf3f191061c5516a871ed546893c820e4f3b7b6c358dbf2a') { throw 'ORT runtime DLL checksum mismatch' }
if (!(Test-Path (Join-Path $ort 'lib/onnxruntime.lib'))) { throw 'Missing ORT import library' }
if (!(Test-Path (Join-Path $ort 'lib/onnxruntime.dll'))) { throw 'Missing ORT runtime DLL' }
"ORT_LIB_LOCATION=$(Join-Path $ort 'lib')" >> $env:GITHUB_ENV

$clang = 'C:/Program Files/LLVM/bin'
if (!(Test-Path (Join-Path $clang 'libclang.dll'))) { throw 'Missing runner libclang' }
"LIBCLANG_PATH=$clang" >> $env:GITHUB_ENV
$clang >> $env:GITHUB_PATH
