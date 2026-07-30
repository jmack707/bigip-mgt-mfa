# certs.sh — source this. The osixia/openldap container chowns the bind-mounted certs/
# dir at every startup, so any local signing after the stack has been up finds it
# root-owned. ensure_certs_writable reclaims it (sudo) or fails early with the fix.
ensure_certs_writable() {
  local d="$1"
  if [ -w "$d" ] && { [ ! -e "$d/ca.key" ] || [ -w "$d/ca.key" ]; }; then return 0; fi
  if command -v sudo >/dev/null 2>&1; then
    echo "==> $d not writable (openldap container chowned it) — reclaiming with sudo"
    sudo chown -R "$(id -u):$(id -g)" "$d"
  else
    echo "$d is not writable (the openldap container chowns it at startup)." >&2
    echo "Fix as root: chown -R $(id -un) $d  — then re-run." >&2
    return 1
  fi
}
