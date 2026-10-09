#!/bin/bash
# ============================================================
# 系统巡检脚本 v2
# 退出码：0 = 正常，1 = 发现异常
#
# 【v1 → v2 的改动】由第 4 周演练 5B 暴露的监控盲区驱动
#   v1 只看 systemctl is-active，无法发现"服务 active 但端口没了"。
#   实证：mysqld 加 skip-networking（一个【合法】参数）后 is-active=active，
#         而 3306 完全没有监听；v1 却写下 [OK] 并 exit 0 → 告警永不触发。
#   同类场景：bind-address 改错、防火墙拦截、socket 权限不对、只监听 IPv6。
#
#   新增 检查 0：脚本自检（ss 不可用则立刻报错，避免端口检查全部误报）
#   新增 检查 4：关键端口监听（业务可达层）
#   新增 检查 5：nginx HTTP 探活（curl 必须带 -m 超时）
#   服务列表补入 node_exporter（v1 漏了它，9 个服务只查了 8 个）
#   服务列表改为【单一数据源】SVC_PORTS，检查 3 与检查 4 共用，避免两处漂移
#
# 【v1 原有逻辑原样保留】磁盘（仅真实块设备、排除 sr0）、
#   内存（MemAvailable）、服务的 systemctl 检查、退出码约定
#
# 【备份】改动前的 v1：health_check.sh.v1
#   md5 = 3ba5d45a4d814915f70ce05b6bb0b452（1439 字节）
# ============================================================

LOG="$HOME/ops-lab/logs/health.log"
TS=$(date '+%Y-%m-%d %H:%M:%S')
ALERT=0

# 服务 → 必须监听的端口（单一数据源，检查 3 与检查 4 共用）
SVC_PORTS="nginx:80 mysqld:3306 redis:6379 sshd:22 prometheus:9090 alertmanager:9093 grafana-server:3000 alert-webhook:5001 node_exporter:9100"

# --- 检查 0：脚本自检 --- [v2 新增]
# 监控脚本自己的工具坏了，必须大声报错，而不是把所有端口都判成"未监听"
if ! ss -lnt >/dev/null 2>&1; then
    echo "$TS [ALERT] 巡检脚本自检失败：ss 不可用，端口检查无法进行" >> "$LOG"
    exit 1
fi

# --- 检查 1：磁盘使用率（仅真实设备）--- [v1 原样]
while read -r src use mp; do
    u=${use%\%}
    if [ "$u" -ge 80 ]; then
        echo "$TS [ALERT] 磁盘 $mp ($src) 使用率 ${u}%" >> "$LOG"
        ALERT=1
    fi
done < <(df -h --output=source,pcent,target | tail -n +2 \
         | awk '$1 ~ /^\/dev\// && $1 !~ /sr0/')

# --- 检查 2：可用内存 --- [v1 原样]
AVAIL=$(free -m | awk '/^Mem:/{print $7}')
if [ "$AVAIL" -lt 200 ]; then
    echo "$TS [ALERT] 可用内存仅 ${AVAIL}MB" >> "$LOG"
    ALERT=1
fi

# --- 检查 3：关键服务（systemd 层）---
# 这一层只能回答"进程在不在"，回答不了"业务通不通" → 见检查 4
for pairs in $SVC_PORTS; do
    svc=${pairs%%:*}
    if ! systemctl is-active --quiet "$svc"; then
        echo "$TS [ALERT] 服务 $svc 未运行 (systemd 层)" >> "$LOG"
        ALERT=1
    fi
done

# --- 检查 4：关键端口监听（业务可达层）--- [v2 新增，这正是 v1 的盲区]
# 用 tail -n +2 去掉表头，比 ss -H 兼容性更好
for pairs in $SVC_PORTS; do
    svc=${pairs%%:*}
    port=${pairs##*:}
    if [ -z "$(ss -lnt "sport = :$port" 2>/dev/null | tail -n +2)" ]; then
        st=$(systemctl is-active "$svc" 2>/dev/null)
        echo "$TS [ALERT] 端口 $port 未监听 (期望服务 $svc；systemd 却说他 $st)" >> "$LOG"
        ALERT=1
    fi
done

# --- 检查 5：nginx HTTP 探活 --- [v2 新增]
# curl 必须带 -m：否则一个"连得上但不响应"的假死服务会把巡检直接卡死
HTTP_CODE=$(curl -s -o /dev/null -m 5 -w '%{http_code}' http://127.0.0.1/ 2>/dev/null)
if [ "$HTTP_CODE" != "200" ]; then
    echo "$TS [ALERT] nginx HTTP 探活异常: HTTP '$HTTP_CODE' (期望 200)" >> "$LOG"
    ALERT=1
fi

# --- 汇总 --- [退出码约定沿用 v1]
if [ "$ALERT" -eq 1 ]; then
    echo "$TS [INFO] 本次巡检发现异常" >> "$LOG"
    exit 1
else
    echo "$TS [OK] 磁盘/内存/服务/端口/HTTP 均正常" >> "$LOG"
    exit 0
fi
