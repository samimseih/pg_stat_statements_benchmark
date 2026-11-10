# EC2 fleet

`launch_fleet.sh` launches one instance per type in `TYPES`.  Each one
clones PostgreSQL (`PG_REMOTE`), the patch commits (`PATCH_REMOTE`) and this
repository (`BENCHMARK_REPO`), builds upstream and the patches, runs
`run_pgss_benchmark_suite.sh` on them, interleaved, uploads its results to S3
and terminates itself, also on failure.  See the `pgss-benchmark` skill for
the whole procedure.

## Setup

`aws.config`, kept out of git:

```sh
AWS_ACCOUNT_ID=...
AWS_REGION=...
AWS_PROFILE=...   # optional
```

Use an account meant for benchmarks.  The first launch creates, or reuses:

- the S3 bucket `pgss-benchmark-<account>-<region>`, for the results
- an IAM role and instance profile for SSM and the result uploads
- a security group without ingress rules: instances are reached through SSM

Settings and their defaults are in `benchmark.config`; set `VPC_ID` and
`SUBNET_ID` if the account has no default VPC.

## Run

```sh
BASE=<upstream hash> PATCH=<hash> EXTRA="<more hashes>" \
  TYPES="c7i.8xlarge c7i.48xlarge" SECS=180 \
  setsid nohup ./launch_fleet.sh > state/launch.log 2>&1 < /dev/null &
./fetch_fleet_status.sh "$(cat state/current_fleet)"
python3 ../report_datapoints.py fleet results/fleet/"$(cat state/current_fleet)"
```

`state/<fleet>.instances` lists the instances of the fleet.  Instances that
end without results are relaunched, twice at most.

## Other scripts

- `launch_benchmark_instance.sh`: one instance, with the settings of
  `benchmark.config`; `launch_fleet.sh` calls it.
- `connect_instance.sh`: an SSM session on the latest instance launched,
  or that of a run id.
- `push_worktree_patch.sh`, `user_data_profile.sh`: try uncommitted changes,
  or profile with perf, on an instance.
