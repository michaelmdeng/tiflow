// Copyright 2020 PingCAP, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// See the License for the specific language governing permissions and
// limitations under the License.

package ha

import (
	"context"
	"time"

	"github.com/pingcap/check"
	"github.com/pingcap/tiflow/dm/config"
)

func (t *testForEtcd) TestSourceBoundJSON(c *check.C) {
	b1 := NewSourceBound("mysql-replica-1", "dm-worker-1")

	j, err := b1.toJSON()
	c.Assert(err, check.IsNil)
	c.Assert(j, check.Equals, `{"source":"mysql-replica-1","worker":"dm-worker-1"}`)
	c.Assert(j, check.Equals, b1.String())

	b2, err := sourceBoundFromJSON(j)
	c.Assert(err, check.IsNil)
	c.Assert(b2, check.DeepEquals, b1)
}

func (t *testForEtcd) TestSourceBoundEtcd(c *check.C) {
	defer clearTestInfoOperation(c)

	var (
		watchTimeout = 2 * time.Second
		worker1      = "dm-worker-1"
		worker2      = "dm-worker-2"
		bound1       = NewSourceBound("mysql-replica-1", worker1)
		bound2       = NewSourceBound("mysql-replica-2", worker2)
	)
	c.Assert(bound1.IsDeleted, check.IsFalse)

	// no bound exists.
	sbm1, rev1, err := GetSourceBound(etcdTestCli, "")
	c.Assert(err, check.IsNil)
	c.Assert(rev1, check.Greater, int64(0))
	c.Assert(sbm1, check.HasLen, 0)

	// put two bounds.
	rev2, err := PutSourceBound(etcdTestCli, bound1)
	c.Assert(err, check.IsNil)
	c.Assert(rev2, check.Greater, rev1)
	rev3, err := PutSourceBound(etcdTestCli, bound2)
	c.Assert(err, check.IsNil)
	c.Assert(rev3, check.Greater, rev2)

	// watch the PUT operation for the bound1.
	boundCh := make(chan SourceBound, 10)
	errCh := make(chan error, 10)
	ctx, cancel := context.WithTimeout(context.Background(), watchTimeout)
	WatchSourceBound(ctx, etcdTestCli, worker1, rev2, boundCh, errCh)
	cancel()
	close(boundCh)
	close(errCh)
	c.Assert(len(boundCh), check.Equals, 1)
	bound1.Revision = rev2
	c.Assert(<-boundCh, check.DeepEquals, bound1)
	c.Assert(len(errCh), check.Equals, 0)

	// get bound1 back.
	sbm2, rev4, err := GetSourceBound(etcdTestCli, worker1)
	c.Assert(err, check.IsNil)
	c.Assert(rev4, check.Equals, rev3)
	c.Assert(sbm2, check.HasLen, 1)
	c.Assert(sbm2[worker1], check.DeepEquals, bound1)

	// get bound1 and bound2 back.
	sbm2, rev4, err = GetSourceBound(etcdTestCli, "")
	c.Assert(err, check.IsNil)
	c.Assert(rev4, check.Equals, rev3)
	c.Assert(sbm2, check.HasLen, 2)
	c.Assert(sbm2[worker1], check.DeepEquals, bound1)
	bound2.Revision = rev3
	c.Assert(sbm2[worker2], check.DeepEquals, bound2)

	// delete bound1.
	rev5, err := DeleteSourceBound(etcdTestCli, worker1)
	c.Assert(err, check.IsNil)
	c.Assert(rev5, check.Greater, rev4)

	// delete bound2.
	rev6, err := DeleteSourceBound(etcdTestCli, worker2)
	c.Assert(err, check.IsNil)
	c.Assert(rev6, check.Greater, rev5)

	// watch the DELETE operation for bound1.
	boundCh = make(chan SourceBound, 10)
	errCh = make(chan error, 10)
	ctx, cancel = context.WithTimeout(context.Background(), watchTimeout)
	WatchSourceBound(ctx, etcdTestCli, worker1, rev5, boundCh, errCh)
	cancel()
	close(boundCh)
	close(errCh)
	c.Assert(len(boundCh), check.Equals, 1)
	bo := <-boundCh
	c.Assert(bo.IsDeleted, check.IsTrue)
	c.Assert(bo.Revision, check.Equals, rev5)
	c.Assert(len(errCh), check.Equals, 0)

	// get again, bound1 not exists now.
	sbm3, rev7, err := GetSourceBound(etcdTestCli, worker1)
	c.Assert(err, check.IsNil)
	c.Assert(rev7, check.Equals, rev6)
	c.Assert(sbm3, check.HasLen, 0)
}

func (t *testForEtcd) TestGetSourceBoundConfigEtcd(c *check.C) {
	defer clearTestInfoOperation(c)

	var (
		worker = "dm-worker-1"
		source = "mysql-replica-1"
		bound  = NewSourceBound(source, worker)
	)
	cfg, err := config.LoadFromFile(sourceSampleFilePath)
	c.Assert(err, check.IsNil)
	cfg.SourceID = source
	// no source bound and config
	bound1, cfg1, rev1, err := GetSourceBoundConfig(etcdTestCli, worker)
	c.Assert(err, check.IsNil)
	c.Assert(rev1, check.Greater, int64(0))
	c.Assert(bound1.IsEmpty(), check.IsTrue)
	c.Assert(cfg1, check.IsNil)

	rev2, err := PutSourceBound(etcdTestCli, bound)
	c.Assert(err, check.IsNil)
	c.Assert(rev2, check.Greater, rev1)
	// get source bound and config, but config is empty
	// nolint:dogsled
	_, _, _, err = GetSourceBoundConfig(etcdTestCli, worker)
	c.Assert(err, check.ErrorMatches, ".*doesn't have related source config in etcd.*")

	rev3, err := PutSourceCfg(etcdTestCli, cfg)
	c.Assert(err, check.IsNil)
	c.Assert(rev3, check.Greater, rev2)
	// get source bound and config
	bound2, cfg2, rev4, err := GetSourceBoundConfig(etcdTestCli, worker)
	c.Assert(err, check.IsNil)
	c.Assert(rev4, check.Equals, rev3)
	bound.Revision = rev2
	c.Assert(bound2, check.DeepEquals, bound)
	c.Assert(cfg2, check.DeepEquals, cfg)
}
