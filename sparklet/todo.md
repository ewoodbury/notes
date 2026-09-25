# Sparklet Roadmap

Lives in the notes repo (removed from the sparklet repository to keep it a clean, real project).
Status: Phase 1 cleanup complete (#10–#15). Phase 2 optimization complete (#16 width, #17
map-side combine). Next is a vectorized physical kernel (see
phase-3-vectorized-kernel.md) — columnar batches, morsels, then optional
bytecode gen / AQE / native backend.
Source of truth for the current architecture: sparklet docs/ARCHITECTURE.md.
Proposal for the next engine: notes/sparklet/phase-3-vectorized-kernel.md.

## Project 4 - Hygiene, Fault Tolerance, and Reliability

### Phase 0: Architecture and Foundations
Status after the Phase 1 execution cleanup:
- [x] Unify StageBuilder between execution and planner modules and improve design (single builder in sparklet-execution; no planner module exists)
- [x] Single wide-op predicate (`PlanWide.isWide`) — single source of truth for shuffle detection
- [x] Eliminate legacy narrow-only path; route all execution through the unified DAG scheduler
- [x] Remove legacy stage fusion casts: `Executor.createTasks`, `buildStages`, legacy adapter deleted; runtime dispatch no longer inspects `Plan`
- [x] Centralize shuffle write policy with explicit `ShuffleWriteReason` ADT (tested priority selection)
- [x] Erasure enforcement: `Wart.AsInstanceOf`/`Wart.Any` are compile errors; casts only at named boundaries (superseded the broader "remove all casts" framing — named boundaries are the accepted model)
- [x] Consolidate wide-op detection & shuffle decision utilities into `PlanWide` + `Operation.canBypassShuffle` + `ShuffleWriteReason`
- [ ] Enrich partition metadata (`PartitioningInfo`): distribution, ordering tag, **layout**
  (`BoxedRows` vs `Columnar(batchSize)`). See phase-3-vectorized-kernel.md.
  - Why: `Partitioning(byKey, count)` cannot describe hash vs range vs layout, so shuffle
    reuse, join strategy, and a columnar backend have nothing to hang on.
- [ ] Introduce typed `StageOp` / `StageChain` to remove the remaining erasure-heavy handlers
  - Why: stage transport is still `Partition[_]`-erased; handlers in StageExecutor/ShuffleHandler carry documented casts. Benefit: compile-time safety through the executor.
- [ ] Strengthen `InputSource` typing (add `DataDescriptor` or parametric types) to reduce casts
- [ ] Add dedicated physical stage kinds (`ShuffleJoinStage`, `GlobalSortStage`) instead of identity placeholders
- [ ] Prepare physical plan abstraction layer (scaffold `PhysicalPlan` nodes) ahead of optimizer work
  - Benefit: enables projection/predicate pushdown, cost-based selection, adaptive re-planning.

### Fault tolerance (later; not the next engine phase)
- [x] Task retry with exponential backoff (`RetryPolicy` + `TaskExecutionWrapper`), tested through `TaskScheduler.submit`
- [x] Lineage recovery removed (Milestone 2): it could not safely reconstruct arbitrary user
  functions and was unreachable from the supported path. Any future recovery must retain
  executable plan/stage lineage, not operation-name strings.
- [ ] Speculative execution for slow tasks
- [ ] Graceful handling of executor crashes
  - [ ] Task reassignment to healthy executors
  - [ ] Partial result preservation and continuation
- [ ] Advanced failure modes testing
  - [ ] Inject artificial failures in integration tests
  - [ ] Chaos engineering approach to fault tolerance validation
  - [ ] Performance impact analysis under failure conditions

### Optimization (Phase 2 — done)
- [x] Widen aggregation outputs: `groupByKey`/`reduceByKey`/`cogroup`/`sortBy`
  - Merged: https://github.com/ewoodbury/sparklet/pull/16
- [x] Map-side combine for `reduceByKey`
  - Merged: https://github.com/ewoodbury/sparklet/pull/17

### Physical kernel (Phase 3 — next)

Plan: phase-3-vectorized-kernel.md. Logical DistCollection stays. Physical currency
becomes column batches; scheduling grain becomes morsels. SIMD in v1 is HotSpot
auto-vec of `while` loops over primitive arrays, not Panama and not JNI.

- [ ] PR B: `PartitioningInfo` on the existing row path
  - [ ] `Distribution` (Unknown / Singleton / Hash / Range / RoundRobin)
  - [ ] `OrderingTag`, `Layout` (`BoxedRows` | `Columnar(batchSize)`)
  - [ ] Preserve #16 width and #17 combine; tests for Hash vs Range vs Unknown
- [ ] PR C: `sparklet-columnar` module
  - [ ] `ColumnBatch`, `Int32`/`Int64`/`Float64`/`Bool` columns, validity bitmap
  - [ ] Dictionary UTF-8 for v1 strings; no struct/array/map yet
  - [ ] Encode/decode `Seq[Int]`, `Seq[(Int,Int)]`; roundtrip + null tests
- [ ] PR D: vectorized filter + project + benchmark skeleton
  - [ ] Kernels as `while` over arrays (HotSpot auto-vec)
  - [ ] Timed/JMH driver: filter+project vs Sparklet row `map`/`filter`
- [ ] PR E: columnar hash aggregate + hash join
  - [ ] Map-side combine = hash agg before exchange
  - [ ] Same answers as DistCollection `reduceByKey` / `join` on int keys
  - [ ] Benchmark vs Spark SQL `groupBy.agg` and `join` (WSCG, not RDD)
- [ ] PR F: exchange + morsel scheduler
  - [ ] Hash-partition batches into n buffers (local shuffle, no ser/de)
  - [ ] Steal morsels across the worker pool; output width from `Distribution.Hash`
  - [ ] Skew test (one heavy key)
- [ ] PR G: DistCollection primitives select the columnar backend
  - [ ] `DistCollection[Int]` / `[(Int,Int)]` take the new path when encodable
  - [ ] Row path remains default for arbitrary `A`; existing tests stay green

Deferred until after G (do not start as the next PR):
- [ ] Cross-branch CSE (needs PartitioningInfo; diamond is still recomputed per branch)
- [ ] Predicate/projection pushdown (needs a physical pipeline, not Spark-shaped node soup)
- [ ] True sort-merge join (in-memory hash/radix first; current SMJ is hash grouping)
- [ ] Bytecode gen of fused pipelines (answers WSCG-beats-unfused-vectorized)
- [ ] AQE over morsel size / batch size / pipeline vs materialize
- [ ] Panama Vector API kernel provider (JDK 21+, optional; incubating until Valhalla)
- [ ] Native backend: Arrow batches to DataFusion/Velox (whole subplan, not per-op JNI)
- [ ] Benchmark vs DuckDB / DataFusion on the same box (harness in D, full matrix with G)
- [ ] DI / parallel tests (when globals block morsel work)
- [ ] JoinExecutor/CogroupTask read-inside-task (#16 leftover; columnar exchange supersedes)

### SIMD / kernel learning (side path, not blocking PRs B–G)
- [ ] Confirm C2 auto-vec on v1 kernels (`PrintAssembly` / perf)
- [ ] Scratch reimplement one kernel with Panama Vector API; compare ns/row
- [ ] Only then: one op via FFM + Arrow, measure FFI vs 4K-batch cost

### Phase 4: Production Hardening & Observability (FUTURE)
- [ ] Circuit breaker pattern for persistent failures
- [ ] Task execution metrics and monitoring
- [ ] Alerting for retry exhaustion and recovery failures
- [ ] Historical failure pattern analysis
- [ ] Resource-aware retry policies
- [ ] Dynamic retry configuration based on system load

### Memory Management
- [ ] Memory-aware execution
  - [ ] Add `MemoryConf` to `SparkletConf`
  - [ ] Track partition sizes and prevent OOM
  - [ ] Implement spill-to-disk for large partitions
- [ ] Adaptive partitioning
  - [ ] Dynamic partition sizing based on data skew
  - [ ] Memory pressure detection and response

### Observability & Metrics
- [ ] Basic metrics collection
  - [ ] `ExecutionMetrics` case class with counters/timers
  - [ ] Stage completion times, shuffle bytes, task durations
  - [ ] Simple metrics reporter (console/file output)
- [ ] Structured event logging
  - [ ] JSON event log for query executions
  - [ ] Stage/task lifecycle events
- [ ] Performance monitoring
  - [ ] Memory usage tracking per stage
  - [ ] Shuffle read/write bandwidth monitoring

---

## Project 5 — User-Facing API Expansion

### DataFrame API (Priority 1)
- [ ] Core DataFrame implementation
  - [ ] `DataFrame(plan: Plan[Row], schema: StructType)`
  - [ ] Row representation and schema handling
  - [ ] Basic column expressions (`Column` class)
- [ ] Essential DataFrame operations
  - [ ] `select(cols: Column*)` - projection
  - [ ] `filter(condition: Column)` - row filtering  
  - [ ] `withColumn(name: String, col: Column)` - add/replace columns
  - [ ] `drop(colNames: String*)` - remove columns
- [ ] Aggregations and grouping
  - [ ] `groupBy(cols: Column*)` returning `GroupedData`
  - [ ] `agg()` with common functions: `sum`, `count`, `avg`, `max`, `min`
  - [ ] Window functions (basic implementation)
- [ ] DataFrame I/O
  - [ ] `DataFrame.read.parquet(path)` - read from files
  - [ ] `DataFrame.write.parquet(path)` - write to files
  - [ ] CSV and JSON support

### Dataset API (Priority 2)  
- [ ] Encoder system
  - [ ] `Encoder[T]` typeclass for case class serialization
  - [ ] Built-in encoders for primitives and common types
  - [ ] Automatic derivation for case classes
- [ ] Core Dataset implementation
  - [ ] `Dataset[T](plan: Plan[T], encoder: Encoder[T])`
  - [ ] Type-safe transformations: `map[U]`, `filter`, `flatMap`
  - [ ] Typed aggregations: `groupByKey`, `reduceGroups`
- [ ] Dataset-DataFrame interop
  - [ ] `Dataset.toDF()` conversion
  - [ ] `DataFrame.as[T]()` conversion with encoders

### API Integration & Testing
- [ ] Comprehensive API tests
  - [ ] End-to-end DataFrame workflows
  - [ ] Type safety verification for Dataset operations
  - [ ] Performance benchmarks vs DistCollection API
- [ ] Documentation and examples
  - [ ] API documentation with examples
  - [ ] Migration guide from DistCollection to DataFrame/Dataset
  - [ ] Sample ETL job implementations

---

## Project 6 — Distributed Execution

### Network Communication Layer
- [ ] Driver-Executor communication
  - [ ] gRPC service definitions for task submission
  - [ ] `DriverService` and `ExecutorService` traits
  - [ ] Protobuf schemas for task serialization
- [ ] Task serialization
  - [ ] `SerializedTask` with portable operation chains
  - [ ] Function serialization for UDFs
  - [ ] Partition data serialization protocols

### Standalone Executor JVM
- [ ] Lightweight executor process
  - [ ] Minimal JVM that receives and executes tasks
  - [ ] Resource management (CPU, memory limits)
  - [ ] Heartbeat and health reporting to driver
- [ ] Executor lifecycle management
  - [ ] Startup, task execution, graceful shutdown
  - [ ] Dynamic resource allocation
  - [ ] Failure detection and recovery

### Distributed Shuffle Service
- [ ] Network-based shuffle
  - [ ] Extend `ShuffleService` for remote storage
  - [ ] Shared storage backend (S3/HDFS) for shuffle data
  - [ ] Efficient shuffle read/write over network
- [ ] Shuffle optimization
  - [ ] Compression for shuffle data
  - [ ] Local disk caching of remote shuffle blocks
  - [ ] Shuffle service fault tolerance

### Cluster Resource Management
- [ ] Kubernetes-based deployment
  - [ ] `ClusterManager[F[_]]` trait for executor lifecycle
  - [ ] Kubernetes job/pod management for executors
  - [ ] Dynamic scaling based on workload
- [ ] Resource allocation
  - [ ] Request executors based on job requirements
  - [ ] Resource quotas and limits
  - [ ] Multi-tenant resource sharing

### Distributed Runtime Implementation
- [ ] `sparklet-runtime-cluster` module
  - [ ] Distributed implementations of core SPIs
  - [ ] Network-aware task scheduling
  - [ ] Cluster-wide resource coordination
- [ ] Configuration and deployment
  - [ ] Cluster configuration management
  - [ ] Docker images for driver and executor
  - [ ] Helm charts for Kubernetes deployment

---

## Project 7 — Advanced Features (All TBD)

### Caching & Persistence
- [ ] In-memory caching
  - [ ] `.persist()` with storage levels (memory/disk/both)
  - [ ] LRU eviction policies
  - [ ] Memory-aware cache management
- [ ] Checkpointing
  - [ ] `.checkpoint()` to truncate lineage
  - [ ] Reliable storage for checkpoint data
  - [ ] Automatic checkpoint placement optimization

### Query Optimization
- [ ] Physical plan layer
  - [ ] `PhysicalPlan` nodes (`ShuffleExchange`, `LocalHashAggregate`, etc.)
  - [ ] Cost-based optimizer with statistics
  - [ ] Rule-based optimizations
- [ ] Advanced optimizations
  - [ ] Predicate pushdown through joins/aggregations
  - [ ] Projection pruning for columnar formats
  - [ ] Stage coalescing and pipeline optimization
  - [ ] Adaptive query execution

### Advanced I/O & Formats
- [ ] Pluggable serialization
  - [ ] Abstract serialization boundary
  - [ ] Kryo, Avro, Protocol Buffers support
  - [ ] Schema evolution handling
- [ ] Columnar execution (Exploratory)
  - [ ] Apache Arrow integration
  - [ ] `runtime-native` module with Panama bridge
  - [ ] Vectorized operations for numeric data

### Streaming & Real-time
- [ ] Streaming API foundation
  - [ ] `StreamingDataFrame` for continuous processing
  - [ ] Windowing and watermark support
  - [ ] Kafka source/sink connectors
- [ ] Incremental computation
  - [ ] Delta processing for batch jobs
  - [ ] Change data capture (CDC) support

---

## Project 8 — Testing/QA

### Comprehensive Testing
- [ ] Property-based testing
  - [ ] ScalaCheck tests for transformation correctness
  - [ ] Invariant testing across all join types
  - [ ] Roundtrip testing for serialization
- [ ] Integration testing
  - [ ] End-to-end job execution tests
  - [ ] Multi-node cluster testing
  - [ ] Failure injection and recovery testing
- [ ] Performance testing
  - [ ] Benchmark suite for core operations
  - [ ] Scalability testing with increasing data sizes
  - [ ] Memory usage and GC pressure analysis

### CI/CD Pipeline
- [ ] Automated testing
  - [ ] Multi-module test execution
  - [ ] Cross-platform testing (Linux/macOS)
  - [ ] Performance regression detection
- [ ] Code quality
  - [ ] Scalafmt, Wartremover, Scalafix integration
  - [ ] Test coverage reporting
  - [ ] Documentation generation

---


## Project 9 — DataFusion (TBD)

### DataFusion Bridge Architecture
- [ ] Design JNI bridge interface
  - [ ] `DataFusionExecutor[F[_]]` trait for native execution
  - [ ] Arrow-based data interchange (`ArrowBatch`, `ArrowSchema`)
  - [ ] Plan translation layer: Sparklet Plan → DataFusion LogicalPlan
- [ ] Native execution module
  - [ ] `sparklet-datafusion-native` Rust crate
  - [ ] JNI bindings for plan execution
  - [ ] Arrow IPC serialization for JVM↔Rust data transfer
- [ ] Scala bridge implementation
  - [ ] `sparklet-datafusion-bridge` module
  - [ ] `JNIDataFusionExecutor` with error handling
  - [ ] Arrow decoders/encoders for common types

### Plan Translation Layer
- [ ] Logical plan translation
  - [ ] `PlanTranslator` trait for Sparklet → DataFusion conversion
  - [ ] Support for common operations: filter, map, join, aggregation
  - [ ] Handle UDFs and custom functions
- [ ] Physical plan optimization
  - [ ] Leverage DataFusion's optimizer for vectorized execution
  - [ ] Predicate pushdown and projection pruning
  - [ ] Columnar batch processing for numerical operations
- [ ] Schema management
  - [ ] Arrow schema inference from Scala types
  - [ ] Type-safe conversions between Row/case classes and Arrow records

### Native Performance Features
- [ ] Vectorized execution
  - [ ] SIMD-optimized operations for numerical data
  - [ ] Columnar batch processing (configurable batch sizes)
  - [ ] Memory-efficient string and date operations
- [ ] Memory management
  - [ ] Off-heap Arrow buffers to reduce GC pressure
  - [ ] Zero-copy data transfer where possible
  - [ ] Configurable memory pools for large datasets
- [ ] Advanced SQL support
  - [ ] Window functions, CTEs, complex expressions
  - [ ] Subquery optimization and execution
  - [ ] SQL→DataFrame compilation pipeline

### Integration Strategy
- [ ] Hybrid execution model
  - [ ] Keep existing Scala execution for development/testing
  - [ ] DataFusion execution for performance-critical workloads
  - [ ] Runtime switching via configuration flags
- [ ] Compatibility layer
  - [ ] Maintain existing DistCollection/DataFrame APIs
  - [ ] Transparent acceleration for supported operations
  - [ ] Graceful fallback to Scala execution for unsupported features
- [ ] Performance benchmarking
  - [ ] Benchmark suite comparing Scala vs DataFusion execution
  - [ ] Memory usage and GC pressure analysis
  - [ ] Vectorization effectiveness for different data types

---

## Other Ideas

- [ ] Web UI for job monitoring
  - [ ] Stage execution visualization
  - [ ] Task timeline and resource usage
  - [ ] Query plan visualization
- [ ] Advanced APIs
  - [ ] Broadcast variables with automatic distribution
  - [ ] Accumulators for custom metrics
  - [ ] ML pipeline integration hooks
- [ ] Ecosystem integration
  - [ ] Jupyter notebook support
  - [ ] IDE integration and debugging tools
  - [ ] Third-party tool connectors




