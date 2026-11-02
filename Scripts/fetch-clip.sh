#!/usr/bin/env bash
# Download OpenAI CLIP ViT-B/32 and install a Core ML copy for Stillroom.
#
# License: MIT, Copyright 2021 OpenAI.
# https://github.com/openai/CLIP/blob/main/LICENSE
# Apple's MobileCLIP weights are research-only, so they are not used.
#
# The app never downloads this model. Run this script once on a Mac. It
# checks the published checkpoint and the BPE merge list, converts them,
# compiles with xcrun, and writes sha256sum lines for the installed files.
#
# This script was not executed in the environment that added it. There is
# no Xcode there, so the Core ML conversion is untested.
#
# Default install directory:
#   ~/Library/Application Support/Stillroom/Models/openai-clip-vit-b32/

set -euo pipefail

WEIGHT_URL="https://openaipublic.azureedge.net/clip/models/40d365715913c9da98579312b702a82c18be219cc2a73407c4526f58eba950af/ViT-B-32.pt"
WEIGHT_SHA="40d365715913c9da98579312b702a82c18be219cc2a73407c4526f58eba950af"
BPE_URL="https://github.com/openai/CLIP/raw/main/clip/bpe_simple_vocab_16e6.txt.gz"
BPE_SHA="924691ac288e54409236115652ad4aa250f48203de50a9e4722a6ecd48d6804a"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${HOME}/Library/Application Support/Stillroom/Models/openai-clip-vit-b32"
CACHE="${HOME}/Library/Caches/Stillroom/clip-src"

usage() {
  echo "Usage: Scripts/fetch-clip.sh [--output DIR]" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || usage
      OUTPUT="$2"
      shift 2
      ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

require_hash() {
  local file="$1"
  local expected="$2"
  local actual
  actual="$(hash_file "$file")"
  if [[ "$actual" != "$expected" ]]; then
    echo "Checksum mismatch for $file" >&2
    echo "  expected $expected" >&2
    echo "  actual   $actual" >&2
    exit 1
  fi
}

download() {
  local url="$1"
  local dest="$2"
  if [[ -f "$dest" ]]; then
    return
  fi
  echo "Downloading $url"
  curl --fail --location --retry 3 --output "$dest.partial" "$url"
  mv "$dest.partial" "$dest"
}

echo "OpenAI CLIP ViT-B/32 is MIT licensed (Copyright 2021 OpenAI)."
echo "Stillroom does not download it while the app is running."

mkdir -p "$CACHE"
download "$WEIGHT_URL" "$CACHE/ViT-B-32.pt"
download "$BPE_URL" "$CACHE/bpe_simple_vocab_16e6.txt.gz"
require_hash "$CACHE/ViT-B-32.pt" "$WEIGHT_SHA"
require_hash "$CACHE/bpe_simple_vocab_16e6.txt.gz" "$BPE_SHA"

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required to convert the checkpoint." >&2
  exit 1
fi

VENV="$CACHE/venv"
if [[ ! -x "$VENV/bin/python" ]]; then
  python3 -m venv "$VENV"
fi
# shellcheck disable=SC1091
source "$VENV/bin/activate"
python -m pip install --upgrade pip
python -m pip install torch --index-url https://download.pytorch.org/whl/cpu
python -m pip install "coremltools>=8" numpy pillow ftfy regex tqdm
python -m pip install "git+https://github.com/openai/CLIP.git"

WORK="$CACHE/build"
rm -rf "$WORK"
mkdir -p "$WORK"
python "$ROOT/Scripts/convert_clip.py" --checkpoint "$CACHE/ViT-B-32.pt" --output-dir "$WORK"
gzip -dc "$CACHE/bpe_simple_vocab_16e6.txt.gz" > "$WORK/vocab.bpe"

if ! command -v xcrun >/dev/null 2>&1; then
  echo "xcrun is not available, so the .mlpackage files were not compiled." >&2
  echo "They are in $WORK. Re-run this script on a Mac with Xcode." >&2
  exit 1
fi

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/stillroom-clip.XXXXXX")"
cleanup() { rm -rf "$STAGING"; }
trap cleanup EXIT
xcrun coremlcompiler compile "$WORK/ImageEncoder.mlpackage" "$STAGING"
xcrun coremlcompiler compile "$WORK/TextEncoder.mlpackage" "$STAGING"
cp "$WORK/vocab.bpe" "$STAGING/vocab.bpe"

MANIFEST="$STAGING/checksums.sha256"
: > "$MANIFEST"
while IFS= read -r -d '' path; do
  name="$(basename "$path")"
  [[ "$name" == .* ]] && continue
  relative="${path#"$STAGING"/}"
  [[ "$relative" == "checksums.sha256" ]] && continue
  [[ "$relative" == *".."* ]] && continue
  [[ "$relative" == *"\\"* ]] && continue
  printf '%s  %s\n' "$(hash_file "$path")" "$relative" >> "$MANIFEST"
done < <(find "$STAGING" -type f -print0)

mkdir -p "$(dirname "$OUTPUT")"
rm -rf "$OUTPUT"
mkdir -p "$OUTPUT"
cp -R "$STAGING"/. "$OUTPUT"/
echo "Installed $OUTPUT"
echo "Open Stillroom again. It loads this folder and checks checksums.sha256 before using it."
