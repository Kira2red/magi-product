#!/bin/bash
# 产品大师看门狗 v2 — 自动检测卡死并恢复
# 用法: nohup bash watchdog.sh &

set -eu

LOG_FILE="/tmp/openclaw/openclaw-$(date +%Y-%m-%d).log"
SESSIONS_DIR="${HOME}/.openclaw/agents/main/sessions"
POKE_THRESHOLD=300      # 5分钟无新消息 → 发 poke
CONVERGE_THRESHOLD=600   # 10分钟无新消息 → 发收敛
COOLDOWN=120             # 两次干预之间至少间隔2分钟
LAST_ACTION=0
OPENCLAW_BIN="${HOME}/.local/bin/openclaw"
LOG_PATH="${HOME}/.openclaw/skills/product-master/watchdog.log"

log() {
    echo "[watchdog $(date '+%H:%M:%S')] $*" | tee -a "$LOG_PATH"
}

send_message() {
    local msg="$1"
    log "发送: $msg"
    if "$OPENCLAW_BIN" agent -m "$msg" --local 2>/dev/null; then
        return 0
    fi
    # fallback: inject user message via agent session
    curl -sf -X POST "http://127.0.0.1:18789/api/agent/message" \
        -H "Content-Type: application/json" \
        -d "{\"message\":\"$msg\"}" 2>/dev/null || true
}

# 检测是否有活跃的 product-master 会话
find_active_session() {
    # 找最近10分钟内修改过的 jsonl 文件（排除 .trajectory.jsonl）
    find "$SESSIONS_DIR" -maxdepth 1 -name "*.jsonl" \
        ! -name "*.trajectory.jsonl" \
        -mmin -30 2>/dev/null | head -1
}

# 获取会话最后一条消息的时间戳（秒）
get_session_last_ts() {
    local sf="$1"
    if [[ ! -f "$sf" ]]; then
        echo 0
        return
    fi

    local last_line
    last_line=$(tail -1 "$sf" 2>/dev/null || true)
    if [[ -z "$last_line" ]]; then
        echo 0
        return
    fi

    local ts
    ts=$(echo "$last_line" | python3 -c "
import json,sys
try:
    d = json.loads(sys.stdin.read().strip())
    print(d.get('timestamp','')[:19])
except:
    print('')
" 2>/dev/null)
    if [[ -z "$ts" ]]; then
        echo 0
        return
    fi

    # 转成 epoch 秒
    if command -v gdate &>/dev/null; then
        gdate -d "$ts" +%s 2>/dev/null || echo 0
    else
        date -j -f "%Y-%m-%dT%H:%M:%S" "$ts" +%s 2>/dev/null || echo 0
    fi
}

# 检测卡死：方法1 看最后消息时间差，方法2 看 gateway log 的 stalled 警告
detect_stall() {
    local now
    now=$(date +%s)

    # 方法1：直接检查 session 文件最后消息时间
    local sf
    sf=$(find_active_session)
    if [[ -n "$sf" ]]; then
        local last_ts
        last_ts=$(get_session_last_ts "$sf")
        if [[ "$last_ts" -gt 0 ]]; then
            local gap=$(( now - last_ts ))
            if [[ "$gap" -ge "$CONVERGE_THRESHOLD" ]]; then
                echo "converge"
                return
            elif [[ "$gap" -ge "$POKE_THRESHOLD" ]]; then
                echo "poke"
                return
            fi
        fi
    fi

    # 方法2：gateway 日志中的 stalled 警告
    if [[ -f "$LOG_FILE" ]]; then
        local last_stalled
        last_stalled=$(grep "stalled session" "$LOG_FILE" 2>/dev/null | tail -1 || true)
        if [[ -z "$last_stalled" ]]; then
            last_stalled=$(grep "long.running.*classification.*long_running" "$LOG_FILE" 2>/dev/null | tail -1 || true)
        fi
        if [[ -n "$last_stalled" ]]; then
            local age
            age=$(echo "$last_stalled" | grep -o '"age":[0-9]*' | grep -o '[0-9]*' | tail -1)
            if [[ -n "$age" && "$age" -ge "$CONVERGE_THRESHOLD" ]]; then
                echo "converge"
                return
            elif [[ -n "$age" && "$age" -ge "$POKE_THRESHOLD" ]]; then
                echo "poke"
                return
            fi
        fi
    fi

    echo "ok"
}

log "看门狗 v2 启动，工作目录: $(pwd)"
log "poke=${POKE_THRESHOLD}s  converge=${CONVERGE_THRESHOLD}s  cooldown=${COOLDOWN}s"

while true; do
    sleep 60

    status=$(detect_stall)
    now=$(date +%s)

    case "$status" in
        converge)
            if (( now - LAST_ACTION > COOLDOWN )); then
                log "⚠️ ${CONVERGE_THRESHOLD}s 无响应，发送收敛"
                send_message "收敛"
                LAST_ACTION=$now
            fi
            ;;
        poke)
            if (( now - LAST_ACTION > COOLDOWN )); then
                log "⏱ ${POKE_THRESHOLD}s 无响应，发送唤醒"
                send_message "到哪了"
                LAST_ACTION=$now
            fi
            ;;
        ok|*)
            ;;
    esac
done
