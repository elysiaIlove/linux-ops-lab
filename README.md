# linux-ops-lab

CentOS 7 虚拟机上的 Linux 运维练习环境。用于练习系统巡检、服务治理、
日志排查、数据库备份恢复，搭建了一套完整的**指标监控与告警体系**，
并完成了 **6 类故障注入演练**与**两条系统救援路径**（emergency mode / ISO 救援）。
全部工作集中在 **2026-10-07 ~ 10-09 三天内**按 4 个阶段推进完成；脚本、配置与救援脚本
都在本仓库中（见下方「仓库文件」），配置类文件里的凭据已脱敏。

> **说明**：本项目为**个人练习环境**，非生产环境。所有操作均在本地
> VMware NAT 网络内的虚拟机上进行。
>
> **证据约定**：本文所有数字均来自实际执行的输出（脚本退出码、`journalctl`
> 时间戳、`ss` / `md5sum` 等），不是估算值；不确定的地方明确标注。

## 项目时间线

「阶段」按内容单元划分，括号内是实际执行日期（完整记录见文末「附：时间记录」）。

| 阶段 | 内容 | 实际日期 | 状态 |
|---|---|---|---|
| 阶段 1 | 环境初始化、服务盘点、巡检脚本、磁盘告警演练、crontab | 2026-10-07 | ✅ 已完成 |
| 阶段 2 | 测试数据、mysqldump 备份与恢复演练、备份脚本、logrotate | 2026-10-08 上午 | ✅ 已完成 |
| 阶段 3 | node_exporter + Prometheus + Grafana 监控、Alertmanager 告警 | 2026-10-08 下午 | ✅ 已完成 |
| 阶段 4 | 服务治理（8 个服务 Restart 策略 + 熔断）、6 类故障演练、两条救援路径、`/fix` 救援通道 | 2026-10-08 晚 ~ 10-09 | ✅ 已完成 |

## 目录

| 节 | 内容 |
|---|---|
| 第 1 节 | 环境说明（配置、服务清单、初始化调整） |
| 第 2 节 | 阶段 1~3：巡检脚本、服务部署、备份恢复、日志轮转、监控与告警 |
| 第 3 节 | 遇到的问题与解决（14 条） |
| 第 4 节 | 安全评估与决策 |
| **第 5 节** | **阶段 4：服务治理、故障演练与救援通道**（含三个完整排障案例） |
| 第 6 节 | 待改进 |
| 第 7 节 | 后续计划 |
| 附 | 时间记录 |

**仓库文件**

| 文件 | 说明 |
|---|---|
| `health_check.sh` | 系统巡检脚本（**v2**：5 类检查，cron 每 5 分钟执行） |
| `fix.sh` | **救援脚本**（部署为 `/fix`）：存 journal → 记录差异 → 恢复 → md5 校验 → `mount -a` 预演 |
| `drill6-autofix.service` | emergency mode 出现前自动执行 `/fix`（**待命标志 + 一次性**） |
| `mysql_backup.sh` / `logrotate-opslab.conf` | 备份脚本与日志轮转配置 |
| `prometheus.yml` / `prometheus-rules-host-alerts.yml` | 抓取配置与 4 条告警规则 |
| `alertmanager.yml` | 告警路由配置（**已脱敏**：`auth_password` 为占位符） |
| `alert_webhook.py` | 自建告警接收端（落日志） |
| `init_opslab.sql` | 演练用测试数据（4 张表，15 万行） |
| `.gitignore` | 凭据与数据文件的排除规则 |
| `.gitattributes` | 强制 LF 行尾（Windows 侧 `core.autocrlf=true` 会把 `.sh` 改成 CRLF） |
| `LICENSE` | MIT |

> 8 个服务的 systemd drop-in 策略文件（`*.service.d/zz-restart-policy.conf`）
> 部署在练习机上、未随仓库分发，完整策略见第 5.1 节的表格。

---

## 1. 环境说明

| 项目 | 配置 |
|---|---|
| 平台 | VMware Workstation（NAT 模式） |
| 系统 | CentOS Linux 7 (Core)，内核 3.10.0-1160.el7.x86_64 |
| 主机名 / IP | opslab-node1 / 192.168.111.131 |
| 资源 | 4 vCPU / 3770MB 内存 / 根分区 20G / swap 2.5G |
| 工作目录 | `~/ops-lab/{scripts,logs,backup}` |
| 防火墙 | firewalld（active + enabled） |

### 服务清单（巡检脚本 v2 覆盖全部 9 项 + 端口监听 + HTTP 探活）

| 类别 | 服务 | 端口 | 版本 |
|---|---|---|---|
| 业务服务 | nginx | 80 | 1.20.1 |
| | MySQL | 3306 | 5.7.44 |
| | Redis | 6379 | 7.2.5 |
| | sshd | 22 | — |
| 监控体系 | node_exporter | 9100 | 1.7.0 |
| | Prometheus | 9090 | 2.45.6 LTS |
| | Alertmanager | 9093 | 0.27.0 |
| | Grafana | 3000 | 10.4.5 |
| 告警接收 | alert-webhook（自建 Python 服务） | 5001 | — |

### 环境初始化过程中做的调整

| 调整项 | 变更前 | 变更后 | 原因 |
|---|---|---|---|
| 内存 | 1024MB（已在用 swap） | 3770MB | 1GB 内存下运行监控组件会触发内存压力 |
| yum 源 | `vault.centos.org`（403） | `mirrors.aliyun.com/centos-vault/7.9.2009/` | 原归档站不可用 |
| 主机名 | `192.168.111.131`（DHCP 生成） | `opslab-node1` | 便于识别与管理；Grafana 看板中作为主机标识 |
| MySQL 配置 | `innodb_force_recovery = 1` | 已移除（恢复为 0） | 历史遗留的只读保护配置，导致无法写入（详见 3.8） |
| Python | 仅有 Python 2.7.5 | 额外安装 Python 3.6.8 | CentOS 7 默认 python 为 2.7，不支持 f-string（详见 3.11） |
| Prometheus 启动参数 | 无 | 增加 `--web.enable-lifecycle` | 开启 `/-/reload` 热重载，改配置无需重启（详见 3.13） |

---

## 2. 已完成的工作

### 2.1 系统巡检脚本

- **路径**：`~/ops-lab/scripts/health_check.sh`
- **版本**：**v2**（当前）—— 共 **5 类检查**：
  ① 磁盘使用率（阈值 80%）② 可用内存（阈值 200MB）
  ③ **9 个关键服务**运行状态 ④ **服务端口是否真的在监听** ⑤ **nginx HTTP 探活**（取状态码）
- **v1 → v2 的原因**：v1 只用 `systemctl is-active` 判断服务，
  在演练 5 中**漏掉了"服务 active 但端口不监听"**这类故障（详见第 5.3.2 节）
- **运行方式**：crontab 每 5 分钟自动执行，日志追加写入 `health.log`
- **退出码**：`0` = 正常，`1` = 有异常（供 cron / 监控系统判断）

**脚本设计要点**

| 设计 | 说明 |
|---|---|
| `df -h --output=source,pcent,target` | 精确指定输出列，避免解析 `df` 默认输出时因中文列名与空格对齐导致错位 |
| `awk '$1 ~ /^\/dev\// && $1 !~ /sr0/'` | 仅保留真实块设备，排除 tmpfs 等伪文件系统与只读介质 |
| `while read ... done < <(...)` | 使用进程替换而非管道，避免管道产生的子 shell 导致 `ALERT` 标志位丢失 |
| `SERVICES="nginx mysqld ... "` | **服务清单抽成变量**，新增服务只改一行，避免多处维护不一致 |
| `for svc in $SERVICES` | 变量**不加引号**以按空格分词；而 `"$svc"` 是单个值，必须加引号 |
| `systemctl is-active --quiet` | 只用退出码判断服务状态，不产生多余输出 |
| `LOG="$HOME/..."` | 不依赖 `~` 展开，脚本内路径更可移植 |

**服务清单包含监控组件自身**（Prometheus / Alertmanager / Grafana / node_exporter /
alert-webhook）—— 解决"监控系统自己挂了没人知道"的盲区。巡检脚本是独立的
Shell + cron 路径，不依赖监控系统本身，属于**带外监控**思路。

### 2.2 服务部署与验证

| 服务 | 操作 | 验证方式 |
|---|---|---|
| Nginx | `yum install -y nginx` + `systemctl enable --now nginx` | `curl -I http://localhost` 返回 `HTTP/1.1 200 OK` |
| MySQL | 确认既有安装，未重装 | `systemctl is-enabled/is-active` 均为正常 |
| Redis | 确认既有服务，未重装 | `redis-cli ping` 返回 `PONG` |
| 防火墙 | 按需 `--add-service` / `--add-port` + `--reload` | `--zone=public --list-services` / `--list-ports` 核对 |

**Redis RDB 持久化验证（三步证据链）**

1. 写入测试数据并手动触发快照：`set opslab:test hello` → `bgsave`
   → `/var/lib/redis/dump.rdb` 更新为 112 字节（时间戳同步更新）
2. 重启服务模拟宕机：`systemctl restart redis`
3. 读取数据仍在：`get opslab:test` 返回 `"hello"` → 持久化生效

### 2.3 磁盘告警演练（验证脚本有效性）

使用 `fallocate` 瞬间分配 8G 空间制造磁盘压力，验证巡检脚本能正确触发告警并在恢复后回到正常。

| 阶段 | 根分区使用率 | 脚本退出码 | 日志记录 |
|---|---|---|---|
| 演练前基线 | 43%（8.3G/20G） | 0 | `[OK] 磁盘/内存/服务均正常` |
| `fallocate -l 8G /tmp/fill.img` | **85%**（17G/20G） | **1** | `[ALERT] 磁盘 / (/dev/mapper/centos-root) 使用率 85%` |
| 清理后 | 43%（8.3G/20G） | 0 | `[OK] 磁盘/内存/服务均正常` |

**反向测试（证明告警功能真的有效）**

```bash
systemctl stop alert-webhook
~/ops-lab/scripts/health_check.sh; echo $?     # 1
# [ALERT] 服务 alert-webhook 未运行
systemctl start alert-webhook
~/ops-lab/scripts/health_check.sh; echo $?     # 0
```

> **只看脚本"报 OK"不能证明它有效，必须故意制造异常确认能报出来。**

### 2.4 crontab 定时任务

```
*/5 * * * * /root/ops-lab/scripts/health_check.sh >> /root/ops-lab/logs/cron.log 2>&1
# 每日 02:30 备份 opslab 数据库
30 2 * * * /root/ops-lab/scripts/mysql_backup.sh >> /root/ops-lab/logs/backup.log 2>&1
```

| 要点 | 说明 |
|---|---|
| 使用绝对路径 | cron 执行环境的 PATH 与 `$HOME` 与登录 shell 不同，必须写全路径 |
| `>> ... 2>&1` | 同时捕获标准输出与错误输出；不重定向时 cron 会尝试发送邮件 |
| 重启后自动恢复 | 虚拟机重启后任务自动恢复执行，验证持久化配置有效 |

### 2.5 测试数据准备

为备份/恢复演练准备四表关联的业务模型：

```
customers (60)  ──┐
                  ├──> orders (50,000) ──> order_items (100,000)
products  (20)  ──┘
```

- **数据规模**：60 客户 / 20 商品 / 50,000 订单 / 100,000 明细
- **磁盘占用**：`du -sh` 实测 **30M**
- **生成耗时**：**3.187 秒**
- **字符集验证**：中文姓名与城市（`张伟 / 北京`）无乱码
- **完整性验证**：多表 JOIN 查询正常；孤儿明细数 **0**

> 数据做到 15 万行是为了让备份/恢复耗时具有参考意义——数据量过小时耗时接近 0，
> 无法形成量级概念。

### 2.6 数据库备份与恢复演练

#### 备份方案对比

| 方案 | 命令要点 | 耗时 | 文件大小 |
|---|---|---|---|
| 基础备份 | `mysqldump opslab` | 0.297s | 5.5M |
| 完整参数 | `--single-transaction --routines --triggers --events --databases` | 0.327s | 5.5M |
| 完整参数 + 压缩 | 管道接 `gzip` | 0.463s | **1.2M** |

**压缩率约 78%**（mysqldump 输出为文本 SQL，结构重复度高，压缩效果好）。

**参数作用**

| 参数 | 作用 |
|---|---|
| `--single-transaction` | 在一致性快照内导出，**不锁表**，备份期间业务可继续读写（依赖 InnoDB MVCC） |
| `--routines --triggers --events` | 导出存储过程/函数/触发器/事件。**默认不导出**，遗漏会导致恢复后业务逻辑丢失 |
| `--databases` | 在 dump 文件中写入 `CREATE DATABASE` 与 `USE` 语句，使备份自包含 |
| `--default-character-set=utf8mb4` | 明确字符集，避免乱码 |

**其他观察**：15 万行的 dump 文件中 `INSERT INTO` 只出现 9 次 —— mysqldump
会把大量行合并为一条批量 INSERT，这是其性能优于逐行插入的主要原因。

#### 恢复演练（删库 + 恢复）

| 步骤 | 操作 | 结果 |
|---|---|---|
| 1 | 备份基线数据（保险） | `baseline_2026-10-08.sql.gz` |
| 2 | 记录基线行数 | 60 / 20 / 50000 / 100000 |
| 3 | `DROP DATABASE opslab` | 数据库与 `/var/lib/mysql/opslab` 目录均被删除，**不可回滚** |
| 4 | `gunzip -c opslab_full.sql.gz \| mysql` | **耗时 3.104 秒** |
| 5 | 验证 | 见下表 |

**恢复后验证结果**

| 验证项 | 结果 |
|---|---|
| 四个库表行数 | 60 / 20 / 50,000 / 100,000 —— **与删除前完全一致** |
| 中文数据 | `张伟 / 北京` 正常显示 |
| `CHAR_LENGTH('北京')` | **2** —— 未出现乱码导致的长度膨胀 |
| 多表关联查询 | 按城市统计正常，订单数分布均匀 |
| 孤儿明细数 | **0** |

**关键结论：恢复耗时（3.1s）约为备份耗时（0.33s）的 9~10 倍。**

原因：恢复需要解析 SQL 文本、逐条执行 INSERT、重建索引、写 redo/undo 日志并维护约束。
这一比例关系直接决定灾难恢复的 **RTO（恢复时间目标）**——大库应改用物理备份工具
（如 XtraBackup）而非逻辑备份。

### 2.7 备份脚本（防并发 + 校验 + 保留策略）

- **路径**：`~/ops-lab/scripts/mysql_backup.sh`
- **实测耗时**：**0.581 秒**，产出 1175 KB 压缩备份

| 设计 | 作用 |
|---|---|
| `set -euo pipefail` | 严格模式：命令失败、未定义变量、管道中任一环节失败都立即退出 |
| `flock -n 9` | **单实例锁**，防止上一次备份未完成时 cron 又启动一个（已实测触发 SKIP） |
| `gzip -t` 校验 | 验证压缩包完整性 —— **不可验证的备份等于没有备份** |
| 文件大小阈值（1KB） | 捕获"命令成功但产出空文件"的异常情况 |
| `find -mtime +7 -delete` | 保留策略，自动清理过期备份 |

### 2.8 日志轮转（logrotate）

- **配置**：`/etc/logrotate.d/opslab`
- **解决**：`health.log` 每 5 分钟追加一行、持续增长且无清理机制的问题

```
/root/ops-lab/logs/*.log {
    daily
    rotate 7
    maxsize 5M
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    create 0644 root root
    dateext
    dateformat -%Y%m%d
    su root root
}
```

| 参数 | 作用 |
|---|---|
| `rotate 7` | 保留 7 份历史。**不设则历史日志永不删除** |
| `maxsize 5M` | 除 `daily` 外的安全阀：单文件超 5M 立即轮转 |
| `compress` + `delaycompress` | 历史日志压缩，但**最近一份不压缩**，便于直接查看 |
| `copytruncate` | 复制后清空原文件。适用于**无法重开日志文件句柄**的程序；支持重开日志的程序应改用 `postrotate` + 信号 |
| `dateext` + `dateformat` | 用日期而非 `.1` 后缀命名，便于按日期查找 |

**`delaycompress` 两次轮转实测**：第 1 次 → `health.log-20261008`（1.3K 未压缩）；
第 2 次 → `health.log-20261008.gz`（299 字节，压缩率 77%）。

**历史日志完整性**：轮转后文件保留 22 行记录，包括最早的 `[ALERT]` 告警
—— 说明轮转不丢历史数据，排查问题可回溯。

**nginx 日志轮转**另配 `/etc/logrotate.d/nginx-opslab`，使用
`postrotate` + `/bin/kill -USR1 $(cat /run/nginx.pid)` 通知 nginx 重开日志文件
—— 相比 `copytruncate`，**不丢失任何日志**，是生产环境首选。

### 2.9 监控体系搭建

#### 架构

```
node_exporter (:9100)          Prometheus (:9090)           Grafana (:3000)
   采集主机指标        ──拉取──>   存储 TSDB / 规则评估  ──查询──>  可视化看板
                                        │
                                        │ 告警推送
                                        ▼
                                  Alertmanager (:9093)
                                  分组/抑制/路由
                                        │
                        ┌───────────────┴───────────────┐
                        ▼                               ▼
                  邮件通知(warning)              日志落盘(critical)
                  opslab-email                  alert-webhook (:5001)
```

#### 组件安装要点

| 组件 | 安装方式 | 关键点 |
|---|---|---|
| node_exporter | 官方 tar.gz 解压到 `/opt` | **静态链接**（`static_build` 标签），无 glibc 依赖 |
| Prometheus | 官方 tar.gz 解压到 `/opt/prometheus` | 选用 **2.45.6 LTS**；`--storage.tsdb.retention.time=15d` |
| Alertmanager | 官方 tar.gz 解压到 `/opt/alertmanager` | 静态二进制 |
| Grafana | **手动下载 RPM**（官方 yum 仓库已无 el7 包） | 动态链接，选 **10.4.5**（详见 3.12） |

**运行用户隔离**：创建系统用户 `prometheus`（`--no-create-home --shell /sbin/nologin`），
Prometheus 与 Alertmanager 均以该用户运行，`/opt/prometheus`、`/opt/alertmanager`
归属该用户 —— 遵循最小权限原则。

**Prometheus 启动参数**（`/etc/default/prometheus`，由 systemd `EnvironmentFile` 引入）：

```
ARGS="--storage.tsdb.retention.time=15d --web.enable-lifecycle"
```

#### TSDB 数据目录结构

```
/opt/prometheus/data/
├── wal/                ← 预写日志，数据先写这里
├── chunks_head/        ← 内存中的最新数据
├── lock                ← 防多实例锁
├── queries.active
└── 01HXXXXX.../        ← 持久化数据块（每 2 小时生成一个）
```

> 刚启动时 `du -sh data/` 只有 132K，因为 **Prometheus 每 2 小时才把内存数据
> 刷成一个持久化 block**，在此之前数据都在 `wal/` 中。

#### 采集配置与验证

```yaml
# /opt/prometheus/prometheus.yml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - /opt/prometheus/rules/*.yml

alerting:
  alertmanagers:
    - static_configs:
        - targets: ['localhost:9093']

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
  - job_name: 'node'
    static_configs:
      - targets: ['localhost:9100']
```

**验证链路（三层）**

| 层级 | 命令 | 期望 |
|---|---|---|
| 目标采集 | `curl -s localhost:9090/api/v1/targets` | 两个 job 均 `"health":"up"` |
| 数据可用 | `curl -s 'localhost:9090/api/v1/query?query=up'` | 值为 `"1"` |
| 告警出口 | `curl -s localhost:9090/api/v1/alertmanagers` | `activeAlertmanagers` 含 9093 地址 |

#### Grafana 看板

- 数据源：Prometheus，URL `http://localhost:9090`
- 导入社区看板 **Node Exporter Full（ID 1860）**
- 实测面板读数与命令行一致：`Root FS Used 50.0%` 对应
  `df -h` 的 50%、`RAM Used 41.5%` 对应 `free -m` 的 1246/3770

**发现并解释的 `No data` 面板**：`Pressure` 面板依赖 **PSI（Pressure Stall
Information）** 指标，该特性在 **Linux 内核 4.20** 引入，而 CentOS 7 内核为 **3.10**，
因此内核不提供该数据，node_exporter 自然无法采集。

```bash
curl -s http://localhost:9100/metrics | grep -c 'node_pressure'    # 0
uname -r                                                            # 3.10.0-1160.el7
```

**排查顺序**：面板无数据时，先确认**指标在目标端是否存在**（`curl .../metrics | grep`）
→ 再查 Prometheus 是否采集到 → 最后查 Grafana 查询语句。

### 2.10 告警规则与路由

#### 告警规则（`/opt/prometheus/rules/host-alerts.yml`，4 条）

| 规则 | 表达式要点 | `for` | severity |
|---|---|---|---|
| `DiskUsageHigh` | `(1 - avail/size) * 100 > 80`，排除 `tmpfs/overlay/rootfs` | 2m | warning |
| `InstanceDown` | `up == 0` | 1m | critical |
| `MemoryLow` | `MemAvailable < 200MB` | 2m | warning |
| `LoadHigh` | `node_load1 > 4` | 5m | warning |

**`for` 的作用**：告警需**持续满足条件**才从 `pending` 转为 `firing` ——
瞬时抖动只会停留在 `pending`，不会通知人。这是 Prometheus 告警与
"脚本一次判断就报警"的本质区别。

**磁盘规则不限定 `mountpoint`**，实测同时覆盖 `/` 与 `/boot` 两个真实文件系统 ——
避免遗漏 `/boot` 写满导致无法安装内核/无法启动这类高危场景。

#### 验证方式

```bash
/opt/prometheus/promtool check rules /opt/prometheus/rules/host-alerts.yml
# SUCCESS: 4 rules found
/opt/prometheus/promtool check config /opt/prometheus/prometheus.yml
# SUCCESS: 1 rule files found
```

#### 路由与抑制（`/opt/alertmanager/alertmanager.yml`）

```yaml
route:
  group_by: ['alertname', 'instance']
  group_wait: 10s
  group_interval: 1m
  repeat_interval: 1h
  receiver: 'opslab-email'            # 默认：邮件
  routes:
    - matchers:
        - severity = "critical"
      receiver: 'opslab-webhook'      # 严重级别：落日志
      repeat_interval: 30m

receivers:
  - name: 'opslab-webhook'
    webhook_configs:
      - url: 'http://127.0.0.1:5001/webhook'
        send_resolved: true
  - name: 'opslab-email'
    email_configs:
      - to/from/smarthost/auth_username/auth_password（163 邮箱 SMTP）
        require_tls: false
        send_resolved: true

inhibit_rules:
  - source_matchers: [severity = "critical"]
    target_matchers: [severity = "warning"]
    equal: ['instance']
```

**分级路由实测**（`amtool config routes test`）：

| 输入标签 | 路由结果 | 通道 |
|---|---|---|
| `severity=warning` | `opslab-email` | **邮件通知** |
| `severity=critical` | `opslab-webhook` | **落日志文件** |

> Alertmanager 路由是**树形结构且优先匹配子路由**：告警先看有无匹配的子路由，
> 匹配则走子路由，否则落到父级的默认 receiver。

**抑制规则的作用**：实例不可达（critical）时，压制该实例上的 warning 告警。
理由：机器都连不上了，磁盘/内存告警没有意义，只会造成干扰。

**配置校验**：`/opt/alertmanager/amtool check-config` → `SUCCESS`（2 receivers，
1 inhibit rule）。

#### 告警接收端（自建）

- **路径**：`~/ops-lab/scripts/alert_webhook.py`
- **监听**：`127.0.0.1:5001/webhook`
- **功能**：接收 Alertmanager 的 POST，解析 JSON，按 `[FIRING]` / `[RESOLVED]`
  格式化后追加写入 `~/ops-lab/logs/alerts.log`，同时打印到标准输出（便于
  `journalctl` 查看）
- **由 systemd 托管**：`alert-webhook.service`，`Restart=on-failure`

### 2.11 告警演练（端到端闭环验证）

**这是本项目最完整的验证：从制造故障到收到恢复通知的全链路证据。**

| 步骤 | 操作 | 实测结果 |
|---|---|---|
| ① 基线 | 记录磁盘与告警状态 | 磁盘 50%，`ALERTS` 返回 0 条 |
| ② 制造故障 | `fallocate -l 8G /tmp/fill.img` | 磁盘升至 **92.3%** |
| ③ 规则评估 | 观察 `DiskUsageHigh` 状态机 | `inactive` → **`pending`** → **`firing`**（`duration: 120` 秒 = `for: 2m`） |
| ④ Alertmanager 接收 | `curl -s localhost:9093/api/v2/alerts` | `"state": "active"`，`inhibitedBy: []`，`silencedBy: []` |
| ⑤ 路由命中 | 同上，看 `receivers` 字段 | **`[{"name": "opslab-email"}]`** |
| ⑥ 邮件送达 | 查看 163 邮箱 | **17:41 收到告警邮件**，标题 `1 alert for alertname=DiskUsageHigh instance=localhost:9100`，中文注释 `挂载点 / 使用率 92.3%，已超过 80%` 正常渲染 |
| ⑦ 清理恢复 | `rm -f /tmp/fill.img` | 磁盘回落至 **51%**，表达式值 50.61% |
| ⑧ 规则恢复 | 重新观察规则状态 | `DiskUsageHigh` 回到 **`inactive`** |
| ⑨ **恢复通知** | 查看邮箱 | **17:47 收到 `[1] Resolved` 恢复邮件**（绿底） |

**观察到的现象与分析**

| 现象 | 分析 |
|---|---|
| 实际磁盘升至 92.3%，高于预期约 85% | **监控系统自身消耗被监控资源**：Prometheus TSDB 持续写 WAL、Grafana 的 400MB 安装与运行数据、日志文件等。排障时"磁盘比预期涨得快"很可能来自监控/日志自身 |
| `alerts.log` 中没有这条告警 | **正确行为**：磁盘告警为 `severity=warning`，按路由走邮件；`alerts.log` 只接收 critical 告警。这恰好证明了分级路由生效 |
| 告警不是立刻触发 | `for: 2m` 的预期行为，先 `pending` 再 `firing`，用于过滤瞬时抖动 |

**同时验证了 Prometheus 的告警规则与巡检脚本的互补关系**：

| | 巡检脚本（阶段 1） | Prometheus 告警（阶段 3） |
|---|---|---|
| 判断方式 | 单次阈值判断 | 表达式 + `for` 持续时间 |
| 数据视角 | 只看当前状态 | 可查历史趋势、可算速率 |
| 通知 | 写日志，需人工查看 | 主动推送邮件 |
| 覆盖 | 磁盘 / 内存 / 服务存活 | 任意 PromQL 可表达的指标 |

> **脚本解决"轻量存活检查"，监控系统解决"指标趋势与主动通知"，两者互补而非替代。**

---

## 3. 遇到的问题与解决

### 3.1 yum 源返回 403，base 源全部失效

- **现象**：`yum list` 报 `[Errno 14] HTTP Error 403 - Forbidden`，
  指向 `http://vault.centos.org/7.9.2009/os/x86_64/repodata/repomd.xml`
- **原因**：CentOS 7 已于 2024-06 停止维护，官方归档站不再对外提供
- **解决**：将 `CentOS-Base.repo` 的 baseurl 改指
  `https://mirrors.aliyun.com/centos-vault/7.9.2009/`（含 base/updates/extras）
- **验证**：`yum repolist` 显示共 37271 个包
- **补充**：`ping 114.114.114.114` 丢包但 `ping www.baidu.com` 正常，
  说明部分运营商屏蔽 ICMP，**判断网络连通性不能只看 IP ping**

### 3.2 环境中已存在 MySQL 5.7

- **现象**：`rpm -qa | grep mysql` 发现已安装 mysql-community 5.7.44
- **决策**：**不卸载重装为 MariaDB**
- **原因**：CentOS 7 base 源提供 MariaDB，与 mysql-community 包存在文件冲突
  （都提供 `/usr/bin/mysql` 等），卸载重装风险高，且现有 MySQL 已可用
- **反思**：**接手存量机器应先盘点**（是否已装、版本、安装方式、服务管理方式），
  而不是直接执行安装命令

### 3.3 systemd override 的对比分析

| 服务 | override 内容 | 评估 |
|---|---|---|
| mysqld | `StartLimitInterval=0`、`StartLimitBurst=10` | ⚠️ `Interval=0` 会**关闭启动频率限制**，使 `Burst` 失效。若服务崩溃循环，systemd 将无限重启并反复读写坏数据，**掩盖真实故障且无人收到告警** |
| redis | `LimitNOFILE=10240` | ✅ 合理。Redis 单线程处理大量并发连接，需提升文件描述符上限 |

- **收获**：同样是 override，一个解决真实瓶颈，一个掩盖故障。
  评估配置不能只看"能否工作"，还要看"出问题时是否会被发现"

### 3.4 Redis 服务已存在

- **现象**：`rpm -q redis` 显示 `redis-7.2.5-1.el7.remi.x86_64`，服务已 enable + active
- **决策**：无需重装，直接进入功能验证
- **反思**：与 3.2 同一个教训——**先盘点现状再动手**

### 3.5 vim 普通模式下粘贴导致脚本内容丢失

- **现象**：脚本执行退出码为 0（看似成功），但日志文件未被创建
- **排查**：`cat -A` 发现文件**只有 3 行**（是之前敲过的命令，非完整脚本）；
  `bash -x` 确认实际执行的全是 `systemctl` 调用，没有磁盘检查与日志写入逻辑
- **原因**：`vim` 打开文件时处于**普通模式**，直接粘贴的内容被当作 vim 命令解析
- **解决**：改用 heredoc 写入（`cat > file <<'SCRIPT' ... SCRIPT`）
- **教训**：
  1. 多行脚本用 heredoc 或 `sed` 写入，不依赖交互式编辑器的模式
  2. **`bash -n` 语法检查通过不代表脚本正确**
  3. 排查 Shell 脚本问题优先使用 `bash -x` 追踪实际执行的命令

### 3.6 巡检脚本产生伪告警（告警疲劳的雏形）

- **现象**：脚本首次运行即报
  `[ALERT] 磁盘 /run/media/root/CentOS 7 x86_64 使用率 100%`
- **原因**：该挂载点是光驱中的 CentOS 安装 ISO（`/dev/sr0`）。ISO 为只读文件系统，
  **容量与已用恒等，因此永远是 100%**；同时脚本未排除 `tmpfs` 等内存文件系统
- **解决**：增加 `source` 列输出，用 `awk '$1 ~ /^\/dev\// && $1 !~ /sr0/'`
  仅保留真实块设备
- **意义**：这是**告警疲劳**的典型成因。**监控的难点不是"能不能报警"，
  而是"报的警是否有意义"**

### 3.7 fallocate 不接受小数容量

- **现象**：`fallocate -l 7.5G /tmp/fill.img` 报"指定的长度值无效"
- **原因**：GNU `fallocate` 只接受整数加单位后缀（K/M/G），不解析小数
- **解决**：改用 `-l 8G`
- **延伸**：`dd` 同样只接受整数。**`df`/`du` 等"读取类"命令的输出可以带小数，
  但"写入类"命令的参数通常是整数**
- **补充**：`fallocate` 只分配块不写数据（瞬时完成）；`dd` 实际写入字节（受磁盘速度限制）

### 3.8 MySQL 处于 innodb_force_recovery=1 只读状态

- **现象**：插入数据时报
  `ERROR 1881 (HY000): Operation not allowed when innodb_forced_recovery > 0`
- **排查过程**：
  1. `SHOW VARIABLES LIKE 'innodb_force_recovery'` → 值为 **1**（正常应为 0）
  2. `grep` 配置文件发现 `/etc/my.cnf` 第 48、49 行**重复写入两次**该参数
  3. 查 `/var/log/mysqld.log` 定位成因：
     ```
     InnoDB: Database was not shutdown normally!
     InnoDB: Starting crash recovery.
     InnoDB: !!! innodb_force_recovery is set to 1 !!!
     [ERROR] InnoDB: innodb_force_recovery is on. We do not allow
             database modifications by the user.
     ```
- **根因**：虚拟机上次为**非正常关机**（直接关闭 VMware 而非 `poweroff`），
  InnoDB 需要崩溃恢复；环境维护者曾设置 `innodb_force_recovery=1` 作为只读保护，
  但**事后未清理**，且重复写入两次
- **判断数据未损坏的依据**（修复前先评估，而非直接改配置）：
  1. crash recovery **仅耗时约 0.2 秒**，说明需回滚的事务极少
  2. 日志中**无任何 `corruption` 类报错**
  3. 所有数据库均可正常读取
- **修复**：备份配置 → `sed -i '/innodb_force_recovery/d'` 删除 →
  重启 → 验证参数为 0、写操作恢复、原有库数据完整
- **预防**：关机使用 `systemctl poweroff`，避免非正常关机
- **延伸**：该参数取 1~6 时数据库强制只读，用于从损坏中抢救数据；
  **值越大跳过越多检查、可读出的数据越多但越可能不完整**；
  **不能在运行时修改**，必须改配置文件后重启

### 3.9 logrotate 配置文件不支持行内注释

- **现象**：`logrotate -d` 报错
  `bad rotation count '7    # 保留 7 份历史（共约 8 天）'`
- **原因**：logrotate **只在行首识别 `#` 注释**，同一行 `#` 之后的内容会被
  当作指令参数一起解析
- **对比**：bash / MySQL / nginx 均支持行内注释，**logrotate 不支持**
- **解决**：所有注释单独成行
- **教训**：写配置文件前先确认该工具的注释语法；
  **用工具自带的校验模式验证配置**（`logrotate -d`、`nginx -t`、`bash -n`、
  `promtool check`、`amtool check-config`）

### 3.10 crontab 清理任务匹配不到 logrotate 生成的文件名

- **现象**：自行编写的清理任务 `find ... -name "*.log.*" -mtime +30 -delete`
- **问题**：logrotate 配置 `dateext` 后生成 `health.log-20261008.gz`（**连字符**），
  而该命令匹配 `*.log.*`（点号），**两者不匹配，实际不删除任何文件**
- **解决**：删除该 crontab 任务，统一交由 logrotate 管理
- **意义**：这是一类**"看似在工作、实际无效果"的配置**——命令能执行、不报错、
  退出码为 0，但什么都没做。**比报错更危险**，因为它给人"日志已清理"的假象。
  **验证配置时必须检查实际效果，而非只看执行结果**

### 3.11 CentOS 7 默认 python 是 Python 2.7，不支持 f-string

- **现象**：运行 Python 脚本报
  `SyntaxError: Non-ASCII character '\xe5' in file ... but no encoding declared`
- **原因**：CentOS 7 的 `/usr/bin/python` 是 **Python 2.7.5**：
  ① 源码含中文时**必须声明 `# -*- coding: utf-8 -*-`**；
  ② **f-string 是 Python 3.6+ 语法**，Python 2 不支持
- **解决**：`yum install -y python3`（3.6.8），脚本 shebang 改为
  `#!/usr/bin/env python3`
- **⚠️ 重要注意事项**：**不要用 `ln -sf /usr/bin/python3 /usr/bin/python` 修改默认
  python**，因为 **CentOS 7 的 yum 是用 Python 2 编写的**，修改后 yum 会直接不可用
  —— 这是 CentOS 7 上最常见的"自伤"操作之一
- **教训**：写脚本前先确认目标环境的解释器版本（`python --version`），
  不要默认新语法可用

### 3.12 Grafana 官方 yum 仓库已不再提供 el7 包

- **现象**：按官方文档配置 `rpm.grafana.com` 仓库后，`yum list available grafana`
  找不到任何 el7 包
- **验证**：拉取仓库 `primary.xml` 解析后发现，1604 个 grafana 包中
  **`.el7` 包数量为 0**
- **原因**：Grafana 已放弃 CentOS 7 支持
- **解决**：改为手动下载 RPM 安装（`dl.grafana.com/oss/release/`），
  选用 **10.4.5** 版本
- **延伸**：**Prometheus 全家桶是静态链接的 Go 二进制**（`static_build` 标签），
  可在任何 Linux 上直接运行；而 **Grafana 从 9.x 起引入 Rust 模块，动态依赖 glibc**，
  因此受系统库版本限制。**Grafana 11.x 起要求 glibc 2.28+，在 CentOS 7 上无法运行**
- **判断二进制兼容性的方法**（比记版本号可靠）：
  ```bash
  strings <二进制> | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sort -u -V   # 空 = 无 glibc 依赖
  <二进制> --version                                                # 直接试运行
  ```
- **更大的背景**：CentOS 7 于 2024-06 EOL，glibc 停在 2.17，
  新版本软件越来越要求 glibc 2.28+ —— 这是企业迁移到 Rocky/AlmaLinux 9 的实际动因之一，
  **不只是"没有安全更新"，还有"装不上新软件"**

### 3.13 Prometheus 的 /-/reload 热重载默认关闭

- **现象**：`curl -X POST http://localhost:9090/-/reload` 返回
  `Lifecycle API is not enabled.`
- **原因**：`/-/reload` 是**管理接口**，默认关闭以避免被未授权触发配置重载
- **解决**：在启动参数中加入 `--web.enable-lifecycle`
- **安全考量**：开启后该接口**无认证**，生产环境应通过反向代理加认证，
  或限制访问来源 IP；也可用 `systemctl reload` 替代
- **收获**：**便利性与攻击面的权衡** —— 开启前先明确"谁能访问这个接口"

### 3.14 Grafana 看板 Pressure 面板无数据（内核版本限制）

- **现象**：导入 Node Exporter Full（ID 1860）后，`Pressure` 面板显示 `No data`
- **排查**：`curl -s localhost:9100/metrics | grep -c 'node_pressure'` 返回 **0**，
  说明目标端根本没有该指标
- **原因**：`node_pressure_*` 指标依赖 **PSI（Pressure Stall Information）**，
  该特性在 **Linux 内核 4.20** 才引入，而 **CentOS 7 内核为 3.10**
- **解决**：无需处理，属于环境能力限制
- **⚠️ 重要认知**：**`No data` 不一定是故障，可能是"被监控对象本身不提供该能力"**
- **正确的排查顺序**：先确认**指标在目标端是否存在**（`curl .../metrics | grep`）
  → 再查 Prometheus 是否采集到 → 最后查 Grafana 查询语句

---

## 4. 安全评估与决策

> 以下为本人在练习环境中发现的问题及判断依据。
> 每项均记录了**触发条件**——即何种情况下必须重新评估。

### 4.1 Redis 弱密码 + 绑定 0.0.0.0

- **现状**：`requirepass root`，`bind 0.0.0.0 -::1`，`protected-mode yes`
- **风险**：弱密码配合全网卡监听，存在 **Redis 未授权访问**隐患。
  典型利用链为 `CONFIG SET dir /root/.ssh` → 写入 `authorized_keys` →
  SSH 免密登录 → 服务器失陷。另外 `appendonly no` 使 AOF 未生效
- **评估**：本机为 VMware NAT 内网环境，无公网暴露、无真实数据、可随时重建，
  风险可接受；使用简单密码便于反复实验
- **触发条件**：**一旦部署到公网或接入真实业务，必须** ① 改为强密码
  ② 将 `bind` 收敛为 `127.0.0.1` ③ 评估是否开启 AOF

### 4.2 数据库与监控端口对网段开放

- **现状**：firewalld public zone 放行 `3306`（MySQL）、`8080`、`3000`（Grafana）、
  `9090`（Prometheus）、`9093`（Alertmanager）、`9100`（node_exporter）
- **评估**：NAT 内网风险有限。但需注意：
  - **Prometheus / Alertmanager / Grafana 均无认证**（Grafana 有登录，
    但 Prometheus 与 Alertmanager 的控制台完全开放）
  - **Alertmanager 的控制台可以创建 Silence（静默规则）** ——
    意味着能访问它的人可以让告警静默，属于管理面暴露
- **触发条件**：公网部署必须加认证与 TLS，或用反向代理限制来源；
  数据库端口应移除或限制到特定 IP
- **进阶方案**：
  `firewall-cmd --add-rich-rule='rule family="ipv4" source address="192.168.111.1/32"
  port port="3306" protocol="tcp" accept'` —— 仅允许宿主机访问，
  体现最小权限原则

### 4.3 保留 CentOS 安装 ISO 作为救援介质

- **决策**：不卸载 `/dev/sr0` 上的 CentOS 安装 ISO
- **理由**：ISO 自带 **Rescue Mode**，可在系统无法启动时挂载根分区修复
  （`/etc/fstab` 写错、GRUB 引导损坏、root 密码丢失）
- **代价**：`df` 中该挂载点恒为 100%，**已在巡检脚本中排除**，避免无效告警

### 4.4 凭据文件的权限控制

- **做法**：MySQL 凭据写入 `~/.my.cnf` 并 `chmod 600`
- **原因**：MySQL 客户端会检查配置文件权限，若对其他用户可读则拒绝使用；
  这也是所有运维工具凭据文件的通用规则（SSH 私钥同理）
- **延伸**：Redis 无标准凭据文件，可使用 `REDISCLI_AUTH` 环境变量避免密码
  出现在命令历史中

### 4.5 备份文件与告警凭据的敏感性

- **现状**：备份文件 `opslab_*.sql.gz` 包含全部业务数据，权限 `0644`；
  Alertmanager 配置中含 163 邮箱 SMTP 授权码
- **评估**：练习环境无真实数据，风险可接受
- **触发条件**：真实环境中
  ① 备份文件应设为 `0600` 并限制目录访问
  ② **凭据不得提交到 Git 仓库**（应使用环境变量或独立的 secrets 文件并加入 `.gitignore`）
  ③ 凭据若曾在命令行明文输入，会留在 `~/.bash_history`，**泄露后应立即轮换**
- **延伸**：备份加密、异地存储、定期恢复演练是生产环境的必备要求

### 4.6 仓库发布前的凭据检查

把练习环境整理成公开仓库前，必须先确认没有任何凭据进入版本库。
**顺序不能反** —— 先提交再删除，凭据会永久留在 history 里：

| 检查项 | 命令 |
|---|---|
| 配置文件里有无密码 / 授权码 | `grep -riE 'password\|passwd\|auth_password\|requirepass\|secret' . --exclude-dir=.git` |
| 命令历史里有无明文凭据 | `grep -iE 'password\|授权码' ~/.bash_history` |
| `.gitignore` 是否覆盖敏感文件 | 见仓库根目录 `.gitignore`（排除 `*.cnf` / `*.sql` / `*.sql.gz` / `*.rdb` / `*.pem` 等） |
| 提交历史里是否混入过凭据 | `git log -p \| grep -iE 'password\|授权码'` |

**本项目的处理方式**

- `alertmanager.yml` 在仓库中保留的是**脱敏模板**（`auth_password` 为占位符）；
  真实版本只存在于虚拟机上
- `~/.my.cnf`、`*.sql.gz`、`dump.rdb` 一律不进仓库

> 一个值得记录的实测数字：本机 `~/.bash_history` 曾达到 **42,355 字节 / 1000 行，
> 其中 50 行命中 `password` / 授权码 等敏感关键词** —— 只要提交过一次就洗不掉，
> 所以**必须在提交之前检查**。

**本次实际执行结果（2026-10-09）**

按上表顺序执行，但把前两项做成了**不通过就中止提交**的硬门禁，而不是打印一行结果：

| 环节 | 实测结果 |
|---|---|
| 提交前工作区扫描（16 个文件） | 0 处真实泄露；`alertmanager.yml` 已是脱敏模板 |
| 提交前门禁（6 类判据） | 全部通过 —— 授权码真值 / 私钥 / 手机号 / 邮箱 / 身份类关键词 / 本机路径 / 行尾含 CR |
| 提交历史扫描（`git grep HEAD` 与 `git log -p`） | **16 处命中，全部是占位符与注释文字**，无真值 |
| 远程与本地对账 | `tree` 哈希一致（`5d344a6e…`），13 个文件的字节完全相同 |

仓库侧还做了两件防行尾损坏的事：`core.autocrlf=false` 与 `.gitattributes`
（`* text=auto eol=lf`）—— 因为 Windows 侧 Git 的 system 级配置是 `core.autocrlf=true`，
不覆盖的话 `checkout` 会把 `.sh` 改成 CRLF，脚本在 Linux 上会直接报 `^M` 错。
实测 `git ls-files --eol` 为 **13/13 `i/lf w/lf`**，blob 里 **0 个 CR**。

---

## 5. 阶段 4：服务治理、故障演练与救援通道

### 5.1 服务治理：8 个服务的 systemd drop-in 统一策略

沿用环境里既有的 drop-in 机制（`mysqld.service.d/override.conf` 那种写法），
用**同一套命名规范**给 8 个服务各加一个 `zz-restart-policy.conf`。

| 服务 | `Restart` | `RestartSec` | `StartLimitInterval` | `StartLimitBurst` | 额外 |
|---|---|---|---|---|---|
| nginx | `on-failure` | 10 | 5min | 6 | **`KillMode=control-group`** |
| mysqld | `on-failure` | 10 | 5min | 6 | — |
| redis | `on-failure` | 10 | 5min | 6 | 不覆盖官方 `limit.conf` 的 `LimitNOFILE` |
| grafana-server | `on-failure` | 10 | 5min | 6 | — |
| node_exporter | `always` | 5 | 10min | 20 | — |
| alert-webhook | `always` | 5 | 10min | 20 | — |
| prometheus | `always` | 10 | 10min | 20 | — |
| alertmanager | `always` | 10 | 10min | 20 | — |

**几个踩过的点**

| 点 | 说明 |
|---|---|
| **`on-failure` vs `always`** | 业务服务用 `on-failure`（正常 `stop` 不该被拉起）；监控组件用 `always`（它们"停止"通常意味着崩溃，必须回来） |
| **drop-in 按文件名字典序叠加** | 用 `zz-` 前缀保证**最后生效** —— 环境自带的 `override.conf` 里有一个 `StartLimitInterval=0`，会被 `zz-` 覆盖掉 |
| **`StartLimit*` 写在 `[Service]` 段** | 不是 `[Unit]` |
| **systemd 219 的差异** | 没有 `systemctl show -p NRestarts`、没有 `systemctl --value`；失败措辞与新版本不同 |
| **不要覆盖官方 `limit.conf`** | `redis.service.d/limit.conf`（官方 RPM 自带 `LimitNOFILE=10240`）只补 `Restart` 相关项，不要整份替换 |
| **熔断后要 `reset-failed`** | 否则即使故障消失，服务也不会自己起来 |

### 5.2 自愈能力的定量实测

用"杀掉服务主进程"的方式测恢复时间，**同一个故障重复测**：

| `RestartSec` | 检测到恢复耗时 | 说明 |
|---|---|---|
| 默认（100ms） | **20 ms** | 几乎是立即重启 |
| 3 | **3,424 ms** | ≈ `RestartSec` + 0.4s 的固定开销 |
| 10 | **10,412 ms** | 同上，规律稳定 |

**规律：恢复时间 ≈ `RestartSec` + 0.4s。** 所以 `RestartSec` 是"自愈速度"的直接旋钮。

> **计时必须脚本化**：分块手工执行时测出过 25,522 ms，脚本化后同一操作是 20 ms ——
> 手工操作的间隔把测量窗口污染了一个数量级。

**熔断是"速率限制"，不是"总次数"**

熔断条件不是"重启够 N 次就停"，而是 `StartLimitBurst` 次重启**发生在 `StartLimitInterval` 之内**。
所以**必须满足 `RestartSec × StartLimitBurst < StartLimitInterval` 才可能熔断** ——
`RestartSec=3` 配默认 5 次/10 秒**永远不会熔断**（3×5=15 > 10）。

熔断后的表现：`Result=start-limit`，日志出现 `start request repeated too quickly`，
且**必须 `systemctl reset-failed` 才能再启动**。

### 5.3 三个完整的排障案例

三个案例的共同点：**表面症状和真实原因不一致**，而且都是靠"换一个观测手段"才定位到的。

#### 5.3.1 案例一：服务 `failed`，业务却返回 `HTTP 200`（孤儿 worker）

| 阶段 | 内容 |
|---|---|
| **现象** | `systemctl status nginx` 显示 `failed` / `activating`，但 `curl http://localhost` **照样 200** |
| **排查** | `ss -lntp` 发现 80 端口上仍有 **4 个 nginx worker，`PPID=1`**（被 init 收养的孤儿） |
| **根因** | nginx 的 `KillMode=process` —— systemd 只杀主进程，**不杀 control group 里的 worker**。worker 继续持有监听 socket，所以业务"看起来没死"；而 systemd 认为服务已死、反复重启 → 新 master 又抢不到端口 |
| **修复** | 给 nginx 加 drop-in `KillMode=control-group` |
| **验证** | 同样的 kill 操作后：**0 个孤儿 worker**，服务状态与端口状态一致 |

> **方法论**：`systemctl` 的状态描述的是"**systemd 眼里的服务**"，不是"**业务是否可用**"。
> 两者可能相反，必须分别观测（这正是第 5.3.2 节里巡检脚本要补端口检查的原因）。

#### 5.3.2 案例二：服务 `active`，端口却没了（监控盲区）

| 阶段 | 内容 |
|---|---|
| **现象** | 在 `/etc/my.cnf` 里注入 `skip-networking` 后重启 mysqld：`systemctl is-active` = **active**，但 **3306 完全不监听** |
| **矛盾点** | `localhost` 的 socket 连接仍正常，**只有 TCP 连不上** —— 所以"本机测试通过"是个陷阱 |
| **关键发现** | **三层监控全部漏报**：① Prometheus 的实例存活规则 ② 自建 webhook ③ **我自己写的巡检脚本 v1**（只查 `systemctl is-active`，报 `[OK]` 且退出码 0） |
| **修复** | 巡检脚本升级 **v2**：新增**服务端口监听检查**（`SVC_PORTS` 作为单一数据源）+ **nginx HTTP 探活** |
| **验证** | **用同一个故障做正反对照**：同一秒的日志里，v1 报 `[OK]`（退出码 0），v2 报 `[ALERT]`（退出码 1）；修好后 v2 回到 `[OK]` |

> **方法论**：**"脚本报 OK"本身也需要被验证。** 制造一个已知故障、确认监控能报出来 ——
> 否则你只是拥有一个"永远说没事"的脚本。

#### 5.3.3 案例三：一行假 UUID 拖垮 6 个单元（fstab 救援）

**故障注入**（只追加、不动原行）：在 `/etc/fstab` 末尾加一条带**不存在的 UUID**、
**不带 `nofail`** 的挂载项。

| 观测 | 实测结果 |
|---|---|
| **systemd 会等多久** | **90 秒**（`DefaultTimeoutStartSec` 默认值；实测 12:26:22 → 12:27:55 = **93 秒**） |
| **失败传播** | journal 里 **220 行**、同一秒内 **6 个单元连锁失败**：`/mnt/broken`、**`Local File Systems`（`local-fs.target`）**、`Relabel all filesystems`、`Mark the need to relabel`、`Migrate SELinux policy changes` → 最终 `Reached target Emergency Mode` |
| **开机到 emergency** | **125 秒** |
| **`systemctl --failed`** | **0 个**（连 `--all` 也是 0） |
| **单元真实状态** | `mnt-broken.mount` → `ActiveState=inactive`、`SubState=dead`、**`Result=success`** |
| **journal 里的措辞** | `Unit … has failed`、`Job …/start failed with result 'timeout'` / `'dependency'` |

**两条必须记住的判据：**

> **① 「job 失败」≠「unit failed」。** 因依赖失败而没启动的单元停在 `inactive(dead)`，
> **`Result` 甚至是 `success`**（因为它从未被启动过）。而 `systemctl --failed` **只看 unit 状态**。
> **→ 排查"系统起不来"，`systemctl --failed` 可能是 0，必须看 `journalctl -xb`。**

> **② systemd 的状态行可能被内核参数吞掉。** 本机 `cmdline` 含 `rhgb quiet`，
> 屏幕上完全看不到 `[ TIME ]` / `[ DEPEND ]` —— 消息没丢，它在 journal 里。
> **→ 排查启动故障时，先在 GRUB 按 `e` 删掉 `rhgb quiet` 再启动，屏幕上就能直接看到失败点。**

**两条救援路径（都实际走通了）**

| | **路径 A：emergency mode** | **路径 B：ISO 救援** |
|---|---|---|
| 进入条件 | 系统还能起到 emergency target | **连 emergency 都进不去**（fstab 全毁 / 引导坏 / root 密码丢） |
| 是否要密码 | **要 root 密码** | **不要** |
| 修复方式 | 就地恢复 + 校验 | **`chroot /mnt/sysimage` 进真实系统**离线修复 |
| **能否看到故障现场日志** | ✅ **能**（RAM 里的 journal 还在） | ❌ **不能**（RAM 已断电；`/run` 是 ISO 的） |
| 控制台打字量 | 约 25 次（含密码） | 约 40 次（无密码） |

**路径 B 的关键动作与验证点**

```
BIOS:  VM → Power → Power On to Firmware → Boot 页把 CD-ROM 提到第一位 → F10
ISO:   Troubleshooting → Rescue a CentOS Linux system → 1) Continue
shell: sh-4.2#  chroot /mnt/sysimage        ← 提示符变成 bash-4.2#
                ↑ 这就是"进入真实系统"：之后看到的是硬盘上的 /etc/fstab
       bash-4.2#  ls -l /fix /root/fstab.good.bak   ← 这两个文件只存在于真实系统
       bash-4.2#  /fix
       bash-4.2#  exit → reboot
```

> **为什么不用 `ESC` 抢 Boot Menu**：Power On 按钮在 VMware 工具栏（窗口外），
> 鼠标移进客户机时启动窗口（约 1 秒）早已过去。**进 BIOS 改启动顺序没有时序压力**，
> 是更可靠的路径。（代价：**若把 CD-ROM 留在第一位**，之后每次开机都会先撞安装盘菜单 ——
> 所以用完要把启动顺序改回 `Hard Drive` 置顶，详见第 6 节待改进。）

**恢复的验证方式（不是"看起来对了"）**

```bash
wc -c   /etc/fstab /root/fstab.good.bak    # 493 / 493 —— 字节数完全一致
md5sum  /etc/fstab /root/fstab.good.bak    # 两个 md5 相同
ls -Z   /etc/fstab                         # system_u:object_r:etc_t:s0（标签未被破坏）
mount -a                                   # 退出码 0 —— 恢复后确实能正常挂载
```

### 5.4 救援通道：把恢复动作压缩成一个短命令

**动机**：VMware 控制台**不支持粘贴**，救援时手工输入长命令的代价是可量化的 ——
实测中密码打错两次、`sed` 模式写错、`cp` 别名弹出交互确认。

**做法**：把恢复流程固化成 `/fix`（4 个字符），并在 emergency mode **之前**提供自动执行入口。

| 组件 | 作用 |
|---|---|
| **`/fix`**（见 `fix.sh`） | 存 journal → **记录差异** → 恢复 → **md5 校验** → **`mount -a` 预演** → SELinux 标签检查 |
| **`drill6-autofix.service`** | `Before=emergency.service`，在紧急 shell 出现前自动执行 `/fix` |
| **`/etc/drill6-armed`** | **待命标志**：存在才触发；`/fix` 成功后自动删除 → **只生效一次** |

**两条安全设计与其理由**

| 设计 | 理由 |
|---|---|
| **待命标志（`ConditionPathExists`）** | 无条件自动修复会在**任何原因**的 emergency 里都去改 fstab，从而**掩盖真实故障** —— 与"让故障暴露"的原则相反 |
| **`cp -f` 覆盖而非重建** | 覆盖已有文件走 `O_TRUNC`，**inode 与 SELinux 标签都保留**；重建会产生错误标签（救援模式的经典坑） |

**验证方式：`dry-run`（不需要真的把系统搞坏）**

因为 `/fix` 是**幂等**的（fstab 已正常时它报告"无差异"并正常结束），可以直接：

```bash
touch /etc/drill6-armed
systemctl start drill6-autofix.service
# 观察：单元退出码 0、[0] 存档生成、[3] md5 一致、[3b] mount -a = 0
#       且待命标志被自动解除（一次性设计生效）
```

**闸门的 A/B 验证（这一半比"能跑"更重要）**

"能执行"只验证了一半；更关键的是**"未待命时它绝不执行"** —— 那是防止它掩盖无关故障的唯一屏障。
判据不看属性，看**有没有产生新的存档文件**（条件被跳过时 `/fix` 根本不运行）：

| | 操作 | 实测 | 结论 |
|---|---|---|---|
| **A** | 删除待命标志后 `systemctl start` | 存档数 `3 → 3` | ✅ **未执行**，闸门生效 |
| **B** | `touch /etc/drill6-armed` 后 `systemctl start` | 存档数 `3 → 4` | ✅ **已执行** |
| **C** | 检查标志文件 | 已被自动删除 | ✅ **一次性设计生效** |

```
fix[9344]: OK: fstab restored to factory state (md5 match)
fix[9344]: mount -a exit code = 0 (expect 0)
fix[9344]: (autofix disarmed)
```

> **一个版本陷阱**：`systemctl show -p ConditionPathExists <unit>` 在 **systemd 219 上不返回该属性**
> （逐条 `Condition*` 属性是较新版本才暴露的），只有 `ConditionResult` / `ConditionTimestampMonotonic` 在。
> **不要从"属性没输出"推断"配置没生效"** —— 能不能跳过的判据是**跑不跑**，不是**属性显不显示**。

> **收益量化**：控制台操作从 **200+ 次按键**降到约 **25 次**（emergency 路径）。

### 5.5 日志的可得性：journald 为什么必须持久化

`journalctl` 默认把日志放在 `/run/log/journal`（**tmpfs，内存**）—— 重启即丢。

**实测到的具体后果**

| 场景 | 能否看到"上次失败 boot"的日志 |
|---|---|
| **emergency mode**（路径 A） | ✅ 能 —— RAM 还在，`journalctl -xb` 直接可读 |
| **ISO 救援**（路径 B） | ❌ **不能** —— RAM 已断电；而且 `chroot` 后 `journalctl` 看到的是 **ISO live 环境**的日志 |

**一个容易被误信的陷阱**：在 ISO 救援的 chroot 里"存档日志"，
`journalctl` **不会报错**，而是给出一份 **431KB 的 ISO 环境日志**。核对来源才发现：

| 标志 | 真正的故障现场日志 | 误存下来的那份 |
|---|---|---|
| `opslab-node1` 出现次数 | **267** | **0** |
| 主机名 | `localhost.localdomain` → `opslab-node1` | 全程 `localhost` |
| `anaconda` / `rescue` | — | **78 / 20** |

**机制**：anaconda 救援会把 ISO 环境的 `/proc` `/sys` **`/run`** `/dev`
一起绑定进 `/mnt/sysimage`（`mount` 输出里可见 `tmpfs on /run`），
所以 chroot 里的 `/run/log/journal` 就是 **ISO 的** journal。

> **两条结论**
> ① **必须开 `Storage=persistent`**：日志落盘后，即使只能挂 ISO 救援，
>    也能从 chroot 里读到 `/var/log/journal` 中上次失败 boot 的完整日志。
> ② **任何"自动存档日志"的动作都必须记录来源**（hostname / cmdline / `--list-boots`），
>    否则它给出的不是"没有证据"，而是**"看起来合理、实际是错的证据"** —— 比没有更危险。
>    `fix.sh` 的 `[0]` 步据此加了 `source=TARGET|ISO` 标记与告警。

### 5.6 排障判据速查

**① errno 是分类器（端口起不来时先看它）**

| errno | 含义 | 往哪查 |
|---|---|---|
| **13 `EACCES`** | **安全策略拦截** | SELinux 端口类型（`semanage port -l`） |
| **98 `EADDRINUSE`** | 端口被占 | `ss -lntp` 找 PID |
| **111 `ECONNREFUSED`** | 连接被拒 | 服务是否在监听 |

**② 端口不通的三层排查顺序**：**SELinux → 防火墙 → 服务是否在听**

**③ SELinux 端口类型（`semanage port` 的坑）**

| 命令 | 实际含义 |
|---|---|
| `semanage port -l` | **策略 ∪ 本地记录的并集，且不去重** —— 不能只看这一条判断 |
| `semanage port -l -C` | **只看本地自定义**（相当于 `git diff`） |
| `semanage port -a` / `-m` / `-d` | 新增条目 / 修改类型 / 删除本地记录 |

`http_port_t` 默认包含：80, 81, 443, 488, 8008, 8009, 8443, 9000。
（另：`sealert` 是 GUI 程序，无头环境下会弹 X 窗口；替代品是
`/var/log/messages` 里的 `SELinux is preventing ...`。）

**④ 日志落点有三种模式**

| 模式 | 例子 |
|---|---|
| 只写 journal | node_exporter / alert-webhook |
| **只写文件**（journal 里查不到根因） | **mysqld → `/var/log/mysqld.log`** |
| 两边都写 | nginx |

### 5.7 阶段 4 沉淀的方法论

> **① 改前备份** —— 关键配置改动前先 `\cp -a` 留一份副本 + `md5sum`
> **② 改后预检** —— `fstab` 改完必须 `mount -a`（实测：坏条目当场报错、退出码 **32**，
>    这一条本可避免两次进入 emergency mode）
> **③ 修后验证** —— 用 `md5` / 字节数 / `mount -a` 退出码证明"真的恢复"，
>    而不是"看起来 12 行、跟原来一样"
> **④ 证据标来源** —— 存档数据必须写明来自哪台机、哪一次 boot；
>    假的退出码和来源错误的日志，比没有记录更危险

**两条把教训落成动作的经验**

| 教训 | 落成的动作 |
|---|---|
| `cmd \| head` 之后取 `$?` 会拿到 `head` 的退出码（**同一个错误犯了两次**） | 用两个 `grep` 交叉自审：`grep -n '\| *head'` + `grep -n '\$?'`，两行相邻即疑似 bug。据此定位 3 处 |
| 「追加 + 按模式删除」**不等于**回到原样（追加内容里的分隔空行会残留） | 恢复后一律比对 `md5` + 字节数；覆盖现场前先 `diff` / `wc -c` 记录差异 |

> 一个具体例子：靠 `md5` 发现 `sed` 恢复后的文件比备份**多 1 个字节**（残留换行），
> 而从 `cat -n` 上几乎看不出来。

---

## 6. 待改进

- [x] ~~日志无轮转~~ → 已配置 logrotate
- [x] ~~备份任务未建立~~ → 已有备份脚本 + 定时 + 保留策略，并完成恢复演练
- [x] ~~无指标监控~~ → 已搭建 node_exporter + Prometheus + Grafana
- [x] ~~告警仅落日志~~ → 已接入 Alertmanager，分级路由（邮件 + 日志）
- [ ] **告警只落日志一份**：warning 走邮件、critical 落日志，两通道互斥。
      若需所有告警都留档，可在 email receiver 下追加 webhook 配置
      （一个 receiver 可挂多个通道）
- [ ] **备份未做异地存储**：所有备份与源库在同一块磁盘上，
      磁盘损坏则数据与备份同时丢失
- [ ] **未使用 Alertmanager 的 Silence 功能做维护窗口**：计划中的维护操作
      应提前静默告警，避免"计划内操作触发告警"
- [ ] **Redis 未开启 AOF**：当前仅 RDB，最多可能丢失数分钟数据
- [ ] **备份脚本产出的压缩包未验证可恢复性**：脚本校验了压缩包完整性，
      但没验证过**它自己产出的**包能否成功导入（第 2.6 节的删库恢复演练用的是手工
      `mysqldump` 产物，不是这个脚本的输出），可考虑定期自动化恢复测试
- [ ] **监控数据无远程存储**：Prometheus 本地 TSDB，节点故障则历史数据丢失；
      生产需配合远程存储或 Thanos 类方案
- [ ] **Grafana 使用默认弱密码**：首次登录后修改的密码强度未受策略约束
- [ ] **未配置日志采集**：当前是"指标"监控，未把系统日志接入
      （课程项目中的 Loki 方案可迁移过来，形成日志 + 指标的统一可观测性）

**阶段 4 新增的待改进项**

- [ ] **journald 未持久化**（`Storage=persistent`）：日志只在 `/run`（内存），
      重启即丢。**已实测到具体后果**：走 ISO 救援时**看不到**"上次失败 boot"的日志
      （RAM 已断电），只能靠屏幕人工抄。详见第 5.5 节
- [x] ~~**CD/DVD 设为第一启动项**~~ → **已解决**：原先 CD-ROM 排第一位，每次开机都会先撞
      CentOS 安装盘的启动菜单，而它 **60 秒超时的默认项是「安装 CentOS 7」** ——
      手慢一次就进入安装程序。已把 BIOS 启动顺序改为 **`Hard Drive` 置顶**（存于 NVRAM，
      并已随快照一起固化），开机直接进系统。CD/DVD 的「启动时连接」仍然开着，但启动顺序
      已把它排除在外，不影响开机；安装 ISO 仍留在虚拟机里，
      作为第 4.3 节决策中保留的救援介质
- [ ] **未清理的默认服务**：`cupsd`(631) / `postfix`(25) / `rpcbind`(111) /
      `dnsmasq`(53) 仍在监听；GNOME 图形界面未改为 `multi-user.target`
- [ ] **`health_check.sh` 一处输出文案瑕疵**：ALERT 行里 `systemd 却说他 active`，
      「他」应为「它」。不影响功能，**留到下次改动该文件时一并订正并重记 md5**
- [ ] **`/fix` 每次运行都会留一份 journal 存档**，长期运行需要保留策略
      （例如只保留最近 3 份）

---

## 7. 后续计划

> 阶段 1~4 的完成情况见顶部「项目时间线」，此处只列尚未完成的项。

| 事项 | 内容 | 状态 |
|---|---|---|
| ~~凭据检查与仓库发布~~ | 检查配置文件与命令历史中的凭据 → `.gitignore` → 整理 README 并发布仓库 | ✅ 已完成（2026-10-09，见第 4.6 节） |
| journald 持久化 | `Storage=persistent` + `SystemMaxUse`，让重启后仍能查历史日志（详见第 5.5 节） | 待开始 |
| 清理多余的默认服务 | 关闭未使用的默认服务（清单见第 6 节待改进）；GNOME 改 `multi-user.target` | 待开始 |
| 进阶：云端部署练习 | 域名解析、Let's Encrypt 证书自动续期、安全组与 SSH 加固 | 待开始 |

---

## 附：时间记录

| 日期 | 完成内容 |
|---|---|
| 2026-10-07 | 环境初始化（yum 源、内存扩容、主机名）；服务盘点与验证；巡检脚本编写与调试；磁盘告警演练；crontab 定时配置 |
| 2026-10-08 上午 | 排查并修复 MySQL `innodb_force_recovery` 只读故障；准备 15 万行三表测试数据；mysqldump 备份参数对比与压缩；删库恢复演练（含字符集验证）；备份脚本（防并发/校验/保留）；logrotate 日志轮转配置 |
| 2026-10-08 下午 | 安装 node_exporter / Prometheus / Grafana；导入 Node Exporter Full 看板；编写 4 条告警规则；部署 Alertmanager 与自建 webhook 接收端；配置分级路由与抑制规则；完成端到端告警演练（FIRING → 邮件 → RESOLVED）；巡检脚本扩展至 8 个服务并完成反向测试 |
| 2026-10-08 晚 | **演练 0~3**：开机基线校验；磁盘写满（`fallocate` + `df`/`du` 逐层定位）；nginx 排障与自愈实验（**孤儿 worker**、`KillMode=process`）；熔断机制验证；nginx 配置改坏（`reload` vs `stop/start`）；**SELinux 端口类型**排障（`13 EACCES`） |
| 2026-10-09 上午 | **演练 4**：80 端口被野进程占用（意外挖出 `getfqdn()` 因 `/etc/hosts` 缺本机名而卡 **15 秒**）；**演练 5**：MySQL 配置改坏、`skip-networking`（**服务 active 但端口不监听 → 暴露三层监控盲区**）；巡检脚本升级 **v2** 并用同一故障正反验证 |
| 2026-10-09 下午 | **演练 6**：fstab 故障注入，走通 **emergency mode 就地修复** 与 **ISO 救援 `chroot /mnt/sysimage`** 两条路径；统一 8 个服务的 `Restart` / `KillMode` 策略；建立救援通道 `/fix` + 自动修复钩子并完成 dry-run 验证；修复控制台键盘映射（`cn` → `us`，解决反复 `Login incorrect`） |
