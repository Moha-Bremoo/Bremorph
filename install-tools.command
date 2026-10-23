#!/bin/bash
# Installs the optional helper tools Bremorph can use (via Homebrew).
cd "$(dirname "$0")" || exit 1
exec > >(tee install-tools.log) 2>&1
echo "=== install $(date) ==="
BREW=""
for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$b" ] && BREW="$b" && break; done
[ -z "$BREW" ] && { echo "NO_BREW"; exit 1; }
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1

if ! [ -x "$("$BREW" --prefix)/bin/ffmpeg" ]; then
  "$BREW" install ffmpeg
fi
echo "--- ffmpeg encoders"
"$("$BREW" --prefix)/bin/ffmpeg" -hide_banner -encoders 2>/dev/null | grep -E "libmp3lame|libvorbis|libopus|libvpx-vp9|libwebp |libaom-av1|libsvtav1|wmav2|wmv2|libx264|libx265|mpeg4"

"$BREW" list webp >/dev/null 2>&1 || "$BREW" install webp

if ! ls -d /Applications/LibreOffice.app "$HOME/Applications/LibreOffice.app" >/dev/null 2>&1; then
  echo "--- installing LibreOffice (large download)"
  "$BREW" install --cask --appdir="$HOME/Applications" libreoffice
fi
ls -d /Applications/LibreOffice.app "$HOME/Applications/LibreOffice.app" 2>/dev/null && echo LIBREOFFICE_OK
echo INSTALL_DONE
