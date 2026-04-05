ARG PHP_TAG=8.4-fpm-bookworm

# Builder stage: compile/install extensions with build deps
FROM php:${PHP_TAG} AS builder

# Install dependencies for building extensions
ADD --chmod=0755 https://github.com/mlocati/docker-php-extension-installer/releases/latest/download/install-php-extensions /usr/local/bin/

ARG SELECT_EXTENSIONS=""

# Prepare build deps and install extensions in two steps to improve cache usage:
# 1) install extensions
RUN set -eux; \
    if [ -n "$SELECT_EXTENSIONS" ]; then \
        SEL=$(echo "$SELECT_EXTENSIONS" | tr ',' ' '); \
        echo "[builder] Installing extensions: $SEL"; \
        CFLAGS="${CFLAGS:-} -Wno-error" \
        CXXFLAGS="${CXXFLAGS:-} -Wno-error" \
        IPE_DEBUG=1 \
        IPE_ICU_EN_ONLY=1 \
        IPE_ASPELL_LANGUAGES='en' \
        install-php-extensions $SEL; \
    else \
        echo "[builder] No SELECT_EXTENSIONS provided; skipping extension build"; \
    fi;

# 2) collect generated ini files, extension .so and shared lib deps (separate RUN for caching)
RUN set -eux; \
    mkdir -p /opt/php-extensions-available; \
    > /opt/php-extensions-available/extensions.map; \
    for f in /usr/local/etc/php/conf.d/*.ini; do \
        if [ -f "$f" ]; then \
            base=$(basename "$f"); \
            cp "$f" "/opt/php-extensions-available/$base"; \
            ext=$(sed -n -e 's/^[[:space:]]*extension[[:space:]]*=[[:space:]]*\(.*\)/\1/p' -e 's/^[[:space:]]*zend_extension[[:space:]]*=[[:space:]]*\(.*\)/\1/p' "$f" | sed -E 's/.*/\L&/' | sed -E 's/.*/\0/' | sed -E 's/.*\\/([^/]+)\\.so$/\\1/' | sed -E 's/\\.so$//' | head -n1); \
            if [ -z "$ext" ]; then \
                ext=$(echo "$base" | sed -E 's/^[0-9]+-//' | sed -E 's/\\.ini$//'); \
            fi; \
            echo "$ext=$base" >> /opt/php-extensions-available/extensions.map; \
        fi; \
    done; \
    mkdir -p /opt/php-extensions-available/lib; \
    cp -a /usr/local/lib/php/extensions/. /opt/php-extensions-available/lib/ 2>/dev/null || true; \
    mkdir -p /opt/php-extensions-available/libdeps; \
    missing=; \
    for so in $(find /opt/php-extensions-available/lib -type f -name '*.so' -print 2>/dev/null); do \
        ldd_output=$(ldd "$so" 2>/dev/null || true); \
        for lib in $(echo "$ldd_output" | sed -n 's/.*=> \(\/[^ ]*\).*/\1/p' | sort -u); do \
            if [ -n "$lib" ] && [ -f "$lib" ]; then \
                destdir=/opt/php-extensions-available/libdeps$(dirname "$lib"); \
                mkdir -p "$destdir" || true; \
                cp -a "$lib" "$destdir/" || true; \
                if [ -L "$lib" ]; then \
                    target=$(readlink -f "$lib" 2>/dev/null || true); \
                    if [ -n "$target" ] && [ -f "$target" ]; then \
                        targetdir=/opt/php-extensions-available/libdeps$(dirname "$target"); \
                        mkdir -p "$targetdir" || true; \
                        cp -a "$target" "$targetdir/" || true; \
                    fi; \
                fi; \
            fi; \
        done; \
        nf=$(echo "$ldd_output" | sed -n "s/^[[:space:]]*\([^[:space:]]\+\).*not found$/\1/p" | tr '\n' ' '); \
        if [ -n "$nf" ]; then echo "Missing shared libs for $so: $nf" >&2; missing=1; fi; \
    done; \
    if [ -n "$missing" ]; then \
        echo "Error: missing shared libs detected during build" >&2; \
        exit 1; \
    fi; \
    if command -v strip >/dev/null 2>&1; then \
        find /usr/local/lib/php/extensions -type f -name '*.so' -print0 | xargs -0 -r strip --strip-unneeded || true; \
        find /opt/php-extensions-available/lib -type f -name '*.so' -print0 | xargs -0 -r strip --strip-unneeded || true; \
    fi; \
    find /usr/local -type f \( -name '*.a' -o -name '*.la' \) -delete 2>/dev/null || true; \
    rm -rf /usr/local/lib/pkgconfig /usr/local/share/doc /usr/local/share/man /usr/local/share/locale 2>/dev/null || true;

# Install/download MIBs at build time if snmp extension is present (use robust detection)
RUN set -eux; \
    mkdir -p /opt/php-extensions-available/mibs; \
    if grep -q '^snmp=' /opt/php-extensions-available/extensions.map 2>/dev/null || \
       ls /opt/php-extensions-available/lib/*snmp*.so >/dev/null 2>&1 || \
       ls /usr/local/lib/php/extensions/*snmp*.so >/dev/null 2>&1; then \
        echo "[builder] snmp extension detected — installing MIBs"; \
        if command -v apt-get >/dev/null 2>&1; then \
            apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends snmp snmp-mibs-downloader || true; \
            download-mibs || true; \
            rm -rf /var/lib/apt/lists/* || true; \
        elif command -v apk >/dev/null 2>&1; then \
            apk add --no-cache net-snmp net-snmp-tools || true; \
        elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then \
            if command -v dnf >/dev/null 2>&1; then dnf -y install net-snmp net-snmp-utils || true; else yum -y install net-snmp net-snmp-utils || true; fi; \
        fi; \
        # copy MIB files into opt area for safe COPY to final image
        if [ -d /usr/share/snmp/mibs ]; then \
            cp -a /usr/share/snmp/mibs/. /opt/php-extensions-available/mibs/ 2>/dev/null || true; \
        fi; \
    else \
        echo "[builder] snmp extension not detected; skipping MIB install"; \
    fi


# Final runtime stage: smaller image
FROM php:${PHP_TAG}

ARG COMPOSER_VERSION=""

# Copy prepared extensions and mapping from builder
COPY --from=builder /opt/php-extensions-available /opt/php-extensions-available
# Restore collected shared libs into final image root so linker can find them
COPY --from=builder /opt/php-extensions-available/libdeps /opt/php-extensions-available/libdeps
# Copy MIBs collected in builder (if any)
COPY --from=builder /opt/php-extensions-available/mibs /usr/share/snmp/mibs
# copy installer script from builder so final image keeps it
COPY --from=builder /usr/local/bin/install-php-extensions /usr/local/bin/install-php-extensions

# Install collected extension .so files into the standard PHP extensions dir
RUN set -e; \
    if [ -f /usr/local/bin/install-php-extensions ]; then \
        chmod +x /usr/local/bin/install-php-extensions || true; \
        if [ -n "${COMPOSER_VERSION:-}" ]; then \
            echo "[final] Installing composer version ${COMPOSER_VERSION}"; \
            install-php-extensions @composer:${COMPOSER_VERSION}; \
        else \
            echo "[final] Installing composer (latest)"; \
            install-php-extensions @composer; \
        fi; \
    else \
        echo "[final] install-php-extensions not present; skipping composer install"; \
    fi; \
    # copy extension .so files into PHP extensions dir
    if [ -d /opt/php-extensions-available/lib ]; then \
        echo "Copying extension .so files into /usr/local/lib/php/extensions"; \
        mkdir -p /usr/local/lib/php/extensions; \
        (cd /opt/php-extensions-available/lib && tar cf - .) | tar -C /usr/local/lib/php/extensions -xpf - || true; \
    fi; \
    # Restore collected libdeps into /usr/local/lib (do NOT overwrite system /lib), and register with ldconfig
    if [ -d /opt/php-extensions-available/libdeps ]; then \
        echo "Installing collected libdeps into /usr/local/lib"; \
        mkdir -p /usr/local/lib; \
        find /opt/php-extensions-available/libdeps -type f -name '*.so*' -print0 | xargs -0 -r -I{} cp -a {} /usr/local/lib/ || true; \
        # ensure dynamic linker will search /usr/local/lib
        echo "/usr/local/lib" > /etc/ld.so.conf.d/php-extensions.conf || true; \
    fi; \
    # update dynamic linker cache (or fallback to LD_LIBRARY_PATH)
    if command -v ldconfig >/dev/null 2>&1; then ldconfig || true; else export LD_LIBRARY_PATH=/usr/local/lib:${LD_LIBRARY_PATH:-}; fi; \
    # runtime checks: list enabled modules and check shared lib dependencies for missing symbols
    if command -v php >/dev/null 2>&1; then \
        php -m > /opt/php-extensions-available/php-modules.txt || true; \
    fi; \
    # (MIB installation handled at build time if needed; removed runtime MIB installation)
    echo "Checking .so dependencies (ldd) for missing libraries..."; \
    > /opt/php-extensions-available/missing-libs.log; \
    if command -v ldd >/dev/null 2>&1; then \
        # collect any missing library names from ldd (one invocation per .so)
        find /usr/local/lib/php/extensions -type f -name '*.so' -print0 | xargs -0 -I{} sh -c 'ldd "$1" 2>/dev/null | sed -n "s/.*=> \(.*not found\).*/\1/p" | sed -n "/^/p"' _ '{}' >> /opt/php-extensions-available/missing-libs.log || true; \
        # more detailed scan: for each so, record missing libs per file (avoid process-substitution)
        find /usr/local/lib/php/extensions -type f -name '*.so' -print0 | xargs -0 -I{} sh -c 'miss=$(ldd "$1" 2>/dev/null | grep -E "not found" || true); if [ -n "$miss" ]; then echo "--- $1 ---" >> /opt/php-extensions-available/missing-libs.log; echo "$miss" >> /opt/php-extensions-available/missing-libs.log; fi' _ '{}' || true; \
    fi; \
    if [ -s /opt/php-extensions-available/missing-libs.log ]; then \
        echo "Warning: missing shared libs detected; see /opt/php-extensions-available/missing-libs.log"; \
        sed -n '1,200p' /opt/php-extensions-available/missing-libs.log || true; \
    else \
        echo "All extension shared libs appear satisfied."; \
        rm -f /opt/php-extensions-available/missing-libs.log || true; \
    fi; \
    # cleanup: remove copied lib directory (we keep ini files and extensions.map for introspection)
    rm -rf /opt/php-extensions-available/lib || true; \
    # keep only ini files and extensions.map under /opt/php-extensions-available
    find /opt/php-extensions-available -maxdepth 1 -type f ! -name '*.ini' ! -name 'extensions.map' -print0 | xargs -0 -r rm -f || true

# Ensure entrypoint exists and is executable
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh \
    && usermod -u 1000 www-data && groupmod -g 1000 www-data

WORKDIR /www

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
