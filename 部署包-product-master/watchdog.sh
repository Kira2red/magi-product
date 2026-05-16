#!/bin/bash
# 产品大师看门狗 — 自动检测卡死并恢复
# 用法: nohup bash watchdog.sh &

set -euo pipefail

LOG_FILE="/tmp/openclaw/openclaw-$(date +%Y-%m-%d).log"
STALL_THRESHOLD=300      # 5分钟卡死 → 发 poke
CONVERGE_THRESHOLD=600   # 10分钟卡死 → 发收敛
COOLDOWN=120             # 两次干预之间至少间隔2分钟
LAST_ACTION=0
OPENCLAW_BIN="/Users/didi/.local/bin/openclaw"

log() {
    echo "[watchdog $(date '+%H:%M:%S')] $*"
}

send_message() {
    local msg="$1"
    log "发送: $msg"
    if ! "$OPENCLAW_BIN" agent -m "$msg" --local 2>/dev/null; then
        # fallback: inject via config token approach
        log "agent命令失败，尝试直接发送…"
        curl -s -X POST "http://127.0.0.1:18789/api/agent/message" \
            -H "Content-Type: application/json" \
            -d "{\"message\":\"$msg\"}" 2>/dev/null || true
    fi
}

detect_stall() {
    if [[ ! -f "$LOG_FILE" ]]; then
        return 0
    fi

    local now
    now=$(date +%s)

    # 找最新的 stalled session 日志
    local last_stalled
    last_stalled=$(grep "stalled session" "$LOG_FILE" 2>/dev/null | tail -1 || true)
    if [[ -z "$last_stalled" ]]; then
        # 也检查 long-running session
        last_stalled=$(grep "long.running.*classification.*long_running" "$LOG_FILE" 2>/dev/null | tail -1 || true)
    fi

    if [[ -z "$last_stalled" ]]; then
        return 0
    fi

    # 提取 age 值
    local age
    age=$(echo "$last_stalled" | grep -o '"age":[0-9]*' | grep -o '[0-9]*' | tail -1)
    if [[ -z "$age" ]]; then
        return 0
    fi

    # 提取该日志的时间戳
    local log_time
    log_time=$(echo "$last_stalled" | grep -o '"time":"[^"]*"' | head -1 | cut -d'"' -f4)
    if [[ -z "$log_time" ]]; then
        return 0
    fi

    # 将日志时间转为秒
    local log_epoch
    if command -v gdate &>/dev/null; then
        log_epoch=$(gdate -d "$log_time" +%s 2>/dev/null || echo 0)
    else
        log_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${log_time:0:19}" +%s 2>/dev/null || echo 0)
    fi

    if [[ "$log_epoch" -eq 0 ]]; then
        return 0
    fi

    # 估算当前延迟 = 日志年龄age + 日志本身的时间差
    local total_age=$(( age + now - log_epoch ))

    if [[ "$total_age" -ge "$CONVERGE_THRESHOLD" ]]; then
        echo "converge"
    elif [[ "$total_age" -ge "$STALL_THRESHOLD" ]]; then
        echo "poke"
    else
        echo "ok"
    fi
}

log "看门狗启动，监控 $LOG_FILE"
log "软阈值=${STALL_THRESHOLD}s  硬阈值=${CONVERGE_THRESHOLD}s"

while true; do
    sleep 60

    local status
    status=$(detect_stall)
    local now
    now=$(date +%s)

    case "$status" in
        converge)
            if (( now - LAST_ACTION > COOLDOWN )); then
                log "⚠️ 检测到超过 ${CONVERGE_THRESHOLD}s 卡死，发送收敛指令"
                send_message "收敛"
                LAST_ACTION=$now
            fi
            ;;
        poke)
            if (( now - LAST_ACTION > COOLDOWN )); then
                log "⏱ 检测到超过 ${STALL_THRESHOLD}s 无响应，发送唤醒"
                send_message "到哪了"
                LAST_ACTION=$now
            fi
            ;;
        ok|*)
            ;;
    esac
done
