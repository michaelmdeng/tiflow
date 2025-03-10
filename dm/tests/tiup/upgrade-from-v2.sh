#!/bin/bash

set -eux

CLUSTER_NAME="dm-v2"

PRE_VER=$1
CUR_VER=$2

CUR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PATH=$CUR/../_utils:$PATH # for sync_diff_inspector
tiup_dm_operation_log=/tmp/tiup-dm-operation.log

source $CUR/lib.sh

function deploy_previous_v2() {
	# install TiUP-DM
	curl --proto '=https' --tlsv1.2 -sSf https://tiup-mirrors.pingcap.com/install.sh | sh
	source /root/.profile
	tiup install dm >>$tiup_dm_operation_log

	tiup install dmctl:$PRE_VER >>$tiup_dm_operation_log

	tiup dm deploy --yes $CLUSTER_NAME $PRE_VER $CUR/conf/topo.yaml >>$tiup_dm_operation_log
	tiup dm start --yes $CLUSTER_NAME >>$tiup_dm_operation_log
}

function migrate_in_previous_v2() {
	exec_full_stage

	# v2.0.0 doesn't implement relay log.
	# v2.0.1 downgrading has a problem, we use config import which create sources and then create tasks, so for a cluster
	#   1. source is created and bound to a worker.
	#   2. worker starts relay when see the bound and config of the source (after v2.0.2 a manual `start-relay` is needed)
	#      and currently no task created, so it pulls relay log from GTID of SHOW MASTER STATUS, which is later than
	#      expected task checkpoint position. And also v2.0.1 didn't reset to the starting GTID of a binlog file.
	#   3. create task, now the events between checkpoint and SHOW MASTER STATUS in step2 are lost.
	if [[ "$PRE_VER" == "v2.0.0" ]] || [[ "$PRE_VER" == "v2.0.1" ]]; then
		sed -i "s/enable-relay: true/enable-relay: false/g" $CUR/conf/source1.yaml
	fi

	sed -i "s/enable-heartbeat: true/enable-heartbeat: false/g" $CUR/conf/task.yaml
	sed -i "s/enable-heartbeat: true/enable-heartbeat: false/g" $CUR/conf/task_pessimistic.yaml
	sed -i "s/enable-heartbeat: true/enable-heartbeat: false/g" $CUR/conf/task_optimistic.yaml

	tiup dmctl:$PRE_VER --master-addr=master1:8261 operate-source create $CUR/conf/source1.yaml
	tiup dmctl:$PRE_VER --master-addr=master1:8261 operate-source create $CUR/conf/source2.yaml

	tiup dmctl:$PRE_VER --master-addr=master1:8261 start-task $CUR/conf/task.yaml
	tiup dmctl:$PRE_VER --master-addr=master1:8261 start-task $CUR/conf/task_optimistic.yaml
	tiup dmctl:$PRE_VER --master-addr=master1:8261 start-task $CUR/conf/task_pessimistic.yaml

	ensure_start_relay

	exec_incremental_stage1

	# drop table will be skipped
	if [[ "$PRE_VER" != "v2.0.0" ]]; then
		run_sql_tidb_with_retry "select count(*) from opt_db_target.t_target where c1=1000;" "1"
		exec_sql tidb 4000 "delete from opt_db_target.t_target where c1=1000;"
	fi
	check_sync_diff $WORK_DIR $CUR/conf/diff_config.toml

	tiup dmctl:$PRE_VER --master-addr=master1:8261 pause-task $TASK_NAME

	run_dmctl_with_retry $PRE_VER "query-status" "Running" 2 "Paused" 1
}

function upgrade_to_current_v2() {
	tiup uninstall dmctl --all

	tiup install dmctl:v7.5.0 >>$tiup_dm_operation_log
	# config export in PRE_VER
	# on version >= 8.0.0, the `config export` command will connect to the master
	# and fetch the config which previous version doesn't support, so we fix the version to 7.5.0
	tiup dmctl:v7.5.0 --master-addr=master1:8261 config export -d old_configs

	if [[ "$CUR_VER" == "nightly" && ("$ref" == "refs/pull"* || "$id" != "") ]]; then
		patch_nightly_with_tiup_mirror $PRE_VER
	fi

	# uninstall previous dmctl, otherwise dmctl:nightly still use PRE_VER.
	# FIXME: It may be a bug in tiup mirror.

	tiup dm upgrade --yes $CLUSTER_NAME $CUR_VER >>$tiup_dm_operation_log

	restart_relay
}

function migrate_in_v2() {
	run_dmctl_with_retry $CUR_VER "query-status" "Running" 2 "Paused" 1
	run_dmctl_with_retry $CUR_VER "shard-ddl-lock" "\"result\": true" 1 "\"task\": \"$TASK_PESS_NAME\"" 1 "\"task\": \"$TASK_OPTI_NAME\"" 1

	tiup dmctl:$CUR_VER --master-addr=master1:8261 resume-task $TASK_NAME

	run_dmctl_with_retry $CUR_VER "query-status" "Running" 3

	exec_incremental_stage2

	echo "check sources"
	run_dmctl_with_retry $CUR_VER "operate-source show" "mysql-replica-01" 1 "mariadb-replica-02" 1
	echo "check workers"
	run_dmctl_with_retry $CUR_VER "list-member --worker" "\"stage\": \"bound\"" 2

	check_sync_diff $WORK_DIR $CUR/conf/diff_config.toml
	check_sync_diff $WORK_DIR $CUR/conf/diff_config_optimistic.toml
	check_sync_diff $WORK_DIR $CUR/conf/diff_config_pessimistic.toml

	echo "check locks"
	run_dmctl_with_retry $CUR_VER "shard-ddl-lock" "no DDL lock exists" 1

	# config export in CUR_VER
	tiup install dmctl:$CUR_VER
	tiup dmctl:$CUR_VER --master-addr=master1:8261 config export -d new_configs
}

function diff_configs() {
	echo "diff configs between different version"

	sed '/password/d' old_configs/tasks/upgrade_via_tiup.yaml >/tmp/old_task.yaml
	sed '/password/d' old_configs/tasks/upgrade_via_tiup_pessimistic.yaml >/tmp/old_task_pessimistic.yaml
	sed '/password/d' old_configs/tasks/upgrade_via_tiup_optimistic.yaml >/tmp/old_task_optimistic.yaml
	sed '/password/d' new_configs/tasks/upgrade_via_tiup.yaml >/tmp/new_task.yaml
	sed '/password/d' new_configs/tasks/upgrade_via_tiup_pessimistic.yaml >/tmp/new_task_pessimistic.yaml
	sed '/password/d' new_configs/tasks/upgrade_via_tiup_optimistic.yaml >/tmp/new_task_optimistic.yaml

	sed '/password/d' old_configs/sources/mysql-replica-01.yaml >/tmp/old_source1.yaml
	sed '/password/d' old_configs/sources/mariadb-replica-02.yaml >/tmp/old_source2.yaml
	sed '/password/d' new_configs/sources/mysql-replica-01.yaml >/tmp/new_source1.yaml
	sed '/password/d' new_configs/sources/mariadb-replica-02.yaml >/tmp/new_source2.yaml

	diff /tmp/old_task.yaml /tmp/new_task.yaml || exit 1
	diff /tmp/old_task_pessimistic.yaml /tmp/new_task_pessimistic.yaml || exit 1
	diff /tmp/old_task_optimistic.yaml /tmp/new_task_optimistic.yaml || exit 1
	diff /tmp/old_source1.yaml /tmp/new_source1.yaml || exit 1
	diff /tmp/old_source2.yaml /tmp/new_source2.yaml || exit 1
}

function downgrade_to_previous_v2() {
	echo "downgrade to previous version $PRE_VER"

	# destory current cluster
	tiup dm destroy --yes $CLUSTER_NAME >>$tiup_dm_operation_log

	exec_incremental_stage3

	# deploy previous cluster
	tiup dm deploy --yes $CLUSTER_NAME $PRE_VER $CUR/conf/topo.yaml >>$tiup_dm_operation_log
	tiup dm start --yes $CLUSTER_NAME >>$tiup_dm_operation_log

	# config import
	tiup dmctl:$CUR_VER --master-addr=master1:8261 config import -d new_configs

	ensure_start_relay

	exec_incremental_stage4

	run_dmctl_with_retry $CUR_VER "operate-source show" "mysql-replica-01" 1 "mariadb-replica-02" 1
	run_dmctl_with_retry $CUR_VER "list-member --worker" "\"stage\": \"bound\"" 2

	check_sync_diff $WORK_DIR $CUR/conf/diff_config.toml
	check_sync_diff $WORK_DIR $CUR/conf/diff_config_optimistic.toml
	check_sync_diff $WORK_DIR $CUR/conf/diff_config_pessimistic.toml
}

function destroy_v2_by_tiup() {
	export DM_MASTER_ADDR="master1:8261"
	tiup dmctl:$CUR_VER stop-task $TASK_NAME
	tiup dm destroy --yes $CLUSTER_NAME >>$tiup_dm_operation_log
}

function test() {
	deploy_previous_v2

	migrate_in_previous_v2

	upgrade_to_current_v2

	migrate_in_v2

	diff_configs

	downgrade_to_previous_v2

	destroy_v2_by_tiup
}

test
