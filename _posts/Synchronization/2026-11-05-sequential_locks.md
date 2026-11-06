---
title: Sequential Locks in the Linux Kernel
published: true
categories: [Synchronization]
tags: [seqlock, seqcount, synchronization]
mermaid: true
---

# Sequential Locks in the Linux Kernel

Most data in a kernel is read far more often than it is written. A routing table, a mount namespace, a process's accumulated CPU time, the current time of day, and the `jiffies` counter are all inspected by many execution contexts but modified by relatively few. A plain **spinlock** serializes every access, including two readers that only load a field. A **reader-writer spinlock** improves on that by allowing readers to proceed together, but it still makes every reader write to a shared lock word, and it still makes every writer wait for the last reader to leave. Both primitives answer the question "who may enter?" A **sequential lock** answers a different question: "was the data stable while I looked at it?"

That change of question is the whole idea. A **sequential lock** — `seqlock_t` in Linux — lets readers enter without acquiring anything, without writing to shared memory, and without being able to block a writer. The writer never waits for a reader. Instead, the writer publishes a **sequence number** that changes at the start and end of every update, and each reader checks that number after copying the data out. If the number changed, the reader throws the copy away and tries again. Readers get a consistent snapshot by **optimistic concurrency control**, not by mutual exclusion. Writers get a guarantee that no reader can ever delay them.

On AArch64 the primitive is deceptively small. A production `seqlock_t` is typically eight bytes: a 32-bit **sequence counter** and a 32-bit **queued spinlock** used only to serialize writers. __The reader's hot path contains no atomic read-modify-write operation at all — just an ordinary load of the counter, ordinary loads of the data, and a load-load barrier before rechecking the counter.__ That is why sequential locks scale where reader-writer locks do not: readers share the cache line instead of taking exclusive ownership of it. The price is a set of strict rules about what may be protected, what a reader may do, and which contexts may participate.

This document examines `seqlock_t` and its underlying `seqcount_t` on AArch64. It covers why the primitive exists, how it is initialized and used, what the even/odd protocol means at the instruction level, how the AArch64 memory model shapes the implementation, how preemption and interrupt context interact with it, where the sharp edges are, and how real kernel subsystems such as timekeeping and the VFS use it. Unless stated otherwise, the discussion describes a non-`PREEMPT_RT` SMP kernel; `PREEMPT_RT` and NMI-specific behavior are treated separately because they change the rules in interesting ways.

**Diagram conventions.** Timelines run from top to bottom. Columns that sit side by side represent concurrent CPUs or contexts, not a strict wall-clock ordering. `R` and `W` mean reader and writer, `CS` means critical section, and sequence values are shown in decimal unless a raw word is being discussed. A sequence value is always interpreted by its **parity**: even means "no writer is inside its update," odd means "a writer is inside its update."

---

## Table of Contents

1. [Why Reader-Writer Locks Struggle](#1-why-reader-writer-locks-struggle)
   - 1.1 [The Shared Lock Word Is a Contended Cache Line](#11-the-shared-lock-word-is-a-contended-cache-line)
   - 1.2 [Readers Delay Writers](#12-readers-delay-writers)
   - 1.3 [Fairness Machinery and Writer Starvation](#13-fairness-machinery-and-writer-starvation)
   - 1.4 [The Insight: Readers Do Not Need to Write](#14-the-insight-readers-do-not-need-to-write)
2. [What a Sequential Lock Is](#2-what-a-sequential-lock-is)
   - 2.1 [Consistency Without Exclusion](#21-consistency-without-exclusion)
   - 2.2 [The Even/Odd Protocol](#22-the-evenodd-protocol)
   - 2.3 [A Reader's Contract](#23-a-readers-contract)
   - 2.4 [Sequential Lock vs. Reader-Writer Lock](#24-sequential-lock-vs-reader-writer-lock)
3. [The Data Structures](#3-the-data-structures)
   - 3.1 [`seqcount_t`](#31-seqcount_t)
   - 3.2 [`seqlock_t`](#32-seqlock_t)
   - 3.3 [Sequence Counters with Associated Locks](#33-sequence-counters-with-associated-locks)
   - 3.4 [`seqcount_latch_t`](#34-seqcount_latch_t)
   - 3.5 [Layout and Size on AArch64](#35-layout-and-size-on-aarch64)
   - 3.6 [Which Type and Which API?](#36-which-type-and-which-api)
4. [Initialization](#4-initialization)
   - 4.1 [Static Initialization of a `seqlock_t`](#41-static-initialization-of-a-seqlock_t)
   - 4.2 [Dynamic Initialization of a `seqlock_t`](#42-dynamic-initialization-of-a-seqlock_t)
   - 4.3 [Initializing a `seqcount_t`](#43-initializing-a-seqcount_t)
   - 4.4 [Initializing an Associated Sequence Counter](#44-initializing-an-associated-sequence-counter)
   - 4.5 [What Initialization Actually Does](#45-what-initialization-actually-does)
5. [The Writer Side](#5-the-writer-side)
   - 5.1 [`write_seqlock()` and `write_sequnlock()`](#51-write_seqlock-and-write_sequnlock)
   - 5.2 [The Sequence Protocol and Its Barriers](#52-the-sequence-protocol-and-its-barriers)
   - 5.3 [`write_seqcount_begin()` and `write_seqcount_end()`](#53-write_seqcount_begin-and-write_seqcount_end)
   - 5.4 [Raw, Nested, Barrier, and Invalidate Variants](#54-raw-nested-barrier-and-invalidate-variants)
   - 5.5 [Two Writers Arrive](#55-two-writers-arrive)
   - 5.6 [Why the Unlock Order Matters](#56-why-the-unlock-order-matters)
   - 5.7 [Writer API at a Glance](#57-writer-api-at-a-glance)
6. [The Reader Side](#6-the-reader-side)
   - 6.1 [`read_seqbegin()` and `read_seqretry()`](#61-read_seqbegin-and-read_seqretry)
   - 6.2 [One Timeline: Accept, Retry, Stabilize](#62-one-timeline-accept-retry-stabilize)
   - 6.3 [The Reader State Machine](#63-the-reader-state-machine)
   - 6.4 [Raw and Non-Stabilizing Begins](#64-raw-and-non-stabilizing-begins)
   - 6.5 [The Copy-Out Rule](#65-the-copy-out-rule)
   - 6.6 [What the Reader May Not Do](#66-what-the-reader-may-not-do)
   - 6.7 [Reader Questions: Spin, Sleep, and Stale Values](#67-reader-questions-spin-sleep-and-stale-values)
7. [A Complete `kthread` Example](#7-a-complete-kthread-example)
   - 7.1 [The Module](#71-the-module)
   - 7.2 [One Timeline: Four Cases](#72-one-timeline-four-cases)
   - 7.3 [What the Example Demonstrates](#73-what-the-example-demonstrates)
8. [`seqcount_t` vs. `seqlock_t`](#8-seqcount_t-vs-seqlock_t)
   - 8.1 [The Decision Matrix](#81-the-decision-matrix)
   - 8.2 [Associated Locks and Lockdep](#82-associated-locks-and-lockdep)
   - 8.3 [Why `seqlock_t` Uses `seqcount_spinlock_t`](#83-why-seqlock_t-uses-seqcount_spinlock_t)
   - 8.4 [Choosing a Writer Serialization Mechanism](#84-choosing-a-writer-serialization-mechanism)
9. [Preemption, Interrupts, and Context](#9-preemption-interrupts-and-context)
   - 9.1 [Readers Are Preemptible](#91-readers-are-preemptible)
   - 9.2 [Writers Are Not](#92-writers-are-not)
   - 9.3 [The Same-CPU Deadlock](#93-the-same-cpu-deadlock)
   - 9.4 [What `_irqsave` Saves on AArch64](#94-what-_irqsave-saves-on-aarch64)
   - 9.5 [IRQ and Bottom-Half Variants](#95-irq-and-bottom-half-variants)
   - 9.6 [The Locking Reader](#96-the-locking-reader)
   - 9.7 [NMI and `seqcount_latch_t`](#97-nmi-and-seqcount_latch_t)
   - 9.8 [`PREEMPT_RT`](#98-preempt_rt)
   - 9.9 [Context Selection Matrix](#99-context-selection-matrix)
10. [Memory Ordering on AArch64](#10-memory-ordering-on-aarch64)
    - 10.1 [What Must Be Ordered](#101-what-must-be-ordered)
    - 10.2 [The Instructions](#102-the-instructions)
    - 10.3 [The Writer's Barriers](#103-the-writers-barriers)
    - 10.4 [The Reader's Barriers](#104-the-readers-barriers)
    - 10.5 [Why the Writer Barriers Matter](#105-why-the-writer-barriers-matter)
    - 10.6 [Compiler Ordering and `READ_ONCE`](#106-compiler-ordering-and-read_once)
11. [Livelock, Retry Storms, and the Locking Reader](#11-livelock-retry-storms-and-the-locking-reader)
    - 11.1 [Reader Starvation](#111-reader-starvation)
    - 11.2 [`read_seqbegin_or_lock()`](#112-read_seqbegin_or_lock)
    - 11.3 [`need_seqretry()` and `done_seqretry()`](#113-need_seqretry-and-done_seqretry)
    - 11.4 [The IRQ-Safe Variant](#114-the-irq-safe-variant)
    - 11.5 [`scoped_seqlock_read()`](#115-scoped_seqlock_read)
    - 11.6 [When to Fall Back to Locking](#116-when-to-fall-back-to-locking)
12. [Limitations and Sharp Edges](#12-limitations-and-sharp-edges)
    - 12.1 [Pointers and Object Lifetime](#121-pointers-and-object-lifetime)
    - 12.2 [Side Effects](#122-side-effects)
    - 12.3 [Large or Complex Data](#123-large-or-complex-data)
    - 12.4 [Counter Wrap and ABA](#124-counter-wrap-and-aba)
    - 12.5 [Writer Serialization](#125-writer-serialization)
    - 12.6 [Long Readers and Cache Pressure](#126-long-readers-and-cache-pressure)
    - 12.7 [Lifetime of the Lock Itself](#127-lifetime-of-the-lock-itself)
    - 12.8 [Nesting and Reentrancy](#128-nesting-and-reentrancy)
    - 12.9 [What a Seqlock Does Not Provide](#129-what-a-seqlock-does-not-provide)
    - 12.10 [Sharp Edges at a Glance](#1210-sharp-edges-at-a-glance)
13. [Real-World Users on AArch64](#13-real-world-users-on-aarch64)
    - 13.1 [The Tick Counter](#131-the-tick-counter)
    - 13.2 [The Timekeeper](#132-the-timekeeper)
    - 13.3 [The NMI-Safe Clock](#133-the-nmi-safe-clock)
    - 13.4 [Mount and Rename Detection](#134-mount-and-rename-detection)
    - 13.5 [Filesystem Root and Working Directory](#135-filesystem-root-and-working-directory)
    - 13.6 [Network, Namespace, and Memory Hotplug](#136-network-namespace-and-memory-hotplug)
14. [Performance and Scalability](#14-performance-and-scalability)
    - 14.1 [The Reader Fast Path](#141-the-reader-fast-path)
    - 14.2 [The Writer Cost](#142-the-writer-cost)
    - 14.3 [Cache Lines and NUMA](#143-cache-lines-and-numa)
    - 14.4 [Seqlock vs. RCU vs. `rwlock_t`](#144-seqlock-vs-rcu-vs-rwlock_t)
    - 14.5 [When Not to Use a Seqlock](#145-when-not-to-use-a-seqlock)
15. [Summary: Rules of Thumb](#15-summary-rules-of-thumb)
16. [References](#16-references)
    - 16.1 [Core Types and API](#161-core-types-and-api)
    - 16.2 [Sequence Counter Implementation](#162-sequence-counter-implementation)
    - 16.3 [AArch64 Memory Ordering](#163-aarch64-memory-ordering)
    - 16.4 [Timekeeping and `jiffies`](#164-timekeeping-and-jiffies)
    - 16.5 [VFS and Other Users](#165-vfs-and-other-users)
    - 16.6 [Documentation and Comparisons](#166-documentation-and-comparisons)

---

## 1. Why Reader-Writer Locks Struggle

### 1.1 The Shared Lock Word Is a Contended Cache Line

An `rwlock_t` on AArch64 is a `qrwlock`: a 32-bit reader count (`cnts`) plus a 32-bit queued spinlock. The reader fast path is `atomic_add_return_acquire(_QR_BIAS, &cnts)` on entry and `atomic_sub_return_release(_QR_BIAS, &cnts)` on exit. Both are read-modify-write operations on the same cache line.

```text
              rwlock_t readers                         seqlock_t readers
              ────────────────                         ─────────────────
CPU0 ── atomic RMW ──┐                       CPU0 ── plain load ──┐
CPU1 ── atomic RMW ──┼──► lock word           CPU1 ── plain load ──┼──► sequence word
CPU2 ── atomic RMW ──┘    exclusive,          CPU2 ── plain load ──┘    shared,
                           bounces                                      read-only

per reader: 2 atomics (owns the line twice)   per reader: 2 loads (never owns it)
writer:     waits for readers to drain        writer:     never waits for readers
```

Logically the qrwlock reader shares the lock; at the coherency level it **writes** it. Every entry and exit takes exclusive ownership of the line, twice per reader, so the line bounces even when the data is read-only. `wait_lock` usually shares the same line, so writer queue traffic collides with reader traffic.

### 1.2 Readers Delay Writers

A writer must wait for the reader count to reach zero. A reader that is preempted, interrupted, or slow keeps the writer waiting for the whole read-side section. If the writer spins with preemption disabled while the reader it waits for needs the same CPU, the result is priority inversion. The queued implementation reduces the worst cases; it cannot remove the dependency.

### 1.3 Fairness Machinery and Writer Starvation

Continuous readers could starve a writer, so `qrwlock` sets a **waiting bit** (`_QW_WAITING`, `0x100`) when a writer queues; new readers then queue behind it. That is correct, but it is machinery to arbitrate access to one shared word. A seqlock removes the competition: readers never queue, and writers never queue behind readers.

### 1.4 The Insight: Readers Do Not Need to Write

If the writer leaves a marker that says "an update is in progress", a reader can:

1. Read the marker before touching the data.
2. Copy the data into private storage.
3. Read the marker again.
4. Accept the copy only if the marker did not change.

This is **optimistic concurrency control**. An `rwlock_t` reader is guaranteed that nothing changes while it holds the lock. A seqlock reader is guaranteed only that its copy was consistent at some instant during the read. That means the reader may retry, must copy rather than keep pointers into the shared data, and must not perform irreversible side effects before validating the copy.

---

## 2. What a Sequential Lock Is

### 2.1 Consistency Without Exclusion

The kernel documentation defines the mechanism precisely: a data set is consistent when the sequence count at the beginning of the read-side critical section is even and the same value is read again at the end, with the data copied out inside the section. If the count changed, the reader must retry. Writers increment the count at the start and at the end of their critical section; after the start the count is odd, indicating that an update is in progress, and at the end it becomes even again. See [Documentation/locking/seqlock.rst](https://github.com/torvalds/linux/blob/v7.3-rc7/Documentation/locking/seqlock.rst#L10-L36).

That definition contains three distinct properties, and the third is a limit rather than a guarantee:

- **Writer progress:** a writer never waits for a sequence reader. The writer only serializes against other writers.
- **Reader consistency:** an accepted read is a snapshot that existed at some point between the begin and the retry. It is not necessarily the latest snapshot.
- **Reader liveness:** a reader is not guaranteed to finish in bounded time. Under a continuous write stream it may retry indefinitely, which is why the kernel provides a locking-reader fallback.

The absence of writer starvation is the headline. The absence of reader-starvation guarantees is the price.

### 2.2 The Even/Odd Protocol

The sequence starts at zero. A writer makes it odd before modifying anything and even again when it has finished. A reader accepts its copy only when the value at the end equals the even value at the beginning.

```text
time ─────────────────────────────────────────────────────────────────────►
sequence    0          1          2          3          4
            ├──────────┼──────────┼──────────┼──────────┤
parity      even       odd        even       odd        even
state       stable     W1 update  stable     W2 update  stable
                       └──────────┘          └──────────┘
                       writer inside         writer inside

reader A  [ begin=0 ................................ retry=2 ]  ✗ changed → retry
reader B                        [ begin=2 .. retry=2 ]          ✓ stable
reader C  [ begin=0 .. retry=0 ]                                ✓ no writer
```

The value is a **version number with a parity bit**: the low bit means "writer inside", the upper bits distinguish completed versions. So:

| begin | end | meaning |
|---|---|---|
| 0 | 0 | no writer started or finished; accept |
| 0 | 2 | a writer completed in between; reject even though both are even |
| 0 | 1 | a writer is still inside; wait or reject |

The two increments are ordinary `++` operations on a 32-bit `unsigned`, not `atomic_t`. That is safe because writers are serialized and an aligned 32-bit load/store on AArch64 is single-copy atomic. Readers never see a half-written sequence.

### 2.3 A Reader's Contract

A sequence reader must obey four rules:

1. **Copy, do not retain.** The data must be copied into private storage inside the read-side section. A pointer into the shared structure is worthless after the section ends, because the writer may have changed or freed the object.
2. **Validate before use.** The copied values must not be used until `read_seqretry()` (or `read_seqcount_retry()`) has confirmed that the sequence did not change. A torn copy is expected and must be discarded.
3. **Do not perform irreversible side effects.** Printing, publishing a pointer, taking a reference that cannot be dropped, or modifying global state inside the retry loop will be repeated when the reader retries. If a side effect is unavoidable, it must be undoable, as in the dentry reference-count patterns discussed in §12.2.
4. **Keep the section short.** The reader does not block the writer, but a long read section increases the chance of a retry and the amount of work wasted when a retry happens.

A reader that follows these rules gets a consistent snapshot without ever acquiring a lock. A reader that violates them gets a data race that is much harder to debug than an ordinary lock misuse, because the kernel will happily produce a plausible but inconsistent value.

### 2.4 Sequential Lock vs. Reader-Writer Lock

The two primitives are often compared as if they were variants of the same thing. They are not. The following table makes the difference explicit.

| Property | `rwlock_t` | `seqlock_t` |
|---|---|---|
| Reader's shared-memory writes | Atomic add/sub on `cnts` | None; readers only load |
| Writer waits for readers | Yes | No |
| Reader waits for writer | Yes, when a writer holds or is waiting | Only while the sequence is odd at `read_seqbegin()`; otherwise it retries |
| Consistency mechanism | Mutual exclusion | Version check and retry |
| Reader retry | No | Yes |
| Pointer-based data | Safe while the lock is held | Unsafe unless object lifetime is protected externally (for example by RCU) |
| Reader side effects | Allowed | Discouraged; must be undoable |
| Writer starvation | Possible without fairness machinery; prevented by `qrwlock`'s waiting bit | Impossible for sequence readers; a locking reader can still block a writer by design |
| Reader starvation | Possible under a continuous writer stream | Possible; mitigated by `read_seqbegin_or_lock()` |
| Context | Atomic; readers and writers spin | Readers are lockless and preemptible; writers must be non-preemptible |
| Best fit | Read-mostly data that may contain pointers and needs exclusion | Small, read-mostly scalar data with rare, short updates |

The last row is the practical summary. A seqlock is not a faster `rwlock_t`; it is a different tool with a narrower data model.

---

## 3. The Data Structures

### 3.1 `seqcount_t`

The raw mechanism is **`seqcount_t`**, defined in [include/linux/seqlock_types.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/seqlock_types.h#L33-L38):

```c
typedef struct seqcount {
    unsigned sequence;
#ifdef CONFIG_DEBUG_LOCK_ALLOC
    struct lockdep_map dep_map;
#endif
} seqcount_t;
```

It is deliberately minimal. There is no writer lock, no reader count, and no owner field. The comment above the type is unusually direct about the consequences: write-side critical sections must be serialized and non-preemptible; if readers can be invoked from hardirq or softirq context, interrupts or bottom halves must be disabled before entering the write section; and the mechanism cannot be used if the protected data contains pointers, because the writer can invalidate a pointer that a reader is following. See [include/linux/seqlock_types.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/seqlock_types.h#L9-L32).

A `seqcount_t` is therefore a building block, not a complete lock. It assumes the caller already has a way to serialize writers and to keep the writer from being preempted by a reader. That is exactly the situation in many kernel hot paths: the caller already holds a `raw_spinlock_t`, a `spinlock_t`, or a mutex, and adding a second embedded spinlock would be redundant.

The type is four bytes in a production kernel. `CONFIG_DEBUG_LOCK_ALLOC` adds a `lockdep_map`, which makes it much larger but gives lockdep a class to track. There is no `atomic_t` and no hidden state.

### 3.2 `seqlock_t`

A **`seqlock_t`** is a `seqcount_t` plus an embedded spinlock for writer serialization. The definition in [include/linux/seqlock_types.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/seqlock_types.h#L84-L92) is short but carries an important design comment:

```c
context_lock_struct(seqlock) {
    /*
     * Make sure that readers don't starve writers on PREEMPT_RT: use
     * seqcount_spinlock_t instead of seqcount_t. Check __SEQ_LOCK().
     */
    seqcount_spinlock_t seqcount;
    spinlock_t lock;
};
typedef struct seqlock seqlock_t;
```

The sequence counter is not a plain `seqcount_t`; it is a **`seqcount_spinlock_t`**, which associates the counter with the embedded `lock`. The association costs nothing when neither lockdep nor `PREEMPT_RT` is enabled, because `__SEQ_LOCK(expr)` expands to nothing in that configuration. It exists for two reasons:

- **Lockdep validation:** the write side can assert that the associated lock is held, catching callers that forget to serialize writers.
- **`PREEMPT_RT` liveness:** on `PREEMPT_RT`, a reader that sees an odd sequence can briefly acquire and release the associated sleeping lock, which lets a preempted writer make progress. This is the "readers don't starve writers" mechanism mentioned in the comment and explained in §9.8.

The `spinlock_t lock` is the writer serialization lock. It is acquired by `write_seqlock()` and released by `write_sequnlock()`. Readers never touch it on the fast path.

The containment and the self-reference are worth drawing once:

```text
seqcount_t
└── sequence : unsigned (4 bytes)
    └── dep_map : struct lockdep_map    only with CONFIG_DEBUG_LOCK_ALLOC

seqcount_spinlock_t
├── seqcount : seqcount_t
└── lock     : spinlock_t *            only with LOCKDEP || PREEMPT_RT

seqlock_t
├── seqcount : seqcount_spinlock_t
│       └── lock pointer ────────────┐
└── lock     : spinlock_t ◄──────────┘   embedded writer lock
```

The optional pointer is the entire association. It is not a second lock, a reference count, or a wait queue. On a production non-RT, non-lockdep kernel the pointer does not exist, so the associated type has the same four-byte layout as `seqcount_t`.

### 3.3 Sequence Counters with Associated Locks

The kernel generalizes the idea with **`seqcount_LOCKNAME_t`** types. Each one wraps a `seqcount_t` and, when lockdep or `PREEMPT_RT` needs it, a pointer to the lock that serializes writers. The types are generated by a macro in [include/linux/seqlock_types.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/seqlock_types.h#L62-L72):

```c
#define SEQCOUNT_LOCKNAME(lockname, locktype, preemptible, lockbase) \
typedef struct seqcount_##lockname {                                 \
    seqcount_t      seqcount;                                        \
    __SEQ_LOCK(locktype *lock);                                      \
} seqcount_##lockname##_t;

SEQCOUNT_LOCKNAME(raw_spinlock, raw_spinlock_t,  false,    raw_spin)
SEQCOUNT_LOCKNAME(spinlock,     spinlock_t,      __SEQ_RT, spin)
SEQCOUNT_LOCKNAME(rwlock,       rwlock_t,        __SEQ_RT, read)
SEQCOUNT_LOCKNAME(mutex,        struct mutex,    true,     mutex)
#undef SEQCOUNT_LOCKNAME
```

There are four variants in this kernel:

| Type | Associated lock | `preemptible` argument | RT reader-helps-writer |
|---|---|---|---|
| `seqcount_raw_spinlock_t` | `raw_spinlock_t *` | `false` | No; raw spinlocks are non-sleeping on RT |
| `seqcount_spinlock_t` | `spinlock_t *` | `__SEQ_RT` | Yes; the lock is a sleeping lock on RT |
| `seqcount_rwlock_t` | `rwlock_t *` | `__SEQ_RT` | Yes; uses the read side of the rwlock |
| `seqcount_mutex_t` | `struct mutex *` | `true` | Yes; the reader can take the mutex |

The fourth macro argument, `lockbase`, is the prefix used by the RT reader-help path. For `seqcount_rwlock_t` it is `read`, so the generated code calls `read_lock()` and `read_unlock()`; for the others it is the corresponding lock/unlock pair.

The important property is that the association is **compile-time free** in the common configuration. [include/linux/seqlock_types.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/seqlock_types.h#L56-L60) defines:

```c
#if defined(CONFIG_LOCKDEP) || defined(CONFIG_PREEMPT_RT)
#define __SEQ_LOCK(expr)    expr
#else
#define __SEQ_LOCK(expr)
#endif
```

Without lockdep and without `PREEMPT_RT`, `seqcount_spinlock_t` is exactly a `seqcount_t`: four bytes, no pointer, no runtime cost. With lockdep, the pointer is stored so `lockdep_assert_held(s->lock)` can validate the writer. With `PREEMPT_RT`, it is stored so the reader can take the lock if it observes an in-progress writer.

### 3.4 `seqcount_latch_t`

A **latch sequence counter** is a different variant for a different problem. It uses the even/odd value not to validate a copy of one data set, but to select between **two copies** of the protected data. That allows a reader — typically an NMI handler — to interrupt a writer and still find a stable copy. The type is defined in [include/linux/seqlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/seqlock.h#L610-L626):

```c
typedef struct {
    seqcount_t seqcount;
} seqcount_latch_t;

#define SEQCNT_LATCH_ZERO(seq_name) {                    \
    .seqcount = SEQCNT_ZERO(seq_name.seqcount),          \
}

#define seqcount_latch_init(s) seqcount_init(&(s)->seqcount)
```

The writer alternates between the two copies:

```text
writer                                   readers
──────                                   ───────
latch_begin: counter even → odd          read counter
update copy 0                            odd  → read copy 1
latch:       counter odd → even          even → read copy 0
update copy 1                            retry if the counter changed
latch_end:   leaves the counter even
```

The invariant is a two-row table:

| Sequence parity | Writer is modifying | Reader must read |
|---|---|---|
| even (`0`) | `copy[1]` after the second latch | `copy[0]` |
| odd (`1`) | `copy[0]` | `copy[1]` |

The reader does not wait for the writer to finish; it reads the copy that the writer is not touching. The final retry catches the case where the parity flipped while the reader was reading.

The reader picks `copy[seq & 1]` and rechecks the full sequence. While the writer is modifying one copy, readers are directed to the other, which is stable. The cost is double storage; the benefit is that a reader can complete even while a writer is mid-update, which is exactly what an NMI needs. The full protocol and the comments about dynamic data structures are in [include/linux/seqlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/seqlock.h#L628-L804).

The latch is not a general-purpose seqlock. It is a multiversion concurrency-control scheme for data that can be duplicated. It is used by the NMI-safe timekeeper, discussed in §13.3.

### 3.5 Layout and Size on AArch64

On a non-debug, non-`PREEMPT_RT` AArch64 kernel, the types are compact:

```text
type                     size    contents
──────────────────────   ─────   ─────────────────────────────────────────
seqcount_t                4 B    unsigned sequence (+ lockdep map if debug)
seqcount_spinlock_t       4 B    sequence (lock pointer only with lockdep/RT)
spinlock_t                4 B    qspinlock word
seqlock_t                 8 B    sequence + embedded writer spinlock
rwlock_t (comparison)     8 B    reader count + wait_lock
```

With `CONFIG_DEBUG_LOCK_ALLOC`, the `seqcount_t` grows by a `lockdep_map`, the associated variants grow by a lock pointer, and the embedded `spinlock_t` grows by its own dep map. With `CONFIG_DEBUG_SPINLOCK`, the spinlock also grows by a magic value, owner CPU, and owner pointer. On `PREEMPT_RT`, the embedded `spinlock_t` becomes an rt-mutex-based structure and the layout is much larger.

The small size is not the interesting part; the **cache behavior** is. The sequence word and the protected data are usually read together, so co-locating them can reduce cache misses. But the sequence word is written by the writer and read by every reader, which makes it a natural point of invalidation. Global seqlocks are often cache-line aligned to avoid false sharing with unrelated data. The VFS does this for `mount_lock` and `rename_lock`:

```c
__cacheline_aligned_in_smp DEFINE_SEQLOCK(mount_lock);
__cacheline_aligned_in_smp DEFINE_SEQLOCK(rename_lock);
```

from [fs/namespace.c](https://github.com/torvalds/linux/blob/v7.3-rc7/fs/namespace.c#L129) and [fs/dcache.c](https://github.com/torvalds/linux/blob/v7.3-rc7/fs/dcache.c#L85). The timekeeper takes the opposite approach: it aligns the whole `struct tk_data` so that the sequence, the hot timekeeper fields, and the lock share a small number of lines. See [kernel/time/timekeeping.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/time/timekeeping.c#L44-L58). Both choices keep the writer's invalidations away from unrelated hot data while keeping the reader's working set together.

### 3.6 Which Type and Which API?

**Default:** use `seqlock_t` — `DEFINE_SEQLOCK()`, `write_seqlock()`/`write_sequnlock()`, `read_seqbegin()`/`read_seqretry()`. Move to a `seqcount_*` variant only when the writer already holds a lock. Use the latch only when readers can run in NMI.

| Category | Name | Writer side | Reader side | Use when |
|---|---|---|---|---|
| Type | `seqcount_t` | `write_seqcount_begin/end()`; caller holds a lock and disables preemption | `read_seqcount_begin()/read_seqcount_retry()` | you already have writer serialization |
| Type | `seqcount_raw_spinlock_t` | holds a `raw_spinlock_t` | same | low-level writer already holds a raw lock (`jiffies_seq`) |
| Type | `seqcount_spinlock_t` | holds a `spinlock_t` | same | per-object counter whose writer holds a spinlock (`dentry->d_seq`) |
| Type | `seqcount_rwlock_t` | holds the write side of an `rwlock_t` | same | writer already holds an rwlock write side |
| Type | `seqcount_mutex_t` | holds a `mutex`; helper disables preemption for the short section | same | writer is process context and may sleep |
| Type | `seqlock_t` | `write_seqlock()` family; embedded spinlock | `read_seqbegin()/read_seqretry()` | self-contained short atomic update; **normal choice** |
| Type | `seqcount_latch_t` | `write_seqcount_latch_begin()/latch()/latch_end()` | `read_seqcount_latch()/latch_retry()` | readers may run in NMI |
| Writer API | `write_seqlock()` / `write_sequnlock()` | disables preemption | — | readers only in process context |
| Writer API | `write_seqlock_bh()` / `write_sequnlock_bh()` | disables softirqs | — | readers can run in softirq |
| Writer API | `write_seqlock_irq()` / `write_sequnlock_irq()` | disables local IRQs | — | readers can run in hardirq |
| Writer API | `write_seqlock_irqsave()` / `write_sequnlock_irqrestore()` | saves IRQ state, disables IRQs | — | same as `_irq`, but nesting is possible; **usual hardirq choice** |
| Writer API | `raw_write_seqcount_begin/end()` | skips lockdep only | — | hot path where context is already validated |
| Writer API | `write_seqcount_invalidate()` | `sequence += 2` | — | force in-flight readers to retry |
| Reader API | `read_seqbegin()` / `read_seqretry()` | — | lockless, retry | normal reader |
| Reader API | `read_seqlock_excl()` / `read_sequnlock_excl()` | — | takes the embedded lock | reader must keep pointers/references stable |
| Reader API | `read_seqbegin_or_lock()` + `need_seqretry()`/`done_seqretry()` | — | lockless first, locking on retry | bound reader work under heavy writes |
| Reader API | `scoped_seqlock_read()` | — | scoped fallback | new code; makes "copy inside loop" structural |

The `seqcount_*` variants are not different locks; they are the same counter with a pointer to the lock that already serializes the writer. Without lockdep and `PREEMPT_RT` that pointer does not exist, so they cost the same as a plain `seqcount_t`.

---

## 4. Initialization

### 4.1 Static Initialization of a `seqlock_t`

For a lock with static storage duration, use `DEFINE_SEQLOCK`:

```c
#include <linux/seqlock.h>

static DEFINE_SEQLOCK(my_lock);
```

The macro is defined in [include/linux/seqlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/seqlock.h#L806-L827):

```c
#define __SEQLOCK_UNLOCKED(lockname)                                    \
    {                                                                   \
        .seqcount = SEQCNT_SPINLOCK_ZERO(lockname, &(lockname).lock),   \
        .lock = __SPIN_LOCK_UNLOCKED(lockname)                          \
    }

#define DEFINE_SEQLOCK(sl) \
        seqlock_t sl = __SEQLOCK_UNLOCKED(sl)
```

Two things are happening in that initializer. The embedded spinlock is initialized to the architecture's unlocked state. The sequence counter is initialized to zero and, when the configuration needs it, associated with the address of the embedded lock. The association is written as `&(lockname).lock`, so it is a self-reference: the `seqcount_spinlock_t` inside the same `seqlock_t` points at its sibling `spinlock_t`.

The C99 form is also supported for a seqlock embedded in a larger structure:

```c
struct my_data {
    seqlock_t lock;
    int value;
};

static struct my_data foo = {
    .lock = __SEQLOCK_UNLOCKED(foo.lock),
};
```

This is the form documented in [Documentation/locking/seqlock.rst](https://github.com/torvalds/linux/blob/v7.3-rc7/Documentation/locking/seqlock.rst#L173-L185). It is easy to get wrong: the name passed to `__SEQLOCK_UNLOCKED` must match the member being initialized, because it is used both for the lockdep name and for the self-reference to the embedded lock.

### 4.2 Dynamic Initialization of a `seqlock_t`

For a lock allocated at runtime, call `seqlock_init`:

```c
#include <linux/slab.h>
#include <linux/seqlock.h>

static seqlock_t *dyn_lock;

static int __init init_dynamic_lock(void)
{
    dyn_lock = kzalloc(sizeof(*dyn_lock), GFP_KERNEL);
    if (!dyn_lock)
        return -ENOMEM;

    seqlock_init(dyn_lock);
    return 0;
}
```

The macro is defined in [include/linux/seqlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/seqlock.h#L812-L820):

```c
#define seqlock_init(sl)                                            \
    do {                                                            \
        spin_lock_init(&(sl)->lock);                                \
        seqcount_spinlock_init(&(sl)->seqcount, &(sl)->lock);       \
    } while (0)
```

The order is deliberate. The association stores a pointer to the embedded spinlock, and every later writer-side assertion dereferences that lock. Initializing the lock first ensures that the seqcount never points at an uninitialized lock class, even if a buggy path uses the counter before initialization has finished. `seqlock_init()` is the pattern to copy.

A dynamically allocated `seqlock_t` must remain at the same address for its entire lifetime. Do not `krealloc` it, copy it, or free it while a writer holds it or while any task may be spinning on it. Readers do not hold a reference to the lock, so freeing the lock while a reader is inside its read section is also a use-after-free — the reader may still load the sequence word. Lifetime rules are discussed in §12.7.

### 4.3 Initializing a `seqcount_t`

A plain sequence counter has two initializers, one static and one dynamic:

```c
/* Static */
static seqcount_t foo_seqcount = SEQCNT_ZERO(foo_seqcount);

/* Dynamic */
seqcount_t bar_seqcount;
seqcount_init(&bar_seqcount);
```

`SEQCNT_ZERO` is defined in [include/linux/seqlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/seqlock.h#L84-L88):

```c
#define SEQCNT_ZERO(name) { .sequence = 0, SEQCOUNT_DEP_MAP_INIT(name) }
```

With lockdep enabled, `seqcount_init` is a macro that creates a static `lock_class_key` and calls `__seqcount_init` with the call site's identity. Without lockdep it reduces to `__seqcount_init(s, NULL, NULL)`. See [include/linux/seqlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/seqlock.h#L42-L65). The static key is what lets lockdep distinguish two dynamically initialized sequence counters created at different source locations while treating two instances created at the same location as the same **lock class**.

The C99 form used inside a structure is:

```c
struct my_data {
    seqcount_t seq;
    int value;
};

static struct my_data foo = {
    .seq = SEQCNT_ZERO(foo.seq),
};
```

### 4.4 Initializing an Associated Sequence Counter

For an associated counter, use the matching macro. For example, the `jiffies` sequence counter is a `seqcount_raw_spinlock_t` associated with the global `jiffies_lock`:

```c
__cacheline_aligned_in_smp DEFINE_RAW_SPINLOCK(jiffies_lock);
__cacheline_aligned_in_smp seqcount_raw_spinlock_t jiffies_seq =
    SEQCNT_RAW_SPINLOCK_ZERO(jiffies_seq, &jiffies_lock);
```

from [kernel/time/jiffies.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/time/jiffies.c#L42-L44). The dynamic form is:

```c
seqcount_raw_spinlock_t seq;
seqcount_raw_spinlock_init(&seq, &my_raw_lock);
```

The generic initializer is defined in [include/linux/seqlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/seqlock.h#L124-L134):

```c
#define seqcount_LOCKNAME_init(s, _lock, lockname)          \
    do {                                                    \
        seqcount_##lockname##_t *____s = (s);               \
        seqcount_init(&____s->seqcount);                    \
        __SEQ_LOCK(____s->lock = (_lock));                  \
    } while (0)

#define seqcount_raw_spinlock_init(s, lock) seqcount_LOCKNAME_init(s, lock, raw_spinlock)
#define seqcount_spinlock_init(s, lock)     seqcount_LOCKNAME_init(s, lock, spinlock)
#define seqcount_rwlock_init(s, lock)       seqcount_LOCKNAME_init(s, lock, rwlock)
#define seqcount_mutex_init(s, lock)        seqcount_LOCKNAME_init(s, lock, mutex)
```

When `CONFIG_LOCKDEP` and `CONFIG_PREEMPT_RT` are both off, the `__SEQ_LOCK(...)` assignment disappears and the initializer is just `seqcount_init()`. The source code is identical; the storage and the lockdep assertions appear only when the configuration needs them.

### 4.5 What Initialization Actually Does

For a `seqlock_t`, initialization does three things:

1. **Zeroes the sequence counter.** Sequence zero is even, which means "no writer inside."
2. **Initializes the embedded spinlock** to the architecture's unlocked state.
3. **Registers the lock class with lockdep**, if `CONFIG_DEBUG_LOCK_ALLOC` is enabled. For a `seqlock_t`, this includes both the spinlock's dep map and the sequence counter's dep map.

The sequence counter itself has no magic value and no owner. The only corruption check available is lockdep's class tracking and, for the embedded spinlock, `CONFIG_DEBUG_SPINLOCK`'s magic and owner fields. A wild write that corrupts `sequence` will not be caught by the seqlock code; it will simply make readers retry forever or, worse, accept an inconsistent value if the corruption happens to restore an even number. This is one reason the primitive is used on small, well-contained data rather than on large structures with many writers.

Never initialize a `seqlock_t` with `memset()` or a bare compound literal:

```c
/* Wrong: lockdep state and the seqcount-to-lock association are not set up. */
memset(&my_lock, 0, sizeof(my_lock));

/* Also wrong: bypasses the initializer macros and any lockdep registration. */
my_lock = (seqlock_t){ };
```

Use `DEFINE_SEQLOCK`, `__SEQLOCK_UNLOCKED`, or `seqlock_init`. The same rule applies to reinitialization: do not call `seqlock_init` on a lock that is held or that has readers inside it.

---

## 5. The Writer Side

### 5.1 `write_seqlock()` and `write_sequnlock()`

The public writer API is small. The implementation is in [include/linux/seqlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/seqlock.h#L864-L896):

```c
static inline void write_seqlock(seqlock_t *sl)
{
    spin_lock(&sl->lock);
    do_write_seqcount_begin(&sl->seqcount.seqcount);
}

static inline void write_sequnlock(seqlock_t *sl)
{
    do_write_seqcount_end(&sl->seqcount.seqcount);
    spin_unlock(&sl->lock);
}
```

The call chain is:

```text
write_seqlock(sl)
├── spin_lock(&sl->lock)                     serialize writers; preemption off
└── do_write_seqcount_begin(&sl->seqcount.seqcount)
    └── do_write_seqcount_begin_nested(s, 0)
        ├── seqcount_acquire(&dep_map, ...)   lockdep only
        └── do_raw_write_seqcount_begin(s)
            ├── s->sequence++                 even → odd
            └── smp_wmb()                     odd marker before data
```

`write_seqlock()` does **not** call the generic `write_seqcount_begin()`. It calls the internal `do_write_seqcount_begin()` directly. The comment at [include/linux/seqlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/seqlock.h#L858-L862) explains why: the generic helper would add a redundant `lockdep_assert_held()` check, because `spin_lock()` has already acquired the associated lock and established the context. This is a small but characteristic detail: the seqlock write path is written to avoid doing the same validation twice.

The writer's critical section is ordinary C code. The only requirements are that it must not sleep, must not call into code that can block, and must keep the section short enough that readers do not retry excessively. The writer is holding a spinlock on a non-RT kernel, so preemption is disabled for the duration.

A direct probe of the counter makes the transition concrete: zero after initialization, odd inside the writer, and even after unlock.

```c
#include <linux/module.h>
#include <linux/slab.h>
#include <linux/seqlock.h>

static int __init seq_probe_init(void)
{
    seqlock_t *sl;
    unsigned int seq_init, seq_write, seq_unlock;

    sl = kmalloc(sizeof(*sl), GFP_KERNEL);
    if (!sl)
        return -ENOMEM;

    seqlock_init(sl);
    seq_init = READ_ONCE(sl->seqcount.seqcount.sequence);

    write_seqlock(sl);
    seq_write = READ_ONCE(sl->seqcount.seqcount.sequence);
    write_sequnlock(sl);
    seq_unlock = READ_ONCE(sl->seqcount.seqcount.sequence);

    pr_info("sequence: init=%u write=%u unlock=%u\n",
            seq_init, seq_write, seq_unlock);

    kfree(sl);
    return 0;
}
```

### 5.2 The Sequence Protocol and Its Barriers

The raw writer helpers are the heart of the protocol. They are defined in [include/linux/seqlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/seqlock.h#L429-L455):

```c
static inline void do_raw_write_seqcount_begin(seqcount_t *s)
{
    kcsan_nestable_atomic_begin();
    s->sequence++;
    smp_wmb();
}

static inline void do_raw_write_seqcount_end(seqcount_t *s)
{
    smp_wmb();
    s->sequence++;
    kcsan_nestable_atomic_end();
}
```

Expanded, a writer performs:

```text
writer section
──────────────
sequence++   (1) odd marker
smp_wmb()    (2) odd visible before the data
data = ...   (3) protected data stores
smp_wmb()    (4) data visible before the final marker
sequence++   (5) even marker

readers:     retry while odd; accept only when both samples match
```

The two barriers serve different purposes, and neither is optional:

- **Barrier (2)** ensures that the odd marker becomes visible before any of the protected data stores. Without it, a CPU could make a data store visible while the sequence still reads even. A reader that sampled the even count before the writer started could then read that store, and if the writer's sequence stores had not yet propagated either, the reader's final check could also see the original even value and accept an inconsistent copy. The barrier closes that window: if new data is visible, the odd marker is visible too, so the reader will retry.
- **Barrier (4)** ensures that all protected data stores become visible before the final even marker. Without it, a reader could see the final even marker while some data stores were still pending, accept the copy, and read stale fields. The barrier guarantees that an even count observed at the end means the update is complete.

On AArch64, `smp_wmb()` is `dmb ishst`, a store-store barrier in the inner-shareable domain. See [arch/arm64/include/asm/barrier.h](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/barrier.h#L126-L128). The sequence increments themselves are plain `ldr`/`add`/`str` sequences, not atomic instructions. They are safe because the writer side is serialized: only one writer can be between `write_seqlock()` and `write_sequnlock()` at a time. Readers only load the word, and an aligned 32-bit load on AArch64 is single-copy atomic, so a reader never observes a torn sequence value.

The same protocol applies to `write_seqcount_begin()` and `write_seqcount_end()`, which add lockdep and preemption handling around these raw helpers.

### 5.3 `write_seqcount_begin()` and `write_seqcount_end()`

These are the generic forms for a `seqcount_*` that add lockdep and preemption handling around the raw sequence update:

```text
write_seqcount_begin(s)                 write_seqcount_end(s)
───────────────────────                 ─────────────────────
assert the required context              end the raw sequence
    │                                       │
    ├─ preemptible associated lock?         ├─ preemptible?
    │     yes → preempt_disable()           │     yes → preempt_enable()
    ▼                                       ▼
publish the odd marker                   publish the even marker
```

| Check | Plain `seqcount_t` | Associated variant |
|---|---|---|
| `seqprop_assert()` | preemption must already be disabled | associated lock must be held |
| `seqprop_preemptible()` | always false | true only for `seqcount_mutex_t` on non-RT; the helper disables preemption |
| Lockdep | asserts non-preemption | asserts the lock is held |

`do_write_seqcount_begin()` is the inner form and skips both checks. `seqlock_t` uses it after `spin_lock()` because the lock is already held and preemption is already off. `raw_write_seqcount_begin()` skips lockdep as well. The rule behind all of this: **the writer must not be preempted or interrupted by a reader on the same CPU**, otherwise the reader spins on an odd count that only the writer can clear. The helper can enforce "not preempted"; only the caller can enforce "not interrupted" by using `_bh`/`_irqsave`.

### 5.4 Raw, Nested, Barrier, and Invalidate Variants

The writer API has several variants for specialized situations.

| Operation | Lockdep / preemption handling | Use case |
|---|---|---|
| `write_seqcount_begin()` | Asserts context, disables preemption if the associated lock is preemptible | Normal seqcount writer that holds its serialization lock |
| `raw_write_seqcount_begin()` | Skips lockdep, still applies the associated-lock preemption rule | Hot path under an external lock (`dentry->d_seq`) |
| `write_seqcount_begin_nested()` | Same as `write_seqcount_begin()`, with a lockdep subclass | Distinguish nested lockdep classes |
| `raw_write_seqcount_barrier()` | Two increments with one `smp_wmb()` | Ordering between two groups of writes; no snapshot |
| `write_seqcount_invalidate()` | `smp_wmb()` then `sequence += 2` | Force in-progress readers to retry |

- **`raw_write_seqcount_begin/end()`** skip the lockdep acquisition but still disable preemption when the associated lock is a mutex on non-RT.
- **`write_seqcount_begin_nested()`** passes a lockdep subclass. It is not a recursive-write API.
- **`raw_write_seqcount_barrier()`** provides ordering, not a consistent snapshot. With `Y = true; barrier(); X = false;`, a reader that sees `X == false` must see `Y == true`. Used by hrtimer and the unix socket GC.
- **`write_seqcount_invalidate()`** keeps the count even but changes its value, so readers that started before the change fail their final check. Used by `__d_drop()` after unhashing a dentry.

### 5.5 Two Writers Arrive

With a `seqlock_t`, the second writer waits for the embedded spinlock. On non-RT it **spins** on the CPU; it does not sleep. It does not touch the sequence until the first writer has finished:

```text
time ─────────────────────────────────────────────────────────────────────►
CPU0 W1   [lock][seq 0→1][ data ][seq 1→2][unlock]
CPU1 W2            [ spin on lock .......... ][lock][seq 2→3][ data ][seq 3→4][unlock]
                   └──── W2 waits; it does not touch the sequence ────┘

reader A                   [begin=2][ copy ][retry=2 ✓ accept]
reader B                                      [begin=2][ copy ][retry=4 ✗ retry]
```

W2 cannot enter while the count is odd, so the parity history stays valid. Reader A accepts W1's snapshot in the gap before W2 begins; reader B overlaps W2 and retries.

A plain `seqcount_t` does not block the second writer. Without an external lock both writers increment the counter, the parity can become even while data is still changing, and readers can accept a torn copy. This is why the writer side must always be serialized. The associated-lock variants turn that requirement into a `lockdep_assert_held()` check.

### 5.6 Why the Unlock Order Matters

`write_sequnlock()` ends the sequence **before** releasing the spinlock:

```text
correct:  [ data ][ seq 1→2 ][ spin_unlock ]   even before the next writer enters
wrong:    [ data ][ spin_unlock ][ seq 1→2 ]   next writer may enter while still odd
```

If the lock were released first, another writer could acquire it before the count became even, and its first increment would make the count even while data was still being modified. **Finish the data and the sequence before releasing the writer lock.** The interrupt variants follow the same rule: `write_sequnlock_irqrestore()` makes the count even before restoring interrupts, otherwise a same-CPU interrupt reader could spin on an odd count that cannot be cleared.

### 5.7 Writer API at a Glance

| Call | What it excludes | Unlock |
|---|---|---|
| `write_seqlock()` | preemption (via spinlock) | `write_sequnlock()` |
| `write_seqlock_bh()` | softirqs + preemption | `write_sequnlock_bh()` |
| `write_seqlock_irq()` | local IRQs + preemption | `write_sequnlock_irq()` |
| `write_seqlock_irqsave()` | saves flags, local IRQs + preemption | `write_sequnlock_irqrestore()` |
| `write_seqcount_begin()` | asserts context; preemption off only for mutex association | `write_seqcount_end()` |
| `raw_write_seqcount_begin()` | same, without lockdep | `raw_write_seqcount_end()` |

Lockless readers have no `_irqsave` variant. The writer must exclude the contexts in which they run: `_bh` for softirq readers, `_irqsave` for hardirq readers.

---

## 6. The Reader Side

### 6.1 `read_seqbegin()` and `read_seqretry()`

The public reader API is two functions:

```text
read_seqbegin(sl)                         read_seqretry(sl, start)
─────────────────                         ────────────────────────
lockdep pseudo-access (if enabled)        load-load barrier (dmb ishld)
load sequence with acquire (ldar)         re-load the sequence
while (odd) cpu_relax()                   return "changed?"
return the even value
```

The normal pattern is:

```c
do {
    seq = read_seqbegin(&lock);
    snap = shared;              /* copy inside the section */
} while (read_seqretry(&lock, seq));
```

`read_seqbegin()` spins on an odd value (`cpu_relax()` is `yield`) until a writer finishes. `read_seqretry()` uses a load-load barrier plus a plain load, not a second `ldar`, because the ordering direction is opposite. The `start` value is odd only when `read_seqbegin_or_lock()` has selected the locking fallback (§11.2).

### 6.2 One Timeline: Accept, Retry, Stabilize

```text
case 1: no writer           case 2: writer overlaps          case 3: writer already in
──────────────────          ────────────────────────          ─────────────────────────
begin = 0                   begin = 0                         begin: sees 5 (odd)
copy data                   copy field A                      spin in cpu_relax()
                            W: 0→1, data, 1→2                 W: 5→6
retry = 0 ✓ accept          copy field B                      begin = 6
                            retry = 2 ✗ discard               copy data
                            begin = 2, copy                   retry = 6 ✓ accept
                            retry = 2 ✓ accept
```

- **Case 2** may produce a mixed old/new copy. It is discarded, never inspected.
- **Case 3** is **stabilization**: wait for the writer before copying, so the reader does not do work that is certain to fail.
- A writer that starts *after* the retry check cannot invalidate the private copy. Only copied values are safe; pointers into the shared data are not.

### 6.3 The Reader State Machine

```text
              ┌──────────────────────────────────────────┐
              ▼                                          │
      load the sequence                                  │
              │                                          │
        odd? ──yes──► cpu_relax() ──────────────────────┘
              │no            (stabilize; no copy yet)
              ▼
      copy the data
              │
              ▼
      sequence changed? ──yes──► discard and retry
              │no
              ▼
      use the private copy
```

There is no retry limit and no backoff beyond `cpu_relax()`. On `PREEMPT_RT`, the odd branch takes and releases the associated sleeping lock instead of spinning, then re-reads the sequence.

### 6.4 Raw and Non-Stabilizing Begins

| Operation | Stabilizes on odd | Lockdep coverage | Typical use |
|---|---|---|---|
| `read_seqcount_begin()` | Yes | Yes | Normal reader |
| `raw_read_seqcount_begin()` | Yes | No | Hot path with externally validated context |
| `raw_read_seqcount()` | No | No | Caller handles parity explicitly |
| `raw_seqcount_begin()` | No; masks the low bit so an active writer forces a retry | No | Optimistic hot path that expects success |
| `raw_seqcount_try_begin()` | No; returns `false` if odd | No | Elide the section entirely if a writer is active |

`raw_read_seqcount_begin()` is the same odd-sequence spin without the lockdep access. `raw_read_seqcount()` just loads the sequence, leaving parity to the caller. `raw_seqcount_begin()` returns `raw_read_seqcount(s) & ~1`: an odd value `5` becomes `4`, so the final retry compares the real odd counter against `4` and fails. It trades the stabilization spin for a guaranteed failed copy under contention. `dget_parent()` uses this and undoes its reference on the retry path.

### 6.5 The Copy-Out Rule

**Copy inside the section; use only the copy after validation.**

```c
/* correct */
do {
    seq = read_seqbegin(&state_lock);
    snap = state;
} while (read_seqretry(&state_lock, seq));
pr_info("temp=%u\n", snap.temperature);

/* wrong: p points into shared data and may tear or be freed */
seq = read_seqbegin(&state_lock);
p = &state;
read_seqretry(&state_lock, seq);
pr_info("temp=%u\n", p->temperature);
```

The retry check says the *copy* was consistent; it says nothing about the shared object after the check. Copy every field of the snapshot, including nested values, inside the loop.

### 6.6 What the Reader May Not Do

| Do not | Why |
|---|---|
| Follow an unprotected pointer | The writer may replace and free the object; a retry cannot undo a use-after-free |
| Perform irreversible side effects | Printing, global increments, publishing pointers happen again on retry |
| Take a lock a writer may need | Lock-order inversion with the writer |
| Sleep, wait for I/O, or call `copy_to_user()` | Stretches the section, may fault/sleep, and repeats on retry |
| Assume mutual exclusion with other readers | Readers never exclude each other |
| Assume the snapshot is current | It is consistent, not necessarily latest |

### 6.7 Reader Questions: Spin, Sleep, and Stale Values

- **Does a retrying reader spin or sleep?** It spins on the CPU (`cpu_relax()`/`yield`). It does not sleep or block. The only exception is `PREEMPT_RT`'s reader-help path, which may briefly sleep on the associated lock; and the reader can of course be preempted by the scheduler like any task.
- **What if a writer updates between my begin and end, and I end up using the new value?** That is expected. A seqlock gives a consistent snapshot of *some* instant, not the old value. If the writer crossed the read, the reader retries and gets the new version. The old value is gone unless the reader copied it earlier or the code keeps a history/double buffer.
- **Does a second writer spin or sleep?** With `seqlock_t` on non-RT it **spins** on the embedded spinlock; it never waits for readers. On `PREEMPT_RT`, `spinlock_t` is a sleeping lock, so it may sleep.
- **Is the summary correct?** Yes: a reader may spin in its retry loop; a writer may spin waiting for another writer; a writer never waits for a reader; a reader never acquires the lock.

---

## 7. A Complete `kthread` Example

### 7.1 The Module

The following module creates one writer thread and three reader threads. The writer periodically replaces a small sensor snapshot under `write_seqlock()`; the readers copy the snapshot under `read_seqbegin()`/`read_seqretry()` and print it only after the copy has been validated. All sleeping happens outside the lock.

```c
// SPDX-License-Identifier: GPL-2.0
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/kthread.h>
#include <linux/delay.h>
#include <linux/seqlock.h>

#define NR_READERS 3

struct sensor_state {
    u32 temperature;
    u32 humidity;
    u64 updates;
};

static struct sensor_state state;
static DEFINE_SEQLOCK(state_lock);
static struct task_struct *readers[NR_READERS];
static struct task_struct *writer;

static int writer_fn(void *data)
{
    u64 n = 0;

    while (!kthread_should_stop()) {
        struct sensor_state next = {
            .temperature = 20 + (u32)(n % 10),
            .humidity = 40 + (u32)(n % 20),
            .updates = ++n,
        };

        write_seqlock(&state_lock);
        state = next;                    /* short, non-sleeping update */
        write_sequnlock(&state_lock);

        msleep(100);                     /* sleep outside the lock */
    }

    return 0;
}

static int reader_fn(void *data)
{
    unsigned long id = (unsigned long)data;

    while (!kthread_should_stop()) {
        struct sensor_state snap;
        unsigned int seq;

        do {
            seq = read_seqbegin(&state_lock);
            snap = state;                /* copy inside the section */
        } while (read_seqretry(&state_lock, seq));

        pr_info("reader%lu: temp=%uC humidity=%u%% updates=%llu\n",
                id, snap.temperature, snap.humidity,
                (unsigned long long)snap.updates);

        msleep(250);                     /* sleep outside the section */
    }

    return 0;
}

static int __init seqlock_demo_init(void)
{
    int i;

    writer = kthread_run(writer_fn, NULL, "seq_writer");
    if (IS_ERR(writer))
        return PTR_ERR(writer);

    for (i = 0; i < NR_READERS; i++) {
        readers[i] = kthread_run(reader_fn, (void *)(unsigned long)i,
                                 "seq_reader%d", i);
        if (IS_ERR(readers[i])) {
            long ret = PTR_ERR(readers[i]);

            while (--i >= 0)
                kthread_stop(readers[i]);
            kthread_stop(writer);
            return ret;
        }
    }

    pr_info("seqlock demo loaded\n");
    return 0;
}

static void __exit seqlock_demo_exit(void)
{
    int i;

    for (i = 0; i < NR_READERS; i++)
        if (!IS_ERR_OR_NULL(readers[i]))
            kthread_stop(readers[i]);

    if (!IS_ERR_OR_NULL(writer))
        kthread_stop(writer);

    pr_info("seqlock demo unloaded\n");
}

module_init(seqlock_demo_init);
module_exit(seqlock_demo_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Minimal seqlock demonstration");
```

A few details are worth calling out because they are easy to get wrong in real code:

- `state = next;` is a structure assignment. The compiler may emit several loads and stores, and a reader may observe a mix. That is fine because the reader validates the sequence after copying.
- `pr_info()` is outside the retry loop. Printing inside the loop would be a side effect repeated on every retry, and `pr_info()` can take console locks.
- `msleep()` is outside both the write section and the read section. The writer's spinlock is not held while sleeping, and the reader's optimistic section is not stretched.
- The writer's update is a single assignment. If the update needed to allocate memory or take a mutex, it should do that before `write_seqlock()` and publish only the finished result.

### 7.2 One Timeline: Four Cases

```text
case      CPU0: writer                         CPU1: reader
──────    ──────────────────────────────       ────────────────────────────────
A clean   (idle)                            →  begin=4, copy, retry=4 ✓ accept
B overlap lock, 4→5, data, 5→6, unlock      →  begin=4, copy A, copy B
                                               retry=6 ✗ → begin=6, copy
                                               retry=6 ✓ accept
C active  lock, 6→7, data, 7→8, unlock      →  begin: sees 7 (odd), cpu_relax
                                               begin=6, copy, retry=6 ✓ accept
```

- **A** is the fast path: same even value at both ends.
- **B** copies a mixture; the failed retry discards it and the next attempt succeeds.
- **C** stabilizes before copying, so it never does work that is certain to fail.
- In every case the writer never waits for a reader. `read_seqbegin_or_lock()` (§11) bounds case B when writers are frequent.

### 7.3 What the Example Demonstrates

- The embedded spinlock serializes writers; a second writer would spin, not corrupt the sequence.
- The reader copies the whole structure inside the section and prints only after validation.
- Both critical sections are short and non-sleeping; `msleep()` stays outside.
- The data has no pointers, so lifetime management is not needed.

A `char *name` field would require RCU or a locking reader; a large array would make retries expensive and call for a different primitive (§12).

---

## 8. `seqcount_t` vs. `seqlock_t`

### 8.1 The Decision Matrix

The two types answer the same consistency question with different assumptions about writer serialization.

| Question | `seqcount_t` | `seqlock_t` |
|---|---|---|
| Does it embed a writer lock? | No | Yes, a `spinlock_t` |
| Must the caller serialize writers? | Yes, with an external lock | No; the embedded lock does it |
| Must the caller disable preemption? | Yes, for a plain `seqcount_t` | No; `spin_lock()` does it |
| Can the writer sleep? | Yes, if the external lock is a mutex, but the section itself must be non-preemptible | No on non-RT; the embedded spinlock is atomic |
| Lockdep validation | Only with an associated variant | Yes, through `seqcount_spinlock_t` |
| Size (non-debug, non-RT) | 4 bytes | 8 bytes |
| Typical use | You already hold a lock, or need a sleeping writer lock | Self-contained short writer section |
| Example | `jiffies_seq`, `tk_core.seq`, `dentry->d_seq` | `mount_lock`, `rename_lock`, `netdev_rename_lock` |

The decision rule is straightforward:

- If the writer already holds a lock that serializes it, use a `seqcount_t` or an associated `seqcount_LOCKNAME_t`. You avoid a second lock acquisition and a second cache-line touch.
- If the writer does not already hold such a lock, and the write section can run in atomic context, use a `seqlock_t`.
- If the writer needs to sleep (for example, it holds a mutex), use `seqcount_mutex_t` and keep the actual sequence update short and non-preemptible.

The same decision as a flow:

```text
                 ┌─────────────────────────────────────┐
                 │ Writer already holds a lock that    │
                 │ serializes every writer?            │
                 └───────────────┬─────────────────────┘
                          yes    │    no
                    ┌────────────┘    └─────────────┐
                    ▼                              ▼
       ┌────────────────────────┐      ┌────────────────────────────┐
       │ Associated seqcount    │      │ Can the writer sleep or    │
       │ matching that lock     │      │ block in the write path?   │
       └────────────────────────┘      └─────────────┬──────────────┘
                                              yes    │    no
                                         ┌───────────┘    └──────────┐
                                         ▼                        ▼
                             ┌──────────────────────┐  ┌──────────────────────┐
                             │ mutex-associated     │  │ seqlock_t            │
                             │ seqcount / locking   │  │ (embedded spinlock)  │
                             │ reader               │  └──────────────────────┘
                             └──────────────────────┘
```

The flowchart is about the writer's serialization and context rules. It does not replace the reader-side decision: if readers cannot retry or must retain pointers, a locking reader is required regardless of which writer-side type is chosen.

The associated variants are the modern default when an external lock exists. They cost nothing in a production build without lockdep or RT, and they give lockdep enough information to catch a missing lock. The `jiffies` code illustrates the point: it uses `seqcount_raw_spinlock_t` rather than `seqlock_t` because the tick code already holds `jiffies_lock`, and adding a second embedded spinlock would be redundant. See [kernel/time/jiffies.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/time/jiffies.c#L42-L44).

### 8.2 Associated Locks and Lockdep

An associated sequence counter stores a pointer to the writer serialization lock when lockdep or `PREEMPT_RT` needs it. The pointer lets the generic writer helper assert that the lock is held:

```c
static __always_inline void
__seqprop_##lockname##_assert(const seqcount_##lockname##_t *s)
{
    __SEQ_LOCK(lockdep_assert_held(s->lock));
}
```

from [include/linux/seqlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/seqlock.h#L190-L194). For a plain `seqcount_t`, the equivalent assertion is `lockdep_assert_preemption_disabled()`:

```c
static inline void __seqprop_assert(const seqcount_t *s)
{
    lockdep_assert_preemption_disabled();
}
```

from [include/linux/seqlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/seqlock.h#L220-L223). The two assertions capture the two ways a writer can violate the protocol: not holding the serialization lock, or not being non-preemptible.

The association also affects `PREEMPT_RT`, but in a different way. There, the pointer is used not only for assertions but also for the reader-help path. That is the subject of the next subsection.

### 8.3 Why `seqlock_t` Uses `seqcount_spinlock_t`

A `seqlock_t` could have used a plain `seqcount_t` plus a `spinlock_t`, and on a non-RT kernel that is effectively what it is. The reason it uses `seqcount_spinlock_t` is stated in the type definition: to make sure readers do not starve writers on `PREEMPT_RT`. See [include/linux/seqlock_types.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/seqlock_types.h#L84-L92).

On `PREEMPT_RT`, a `spinlock_t` is a sleeping lock. A writer that holds the embedded spinlock can be preempted. If a high-priority reader then runs on the same CPU, sees the odd sequence, and spins waiting for it to become even, the writer may never get the CPU back. That is a livelock, not a deadlock, but it is just as fatal.

The associated-lock read path avoids it. When the reader sees an odd sequence and the associated lock is preemptible, it briefly acquires and releases the lock:

```c
static __always_inline unsigned
__seqprop_##lockname##_sequence(const seqcount_##lockname##_t *s)
{
    unsigned seq = smp_load_acquire(&s->seqcount.sequence);

    if (!IS_ENABLED(CONFIG_PREEMPT_RT))
        return seq;

    if (preemptible && unlikely(seq & 1)) {
        __SEQ_LOCK(lockbase##_lock(s->lock));
        __SEQ_LOCK(lockbase##_unlock(s->lock));

        /*
         * Re-read the sequence counter since the (possibly
         * preempted) writer made progress.
         */
        seq = smp_load_acquire(&s->seqcount.sequence);
    }

    return seq;
}
```

from [include/linux/seqlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/seqlock.h#L158-L178). Acquiring the lock waits for the writer to release it, which means the writer must have made progress. The reader then re-reads the sequence and proceeds. The reader may sleep while waiting, but that is acceptable on RT because it is not holding a raw spinlock or running in atomic context.

The writer side mirrors this. On RT, `__seqprop_preemptible()` returns `false` for the associated spinlock variant, so `write_seqcount_begin()` does not call `preempt_disable()`. The RT spinlock's own semantics handle the context. See [include/linux/seqlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/seqlock.h#L180-L188).

The practical consequence is that on RT, a seqlock reader is not purely lockless in the contended case. It remains lockless in the common case, but when it observes an in-progress writer it may take the associated sleeping lock briefly.

The reader-help sequence is the whole RT liveness argument in one picture:

```text
Writer (holds the associated rt-mutex)        Reader (higher priority)
──────────────────────────────────────        ────────────────────────
spin_lock(); seq 0 → 1
(updates data)
    ... preempted ...
                                              read_seqbegin(): sees 1 (odd)
                                              takes the associated lock
                                              └─ blocks; writer can run
writer resumes
seq 1 → 2
spin_unlock()
                                              lock acquired, released at once
                                              re-reads seq = 2 (even)
                                              copies data and validates

Plain seqcount_t, same scenario:

Writer: seq 0 → 1, preempted                  Reader: sees 1, spins in cpu_relax()
        cannot run to make it even            cannot return until it is even
        ─────────────────────► livelock ◄─────────────────────
```

The associated lock is not held across the reader's copy. It is used only as a "wait for the writer to make progress" primitive, then released before the sequence is re-read. That is why the reader can remain preemptible on RT without reintroducing writer starvation. That is still much cheaper than an `rwlock_t` reader taking the lock for the entire section, and it preserves the no-writer-starvation property.

### 8.4 Choosing a Writer Serialization Mechanism

The associated-lock variants let the writer choose the locking mechanism that fits its context. The following table summarizes the trade-offs.

| Writer lock | Associated type | Writer context | `seqprop_preemptible()` on non-RT | on `PREEMPT_RT` | Notes |
|---|---|---|---|---|---|
| `raw_spinlock_t` | `seqcount_raw_spinlock_t` | Atomic, including hardirq | `false` | `false` | Remains a real spinlock on RT; best for low-level timer paths |
| `spinlock_t` | `seqcount_spinlock_t` | Atomic on non-RT; may sleep on RT | `false` | `false` | The default for `seqlock_t`; RT uses reader-help, not `preempt_disable()` |
| `rwlock_t` | `seqcount_rwlock_t` | Atomic on non-RT; may sleep on RT | `false` | `false` | Rare; useful when the writer already holds the write side of an rwlock |
| `struct mutex` | `seqcount_mutex_t` | Process context; may sleep | `true` | `false` | Helper disables preemption on non-RT; RT uses reader-help |

The key distinction is between the **lock hold time** and the **sequence update time**. A mutex writer can hold the mutex across a long operation, but the sequence section itself must still be short. On non-RT, `seqprop_preemptible()` is true for the mutex-associated variant, so the helper disables preemption for that short section. On RT it returns false for every associated variant: disabling preemption would defeat the purpose of the sleeping lock, and the reader-help path takes the associated lock if it sees an odd count. The sequence counter protects the data; it does not extend the mutex's sleep into the sequence update.

---

## 9. Preemption, Interrupts, and Context

### 9.1 Readers Are Preemptible

A sequence reader never calls `preempt_disable()`. It can be preempted, migrated, or interrupted between any two instructions. That is deliberate: if a reader spun on an odd count with preemption disabled, it could prevent the writer on the same CPU from ever making the count even. Keeping readers preemptible guarantees writer progress; reader progress is best-effort.

A read section is therefore not a spinlock critical section. `might_sleep()` inside it will not warn on a non-RT kernel, because the preemption count is unchanged. The only IRQ control in the read path is inside `seqcount_lockdep_reader_access()`, which wraps lockdep's pseudo-acquire/release in `local_irq_save()` merely to keep the bookkeeping pair atomic; the real read remains preemptible.

### 9.2 Writers Are Not

The writer must not be preempted or interrupted by a reader on the same CPU. `seqlock_t` gets this from its embedded spinlock; a plain `seqcount_t` caller must hold a spinlock or call `preempt_disable()`. `write_seqcount_begin()` disables preemption itself only for an associated preemptible lock (`seqcount_mutex_t` on non-RT). On `PREEMPT_RT` it relies on the reader-help path instead.

If the writer is preempted by a same-CPU reader, the reader spins on the odd count while the writer cannot run to clear it: a livelock.

### 9.3 The Same-CPU Deadlock

```text
CPU0: writer (process context, IRQs on)        CPU0: hardirq
──────────────────────────────────────         ─────────────
write_seqlock(): seq 0→1
data update in progress ................       irq_handler:
                                                 read_seqbegin() sees 1 (odd)
                                                 spins in cpu_relax()
writer cannot resume until IRQ returns         IRQ cannot return until seq is even
                 └────────────► deadlock ◄────────────┘
```

Three fixes:

1. **Writer disables the interrupting context.** `_bh` if readers can run in softirq; `_irqsave` if readers can run in hardirq.
2. **Locking readers use the matching context variant.** `read_seqlock_excl_bh()` or `_irqsave()`, exactly like a spinlock.
3. **NMI readers use the latch.** NMI cannot be masked, so a plain seqlock reader in NMI is always unsafe (§9.7).

With `write_seqlock_irqsave()`, the handler cannot run in the middle:

```text
without _irqsave                              with _irqsave
─────────────────                             ────────────
writer: seq 0→1                               writer: irq save, seq 0→1
IRQ fires: reader sees 1, spins               data, seq 1→2
IRQ cannot return                             irq restore
writer cannot resume                          IRQ runs now: reader sees 2 ✓
        └──────────► deadlock
```

A **lockless** reader needs no `_irqsave` form because it takes no lock; the writer must exclude its context. A **locking** reader does need the usual spinlock variants.

### 9.4 What `_irqsave` Saves on AArch64

`local_irq_save(flags)` reads the current **DAIF** register, masks IRQ and FIQ (`msr daifset, #3`), and saves the full value; restore writes it back. With pseudo-NMI support it uses the GIC priority mask (`ICC_PMR_EL1`) instead. Either way, `flags` captures the exact prior state, so `write_sequnlock_irqrestore()` restores what was there rather than blindly enabling interrupts — important when seqlocks nest inside other IRQ-disabled regions. IRQ state is restored only after the sequence is even and the spinlock is released (§5.6).

### 9.5 IRQ and Bottom-Half Variants

The writer variants mirror spinlock suffixes; the unlock always ends the sequence first:

| Operation | Context protection | Unlock |
|---|---|---|
| `write_seqlock()` | preemption via embedded spinlock | `write_sequnlock()` |
| `write_seqlock_bh()` | softirqs + preemption | `write_sequnlock_bh()` |
| `write_seqlock_irq()` | local IRQs + preemption | `write_sequnlock_irq()` |
| `write_seqlock_irqsave()` | saves IRQ state, disables IRQs | `write_sequnlock_irqrestore()` |

A lockless reader has no `read_seqbegin_irqsave()`: it takes no lock, so the writer must exclude the contexts in which it runs. Only **locking** readers have context variants: `read_seqlock_excl_bh()`, `read_seqlock_excl_irq()`, `read_seqlock_excl_irqsave()`, and the fallback `read_seqbegin_or_lock_irqsave()`.

Rule: **the writer disables the contexts in which lockless readers may run; a reader disables contexts only when it is going to take the lock.**

### 9.6 The Locking Reader

A locking reader takes the embedded spinlock instead of using the retry protocol: `read_seqlock_excl()` / `read_sequnlock_excl()`. It does not update the sequence. It excludes writers and other locking readers, but not lockless readers, which never take the lock.

Use it when the reader cannot retry or must take references. `fs_struct` is the canonical case: `get_fs_root()` copies `fs->root` and calls `path_get()` while holding the lock, so the pointers cannot change between the copy and the reference. The writer (`set_fs_root()`) does the `path_get()`/`path_put()` work outside the write section, keeping it short. Context rules are the same as a spinlock: a locking reader that can interrupt a writer needs `_bh` or `_irqsave`.

### 9.7 NMI and `seqcount_latch_t`

NMI can interrupt a writer at any instruction and cannot be masked, so a plain `read_seqbegin()` in NMI would spin forever. The latch keeps **two copies** and uses the sequence parity to select the stable one:

```text
writer                                      NMI reader
──────────────────────────────────────      ──────────────────────────
latch_begin: counter even→odd               counter = read_latch() → odd
             readers must use copy 1        index = counter & 1 = 1
modify copy 0                               read copy 1 (stable)
latch: counter odd→even                     retry: counter unchanged ✓
       readers must use copy 0
modify copy 1
latch_end: leaves the counter even
```

The reader accepts while the sequence is odd because the writer is modifying the *other* copy. If the parity flips during the read, the final check retries. The cost is double storage; the benefit is a bounded NMI read. Used by `tk_fast` in the timekeeper.

### 9.8 `PREEMPT_RT`

- `spinlock_t` becomes a sleeping rt-mutex, so a `seqlock_t` writer can be preempted.
- A reader that sees an odd sequence takes the associated lock briefly, which lets the writer run, then re-reads. The reader may sleep there.
- `seqlock_t` writers may sleep, so they must not be called from hardirq.
- `seqcount_raw_spinlock_t` stays a real spinlock; use it for low-level paths such as `jiffies_seq`.
- A plain `seqcount_t` has no associated lock, so the reader-help path cannot work; use an associated variant when the writer lock can sleep.

### 9.9 Context Selection Matrix

The writer API is chosen by the **reader contexts it must exclude**, not by the writer's own context:

```text
reader context       writer call                 why
────────────────     ───────────────────────     ─────────────────────────
process              write_seqlock()             preemption is enough
softirq              write_seqlock_bh()          block softirq readers
hardirq              write_seqlock_irqsave()     block hardirq readers
NMI                  seqcount_latch_t            a plain seqlock would spin
```

| Lockless readers may run in | Writer API | Reader API |
|---|---|---|
| Process only | `write_seqlock()` | `read_seqbegin()` / `read_seqretry()` |
| Process + softirq | `write_seqlock_bh()` | `read_seqbegin()` / `read_seqretry()` |
| Process + softirq + hardirq | `write_seqlock_irqsave()` | `read_seqbegin()` / `read_seqretry()` |
| NMI | plain seqlock unsupported | `seqcount_latch_t` |

| Locking reader context | Reader API | Writer requirement |
|---|---|---|
| Process | `read_seqlock_excl()` | `write_seqlock()` if no higher-context reader exists |
| Softirq | `read_seqlock_excl_bh()` | writer must exclude softirq on the same CPU |
| Hardirq | `read_seqlock_excl_irqsave()` | writer must exclude hardirq on the same CPU |

---

## 10. Memory Ordering on AArch64

### 10.1 What Must Be Ordered

A seqlock has four ordering requirements:

| # | Requirement | Owner |
|---|---|---|
| 1 | Odd marker visible before data stores | writer |
| 2 | Data stores visible before final even marker | writer |
| 3 | Data loads not reordered before the initial sequence load | reader |
| 4 | Data loads not reordered after the final sequence load | reader |

On AArch64 none of these happen for free. On x86 the strong memory model hides many of them, which is why seqlock bugs often appear first on Arm.

### 10.2 The Instructions

| Kernel primitive | AArch64 | Meaning |
|---|---|---|
| `smp_load_acquire()` | `ldar` | later accesses stay after the load |
| `smp_store_release()` | `stlr` | earlier accesses stay before the store |
| `smp_rmb()` | `dmb ishld` | load-load barrier, inner-shareable |
| `smp_wmb()` | `dmb ishst` | store-store barrier, inner-shareable |
| `smp_mb()` | `dmb ish` | full barrier, inner-shareable |
| `cpu_relax()` | `yield` | spin hint, not a memory barrier |
| `READ_ONCE()` / `WRITE_ONCE()` | `ldr` / `str` | single-copy-atomic, compiler ordering |

The seqlock uses `ldar` for the initial sequence load, `dmb ishld` for the final check, and `dmb ishst` around the writer's increments. It deliberately avoids the full `dmb ish`. `stlr` is not used for the increments: the first increment needs a store-store barrier *after* the store, which release semantics cannot provide.

### 10.3 The Writer's Barriers

```text
writer timeline
───────────────
sequence++      (1) odd marker
   │
smp_wmb()       (2) odd visible before data
   │
data = ...      (3) protected stores
   │
smp_wmb()       (4) data visible before the even marker
   │
sequence++      (5) even marker
```

- (2) orders the odd marker before the data stores: a CPU that sees new data must also see the odd marker.
- (4) orders the data stores before the final even marker: a CPU that sees the even marker must also see all data.

The writer needs no full `dmb ish` because only stores must be ordered against stores. The increments are plain `ldr`/`add`/`str`, safe because only one writer is inside. `dmb ishst` also acts as a compiler barrier via its `"memory"` clobber.

### 10.4 The Reader's Barriers

```text
reader timeline
───────────────
ldar sequence   (1) acquire: later loads stay after it
   │
data loads      (2) plain loads
   │
dmb ishld       (3) prior loads stay before the final load
   │
ldr sequence    (4) compare with the start value
```

- (1) prevents data loads from being reordered *before* the sequence sample.
- (3) prevents data loads from being reordered *after* the final sequence load.

Acquire and load-load are needed in opposite directions. That is why the final check is `smp_rmb()` plus a plain `READ_ONCE`, not a second `ldar`: an acquire orders later accesses, but the reader must order prior data loads before the final load. The initial `ldar` is cheaper than a plain load plus `dmb ishld`.

### 10.5 Why the Writer Barriers Matter

Both barriers are necessary; the final comparison alone cannot catch everything. These panels show **visibility order**, not program order:

```text
missing barrier (2)                       missing barrier (4)
────────────────────                      ────────────────────
data = NEW becomes visible first          data store still pending
                                          seq 1→2 (even) visible early

reader: seq=0, data=NEW, seq=0            reader: seq=2, data=OLD, seq=2
        accept ✗ (mixed old/new)                  accept ✗ (stale data)
```

Without (2), the reader sees new data with an unchanged even sequence. Without (4), it sees the even marker before the data and accepts stale values. Together the barriers make the sequence a faithful summary: odd means "update in progress", even at the end means "update complete".

### 10.6 Compiler Ordering and `READ_ONCE`

The compiler can also reorder, split, merge, or cache accesses. The `smp_*` primitives are inline assembly with a `"memory"` clobber, so they are full compiler barriers. Inside the section, `READ_ONCE()` and `WRITE_ONCE()` prevent tearing, merging, inventing, and register-caching, and document that the access is intentionally racy:

```c
do {
    seq = read_seqbegin(&lock);
    temp = READ_ONCE(state.temperature);
    humidity = READ_ONCE(state.humidity);
} while (read_seqretry(&lock, seq));
```

A structure assignment such as `snap = state;` is fine because the retry check covers the whole copy, but the copy must be complete before the retry and must not be optimized into a pointer to shared data.

---

## 11. Livelock, Retry Storms, and the Locking Reader

### 11.1 Reader Starvation

A seqlock cannot starve a writer, but continuous writers can starve a reader: every attempt overlaps a write and is discarded. The fix is the **conditional locking reader** — try lockless, then take the embedded lock on failure so writers are excluded.

### 11.2 `read_seqbegin_or_lock()`

```c
static inline void read_seqbegin_or_lock(seqlock_t *lock, int *seq)
{
    if (!(*seq & 1))        /* even: lockless */
        *seq = read_seqbegin(lock);
    else                    /* odd: locking */
        read_seqlock_excl(lock);
}
```

`seq` is overloaded: an even value (start at `0`) means "lockless pass and here is the sequence"; an odd value means "this pass owns the embedded lock". On a failed retry the caller sets `seq = 1` and restarts. The VFS `d_path` walk uses exactly this, with `mount_lock` and `rename_lock`, because retrying a recursive path walk forever under a rename storm would livelock. The lockless pass holds `rcu_read_lock()` for dentry lifetime; the locking pass does not need it because the rename lock keeps the parent chain stable.

### 11.3 `need_seqretry()` and `done_seqretry()`

```c
static inline int need_seqretry(seqlock_t *lock, int seq)
{
    return !(seq & 1) && read_seqretry(lock, seq);
}

static inline void done_seqretry(seqlock_t *lock, int seq)
{
    if (seq & 1)
        read_sequnlock_excl(lock);
}
```

```text
seq is even ──► lockless value           seq is odd ──► "I own the lock"
      │                                        │
      ▼                                        ▼
read_seqbegin()                          read_seqlock_excl()
      │                                        │
need_seqretry()? ──true──► seq = 1 ────────────┘
      │false                                   │
      ▼                                        ▼
done_seqretry(): no-op                   done_seqretry(): unlock
```

`need_seqretry()` checks the sequence only when `seq` is even. When odd, the writer was excluded, so it returns `false` without touching the sequence. `done_seqretry()` releases the lock only when `seq` is odd. Always call it after `need_seqretry()` returns `false`, including after a successful lockless pass. Do not invent odd markers or call `read_seqretry()` directly on one.

### 11.4 The IRQ-Safe Variant

If the locking fallback can interrupt a writer, use the IRQ-safe pair:

```c
flags = read_seqbegin_or_lock_irqsave(&sig->stats_lock, &seq);
...
done_seqretry_irqrestore(&sig->stats_lock, seq, flags);
```

`flags` is meaningful only in the locking case; the lockless pass disables nothing and leaves it zero. Interrupts are disabled only when the reader actually takes the embedded lock. Used by `sig->stats_lock` in `kernel/sys.c`.

### 11.5 `scoped_seqlock_read()`

The scoped form hides the retry loop and the fallback:

```c
scoped_seqlock_read (&sig->stats_lock, ss_lock_irqsave) {
    cmin_flt = sig->cmin_flt;
    ...
}
```

Modes: `ss_lockless` (retry optimistically), `ss_lock`, `ss_lock_irqsave`. The body is re-executed on retry, which makes "copy inside the loop" structurally obvious. Lock-guard wrappers (`DEFINE_LOCK_GUARD_0`) exist for the locking writer/reader forms.

### 11.6 When to Fall Back to Locking

Use the fallback when the read is expensive, the reader has a latency bound, the writer rate makes the optimistic path likely to fail, or the reader must take references. Do **not** use it for a short hot-path read: the retry is cheaper than blocking writers.

---

## 12. Limitations and Sharp Edges

### 12.1 Pointers and Object Lifetime

The real rule: **a lockless reader must not follow a pointer whose lifetime is not protected.** The seqlock protects the consistency of the pointer *value*, not the object it points to. The writer can replace the pointer and free the old object; a retry cannot undo a use-after-free.

| Safe pattern | Mechanism | Example |
|---|---|---|
| RCU | `rcu_read_lock()` + `rcu_dereference()`; free with `kfree_rcu()` | VFS path walk |
| Reference count | take a ref inside the loop, undo it on retry | `dget_parent()` |
| Locking reader | exclude writers while taking the reference | `fs_struct` |

```text
Does the protected data contain a pointer?
├── no  → copy the scalar snapshot; the seqlock is enough
└── yes → how is the object's lifetime protected?
          ├── RCU: traverse safely, free after a grace period
          ├── reference count: take it inside the loop, undo on retry
          └── locking reader: hold the embedded lock while taking it
```

If none of these fits, a seqlock is the wrong primitive. "The sequence check passed" is a consistency statement, never a lifetime statement.

### 12.2 Side Effects

A lockless reader is a **read-only retry loop**. A side effect is repeated on every retry:

```c
/* wrong: increments once per retry */
do {
    seq = read_seqbegin(&lock);
    atomic_inc(&global_counter);
    value = state.value;
} while (read_seqretry(&lock, seq));
```

A side effect is acceptable only if it is **undoable**. `dget_parent()` takes a reference inside the loop and calls `dput()` if the retry fails. The rule is not "no side effects", it is "no irreversible side effects, and none visible to others before validation". `printk()`, `copy_to_user()`, and global list insertion all fail that test.

### 12.3 Large or Complex Data

A seqlock fits a small, self-contained snapshot, not a large structure. The reader copies everything on every attempt, so cost grows with size; the writer invalidates every line it touches; and the retry probability grows with the section length. Invariants spanning multiple objects need one writer section covering all of them. The timekeeper is the counterexample that proves the rule: `struct timekeeper` is large, but the hot fields are laid out to fit in a single cache line, so the reader's working set stays small. For genuinely large data, use a locking reader, `rwlock_t`, or RCU.

### 12.4 Counter Wrap and ABA

The sequence is a 32-bit `unsigned`, so it wraps after `2^32` increments. If it wraps completely while a reader is inside its section, the end value can equal the start value and the reader accepts torn data — classic **ABA**. At a million updates per second that takes about 35 minutes; the window is theoretical, not practical, but it exists. Keep read sections short, do not rely on a seqlock to detect every update over long periods, and use RCU or a lock where ABA is semantically dangerous. The counter has no checksum, so a corrupted word producing matching even values also yields a false accept.

### 12.5 Writer Serialization

A `seqcount_t` does not serialize writers. Two unsynchronized writers can lose a sequence update and can leave the count even while data is still being modified. The associated variants assert the external lock is held; a plain counter asserts only that preemption is disabled, which is necessary but not sufficient. A `seqlock_t` embeds the writer lock, which is the main reason to prefer it when the writer does not already hold one.

### 12.6 Long Readers and Cache Pressure

A long read section does not block the writer, but it raises the retry probability, wastes more work per retry, and creates coherence traffic proportional to the number of active readers. `cpu_relax()` only reduces power/SMT pressure; it does not shorten the wait. Avoid **false sharing**: if the sequence word shares a line with unrelated hot data, each side invalidates the other. The VFS aligns its global seqlocks; the timekeeper aligns the whole `tk_data`. Measure rather than assume.

### 12.7 Lifetime of the Lock Itself

A lockless reader holds no reference to the lock or the protected object. Freeing either while a reader is inside is a use-after-free the seqlock cannot detect. Static `DEFINE_SEQLOCK` instances are safe by construction; dynamically allocated ones must outlive every possible reader and writer. Never free or reinitialize a live seqlock, and never copy one — its embedded lock state, RT wait queue, and lockdep state are address-sensitive. The same lifetime rules apply to the protected data.

### 12.8 Nesting and Reentrancy

Lockless readers nest freely: no lock, no counter, no ownership. Locking readers cannot nest on the same `seqlock_t` because `read_seqlock_excl()` takes the embedded spinlock. A lockless reader inside a locking reader is fine; the reverse can block on a writer, but the outer reader simply retries. Writers cannot nest on the same `seqlock_t`, and a writer invoked inside a locking read section deadlocks. A writer inside a lockless read is not recursion but is almost always a design error. `write_seqcount_begin_nested()` is a lockdep subclass tool, not a recursive-write API.

### 12.9 What a Seqlock Does Not Provide

A seqlock provides no mutual exclusion, no object lifetime management, no priority inheritance, no fairness, no bounded reader latency, no multi-object atomicity, no ordering for non-memory accesses, no stable view after the read section, and no protection against a corrupted sequence word. Most seqlock bugs come from assuming one of these guarantees exists.

### 12.10 Sharp Edges at a Glance

| Sharp edge | What goes wrong | Mitigation |
|---|---|---|
| Unprotected pointer | Writer frees the object; reader follows a stale pointer | RCU, reference count, or locking reader (§12.1) |
| Retried side effect | `printk()`, `copy_to_user()`, or list insertion happens twice | Only undoable side effects inside the loop (§12.2) |
| Large data | Repeated copies, cache invalidation, high retry rate | Keep the hot working set small; use `rwlock_t`/RCU (§12.3) |
| 32-bit wrap (ABA) | Delayed reader accepts torn data | Short sections; use another primitive if ABA matters (§12.4) |
| Unsynchronized writers | Lost sequence update, wrong parity | External lock or `seqlock_t` (§12.5) |
| Long read section | Retry storms, wasted work, coherence traffic | Locking reader or different primitive (§12.6) |
| False sharing | Unrelated hot lines invalidate each other | Align or co-locate the sequence line (§12.6) |
| Lock/data freed | Use-after-free on the sequence or data | Static lifetime, RCU, or a reference count (§12.7) |
| Nested locking reader/writer | Deadlock on the embedded spinlock | No recursion; restructure the code (§12.8) |
| NMI reader | Spins forever on an odd sequence | `seqcount_latch_t` or an NMI-safe mechanism (§9.7) |
| Writer preempted by its reader | Reader spins or livelocks on the same CPU | Disable preemption; hold the writer lock (§9.2) |
| Missing context disable | Reader interrupts a writer in softirq/hardirq | `_bh` / `_irqsave` writer variants (§9.5) |
| Unlock before sequence end | Another writer enters and corrupts the history | Always call `write_seqcount_end()` first (§5.6) |
| Wrong `seq` marker | Locking fallback is never released | Use `need_seqretry()`/`done_seqretry()` (§11.3) |
| Corrupted sequence word | False accept | No checksum exists; protect integrity elsewhere (§12.4) |

---

## 13. Real-World Users on AArch64

### 13.1 The Tick Counter

The tick counter is the classic example, but on AArch64 it no longer needs a sequence read. On 32-bit systems a 64-bit value is loaded in two halves, so a reader can see one half from before an update and one half from after. The tick code therefore updates the counter under a lock and a sequence counter, and readers retry until both halves agree. On a 64-bit machine, including AArch64, the same read is a single aligned load that cannot tear. The sequence counter remains for other tick state, but the fast path is just a load. The lesson is that this is a solution to 32-bit atomicity, not an AArch64 requirement.

### 13.2 The Timekeeper

The timekeeper publishes a large collection of time-related fields that many contexts read while the tick and clock-adjustment code update them. Writers prepare a complete new copy in a shadow structure and then publish it under a sequence counter, so a reader sees either the old state or the new state, never a mixture. The sequence also orders the kernel's update against the vDSO's update, which prevents time from appearing to move backwards. Readers copy the seconds and derive nanoseconds inside the retry loop. The structure is large, but the fields on the hot path are grouped together and fit in a few cache lines.

### 13.3 The NMI-Safe Clock

Some clock readers run in NMI or tracing context, where spinning is unacceptable. Those readers use a latch: two complete copies of the clock data, with a counter that tells the reader which copy is stable. The writer updates one copy, flips the latch, updates the other, and flips back. A reader chooses a copy from the counter and retries only if the latch moved while it was reading. The worst case is a timestamp that is briefly stale, never a lockup.

### 13.4 Mount and Rename Detection

Path walking in the virtual filesystem is lockless for most of its work. Two global sequence counters detect when a mount or a rename changes the tree while a walk is in progress. The walk holds an RCU read-side section so that dentries and mounts cannot disappear, copies what it needs, and retries if either sequence changed. A smaller per-dentry counter detects changes to an individual dentry and is updated under that dentry's lock. The combination is deliberate: RCU provides lifetime, and the sequence provides a consistent view of the topology.

### 13.5 Filesystem Root and Working Directory

A process's root and working directory are stored as path pairs: a mount pointer and a dentry pointer. A lockless reader could copy the pointers but could not keep the objects alive. This code therefore uses a sequence lock with an exclusive reader: the reader takes the embedded lock while it copies the paths and takes references, so the pointers cannot change underneath it. Writers do the reference-count work outside the short write section. This is the clearest case where a reader must lock rather than retry.

### 13.6 Network, Namespace, and Memory Hotplug

The network stack uses a global sequence lock to copy a device name while a rename may be in progress; writers disable bottom halves because readers can run in softirq. The namespace tree uses a sequence lock with a locking reader because it walks pointers and needs a stable structure. The page allocator uses a sequence counter to detect a rebuild of its zonelist during memory hotplug; the state is small, reads are frequent, and updates are rare, which is exactly the right fit. The scheduler's per-signal CPU-time accounting uses a scoped reader that starts lockless and falls back to an interrupt-safe locking read when a writer interferes.

---

## 14. Performance and Scalability

### 14.1 The Reader Fast Path

A reader's uncontended path is two loads of the sequence word around ordinary data loads, with a load-load barrier before the second check:

```text
                 reader fast path (AArch64)
                 ──────────────────────────
        ┌──────────────────────────┐
        │ load sequence (acquire)  │  must be even
        └────────────┬─────────────┘
                     ▼
        ┌──────────────────────────┐
        │ load and copy the data   │  ordinary loads, no atomics
        └────────────┬─────────────┘
                     ▼
        ┌──────────────────────────┐
        │ load-load barrier        │  prior loads stay before the check
        └────────────┬─────────────┘
                     ▼
        ┌──────────────────────────┐
        │ re-load sequence         │──► changed? ──yes──► discard, retry
        └──────────────────────────┘
```

There is no atomic read-modify-write and no exclusive cache-line ownership: every reader can hold the sequence line shared. That is the scalability advantage over a reader-writer lock, whose readers must take exclusive ownership of the lock word on entry and exit. The seqlock reader still pays for the barrier and the second load, but those are local costs, not coherence traffic.

### 14.2 The Writer Cost

A writer takes the embedded lock, publishes an odd sequence, writes the data, publishes an even sequence, and releases the lock. It never waits for readers, so its instruction cost is largely independent of reader count. The cost that does grow is cache invalidation: every reader caching the sequence line must be told that it changed. Store-store barriers add a fixed cost, which is another reason to keep the write section short.

### 14.3 Cache Lines and NUMA

The sequence word is the seqlock's central cache line: every reader loads it and every writer stores it. On a NUMA system the line is replicated across nodes, and each write must invalidate all copies. That is one invalidation per write, not a lock acquisition per reader, so it scales better than a contended lock word, but it is not free.

Layout matters. Keep the sequence word close to the data it protects, as the timekeeper does, or give global sequence locks their own cache line, as the VFS does. Avoid placing a frequently written seqlock beside unrelated hot data: each side will invalidate the other's line.

### 14.4 Seqlock vs. RCU vs. `rwlock_t`

The three read-mostly primitives solve different problems:

| Property | `rwlock_t` | `seqlock_t` | RCU |
|---|---|---|---|
| Reader shared-memory writes | Atomic add/sub | None | None |
| Writer waits for readers | Yes | No | No, but waits for a grace period before freeing |
| Reader waits for writer | Yes | Only on an odd sequence at begin; otherwise retries | No |
| Reader retry | No | Yes | No |
| Pointer-based traversal | Safe under the lock | Unsafe unless lifetime is protected | Safe |
| Reader side effects | Allowed | Must be undoable | Allowed |
| Reader context | Atomic | Any except NMI for a plain seqlock | Any, including NMI with special variants |
| Writer context | Atomic | Atomic (non-RT) | Process context for a grace period; callback from non-NMI contexts |
| Consistency model | Mutual exclusion | Snapshot with retry | Per-object publication |
| Best fit | Read-mostly data with pointers and exclusion | Small scalar snapshots with rare updates | Pointer-based read-mostly structures |

The same choice as a block diagram:

```text
                    ┌─────────────────────────────────┐
                    │ Pointer-based and read-mostly?  │
                    └───────────────┬─────────────────┘
                         yes        │        no
                    ┌───────────────┘        └──────────────────┐
                    ▼                                           ▼
          ┌──────────────────┐                     ┌──────────────────────────────┐
          │       RCU        │                     │ Small scalar snapshot with   │
          │ traverse in place│                     │ rare, short updates?         │
          └──────────────────┘                     └──────────────┬───────────────┘
                                                   yes          │          no
                                            ┌────────────────────┘          └────────────────┐
                                            ▼                                              ▼
                                  ┌───────────────────┐                      ┌──────────────────────────────┐
                                  │    seqlock_t      │                      │ Must the reader hold data    │
                                  │ copy, check, retry│                      │ stable or take references?   │
                                  └───────────────────┘                      └──────────────┬───────────────┘
                                                                                  yes        │        no
                                                                           ┌─────────────────┘        └──────────────┐
                                                                           ▼                                         ▼
                                                              ┌──────────────────────────┐             ┌──────────────────────────┐
                                                              │ locking reader, rwlock_t │             │ Write rate high or read  │
                                                              │ or mutex                 │             │ section long?            │
                                                              └──────────────────────────┘             └────────────┬─────────────┘
                                                                                                         yes        │        no
                                                                                                          ▼                  ▼
                                                                                             ┌──────────────────┐  ┌──────────────────┐
                                                                                             │ lock or another  │  │ seqlock may fit; │
                                                                                             │ primitive        │  │ measure retries  │
                                                                                             └──────────────────┘  └──────────────────┘
```

The seqlock's niche is narrow but important: small, hot, read-mostly data where the reader can copy and retry, and where the writer must never wait. Timekeeping, tick counters, mount and rename generations, and per-object dentry state are all in that niche.

### 14.5 When Not to Use a Seqlock

A seqlock is the wrong tool when:

- **Writes are frequent.** Every write invalidates readers and forces retries; a lock may be cheaper.
- **The data is large.** Copying and retrying wastes memory bandwidth; use a lock or RCU.
- **The data contains unprotected pointers.** Use RCU, a locking reader, or another primitive.
- **The reader has irreversible side effects.** A retry repeats them; use a lock.
- **The reader needs mutual exclusion or the latest value with no retry.** A seqlock provides neither.
- **The reader runs in NMI.** Use a latch or an NMI-safe mechanism.
- **The data has invariants across independent objects.** One sequence counter cannot make a multi-object update atomic unless all objects share the same writer and reader section.

---

## 15. Summary: Rules of Thumb

The following rules capture the practical essence of the primitive.

#### Use a seqlock when

- The data is small, self-contained, and read-mostly.
- Writers are rare and their critical sections are short.
- Readers can copy the data and retry.
- Readers must never block writers.
- The data contains no unprotected pointers.
- The reader does not need to hold a reference across a non-trivial operation.

#### Use a `seqcount_t` instead of a `seqlock_t` when

- The writer already holds a lock that serializes it.
- You want to avoid a second embedded spinlock and a second cache-line touch.
- You need to associate the counter with a specific lock for lockdep validation.
- The writer uses a mutex or rwlock and you want the RT reader-help behavior.

#### Writer rules

- Serialize writers. `seqlock_t` does it with its embedded spinlock; `seqcount_t` requires an external lock.
- Keep the writer non-preemptible. `seqlock_t` does it with the spinlock; plain `seqcount_t` requires explicit `preempt_disable()` or an external spinlock.
- Disable the contexts in which lockless readers can run. Use `_bh` for softirq readers, `_irqsave` for hardirq readers.
- End the sequence before releasing the writer lock.
- Keep the critical section short and free of sleeping operations.

#### Reader rules

- Copy the data inside the loop.
- Validate with `read_seqretry()` before using the copy.
- Do not use pointers into the shared data unless lifetime is protected by RCU or a reference count.
- Do not perform irreversible side effects.
- Do not sleep, block, or take locks that a writer might need.
- Do not use a plain seqlock in NMI; use `seqcount_latch_t`.
- Keep the read section short; use `read_seqbegin_or_lock()` or `scoped_seqlock_read()` when writers are frequent.

#### AArch64 rules

- The reader's initial load is `ldar`; the final check is `dmb ishld` plus a plain load. Do not replace the `dmb ishld` with an acquire load; the direction is wrong.
- The writer's barriers are `dmb ishst`; do not weaken them to compiler barriers.
- The sequence word is a plain 32-bit `unsigned`; its atomicity comes from single-copy-atomic aligned accesses and single-writer serialization, not from `atomic_t`.
- Align hot seqlocks and keep the sequence and hot data close, but avoid false sharing with unrelated hot data.

#### The one-sentence summary a seqlock trades the reader's guarantee of exclusion for the writer's guarantee of progress, and it works only when the reader can copy, validate, and retry.

---

## 16. References

### 16.1 Core Types and API

- [include/linux/seqlock_types.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/seqlock_types.h#L9-L92) — `seqcount_t`, `seqcount_LOCKNAME_t`, and `seqlock_t` definitions and design comments.
- [include/linux/seqlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/seqlock.h#L42-L88) — `seqcount_init()`, `SEQCNT_ZERO()`, and lockdep reader access.
- [include/linux/seqlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/seqlock.h#L124-L264) — associated-lock initializers and property dispatch.
- [include/linux/seqlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/seqlock.h#L266-L413) — read-side begin, retry, raw variants, and lockdep annotations.
- [include/linux/seqlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/seqlock.h#L421-L598) — write-side begin/end, raw variants, barrier, and invalidate.
- [include/linux/seqlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/seqlock.h#L806-L993) — `DEFINE_SEQLOCK()`, `seqlock_init()`, and writer IRQ/BH variants.
- [include/linux/seqlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/seqlock.h#L995-L1235) — locking readers, `read_seqbegin_or_lock()`, and IRQ-safe fallback.
- [include/linux/seqlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/seqlock.h#L1237-L1364) — `scoped_seqlock_read()` and lock-guard support.

### 16.2 Sequence Counter Implementation

- [include/linux/seqlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/seqlock.h#L158-L194) — `PREEMPT_RT` reader-help path and associated-lock assertions.
- [include/linux/seqlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/seqlock.h#L272-L413) — the even/odd read protocol and barrier placement.
- [include/linux/seqlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/seqlock.h#L429-L455) — the writer's `smp_wmb()` pair.
- [include/linux/seqlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/seqlock.h#L569-L598) — write barrier and invalidation semantics.
- [include/linux/seqlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/seqlock.h#L610-L804) — `seqcount_latch_t` and the two-copy protocol.

### 16.3 AArch64 Memory Ordering

- [arch/arm64/include/asm/barrier.h](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/barrier.h#L63-L65) — `__mb()`, `__rmb()`, `__wmb()`.
- [arch/arm64/include/asm/barrier.h](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/barrier.h#L107-L124) — `arch_counter_enforce_ordering()` and speculative system register reads.
- [arch/arm64/include/asm/barrier.h](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/barrier.h#L126-L194) — `smp_*` barriers, `ldar`, and `stlr`.
- [arch/arm64/include/asm/arch_timer.h](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/arch_timer.h#L170-L202) — counter reads with enforced ordering.
- [arch/arm64/include/asm/vdso/processor.h](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/vdso/processor.h#L10-L13) — `cpu_relax()` as `yield`.
- [arch/arm64/include/asm/irqflags.h](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/irqflags.h#L163-L197) — `local_irq_save()`/`restore()` and DAIF/PMR handling.

### 16.4 Timekeeping and `jiffies`

- [kernel/time/jiffies.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/time/jiffies.c#L42-L59) — `jiffies_seq`, `jiffies_lock`, and `get_jiffies_64()`.
- [kernel/time/tick-common.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/time/tick-common.c#L86-L103) — the tick writer's sequence section.
- [kernel/time/tick-common.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/time/tick-common.c#L160-L180) — `tick_next_period` read with the sequence counter.
- [kernel/time/tick-sched.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/time/tick-sched.c#L60-L88) — 64-bit fast path vs. 32-bit seqcount path.
- [include/linux/jiffies.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/jiffies.h#L70-L99) — 64-bit atomicity and `get_jiffies_64()` inline form.
- [kernel/time/timekeeping.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/time/timekeeping.c#L44-L58) — `struct tk_data` and the timekeeper sequence.
- [kernel/time/timekeeping.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/time/timekeeping.c#L816-L867) — writer update under the sequence counter.
- [kernel/time/timekeeping.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/time/timekeeping.c#L971-L989) — `ktime_get_real_ts64()` reader.
- [kernel/time/timekeeping.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/time/timekeeping.c#L500-L534) — NMI-safe latch timekeeper.

### 16.5 VFS and Other Users

- [fs/dcache.c](https://github.com/torvalds/linux/blob/v7.3-rc7/fs/dcache.c#L85) — global `rename_lock`.
- [fs/dcache.c](https://github.com/torvalds/linux/blob/v7.3-rc7/fs/dcache.c#L361-L388) — dentry name snapshot with reference-count undo.
- [fs/dcache.c](https://github.com/torvalds/linux/blob/v7.3-rc7/fs/dcache.c#L1100-L1116) — `dget_parent()` optimistic read.
- [include/linux/dcache.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/dcache.h#L96) — per-dentry `d_seq`.
- [fs/namespace.c](https://github.com/torvalds/linux/blob/v7.3-rc7/fs/namespace.c#L129) — global `mount_lock`.
- [fs/namespace.c](https://github.com/torvalds/linux/blob/v7.3-rc7/fs/namespace.c#L775-L868) — mount lookup and legitimization.
- [fs/d_path.c](https://github.com/torvalds/linux/blob/v7.3-rc7/fs/d_path.c#L156-L197) — `read_seqbegin_or_lock()` in the path walk.
- [include/linux/fs_struct.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/fs_struct.h#L11-L42) — `fs_struct` and locking readers.
- [fs/fs_struct.c](https://github.com/torvalds/linux/blob/v7.3-rc7/fs/fs_struct.c#L17-L46) — writer-side path updates.
- [net/core/dev.c](https://github.com/torvalds/linux/blob/v7.3-rc7/net/core/dev.c#L1198-L1208) — `netdev_rename_lock` reader.
- [kernel/nstree.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/nstree.c#L11-L19) — namespace tree lock guards.
- [mm/page_alloc.c](https://github.com/torvalds/linux/blob/v7.3-rc7/mm/page_alloc.c#L4415-L4428) — zonelist update sequence.
- [include/linux/sched/signal.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/sched/signal.h#L189) — `stats_lock`.
- [kernel/sched/cputime.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/sched/cputime.c#L346-L358) — scoped IRQ-safe read.

### 16.6 Documentation and Comparisons

- [Documentation/locking/seqlock.rst](https://github.com/torvalds/linux/blob/v7.3-rc7/Documentation/locking/seqlock.rst#L10-L36) — the definition of sequence counters and the consistency rule.
- [Documentation/locking/seqlock.rst](https://github.com/torvalds/linux/blob/v7.3-rc7/Documentation/locking/seqlock.rst#L41-L141) — `seqcount_t` and associated-lock usage patterns.
- [Documentation/locking/seqlock.rst](https://github.com/torvalds/linux/blob/v7.3-rc7/Documentation/locking/seqlock.rst#L146-L236) — latch counters and `seqlock_t` reader categories.
- [Documentation/locking/locktypes.rst](https://github.com/torvalds/linux/blob/v7.3-rc7/Documentation/locking/locktypes.rst#L46-L74) — lock types and `PREEMPT_RT` semantics.
- [Documentation/locking/lockdep-design.rst](https://github.com/torvalds/linux/blob/v7.3-rc7/Documentation/locking/lockdep-design.rst#L9-L28) — lockdep class and dependency model.
- [include/linux/rwlock_types.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/rwlock_types.h#L25-L35) — `rwlock_t` layout for comparison.
- [include/asm-generic/qrwlock_types.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/asm-generic/qrwlock_types.h#L13-L32) — `qrwlock` layout for comparison.
- [include/asm-generic/qrwlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/asm-generic/qrwlock.h#L24-L123) — `qrwlock` reader/writer fast paths for comparison.
- [arch/arm64/Kconfig](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/Kconfig#L69-L70) — AArch64 selects queued rwlocks and spinlocks.
- [kernel/Kconfig.locks](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/Kconfig.locks#L269-L274) — `QUEUED_RWLOCKS` configuration.
