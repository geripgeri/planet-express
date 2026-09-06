#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Longhorn + Cilium Network Diagnostic Script
# Run on the host system (not inside the sandbox)
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

NODES=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

# Return the cilium agent pod name that runs on the given node.
cilium_pod_for_node() {
    local node="$1"
    kubectl get pods -n kube-system -o jsonpath \
        "{.items[?(@.spec.nodeName=='$node')].metadata.name}" 2>/dev/null | \
        tr ' ' '\n' | grep '^cilium-' | head -1
}

# Run a command inside the cilium agent pod on a specific node (host netns).
exec_on_node() {
    local node="$1"; shift
    local pod
    pod=$(cilium_pod_for_node "$node")
    if [ -z "$pod" ]; then
        echo "  [ERROR] no cilium pod on node $node"
        return 1
    fi
    kubectl exec -n kube-system "$pod" -c cilium-agent -- "$@" 2>&1
}

# Resolve the Longhorn Gateway's assigned LB address at runtime so no
# hardcoded internal address needs to live in this public script. Override
# with LONGHORN_LB_IP if the Gateway is unreachable during an outage.
resolve_lb_ip() {
    local ip
    ip=$(kubectl get gateway shared-gateway -n kube-system \
        -o jsonpath='{.status.addresses[?(@.type=="IPAddress")].value}' 2>/dev/null)
    if [ -n "$ip" ]; then
        echo "$ip"
    elif [ -n "${LONGHORN_LB_IP:-}" ]; then
        echo "$LONGHORN_LB_IP"
    else
        echo "(unknown)"
    fi
}
LB_IP=$(resolve_lb_ip)

echo "=========================================="
echo " Longhorn + Cilium Network Diagnostics"
echo " $(date -Iseconds)"
echo "=========================================="
echo ""

# --- 1. Talos Node Network Interfaces ---
echo "### 1. Talos Node Network Interfaces ###"
echo "Expected interfaces: ens18 (VLAN 10), ens19 (VLAN 20)"
echo ""
for node in $NODES; do
    echo "--- Node: $node ---"
    addr=$(exec_on_node "$node" ip -4 addr show ens18 2>/dev/null | grep -E 'inet ' || echo "    NOT FOUND")
    echo "  ens18 addr: $addr"
    addr=$(exec_on_node "$node" ip -4 addr show ens19 2>/dev/null | grep -E 'inet ' || echo "    NOT FOUND")
    echo "  ens19 addr: $addr"
    echo ""
done

# --- 2. Cilium DaemonSet env (effective config as rendered) ---
echo "### 2. Cilium DaemonSet env - devices/l2announcements/routing ###"
echo ""
CILIUM_ENV=$(kubectl -n kube-system get daemonset cilium -o jsonpath='{.spec.template.spec.containers[0].env}' 2>/dev/null)
printf '%s' "$CILIUM_ENV" | python3 -c '
import sys, json
try:
    env = json.load(sys.stdin)
except json.JSONDecodeError:
    print("  Could not read DaemonSet env")
    sys.exit(0)
keys = ("device", "l2", "announce", "route", "node", "routing", "cidr",
        "masquerade", "gateway", "ipam", "pool", "kube", "container", "binary")
for e in env:
    n = e.get("name", "")
    if any(k in n.lower() for k in keys):
        v = e.get("value")
        print(f"  {n}={v if v is not None else '"'"'<valueFrom>'"'"'}")
'
echo ""

# --- 3. Effective cilium-config ConfigMap (what the agent loaded) ---
echo "### 3. Effective cilium-config ConfigMap (agent runtime values) ###"
echo ""
kubectl -n kube-system get cm cilium-config -o yaml 2>/dev/null | \
    grep -E '^\s{2}(l2-announcements|routing-mode|ipv4-native-routing-cidr|auto-direct-node-routes|bpf-masquerade|enable-ipv4-masquerade|devices|direct-routing-device|enable-l2-neigh-discovery|ipam|enable-gateway-api|gateway-api-|kube-proxy-replacement|cluster-pool|enable-ipv4)' \
    || echo "  Could not read cilium-config"
echo ""

# --- 4. CiliumL2AnnouncementPolicy ---
echo "### 4. CiliumL2AnnouncementPolicy ###"
echo ""
kubectl get ciliuml2announcementpolicies k8s-l2-policy -o yaml 2>/dev/null || echo "  CRD or policy not found"
echo ""

# --- 5. CiliumLoadBalancerIPPool ---
echo "### 5. CiliumLoadBalancerIPPool ###"
echo ""
kubectl get ciliumloadbalancerippools k8s-pool -o yaml 2>/dev/null || echo "  CRD or pool not found"
echo ""

# --- 6. Cilium agent pods + CiliumNodes ---
echo "### 6. Cilium agent pods and CiliumNodes ###"
echo ""
for node in $NODES; do
    pod=$(cilium_pod_for_node "$node")
    echo "  $node: ${pod:-<none>}"
done
echo ""
kubectl get pods -n kube-system -o wide 2>/dev/null | grep -E 'cilium|NAME' || true
echo ""
kubectl get ds cilium -n kube-system 2>/dev/null || echo "  DS not found"
echo ""
kubectl get cnodes -o wide 2>/dev/null || echo "  No CiliumNodes found (agent not registered)"
echo ""

# --- 7. cilium status (agent health, direct) ---
echo "### 7. Cilium status (first agent) ###"
echo ""
FIRST_POD=$(cilium_pod_for_node "$(echo "$NODES" | cut -d' ' -f1)")
if [ -n "$FIRST_POD" ]; then
    kubectl exec -n kube-system "$FIRST_POD" -c cilium-agent -- cilium status 2>/dev/null || \
        echo "  Could not run cilium status"
else
    echo "  No cilium pod"
fi
echo ""

# --- 8. Shared Gateway + its LoadBalancer Service ---
echo "### 8. Shared Gateway and LB service ###"
echo ""
kubectl get gateway shared-gateway -n kube-system -o yaml 2>/dev/null | \
    grep -A5 '^status:' || echo "  Gateway not found"
echo ""
kubectl get svc -n kube-system shared-gateway -o yaml 2>/dev/null || echo "  LB service not found"
echo ""

# --- 9. HTTPRoute ---
echo "### 9. HTTPRoute ###"
echo ""
kubectl get httproute longhorn -n longhorn-system -o yaml 2>/dev/null || echo "  HTTPRoute not found"
echo ""

# --- 10. longhorn-frontend Service ---
echo "### 10. longhorn-frontend Service ###"
echo ""
kubectl get svc longhorn-frontend -n longhorn-system -o yaml 2>/dev/null | grep -E '^  clusterIP|^  type|^    app:' || true
kubectl get endpoints longhorn-frontend -n longhorn-system 2>/dev/null || echo "  Endpoints not found"
echo ""

# --- 11. Per-node L2/announcement logs ---
echo "### 11. Cilium L2 announcement logs (per node) ###"
echo ""
for node in $NODES; do
    pod=$(cilium_pod_for_node "$node")
    [ -z "$pod" ] && continue
    echo "--- $node ($pod) ---"
    kubectl logs -n kube-system "$pod" -c cilium-agent --tail=200 2>/dev/null | \
        grep -iE "l2.?announc|announcement|ens19|${LB_IP//./\.}|loadbalancer.*(serve|proxy)|Creation of|withdrawn" | tail -10 \
        || echo "  no matching log lines"
    echo ""
done

# --- 12. Per-node connectivity to LB IP ---
echo "### 12. Connectivity to $LB_IP from each node ###"
echo ""
for node in $NODES; do
    echo "--- From $node ---"
    exec_on_node "$node" ip route get "$LB_IP" 2>/dev/null || echo "  No route to $LB_IP"
    exec_on_node "$node" bash -c "ping -c 1 -W 2 $LB_IP 2>&1 | tail -2" 2>/dev/null \
        || echo "  Ping failed"
    echo ""
done

# --- 13. ArgoCD Application Status ---
echo "### 13. ArgoCD Application Status ###"
echo ""
kubectl get application -n argocd -o wide 2>/dev/null || echo "  Could not get applications"
echo ""
kubectl describe application cilium-network -n argocd 2>/dev/null | head -30 || echo "  Could not describe cilium-network"
echo ""

echo "=========================================="
echo " Diagnostics complete"
echo "=========================================="
