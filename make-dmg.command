#!/bin/bash
# Packs Bremorph.app into build/Bremorph.dmg: open it, drag Bremorph into Applications.
# Usage: ./make-dmg.command [path/to/Bremorph.app]   (default: ~/Applications/Bremorph.app from build.command)
cd "$(dirname "$0")" || exit 1
APP="${1:-$HOME/Applications/Bremorph.app}"
[ -d "$APP" ] || { echo "No app at $APP. Run ./build.command first."; exit 1; }
mkdir -p build
OUT="build/Bremorph.dmg"
rm -f "$OUT"

# dmgbuild lays out the window (background, icon positions) without scripting Finder.
# It's installed into its own small virtual environment, so the system Python stays untouched.
PY=python3
if ! "$PY" -c "import dmgbuild" 2>/dev/null; then
  VENV="$HOME/Library/Caches/bremorph-dmgbuild"
  [ -x "$VENV/bin/python3" ] || python3 -m venv "$VENV"
  "$VENV/bin/python3" -m pip install --quiet --disable-pip-version-check dmgbuild && PY="$VENV/bin/python3"
fi
if "$PY" -c "import dmgbuild" 2>/dev/null; then
  "$PY" - "$APP" "$OUT" <<'PY' || { echo "DMG_FAILED"; exit 1; }
import sys, os, dmgbuild
app, out = sys.argv[1], sys.argv[2]
here = os.path.abspath("packaging")
dmgbuild.build_dmg(out, "Bremorph", settings_file=os.path.join(here, "dmg-settings.py"),
                   defines={"app": os.path.abspath(app), "dir": here})
PY
else
  echo "dmgbuild isn't available, making a plain DMG instead."
  T="$(mktemp -d)"
  ditto "$APP" "$T/Bremorph.app"
  ln -s /Applications "$T/Applications"
  hdiutil create -volname Bremorph -srcfolder "$T" -fs HFS+ -format UDZO -ov "$OUT" || { echo "DMG_FAILED"; exit 1; }
fi
hdiutil verify "$OUT" >/dev/null && ls -lh "$OUT" && echo "DMG_OK"
