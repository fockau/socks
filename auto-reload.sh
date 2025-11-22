#!/bin/bash
set -o pipefail

PRIMARY_CONFIG_URL="${PRIMARY_CONFIG_URL:?环境变量 PRIMARY_CONFIG_URL 未设置}"
BACKUP_CONFIG_URL="${BACKUP_CONFIG_URL:?环境变量 BACKUP_CONFIG_URL 未设置}"

CONFIG_FILE="${CONFIG_FILE:-/etc/openvpn/client/client.ovpn}"
LOG_FILE="${LOG_FILE:-/var/log/openvpn.log}"
FAIL_COUNT_FILE="${FAIL_COUNT_FILE:-/var/log/openvpnsb.log}"

CHECK_INTERVAL="${CHECK_INTERVAL:-10}"
MAX_RETRIES="${MAX_RETRIES:-3}"
CONFIG_RETRY_INTERVAL="${CONFIG_RETRY_INTERVAL:-5}"
RECOVERY_DELAY="${RECOVERY_DELAY:-5}"
PRIMARY_FAIL_THRESHOLD="${PRIMARY_FAIL_THRESHOLD:-1}"
LOG_MAX_SIZE_MB="${LOG_MAX_SIZE_MB:-10}"

TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"

RECOVERY_LOCK=false
CURRENT_SOCKS_PID=0
VPN_PID=""

# ===== 关键修复：日志轮转“就地清空”，不要 mv =====
check_log_size() {
  [ -z "$LOG_FILE" ] && return 0
  [ ! -f "$LOG_FILE" ] && return 0
  local max_bytes=$((LOG_MAX_SIZE_MB * 1024 * 1024))
  local size
  size=$(wc -c <"$LOG_FILE" 2>/dev/null || echo 0)
  if [ "$size" -ge "$max_bytes" ]; then
    : > "$LOG_FILE"   # 保持 inode，不会断开 openvpn/danted 的 FD
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
  log "[清理] 日志文件已清空"
}

send_telegram_message() {
  local message="$1"
  if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
    log "[Telegram] 未配置 TG_BOT_TOKEN 或 TG_CHAT_ID，跳过发送"
    return 0
  fi
  local bot_token="$TG_BOT_TOKEN"
  local chat_id="$TG_CHAT_ID"
  local send_url="https://api.telegram.org/bot${bot_token}/sendMessage"
  local short_message
  short_message=$(echo "$message" | head -n 2)
  log "[Telegram] 尝试发送新消息..."
  local send_response
  send_response=$(curl -s -X POST "$send_url" \
      -d chat_id="$chat_id" \
      -d text="${INSTANCE_NAME:-VPN} 当前IP:%0A$short_message" \
      --http1.1 \
      --tls-max 1.2 \
      --connect-timeout 5 --max-time 10 2>/dev/null)
  local send_status=$?
  if [ $send_status -eq 0 ] && [ -n "$send_response" ]; then
    log "[Telegram] 消息已成功发送"
  else
    log "[Telegram] 错误：消息发送失败，curl 调用失败 (状态码: $send_status, 响应: $send_response)"
  fi
}

# 失败次数初始化（容错：空/非数字 => 0）
if [ -f "$FAIL_COUNT_FILE" ]; then
  PRIMARY_FAIL_COUNT=$(cat "$FAIL_COUNT_FILE" 2>/dev/null)
  if ! [[ "$PRIMARY_FAIL_COUNT" =~ ^[0-9]+$ ]]; then
    PRIMARY_FAIL_COUNT=0
    echo "0" > "$FAIL_COUNT_FILE"
  fi
  log "[配置切换] 读取主配置失败次数: $PRIMARY_FAIL_COUNT"
else
  PRIMARY_FAIL_COUNT=0
  echo "0" > "$FAIL_COUNT_FILE"
  log "[配置切换] 初始化主配置失败次数: 0"
fi

download_config() {
  local retry_count=0
  local use_backup=false
  local config_url

  if [ "$PRIMARY_FAIL_COUNT" -ge "$PRIMARY_FAIL_THRESHOLD" ]; then
    use_backup=true
    log "[配置切换] 主配置失败次数已达阈值($PRIMARY_FAIL_COUNT)，本次使用备用配置"
  fi

  while [ $retry_count -lt "$MAX_RETRIES" ]; do
    if $use_backup; then
      config_url="$BACKUP_CONFIG_URL"
      log "[配置更新] 尝试从备用配置下载 (第 $((retry_count+1))/$MAX_RETRIES 次)"
    else
      config_url="$PRIMARY_CONFIG_URL"
      log "[配置更新] 尝试从主配置下载 (第 $((retry_count+1))/$MAX_RETRIES 次)"
    fi

    if curl -sSf --connect-timeout 20 --max-time 30 "$config_url" -o "$CONFIG_FILE.tmp"; then
      if grep -q "client" "$CONFIG_FILE.tmp" && \
         grep -q "dev tun" "$CONFIG_FILE.tmp" && \
         grep -q "remote " "$CONFIG_FILE.tmp"; then

        sed -i '/^cipher AES-128-CBC$/d' "$CONFIG_FILE.tmp"
        echo "data-ciphers AES-256-GCM:AES-128-GCM:AES-128-CBC" >> "$CONFIG_FILE.tmp"
        echo "data-ciphers-fallback AES-128-CBC" >> "$CONFIG_FILE.tmp"

        mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"

        if ! $use_backup; then
          PRIMARY_FAIL_COUNT=0
          echo "0" > "$FAIL_COUNT_FILE"
          log "[配置切换] 主配置下载成功，失败次数重置为0"
        fi

        log "[配置更新] 下载验证成功 (来源: $config_url)"
        return 0
      else
        log "[配置更新] 错误：配置缺少必要字段"
        rm -f "$CONFIG_FILE.tmp"
      fi
    else
      log "[配置更新] 错误：从 $config_url 下载失败"
      rm -f "$CONFIG_FILE.tmp"
    fi

    retry_count=$((retry_count + 1))
    sleep "$CONFIG_RETRY_INTERVAL"
  done

  if ! $use_backup; then
    PRIMARY_FAIL_COUNT=$((PRIMARY_FAIL_COUNT + 1))
    echo "$PRIMARY_FAIL_COUNT" > "$FAIL_COUNT_FILE"
    log "[配置切换] 主配置下载失败，失败次数增加至$PRIMARY_FAIL_COUNT"

    if [ "$PRIMARY_FAIL_COUNT" -ge "$PRIMARY_FAIL_THRESHOLD" ]; then
      log "[配置切换] 主配置失败次数已达阈值($PRIMARY_FAIL_COUNT)，将切换到备用配置"
      if curl -sSf --connect-timeout 20 --max-time 30 "$BACKUP_CONFIG_URL" -o "$CONFIG_FILE.tmp"; then
        if grep -q "client" "$CONFIG_FILE.tmp" && \
           grep -q "dev tun" "$CONFIG_FILE.tmp" && \
           grep -q "remote " "$CONFIG_FILE.tmp"; then

          sed -i '/^cipher AES-128-CBC$/d' "$CONFIG_FILE.tmp"
          echo "data-ciphers AES-256-GCM:AES-128-GCM:AES-128-CBC" >> "$CONFIG_FILE.tmp"
          echo "data-ciphers-fallback AES-128-CBC" >> "$CONFIG_FILE.tmp"

          mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
          chmod 600 "$CONFIG_FILE"

          log "[配置更新] 备用配置下载成功"
          return 0
        else
          log "[配置更新] 错误：备用配置缺少必要字段"
          rm -f "$CONFIG_FILE.tmp"
          return 1
        fi
      else
        log "[配置更新] 错误：备用配置下载失败"
        rm -f "$CONFIG_FILE.tmp"
        return 1
      fi
    fi
  fi

  log "[配置更新] 错误：超过最大重试次数"
  return 1
}

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
  # 建议：danted 使用独立日志，避免污染 openvpn.log
  /usr/sbin/danted -f /etc/danted.conf > /var/log/danted.log 2>&1 &
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
  log "[VPN] 启动中..."
  if openvpn --config "$CONFIG_FILE" >> "$LOG_FILE" 2>&1 & then
    VPN_PID=$!
    local wait_time=0
    local max_wait=20
    while [ $wait_time -lt $max_wait ]; do
      if ! kill -0 "$VPN_PID" 2>/dev/null; then
        log "[VPN] 进程意外退出"
        return 1
      fi
      if tail -n 20 "$LOG_FILE" | grep -q "Initialization Sequence Completed"; then
        log "[VPN] 启动成功 (PID: $VPN_PID)"
        sleep "$RECOVERY_DELAY"
        return 0
      fi
      sleep 1
      wait_time=$((wait_time + 1))
    done
    log "[VPN] 启动超时"
    kill "$VPN_PID" 2>/dev/null || true
    return 1
  else
    log "[VPN] 启动失败"
    return 1
  fi
}

monitor_socks() {
  log "[SOCKS监控] 启动监控 (10秒间隔)"
  log "[SOCKS监控] 尝试获取初始IP..."
  local initial_ip
  initial_ip=$(curl -sSf --connect-timeout 10 --max-time 15 --location --fail \
      --socks5-hostname 127.0.0.1:1080 "http://ping0.cc/geo" \
      --http1.1 \
      --tls-max 1.2 \
      2>/dev/null | head -n 2)
  if echo "$initial_ip" | head -n 1 | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
    log "[SOCKS监控] 初始IP获取成功: $(echo "$initial_ip" | head -n 1)"
    send_telegram_message "$initial_ip"
  else
    log "[SOCKS监控] 初始IP获取失败"
    log "[SOCKS监控] 返回内容: $initial_ip"
  fi

  local socks_check_interval=10
  local socks_fail_count=0
  local max_fail_count=3
  local total_checks=0
  local test_urls=("https://www.gstatic.com/generate_204" "https://www.wikipedia.org" "https://www.cloudflare.com")
  local url_index=0
  log "[SOCKS监控] 开始对知名网站进行轮询联通性测试"

  while true; do
    if ! kill -0 "$VPN_PID" 2>/dev/null; then
      log "[SOCKS监控] VPN进程已终止 (PID: $VPN_PID)"
      return 1
    fi

    total_checks=$((total_checks + 1))
    url_index=$((total_checks % 3))
    local current_url=${test_urls[$url_index]}

    log "[SOCKS检测] 测试#${total_checks} 代理连通性 (目标: $current_url)..."

    if timeout 25s curl --silent --show-error --fail \
        --connect-timeout 10 --max-time 15 --location \
        --socks5-hostname 127.0.0.1:1080 "$current_url" \
        --head \
        --http1.1 \
        --tls-max 1.2 \
        >/dev/null 2>&1; then
      log "[SOCKS检测] 连通性正常 - 目标: $current_url"
      socks_fail_count=0
    else
      socks_fail_count=$((socks_fail_count + 1))
      local curl_error
      curl_error=$(timeout 25s curl -I -v --socks5-hostname 127.0.0.1:1080 "$current_url" \
          --http1.1 --tls-max 1.2 2>&1 | grep -E 'Failed|error|SSL|timeout|HTTP/[12]\.[01] [45][0-9][0-9]' | tail -n 3 || true)
      log "[SOCKS检测] 失败 (累计:${socks_fail_count}/${max_fail_count}) 错误: ${curl_error:-无详情}"
      if [ "$socks_fail_count" -ge "$max_fail_count" ]; then
        log "[SOCKS监控] 达到失败阈值 (连续失败 $max_fail_count 次)"
        return 1
      fi
    fi

    sleep "$socks_check_interval"
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

# 优雅退出：容器 stop/restart 时清掉子进程
graceful_exit() {
  log "[退出] 收尾：停止 SOCKS 和 OpenVPN"
  stop_socks
  stop_vpn
  exit 0
}
trap graceful_exit SIGTERM SIGINT

log "=== OpenVPN自动维护脚本启动 ==="
log "主配置URL: $PRIMARY_CONFIG_URL"
log "备用配置URL: $BACKUP_CONFIG_URL"
log "检测间隔: $CHECK_INTERVAL 秒"
log "日志轮转阈值: ${LOG_MAX_SIZE_MB} MB"

while ! download_config; do
  sleep "$CONFIG_RETRY_INTERVAL"
done

if start_vpn && start_socks; then
  log "[初始化] 服务启动成功"
else
  log "[初始化] 启动失败"
fi

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
    log "[恢复] 步骤4/6: 下载配置..."
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
