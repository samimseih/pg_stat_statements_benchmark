# pg_stat_statements EC2 benchmark setup

Helper scripts for launching the pg_stat_statements benchmark suite on EC2.
Account-specific settings, generated state, and fetched results are kept out of
git by `ec2-setup/.gitignore`.

`aws.config` is local-only and should contain:

```sh
AWS_ACCOUNT_ID=...
AWS_REGION=...
# Optional, if using a named AWS CLI profile:
AWS_PROFILE=...
```

The default benchmark target is:

```sh
INSTANCE_TYPE=c7i.8xlarge
AMI=AL2023 x86_64
ACCESS=SSM
PATCH_REF=samimseih/postgres:pg_stat_statements_v14
BASE_REF=postgres/postgres:master
```

The instance clones PostgreSQL from GitHub, adds the `samimseih` fork as a
remote, builds a release Meson tree, clones the public benchmark repo, and runs
the configured suite.  Results are uploaded to S3 before the instance shuts
down.  If the benchmark fails, the instance is left running by default for
inspection.

## Auth

The scripts use the local AWS CLI.  Authenticate first, then verify:

```sh
aws sts get-caller-identity --region "$(awk -F= '/^AWS_REGION=/ {print $2}' aws.config)"
```

## Launch

```sh
./launch_benchmark_instance.sh
```

Useful overrides:

```sh
INSTANCE_TYPE=c7i.8xlarge ./launch_benchmark_instance.sh
HOTCOLD_SECONDS=300 SELECT_SECONDS=300 ./launch_benchmark_instance.sh
RUN_HOTCOLD_4000_1500=0 ./launch_benchmark_instance.sh
RUN_ORDER=interleaved ./launch_benchmark_instance.sh
AUTO_TERMINATE=0 ./launch_benchmark_instance.sh
```

`RUN_ORDER=interleaved` builds each tested commit once into its own install
prefix, then alternates patch/baseline per client point with a fresh `initdb`
for each point.

The launch script creates, or reuses, these account resources:

- S3 bucket for result uploads
- IAM role and instance profile with SSM and result-upload permissions
- SSM-only security group with no ingress rules

If the account does not have a default VPC, set `VPC_ID` and `SUBNET_ID`.

## Status And Results

```sh
./status_instance.sh
./live_status.sh
./fetch_results.sh
./analyze_results.sh
```

`live_status.sh` uses SSM to show the current benchmark phase, completed
summary rows, failures, and the most recent TPS rows while the instance is
still running.  For the raw process list and benchmark log tail:

```sh
LIVE_VERBOSE=1 ./live_status.sh
```

Results are copied to:

```sh
results/<run-id>/
```

`analyze_results.sh` accepts either a run id or a result subdirectory:

```sh
./analyze_results.sh
./analyze_results.sh pgss-2p5h-20261015T122532Z
./analyze_results.sh results/pgss-2p5h-20261015T122532Z
```

It extracts the result tarball if needed, runs the public benchmark report
generator, and writes `report.md` next to the tarball.

## Connect

Once SSM reports the instance as online:

```sh
./connect_instance.sh
```

This sources `aws.config` and `state/latest.env`, then runs
`aws ssm start-session` for the latest launched instance.  It starts a login
shell as `ec2-user`, which is the user that runs the benchmark.  To get the
raw Session Manager user instead:

```sh
CONNECT_USER=ssm-user ./connect_instance.sh
```

## Terminate

The instance is launched with instance-initiated shutdown behavior set to
terminate.  On a successful upload, `AUTO_TERMINATE=1` shuts the instance down.

Manual termination:

```sh
./terminate_instance.sh
```
