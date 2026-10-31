#!/usr/bin/env bash
# headset-surround-linux
# Virtual 7.1 surround + Dolby-like "Cinema" mode for any headset on Linux (PipeWire),
# plus optional headsetcontrol, dark-mode fix and Hyprland volume keys.
# Herhangi bir kulaklik icin Linux'ta (PipeWire) sanal 7.1 surround + Dolby benzeri "Sinema" modu.
#
#   curl -fsSL https://raw.githubusercontent.com/gok8lp/headset-surround-linux/main/install.sh | bash
#
# SPDX-License-Identifier: MIT
set -euo pipefail

VERSION="1.1.0"
SOFA_URL="https://raw.githubusercontent.com/hoene/libmysofa/main/share/MIT_KEMAR_normal_pinna.sofa"

CFG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
CONF_DIR="$CFG_HOME/pipewire/filter-chain.conf.d"
DATA_DIR="$DATA_HOME/headset-surround"
BACKUP_DIR="$DATA_DIR/backup"
STATE_FILE="$DATA_DIR/state"
UNIT_DIR="$CFG_HOME/systemd/user"
OWN_UNIT="headset-surround.service"
F_SURR="$CONF_DIR/60-headset-surround.conf"
F_CINE="$CONF_DIR/61-headset-cinema.conf"
F_BASS="$CONF_DIR/62-headset-bass.conf"
SINK_SURR="headset_surround"
SINK_CINE="headset_cinema"
SINK_BASS="headset_bass"
# earlier hand-made versions of this setup
LEGACY_FILES=("$CONF_DIR/60-g633-sanal-surround.conf" "$CONF_DIR/61-g633-sinema.conf")

DO_SURROUND=0 DO_HSC=0 DO_DARK=0 DO_HYPR=0 DO_UNINSTALL=0
DRY=0 ASSUME_YES=0 SET_DEFAULT=1 PICKED=0
DEVICE=""
VOL_STEP=2
VOL_MAX=150
LANG_TR=0
case "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" in tr*) LANG_TR=1 ;; esac

# ---------- output helpers ----------
if [ -t 1 ]; then B=$'\e[1m' G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' N=$'\e[0m'; else B="" G="" Y="" R="" N=""; fi
t() { if [ "$LANG_TR" = 1 ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }
say()  { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '%s ✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s !%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%s ✗%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
run()  { if [ "$DRY" = 1 ]; then printf '   + %s\n' "$*"; else "$@"; fi; }
have() { command -v "$1" >/dev/null 2>&1; }

TTY=""
if { : </dev/tty; } 2>/dev/null; then TTY=/dev/tty; fi

ask_yn() { # ask_yn "question" default(Y/N)
    local q=$1 def=$2 a
    if [ "$ASSUME_YES" = 1 ] || [ -z "$TTY" ]; then [ "$def" = Y ]; return; fi
    printf '%s [%s] ' "$q" "$([ "$def" = Y ] && echo Y/n || echo y/N)" >"$TTY"
    read -r a <"$TTY" || a=""
    a=${a:-$def}
    case "$a" in [YyEe]*) return 0 ;; *) return 1 ;; esac
}

usage() {
    cat <<EOF
headset-surround-linux $VERSION

Usage / Kullanim:  install.sh [options]

Components (no flag = interactive menu) / Bilesenler (bayraksiz = menu):
  --surround        Virtual 7.1 surround, Cinema (Dolby-like) and Bass Boost outputs
  --headsetcontrol  Install headsetcontrol (sidetone, LEDs, battery) via package manager
  --dark            Dark mode fix (GTK prefer-dark, GTK3 theme, Flatpak Qt apps)
  --hyprland        Hyprland volume keys: smaller step, higher max
  --all             Everything above

Options / Secenekler:
  --device SINK     Output device (sink name) to wrap; see --list-devices
  --list-devices    List output devices and exit
  --no-default      Do not make the surround output the default
  --vol-step N      Volume key step in %   (default $VOL_STEP)
  --vol-max N       Volume key maximum in % (default $VOL_MAX)
  --uninstall       Remove surround/cinema outputs and restore the default device
  --dry-run         Show what would happen, change nothing
  -y, --yes         Do not ask questions
  --lang tr|en      Message language
  -h, --help        This help

Pass options through curl:  curl -fsSL .../install.sh | bash -s -- --all
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --surround) DO_SURROUND=1 PICKED=1 ;;
        --headsetcontrol) DO_HSC=1 PICKED=1 ;;
        --dark) DO_DARK=1 PICKED=1 ;;
        --hyprland) DO_HYPR=1 PICKED=1 ;;
        --all) DO_SURROUND=1 DO_HSC=1 DO_DARK=1 DO_HYPR=1 PICKED=1 ;;
        --device) DEVICE=${2:?}; shift ;;
        --device=*) DEVICE=${1#*=} ;;
        --list-devices) LIST_ONLY=1 ;;
        --no-default) SET_DEFAULT=0 ;;
        --vol-step) VOL_STEP=${2:?}; shift ;;
        --vol-max) VOL_MAX=${2:?}; shift ;;
        --uninstall) DO_UNINSTALL=1 PICKED=1 ;;
        --dry-run) DRY=1 ;;
        -y|--yes) ASSUME_YES=1 ;;
        --lang) [ "${2:?}" = tr ] && LANG_TR=1 || LANG_TR=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "$(t "Unknown option" "Bilinmeyen secenek"): $1 (--help)" ;;
    esac
    shift
done

[ "$(id -u)" = 0 ] && die "$(t "Run as your normal user, not root (sudo is used only where needed)." "Root olarak degil, normal kullanicinla calistir (sudo yalniz gerektiginde kullanilir).")"
[ "$(uname -s)" = Linux ] || die "$(t "Linux only. On Windows/macOS use your headset vendor's app (e.g. Logitech G HUB)." "Yalniz Linux. Windows/macOS'ta ureticinin uygulamasini kullan (or. Logitech G HUB).")"
case "$VOL_STEP$VOL_MAX" in *[!0-9]*) die "--vol-step/--vol-max: integer" ;; esac

# ---------- backups / file writing ----------
backup() {
    local f=$1
    [ -e "$f" ] || return 0
    local dest
    dest="$BACKUP_DIR/$(date +%Y%m%d-%H%M%S)${f//\//_}"
    run mkdir -p "$BACKUP_DIR"
    run cp -a "$f" "$dest"
}

write_file() { # write_file path  (content on stdin)
    local f=$1 tmp
    tmp=$(mktemp)
    cat >"$tmp"
    if [ -e "$f" ] && cmp -s "$tmp" "$f"; then rm -f "$tmp"; return 0; fi
    if [ "$DRY" = 1 ]; then printf '   + write %s (%s lines)\n' "$f" "$(wc -l <"$tmp")"; rm -f "$tmp"; return 0; fi
    backup "$f"
    mkdir -p "$(dirname "$f")"
    mv "$tmp" "$f"
    chmod 644 "$f"
}

state_set() { # state_set key value
    [ "$DRY" = 1 ] && return 0
    mkdir -p "$DATA_DIR"
    touch "$STATE_FILE"
    grep -v "^$1=" "$STATE_FILE" >"$STATE_FILE.tmp" || true
    printf '%s=%s\n' "$1" "$2" >>"$STATE_FILE.tmp"
    mv "$STATE_FILE.tmp" "$STATE_FILE"
}
state_get() { [ -f "$STATE_FILE" ] && sed -n "s/^$1=//p" "$STATE_FILE" | tail -1; }

# ---------- package manager ----------
PM=""
for p in pacman apt-get dnf zypper xbps-install apk eopkg; do have "$p" && { PM=$p; break; }; done

pkg_install() { # pkg_install name...
    [ $# -gt 0 ] || return 1
    case "$PM" in
        pacman) run sudo pacman -S --needed --noconfirm "$@" ;;
        apt-get) run sudo apt-get install -y "$@" ;;
        dnf) run sudo dnf install -y "$@" ;;
        zypper) run sudo zypper --non-interactive install "$@" ;;
        xbps-install) run sudo xbps-install -y "$@" ;;
        apk) run sudo apk add "$@" ;;
        eopkg) run sudo eopkg install -y "$@" ;;
        *) return 1 ;;
    esac
}

# ---------- PipeWire / device detection ----------
need_pactl() {
    have pactl && return 0
    warn "$(t "pactl not found, trying to install it" "pactl bulunamadi, kurmayi deniyorum")"
    case "$PM" in
        pacman) pkg_install libpulse ;;
        apt-get) pkg_install pulseaudio-utils ;;
        dnf) pkg_install pulseaudio-utils ;;
        zypper) pkg_install pulseaudio-utils ;;
        xbps-install) pkg_install pulseaudio-utils ;;
        apk) pkg_install pulseaudio-utils ;;
        *) false ;;
    esac || die "$(t "Please install pactl (pulseaudio-utils / libpulse)." "Lutfen pactl kur (pulseaudio-utils / libpulse).")"
}

check_pipewire() {
    have pipewire || die "$(t "PipeWire is not installed. This tool needs PipeWire (default on most distros since 2022)." "PipeWire kurulu degil. Bu arac PipeWire gerektirir (2022'den beri cogu dagitimda varsayilan).")"
    need_pactl
    pactl info 2>/dev/null | grep -qi pipewire || die "$(t "The running sound server is not PipeWire (pipewire-pulse)." "Calisan ses sunucusu PipeWire (pipewire-pulse) degil.")"
}

# prints "name<TAB>description" for real output devices
list_sinks() {
    pactl list sinks 2>/dev/null | awk -v a="$SINK_SURR" -v b="$SINK_CINE" -v c="$SINK_BASS" '
        /^[[:space:]]*Name:/ { name=$2 }
        /^[[:space:]]*Description:/ { sub(/^[[:space:]]*Description: /,""); if (name!=a && name!=b && name!=c && name !~ /g633_(surround|sinema)/) print name "\t" $0 }'
}

pick_device() {
    if [ -n "$DEVICE" ]; then
        list_sinks | cut -f1 | grep -qxF "$DEVICE" || die "$(t "No such output device" "Boyle bir cikis cihazi yok"): $DEVICE  (--list-devices)"
        return
    fi
    local prev; prev=$(state_get device || true)
    if [ -n "$prev" ] && list_sinks | cut -f1 | grep -qxF "$prev"; then DEVICE=$prev; return; fi

    local -a names descs
    local n d
    while IFS=$'\t' read -r n d; do names+=("$n"); descs+=("$d"); done < <(list_sinks)
    [ ${#names[@]} -gt 0 ] || die "$(t "No output devices found." "Cikis cihazi bulunamadi.")"

    # prefer headsets: USB / Bluetooth / anything called headset/headphone
    local -a cand=()
    local i
    for i in "${!names[@]}"; do
        if printf '%s %s' "${names[$i]}" "${descs[$i]}" | grep -qiE 'headset|headphone|kulakl|usb|bluez'; then cand+=("$i"); fi
    done

    if [ -n "$TTY" ] && [ "$ASSUME_YES" = 0 ] && { [ ${#cand[@]} -ne 1 ] || [ ${#names[@]} -gt 1 ]; }; then
        printf '\n%s\n' "$(t "Which output is your headset?" "Kulakligin hangi cikis?")" >"$TTY"
        local def=1
        [ ${#cand[@]} -ge 1 ] && def=$(( cand[0] + 1 ))
        for i in "${!names[@]}"; do printf '  %d) %s\n' $((i + 1)) "${descs[$i]}" >"$TTY"; done
        printf '%s [%d]: ' "$(t "Number" "Numara")" "$def" >"$TTY"
        local a; read -r a <"$TTY" || a=""
        a=${a:-$def}
        case "$a" in *[!0-9]*|"") die "$(t "Invalid choice" "Gecersiz secim")" ;; esac
        [ "$a" -ge 1 ] && [ "$a" -le ${#names[@]} ] || die "$(t "Invalid choice" "Gecersiz secim")"
        DEVICE=${names[$((a - 1))]}
    elif [ ${#cand[@]} -ge 1 ]; then
        DEVICE=${names[${cand[0]}]}
    else
        DEVICE=$(pactl get-default-sink)
    fi
}

device_desc() { list_sinks | awk -F'\t' -v n="$1" '$1==n {print $2}'; }

find_sofa_plugin() {
    find /usr/lib /usr/lib64 /usr/local/lib -maxdepth 5 \( -name '*filter-graph-plugin-sofa*.so' -o -name '*filter-chain-sofa*.so' \) 2>/dev/null | head -1
}

find_sofa_file() {
    local f
    for f in "$DATA_DIR/MIT_KEMAR_normal_pinna.sofa" /usr/share/libmysofa/MIT_KEMAR_normal_pinna.sofa \
             /usr/local/share/libmysofa/MIT_KEMAR_normal_pinna.sofa /usr/share/libmysofa/default.sofa; do
        [ -r "$f" ] && { readlink -f "$f"; return 0; }
    done
    return 1
}

get_sofa_file() {
    find_sofa_file && return 0
    say "$(t "Downloading the MIT KEMAR HRTF (libmysofa, ~1 MB)" "MIT KEMAR HRTF dosyasi indiriliyor (libmysofa, ~1 MB)")" >&2
    local dest="$DATA_DIR/MIT_KEMAR_normal_pinna.sofa"
    if [ "$DRY" = 1 ]; then echo "$dest"; return 0; fi
    mkdir -p "$DATA_DIR"
    if have curl; then curl -fsSL "$SOFA_URL" -o "$dest.part" || return 1
    elif have wget; then wget -qO "$dest.part" "$SOFA_URL" || return 1
    else return 1; fi
    # SOFA files are HDF5 containers
    if [ "$(head -c 4 "$dest.part" | od -An -tx1 | tr -d ' \n')" != "89484446" ]; then rm -f "$dest.part"; return 1; fi
    mv "$dest.part" "$dest"
    echo "$dest"
}

# ---------- filter graph generation ----------
NODES="" LINKS=""
node() { NODES+="                    $1"$'\n'; }
link() { LINKS+="                    { output = \"$1\" input = \"$2\" }"$'\n'; }

# rear/side channels -> surL/surR mixers
build_rear() { # build_rear sofa_file_or_empty
    local sofa=$1 c az
    local -a order=(RL RR SL SR)
    local -A azm=([RL]=150 [RR]=210 [SL]=90 [SR]=270)
    local g='"Gain 1" = 0.6 "Gain 2" = 0.6 "Gain 3" = 0.6 "Gain 4" = 0.6'
    node "{ type = builtin label = mixer name = surL control = { $g } }"
    node "{ type = builtin label = mixer name = surR control = { $g } }"
    if [ -n "$sofa" ]; then
        local i=1
        for c in "${order[@]}"; do
            az=${azm[$c]}
            node "{ type = sofa label = spatializer name = sp$c config = { filename = \"$sofa\" } control = { \"Azimuth\" = $az.0 \"Elevation\" = 0.0 \"Radius\" = 1.0 } }"
            link "sp$c:Out L" "surL:In $i"
            link "sp$c:Out R" "surR:In $i"
            i=$((i + 1))
        done
        REAR_INPUTS='"spRL:In" "spRR:In" "spSL:In" "spSR:In"'
    else
        # no SOFA support: simple interaural time/level difference panning
        for c in "${order[@]}"; do node "{ type = builtin label = copy name = cp$c }"; done
        node "{ type = builtin label = mixer name = rsL control = { \"Gain 1\" = 1.0 \"Gain 2\" = 1.0 } }"
        node "{ type = builtin label = mixer name = rsR control = { \"Gain 1\" = 1.0 \"Gain 2\" = 1.0 } }"
        link "cpRL:Out" "rsL:In 1"; link "cpSL:Out" "rsL:In 2"
        link "cpRR:Out" "rsR:In 1"; link "cpSR:Out" "rsR:In 2"
        local s o
        for s in L R; do
            o=$([ $s = L ] && echo R || echo L)
            node "{ type = builtin label = delay name = itd$s config = { \"max-delay\" = 0.1 } control = { \"Delay (s)\" = 0.0006 } }"
            node "{ type = builtin label = bq_lowpass name = ild$s control = { \"Freq\" = 1500.0 \"Q\" = 0.7 } }"
            link "rs$o:Out" "itd$s:In"; link "itd$s:Out" "ild$s:In"
            link "rs$s:Out" "sur$s:In 1"; link "ild$s:Out" "sur$s:In 2"
        done
        REAR_INPUTS='"cpRL:In" "cpRR:In" "cpSL:In" "cpSR:In"'
    fi
    local s
    for s in L R; do
        # tame the bright, unequalised HRTF and add a little warmth
        node "{ type = builtin label = bq_highshelf name = shelf$s control = { \"Freq\" = 3500.0 \"Q\" = 0.7 \"Gain\" = -7.0 } }"
        node "{ type = builtin label = bq_lowshelf name = warm$s control = { \"Freq\" = 200.0 \"Q\" = 0.7 \"Gain\" = 2.0 } }"
        link "sur$s:Out" "shelf$s:In"; link "shelf$s:Out" "warm$s:In"
    done
}

build_graph() { # build_graph surround|cinema|bass sofa_file_or_empty
    local mode=$1 sofa=$2 s c
    NODES="" LINKS="" REAR_INPUTS=""
    for c in FL FR FC LFE; do node "{ type = builtin label = copy name = cp$c }"; done
    build_rear "$sofa"
    if [ "$mode" = surround ] || [ "$mode" = bass ]; then
        local mg='"Gain 1" = 1.0 "Gain 2" = 0.7 "Gain 3" = 0.5 "Gain 4" = 1.0'
        for s in L R; do
            node "{ type = builtin label = mixer name = mix$s control = { $mg } }"
            link "cpF$s:Out" "mix$s:In 1"; link "cpFC:Out" "mix$s:In 2"
            link "cpLFE:Out" "mix$s:In 3"; link "warm$s:Out" "mix$s:In 4"
        done
        OUTPUTS='"mixL:Out" "mixR:Out"'
        if [ "$mode" = bass ]; then
            # heavy bass: -9 dB headroom first so the boost does not clip, then
            # +10 dB low shelf, +5 dB sub peak, a small mud cut and +3 dB makeup on top
            for s in L R; do
                node "{ type = builtin label = mixer name = pre$s control = { \"Gain 1\" = 0.35 } }"
                node "{ type = builtin label = bq_lowshelf name = shelfB$s control = { \"Freq\" = 90.0 \"Q\" = 0.7 \"Gain\" = 10.0 } }"
                node "{ type = builtin label = bq_peaking name = sub$s control = { \"Freq\" = 45.0 \"Q\" = 1.2 \"Gain\" = 5.0 } }"
                node "{ type = builtin label = bq_peaking name = mud$s control = { \"Freq\" = 300.0 \"Q\" = 1.0 \"Gain\" = -2.5 } }"
                node "{ type = builtin label = bq_highshelf name = air$s control = { \"Freq\" = 6000.0 \"Q\" = 0.7 \"Gain\" = 3.0 } }"
                link "mix$s:Out" "pre$s:In 1"; link "pre$s:Out" "shelfB$s:In"
                link "shelfB$s:Out" "sub$s:In"; link "sub$s:Out" "mud$s:In"; link "mud$s:Out" "air$s:In"
            done
            OUTPUTS='"airL:Out" "airR:Out"'
        fi
    else
        # crossfeed: opposite front channel, 0.3 ms later, low-passed (head shadow)
        local src o i dl
        for s in L R; do
            src=$([ $s = L ] && echo FR || echo FL)
            node "{ type = builtin label = delay name = xd$s config = { \"max-delay\" = 0.1 } control = { \"Delay (s)\" = 0.0003 } }"
            node "{ type = builtin label = bq_lowpass name = xl$s control = { \"Freq\" = 700.0 \"Q\" = 0.7 } }"
            link "cp$src:Out" "xd$s:In"; link "xd$s:Out" "xl$s:In"
        done
        # early room reflections
        for s in L R; do
            node "{ type = builtin label = mixer name = rm$s control = { \"Gain 1\" = 0.22 \"Gain 2\" = 0.16 \"Gain 3\" = 0.12 } }"
            if [ $s = L ]; then set -- FL:0.011 FR:0.017 FC:0.023; else set -- FR:0.013 FL:0.019 FC:0.029; fi
            i=1
            for o in "$@"; do
                src=${o%%:*} dl=${o#*:}
                node "{ type = builtin label = delay name = rd$s$i config = { \"max-delay\" = 0.1 } control = { \"Delay (s)\" = $dl } }"
                link "cp$src:Out" "rd$s$i:In"; link "rd$s$i:Out" "rm$s:In $i"
                i=$((i + 1))
            done
            node "{ type = builtin label = bq_lowpass name = rl$s control = { \"Freq\" = 4500.0 \"Q\" = 0.7 } }"
            link "rm$s:Out" "rl$s:In"
        done
        node '{ type = builtin label = bq_lowpass name = lfeLP control = { "Freq" = 120.0 "Q" = 0.7 } }'
        link "cpLFE:Out" "lfeLP:In"
        local mg='"Gain 1" = 0.85 "Gain 2" = 0.3 "Gain 3" = 0.7 "Gain 4" = 0.6 "Gain 5" = 1.0 "Gain 6" = 1.0'
        for s in L R; do
            node "{ type = builtin label = mixer name = mix$s control = { $mg } }"
            link "cpF$s:Out" "mix$s:In 1"; link "xl$s:Out" "mix$s:In 2"; link "cpFC:Out" "mix$s:In 3"
            link "lfeLP:Out" "mix$s:In 4"; link "warm$s:Out" "mix$s:In 5"; link "rl$s:Out" "mix$s:In 6"
            # cinema tone: +4 dB bass, slight presence
            node "{ type = builtin label = bq_lowshelf name = bass$s control = { \"Freq\" = 110.0 \"Q\" = 0.7 \"Gain\" = 4.0 } }"
            node "{ type = builtin label = bq_peaking name = pres$s control = { \"Freq\" = 2500.0 \"Q\" = 1.0 \"Gain\" = 1.5 } }"
            link "mix$s:Out" "bass$s:In"; link "bass$s:Out" "pres$s:In"
        done
        OUTPUTS='"presL:Out" "presR:Out"'
    fi
}

emit_conf() { # emit_conf mode sink_name description target sofa
    local mode=$1 sink=$2 desc=$3 target=$4 sofa=$5
    build_graph "$mode" "$sofa"
    cat <<EOF
# Generated by headset-surround-linux $VERSION ($mode) - https://github.com/gok8lp/headset-surround-linux
# HRTF: ${sofa:-none (ITD/ILD fallback)}
# Remove with: install.sh --uninstall
context.modules = [
    { name = libpipewire-module-filter-chain
        flags = [ nofail ]
        args = {
            node.description = "$desc"
            media.name       = "$desc"
            filter.graph = {
                nodes = [
${NODES}                ]
                links = [
${LINKS}                ]
                inputs  = [ "cpFL:In" "cpFR:In" "cpFC:In" "cpLFE:In" $REAR_INPUTS ]
                outputs = [ $OUTPUTS ]
            }
            capture.props = {
                node.name      = "$sink"
                media.class    = Audio/Sink
                audio.channels = 8
                audio.position = [ FL FR FC LFE RL RR SL SR ]
            }
            playback.props = {
                node.name      = "$sink.output"
                node.passive   = true
                audio.channels = 2
                audio.position = [ FL FR ]
                target.object  = "$target"
                node.dont-reconnect = true
            }
        }
    }
]
EOF
}

# ---------- filter-chain service ----------
has_systemd_user() { have systemctl && systemctl --user show-environment >/dev/null 2>&1; }

service_unit() {
    local u; u=$(state_get unit || true)
    if [ -n "$u" ]; then echo "$u"; return; fi
    if systemctl --user cat filter-chain.service >/dev/null 2>&1; then echo filter-chain.service; else echo "$OWN_UNIT"; fi
}

start_service() {
    if has_systemd_user; then
        local unit; unit=$(service_unit)
        if [ "$unit" = "$OWN_UNIT" ]; then
            write_file "$UNIT_DIR/$OWN_UNIT" <<EOF
[Unit]
Description=headset-surround-linux (PipeWire filter-chain)
After=pipewire.service pipewire-session-manager.service
BindsTo=pipewire.service

[Service]
ExecStart=$(command -v pipewire) -c filter-chain.conf
Restart=on-failure

[Install]
WantedBy=pipewire.service
EOF
            run systemctl --user daemon-reload
        fi
        state_set unit "$unit"
        run systemctl --user enable "$unit" >/dev/null 2>&1 || true
        run systemctl --user restart "$unit"
        ok "$(t "Service" "Servis"): $unit"
    else
        # non-systemd: XDG autostart + start now
        write_file "$CFG_HOME/autostart/headset-surround.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=headset-surround-linux
Exec=sh -c 'sleep 3; exec pipewire -c filter-chain.conf'
X-GNOME-Autostart-enabled=true
EOF
        state_set unit autostart
        run pkill -f 'pipewire -c filter-chain.conf' || true
        if [ "$DRY" = 0 ]; then nohup pipewire -c filter-chain.conf >/dev/null 2>&1 & fi
        warn "$(t "No systemd user session: added an XDG autostart entry. On WMs without XDG autostart (e.g. Hyprland), add: exec-once = pipewire -c filter-chain.conf" "systemd kullanici oturumu yok: XDG autostart girdisi eklendi. XDG autostart calistirmayan WM'lerde (or. Hyprland) sunu ekle: exec-once = pipewire -c filter-chain.conf")"
    fi
}

wait_sink() {
    [ "$DRY" = 1 ] && return 0
    local i
    for i in $(seq 1 20); do
        pactl list short sinks | awk '{print $2}' | grep -qxF "$1" && return 0
        sleep 0.25
    done
    return 1
}

# ---------- components ----------
install_surround() {
    say "$(t "Virtual surround + Cinema mode" "Sanal surround + Sinema modu")"
    check_pipewire
    pick_device
    local desc; desc=$(device_desc "$DEVICE")
    ok "$(t "Device" "Cihaz"): ${desc:-$DEVICE}"

    local sofa=""
    if [ -n "$(find_sofa_plugin)" ]; then
        sofa=$(get_sofa_file) || { warn "$(t "Could not get an HRTF file, using the simple fallback." "HRTF dosyasi alinamadi, basit yedek yontem kullaniliyor.")"; sofa=""; }
    else
        warn "$(t "This PipeWire build has no SOFA (HRTF) plugin; using the simple ITD/ILD fallback." "Bu PipeWire surumunde SOFA (HRTF) eklentisi yok; basit ITD/ILD yontemi kullaniliyor.")"
    fi
    [ -n "$sofa" ] && ok "HRTF: $sofa"

    # remember which outputs are new, so only those get the quiet starting volume
    local sk new_sinks=()
    for sk in "$SINK_SURR" "$SINK_CINE" "$SINK_BASS"; do
        pactl list short sinks | awk '{print $2}' | grep -qxF "$sk" || new_sinks+=("$sk")
    done

    local f
    for f in "${LEGACY_FILES[@]}"; do
        if [ -e "$f" ]; then backup "$f"; run rm -f "$f"; fi
    done
    local short=${desc:-headset}
    emit_conf surround "$SINK_SURR" "Surround 7.1 - $short" "$DEVICE" "$sofa" | write_file "$F_SURR"
    emit_conf cinema "$SINK_CINE" "Cinema / Sinema (Dolby-like) - $short" "$DEVICE" "$sofa" | write_file "$F_CINE"
    emit_conf bass "$SINK_BASS" "Bass Boost - $short" "$DEVICE" "$sofa" | write_file "$F_BASS"
    state_set device "$DEVICE"
    [ -n "$(state_get previous_default || true)" ] || state_set previous_default "$(pactl get-default-sink)"

    start_service
    wait_sink "$SINK_SURR" || die "$(t "The surround output did not appear. Check: journalctl --user -u $(service_unit)" "Surround cikisi olusmadi. Kontrol: journalctl --user -u $(service_unit)")"
    wait_sink "$SINK_CINE" || warn "$(t "Cinema output did not appear." "Sinema cikisi olusmadi.")"
    wait_sink "$SINK_BASS" || warn "$(t "Bass Boost output did not appear." "Bass Boost cikisi olusmadi.")"

    # The filters sit on top of the real device: keep the device itself at 100 % and
    # control loudness on the virtual outputs. New outputs start quiet on purpose.
    run pactl set-sink-volume "$DEVICE" 100%
    for sk in "${new_sinks[@]}"; do run pactl set-sink-volume "$sk" 30%; done
    if [ "$SET_DEFAULT" = 1 ]; then run pactl set-default-sink "$SINK_SURR"; fi
    ok "$(t "Outputs ready: 'Surround 7.1', 'Cinema (Dolby-like)' and 'Bass Boost'. Pick one in your sound settings. Volume starts at 30%, raise it slowly." "Cikislar hazir: 'Surround 7.1', 'Sinema (Dolby benzeri)' ve 'Bass Boost'. Ses ayarlarindan birini sec. Ses %30'dan baslar, yavasca ac.")"
}

uninstall_surround() {
    say "$(t "Removing surround outputs" "Surround cikislari kaldiriliyor")"
    local f any=0
    for f in "$F_SURR" "$F_CINE" "$F_BASS" "${LEGACY_FILES[@]}"; do
        if [ -e "$f" ]; then backup "$f"; run rm -f "$f"; any=1; fi
    done
    [ "$any" = 1 ] || warn "$(t "Nothing installed." "Kurulu bir sey yok.")"
    local unit; unit=$(state_get unit || true)
    if has_systemd_user; then
        unit=${unit:-$(service_unit)}
        if [ "$unit" = "$OWN_UNIT" ]; then
            run systemctl --user disable --now "$OWN_UNIT" >/dev/null 2>&1 || true
            run rm -f "$UNIT_DIR/$OWN_UNIT"
            run systemctl --user daemon-reload
        elif [ -z "$(ls -A "$CONF_DIR" 2>/dev/null)" ]; then
            run systemctl --user disable --now "$unit" >/dev/null 2>&1 || true
        else
            run systemctl --user restart "$unit"
        fi
    fi
    if [ "$unit" = autostart ]; then
        run rm -f "$CFG_HOME/autostart/headset-surround.desktop"
        run pkill -f 'pipewire -c filter-chain.conf' || true
    fi
    if have pactl; then
        local dev; dev=$(state_get device || true)
        if [ -n "$dev" ] && pactl list short sinks | awk '{print $2}' | grep -qxF "$dev"; then
            run pactl set-default-sink "$dev"
        fi
    fi
    [ "$DRY" = 1 ] || rm -f "$STATE_FILE"
    ok "$(t "Removed. Backups:" "Kaldirildi. Yedekler:") $BACKUP_DIR"
}

install_headsetcontrol() {
    say "headsetcontrol"
    if have headsetcontrol; then ok "$(t "already installed" "zaten kurulu")"; else
        case "$PM" in
            pacman|apt-get|dnf|zypper|xbps-install|apk) pkg_install headsetcontrol ;;
            *) false ;;
        esac || { warn "$(t "Not in your package manager. Build it from source:" "Paket yoneticinde yok. Kaynaktan derle:") https://github.com/Sapd/HeadsetControl"; return 0; }
        if have udevadm; then
            run sudo udevadm control --reload-rules || true
            run sudo udevadm trigger || true
        fi
    fi
    if [ "$DRY" = 0 ] && have headsetcontrol; then headsetcontrol 2>&1 | sed -n '1,3p' | sed 's/^/   /' || true; fi
    ok "$(t "Example: sidetone  headsetcontrol -s 64   (wired headsets have no battery readout)" "Ornek: kendi sesini duyma  headsetcontrol -s 64   (kablolu kulakliklarda pil bilgisi yok)")"
}

ini_set() { # ini_set file key value  (inside [Settings])
    local f=$1 k=$2 v=$3 tmp
    tmp=$(mktemp)
    if [ -e "$f" ]; then cp "$f" "$tmp"; else printf '[Settings]\n' >"$tmp"; fi
    grep -q '^\[Settings\]' "$tmp" || printf '[Settings]\n' >>"$tmp"
    if grep -q "^$k=" "$tmp"; then sed -i "s|^$k=.*|$k=$v|" "$tmp"; else sed -i "/^\[Settings\]/a $k=$v" "$tmp"; fi
    write_file "$f" <"$tmp"
    rm -f "$tmp"
}

theme_exists() {
    local d
    for d in "$DATA_HOME/themes" "$HOME/.themes" /usr/share/themes /usr/local/share/themes; do
        [ -d "$d/$1" ] && return 0
    done
    return 1
}

install_dark() {
    say "$(t "Dark mode" "Karanlik mod")"
    local theme=""
    if ! theme_exists adw-gtk3-dark; then
        case "$PM" in
            pacman) pkg_install adw-gtk-theme || true ;;
            dnf) pkg_install adw-gtk3-theme || true ;;
            *) true ;;
        esac
    fi
    theme_exists adw-gtk3-dark && theme=adw-gtk3-dark
    if have gsettings; then
        run gsettings set org.gnome.desktop.interface color-scheme prefer-dark || true
        [ -n "$theme" ] && { run gsettings set org.gnome.desktop.interface gtk-theme "$theme" || true; }
        ok "gsettings: prefer-dark${theme:+, $theme}"
    fi
    ini_set "$CFG_HOME/gtk-3.0/settings.ini" gtk-application-prefer-dark-theme true
    ini_set "$CFG_HOME/gtk-4.0/settings.ini" gtk-application-prefer-dark-theme true
    [ -n "$theme" ] && ini_set "$CFG_HOME/gtk-3.0/settings.ini" gtk-theme-name "$theme"
    ok "GTK 3/4 settings.ini"
    if have flatpak; then
        local app rt n=0
        while read -r app; do
            [ -n "$app" ] || continue
            rt=$(flatpak info -m "$app" 2>/dev/null | sed -n 's/^runtime=//p')
            case "$rt" in org.kde.Platform/*)
                if ! flatpak override --user --show "$app" 2>/dev/null | grep -q QT_QPA_PLATFORMTHEME; then
                    run flatpak override --user --env=QT_QPA_PLATFORMTHEME=kde "$app"
                fi
                n=$((n + 1)) ;;
            esac
        done < <(flatpak list --app --columns=application 2>/dev/null)
        ok "Flatpak Qt: $n $(t "apps" "uygulama") (QT_QPA_PLATFORMTHEME=kde)"
    fi
    ok "$(t "Restart apps to apply." "Uygulamalari yeniden baslatinca uygulanir.")"
}

install_hyprland() {
    say "Hyprland ($(t "volume keys" "ses tuslari"))"
    local dir="$CFG_HOME/hypr" changed=0 f
    # shellcheck disable=SC2088
    [ -d "$dir" ] || { warn "$(t "No ~/.config/hypr, skipping." "~/.config/hypr yok, atlaniyor.")"; return 0; }
    local maxf; maxf=$(awk -v m="$VOL_MAX" 'BEGIN { printf "%g", m / 100 }')
    # end-4 style Lua config: variables.lua { volumeStep = N, volumeMax = N }
    while IFS= read -r f; do
        local tmp; tmp=$(mktemp)
        sed -E "s/^([[:space:]]*volumeStep[[:space:]]*=[[:space:]]*)[0-9]+/\1$VOL_STEP/; s/^([[:space:]]*volumeMax[[:space:]]*=[[:space:]]*)[0-9]+/\1$VOL_MAX/" "$f" >"$tmp"
        if ! cmp -s "$tmp" "$f"; then write_file "$f" <"$tmp"; changed=1; fi
        rm -f "$tmp"
    done < <(grep -rlE --include='*.lua' '^[[:space:]]*volume(Step|Max)[[:space:]]*=' "$dir" 2>/dev/null | grep -v -E 'yedek|backup|\.bak')
    # classic hyprland.conf binds: wpctl set-volume [-l X] @DEFAULT_AUDIO_SINK@ N%+
    while IFS= read -r f; do
        local tmp; tmp=$(mktemp)
        sed -E "/wpctl set-volume/{s/(@DEFAULT_AUDIO_SINK@ )[0-9]+%([+-])/\1$VOL_STEP%\2/g; s/(set-volume -l )[0-9.]+/\1$maxf/g}" "$f" >"$tmp"
        if ! cmp -s "$tmp" "$f"; then write_file "$f" <"$tmp"; changed=1; fi
        rm -f "$tmp"
    done < <(grep -rl --include='*.conf' 'wpctl set-volume' "$dir" 2>/dev/null | grep -v -E 'yedek|backup|\.bak')
    if [ "$changed" = 1 ]; then
        have hyprctl && [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] && { run hyprctl reload >/dev/null || true; }
        ok "$(t "Volume step" "Ses adimi") $VOL_STEP%, max $VOL_MAX%"
    else
        warn "$(t "No matching volume bindings found (or already set)." "Uygun ses tusu ayari bulunamadi (ya da zaten ayarli).")"
    fi
}

# ---------- main ----------
if [ "${LIST_ONLY:-0}" = 1 ]; then
    need_pactl
    list_sinks | awk -F'\t' '{ printf "%-70s %s\n", $1, $2 }'
    exit 0
fi

printf '%sheadset-surround-linux %s%s\n' "$B" "$VERSION" "$N"
[ "$DRY" = 1 ] && warn "dry-run: $(t "nothing will be changed" "hicbir sey degistirilmeyecek")"

if [ "$PICKED" = 0 ]; then
    if [ -z "$TTY" ] || [ "$ASSUME_YES" = 1 ]; then
        DO_SURROUND=1
    else
        ask_yn "$(t "Install virtual surround + Cinema (Dolby-like) mode?" "Sanal surround + Sinema (Dolby benzeri) modu kurulsun mu?")" Y && DO_SURROUND=1
        ask_yn "$(t "Install headsetcontrol (needs sudo)?" "headsetcontrol kurulsun mu (sudo ister)?")" N && DO_HSC=1
        ask_yn "$(t "Apply the dark-mode fix?" "Karanlik mod duzeltmesi uygulansin mi?")" N && DO_DARK=1
        if [ -d "$CFG_HOME/hypr" ]; then
            ask_yn "$(t "Hyprland volume keys: step $VOL_STEP%, max $VOL_MAX%?" "Hyprland ses tuslari: adim %$VOL_STEP, en fazla %$VOL_MAX?")" N && DO_HYPR=1
        fi
    fi
fi

if [ "$DO_UNINSTALL" = 1 ]; then uninstall_surround; exit 0; fi
[ "$DO_SURROUND" = 1 ] && install_surround
[ "$DO_HSC" = 1 ] && install_headsetcontrol
[ "$DO_DARK" = 1 ] && install_dark
[ "$DO_HYPR" = 1 ] && install_hyprland
say "$(t "Done." "Bitti.")"
