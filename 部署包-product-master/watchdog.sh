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

# 检测是否有活跃的 product-master 会话（硬逻辑，不走 grep 猜测）
find_controller_session() {
    python3 -c "
import os, json, glob, re

sessions_dir = os.path.expanduser('$SESSIONS_DIR')
candidates = []

for sf in glob.glob(f'{sessions_dir}/*.jsonl'):
    if 'trajectory' in sf:
        continue
    try:
        mtime = os.path.getmtime(sf)
        size = os.path.getsize(sf)
    except:
        continue

    # 跳过太小的文件（< 5KB，通常是刚创建的空 session）
    if size < 5000:
        continue

    # 跳过子 Agent 会话（第一个 user 消息包含 [Subagent Context]）
    try:
        with open(sf) as f:
            head = f.read(8192)
    except:
        continue

    is_subagent = '[Subagent Context]' in head
    if is_subagent:
        continue

    # 评分：session 越匹配产品大师，分数越高
    score = 0
    if '产品大师' in head or 'product-master' in head:
        score += 10
    if '🔖[' in head:
        score += 20
    if 'sessions_spawn' in head:
        score += 15
    if '启用产品大师' in head or '启动产品大师' in head:
        score += 30
    if '阶段' in head:
        score += 5

    candidates.append((sf, mtime, score))

# 按分数降序 + 时间降序排序
candidates.sort(key=lambda x: (x[2], x[1]), reverse=True)

if candidates:
    print(candidates[0][0])
else:
    print('')
" 2>/dev/null
}

find_active_session() {
    local pm_session
    pm_session=$(find_controller_session)
    if [[ -n "$pm_session" ]]; then
        echo "$pm_session"
        return
    fi

    # 最终 fallback：找最近修改的非 subagent session
    find "$SESSIONS_DIR" -maxdepth 1 -name "*.jsonl" \
        ! -name "*.trajectory.jsonl" \
        -mmin -60 2>/dev/null | while read f; do
        if ! grep -q '\[Subagent Context\]' "$f" 2>/dev/null; then
            echo "$f"
            break
        fi
    done
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

# 方法5：双 Agent 都返回了但 Controller 没合并（最常见卡死模式之二）
DUAL_RETURN_THRESHOLD=120  # 2分钟未合并 → 强制
detect_dual_return_no_merge() {
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
threshold = $DUAL_RETURN_THRESHOLD

try:
    with open(sf) as f:
        lines = [line.strip() for line in f if line.strip()]
except:
    sys.exit(0)

# 找所有 checkpoint 标签
checkpoints = []
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

# 找「Lead PM 已返回」和「Reviewer 已返回」的时间点
lp_return_ts = None
rv_return_ts = None
merge_after_returns = False
last_is_merge = ('合并展示' in checkpoints[-1][1])

for ts, tag in checkpoints:
    if 'LeadPM已返回' in tag or 'PM已返回' in tag or 'LeadPM完成' in tag:
        lp_return_ts = ts
    if 'Reviewer已返回' in tag or 'Reviewer完成' in tag:
        rv_return_ts = ts
    # 检查合并是否发生在两者都返回之后
    if lp_return_ts and rv_return_ts and '合并展示' in tag:
        merge_after_returns = True

# 双 Agent 都返回了吗？
if not lp_return_ts or not rv_return_ts:
    print('ok')
    sys.exit(0)

# 已经合并了？
if merge_after_returns or last_is_merge:
    print('ok')
    sys.exit(0)

# 计算两者都返回以来的时间（取较晚的那个）
try:
    from datetime import datetime
    later_ts = max(lp_return_ts, rv_return_ts)
    ts_dt = datetime.fromisoformat(later_ts[:19])
    ts_epoch = int(ts_dt.timestamp())
    gap = now - ts_epoch
except:
    gap = 0

if gap >= threshold:
    print(f'dual_return_no_merge:{gap}')
else:
    print('ok')
" 2>/dev/null || echo "ok"
}


# 方法6：任务完成标记检测（子 Agent 写了 marker 但 Controller 没继续）
MARKER_STALL_THRESHOLD=90
detect_marker_but_no_progress() {
    local sf="$1"
    local now="$2"

    if [[ ! -d /tmp/pm-marker ]]; then
        echo "ok"
        return
    fi

    if [[ ! -f "$sf" ]]; then
        echo "ok"
        return
    fi

    python3 -c "
import json, sys, os, re, glob

sf = '$sf'
now = $now
threshold = $MARKER_STALL_THRESHOLD
marker_dir = '/tmp/pm-marker'

try:
    with open(sf) as f:
        lines = [line.strip() for line in f if line.strip()]
except:
    sys.exit(0)

spawn_tasks = set()
completed_spawns = set()

for line in lines:
    try:
        ev = json.loads(line)
    except:
        continue
    msg = ev.get('message', {})
    content = msg.get('content', [])

    for item in content if isinstance(content, list) else []:
        if not isinstance(item, dict):
            continue
        if item.get('type') == 'toolCall' and item.get('name') == 'sessions_spawn':
            tn = item.get('arguments', {}).get('taskName', '')
            if tn:
                spawn_tasks.add(tn)
    if msg.get('role') == 'toolResult':
        for item in content if isinstance(content, list) else []:
            if isinstance(item, dict):
                text = str(item.get('text', '') or item.get('content', '') or item.get('result', ''))
                for tn in list(spawn_tasks):
                    if tn in text:
                        completed_spawns.add(tn)

pending_markers = []
for tn in spawn_tasks:
    if tn in completed_spawns:
        continue
    marker_path = os.path.join(marker_dir, f'{tn}.done')
    if os.path.exists(marker_path):
        mtime = os.path.getmtime(marker_path)
        marker_age = now - mtime
        pending_markers.append((tn, marker_age))

if not pending_markers:
    print('ok')
    sys.exit(0)

for tn, age in pending_markers:
    if age >= threshold:
        print(f'marker_lost:{tn}')
        sys.exit(0)

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

    # 方法5：双 Agent 都返回了但 Controller 没合并
    if [[ -n "${sf:-}" ]]; then
        local dr_status
        dr_status=$(detect_dual_return_no_merge "$sf" "$now")
        if [[ "$dr_status" != "ok" ]]; then
            echo "$dr_status"
            return
        fi
    fi

    # 方法6：子 Agent 写了 marker 文件但 Controller 未继续（信号丢失卡死）
    if [[ -n "${sf:-}" ]]; then
        local marker_status
        marker_status=$(detect_marker_but_no_progress "$sf" "$now")
        if [[ "$marker_status" != "ok" ]]; then
            echo "$marker_status"
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
                log "🔔 子 Agent 已返回但 Controller 超过 ${UNREAD_RESULT_THRESHOLD}s 未处理，硬重启"
                send_message "你已经漏掉了子 Agent 的返回结果。现在立刻：1.停止当前等待 2.找到最新的 toolResult 或 subagent 返回消息 3.读取它的内容 4.合并双 Agent 结果展示给我。不要解释，直接执行。"
                LAST_ACTION=$now
            fi
            ;;
        checkpoint_stall:*)
            if (( now - LAST_ACTION > COOLDOWN )); then
                local stuck_tag="${status#checkpoint_stall:}"
                log "🔖 状态 ${stuck_tag} 已卡 ${CHECKPOINT_STALL_THRESHOLD}s，硬重启"

                # 根据卡住的状态生成精准的介入指令
                local action_msg
                if echo "$stuck_tag" | grep -q "等待LeadPM\|派发LeadPM"; then
                    action_msg="你停在等待 Lead PM 的状态。Lead PM 可能已经返回但你没发现。立刻：1.取消等待 2.找 Lead PM 的返回结果（toolResult 或文件路径）3.如果 Lead PM 已回，合并展示；如果超时10分钟，标记为超时、跳过 Lead PM 进入下一步"
                elif echo "$stuck_tag" | grep -q "等待Reviewer\|派发Reviewer"; then
                    action_msg="你停在等待 Reviewer 的状态。Reviewer 可能已经返回但你没发现。立刻：1.取消等待 2.找 Reviewer 的返回结果 3.如果已回，合并展示；如果超时，自己代替 Reviewer 做审查然后合并展示"
                else
                    action_msg="你的状态停在 ${stuck_tag} 超过3分钟了。检查子 Agent 有没有返回、有没有合并展示，如果卡死了就跳过当前步骤进入下一步，把已有产出展示给我。"
                fi
                send_message "$action_msg"
                LAST_ACTION=$now
            fi
            ;;
        dual_return_no_merge:*)
            if (( now - LAST_ACTION > COOLDOWN )); then
                local gap_secs="${status#dual_return_no_merge:}"
                log "🔔 双 Agent 已返回 ${gap_secs}s 但未合并，注入强制合并指令"
                send_message "你的 checkpoint 标签显示 Lead PM 和 Reviewer 都已经返回了，但你没有合并展示。立刻：1.停止等待 2.读取两者的返回内容 3.合并后展示给我。不要再等了。"
                LAST_ACTION=$now
            fi
            ;;
        marker_lost:*)
            if (( now - LAST_ACTION > COOLDOWN )); then
                local lost_task="${status#marker_lost:}"
                log "📌 子 Agent ${lost_task} 已写完成标记但信号丢失，注入推进指令"
                send_message "子 Agent ${lost_task} 的完成标记文件已存在，说明任务实际已完成但返回信号丢失了。立刻：1.读取最新产出文件 2.继续下一步流程。"
                LAST_ACTION=$now
            fi
            ;
        ok|*)
            ;;
    esac
done
