#!/bin/bash
# =============================================================================
# VPS SQLite バックアップ環境セットアップスクリプト
# =============================================================================
#
# 使い方:
#   ssh deploy@162.43.7.199 'bash -s' < scripts/setup-vps-backup.sh
#
# または VPS上で直接:
#   bash setup-vps-backup.sh
#
# =============================================================================

set -euo pipefail

BACKUP_ROOT="/var/backups/sqlite"
APPS=("amazon-profit-finder" "bridalbria" "houjin-db" "kicyoudaikou" "seo-master")
TYPES=("daily" "weekly" "deploy")

echo "=== SQLite バックアップ セットアップ開始 ==="
echo ""

# --- 1. sqlite3 の存在確認 ---
echo ">>> [1/5] sqlite3 確認..."
if command -v sqlite3 &>/dev/null; then
  echo "    sqlite3 OK: $(sqlite3 --version)"
else
  echo "    エラー: sqlite3 がインストールされていません"
  echo "    >>> sudo apt install sqlite3 を実行してください"
  exit 1
fi

# --- 2. ディレクトリ作成 ---
echo ">>> [2/5] ディレクトリ作成..."
sudo mkdir -p "$BACKUP_ROOT"
sudo chown "$(whoami):$(whoami)" "$BACKUP_ROOT"

for APP in "${APPS[@]}"; do
  for TYPE in "${TYPES[@]}"; do
    mkdir -p "$BACKUP_ROOT/$APP/$TYPE"
  done
  echo "    $APP/ (daily, weekly, deploy)"
done
echo "    ディレクトリ作成完了"

# --- 3. バックアップスクリプト配置 ---
echo ">>> [3/5] バックアップスクリプト配置..."

cat > "$BACKUP_ROOT/backup.sh" << 'BACKUP_SCRIPT_EOF'
#!/bin/bash
# =============================================================================
# SQLite バックアップスクリプト（全プロジェクト共通）
# =============================================================================
#
# 使い方:
#   backup.sh <daily|weekly|deploy> [app_name]
#
# 例:
#   backup.sh daily              # 全アプリの日次バックアップ
#   backup.sh deploy houjin-db   # houjin-db のデプロイ時バックアップ
#   backup.sh weekly             # 全アプリの週次バックアップ
#
# =============================================================================

set -uo pipefail

BACKUP_ROOT="/var/backups/sqlite"
LOG_FILE="$BACKUP_ROOT/backup.log"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# --- 世代管理: 保持数 ---
DAILY_KEEP=7
WEEKLY_KEEP=4
DEPLOY_KEEP=5

# --- プロジェクト定義 ---
# 形式: "app_name|app_dir|db_resolve_method|static_db_path"
#   db_resolve_method:
#     env    = .env の DATABASE_URL から相対パスを解決
#     static = 固定パスを使用
PROJECTS=(
  "amazon-profit-finder|/var/www/amazon-profit-finder|static|data/jan_asin_cache.db"
  "bridalbria|/var/www/bridalbria|env|"
  "houjin-db|/var/www/houjin-db|env|"
  "kicyoudaikou|/var/www/kicyoudaikou|env|"
  "seo-master|/var/www/seo-master|env|"
)

# =============================================================================
# ユーティリティ関数
# =============================================================================

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
  echo "$msg" | tee -a "$LOG_FILE"
}

# .env の DATABASE_URL からDBファイルの絶対パスを解決する
resolve_db_path() {
  local app_dir="$1"
  local method="$2"
  local static_path="$3"

  if [ "$method" = "static" ]; then
    echo "$app_dir/$static_path"
    return
  fi

  # env method: .env から DATABASE_URL を読み取る
  local env_file="$app_dir/.env"
  if [ ! -f "$env_file" ]; then
    echo ""
    return
  fi

  # DATABASE_URL="file:./prisma/dev.db" のような形式からパスを抽出
  local db_url
  db_url=$(grep "^DATABASE_URL" "$env_file" 2>/dev/null | head -1 | sed 's/^DATABASE_URL=//' | sed 's/^[" ]*//' | sed 's/[" ]*$//')

  if [ -z "$db_url" ]; then
    echo ""
    return
  fi

  # file:./ プレフィックスを除去して相対パスを取得
  local relative_path
  relative_path=$(echo "$db_url" | sed 's|^file:\./||' | sed 's|^file:||')

  echo "$app_dir/$relative_path"
}

# sqlite3 .backup で安全にバックアップを取る
backup_db() {
  local app_name="$1"
  local db_path="$2"
  local backup_type="$3"

  local dest_dir="$BACKUP_ROOT/$app_name/$backup_type"
  local dest_file="$dest_dir/${app_name}_${TIMESTAMP}.db"

  # DBファイルの存在確認
  if [ ! -f "$db_path" ]; then
    log "  警告: DBファイルが見つかりません: $db_path（スキップ）"
    return 1
  fi

  # バックアップ実行（sqlite3 .backup はDB使用中でも安全）
  if sqlite3 "$db_path" ".backup '$dest_file'" 2>/dev/null; then
    # バックアップファイルのサイズ確認
    local size
    size=$(du -h "$dest_file" | cut -f1)
    if [ -s "$dest_file" ]; then
      log "  OK: $app_name ($size) → $dest_file"
      return 0
    else
      log "  警告: バックアップファイルが空です: $dest_file"
      rm -f "$dest_file"
      return 1
    fi
  else
    log "  エラー: sqlite3 .backup 失敗: $db_path"
    rm -f "$dest_file"
    return 1
  fi
}

# 古いバックアップを削除（世代管理）
rotate_backups() {
  local app_name="$1"
  local backup_type="$2"
  local keep_count="$3"

  local backup_dir="$BACKUP_ROOT/$app_name/$backup_type"

  # .db ファイルを日付降順でリスト、keep_count を超えたら削除
  local files
  files=$(ls -t "$backup_dir"/*.db 2>/dev/null || true)

  if [ -z "$files" ]; then
    return
  fi

  local count=0
  while IFS= read -r file; do
    count=$((count + 1))
    if [ "$count" -gt "$keep_count" ]; then
      rm -f "$file"
      log "  削除（ローテーション）: $file"
    fi
  done <<< "$files"
}

# 保持数を取得
get_keep_count() {
  local backup_type="$1"
  case "$backup_type" in
    daily)  echo "$DAILY_KEEP" ;;
    weekly) echo "$WEEKLY_KEEP" ;;
    deploy) echo "$DEPLOY_KEEP" ;;
    *)      echo "5" ;;
  esac
}

# =============================================================================
# メイン処理
# =============================================================================

# 引数チェック
BACKUP_TYPE="${1:-}"
FILTER_APP="${2:-}"

if [ -z "$BACKUP_TYPE" ]; then
  echo "使い方: $0 <daily|weekly|deploy> [app_name]"
  exit 1
fi

if [[ ! "$BACKUP_TYPE" =~ ^(daily|weekly|deploy)$ ]]; then
  echo "エラー: 不正なバックアップ種別: $BACKUP_TYPE"
  echo "使い方: $0 <daily|weekly|deploy> [app_name]"
  exit 1
fi

KEEP_COUNT=$(get_keep_count "$BACKUP_TYPE")

log "=== バックアップ開始: $BACKUP_TYPE ==="

SUCCESS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

for PROJECT in "${PROJECTS[@]}"; do
  IFS='|' read -r app_name app_dir method static_path <<< "$PROJECT"

  # アプリフィルタが指定されていて、一致しなければスキップ
  if [ -n "$FILTER_APP" ] && [ "$app_name" != "$FILTER_APP" ]; then
    continue
  fi

  log "--- $app_name ---"

  # アプリディレクトリの存在確認
  if [ ! -d "$app_dir" ]; then
    log "  警告: アプリディレクトリが見つかりません: $app_dir（スキップ）"
    SKIP_COUNT=$((SKIP_COUNT + 1))
    continue
  fi

  # DBパス解決
  db_path=$(resolve_db_path "$app_dir" "$method" "$static_path")

  if [ -z "$db_path" ]; then
    log "  警告: DBパスを解決できません（.envにDATABASE_URLがない？）（スキップ）"
    SKIP_COUNT=$((SKIP_COUNT + 1))
    continue
  fi

  # バックアップ実行
  if backup_db "$app_name" "$db_path" "$BACKUP_TYPE"; then
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi

  # 世代管理
  rotate_backups "$app_name" "$BACKUP_TYPE" "$KEEP_COUNT"
done

log "=== バックアップ完了: 成功=$SUCCESS_COUNT 失敗=$FAIL_COUNT スキップ=$SKIP_COUNT ==="

# 全て失敗した場合のみ異常終了
if [ "$SUCCESS_COUNT" -eq 0 ] && [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi

exit 0
BACKUP_SCRIPT_EOF

chmod +x "$BACKUP_ROOT/backup.sh"
echo "    backup.sh 配置完了"

# --- 4. cron 設定 ---
echo ">>> [4/5] cron 設定..."

# タイムゾーン確認
CURRENT_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "unknown")
echo "    現在のタイムゾーン: $CURRENT_TZ"

if [ "$CURRENT_TZ" = "Asia/Tokyo" ] || [ "$CURRENT_TZ" = "JST" ]; then
  DAILY_HOUR=3
  WEEKLY_HOUR=4
  echo "    JST検出: 日次=3:00, 週次=日曜4:00"
else
  # UTC想定: JST-9
  DAILY_HOUR=18
  WEEKLY_HOUR=19
  echo "    UTC想定: 日次=18:00 UTC (3:00 JST), 週次=日曜19:00 UTC (4:00 JST)"
fi

# crontab に追記（既存のsqlite-backup行は除去してから追加）
CRON_MARKER="# sqlite-backup"
(crontab -l 2>/dev/null | grep -v "$CRON_MARKER") | {
  cat
  echo "0 $DAILY_HOUR * * * $BACKUP_ROOT/backup.sh daily >> $BACKUP_ROOT/cron.log 2>&1 $CRON_MARKER"
  echo "0 $WEEKLY_HOUR * * 0 $BACKUP_ROOT/backup.sh weekly >> $BACKUP_ROOT/cron.log 2>&1 $CRON_MARKER"
} | crontab -

echo "    cron 設定完了:"
crontab -l | grep "$CRON_MARKER" | sed 's/^/    /'

# --- 5. テストバックアップ ---
echo ">>> [5/5] テストバックアップ実行..."
echo ""
"$BACKUP_ROOT/backup.sh" daily
echo ""

# --- 完了 ---
echo "=== セットアップ完了 ==="
echo ""
echo "ファイル構成:"
echo "  スクリプト: $BACKUP_ROOT/backup.sh"
echo "  ログ:       $BACKUP_ROOT/backup.log"
echo "  cronログ:   $BACKUP_ROOT/cron.log"
echo ""
echo "手動実行:"
echo "  $BACKUP_ROOT/backup.sh daily              # 全アプリ日次バックアップ"
echo "  $BACKUP_ROOT/backup.sh deploy houjin-db   # 特定アプリのデプロイ時バックアップ"
echo "  $BACKUP_ROOT/backup.sh weekly             # 全アプリ週次バックアップ"
