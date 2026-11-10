#!/usr/bin/env bash
#
# Set the online logical CPUs.
#
#   set_cpus.sh              bring all CPUs online
#   set_cpus.sh N            keep CPUs 0..N-1 online
#   set_cpus.sh LIST         keep the CPUs of LIST online, e.g. 0-3,16-19
#   set_cpus.sh --expand X   print the CPUs of a LIST or count X, one per line
#
# Prints the resulting online list.  CPU0 usually cannot be taken offline, so
# it stays online even if LIST omits it; callers compare the result.  Writing
# the sysfs files needs root, so this uses "sudo -n" when not run as root.
set -Eeuo pipefail

SYS=/sys/devices/system/cpu

die() {
  echo "error: $*" >&2
  exit 1
}

expand() {
  local spec="$1" part lo hi i

  if [[ "$spec" =~ ^[0-9]+$ ]]; then
    (( spec > 0 )) || die "CPU count must be positive"
    for ((i = 0; i < spec; i++)); do echo "$i"; done
    return
  fi
  [[ "$spec" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]] || die "bad CPU list: $spec"
  IFS=',' read -ra parts <<<"$spec"
  for part in "${parts[@]}"; do
    lo=${part%-*}
    hi=${part#*-}
    (( lo <= hi )) || die "bad CPU range: $part"
    for ((i = lo; i <= hi; i++)); do echo "$i"; done
  done | sort -n -u
}

set_online() {
  local path="$SYS/cpu$1/online" state="$2"

  [[ -e "$path" ]] || return 0
  [[ "$(cat "$path")" == "$state" ]] && return 0
  if [[ -w "$path" ]]; then
    echo "$state" >"$path"
  else
    echo "$state" | sudo -n tee "$path" >/dev/null || die "cannot write $path"
  fi
}

if [[ "${1:-}" == "--expand" ]]; then
  expand "${2:?}"
  exit 0
fi

declare -A want=()
all=()
for dir in "$SYS"/cpu[0-9]*; do
  all+=("${dir##*/cpu}")
done

if [[ -n "${1:-}" ]]; then
  while read -r cpu; do
    [[ -d "$SYS/cpu$cpu" ]] || die "no such CPU: $cpu"
    want[$cpu]=1
  done < <(expand "$1")
else
  for cpu in "${all[@]}"; do want[$cpu]=1; done
fi

# Bring wanted CPUs online before taking others offline
for cpu in "${all[@]}"; do
  [[ -n "${want[$cpu]:-}" ]] && set_online "$cpu" 1
done
for cpu in "${all[@]}"; do
  [[ -z "${want[$cpu]:-}" ]] && set_online "$cpu" 0
done

cat "$SYS/online"
