#!/bin/bash
# Runs Bremorph's command-line mode over sample files and logs the results.
cd "$(dirname "$0")/CLI Tests" || exit 1
M="$HOME/Applications/Bremorph.app/Contents/MacOS/Bremorph"
LOG="../test.log"
: > "$LOG"
run() {
  local last="${@: -1}"
  if [ ! -e "$last" ]; then echo "SKIP $1 (missing $last)" | tee -a "$LOG"; return; fi
  "$M" --run "$@" 2>&1 | grep -E "^(OK|FAIL)" | tee -a "$LOG"
}

echo "--- images" | tee -a "$LOG"
run imgAVIF landscape.jpg
run imgWEBP landscape.jpg
run imgFitSize landscape.jpg
echo "--- video" | tee -a "$LOG"
run vidMKV clip.mp4
run vidWEBM clip.mp4
run vidAVI clip.mp4
run vidWMV clip.mp4
run vidMP3 clip.mp4
run vidMP4 clip.mkv
run vidMOV clip.webm
run vidCompress clip.webm
run vidTrim clip.mkv
run vidSplit clip.mp4
run vidSplit clip.webm
run vidSnapshot clip.webm
run vidGIF clip.mkv
run vidSpeed clip.mkv
run vidFitSize clip.mp4
run vidAudio clip.webm
run vidMute clip.mkv
run vidStripMeta clip.webm
run vidJoin clip.mp4 clip.mkv
echo "--- audio" | tee -a "$LOG"
run audMP3 tone.wav
run audOGG tone.wav
run audOPUS tone.wav
run audWMA tone.wav
run audM4A tone.ogg
run audFLAC tone.mp3
run audWAV tone.ogg
run audBleep tone.wav
run audBleep tone.ogg
run audStereo tonemono.wav
run audMono tone.ogg
run audNormalize tone.ogg
run audTrim tone.ogg
echo "--- documents" | tee -a "$LOG"
run docDOCX sample.md
run docHTML sample.md
run docEPUB sample.md
run docPDF sample.docx
run docMD sample.docx
run docODT sample.docx
run docTXT sample.epub
run docDOCX sample.epub
echo "--- pdf" | tee -a "$LOG"
run pdfDOCX sample.pdf
run pdfMD sample.pdf
run pdfEPUB sample.pdf
run pdfPPTX sample.pdf
run pdfXLSX sample.pdf
run pdfPNG sample.pdf
run pdfFitSize sample.pdf
echo "--- slides & sheets" | tee -a "$LOG"
run slPDF sample.pptx
run slPNG sample.pptx
run shXLSX sample.csv
run shTSV sample.csv
run shODS sample.xlsx
run shCSV sample.xlsx
run shPDF sample.xlsx
echo "--- subtitles" | tee -a "$LOG"
run subTXT subs.srt
echo TESTS_DONE | tee -a "$LOG"
