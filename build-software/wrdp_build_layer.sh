#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/output"

mkdir -p "${OUTPUT_DIR}"

REPO="wrdp"
VERSION="0.1.0"

echo "======================================================="
echo " Сборка WRDP + systemd-юнит с OverlayFS в Docker       "
echo "======================================================="

docker run --rm -i --privileged --network=host \
  -e http_proxy=http://127.0.0.1:1080 \
  -e https_proxy=http://127.0.0.1:1080 \
  -e CARGO_TERM_COLOR=always \
  -e PKG_CONFIG_PATH=/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/share/pkgconfig \
  -v "${OUTPUT_DIR}:/output" \
  debian13-builder bash -s -- "${REPO}" "${VERSION}" << 'EOF'
    set -e

    CURRENT_REPO="$1"
    VERSION="$2"

    echo "--> Клонирование репозитория ${CURRENT_REPO} во временную память контейнера..."
    rm -rf "/tmp/${CURRENT_REPO}"
    git clone --depth 1 "https://github.com/rcarmo/wrdp.git" "/tmp/${CURRENT_REPO}"
    cd "/tmp/${CURRENT_REPO}"

    echo "--> Компиляция Rust-проекта..."
    cargo build --release --verbose

    echo "--> Подготовка структуры слоев..."
    rm -rf /output/upper /output/work
    mkdir -p /output/upper /output/work

    # Механизм гарантированной очистки: размонтирует и удалит мусор, даже если dpkg-deb упадет
    cleanup() {
        echo "--> Аварийная или плановая очистка ресурсов..."
        umount -l /usr 2>/dev/null || true
        rm -rf /output/upper /output/work
    }
    trap cleanup EXIT

    echo "--> Монтирование чистого системного слоя /usr..."
    mount -t overlay overlay -o lowerdir=/usr,upperdir=/output/upper,workdir=/output/work /usr

    echo "--> Установка полного стека бинарных файлов (wrdp, wrdp-sesman, wrdpctl)..."
    mkdir -p /usr/bin
    cp target/release/wrdp /usr/bin/wrdp
    cp target/release/wrdp-sesman /usr/bin/wrdp-sesman
    cp target/release/wrdpctl /usr/bin/wrdpctl

    echo "--> Добавление системного systemd-юнита..."
    # В Debian 13 /lib/systemd/system является ссылкой на /usr/lib/systemd/system (UsrMerge),
    # поэтому пишем строго в /usr, чтобы OverlayFS гарантированно перехватил файл!
    mkdir -p /usr/lib/systemd/system
    cat << SYSTEMD_EOF > /usr/lib/systemd/system/wrdp.service
[Unit]
Description=WRDP - RDP architecture for Wayland compositors
After=network.target systemd-user-sessions.service

[Service]
Type=simple
ExecStart=/usr/bin/wrdp --listen 0.0.0.0:3389
Restart=always
RestartSec=5
User=root
Group=root

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF

    echo "--> Демонтирование системного слоя..."
    umount -l /usr

    # Подготавливаем структуру пакета
    DEB_ROOT="/tmp/deb-package"
    rm -rf "$DEB_ROOT"
    mkdir -p "$DEB_ROOT/DEBIAN"

    echo "--> Перенос файлов из перехваченного слоя OverlayFS..."
    if [ -d "/output/upper" ] && [ "$(ls -A /output/upper)" ]; then
       cp -a /output/upper/* "$DEB_ROOT/" 2>/dev/null || true
    else
       echo "КРИТИЧЕСКАЯ ОШИБКА: Слой OverlayFS оказался пуст! Файлы не перехвачены."
       exit 1
    fi

    # Скрипты автоматизации пакета
    cat << POSTINST_EOF > "$DEB_ROOT/DEBIAN/postinst"
#!/bin/sh
set -e
if [ "\$1" = "configure" ]; then
    echo "--> Обновление конфигурации systemd..."
    systemctl daemon-reload || true
fi
POSTINST_EOF
    chmod 755 "$DEB_ROOT/DEBIAN/postinst"

    cat << PRERM_EOF > "$DEB_ROOT/DEBIAN/prerm"
#!/bin/sh
set -e
if [ "\$1" = "remove" ] || [ "\$1" = "purge" ]; then
    echo "--> Остановка службы wrdp..."
    systemctl stop wrdp.service || true
    systemctl disable wrdp.service || true
fi
PRERM_EOF
    chmod 755 "$DEB_ROOT/DEBIAN/prerm"

    if [ -d "$DEB_ROOT/usr" ]; then
       find "$DEB_ROOT/usr" -type d -empty -delete 2>/dev/null || true
    fi

    DEPS="libwayland-client0, libpixman-1-0, libssl3t64, libxkbcommon0, libpipewire-0.3-0, libva2, libgbm1, libpam0g"

    cat << CONTROL_EOF > "$DEB_ROOT/DEBIAN/control"
Package: ${CURRENT_REPO}
Version: ${VERSION}-1
Section: net
Priority: optional
Architecture: amd64
Depends: ${DEPS}
Maintainer: builder@local
Description: WRDP - RDP server architecture for Wayland compositors
 Built cleanly using Native OverlayFS layers and Cargo inside Docker.
 Includes systemd service unit and full binary tools stack.
CONTROL_EOF

    echo "--> Упаковка собранного слоя в .deb пакет..."
    chown -R root:root "$DEB_ROOT"
    dpkg-deb --build "$DEB_ROOT" "/output/${CURRENT_REPO}_${VERSION}-1_amd64.deb"
    
    echo "--> Компонент ${CURRENT_REPO} успешно упакован!"
EOF

echo "======================================================="
echo " Сборка завершена! Пакет лежит в: "
echo " ${OUTPUT_DIR}/${REPO}_${VERSION}-1_amd64.deb"
echo "======================================================="
