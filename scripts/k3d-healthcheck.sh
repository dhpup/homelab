#!/bin/bash

# K3d Homelab Health Check and Recovery Script
# This script checks if the k3d cluster is healthy and attempts recovery if needed
# Handles: stopped load balancer, NotReady nodes, unresponsive API server

CLUSTER_NAME="homelab"
KUBE_CONTEXT="k3d-${CLUSTER_NAME}"
MAX_RETRIES=3
WAIT_TIME=45
LOG_FILE="$HOME/Library/Logs/k3d-healthcheck.log"

log() {
    echo "[$(date)] $1" | tee -a "$LOG_FILE"
}

# Rotate log: keep last 500 lines to prevent unbounded growth
if [ -f "$LOG_FILE" ]; then
    tail -n 500 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
fi

log "Checking k3d cluster health..."

# Ensure we're using the correct kubectl context
ensure_context() {
    current_context=$(kubectl config current-context 2>/dev/null)
    if [ "$current_context" != "$KUBE_CONTEXT" ]; then
        log "Switching kubectl context from '$current_context' to '$KUBE_CONTEXT'"
        kubectl config use-context "$KUBE_CONTEXT" &>/dev/null
        if [ $? -ne 0 ]; then
            log "ERROR: Failed to switch to context '$KUBE_CONTEXT'"
            return 1
        fi
    fi
    return 0
}

# Function to check if Docker is running
check_docker() {
    docker info &>/dev/null
    return $?
}

# Function to check if cluster API is responsive
check_cluster_health() {
    kubectl cluster-info --request-timeout=10s &>/dev/null
    return $?
}

# Function to check if load balancer is running
check_loadbalancer() {
    docker ps --format "{{.Names}}" | grep -q "k3d-${CLUSTER_NAME}-serverlb"
    return $?
}

# Function to check if any nodes are NotReady
check_nodes_ready() {
    local not_ready_count
    not_ready_count=$(kubectl get nodes --no-headers 2>/dev/null | grep -c "NotReady")
    if [ "$not_ready_count" -gt 0 ]; then
        return 1
    fi
    return 0
}

# Function to start stopped load balancer
start_loadbalancer() {
    log "Load balancer is stopped. Starting it..."
    docker start "k3d-${CLUSTER_NAME}-serverlb"
    sleep 15
}

# Function to start all stopped k3d containers
start_all_containers() {
    log "Starting all stopped k3d containers..."
    docker ps -a --filter "name=k3d-${CLUSTER_NAME}" --filter "status=exited" --format "{{.Names}}" | while read -r container; do
        log "Starting container: $container"
        docker start "$container"
    done
    sleep 20
}

# Function to get list of NotReady node names
get_notready_nodes() {
    kubectl get nodes --no-headers 2>/dev/null | grep "NotReady" | awk '{print $1}'
}

# Function to fix flannel public-ip annotations after IP drift
# After a machine restart, Docker may assign different IPs to containers.
# Flannel stores the node's public-ip in an annotation; if it doesn't match
# the container's actual IP, flannel crashes with:
#   "failed to find interface with specified node ip"
fix_flannel_ip_annotations() {
    log "Checking for flannel IP annotation drift..."
    local fixed=0

    for container in $(docker ps -a --filter "name=k3d-${CLUSTER_NAME}" --format "{{.Names}}" | grep -E 'server|agent'); do
        # Get the container's actual Docker network IP
        local actual_ip
        actual_ip=$(docker inspect "$container" --format "{{(index .NetworkSettings.Networks \"k3d-${CLUSTER_NAME}\").IPAddress}}" 2>/dev/null)
        if [ -z "$actual_ip" ]; then
            continue
        fi

        # The node name in k8s matches the container name
        local node_name="$container"

        # Get the flannel public-ip annotation
        local flannel_ip
        flannel_ip=$(kubectl get node "$node_name" -o jsonpath='{.metadata.annotations.flannel\.alpha\.coreos\.com/public-ip}' 2>/dev/null)
        if [ -z "$flannel_ip" ]; then
            continue
        fi

        if [ "$actual_ip" != "$flannel_ip" ]; then
            log "IP drift detected: $node_name has Docker IP $actual_ip but flannel annotation says $flannel_ip"
            kubectl annotate node "$node_name" "flannel.alpha.coreos.com/public-ip=$actual_ip" --overwrite 2>/dev/null
            if [ $? -eq 0 ]; then
                log "Updated flannel annotation for $node_name to $actual_ip"
                fixed=$((fixed + 1))
            else
                log "ERROR: Failed to update flannel annotation for $node_name"
            fi
        fi
    done

    if [ "$fixed" -gt 0 ]; then
        log "Fixed $fixed flannel annotation(s)"
        return 0
    fi
    return 1
}

# Function to restart agent containers (fixes NotReady nodes after power outage)
# Retries up to 3 times, restarting only the NotReady agents each time
restart_agent_containers() {
    log "Restarting agent containers to fix NotReady nodes..."
    
    for attempt in 1 2 3; do
        # Get list of NotReady nodes
        notready_nodes=$(get_notready_nodes)
        
        if [ -z "$notready_nodes" ]; then
            log "All nodes are Ready"
            return 0
        fi

        # Fix flannel annotations before restarting (the actual root cause of most failures)
        fix_flannel_ip_annotations
        
        log "Attempt $attempt: Restarting NotReady agents: $notready_nodes"
        
        # Restart each NotReady agent container
        echo "$notready_nodes" | while read -r node; do
            if [[ "$node" == *"agent"* ]]; then
                log "Restarting container: $node"
                docker restart "$node" 2>/dev/null
            fi
        done
        
        sleep 25
    done
    
    # Final check
    if check_nodes_ready; then
        return 0
    else
        log "Some nodes still NotReady after 3 restart attempts"
        return 1
    fi
}

# Function to restart the cluster
restart_cluster() {
    log "Performing full cluster restart..."
    k3d cluster stop "$CLUSTER_NAME" 2>/dev/null
    sleep 5
    k3d cluster start "$CLUSTER_NAME"
    sleep $WAIT_TIME
    
    # After restart, Docker may reassign IPs - fix flannel annotations
    if check_cluster_health; then
        fix_flannel_ip_annotations
    fi
    
    # After k3d cluster start, agents sometimes don't start properly - restart them
    if ! check_nodes_ready; then
        log "Nodes still NotReady after cluster start, restarting agents..."
        restart_agent_containers
    fi
}

# Function for full health check (API + nodes)
full_health_check() {
    if ! check_cluster_health; then
        return 1
    fi
    if ! check_nodes_ready; then
        log "API is up but some nodes are NotReady"
        return 1
    fi
    return 0
}

# Wait for Docker to be ready (important after boot)
if ! check_docker; then
    log "Docker is not running. Waiting up to 2 minutes..."
    for i in $(seq 1 12); do
        sleep 10
        if check_docker; then
            log "Docker is now running"
            break
        fi
    done
    if ! check_docker; then
        log "ERROR: Docker failed to start"
        exit 1
    fi
fi

# Check if cluster exists
if ! k3d cluster get "$CLUSTER_NAME" &>/dev/null; then
    log "ERROR: Cluster '$CLUSTER_NAME' not found"
    exit 1
fi

# Ensure we're on the correct kubectl context
if ! ensure_context; then
    log "ERROR: Could not set kubectl context"
    exit 1
fi

# Quick check - if everything is healthy, exit early
if full_health_check; then
    log "Cluster is fully healthy (API responsive, all nodes Ready)"
    exit 0
fi

# STEP 1: Check if load balancer is stopped (quick fix)
if ! check_loadbalancer; then
    start_loadbalancer
    if full_health_check; then
        log "Cluster recovered by starting load balancer"
        exit 0
    fi
fi

# STEP 2: Check if any containers are stopped and start them
stopped_containers=$(docker ps -a --filter "name=k3d-${CLUSTER_NAME}" --filter "status=exited" --format "{{.Names}}" | wc -l | tr -d ' ')
if [ "$stopped_containers" -gt 0 ]; then
    start_all_containers
    if full_health_check; then
        log "Cluster recovered by starting stopped containers"
        exit 0
    fi
fi

# STEP 3: Fix flannel IP drift (most common cause of post-restart failures)
# Docker doesn't guarantee stable IPs across restarts, but flannel/k3s stores
# the node IP in annotations. Fix the annotations before any restart attempts.
if check_cluster_health; then
    if fix_flannel_ip_annotations; then
        log "Fixed flannel IP drift, restarting affected containers..."
        # Restart containers in restart loops (they're crashing because of the IP mismatch)
        docker ps -a --filter "name=k3d-${CLUSTER_NAME}" --format "{{.Names}} {{.Status}}" | grep "Restarting" | awk '{print $1}' | while read -r container; do
            log "Restarting crash-looping container: $container"
            docker restart "$container" 2>/dev/null
        done
        # Also restart NotReady agents
        get_notready_nodes | while read -r node; do
            log "Restarting NotReady node: $node"
            docker restart "$node" 2>/dev/null
        done
        sleep 30
        if full_health_check; then
            log "Cluster recovered by fixing flannel IP annotations"
            exit 0
        fi
    fi
fi

# STEP 3b: If API is up but nodes are NotReady, try restarting agents (faster than full restart)
if check_cluster_health && ! check_nodes_ready; then
    log "Detected NotReady nodes - trying agent restart first"
    restart_agent_containers
    if full_health_check; then
        log "Cluster recovered by restarting agent containers"
        exit 0
    fi
fi

# STEP 4: Full cluster restart with retries
for i in $(seq 1 $MAX_RETRIES); do
    log "Recovery attempt $i/$MAX_RETRIES - performing full cluster restart"
    
    restart_cluster
    
    # Give nodes time to become ready
    sleep 30
    
    if full_health_check; then
        log "Cluster recovered successfully after full restart"
        exit 0
    fi
    
    # Log current state for debugging
    log "Current node status:"
    kubectl get nodes --no-headers 2>/dev/null | while read -r line; do
        log "  $line"
    done
done

log "ERROR: Failed to recover cluster after $MAX_RETRIES attempts"
log "Manual intervention required. Try: k3d cluster stop $CLUSTER_NAME && k3d cluster start $CLUSTER_NAME"
exit 1
