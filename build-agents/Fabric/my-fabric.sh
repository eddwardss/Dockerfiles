#!/bin/bash

# Настройки для Ollama и Fabric
VENDOR="Ollama"
MODEL="qwen2.5-coder-3b:latest"
URL="http://localhost:11434"
WORK_DIR="/mnt/newdisk/builds"

# Функция для запуска Docker с нужными переменными
run_fabric_docker() {
    docker run --rm -i \
      --network=host \
      -v "${WORK_DIR}:/workspace" \
      -e DEFAULT_VENDOR="$VENDOR" \
      -e DEFAULT_MODEL="$MODEL" \
      -e OLLAMA_HOST="$URL" \
      -e OLLAMA_API_URL="$URL" \
      my-fabric "$@"
}

# 1. Проверяем, пришли ли данные через конвейер (stdin)
if [ ! -t 0 ]; then
    # Если данные вливаются через pipe, просто передаем их дальше
    cat | run_fabric_docker "$@"

# 2. Если конвейер пуст, проверяем: является ли первый аргумент существующим файлом
elif [ -f "$1" ]; then
    FILE_PATH="$1"
    shift
    cat "$FILE_PATH" | run_fabric_docker "$@"

# 3. Если это не конвейер и не файл, значит пользователь просто передает флаги (например, --listpatterns)
else
    run_fabric_docker "$@"
fi
