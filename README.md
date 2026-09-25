# Linux 服务器自动化巡检与故障排查工具

单文件 Bash 巡检脚本：一条命令完成系统信息、CPU、内存、磁盘、核心服务、安全日志、监听端口、网络连通性的全量检查，生成带时间戳的 TXT 巡检报告；发现异常时以非零退出码返回，可无缝接入 cron 定时任务。

> 对应岗位：日常巡检 / 日常监控 / 告警处理 / 故障处理 / 安全评估

## 功能清单

| 巡检模块 | 检查内容 | 异常判定 |
| --- | --- | --- |
| 系统信息 | 操作系统、内核、运行时长 | — |
| CPU | 型号、核数、使用率（/proc/stat 双采样）、负载 | 使用率 > 阈值 |
| 内存 | 使用率（按可用内存计算）、Swap | 使用率 > 阈值 |
| 磁盘 | 全部真实分区容量逐个检查 | 任一分区 > 阈值 |
| 核心服务 | ssh / cron / rsyslog 等服务状态 | 服务未运行 |
| 安全检查 | 最近登录、失败登录尝试、来源 IP TOP5 | 记录供人工研判 |
| 端口检查 | 当前监听端口清单 | 记录供人工比对 |
| 网络检查 | ping 公网 DNS、域名解析、业务 HTTP 探活 | 任一不通 |
| 报告输出 | `reports/inspection_主机名_时间戳.txt` | — |

## 快速开始

```bash
chmod +x health_check.sh
./health_check.sh                  # 巡检并在 reports/ 生成报告
./health_check.sh --outdir /tmp    # 指定报告输出目录
```

退出码：`0` = 全部正常；`1` = 存在告警项。因此可以直接写进定时任务做判断。

## 配置说明

阈值与巡检目标集中在 `inspection.conf`，改配置不改代码：

```bash
CPU_THRESHOLD=85                      # CPU 告警阈值（%）
MEM_THRESHOLD=85                      # 内存告警阈值（%）
DISK_THRESHOLD=85                     # 磁盘告警阈值（%）
SERVICES=(ssh cron rsyslog)           # 需巡检的核心服务
PING_TARGETS=(223.5.5.5 119.29.29.29) # 连通性检测目标
DNS_TARGET="www.baidu.com"            # DNS 解析检测
HTTP_TARGETS=("http://localhost:8080")# 业务 HTTP 探活地址
FAILED_LOGIN_SINCE="7 days ago"       # 失败登录日志回溯窗口
```

配置文件缺失时脚本使用内置默认值，单独分发脚本也能直接跑。

## 定时自动巡检（cron）

```bash
crontab -e
# 每 30 分钟巡检一次，仅保留日志，异常时由退出码驱动后续动作
*/30 * * * * /opt/server-inspection/health_check.sh >/dev/null 2>&1 || echo "巡检发现异常，请查看 reports/" | mail -s "巡检告警" ops@example.com
```

简化版（只留报告文件，人工回看）：

```bash
*/30 * * * * /opt/server-inspection/health_check.sh >/dev/null 2>&1
```

## 故障验证演练（重点）

巡检工具的价值在于"能发现异常"，必须实测一次：

```bash
# 1. 正常状态：HTTP 探活通过，无告警
./health_check.sh

# 2. 制造故障：停止被监控的业务服务（例如项目一的 Nginx 演示站点）
docker stop nginx        # 或 systemctl stop <你的业务服务>

# 3. 再次巡检：HTTP 探活失败，结论为"发现 1 项异常"，退出码 1
./health_check.sh

# 4. 恢复服务后复测，恢复"全部正常"
docker start nginx && ./health_check.sh
```

对比三份报告中的「网络与连通性检查 / 巡检结论」小节，就是一份完整的巡检记录：**正常基线 → 异常发现 → 恢复确认**。

## 相对参考仓库的修改点

基础思路参考 [MickaxL/bash-system-health-check](https://github.com/MickaxL/bash-system-health-check)（MIT License），本项目为学习目的的重写与扩展：

1. **新增配置文件** `inspection.conf`：阈值、服务清单、巡检目标全部可配置，脚本带默认值兜底
2. **新增网络连通性检查**：ping 公网 DNS + 域名解析 + 业务 HTTP 探活（curl），并可与监控栈的 Nginx 站点联动
3. **新增定时任务支持**：非交互环境自动关闭颜色、报告文件不含 ANSI 乱码；非零退出码驱动 cron 告警
4. **登录日志兼容性修正**：原版只读 `/var/log/auth.log`（Debian 系），现依次尝试 `auth.log → /var/log/secure（RHEL 系）→ journalctl`，适配更多发行版
5. **CPU 采集方式修正**：原版用 `top -bn1` 首屏（自开机以来的平均值），现改为 `/proc/stat` 双采样计算瞬时使用率
6. **内存口径修正**：改按"可用内存"（MemAvailable）计算使用率，比 used 列更接近真实占用
7. **磁盘检查增强**：从只查根分区改为遍历全部真实分区逐一判阈值
8. **服务状态兼容**：无 systemd 环境自动回退 `service` 命令，未安装的服务显示"跳过"而非误报
9. **统一 `LC_ALL=C`**：保证 `top/df/sort` 输出格式稳定可解析，不受系统语言影响

## 简历写法参考

> **Linux 服务器自动化巡检与故障排查工具（Shell）**：编写 Bash 巡检脚本实现系统信息、CPU/内存/磁盘、核心服务、安全日志、监听端口与网络连通性的自动化检查，支持阈值配置文件与 journalctl 登录日志兼容；输出带时间戳的巡检报告并按异常结果返回非零退出码，接入 cron 实现定时巡检；通过模拟服务中断完成「正常基线 → 异常发现 → 恢复确认」的巡检验证。

如实区分：脚本为参考开源思路（MIT，感谢原作者 Mickaël Paquet）重写与扩展，上述修改点均为本人完成，可在面试中逐条讲解。

## 环境要求

- Bash 4+（Ubuntu / Debian / RHEL 等主流发行版默认满足）
- 可选命令缺失时自动降级：`curl`（HTTP 探活）、`last`（登录记录）、`ss/netstat`（端口）
