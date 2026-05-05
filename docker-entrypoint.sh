#!/bin/sh
set -e

# (MIB handling moved to image build-time; do not change MIB env at runtime)
# docker-entrypoint.sh (POSIX sh)
# 启动时根据 ENABLE_EXTENSIONS 环境变量启用预安装的 PHP 扩展。
# ENABLE_EXTENSIONS 可以是以逗号分隔的扩展名列表，或者设置为 "all" 来启用全部。

PHP_CONF_DIR="/usr/local/etc/php/conf.d"
AVAILABLE_DIR="/opt/php-extensions-available"
MAPPING_FILE="$AVAILABLE_DIR/extensions.map"

# Ensure conf.d exists
mkdir -p "$PHP_CONF_DIR"

# Load mapping (name=filename) into plain files under /tmp for lookup
# We'll use a simple lookup function that greps the mapping file
lookup_map() {
  name="$1"
  if [ -f "$MAPPING_FILE" ]; then
    exact=$(awk -F= -v key="$name" '$1==key {print $2; exit}' "$MAPPING_FILE")
    if [ -n "$exact" ]; then
      printf '%s\n' "$exact"
      return 0
    fi
    awk -F= -v key="$name" '
      function normalize(value) {
        sub(/^[0-9]+-/, "", value)
        sub(/^docker-php-ext-/, "", value)
        sub(/\.ini$/, "", value)
        return value
      }
      normalize($1) == key || normalize($2) == key { print $2; exit }
    ' "$MAPPING_FILE"
  fi
}

link_ini_file() {
  src="$1"
  base=$(basename "$src")
  dest="$PHP_CONF_DIR/$base"
  if [ -L "$dest" ] && [ "$(readlink -f "$dest")" = "$(readlink -f "$src")" ]; then
    return 0
  fi
  ln -sf "$src" "$dest"
  return 0
}

expand_dependencies() {
  ext="$1"
  case "$ext" in
    redis)
      printf '%s\n' igbinary
      printf '%s\n' msgpack
      ;;
  esac
  printf '%s\n' "$ext"
}

# Fallback: derive short name from ini file content (portable, avoids GNU-only sed extensions)
derive_shortname() {
  fpath="$1"
  # extract the first extension or zend_extension value from the ini file
  val=$(sed -n -e 's/^[[:space:]]*extension[[:space:]]*=[[:space:]]*\(.*\)/\1/p' -e 's/^[[:space:]]*zend_extension[[:space:]]*=[[:space:]]*\(.*\)/\1/p' "$fpath" | head -n1 || true)
  [ -z "$val" ] && return 1
  # get basename and strip .so suffix, then lowercase in a portable way
  base=$(basename "$val")
  base=${base%.so}
  echo "$base" | tr '[:upper:]' '[:lower:]'
}

is_loaded_module() {
  ext="$1"
  if ! command -v php >/dev/null 2>&1; then
    return 1
  fi
  if php -m 2>/dev/null | grep -F -i -x "$ext" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# Helper: enable one extension by creating symlink (preserve original filename)
enable_ext() {
  ext="$1"
  attempts_tmp=$(mktemp)
  file="$(lookup_map "$ext")"
  if [ -n "$file" ]; then
    printf '%s\n' "mapping:$file" >> "$attempts_tmp"
    if [ -f "$AVAILABLE_DIR/$file" ]; then
      link_ini_file "$AVAILABLE_DIR/$file"
      echo "[entrypoint] enabled extension: $ext -> $file"
      rm -f "$attempts_tmp"
      return 0
    else
      # mapping existed but target file missing
      printf '%s\n' "mapping-file-missing:$AVAILABLE_DIR/$file" >> "$attempts_tmp"
    fi
  fi
  # Prefer exact filename matches before any fuzzy fallback.
  for f in "$AVAILABLE_DIR"/docker-php-ext-"$ext".ini "$AVAILABLE_DIR"/"$ext".ini; do
    if [ ! -f "$f" ]; then
      printf '%s\n' "exact-no-file:$f" >> "$attempts_tmp"
      continue
    fi
    printf '%s\n' "exact:$f" >> "$attempts_tmp"
    link_ini_file "$f"
    echo "[entrypoint] enabled extension (exact): $ext -> $(basename "$f")"
    rm -f "$attempts_tmp"
    return 0
  done
  # try to match by derived shortname
  for f in "$AVAILABLE_DIR"/*.ini; do
    [ -f "$f" ] || continue
    printf '%s\n' "scanning:$f" >> "$attempts_tmp"
    if short=$(derive_shortname "$f"); then
      if [ "$short" = "$ext" ]; then
        link_ini_file "$f"
        echo "[entrypoint] enabled extension (derived): $ext -> $(basename "$f")"
        rm -f "$attempts_tmp"
        return 0
      fi
    else
      printf '%s\n' "derive-no-match:$f" >> "$attempts_tmp"
    fi
  done
  # Last resort: try a fuzzy filename match.
  for f in "$AVAILABLE_DIR"/*"-$ext".ini "$AVAILABLE_DIR"/*"$ext"*.ini; do
    if [ ! -f "$f" ]; then
      printf '%s\n' "pattern-no-file:$f" >> "$attempts_tmp"
      continue
    fi
    printf '%s\n' "pattern:$f" >> "$attempts_tmp"
    link_ini_file "$f"
    echo "[entrypoint] enabled extension (fallback): $ext -> $(basename "$f")"
    rm -f "$attempts_tmp"
    return 0
  done
  if is_loaded_module "$ext"; then
    echo "[entrypoint] extension already loaded by base image: $ext"
    rm -f "$attempts_tmp"
    return 0
  fi
  echo "[entrypoint] warning: extension ini not found for '$ext'" >&2
  echo "[entrypoint][debug] attempted candidates:" >&2
  sed -n '1,200p' "$attempts_tmp" >&2 || true
  echo "[entrypoint][debug] available ini files (first 200):" >&2
  ls -1 "$AVAILABLE_DIR"/*.ini 2>/dev/null | sed -n '1,200p' >&2 || true
  rm -f "$attempts_tmp"
  return 1
}

# Collect enabled extensions directly from environment variables named
# EXTENSION_<NAME>=1 (or true/TRUE). If an allowed list exists, validate
# against it. (Avoid duplicate ENABLE_EXTENSIONS handling.)
enabled_tmp=$(mktemp)
trap 'rm -f "$enabled_tmp"' EXIT INT TERM
env | while IFS='=' read -r name value; do
  case "$name" in
    EXTENSION_*)
      case "$value" in
        1|true|TRUE)
          ext=$(echo "${name#EXTENSION_}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_]+/_/g')
          expand_dependencies "$ext" >> "$enabled_tmp"
          ;;
      esac
      ;;
  esac
done

# dedupe while preserving order and enable each
if [ -s "$enabled_tmp" ]; then
  enabled_exts=$(awk '!seen[$0]++{print}' "$enabled_tmp" | paste -sd, -)
  rm -f "$enabled_tmp"
  echo "[entrypoint] enabling extensions from EXTENSION_* env flags: ${enabled_exts}"
  OLD_IFS=$IFS
  IFS=','
  for e in $enabled_exts; do
    e_trim=$(echo "$e" | tr -d '\r' | sed -e 's/^\s*//' -e 's/\s*$//')
    [ -z "$e_trim" ] && continue
  enable_ext "$e_trim"
  done
  IFS=$OLD_IFS
else
  rm -f "$enabled_tmp"
  echo "[entrypoint] no EXTENSION_* env flags found — no extensions will be enabled by default"
fi

# If no args provided, start php-fpm; otherwise execute whatever the user passed
if [ "$#" -eq 0 ]; then
  if command -v php-fpm >/dev/null 2>&1; then
    exec php-fpm
  else
    exec /bin/bash
  fi
else
  exec "$@"
fi
