#!/bin/sh
# Talks to the running StackNudge panel over its Unix socket. say, state and
# focus on|off exit 0 quietly when the app is down, so a script or a Shortcuts
# automation never fails because the panel is not running.
#
# Installed as ~/.stack-nudge/stack-nudge beside notify.sh. The socket is the
# same one notify.sh posts events to; a line with a "cmd" key is a command and
# gets one JSON line back.
SOCK="${STACKNUDGE_SOCK:-$HOME/.stack-nudge/panel.sock}"

usage() {
    cat >&2 <<'USAGE'
usage: stack-nudge say "title" [--body ..] [--url ..] [--severity info|action|alert]
                     [--source github|calendar|script] [--tag ..] [--key ..]
       stack-nudge focus on|off|status
       stack-nudge state <pose> [--ttl seconds]
       stack-nudge settings [category]
       stack-nudge poll | busy | ping
USAGE
    exit 2
}

esc() {
    printf '%s' "$1" | awk 'BEGIN{ORS=""} {gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); gsub(/\t/,"\\t"); gsub(/\r/,""); if (NR>1) print "\\n"; print}'
}

[ $# -ge 1 ] || usage
cmd=$1
shift
quiet=0
wait=5

case "$cmd" in
    say)
        [ $# -ge 1 ] || usage
        title=$1
        shift
        body='' url='' severity='' source='' tag='' key=''
        while [ $# -gt 0 ]; do
            [ $# -ge 2 ] || usage
            case "$1" in
                --body) body=$2 ;;
                --url) url=$2 ;;
                --severity) severity=$2 ;;
                --source) source=$2 ;;
                --tag) tag=$2 ;;
                --key) key=$2 ;;
                *) usage ;;
            esac
            shift 2
        done
        json="{\"cmd\":\"say\",\"title\":\"$(esc "$title")\",\"body\":\"$(esc "$body")\",\"url\":\"$(esc "$url")\""
        [ -n "$severity" ] && json="$json,\"severity\":\"$(esc "$severity")\""
        [ -n "$source" ] && json="$json,\"source\":\"$(esc "$source")\""
        [ -n "$tag" ] && json="$json,\"tag\":\"$(esc "$tag")\""
        [ -n "$key" ] && json="$json,\"key\":\"$(esc "$key")\""
        json="$json}"
        quiet=1
        ;;
    state)
        [ $# -ge 1 ] || usage
        name=$1
        shift
        ttl=30
        if [ "${1:-}" = "--ttl" ]; then
            [ $# -eq 2 ] || usage
            ttl=$2
        elif [ $# -gt 0 ]; then
            usage
        fi
        case "$ttl" in '' | *[!0-9.]*) usage ;; esac
        json="{\"cmd\":\"state\",\"state\":\"$(esc "$name")\",\"ttlSeconds\":$ttl}"
        quiet=1
        ;;
    focus)
        [ $# -eq 1 ] || usage
        case "$1" in on | off | status) ;; *) usage ;; esac
        json="{\"cmd\":\"focus\",\"state\":\"$1\"}"
        [ "$1" = status ] || quiet=1
        ;;
    settings)
        [ $# -le 1 ] || usage
        json="{\"cmd\":\"settings\",\"category\":\"$(esc "${1:-}")\"}"
        ;;
    poll)
        json='{"cmd":"poll"}'
        wait=240
        ;;
    busy)
        json='{"cmd":"busy"}'
        ;;
    ping)
        json='{"cmd":"ping"}'
        ;;
    *)
        usage
        ;;
esac

down() {
    [ "$quiet" = 1 ] && exit 0
    echo "stack-nudge: the panel is not running (open StackNudge.app)" >&2
    exit 1
}

[ -S "$SOCK" ] || down
reply=$(printf '%s\n' "$json" | nc -U -w "$wait" "$SOCK" 2>/dev/null) || down
[ -n "$reply" ] || down
case "$reply" in
    *'"ok":true'*)
        [ "$quiet" = 1 ] || echo "$reply"
        ;;
    *)
        echo "$reply" >&2
        exit 1
        ;;
esac
