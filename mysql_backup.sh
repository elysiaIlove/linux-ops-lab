#!/bin/bash
# ============================================================
# MySQL 备份脚本
# 功能：全量备份指定库 → gzip 压缩 → 校验完整性 → 清理过期备份
# 特性：flock 防并发、set -euo pipefail 严格模式、备份后校验
# 用法：./mysql_backup.sh [数据库名]   默认 opslab
#
# 设计说明：
#   1. flock 单实例锁：防止上一次备份未完成时 cron 又启动一个，
#      两个 mysqldump 并发执行可能互相影响
#   2. set -euo pipefail：命令失败、未定义变量、管道任一环节失败
#      都立即退出，避免"静默失败"
#   3. gzip -t 校验 + 文件大小阈值：不可验证的备份等于没有备份；
#      备份命令可能"成功退出但产出空文件"（权限、磁盘满等情况）
#   4. find -mtime +N -delete：保留策略，否则备份文件会无限增长
#      最终把磁盘写满
#
# 定时执行（crontab）：
#   30 2 * * * /root/ops-lab/scripts/mysql_backup.sh \
#       >> /root/ops-lab/logs/backup.log 2>&1
# ============================================================
set -euo pipefail

DB="${1:-opslab}"
BACKUP_DIR="$HOME/ops-lab/backup"
KEEP_DAYS=7
MIN_SIZE=1024                 # 小于 1KB 视为异常备份
TS=$(date '+%Y%m%d_%H%M%S')
FILE="$BACKUP_DIR/${DB}_${TS}.sql.gz"

# 单实例锁：防止上一次备份未完成时 cron 又启动一个
LOCK="/tmp/mysql_backup.lock"
exec 9>"$LOCK"
if ! flock -n 9; then
    echo "[$(date '+%F %T')] [SKIP] 上一次备份仍在进行，本次跳过"
    exit 0
fi

mkdir -p "$BACKUP_DIR"

echo "[$(date '+%F %T')] 开始备份 $DB"

mysqldump \
    --single-transaction \
    --routines --triggers --events \
    --default-character-set=utf8mb4 \
    --databases "$DB" | gzip > "$FILE"

# --- 校验 1：gzip 包完整性 ---
gzip -t "$FILE"

# --- 校验 2：文件大小是否合理 ---
SIZE=$(stat -c%s "$FILE")
if [ "$SIZE" -lt "$MIN_SIZE" ]; then
    echo "[$(date '+%F %T')] [ERROR] 备份文件异常（仅 ${SIZE} 字节），保留文件待排查"
    exit 1
fi

echo "[$(date '+%F %T')] 备份成功：$FILE （$((SIZE/1024)) KB）"

# --- 清理过期备份 ---
DELETED=$(find "$BACKUP_DIR" -name "${DB}_*.sql.gz" -type f -mtime "+$KEEP_DAYS" -print -delete | wc -l)
echo "[$(date '+%F %T')] 清理过期备份 ${DELETED} 个（保留 ${KEEP_DAYS} 天）"

# --- 输出当前备份列表 ---
echo "[$(date '+%F %T')] 当前备份文件："
ls -lh "$BACKUP_DIR"/${DB}_*.sql.gz | tail -5
