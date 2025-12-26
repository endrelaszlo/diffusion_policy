#!/usr/bin/env bash
set -euo pipefail

# Be explicit about the micromamba root prefix.
# Some container platforms / shells may start without inheriting ENV reliably,
# and micromamba will then fall back to ~/.local/share/mamba (which won't
# contain the prebuilt env from the Dockerfile).
export MAMBA_ROOT_PREFIX="${MAMBA_ROOT_PREFIX:-/opt/micromamba}"
export PATH="${MAMBA_ROOT_PREFIX}/bin:${PATH}"

log() {
  echo "[entrypoint] $*" >&2
}

generate_token() {
  # Use python (present in the robodiff env) to generate a strong token without relying on extra OS packages.
  micromamba run -n robodiff python - <<'PY'
import secrets
print(secrets.token_urlsafe(32))
PY
}

ensure_user() {
  local user="$1"
  if ! id -u "$user" >/dev/null 2>&1; then
    log "User '$user' does not exist; creating."
    useradd -m -s /bin/bash "$user"
  fi
}

install_key() {
  local user="$1"
  local home_dir
  home_dir="$(getent passwd "$user" | cut -d: -f6)"
  if [[ -z "${home_dir}" ]]; then
    log "Could not determine home dir for '$user'; skipping key install."
    return 0
  fi

  local ssh_dir="${home_dir}/.ssh"
  local auth_keys="${ssh_dir}/authorized_keys"
  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"

  # Support a few common env var names used by container platforms / templates.
  # Accept multiple keys separated by newlines.
  local key_material=""
  if [[ -n "${PUBLIC_KEY:-}" ]]; then key_material="${PUBLIC_KEY}"; fi
  if [[ -z "$key_material" && -n "${SSH_PUBLIC_KEY:-}" ]]; then key_material="${SSH_PUBLIC_KEY}"; fi
  if [[ -z "$key_material" && -n "${AUTHORIZED_KEYS:-}" ]]; then key_material="${AUTHORIZED_KEYS}"; fi
  if [[ -z "$key_material" && -n "${RUNPOD_SSH_PUBLIC_KEY:-}" ]]; then key_material="${RUNPOD_SSH_PUBLIC_KEY}"; fi

  if [[ -n "$key_material" ]]; then
    # Normalize CRLF and ensure trailing newline
    key_material="$(printf "%s\n" "$key_material" | sed 's/\r$//')"
    # Only append if it looks like an SSH public key line
    if echo "$key_material" | grep -Eq '^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp(256|384|521)) '; then
      touch "$auth_keys"
      chmod 600 "$auth_keys"
      # Append keys that aren't already present
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if ! grep -Fqx "$line" "$auth_keys"; then
          echo "$line" >> "$auth_keys"
        fi
      done <<< "$key_material"
      log "Installed SSH public key(s) for user '$user' at $auth_keys"
    else
      log "Provided key material doesn't look like an SSH public key; ignoring."
    fi
  else
    # If RunPod (or the user) mounted authorized_keys already, keep it.
    if [[ -f "$auth_keys" ]]; then
      log "Found existing $auth_keys for '$user' (not modifying)."
    else
      log "No SSH public key env var found and no existing $auth_keys; SSH login may fail."
    fi
  fi

  chown -R "$user":"$user" "$ssh_dir" || true
}

has_authorized_keys() {
  local user="$1"
  local home_dir
  home_dir="$(getent passwd "$user" | cut -d: -f6)"
  [[ -n "${home_dir}" && -s "${home_dir}/.ssh/authorized_keys" ]]
}

main() {
  # Ensure sshd runtime dirs exist
  mkdir -p /var/run/sshd

  # Generate host keys if missing (unique per instance)
  if ! ls /etc/ssh/ssh_host_* >/dev/null 2>&1; then
    log "Generating SSH host keys."
    ssh-keygen -A
  fi

  # Ensure default user exists (created at build time, but safe to re-check)
  ensure_user "runpod"

  # Install keys for runpod and root (root login is key-only due to sshd_config)
  install_key "runpod"
  install_key "root"

  # Align with RunPod's official pattern: only start SSH if a public key exists
  # (their reference uses PUBLIC_KEY and then starts ssh) while still supporting
  # pre-mounted authorized_keys files. See: https://www.runpod.io/blog/diy-deep-learning-docker-container
  if has_authorized_keys "runpod" || has_authorized_keys "root"; then
    log "SSH key(s) detected; starting sshd."
    /usr/sbin/sshd -D -e &
  else
    log "No SSH keys detected; not starting sshd."
  fi

  log "Executing: $*"
  exec "$@"
}

main "$@"


