# Sparklet Execution Cleanup and DAG Consolidation Plan

Status: handoff-ready

Date prepared: 2026-09-13

Repository to change: `/home/ethan/projects/sparklet`

This document is an execution plan for a new coding agent. It is intentionally more specific than a roadmap: it records the current architecture, the known correctness risks, the desired contracts, the order of implementation, the code that should be removed, and the verification gates that must pass before the work is considered complete.

## 1. Objective

Revitalize Sparklet through a focused cleanup phase that:

- establishes reliable behavioral contracts with characterization tests;
- fixes known correctness defects without expanding scope unnecessarily;
- routes every action through one DAG execution path;
- removes the obsolete narrow-only task/stage path and misleading recovery path;
- keeps the logical `Plan` model stable enough for incremental work;
- reduces duplicate intermediate representations and unsafe runtime boundaries;
- updates documentation so it describes the code that actually exists;
- leaves a smaller, honest, well-tested execution core for the later re-architecture.

The intended result is not a complete distributed engine or a new optimizer. It is a trustworthy local execution baseline with one scheduling model and clear boundaries for future work.

## 2. Handoff Instructions

The new agent should work in `/home/ethan/projects/sparklet`. This plan itself is stored in the separate notes repository and should not be modified by the implementation agent.

Before editing:

1. Read `/home/ethan/projects/sparklet/AGENTS.md`.
2. Inspect `git status --short --branch`.
3. Preserve unrelated existing work. Do not revert or overwrite changes that predate this plan.
4. Treat the current Scala source and `build.sbt` as authoritative when they disagree with historical documentation.
5. Run the build once if the local toolchain is available. Record any environment blocker instead of claiming a successful baseline.

The current Sparklet working tree contains pre-existing changes that were not made as part of this plan:

- `M modules/sparklet-core/src/main/scala/com/ewoodbury/sparklet/core/Plan.scala`
- `M modules/sparklet-execution/src/main/scala/com/ewoodbury/sparklet/execution/Stage.scala`
- `D project/project/project/target/config-classes/$c11277274135aa50bbc9.cache`

Do not revert those changes. Read the affected files and work around them carefully if they overlap with this plan.

## 3. Current Repository Shape

The current build contains these actual modules:

| Module | Responsibility |
|---|---|
| `sparklet-api` | Public `DistCollection` API |
| `sparklet-core` | `Plan`, `ExecutionService`, model types, configuration, IDs, retry policy |
| `sparklet-runtime` | Runtime SPIs and local runtime implementations |
| `sparklet-execution` | `Stage`, `Task`, `StageBuilder`, `DAGScheduler`, execution planning |
| `sparklet-tests` | Aggregated ScalaTest suite |

The root aggregator is defined in `build.sbt`. Historical references in `docs/CompletedTodos.md` to `sparklet-planner`, `sparklet-runtime-api`, `sparklet-runtime-local`, `sparklet-shuffle-api`, `sparklet-shuffle-local`, and `sparklet-dataset` do not match the current build and must not be treated as implementation instructions.

The build uses:

- Scala `3.3.5`;
- sbt-scalafix `0.14.2`;
- sbt-wartremover `3.3.3`;
- sbt-scalafmt `2.5.5`;
- ScalaTest `3.2.17`;
- Cats Effect `3.5.3`;
- sequential test execution via `Test / parallelExecution := false`.

The repository's Scala style rules require functional code, short testable functions, descriptive names, no unnecessary `var`, explicit types where inference would create `Any`, English locale arguments for case conversion, and minimal comments that explain non-obvious logic.

## 4. Existing Execution Flow

### 4.1 Public entry point

`DistCollection` stores a lazy `Plan[A]`. Actions delegate to the global `ExecutionService` registry:

```text
DistCollection action
  -> ExecutionService.get
  -> DefaultExecutionService
```

`DistCollection` currently also contains two explicitly legacy actions:

- `reduceByKeyAction`
- `groupByKeyAction`

They collect all data to the driver and then use ordinary collection operations. They should be removed in this cleanup rather than retained as a second semantic path.

### 4.2 Current narrow path

For a plan that `PlanWide.isWide` classifies as narrow:

```text
DefaultExecutionService.execute
  -> Executor.createTasks
  -> StageBuilder.buildStages
  -> StageTask per source partition
  -> LocalTaskScheduler.submit
  -> flattened results
```

This path is the legacy path. It uses a compatibility adapter inside `StageBuilder`, and it is separate from the stage-graph implementation.

### 4.3 Current wide path

For a plan that `PlanWide.isWide` classifies as wide:

```text
DefaultExecutionService.execute
  -> DAGScheduler
  -> StageBuilder.buildStageGraph
  -> TopologicalSort
  -> ExecutionPlanner.runStagesWithRecovery
  -> StageExecutor / ShuffleHandler / JoinExecutor
  -> flattened final results
```

This is the path that should become the only path. Narrow plans should also be represented as a one-stage graph and executed through this same scheduler.

### 4.4 Main architectural duplication

There are currently several overlapping representations of execution work:

- logical `Plan` nodes in `sparklet-core`;
- `Operation` values in `sparklet-execution`;
- `WideOp` values and metadata in `sparklet-execution`;
- `Stage` values;
- legacy task classes and `DAGTask` in `Task.scala`;
- `StageBuilder.buildStages` compatibility output;
- `StageBuilder.buildStageGraph` output.

The cleanup should not attempt to replace all of these with a sophisticated typed physical-plan system. It should first choose one supported execution path and remove the representations that are only compatibility scaffolding.

## 5. Verified Problems to Address

### 5.1 `aggregate` ignores `combOp`

`DistCollection.aggregate` currently executes `collect().foldLeft(zero)(seqOp)`. The supplied `combOp` is never called. This is observably incorrect for operations where the sequence accumulator and the combiner have different semantics.

The target behavior is:

1. execute the plan while preserving output partitions;
2. apply `seqOp` independently to each output partition, starting each partition with `zero`;
3. combine the partition accumulators with `combOp`, starting with `zero`;
4. return `zero` for an empty collection.

The caller is responsible for supplying operations suitable for partitioned aggregation, normally associative and compatible with the accumulator type.

Do not fix this by calling `combOp` after one global `foldLeft`. That would still hide the partitioning semantics.

### 5.2 Empty source construction can fail

`DistCollection.apply(data, numPartitions)` computes a grouping size using:

```scala
math.ceil(data.size.toDouble / numPartitions).toInt
```

For empty data this becomes zero, and `grouped(0)` is invalid. The API documentation describes `numPartitions` as the desired number of partitions, so the contract should be explicit and tested.

Preferred contract for this cleanup:

- `numPartitions` must be strictly positive;
- source construction produces exactly `numPartitions` partitions;
- empty inputs produce exactly `numPartitions` empty partitions;
- non-empty inputs distribute records deterministically across those partitions;
- downstream execution must tolerate empty partitions.

If the implementation team finds a compelling reason to preserve an "at most N partitions" contract instead, change the API documentation and tests together. Do not leave the behavior implicit.

### 5.3 `HashPartitioner` mishandles `Int.MinValue`

`math.abs(key.hashCode())` remains negative for `Int.MinValue`. The current implementation can therefore return an invalid negative partition index.

For a positive partition count, use a non-negative operation such as:

```scala
Math.floorMod(key.hashCode(), numPartitions)
```

The invalid/non-positive partition-count behavior must also be explicit. Existing code returns `0` for `numPartitions <= 0`; preserve that only if it is an intentional runtime contract, otherwise reject invalid counts at the operation boundary and test the rejection. Do not silently create invalid shuffle metadata.

### 5.4 Normal task submission bypasses retry policy

`LocalTaskScheduler.submit` currently calls `executeTasksWithRetry`, but that helper invokes `executionWrapper.executeSimple`, which bypasses `RetryPolicy`. `submitWithRetry` invokes `executeWithRetry` directly.

There must be one clearly documented behavior for normal scheduler submission:

- either `submit` uses the scheduler's configured retry policy;
- or retries are explicitly disabled and `submitWithRetry` is the only opt-in path.

The selected behavior must match `SparkletConf`, be reflected in the method names/docs, and be covered by an integration test that submits a task which fails before succeeding.

The preferred behavior for this cleanup is that normal execution uses the configured policy. The scheduler should not advertise fault tolerance that the default path bypasses.

### 5.5 Recovery is half-integrated and not reliable

The following code advertises lineage recovery:

- `DAGScheduler` accepts an optional `LineageRecoveryManager`;
- `ExecutionPlanner.runStagesWithRecovery` delegates directly to `runStages`;
- `TaskExecutionWrapper` attempts `TaskReconstructor`-based recovery;
- `LocalTaskScheduler` lazily constructs recovery infrastructure;
- `TaskReconstructor` cannot generally reconstruct arbitrary user functions safely.

The cleanup must not claim recovery guarantees that are not implemented. The preferred decision is to remove the unsupported recovery path from the supported runtime:

- remove recovery from the default scheduler and DAG execution path;
- simplify task execution around retry policy;
- remove `TaskReconstructor`, `LineageRecoveryManager`, and their normal-path wiring if no supported caller remains;
- remove or rewrite tests that only verify the unsupported recovery subsystem;
- update `SparkletConf` and docs so recovery is not presented as complete.

If the agent determines that deleting the recovery files would create an unreasonable unrelated API break, isolate them explicitly as unsupported internal code, ensure no production path constructs them, and mark the isolation with tests and documentation. Do not leave the current ambiguous behavior in place.

### 5.6 Sort-merge and global ordering need an honest contract

The public API exposes `sortMergeJoin`, `sortBy`, and a `JoinStrategy.SortMerge` choice. Historical completion notes claim sort-merge support, but the implementation and planner contain erased values, hash-based/shuffle ordering assumptions, and strategy code that needs a complete audit.

For this cleanup:

- preserve result correctness for the existing supported `sortBy` behavior;
- add tests that use nontrivial keys and multiple partitions;
- ensure a global sort result is ordered by the supplied `Ordering`, not by hash code or partition accident;
- do not expand sort-merge join into a new physical algorithm;
- if `sortMergeJoin` cannot meet its documented contract safely, reject or route it to a known-correct shuffle-hash implementation and document that decision;
- defer a true typed sort-merge join until the later physical-plan redesign.

### 5.7 Unsafe and duplicate stage construction

`StageBuilder.scala` is approximately 1,462 lines and contains both the newer graph builder and a legacy adapter. The compatibility section includes:

- `buildStages`;
- `legacyAdapter`;
- `findLinearPathToFinal`;
- `buildStageFromPath`;
- the old path's `asInstanceOf` conversions.

These functions should be deleted only after all production callers and tests have been migrated to `buildStageGraph`. Do not keep dead compatibility methods merely to preserve tests that encode the old architecture.

### 5.8 Documentation describes obsolete architecture

At minimum, these files are stale relative to the target architecture:

- `docs/TODO.md` describes nonexistent modules and marks partially completed work as complete;
- `docs/ARCHITECTURE.md` documents two supported execution paths;
- `docs/DAGScheduler.md` documents the legacy path as an active design;
- `docs/CompletedTodos.md` records module names and recovery claims that do not match the current build.

Documentation cleanup is part of the implementation, not an optional follow-up. Do not rewrite history in `CompletedTodos.md`; clearly mark superseded claims or replace the document with an accurate historical note.

## 6. Target Architecture After This Cleanup

The supported action path should be:

```text
DistCollection action
  -> ExecutionService
  -> DefaultExecutionService
  -> DAGScheduler.execute / executePartitions
  -> StageBuilder.buildStageGraph
  -> topological stage execution
  -> TaskScheduler.submit
  -> shuffle service when required
  -> final partition results
```

The following properties are required:

- narrow and wide plans use the same scheduler entry point;
- a source-only or narrow plan is still represented as a valid one-stage graph;
- the final result retains partition boundaries until the action explicitly flattens it;
- task result order is deterministic where the existing API promises order;
- shuffle IDs come from the shuffle service, not from stage IDs or "latest shuffle" lookup;
- stage graph validation rejects missing stages, missing dependencies, cycles, unreachable stages, invalid partition counts, and invalid final-stage references;
- stage metadata says enough to execute the operation without relying on a hidden legacy adapter;
- type erasure is isolated at a small, named runtime boundary rather than scattered across planners and public API code;
- retries are configured and tested; recovery is either genuinely implemented or explicitly absent;
- no public method is labeled legacy while still being required by the main execution flow.

This target does not require a GADT plan, typed physical stage algebra, or full elimination of every runtime cast in this phase.

## 7. Semantic Contracts

The implementation agent should turn these into tests before changing behavior. If an existing test contradicts a contract below, update the test and the implementation together, and document the changed behavior in the relevant API docs.

### 7.1 Source and partition contracts

- `numPartitions > 0` is required for source creation and every operation that creates a target partition count.
- Source construction is deterministic.
- Source construction preserves input order within each partition and partition order across the collection.
- Empty input remains executable and produces the documented number of empty partitions.
- Empty partitions are valid inputs to every narrow operation.
- `collect` flattens partitions in scheduler result order.

### 7.2 Transformation contracts

- `map`, `filter`, `flatMap`, and `mapPartitions` preserve source partition count unless the operation explicitly changes partitioning.
- `union` concatenates both inputs and does not drop the right side.
- Key/value projections preserve key/value association.
- `distinct` has correct set semantics; result ordering is only promised if already documented.
- `repartition`, `coalesce`, and `partitionBy` validate positive target counts and produce the documented count.

### 7.3 Wide operation contracts

- `groupByKey` returns every key and all values for that key.
- `reduceByKey` combines all values for each key exactly once under the operation's documented associativity expectations.
- `join` is an inner join and produces the Cartesian product for duplicate matching keys.
- `cogroup` includes keys present on either side and uses empty values for the missing side.
- `sortBy` uses the provided `Ordering` globally across all output partitions/results.
- `sortMergeJoin` must not claim a true sort-merge implementation unless the implementation actually establishes and consumes compatible ordering. A known-correct fallback is preferable to silently incorrect ordering.

### 7.4 Action contracts

- `collect` returns all results.
- `count` returns the number of results, including zero.
- `take(0)` returns an empty result without failing or requiring data.
- `take(n)` for negative `n` follows the chosen documented contract; the preferred contract is an empty result for `n <= 0`.
- `first` returns the first result or throws the existing documented empty-collection exception.
- `reduce` throws on empty input and combines non-empty input correctly.
- `fold` applies the initial value according to the existing API contract.
- `aggregate` uses partition-local `seqOp` and cross-partition `combOp`; `combOp` must be observable in tests.

### 7.5 Runtime contracts

- Every submitted task goes through the chosen retry behavior.
- Retry attempt counts and backoff boundaries are tested.
- A task that permanently fails returns the original failure after the configured retry budget.
- Scheduler output order matches input task order, as promised by `TaskScheduler`.
- Shuffle reads and writes use explicit shuffle IDs and partition IDs.
- Invalid shuffle partition indexes fail clearly rather than producing corrupt data.

## 8. Implementation Roadmap

Implement the work as four coherent milestones. Each milestone should leave the repository compiling and tested. Do not combine all four into one unreviewable rewrite.

### Milestone 1: Contracts, Characterization, and Safe Fixes

Goal: establish a behavioral baseline and fix defects that can be isolated without changing the scheduler architecture.

#### 8.1 Baseline and test setup

Add or update tests before deleting code. Prefer user-facing tests through `DistCollection` for behavior and focused unit tests for partitioner, retry, and stage-graph invariants.

Cover at least:

- empty source with one and multiple requested partitions;
- source with fewer records than requested partitions;
- source with more records than requested partitions;
- invalid zero and negative partition counts;
- `take(0)` and empty `first` behavior;
- aggregate where `seqOp` and `combOp` are intentionally different;
- aggregate over multiple partitions and over empty input;
- `HashPartitioner` with `Int.MinValue` and negative hash codes;
- all key/value wide operations on multiple input partitions;
- duplicate keys on both sides of a join;
- union preserving both sides;
- sort across multiple partitions with ascending and descending orderings;
- task retry behavior through `TaskScheduler.submit`, not only through `TaskExecutionWrapper` directly;
- stage graph validation for missing dependency, cycle, unreachable stage, and invalid final stage.

Existing test files to extend or use as references:

- `modules/sparklet-tests/src/test/scala/com/ewoodbury/sparklet/core/TestLocalActions.scala`
- `modules/sparklet-tests/src/test/scala/com/ewoodbury/sparklet/core/TestLocalTransformations.scala`
- `modules/sparklet-tests/src/test/scala/com/ewoodbury/sparklet/core/TestLocalKeyValueActions.scala`
- `modules/sparklet-tests/src/test/scala/com/ewoodbury/sparklet/core/TestJoins.scala`
- `modules/sparklet-tests/src/test/scala/com/ewoodbury/sparklet/execution/TestGlobalSort.scala`
- `modules/sparklet-tests/src/test/scala/com/ewoodbury/sparklet/execution/TestJoinStrategies.scala`
- `modules/sparklet-tests/src/test/scala/com/ewoodbury/sparklet/execution/TestShuffleOperationsExecution.scala`
- `modules/sparklet-tests/src/test/scala/com/ewoodbury/sparklet/execution/TestDAGScheduler.scala`
- `modules/sparklet-tests/src/test/scala/com/ewoodbury/sparklet/execution/TestOperationsAndInputSources.scala`
- `modules/sparklet-tests/src/test/scala/com/ewoodbury/sparklet/runtime/TestTaskExecutionWrapper.scala`
- `modules/sparklet-tests/src/test/scala/com/ewoodbury/sparklet/runtime/TestLineageRecoveryManager.scala`

Do not preserve tests merely because they assert that a legacy method exists. A test that documents the old architecture should be replaced with a test of the target behavior.

#### 8.2 Fix source partitioning

Replace the zero-width grouping behavior in `DistCollection.apply` with a deterministic partitioning implementation that meets the selected source partition contract. Prefer a small pure helper with explicit types and no mutable loop state.

Test exact partition count and flattened data order. Ensure the helper works for empty input, one element, fewer elements than partitions, evenly divisible input, and uneven input.

#### 8.3 Fix partition indexing

Update `modules/sparklet-runtime/src/main/scala/com/ewoodbury/sparklet/runtime/local/HashPartitioner.scala` to use a safe non-negative modulus. Add focused tests for `Int.MinValue`, ordinary negative hashes, one partition, and invalid partition counts.

#### 8.4 Correct aggregate semantics

Add partition-preserving execution to the service boundary. The preferred shape is an explicit operation such as:

```scala
def executePartitions[A](plan: Plan[A]): Seq[Partition[A]]
```

or an equivalent aggregate-specific service method if the agent can demonstrate that it keeps the boundary smaller. Whichever shape is selected:

- the execution engine must retain partition results;
- `execute` may flatten those results for `collect`;
- `DistCollection.aggregate` must run `seqOp` per partition and `combOp` across accumulators;
- the no-data result must be `zero`;
- all `ExecutionService` implementations and the unregistered-service stub must be updated;
- tests must prove that `combOp` is actually called and that the result changes when it differs from `seqOp`.

Do not silently make aggregate correct only for the current single-partition test helper.

#### 8.5 Make retry behavior honest

Choose and implement the normal `TaskScheduler.submit` retry contract. The preferred implementation is to replace the `executeSimple` call in the normal local path with the retry-aware call using the configured policy, while preserving bounded parallelism and task-order result collection.

Add a scheduler-level test that fails a task a known number of times and verifies the configured attempt count. Use short test delays. Confirm that permanent failure does not get swallowed.

If the recovery subsystem remains temporarily present during this milestone, ensure normal retry behavior does not accidentally invoke unsupported recovery. The final supported path must make this decision explicit.

#### 8.6 Remove clearly obsolete API surface

After characterization tests exist, remove `reduceByKeyAction` and `groupByKeyAction` from `DistCollection`. Their replacement is the normal transformation plus action path:

```scala
collection.reduceByKey(op).collect()
collection.groupByKey().collect()
```

Update tests and docs. Do not add wrappers that retain the old driver-collection semantics.

#### 8.7 Milestone 1 acceptance criteria

- All new semantic tests pass.
- `aggregate` uses both accumulator functions correctly.
- Empty sources execute without `grouped(0)` or equivalent failures.
- `HashPartitioner` never returns a negative valid partition index.
- Normal scheduler submission has a tested retry contract.
- Legacy key-action methods are gone or explicitly justified with a concrete external compatibility requirement.
- `sbt compile` and `sbt test` pass, subject to a documented toolchain issue.
- Formatting and static checks pass or have a precisely documented pre-existing exception.

### Milestone 2: One DAG Execution Path and Legacy Deletion

Goal: make `DAGScheduler` the only production execution entry point and remove the narrow-only compatibility path.

#### 8.8 Preserve partition results in the DAG scheduler

Refactor `DAGScheduler` so it exposes an internal/public-to-the-core execution operation that returns final `Seq[Partition[A]]` or an equivalent typed result. Its ordinary `execute` operation should flatten that result only at the outer boundary.

Use the existing `ExecutionPlanner` stage result map as the source of partition-preserving output. Ensure the final stage's output is not reconstructed from a flattened `Iterable`.

Handle source-only plans and empty plans as valid graphs. Do not special-case narrow plans back into a separate executor path.

#### 8.9 Route `DefaultExecutionService` through the scheduler unconditionally

Remove the `PlanWide.isWide` branch in `DefaultExecutionService`. The service should construct or receive the scheduler/runtime dependencies once and delegate every plan to the same DAG path.

The result should have one production call graph for:

- source-only plans;
- narrow chains;
- unions;
- repartition/coalesce/partitionBy;
- groupBy/reduce;
- sort;
- joins and cogroups.

`PlanWide.isWide` may remain as a planning utility or be replaced by a graph-builder decision, but it must not choose between unrelated execution engines.

#### 8.10 Remove `Executor.createTasks` as a production entry point

Once the service no longer calls it, remove `Executor.createTasks` and the associated legacy task factory path unless a small, clearly named internal helper is still necessary for stage task creation.

Do not retain it only because `TestExecutorCreateTasks.scala` asserts that narrow plans produce `StageTask` and wide plans produce `DAGTask`. Replace those tests with tests of the unified scheduler and stage graph behavior.

#### 8.11 Remove obsolete task/stage compatibility code

Inspect `Task.scala` and `Stage.scala` and remove classes that exist only for the old path, including `DAGTask` if orchestration now belongs to `DAGScheduler` rather than a task wrapper. Retain the smallest runnable unit needed by `TaskScheduler` to execute one planned stage partition.

Remove from `StageBuilder` after caller migration:

- `buildStages`;
- `legacyAdapter`;
- `findLinearPathToFinal`;
- `buildStageFromPath`;
- old path-specific helper methods;
- compatibility `asInstanceOf` conversions that only support those methods.

Keep `buildStageGraph` as the sole graph construction API. Make its name and documentation clear that it handles narrow and wide plans.

#### 8.12 Simplify recovery and retry wiring

The normal graph scheduler should use task retry behavior through the scheduler boundary. It should not accept an optional recovery manager that is ignored by `ExecutionPlanner.runStagesWithRecovery`.

Preferred cleanup:

- remove `recoveryManager` from `DAGScheduler`;
- remove `runStagesWithRecovery` and retain a single stage execution method;
- remove `TaskReconstructor` and `LineageRecoveryManager` if no supported production caller remains;
- simplify `TaskExecutionWrapper` to retry and failure propagation;
- remove `enableRecovery` from `LocalTaskScheduler` and obsolete recovery configuration from `SparkletConf`;
- update or delete recovery-only tests and docs.

If the agent chooses isolation instead of deletion, the isolated code must be unreachable from the normal runtime, clearly labeled unsupported, and covered by a test that proves the supported path does not invoke it. Deletion is preferred because the existing reconstruction model cannot safely handle arbitrary closures.

#### 8.13 Milestone 2 acceptance criteria

- `DefaultExecutionService` has no narrow/wide execution fork.
- Every action reaches `DAGScheduler`.
- Narrow plans execute correctly through a valid one-stage graph.
- Final results remain partitioned until the outer action boundary.
- `Executor.createTasks` and legacy stage construction are removed from production code.
- `DAGTask` and other obsolete task wrappers are removed unless a specific surviving use is documented.
- Recovery is not advertised or silently attempted.
- All user-facing transformation/action tests pass through the unified path.
- No test requires a deleted legacy API.

### Milestone 3: Minimal Intermediate Representation Cleanup

Goal: reduce duplicate operation representations without starting the full physical-plan redesign.

#### 8.14 Establish ownership of operation metadata

Choose one representation for the metadata needed by `StageBuilder` and `StageExecutor` to identify a wide operation. The preferred short-term direction is:

- logical `Plan` remains the public logical IR;
- `WideOp` becomes the internal normalized description of a shuffle boundary;
- `Operation` is retained only if it is the actual narrow-stage executable operation representation;
- duplicate conversion helpers such as `Operation.fromPlan` are consolidated;
- `StageInfo` no longer stores both a generic `Plan[_]` and an equivalent duplicate metadata object unless each field has a distinct, documented role.

Do not introduce a GADT or `PhysicalPlan` hierarchy in this milestone. The goal is fewer ambiguous representations, not a perfect final type system.

#### 8.15 Improve stage metadata conservatively

The current `Partitioning(byKey, numPartitions)` is too weak for future shuffle reuse, but a broad redesign is deferred. Add only metadata required to make current decisions explicit and testable.

At minimum, document and validate:

- whether the output is keyed;
- the partition count;
- the partitioner identity or compatibility where current shuffle reuse depends on it;
- whether ordering is guaranteed, if the current operation truly provides it.

Do not claim ordering merely because records happen to be emitted in a stable order by the local implementation.

#### 8.16 Isolate erasure boundaries

`StageExecutor`, `ShuffleHandler`, and stage metadata currently use `Any`, wildcard partitions, and casts. Do not attempt to eliminate every cast in one pass. Instead:

- keep casts at named boundary functions;
- give those functions explicit input/output types;
- validate the expected operation before casting;
- fail with a useful `IllegalStateException` when the graph and runtime data disagree;
- avoid leaking `Any` into public API types;
- remove suppressions that are no longer needed after legacy deletion.

This creates a clear baseline for a later typed `StageOp`/`StageChain` redesign.

#### 8.17 Make shuffle policy explicit

Introduce a small internal policy type or equivalent named logic for why a stage writes shuffle output. It should distinguish at least:

- downstream shuffle dependency;
- explicit repartition/coalesce;
- key partitioning;
- range partitioning for sort.

This is for clarity and tests, not for adaptive query execution. Ensure real shuffle IDs continue to come from the shuffle service.

#### 8.18 Milestone 3 acceptance criteria

- `Plan`, `Operation`, and `WideOp` responsibilities are documented and non-duplicative.
- Duplicate conversion logic is removed.
- Stage metadata has tested invariants and no misleading ordering claims.
- Unsafe casts are concentrated at explicit runtime boundaries.
- Shuffle-write decisions are inspectable and tested.
- No GADT, full physical-plan layer, or broad public API rewrite was introduced.

### Milestone 4: Invariants, Enforcement, and Release Gates

Goal: make the cleaned architecture difficult to regress.

#### 8.19 Stage graph invariants

Keep or strengthen validation in `StageBuilder` so every graph verifies:

- `finalStageId` exists;
- every dependency source and target exists;
- no stage depends on itself;
- the dependency graph is acyclic;
- every stage is reachable from the final stage in the chosen graph direction;
- stage IDs are deterministic/monotonic for a given plan traversal;
- shuffle stages have the required operation metadata;
- output partition metadata has valid counts;
- input source side tags are valid for single-input and multi-input operations;
- every stage output consumed by another stage has an explicit mapping.

Tests should construct invalid graphs directly where practical, rather than only relying on failures deep inside execution.

#### 8.20 Type-safety enforcement

Use staged enforcement rather than a global hard failure:

- remove obsolete cast suppressions first;
- add a no-new-unsafe-casts rule to review and implementation notes;
- isolate unavoidable casts in named boundary functions;
- enable stricter WartRemover rules for cleaned files or packages when the baseline permits;
- only later consider enabling `Wart.AsInstanceOf` as a hard project-wide rule.

Do not add broad `Any` suppressions to make the new path compile.

#### 8.21 Documentation and release gates

Update the following documentation to describe the single DAG path:

- `docs/ARCHITECTURE.md`;
- `docs/DAGScheduler.md`;
- `docs/TODO.md`;
- `docs/CompletedTodos.md`.

The updated docs must:

- list only the five actual modules;
- show narrow plans entering the same DAG scheduler as wide plans;
- describe shuffle IDs as runtime-owned;
- remove claims that recovery is complete unless it was genuinely implemented;
- distinguish supported behavior from deferred re-architecture;
- state ordering guarantees and limitations;
- remove obsolete methods and class names from diagrams and examples.

The release gate for this cleanup is:

```text
compile passes
all tests pass
scalafmt check passes
scalafix check passes
WartRemover passes under the agreed staged policy
documentation matches the source and build
no legacy production path remains
```

## 9. Explicitly Deferred Work

Do not implement these items as part of this cleanup unless a concrete blocker makes one unavoidable. If a blocker appears, stop and document the scope change before expanding the implementation.

### 9.1 Deferred core re-architecture

- GADT-style `Plan` with typed input/output witnesses;
- typed `StageOp` and `StageChain` replacing all erased operation storage;
- fully parametric `InputSource` and `DataDescriptor` design;
- dedicated physical stage types such as `ShuffleJoinStage` and `GlobalSortStage`;
- complete immutable rewrite of the entire `StageBuilder`;
- a rich `PartitioningInfo` model with full distribution and ordering algebra;
- a first-class `PhysicalPlan` layer and optimizer;
- complete removal of the global `ExecutionService` and `SparkletRuntime` registries;
- effectful redesign of the public `DistCollection` API;
- cluster/distributed runtime, network shuffle, serialization, and executor processes.

### 9.2 Deferred algorithm work

- true typed sort-merge join;
- adaptive join selection;
- cost-based optimization;
- shuffle reuse beyond the current explicit metadata;
- speculative execution;
- executor crash recovery;
- spill-to-disk and memory-aware execution;
- performance benchmarking and adaptive partition sizing.

The cleanup may fix an incorrect existing algorithm or route an advertised strategy to a known-correct implementation. It should not grow a new algorithm family.

## 10. File-by-File Guidance

### Public API and core

`modules/sparklet-api/src/main/scala/com/ewoodbury/sparklet/api/DistCollection.scala`

- fix source partition creation;
- fix aggregate semantics;
- remove driver-collection legacy actions;
- preserve public behavior unless a documented contract above requires correction;
- avoid adding new casts to compensate for execution changes.

`modules/sparklet-core/src/main/scala/com/ewoodbury/sparklet/core/ExecutionService.scala`

- add the smallest partition-preserving service capability required for aggregate and unified execution;
- update the unregistered-service implementation;
- keep the API module independent of the execution module.

`modules/sparklet-core/src/main/scala/com/ewoodbury/sparklet/core/Plan.scala`

- preserve the logical plan shape during this phase;
- validate operation parameters at construction or planning boundaries where appropriate;
- do not replace the whole plan ADT with the deferred GADT design.

`modules/sparklet-core/src/main/scala/com/ewoodbury/sparklet/core/SparkletConf.scala`

- retain configuration that is actually used;
- remove or clearly deprecate unsupported recovery/speculation fields if their implementations are removed;
- validate positive counts and non-negative durations where appropriate.

### Execution

`modules/sparklet-execution/src/main/scala/com/ewoodbury/sparklet/execution/DefaultExecutionService.scala`

- remove the narrow/wide branch;
- delegate all plans to the unified DAG scheduler;
- expose flattened and partition-preserving forms without duplicating execution.

`modules/sparklet-execution/src/main/scala/com/ewoodbury/sparklet/execution/DAGScheduler.scala`

- become the single scheduler entry point;
- remove ignored recovery parameters;
- preserve final partitions;
- retain clear topological execution and stage-result mapping.

`modules/sparklet-execution/src/main/scala/com/ewoodbury/sparklet/execution/ExecutionPlanner.scala`

- retain one stage execution method;
- remove the no-op recovery wrapper;
- keep shuffle-ID mappings explicit;
- make shuffle-write reasons inspectable.

`modules/sparklet-execution/src/main/scala/com/ewoodbury/sparklet/execution/StageBuilder.scala`

- make `buildStageGraph` the only production graph-building API;
- delete the legacy adapter after caller/test migration;
- keep graph validation;
- reduce duplicate plan/operation metadata incrementally.

`modules/sparklet-execution/src/main/scala/com/ewoodbury/sparklet/execution/Executor.scala`

- remove once `DefaultExecutionService` no longer uses it;
- if a helper survives, rename it around its actual responsibility instead of retaining a misleading executor facade.

`modules/sparklet-execution/src/main/scala/com/ewoodbury/sparklet/execution/Task.scala`

- remove `DAGTask` and legacy task variants that only support the old path;
- retain only the smallest task abstraction needed by stage scheduling;
- keep task output types explicit.

`modules/sparklet-execution/src/main/scala/com/ewoodbury/sparklet/execution/StageExecutor.scala`

- retain operation-specific execution behavior;
- isolate and validate erased boundaries;
- ensure empty inputs are not treated as fatal unless the operation contract requires data;
- avoid introducing new mutable data structures or broad suppressions.

`modules/sparklet-execution/src/main/scala/com/ewoodbury/sparklet/execution/ShuffleHandler.scala`

- keep runtime-owned shuffle IDs;
- make partition count and shuffle-write reason explicit;
- preserve the correct path for group/reduce/join/sort operations.

`modules/sparklet-execution/src/main/scala/com/ewoodbury/sparklet/execution/Operation.scala`

- retain only if it is the chosen executable narrow-operation representation;
- remove duplicate conversions and stale compatibility types.

### Runtime

`modules/sparklet-runtime/src/main/scala/com/ewoodbury/sparklet/runtime/local/LocalTaskScheduler.scala`

- make normal submission use the selected retry behavior;
- preserve bounded concurrency and input-order result collection;
- remove unsupported recovery construction;
- keep `submitWithRetry` only if it has a distinct documented use after normal submission is corrected.

`modules/sparklet-runtime/src/main/scala/com/ewoodbury/sparklet/runtime/TaskExecutionWrapper.scala`

- retain retry and failure propagation;
- remove `executeSimple` if no supported caller remains;
- do not perform unsafe recovery casts.

`modules/sparklet-runtime/src/main/scala/com/ewoodbury/sparklet/runtime/TaskReconstructor.scala`

`modules/sparklet-runtime/src/main/scala/com/ewoodbury/sparklet/runtime/LineageRecoveryManager.scala`

- remove from the supported runtime unless the agent implements a real, type-safe recovery contract;
- do not leave them wired into defaults while documenting them as complete.

`modules/sparklet-runtime/src/main/scala/com/ewoodbury/sparklet/runtime/local/HashPartitioner.scala`

- fix negative hash handling and add focused tests.

`modules/sparklet-runtime/src/main/scala/com/ewoodbury/sparklet/runtime/SparkletRuntime.scala`

- retain only the global/thread-local runtime wiring that is still needed in this phase;
- do not expand the registry design;
- ensure scheduler configuration is not silently disconnected from `SparkletConf`.

## 11. Test Migration Guidance

`TestExecutorCreateTasks.scala` is tightly coupled to the old architecture. Replace it rather than preserving its assertions about `StageTask` versus `DAGTask`.

`TestOperationsAndInputSources.scala` contains useful graph and metadata coverage, but it also expects `StageBuilder.buildStages` to reject wide plans. Migrate those tests to `buildStageGraph` and assert graph semantics instead of compatibility behavior.

`TestDAGScheduler.scala` should become the primary execution-path test. Add narrow plans, source-only plans, unions, empty inputs, and wide plans to prove they all use the same service/scheduler path.

`TestLocalActions.scala` should cover action contracts, including the corrected aggregate semantics and empty behavior.

`TestGlobalSort.scala` should verify global ordering with multiple partitions and custom orderings. Keep the test focused on observable sort correctness, not placeholder stage implementation details.

`TestJoinStrategies.scala` and `TestJoins.scala` should verify result sets, duplicate-key Cartesian products, empty-side behavior, and the documented status of each join strategy. Avoid tests that merely assert an internal strategy enum was selected unless that selection is part of the supported contract.

`TestTaskExecutionWrapper.scala` should remain focused on retry policy. Add or update scheduler integration coverage so the wrapper's behavior is not tested only in isolation.

Recovery-only tests should be deleted or rewritten to test the explicit unsupported status if recovery code is removed or isolated.

## 12. Verification Commands

Run from `/home/ethan/projects/sparklet`:

```bash
sbt compile
sbt test
sbt scalafmtCheck
sbt scalafixAll --check
```

The repository also provides:

```bash
make test
make test-lint
```

Use focused commands while iterating when useful, but run the full aggregate checks before each milestone is declared complete.

If `sbt` is unavailable, install or expose the expected toolchain before concluding that code is broken. The investigation that produced this plan saw `/bin/bash: line 1: sbt: command not found` in one shell. Another session reported JDK 17 and sbt 2.0.8 installed user-locally and reported 248 tests across 22 suites passing, but that result was not independently verified in the shell used for this plan. Treat it as historical context, not as current proof.

When a check cannot run, record:

- the exact command;
- the exact error;
- whether compilation, tests, formatting, or linting remain unverified;
- what was manually inspected instead.

Never report a green build based only on a prior agent's summary.

## 13. Commit and Review Boundaries for the Implementation Agent

Keep the four milestones reviewable. Preferred commit/PR boundaries are:

1. contract tests and safe correctness fixes;
2. unified DAG execution and legacy deletion;
3. minimal IR and boundary cleanup;
4. invariant enforcement and documentation/release gates.

Each boundary should include its tests and docs. Avoid mixing unrelated formatting churn with architectural edits. Do not commit generated build output, caches, secrets, or changes to the separate notes repository.

Before any implementation commit, inspect:

```bash
git status --short
git diff --stat
git diff
git log --oneline -10
```

Stage only intended Sparklet files. Preserve the pre-existing working-tree changes listed in Section 2 unless the user separately directs otherwise.

## 14. Final Definition of Done

This cleanup is complete only when all of the following are true:

- the build contains only the five actual modules and docs agree;
- every public action uses the unified DAG scheduler;
- narrow and wide plans share one stage-graph execution model;
- final partition boundaries are available to partition-aware actions;
- aggregate uses `seqOp` per partition and `combOp` across partitions;
- empty source data and empty partitions are fully supported;
- valid hash partition indexes are guaranteed;
- normal scheduler submission has a tested retry contract;
- unsupported lineage recovery is removed from or isolated from the supported path;
- legacy driver-collecting actions are gone;
- `Executor.createTasks`, `DAGTask`, and the legacy `StageBuilder` adapter are gone unless a surviving, documented use justifies a narrowly scoped replacement;
- stage graph invariants are validated;
- unsafe casts are isolated rather than multiplied;
- sort and join behavior is either correct under its documented contract or explicitly routed/fenced off;
- no-new-cast and lint policy is documented and partially enforced;
- all relevant tests pass through the supported public path;
- formatting and static checks pass;
- architecture and TODO documentation no longer describe obsolete modules or execution paths;
- deferred re-architecture work is recorded rather than accidentally implemented in this phase.

The next project after this cleanup may then introduce typed physical stages, richer partition/order metadata, a real optimizer, true sort-merge joins, dependency injection, and distributed runtime components from a stable baseline.
