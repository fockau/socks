#!/bin/bash
set -o pipefail

# ===== REQUIRED ENV =====
PRIMARY_CONFIG_URL="${PRIMARY_CONFIG_URL:?环境变量 PRIMARY_CONFIG_URL 未设置}"
BACKUP_CONFIG_URL="${BACKUP_CONFIG_URL:?环境变量 BACKUP_CONFIG_URL 未设置}"

# ===== OPTIONAL ENV (WITH DEFAULTS) =====
CONFIG_FILE="${CONFIG_FILE:-/etc/openvpn/client/client.ovpn}"
LOG_FILE="${LOG_FILE:-/var/log/openvpn.log}"

CHECK_INTERVAL="${CHECK_INTERVAL:-10}"
MAX_RETRIES="${MAX_RETRIES:-1}"                     # 每个配置源下载失败一次就切换
CONFIG_RETRY_INTERVAL="${CONFIG_RETRY_INTERVAL:-5}"
RECOVERY_DELAY="${RECOVERY_DELAY:-5}"
LOG_MAX_SIZE_MB="${LOG_MAX_SIZE_MB:-10}"

VPN_START_PER_TRY_WAIT="${VPN_START_PER_TRY_WAIT:-20}"           # 单次启动最长等待秒数
MAX_VPN_FAIL_SECONDS_PER_CONFIG="${MAX_VPN_FAIL_SECONDS_PER_CONFIG:-300}"  # 每个配置累计启动失败时间上限（秒）

TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"
INSTANCE_NAME="${INSTANCE_NAME:-VPN}"

# SOCKS 检测相关
SOCKS_CHECK_INTERVAL="${SOCKS_CHECK_INTERVAL:-10}"   # 检测间隔秒
LOG_ONLY_ERRORS="${LOG_ONLY_ERRORS:-true}"          # 只在失败时记录检测日志
MONITOR_SUCCESS_EVERY_N="${MONITOR_SUCCESS_EVERY_N:-0}" # >0 时每 N 次成功记录一次

# danted 日志路径（用于恢复时一并清理）
DANTED_LOG_FILE="${DANTED_LOG_FILE:-/var/log/danted.log}"

# SOCKS 代理地址（nc 使用）
SOCKS_PROXY_ADDR="${SOCKS_PROXY_ADDR:-127.0.0.1:1080}"

# ===== RUNTIME STATE =====
RECOVERY_LOCK=false
CURRENT_SOCKS_PID=0
VPN_PID=""

# 每个配置累计“启动失败等待时间”（秒）
PRIMARY_VPN_FAIL_SECONDS=0
BACKUP_VPN_FAIL_SECONDS=0

# 当前 CONFIG_FILE 对应的是主还是备（"主" / "备"）
CURRENT_CONFIG_LABEL=""
# choose_config_label() 输出的下一轮要用的配置
NEXT_CONFIG_LABEL=""

# ----- LOG ROTATION: copytruncate style -----
check_log_size() {
  [ -z "$LOG_FILE" ] && return 0
  [ ! -f "$LOG_FILE" ] && return 0

  local max_bytes=$((LOG_MAX_SIZE_MB * 1024 * 1024))
  local size
  size=$(wc -c <"$LOG_FILE" 2>/dev/null || echo 0)

  if [ "$size" -ge "$max_bytes" ]; then
    : > "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - [日志轮转] $LOG_FILE 超过 ${LOG_MAX_SIZE_MB}MB，已就地清空" >> "$LOG_FILE"
  fi
}

log() {
  check_log_size
  local message
  message="$(date '+%Y-%m-%d %H:%M:%S') - $1"
  echo "$message" | tee -a "$LOG_FILE"
}

clear_log() {
  log "[清理] 准备清理日志文件..."
  : > "$LOG_FILE"
  if [ -n "$DANTED_LOG_FILE" ] && [ -f "$DANTED_LOG_FILE" ]; then
    : > "$DANTED_LOG_FILE"
  fi
  log "[清理] OpenVPN 日志和 danted 日志已清空"
}

# ===== Telegram 发送：一次 + 最多两次重试，发 ping0.cc + cip.cc 完整信息 =====
send_telegram_message() {
  local message="$1"

  if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
    log "[Telegram] 未配置 TG_BOT_TOKEN 或 TG_CHAT_ID，跳过发送"
    return 0
  fi

  local send_url="https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"
  local max_attempts=3
  local attempt=1
  local send_response
  local send_status

  # 把实例名加在最上面
  local text="${INSTANCE_NAME} 当前IP信息如下："$'\n'"${message}"

  while [ $attempt -le $max_attempts ]; do
    log "[Telegram] 尝试发送消息 (第 ${attempt}/${max_attempts} 次)..."

    send_response=$(curl -s -X POST "$send_url" \
      -d "chat_id=${TG_CHAT_ID}" \
      --data-urlencode "text=${text}" \
      --http1.1 --tls-max 1.2 \
      --connect-timeout 5 --max-time 10 2>/dev/null)

    send_status=$?

    if [ $send_status -eq 0 ] && echo "$send_response" | grep -q '"ok":true'; then
      log "[Telegram] 消息已成功发送"
      return 0
    else
      log "[Telegram] 错误：发送失败 (状态码: $send_status, 响应: $send_response)"
    fi

    attempt=$((attempt + 1))
    if [ $attempt -le $max_attempts ]; then
      sleep 2
    fi
  done

  log "[Telegram] 多次重试后仍发送失败"
  return 1
}

# ===== 配置选择策略：根据每个配置累计启动失败时间切换 =====
choose_config_label() {
  if [ "$PRIMARY_VPN_FAIL_SECONDS" -lt "$MAX_VPN_FAIL_SECONDS_PER_CONFIG" ] && \
     [ "$BACKUP_VPN_FAIL_SECONDS" -lt "$MAX_VPN_FAIL_SECONDS_PER_CONFIG" ]; then
    NEXT_CONFIG_LABEL="主"
    return 0
  fi

  if [ "$PRIMARY_VPN_FAIL_SECONDS" -ge "$MAX_VPN_FAIL_SECONDS_PER_CONFIG" ] && \
     [ "$BACKUP_VPN_FAIL_SECONDS" -lt "$MAX_VPN_FAIL_SECONDS_PER_CONFIG" ]; then
    log "[配置策略] 主配置累计启动失败时间已达阈值 (${PRIMARY_VPN_FAIL_SECONDS}s >= ${MAX_VPN_FAIL_SECONDS_PER_CONFIG}s)，优先使用备用配置"
    NEXT_CONFIG_LABEL="备"
    return 0
  fi

  if [ "$BACKUP_VPN_FAIL_SECONDS" -ge "$MAX_VPN_FAIL_SECONDS_PER_CONFIG" ] && \
     [ "$PRIMARY_VPN_FAIL_SECONDS" -lt "$MAX_VPN_FAIL_SECONDS_PER_CONFIG" ]; then
    log "[配置策略] 备用配置累计启动失败时间已达阈值 (${BACKUP_VPN_FAIL_SECONDS}s >= ${MAX_VPN_FAIL_SECONDS_PER_CONFIG}s)，优先使用主配置"
    NEXT_CONFIG_LABEL="主"
    return 0
  fi

  log "[配置策略] 主/备配置累计失败时间均超过阈值，仍优先尝试主配置"
  NEXT_CONFIG_LABEL="主"
}

# ===== 下载指定来源的配置（主 or 备）=====
download_config_for_source() {
  local label="$1"
  local src=""

  if [ "$label" = "主" ]; then
    src="$PRIMARY_CONFIG_URL"
  else
    src="$BACKUP_CONFIG_URL"
  fi

  local retry=0
  while [ $retry -lt "$MAX_RETRIES" ]; do
    log "[配置更新] 尝试从${label}配置下载 (第 $((retry+1))/$MAX_RETRIES 次)"

    if curl -sSf --connect-timeout 20 --max-time 30 "$src" -o "$CONFIG_FILE.tmp"; then
      if grep -q "client" "$CONFIG_FILE.tmp" && \
         grep -q "dev tun" "$CONFIG_FILE.tmp" && \
         grep -q "remote " "$CONFIG_FILE.tmp"; then

        sed -i '/^cipher AES-128-CBC$/d' "$CONFIG_FILE.tmp"
        echo "data-ciphers AES-256-GCM:AES-128-GCM:AES-128-CBC" >> "$CONFIG_FILE.tmp"
        echo "data-ciphers-fallback AES-128-CBC" >> "$CONFIG_FILE.tmp"

        mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"

        log "[配置更新] 下载验证成功 (来源: ${label}配置: $src)"
        CURRENT_CONFIG_LABEL="$label"
        return 0
      else
        log "[配置更新] 错误：${label}配置缺少必要字段"
        rm -f "$CONFIG_FILE.tmp"
      fi
    else
      log "[配置更新] 错误：从${label}配置下载失败"
      rm -f "$CONFIG_FILE.tmp"
    fi

    retry=$((retry + 1))
    if [ $retry -lt "$MAX_RETRIES" ]; then
      sleep "$CONFIG_RETRY_INTERVAL"
    fi
  done

  log "[配置更新] ${label}配置在本轮尝试中下载失败"
  return 1
}

# ===== 高层 download_config：根据失败时间决定先主还是先备，下载失败就切另一边 =====
download_config() {
  choose_config_label

  local first_label="$NEXT_CONFIG_LABEL"
  local second_label
  if [ "$first_label" = "主" ]; then
    second_label="备"
  else
    second_label="主"
  fi

  if download_config_for_source "$first_label"; then
    return 0
  fi

  log "[配置更新] ${first_label}配置本轮下载失败，尝试${second_label}配置"

  if download_config_for_source "$second_label"; then
    return 0
  fi

  log "[配置更新] 主/备两个配置源本轮下载均失败"
  return 1
}

# ===== VPN 启动失败时间统计 =====
update_vpn_fail_time() {
  local elapsed="$1"
  local result="$2"  # "success" 或 "fail"

  case "$CURRENT_CONFIG_LABEL" in
    "主")
      if [ "$result" = "success" ]; then
        PRIMARY_VPN_FAIL_SECONDS=0
        log "[配置统计] 主配置启动成功，累计失败时间重置为 0 秒"
      else
        PRIMARY_VPN_FAIL_SECONDS=$((PRIMARY_VPN_FAIL_SECONDS + elapsed))
        log "[配置统计] 主配置累计启动失败时间: ${PRIMARY_VPN_FAIL_SECONDS} 秒"
      fi
      ;;
    "备")
      if [ "$result" = "success" ]; then
        BACKUP_VPN_FAIL_SECONDS=0
        log "[配置统计] 备用配置启动成功，累计失败时间重置为 0 秒"
      else
        BACKUP_VPN_FAIL_SECONDS=$((BACKUP_VPN_FAIL_SECONDS + elapsed))
        log "[配置统计] 备用配置累计启动失败时间: ${BACKUP_VPN_FAIL_SECONDS} 秒"
      fi
      ;;
    *)
      log "[配置统计] 警告: CURRENT_CONFIG_LABEL 未设置，无法统计失败时间"
      ;;
  esac
}

# ===== SOCKS 相关 =====
stop_socks() {
  if [ "$CURRENT_SOCKS_PID" -ne 0 ]; then
    if kill -0 "$CURRENT_SOCKS_PID" 2>/dev/null; then
      kill "$CURRENT_SOCKS_PID"
      wait "$CURRENT_SOCKS_PID" 2>/dev/null
      log "[SOCKS] 已停止 (PID: $CURRENT_SOCKS_PID)"
      CURRENT_SOCKS_PID=0
    else
      log "[SOCKS] 进程不存在 (PID: $CURRENT_SOCKS_PID)"
      CURRENT_SOCKS_PID=0
    fi
  else
    log "[SOCKS] 无进程可停止"
  fi
  sleep "$RECOVERY_DELAY"
}

start_socks() {
  if [ "$CURRENT_SOCKS_PID" -ne 0 ] && kill -0 "$CURRENT_SOCKS_PID" 2>/dev/null; then
    log "[SOCKS] 已在运行 (PID: $CURRENT_SOCKS_PID)"
    return 0
  fi

  log "[SOCKS] 启动中..."
  /usr/sbin/danted -f /etc/danted.conf > "$DANTED_LOG_FILE" 2>&1 &
  CURRENT_SOCKS_PID=$!

  sleep 2
  if kill -0 "$CURRENT_SOCKS_PID" 2>/dev/null; then
    log "[SOCKS] 启动成功 (PID: $CURRENT_SOCKS_PID)"
    sleep "$RECOVERY_DELAY"
    return 0
  else
    log "[SOCKS] 启动失败"
    CURRENT_SOCKS_PID=0
    return 1
  fi
}

# ===== VPN 相关 =====
stop_vpn() {
  if [ -n "$VPN_PID" ] && kill -0 "$VPN_PID" 2>/dev/null; then
    kill "$VPN_PID"
    wait "$VPN_PID" 2>/dev/null
    log "[VPN] 已停止 (PID: $VPN_PID)"
    VPN_PID=""
  else
    log "[VPN] 无进程可停止"
  fi
  sleep "$RECOVERY_DELAY"
}

start_vpn() {
  stop_vpn
  log "[VPN] 启动中 (配置: ${CURRENT_CONFIG_LABEL:-未知})..."

  if openvpn --config "$CONFIG_FILE" >> "$LOG_FILE" 2>&1 & then
    VPN_PID=$!
    local wait_time=0
    local max_wait="$VPN_START_PER_TRY_WAIT"
    local start_ts
    local end_ts
    local elapsed

    start_ts=$(date +%s)

    while [ $wait_time -lt "$max_wait" ]; do
      if ! kill -0 "$VPN_PID" 2>/dev/null; then
        log "[VPN] 进程在启动过程中意外退出"
        end_ts=$(date +%s)
        elapsed=$((end_ts - start_ts))
        update_vpn_fail_time "$elapsed" "fail"
        return 1
      fi

      if tail -n 50 "$LOG_FILE" | grep -q "Initialization Sequence Completed"; then
        log "[VPN] 启动成功 (PID: $VPN_PID, 配置: ${CURRENT_CONFIG_LABEL:-未知})"
        update_vpn_fail_time 0 "success"
        sleep "$RECOVERY_DELAY"
        return 0
      fi

      sleep 1
      wait_time=$((wait_time + 1))
    done

    log "[VPN] 启动超时（${max_wait} 秒内未完成初始化）"
    kill "$VPN_PID" 2>/dev/null || true
    end_ts=$(date +%s)
    elapsed=$((end_ts - start_ts))
    update_vpn_fail_time "$elapsed" "fail"
    return 1
  else
    log "[VPN] 启动失败（openvpn 无法启动）"
    update_vpn_fail_time 0 "fail"
    return 1
  fi
}

# ===== SOCKS 纯 TCP 连通性检测（nc）=====
check_socks_tcp() {
  if ! command -v nc >/dev/null 2>&1; then
    log "[SOCKS检测] 警告: 未找到 nc 命令，跳过 TCP 握手检测（请在镜像中安装 netcat-openbsd）"
    return 0
  fi

  local proxy_addr="$SOCKS_PROXY_ADDR"
  local targets=("1.1.1.1 443" "8.8.8.8 443" "9.9.9.9 443")
  local t host port

  for t in "${targets[@]}"; do
    set -- $t
    host="$1"
    port="$2"
    if nc -x "$proxy_addr" -X 5 -z -w 5 "$host" "$port" >/dev/null 2>&1; then
      return 0
    fi
  done

  return 1
}

monitor_socks() {
  log "[SOCKS监控] 启动监控 (${SOCKS_CHECK_INTERVAL}秒间隔)"
  log "[SOCKS监控] 尝试获取初始IP..."

  local ping0_info cip_info combined

  # 通过 SOCKS 请求 ping0.cc/geo 完整信息
  ping0_info=$(curl -sSf --connect-timeout 10 --max-time 15 --location --fail \
      --socks5-hostname 127.0.0.1:1080 "http://ping0.cc/geo" \
      --http1.1 --tls-max 1.2 2>/dev/null || true)

  # 通过 SOCKS 请求 cip.cc 完整信息
  cip_info=$(curl -sSf --connect-timeout 10 --max-time 15 --location --fail \
      --socks5-hostname 127.0.0.1:1080 "http://cip.cc" \
      --http1.1 --tls-max 1.2 2>/dev/null || true)

  if echo "$ping0_info" | grep -Eq '([0-9]{1,3}\.){3}[0-9]{1,3}'; then
    log "[SOCKS监控] 初始IP获取成功 (来自 ping0.cc): $(echo "$ping0_info" | head -n 1)"
  else
    log "[SOCKS监控] 初始IP获取失败或格式异常"
    log "[SOCKS监控] ping0.cc 返回内容: $ping0_info"
  fi

  combined="${ping0_info}"$'\n\n'"${cip_info}"

  send_telegram_message "$combined"

  local socks_fail_count=0
  local max_fail_count=3
  local total_checks=0
  local success_count=0

  while true; do
    if ! kill -0 "$VPN_PID" 2>/dev/null; then
      log "[SOCKS监控] VPN进程已终止 (PID: $VPN_PID)"
      return 1
    fi

    total_checks=$((total_checks + 1))

    if check_socks_tcp; then
      socks_fail_count=0
      success_count=$((success_count + 1))
      if [ "$LOG_ONLY_ERRORS" != "true" ]; then
        if [ "$MONITOR_SUCCESS_EVERY_N" -gt 0 ]; then
          if [ $((success_count % MONITOR_SUCCESS_EVERY_N)) -eq 0 ]; then
            log "[SOCKS检测] 连通性正常 (TCP handshake，通过 SOCKS) (累计OK: $success_count)"
          fi
        else
          log "[SOCKS检测] 连通性正常 (TCP handshake，通过 SOCKS)"
        fi
      fi
    else
      socks_fail_count=$((socks_fail_count + 1))
      log "[SOCKS检测] 失败 (累计:${socks_fail_count}/${max_fail_count}) —— 通过 SOCKS 的 TCP 握手到公网 IP 均失败"
      if [ "$socks_fail_count" -ge "$max_fail_count" ]; then
        log "[SOCKS监控] 达到失败阈值 (连续失败 $max_fail_count 次)，触发恢复流程"
        return 1
      fi
    fi

    sleep "$SOCKS_CHECK_INTERVAL"
  done
}

check_errors() {
  if [ -z "$VPN_PID" ] || ! kill -0 "$VPN_PID" 2>/dev/null; then
    log "[错误检测] VPN进程已退出"
    return 1
  fi

  local log_tail
  log_tail=$(tail -n 30 "$LOG_FILE" 2>/dev/null || echo "")

  if ! grep -q "Initialization Sequence Completed" <<< "$log_tail"; then
    log "[错误检测] VPN未完成初始化"
    return 1
  fi

  local errors=(
    "SIGTERM"
    "TLS Error"
    "AUTH_FAILED"
    "Exiting due to fatal error"
    "Connection reset"
    "process exiting"
    "TLS key negotiation failed"
  )

  local err
  for err in "${errors[@]}"; do
    if grep -q "$err" <<< "$log_tail"; then
      log "[错误检测] 发现错误: $err"
      return 1
    fi
  done

  return 0
}

# ----- 优雅退出：容器 stop/restart 时清理子进程 -----
graceful_exit() {
  log "[退出] 收尾：停止 SOCKS 和 OpenVPN"
  stop_socks
  stop_vpn
  exit 0
}
trap graceful_exit SIGTERM SIGINT

# ===== 启动流程 =====
log "=== OpenVPN自动维护脚本启动 ==="
log "主配置URL: $PRIMARY_CONFIG_URL"
log "备用配置URL: $BACKUP_CONFIG_URL"
log "检测间隔: $CHECK_INTERVAL 秒"
log "日志轮转阈值: ${LOG_MAX_SIZE_MB} MB"
log "SOCKS 检测间隔: ${SOCKS_CHECK_INTERVAL} 秒，LOG_ONLY_ERRORS=${LOG_ONLY_ERRORS}"
log "单次 VPN 启动最大等待: ${VPN_START_PER_TRY_WAIT} 秒"
log "每个配置累计启动失败时间上限: ${MAX_VPN_FAIL_SECONDS_PER_CONFIG} 秒"

while ! download_config; do
  sleep "$CONFIG_RETRY_INTERVAL"
done

if start_vpn && start_socks; then
  log "[初始化] 服务启动成功"
else
  log "[初始化] 启动失败"
fi

# ===== 维护循环 =====
while true; do
  if ! $RECOVERY_LOCK && { ! check_errors || [ -z "$VPN_PID" ] || ! monitor_socks; }; then
    RECOVERY_LOCK=true
    log "[恢复] ====== 开始恢复流程 ======"
    log "[恢复] 步骤1/6: 停止SOCKS代理..."
    stop_socks
    log "[恢复] 步骤2/6: 停止OpenVPN..."
    stop_vpn
    log "[恢复] 步骤3/6: 清理日志文件..."
    clear_log
    log "[恢复] 步骤4/6: 选择并下载配置..."
    if download_config; then
      log "[恢复] 步骤5/6: 启动OpenVPN..."
      if start_vpn; then
        log "[恢复] 步骤6/6: 启动SOCKS代理..."
        if start_socks; then
          log "[恢复] 恢复成功"
        else
          log "[恢复] SOCKS启动失败"
        fi
      else
        log "[恢复] OpenVPN启动失败"
      fi
    else
      log "[恢复] 配置下载失败"
    fi
    RECOVERY_LOCK=false
    log "[恢复] ====== 恢复流程结束 ======"
  fi
  sleep "$CHECK_INTERVAL"
done
