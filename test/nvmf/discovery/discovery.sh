#!/usr/bin/env bash

testdir=$(readlink -f $(dirname $0))
rootdir=$(readlink -f $testdir/../../..)
source $rootdir/test/common/autotest_common.sh
source $rootdir/test/nvmf/common.sh

NULL_BDEV_SIZE=102400
NULL_BLOCK_SIZE=512

rpc_py="python $rootdir/scripts/rpc.py"

set -e

if ! hash nvme; then
	echo "nvme command not found; skipping discovery test"
	exit 0
fi

RDMA_IP_LIST=$(get_available_rdma_ips)
NVMF_FIRST_TARGET_IP=$(echo "$RDMA_IP_LIST" | head -n 1)
if [ -z $NVMF_FIRST_TARGET_IP ]; then
	echo "no NIC for nvmf test"
	exit 0
fi

timing_enter discovery
timing_enter start_nvmf_tgt
# Start up the NVMf target in another process
$NVMF_APP -m 0xF -w &
nvmfpid=$!

trap "killprocess $nvmfpid; exit 1" SIGINT SIGTERM EXIT

waitforlisten $nvmfpid
$rpc_py set_nvmf_target_options -u 8192 -p 4
$rpc_py start_subsystem_init
timing_exit start_nvmf_tgt

null_bdevs="$($rpc_py construct_null_bdev Null0 $NULL_BDEV_SIZE $NULL_BLOCK_SIZE) "
null_bdevs+="$($rpc_py construct_null_bdev Null1 $NULL_BDEV_SIZE $NULL_BLOCK_SIZE)"

modprobe -v nvme-rdma

$rpc_py construct_nvmf_subsystem nqn.2016-06.io.spdk:cnode1 "trtype:RDMA traddr:$NVMF_FIRST_TARGET_IP trsvcid:4420" "" -a -s SPDK00000000000001
for null_bdev in $null_bdevs; do
	$rpc_py nvmf_subsystem_add_ns nqn.2016-06.io.spdk:cnode1 $null_bdev
done

nvme discover -t rdma -a $NVMF_FIRST_TARGET_IP -s $NVMF_PORT

echo "Perform nvmf subsystem discovery via RPC"
$rpc_py get_nvmf_subsystems

$rpc_py delete_nvmf_subsystem nqn.2016-06.io.spdk:cnode1

for null_bdev in $null_bdevs; do
	$rpc_py delete_null_bdev $null_bdev
done

check_bdevs=$($rpc_py get_bdevs | jq -r '.[].name')
if [ -n "$check_bdevs" ]; then
	echo $check_bdevs
	exit 1
fi

trap - SIGINT SIGTERM EXIT

nvmfcleanup
killprocess $nvmfpid
timing_exit discovery
