#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/output"
CCACHE_DIR="${HOME}/.ccache"

mkdir -p "${OUTPUT_DIR}" "${CCACHE_DIR}"

# Полный список репозиториев
REPOS=(
  "e16"
  "e16-epplets"
  "e16-keyedit"
  "e16-themes"
  "e16-docs"
)
#e16-menuedit (зависимость от libglade-2.0)

echo "======================================================="
echo " Сборка полного стека графической среды e16 в Docker   "
echo "======================================================="

for REPO in "${REPOS[@]}"; do
  echo "-------------------------------------------------------"
  echo " Начинается сборка компонента: ${REPO}"
  echo "-------------------------------------------------------"

  docker run --rm -i \
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

      # Шаг 1. Фиксируем точный текстовый список файлов до инсталляции
      echo "--> Сканирование системы до инсталляции..."
      rm -f /tmp/files_before.txt /tmp/files_after.txt /tmp/files_diff.txt
      find /usr -type f -o -type l | sort > /tmp/files_before.txt

      # Шаг 2. Реальная инсталляция софта в систему контейнера
      echo "--> Инсталляция в систему контейнера..."
      make install

      # Шаг 3. Фиксируем список файлов после инсталляции и вычисляем чистую разницу
      find /usr -type f -o -type l | sort > /tmp/files_after.txt
      comm -13 /tmp/files_before.txt /tmp/files_after.txt > /tmp/files_diff.txt

      # Шаг 4. Подготавливаем чистую структуру DEB пакета
      DEB_ROOT="/tmp/deb-package"
      rm -rf "$DEB_ROOT"
      mkdir -p "$DEB_ROOT/DEBIAN"

      # Шаг 5. Копируем строго новые файлы по списку разницы
      echo "--> Изолированное формирование дерева каталогов пакета..."
      while IFS= read -r file; do
         # Проверяем, что файл действительно лежит в /usr и физически существует
         if [ -f "$file" ] || [ -L "$file" ]; then
            dest_dir="${DEB_ROOT}$(dirname "$file")"
            mkdir -p "$dest_dir"
            cp -d "$file" "$dest_dir/"
         fi
      done < /tmp/files_diff.txt

      # Версионирование компонентов
      case "$CURRENT_REPO" in
         "e16") VERSION="1.0.31" ;;
         "e16-epplets") VERSION="0.18" ;;
         "e16-keyedit") VERSION="0.10" ;;
         "e16-themes") VERSION="1.0.3" ;;
         "e16-docs") VERSION="0.99.0" ;;
         "e16-menuedit") VERSION="0.1" ;;
         *) VERSION="1.0.0" ;;
      esac

      # Настройка системных рантайм-зависимостей Debian
      if [ "$CURRENT_REPO" = "e16" ]; then
         DEPS="libimlib2, libpango-1.0-0, libx11-6, libxcomposite1, libxext6, libxft2, libxinerama1, libxrandr2, libxrender1, libsndfile1, libxpresent1"
      else
         DEPS="e16"
      fi

      #倾Генерируем официальный control файл
      cat << CONTROL_EOF > "$DEB_ROOT/DEBIAN/control"
Package: ${CURRENT_REPO}
Version: ${VERSION}-1
Section: x11
Priority: optional
Architecture: amd64
Depends: ${DEPS}
Maintainer: builder@local
Description: Complete Enlightenment E16 component - ${CURRENT_REPO}
 Built cleanly inside Docker for Debian 13 Trixie.
CONTROL_EOF

      echo "--> Упаковка пакета через dpkg-deb..."
      chown -R root:root "$DEB_ROOT"
      dpkg-deb --build "$DEB_ROOT" "/output/${CURRENT_REPO}_${VERSION}-1_amd64.deb"
      
      echo "--> Компонент ${CURRENT_REPO} УСПЕШНО упакован в .deb!"
EOF

done

echo "======================================================="
echo " Сборка завершена! ВСЕ ПАКЕТЫ лежат в папке: "
echo " ${OUTPUT_DIR}/"
echo "======================================================="
