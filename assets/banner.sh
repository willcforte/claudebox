# shellcheck shell=bash
# claudebox banner — emerald (oh-my-logo style, toilet/pagga) wordmark with Claude-orange rail that
# envelops the box details as one graphic. Sourced from ~/.bashrc (truecolor; COLORTERM forwarded).
_cb_box="${CLAUDEBOX_NAME:-$(hostname 2>/dev/null)}"
_cb_repo="${CLAUDEBOX_WORKSPACE:-$PWD}"
_cb_gpu="${CLAUDEBOX_GPU:-?}"; [ "$_cb_gpu" = true ] && _cb_gpu=on
_cb_ports="${CLAUDEBOX_PORTS:-none}"
_cb_agent="$(jq -r '.oauthAccount.emailAddress // empty' "$HOME/.claude.json" 2>/dev/null)"
[ -n "$_cb_agent" ] || _cb_agent="Claude Code (auto-mode)"

# emerald vertical gradient (shading) + Claude-orange accents
_e1=$'\033[1;38;2;52;211;153m'; _e2=$'\033[1;38;2;16;185;129m'; _e3=$'\033[1;38;2;6;150;110m'
_or=$'\033[38;2;222;120;75m'; _lab=$'\033[1;38;2;52;211;153m'; _r=$'\033[0m'
_row(){ printf '  %s┃%s  %s\n' "$_or" "$_r" "$1"; }

printf '\n  %s┏━━%s\n' "$_or" "$_r"
printf '  %s┃%s  %s░█▀▀░█░░░█▀█░█░█░█▀▄░█▀▀░█▀▄░█▀█░█░█%s\n' "$_or" "$_r" "$_e1" "$_r"
printf '  %s┃%s  %s░█░░░█░░░█▀█░█░█░█░█░█▀▀░█▀▄░█░█░▄▀▄%s\n' "$_or" "$_r" "$_e2" "$_r"
printf '  %s┃%s  %s░▀▀▀░▀▀▀░▀░▀░▀▀▀░▀▀░░▀▀▀░▀▀░░▀▀▀░▀░▀%s\n' "$_or" "$_r" "$_e3" "$_r"
printf '  %s┃%s\n' "$_or" "$_r"
_row "${_lab}box${_r}   $_cb_box   ${_or}·${_r}  ${_lab}agent${_r}  $_cb_agent"
_row "${_lab}repo${_r}  $_cb_repo   ${_or}·${_r}  ${_lab}gpu${_r}  $_cb_gpu   ${_or}·${_r}  ${_lab}ports${_r}  $_cb_ports"
_host="${CLAUDEBOX_HOST:-localhost}"
case "$_cb_ports" in *9090*) _row "${_lab}viz${_r}   http://${_host}:9090?url=rerun%2Bhttp%3A%2F%2F${_host}%3A9876%2Fproxy" ;; esac
printf '  %s┗━━%s\n\n' "$_or" "$_r"
unset _cb_box _cb_repo _cb_gpu _cb_ports _cb_agent _host _e1 _e2 _e3 _or _lab _r
