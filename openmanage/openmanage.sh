#!/bin/bash
#
# openmanage.sh — Dell PowerEdge hardware monitor for Xymon
#
# version 1.0.4
#
# Client-side ext script. Uses Dell OMSA (omreport) for chassis + storage,
# and perccli/storcli when available (via direct exec or sudo -n) for a
# clearer RAID view. Designed so a failed disk, degraded VD, and background
# jobs are visible in the Xymon column without logging into the host.
#
# Long-running task ETA: client-side state file (not Xymon server / spacey).
# PD init/erase (perccli) and SCSI FORMAT-in-progress (pd-sense helper) → yellow.
#
# Column: hardware
#
# Origin: heavily rewritten from Brian Smith-Sweeney openmanage (2002) and
# local 0.5x patches. Public-domain-style reuse of concepts; new code is
# operational tooling for this environment.
#

set -u

TEST="hardware"
XYMONPROG=openmanage.sh
export XYMONPROG

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
if [ -z "${XYMONHOME:-}" ]; then
    echo "${XYMONPROG}: XYMONHOME is not set" >&2
    exit 1
fi

if [ -z "${XYMONTMP:-}" ] && [ -f "${XYMONHOME}/etc/bbdef.sh" ]; then
    # shellcheck disable=SC1090
    . "${XYMONHOME}/etc/bbdef.sh"
fi

XYMONTMP="${XYMONTMP:-/tmp}"
PATH="/opt/dell/srvadmin/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

OMREPORT="${OMREPORT:-}"
for c in /opt/dell/srvadmin/bin/omreport omreport; do
    if [ -z "$OMREPORT" ] && command -v "$c" >/dev/null 2>&1; then
        OMREPORT=$(command -v "$c" 2>/dev/null || echo "$c")
        [ -x "$c" ] && OMREPORT="$c"
    fi
    [ -n "$OMREPORT" ] && [ -x "$OMREPORT" ] && break
done
[ -z "$OMREPORT" ] && [ -x /opt/dell/srvadmin/bin/omreport ] && OMREPORT=/opt/dell/srvadmin/bin/omreport

# perccli/storcli: try direct, then sudo -n (xymon usually needs root for RAID CLI).
# IMPORTANT: as non-root, `show ctrlcount` can return Success with Controller Count=0
# (no permission to see adapters). Require count > 0, and prefer sudo -n when needed.
raid_cli_ctrlcount() {
    local cmd="$1"
    local out n
    # shellcheck disable=SC2086
    out=$(eval $cmd show ctrlcount 2>/dev/null) || return 1
    echo "$out" | grep -q "Status = Success" || return 1
    n=$(echo "$out" | awk -F'=' '
        /Controller Count/ {
            gsub(/[[:space:]]/, "", $2)
            print $2 + 0
            exit
        }')
    [ "${n:-0}" -gt 0 ]
}

find_raid_cli() {
    local p bp
    local candidates=(
        ${PERCCLI:+$PERCCLI}
        /opt/MegaRAID/perccli/perccli64
        /opt/MegaRAID/perccli/perccli
        /opt/MegaRAID/storcli/storcli64
        /opt/MegaRAID/storcli/storcli
        /usr/local/megaraid/StorCLI/storcli64
        /usr/local/bin/perccli64
        /usr/local/bin/storcli64
        /usr/sbin/perccli64
        /usr/sbin/storcli64
    )
    for p in "${candidates[@]}"; do
        [ -n "$p" ] && [ -x "$p" ] || continue
        # Prefer working direct access; else sudo -n (xymon path)
        if raid_cli_ctrlcount "$p"; then
            echo "$p"
            return 0
        fi
        if raid_cli_ctrlcount "sudo -n $p"; then
            echo "sudo -n $p"
            return 0
        fi
        # Root with binary present but ctrlcount odd — still try direct
        if [ "$(id -u)" -eq 0 ]; then
            echo "$p"
            return 0
        fi
    done
    for p in perccli64 perccli storcli64 storcli; do
        command -v "$p" >/dev/null 2>&1 || continue
        bp=$(command -v "$p")
        if raid_cli_ctrlcount "$bp"; then
            echo "$bp"
            return 0
        fi
        if raid_cli_ctrlcount "sudo -n $bp"; then
            echo "sudo -n $bp"
            return 0
        fi
    done
    return 1
}

RAIDCLI=$(find_raid_cli || true)

WORKDIR=$(mktemp -d "${XYMONTMP}/openmanage.XXXXXX")
trap 'rm -rf "$WORKDIR"' EXIT

BODY="$WORKDIR/body"
SUMMARY="$WORKDIR/summary"
touch "$BODY" "$SUMMARY"

COLOR="green"
MSGS=()

# ---------------------------------------------------------------------------
# Long-running task ETA (local state file — client only)
# Format per line: key|epoch|percent|label
# Keeps up to TASK_HIST_MAX samples per key across runs for rate averaging.
# ---------------------------------------------------------------------------
TASK_HIST_MAX=6
TASK_STATE_NEW="$WORKDIR/taskstate.new"
: >"$TASK_STATE_NEW"
: >"$WORKDIR/eta_detail"

# Prefer a persistent, xymon-writable dir; fall back to XYMONTMP (/dev/shm).
resolve_state_file() {
    local d
    if [ -n "${OPENMANAGE_STATE_FILE:-}" ]; then
        echo "$OPENMANAGE_STATE_FILE"
        return
    fi
    for d in \
        "${XYMONHOME}/tmp" \
        "${XYMONCLIENTHOME:-}/tmp" \
        /var/lib/xymon \
        /var/tmp \
        "${XYMONTMP}" \
        /tmp
    do
        [ -n "$d" ] || continue
        if [ -d "$d" ] && [ -w "$d" ]; then
            echo "${d}/openmanage-tasks.state"
            return
        fi
        if mkdir -p "$d" 2>/dev/null && [ -w "$d" ]; then
            echo "${d}/openmanage-tasks.state"
            return
        fi
    done
    echo "${XYMONTMP}/openmanage-tasks.state"
}

STATE_FILE=$(resolve_state_file)

# worst-of colour ranking
rank_of() {
    case "$1" in
        red) echo 3 ;;
        yellow) echo 2 ;;
        purple) echo 1 ;;
        *) echo 0 ;;
    esac
}

raise() {
    # raise COLOR to $1 and optionally append summary line $2
    local new="$1"
    local msg="${2:-}"
    if [ "$(rank_of "$new")" -gt "$(rank_of "$COLOR")" ]; then
        COLOR="$new"
    fi
    if [ -n "$msg" ]; then
        MSGS+=("$msg")
        case "$new" in
            red)    echo "&red $msg" >>"$SUMMARY" ;;
            yellow) echo "&yellow $msg" >>"$SUMMARY" ;;
            purple) echo "&purple $msg" >>"$SUMMARY" ;;
            *)      echo "&clear $msg" >>"$SUMMARY" ;;
        esac
    fi
}

section() {
    {
        echo ""
        echo "==============================================================================="
        echo " $1"
        echo "==============================================================================="
    } >>"$BODY"
}

# Extract leading integer percent from strings like "88%", "87% complete",
# "Consistency Check (88%)".
parse_percent() {
    echo "$1" | grep -oE '[0-9]+%' | head -1 | tr -d '%'
}

# Human duration from seconds (e.g. 4h 12m, 45m, 90s).
format_duration() {
    local sec="${1:-0}"
    local h m s
    if [ "$sec" -lt 0 ]; then
        sec=0
    fi
    h=$((sec / 3600))
    m=$(((sec % 3600) / 60))
    s=$((sec % 60))
    if [ "$h" -gt 0 ]; then
        printf '%dh %dm' "$h" "$m"
    elif [ "$m" -gt 0 ]; then
        printf '%dm' "$m"
    else
        printf '%ds' "$s"
    fi
}

# Record progress sample and raise with ETA when rate is known.
#   track_progress_task KEY LABEL PCT_STRING COLOR
# KEY should be stable for the same job (e.g. omsa-c0-vd1-cc).
track_progress_task() {
    local key="$1"
    local label="$2"
    local pct_raw="$3"
    local color="${4:-yellow}"
    local pct now eta_note samples n first_e first_p last_e last_p dt dpct
    local remain rate_note line hist_file

    pct=$(parse_percent "$pct_raw")
    now=$(date +%s)

    if [ -z "$pct" ]; then
        raise "$color" "${label}${pct_raw:+ ($pct_raw)}"
        return
    fi

    # Collect prior samples for this key + this sample
    hist_file="$WORKDIR/hist.$key"
    if [ -f "$STATE_FILE" ]; then
        grep -E "^${key}\\|" "$STATE_FILE" 2>/dev/null | tail -n "$TASK_HIST_MAX" >"$hist_file" || true
    else
        : >"$hist_file"
    fi
    echo "${key}|${now}|${pct}|${label}" >>"$hist_file"

    # Persist active history (capped) for next run
    tail -n "$TASK_HIST_MAX" "$hist_file" >>"$TASK_STATE_NEW"

    n=$(wc -l <"$hist_file" | tr -d ' ')
    eta_note=""
    rate_note=""

    if [ "$n" -lt 2 ]; then
        eta_note=" — ETA pending (first sample; next run will estimate)"
    else
        first_e=$(head -1 "$hist_file" | cut -d'|' -f2)
        first_p=$(head -1 "$hist_file" | cut -d'|' -f3)
        last_e=$(tail -1 "$hist_file" | cut -d'|' -f2)
        last_p=$(tail -1 "$hist_file" | cut -d'|' -f3)
        dt=$((last_e - first_e))
        dpct=$((last_p - first_p))

        if [ "$dt" -lt 60 ]; then
            eta_note=" — ETA pending (samples under 60s apart)"
        elif [ "$dpct" -le 0 ]; then
            eta_note=" — ETA unknown (no progress over $(format_duration "$dt"); ${first_p}%->${last_p}%)"
        elif [ "$last_p" -ge 100 ]; then
            eta_note=" — complete"
        else
            # remain_sec = (100 - last_p) * dt / dpct
            remain=$(( (100 - last_p) * dt / dpct ))
            # Cap absurd ETAs (e.g. 1% in a day → months)
            if [ "$remain" -gt 604800 ]; then
                eta_note=" — ETA over 7d (very slow: +${dpct}% in $(format_duration "$dt"))"
            else
                eta_note=" — ETA ~$(format_duration "$remain") (avg +${dpct}% in $(format_duration "$dt"))"
            fi
            rate_note="rate ~$(awk -v d="$dpct" -v t="$dt" 'BEGIN{ if(t>0) printf "%.2f", d/(t/3600); else print "0" }') %/h"
        fi
    fi

    raise "$color" "${label}: ${pct}%${eta_note}"

    # Extra detail line for the body ETA section
    {
        echo "&${color} ${label}: ${pct}%"
        [ -n "$eta_note" ] && echo "    ${eta_note# — }"
        [ -n "$rate_note" ] && echo "    ${rate_note}"
        echo "    state_file=${STATE_FILE} samples=${n}"
    } >>"$WORKDIR/eta_detail"
}

# Write pruned state (only tasks still active this run).
save_task_state() {
    if [ ! -s "$TASK_STATE_NEW" ]; then
        # No active tasks — clear state so finished jobs do not linger
        rm -f "$STATE_FILE" 2>/dev/null || true
        return
    fi
    # Atomic replace when possible
    if mv "$TASK_STATE_NEW" "$STATE_FILE" 2>/dev/null; then
        chmod 644 "$STATE_FILE" 2>/dev/null || true
    else
        cat "$TASK_STATE_NEW" >"$STATE_FILE" 2>/dev/null || true
        chmod 644 "$STATE_FILE" 2>/dev/null || true
    fi
}

# Resolve openmanage-pd-sense helper (FORMAT UNIT progress via MegaRAID passthrough).
# Needs root or sudo -n; returns command prefix or empty.
find_pd_sense_cmd() {
    local p script_dir
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)
    for p in \
        ${OPENMANAGE_PD_SENSE:+$OPENMANAGE_PD_SENSE} \
        "${script_dir}/openmanage-pd-sense" \
        "${XYMONCLIENTHOME:-}/ext/openmanage-pd-sense" \
        "${XYMONHOME:-}/ext/openmanage-pd-sense" \
        /usr/local/libexec/openmanage-pd-sense \
        /usr/share/xymon-client/ext/openmanage-pd-sense
    do
        [ -n "$p" ] && [ -x "$p" ] || continue
        if [ "$(id -u)" -eq 0 ]; then
            echo "$p"
            return 0
        fi
        # xymon: needs NOPASSWD for this helper (see sudoers.xymon-perccli.snippet)
        if sudo -n "$p" /dev/sda 0 2>/dev/null | head -1 | grep -qE '^(FORMAT_IN_PROGRESS|OK|BUSY|ERROR)'; then
            echo "sudo -n $p"
            return 0
        fi
    done
    return 1
}

# Parse perccli "show initialization|erase" for in-progress line.
# Sets globals: _PD_OP_PCT _PD_OP_ETA _PD_OP_ACTIVE (0/1)
parse_perccli_pd_op() {
    local out="$1"
    _PD_OP_ACTIVE=0
    _PD_OP_PCT=""
    _PD_OP_ETA=""
    if ! echo "$out" | grep -qi "In progress"; then
        return 1
    fi
    _PD_OP_ACTIVE=1
    # Example: /c0/e64/s11         0 In progress 18 Hours 49 Minutes
    _PD_OP_PCT=$(echo "$out" | awk '/In progress/{print $2; exit}')
    case "$_PD_OP_PCT" in
        ''|'-'|*[!0-9]*) _PD_OP_PCT="" ;;
    esac
    _PD_OP_ETA=$(echo "$out" | sed -n 's/.*In progress[[:space:]]*//p' | head -1)
    return 0
}

# Block device used for MegaRAID bus number (first PERC LD is fine).
pd_sense_blockdev() {
    for d in /dev/sda /dev/sdb /dev/sdc; do
        [ -b "$d" ] && { echo "$d"; return 0; }
    done
    echo "/dev/sda"
}

# Check one PD for init / erase / SCSI format; raise yellow + ETA when active.
# Args: eid slt did model
check_pd_long_ops() {
    local eid="$1" slt="$2" did="$3" model="${4:-}"
    local slot label out pct_str sense_cmd bdev sense_out pct
    local fmt_active=0

    slot="${eid}:${slt}"
    label="PD ${slot}"
    [ -n "$did" ] && label="$label DID $did"
    [ -n "$model" ] && [ "$model" != "-" ] && label="$label ($model)"

    # --- perccli initialization (clear) ---
    out=$(raid_run /c0/e"${eid}"/s"${slt}" show initialization 2>/dev/null || true)
    if parse_perccli_pd_op "$out"; then
        if [ -n "$_PD_OP_PCT" ]; then
            pct_str="${_PD_OP_PCT}%"
            [ -n "$_PD_OP_ETA" ] && pct_str="${pct_str} (${_PD_OP_ETA})"
            track_progress_task "perc-e${eid}-s${slt}-init" \
                "${label}: initialization / clear" "$pct_str" yellow
        else
            raise yellow "${label}: initialization / clear in progress${_PD_OP_ETA:+ — $_PD_OP_ETA}"
        fi
        printf '  %-10s init   %s\n' "$slot" "${pct_str:-in progress ${_PD_OP_ETA}}" >>"$WORKDIR/pd_ops_table"
    fi

    # --- perccli erase ---
    out=$(raid_run /c0/e"${eid}"/s"${slt}" show erase 2>/dev/null || true)
    if parse_perccli_pd_op "$out"; then
        if [ -n "$_PD_OP_PCT" ]; then
            pct_str="${_PD_OP_PCT}%"
            [ -n "$_PD_OP_ETA" ] && pct_str="${pct_str} (${_PD_OP_ETA})"
            track_progress_task "perc-e${eid}-s${slt}-erase" \
                "${label}: secure erase" "$pct_str" yellow
        else
            raise yellow "${label}: secure erase in progress${_PD_OP_ETA:+ — $_PD_OP_ETA}"
        fi
        printf '  %-10s erase  %s\n' "$slot" "${pct_str:-in progress ${_PD_OP_ETA}}" >>"$WORKDIR/pd_ops_table"
    fi

    # --- SCSI FORMAT UNIT (passthrough sense; not shown by perccli) ---
    if [ -n "${PD_SENSE_CMD:-}" ] && [ -n "$did" ]; then
        bdev=$(pd_sense_blockdev)
        # shellcheck disable=SC2086
        sense_out=$(eval $PD_SENSE_CMD "$bdev" "$did" 2>/dev/null || true)
        case "$sense_out" in
            FORMAT_IN_PROGRESS*)
                fmt_active=1
                pct=$(echo "$sense_out" | awk '{print $2}')
                case "$pct" in
                    ''|unknown|*[!0-9]*)
                        raise yellow "${label}: SCSI FORMAT in progress (low-level reformat)"
                        printf '  %-10s format in progress (%% unknown)\n' "$slot" >>"$WORKDIR/pd_ops_table"
                        ;;
                    *)
                        track_progress_task "perc-e${eid}-s${slt}-format" \
                            "${label}: SCSI FORMAT (low-level reformat)" "${pct}%" yellow
                        printf '  %-10s format %s%%\n' "$slot" "$pct" >>"$WORKDIR/pd_ops_table"
                        ;;
                esac
                # Remember slots under format so UGood noise can be suppressed
                echo "$slot" >>"$WORKDIR/pd_format_slots"
                ;;
            BUSY*)
                raise yellow "${label}: drive busy (${sense_out#BUSY })"
                printf '  %-10s busy   %s\n' "$slot" "${sense_out}" >>"$WORKDIR/pd_ops_table"
                ;;
        esac
    fi
    return 0
}

# ---------------------------------------------------------------------------
# No OMSA at all
# ---------------------------------------------------------------------------
if [ -z "$OMREPORT" ] || [ ! -x "$OMREPORT" ]; then
    COLOR="purple"
    LINE="status ${MACHINE}.${TEST} purple $(date) OMSA omreport not found
Dell OpenManage (omreport) is not installed or not executable.
Install OMSA / srvadmin-storage-cli, or remove this check from clientlaunch."
    if [ "${DRY_RUN:-0}" = "1" ]; then
        printf '%s\n' "$LINE"
    else
        $XYMON $XYMSRV "$LINE"
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------
section "Host / OMSA"
{
    echo "Hostname        : $(hostname -f 2>/dev/null || hostname)"
    echo "Time            : $(date -u '+%Y-%m-%d %H:%M:%S UTC') / $(date '+%Y-%m-%d %H:%M:%S %Z')"
    if $OMREPORT system summary 2>/dev/null | grep -q .; then
        $OMREPORT system summary 2>/dev/null \
            | awk '
                /^Chassis Model/ || /^System Model/ || /^Model/ { if (!m) { print; m=1 } }
                /Service Tag/ && !/Express/ { if (!s) { print; s=1 } }
                /^Name[[:space:]]+:.*OpenManage/ { print "OMSA            : " $0 }
                /^Version[[:space:]]+:/ && prev ~ /OpenManage|Systems Management/ { print "OMSA Version    : " $0 }
                { prev=$0 }
            ' | sed 's/[[:space:]]\{2,\}/ /g'
    fi
    echo "omreport        : $OMREPORT"
    if [ -n "$RAIDCLI" ]; then
        echo "RAID CLI        : $RAIDCLI"
    else
        echo "RAID CLI        : (not available — perccli/storcli missing or not runnable as this user)"
    fi
} >>"$BODY"

# ---------------------------------------------------------------------------
# Chassis
# ---------------------------------------------------------------------------
section "Chassis health (omreport chassis)"
CHASSIS=$WORKDIR/chassis
$OMREPORT chassis 2>/dev/null | grep -v "For further help" >"$CHASSIS" || true
cat "$CHASSIS" >>"$BODY"

# Parse SEVERITY : COMPONENT lines
while IFS= read -r line; do
    sev=$(echo "$line" | awk -F':' '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$1); print $1}')
    comp=$(echo "$line" | awk -F':' '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2}')
    [ -z "$comp" ] && continue
    case "$sev" in
        Ok|OK) ;;
        Critical)
            raise red "Chassis ${comp}: Critical"
            ;;
        Non-Critical|NonCritical)
            raise yellow "Chassis ${comp}: Non-Critical"
            ;;
        *)
            if [ "$sev" != "SEVERITY" ] && [ -n "$sev" ]; then
                raise purple "Chassis ${comp}: unknown severity '${sev}'"
            fi
            ;;
    esac
done < <(awk '/SEVERITY/{p=1; next} p && /:/{print} p && /^$/{exit}' "$CHASSIS")

# Drill-down for bad chassis components
drill_chassis() {
    local item="$1"
    case "$item" in
        Fans)          $OMREPORT chassis fans 2>/dev/null ;;
        Intrusion)     $OMREPORT chassis intrusion 2>/dev/null ;;
        Memory)        $OMREPORT chassis memory 2>/dev/null ;;
        Power|Supplies) $OMREPORT chassis pwrsupplies 2>/dev/null ;;
        "Power Management"|Management) $OMREPORT chassis pwrmanagement 2>/dev/null ;;
        Processors)    $OMREPORT chassis processors 2>/dev/null ;;
        Temperatures)  $OMREPORT chassis temps 2>/dev/null ;;
        Voltages)      $OMREPORT chassis volts 2>/dev/null ;;
        Batteries)     $OMREPORT chassis batteries 2>/dev/null ;;
        "Hardware Log"|Log|Hardware) $OMREPORT system esmlog 2>/dev/null | head -80 ;;
        Storage)       : ;; # handled in storage section
        *)             echo "(no level-3 mapping for: $item)" ;;
    esac
}

BAD_CHASSIS=$(awk -F':' '
    /SEVERITY/{p=1; next}
    p && /:/ {
        sev=$1; gsub(/^[[:space:]]+|[[:space:]]+$/,"",sev)
        comp=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",comp)
        if (sev != "" && sev != "Ok" && sev != "OK" && comp != "") print comp
    }
    p && /^$/{exit}
' "$CHASSIS")

if [ -n "$BAD_CHASSIS" ]; then
    section "Chassis detail (non-Ok components)"
    for item in $BAD_CHASSIS; do
        echo "--- $item ---" >>"$BODY"
        drill_chassis "$item" >>"$BODY"
        echo "" >>"$BODY"
    done
fi

# ---------------------------------------------------------------------------
# iDRAC DNS (best effort)
# ---------------------------------------------------------------------------
section "iDRAC network / DNS"
REMOTEACCESS=$($OMREPORT chassis remoteaccess config=network 2>/dev/null || true)
if [ -n "$REMOTEACCESS" ]; then
    IDRAC_IP=$(echo "$REMOTEACCESS" | awk -F'[[:space:]]*:[[:space:]]*' \
        '/^IP Address[[:space:]]*:/ && !/Source/ { print $2; exit }')
    IDRAC_NAME=$(echo "$REMOTEACCESS" | awk -F'[[:space:]]*:[[:space:]]*' \
        '/DNS iDRAC Name/ { print $2; exit }')
    IDRAC_DOM=$(echo "$REMOTEACCESS" | awk -F'[[:space:]]*:[[:space:]]*' \
        '/DNS Domain Name/ { print $2; exit }')
    {
        echo "iDRAC IP        : ${IDRAC_IP:-unknown}"
        echo "DNS iDRAC Name  : ${IDRAC_NAME:-unknown}"
        echo "DNS Domain      : ${IDRAC_DOM:-unknown}"
    } >>"$BODY"
    if [ -n "${IDRAC_NAME:-}" ]; then
        if [ -n "${IDRAC_DOM:-}" ]; then
            IDRAC_FQDN="${IDRAC_NAME}.${IDRAC_DOM}"
        else
            IDRAC_FQDN="$IDRAC_NAME"
        fi
        IDRAC_DNS_IP=$(getent hosts "$IDRAC_FQDN" 2>/dev/null | awk '{ print $1; exit }')
        echo "Resolved FQDN   : $IDRAC_FQDN -> ${IDRAC_DNS_IP:-FAIL}" >>"$BODY"
        if [ -z "${IDRAC_IP:-}" ]; then
            raise red "iDRAC DNS: could not parse iDRAC IP from omreport"
        elif [ -z "${IDRAC_DNS_IP:-}" ]; then
            raise red "iDRAC DNS: $IDRAC_FQDN does not resolve (iDRAC NIC $IDRAC_IP)"
        elif [ "$IDRAC_IP" != "$IDRAC_DNS_IP" ]; then
            raise red "iDRAC DNS mismatch: $IDRAC_FQDN -> $IDRAC_DNS_IP (NIC $IDRAC_IP)"
        else
            echo "iDRAC DNS check : ok" >>"$BODY"
        fi
    else
        echo "iDRAC DNS check : skipped (no DNS iDRAC Name configured)" >>"$BODY"
    fi
else
    echo "iDRAC remoteaccess not available via omreport" >>"$BODY"
fi

# ---------------------------------------------------------------------------
# Storage — OMSA
# ---------------------------------------------------------------------------
section "Storage controllers (OMSA)"

CTRL_SSV=$WORKDIR/ctrl.ssv
$OMREPORT storage controller -fmt ssv 2>/dev/null >"$CTRL_SSV" || true

controller_ids=()
if [ -s "$CTRL_SSV" ]; then
    # Header then data rows starting with numeric ID
    while IFS= read -r cid; do
        controller_ids+=("$cid")
    done < <(awk -F';' 'NR>1 && $1 ~ /^[0-9]+$/ { print $1 }' "$CTRL_SSV")
fi

# Fallback: try controller 0 if ssv empty but storage exists
if [ ${#controller_ids[@]} -eq 0 ]; then
    if $OMREPORT storage controller 2>/dev/null | grep -qi "Controller"; then
        controller_ids=(0)
    fi
fi

if [ ${#controller_ids[@]} -eq 0 ]; then
    echo "(no storage controllers reported by OMSA)" >>"$BODY"
else
    printf '%-4s %-10s %-28s %-10s %-18s %s\n' \
        "ID" "Status" "Name" "State" "Firmware" "Cache" >>"$BODY"
    printf '%-4s %-10s %-28s %-10s %-18s %s\n' \
        "----" "----------" "----------------------------" "----------" "------------------" "-----" >>"$BODY"

    for cid in "${controller_ids[@]}"; do
        cout=$WORKDIR/ctrl.$cid
        $OMREPORT storage controller controller="$cid" 2>/dev/null >"$cout" || true
        c_status=$(awk -F: '/^Status[[:space:]]*:/ {gsub(/^[[:space:]]+/,"",$2); print $2; exit}' "$cout")
        c_name=$(awk -F: '/^Name[[:space:]]*:/ {gsub(/^[[:space:]]+/,"",$2); print $2; exit}' "$cout")
        c_state=$(awk -F: '/^State[[:space:]]*:/ {gsub(/^[[:space:]]+/,"",$2); print $2; exit}' "$cout")
        c_fw=$(awk -F: '/^Firmware Version[[:space:]]*:/ {gsub(/^[[:space:]]+/,"",$2); print $2; exit}' "$cout")
        c_cache=$(awk -F: '/^Cache Memory Size[[:space:]]*:/ {gsub(/^[[:space:]]+/,"",$2); print $2; exit}' "$cout")
        printf '%-4s %-10s %-28s %-10s %-18s %s\n' \
            "$cid" "${c_status:-?}" "${c_name:-?}" "${c_state:-?}" "${c_fw:-?}" "${c_cache:-?}" >>"$BODY"

        case "${c_status:-}" in
            Ok|OK|"") ;;
            Critical) raise red "Controller $cid ($c_name): Status $c_status / State $c_state" ;;
            Non-Critical) raise yellow "Controller $cid ($c_name): Status $c_status / State $c_state" ;;
            *) raise yellow "Controller $cid ($c_name): Status $c_status / State $c_state" ;;
        esac
        case "${c_state:-}" in
            Ready|""|Ok) ;;
            *) raise yellow "Controller $cid state: $c_state" ;;
        esac

        # Battery
        bout=$WORKDIR/bat.$cid
        $OMREPORT storage battery controller="$cid" 2>/dev/null >"$bout" || true
        if grep -qi "No battery\|not present\|No Controller Battery" "$bout" 2>/dev/null; then
            :
        elif [ -s "$bout" ] && grep -q "Status" "$bout"; then
            b_status=$(awk -F: '/^Status[[:space:]]*:/ {gsub(/^[[:space:]]+/,"",$2); print $2; exit}' "$bout")
            b_state=$(awk -F: '/^State[[:space:]]*:/ {gsub(/^[[:space:]]+/,"",$2); print $2; exit}' "$bout")
            echo "  Battery $cid     : Status=${b_status:-?} State=${b_state:-?}" >>"$BODY"
            case "${b_status:-}" in
                Ok|OK|"") ;;
                Critical) raise red "Controller $cid battery: $b_status / $b_state" ;;
                Non-Critical) raise yellow "Controller $cid battery: $b_status / $b_state" ;;
            esac
            case "${b_state:-}" in
                Ready|""|Ok|Charging|Reconditioning|Learning)
                    case "${b_state:-}" in
                        Charging|Reconditioning|Learning)
                            raise yellow "Controller $cid battery state: $b_state"
                            ;;
                    esac
                    ;;
                *) raise red "Controller $cid battery state: $b_state" ;;
            esac
        fi
    done
fi

# Virtual disks
section "Virtual disks (OMSA)"
printf '%-4s %-4s %-12s %-12s %-14s %-10s %-8s %s\n' \
    "Ctl" "ID" "Name" "Status" "State" "Layout" "Progress" "Device" >>"$BODY"
printf '%-4s %-4s %-12s %-12s %-14s %-10s %-8s %s\n' \
    "----" "----" "------------" "------------" "--------------" "----------" "--------" "------" >>"$BODY"

for cid in "${controller_ids[@]:-}"; do
    vout=$WORKDIR/vd.$cid
    $OMREPORT storage vdisk controller="$cid" 2>/dev/null >"$vout" || true
    [ -s "$vout" ] || continue

    # Split vdisks on /^ID[[:space:]]*:/
    awk -v cid="$cid" -v outdir="$WORKDIR" '
        function flush() {
            if (id == "") return
            file = outdir "/vdrec." cid "." id
            print "ID=" id > file
            print "Name=" name >> file
            print "Status=" status >> file
            print "State=" state >> file
            print "Layout=" layout >> file
            print "Progress=" progress >> file
            print "Device=" device >> file
            print "BadBlocks=" badblocks >> file
            print "Size=" size >> file
            close(file)
            n++
            ids[n] = id
        }
        /^ID[[:space:]]*:/ {
            flush()
            id = $0; sub(/^[^:]*:[[:space:]]*/, "", id)
            name=status=state=layout=progress=device=badblocks=size=""
            next
        }
        /^Name[[:space:]]*:/ { name=$0; sub(/^[^:]*:[[:space:]]*/, "", name); next }
        /^Status[[:space:]]*:/ { status=$0; sub(/^[^:]*:[[:space:]]*/, "", status); next }
        /^State[[:space:]]*:/ { state=$0; sub(/^[^:]*:[[:space:]]*/, "", state); next }
        /^Layout[[:space:]]*:/ { layout=$0; sub(/^[^:]*:[[:space:]]*/, "", layout); next }
        /^Progress[[:space:]]*:/ { progress=$0; sub(/^[^:]*:[[:space:]]*/, "", progress); next }
        /^Device Name[[:space:]]*:/ { device=$0; sub(/^[^:]*:[[:space:]]*/, "", device); next }
        /^Virtual Disk Bad Blocks[[:space:]]*:/ { badblocks=$0; sub(/^[^:]*:[[:space:]]*/, "", badblocks); next }
        /^Size[[:space:]]*:/ { size=$0; sub(/^[^:]*:[[:space:]]*/, "", size); next }
        END { flush() }
    ' "$vout"

    for rec in "$WORKDIR"/vdrec."$cid".*; do
        [ -f "$rec" ] || continue
        # shellcheck disable=SC1090
        id=$(sed -n 's/^ID=//p' "$rec")
        name=$(sed -n 's/^Name=//p' "$rec")
        status=$(sed -n 's/^Status=//p' "$rec")
        state=$(sed -n 's/^State=//p' "$rec")
        layout=$(sed -n 's/^Layout=//p' "$rec")
        progress=$(sed -n 's/^Progress=//p' "$rec")
        device=$(sed -n 's/^Device=//p' "$rec")
        badblocks=$(sed -n 's/^BadBlocks=//p' "$rec")

        prog_show="$progress"
        case "$progress" in
            "Not Applicable"|"") prog_show="-" ;;
        esac

        printf '%-4s %-4s %-12s %-12s %-14s %-10s %-8s %s\n' \
            "$cid" "$id" "${name:--}" "${status:--}" "${state:--}" \
            "${layout:--}" "${prog_show:--}" "${device:--}" >>"$BODY"

        # --- colour rules for VDs ---
        # Bad blocks always red
        if [ "${badblocks:-}" = "Yes" ]; then
            raise red "VD $cid/$id ($name): bad blocks detected (state=$state)"
        fi

        case "${status:-}" in
            Critical) raise red "VD $cid/$id ($name): Status Critical (state=$state)" ;;
        esac

        # State machine — do NOT treat Resynching as rebuild
        case "${state:-}" in
            Ready|Optimal|Ok|"")
                ;;
            Failed|Offline|Degraded)
                raise red "VD $cid/$id ($name): State $state${progress:+ ($progress)}"
                ;;
            Resynching)
                # OMSA name for consistency check / resync — not a disk rebuild
                track_progress_task "omsa-c${cid}-vd${id}-cc" \
                    "VD $cid/$id ($name): Consistency check / resync" \
                    "${progress:-}" yellow
                ;;
            "Consistency Check")
                track_progress_task "omsa-c${cid}-vd${id}-cc" \
                    "VD $cid/$id ($name): Consistency Check" \
                    "${progress:-}" yellow
                ;;
            "Background Initialization"|BGI)
                track_progress_task "omsa-c${cid}-vd${id}-bgi" \
                    "VD $cid/$id ($name): BGI" \
                    "${progress:-}" yellow
                ;;
            Rebuilding|"Replace Member"|Reconstructing|Reconstruct|Regenerating)
                track_progress_task "omsa-c${cid}-vd${id}-rbld" \
                    "VD $cid/$id ($name): $state" \
                    "${progress:-}" yellow
                ;;
            "Partially Degraded")
                raise red "VD $cid/$id ($name): Partially Degraded"
                ;;
            *)
                # Non-Critical status with odd state
                if [ "${status:-}" = "Non-Critical" ]; then
                    raise yellow "VD $cid/$id ($name): $status / $state${progress:+ ($progress)}"
                else
                    raise yellow "VD $cid/$id ($name): State $state"
                fi
                ;;
        esac
    done
done

# Physical disks — compact table; colour by State / Failure Predicted, NOT by
# Status alone (third-party drives are often Status=Non-Critical while Online).
section "Physical disks (OMSA)"
printf '%-10s %-10s %-12s %-4s %-6s %-8s %-18s %-14s %s\n' \
    "ID" "State" "Status" "Pred" "Media" "Bus" "Product" "Serial" "Capacity" >>"$BODY"
printf '%-10s %-10s %-12s %-4s %-6s %-8s %-18s %-14s %s\n' \
    "----------" "----------" "------------" "----" "------" "--------" "------------------" "--------------" "--------" >>"$BODY"

PROBLEM_PD=0
for cid in "${controller_ids[@]:-}"; do
    pout=$WORKDIR/pd.$cid
    $OMREPORT storage pdisk controller="$cid" 2>/dev/null >"$pout" || true
    [ -s "$pout" ] || continue

    awk -v cid="$cid" -v outdir="$WORKDIR" '
        function flush(    safe, file) {
            if (id == "") return
            safe = id
            gsub(/:/, "_", safe)
            file = outdir "/pdrec." cid "." safe
            print "ID=" id > file
            print "Name=" name >> file
            print "Status=" status >> file
            print "State=" state >> file
            print "Pred=" pred >> file
            print "Media=" media >> file
            print "Bus=" bus >> file
            print "Product=" product >> file
            print "Serial=" serial >> file
            print "Capacity=" capacity >> file
            print "Progress=" progress >> file
            print "HotSpare=" hotspare >> file
            close(file)
        }
        /^ID[[:space:]]*:/ {
            flush()
            id=$0; sub(/^[^:]*:[[:space:]]*/, "", id)
            name=status=state=pred=media=bus=product=serial=capacity=progress=hotspare=""
            next
        }
        /^Name[[:space:]]*:/ { name=$0; sub(/^[^:]*:[[:space:]]*/, "", name); next }
        /^Status[[:space:]]*:/ { status=$0; sub(/^[^:]*:[[:space:]]*/, "", status); next }
        /^State[[:space:]]*:/ { state=$0; sub(/^[^:]*:[[:space:]]*/, "", state); next }
        /^Failure Predicted[[:space:]]*:/ { pred=$0; sub(/^[^:]*:[[:space:]]*/, "", pred); next }
        /^Media[[:space:]]*:/ { media=$0; sub(/^[^:]*:[[:space:]]*/, "", media); next }
        /^Bus Protocol[[:space:]]*:/ { bus=$0; sub(/^[^:]*:[[:space:]]*/, "", bus); next }
        /^Product ID[[:space:]]*:/ { product=$0; sub(/^[^:]*:[[:space:]]*/, "", product); next }
        /^Serial No\.[[:space:]]*:/ { serial=$0; sub(/^[^:]*:[[:space:]]*/, "", serial); next }
        /^Capacity[[:space:]]*:/ { capacity=$0; sub(/^[^:]*:[[:space:]]*/, "", capacity); next }
        /^Progress[[:space:]]*:/ { progress=$0; sub(/^[^:]*:[[:space:]]*/, "", progress); next }
        /^Hot Spare[[:space:]]*:/ { hotspare=$0; sub(/^[^:]*:[[:space:]]*/, "", hotspare); next }
        END { flush() }
    ' "$pout"

    for rec in "$WORKDIR"/pdrec."$cid".*; do
        [ -f "$rec" ] || continue
        id=$(sed -n 's/^ID=//p' "$rec")
        state=$(sed -n 's/^State=//p' "$rec")
        status=$(sed -n 's/^Status=//p' "$rec")
        pred=$(sed -n 's/^Pred=//p' "$rec")
        media=$(sed -n 's/^Media=//p' "$rec")
        bus=$(sed -n 's/^Bus=//p' "$rec")
        product=$(sed -n 's/^Product=//p' "$rec")
        serial=$(sed -n 's/^Serial=//p' "$rec")
        capacity=$(sed -n 's/^Capacity=//p' "$rec")
        progress=$(sed -n 's/^Progress=//p' "$rec")
        hotspare=$(sed -n 's/^HotSpare=//p' "$rec")

        # Short capacity (first token before GiB/bytes paren often has comma size)
        cap_short=$(echo "$capacity" | sed 's/ (.*//; s/,//g' | awk '{print $1" "$2}')

        printf '%-10s %-10s %-12s %-4s %-6s %-8s %-18s %-14s %s\n' \
            "$id" "${state:--}" "${status:--}" "${pred:-No}" \
            "${media:--}" "${bus:--}" "${product:--}" "${serial:--}" \
            "${cap_short:--}" >>"$BODY"

        pd_label="PD $id"
        [ -n "$serial" ] && [ "$serial" != "Not Available" ] && pd_label="$pd_label SN $serial"
        [ -n "$product" ] && pd_label="$pd_label ($product)"

        # Predictive failure — always red
        if [ "${pred:-No}" = "Yes" ]; then
            raise red "$pd_label: Failure Predicted=Yes"
            PROBLEM_PD=1
        fi

        # State-based (authoritative)
        case "${state:-}" in
            Online|Ready|"Spun Up"|"Non-Raid"|NonRAID|Non-RAID)
                # Online + Status Critical is still a problem; Online+Non-Critical is noise
                if [ "${status:-}" = "Critical" ]; then
                    raise red "$pd_label: Status Critical while State=$state"
                    PROBLEM_PD=1
                fi
                ;;
            Failed|Offline|Missing|Removed|"Foreign"|Foreign)
                raise red "$pd_label: State $state"
                PROBLEM_PD=1
                ;;
            Rebuilding|"Replace Member"|Reconstructing)
                raise yellow "$pd_label: $state${progress:+ ($progress)}"
                PROBLEM_PD=1
                ;;
            Degraded)
                raise red "$pd_label: State Degraded"
                PROBLEM_PD=1
                ;;
            *)
                if [ "${status:-}" = "Critical" ]; then
                    raise red "$pd_label: Status Critical / State ${state:-unknown}"
                    PROBLEM_PD=1
                elif [ -n "${state:-}" ]; then
                    raise yellow "$pd_label: State $state / Status $status"
                    PROBLEM_PD=1
                fi
                ;;
        esac

        if [ "${hotspare:-No}" != "No" ] && [ -n "${hotspare:-}" ]; then
            echo "  (hot spare flag: $hotspare on $id)" >>"$BODY"
        fi
    done
done

# Enclosures
section "Enclosures (OMSA)"
for cid in "${controller_ids[@]:-}"; do
    eout=$WORKDIR/enc.$cid
    $OMREPORT storage enclosure controller="$cid" 2>/dev/null >"$eout" || true
    if [ ! -s "$eout" ]; then
        echo "Controller $cid: (no enclosure data)" >>"$BODY"
        continue
    fi
    echo "Controller $cid:" >>"$BODY"
    awk '
        /^ID[[:space:]]*:/ { if (id!="") printf "  %-8s %-12s %-10s %s\n", id, status, state, name
            id=$0; sub(/^[^:]*:[[:space:]]*/,"",id)
            status=state=name="" }
        /^Status[[:space:]]*:/ { status=$0; sub(/^[^:]*:[[:space:]]*/,"",status) }
        /^State[[:space:]]*:/ { state=$0; sub(/^[^:]*:[[:space:]]*/,"",state) }
        /^Name[[:space:]]*:/ { name=$0; sub(/^[^:]*:[[:space:]]*/,"",name) }
        END { if (id!="") printf "  %-8s %-12s %-10s %s\n", id, status, state, name }
    ' "$eout" >>"$BODY"

    while IFS= read -r eline; do
        eid=$(echo "$eline" | awk '{print $1}')
        estatus=$(echo "$eline" | awk '{print $2}')
        estate=$(echo "$eline" | awk '{print $3}')
        ename=$(echo "$eline" | awk '{for(i=4;i<=NF;i++) printf "%s ", $i;}' | sed 's/[[:space:]]*$//')
        # Single raise per enclosure (OMSA often sets both Status Critical and State Failed)
        if [ "$estatus" = "Critical" ] || [ "$estate" = "Failed" ] || [ "$estate" = "Degraded" ]; then
            raise red "Enclosure $eid ($ename): $estatus / $estate"
        elif [ "$estatus" = "Non-Critical" ]; then
            raise yellow "Enclosure $eid ($ename): Non-Critical / $estate"
        fi
    done < <(awk '
        /^ID[[:space:]]*:/ { if (id!="") print id, status, state, name
            id=$0; sub(/^[^:]*:[[:space:]]*/,"",id)
            status=state=name="" }
        /^Status[[:space:]]*:/ { status=$0; sub(/^[^:]*:[[:space:]]*/,"",status) }
        /^State[[:space:]]*:/ { state=$0; sub(/^[^:]*:[[:space:]]*/,"",state) }
        /^Name[[:space:]]*:/ { name=$0; sub(/^[^:]*:[[:space:]]*/,"",name) }
        END { if (id!="") print id, status, state, name }
    ' "$eout")
done

# Full detail for problem physical disks only
if [ "$PROBLEM_PD" -eq 1 ]; then
    section "Problem disk detail (OMSA full)"
    for rec in "$WORKDIR"/pdrec.*; do
        [ -f "$rec" ] || continue
        id=$(sed -n 's/^ID=//p' "$rec")
        state=$(sed -n 's/^State=//p' "$rec")
        status=$(sed -n 's/^Status=//p' "$rec")
        pred=$(sed -n 's/^Pred=//p' "$rec")
        problem=0
        case "$state" in
            Online|Ready|"Spun Up") [ "$status" = "Critical" ] && problem=1; [ "$pred" = "Yes" ] && problem=1 ;;
            *) problem=1 ;;
        esac
        [ "$pred" = "Yes" ] && problem=1
        [ "$problem" -eq 0 ] && continue
        # extract controller from filename pdrec.0.0_1_11
        base=$(basename "$rec")
        cid=$(echo "$base" | sed 's/^pdrec\.\([0-9]*\)\..*/\1/')
        echo "--- omreport storage pdisk controller=$cid pdisk=$id ---" >>"$BODY"
        $OMREPORT storage pdisk controller="$cid" pdisk="$id" 2>/dev/null >>"$BODY" || true
        echo "" >>"$BODY"
    done
fi

# ---------------------------------------------------------------------------
# Storage — perccli / storcli (preferred RAID view when available)
# ---------------------------------------------------------------------------
if [ -n "$RAIDCLI" ]; then
    section "RAID CLI (perccli/storcli) — primary RAID view"

    # shellcheck disable=SC2086
    raid_run() { eval $RAIDCLI "$@"; }

    {
        echo "CLI             : $RAIDCLI"
        echo ""
        echo "--- Controller summary ---"
        raid_run /c0 show 2>/dev/null || raid_run show 2>/dev/null || echo "(controller show failed)"
    } >>"$BODY"

    # Parse PD list from /c0/eall/sall show for colour (more reliable than scraping big dump)
    PDCLI=$WORKDIR/pdcli.txt
    : >"$WORKDIR/pd_ops_table"
    : >"$WORKDIR/pd_format_slots"
    raid_run /c0/eall/sall show 2>/dev/null >"$PDCLI" || true

    PD_SENSE_CMD=$(find_pd_sense_cmd || true)
    if [ -n "$PD_SENSE_CMD" ]; then
        echo "PD sense helper : $PD_SENSE_CMD" >>"$BODY"
    else
        echo "PD sense helper : (none — SCSI FORMAT progress not detected; install openmanage-pd-sense + sudo)" >>"$BODY"
    fi

    # Background PD ops first (init / erase / FORMAT) so FORMAT slots are known
    if [ -s "$PDCLI" ]; then
        section "Physical disk background ops (init / erase / format)"
        while IFS= read -r pline; do
            echo "$pline" | grep -qE '^[0-9]+:[0-9]+' || continue
            slot=$(echo "$pline" | awk '{print $1}')
            did=$(echo "$pline" | awk '{print $2}')
            state=$(echo "$pline" | awk '{print $3}')
            model=$(echo "$pline" | awk '{print $12}')
            eid=$(echo "$slot" | cut -d: -f1)
            slt=$(echo "$slot" | cut -d: -f2)
            # Skip pure legend lines
            case "$state" in
                State|EID*) continue ;;
            esac
            check_pd_long_ops "$eid" "$slt" "$did" "$model"
        done <"$PDCLI"
        if [ -s "$WORKDIR/pd_ops_table" ]; then
            {
                echo "Active PD operations:"
                cat "$WORKDIR/pd_ops_table"
            } >>"$BODY"
        else
            echo "(no perccli init/erase or SCSI FORMAT in progress on scanned PDs)" >>"$BODY"
        fi
    fi

    if [ -s "$PDCLI" ]; then
        # Lines like: 64:11    11 Failed  1  10.913 TB ...
        while IFS= read -r pline; do
            echo "$pline" | grep -qE '^[0-9]+:[0-9]+' || continue
            # EID:Slt DID State DG Size Unit Intf Med SED PI SeSz Model ...
            slot=$(echo "$pline" | awk '{print $1}')
            state=$(echo "$pline" | awk '{print $3}')
            model=$(echo "$pline" | awk '{print $12}')
            case "$state" in
                Onln|GHS|DHS|JBOD)
                    ;;
                UGood|UG)
                    # If SCSI FORMAT is running, already raised yellow with % — skip duplicate
                    if [ -f "$WORKDIR/pd_format_slots" ] \
                        && grep -qxF "$slot" "$WORKDIR/pd_format_slots" 2>/dev/null; then
                        :
                    else
                        # Unconfigured Good = disk present but not in an array
                        raise yellow "perccli PD $slot: $state (unconfigured — not in an array)${model:+ ($model)}"
                    fi
                    ;;
                Failed|Offln|UBad|Msng|Ubads|UBUnsp)
                    raise red "perccli PD $slot: $state${model:+ ($model)}"
                    ;;
                Rbld|Cpybck|CFShld)
                    # Prefer perccli rebuild progress when available
                    eid=$(echo "$slot" | cut -d: -f1)
                    slt=$(echo "$slot" | cut -d: -f2)
                    rb_out=$(raid_run /c0/e"${eid}"/s"${slt}" show rebuild 2>/dev/null || true)
                    if echo "$rb_out" | grep -qi "In progress\|Progress"; then
                        rb_pct=$(echo "$rb_out" | awk '/Progress|In progress/{for(i=1;i<=NF;i++) if($i+0>0||$i=="0"){print $i; exit}}')
                        if [ -n "$(parse_percent "${rb_pct}%")" ] || echo "$rb_pct" | grep -qE '^[0-9]+$'; then
                            track_progress_task "perc-e${eid}-s${slt}-rbld" \
                                "perccli PD $slot: $state${model:+ ($model)}" "${rb_pct}%" yellow
                        else
                            raise yellow "perccli PD $slot: $state${model:+ ($model)}"
                        fi
                    else
                        raise yellow "perccli PD $slot: $state${model:+ ($model)}"
                    fi
                    ;;
                *)
                    raise yellow "perccli PD $slot: state $state${model:+ ($model)}"
                    ;;
            esac
        done <"$PDCLI"
    fi

    # VD list states
    VDCLI=$WORKDIR/vdcli.txt
    raid_run /c0/vall show 2>/dev/null >"$VDCLI" || true
    if [ -s "$VDCLI" ]; then
        # DG/VD TYPE State ...
        while IFS= read -r vline; do
            echo "$vline" | grep -qE '^[0-9]+/[0-9]+' || continue
            dgvd=$(echo "$vline" | awk '{print $1}')
            typ=$(echo "$vline" | awk '{print $2}')
            st=$(echo "$vline" | awk '{print $3}')
            name=$(echo "$vline" | awk '{print $NF}')
            case "$st" in
                Optl)
                    ;;
                Pdgd|Dgrd)
                    raise red "perccli VD $dgvd ($name $typ): $st (degraded)"
                    ;;
                OfLn|Rec)
                    raise red "perccli VD $dgvd ($name $typ): $st"
                    ;;
                *)
                    raise yellow "perccli VD $dgvd ($name $typ): $st"
                    ;;
            esac
        done <"$VDCLI"
    fi

    # Active ops + detail for non-optimal VDs
    section "RAID CLI — virtual drive detail"
    for v in 0 1 2 3 4 5 6 7; do
        vdetail=$WORKDIR/vdetail.$v
        if raid_run /c0/v$v show all 2>/dev/null >"$vdetail"; then
            if grep -q "Status = Success" "$vdetail" 2>/dev/null || grep -q "DG/VD" "$vdetail"; then
                if ! grep -q "Controller = 0 not found\|Failed to get" "$vdetail"; then
                    # compact extract
                    {
                        echo "--- /c0/v$v ---"
                        grep -E 'DG/VD|TYPE|State |Active Operations|OS Drive Name|Strip Size|Number of Drives|Consist' "$vdetail" | head -40
                        echo ""
                        # PD members table if present
                        awk '/PDs for VD/,/^$/' "$vdetail" | head -40
                        echo ""
                    } >>"$BODY"
                    if grep -qiE 'Active Operations = .*(Rebuild|Consistency|BGI|Patrol|Copyback|Replace)' "$vdetail"; then
                        op=$(awk -F= '/Active Operations/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}' "$vdetail")
                        case "$op" in
                            *Rebuild*|*Copyback*|*Replace*)
                                track_progress_task "perc-c0-v${v}-rbld" \
                                    "perccli VD $v: $op" "$op" yellow
                                ;;
                            *Consistency*)
                                track_progress_task "perc-c0-v${v}-cc" \
                                    "perccli VD $v: Consistency Check (not a rebuild)" \
                                    "$op" yellow
                                ;;
                            *BGI*|*Background*)
                                track_progress_task "perc-c0-v${v}-bgi" \
                                    "perccli VD $v: $op" "$op" yellow
                                ;;
                            *None*|"")
                                ;;
                            *)
                                if [ -n "$(parse_percent "$op")" ]; then
                                    track_progress_task "perc-c0-v${v}-op" \
                                        "perccli VD $v: $op" "$op" yellow
                                else
                                    raise yellow "perccli VD $v active: $op"
                                fi
                                ;;
                        esac
                    fi
                fi
            fi
        fi
    done

    # Failed / non-Onln drive full detail
    section "RAID CLI — problem physical disk detail"
    any_cli_pd=0
    if [ -s "$PDCLI" ]; then
        while IFS= read -r pline; do
            echo "$pline" | grep -qE '^[0-9]+:[0-9]+' || continue
            slot=$(echo "$pline" | awk '{print $1}')
            state=$(echo "$pline" | awk '{print $3}')
            case "$state" in
                Onln|GHS|DHS|JBOD) continue ;;
            esac
            any_cli_pd=1
            eid=$(echo "$slot" | cut -d: -f1)
            slt=$(echo "$slot" | cut -d: -f2)
            echo "--- /c0/e${eid}/s${slt} show all (state=$state) ---" >>"$BODY"
            raid_run /c0/e${eid}/s${slt} show all 2>/dev/null >>"$BODY" || true
            echo "" >>"$BODY"
        done <"$PDCLI"
    fi
    if [ "$any_cli_pd" -eq 0 ]; then
        echo "(no non-online physical disks in perccli PD list)" >>"$BODY"
    fi

    # BBU one-liner already in /c0 show; foreign config
    section "RAID CLI — foreign config / BBU"
    {
        echo "--- foreign config ---"
        raid_run /c0/fall show 2>/dev/null || echo "(no foreign config or command failed)"
        echo ""
        echo "--- BBU ---"
        raid_run /c0/bbu show 2>/dev/null || raid_run /c0 show 2>/dev/null | awk '/BBU/,/^$/' || true
    } >>"$BODY"
else
    section "RAID CLI (perccli/storcli)"
    echo "Not available. Install perccli and allow the xymon user to run it via" >>"$BODY"
    echo "  /etc/sudoers.d/xymon  (same file as other xymon sudos), e.g.:" >>"$BODY"
    echo "  xymon ALL=NOPASSWD: /opt/MegaRAID/perccli/perccli64" >>"$BODY"
    echo "OMSA-only mode is active for storage." >>"$BODY"
fi

# ---------------------------------------------------------------------------
# Long-running task ETA detail + persist state
# ---------------------------------------------------------------------------
if [ -s "$WORKDIR/eta_detail" ]; then
    section "Long-running task ETA (client state)"
    {
        echo "State file: $STATE_FILE"
        echo "History: up to $TASK_HIST_MAX samples per task key; rate from oldest->newest kept sample."
        echo ""
        cat "$WORKDIR/eta_detail"
    } >>"$BODY"
fi
save_task_state

# ---------------------------------------------------------------------------
# OpenManage web link
# ---------------------------------------------------------------------------
section "Links"
echo "OpenManage Web  : https://${HOSTNAME:-$(hostname -f)}:1311/" >>"$BODY"

# ---------------------------------------------------------------------------
# Compose Xymon message
# ---------------------------------------------------------------------------
MSG_HEAD=""
if [ ${#MSGS[@]} -gt 0 ]; then
    MSG_HEAD=$(printf '%s; ' "${MSGS[@]}")
    MSG_HEAD=${MSG_HEAD%; }
else
    MSG_HEAD="Dell hardware OK"
fi

# Prepend summary block to body
FINAL=$WORKDIR/final
{
    echo "SUMMARY"
    echo "-------"
    if [ -s "$SUMMARY" ]; then
        cat "$SUMMARY"
    else
        echo "&green All checked components OK"
    fi
    echo ""
    echo "Tools: omreport=${OMREPORT}"
    echo "       raidcli=${RAIDCLI:-none}"
    echo "       task_state=${STATE_FILE}"
    cat "$BODY"
} >"$FINAL"

# Xymon status line — keep header reasonably short
LINE="status ${MACHINE}.${TEST} ${COLOR} $(date) ${MSG_HEAD}
$(cat "$FINAL")"

if [ "${DRY_RUN:-0}" = "1" ]; then
    printf '%s\n' "$LINE"
else
    # Prefer XYMSRV (modern), fall back to XYMONDISP
    DEST="${XYMSRV:-${XYMONDISP:-}}"
    if [ -z "$DEST" ]; then
        echo "${XYMONPROG}: XYMSRV/XYMONDISP not set" >&2
        exit 1
    fi
    $XYMON $DEST "$LINE"
fi

exit 0
