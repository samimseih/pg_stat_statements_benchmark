#!/usr/bin/env bash
# Copy the sample files of each finished run into archive/<results>/<run>/,
# before a later run of the same build, workload and clients reuses its
# directory.
. "$(dirname "$(readlink -f "$0")")/common.sh"
for f in *_results.txt; do
  [ -f "$f" ] || continue
  while read -r b w c max tps rest; do
    [[ $b == inst-* ]] || continue
    v=$(grep -o 'vcpus=[0-9]*' <<< "$rest" | cut -d= -f2); r=$(grep -o 'rep=[0-9]*' <<< "$rest" | cut -d= -f2)
    d=ab-$b-$w-$c; a=archive/${f%_results.txt}/$b-$w-$c${v:+-v$v}${r:+-r$r}
    [ -d $a ] && continue
    grep -q "tps = $tps " $d/pgbench.log 2>/dev/null || continue
    mkdir -p $a
    cp $d/pgbench.log $d/samples5.txt $d/entry_count.txt $d/age.txt $d/measured_since $a/ 2>/dev/null
  done < $f
done
