#!/usr/bin/env bash
set -e

# PHP Versions
PHP_VERSIONS=("8.5" "8.4" "8.3" "8.2" "8.1" "8.0" "7.4" "7.3" "7.2" "7.1" "7.0" "5.6" "5.5")

# Default Debian OS for each PHP version (second-newest available, no Alpine)
declare -A PHP_DEFAULT_OS
PHP_DEFAULT_OS["5.6"]="stretch"
PHP_DEFAULT_OS["7.0"]="stretch"
PHP_DEFAULT_OS["7.1"]="stretch"
PHP_DEFAULT_OS["7.2"]="buster"
PHP_DEFAULT_OS["7.3"]="bullseye"
PHP_DEFAULT_OS["7.4"]="bullseye"
PHP_DEFAULT_OS["8.0"]="bullseye"
PHP_DEFAULT_OS["8.1"]="bookworm"
PHP_DEFAULT_OS["8.2"]="bookworm"
PHP_DEFAULT_OS["8.3"]="bookworm"
PHP_DEFAULT_OS["8.4"]="bookworm"
PHP_DEFAULT_OS["8.5"]="bookworm"

usage() {
        cat <<'EOF'
Usage: build.sh <php_version> [options]
       build.sh -v <php_version> [options]

Required:
    <php_version>       PHP version, e.g. 8.4, 7.4

Options:
    -i, --image <name>       Image name/repository (default: dphp), e.g. wayfarer35/dphp
    -t, --tag <full_tag>     Full image tag override, e.g. wayfarer35/dphp:8.4
    --extensions="a b c"    Explicit space- or comma-separated list of extensions to install (overrides other selection).
    --exclude="a b c"       Exclude these extensions from the default full raw list (space- or comma-separated).
    --include="a b c"       Include these extensions even if they are in the default not-install list
    -d, --dry-run            Print the docker build command and selected extensions, do not execute.
    --fail-on-generate       Exit with error if auto-generation of all-extensions.raw fails
    -h, --help               Show this help and exit

Examples:
    build.sh 8.4                                   # install default (all from all-extensions.raw)
    build.sh 8.4 --image wayfarer35/dphp           # build as wayfarer35/dphp:8.4
    build.sh 8.4 --tag wayfarer35/dphp:8.4         # fully custom tag
    build.sh 8.4 --exclude="xdebug xhprof"
    build.sh 8.4 --extensions="pdo_mysql,redis"
    build.sh 8.4 --dry-run
    build.sh -v 8.4                                # compatible legacy form
EOF
        exit 1
}

# parse arguments
IMAGE_NAME="${IMAGE_NAME:-dphp}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -v)
            PHP_VERSION="$2"; shift 2;;
        -i|--image)
            IMAGE_NAME="$2"; shift 2;;
        --image=*)
            IMAGE_NAME="${1#*=}"; shift;;
        -t|--tag)
            CUSTOM_TAG="$2"; shift 2;;
        --tag=*)
            CUSTOM_TAG="${1#*=}"; shift;;
        --extensions=*)
            SELECT_EXTENSIONS="${1#*=}"; EXPLICIT_EXTENSIONS=1; shift;;
        --exclude=*)
            EXCLUDE_LIST="${1#*=}"; shift;;
        --include=*)
            INCLUDE_LIST="${1#*=}"; shift;;
        -d|--dry-run)
            DRY_RUN=1; shift;;
        --fail-on-generate)
            FAIL_ON_GENERATE=1; shift;;
        -h|--help)
            usage;;
        -*)
            echo "Unknown argument: $1" >&2; usage;;
        *)
            if [[ -z "${PHP_VERSION:-}" ]]; then
                PHP_VERSION="$1"
                shift
            else
                echo "Unknown argument: $1" >&2
                usage
            fi
            ;;
    esac
done

# If PHP version not provided, prompt interactively
if [[ -z "$PHP_VERSION" ]]; then
    echo "Select PHP version:"
    select v in "${PHP_VERSIONS[@]}"; do
        PHP_VERSION=$v
        break
    done
fi

# Auto-select Debian OS for the chosen PHP version
OS=${PHP_DEFAULT_OS[$PHP_VERSION]:-}
if [[ -z "$OS" ]]; then
    echo "Error: Unsupported PHP version $PHP_VERSION"
    echo "Supported: ${PHP_VERSIONS[*]}"
    exit 1
fi


# Read single merged raw file and compute extensions for this PHP_VERSION + OS
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXT_DIR="$SCRIPT_DIR/extensions"
RAW_FILE="$EXT_DIR/all-extensions.raw"

# Ensure RAW_FILE exists: if missing, try to run the bundled generator script
if [ ! -f "$RAW_FILE" ]; then
    GENERATOR="$SCRIPT_DIR/generate-extension-raw.sh"
    if [ -f "$GENERATOR" ]; then
        echo "all-extensions.raw not found; attempting to generate using $GENERATOR"
        if [ -x "$GENERATOR" ]; then
            if ! "$GENERATOR"; then
                echo "Warning: generator $GENERATOR failed" >&2
            fi
        else
            if ! bash "$GENERATOR"; then
                echo "Warning: generator $GENERATOR failed" >&2
            fi
        fi
        if [ -f "$RAW_FILE" ]; then
            echo "Generated $RAW_FILE"
        else
            echo "Warning: raw file $RAW_FILE still missing after generation attempt; no extensions will be selected by list" >&2
            if [ -n "${FAIL_ON_GENERATE:-}" ]; then
                echo "Error: generation failed and --fail-on-generate specified" >&2
                exit 2
            fi
        fi
    else
            echo "Warning: raw file $RAW_FILE not found and no generator present; no extensions will be selected by list" >&2
            if [ -n "${FAIL_ON_GENERATE:-}" ]; then
                echo "Error: no generator present and --fail-on-generate specified" >&2
                exit 2
            fi
    fi
fi

# parse raw lines: ext v1 v2 ... [| blocked=os1,os2]
# Priority: explicit SELECT_EXTENSIONS (via --extensions) already wins
if [ -z "${SELECT_EXTENSIONS:-}" ] && [ -f "$RAW_FILE" ]; then
    want=()
    while IFS= read -r l; do
        [[ -z "$l" ]] && continue
        [[ "$l" =~ ^# ]] && continue
        # split on '|' to separate blocked
        left=$(echo "$l" | cut -d'|' -f1)
        right=$(echo "$l" | sed -n 's/.*|\s*//p' || true)
        read -ra toks <<< "$left"
        ext=${toks[0]}
        versions=("")
        if [ ${#toks[@]} -gt 1 ]; then
            versions=("${toks[@]:1}")
        fi
        # check version membership
        ok=0
        for v in "${versions[@]}"; do
            if [ "$v" = "$PHP_VERSION" ]; then ok=1; break; fi
        done
        if [ $ok -eq 0 ]; then
            continue
        fi
        # check blocked list
        blocked=""
        if [ -n "$right" ] && echo "$right" | grep -q 'blocked='; then
            blocked=$(echo "$right" | sed -E 's/.*blocked=//')
        fi
        skip=0
        if [ -n "$blocked" ]; then
            IFS=',' read -ra btokens <<< "$blocked"
            for b in "${btokens[@]}"; do
                b=$(echo "$b" | sed -e 's/^[[:space:]]*//;s/[[:space:]]*$//')
                # token like 7.2-alpine or alpine3.10 or just buster
                if [[ "$b" == *"-"* ]]; then
                    ver_part="${b%%-*}"
                    os_part="${b#*-}"
                    if [ "$ver_part" = "$PHP_VERSION" ]; then
                        if [[ "$OS" = "$os_part" || "$OS" == "$os_part"* || "$os_part" == "$OS"* ]]; then
                            skip=1; break
                        fi
                    fi
                else
                    # token might be a php version or an os (alpine, alpine3.10, buster)
                    if [ "$b" = "$PHP_VERSION" ]; then
                        skip=1; break
                    fi
                    if [[ "$OS" = "$b" || "$OS" == "$b"* || "$b" == "$OS"* ]]; then
                        skip=1; break
                    fi
                fi
            done
        fi
        if [ $skip -eq 0 ]; then
            want+=("$ext")
        fi
    done < "$RAW_FILE"
    # dedupe while preserving order
    # if EXCLUDE_LIST provided, filter those out
    if [ -n "${EXCLUDE_LIST:-}" ]; then
        # normalize exclude into newline list
        excl=$(echo "$EXCLUDE_LIST" | tr ',' ' ' | tr ' ' '\n' | sed '/^$/d')
        # build associative to speed-up membership
        declare -A exmap
        while IFS= read -r e; do exmap["$e"]=1; done <<< "$excl"
        filtered=()
        for x in "${want[@]}"; do
            if [ -z "${exmap[$x]:-}" ]; then
                filtered+=("$x")
            fi
        done
        want=("${filtered[@]}")
    fi
    SELECT_EXTENSIONS=$(printf "%s\n" "${want[@]}" | awk '!seen[$0]++{print}' | tr '\n' ' ' | sed -e 's/^ \+//' -e 's/ \+$//')
fi

# Default-not-install list: moved to extensions/default-not-install.conf
# Load list from file if present, otherwise fall back to a built-in list
# The file supports two formats:
#   - legacy / global lines (no colon): one extension per line or comma/space separated
#   - per-version lines: "7.4: ext1 ext2,ext3" (tokens after ':' are extensions for that PHP version)
DEFAULT_NOT_INSTALL_FILE="$EXT_DIR/default-not-install.conf"
DEFAULT_NOT_INSTALL=()
if [ -f "$DEFAULT_NOT_INSTALL_FILE" ]; then
    GLOBAL_DEFAULT_NOT_INSTALL=()
    declare -A VERSION_DEFAULT_NOT_INSTALL
    while IFS= read -r line || [ -n "$line" ]; do
        # trim leading/trailing space
        line=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        [ -z "$line" ] && continue
        [[ "$line" =~ ^# ]] && continue
        # parse tokens: first token is extension, remaining tokens (if any) are PHP versions
        read -ra toks <<< "$line"
        ext=${toks[0]}
        if [ ${#toks[@]} -gt 1 ]; then
            # version-specific: register ext under each listed version
            for v in "${toks[@]:1}"; do
                v=$(echo "$v" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
                [ -n "$v" ] && VERSION_DEFAULT_NOT_INSTALL["$v"]="${VERSION_DEFAULT_NOT_INSTALL["$v"]} $ext"
            done
        else
            # global entry
            GLOBAL_DEFAULT_NOT_INSTALL+=("$ext")
        fi
    done < "$DEFAULT_NOT_INSTALL_FILE"

    # Build effective DEFAULT_NOT_INSTALL: global + version-specific for current PHP_VERSION
    DEFAULT_NOT_INSTALL=("")
    if [ ${#GLOBAL_DEFAULT_NOT_INSTALL[@]} -gt 0 ]; then
        for g in "${GLOBAL_DEFAULT_NOT_INSTALL[@]}"; do
            [ -n "$g" ] && DEFAULT_NOT_INSTALL+=("$g")
        done
    fi
    if [ -n "${VERSION_DEFAULT_NOTSTALL:-}" ]; then
        : # noop (keeps shellcheck quiet if var referenced)
    fi
    if [ -n "${VERSION_DEFAULT_NOT_INSTALL[$PHP_VERSION]:-}" ]; then
        read -ra vs <<< "${VERSION_DEFAULT_NOT_INSTALL[$PHP_VERSION]}"
        for v in "${vs[@]}"; do
            [ -n "$v" ] && DEFAULT_NOT_INSTALL+=("$v")
        done
    fi
    # remove any leading empty element if present
    if [ "${DEFAULT_NOT_INSTALL[0]}" = "" ]; then
        DEFAULT_NOT_INSTALL=("${DEFAULT_NOT_INSTALL[@]:1}")
    fi
else
    DEFAULT_NOT_INSTALL=(opcache ddtrace oci8 pdo_oci parallel xdiff relay imagick vips zmq smbclient snappy snuffleupagus sourceguardian blackfire newrelic opentelemetry tideways)
fi

# If user did NOT pass explicit --extensions, remove default-not-install entries from
# the computed SELECT_EXTENSIONS unless they were re-added via --include.
if [ -z "${EXPLICIT_EXTENSIONS:-}" ] && [ -n "${SELECT_EXTENSIONS:-}" ]; then
    # build maps
    read -ra SEL_ARR_TMP <<< "$SELECT_EXTENSIONS"
    declare -A selmap_tmp
    for s in "${SEL_ARR_TMP[@]}"; do selmap_tmp["$s"]=1; done

    declare -A include_map
    if [ -n "${INCLUDE_LIST:-}" ]; then
        includes=$(echo "$INCLUDE_LIST" | tr ',' ' ')
        for i in $includes; do include_map["$i"]=1; done
    fi

    removed=()
    for d in "${DEFAULT_NOT_INSTALL[@]}"; do
        if [ -n "${selmap_tmp[$d]:-}" ] && [ -z "${include_map[$d]:-}" ]; then
            unset selmap_tmp["$d"]
            removed+=("$d")
        fi
    done

    # rebuild SELECT_EXTENSIONS preserving original order and append includes
    newsel=()
    for k in "${SEL_ARR_TMP[@]}"; do
        if [ -n "${selmap_tmp[$k]:-}" ]; then
            newsel+=("$k")
        fi
    done
    for inc in "${!include_map[@]}"; do
        if [ -z "${selmap_tmp[$inc]:-}" ]; then
            newsel+=("$inc")
        fi
    done
    SELECT_EXTENSIONS=$(printf "%s " "${newsel[@]}" | sed -e 's/ $//')
    if [ ${#removed[@]} -gt 0 ]; then
        echo "Info: removed default-not-install extensions from selection: ${removed[*]}"
    fi
fi

# Vlidate conflicts and remove conflicting extensions from SELECT_EXTENSIONS
CONFLICT_FILE="$EXT_DIR/conflicts.conf"
if [ -f "$CONFLICT_FILE" ] && [ -n "${SELECT_EXTENSIONS:-}" ]; then
    # build selection map
    read -ra SEL_ARR <<< "$SELECT_EXTENSIONS"
    declare -A selmap
    for s in "${SEL_ARR[@]}"; do selmap["$s"]=1; done

    changed=0
    while IFS= read -r line || [ -n "$line" ]; do
        line=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        [ -z "$line" ] && continue
        [[ "$line" =~ ^# ]] && continue
        # preferred:conf1 conf2
        pref=${line%%:*}
        rest=${line#*:}
        for conf in $rest; do
            if [ -n "${selmap[$pref]:-}" ] && [ -n "${selmap[$conf]:-}" ]; then
                unset selmap["$conf"]
                echo "Info: conflict detected: keeping $pref, removing $conf"
                changed=1
            fi
        done
    done < "$CONFLICT_FILE"

    if [ $changed -eq 1 ]; then
        newsel=()
        for k in "${SEL_ARR[@]}"; do
            if [ -n "${selmap[$k]:-}" ]; then
                newsel+=("$k")
            fi
        done
        # rebuild SELECT_EXTENSIONS preserving original order
        SELECT_EXTENSIONS=$(printf "%s " "${newsel[@]}" | sed -e 's/ $//')
    fi
fi

# Build PHP_TAG (always fpm mode) and final image tag
PHP_TAG="${PHP_VERSION}-fpm-${OS}"
if [ -n "${CUSTOM_TAG:-}" ]; then
    IMAGE_TAG="$CUSTOM_TAG"
else
    IMAGE_TAG="${IMAGE_NAME}:${PHP_VERSION}"
fi
echo "Building Docker image: $IMAGE_TAG"

DOCKER_CMD="docker"
if ! docker info >/dev/null 2>&1; then
    if command -v sudo >/dev/null 2>&1; then
        DOCKER_CMD="sudo docker"
    else
        echo "Error: docker requires root privileges. Please add your user to the docker group or run with sudo."
        exit 1
    fi
fi

BUILD_CMD="$DOCKER_CMD build --progress=plain --build-arg PHP_TAG=\"$PHP_TAG\""
if [ -n "$SELECT_EXTENSIONS" ]; then
    BUILD_CMD="$BUILD_CMD --build-arg SELECT_EXTENSIONS=\"$SELECT_EXTENSIONS\""
fi

BUILD_CMD="$BUILD_CMD -t $IMAGE_TAG ."

if [ -n "${DRY_RUN:-}" ]; then
    echo "DRY-RUN:" 
    echo "$BUILD_CMD"
else
    # Execute the built command
    eval "$BUILD_CMD"
fi
