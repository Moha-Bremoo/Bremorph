#!/bin/bash
# Reports which helper tools (Homebrew, ffmpeg, LibreOffice) are available.
cd "$(dirname "$0")" || exit 1
exec > >(tee check-tools.log) 2>&1
echo "=== check $(date) ==="
for b in /opt/homebrew/bin/brew /usr/local/bin/brew "$HOME/.homebrew/bin/brew" "$HOME/homebrew/bin/brew"; do
  [ -x "$b" ] && echo "BREW_FOUND $b"
done
echo "PATH_BREW $(command -v brew)"
for b in /opt/homebrew/bin/brew /usr/local/bin/brew "$HOME/.homebrew/bin/brew"; do
  if [ -x "$b" ]; then echo "PREFIX $b -> $("$b" --prefix)"; fi
done
for f in /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg "$HOME/.homebrew/bin/ffmpeg"; do [ -x "$f" ] && echo "FFMPEG $f"; done
echo "PATH_FFMPEG $(command -v ffmpeg)"
ls -d /Applications/LibreOffice.app "$HOME/Applications/LibreOffice.app" 2>/dev/null
ls -d /Applications/Pages.app /Applications/Keynote.app /Applications/Numbers.app 2>/dev/null
df -h / | tail -1
echo CHECK_DONE
