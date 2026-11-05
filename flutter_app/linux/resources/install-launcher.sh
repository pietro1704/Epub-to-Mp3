#!/usr/bin/env bash
# Install the launcher after extracting the complete Linux bundle in its final location.
set -euo pipefail

bundle_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
if [[ ! -x "$bundle_dir/flutter_app" || ! -f "$bundle_dir/data/app-icon.png" ]]; then
  echo 'Run install-launcher.sh from the extracted EpubToMp3 Linux bundle.' >&2
  exit 2
fi
if [[ "$bundle_dir" == *$'\n'* || "$bundle_dir" == *$'\r'* ]]; then
  echo 'The bundle path must not contain line breaks.' >&2
  exit 2
fi
applications="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
mkdir -p -- "$applications"
temporary=$(mktemp "$applications/.epubtomp3-launcher.XXXXXX")
trap 'rm -f -- "$temporary"' EXIT

# Desktop Entry string escaping happens before Exec argument escaping.
executable="$bundle_dir/flutter_app"
executable=${executable//\\/\\\\}
executable=${executable//\"/\\\"}
executable=${executable//\$/\\\$}
executable=${executable//\`/\\\`}
executable=${executable//%/%%}
executable=${executable//\\/\\\\}
icon="$bundle_dir/data/app-icon.png"
icon=${icon//\\/\\\\}
cat > "$temporary" <<EOF
[Desktop Entry]
Type=Application
Name=EpubToMp3
Comment=Read books and listen to audiobooks
Exec="$executable"
Icon=$icon
Terminal=false
Categories=AudioVideo;Audio;Education;
StartupWMClass=com.epubtomp3.flutter_app
EOF
chmod 644 "$temporary"
mv -f -- "$temporary" "$applications/com.epubtomp3.flutter_app.desktop"
echo "Installed EpubToMp3 launcher in $applications"
