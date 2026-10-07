#!/bin/sh
# read-config.sh [workspaces.conf]
# Parse a workspaces config (see workspaces.example.conf) and print one
# normalized line per workspace, pipe-separated with every field filled in:
#
#   name|url|icon-abs-path-or-empty|store-uuid
#
# Used by build-combined.sh. An omitted store-uuid is derived from the name
# (stable across rebuilds; renaming a workspace therefore gives it a fresh,
# signed-out store).

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
CONF="${1:-${CONFIG:-$HERE/workspaces.conf}}"

if [ ! -f "${CONF}" ]; then
  echo "no config at ${CONF}" >&2
  echo "copy the example and edit it:  cp ${HERE}/workspaces.example.conf ${HERE}/workspaces.conf" >&2
  exit 2
fi
CONF_DIR=$(cd "$(dirname "${CONF}")" && pwd)

trim() { printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

n=0
while IFS='|' read -r name url icon store || [ -n "${name}" ]; do
  name=$(trim "${name}")
  case "${name}" in ''|'#'*) continue ;; esac
  url=$(trim "${url:-}"); icon=$(trim "${icon:-}"); store=$(trim "${store:-}")
  if [ -z "${url}" ]; then
    echo "${CONF}: workspace '${name}' has no URL" >&2
    exit 2
  fi

  if [ -n "${icon}" ]; then
    case "${icon}" in
      '~/'*) icon="${HOME}/${icon#\~/}" ;;
      /*) ;;
      *) icon="${CONF_DIR}/${icon}" ;;
    esac
    if [ ! -f "${icon}" ]; then
      echo "${CONF}: icon for '${name}' not found: ${icon}" >&2
      exit 2
    fi
  fi

  if [ -z "${store}" ]; then
    h=$(printf 'workspace-store:%s' "${name}" | md5 -q 2>/dev/null || printf 'workspace-store:%s' "${name}" | md5sum | cut -c1-32)
    # Shape the hash as an RFC 4122 v4-style UUID (version 4, variant 8).
    store=$(printf '%s' "${h}" | tr '[:lower:]' '[:upper:]' |
      sed -E 's/^(.{8})(.{4}).(.{3}).(.{3})(.{12})$/\1-\2-4\3-8\4-\5/')
  fi

  printf '%s|%s|%s|%s\n' "${name}" "${url}" "${icon}" "${store}"
  n=$((n + 1))
done < "${CONF}"

if [ "${n}" -eq 0 ]; then
  echo "${CONF}: no workspaces defined" >&2
  exit 2
fi
