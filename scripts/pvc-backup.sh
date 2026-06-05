#!/bin/bash

# PVC Backup and Restore Script
# Usage:
#   ./pvc-backup.sh backup           — backs up all PVCs to ~/homelab-pvc-backup/<date>/
#   ./pvc-backup.sh backup <dir>     — backs up to a specific directory
#   ./pvc-backup.sh restore <dir>    — restores all PVCs from a backup directory
#   ./pvc-backup.sh list             — lists available backups

set -euo pipefail

CLUSTER_NAME="homelab"
KUBE_CONTEXT="k3d-${CLUSTER_NAME}"
DEFAULT_BACKUP_ROOT="$HOME/homelab-pvc-backup"

# namespace:pvc-name pairs to back up
PVCS=(
  "sonarr:sonarr"
  "radarr:radarr"
  "bazarr:bazarr"
  "prowlarr:prowlarr"
  "seerr:seerr"
  "maintainerr:maintainerr"
  "tdarr:tdarr-config"
  "tdarr:tdarr-data"
)

log() {
  echo "[$(date +%H:%M:%S)] $1"
}

die() {
  echo "ERROR: $1" >&2
  exit 1
}

ensure_context() {
  kubectl config use-context "$KUBE_CONTEXT" &>/dev/null || die "Could not switch to context '$KUBE_CONTEXT'"
}

# Scale all app deployments up or down
# Usage: scale_apps up|down
scale_apps() {
  local replicas=0
  [[ "$1" == "up" ]] && replicas=1

  log "$( [[ $replicas -eq 0 ]] && echo 'Scaling down' || echo 'Scaling up' ) all apps..."
  for ns in sonarr radarr bazarr prowlarr seerr maintainerr tdarr; do
    kubectl scale deploy -n "$ns" --all --replicas="$replicas" 2>/dev/null || true
  done

  if [[ $replicas -eq 0 ]]; then
    log "Waiting for pods to terminate..."
    for ns in sonarr radarr bazarr prowlarr seerr maintainerr tdarr; do
      kubectl wait --for=delete pod --all -n "$ns" --timeout=120s 2>/dev/null || true
    done
  else
    log "Waiting for pods to be ready..."
    for ns in sonarr radarr bazarr prowlarr seerr maintainerr tdarr; do
      kubectl wait --for=condition=Ready pod --all -n "$ns" --timeout=120s 2>/dev/null || true
    done
  fi
}

# Spin up a temporary busybox pod mounting a PVC, run a command, then clean up
# Usage: with_pvc_pod <namespace> <pvc> <pod-name> <command...>
with_pvc_pod() {
  local ns="$1" pvc="$2" pod="$3"
  shift 3

  kubectl apply -f - &>/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $pod
  namespace: $ns
spec:
  restartPolicy: Never
  containers:
  - name: worker
    image: busybox
    command: ["sleep", "3600"]
    volumeMounts:
    - mountPath: /data
      name: pvc-data
  volumes:
  - name: pvc-data
    persistentVolumeClaim:
      claimName: $pvc
EOF

  kubectl wait pod/"$pod" -n "$ns" --for=condition=Ready --timeout=60s &>/dev/null
  kubectl exec -n "$ns" "$pod" -- "$@"
  kubectl delete pod "$pod" -n "$ns" --wait=false &>/dev/null
}

cmd_backup() {
  local backup_dir="${1:-$DEFAULT_BACKUP_ROOT/$(date +%Y%m%d_%H%M%S)}"
  mkdir -p "$backup_dir"

  log "Backup directory: $backup_dir"

  ensure_context
  scale_apps down

  local failed=0
  for entry in "${PVCS[@]}"; do
    local ns="${entry%%:*}"
    local pvc="${entry##*:}"
    local outfile="$backup_dir/${ns}-${pvc}.tar.gz"
    log "Backing up $ns/$pvc -> $(basename "$outfile")"

    if with_pvc_pod "$ns" "$pvc" "pvc-backup-$$-${pvc}" \
        tar czf - -C /data . > "$outfile" 2>/dev/null; then
      log "  OK ($(du -sh "$outfile" | cut -f1))"
    else
      log "  FAILED: $ns/$pvc"
      rm -f "$outfile"
      failed=$((failed + 1))
    fi
  done

  scale_apps up

  echo ""
  if [[ $failed -eq 0 ]]; then
    log "Backup complete: $backup_dir"
    log "Total size: $(du -sh "$backup_dir" | cut -f1)"
  else
    log "Backup completed with $failed failure(s): $backup_dir"
    exit 1
  fi
}

cmd_restore() {
  local backup_dir="${1:-}"
  [[ -z "$backup_dir" ]] && die "Usage: $0 restore <backup-dir>"
  [[ -d "$backup_dir" ]] || die "Backup directory not found: $backup_dir"

  # Restore copies archives via the shared host mount (/homelab-storage) so the
  # pod reads from a file rather than stdin — stdin piping is unreliable for
  # large archives and silently truncates without error.
  local HOST_STORAGE="/Users/daneko/homelab-storage"
  local STAGING="$HOST_STORAGE/.pvc-restore-staging"

  ensure_context

  log "Restoring from: $backup_dir"
  log ""
  log "NOTE: PVCs must already exist (ArgoCD must have synced and pods must have"
  log "      been scheduled at least once). Scale down apps before restoring."
  echo ""
  read -r -p "Continue? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { log "Aborted."; exit 0; }

  mkdir -p "$STAGING"
  trap 'rm -rf "$STAGING"' EXIT

  scale_apps down

  local failed=0
  for entry in "${PVCS[@]}"; do
    local ns="${entry%%:*}"
    local pvc="${entry##*:}"
    local infile="$backup_dir/${ns}-${pvc}.tar.gz"

    if [[ ! -f "$infile" ]]; then
      log "Skipping $ns/$pvc — no backup file found"
      continue
    fi

    if ! kubectl get pvc "$pvc" -n "$ns" &>/dev/null; then
      log "  SKIPPED: PVC $pvc not found in namespace $ns — sync ArgoCD first"
      continue
    fi

    log "Restoring $ns/$pvc from $(basename "$infile")..."

    local staged="$STAGING/${ns}-${pvc}.tar.gz"
    cp "$infile" "$staged"

    local pod="pvc-restore-$$-${pvc}"
    kubectl apply -f - &>/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $pod
  namespace: $ns
spec:
  restartPolicy: Never
  containers:
  - name: restore
    image: busybox
    command: ["sleep", "600"]
    volumeMounts:
    - mountPath: /data
      name: pvc-data
    - mountPath: /staging
      name: host-staging
  volumes:
  - name: pvc-data
    persistentVolumeClaim:
      claimName: $pvc
  - name: host-staging
    hostPath:
      path: $HOST_STORAGE/.pvc-restore-staging
      type: Directory
EOF

    if kubectl wait pod/"$pod" -n "$ns" --for=condition=Ready --timeout=60s &>/dev/null; then
      if kubectl exec -n "$ns" "$pod" -- sh -c "
        rm -rf /data/* /data/.[^.]* 2>/dev/null
        tar xzf /staging/${ns}-${pvc}.tar.gz -C /data &&
        rm -f /data/*.db-shm /data/*.db-wal /data/*.pid
      "; then
        log "  OK"
      else
        log "  FAILED: $ns/$pvc"
        failed=$((failed + 1))
      fi
    else
      log "  FAILED: restore pod never became ready for $ns/$pvc"
      failed=$((failed + 1))
    fi

    kubectl delete pod "$pod" -n "$ns" --wait=false &>/dev/null
    rm -f "$staged"
  done

  scale_apps up

  echo ""
  if [[ $failed -eq 0 ]]; then
    log "Restore complete."
  else
    log "Restore completed with $failed failure(s)."
    exit 1
  fi
}

cmd_list() {
  if [[ ! -d "$DEFAULT_BACKUP_ROOT" ]]; then
    echo "No backups found at $DEFAULT_BACKUP_ROOT"
    exit 0
  fi
  echo "Available backups in $DEFAULT_BACKUP_ROOT:"
  for d in "$DEFAULT_BACKUP_ROOT"/*/; do
    [[ -d "$d" ]] || continue
    local size
    size=$(du -sh "$d" 2>/dev/null | cut -f1)
    echo "  $(basename "$d")  ($size)"
  done
}

case "${1:-}" in
  backup)  cmd_backup "${2:-}" ;;
  restore) cmd_restore "${2:-}" ;;
  list)    cmd_list ;;
  *) echo "Usage: $0 backup [dir] | restore <dir> | list"; exit 1 ;;
esac
