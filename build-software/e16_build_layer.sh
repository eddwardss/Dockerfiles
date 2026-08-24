#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/output"
CCACHE_DIR="${HOME}/.ccache"

mkdir -p "${OUTPUT_DIR}" "${CCACHE_DIR}"

REPOS=(
  "e16"
  "e16-epplets"
  "e16-keyedit"
  "e16-themes"
  "e16-docs"
)
#e16-menuedit (зависимость от libglade-2.0)

echo "======================================================="
echo " Сборка стека e16 с использованием OverlayFS в Docker  "
echo "======================================================="

for REPO in "${REPOS[@]}"; do
  echo "-------------------------------------------------------"
  echo " Компиляция компонента: ${REPO}"
  echo "-------------------------------------------------------"

  # Добавлен флаг --privileged, без него ядро Linux заблокирует команду mount внутри контейнера
  docker run --rm -i --privileged \
    -v "${OUTPUT_DIR}:/output" \
    -v "${CCACHE_DIR}:/root/.ccache" \
    debian13-builder bash -s -- "${REPO}" << 'EOF'
      set -e

      CURRENT_REPO="$1"

      echo "--> Клонирование репозитория ${CURRENT_REPO}..."
      URL="https://git.enlightenment.org/e16/"
      URL="${URL}${CURRENT_REPO}"
      URL="${URL}.git"

      git clone --depth 1 "$URL" "/tmp/${CURRENT_REPO}"
      cd "/tmp/${CURRENT_REPO}"

      # Конфигурация с правильными флагами для каждого компонента
      if [ "$CURRENT_REPO" = "e16" ]; then
         echo "--> Применяем графические флаги для ядра e16..."
         ./autogen.sh --prefix=/usr --enable-glx --enable-composite
      elif [ "$CURRENT_REPO" = "e16-menuedit" ]; then
         echo "--> Обходим системную блокировку для e16-menuedit..."
         ./autogen.sh --prefix=/usr --enable-build
      else
         echo "--> Конфигурация компонента ${CURRENT_REPO}..."
         ./autogen.sh --prefix=/usr
      fi

      # Компиляция
      make -j$(nproc)

      echo "--> Подготовка слоев OverlayFS напрямую поверх системы..."
      rm -rf /output/upper /output/work
      mkdir -p /output/upper /output/work

      mount -t overlay overlay -o lowerdir=/usr,upperdir=/output/upper,workdir=/output/work /usr

      echo "--> Чистая инсталляция в системные пути под контролем OverlayFS..."
      make install

      # Сразу после установки размонтируем системный /usr, чтобы вернуть его в исходное состояние
      umount -l /usr

      # Подготавливаем чистую структуру для DEB-пакета
      DEB_ROOT="/tmp/deb-package"
      rm -rf "$DEB_ROOT"
      mkdir -p "$DEB_ROOT/DEBIAN"

      # Переносим скомпилированную структуру из верхнего слоя OverlayFS в корень пакета
      if [ -d "/output/upper" ]; then
         # Переносим все созданные подкаталоги (bin, lib, share, include)
         cp -a /output/upper/* "$DEB_ROOT/" 2>/dev/null || true
      fi

      # Очищаем временные рабочие папки OverlayFS с диска хоста
      rm -rf /output/upper /output/work

      # ИСПРАВЛЕНИЕ: Удаляем пустые папки СТРОГО внутри каталога usr, 
      # чтобы случайно не снести служебную папку DEBIAN!
      if [ -d "$DEB_ROOT/usr" ]; then
         find "$DEB_ROOT/usr" -type d -empty -delete 2>/dev/null || true
      fi

      # Жесткое версионирование компонентов
      case "$CURRENT_REPO" in
         "e16") VERSION="1.0.31" ;;
         "e16-epplets") VERSION="0.18" ;;
         "e16-keyedit") VERSION="0.10" ;;
         "e16-themes") VERSION="1.0.3" ;;
         "e16-docs") VERSION="0.99.0" ;;
         "e16-menuedit") VERSION="0.10" ;;
         *) VERSION="1.0.0" ;;
      esac

      # Настройка зависимостей
      if [ "$CURRENT_REPO" = "e16" ]; then
         DEPS="libimlib2, libpango-1.0-0, libx11-6, libxcomposite1, libxext6, libxft2, libxinerama1, libxrandr2, libxrender1, libsndfile1, libxpresent1"
      else
         DEPS="e16"
      fi
      # === КОНЕЦ ИСПРАВЛЕННОГО БЛОКА OVERLAYFS ===

      # Генерируем файл control
      cat << CONTROL_EOF > "$DEB_ROOT/DEBIAN/control"
Package: ${CURRENT_REPO}
Version: ${VERSION}-1
Section: x11
Priority: optional
Architecture: amd64
Depends: ${DEPS}
Maintainer: builder@local
Description: Complete Enlightenment E16 component - ${CURRENT_REPO}
 Built cleanly using Native OverlayFS layers inside Docker.
CONTROL_EOF

      echo "--> Упаковка собранного слоя в .deb пакет..."
      chown -R root:root "$DEB_ROOT"
      dpkg-deb --build "$DEB_ROOT" "/output/${CURRENT_REPO}_${VERSION}-1_amd64.deb"
      
      echo "--> Компонент ${CURRENT_REPO} успешно упакован!"
EOF

done

echo "======================================================="
echo " Сборка завершена! Все чистые пакеты лежат в: "
echo " ${OUTPUT_DIR}/"
echo "======================================================="
