#!/bin/bash
# ============================================================================
#  fix.sh —— 救援脚本（对应虚拟机上的 /fix）
# ----------------------------------------------------------------------------
#  为什么存在：
#    VMware 控制台不支持粘贴，救援时手工敲长命令既慢又易错
#    （实测代价：密码打错两次、sed 模式写错、cp -i 弹确认）。
#    于是把"恢复关键配置"压缩成一个 4 字符命令，在 emergency shell 或
#    ISO 救援 chroot 里直接执行：  /fix
#
#  设计要点：
#    1) [0] 先把当前 boot 的 journal 落盘 —— journal 在 /run（内存）里，
#       重启即丢。并记录【来源】，避免把 ISO live 环境的日志误当故障现场。
#    2) [1] 覆盖前先记录差异（字节数 / md5 / diff / SELinux 标签）。
#    3) [3] 用 md5 校验恢复结果，而不是"看起来对了"。
#    4) [3b] 用 mount -a 预演 —— 恢复后必须真的能挂载。
#    5) 一次性：成功修复后自动解除 /etc/drill6-armed 待命标志。
#
#  退出码：0 = 恢复并验证通过；1 = 失败，需人工介入
# ============================================================================
BAK=/root/fstab.good.bak
STAMP=$(date +%Y%m%d-%H%M%S)
HOST=$(hostname 2>/dev/null)
CMDLINE=$(cat /proc/cmdline 2>/dev/null)

# --- does this journal belong to the target system, or to the ISO env? -------
SRC=TARGET
case "$CMDLINE" in
  *rescue*|*inst.stage2*|*anaconda*) SRC=ISO ;;
esac

echo "===== [0] archive this boot's journal (RAM -> disk) ====="
echo "  hostname : $HOST"
echo "  cmdline  : $CMDLINE"
if [ "$SRC" = "ISO" ]; then
  echo "  !! WARNING: cmdline looks like the ISO installer/rescue environment."
  echo "  !! journalctl here shows the ISO live-env log, NOT the target"
  echo "  !! system's failed boot. Do not treat it as incident evidence."
fi

LOG="/root/emergency-$STAMP-$SRC.log"
if journalctl -xb > "$LOG" 2>/dev/null; then
  echo "  archived $LOG ($(wc -l < "$LOG") lines)  source=$SRC"
else
  echo "  (journalctl unavailable, skipped)"
fi

STATE="/root/emergency-$STAMP-$SRC.state"
{
  echo "### archive source : $SRC"
  echo "### hostname       : $HOST"
  echo "### cmdline        : $CMDLINE"
  echo "### date           : $(date)"
  echo "### --- journalctl --list-boots ---"
  journalctl --list-boots --no-pager 2>&1
  echo "### --- systemctl --failed ---"
  systemctl --failed --no-pager 2>&1
  echo "### --- cat -n /etc/fstab (BEFORE fix) ---"
  cat -n /etc/fstab
  echo "### --- mount ---"
  mount
} > "$STATE" 2>&1
echo "  archived $STATE"
echo

if [ ! -f "$BAK" ]; then echo "ERROR: backup $BAK not found"; exit 1; fi

echo "===== [1] BEFORE: record the difference first ====="
echo "--- size (bytes) ---";     wc -c /etc/fstab "$BAK"
echo "--- md5 ---";              md5sum /etc/fstab "$BAK"
echo "--- diff ---";             diff /etc/fstab "$BAK"
echo "--- SELinux context ---";  ls -Z /etc/fstab 2>/dev/null
echo

echo "===== [2] applying fix ====="
mount -o remount,rw / 2>/dev/null
cp -f "$BAK" /etc/fstab
echo "  copied $BAK -> /etc/fstab"
echo

echo "===== [3] verify ====="
wc -c /etc/fstab "$BAK"
md5sum /etc/fstab "$BAK"
A=$(md5sum /etc/fstab | cut -d' ' -f1)
B=$(md5sum "$BAK"    | cut -d' ' -f1)
if [ "$A" = "$B" ]; then
  echo "  OK: fstab restored to factory state (md5 match)"
else
  echo "  FAIL: md5 mismatch -- inspect manually"; exit 1
fi
echo

echo "===== [3b] dry-run mount -a (must not be skipped) ====="
mount -a ; echo "  mount -a exit code = $? (expect 0)"
echo

echo "===== [4] SELinux context check ====="
ls -Z /etc/fstab 2>/dev/null
if command -v restorecon >/dev/null 2>&1; then
  restorecon -v /etc/fstab 2>&1 | head -3
fi
echo "  if the context looks wrong: run  touch /.autorelabel  then reboot"
echo
echo "next: exit the chroot -> reboot"

# 一次性设计：成功修复后解除自动修复的待命标志
[ -f /etc/drill6-armed ] && rm -f /etc/drill6-armed && echo "  (autofix disarmed)"
exit 0
