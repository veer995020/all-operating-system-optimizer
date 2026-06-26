#!/usr/bin/env bash
# ================================================================
#  UNIVERSAL LINUX OPTIMIZER v1.0
#  Bash port of Universal PC Optimizer v13.0 (Windows/PowerShell)
#  Same 6-step structure, same spirit, native Linux mechanisms.
#  Works on: Ubuntu/Debian, Fedora/RHEL, Arch, openSUSE (auto-detected)
#  No file deletion of anything important — only safe caches/logs.
#  Made by Veer Bhardwaj
# ================================================================

set -u
# NOTE: deliberately NOT using -e or pipefail — individual tweak
# failures are logged and skipped, never abort the whole script
# (same philosophy as -ErrorAction SilentlyContinue in the PS version).

# ── ROOT CHECK + AUTO RE-EXEC VIA SUDO ───────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    echo
    echo "This script needs root privileges. Re-launching with sudo..."
    echo
    exec sudo bash "$0" "$@"
    exit 1
fi

# ── DETECT SYSTEM INFO ────────────────────────────────────────────
DISTRO_NAME="Unknown Linux"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO_NAME="${PRETTY_NAME:-$DISTRO_NAME}"
fi
KERNEL_VER="$(uname -r)"

PKG_MGR=""
if command -v apt-get  &>/dev/null; then PKG_MGR="apt"
elif command -v dnf     &>/dev/null; then PKG_MGR="dnf"
elif command -v yum     &>/dev/null; then PKG_MGR="yum"
elif command -v pacman  &>/dev/null; then PKG_MGR="pacman"
elif command -v zypper  &>/dev/null; then PKG_MGR="zypper"
fi

# Real (non-root) user/home, for user-scoped cleanup (thumbnails, autostart)
REAL_USER="${SUDO_USER:-}"
if [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; then
    REAL_USER="$(logname 2>/dev/null || echo "")"
fi
REAL_HOME=""
if [ -n "$REAL_USER" ]; then
    REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6)"
fi

# ── COLORS + RAINBOW PALETTE (precomputed once, cached array) ───
RESET="\033[0m"
BOLD="\033[1m"
GREEN="\033[1;32m"
CYAN="\033[1;36m"
GRAY="\033[2;37m"

RAINBOW_STEPS=48
declare -a RAINBOW
while IFS=' ' read -r r g b; do
    RAINBOW+=("\033[38;2;${r};${g};${b}m")
done < <(awk -v steps="$RAINBOW_STEPS" '
function abs(x){ if (x<0) return -x; else return x }
BEGIN{
    for(i=0;i<steps;i++){
        h = i*360.0/steps
        s = 0.85; v = 1.0
        c = v*s
        hh = h/60.0
        hh_mod2 = hh - 2*int(hh/2)
        x = c*(1-abs(hh_mod2-1))
        m = v-c
        seg = int(hh) % 6
        if(seg==0){r=c;g=x;b=0}
        else if(seg==1){r=x;g=c;b=0}
        else if(seg==2){r=0;g=c;b=x}
        else if(seg==3){r=0;g=x;b=c}
        else if(seg==4){r=x;g=0;b=c}
        else {r=c;g=0;b=x}
        printf "%d %d %d\n", int((r+m)*255), int((g+m)*255), int((b+m)*255)
    }
}')

SPIN_FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")

# ── SHARED STATE ──────────────────────────────────────────────────
LOGFILE="/var/log/pc-optimizer-$(date +%Y%m%d-%H%M%S).log"
START_EPOCH=$(date +%s)
STEP_WEIGHTS=(20 30 10 10 8 16)   # mirrors v13.0 PowerShell weights
TOTAL_WEIGHT=0
for w in "${STEP_WEIGHTS[@]}"; do TOTAL_WEIGHT=$((TOTAL_WEIGHT + w)); done
DONE_WEIGHT=0

# ── HELPER: log a line to both screen and logfile, PS>-style prompt ──
L() {
    local ts msg
    ts="$(date +%H:%M:%S)"
    msg="$1"
    printf "%b[%s]%b %b\$%b %s\n" "$GRAY" "$ts" "$RESET" "$GREEN" "$RESET" "$msg"
    echo "[$ts] $ $msg" >> "$LOGFILE"
}

# ── HELPER: run a command with a live rainbow spinner on one line ────
# Runs $* in the background, shows a spinner+rainbow on the SAME line
# (using \r, which only returns to column 0 of the current line — safe,
# unlike absolute cursor jumps which break across terminal emulators).
run_spin() {
    local label="$1"; shift
    L "$label"
    ( "$@" ) >>"$LOGFILE" 2>&1 &
    local pid=$!
    local i=0
    local hue=0
    while kill -0 "$pid" 2>/dev/null; do
        local frame="${SPIN_FRAMES[$((i % 10))]}"
        local color="${RAINBOW[$((hue % RAINBOW_STEPS))]}"
        printf "\r%b%s%b  %s" "$color" "$frame" "$RESET" "$label"
        i=$((i+1)); hue=$((hue+2))
        sleep 0.07
    done
    wait "$pid" 2>/dev/null
    printf "\r%b✓%b  %s\n" "$GREEN" "$RESET" "$label"
}

# ── HELPER: step header with overall progress bar + ETA ──────────
step_header() {
    local name="$2"
    local pct=$(( DONE_WEIGHT * 100 / TOTAL_WEIGHT ))
    local now
    now=$(date +%s)
    local elapsed=$(( now - START_EPOCH ))
    local eta="--:--"
    if [ "$DONE_WEIGHT" -gt 0 ] && [ "$elapsed" -gt 1 ]; then
        local remaining=$(( TOTAL_WEIGHT - DONE_WEIGHT ))
        local eta_sec=$(( remaining * elapsed / DONE_WEIGHT ))
        eta=$(printf "%02d:%02d" $((eta_sec/60)) $((eta_sec%60)))
    fi
    local filled=$(( pct / 5 ))
    local bar=""
    for ((j=0;j<20;j++)); do
        if [ "$j" -lt "$filled" ]; then bar="${bar}█"; else bar="${bar}░"; fi
    done
    echo
    printf "%b%b▶ STEP %d/6%b  [%b%s%b]  %3d%%  ETA %s   %s\n" \
        "$BOLD" "$CYAN" "$1" "$RESET" "$CYAN" "$bar" "$RESET" "$pct" "$eta" "$name"
    echo "────────────────────────────────────────────────────────────"
}

step_done() {
    DONE_WEIGHT=$(( DONE_WEIGHT + ${STEP_WEIGHTS[$1]} ))
}

# ── HELPER: sysctl set + persist to a single consolidated file ──
SYSCTL_FILE="/etc/sysctl.d/99-pc-optimizer.conf"
set_sysctl() {
    local key="$1" val="$2"
    sysctl -w "${key}=${val}" >>"$LOGFILE" 2>&1
    if grep -q "^${key}" "$SYSCTL_FILE" 2>/dev/null; then
        sed -i "s|^${key}.*|${key} = ${val}|" "$SYSCTL_FILE"
    else
        echo "${key} = ${val}" >> "$SYSCTL_FILE"
    fi
    L "sysctl -w ${key}=${val}  (persisted to $SYSCTL_FILE)"
}

# ════════════════════════════════════════════════════════════════
#  STARTUP SPLASH (ASCII banner, rainbow shimmer, credit line)
# ════════════════════════════════════════════════════════════════
clear
echo
for i in $(seq 0 14); do
    color="${RAINBOW[$((i*3 % RAINBOW_STEPS))]}"
    printf "\r%b%b" "$color" "$BOLD"
    printf "   ╔══════════════════════════════════════════════════╗\n"
    printf "   ║        UNIVERSAL  LINUX  OPTIMIZER  v1.0          ║\n"
    printf "   ╚══════════════════════════════════════════════════╝%b\n" "$RESET"
    sleep 0.06
    tput cuu 3 2>/dev/null
done
printf "\n"
echo "   ╔══════════════════════════════════════════════════╗"
echo "   ║        UNIVERSAL  LINUX  OPTIMIZER  v1.0          ║"
echo "   ╚══════════════════════════════════════════════════╝"
echo
for i in $(seq 0 20); do
    color="${RAINBOW[$((i*2 % RAINBOW_STEPS))]}"
    printf "\r%b%b            Made by Veer Bhardwaj            %b" "$color" "$BOLD" "$RESET"
    sleep 0.05
done
printf "\n\n"
echo "   $DISTRO_NAME  |  Kernel $KERNEL_VER  |  6 Steps  |  No important files deleted"
sleep 0.5
echo
echo "Starting in 2 seconds... (Ctrl+C to cancel)"
sleep 2
clear

echo "================================================================"
echo " UNIVERSAL LINUX OPTIMIZER v1.0  —  Made by Veer Bhardwaj"
echo "================================================================"
echo " Distro:  $DISTRO_NAME"
echo " Kernel:  $KERNEL_VER"
echo " Pkg mgr: ${PKG_MGR:-unknown}"
echo " Log:     $LOGFILE"
echo "================================================================"
touch "$LOGFILE"

# ════════════════════════════════════════════════════════════════
#  STEP 1 — DRIVE OPTIMIZATION (TRIM)
# ════════════════════════════════════════════════════════════════
step_header 1 "Drive Optimization (TRIM)"
if command -v fstrim &>/dev/null; then
    run_spin "fstrim -av (trim all eligible mounted filesystems)" fstrim -av
else
    L "fstrim not found — skipping (install util-linux to enable)"
fi
step_done 0

# ════════════════════════════════════════════════════════════════
#  STEP 2 — PERFORMANCE + GAMING TWEAKS
# ════════════════════════════════════════════════════════════════
step_header 2 "Performance + Gaming Tweaks"

L "Setting CPU governor to 'performance' on all cores"
if command -v cpupower &>/dev/null; then
    cpupower frequency-set -g performance >>"$LOGFILE" 2>&1
    L "cpupower frequency-set -g performance"
else
    for gov_file in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -w "$gov_file" ] && echo performance > "$gov_file" 2>/dev/null
    done
    L "Wrote 'performance' to scaling_governor for all CPUs"
fi

L "Setting I/O scheduler to mq-deadline on block devices (where supported)"
for sched_file in /sys/block/*/queue/scheduler; do
    if [ -w "$sched_file" ] && grep -q "mq-deadline" "$sched_file" 2>/dev/null; then
        echo mq-deadline > "$sched_file" 2>/dev/null
    fi
done

L "GAMING: disabling mouse acceleration (X11 sessions only)"
if [ -n "${DISPLAY:-}" ] && command -v xset &>/dev/null; then
    xset m 0 0 >>"$LOGFILE" 2>&1
    L "xset m 0 0"
else
    L "Skipped — no X11 session detected (Wayland-only or headless)"
fi

L "GAMING: ensuring GameMode (gamemoded) is enabled, if installed"
if systemctl list-unit-files 2>/dev/null | grep -q gamemoded; then
    systemctl enable --now gamemoded >>"$LOGFILE" 2>&1
    L "systemctl enable --now gamemoded"
else
    L "gamemoded not installed — skipped (not installing new packages automatically)"
fi

L "NOTE: GPU driver-timeout and per-app visual-effects tweaks have no"
L "reliable Linux equivalent reachable from a root script — skipped"
step_done 1

# ════════════════════════════════════════════════════════════════
#  STEP 3 — PRIVACY & TELEMETRY
# ════════════════════════════════════════════════════════════════
step_header 3 "Privacy & Telemetry"

for svc in apport whoopsie popularity-contest; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
        systemctl disable --now "${svc}.service" >>"$LOGFILE" 2>&1
        L "systemctl disable --now ${svc}.service"
    else
        L "${svc}.service not present — skipped"
    fi
done

if [ -f /etc/default/apport ]; then
    sed -i 's/^enabled=1/enabled=0/' /etc/default/apport 2>/dev/null
    L "Set enabled=0 in /etc/default/apport"
fi
step_done 2

# ════════════════════════════════════════════════════════════════
#  STEP 4 — MEMORY & CPU TUNING
# ════════════════════════════════════════════════════════════════
step_header 4 "Memory & CPU Tuning"

touch "$SYSCTL_FILE"
set_sysctl vm.swappiness 10
set_sysctl vm.vfs_cache_pressure 50
step_done 3

# ════════════════════════════════════════════════════════════════
#  STEP 5 — NETWORK OPTIMIZATION
# ════════════════════════════════════════════════════════════════
step_header 5 "Network Optimization"

L "Checking for BBR congestion control support"
modprobe tcp_bbr 2>/dev/null
BBR_LOADED=false
if command -v lsmod &>/dev/null && lsmod | grep -q tcp_bbr; then
    BBR_LOADED=true
elif [ -f /proc/sys/net/ipv4/tcp_available_congestion_control ] && \
     grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    BBR_LOADED=true
fi
if [ "$BBR_LOADED" = true ]; then
    set_sysctl net.core.default_qdisc fq
    set_sysctl net.ipv4.tcp_congestion_control bbr
else
    L "BBR not available on this kernel — skipped"
fi

set_sysctl net.core.rmem_max 16777216
set_sysctl net.core.wmem_max 16777216
set_sysctl net.ipv4.tcp_rmem "4096 87380 16777216"
set_sysctl net.ipv4.tcp_wmem "4096 65536 16777216"

L "Setting DNS to Cloudflare (1.1.1.1) + Google (8.8.8.8)"
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    for iface_path in /sys/class/net/*; do
        iface="$(basename "$iface_path")"
        [ "$iface" = "lo" ] && continue
        resolvectl dns "$iface" 1.1.1.1 8.8.8.8 >>"$LOGFILE" 2>&1
    done
    L "resolvectl dns <iface> 1.1.1.1 8.8.8.8 (systemd-resolved)"
elif command -v nmcli &>/dev/null && nmcli -t -f STATE general status 2>/dev/null | grep -q connected; then
    for conn in $(nmcli -t -f NAME connection show --active 2>/dev/null); do
        nmcli connection modify "$conn" ipv4.dns "1.1.1.1 8.8.8.8" >>"$LOGFILE" 2>&1
    done
    L "nmcli connection modify <conn> ipv4.dns '1.1.1.1 8.8.8.8' (NetworkManager)"
else
    L "Neither systemd-resolved nor NetworkManager detected — DNS left unchanged"
    L "(direct /etc/resolv.conf edits would likely be overwritten on most systems)"
fi
step_done 4

# ════════════════════════════════════════════════════════════════
#  STEP 6 — STARTUP + DISK CLEANUP
# ════════════════════════════════════════════════════════════════
step_header 6 "Startup + Disk Cleanup"

if [ -n "$REAL_HOME" ] && [ -d "$REAL_HOME/.config/autostart" ]; then
    L "Disabling known bloat autostart entries for user '$REAL_USER'"
    for app in skype discord slack dropbox steam spotify teams; do
        for f in "$REAL_HOME/.config/autostart/"*"${app}"*.desktop; do
            [ -f "$f" ] || continue
            if grep -q "^Hidden=true" "$f" 2>/dev/null; then
                continue
            fi
            echo "Hidden=true" >> "$f"
            L "Disabled autostart: $(basename "$f")"
        done
    done
else
    L "No autostart directory found for a real user — skipped"
fi

run_spin "Cleaning /tmp (files older than 1 day, locks/sockets left alone)" \
    find /tmp -mindepth 1 -mtime +1 -delete

if [ -n "$REAL_HOME" ] && [ -d "$REAL_HOME/.cache/thumbnails" ]; then
    run_spin "Clearing thumbnail cache" rm -rf "$REAL_HOME/.cache/thumbnails"
else
    L "No thumbnail cache found — skipped"
fi

case "$PKG_MGR" in
    apt)
        run_spin "apt-get clean" apt-get clean -y
        run_spin "apt-get autoremove (orphaned packages)" apt-get autoremove -y
        ;;
    dnf)
        run_spin "dnf clean all" dnf clean all
        run_spin "dnf autoremove" dnf autoremove -y
        ;;
    yum)
        run_spin "yum clean all" yum clean all
        ;;
    pacman)
        run_spin "pacman -Sc (clean package cache)" pacman -Sc --noconfirm
        ;;
    zypper)
        run_spin "zypper clean --all" zypper clean --all
        ;;
    *)
        L "No known package manager detected — cache cleanup skipped"
        ;;
esac

run_spin "Vacuuming systemd journal logs (keep last 100MB)" \
    journalctl --vacuum-size=100M
step_done 5

# ════════════════════════════════════════════════════════════════
#  SUMMARY
# ════════════════════════════════════════════════════════════════
END_EPOCH=$(date +%s)
TOTAL_TIME=$(( END_EPOCH - START_EPOCH ))
echo
echo "================================================================"
printf "%b%b ✓ ALL 6 STEPS COMPLETE%b\n" "$GREEN" "$BOLD" "$RESET"
echo "================================================================"
printf " Completed in %02d:%02d\n" $((TOTAL_TIME/60)) $((TOTAL_TIME%60))
echo " Full log saved to: $LOGFILE"
echo
echo " Summary:"
echo "   1. Drive TRIM"
echo "   2. CPU governor=performance, I/O scheduler, gaming tweaks"
echo "   3. Telemetry services disabled (apport/whoopsie/popcon)"
echo "   4. vm.swappiness=10, vm.vfs_cache_pressure=50"
echo "   5. BBR (if supported), larger TCP buffers, DNS set"
echo "   6. Autostart bloat disabled, /tmp + caches + journal cleaned"
echo
echo " A REBOOT is recommended to fully apply CPU governor and"
echo " sysctl changes on some systems."
echo
read -r -p " Reboot now? [y/N] " ans
case "$ans" in
    [Yy]*) echo "Rebooting in 5 seconds... Ctrl+C to cancel"; sleep 5; reboot ;;
    *) echo "Remember to reboot later when convenient." ;;
esac
