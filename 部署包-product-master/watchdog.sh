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
    # 优先找包含产品大师 activity 的最近会话
    local pm_sessions
    pm_sessions=$(find "$SESSIONS_DIR" -maxdepth 1 -name "*.jsonl" \
        ! -name "*.trajectory.jsonl" \
        -mmin -30 2>/dev/null | while read f; do
        if grep -ql "产品大师\|product-master\|场景锚点\|lead_pm\|reviewer" "$f" 2>/dev/null; then
            echo "$f"
        fi
    done | sort | head -1)

    if [[ -n "$pm_sessions" ]]; then
        echo "$pm_sessions"
        return
    fi

    # fallback: 找最近修改的文件
    find "$SESSIONS_DIR" -maxdepth 1 -name "*.jsonl" \
        ! -name "*.trajectory.jsonl" \
        -mmin -30 2>/dev/null | sort | head -1
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

# 方法3：检测子 Agent 已返回但 Controller 未处理（最常见卡死模式）
UNREAD_RESULT_THRESHOLD=120  # 2分钟未处理 → 唤醒
detect_unread_subagent_result() {
    local sf="$1"
    local now="$2"

    if [[ ! -f "$sf" ]]; then
        echo "ok"
        return
    fi

    python3 -c "
import json, sys

sf = '$sf'
now = $now
threshold = $UNREAD_RESULT_THRESHOLD

try:
    with open(sf) as f:
        lines = [line.strip() for line in f if line.strip()]
except:
    sys.exit(0)

# 分别找到最后 toolResult 和最后 assistant text 的时间戳
last_tool_result_ts = None
last_assistant_text_ts = None
last_tool_result_msg = ''

for line in lines:
    try:
        ev = json.loads(line)
    except:
        continue
    msg = ev.get('message', {})
    role = msg.get('role', '')
    content = msg.get('content', [])
    ts_str = ev.get('timestamp', '')

    # 检查 toolResult
    if role == 'toolResult':
        for item in content if isinstance(content, list) else []:
            if isinstance(item, dict):
                text = item.get('text', '') or item.get('content', '') or item.get('result', '')
                if isinstance(text, str) and len(text) > 50:
                    last_tool_result_ts = ts_str
                    last_tool_result_msg = text[:80]
                    break

    # 检查 assistant text
    if role == 'assistant':
        for item in content if isinstance(content, list) else []:
            if isinstance(item, dict) and item.get('type') == 'text':
                t = item.get('text', '')
                if len(t) > 20:
                    last_assistant_text_ts = ts_str
                    break

# 如果都没有记录，跳过
if not last_tool_result_ts or not last_assistant_text_ts:
    print('ok')
    sys.exit(0)

# 比较时间戳大小（字符串比较在 ISO 格式下是对的）
if last_tool_result_ts <= last_assistant_text_ts:
    # toolResult 在 assistant text 之前 → 正常，已经处理了
    print('ok')
    sys.exit(0)

# toolResult 在 assistant text 之后 → Controller 还没处理
# 计算 toolResult 到现在的时间差
try:
    from datetime import datetime, timezone
    ts_dt = datetime.fromisoformat(last_tool_result_ts[:19])
    ts_epoch = int(ts_dt.timestamp())
    gap = now - ts_epoch
except:
    gap = 0

if gap >= threshold:
    print('missed_result')
else:
    print('ok')
" 2>/dev/null || echo "ok"
}

# 方法4：状态 checkpoint 差检测（🔖 标签未推进）
CHECKPOINT_STALL_THRESHOLD=180  # 3分钟状态未推进 → 警告
detect_checkpoint_stall() {
    local sf="$1"
    local now="$2"

    if [[ ! -f "$sf" ]]; then
        echo "ok"
        return
    fi

    python3 -c "
import json, sys, re

sf = '$sf'
now = $now
threshold = $CHECKPOINT_STALL_THRESHOLD

try:
    with open(sf) as f:
        lines = [line.strip() for line in f if line.strip()]
except:
    sys.exit(0)

# 找所有 assistant 文本中的 🔖 标签
checkpoints = []  # (ts, tag)
for line in lines:
    try:
        ev = json.loads(line)
    except:
        continue
    msg = ev.get('message', {})
    if msg.get('role') != 'assistant':
        continue
    content = msg.get('content', [])
    for item in content if isinstance(content, list) else []:
        if isinstance(item, dict) and item.get('type') == 'text':
            t = item.get('text', '')
            tags = re.findall(r'🔖\[.*?\]', t)
            if tags:
                checkpoints.append((ev.get('timestamp', ''), tags[-1]))

if not checkpoints:
    print('ok')
    sys.exit(0)

last_tag = checkpoints[-1][1]
last_ts = checkpoints[-1][0]

# 计算最后一个 checkpoint 到现在的时间差
try:
    from datetime import datetime
    ts_dt = datetime.fromisoformat(last_ts[:19])
    ts_epoch = int(ts_dt.timestamp())
    gap = now - ts_epoch
except:
    gap = 0

# 只在「等待」类状态时检测
waiting_states = ['等待LeadPM', '等待Reviewer', '等待', '派发LeadPM', '派发Reviewer']
if any(w in last_tag for w in waiting_states) and gap >= threshold:
    print(f'checkpoint_stall:{last_tag}')
else:
    print('ok')
" 2>/dev/null || echo "ok"
}

# 检测卡死：方法1 看最后消息时间差，方法2 看 gateway log，方法3 子 Agent 返回但 Controller 未处理
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

    # 方法3：子 Agent 返回了但 Controller 没读
    if [[ -n "${sf:-}" ]]; then
        local result_status
        result_status=$(detect_unread_subagent_result "$sf" "$now")
        if [[ "$result_status" != "ok" ]]; then
            echo "$result_status"
            return
        fi
    fi

    # 方法4：状态 checkpoint 卡在等待态
    if [[ -n "${sf:-}" ]]; then
        local cp_status
        cp_status=$(detect_checkpoint_stall "$sf" "$now")
        if [[ "$cp_status" != "ok" ]]; then
            echo "$cp_status"
            return
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
        missed_result)
            if (( now - LAST_ACTION > COOLDOWN )); then
                log "🔔 子 Agent 已返回但 Controller 超过 ${UNREAD_RESULT_THRESHOLD}s 未处理，发送强制检查"
                send_message "检查下之前派发的子 Agent 有没有返回，应该是回来了但你没发现。读取最新的 toolResult，合并双 Agent 结果展示给我"
                LAST_ACTION=$now
            fi
            ;;
        checkpoint_stall:*)
            if (( now - LAST_ACTION > COOLDOWN )); then
                local stuck_tag="${status#checkpoint_stall:}"
                log "🔖 状态 ${stuck_tag} 已卡 ${CHECKPOINT_STALL_THRESHOLD}s，发送状态推进指令"
                send_message "你的状态标签停在 ${stuck_tag}，超过3分钟了。检查下子 Agent 有没有返回、有没有合并展示，推进到下一步。"
                LAST_ACTION=$now
            fi
            ;;
        ok|*)
            ;;
    esac
done
