# Loaded as this explicitly opted-in interactive Bash's rcfile. No startup file
# is written. Keep payloads out of xtrace/verbose/DEBUG traps and child envs.
if [[ -r ~/.bashrc ]]; then . ~/.bashrc; fi
if (( BASH_VERSINFO[0] < 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] < 1) )) ||
   [[ $- == *x* || $- == *v* || $- == *a* || -o functrace ]] ||
   [[ -n $(trap -p DEBUG) ]] || ! shopt -q promptvars ||
   [[ $(builtin bind -v 2>/dev/null) != *'set editing-mode emacs'* ]] ||
   declare -F __hspterm_apply >/dev/null; then
    builtin printf '\nHSPTerm: optional Bash integration unavailable; ordinary terminal input retained.\n'
    return
fi
__hspterm_nonce='@HSPTERM_NONCE@'
__hspterm_prompt_id=0
__hspterm_active=0
__hspterm_pending=''
__hspterm_command_open=0
__hspterm_previous_prompt=("${PROMPT_COMMAND[@]}")
__hspterm_supported() {
    [[ $- != *x* && $- != *v* && $- != *a* && ! -o functrace ]] &&
    shopt -q promptvars && [[ $(builtin bind -v 2>/dev/null) == *'set editing-mode emacs'* ]]
}
__hspterm_hex() {
    local LC_ALL=C value=$1 i byte
    __hspterm_encoded=''
    for ((i=0; i<${#value}; i++)); do
        builtin printf -v byte '%02x' "'${value:i:1}"
        __hspterm_encoded+=$byte
    done
}
__hspterm_decode() {
    local LC_ALL=C value=$1 pair byte i
    __hspterm_decoded=''
    [[ ${#value} -le 8192 && $((${#value} % 2)) == 0 && $value != *[!0-9a-f]* ]] || return 1
    for ((i=0; i<${#value}; i+=2)); do
        pair=${value:i:2}
        [[ $pair != 00 ]] || return 1
        builtin printf -v byte '%b' "\x$pair"
        __hspterm_decoded+=$byte
    done
    [[ $__hspterm_decoded != *[$'\x01'-$'\x1f\x7f']* ]]
}
__hspterm_emit() {
    # All arguments are fixed kinds or bounded numbers/hex, never terminal text.
    builtin printf '\033]777;hspterm;HSP1;%s;%s;%s;%s;%s;%s\033\\' \
        "$__hspterm_nonce" "$__hspterm_prompt_id" "$1" "$2" "$3" "$4"
}
__hspterm_ready() {
    if [[ $__hspterm_active == 1 ]] && __hspterm_supported; then
        __hspterm_emit R 0 0 ''
    fi
}
# Same authenticated stream, empty URI authority: no DNS/hostname guessing.
__hspterm_cwd() {
    local LC_ALL=C value=$PWD encoded='' byte char i
    [[ ${#value} -le 16384 && $value == /* ]] || return
    for ((i=0; i<${#value}; i++)); do
        char=${value:i:1}
        case "$char" in
            [a-zA-Z0-9/._~-]) encoded+=$char ;;
            *) builtin printf -v byte '%%%02X' "'$char"; encoded+=$byte ;;
        esac
    done
    builtin printf '\033]7;file://%s\033\\' "$encoded"
}
__hspterm_status() { return "$1"; }
__hspterm_prompt() {
    local previous_status=$? command
    if [[ $__hspterm_command_open == 1 ]]; then
        builtin printf '\033]133;D;%s\033\\' "$previous_status"
        __hspterm_command_open=0
    fi
    __hspterm_active=0
    __hspterm_pending=''
    for command in "${__hspterm_previous_prompt[@]}"; do
        [[ -z $command ]] && continue
        __hspterm_status "$previous_status"
        # These are the user's original PROMPT_COMMAND entries, NOT wire data.
        builtin eval -- "$command"
        previous_status=$?
    done
    if __hspterm_supported && [[ $__hspterm_prompt_id -lt 2147483647 ]]; then
        ((__hspterm_prompt_id+=1))
        __hspterm_active=1
        # Last expansion: any user PS1 command substitutions run before ready.
        __hspterm_cwd
        [[ $PS1 == *'\[$(__hspterm_ready)\]'* ]] || PS1='\[\e]133;A\a\]'"$PS1"'\[$(__hspterm_ready)\]\[\e]133;B\a\]'
    fi
    return "$previous_status"
}
__hspterm_submit() {
    # Readline exposes a character position in the user's multibyte locale.
    # Capture that comparison before switching to byte-oriented wire encoding.
    local point=$READLINE_POINT length=${#READLINE_LINE}
    local LC_ALL=C
    builtin bind '"\e[9878~":""'
    __hspterm_pending=''
    if [[ $__hspterm_active == 1 && ${#READLINE_LINE} -le 4096 &&
          $point == "$length" &&
          $READLINE_LINE != *[$'\x01'-$'\x1f\x7f']* ]] && __hspterm_supported; then
        __hspterm_hex "$READLINE_LINE"
        __hspterm_pending=$__hspterm_encoded
        __hspterm_encoded=''
    fi
    # A second Enter/PS2 cannot qualify an earlier incomplete command.
    __hspterm_active=0
}
__hspterm_before_exec() {
    local LC_ALL=C hex
    __hspterm_active=0
    hex=$__hspterm_pending
    __hspterm_pending=''
    if __hspterm_supported && [[ $__hspterm_prompt_id -gt 0 ]]; then
        if [[ -n $hex ]]; then
            __hspterm_emit S 0 "$((${#hex}/2))" "$hex"
            if [[ $__hspterm_command_open == 0 ]]; then
                builtin printf '\033]133;C\033\\'
                __hspterm_command_open=1
            fi
        fi
        __hspterm_emit B 0 0 ''
    fi
}
__hspterm_apply() {
    local header body version nonce prompt request execute old next extra actual size
    builtin bind '"\e[9878~":""'
    # Drain the complete bounded request before rejecting stale readiness.
    # Otherwise its hex body could become ordinary Readline input.
    # Five ASCII length digits, then exactly that many ASCII bytes, no newline.
    IFS= builtin read -r -N 5 -t 1 header || { __hspterm_active=0; return; }
    [[ ${#header} == 5 && $header != *[!0-9]* ]] || { __hspterm_active=0; return; }
    size=$((10#$header))
    [[ $size -gt 0 && $size -le 16544 ]] || { __hspterm_active=0; return; }
    IFS= builtin read -r -N "$size" -t 1 body || { __hspterm_active=0; return; }
    [[ $__hspterm_active == 1 ]] && __hspterm_supported || return
    IFS=';' builtin read -r version nonce prompt request execute old next extra <<< "$body"
    # The trailing field must be absent. Full-body reconstruction also rejects
    # a trailing semicolon or read's whitespace/field-normalization ambiguities.
    if [[ $body != "$version;$nonce;$prompt;$request;$execute;$old;$next" ||
          $version != HSP1 || $nonce != "$__hspterm_nonce" ||
          $prompt != "$__hspterm_prompt_id" ||
          -z $request || ${#request} -gt 20 || $request == *[!0-9]* ||
          $request == 0* || ( $execute != 0 && $execute != 1 ) ||
          ${#READLINE_LINE} -gt 4096 || $READLINE_POINT != ${#READLINE_LINE} ]]; then
        __hspterm_active=0
        return
    fi
    __hspterm_hex "$READLINE_LINE"
    actual=$__hspterm_encoded
    __hspterm_encoded=''
    if [[ ${#actual} -gt 8192 || $actual != "$old" ]] || ! __hspterm_decode "$next"; then
        __hspterm_decoded=''
        __hspterm_active=0
        __hspterm_emit X "$request" 0 ''
        return
    fi
    READLINE_LINE=$__hspterm_decoded
    READLINE_POINT=${#READLINE_LINE}
    READLINE_MARK=$READLINE_POINT
    __hspterm_decoded=''
    __hspterm_emit A "$request" "$((${#next}/2))" "$next"
    if [[ $execute == 1 ]]; then
        # Only this successful compare-and-apply enables the queued commit key.
        # Failed requests leave it a no-op, so no stale line can be executed.
        builtin bind '"\e[9878~":"\e[9877~\e[9879~"'
    fi
}
builtin bind -x '"\e[9876~":__hspterm_apply'
builtin bind -x '"\e[9877~":__hspterm_submit'
builtin bind '"\e[9878~":""'
builtin bind '"\e[9879~":accept-line'
builtin bind '"\C-m":"\e[9877~\e[9879~"'
builtin bind '"\C-j":"\e[9877~\e[9879~"'
PROMPT_COMMAND=(__hspterm_prompt)
# Do not inherit this trap into arbitrary functions/subshells. Each top-level
# command relinquishes proof before it can run a TUI or password-reading tool.
trap 'case "$BASH_COMMAND" in __hspterm_prompt|__hspterm_apply|__hspterm_submit) ;; *) __hspterm_before_exec ;; esac' DEBUG
