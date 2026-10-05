#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
#  node-tuning.sh — проверка, тюнинг и откат настроек VPN-ноды
#  (сеть, ядро, swap). Меню: 1 проверка · 2 тюнинг · 3 откат.
#
#  Запуск:
#    sudo bash node-tuning.sh              интерактивное меню
#    sudo bash node-tuning.sh check        проверка + вердикт
#    sudo bash node-tuning.sh tune [-y]    тюнинг (-y: без подтверждения)
#    sudo bash node-tuning.sh rollback [-y] откат к состоянию до тюнинга
#
#  Что делает:
#    • замеряет скорость скачивания (Cloudflare, 50 МБ);
#    • сверяет sysctl (BBR, буферы, conntrack, очереди, MTU-probing…)
#      с целевыми значениями, подобранными под объём RAM;
#    • проверяет swap: нет — создаёт, мало — увеличивает (размер адаптивный);
#    • перед тюнингом сохраняет полный снимок в /var/backups/node-tuning/,
#      откуда возвращает всё одной командой.
# ─────────────────────────────────────────────────────────────────────
set -u

VERSION=1.0
CONF=/etc/sysctl.d/99-cyphra-tuning.conf
MODCONF=/etc/modules-load.d/99-cyphra-tuning.conf
SWAPFILE=/swap.cyphra
BK_ROOT=/var/backups/node-tuning
SPEED_URL='https://speed.cloudflare.com/__down?bytes=50000000'
ASSUME_YES=0
BK=""

# ── оформление ───────────────────────────────────────────────────────
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'
  B=$'\033[1m';  D=$'\033[2m';  N=$'\033[0m'
else
  G=; Y=; R=; C=; B=; D=; N=
fi
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$R" "$N" "$*"; }
sub()  { printf '    %s%s%s\n' "$D" "$*" "$N"; }
step() { printf '\n%s%s▸ %s%s\n' "$B" "$C" "$*" "$N"; }
line() { printf '%s\n' "${C}──────────────────────────────────────────────────────${N}"; }
banner() {
  printf '\n'; line
  printf '  %s%sNODE TUNING%s  %s%s v%s%s\n' "$B" "$C" "$N" "$D" "$1" "$VERSION" "$N"
  line
}

# ── ввод пользователя (работает и при запуске через pipe) ────────────
ANS=""
ask() {
  ANS=""
  printf '%s' "$1" >&2
  read -r ANS </dev/tty 2>/dev/null || ANS=""
}
confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  ask "$1 [y/N] "
  case "$ANS" in y|Y|yes|YES|д|Д|да|Да) return 0 ;; esac
  return 1
}

norm() { printf '%s' "$1" | awk '{$1=$1; print}'; }

# ── окружение ────────────────────────────────────────────────────────
detect_env() {
  RAM_MB=$(awk '/^MemTotal:/{print int(($2+512)/1024)}' /proc/meminfo)
  VIRT=$(systemd-detect-virt 2>/dev/null); [ -n "$VIRT" ] || VIRT=unknown
  IFACE=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
  KERNEL=$(uname -r)
}

virt_blocked() {
  case "$VIRT" in openvz|lxc|lxc-libvirt|docker|podman|systemd-nspawn) return 0 ;; esac
  return 1
}

show_env() {
  step "Сервер"
  sub "RAM: ${RAM_MB} МБ · ядро: ${KERNEL} · виртуализация: ${VIRT} · интерфейс: ${IFACE:-?}"
  if virt_blocked; then
    bad "контейнерная виртуализация (${VIRT}): ядро общее с хостом, sysctl и swap менять нельзя"
    sub "нужен KVM/VDS; проверка ниже покажет значения, но тюнинг будет заблокирован"
  fi
}

# Модули, без которых нужных ключей нет в системе. nf_conntrack НЕ грузим
# принудительно: если он не нужен ноде, навязывать его незачем.
load_modules() {
  modprobe tcp_bbr 2>/dev/null || true
  modprobe sch_fq  2>/dev/null || true
}

# ── целевые значения (зависят от объёма RAM) ─────────────────────────
# формат строки: ключ|режим|цель
#   eq   — должно совпадать       ge — не меньше       le — не больше
#   last — у тройки tcp_rmem/wmem сравнивается максимум (3-е число)
build_spec() {
  local buf ct
  if   [ "$RAM_MB" -le 512 ];  then buf=4194304
  elif [ "$RAM_MB" -le 1024 ]; then buf=8388608
  else buf=16777216; fi
  if   [ "$RAM_MB" -le 1024 ]; then ct=65536
  elif [ "$RAM_MB" -le 2048 ]; then ct=131072
  elif [ "$RAM_MB" -le 4096 ]; then ct=262144
  else ct=524288; fi
  cat <<EOF
net.core.default_qdisc|eq|fq
net.ipv4.tcp_congestion_control|eq|bbr
net.ipv4.tcp_rmem|last|4096 131072 $buf
net.ipv4.tcp_wmem|last|4096 65536 $buf
net.core.rmem_max|ge|$buf
net.core.wmem_max|ge|$buf
net.ipv4.tcp_slow_start_after_idle|eq|0
net.ipv4.tcp_no_metrics_save|eq|1
net.ipv4.tcp_mtu_probing|ge|1
net.netfilter.nf_conntrack_max|ge|$ct
net.core.netdev_max_backlog|ge|16384
net.core.somaxconn|ge|8192
net.ipv4.ip_local_port_range|eq|10240 65535
vm.swappiness|le|10
EOF
}

# eval_key КЛЮЧ РЕЖИМ ЦЕЛЬ  →  ST (ok|miss|na), CUR, TARGET
# TARGET — что писать в конфиг: для ge/le не понижаем то, что уже лучше цели.
eval_key() {
  local key=$1 mode=$2 want=$3 raw cl wl
  ST=na; CUR=""; TARGET=$want
  raw=$(sysctl -n "$key" 2>/dev/null) || return 0
  CUR=$(norm "$raw")
  if [ "$key" = net.ipv4.tcp_congestion_control ] && [ "$want" = bbr ]; then
    case " $(norm "$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)") " in
      *" bbr "*) : ;;
      *) ST=na; return 0 ;;
    esac
  fi
  case "$mode" in
    eq)
      if [ "$CUR" = "$want" ]; then ST=ok; else ST=miss; fi ;;
    ge)
      if [ "$CUR" -ge "$want" ] 2>/dev/null; then ST=ok; TARGET=$CUR; else ST=miss; fi ;;
    le)
      if [ "$CUR" -le "$want" ] 2>/dev/null; then ST=ok; TARGET=$CUR; else ST=miss; fi ;;
    last)
      cl=$(awk '{print $3}' <<<"$CUR"); wl=$(awk '{print $3}' <<<"$want")
      if [ "${cl:-0}" -ge "$wl" ] 2>/dev/null; then
        ST=ok; TARGET="$(awk '{print $1" "$2}' <<<"$want") $cl"
      else
        ST=miss
      fi ;;
  esac
  return 0
}

# ── очередь пакетов на боевом интерфейсе ─────────────────────────────
qdisc_live() {
  [ -n "${IFACE:-}" ] && command -v tc >/dev/null 2>&1 || return 0
  tc qdisc show dev "$IFACE" 2>/dev/null | head -1 | awk '{print $2}'
}

# ── swap: адаптивный размер ──────────────────────────────────────────
swap_total_mb()  { awk 'NR>1{s+=$3} END{print int(s/1024)}' /proc/swaps; }
swap_ours_mb()   { awk -v f="$SWAPFILE" 'NR>1 && $1==f{print int($3/1024)}' /proc/swaps; }
swap_ours_used() { awk -v f="$SWAPFILE" 'NR>1 && $1==f{print int($4/1024)}' /proc/swaps; }

# ≤1 ГБ RAM → 2×RAM; ≤4 ГБ → =RAM; ≤16 ГБ → RAM/2 (не меньше 4 ГБ); больше → 4 ГБ
swap_target_mb() {
  local half
  if   [ "$RAM_MB" -le 1024 ]; then echo $((RAM_MB * 2))
  elif [ "$RAM_MB" -le 4096 ]; then echo "$RAM_MB"
  elif [ "$RAM_MB" -le 16384 ]; then
    half=$((RAM_MB / 2)); [ "$half" -lt 4096 ] && half=4096; echo "$half"
  else echo 4096; fi
}

# Считает план: SW_ACTION = none | create | resize | nodisk
plan_swap() {
  local avail cap
  SW_TOTAL=$(swap_total_mb); SW_OURS=$(swap_ours_mb); SW_OURS=${SW_OURS:-0}
  SW_OTHER=$((SW_TOTAL - SW_OURS))
  SW_TARGET=$(swap_target_mb)
  SW_ACTION=none; SW_NEED=0; SW_NOTE=""; SW_OK=0
  # достаточно, если есть не меньше 90% цели
  if [ $((SW_TOTAL * 10)) -ge $((SW_TARGET * 9)) ]; then SW_OK=1; return 0; fi
  SW_NEED=$((SW_TARGET - SW_OTHER))
  avail=$(df -Pm "$(dirname "$SWAPFILE")" 2>/dev/null | awk 'NR==2{print $4}')
  avail=$(( ${avail:-0} + SW_OURS ))      # место нашего же файла можно переиспользовать
  cap=$((avail / 2))                      # не занимаем больше половины свободного диска
  if [ "$SW_NEED" -gt "$cap" ]; then SW_NEED=$cap; SW_NOTE="ограничено свободным местом на диске"; fi
  if [ "$SW_NEED" -lt 256 ]; then SW_ACTION=nodisk; SW_NEED=0; return 0; fi
  if [ "$SW_OURS" -gt 0 ]; then
    if [ "$SW_NEED" -le "$SW_OURS" ]; then SW_ACTION=none; SW_NEED=0; return 0; fi
    SW_ACTION=resize
  else
    SW_ACTION=create
  fi
}

print_swap() {
  local state="выключен"
  [ "$SW_TOTAL" -gt 0 ] && state="${SW_TOTAL} МБ"
  sub "RAM ${RAM_MB} МБ · swap сейчас: ${state} · рекомендуется: ${SW_TARGET} МБ"
  case "$SW_ACTION" in
    create) warn "swap $( [ "$SW_TOTAL" -gt 0 ] && echo 'мал' || echo 'отключён' ): будет создан $SWAPFILE на ${SW_NEED} МБ ${SW_NOTE:+($SW_NOTE)}" ;;
    resize) warn "swap мал: файл $SWAPFILE будет увеличен ${SW_OURS} → ${SW_NEED} МБ ${SW_NOTE:+($SW_NOTE)}" ;;
    nodisk) bad  "swap нужен, но на диске нет места (нужно ≥ 512 МБ свободных)" ;;
    *)
      if [ "$SW_OK" = 1 ]; then ok "swap достаточен"
      else warn "swap меньше рекомендуемого, но увеличить нечем ${SW_NOTE:+($SW_NOTE)}"; fi ;;
  esac
}

# Создаёт/пересоздаёт наш swap-файл нужного размера и включает его.
build_swapfile() {
  local mb=$1 fs used avail
  fs=$(df -PT "$(dirname "$SWAPFILE")" 2>/dev/null | awk 'NR==2{print $2}')
  if [ -n "$(swap_ours_mb)" ]; then
    used=$(swap_ours_used); used=${used:-0}
    avail=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)
    if [ $((used + 128)) -ge "${avail:-0}" ]; then
      bad "нельзя отключить $SWAPFILE: в нём ${used} МБ данных, а свободной RAM ${avail} МБ"
      return 1
    fi
    swapoff "$SWAPFILE" || return 1
  fi
  rm -f "$SWAPFILE"
  : > "$SWAPFILE" && chmod 600 "$SWAPFILE" || return 1
  [ "$fs" = btrfs ] && chattr +C "$SWAPFILE" 2>/dev/null
  if ! { fallocate -l "${mb}M" "$SWAPFILE" 2>/dev/null \
         && mkswap "$SWAPFILE" >/dev/null 2>&1 \
         && swapon "$SWAPFILE" 2>/dev/null; }; then
    # fallocate на некоторых ФС даёт файл с «дырами» — пишем честно через dd
    swapoff "$SWAPFILE" 2>/dev/null
    rm -f "$SWAPFILE"; : > "$SWAPFILE"; chmod 600 "$SWAPFILE"
    [ "$fs" = btrfs ] && chattr +C "$SWAPFILE" 2>/dev/null
    dd if=/dev/zero of="$SWAPFILE" bs=1M count="$mb" 2>/dev/null || return 1
    mkswap "$SWAPFILE" >/dev/null 2>&1 || return 1
    swapon "$SWAPFILE" 2>/dev/null || return 1
  fi
  grep -qs "^$SWAPFILE[[:space:]]" /etc/fstab || \
    printf '%s none swap sw 0 0\n' "$SWAPFILE" >> /etc/fstab
  return 0
}

# ── анализ: заполняет SPEC_*, план swap и очереди ────────────────────
analyse() {
  local key mode want
  SPEC_KEY=(); SPEC_CUR=(); SPEC_TGT=(); SPEC_ST=()
  N_OK=0; N_MISS=0; N_NA=0
  while IFS='|' read -r key mode want; do
    eval_key "$key" "$mode" "$want"
    SPEC_KEY+=("$key"); SPEC_CUR+=("$CUR"); SPEC_TGT+=("$TARGET"); SPEC_ST+=("$ST")
    case "$ST" in ok) N_OK=$((N_OK+1)) ;; miss) N_MISS=$((N_MISS+1)) ;; *) N_NA=$((N_NA+1)) ;; esac
  done < <(build_spec)
  plan_swap
  QL=$(qdisc_live); QD_BAD=0
  case "$QL" in fq|mq|"") : ;; *) QD_BAD=1 ;; esac
}

print_table() {
  local i mark
  for i in "${!SPEC_KEY[@]}"; do
    case "${SPEC_ST[$i]}" in
      ok)   mark="${G}✓${N}"; printf '  %s %-36s %-22s\n' "$mark" "${SPEC_KEY[$i]}" "${SPEC_CUR[$i]}" ;;
      miss) mark="${Y}!${N}"; printf '  %s %-36s %-22s → %s\n' "$mark" "${SPEC_KEY[$i]}" "${SPEC_CUR[$i]}" "${SPEC_TGT[$i]}" ;;
      *)    mark="${D}–${N}"; printf '  %s %s%-36s не поддерживается ядром/не загружен%s\n' "$mark" "$D" "${SPEC_KEY[$i]}" "$N" ;;
    esac
  done
  if [ -n "$QL" ]; then
    if [ "$QD_BAD" = 1 ]; then warn "очередь на ${IFACE}: ${QL} (нужна fq)"
    else ok "очередь на ${IFACE}: ${QL}"; fi
  fi
}

# ── скорость ─────────────────────────────────────────────────────────
SPEED_BPS=0
speed_test() {
  local out
  SPEED_BPS=0
  if ! command -v curl >/dev/null 2>&1; then warn "curl не найден — замер пропущен"; return 1; fi
  sub "качаю 50 МБ с speed.cloudflare.com…"
  out=$(curl -s -o /dev/null --max-time 45 -w '%{speed_download}' "$SPEED_URL" 2>/dev/null)
  SPEED_BPS=${out%%[.,]*}
  case "$SPEED_BPS" in ''|*[!0-9]*) SPEED_BPS=0 ;; esac
  if [ "$SPEED_BPS" -gt 0 ]; then
    printf '  скорость: %s Б/с  (%s Мбит/с)\n' "$SPEED_BPS" \
      "$(awk -v b="$SPEED_BPS" 'BEGIN{printf "%.1f", b*8/1000000}')"
  else
    warn "замер не удался (нет доступа к speed.cloudflare.com?)"
    return 1
  fi
}

# ── 1. ПРОВЕРКА ──────────────────────────────────────────────────────
verdict() {
  local i n r recs=()
  for i in "${!SPEC_KEY[@]}"; do
    [ "${SPEC_ST[$i]}" = miss ] && recs+=("${SPEC_KEY[$i]}: ${SPEC_CUR[$i]} → ${SPEC_TGT[$i]}")
  done
  case "$SW_ACTION" in
    create) recs+=("включить swap ${SW_NEED} МБ (файл $SWAPFILE)") ;;
    resize) recs+=("увеличить swap до ${SW_NEED} МБ (файл $SWAPFILE)") ;;
    nodisk) recs+=("освободить место на диске под swap") ;;
  esac
  [ "$QD_BAD" = 1 ] && recs+=("очередь на ${IFACE}: ${QL} → fq")
  n=${#recs[@]}

  step "Вердикт"
  if [ "$n" -eq 0 ]; then
    ok "${B}сервер настроен${N} — тюнинг не требуется"
  else
    if [ "$n" -le 3 ]; then warn "${B}почти готов${N}: нужно поправить $n пункт(а)"
    else bad "${B}нужен тюнинг${N}: расхождений — $n"; fi
    printf '\n  %sРекомендации:%s\n' "$B" "$N"
    for r in "${recs[@]}"; do printf '    • %s\n' "$r"; done
    printf '\n'; sub "всё это сделает пункт 2 меню (с бэкапом и возможностью отката)"
  fi
  if [ "$N_NA" -gt 0 ]; then
    sub "не поддерживается/не загружено: $N_NA парам. (старое ядро или нет bbr/conntrack) — они будут пропущены"
  fi
}

do_check() {
  detect_env
  banner "проверка сервера"
  show_env
  step "Скорость скачивания (до тюнинга)"
  speed_test
  load_modules
  analyse
  step "Текущие настройки"
  print_table
  step "Swap"
  print_swap
  verdict
  printf '\n'
}

# ── 2. ТЮНИНГ ────────────────────────────────────────────────────────
state_set() { printf '%s=%q\n' "$1" "$2" >> "$BK/state.env"; }

make_backup() {
  local key mode want v
  BK="$BK_ROOT/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BK" || return 1
  chmod 700 "$BK_ROOT" "$BK" 2>/dev/null
  : > "$BK/sysctl-live.txt"
  while IFS='|' read -r key mode want; do
    v=$(sysctl -n "$key" 2>/dev/null) || continue
    printf '%s|%s\n' "$key" "$(norm "$v")" >> "$BK/sysctl-live.txt"
  done < <(build_spec)
  [ -f "$CONF" ]    && cp -p "$CONF" "$BK/conf.prev"
  [ -f "$MODCONF" ] && cp -p "$MODCONF" "$BK/modconf.prev"
  cp -p /etc/fstab "$BK/fstab.bak" 2>/dev/null
  cp /proc/swaps "$BK/swaps.txt" 2>/dev/null
  : > "$BK/state.env"
  state_set IFACE "${IFACE:-}"
  state_set QDISC_PREV "${QL:-}"
  state_set QDISC_APPLIED 0
  state_set SWAP_PREV_MB "$SW_OURS"
  state_set SWAP_TOUCHED 0
  return 0
}

apply_swap() {
  case "$SW_ACTION" in
    create|resize)
      sub "готовлю swap ${SW_NEED} МБ в $SWAPFILE (создание файла может занять время)…"
      state_set SWAP_TOUCHED 1
      if build_swapfile "$SW_NEED"; then
        ok "swap включён: теперь $(swap_total_mb) МБ, добавлен в /etc/fstab"
      else
        bad "swap настроить не удалось — остальное применяю без него"
        # если пересоздание сломалось на полпути — пробуем вернуть прежний размер
        if [ "$SW_OURS" -gt 0 ] && [ -z "$(swap_ours_mb)" ]; then build_swapfile "$SW_OURS" || true; fi
      fi ;;
    nodisk) warn "на диске нет места под swap — пропускаю" ;;
    *)      ok "swap достаточен — не трогаю" ;;
  esac
}

write_conf() {
  local tmp i
  tmp=$(mktemp) || return 1
  {
    printf '# node-tuning.sh v%s · %s\n' "$VERSION" "$(date '+%F %T')"
    printf '# откат: sudo bash node-tuning.sh rollback\n'
    for i in "${!SPEC_KEY[@]}"; do
      [ "${SPEC_ST[$i]}" = na ] && continue
      printf '%s = %s\n' "${SPEC_KEY[$i]}" "${SPEC_TGT[$i]}"
    done
  } > "$tmp"
  install -m 644 "$tmp" "$CONF"; rm -f "$tmp"
  # conntrack-ключи живут в модуле: закрепляем его загрузку до чтения sysctl.d
  if grep -q '^net\.netfilter\.' "$CONF"; then
    mkdir -p /etc/modules-load.d
    printf 'nf_conntrack\n' > "$MODCONF"
  fi
}

verify_applied() {
  local i key cur who diffs=0
  for i in "${!SPEC_KEY[@]}"; do
    [ "${SPEC_ST[$i]}" = na ] && continue
    key=${SPEC_KEY[$i]}
    cur=$(norm "$(sysctl -n "$key" 2>/dev/null)")
    if [ "$cur" != "$(norm "${SPEC_TGT[$i]}")" ]; then
      diffs=$((diffs+1))
      warn "не встало: $key = $cur (ожидалось ${SPEC_TGT[$i]})"
      who=$(grep -lsE "^[[:space:]]*${key//./\\.}[[:space:]]*=" \
            /etc/sysctl.conf /etc/sysctl.d/*.conf /run/sysctl.d/*.conf 2>/dev/null | grep -vF "$CONF" | tr '\n' ' ')
      [ -n "$who" ] && sub "тот же ключ задан в: $who"
    fi
  done
  if [ "$diffs" = 0 ]; then ok "все значения встали как задумано"
  else sub "побеждает файл, который читается позже по алфавиту"; fi
}

do_tune() {
  local i miss_list="" before=0 after=0
  detect_env
  banner "тюнинг сервера"
  show_env
  if virt_blocked; then bad "тюнинг на ${VIRT} невозможен"; return 1; fi

  step "Шаг 1/5 · Скорость до тюнинга"
  speed_test; before=$SPEED_BPS

  step "Шаг 2/5 · Анализ — чего не хватает"
  load_modules; analyse
  print_table
  print_swap
  if [ "$N_MISS" -eq 0 ] && [ "$QD_BAD" = 0 ] && { [ "$SW_ACTION" = none ] || [ "$SW_ACTION" = nodisk ]; }; then
    ok "всё уже на месте — менять нечего"
    return 0
  fi
  if ! confirm "Применить изменения? Перед этим будет сделан бэкап."; then
    warn "отменено, ничего не изменено"; return 0
  fi

  step "Шаг 3/5 · Бэкап"
  if make_backup; then
    ok "снимок сохранён: $BK"
    sub "вернуть всё: sudo bash $0 rollback"
  else
    bad "не удалось создать бэкап — тюнинг прерван (ничего не изменено)"; return 1
  fi

  step "Шаг 4/5 · Применяю"
  apply_swap
  write_conf && ok "записан $CONF"
  local out
  out=$(sysctl -p "$CONF" 2>&1 >/dev/null)
  if [ -n "$out" ]; then warn "sysctl ругнулся:"; printf '%s\n' "$out" | while IFS= read -r l; do sub "$l"; done
  else ok "sysctl применён, настройки переживут перезагрузку"; fi
  if [ "$QD_BAD" = 1 ] && [ -n "${IFACE:-}" ]; then
    if tc qdisc replace dev "$IFACE" root fq 2>/dev/null; then
      ok "очередь на ${IFACE}: ${QL} → fq"; state_set QDISC_APPLIED 1
    else
      warn "очередь на ${IFACE} сейчас не сменилась — встанет fq после перезагрузки"
    fi
  fi
  verify_applied

  step "Шаг 5/5 · Скорость после тюнинга"
  speed_test; after=$SPEED_BPS
  if [ "$before" -gt 0 ] && [ "$after" -gt 0 ]; then
    printf '  %sдо:%s %s Мбит/с   %sпосле:%s %s Мбит/с   (%s%%)\n' "$D" "$N" \
      "$(awk -v b="$before" 'BEGIN{printf "%.1f", b*8/1000000}')" "$D" "$N" \
      "$(awk -v b="$after" 'BEGIN{printf "%.1f", b*8/1000000}')" \
      "$(awk -v a="$after" -v b="$before" 'BEGIN{printf "%+.0f", (a-b)*100/b}')"
    sub "один замер шумит; BBR и буферы заметнее на дальних клиентах и длинных загрузках"
  fi
  printf '\n'; line
  ok "готово. Откат: sudo bash $0 rollback"
  printf '\n'
}

# ── 3. ОТКАТ ─────────────────────────────────────────────────────────
do_rollback() {
  local list=() d n i k v choice
  banner "откат к состоянию до тюнинга"
  while IFS= read -r d; do list+=("$d"); done < <(
    find "$BK_ROOT" -maxdepth 1 -mindepth 1 -type d -name '2*' ! -name '*.restored' 2>/dev/null | sort -r)
  n=${#list[@]}
  if [ "$n" -eq 0 ]; then bad "бэкапов нет в $BK_ROOT — откатывать нечего"; return 1; fi

  step "Доступные снимки (новые сверху)"
  for i in "${!list[@]}"; do printf '    %s) %s\n' "$((i+1))" "$(basename "${list[$i]}")"; done
  choice=1
  if [ "$ASSUME_YES" != 1 ] && [ "$n" -gt 1 ]; then
    ask "Какой восстановить? [1] "; [ -n "$ANS" ] && choice=$ANS
  fi
  case "$choice" in ''|*[!0-9]*) bad "нужен номер из списка"; return 1 ;; esac
  if [ "$choice" -lt 1 ] || [ "$choice" -gt "$n" ]; then bad "нет такого снимка"; return 1; fi
  d=${list[$((choice-1))]}
  [ -f "$d/state.env" ] || { bad "снимок повреждён: нет state.env"; return 1; }
  if ! confirm "Восстановить состояние из $(basename "$d")?"; then warn "отменено"; return 0; fi

  # shellcheck disable=SC1090,SC1091
  . "$d/state.env"
  IFACE=${IFACE:-}; SWAP_PREV_MB=${SWAP_PREV_MB:-0}; SWAP_TOUCHED=${SWAP_TOUCHED:-0}
  QDISC_APPLIED=${QDISC_APPLIED:-0}; QDISC_PREV=${QDISC_PREV:-}

  step "Конфиги"
  if [ -f "$d/conf.prev" ]; then cp -p "$d/conf.prev" "$CONF" && ok "восстановлен прежний $CONF"
  else rm -f "$CONF" && ok "удалён $CONF (до тюнинга его не было)"; fi
  if [ -f "$d/modconf.prev" ]; then cp -p "$d/modconf.prev" "$MODCONF"
  else rm -f "$MODCONF"; fi

  step "Swap"
  if [ "$SWAP_TOUCHED" = 1 ]; then
    RAM_MB=$(awk '/^MemTotal:/{print int(($2+512)/1024)}' /proc/meminfo)
    if [ "$SWAP_PREV_MB" -gt 0 ]; then
      if build_swapfile "$SWAP_PREV_MB"; then ok "размер $SWAPFILE возвращён: ${SWAP_PREV_MB} МБ"
      else bad "не удалось вернуть размер swap-файла"; fi
    else
      swapoff "$SWAPFILE" 2>/dev/null
      if [ -n "$(swap_ours_mb)" ]; then bad "не удалось отключить $SWAPFILE (используется) — удали вручную после освобождения RAM"
      else
        rm -f "$SWAPFILE"
        sed -i "\|^$SWAPFILE[[:space:]]|d" /etc/fstab
        ok "swap-файл $SWAPFILE отключён и удалён, строка fstab убрана"
      fi
    fi
  else
    ok "swap тюнингом не менялся"
  fi

  step "Значения ядра (живые)"
  while IFS='|' read -r k v; do
    [ -n "$k" ] || continue
    if sysctl -w "$k=$v" >/dev/null 2>&1; then ok "$k = $v"
    else warn "не удалось вернуть $k"; fi
  done < "$d/sysctl-live.txt"

  step "Очередь пакетов"
  if [ "$QDISC_APPLIED" = 1 ] && [ -n "$IFACE" ] && [ -n "$QDISC_PREV" ]; then
    case "$QDISC_PREV" in
      noqueue) tc qdisc del dev "$IFACE" root 2>/dev/null && ok "${IFACE}: очередь возвращена (noqueue)" ;;
      mq)      sub "mq восстанавливается сам после перезагрузки" ;;
      *)       tc qdisc replace dev "$IFACE" root "$QDISC_PREV" 2>/dev/null \
                 && ok "${IFACE}: очередь возвращена (${QDISC_PREV})" \
                 || warn "очередь на ${IFACE} вернётся после перезагрузки" ;;
    esac
  else
    ok "очередь тюнингом не менялась"
  fi

  mv "$d" "$d.restored" 2>/dev/null
  printf '\n'; line
  ok "откат выполнен. Снимок помечен как использованный: $(basename "$d").restored"
  printf '\n'
}

# ── меню и точка входа ───────────────────────────────────────────────
usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

main_menu() {
  while true; do
    banner "настройка VPN-ноды"
    printf '   %s1%s  Проверка сервера     %s(вердикт и рекомендации)%s\n' "$B" "$N" "$D" "$N"
    printf '   %s2%s  Тюнинг сервера       %s(бэкап → применение)%s\n' "$B" "$N" "$D" "$N"
    printf '   %s3%s  Откат                %s(к состоянию до тюнинга)%s\n' "$B" "$N" "$D" "$N"
    printf '   %s0%s  Выход\n\n' "$B" "$N"
    ask "Выбор: "
    case "$ANS" in
      1) do_check ;;
      2) do_tune ;;
      3) do_rollback ;;
      0|q|Q|"") exit 0 ;;
      *) warn "нет такого пункта" ;;
    esac
    ask "Enter — вернуться в меню… "
  done
}

CMD=""
for a in "$@"; do
  case "$a" in
    check|tune|rollback) CMD=$a ;;
    -y|--yes)            ASSUME_YES=1 ;;
    -h|--help)           usage; exit 0 ;;
    *) bad "не понял аргумент: $a"; usage; exit 2 ;;
  esac
done

if [ "$(id -u)" != 0 ]; then
  bad "нужен root: sudo bash $0 ${CMD}"; exit 1
fi

case "$CMD" in
  check)    do_check ;;
  tune)     do_tune ;;
  rollback) do_rollback ;;
  *)        main_menu ;;
esac
