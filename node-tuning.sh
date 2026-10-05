#!/usr/bin/env bash
# ═════════════════════════════════════════════════════════════════════════
#   node-tuning · проверка, тюнинг и откат настроек сетевой ноды
# ═════════════════════════════════════════════════════════════════════════
#
#   Что это
#   ───────
#   Скрипт приводит сервер к рабочему виду для ноды: проверяет сеть, ядро,
#   swap, Docker и диск, показывает вердикт с рекомендациями, а по вашему
#   согласию применяет исправления. Перед любым изменением делается снимок,
#   поэтому всё можно вернуть одной командой.
#
#   Запуск
#   ──────
#     sudo bash node-tuning.sh                 меню: 1 проверка · 2 тюнинг · 3 откат
#     sudo bash node-tuning.sh about           краткая справка «что делает скрипт»
#     sudo bash node-tuning.sh check           только проверка, ничего не меняет
#     sudo bash node-tuning.sh tune [-y]       тюнинг (-y — без вопросов)
#     sudo bash node-tuning.sh rollback [-y]   откат к состоянию до тюнинга
#
# ─────────────────────────────────────────────────────────────────────────
#   1 · ЧТО СКРИПТ ПРОВЕРЯЕТ
# ─────────────────────────────────────────────────────────────────────────
#
#   1.1  Окружение
#          • объём RAM — от него зависят буферы, таблица соединений и swap;
#          • версию ядра, тип виртуализации, основной сетевой интерфейс;
#          • на контейнерной виртуализации (OpenVZ, LXC и т. п.) ядро общее
#            с хостом — тюнинг там невозможен, скрипт сразу об этом скажет.
#
#   1.2  Скорость скачивания
#          • замер через curl: 50 МБ с публичного speed-теста;
#          • делается до и после тюнинга, чтобы увидеть разницу.
#
#   1.3  Сеть и ядро (sysctl) — 14 параметров
#          Параметр                           Цель           Зачем
#          ────────────────────────────────── ────────────── ─────────────────────────────
#          net.core.default_qdisc             fq             ровная отправка пакетов для BBR
#          net.ipv4.tcp_congestion_control    bbr            скорость на каналах с потерями
#          net.ipv4.tcp_rmem                  макс 4–16 МБ   буфер приёма TCP, дальний клиент
#          net.ipv4.tcp_wmem                  макс 4–16 МБ   буфер отправки TCP
#          net.core.rmem_max                  4–16 МБ        потолок буферов (в т. ч. UDP)
#          net.core.wmem_max                  4–16 МБ        потолок буферов (в т. ч. UDP)
#          net.ipv4.tcp_slow_start_after_idle 0              не сбрасывать скорость после паузы
#          net.ipv4.tcp_no_metrics_save       1              не копить «плохие» метрики
#          net.ipv4.tcp_mtu_probing           1              подбор MTU (мобильные сети, CDN)
#          net.netfilter.nf_conntrack_max     64–512 тыс.    таблица соединений, не переполнять
#          net.core.netdev_max_backlog        16384          очередь от сетевой карты
#          net.core.somaxconn                 8192           очередь ожидающих accept()
#          net.ipv4.ip_local_port_range       10240–65535    исходящие порты
#          vm.swappiness                      10             swap — только страховка
#          Значения подбираются по объёму RAM. Если сейчас уже лучше цели —
#          не понижаются. Чего нет в ядре (нет bbr, не загружен conntrack) —
#          пропускается без ошибок.
#
#   1.4  Очередь пакетов на живом интерфейсе
#          • tc qdisc show: нужна fq (mq допустима — внутри неё уже fq);
#          • sysctl действует только на новые интерфейсы, поэтому на
#            работающем очередь меняется отдельной командой tc.
#
#   1.5  Swap
#          • включён ли и хватает ли его для вашего объёма RAM:
#              RAM до 1 ГБ    →  2 × RAM
#              RAM до 4 ГБ    →  размер RAM
#              RAM до 16 ГБ   →  RAM / 2, но не меньше 4 ГБ
#              RAM больше     →  4 ГБ
#          • нет swap — создаётся файл; меньше 90% цели — увеличивается;
#          • чужие swap-разделы и файлы не трогаются, недостающее добирает
#            наш файл; он занимает не больше половины свободного диска.
#
#   1.6  Docker (если установлен)
#          • LimitNOFILE / LimitNPROC демона ≥ 1048576: каждое соединение —
#            открытый файл, на дефолтной тысяче нода отказывает клиентам;
#          • ulimit -n внутри контейнера ноды ≥ 65536;
#          • daemon.json: ограничены ли логи контейнеров (max-size, max-file);
#          • у самого контейнера применён ли лимит логов — Docker запоминает
#            его при создании контейнера, новый daemon.json сам не приедет.
#
#   1.7  Диск
#          • журнал systemd: SystemMaxUse ≤ 200M и его фактический размер;
#          • /var/log/btmp (журнал неудачных входов SSH): от 10 МБ — раздут;
#          • заполнение корня: от 85% — предупреждение и подсказки, где искать.
#
# ─────────────────────────────────────────────────────────────────────────
#   2 · ЧТО ДЕЛАЕТ ТЮНИНГ (пункт 2 меню)
# ─────────────────────────────────────────────────────────────────────────
#
#   Шаг 1  Замер скорости до тюнинга.
#   Шаг 2  Анализ: что не хватает → план → подтверждение (кроме -y).
#   Шаг 3  Бэкап: живые значения sysctl, прежние конфиги, fstab, состояние
#          swap — в /var/backups/node-tuning/<дата>/.
#   Шаг 4  Система: swap → sysctl-файл с комментариями к каждому ключу →
#          применение → fq на живом интерфейсе → сверка значений.
#   Шаг 5  Docker и диск: лимиты Docker, лимит логов в daemon.json (чужие
#          настройки сохраняются), потолок журнала + его очистка, обнуление
#          btmp, ОДИН перезапуск Docker, пересоздание контейнера — только
#          если лимит логов к нему так и не применился.
#   Шаг 6  Проверка: ulimit и лог-настройки в контейнере, состояние ноды,
#          диск, повторный замер скорости и сравнение «до / после».
#
# ─────────────────────────────────────────────────────────────────────────
#   3 · ОТКАТ (пункт 3 меню)
# ─────────────────────────────────────────────────────────────────────────
#
#   Возвращает из выбранного снимка: sysctl-конфиги и живые значения ядра,
#   swap (удаляет созданный файл или возвращает прежний размер), строку
#   в fstab, очередь на интерфейсе, лимиты Docker, daemon.json и настройки
#   журнала. Использованный снимок помечается «.restored», поэтому
#   следующий откат уйдёт к более раннему.
#
# ─────────────────────────────────────────────────────────────────────────
#   4 · ВАЖНО ЗНАТЬ
# ─────────────────────────────────────────────────────────────────────────
#
#   • Docker перезапускается один раз за весь тюнинг — клиенты отвалятся
#     секунд на 10, при пересоздании контейнера ещё раз. Запускайте в
#     тихое окно.
#   • Не откатываются по природе: очистка журнала, обнуление btmp и
#     пересоздание контейнера (он сохранит лимит логов). Скрипт предупредит
#     об этом до применения.
#   • Без root скрипт не работает: настройки ядра пишет только он.
#
#   Переменные окружения:
#     NODE_CONTAINER=имя   контейнер ноды (имя по умолчанию задано ниже)
#     NO_COLOR=1           отключить цвета и анимацию
# ═════════════════════════════════════════════════════════════════════════

set -u

VERSION=2.0

# ── пути и константы ─────────────────────────────────────────────────
# Все пути можно переопределить переменными окружения (удобно для тестов).
CONF=${CONF:-/etc/sysctl.d/99-cyphra-tuning.conf}          # наши sysctl-настройки
MODCONF=${MODCONF:-/etc/modules-load.d/99-cyphra-tuning.conf} # автозагрузка модулей
SWAPFILE=${SWAPFILE:-/swap.cyphra}                           # наш swap-файл
FSTAB=${FSTAB:-/etc/fstab}
PROC_SWAPS=${PROC_SWAPS:-/proc/swaps}
LIMCONF=${LIMCONF:-/etc/systemd/system/docker.service.d/limits.conf} # лимиты Docker
DAEMON_JSON=${DAEMON_JSON:-/etc/docker/daemon.json}          # настройки демона Docker
JOURNALD_CONF=${JOURNALD_CONF:-/etc/systemd/journald.conf}   # настройки журнала
BTMP=${BTMP:-/var/log/btmp}                                  # журнал неудачных входов SSH
BK_ROOT=${BK_ROOT:-/var/backups/node-tuning}                 # где лежат снимки
NODE_CT=${NODE_CONTAINER:-remnanode}                         # контейнер ноды
JOURNAL_MAX_MB=200                                           # потолок журнала systemd
SPEED_URL='https://speed.cloudflare.com/__down?bytes=50000000'
ASSUME_YES=0
BK=""

# ═════════════════════════════════════════════════════════════════════
#  ОФОРМЛЕНИЕ: цвета, спиннер, логотип
# ═════════════════════════════════════════════════════════════════════

# Цвет выбираем один раз по «лесенке»: truecolor → 256 → 8 цветов → без цвета.
# Так не остаётся «раскрашенного» терминала в логах, пайпах и старом ssh.
LVL=off
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  case "${COLORTERM:-}" in
    truecolor|24bit) LVL=rgb ;;
    *) _nc=$(tput colors 2>/dev/null || echo 0)
       if   [ "${_nc:-0}" -ge 256 ]; then LVL=256
       elif [ "${_nc:-0}" -ge 8 ];   then LVL=8; fi ;;
  esac
fi

# fg R G B КОД256 КОД8 — escape-последовательность цвета для текущей ступеньки
fg() {
  case "$LVL" in
    rgb) printf '\033[38;2;%s;%s;%sm' "$1" "$2" "$3" ;;
    256) printf '\033[38;5;%sm' "$4" ;;
    8)   printf '\033[%sm' "$5" ;;
  esac
}
G=$(fg 90 215 130 77 32)     # зелёный — «в порядке»
Y=$(fg 240 190 80 179 33)    # жёлтый  — «внимание»
R=$(fg 240 95 95 167 31)     # красный — «ошибка»
C=$(fg 80 200 255 81 36)     # голубой — акцент интерфейса
if [ "$LVL" = off ]; then B=; D=; N=
else B=$'\033[1m'; D=$'\033[2m'; N=$'\033[0m'; fi

ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$R" "$N" "$*"; }
sub()  { printf '    %s%s%s\n' "$D" "$*" "$N"; }
step() { printf '\n%s%s▸ %s%s\n' "$B" "$C" "$*" "$N"; }
line() { printf '%s──────────────────────────────────────────────────────%s\n' "$C" "$N"; }

# stepn N ВСЕГО ТЕКСТ — заголовок шага с мини-прогрессбаром ▰▰▱▱▱
stepn() {
  local n=$1 t=$2 bar="" i; shift 2
  for ((i=1; i<=t; i++)); do
    if [ "$i" -le "$n" ]; then bar+="▰"; else bar+="▱"; fi
  done
  printf '\n%s%s▸ %s %s/%s · %s%s\n' "$B" "$C" "$bar" "$n" "$t" "$*" "$N"
}

# Компактная шапка раздела (большой логотип показывается один раз — intro)
banner() {
  printf '\n'; line
  printf '  %s%sNODE TUNING%s  %s%s · v%s%s\n' "$B" "$C" "$N" "$D" "$1" "$VERSION" "$N"
  line
}

# Курсор прячем на время анимации и обязательно возвращаем при любом выходе.
trap 'printf "\033[?25h"' EXIT
trap 'printf "\033[?25h\n"; exit 130' INT TERM

# typewrite ТЕКСТ — вывод «печатной машинкой» (в логе/пайпе — обычной строкой)
typewrite() {
  local s=$1 i
  if [ "$LVL" != off ]; then
    for ((i=0; i<${#s}; i++)); do printf '%s' "${s:i:1}"; sleep 0.012 2>/dev/null; done
    printf '\n'
  else
    printf '%s\n' "$s"
  fi
}

# Логотип в два тона: «net» — голубой, «503» — янтарный.
# Буквы набраны косым шрифтом и перекрываются по вертикали, поэтому границу
# между «net» и «503» задаём для каждой строки отдельно: это номер колонки,
# с которой начинается «503».
LOGO_SPLIT=(34 34 34 34 33 33 33 33 33 33 33 34 34 33 33)
show_logo() {
  local i=0 row left right cl cr delay=0 s
  case "$LVL" in
    rgb) cl=$(fg 80 200 255 0 0);  cr=$(fg 255 165 60 0 0) ;;
    256) cl=$(fg 0 0 0 45 0);      cr=$(fg 0 0 0 214 0) ;;
    8)   cl=$(fg 0 0 0 0 36);      cr=$(fg 0 0 0 0 33) ;;
    *)   cl="";                    cr="" ;;
  esac
  [ "$LVL" != off ] && delay=0.045
  while IFS= read -r row; do
    s=${LOGO_SPLIT[$i]}
    left=${row:0:$s}; right=${row:$s}
    printf '%s%s%s%s%s\n' "$cl" "$left" "$cr" "$right" "$N"
    [ "$delay" != 0 ] && sleep "$delay" 2>/dev/null   # построчное «проявление»
    i=$((i+1))
  done <<'LOGO'
                                        ,----,.                             
                                      ,'   ,' |               .--,-``-.     
                          ___       ,'   .'   |    ,----..   /   /     '.   
                        ,--.'|_   ,----.'    .'   /   /   \ / ../        ;  
      ,---,             |  | :,'  |    |   .'    /   .     :\ ``\  .`-    ' 
  ,-+-. /  |            :  : ' :  :    :  |--,  .   /   ;.  \\___\/   \   : 
 ,--.'|'   |   ,---.  .;__,'  /   :    |  ;.' \.   ;   /  ` ;     \   :   | 
|   |  ,"' |  /     \ |  |   |    |    |      |;   |  ; \ ; |     /  /   /  
|   | /  | | /    /  |:__,'| :    `----'.'\   ;|   :  | ; | '     \  \   \  
|   | |  | |.    ' / |  '  : |__    __  \  .  |.   |  ' ' ' : ___ /   :   | 
|   | |  |/ '   ;   /|  |  | '.'| /   /\/  /  :'   ;  \; /  |/   /\   /   : 
|   | |--'  '   |  / |  ;  :    ;/ ,,/  ',-   . \   \  ',  // ,,/  ',-    . 
|   |/      |   :    |  |  ,   / \ ''\       ;   ;   :    / \ ''\        ;  
'---'        \   \  /    ---`-'   \   \    .'     \   \ .'   \   \     .'   
              `----'               `--`-,-'        `---`      `--`-,,-'     
LOGO
}

intro() {
  show_logo
  printf '\n  '
  typewrite "node-tuning v${VERSION} · проверка → тюнинг → откат"
}

# spin "ТЕКСТ" команда [арги…] — запускает команду в фоне и крутит спиннер.
# Вывод команды складывается в SPIN_OUT, код возврата — в SPIN_RC.
# ВАЖНО: фон — это подоболочка, поэтому функция под спиннером не может
# менять переменные скрипта (только файловую систему и свой вывод).
SPIN_OUT=""; SPIN_RC=0
spin() {
  local msg=$1 log pid i=0 frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'; shift
  log=$(mktemp)
  "$@" >"$log" 2>&1 &
  pid=$!
  if [ "$LVL" != off ]; then
    printf '\033[?25l'
    while kill -0 "$pid" 2>/dev/null; do
      printf '\r  %s%s%s %s' "$C" "${frames:$((i % 10)):1}" "$N" "$msg"
      i=$((i+1)); sleep 0.1
    done
    printf '\r\033[K\033[?25h'
  else
    sub "$msg"
  fi
  wait "$pid"; SPIN_RC=$?
  SPIN_OUT=$(cat "$log"); rm -f "$log"
  return "$SPIN_RC"
}

# ── ввод пользователя (работает и при запуске через pipe: читаем из tty) ──
ANS=""
ask() { ANS=""; printf '%s' "$1" >&2; read -r ANS </dev/tty 2>/dev/null || ANS=""; }
confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  ask "$1 [y/N] "
  case "$ANS" in y|Y|yes|YES|д|Д|да|Да) return 0 ;; esac
  return 1
}

# norm — схлопывает пробелы/табы (sysctl отдаёт тройки через табуляцию)
norm() { printf '%s' "$1" | awk '{$1=$1; print}'; }

# ═════════════════════════════════════════════════════════════════════
#  ОКРУЖЕНИЕ
# ═════════════════════════════════════════════════════════════════════
detect_env() {
  RAM_MB=$(awk '/^MemTotal:/{print int(($2+512)/1024)}' /proc/meminfo)
  VIRT=$(systemd-detect-virt 2>/dev/null); [ -n "$VIRT" ] || VIRT=unknown
  IFACE=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
  KERNEL=$(uname -r)
}

# На контейнерной виртуализации ядро общее с хостом: sysctl и swap там
# менять нельзя, поэтому тюнинг блокируем сразу и честно.
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
  modprobe tcp_bbr 2>/dev/null || true   # алгоритм BBR
  modprobe sch_fq  2>/dev/null || true   # очередь fq (нужна BBR для pacing)
}

# ═════════════════════════════════════════════════════════════════════
#  SYSCTL: что должно быть и зачем
# ═════════════════════════════════════════════════════════════════════
# Формат строки: ключ|режим|цель
#   eq   — значение должно совпадать
#   ge   — не меньше цели (если уже больше — не понижаем)
#   le   — не больше цели
#   last — у троек tcp_rmem/wmem сравнивается максимум (3-е число)
# Буферы и таблица соединений подбираются под объём RAM: на слабой
# машине огромные буферы только съедят память.
build_spec() {
  local buf ct
  if   [ "$RAM_MB" -le 512 ];  then buf=4194304      #  4 МБ
  elif [ "$RAM_MB" -le 1024 ]; then buf=8388608      #  8 МБ
  else buf=16777216; fi                              # 16 МБ
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

# Человеческое описание: за что отвечает каждая настройка.
# Показывается в проверке и пишется комментариями в сам конфиг.
key_desc() {
  case "$1" in
    net.core.default_qdisc)
      echo "очередь пакетов для новых интерфейсов; fq нужна BBR, чтобы отправлять пакеты ровно, а не пачками" ;;
    net.ipv4.tcp_congestion_control)
      echo "алгоритм борьбы с перегрузкой; BBR держит скорость на каналах с потерями и большим пингом, где cubic проседает" ;;
    net.ipv4.tcp_rmem)
      echo "буфер приёма TCP (мин / старт / макс); большой максимум нужен, чтобы заполнить канал до дальнего клиента" ;;
    net.ipv4.tcp_wmem)
      echo "буфер отправки TCP (мин / старт / макс); то же самое для исходящего потока" ;;
    net.core.rmem_max)
      echo "потолок буфера приёма любого сокета, в том числе UDP (Hysteria2, QUIC, WireGuard)" ;;
    net.core.wmem_max)
      echo "потолок буфера отправки любого сокета, в том числе UDP" ;;
    net.ipv4.tcp_slow_start_after_idle)
      echo "0 — не сбрасывать скорость соединения после паузы; иначе долгоживущий туннель после простоя разгоняется заново" ;;
    net.ipv4.tcp_no_metrics_save)
      echo "1 — не запоминать метрики прошлых соединений; одна плохая сессия не занижает скорость следующих" ;;
    net.ipv4.tcp_mtu_probing)
      echo "1 — подбирать размер пакета, если он не проходит (мобильные сети, CDN, туннели); лечит «подключилось, но не грузит»" ;;
    net.netfilter.nf_conntrack_max)
      echo "размер таблицы отслеживания соединений; при переполнении пакеты молча теряются (table full)" ;;
    net.core.netdev_max_backlog)
      echo "очередь пакетов от сетевой карты до обработки ядром; защищает от потерь при всплесках трафика" ;;
    net.core.somaxconn)
      echo "очередь соединений, ждущих accept(); при подключениях пачками иначе клиенты получают отказ" ;;
    net.ipv4.ip_local_port_range)
      echo "диапазон исходящих портов; шире диапазон — больше одновременных соединений наружу к одному адресу" ;;
    vm.swappiness)
      echo "10 — swap только как страховка от нехватки RAM, а не место, куда вытесняются рабочие данные" ;;
    *) echo "" ;;
  esac
}

# eval_key КЛЮЧ РЕЖИМ ЦЕЛЬ  →  ST (ok|miss|na), CUR (сейчас), TARGET (что писать в конфиг).
# na — ядро не знает ключ (или у него нет нужного значения, как bbr).
eval_key() {
  local key=$1 mode=$2 want=$3 raw cl wl
  ST=na; CUR=""; TARGET=$want
  raw=$(sysctl -n "$key" 2>/dev/null) || return 0
  CUR=$(norm "$raw")
  # Ключ tcp_congestion_control есть у любого ядра, а bbr — не у любого:
  # без этой проверки строка с bbr молча ломала бы применение всего файла.
  if [ "$key" = net.ipv4.tcp_congestion_control ] && [ "$want" = bbr ]; then
    case " $(norm "$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)") " in
      *" bbr "*) : ;;
      *) ST=na; return 0 ;;
    esac
  fi
  case "$mode" in
    eq)
      if [ "$CUR" = "$want" ]; then ST=ok; else ST=miss; fi ;;
    ge)  # не понижаем то, что уже лучше цели
      if [ "$CUR" -ge "$want" ] 2>/dev/null; then ST=ok; TARGET=$CUR; else ST=miss; fi ;;
    le)
      if [ "$CUR" -le "$want" ] 2>/dev/null; then ST=ok; TARGET=$CUR; else ST=miss; fi ;;
    last)  # тройка «мин дефолт макс»: сравниваем только макс
      cl=$(awk '{print $3}' <<<"$CUR"); wl=$(awk '{print $3}' <<<"$want")
      if [ "${cl:-0}" -ge "$wl" ] 2>/dev/null; then
        ST=ok; TARGET="$(awk '{print $1" "$2}' <<<"$want") $cl"
      else
        ST=miss
      fi ;;
  esac
  return 0
}

# Очередь на боевом интерфейсе. default_qdisc из sysctl действует лишь на
# интерфейсы, поднятые ПОСЛЕ него, поэтому живую очередь смотрим отдельно.
qdisc_live() {
  [ -n "${IFACE:-}" ] && command -v tc >/dev/null 2>&1 || return 0
  tc qdisc show dev "$IFACE" 2>/dev/null | head -1 | awk '{print $2}'
}

# ═════════════════════════════════════════════════════════════════════
#  SWAP: адаптивный размер
# ═════════════════════════════════════════════════════════════════════
swap_total_mb()  { awk 'NR>1{s+=$3} END{print int(s/1024)}' "$PROC_SWAPS"; }
swap_ours_mb()   { awk -v f="$SWAPFILE" 'NR>1 && $1==f{print int($3/1024)}' "$PROC_SWAPS"; }
swap_ours_used() { awk -v f="$SWAPFILE" 'NR>1 && $1==f{print int($4/1024)}' "$PROC_SWAPS"; }

# Целевой размер:  ≤1 ГБ RAM → 2×RAM · ≤4 ГБ → =RAM ·
#                  ≤16 ГБ → RAM/2 (не меньше 4 ГБ) · больше → 4 ГБ
swap_target_mb() {
  local half
  if   [ "$RAM_MB" -le 1024 ]; then echo $((RAM_MB * 2))
  elif [ "$RAM_MB" -le 4096 ]; then echo "$RAM_MB"
  elif [ "$RAM_MB" -le 16384 ]; then
    half=$((RAM_MB / 2)); [ "$half" -lt 4096 ] && half=4096; echo "$half"
  else echo 4096; fi
}

# Строит план. SW_ACTION: none | create | resize | nodisk.
# Чужие swap-разделы и файлы не трогаем: недостающее добираем СВОИМ файлом.
plan_swap() {
  local avail cap
  SW_TOTAL=$(swap_total_mb); SW_OURS=$(swap_ours_mb); SW_OURS=${SW_OURS:-0}
  SW_OTHER=$((SW_TOTAL - SW_OURS))
  SW_TARGET=$(swap_target_mb)
  SW_ACTION=none; SW_NEED=0; SW_NOTE=""; SW_OK=0
  # Достаточно, если уже есть ≥90% цели — ради 10% файл не перекраиваем.
  if [ $((SW_TOTAL * 10)) -ge $((SW_TARGET * 9)) ]; then SW_OK=1; return 0; fi
  SW_NEED=$((SW_TARGET - SW_OTHER))
  avail=$(df -Pm "$(dirname "$SWAPFILE")" 2>/dev/null | awk 'NR==2{print $4}')
  avail=$(( ${avail:-0} + SW_OURS ))   # место нашего же файла можно переиспользовать
  cap=$((avail / 2))                   # не отъедаем больше половины свободного диска
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
  [ "$SW_ACTION" = create ] || [ "$SW_ACTION" = resize ] && \
    sub "зачем: swap — страховка от OOM-killer, который иначе убьёт ноду при всплеске памяти"
}

# Создаёт или пересоздаёт наш swap-файл нужного размера и включает его.
build_swapfile() {
  local mb=$1 fs used avail
  fs=$(df -PT "$(dirname "$SWAPFILE")" 2>/dev/null | awk 'NR==2{print $2}')
  # Если файл уже подключён — сперва отключаем, но только если данные из
  # него поместятся в свободную RAM (иначе swapoff повесит машину).
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
  : > "$SWAPFILE" && chmod 600 "$SWAPFILE" || return 1   # swap читаем только root
  [ "$fs" = btrfs ] && chattr +C "$SWAPFILE" 2>/dev/null  # на btrfs swap-файл без CoW
  if ! { fallocate -l "${mb}M" "$SWAPFILE" 2>/dev/null \
         && mkswap "$SWAPFILE" >/dev/null 2>&1 \
         && swapon "$SWAPFILE" 2>/dev/null; }; then
    # fallocate на некоторых ФС даёт файл с «дырами», который ядро не примет —
    # тогда пишем нулями честно через dd (дольше, зато работает везде).
    swapoff "$SWAPFILE" 2>/dev/null
    rm -f "$SWAPFILE"; : > "$SWAPFILE"; chmod 600 "$SWAPFILE"
    [ "$fs" = btrfs ] && chattr +C "$SWAPFILE" 2>/dev/null
    dd if=/dev/zero of="$SWAPFILE" bs=1M count="$mb" 2>/dev/null || return 1
    mkswap "$SWAPFILE" >/dev/null 2>&1 || return 1
    swapon "$SWAPFILE" 2>/dev/null || return 1
  fi
  # Запись в fstab — чтобы swap включался после перезагрузки.
  grep -qs "^$SWAPFILE[[:space:]]" "$FSTAB" || \
    printf '%s none swap sw 0 0\n' "$SWAPFILE" >> "$FSTAB"
  return 0
}

# ═════════════════════════════════════════════════════════════════════
#  DOCKER И ДИСК: лимиты файлов, логи, журнал
# ═════════════════════════════════════════════════════════════════════
docker_present() {
  command -v docker >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1 \
    && systemctl cat docker.service >/dev/null 2>&1
}

# Эффективный лимит юнита docker.service (то, что реально получит демон).
unit_limit() { systemctl show docker -p "$1" 2>/dev/null | cut -d= -f2; }
# Лимит достаточный: infinity или не меньше 1048576.
limit_ok() {
  case "$1" in infinity) return 0 ;; ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -ge 1048576 ]
}

ct_exists()  { docker inspect "$NODE_CT" >/dev/null 2>&1; }
ct_running() { [ "$(docker inspect -f '{{.State.Running}}' "$NODE_CT" 2>/dev/null)" = true ]; }
ct_ulimit()  { docker exec "$NODE_CT" sh -c 'ulimit -n' 2>/dev/null; }
# Docker запоминает настройки логов В МОМЕНТ СОЗДАНИЯ контейнера и держит до
# конца его жизни — новый daemon.json на работающую ноду сам не приедет.
ct_logcfg_ok() {
  docker inspect "$NODE_CT" --format '{{.HostConfig.LogConfig.Config}}' 2>/dev/null | grep -q 'max-size'
}
wait_ct() {  # wait_ct СЕК — ждём, пока контейнер поднимется
  local i
  for ((i=0; i<$1; i++)); do ct_running && return 0; sleep 1; done
  return 1
}

# Каталог compose-проекта берём из метки самого контейнера; если нет — /opt/remnanode.
compose_dir() {
  local d
  d=$(docker inspect "$NODE_CT" --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' 2>/dev/null)
  [ -n "$d" ] && [ -d "$d" ] || d=/opt/remnanode
  local f
  for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    [ -f "$d/$f" ] && { printf '%s' "$d"; return 0; }
  done
  return 1
}
compose_up() {
  cd "$1" || return 1
  if docker compose version >/dev/null 2>&1; then docker compose up -d --force-recreate
  else docker-compose up -d --force-recreate; fi
}

# daemon.json уже ограничивает логи? (driver local ротирует сам; json-file — при max-size+max-file)
daemon_log_ok() {
  [ -f "$DAEMON_JSON" ] || return 1
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$DAEMON_JSON" 2>/dev/null <<'PY'
import json, sys
try:
    c = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
o = c.get('log-opts') or {}
drv = c.get('log-driver', 'json-file')
sys.exit(0 if drv == 'local' or (drv == 'json-file' and o.get('max-size') and o.get('max-file')) else 1)
PY
  else
    grep -q '"max-size"' "$DAEMON_JSON" && grep -q '"max-file"' "$DAEMON_JSON"
  fi
}

# Пишет лимиты логов в daemon.json, НЕ затирая чужие настройки (зеркала,
# data-root и т.п.): если файл есть — аккуратно сливаем JSON.
write_daemon_json() {
  mkdir -p "$(dirname "$DAEMON_JSON")"
  if [ ! -s "$DAEMON_JSON" ]; then
    cat > "$DAEMON_JSON" <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "3" }
}
EOF
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$DAEMON_JSON" <<'PY'
import json, sys
p = sys.argv[1]
with open(p) as fh:
    c = json.load(fh)
c['log-driver'] = 'json-file'
o = c.get('log-opts') or {}
o['max-size'] = '50m'     # один файл лога — не больше 50 МБ
o['max-file'] = '3'       # хранить 3 файла (итого ≤150 МБ на контейнер)
c['log-opts'] = o
with open(p, 'w') as fh:
    json.dump(c, fh, indent=2)
    fh.write('\n')
PY
    return $?
  fi
  if command -v jq >/dev/null 2>&1; then
    jq '. + {"log-driver":"json-file"} | .["log-opts"] = ((.["log-opts"] // {}) + {"max-size":"50m","max-file":"3"})' \
      "$DAEMON_JSON" > "$DAEMON_JSON.tmp" && mv "$DAEMON_JSON.tmp" "$DAEMON_JSON"
    return $?
  fi
  return 1   # нечем безопасно слить JSON — лучше не трогать, чем сломать
}

# SystemMaxUse из журнала (последнее значение из основного конфига и drop-in'ов).
jrn_cfg_value() {
  grep -rhsE '^[[:space:]]*SystemMaxUse=' "$JOURNALD_CONF" "$(dirname "$JOURNALD_CONF")/journald.conf.d" 2>/dev/null \
    | tail -1 | cut -d= -f2 | tr -d ' '
}
# size_mb "200M" → 200 (G/M/K/байты); -1 если не разобрали
size_mb() {
  case "$1" in ''|*[!0-9GgMmKk]*) echo -1; return ;; esac
  case "$1" in
    *[Gg]) echo $(( ${1%[Gg]} * 1024 )) ;;
    *[Mm]) echo "${1%[Mm]}" ;;
    *[Kk]) echo $(( ${1%[Kk]} / 1024 )) ;;
    *)     echo $(( $1 / 1048576 )) ;;
  esac
}
jrn_size_mb() { du -sm /var/log/journal /run/log/journal 2>/dev/null | awk '{s+=$1} END{print s+0}'; }

# ═════════════════════════════════════════════════════════════════════
#  АНАЛИЗ: собирает состояние системы, ничего не меняя
# ═════════════════════════════════════════════════════════════════════
analyse() {
  local key mode want mb
  # ── sysctl ──
  SPEC_KEY=(); SPEC_CUR=(); SPEC_TGT=(); SPEC_ST=()
  N_OK=0; N_MISS=0; N_NA=0
  while IFS='|' read -r key mode want; do
    eval_key "$key" "$mode" "$want"
    SPEC_KEY+=("$key"); SPEC_CUR+=("$CUR"); SPEC_TGT+=("$TARGET"); SPEC_ST+=("$ST")
    case "$ST" in ok) N_OK=$((N_OK+1)) ;; miss) N_MISS=$((N_MISS+1)) ;; *) N_NA=$((N_NA+1)) ;; esac
  done < <(build_spec)
  # ── swap и очередь ──
  plan_swap
  QL=$(qdisc_live); QD_BAD=0
  case "$QL" in fq|mq|"") : ;; *) QD_BAD=1 ;; esac   # mq — корень с fq внутри, его не трогаем
  # ── Docker ──
  DK_PRESENT=0; LIM_NOFILE=""; LIM_NPROC=""; LIM_BAD=0; DLOG_BAD=0
  CT_STATE=none; CT_ULIMIT=""; CT_LOG_BAD=0; DK_RESTART=0; CT_RECREATE=0
  if docker_present; then
    DK_PRESENT=1
    LIM_NOFILE=$(unit_limit LimitNOFILE); LIM_NPROC=$(unit_limit LimitNPROC)
    { limit_ok "$LIM_NOFILE" && limit_ok "$LIM_NPROC"; } || LIM_BAD=1
    daemon_log_ok || DLOG_BAD=1
    if ct_exists; then
      if ct_running; then CT_STATE=running; CT_ULIMIT=$(ct_ulimit); else CT_STATE=stopped; fi
      ct_logcfg_ok || CT_LOG_BAD=1
    fi
    { [ "$LIM_BAD" = 1 ] || [ "$DLOG_BAD" = 1 ]; } && DK_RESTART=1
    { [ "$CT_STATE" != none ] && [ "$CT_LOG_BAD" = 1 ]; } && CT_RECREATE=1
  fi
  # ── журнал systemd, btmp, диск ──
  JRN_PRESENT=0; command -v journalctl >/dev/null 2>&1 && JRN_PRESENT=1
  JRN_CFG=$(jrn_cfg_value); mb=$(size_mb "$JRN_CFG")
  JRN_BAD=0; JRN_VAC=0; JRN_SIZE=$(jrn_size_mb)
  if [ "$JRN_PRESENT" = 1 ]; then
    { [ "$mb" -ge 0 ] && [ "$mb" -le "$JOURNAL_MAX_MB" ]; } || JRN_BAD=1
    [ "$JRN_SIZE" -gt "$JOURNAL_MAX_MB" ] && JRN_VAC=1
  fi
  BTMP_MB=$(( $(stat -c %s "$BTMP" 2>/dev/null || echo 0) / 1048576 )); BTMP_BAD=0
  [ "$BTMP_MB" -ge 10 ] && BTMP_BAD=1
  DISK_PCT=$(df -P / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}'); DISK_PCT=${DISK_PCT:-0}
  # ── сколько всего нужно поменять ──
  N_TODO=$((N_MISS + QD_BAD + LIM_BAD + DLOG_BAD + CT_RECREATE + JRN_BAD + JRN_VAC + BTMP_BAD))
  case "$SW_ACTION" in create|resize) N_TODO=$((N_TODO+1)) ;; esac
}

# ═════════════════════════════════════════════════════════════════════
#  ВЫВОД РЕЗУЛЬТАТОВ АНАЛИЗА
# ═════════════════════════════════════════════════════════════════════
print_table() {
  local i d
  for i in "${!SPEC_KEY[@]}"; do
    case "${SPEC_ST[$i]}" in
      ok)   printf '  %s✓%s %-36s %-22s\n' "$G" "$N" "${SPEC_KEY[$i]}" "${SPEC_CUR[$i]}" ;;
      miss) printf '  %s!%s %-36s %-22s → %s\n' "$Y" "$N" "${SPEC_KEY[$i]}" "${SPEC_CUR[$i]}" "${SPEC_TGT[$i]}"
            d=$(key_desc "${SPEC_KEY[$i]}"); [ -n "$d" ] && sub "$d" ;;
      *)    printf '  %s–%s %s%-36s не поддерживается ядром / не загружен%s\n' "$D" "$N" "$D" "${SPEC_KEY[$i]}" "$N" ;;
    esac
  done
  if [ -n "$QL" ]; then
    if [ "$QD_BAD" = 1 ]; then
      warn "очередь на ${IFACE}: ${QL} (нужна fq)"
      sub "sysctl задаёт очередь только вновь поднятым интерфейсам — на живом её меняем командой tc"
    else ok "очередь на ${IFACE}: ${QL}"; fi
  fi
}

print_docker_disk() {
  local u
  step "Docker: лимиты файлов и логи"
  if [ "$DK_PRESENT" = 0 ]; then
    sub "Docker не найден — пропускаю"
  else
    if [ "$LIM_BAD" = 1 ]; then
      warn "лимиты Docker: NOFILE=${LIM_NOFILE:-?} NPROC=${LIM_NPROC:-?} (нужно 1048576)"
      sub "каждое соединение — открытый файл; дефолтной тысячи хватает на сотню клиентов, потом Xray отказывает, оставаясь «живым»"
    else ok "лимиты Docker: NOFILE=${LIM_NOFILE} NPROC=${LIM_NPROC}"; fi
    case "$CT_STATE" in
      running)
        u=${CT_ULIMIT:-?}
        case "$u" in ''|*[!0-9]*) ok "ulimit -n внутри $NODE_CT: $u" ;;
          *) if [ "$u" -ge 65536 ]; then ok "ulimit -n внутри $NODE_CT: $u"
             else warn "ulimit -n внутри $NODE_CT: $u — мало"
                  sub "после тюнинга скрипт пересоздаст контейнер; если не поможет — задай ulimits в docker-compose.yml"; fi ;;
        esac ;;
      stopped) warn "контейнер $NODE_CT остановлен — лимиты внутри проверить нельзя" ;;
      none)    sub "контейнер $NODE_CT не найден (другое имя? NODE_CONTAINER=имя) — проверка внутри пропущена" ;;
    esac
    if [ "$DLOG_BAD" = 1 ]; then
      warn "daemon.json: логи контейнеров не ограничены"
      sub "json-file без лимита растёт бесконечно — именно он чаще всего забивает диск ноды"
    else ok "daemon.json: логи контейнеров ограничены"; fi
    if [ "$CT_STATE" != none ]; then
      if [ "$CT_LOG_BAD" = 1 ]; then
        warn "у контейнера $NODE_CT лимит логов не применён"
        sub "Docker запоминает настройки логов при создании контейнера — нужно пересоздание (клиенты отвалятся ~10 с)"
      else ok "у контейнера $NODE_CT лимит логов применён"; fi
    fi
  fi
  step "Диск: журнал, btmp, заполнение"
  if [ "$JRN_PRESENT" = 1 ]; then
    if [ "$JRN_BAD" = 1 ]; then
      warn "журнал systemd: SystemMaxUse=${JRN_CFG:-не задан}, занимает ${JRN_SIZE} МБ (нужно ≤ ${JOURNAL_MAX_MB}M)"
      sub "без лимита журнал разрастается до гигабайта; лимит режет его раз и навсегда"
    elif [ "$JRN_VAC" = 1 ]; then
      warn "журнал systemd занимает ${JRN_SIZE} МБ при лимите ${JRN_CFG} — будет очищен до ${JOURNAL_MAX_MB}M"
    else ok "журнал systemd: ${JRN_SIZE} МБ, лимит ${JRN_CFG}"; fi
  fi
  if [ "$BTMP_BAD" = 1 ]; then
    warn "$BTMP занимает ${BTMP_MB} МБ"
    sub "журнал неудачных входов SSH; на открытом порту растёт сам по себе — обнуляем"
  else ok "$BTMP: ${BTMP_MB} МБ"; fi
  if [ "$DISK_PCT" -ge 85 ]; then
    warn "диск / занят на ${DISK_PCT}% — журнал и логи Docker не единственные виновники"
    sub "ищи дальше: docker images (старые образы), du -xh / --max-depth=2 | sort -h | tail"
  else ok "диск / занят на ${DISK_PCT}%"; fi
}

# ═════════════════════════════════════════════════════════════════════
#  СКОРОСТЬ
# ═════════════════════════════════════════════════════════════════════
SPEED_BPS=0
_curl_speed() { curl -s -o /dev/null --max-time 45 -w '%{speed_download}' "$SPEED_URL"; }
speed_test() {
  local out
  SPEED_BPS=0
  if ! command -v curl >/dev/null 2>&1; then warn "curl не найден — замер пропущен"; return 1; fi
  spin "качаю 50 МБ с speed.cloudflare.com…" _curl_speed
  out=$SPIN_OUT
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

# ═════════════════════════════════════════════════════════════════════
#  1. ПРОВЕРКА
# ═════════════════════════════════════════════════════════════════════
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
  [ "$QD_BAD" = 1 ]      && recs+=("очередь на ${IFACE}: ${QL} → fq")
  [ "$LIM_BAD" = 1 ]     && recs+=("поднять LimitNOFILE/LimitNPROC Docker до 1048576 (перезапуск Docker)")
  [ "$DLOG_BAD" = 1 ]    && recs+=("ограничить логи контейнеров в daemon.json (50m × 3)")
  [ "$CT_RECREATE" = 1 ] && recs+=("пересоздать контейнер $NODE_CT, чтобы лимит логов применился")
  [ "$JRN_BAD" = 1 ]     && recs+=("ограничить журнал systemd до ${JOURNAL_MAX_MB}M")
  { [ "$JRN_BAD" = 0 ] && [ "$JRN_VAC" = 1 ]; } && recs+=("очистить журнал systemd (${JRN_SIZE} МБ → ${JOURNAL_MAX_MB}M)")
  [ "$BTMP_BAD" = 1 ]    && recs+=("обнулить $BTMP (${BTMP_MB} МБ)")
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
    if [ "$DK_RESTART" = 1 ] || [ "$CT_RECREATE" = 1 ]; then
      sub "учти: перезапуск Docker и пересоздание контейнера отключат клиентов на ~10 с — делай это в тихое окно"
    fi
  fi
  [ "$N_NA" -gt 0 ] && \
    sub "не поддерживается/не загружено: $N_NA парам. (старое ядро или нет bbr/conntrack) — будут пропущены"
}

do_check() {
  detect_env
  banner "проверка сервера"
  show_env
  step "Скорость скачивания (до тюнинга)"
  speed_test
  load_modules
  analyse
  step "Сеть и ядро"
  print_table
  step "Swap"
  print_swap
  print_docker_disk
  verdict
  printf '\n'
}

# ═════════════════════════════════════════════════════════════════════
#  2. ТЮНИНГ
# ═════════════════════════════════════════════════════════════════════
# state.env — «паспорт» снимка: что именно мы меняли, чтобы откат знал,
# что возвращать. Дописываем строками; при чтении побеждает последняя.
state_set() { printf '%s=%q\n' "$1" "$2" >> "$BK/state.env"; }

# Снимок: живые значения sysctl, прежние файлы конфигов, fstab, состояние swap.
make_backup() {
  local key mode want v f
  BK="$BK_ROOT/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BK" || return 1
  chmod 700 "$BK_ROOT" "$BK" 2>/dev/null
  : > "$BK/sysctl-live.txt"
  while IFS='|' read -r key mode want; do
    v=$(sysctl -n "$key" 2>/dev/null) || continue
    printf '%s|%s\n' "$key" "$(norm "$v")" >> "$BK/sysctl-live.txt"
  done < <(build_spec)
  # копии конфигов: есть «.prev» — файл существовал до нас, нет — создали мы
  [ -f "$CONF" ]          && cp -p "$CONF" "$BK/conf.prev"
  [ -f "$MODCONF" ]       && cp -p "$MODCONF" "$BK/modconf.prev"
  [ -f "$LIMCONF" ]       && cp -p "$LIMCONF" "$BK/limits.conf.prev"
  [ -f "$DAEMON_JSON" ]   && cp -p "$DAEMON_JSON" "$BK/daemon.json.prev"
  [ -f "$JOURNALD_CONF" ] && cp -p "$JOURNALD_CONF" "$BK/journald.conf.prev"
  cp -p "$FSTAB" "$BK/fstab.bak" 2>/dev/null
  cp "$PROC_SWAPS" "$BK/swaps.txt" 2>/dev/null
  : > "$BK/state.env"
  state_set IFACE "${IFACE:-}"
  state_set QDISC_PREV "${QL:-}"
  state_set QDISC_APPLIED 0
  state_set SWAP_PREV_MB "$SW_OURS"
  for f in SWAP_TOUCHED LIM_TOUCHED DJ_TOUCHED JRN_TOUCHED; do state_set "$f" 0; done
  return 0
}

# ── блок «система»: swap → sysctl → очередь ──
apply_swap() {
  case "$SW_ACTION" in
    create|resize)
      state_set SWAP_TOUCHED 1
      if spin "готовлю swap ${SW_NEED} МБ в $SWAPFILE (создание файла может занять время)…" build_swapfile "$SW_NEED"; then
        ok "swap включён: теперь $(swap_total_mb) МБ, добавлен в fstab"
      else
        [ -n "$SPIN_OUT" ] && printf '%s\n' "$SPIN_OUT"
        bad "swap настроить не удалось — остальное применяю без него"
        # если пересоздание сломалось на полпути — пробуем вернуть прежний размер
        if [ "$SW_OURS" -gt 0 ] && [ -z "$(swap_ours_mb)" ]; then build_swapfile "$SW_OURS" >/dev/null 2>&1 || true; fi
      fi ;;
    nodisk) warn "на диске нет места под swap — пропускаю" ;;
    *)      ok "swap достаточен — не трогаю" ;;
  esac
}

# Пишем в конфиг ВСЕ поддерживаемые ключи (чтобы они пережили ребут), с
# комментарием «зачем» над каждым — файл сам себе документация.
write_conf() {
  local tmp i d
  tmp=$(mktemp) || return 1
  {
    printf '# Сгенерировано node-tuning.sh v%s · %s\n' "$VERSION" "$(date '+%F %T')"
    printf '# Откат: sudo bash node-tuning.sh rollback\n'
    printf '# Значения подобраны под %s МБ RAM; «не меньше»-ключи не понижаются.\n\n' "$RAM_MB"
    for i in "${!SPEC_KEY[@]}"; do
      [ "${SPEC_ST[$i]}" = na ] && continue
      d=$(key_desc "${SPEC_KEY[$i]}"); [ -n "$d" ] && printf '# %s\n' "$d"
      printf '%s = %s\n\n' "${SPEC_KEY[$i]}" "${SPEC_TGT[$i]}"
    done
  } > "$tmp"
  mkdir -p "$(dirname "$CONF")"
  install -m 644 "$tmp" "$CONF"; rm -f "$tmp"
  # Ключи net.netfilter.* живут в модуле nf_conntrack. При загрузке он
  # подтягивается позже, чем systemd-sysctl читает файлы, и эти строки молча
  # не применились бы. Закрепляем модуль на раннюю загрузку.
  if grep -q '^net\.netfilter\.' "$CONF"; then
    mkdir -p "$(dirname "$MODCONF")"
    printf '# nf_conntrack нужен раньше sysctl — иначе таблица соединений не применится после ребута\nnf_conntrack\n' > "$MODCONF"
  fi
}

# Сверяем желаемое с фактическим: файл в sysctl.d — не последнее слово,
# другой файл с тем же ключом (читается позже по алфавиту) может перебить наш.
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

apply_system() {
  local out l
  apply_swap
  if write_conf; then ok "записан $CONF (с комментариями к каждому ключу)"; fi
  out=$(sysctl -p "$CONF" 2>&1 >/dev/null)
  if [ -n "$out" ]; then
    warn "sysctl ругнулся:"
    printf '%s\n' "$out" | while IFS= read -r l; do sub "$l"; done
  else
    ok "sysctl применён, настройки переживут перезагрузку"
  fi
  # fq на живом интерфейсе (sysctl действует только на будущие интерфейсы)
  if [ "$QD_BAD" = 1 ] && [ -n "${IFACE:-}" ]; then
    if tc qdisc replace dev "$IFACE" root fq 2>/dev/null; then
      ok "очередь на ${IFACE}: ${QL} → fq"; state_set QDISC_APPLIED 1
    else
      warn "очередь на ${IFACE} сейчас не сменилась — встанет fq после перезагрузки"
    fi
  fi
  verify_applied
}

# ── блок «Docker и диск»: конфиги → ОДИН перезапуск → пересоздание ──
# Конфиги меняем все сразу, а Docker перезапускаем один раз: каждый
# лишний рестарт — ещё одно отключение клиентов.
apply_docker_disk() {
  local d u need=0
  if [ "$DK_PRESENT" = 1 ]; then
    # Лимит открытых файлов/процессов для демона Docker (drop-in юнита).
    if [ "$LIM_BAD" = 1 ]; then
      state_set LIM_TOUCHED 1
      mkdir -p "$(dirname "$LIMCONF")"
      cat > "$LIMCONF" <<'EOF'
# Сгенерировано node-tuning.sh. Откат: sudo bash node-tuning.sh rollback
[Service]
# LimitNOFILE — максимум открытых файлов (каждое соединение = дескриптор).
# При дефолтной 1024 нода отказывает клиентам, оставаясь «живой».
LimitNOFILE=1048576
# LimitNPROC — максимум процессов/потоков у демона и его детей.
LimitNPROC=1048576
EOF
      systemctl daemon-reload && ok "лимиты Docker записаны: NOFILE/NPROC = 1048576"
    fi
    # Лимит логов контейнеров (json-file: 50 МБ × 3 файла).
    if [ "$DLOG_BAD" = 1 ]; then
      state_set DJ_TOUCHED 1
      if write_daemon_json; then ok "daemon.json: логи ограничены (50m × 3), остальные настройки сохранены"
      else bad "daemon.json не обновлён: нет python3/jq, а файл уже содержит чужие настройки"
           sub "добавь вручную: \"log-driver\": \"json-file\", \"log-opts\": {\"max-size\":\"50m\",\"max-file\":\"3\"}"; fi
    fi
  fi
  # Журнал systemd: потолок 200 МБ + чистка уже накопленного.
  if [ "$JRN_BAD" = 1 ] || [ "$JRN_VAC" = 1 ]; then
    state_set JRN_TOUCHED 1
    [ -f "$JOURNALD_CONF" ] || { mkdir -p "$(dirname "$JOURNALD_CONF")"; : > "$JOURNALD_CONF"; }
    if grep -q '^SystemMaxUse=' "$JOURNALD_CONF"; then
      sed -i "s/^SystemMaxUse=.*/SystemMaxUse=${JOURNAL_MAX_MB}M/" "$JOURNALD_CONF"
    else
      printf 'SystemMaxUse=%sM\n' "$JOURNAL_MAX_MB" >> "$JOURNALD_CONF"
    fi
    journalctl --vacuum-size="${JOURNAL_MAX_MB}M" >/dev/null 2>&1
    systemctl restart systemd-journald 2>/dev/null
    ok "журнал systemd: SystemMaxUse=${JOURNAL_MAX_MB}M, накопленное очищено (необратимо)"
  fi
  # btmp — журнал неудачных входов SSH.
  if [ "$BTMP_BAD" = 1 ]; then
    truncate -s 0 "$BTMP" && ok "$BTMP обнулён (было ${BTMP_MB} МБ, необратимо)"
  fi
  # Единственный перезапуск Docker.
  if [ "$DK_RESTART" = 1 ]; then
    warn "перезапускаю Docker — клиенты отвалятся секунд на 10"
    if spin "перезапускаю Docker…" systemctl restart docker; then
      ok "Docker перезапущен"
      if [ "$CT_STATE" = running ]; then
        spin "жду, пока $NODE_CT поднимется…" wait_ct 40 || {
          warn "$NODE_CT сам не поднялся — запускаю"; docker start "$NODE_CT" >/dev/null 2>&1; }
      fi
    else
      bad "systemctl restart docker не удался:"; printf '%s\n' "$SPIN_OUT" | while IFS= read -r l; do sub "$l"; done
      return 1
    fi
  fi
  # Пересоздание контейнера: только если лимит логов так и не доехал
  # (или внутри всё ещё мало файловых дескрипторов).
  if [ "$DK_PRESENT" = 1 ] && [ "$CT_STATE" != none ]; then
    need=0
    ct_logcfg_ok || need=1
    if [ "$LIM_BAD" = 1 ]; then
      u=$(ct_ulimit)
      case "$u" in ''|*[!0-9]*) : ;; *) [ "$u" -lt 65536 ] && need=1 ;; esac
    fi
    if [ "$need" = 1 ]; then
      if d=$(compose_dir); then
        warn "пересоздаю контейнер $NODE_CT — клиенты отвалятся ещё раз на ~10 с"
        if spin "пересоздаю $NODE_CT (compose: $d)…" compose_up "$d"; then ok "контейнер пересоздан"
        else bad "пересоздание не удалось:"; printf '%s\n' "$SPIN_OUT" | while IFS= read -r l; do sub "$l"; done; fi
      else
        warn "docker-compose.yml для $NODE_CT не найден (метка compose и /opt/remnanode) — пересоздай вручную:"
        sub "cd <каталог ноды> && docker compose up -d --force-recreate"
      fi
    fi
  fi
}

# Итоговая сверка Docker и диска — то, что обещали скриншоты-инструкции.
verify_docker_disk() {
  local u cfg
  if [ "$DK_PRESENT" = 1 ] && [ "$CT_STATE" != none ]; then
    wait_ct 20
    u=$(ct_ulimit)
    case "$u" in ''|*[!0-9]*) warn "ulimit -n в $NODE_CT не прочитан" ;;
      *) if [ "$u" -ge 65536 ]; then ok "ulimit -n внутри $NODE_CT = $u"
         else warn "ulimit -n внутри $NODE_CT = $u — всё ещё мало"; fi ;;
    esac
    cfg=$(docker inspect "$NODE_CT" --format '{{.HostConfig.LogConfig.Config}}' 2>/dev/null)
    if printf '%s' "$cfg" | grep -q 'max-size'; then ok "логи $NODE_CT: $cfg"
    else warn "у $NODE_CT лимит логов не применён: $cfg"; fi
    ct_running && ok "$NODE_CT: Up" || warn "$NODE_CT не запущен — проверь docker ps"
  fi
  [ "$JRN_PRESENT" = 1 ] && ok "журнал systemd: $(jrn_size_mb) МБ, лимит $(jrn_cfg_value)"
  ok "диск /: $(df -h / 2>/dev/null | awk 'NR==2{print $3" из "$2" ("$5")"}')"
}

do_tune() {
  local before=0 after=0
  detect_env
  banner "тюнинг сервера"
  show_env
  if virt_blocked; then bad "тюнинг на ${VIRT} невозможен"; return 1; fi

  stepn 1 6 "Скорость до тюнинга"
  speed_test; before=$SPEED_BPS

  stepn 2 6 "Анализ — чего не хватает"
  load_modules; analyse
  print_table
  print_swap
  print_docker_disk
  if [ "$N_TODO" -eq 0 ]; then ok "всё уже на месте — менять нечего"; return 0; fi
  printf '\n'
  if [ "$DK_RESTART" = 1 ]; then warn "будет перезапущен Docker (один раз) — клиенты отвалятся на ~10 с"; fi
  if [ "$CT_RECREATE" = 1 ]; then warn "возможно пересоздание $NODE_CT — ещё ~10 с без клиентов"; fi
  if [ "$JRN_VAC" = 1 ] || [ "$JRN_BAD" = 1 ] || [ "$BTMP_BAD" = 1 ]; then
    warn "очистка журнала и btmp необратима (остальное откатывается)"; fi
  if ! confirm "Применить изменения? Перед этим будет сделан бэкап."; then
    warn "отменено, ничего не изменено"; return 0
  fi

  stepn 3 6 "Бэкап"
  if make_backup; then
    ok "снимок сохранён: $BK"
    sub "вернуть всё: sudo bash $0 rollback"
  else
    bad "не удалось создать бэкап — тюнинг прерван (ничего не изменено)"; return 1
  fi

  stepn 4 6 "Система: swap, sysctl, очередь"
  apply_system

  stepn 5 6 "Docker и диск"
  apply_docker_disk

  stepn 6 6 "Проверка и скорость после тюнинга"
  verify_docker_disk
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

# ═════════════════════════════════════════════════════════════════════
#  3. ОТКАТ
# ═════════════════════════════════════════════════════════════════════
# restore_file СНИМОК ИМЯ_КОПИИ ЦЕЛЬ — вернуть файл из снимка
# или удалить, если до тюнинга его не было.
restore_file() {
  if [ -f "$1/$2" ]; then cp -p "$1/$2" "$3"; else rm -f "$3"; fi
}

do_rollback() {
  local list=() d n i k v choice restart_dk=0
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

  # shellcheck disable=SC1090,SC1091
  . "$d/state.env"
  IFACE=${IFACE:-}; SWAP_PREV_MB=${SWAP_PREV_MB:-0}; SWAP_TOUCHED=${SWAP_TOUCHED:-0}
  QDISC_APPLIED=${QDISC_APPLIED:-0}; QDISC_PREV=${QDISC_PREV:-}
  LIM_TOUCHED=${LIM_TOUCHED:-0}; DJ_TOUCHED=${DJ_TOUCHED:-0}; JRN_TOUCHED=${JRN_TOUCHED:-0}
  { [ "$LIM_TOUCHED" = 1 ] || [ "$DJ_TOUCHED" = 1 ]; } && restart_dk=1

  [ "$restart_dk" = 1 ] && warn "для отката лимитов Docker он будет перезапущен — клиенты отвалятся на ~10 с"
  if ! confirm "Восстановить состояние из $(basename "$d")?"; then warn "отменено"; return 0; fi

  step "Конфиги sysctl"
  restore_file "$d" conf.prev "$CONF" && \
    { [ -f "$d/conf.prev" ] && ok "восстановлен прежний $CONF" || ok "удалён $CONF (до тюнинга его не было)"; }
  restore_file "$d" modconf.prev "$MODCONF"

  step "Swap"
  if [ "$SWAP_TOUCHED" = 1 ]; then
    RAM_MB=$(awk '/^MemTotal:/{print int(($2+512)/1024)}' /proc/meminfo)
    if [ "$SWAP_PREV_MB" -gt 0 ]; then
      # swap-файл существовал — возвращаем прежний размер
      if spin "возвращаю размер $SWAPFILE: ${SWAP_PREV_MB} МБ…" build_swapfile "$SWAP_PREV_MB"; then
        ok "размер $SWAPFILE возвращён: ${SWAP_PREV_MB} МБ"
      else bad "не удалось вернуть размер swap-файла"; fi
    else
      # swap создали мы — отключаем, удаляем файл и строку fstab
      swapoff "$SWAPFILE" 2>/dev/null
      if [ -n "$(swap_ours_mb)" ]; then
        bad "не удалось отключить $SWAPFILE (в нём данные) — удали вручную, когда освободится RAM"
      else
        rm -f "$SWAPFILE"
        sed -i "\|^$SWAPFILE[[:space:]]|d" "$FSTAB"
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

  step "Docker и диск"
  if [ "$LIM_TOUCHED" = 1 ]; then
    restore_file "$d" limits.conf.prev "$LIMCONF"
    rmdir "$(dirname "$LIMCONF")" 2>/dev/null   # пустой drop-in каталог убираем
    systemctl daemon-reload && ok "лимиты Docker возвращены"
  fi
  if [ "$DJ_TOUCHED" = 1 ]; then
    restore_file "$d" daemon.json.prev "$DAEMON_JSON" && ok "daemon.json возвращён"
  fi
  if [ "$restart_dk" = 1 ]; then
    if spin "перезапускаю Docker…" systemctl restart docker; then ok "Docker перезапущен с прежними настройками"
    else bad "Docker не перезапустился: проверь systemctl status docker"; fi
  fi
  if [ "$JRN_TOUCHED" = 1 ]; then
    restore_file "$d" journald.conf.prev "$JOURNALD_CONF"
    systemctl restart systemd-journald 2>/dev/null && ok "настройки журнала возвращены"
  fi
  if [ "$LIM_TOUCHED$DJ_TOUCHED$JRN_TOUCHED" != 000 ]; then
    sub "не откатывается по природе: очищенные журнал и btmp; контейнер сохранит лимит логов до пересоздания"
  else
    ok "Docker и журнал тюнингом не менялись"
  fi

  mv "$d" "$d.restored" 2>/dev/null
  printf '\n'; line
  ok "откат выполнен. Снимок помечен как использованный: $(basename "$d").restored"
  printf '\n'
}

# ═════════════════════════════════════════════════════════════════════
#  МЕНЮ И ТОЧКА ВХОДА
# ═════════════════════════════════════════════════════════════════════
# Краткая справка «что проверяет и делает скрипт» — показывается при запуске
# меню и по команде about.
about() {
  printf '\n  %s%sЧТО СКРИПТ ПРОВЕРЯЕТ%s\n' "$B" "$C" "$N"
  printf '   %s▸%s %s%s%s — %s\n' "$C" "$N" "$B" "Сеть и ядро" "$N" "BBR + fq, буферы TCP/UDP, conntrack, очереди, MTU-probing"
  printf '   %s▸%s %s%s%s — %s\n' "$C" "$N" "$B" "Swap" "$N" "есть ли и хватает ли под ваш объём RAM (размер подбирается сам)"
  printf '   %s▸%s %s%s%s — %s\n' "$C" "$N" "$B" "Docker" "$N" "лимиты файлов и процессов, лимит логов, ulimit внутри контейнера"
  printf '   %s▸%s %s%s%s — %s\n' "$C" "$N" "$B" "Диск" "$N" "журнал systemd, btmp, заполнение корня"
  printf '   %s▸%s %s%s%s — %s\n' "$C" "$N" "$B" "Скорость" "$N" "замер скачивания до и после тюнинга"
  printf '\n  %s%sЧТО ДЕЛАЕТ%s\n' "$B" "$C" "$N"
  printf '   %s1%s  Проверка   %sничего не меняет: вердикт и список рекомендаций%s\n' "$B" "$N" "$D" "$N"
  printf '   %s2%s  Тюнинг     %sбэкап → swap → sysctl → очередь → Docker и диск → проверка%s\n' "$B" "$N" "$D" "$N"
  printf '   %s3%s  Откат      %sвозвращает всё из снимка, сделанного перед тюнингом%s\n' "$B" "$N" "$D" "$N"
  printf '\n  %s%sВАЖНО%s\n' "$B" "$Y" "$N"
  printf '   %s•%s Docker перезапускается один раз — клиенты отвалятся секунд на 10\n' "$Y" "$N"
  printf '   %s•%s Не откатываются: очистка журнала, обнуление btmp, пересоздание контейнера\n' "$Y" "$N"
  printf '   %s•%s Подробности по каждому пункту — в шапке файла скрипта\n' "$Y" "$N"
}

usage() {
  cat <<'EOF'
node-tuning.sh — проверка, тюнинг и откат настроек ноды

  sudo bash node-tuning.sh               интерактивное меню
  sudo bash node-tuning.sh about         что проверяет и делает скрипт
  sudo bash node-tuning.sh check         проверка + вердикт
  sudo bash node-tuning.sh tune [-y]     тюнинг (-y — без вопросов)
  sudo bash node-tuning.sh rollback [-y] откат к состоянию до тюнинга

  NODE_CONTAINER=имя   контейнер ноды (по умолчанию remnanode)
  NO_COLOR=1           без цветов и анимации
EOF
}

main_menu() {
  while true; do
    banner "настройка ноды"
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
    check|tune|rollback|about) CMD=$a ;;
    -y|--yes)            ASSUME_YES=1 ;;
    -h|--help)           usage; exit 0 ;;
    *) bad "не понял аргумент: $a"; usage; exit 2 ;;
  esac
done

if [ "$(id -u)" != 0 ]; then
  bad "нужен root: sudo bash $0 ${CMD}"; exit 1
fi

intro
case "$CMD" in
  about)    about ;;
  check)    do_check ;;
  tune)     do_tune ;;
  rollback) do_rollback ;;
  *)        about; main_menu ;;   # меню: сначала короткая справка
esac
