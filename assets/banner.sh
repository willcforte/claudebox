# shellcheck shell=bash
# claudebox shell banner — shown on every interactive shell (sourced from ~/.bashrc).
_cb_box="${CLAUDEBOX_NAME:-$(hostname 2>/dev/null)}"
_cb_repo="${CLAUDEBOX_WORKSPACE:-$PWD}"
_cb_gpu="${CLAUDEBOX_GPU:-?}"
_cb_ports="${CLAUDEBOX_PORTS:-none}"
_cb_agent="$(jq -r '.oauthAccount.emailAddress // empty' "$HOME/.claude.json" 2>/dev/null)"
[ -n "$_cb_agent" ] || _cb_agent="Claude Code (auto-mode)"
_cb_c=$'\033[36m'; _cb_b=$'\033[1m'; _cb_d=$'\033[2m'; _cb_r=$'\033[0m'

printf '\n%s' "$_cb_c"
cat <<'ART'
      _                 _      _
  ___| | __ _ _   _  __| | ___| |__   _____  __
 / __| |/ _` | | | |/ _` |/ _ \ '_ \ / _ \ \/ /
| (__| | (_| | |_| | (_| |  __/ |_) | (_) >  <
 \___|_|\__,_|\__,_|\__,_|\___|_.__/ \___/_/\_\
ART
printf '%s' "$_cb_r"
printf '  %sbox%s    %s  %s(this window)%s\n' "$_cb_b" "$_cb_r" "$_cb_box" "$_cb_d" "$_cb_r"
printf '  %sagent%s  %s\n'                     "$_cb_b" "$_cb_r" "$_cb_agent"
printf '  %srepo%s   %s\n'                     "$_cb_b" "$_cb_r" "$_cb_repo"
printf '  %sgpu%s    %s\n'                     "$_cb_b" "$_cb_r" "$_cb_gpu"
printf '  %sports%s  %s\n'                     "$_cb_b" "$_cb_r" "$_cb_ports"
case "$_cb_ports" in *9090*) echo "  ${_cb_b}viz${_cb_r}    http://persona-0020-2:9090?url=rerun%2Bhttp%3A%2F%2Fpersona-0020-2%3A9876%2Fproxy" ;; esac
echo
unset _cb_box _cb_repo _cb_gpu _cb_ports _cb_agent _cb_c _cb_b _cb_d _cb_r
