# Phase 1 Execution Cleanup — Completion Summary

Date completed: 2026-09-20

The Phase 1 cleanup described in phase-1-cleanup-plan.md is complete. All four milestones
shipped as reviewed PRs with adversarial self-review rounds, each leaving the suite green and
the lint gates passing.

## Shipped

| Milestone | PR | What landed |
|---|---|---|
| M1 | #10 | Contract tests; fixed `aggregate` combOp, source partitioning, HashPartitioner floorMod, honest retry via `SparkletConf` |
| M2 | #11 | One DAG execution path; deleted legacy paths, `DAGTask`, ten single-op tasks, recovery subsystem (~2,600 lines); `take(n)` per-partition limit; fixed TopologicalSort dropping edge-less stages |
| M3 | #13 | `StageInfo.wideOp` (runtime no longer inspects `Plan`); single `Operation.fromPlan` boundary; `ShuffleWriteReason` with tested priority; single `kvPlan` boundary in the API |
| M4 | #14 | Graph validation independently tested (every rejection mode); `Wart.AsInstanceOf`/`Wart.Any` as compile errors confined to named boundaries; docs rewritten against the architecture |
| wrap-up | #15 | Roadmap moved out of the repository into notes/sparklet/todo.md |

## Bugs found and fixed along the way

- `aggregate` silently ignored `combOp` (driver-side fold)
- empty input crashed source construction (`grouped(0)`)
- `HashPartitioner` produced negative partitions for `Int.MinValue`
- retry was bypassed on the normal submission path (`executeSimple`)
- `TopologicalSort` dropped stages without dependency edges (chained narrow plans executed
  zero stages)
- `union.take(n)`/`union.first()` crashed (appendOperation orphaned union stages); also fixed
  pre-existing broken `union.map`
- `repartition(sameCount)` crashed (bypass ops had no materialization case)
- `partitionBy(default)` + groupByKey/reduceByKey produced wrong results (element-hashed
  shuffle writes feeding a key-partition bypass)
- M3 review: shuffle write reason selected by dependent iteration order, not type priority
  (fixed twice — the regression test caught the same pattern inside the first fix)

## End state

- 244 tests / 27 suites, sequential; characterization suites pin public behavior
- One execution path: DistCollection -> ExecutionService -> DAGScheduler -> stage graph
- Type erasure confined to named, compiler-enforced boundaries
- Runtime SPIs intact (TaskScheduler/ShuffleService/Partitioner/BroadcastService) with local impls
- Known limitations recorded in docs/ARCHITECTURE.md; near-term optimization workstream in
  sparklet/todo.md (aggregation output widening, map-side combine, CSE, pushdown, true
  sort-merge join, benchmark harness)

## Next phases (from todo.md)

Optimization work first (aggregation parallelism, map-side combine), then the core
re-architecture (physical stage kinds, PartitioningInfo, DI replacing global state, which also
unlocks parallel tests), then DataFrame/Dataset API, then distributed execution.
