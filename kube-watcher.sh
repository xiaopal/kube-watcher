#!/bin/bash

set -o pipefail

log(){
  local LEVEL="${1^^}" && shift
  echo "[ $(date -R) ] $LEVEL - $*" >&2
}

#kubectl(){
#  local ARGS='kubectl'; for ARG in "$@"; do ARGS="$ARGS '$ARG'"; done; log DEBUG "$ARGS"
#  "$(which kubectl)" "$@"
#}

do_watch(){
  local WATCH_ARGS=(-o 'custom-columns=NAME:.metadata.name,KIND:.kind,APIVERSION:.apiVersion,NAMESPACE:.metadata.namespace' --no-headers) \
    ARG ARG_VAL \
    WATCH_KUBECONFIG="${WATCH_KUBECONFIG:-$KUBECONFIG}" \
    WATCH_NAMESPACE="$WATCH_NAMESPACE" \
    INCLUDE="$WATCH_INCLUDE" \
    INCLUDE_NAMESPACE="$WATCH_INCLUDE_NAMESPACE" \
    INCLUDE_REGEX="$WATCH_INCLUDE_REGEX" \
    INCLUDE_NAMESPACE_REGEX="$WATCH_INCLUDE_NAMESPACE_REGEX"
    CHECKSUM_HOLDER="$WATCH_CHECKSUM" \
    CHECKSUM_JQ="$WATCH_CHECKSUM_JQ" \
    FINALIZER="$WATCH_FINALIZER" \
    EXEC_CREATE="$WATCH_EXEC_CREATE" \
    EXEC_UPDATE="$WATCH_EXEC_UPDATE" \
    EXEC_DELETE="$WATCH_EXEC_DELETE" \
    WATCH_ALL_NAMESPACES="$WATCH_ALL_NAMESPACES"

  while ARG="$1" && shift; do
    case "$ARG" in
    "--kubeconfig")
      WATCH_KUBECONFIG="$1" && shift || return 1
      ;;
    "-n"|"--namespace")
      WATCH_NAMESPACE="$1" && shift || return 1
      ;;
    "--include")
      INCLUDE="$1" && shift || return 1
      ;;
    "--include-regex")
      INCLUDE_REGEX="$1" && shift || return 1
      ;;
    "--all-namespaces")
      WATCH_ALL_NAMESPACES='Y'
      ;;
    "--include-namespace")
      INCLUDE_NAMESPACE="$1" && shift || return 1
      ;;
    "--include-namespace-regex")
      INCLUDE_NAMESPACE_REGEX="$1" && shift || return 1
      ;;
    "--checksum")
      CHECKSUM_HOLDER="$1" && shift || return 1
      ;;
    "--checksum-jq")
      CHECKSUM_JQ="$1" && shift || return 1
      ;;
    "--finalizer")
      FINALIZER="$1" && shift || return 1
      ;;
    "--exec-create")
      EXEC_CREATE="$1" && shift || return 1
      ;;
    "--exec-update")
      EXEC_UPDATE="$1" && shift || return 1
      ;;
    "--exec-delete")
      EXEC_DELETE="$1" && shift || return 1
      ;;
    "--")
      WATCH_ARGS=("${WATCH_ARGS[@]}" "$@")
      break
      ;;
    *)
      WATCH_ARGS=("${WATCH_ARGS[@]}" "$ARG")
      ;;
    esac
  done
  [ ! -z "$FINALIZER" ] || FINALIZER='xiaopal.github.com/kube-watcher'
  [ ! -z "$CHECKSUM_HOLDER" ] || CHECKSUM_HOLDER='kube-watcher.xiaopal.github.com/checksum'

  [ ! -z "$WATCH_ALL_NAMESPACES" ] && WATCH_NAMESPACE=""
  [ ! -z "$WATCH_NAMESPACE" ] && WATCH_ARGS=(--namespace "$WATCH_NAMESPACE" "${WATCH_ARGS[@]}")
  [ ! -z "$WATCH_KUBECONFIG" ] && export KUBECONFIG="$WATCH_KUBECONFIG"

  [ ! -z "$WATCH_RESOURCE" ] && WATCH_ARGS=("${WATCH_ARGS[@]}" "$WATCH_RESOURCE")

  handle_all(){
    local TARGET_SEQ=0 TARGET_NAME TARGET_KIND TARGET_APIVERSION TARGET_NAMESPACE TARGET_GROUP TARGET_VERSION TARGET_TYPE TARGET_TYPE_NAME
    while read -r TARGET_NAME TARGET_KIND TARGET_APIVERSION TARGET_NAMESPACE; do
      [ ! -z "$TARGET_KIND" ] && [ ! -z "$TARGET_APIVERSION" ] && [ ! -z "$TARGET_NAME" ] || continue

      # filter by pattern
      [ -z "$INCLUDE_NAMESPACE" ] || [ -z "$TARGET_NAMESPACE" ] || [[ "$TARGET_NAMESPACE" == $INCLUDE_NAMESPACE ]] || continue
      [ -z "$INCLUDE_NAMESPACE_REGEX" ] || [ -z "$TARGET_NAMESPACE" ] || [[ "$TARGET_NAMESPACE" =~ $INCLUDE_NAMESPACE_REGEX ]] || continue
      [ -z "$INCLUDE" ] || [[ "$TARGET_NAME" == $INCLUDE ]] || continue
      [ -z "$INCLUDE_REGEX" ] || [[ "$TARGET_NAME" =~ $INCLUDE_REGEX ]] || continue

      IFS='/' read -r TARGET_GROUP TARGET_VERSION <<<"$TARGET_APIVERSION" || continue
      [ ! -z "$TARGET_VERSION" ] || { TARGET_VERSION="$TARGET_GROUP"; TARGET_GROUP=""; }
      TARGET_TYPE="$TARGET_KIND.$TARGET_VERSION.$TARGET_GROUP"
      TARGET_TYPE_NAME="$TARGET_TYPE/$TARGET_NAME"
      (( TARGET_SEQ ++ ))

      local TARGET="$WATCH_STAGE/CURRENT"
      kubectl get --ignore-not-found -o json -n "$TARGET_NAMESPACE" "$TARGET_TYPE_NAME" | jq '.' >"$TARGET" && \
      TARGET="$TARGET" \
      TARGET_TYPE_NAME="$TARGET_TYPE_NAME" \
      TARGET_SEQ="$TARGET_SEQ" \
      TARGET_KIND="$TARGET_KIND" \
      TARGET_APIVERSION="$TARGET_APIVERSION" \
      TARGET_TYPE="$TARGET_TYPE" \
      TARGET_NAME="$TARGET_NAME" \
      TARGET_NAMESPACE="$TARGET_NAMESPACE" \
      handle_one "$@" || return 1
    done
  }

  handle_one(){
    jq -se 'length > 0' "$TARGET" >/dev/null || {
      log INFO "$TARGET_TYPE_NAME: destroyed"
      return 0
    }
    local DELETION_TIMESTAMP="$(jq -r '.metadata.deletionTimestamp//empty' "$TARGET")" \
      FINALIZER_FOUND="$(export FINALIZER; jq -r '.metadata.finalizers[]?|select(. == env.FINALIZER)' "$TARGET")"

    [ ! -z "$DELETION_TIMESTAMP" ] && {
      [ ! -z "$FINALIZER_FOUND" ] || return 0
      [ -z "$EXEC_DELETE" ] || bash -c "$EXEC_DELETE" || {
        log ERR "$TARGET_TYPE_NAME: failed to execute - $EXEC_DELETE"
        return 1
      }
      kubectl patch -n "$TARGET_NAMESPACE" "$TARGET_TYPE_NAME" --type='merge' -p "$(export FINALIZER; jq -c '{
        metadata: { 
          finalizers: (.metadata.finalizers//[]|map(select(. != env.FINALIZER))) 
        }
      }' "$TARGET")" || return 1
      return 0
    }

    local CHECKSUM="$(export CHECKSUM_HOLDER; jq -Sc '. + {
        metadata: {
          labels: (.metadata.labels//{}),
          annotations: (.metadata.annotations//{}),
          finalizers: (.metadata.finalizers//[])
        }
      } | del(
        .status,
        .metadata.namespace,
        .metadata.uid,
        .metadata.selfLink,
        .metadata.resourceVersion,
        .metadata.creationTimestamp,
        .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"],
        .metadata.annotations[env.CHECKSUM_HOLDER],
        .metadata.finalizers
      )'"${CHECKSUM_JQ:+|$CHECKSUM_JQ}" "$TARGET" | md5sum | cut -d' ' -f-1)"

    [ ! -z "$FINALIZER_FOUND" ] || {
      [ -z "$EXEC_CREATE" ] || bash -c "$EXEC_CREATE" || {
        log ERR "$TARGET_TYPE_NAME: failed to execute - $EXEC_CREATE"
        return 1
      }
      kubectl patch -n "$TARGET_NAMESPACE" "$TARGET_TYPE_NAME" --type='merge' -p "$(export FINALIZER CHECKSUM_HOLDER CHECKSUM; jq -c '{
        metadata: {
          annotations: { (env.CHECKSUM_HOLDER):env.CHECKSUM },
          finalizers: (.metadata.finalizers//[]|map(select(. != env.FINALIZER))+[env.FINALIZER]) 
        }
      }' "$TARGET")" || return 1
      return 0
    }
    [ ! -z "$EXEC_UPDATE" ] && \
    local CHECKSUM_FOUND="$(export CHECKSUM_HOLDER; jq -r '.metadata.annotations[env.CHECKSUM_HOLDER]//empty' "$TARGET")" && \
    [ "$CHECKSUM" != "$CHECKSUM_FOUND" ] || return 0

    bash -c "$EXEC_UPDATE" || {
      log ERR "$TARGET_TYPE_NAME: failed to execute - $EXEC_UPDATE"
      return 1
    }
    kubectl patch -n "$TARGET_NAMESPACE" "$TARGET_TYPE_NAME" --type='merge' -p "$(export CHECKSUM_HOLDER CHECKSUM; jq -c '{
      metadata: { 
        annotations: { (env.CHECKSUM_HOLDER):env.CHECKSUM }
      }
    }' "$TARGET")" || return 1
  }

  ( export WATCH_STAGE="$(mktemp -d)" && trap "log INFO 'exiting...'; rm -rf '$WATCH_STAGE'" EXIT
    log INFO "watching resources...${WATCH_ALL_NAMESPACES:+(all namespaces)}"
    handle_all < <(while true; do kubectl get --watch "${WATCH_ARGS[@]}"; done) || exit 1
  ) || {
    log ERR "Failed during watch"
    return 1
  }
}

do_watch "$@"
