#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

load_config
load_latest_state "${1:-}"

REMOTE_RESULT_ROOT="/home/ec2-user/pgss-benchmark/results/$RUN_ID"

commands_file="$(mktemp)"
remote_script="$(mktemp)"
trap 'rm -f "$commands_file" "$remote_script"' EXIT

cat >"$remote_script" <<'REMOTE'
#!/usr/bin/env bash
set -eu

root="$1"
run_id="$2"

fmt_bytes() {
  awk -v value="${1:-0}" '
    function human(n, units, i) {
      split("B KiB MiB GiB TiB", units, " ")
      for (i = 1; n >= 1024 && i < 5; i++)
        n /= 1024
      if (i == 1)
        return sprintf("%.0f %s", n, units[i])
      if (n < 10)
        return sprintf("%.1f %s", n, units[i])
      return sprintf("%.0f %s", n, units[i])
    }
    BEGIN { print human(value + 0) }'
}

point_dir="$(
  find "$root" -path '*/monitor_pgss.tsv' -type f -printf '%T@ %h\n' 2>/dev/null |
    sort -n |
    tail -1 |
    cut -d' ' -f2-
)"

if [ -z "$point_dir" ]; then
  echo "no pg_stat_statements samples yet"
  exit 0
fi

pgss_file="$point_dir/monitor_pgss.tsv"
qtext_file="$point_dir/monitor_qtext_file.tsv"
final_file="$point_dir/final_info.tsv"

echo "Run:        $run_id"
echo "Point:      ${point_dir#$root/}"
echo

awk -F '\t' '
  NR == 1 { next }
  NF >= 12 {
    sample = int($1 + 0)
    bucket = $2
    entries = $3 + 0

    samples[sample] = 1
    totals[sample] += entries
    bucket_entries[sample, bucket] = entries

    if (totals[sample] > max_entries)
      max_entries = totals[sample]
    if (entries > bucket_max[bucket])
      bucket_max[bucket] = entries

    dealloc = $8 + 0
    if (dealloc > max_dealloc)
      max_dealloc = dealloc

    entry_dsa = $9 + 0
    qtext_dsa = $10 + 0
    qtext_count = $11 + 0
    qtext_total = $12 + 0

    sample_entry_dsa[sample] = entry_dsa
    sample_qtext_dsa[sample] = qtext_dsa
    sample_qtext_count[sample] = qtext_count
    sample_qtext_total[sample] = qtext_total

    if (sample > last_sample)
      last_sample = sample
  }
  END {
    for (sample in samples) {
      nsamples++
      entries = totals[sample] + 0
      sum_entries += entries

      if (!seen || entries < min_entries)
        min_entries = entries
      seen = 1

      for (bucket in bucket_max)
        bucket_sum[bucket] += bucket_entries[sample, bucket] + 0

      sum_entry_dsa += sample_entry_dsa[sample] + 0
      sum_qtext_dsa += sample_qtext_dsa[sample] + 0
      sum_qtext_count += sample_qtext_count[sample] + 0
      sum_qtext_total += sample_qtext_total[sample] + 0
    }

    if (nsamples == 0) {
      print "samples:    0"
      exit
    }

    printf "samples:    %d\n", nsamples
    printf "entries:    avg=%.0f min=%d max=%d last=%d\n",
           sum_entries / nsamples, min_entries, max_entries,
           totals[last_sample] + 0
    printf "dealloc:    max=%d\n", max_dealloc
    print  "buckets:    bucket avg max last"

    for (bucket in bucket_max)
      printf "            %s %.0f %d %d\n", bucket,
             bucket_sum[bucket] / nsamples, bucket_max[bucket],
             bucket_entries[last_sample, bucket] + 0

    printf "entry_dsa:  avg=%.0f last=%d\n",
           sum_entry_dsa / nsamples, sample_entry_dsa[last_sample] + 0
    printf "qtext_dsa:  avg=%.0f last=%d\n",
           sum_qtext_dsa / nsamples, sample_qtext_dsa[last_sample] + 0
    printf "qtext_mem:  count_avg=%.0f count_last=%d total_len_avg=%.0f total_len_last=%d\n",
           sum_qtext_count / nsamples, sample_qtext_count[last_sample] + 0,
           sum_qtext_total / nsamples, sample_qtext_total[last_sample] + 0
  }' "$pgss_file"

if [ -s "$qtext_file" ]; then
  qtext_summary="$(
    awk -F '\t' '
      NR == 1 { next }
      {
        n++
        size = $2 + 0
        sum += size
        if (size > max)
          max = size
        last = size
      }
      END {
        if (n == 0)
          exit
        printf "%.0f\t%d\t%d\n", sum / n, max, last
      }' "$qtext_file"
  )"

  if [ -n "$qtext_summary" ]; then
    IFS="$(printf '\t')" read -r qtext_avg qtext_max qtext_last <<EOF
$qtext_summary
EOF
    printf "qtext_file: avg=%s max=%s last=%s\n" \
      "$(fmt_bytes "$qtext_avg")" \
      "$(fmt_bytes "$qtext_max")" \
      "$(fmt_bytes "$qtext_last")"
  fi
fi

if [ -s "$final_file" ]; then
  awk -F '\t' '
    NR == 1 {
      for (i = 1; i <= NF; i++)
        col[$i] = i
      next
    }
    NR == 2 {
      printf "final:      dealloc=%s entries=%s entry_dsa=%s qtext_dsa=%s qtext_count=%s qtext_total_len=%s qtext_file=%s\n",
             $col["final_entry_dealloc"], $col["final_entry_count"],
             $col["final_entry_dsa_size"], $col["final_qtext_dsa_size"],
             $col["final_qtext_count"], $col["final_qtext_total_len"],
             $col["final_qtext_file_size"]
    }' "$final_file"
fi
REMOTE

encoded_script="$(base64 -w0 "$remote_script")"

cat >"$commands_file" <<JSON
{
  "commands": [
    "echo '$encoded_script' | base64 -d >/tmp/pgss-sample-status.sh",
    "bash /tmp/pgss-sample-status.sh '$REMOTE_RESULT_ROOT' '$RUN_ID'"
  ]
}
JSON

cmd_id="$(aws_cmd ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters "file://$commands_file" \
  --query 'Command.CommandId' \
  --output text)"

aws_cmd ssm wait command-executed \
  --command-id "$cmd_id" \
  --instance-id "$INSTANCE_ID" || true

aws_cmd ssm get-command-invocation \
  --command-id "$cmd_id" \
  --instance-id "$INSTANCE_ID" \
  --query 'StandardOutputContent' \
  --output text
