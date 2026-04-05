#!/usr/bin/env bash
set -euo pipefail

# generate-extension-raw.sh
# Produce a single merged raw file `all-extensions.raw` in extensions/
# The format: one extension per line: "ext v1 v2 ... | blocked=os1,os2"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# All files live in this directory now
SUPPORTED_LOCAL="${SCRIPT_DIR}/extensions/supported-extensions.raw"
SPECIAL_LOCAL="${SCRIPT_DIR}/extensions/special-requirements.raw"
# write to filename expected by build.sh
OUT_FILE="${SCRIPT_DIR}/extensions/all-extensions.raw"

SUPPORTED_URL="https://raw.githubusercontent.com/mlocati/docker-php-extension-installer/master/data/supported-extensions"
SPECIAL_URL="https://raw.githubusercontent.com/mlocati/docker-php-extension-installer/master/data/special-requirements"

FORCE_DOWNLOAD=0

usage(){
  echo "Usage: $0 [--force-download]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force-download) FORCE_DOWNLOAD=1; shift ;;
    -h|--help) usage ;;
    *) shift ;;
  esac
done

download_if_missing() {
  local url="$1" dest="$2"
  if [ $FORCE_DOWNLOAD -eq 1 ] || [ ! -f "$dest" ]; then
    echo "Downloading $url -> $dest"
    tmp=$(mktemp)
    if ! curl -fsSL "$url" -o "$tmp"; then
      rm -f "$tmp"
      echo "Warning: failed to download $url" >&2
      return 1
    fi
    mv "$tmp" "$dest"
  fi
  return 0
}

SUPPORTED_SRC="$SUPPORTED_LOCAL"
if [ ! -f "$SUPPORTED_SRC" ]; then
  # try to download into same directory
  if ! download_if_missing "$SUPPORTED_URL" "$SUPPORTED_SRC"; then
    echo "Error: no supported-extensions available locally and download failed" >&2
    exit 2
  fi
fi

# special-requirements must be in this directory. If missing, download into same directory and use it.
SPECIAL_SRC="$SPECIAL_LOCAL"
if [ ! -f "$SPECIAL_SRC" ]; then
  if ! download_if_missing "$SPECIAL_URL" "$SPECIAL_SRC"; then
    echo "Warning: special-requirements not available locally and download failed; special requirements will be ignored" >&2
    SPECIAL_SRC=""
  fi
else
  if [ $FORCE_DOWNLOAD -eq 1 ]; then
    if ! download_if_missing "$SPECIAL_URL" "$SPECIAL_SRC"; then
      echo "Warning: failed to refresh local special-requirements; continuing with existing file" >&2
    fi
  fi
fi

echo "Using supported: $SUPPORTED_SRC"
if [ -n "$SPECIAL_SRC" ]; then
  echo "Using special-requirements: $SPECIAL_SRC"
else
  echo "No special-requirements available; special requirements will be ignored"
fi

# parse special requirements from raw if present
declare -A ext_blocked
if [ -n "$SPECIAL_SRC" ] && [ -f "$SPECIAL_SRC" ]; then
  # Detect simple line format: "ext !os1 !os2"
  if grep -q -E '^\s*[A-Za-z0-9_.+-]+(\s+!\S+)+' "$SPECIAL_SRC" 2>/dev/null; then
    while IFS= read -r row; do
      [[ -z "$row" ]] && continue
      [[ "$row" =~ ^# ]] && continue
      read -ra toks <<< "$row"
      ext=${toks[0]}
      blocked_list=""
      for tok in "${toks[@]:1}"; do
        if [[ "$tok" == !* ]]; then
          b=${tok#!}
          blocked_list="$blocked_list $b"
        fi
      done
      if [ -n "$blocked_list" ]; then
        blocked_unique=$(echo "$blocked_list" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ',')
        blocked_unique=${blocked_unique%,}
        ext_blocked["$ext"]="$blocked_unique"
      fi
    done < "$SPECIAL_SRC"
  else
    # Fallback: existing table-style parsing
    SPECIAL_RAW=$(awk '/START OF SPECIAL REQUIREMENTS/{p=1;next}/END OF SPECIAL REQUIREMENTS/{p=0}p' "$SPECIAL_SRC" || true)
    if [ -n "$SPECIAL_RAW" ]; then
      while IFS= read -r row; do
        [[ -z "$row" ]] && continue
        [[ ! "$row" =~ ^\| ]] && continue
        IFS='|' read -ra cols <<< "$row"
        ext_field="${cols[1]:-}"
        ext=$(echo "$ext_field" | sed -E 's/<[^>]*>//g' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
        req_field="${cols[2]:-}"
        req_text=$(echo "$req_field" | sed -e 's/<br \/\/*>/ /g' -e 's/&bull;/ /g' -e 's/<[^>]*>//g')
        blocked_list=""
        for token in $(echo "$req_text" | grep -o -E '\`[^\`]+\`' | sed -e 's/`//g' || true); do
          norm=$(echo "$token" | sed -E 's/alpine[0-9.]+/alpine/; s/[^a-zA-Z0-9._-]//g')
          blocked_list="$blocked_list $norm"
        done
        for word in $(echo "$req_text" | tr '[:punct:]' ' ' | tr ' ' '\n' | sed '/^$/d' || true); do
          if echo "$word" | grep -q -E 'alpine|buster|bullseye|bookworm|trixie|jessie|stretch'; then
            norm=$(echo "$word" | sed -E 's/alpine[0-9.]+/alpine/')
            blocked_list="$blocked_list $norm"
          fi
        done
        if [ -n "$blocked_list" ]; then
          blocked_unique=$(echo "$blocked_list" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ',')
          blocked_unique=${blocked_unique%,}
          ext_blocked["$ext"]="$blocked_unique"
        fi
      done <<< "$SPECIAL_RAW"
    else
      # If no START/END block, try table rows
      SPECIAL_RAW=$(grep '^|' "$SPECIAL_SRC" || true)
      if [ -n "$SPECIAL_RAW" ]; then
        while IFS= read -r row; do
          [[ -z "$row" ]] && continue
          [[ ! "$row" =~ ^\| ]] && continue
          IFS='|' read -ra cols <<< "$row"
          ext_field="${cols[1]:-}"
          ext=$(echo "$ext_field" | sed -E 's/<[^>]*>//g' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
          req_field="${cols[2]:-}"
          req_text=$(echo "$req_field" | sed -e 's/<br \/\/*>/ /g' -e 's/&bull;/ /g' -e 's/<[^>]*>//g')
          blocked_list=""
          for token in $(echo "$req_text" | grep -o -E '\`[^\`]+\`' | sed -e 's/`//g' || true); do
            norm=$(echo "$token" | sed -E 's/alpine[0-9.]+/alpine/; s/[^a-zA-Z0-9._-]//g')
            blocked_list="$blocked_list $norm"
          done
          for word in $(echo "$req_text" | tr '[:punct:]' ' ' | tr ' ' '\n' | sed '/^$/d' || true); do
            if echo "$word" | grep -q -E 'alpine|buster|bullseye|bookworm|trixie|jessie|stretch'; then
              norm=$(echo "$word" | sed -E 's/alpine[0-9.]+/alpine/')
              blocked_list="$blocked_list $norm"
            fi
          done
          if [ -n "$blocked_list" ]; then
            blocked_unique=$(echo "$blocked_list" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ',')
            blocked_unique=${blocked_unique%,}
            ext_blocked["$ext"]="$blocked_unique"
          fi
        done <<< "$SPECIAL_RAW"
      fi
    fi
  fi
fi
if declare -p ext_blocked >/dev/null 2>&1; then
  cnt=${#ext_blocked[@]}
else
  cnt=0
fi
echo "Parsed special requirements for ${cnt} extensions"

# Generate single raw output
tmp_out=$(mktemp)
echo "# Generated all-extensions.raw" > "$tmp_out"
echo "# Format: ext versions... [| blocked=os1,os2]" >> "$tmp_out"
echo "# Source supported: $SUPPORTED_SRC" >> "$tmp_out"
if [ -n "$SPECIAL_SRC" ]; then
  echo "# Source special-requirements: $SPECIAL_SRC" >> "$tmp_out"
fi
echo "" >> "$tmp_out"

while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  [[ "$line" =~ ^# ]] && continue
  read -ra toks <<< "$line"
  ext=${toks[0]}
  versions="${toks[@]:1}"
  outline="$ext $versions"
  if [ -n "${ext_blocked[$ext]:-}" ]; then
    outline="$outline | blocked=${ext_blocked[$ext]}"
  fi
  echo "$outline" >> "$tmp_out"
done < "$SUPPORTED_SRC"

sort -u "$tmp_out" -o "$tmp_out"
mv "$tmp_out" "$OUT_FILE"
chmod 644 "$OUT_FILE"

echo "Wrote merged raw to $OUT_FILE"
