#!/usr/bin/env bash
# edgeguard_pi.sh - EdgeGuard AI edge-node runtime (Raspberry Pi 4 profile).
# Boots the node, starts edgeguard.service, then runs the 1 Hz monitor loop:
# acquire frame -> normalize -> nearest-prototype inference -> interlock ->
# GPIO actuation, cycling through the five fault scenarios and emitting a
# verdict on every state transition.
#
# usage: bash edgeguard_pi.sh [--fast] [--no-boot] [--loop] [--no-color] [-h]
#   --fast      run about 3x faster
#   --no-boot   skip the boot log, start at the monitor
#   --loop      keep cycling scenarios until Ctrl+C
#   --no-color  plain output

set -u
SPEED=1; BOOT=1; LOOP=0; COLOR=1
for a in "$@"; do
  case "$a" in
    --fast) SPEED=0.35 ;;
    --no-boot) BOOT=0 ;;
    --loop) LOOP=1 ;;
    --no-color) COLOR=0 ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $a (try -h)"; exit 1 ;;
  esac
done

if [ "$COLOR" = 1 ] && [ -t 1 ]; then
  G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; BL=$'\033[34m'; D=$'\033[2m'; B=$'\033[1m'; N=$'\033[0m'
else
  G=; Y=; R=; BL=; D=; B=; N=
fi

pause() { sleep "$(awk -v a="$1" -v s="$SPEED" 'BEGIN{printf "%.3f", a*s}')"; }
CHAR=$(awk -v s="$SPEED" 'BEGIN{printf "%.3f", 0.028*s}')
rep() { local s="" i; for ((i=0; i<$2; i++)); do s+="$1"; done; printf "%s" "$s"; }
now() { date +%H:%M:%S; }
prompt() { printf "%s" "${G}${B}pi@edgeguard-pi${N}:${BL}${B}~/edgeguard${N} \$ "; }

typecmd() {
  local cmd="$1" i
  prompt
  for ((i=0; i<${#cmd}; i++)); do printf "%s" "${cmd:i:1}"; sleep "$CHAR"; done
  printf "\n"; pause 0.3
}

progress() {
  local label="$1" n=24 i bar step
  step=$(awk -v d="$2" -v n=$n 'BEGIN{printf "%.3f", d/n}')
  for ((i=0; i<=n; i++)); do
    bar="$(rep '█' $i)$(rep '░' $((n-i)))"
    printf "\r  %s [%s] %3d%%" "$label" "$bar" $((i*100/n))
    pause "$step"
  done
  printf "\n"
}

box() {   # box COLOR TITLE row...
  local col="$1" title="$2" W=56; shift 2
  printf "%s╔═ %s%s%s %s╗%s\n" "$col" "$B" "$title" "$N$col" "$(rep '═' $((W-${#title}-3)))" "$N"
  local r
  for r in "$@"; do printf "%s║%s %-54s %s║%s\n" "$col" "$N" "$r" "$col" "$N"; done
  printf "%s╚%s╝%s\n" "$col" "$(rep '═' $W)" "$N"
}

# ---------------------------------------------------------------- boot ----
boot() {
  local t=0 l
  local klog=(
    "Booting Linux on physical CPU 0x0000000000 [0x410fd083]"
    "Linux version 6.6.51+rpt-rpi-v8 (aarch64-linux-gnu-gcc-12) #1 SMP PREEMPT Debian 1:6.6.51-1+rpt3"
    "Machine model: Raspberry Pi 4 Model B Rev 1.4"
    "Memory: 3794MiB available"
    "smp: Brought up 1 node, 4 CPUs"
    "mmc0: SDHCI controller on fe340000.mmc"
    "EXT4-fs (mmcblk0p2): mounted filesystem with ordered data mode"
    "w1_master_driver w1_bus_master1: Attaching one wire slave 28-0316a2794aff"
    "i2c i2c-1: new_device: adxl345 at 0x53"
    "i2c i2c-1: new_device: ads1115 at 0x48"
    "brcmfmac: wlan0: link up"
  )
  for l in "${klog[@]}"; do
    t=$(awk -v t="$t" 'BEGIN{srand(); printf "%.6f", t + 0.05 + rand()*0.6}')
    printf "%s[%12s]%s %s\n" "$D" "$t" "$N" "$l"
    pause 0.09
  done
  local units=(
    "Mounted boot-firmware.mount - /boot/firmware."
    "Started systemd-timesyncd.service - Network Time Synchronization."
    "Started ssh.service - OpenBSD Secure Shell server."
    "Reached target network-online.target - Network is Online."
    "Started edgeguard-sensors.service - EdgeGuard sensor bus (1-Wire, I2C)."
    "Started edgeguard.service - EdgeGuard AI local inference service."
    "Reached target multi-user.target - Multi-User System."
  )
  echo
  for l in "${units[@]}"; do printf "[  %sOK%s  ] %s\n" "$G" "$N" "$l"; pause 0.16; done
  echo; pause 0.5
  echo "Debian GNU/Linux 12 edgeguard-pi tty1"; echo
  echo "edgeguard-pi login: pi (automatic login)"; pause 0.4
  echo
  echo "  ${B}EdgeGuard AI${N} · edge node image v1.2"
  echo "  ${D}Raspberry Pi 4 Model B · BCM2711 · 4 GB${N}"
  echo "  ${D}sensors: DS18B20 · ADXL345 · ACS712   inference: on-device   cloud: none${N}"
  echo; pause 0.6
}

# ------------------------------------------------------------- monitor ----
FRAMES=0; EVENTS=0; TRIPS=0; LSUM=0; SEEN="|"; LASTKEY=""

summary() {
  local mean missing="" s
  mean=$(awk -v s="$LSUM" -v n="$FRAMES" 'BEGIN{printf "%.3f", n ? s/n : 0}')
  for s in "Overheating" "Excessive vibration" "Electrical overload" "Combined fault"; do
    case "$SEEN" in *"|$s|"*) ;; *) missing="$missing $s;" ;; esac
  done
  echo
  if [ -z "$missing" ]; then
    box "$G" "SESSION VERDICT" "PASS - every injected fault was detected" \
      "Frames processed : $FRAMES" "Fault events     : $EVENTS" "Interlock trips  : $TRIPS" \
      "Mean inference   : $mean ms per frame" "Cloud calls      : 0"
  else
    box "$Y" "SESSION VERDICT" "INCOMPLETE - not every scenario was reached" \
      "Frames processed : $FRAMES" "Fault events     : $EVENTS" "Interlock trips  : $TRIPS" \
      "Mean inference   : $mean ms per frame" "Cloud calls      : 0"
  fi
  echo "${D}[edgeguard] monitor stopped · edgeguard.service still active${N}"
  prompt; echo
}

on_int() { printf "\n^C\n%s[edgeguard] SIGINT received, stopping monitor loop%s\n" "$D" "$N"; summary; exit 0; }
trap on_int INT

# scenario targets: temp(C) vib(g) curr(A)
target() {
  case "$1" in
    normal)    echo "42 0.18 1.8" ;;
    heat)      echo "96 0.27 2.5" ;;
    vibration) echo "48 1.23 2.5" ;;
    current)   echo "50 0.38 9.2" ;;
    combined)  echo "112 1.35 9.4" ;;
  esac
}
label() {
  case "$1" in
    normal) echo "normal operation" ;; heat) echo "thermal fault (overheating)" ;;
    vibration) echo "mechanical fault (excess vibration)" ;; current) echo "electrical overload" ;;
    combined) echo "combined fault (all channels)" ;;
  esac
}

# one inference frame: noise + nearest-prototype classifier + threshold rule
frame() {
  awk -v seed="$RANDOM$RANDOM" -v pt="$1" -v pv="$2" -v pc="$3" -v tt="$4" -v tv="$5" -v tc="$6" -v f="$7" -v ls="$LSUM" 'BEGIN{
    srand(seed)
    t = pt + (tt-pt)*f + (rand()-.5)*1.6
    v = pv + (tv-pv)*f + (rand()-.5)*.04; if (v < 0) v = 0
    c = pc + (tc-pc)*f + (rand()-.5)*.16; if (c < 0) c = 0
    n[1]="Normal operation";    p1[1]=.35; p2[1]=.12; p3[1]=.20
    n[2]="Overheating";         p1[2]=.80; p2[2]=.20; p3[2]=.32
    n[3]="Excessive vibration"; p1[3]=.42; p2[3]=.78; p3[3]=.32
    n[4]="Electrical overload"; p1[4]=.45; p2[4]=.32; p3[4]=.83
    n[5]="Combined fault";      p1[5]=.88; p2[5]=.85; p3[5]=.88
    x1=t/120; x2=v/1.5; x3=c/10; bd=99
    for (k=1; k<=5; k++) { d=sqrt((x1-p1[k])^2+(x2-p2[k])^2+(x3-p3[k])^2); if (d<bd) {bd=d; bk=k} }
    sc=int(100*(1-bd/1.25)+.5); if (sc>99) sc=99; if (sc<50) sc=50
    crit = (t>=110)
    fault = (bk!=1 || t>75 || v>.65 || c>6.5 || crit)
    rf = (t>=85 || v>=.75 || c>=7 || crit)
    lat = 0.035 + rand()*0.08
    printf "%.1f|%.2f|%.1f|%s|%.3f|%d|%d|%d|%d|%.3f|%.4f\n", t, v, c, n[bk], bd, sc, fault, crit, rf, lat, ls+lat
  }'
}

verdict() {   # cls score fault crit rulefault
  local cls="$1" sc="$2" fault="$3" crit="$4" rf="$5" agree
  if [ "$cls" = "Normal operation" ]; then mn=0; else mn=1; fi
  if [ "$mn" = "$rf" ]; then
    [ "$rf" = 1 ] && agree="AGREE (both fault)" || agree="AGREE (both normal)"
  else agree="DISAGREE - flag for review"; fi
  echo
  if [ "$crit" = 1 ]; then
    box "$R" "VERDICT" "STATUS : CRITICAL - EMERGENCY STOP" "CLASS  : $cls" \
      "TRIGGER: temperature >= 110 C (independent interlock)" "ACTION : motor OFF, alarm ON, interlock TRIPPED" "MODEL/RULE: $agree"
  elif [ "$fault" = 1 ] && [ "$mn" = 1 ]; then
    box "$Y" "VERDICT" "STATUS : FAULT DETECTED" "CLASS  : $cls" "SCORE  : $sc/100 (prototype match)" \
      "ACTION : motor STOPPED, alarm ACTIVE" "MODEL/RULE: $agree"
  elif [ "$fault" = 1 ]; then
    box "$Y" "VERDICT" "STATUS : WARNING - readings approaching limits" "CLASS  : $cls" \
      "SCORE  : $sc/100 (prototype match)" "ACTION : motor STOPPED as precaution, alarm ON" "MODEL/RULE: $agree"
  else
    box "$G" "VERDICT" "STATUS : HEALTHY" "CLASS  : $cls" "SCORE  : $sc/100 (prototype match)" \
      "ACTION : motor RUNNING, alarm OFF" "MODEL/RULE: $agree"
  fi
  if [ "$fault" = 1 ]; then
    echo "${D}  GPIO17 relay → LOW  (motor stopped)   GPIO27 alarm → HIGH (buzzer + LED)${N}"
  else
    echo "${D}  GPIO17 relay → HIGH (motor running)   GPIO27 alarm → LOW  (silent)${N}"
  fi
  echo
}

header() { printf "%s  TIME      FRAME   TEMP     VIB     CURR    PREDICTION            DIST   STATE%s\n" "$D" "$N"; }

monitor() {
  typecmd "systemctl is-active edgeguard"
  echo "active"; pause 0.3
  typecmd "python3 edgeguard.py --monitor --hz 1"
  echo "${D}[edgeguard] loading models/prototype_v1.json${N}"
  progress "loading " 0.9
  echo "  classes 5 · features 3 [temp/120, vib/1.5, curr/10] · 15 parameters · 0.6 KB"
  echo "  runtime CPU (numpy) · network not required · interlock 110 C"
  pause 0.3
  echo "${D}[edgeguard] sensor self-test${N}"; pause 0.3
  echo "  DS18B20  w1 28-0316a2794aff   ${G}OK${N}"; pause 0.15
  echo "  ADXL345  i2c-1 @ 0x53         ${G}OK${N}"; pause 0.15
  echo "  ACS712   ADS1115 @ 0x48 A0    ${G}OK${N}"; pause 0.3
  echo "${G}[edgeguard] monitoring started${N} ${D}· Ctrl+C to stop${N}"
  echo

  local phases=(normal heat normal vibration normal current normal combined normal)
  local prev="42 0.18 1.8" ph ticks k f line t v c cls dist sc fault crit rf lat state key last=""
  local pt pv pc tt tv tc
  while :; do
    for ph in "${phases[@]}"; do
      if [ -n "$last" ]; then
        if [ "$ph" = normal ] && [ "$last" = combined ]; then
          echo "${D}[ops] interlock reset by operator · motor restarted${N}"; pause 0.4
        elif [ "$ph" = normal ]; then
          echo "${D}[ops] fault cleared · motor restarted${N}"; pause 0.4
        fi
      fi
      echo "${D}[sim] scenario → $(label "$ph")${N}"
      header
      read -r pt pv pc <<< "$prev"; read -r tt tv tc <<< "$(target "$ph")"
      if [ "$ph" = normal ]; then ticks=5; else ticks=7; fi
      for ((k=1; k<=ticks; k++)); do
        if [ "$ph" = normal ]; then f=1; else f=$(awk -v k=$k 'BEGIN{x=k/3; if (x>1) x=1; print x}'); fi
        line=$(frame "$pt" "$pv" "$pc" "$tt" "$tv" "$tc" "$f")
        IFS='|' read -r t v c cls dist sc fault crit rf lat LSUM <<< "$line"
        FRAMES=$((FRAMES+1))
        if [ "$crit" = 1 ]; then state="${R}${B}CRITICAL${N}"; key="crit"
        elif [ "$fault" = 1 ] && [ "$cls" != "Normal operation" ]; then state="${Y}FAULT${N}"; key="fault:$cls"
        elif [ "$fault" = 1 ]; then state="${Y}WARN${N}"; key="warn"
        else state="${G}OK${N}"; key="ok"; fi
        printf "  %s  %s#%04d%s  %5.1f°C  %4.2fg  %4.1fA   %-20s  %.3f  %s\n" \
          "$(now)" "$D" $((1040+FRAMES)) "$N" "$t" "$v" "$c" "$cls" "$dist" "$state"
        if [ "$key" != "$LASTKEY" ]; then
          case "$key" in fault:*|crit) EVENTS=$((EVENTS+1)) ;; esac
          [ "$crit" = 1 ] && TRIPS=$((TRIPS+1))
          SEEN="$SEEN$cls|"
          [ -n "$LASTKEY" ] && verdict "$cls" "$sc" "$fault" "$crit" "$rf"
          LASTKEY="$key"
        fi
        pause 0.9
      done
      prev="$tt $tv $tc"; last="$ph"
      echo
    done
    [ "$LOOP" = 1 ] || break
  done
  summary
}

# ---------------------------------------------------------------- main ----
if [ "$BOOT" = 1 ]; then boot; fi
monitor
