#!/bin/sh
CONF="/etc/qwairah_tg.conf"
STATE_DIR="/tmp/qwairah_mon"
[ -f "$CONF" ] && . "$CONF"
[ -z "$BOT_TOKEN" ] || [ -z "$CHAT_ID" ] && exit 0
mkdir -p "$STATE_DIR"

MODE="${1:-boot}"
DETAIL="${2:-}"
RAW_NODE="${NODE_NAME:-$(uci -q get system.@system[0].hostname || echo قويره)}"
MODEM_NAME=$(printf '%s' "$RAW_NODE" | sed 's/QWAIRAH/قويره/g')
MODEL="$(cat /tmp/sysinfo/model 2>/dev/null || echo 'DAVOLINK DV01-901H')"
MODEM_IP="$(ip -4 addr show br-lan 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1)"
[ -z "$MODEM_IP" ] && MODEM_IP="$(uci -q get network.lan.ipaddr || echo '192.168.1.1')"
DHCP_STATE=$([ "$(uci -q get dhcp.lan.ignore)" = "1" ] && echo "معطل (OFF)" || echo "شغال (ON)")

UP_SEC=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)
if [ "$UP_SEC" -ge 3600 ]; then
  UPTIME_STR="$((UP_SEC / 3600)) ساعة و $(((UP_SEC % 3600) / 60)) دقيقة"
elif [ "$UP_SEC" -ge 60 ]; then
  UPTIME_STR="$((UP_SEC / 60)) دقيقة و $((UP_SEC % 60)) ثانية"
else
  UPTIME_STR="${UP_SEC} ثانية"
fi

get_ping() {
  ping -c 3 -W 2 1.1.1.3 2>/dev/null | awk -F/ '/round-trip|rtt/ {print $5}' | sed 's/[^0-9.]//g' | head -n1
}

get_speed() {
  P2=$(ping -s 1200 -c 4 -W 2 1.1.1.3 2>/dev/null | awk -F/ '/round-trip|rtt/ {print $5}' | sed 's/[^0-9.]//g' | head -n1)
  if [ -n "$P2" ]; then
    awk -v ms="$P2" 'BEGIN {
      if (ms <= 0) ms = 50;
      est = (1200 * 8) / (ms * 1000);
      if (est < 1.0) est = 1.0;
      if (est > 100.0) est = 100.0;
      printf "%.2f ميجابت/ث", est;
    }'
    return 0
  fi
  echo "0.00 ميجابت/ث"
}

get_net_cards() {
  CARDS=""
  for d in /sys/class/net/*; do
    [ -e "$d" ] || continue
    iface=$(basename "$d")
    [ "$iface" = "lo" ] && continue
    st=$(cat "$d/operstate" 2>/dev/null || echo "unknown")
    case "$iface" in
      wlan*|ra*|apcli*|ath*) ic="📶"; role="واي فاي" ;;
      br-*) ic="🌉"; role="جسر شبكة" ;;
      eth*|lan*|wan*) ic="🔌"; role="منفذ شبكة" ;;
      *) ic="🖧"; role="واجهة" ;;
    esac
    item="${ic} ${iface} (${role}: ${st})"
    [ -z "$CARDS" ] && CARDS="$item" || CARDS="${CARDS}، ${item}"
  done
  [ -z "$CARDS" ] && CARDS="⚠️ غير متاح"
  printf '%s' "$CARDS"
}

describe_cable() {
  st="$1"; spd="$2"
  if [ "$st" = "up" ] && [ -n "$spd" ] && [ "$spd" -gt 0 ] 2>/dev/null; then
    if [ "$spd" -ge 1000 ]; then printf 'كابل 1 جيجابت/ث (%s Mbps - سليم)' "$spd"
    elif [ "$spd" -ge 100 ]; then printf 'كابل 100 ميجابت/ث (%s Mbps - تحقق من الكابل)' "$spd"
    else printf 'كابل 10 ميجابت/ث (%s Mbps - تحذير عطل/كابل ضعيف)' "$spd"; fi
  elif [ "$st" = "up" ]; then printf 'مرتبط (سرعة غير محددة - احتمال عطل)'
  else printf 'غير مرتبط / مفصول'; fi
}

get_ports_info() {
  OUT=""; FOUND_LINK=0
  for p in lan1 lan2 lan3 lan4 eth0 eth1 wan br-lan; do
    [ -d "/sys/class/net/$p" ] || continue
    st=$(cat "/sys/class/net/$p/operstate" 2>/dev/null || echo "down")
    spd=$(cat "/sys/class/net/$p/speed" 2>/dev/null || echo "")
    cdesc=$(describe_cable "$st" "$spd")
    [ "$st" = "up" ] && FOUND_LINK=1 && line="🟢 منفذ ${p}: مرتبط | ${cdesc}" || line="🔴 منفذ ${p}: غير مرتبط / مفصول | ${cdesc}"
    [ -z "$OUT" ] && OUT="$line" || OUT="${OUT}\n${line}"
  done
  [ -z "$OUT" ] && OUT="⚠️ لا توجد منافذ سلكية معرفة"
  [ "$FOUND_LINK" -eq 1 ] && OUT="${OUT}\n🔗 حالة الارتباط بالمنافذ: يوجد ارتباط نشط" || OUT="${OUT}\n🔌 حالة الارتباط بالمنافذ: لا يوجد أجهزة مرتبطة بالمنافذ"
  printf '%b' "$OUT"
}

lookup_host_by_mac() {
  TMAC=$(printf '%s' "$1" | tr 'A-F' 'a-f')
  HNAME=""
  [ -f /tmp/dhcp.leases ] && HNAME=$(awk -v m="$TMAC" 'tolower($2)==m && $4!="*" && $4!="" {print $4; exit}' /tmp/dhcp.leases 2>/dev/null)
  [ -z "$HNAME" ] && HNAME="غير معروف"
  printf '%s' "$HNAME"
}

lookup_ip_by_mac() {
  TMAC=$(printf '%s' "$1" | tr 'A-F' 'a-f')
  TIP=""
  [ -f /proc/net/arp ] && TIP=$(awk -v m="$TMAC" 'tolower($4)==m {print $1; exit}' /proc/net/arp 2>/dev/null)
  [ -z "$TIP" ] && TIP="غير محدد"
  printf '%s' "$TIP"
}

get_wifi_clients() {
  if command -v iw >/dev/null 2>&1; then
    for w in $(iw dev 2>/dev/null | awk '$1=="Interface"{print $2}'); do
      iw dev "$w" station dump 2>/dev/null | awk -v iface="$w" '
        /^Station / { mac=tolower($2); sig=""; rx=""; tx=""; }
        /signal:/ { if ($3 == "dBm") sig=$2 " dBm"; else if ($4 == "dBm") sig=$3 " dBm"; else sig=$2; }
        /rx bitrate:/ { rx=$3 " " $4; }
        /tx bitrate:/ { tx=$3 " " $4; }
        /^$/ || (mac!="" && /tx bitrate:/) {
          if (mac!="" && (sig!="" || rx!="" || tx!="")) {
            printf "%s|%s|%s|%s|%s\n", iface, mac, sig, rx, tx;
            mac=""; sig=""; rx=""; tx="";
          }
        }
      ' | sort -u | while IFS='|' read -r w_if w_mac w_sig w_rx w_tx; do
        [ -z "$w_mac" ] && continue
        h_name=$(lookup_host_by_mac "$w_mac")
        ip_addr=$(lookup_ip_by_mac "$w_mac")
        printf '👤 الاسم: %s | 📶 الكرت: %s | 🔖 الماك: %s | 🌐 الآيبي: %s | 📡 الإشارة: %s | ⬇️ الاستقبال: %s | ⬆️ الإرسال: %s\n' \
          "$h_name" "$w_if" "$w_mac" "$ip_addr" "${w_sig:-غير متاح}" "${w_rx:-غير متاح}" "${w_tx:-غير متاح}"
      done
    done
  fi
}

url_enc() {
  LC_ALL=C hexdump -v -e '/1 "%02X\n"' | awk '
    BEGIN {
      for (i = 0; i < 16; i++) h[sprintf("%X", i)] = i
      for (c = 32; c < 127; c++) ch[c] = sprintf("%c", c)
    }
    /^[0-9A-Fa-f]{2}$/ {
      u = toupper($0)
      b = h[substr(u, 1, 1)] * 16 + h[substr(u, 2, 1)]
      if ((b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 45 || b == 46 || b == 95 || b == 126) printf "%s", ch[b]
      else if (b == 32) printf "+"
      else printf "%%%s", u
    }
  '
}

send_msg() {
  TXT="$1"; TOUT="${2:-15}"
  if command -v curl >/dev/null 2>&1; then
    curl -sSk --max-time "$TOUT" -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${CHAT_ID}" \
      --data-urlencode "text=${TXT}"
    return $?
  fi
  ENC=$(printf '%s' "$TXT" | url_enc)
  URL="https://api.telegram.org/bot${BOT_TOKEN}/sendMessage?chat_id=${CHAT_ID}&text=${ENC}"
  if command -v uclient-fetch >/dev/null 2>&1; then
    uclient-fetch --no-check-certificate -T "$TOUT" -q -O - "$URL" 2>&1
    return $?
  elif command -v wget >/dev/null 2>&1; then
    wget --no-check-certificate -T "$TOUT" -qO - "$URL" 2>&1
    return $?
  fi
  return 1
}

build_full_report() {
  HEAD_TITLE="$1"; P_VAL="$2"; S_VAL="$3"
  NET_CARDS=$(get_net_cards); PORTS_BLK=$(get_ports_info); WIFI_BLK=$(get_wifi_clients)
  [ -z "$WIFI_BLK" ] && WIFI_BLK="🚫 لا يوجد مستخدمون مرتبطون على كروت الواي فاي حالياً"
  printf '%s\n📡 الموديل: %s (%s)\n🌐 الآيبي: %s | DHCP: %s\n📶 البينج (1.1.1.3): %s مللي ثانية\n⚡ سرعة الانترنت: %s\n⏱️ مدة التشغيل: %s\n\n🧩 كروت الشبكة:\n%s\n\n🔌 المنافذ وحالة الارتباط:\n%s\n\n👥 المستخدمون المرتبطون بالواي فاي:\n%s' \
    "$HEAD_TITLE" "$MODEL" "$MODEM_NAME" "$MODEM_IP" "$DHCP_STATE" "$P_VAL" "$S_VAL" "$UPTIME_STR" "$NET_CARDS" "$PORTS_BLK" "$WIFI_BLK"
}

case "$MODE" in
  shutdown)
    MSG=$(printf '🔴 تنبيه إطفاء / إعادة تشغيل — شبكة قـويــره نت\n📡 الموديل: %s (%s)\n🌐 الآيبي: %s | DHCP: %s' "$MODEL" "$MODEM_NAME" "$MODEM_IP" "$DHCP_STATE")
    send_msg "$MSG" 6
    ;;
  net_down)
    MSG=$(printf '🔴 تنبيه مودم مقطوع / شبكة قـويــره نت\n📡 الموديل: %s (%s)\n🌐 الآيبي: %s | DHCP: %s\n⚠️ السبب: %s\n⏱️ مدة التشغيل: %s' "$MODEL" "$MODEM_NAME" "$MODEM_IP" "$DHCP_STATE" "${DETAIL:-فحص بنج الانترنت 1.1.1.3}" "$UPTIME_STR")
    send_msg "$MSG" 8
    ;;
  event)
    MSG=$(printf '🔔 تنبيه ارتباط/تحديث — شبكة قـويــره نت\n📡 الموديل: %s (%s)\n🌐 الآيبي: %s | DHCP: %s\n📋 التفاصيل: %s' "$MODEL" "$MODEM_NAME" "$MODEM_IP" "$DHCP_STATE" "${DETAIL:-تحديث}")
    send_msg "$MSG" 10
    ;;
  test)
    P_AVG=$(get_ping); SPD=$(get_speed)
    MSG=$(build_full_report "🟢 تقرير تشغيل وحالة المودم — شبكة قـويــره نت" "${P_AVG:-انتهت المهلة}" "$SPD")
    send_msg "$MSG" 15
    ;;
  *)
    i=0; P_AVG=""
    while [ $i -lt 20 ]; do
      P_AVG=$(get_ping); [ -n "$P_AVG" ] && break
      sleep 3; i=$((i + 1))
    done
    if [ -n "$P_AVG" ]; then
      SPD=$(get_speed); echo "up" > "$STATE_DIR/net_state"
      HEAD="🟢 تقرير تشغيل العقدة — شبكة قـويــره نت"
      [ "$MODE" = "recovered" ] && HEAD="🟢 عودة واستقرار الإنترنت — شبكة قـويــره نت"
      MSG=$(build_full_report "$HEAD" "$P_AVG" "$SPD")
      send_msg "$MSG" 15
    else
      echo "down" > "$STATE_DIR/net_state"
      MSG=$(printf '🔴 تنبيه مودم مقطوع / شبكة قـويــره نت\n📡 الموديل: %s (%s)\n🌐 الآيبي: %s | DHCP: %s\n⚠️ الحالة: انقطع الانترنت عنه\n⏱️ مدة التشغيل: %s' "$MODEL" "$MODEM_NAME" "$MODEM_IP" "$DHCP_STATE" "$UPTIME_STR")
      send_msg "$MSG" 10
    fi
    ;;
esac
