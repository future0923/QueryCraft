#!/bin/bash
# QueryCraft shell task backend. Uses only the existing shell and system tools.
umask 077
export LC_ALL=C
fail() { printf '{"error":"%s","automatic_retry":false}\n' "$1"; exit 1; }
private_dir() { [[ -d "$1" && ! -L "$1" && -O "$1" ]] && [[ $(ls -ld "$1") == drwx------* ]]; }
regular() { [[ -f "$1" && ! -L "$1" && -O "$1" ]]; }
number() { [[ "$1" =~ ^[0-9]{1,16}$ ]] && (( 10#$1 <= 9007199254740991 )); }
elapsed_now() {
    if [[ -r /proc/uptime ]]; then local uptime rest; read -r uptime rest < /proc/uptime; printf '%s' "${uptime%.*}"
    else printf '%s' "$SECONDS"; fi
}
readnum() { local n; regular "$1" || return 1; read -r n < "$1"; number "$n" || return 1; printf '%s' "$n"; }
put() {
    local tmp="$1.tmp.$$.$RANDOM"
    (set -C; printf '%s\n' "$2" > "$tmp") || return 1
    mv -f -- "$tmp" "$1"
}
decode() { printf '%s' "$1" | base64 "$decode_flag"; }
if [[ $(printf eA== | base64 -d 2>/dev/null) == x ]]; then decode_flag=-d; else decode_flag=-D; fi
action=$1; id=$2
[[ "$id" =~ ^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$ ]] || fail invalid_task_id
parent="$HOME/.querycraft-ssh-tasks"
base="$parent/shell-v1"
job="$base/$id"
if [[ "$action" == start ]]; then
    [[ -e "$parent" ]] || mkdir -m 700 -- "$parent" || fail task_directory_unavailable
    private_dir "$parent" || fail unsafe_task_directory
    [[ -e "$base" ]] || mkdir -m 700 -- "$base" || fail task_directory_unavailable
fi
private_dir "$parent" && private_dir "$base" || fail task_directory_unavailable_or_legacy_task

state_read() {
    regular "$job/state" || return 1
    read -r state code created started finished < "$job/state"
    case "$state" in starting|running|completed|cancelled|timed_out|failed|unknown) ;; *) return 1 ;; esac
    [[ "$code" == null || "$code" =~ ^[0-9]{1,3}$ ]] && number "$created" && number "$started" && number "$finished"
}
terminal() { case "$state" in completed|cancelled|timed_out|failed) return 0;; *) return 1;; esac; }
state_put() { put "$job/state" "$state $code $created $started $finished"; }
summary() {
    state_read || fail invalid_task_state
    # A live runner owns this heartbeat. Missing/stale supervision means unknown.
    if ! terminal; then
        beat=$(readnum "$job/heartbeat") || beat=0
        now=$(date +%s)
        if (( now - beat > 10 )); then state=unknown; fi
    fi
    out=$(readnum "$job/stdout.bytes") || out=0
    err=$(readnum "$job/stderr.bytes") || err=0
    keptout=$(readnum "$job/stdout.kept") || keptout=0
    kepterr=$(readnum "$job/stderr.kept") || kepterr=0
    truncated=false; ((out+err>keptout+kepterr)) && truncated=true
    final=false; terminal && final=true
    printf '{"task_id":"%s","state":"%s","exit_code":%s,"created_at_unix":%s,"started_at_unix":%s,"finished_at_unix":%s,"stdout_bytes":%s,"stderr_bytes":%s,"stdout_retained_bytes":%s,"stderr_retained_bytes":%s,"truncated":%s,"output_incomplete":%s,"automatic_retry":false}\n' "$id" "$state" "$code" "$created" "$started" "$finished" "$out" "$err" "$keptout" "$kepterr" "$truncated" "$( [[ -f "$job/incomplete" ]] && printf true || printf false )"
}

if [[ "$action" == start ]]; then
    source=$3; command_data=$4; cwd_data=$5; lifetime=$6; cap=$7
    number "$lifetime" && ((lifetime>=1 && lifetime<=86400)) || fail invalid_lifetime
    number "$cap" && ((cap>=1024 && cap<=67108864)) || fail invalid_log_limit
    mkdir -- "$base/.launch.lock" 2>/dev/null || fail launch_busy_retry_later
    trap 'rmdir -- "$base/.launch.lock" 2>/dev/null' EXIT
    active=0
    for candidate in "$base"/*; do
        [[ -d "$candidate" && ! -L "$candidate" ]] || continue
        if regular "$candidate/state"; then
            read -r old _ < "$candidate/state"
            case "$old" in completed|cancelled|timed_out|failed) ;; *) active=$((active+1));; esac
        fi
    done
    ((active<16)) || fail remote_task_capacity
    mkdir -m 700 -- "$job" || fail task_already_exists_never_relaunch
    created=$(date +%s); started=0; finished=0; state=failed; code=null
    state_put || fail state_write_failed
    decode "$source" > "$job/runner.sh" && decode "$command_data" > "$job/command.sh" && decode "$cwd_data" > "$job/cwd" || fail invalid_task_payload
    printf '%s\n' "$lifetime" > "$job/lifetime"
    printf '%s\n' "$cap" > "$job/cap"
    for name in stdout stderr; do : > "$job/$name"; put "$job/$name.bytes" 0; put "$job/$name.kept" 0; done
    put "$job/retained" 0
    state=starting; state_put && put "$job/heartbeat" "$created" || fail state_write_failed
    nohup /bin/bash "$job/runner.sh" run "$id" </dev/null >/dev/null 2>&1 &
    summary
    exit 0
fi
private_dir "$job" || fail task_not_found_or_legacy_backend
[[ "$action" == run || "$action" == collect ]] || regular "$job/runner.sh" || fail invalid_task_backend

# Each collector reads raw bytes in bounded chunks; it drains excess output.
if [[ "$action" == collect ]]; then
    stream=$3; [[ "$stream" == stdout || "$stream" == stderr ]] || exit 1
    cap=$(readnum "$job/cap") || exit 1
    total=0; kept=0
    exec 3< "$job/$stream.pipe"
    while :; do
        # One pipe read publishes short output immediately instead of waiting
        # for sixteen input blocks or EOF. The chunk stays bounded at 64 KiB.
        dd bs=65536 count=1 <&3 > "$job/chunk.$stream" 2>/dev/null || exit 1
        n=$(wc -c < "$job/chunk.$stream"); n=${n//[[:space:]]/}
        number "$n" || exit 1
        ((n>0)) || break
        total=$((total+n)); put "$job/$stream.bytes" "$total" || exit 1
        while ! mkdir -- "$job/.bytes.lock" 2>/dev/null; do sleep 0.1; done
        retained=$(readnum "$job/retained") || exit 1
        allowed=$((cap-retained)); ((allowed>n)) && allowed=$n; ((allowed<0)) && allowed=0
        put "$job/retained" "$((retained+allowed))" || exit 1
        rmdir -- "$job/.bytes.lock" || exit 1
        if ((allowed>0)); then
            dd bs=1 count="$allowed" < "$job/chunk.$stream" >> "$job/$stream" 2>/dev/null || exit 1
            kept=$((kept+allowed)); put "$job/$stream.kept" "$kept" || exit 1
        fi
    done
    exit 0
fi
if [[ "$action" == run ]]; then
    state_read || exit 1
    lifetime=$(readnum "$job/lifetime") || exit 1
    # Interactive job control supplies owned process groups without setsid or an installed helper.
    set -m
    mkfifo -- "$job/stdout.pipe" "$job/stderr.pipe" || exit 1
    /bin/bash "$job/runner.sh" collect "$id" stdout & outpid=$!
    /bin/bash "$job/runner.sh" collect "$id" stderr & errpid=$!
    # Append a sentinel before command substitution, preserving trailing newlines in paths.
    cwd=$(cat "$job/cwd"; printf .); cwd=${cwd%.}
    [[ -n "$cwd" ]] || cwd=$HOME
    if [[ "$cwd" != /* ]] || ! cd -- "$cwd"; then
        state=failed; finished=$(date +%s); state_put
        kill -KILL -- -"$outpid" -"$errpid" 2>/dev/null
        wait; exit 0
    fi
    /bin/sh "$job/command.sh" </dev/null > "$job/stdout.pipe" 2> "$job/stderr.pipe" & child=$!
    deadline_start=$(elapsed_now)
    started=$(date +%s); state=running; state_put || exit 1
    stop=completed
    while jobs -pr | grep -qx "$child"; do
        now=$(date +%s); put "$job/heartbeat" "$now" || exit 1
        if [[ -f "$job/cancel" ]]; then stop=cancelled
        elif (($(elapsed_now)-deadline_start>=lifetime)); then stop=timed_out; fi
        if [[ "$stop" != completed ]]; then
            # Only this supervisor signals its own live job group, never a caller-provided PID.
            kill -KILL -- -"$child" 2>/dev/null
            break
        fi
        sleep 0.2
    done
    wait "$child"; code=$?
    # Descendants may retain pipes. Bound final drainage and flag incomplete output.
    for ((i=0;i<20;i++)); do
        running=$(jobs -pr)
        [[ $'\n'"$running"$'\n' == *$'\n'"$outpid"$'\n'* || $'\n'"$running"$'\n' == *$'\n'"$errpid"$'\n'* ]] || break
        put "$job/heartbeat" "$(date +%s)"; sleep 0.1
    done
    for pid in "$outpid" "$errpid"; do
        if jobs -pr | grep -qx "$pid"; then : > "$job/incomplete"; kill -KILL -- -"$pid" 2>/dev/null; fi
        wait "$pid" || : > "$job/incomplete"
    done
    state=$stop; finished=$(date +%s); state_put
    exit 0
fi

state_read || fail invalid_task_state
case "$action" in
status) summary ;;
output)
    stream=$8; offset=$9; limit=${10}
    [[ "$stream" == stdout || "$stream" == stderr ]] && number "$offset" && number "$limit" && ((limit>=1 && limit<=262144)) || fail invalid_log_window
    regular "$job/$stream" || fail invalid_log_file
    # dd seeks regular files directly. pipefail distinguishes read failure from EOF.
    content=$(set -o pipefail; dd if="$job/$stream" bs=1 skip="$offset" count="$limit" 2>/dev/null | base64 | tr -d '\r\n') || fail log_read_failed
    count=$(printf '%s' "$content" | base64 "$decode_flag" | wc -c); count=${count//[[:space:]]/}
    summary_value=$(summary) || exit 1
    state_read || exit 1
    [[ "$summary_value" != *'"state":"unknown"'* ]] || state=unknown
    final=false; terminal && final=true
    printf '{"task_id":"%s","state":"%s","stream":"%s","offset":%s,"bytes_read":%s,"next_offset":%s,"content_base64":"%s","final":%s,"truncated":%s}\n' "$id" "$state" "$stream" "$offset" "$count" "$((offset+count))" "$content" "$final" "$( [[ "$summary_value" == *'"truncated":true'* ]] && printf true || printf false )"
    ;;
cancel)
    if terminal; then summary; exit; fi
    value=$(summary) || exit 1
    [[ "$value" != *'"state":"unknown"'* ]] || fail supervisor_absent_outcome_unknown
    [[ ! -e "$job/cancel" ]] || regular "$job/cancel" || fail unsafe_cancel_marker
    : > "$job/cancel"
    printf '{"task_id":"%s","state":"cancellation_requested","automatic_retry":false}\n' "$id"
    ;;
remove)
    terminal || fail refusing_active_or_unknown_task
    for path in "$job"/* "$job"/.[!.]*; do
        [[ -e "$path" || -L "$path" ]] || continue
        name=${path##*/}
        case "$name" in runner.sh|command.sh|cwd|lifetime|cap|state|heartbeat|stdout|stderr|stdout.bytes|stderr.bytes|stdout.kept|stderr.kept|retained|cancel|incomplete|chunk.stdout|chunk.stderr|stdout.pipe|stderr.pipe) ;;
        *) fail unrecognized_task_files;; esac
        [[ ! -L "$path" && -O "$path" && ( -f "$path" || -p "$path" ) ]] || fail unsafe_task_file
    done
    for path in "$job"/* "$job"/.[!.]*; do [[ -e "$path" ]] && rm -- "$path"; done
    rmdir -- "$job" || fail cleanup_failed
    printf '{"task_id":"%s","removed":true}\n' "$id"
    ;;
*) fail invalid_action;;
esac
