#!/usr/bin/env bash
# Launch a fleet: one instance per type in TYPES, each building upstream
# (BASE) and the patch commits (PATCH, then EXTRA) and running the suite on
# them, interleaved, then uploading its results to S3 and terminating itself,
# also on failure.
#
# Each type is launched in parallel: first in the subnet the launcher chooses
# itself, then, on a failure such as InsufficientInstanceCapacity, in each
# other subnet of the default VPC with internet access, then again every 10
# minutes, for up to 24 hours.  A watchdog then follows each instance: one
# that terminates without its results in S3 is relaunched, at most twice per
# type.
#
# usage: BASE=<full hash> PATCH=<full hash> [EXTRA="<full hashes>"]
#        [FLEET=<name>] [TYPES="c7i.8xlarge ..."] [CLIENTS="1 2 4 ..."]
#        [SECS=180] [RUN100M=1] [RUN1500=1] [RUNSEL=1] [TRICKLE=0]
#        launch_fleet.sh
# Run it detached; it returns when every type is done.  The fleet name is
# written to state/current_fleet, its instances (type, instance id, attempt,
# run id) to state/<fleet>.instances.
set -u
cd "$(dirname "$(readlink -f "$0")")" || exit 1
set -a; . ./aws.config; . ./benchmark.config; set +a
[ -n "${BASE:-}" ] && [ -n "${PATCH:-}" ] || { echo "BASE and PATCH are required" >&2; exit 1; }
SECS=${SECS:-180}
FLEET=${FLEET:-pgss-${PATCH:0:7}-${SECS}s-$(date -u +%Y%m%dT%H%MZ)}
mkdir -p state
echo "$FLEET" > state/current_fleet
INSTANCES=$PWD/state/$FLEET.instances
TYPES=${TYPES:-"c7i.large c7i.2xlarge c7i.8xlarge c7i.24xlarge c7i.48xlarge"}
EXTRA=${EXTRA:-}
CLIENTS=${CLIENTS:-"1 2 4 8 16 32 64 128 256 512"}
common=(PATCH_COMMIT=$PATCH EXTRA_COMMITS="$EXTRA" BASE_COMMIT=$BASE
	CLIENTS="$CLIENTS" SELECT_CLIENTS="$CLIENTS"
	HOTCOLD_100M_CLIENTS="$CLIENTS" HOTCOLD_1500_CLIENTS="$CLIENTS"
	HOTCOLD_SECONDS=$SECS SELECT_SECONDS=$SECS TRICKLE_SECONDS=$SECS
	RUN_HOTCOLD_4000_100M=${RUN100M:-1} RUN_HOTCOLD_4000_1500=${RUN1500:-1}
	RUN_SELECT_ONLY=${RUNSEL:-1} RUN_TRICKLE_5000=${TRICKLE:-0}
	RUN_ORDER=interleaved MAX_CONNECTIONS=600
	AUTO_SHUTDOWN=terminate SHUTDOWN_ON_FAILURE=1)
log() { echo "$(date -u +%FT%TZ) $*"; }

# Does the route table have an active default route to the internet?
has_egress() {
	aws ec2 describe-route-tables --route-table-ids "$1" \
		--query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0' && State=='active'].GatewayId" \
		--output text | grep -qE 'igw-|nat-'
}

# Subnets of the default VPC with internet access, as the launcher's own
# default_subnet_id() requires
egress_subnets() {
	local vpc main subnet rt
	vpc=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
		--query 'Vpcs[0].VpcId' --output text)
	main=$(aws ec2 describe-route-tables \
		--filters "Name=vpc-id,Values=$vpc" Name=association.main,Values=true \
		--query 'RouteTables[0].RouteTableId' --output text)
	for subnet in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc" \
		--query 'Subnets[].SubnetId' --output text); do
		rt=$(aws ec2 describe-route-tables \
			--filters "Name=association.subnet-id,Values=$subnet" \
			--query 'RouteTables[0].RouteTableId' --output text)
		if [ -z "$rt" ] || [ "$rt" = None ]; then
			rt=$main
		fi
		has_egress "$rt" && echo "$subnet"
	done
}

# Launch one instance of "type", as attempt "n"; print its id and run id
launch_one() {
	local type=$1 n=$2 deadline=$(( $(date +%s) + 24 * 3600 )) out subnet run_id id
	run_id="$FLEET-${type//./-}"
	[ "$n" -gt 1 ] && run_id="$run_id-r$n"
	while [ "$(date +%s)" -lt "$deadline" ]; do
		# "" first: the subnet the launcher chooses itself
		for subnet in "" $(egress_subnets); do
			out=$(env "${common[@]}" RUN_ID="$run_id" INSTANCE_TYPE="$type" \
				${subnet:+SUBNET_ID=$subnet} ./launch_benchmark_instance.sh 2>&1)
			if [ $? -eq 0 ]; then
				id=$(echo "$out" | sed -n 's/^Instance ID: //p')
				log "$type: attempt $n launched $id in ${subnet:-the launcher subnet}, run $run_id" >&2
				echo "$type $id $n $run_id" >> "$INSTANCES"
				echo "$id $run_id"
				return 0
			fi
			log "$type: ${subnet:-the launcher subnet} failed: $(echo "$out" | grep -m1 -iE 'error|capacity|die|failed' | cut -c1-200)" >&2
		done
		log "$type: all subnets failed, retrying in 10 minutes" >&2
		sleep 600
	done
	log "$type: gave up launching after 24 hours" >&2
	return 1
}

results_uploaded() {
	aws s3 ls "s3://$RESULT_BUCKET/$RESULT_PREFIX/$1/$1.results.tar.gz" >/dev/null 2>&1
}

# Follow one instance type until its benchmark uploads results, relaunching it
# at most twice when it terminates without them
follow() {
	local type=$1 n=1 id run_id state launched online
	read -r id run_id < <(launch_one "$type" $n)
	[ -n "${id:-}" ] || return 1
	launched=$(date +%s)
	online=0
	while true; do
		sleep 120
		if results_uploaded "$run_id"; then
			log "$type: $id done, results uploaded"
			return 0
		fi
		if [ $online = 0 ]; then
			if aws ssm describe-instance-information \
				--filters "Key=InstanceIds,Values=$id" \
				--query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null | grep -q Online; then
				online=1
				log "$type: $id online in SSM"
			elif [ $(( $(date +%s) - launched )) -gt 1200 ]; then
				online=2
				log "$type: $id not online in SSM after 20 minutes; it should fail and terminate itself"
			fi
		fi
		state=$(aws ec2 describe-instances --instance-ids "$id" \
			--query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null)
		case "$state" in
			terminated|shutting-down|stopped)
				# The results archive may land just before the shutdown
				sleep 60
				if results_uploaded "$run_id"; then
					log "$type: $id done, results uploaded"
					return 0
				fi
				log "$type: $id $state without results (see s3://$RESULT_BUCKET/$RESULT_PREFIX/$run_id/ and its console output)"
				if [ $n -ge 3 ]; then
					log "$type: giving up after $n attempts"
					return 1
				fi
				n=$((n + 1))
				read -r id run_id < <(launch_one "$type" $n)
				[ -n "${id:-}" ] || return 1
				launched=$(date +%s)
				online=0
				;;
		esac
	done
}

log "fleet $FLEET: $TYPES"
for t in $TYPES; do
	follow "$t" &
	sleep 20
done
wait
log "fleet $FLEET: all instance types finished"
