# shellcheck shell=bash
# claudebox: auto-activate a pixi env from CWD for interactive and non-interactive shells.
# Read via BASH_ENV (non-interactive `bash -c`) and sourced from .bashrc (interactive).
# Guard is exported before the hook runs so any bash pixi spawns short-circuits (no recursion).
[ -n "${CLAUDEBOX_PIXI_ACTIVATED:-}" ] && return 0
export CLAUDEBOX_PIXI_ACTIVATED=1
command -v pixi >/dev/null 2>&1 || return 0
_hook="$(pixi shell-hook -s bash 2>/dev/null)" && [ -n "$_hook" ] && eval "$_hook"
unset _hook
