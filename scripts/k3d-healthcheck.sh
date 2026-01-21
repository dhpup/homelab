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

# Function to check if any server container is in restart loop
check_container_restart_loop() {
    docker ps --format "{{.Names}} {{.Status}}" | grep "k3d-${CLUSTER_NAME}" | grep -q "Restarting"
    return $?
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
if ! k3d cluster list 2>/dev/null | grep -q "^$CLUSTER_NAME"; then
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

# STEP 3: Check for restart loops or NotReady nodes - requires full restart
if check_container_restart_loop; then
    log "Detected container in restart loop"
fi

# STEP 3b: If API is up but nodes are NotReady, try restarting agents first (faster than full restart)
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
