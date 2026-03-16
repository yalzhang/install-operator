#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE="confidential-clusters"
MARKETPLACE_NAMESPACE="openshift-marketplace"
MACHINESET_NAMESPACE="openshift-machine-api"

usage() {
    echo "Usage: $0 [--operator-cluster] [--target-cluster] [--machineset <name>] [--all]"
    echo ""
    echo "Options:"
    echo "  --operator-cluster        Clean up operator from external cluster"
    echo "  --target-cluster          Clean up confidential resources from target cluster"
    echo "  --machineset <name>       Specific confidential machineset to remove (used with --target-cluster)"
    echo "  --all                     Clean up both operator and target cluster resources"
    echo "  -h, --help                Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 --operator-cluster                          # Remove operator from external cluster"
    echo "  $0 --target-cluster                            # Remove all confidential machinesets"
    echo "  $0 --target-cluster --machineset machinset-conf-nodes  # Remove specific machineset"
    echo "  $0 --all                                       # Clean everything"
    exit 1
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

cleanup_operator_cluster() {
    log_info "Starting cleanup of Confidential Cluster Operator from external cluster..."
    echo ""

    # Step 1: Delete routes
    log_info "[1/9] Deleting routes..."
    if oc get route kbs-service -n $NAMESPACE &>/dev/null; then
        oc delete route kbs-service -n $NAMESPACE
        log_info "      Deleted route: kbs-service"
    else
        log_warn "      Route kbs-service not found (already deleted or never created)"
    fi

    if oc get route register-server -n $NAMESPACE &>/dev/null; then
        oc delete route register-server -n $NAMESPACE
        log_info "      Deleted route: register-server"
    else
        log_warn "      Route register-server not found (already deleted or never created)"
    fi
    echo ""

    # Step 2: Delete ApprovedImage CR
    log_info "[2/9] Deleting ApprovedImage custom resource..."
    if oc get approvedimage rhcos -n $NAMESPACE &>/dev/null; then
        oc delete approvedimage rhcos -n $NAMESPACE
        log_info "      Deleted ApprovedImage: rhcos"
    else
        log_warn "      ApprovedImage rhcos not found (already deleted or never created)"
    fi
    echo ""

    # Step 3: Delete TrustedExecutionCluster CR
    log_info "[3/9] Deleting TrustedExecutionCluster custom resource..."
    if oc get trustedexecutioncluster confidential-cluster -n $NAMESPACE &>/dev/null; then
        oc delete trustedexecutioncluster confidential-cluster -n $NAMESPACE
        log_info "      Deleted TrustedExecutionCluster: confidential-cluster"
    else
        log_warn "      TrustedExecutionCluster confidential-cluster not found (already deleted or never created)"
    fi
    echo ""

    # Step 4: Delete Subscription
    log_info "[4/9] Deleting Subscription..."
    if oc get subscription confidential-clusters-sub -n $NAMESPACE &>/dev/null; then
        oc delete subscription confidential-clusters-sub -n $NAMESPACE
        log_info "      Deleted Subscription: confidential-clusters-sub"
    else
        log_warn "      Subscription confidential-clusters-sub not found (already deleted or never created)"
    fi
    echo ""

    # Step 5: Wait for CSV to be deleted
    log_info "[5/9] Waiting for ClusterServiceVersion to be deleted..."
    CSV_NAME=$(oc get csv -n $NAMESPACE -o name 2>/dev/null | grep confidential-cluster || true)
    if [ -n "$CSV_NAME" ]; then
        log_info "      Found CSV: $CSV_NAME"
        log_info "      Waiting for CSV deletion (timeout: 60s)..."
        oc wait --for=delete $CSV_NAME -n $NAMESPACE --timeout=60s 2>/dev/null || log_warn "      Timeout waiting for CSV deletion, continuing anyway..."
        log_info "      CSV deleted"
    else
        log_warn "      No ClusterServiceVersion found"
    fi
    echo ""

    # Step 6: Delete OperatorGroup
    log_info "[6/9] Deleting OperatorGroup..."
    if oc get operatorgroup confidential-clusters-og -n $NAMESPACE &>/dev/null; then
        oc delete operatorgroup confidential-clusters-og -n $NAMESPACE
        log_info "      Deleted OperatorGroup: confidential-clusters-og"
    else
        log_warn "      OperatorGroup confidential-clusters-og not found (already deleted or never created)"
    fi
    echo ""

    # Step 7: Delete SecurityContextConstraints
    log_info "[7/9] Deleting SecurityContextConstraints..."
    SCC_NAME="confidential-clusters-trusted-cluster-scc"
    if oc get scc $SCC_NAME &>/dev/null; then
        oc delete scc $SCC_NAME
        log_info "      Deleted SCC: $SCC_NAME"
    else
        log_warn "      SCC $SCC_NAME not found (already deleted or never created)"
    fi
    echo ""

    # Step 8: Delete Namespace
    log_info "[8/9] Deleting namespace..."
    if oc get namespace $NAMESPACE &>/dev/null; then
        oc delete namespace $NAMESPACE
        log_info "      Deleted namespace: $NAMESPACE"
        log_info "      Waiting for namespace deletion (timeout: 120s)..."
        oc wait --for=delete namespace/$NAMESPACE --timeout=120s 2>/dev/null || log_warn "      Timeout waiting for namespace deletion, continuing anyway..."
    else
        log_warn "      Namespace $NAMESPACE not found (already deleted or never created)"
    fi
    echo ""

    # Step 9: Delete CatalogSource
    log_info "[9/9] Deleting CatalogSource..."
    CATALOG_NAME="confidential-cluster-operator-dev-preview"
    if oc get catalogsource $CATALOG_NAME -n $MARKETPLACE_NAMESPACE &>/dev/null; then
        oc delete catalogsource $CATALOG_NAME -n $MARKETPLACE_NAMESPACE
        log_info "      Deleted CatalogSource: $CATALOG_NAME"
    else
        log_warn "      CatalogSource $CATALOG_NAME not found (already deleted or never created)"
    fi
    echo ""

    log_info "✓ Operator cluster cleanup completed!"
}

cleanup_target_cluster() {
    local SPECIFIC_MACHINESET="$1"

    log_info "Starting cleanup of confidential resources from target cluster..."
    echo ""

    # Step 1: Find and scale down confidential machinesets
    log_info "[1/4] Finding and scaling down confidential machinesets..."

    if [ -n "$SPECIFIC_MACHINESET" ]; then
        # Clean up specific machineset
        if oc get machineset "$SPECIFIC_MACHINESET" -n $MACHINESET_NAMESPACE &>/dev/null; then
            CURRENT_REPLICAS=$(oc get machineset "$SPECIFIC_MACHINESET" -n $MACHINESET_NAMESPACE -o jsonpath='{.spec.replicas}')
            if [ "$CURRENT_REPLICAS" -gt 0 ]; then
                log_info "      Scaling down machineset: $SPECIFIC_MACHINESET (replicas: $CURRENT_REPLICAS -> 0)"
                oc scale machineset "$SPECIFIC_MACHINESET" -n $MACHINESET_NAMESPACE --replicas=0
                log_info "      Waiting for machines to be deleted..."
                sleep 5
            else
                log_info "      MachineSet $SPECIFIC_MACHINESET already scaled to 0"
            fi
            MACHINESETS_TO_DELETE=("$SPECIFIC_MACHINESET")
        else
            log_error "      MachineSet $SPECIFIC_MACHINESET not found"
            return 1
        fi
    else
        # Find all machinesets using conf-ignition-secret (confidential machinesets)
        MACHINESETS_TO_DELETE=($(oc get machineset -n $MACHINESET_NAMESPACE -o json | \
            jq -r '.items[] | select(.spec.template.spec.providerSpec.value.userDataSecret.name == "conf-ignition-secret") | .metadata.name'))

        if [ ${#MACHINESETS_TO_DELETE[@]} -eq 0 ]; then
            log_warn "      No confidential machinesets found (no machinesets using conf-ignition-secret)"
        else
            log_info "      Found ${#MACHINESETS_TO_DELETE[@]} confidential machineset(s)"
            for ms in "${MACHINESETS_TO_DELETE[@]}"; do
                CURRENT_REPLICAS=$(oc get machineset "$ms" -n $MACHINESET_NAMESPACE -o jsonpath='{.spec.replicas}')
                if [ "$CURRENT_REPLICAS" -gt 0 ]; then
                    log_info "      Scaling down machineset: $ms (replicas: $CURRENT_REPLICAS -> 0)"
                    oc scale machineset "$ms" -n $MACHINESET_NAMESPACE --replicas=0
                else
                    log_info "      MachineSet $ms already scaled to 0"
                fi
            done
            log_info "      Waiting for machines to be deleted..."
            sleep 10
        fi
    fi
    echo ""

    # Step 2: Delete machinesets
    log_info "[2/4] Deleting confidential machinesets..."
    if [ ${#MACHINESETS_TO_DELETE[@]} -eq 0 ]; then
        log_warn "      No machinesets to delete"
    else
        for ms in "${MACHINESETS_TO_DELETE[@]}"; do
            oc delete machineset "$ms" -n $MACHINESET_NAMESPACE
            log_info "      Deleted machineset: $ms"
            # Delete the generated YAML file if it exists
            if [ -f "${ms}.yaml" ]; then
                rm -f "${ms}.yaml"
                log_info "      Deleted generated file: ${ms}.yaml"
            fi
        done
    fi
    echo ""

    # Step 3: Delete ignition secret
    log_info "[3/4] Deleting ignition secret..."
    IGNITION_SECRET="conf-ignition-secret"
    if oc get secret $IGNITION_SECRET -n $MACHINESET_NAMESPACE &>/dev/null; then
        oc delete secret $IGNITION_SECRET -n $MACHINESET_NAMESPACE
        log_info "      Deleted secret: $IGNITION_SECRET"
        # Delete the temporary ignition file if it exists
        if [ -f "conf-node-ignition" ]; then
            rm -f "conf-node-ignition"
            log_info "      Deleted temporary file: conf-node-ignition"
        fi
    else
        log_warn "      Secret $IGNITION_SECRET not found (already deleted or never created)"
    fi
    echo ""

    # Step 4: Delete MachineConfig (optional - ask for confirmation)
    log_info "[4/4] Checking for MachineConfig..."
    MACHINE_CONFIG="99-worker-custom-image"
    if oc get machineconfig $MACHINE_CONFIG &>/dev/null; then
        log_warn "      Found MachineConfig: $MACHINE_CONFIG"
        log_warn "      This affects all worker nodes. Do you want to delete it? (y/N)"
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            oc delete machineconfig $MACHINE_CONFIG
            log_info "      Deleted MachineConfig: $MACHINE_CONFIG"
        else
            log_info "      Skipping MachineConfig deletion"
        fi
    else
        log_warn "      MachineConfig $MACHINE_CONFIG not found"
    fi
    echo ""

    log_info "✓ Target cluster cleanup completed!"
}

# Parse command line arguments
CLEAN_OPERATOR=false
CLEAN_TARGET=false
SPECIFIC_MACHINESET=""

if [ $# -eq 0 ]; then
    usage
fi

while [[ $# -gt 0 ]]; do
    case $1 in
        --operator-cluster)
            CLEAN_OPERATOR=true
            shift
            ;;
        --target-cluster)
            CLEAN_TARGET=true
            shift
            ;;
        --machineset)
            SPECIFIC_MACHINESET="$2"
            shift 2
            ;;
        --all)
            CLEAN_OPERATOR=true
            CLEAN_TARGET=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Execute cleanup based on flags
if [ "$CLEAN_OPERATOR" = true ]; then
    cleanup_operator_cluster
    echo ""
fi

if [ "$CLEAN_TARGET" = true ]; then
    cleanup_target_cluster "$SPECIFIC_MACHINESET"
    echo ""
fi

log_info "All cleanup operations completed successfully!"
