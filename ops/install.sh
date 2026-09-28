#!/bin/sh
# Installs Crescendo's scripts and systemd user units. It never enables a
# unit or overwrites local configuration; it prints what is left to do.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=${CRESCENDO_INSTALL_ROOT:-$HOME/.local/lib/crescendo}
config=${CRESCENDO_CONFIG_DIR:-$HOME/.config/crescendo}
units=$HOME/.config/systemd/user

mkdir -p "$root/bin" "$root/releases" "$units" "$config/projects"
chmod 700 "$config"
for script in start crescendo deploy; do install -m 755 "$here/bin/$script" "$root/bin/$script"; done
for unit in crescendo.service crescendo-deploy.service crescendo-deploy.timer; do install -m 644 "$here/systemd/$unit" "$units/$unit"; done
systemctl --user daemon-reload

if [ ! -e "$config/crescendo.yml" ]; then
  cat > "$config/crescendo.yml" <<'YAML'
server: {host: 127.0.0.1, port: 4280}
paths: {state: ~/.local/state/crescendo}
pool: {slots: 3}
throttle:
  daily_budget_usd: 50
projects: {}
YAML
  chmod 600 "$config/crescendo.yml"
fi

cat <<NEXT
Installed scripts to $root/bin and units to $units.
Left to do:
  - $config/service.env: PATH (with mise, codex and gh), MISE_* directories, and
    CRESCENDO_RELEASE pointing at a built release (releases/<sha>).
  - Add projects: $root/bin/crescendo project add $config/crescendo.yml <id> <owner/repo>
    then $root/bin/crescendo labels sync $config/crescendo.yml
  - systemctl --user enable --now crescendo.service
  - Optional self-deploy: systemctl --user enable --now crescendo-deploy.timer
NEXT
