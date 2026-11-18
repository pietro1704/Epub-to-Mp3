#!/usr/bin/env bash
# Provision the CPU ONNX Runtime 1.24.4 for Linux x64 from Microsoft's official
# NuGet package and lay it out like the former GitHub release archive:
#   <destination>/onnxruntime-linux-x64-1.24.4/{lib,include}
# with lib/libonnxruntime.so -> libonnxruntime.so.1 -> libonnxruntime.so.1.24.4
# (the library's SONAME is libonnxruntime.so.1).
# The package digest is checked before extraction and the library digest after.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <destination directory>" >&2
  exit 64
fi

version='1.24.4'
package_sha256='4b978d5065b85e7004b6c6f60ca494bd978fbe6836cbf0a0b52d82b61ab99638'
library_sha256='d132535d051344ff5c64c9c200004150559049a81ed330eb4422c1962fb6b7e4'
url="https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime/${version}/microsoft.ml.onnxruntime.${version}.nupkg"

destination=$1
root="$destination/onnxruntime-linux-x64-$version"
if [[ -e "$root" ]]; then
  echo "Refusing to overwrite existing runtime: $root" >&2
  exit 1
fi
mkdir -p "$destination"
staging=$(mktemp -d "$destination/.onnxruntime-nuget.XXXXXX")
trap 'rm -rf "$staging"' EXIT

package="$staging/microsoft.ml.onnxruntime.$version.nupkg"
curl --fail --silent --show-error --location --retry 3 --max-time 300 "$url" --output "$package"
echo "$package_sha256  $package" | sha256sum --check --status

unzip -q "$package" 'runtimes/linux-x64/native/libonnxruntime.so' 'build/native/include/*' -d "$staging/extracted"
library="$staging/extracted/runtimes/linux-x64/native/libonnxruntime.so"
echo "$library_sha256  $library" | sha256sum --check --status

mkdir -p "$root/lib"
mv "$staging/extracted/build/native/include" "$root/include"
mv "$library" "$root/lib/libonnxruntime.so.$version"
ln -s "libonnxruntime.so.$version" "$root/lib/libonnxruntime.so.1"
ln -s 'libonnxruntime.so.1' "$root/lib/libonnxruntime.so"
test -f "$root/lib/libonnxruntime.so"
