#!/usr/bin/env bash
set -euo pipefail

# Cleanup script для подготовки k8s backup к восстановлению на Minikube
# Использует Стратегию 2 с удалением PV/PVC и replicas=0

BACKUP_DIR="${1:-.}"
DRY_RUN="${2:-false}"

if [ "$DRY_RUN" = "true" ]; then
  echo "🔍 DRY RUN MODE - никакие файлы не будут изменены"
  DRY_PREFIX="echo [DRY RUN] "
else
  echo "✅ PRODUCTION MODE - файлы будут изменены"
  DRY_PREFIX=""
fi

echo ""
echo "📁 Backup директория: $BACKUP_DIR"
echo ""

# Функция для проверки yq
check_yq() {
  if ! command -v yq &> /dev/null; then
    echo "❌ yq не найден. Пожалуйста, установите yq:"
    echo "   Windows (Chocolatey): choco install yq"
    echo "   Windows (Scoop): scoop install yq"
    echo "   macOS: brew install yq"
    echo "   Linux: sudo apt install yq"
    echo ""
    echo "   Или скачайте отсюда: https://github.com/mikefarah/yq/releases"
    exit 1
  fi
  echo "✓ yq найден: $(yq --version)"
}

# Функция для создания резервной копии
create_backup() {
  if [ ! -d "$BACKUP_DIR.backup" ]; then
    if [ "$DRY_RUN" = "true" ]; then
      echo "  [DRY RUN] Была бы создана резервная копия в: $BACKUP_DIR.backup"
    else
      echo "  📦 Создаю резервную копию..."
      cp -r "$BACKUP_DIR" "$BACKUP_DIR.backup"
      echo "  ✓ Резервная копия создана: $BACKUP_DIR.backup"
    fi
  else
    echo "  ⚠️  Резервная копия уже существует: $BACKUP_DIR.backup"
  fi
}

# Функция для удаления файлов
remove_files() {
  local pattern="$1"
  local description="$2"
  
  echo ""
  echo "🗑️  $description"
  
  local count=$(find "$BACKUP_DIR" -type f -path "$pattern" 2>/dev/null | wc -l || echo 0)
  
  if [ "$count" -gt 0 ]; then
    if [ "$DRY_RUN" = "true" ]; then
      echo "  [DRY RUN] Были бы удалены $count файлов:"
      find "$BACKUP_DIR" -type f -path "$pattern" 2>/dev/null | head -5
      [ "$count" -gt 5 ] && echo "  ... и еще $((count - 5)) файлов"
    else
      find "$BACKUP_DIR" -type f -path "$pattern" 2>/dev/null -delete
      echo "  ✓ Удалено $count файлов"
    fi
  else
    echo "  ℹ️  Файлов не найдено"
  fi
}

# Функция для применения yq команд
apply_yq() {
  local file_pattern="$1"
  local yq_command="$2"
  local description="$3"
  
  echo ""
  echo "⚙️  $description"
  
  # Подсчет файлов
  local files_array=()
  while IFS= read -r -d '' file; do
    files_array+=("$file")
  done < <(find "$BACKUP_DIR" -type f -name "*.yaml" -path "$file_pattern" -print0 2>/dev/null)
  
  local count=${#files_array[@]}
  
  if [ "$count" -gt 0 ]; then
    if [ "$DRY_RUN" = "true" ]; then
      echo "  [DRY RUN] Команда yq будет применена к $count файлам:"
      echo "  yq eval '$yq_command' -i"
      for ((i=0; i<3 && i<count; i++)); do
        echo "    ${files_array[$i]}"
      done
      [ "$count" -gt 3 ] && echo "  ... и еще $((count - 3)) файлам"
    else
      # Применяем команду к каждому файлу с небольшой задержкой
      local processed=0
      for file in "${files_array[@]}"; do
        yq eval "$yq_command" -i "$file" 2>/dev/null || true
        processed=$((processed + 1))
        # Показываем прогресс каждые 50 файлов
        if [ $((processed % 50)) -eq 0 ]; then
          echo "  ... обработано $processed/$count"
        fi
      done
      echo "  ✓ Применено к $count файлам"
    fi
  else
    echo "  ℹ️  Файлов не найдено"
  fi
}

# =============================================================================
# ОСНОВНЫЕ ДЕЙСТВИЯ
# =============================================================================

echo "============================================================"
echo "   Очистка k8s backup для Minikube (Стратегия 2)"
echo "============================================================"
echo ""

# Шаг 1: Проверка yq
echo "[1/7] Проверка зависимостей..."
check_yq

# Шаг 2: Создание резервной копии
echo ""
echo "[2/7] Создание резервной копии..."
create_backup

# Шаг 3: Удаление PV файлов
remove_files "**/persistentvolumes/*.yaml" "Удаление PersistentVolumes"

# Шаг 4: Удаление PVC файлов
remove_files "**/persistentvolumeclaims/*.yaml" "Удаление PersistentVolumeClaims"

# Шаг 5: Удаление default-token секретов
remove_files "**/secrets/default-token-*.yaml" "Удаление auto-generated Service Account токенов"

# Шаг 6: Очистка метаданных со всех YAML
apply_yq "*/**/*.yaml" \
  'del(.metadata.uid, .metadata.resourceVersion, .metadata.generation, .metadata.creationTimestamp, .metadata.selfLink, .metadata.managedFields, .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"])' \
  "Удаление метаданных специфичных для оригинального кластера"

# Шаг 7: Удаление nodeSelector из deployments
apply_yq "**/deployments/*.yaml" \
  'del(.spec.template.spec.nodeSelector, .spec.template.spec.affinity)' \
  "Удаление nodeSelector и affinity из Deployments"

# Шаг 8: Удаление nodeSelector из DaemonSets
apply_yq "**/daemonsets/*.yaml" \
  'del(.spec.template.spec.nodeSelector, .spec.template.spec.affinity)' \
  "Удаление nodeSelector и affinity из DaemonSets"

# Шаг 9: Удаление nodeSelector из StatefulSets
apply_yq "**/statefulsets/*.yaml" \
  'del(.spec.template.spec.nodeSelector, .spec.template.spec.affinity)' \
  "Удаление nodeSelector и affinity из StatefulSets"

# Шаг 10: Установка replicas = 1 для Deployments
apply_yq "**/deployments/*.yaml" \
  '.spec.replicas = 1' \
  "Установка replicas = 1 для Deployments (вместо replicas: 0)"

# Шаг 11: Удаление service account UIDs из аннотаций
apply_yq "**/secrets/*.yaml" \
  'del(.metadata.annotations["kubernetes.io/service-account.uid"])' \
  "Удаление service account UID аннотаций из Secrets"

echo ""
echo "============================================================"
if [ "$DRY_RUN" = "true" ]; then
  echo "✅ DRY RUN ЗАВЕРШЕН"
  echo ""
  echo "Команды для выполнения реальной очистки:"
  echo "  ./cleanup.sh <backup-dir>"
  echo ""
  echo "Или для конкретного backup:"
  echo "  ./cleanup.sh ./dev-anthill-k8s-backup-20260415161101"
else
  echo "✅ ОЧИСТКА ЗАВЕРШЕНА"
  echo ""
  echo "Резервная копия сохранена в: $BACKUP_DIR.backup"
  echo ""
  echo "Следующие шаги:"
  echo "  1. Отключите корпоративный VPN"
  echo "  2. Запустите: ./restore.sh <backup-dir>"
  echo "  3. Проверьте логи: kubectl logs -n <namespace> <pod>"
fi
echo "============================================================"
