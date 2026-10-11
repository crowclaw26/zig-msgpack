# msgpack benchmark discussion with Muse — 2026-10-10

Evening thread on the `benchmark` branch of `justinhj/zig-msgpack`
(Antigravity implemented the benchmark plan; results in `docs/benchmarknotes.md`,
harness in `bench/compare.zig`, 36 workloads + chunked-streaming suite vs `zigcc/zig-msgpack`).

## Benchmark review: justinhj vs zigcc

**Verdict: the headline is credible.**
- **Writes 3–30x faster** — architectural, not a micro-optimization. zigcc's write API
  forces a heap-allocated DOM (`Payload`) tree before serializing; justinhj writes
  directly to the output stream. The report is honest that allocation dominates.
- **Reads: split.** justinhj wins on strings (+33–44%), maps (+44–51%), nested (+88%),
  binary (+12–33%). zigcc wins on large-int/float scalar decode (~2x) via branch-free
  fast paths — a genuine, bounded optimization target.
- **Methodology flag:** the sub-nanosecond write times (e.g. 0.49 ns/op) measure
  per-call overhead writing 1–2 bytes to a hot stack slot with no loop-carried deps,
  not serialization throughput. Ratios are directionally right, but don't quote them
  as throughput. The nested/mixed numbers (~10–22 ns for ~50-byte payloads) are the
  representative ones. Also single-run, no variance reported.
- **Streaming suite is the strongest part** — unique capability, sane numbers.

## Terminology: why "DOM"?

Borrowed from simdjson's API naming (DOM = parse whole input into an in-memory tree
first, vs On Demand streaming). Generic jargon now for tree-style parsing
(serde_json's `Value`, zigcc's `Payload`). The contrast is tree-in-memory vs streaming.

## Benching lalinsky/msgpack.zig ("the zio guy") — PARKED

- Identified: lalinsky (author of the zio async-I/O framework) wrote `lalinsky/msgpack.zig`,
  the typed comptime-API library (`writeStruct`/`readStruct`, no DOM).
- What it'd take: `zig fetch` dependency, ~36 struct-based workload adapters, ext/timestamp
  support check, 0.17.0 build verification. Framing must be typed-vs-untyped.
- Strategic value: reconnaissance for the planned comptime struct serialization —
  tells us the perf bar the typed layer must clear, and its map-vs-array encoding
  choice is the design decision being faced.
- **Decision: backburner. Comptime work first, then come back to this.**

## zigcc's SIMD

Nuance: SIMD helps bulk *throughput* (copies, scans), not single-value *latency* —
decoding one u64 is a load + byteswap, not vectorizable. So it likely doesn't explain
their scalar wins (that's branch-free paths). And the dog that didn't bark: if their
SIMD were in the copy path, they'd win the 1KB binary reads — they don't (we're
1.12–1.33x ahead). Advice: profile before reaching for SIMD to close the scalar gap;
it's probably branchiness in decode dispatch.

## Streaming: greedy parsing vs 1-byte chunks

Hart's "1-byte feeding costs only ~1.6x" needed Justin's correction: the *parser* is
greedy per attempt — each `nextAlloc` consumes maximal complete values, never re-scans
(O(1) amortized per byte). The 1-byte chunking is imposed artificially by the harness;
the 1.6x is per-feed call plumbing, not parsing work. In real use (`peekGreedy(1)` =
"at least one byte, whatever's available"), 1-byte chunks basically never occur —
real overhead is ~1.2x (the 8/64-byte columns). **Writeup framing: 1-byte column is the
adversarial bound, not the operating point.**

## msgpack-c comparison

- msgpack-c also streams: direct-write packer, unpacker with
  `reserve_buffer`/feed/`buffer_consumed`/`next` + zone (bump-arena) allocation.
  Our architectural advantages evaporate — it becomes a Zig-vs-C codegen shootout.
- Expected: close on both paths; the story becomes "safe Zig matches the reference C
  implementation," which is the badge that matters.
- What it'd take: compile msgpack-c sources via `addCSourceFile`, `@cImport`, thin
  adapters (sbuffer packer side, unpacker+zone read side). ~An afternoon.

## Sliding buffer (msgpack-c) vs ring buffer (ours)

Justin's observation, confirmed: msgpack-c compacts with `memmove` (slide unconsumed
tail to front), buying the parser a permanent contiguous-memory invariant at the cost
of occasional O(n) copies. Our ring buffer never copies; the state machine handles
wraparound — which is free, because wraparound and chunk boundaries are the same
resume-where-you-left-off mechanism.

## Infinite streaming is where we win

Not the RPC loop (buffer drains between messages; memmove rarely fires) but sustained,
never-draining streams: compactions recur for the connection lifetime and cluster
under backpressure — the worst time for a latency spike. Ring-buffer cost is flat
forever. **Headline for the writeup: no compaction pauses under sustained load**
(a tail-latency story, not a throughput story).

## Real-world infinite-stream use cases

- **Fluentd / Fluent Bit forward protocol** — the canonical one: persistent TCP,
  msgpack event streams 24/7. Cite in the writeup as the existence proof.
- Event ingestion pipelines (Treasure Data-style), market data feeds (where tail
  latency bites hardest), game state sync, and mildly our own neovim-boss.

## "Bench Fluentd, swap my library in" — refined

Direct swap is a project (Fluentd is Ruby; msgpack-ruby is a C ext — needs a C-ABI
shared lib + Ruby shim). Better: replay a Fluentd-like forward-protocol stream
(time/tag/record tuples, megabytes) through both unpackers in sustained mode, measuring
throughput **and p99/p999 frame latency**. An afternoon in the existing harness, no
Ruby overhead muddying the numbers.

## README performance summary (drafted)

```markdown
## Performance

Benchmarked head-to-head against [zigcc/zig-msgpack](https://github.com/zigcc/zig-msgpack)
across 36 identical workloads in a single harness (`zig build bench -Doptimize=ReleaseFast`;
full methodology and results in [docs/benchmarknotes.md](docs/benchmarknotes.md)):

- **Serialization is 3–30x faster.** zigcc's API requires building a heap-allocated
  DOM tree before anything can be written; this library writes directly to the
  output stream with no intermediate allocations. The gap is architectural, not
  a micro-optimization.
- **Deserialization is faster on structured data.** Strings, maps, arrays, nested
  structures, and binary blobs decode 1.1–1.9x faster from whole buffers. Scalar
  integer/float decoding is currently zigcc's stronghold (~2x) via branch-free
  fast paths.
- **Streaming decode is unique to this library.** zigcc can only parse a complete,
  contiguous buffer; the state-machine unpacker here consumes data across arbitrary
  chunk boundaries with no re-parsing — even fed one byte at a time (an adversarial
  bound; real I/O reads greedily), nested structures still decode at over
  2.6M messages/sec.
```

One-liner version: "3–30x faster serialization, faster structured decoding, and the
only Zig msgpack parser that streams."

## Open threads / next steps

1. Comptime struct serialization design (map vs array encoding; lalinsky recon later).
2. Scalar int/float decode fast paths (the one read-side deficit vs zigcc).
3. Sustained-stream benchmark with p99/p999 latency vs msgpack-c (Fluentd-like workload).
4. msgpack-c head-to-head (embed via `addCSourceFile`, an afternoon).
5. Frame the 1-byte streaming column as adversarial bound in the writeup; add bytes/sec
   column; note single-run methodology.
