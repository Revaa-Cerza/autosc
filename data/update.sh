#!/bin/bash
# Autoscript updater.
#
# Design goals, in response to how the previous updater failed in practice:
#
#   * Atomic. Everything is downloaded to a staging directory and validated
#     first. Files are only installed once every download succeeded, so a
#     connection that drops halfway can no longer leave `menu` as a 0-byte file
#     and lock the operator out of the panel.
#   * Validated. `wget -O` truncates its target before writing, so a 404 or a
#     captive portal silently produces an empty or HTML file. Each artifact is
#     checked for non-zero size, and shell scripts must additionally parse with
#     `bash -n` before they are allowed near /usr/bin.
#   * Resumable and reversible. The previously installed files are copied to a
#     timestamped backup, and any failure during install rolls them back.
#   * Version-aware. Migration steps that only make sense once (installing
#     packages, rewriting /root/.profile) are keyed to the version actually
#     installed instead of being replayed on every single update.
#
# Usage:
#   update            normal update, skips if already on the latest version
#   update --force    reinstall even when the version already matches
#   update --check    report whether an update is available, change nothing
#   update --rollback restore the most recent backup

set -uo pipefail

REPO="https://raw.githubusercontent.com/Revaa-Cerza/autosc/main"
VER_FILE="/opt/.ver"
BACKUP_ROOT="/var/backups/autosc"
STAGING=""

###########- COLOR CODE -##############
colornow=$(cat /etc/yudhynetwork/theme/color.conf 2>/dev/null)
NC="\e[0m"
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
COLOR1="$(cat "/etc/yudhynetwork/theme/$colornow" 2>/dev/null | grep -w "TEXT" | cut -d: -f2 | sed 's/ //g')"
COLBG1="$(cat "/etc/yudhynetwork/theme/$colornow" 2>/dev/null | grep -w "BG" | cut -d: -f2 | sed 's/ //g')"
WH='\033[1;37m'
[ -z "$COLOR1" ] && COLOR1="$GREEN"
#######################################

info()  { echo -e " ${COLOR1}[INFO]${NC} $*"; }
warn()  { echo -e " ${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e " ${RED}[ERROR]${NC} $*"; }
ok()    { echo -e " ${GREEN}[ OK ]${NC} $*"; }

cleanup() {
    [ -n "$STAGING" ] && [ -d "$STAGING" ] && rm -rf "$STAGING"
}
trap cleanup EXIT

# --------------------------------------------------------------------------- #
# manifest: what an update consists of
#
#   <destination>|<source path in repo>|<mode>
# Scripts land in /usr/bin, are syntax-checked, and made executable.
# --------------------------------------------------------------------------- #
read -r -d '' MANIFEST <<'EOF'
/usr/bin/menu|data/menu.sh|script
/usr/bin/menu-ssh|data/menu-ssh.sh|script
/usr/bin/menu-vmess|data/menu-vmess.sh|script
/usr/bin/menu-vless|data/menu-vless.sh|script
/usr/bin/menu-trojan|data/menu-trojan.sh|script
/usr/bin/menu-ss|data/menu-ss.sh|script
/usr/bin/menu-dns|data/menu-dns.sh|script
/usr/bin/menu-theme|data/menu-theme.sh|script
/usr/bin/menu-backup|data/menu-backup.sh|script
/usr/bin/menu-set|data/menu-set.sh|script
/usr/bin/menu-tcp|data/menu-tcp.sh|script
/usr/bin/menu-tor|data/menu-tor.sh|script
/usr/bin/menu-ip|data/menu-ip.sh|script
/usr/bin/menu-bot|data/menu-bot.sh|script
/usr/bin/menu-api|data/menu-api.sh|script
/usr/bin/info|data/info.sh|script
/usr/bin/restart|data/restart.sh|script
/usr/bin/rebootvps|data/rebootvps.sh|script
/usr/bin/autoboot|data/autoboot.sh|script
/usr/bin/mspeed|data/menu-speedtest.sh|script
/usr/bin/mbandwith|data/menu-bandwith.sh|script
/usr/bin/crtxray|data/crt.sh|script
/usr/bin/runcheck|data/runcheck|script
/usr/bin/xp|data/xp.sh|script
/usr/bin/update|data/update.sh|script
/usr/bin/autobackup|data/v1.1.0/autobackup.sh|script
/usr/bin/backup|data/v1.1.0/backup.sh|script
/usr/bin/restore|data/v1.1.0/restore.sh|script
/usr/bin/backup_setting|data/v1.1.0/bset.sh|script
/usr/bin/hidessh|data/addons/hidessh/hidessh|script
/usr/local/bin/add-ssh-user|data/addons/hidessh/newhide/add-ssh-user|script
/usr/local/bin/del-ssh-user|data/addons/hidessh/newhide/del-ssh-user|script
/root/profile/profile2|data/profile2|data
/root/profile/wc|data/wc|data
/root/profile/art|data/art|data
EOF

fetch() {
    # fetch <url> <destination>; returns non-zero and leaves nothing behind on
    # failure, unlike `wget -O` which truncates its target first.
    local url="$1" dest="$2" tmp="$2.part"
    rm -f "$tmp"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 2 --retry-delay 1 --connect-timeout 10 --max-time 60 -o "$tmp" "$url" 2>/dev/null
    else
        wget -q --tries=2 --timeout=15 -O "$tmp" "$url" 2>/dev/null
    fi
    local rc=$?
    if [ $rc -ne 0 ] || [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$dest"
    return 0
}

remote_version() {
    local tmp
    tmp=$(mktemp)
    if fetch "$REPO/data/version" "$tmp"; then
        tr -d ' \t\r\n' < "$tmp"
    fi
    rm -f "$tmp"
}

local_version() {
    if [ -s "$VER_FILE" ]; then
        tr -d ' \t\r\n' < "$VER_FILE"
    else
        echo "0.0.0"
    fi
}

# Numeric version compare: prints 0 if equal, 1 if $1 > $2, 2 if $1 < $2.
# The menu used a string comparison, which ranks 1.10.0 below 1.9.0.
vercmp() {
    local a="${1:-0}" b="${2:-0}"
    if [ "$a" = "$b" ]; then echo 0; return; fi
    local first
    first=$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n1)
    if [ "$first" = "$a" ]; then echo 2; else echo 1; fi
}

version_lt() { [ "$(vercmp "$1" "$2")" = "2" ]; }

# --------------------------------------------------------------------------- #
# phase 1: download everything into staging
# --------------------------------------------------------------------------- #
download_all() {
    local failed=0 total=0 done=0
    total=$(echo "$MANIFEST" | grep -c '|')

    while IFS='|' read -r dest src kind; do
        [ -z "$dest" ] && continue
        local target="$STAGING/files/${dest#/}"
        mkdir -p "$(dirname "$target")"
        if fetch "$REPO/$src" "$target"; then
            done=$((done + 1))
            printf "\r ${COLOR1}[INFO]${NC} Downloading %d/%d ..." "$done" "$total"
        else
            printf "\r\033[K"
            err "Failed to download $src"
            failed=$((failed + 1))
            # Stop after a few consecutive failures rather than retrying every
            # remaining file: when the network is down this is the difference
            # between failing in seconds and hanging for minutes.
            if [ $failed -ge 3 ]; then
                err "Too many download failures, aborting early."
                break
            fi
        fi
    done <<< "$MANIFEST"
    printf "\r\033[K"

    if [ $failed -gt 0 ]; then
        err "Update aborted. Nothing on this system was changed."
        return 1
    fi
    ok "Downloaded $done file(s)"
    return 0
}

# --------------------------------------------------------------------------- #
# phase 2: validate staged files before letting them near /usr/bin
# --------------------------------------------------------------------------- #
validate_all() {
    local bad=0
    while IFS='|' read -r dest src kind; do
        [ -z "$dest" ] && continue
        local target="$STAGING/files/${dest#/}"

        if [ ! -s "$target" ]; then
            err "Empty file: $dest"
            bad=$((bad + 1)); continue
        fi

        # A captive portal or GitHub error page is valid text but not a script.
        if head -c 200 "$target" | grep -qiE '<!doctype html|<html'; then
            err "Got an HTML page instead of $src (proxy or network portal?)"
            bad=$((bad + 1)); continue
        fi

        if [ "$kind" = "script" ]; then
            case "$(head -c 2 "$target")" in
                '#!') ;;
                *) # Not every helper carries a shebang; only reject if it also
                   # fails to parse, which the next check covers.
                   ;;
            esac
            if ! bash -n "$target" 2>/dev/null; then
                err "Syntax error in downloaded $src"
                bad=$((bad + 1)); continue
            fi
        fi
    done <<< "$MANIFEST"

    if [ $bad -gt 0 ]; then
        err "$bad file(s) failed validation. Nothing was changed."
        return 1
    fi
    ok "Validated all files"
    return 0
}

# --------------------------------------------------------------------------- #
# phase 3: back up, then install; roll back on any failure
# --------------------------------------------------------------------------- #
BACKUP_DIR=""

make_backup() {
    BACKUP_DIR="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    while IFS='|' read -r dest src kind; do
        [ -z "$dest" ] && continue
        if [ -f "$dest" ]; then
            mkdir -p "$BACKUP_DIR/$(dirname "${dest#/}")"
            cp -p "$dest" "$BACKUP_DIR/${dest#/}" 2>/dev/null
        fi
    done <<< "$MANIFEST"
    echo "$(local_version)" > "$BACKUP_DIR/.version"
    ok "Backed up current files to $BACKUP_DIR"

    # Keep the five most recent backups.
    ls -1dt "$BACKUP_ROOT"/*/ 2>/dev/null | tail -n +6 | xargs -r rm -rf
}

restore_backup() {
    local dir="$1"
    [ -d "$dir" ] || { err "Backup not found: $dir"; return 1; }
    local n=0
    while IFS='|' read -r dest src kind; do
        [ -z "$dest" ] && continue
        if [ -f "$dir/${dest#/}" ]; then
            mkdir -p "$(dirname "$dest")"
            cp -p "$dir/${dest#/}" "$dest" && n=$((n + 1))
            [ "$kind" = "script" ] && chmod +x "$dest"
        fi
    done <<< "$MANIFEST"
    [ -s "$dir/.version" ] && cp "$dir/.version" "$VER_FILE"
    ok "Restored $n file(s) from $dir"
}

install_all() {
    local n=0
    while IFS='|' read -r dest src kind; do
        [ -z "$dest" ] && continue
        local target="$STAGING/files/${dest#/}"
        mkdir -p "$(dirname "$dest")"
        if ! cp "$target" "$dest"; then
            err "Failed to install $dest -- rolling back"
            restore_backup "$BACKUP_DIR"
            return 1
        fi
        if [ "$kind" = "script" ]; then
            chmod +x "$dest"
        else
            chmod 755 "$dest"
        fi
        n=$((n + 1))
    done <<< "$MANIFEST"
    ok "Installed $n file(s)"
    return 0
}

# --------------------------------------------------------------------------- #
# phase 4: migrations, each guarded by the version it belongs to
# --------------------------------------------------------------------------- #
run_migrations() {
    local from="$1"

    if version_lt "$from" "1.0.6"; then
        info "Migration 1.0.6: speedtest CLI"
        local t="$STAGING/speedtest.sh"
        fetch "$REPO/data/speedtest.sh" "$t" && bash "$t" >/dev/null 2>&1
    fi

    if version_lt "$from" "1.0.9"; then
        info "Migration 1.0.9: login profile"
        mkdir -p /root/profile
        fetch "$REPO/data/profile" /root/.profile
    fi

    if version_lt "$from" "1.1.0"; then
        info "Migration 1.1.0: backup dependencies"
        mkdir -p /etc/lukman
        local t="$STAGING/deps.sh"
        fetch "$REPO/data/v1.1.0/dependencies.sh" "$t" && bash "$t" >/dev/null 2>&1
    fi

    if version_lt "$from" "1.1.1"; then
        info "Migration 1.1.1: server location cache"
        local t="$STAGING/city.sh"
        fetch "$REPO/data/v1.1.1/city.sh" "$t" && bash "$t" >/dev/null 2>&1
    fi

    if version_lt "$from" "1.1.4"; then
        info "Migration 1.1.4: region checker"
        cat > /usr/bin/regionchecker <<'RC'
#!/bin/bash
echo "0" | bash <(curl -L -a https://raw.githubusercontent.com/lmc999/RegionRestrictionCheck/main/check.sh) -E en -M 4
read -n 1 -s -r -p "  Press any key to go back"
menu-set
RC
        chmod +x /usr/bin/regionchecker
    fi

    if version_lt "$from" "1.2.0"; then
        info "Migration 1.2.0: REST API and documentation"
        local t="$STAGING/ins-api.sh"
        if fetch "$REPO/data/api/ins-api.sh" "$t"; then
            bash "$t"
        else
            warn "Could not install the API; run 'update --force' later to retry"
        fi
    fi

    # The API server and its docs are refreshed on every update so fixes land
    # without needing a version bump.
    if [ -f /usr/local/bin/autosc-api ]; then
        local t="$STAGING/autosc-api"
        if fetch "$REPO/data/api/autosc-api.py" "$t" && python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$t" 2>/dev/null; then
            cp "$t" /usr/local/bin/autosc-api && chmod +x /usr/local/bin/autosc-api
            mkdir -p /usr/local/lib/autosc-api
            fetch "$REPO/data/api/openapi.json" /usr/local/lib/autosc-api/openapi.json
            [ -d /home/vps/public_html/docs ] && fetch "$REPO/data/api/docs-index.html" /home/vps/public_html/docs/index.html
            systemctl restart autosc-api >/dev/null 2>&1
            ok "Refreshed the API service"
        fi
    fi
}

# --------------------------------------------------------------------------- #
# entry points
# --------------------------------------------------------------------------- #
banner() {
clear
echo -e "$COLOR1┌─────────────────────────────────────────────────┐${NC}"
echo -e "$COLOR1 ${NC} ${COLBG1}            ${WH}• UPDATE SCRIPT VPS •              ${NC} $COLOR1 $NC"
echo -e "$COLOR1└─────────────────────────────────────────────────┘${NC}"
echo -e "$COLOR1┌─────────────────────────────────────────────────┐${NC}"
}

footer() {
echo -e "$COLOR1└─────────────────────────────────────────────────┘${NC}"
echo -e "$COLOR1┌────────────────────── ${WH}BY${NC} ${COLOR1}───────────────────────┐${NC}"
echo -e "$COLOR1 ${NC}                 ${WH}• LawNetwork •${NC}                 $COLOR1 $NC"
echo -e "$COLOR1└─────────────────────────────────────────────────┘${NC}"
}

do_rollback() {
    banner
    local latest
    latest=$(ls -1dt "$BACKUP_ROOT"/*/ 2>/dev/null | head -n1)
    if [ -z "$latest" ]; then
        err "No backup available to restore"
        footer
        exit 1
    fi
    info "Restoring $latest"
    restore_backup "$latest"
    ok "Rollback complete. Version is now $(local_version)"
    footer
    exit 0
}

do_check() {
    local remote current
    remote=$(remote_version)
    current=$(local_version)
    banner
    if [ -z "$remote" ]; then
        err "Cannot reach the update server"
        footer
        exit 1
    fi
    echo -e "$COLOR1 ${NC} ${WH}Installed ${COLOR1}: ${WH}$current${NC}"
    echo -e "$COLOR1 ${NC} ${WH}Available ${COLOR1}: ${WH}$remote${NC}"
    if version_lt "$current" "$remote"; then
        echo -e "$COLOR1 ${NC} ${GREEN}Update tersedia. Jalankan: update${NC}"
    else
        echo -e "$COLOR1 ${NC} ${WH}Sudah versi terbaru${NC}"
    fi
    footer
    exit 0
}

main() {
    local force=0
    case "${1:-}" in
        --check|-c)    do_check ;;
        --rollback|-r) do_rollback ;;
        --force|-f)    force=1 ;;
        --help|-h)
            echo "Usage: update [--check|--force|--rollback]"
            exit 0 ;;
    esac

    if [ "$(id -u)" -ne 0 ]; then
        err "This updater must run as root"
        exit 1
    fi

    banner

    local current remote
    current=$(local_version)
    remote=$(remote_version)

    if [ -z "$remote" ]; then
        err "Cannot reach the update server. Check your connection and try again."
        footer
        exit 1
    fi

    info "Installed version : $current"
    info "Latest version    : $remote"

    if [ $force -eq 0 ] && ! version_lt "$current" "$remote"; then
        ok "Already up to date"
        footer
        echo ""
        read -n 1 -s -r -p "  Press any key to go back"
        exit 0
    fi

    STAGING=$(mktemp -d /tmp/autosc-update.XXXXXX)
    mkdir -p "$STAGING/files"

    download_all || { footer; exit 1; }
    validate_all || { footer; exit 1; }

    mkdir -p "$BACKUP_ROOT"
    make_backup
    install_all || { footer; exit 1; }

    run_migrations "$current"

    echo "$remote" > "$VER_FILE"

    echo ""
    ok "Updated from $current to $remote"
    info "Backup kept at $BACKUP_DIR"
    info "Revert anytime with: update --rollback"
    footer
    echo ""
    read -n 1 -s -r -p "  Press any key to go back"
}

main "$@"
