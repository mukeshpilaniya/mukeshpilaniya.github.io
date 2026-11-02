---
title: Reader-Writer Semaphores in the Linux Kernel
published: true
categories: [Synchronization]
tags: [rwsem, rw_semaphore, sleeping-lock, percpu-rwsem]
mermaid: true
---
# Reader-Writer Semaphores in the Linux Kernel

A **reader-writer semaphore** is a sleeping lock with two acquisition modes: any number of readers may hold it at once, while a writer requires exclusive access. Linux calls this primitive `rw_semaphore`. It exists for the same reason reader-writer spinlocks exist — read-mostly data should not serialize readers against one another — but it solves a different problem: the reader critical section may block. A reader may take a page fault, copy to user memory, allocate with `GFP_KERNEL`, wait for I/O, or call filesystem code. None of that is legal under `rwlock_t`, which disables preemption and spins. `rw_semaphore` instead puts a conflicting task to sleep, lets the scheduler run something else, and wakes it when the lock becomes available.

That sleeping behavior changes almost every design decision. The lock word is a 64-bit atomic count rather than a 32-bit queued-lock word. Waiters live on their kernel stacks and are linked through a list protected by an internal `raw_spinlock_t`. Writers may perform **optimistic spinning** before they sleep, using an MCS-style optimistic spin queue. Readers may perform **optimistic lock stealing**, but only within bounds intended to keep writers from starving. The non-RT implementation is deliberately fair: a waiting writer is not forgotten, and a stream of readers cannot permanently postpone it. On AArch64, the generic implementation is used, with 64-bit atomics that lower either to Armv8.1 **LSE** instructions or to `LDAXR`/`STLXR` loops, and with a queued spinlock protecting the slow paths.

This document examines `rw_semaphore` on AArch64 in detail: the data structure and count encoding, initialization, every public acquisition and release path, the internal sleep and wake machinery, fairness and handoff, optimistic spinning, memory ordering, recursion and upgrade rules, context restrictions, `percpu_rw_semaphore`, real kernel users, debugging, and performance trade-offs. The scope is the non-`PREEMPT_RT` SMP kernel, which is where the implementation described here is used. `PREEMPT_RT` is discussed only as a contrast because it replaces the lock with an `rt_mutex`-based implementation.

Throughout the document, the word **reader** means a task holding the lock in shared mode, **writer** means a task holding it in exclusive mode, and **owner** means the task recorded in the writer-side owner field. The owner field is not a complete ownership record for readers; it is a hint used by debugging and optimistic spinning. The source references are pinned to Linux `v7.3-rc7`.

**Diagram conventions.** Timelines run from top to bottom. Side-by-side columns represent concurrent CPUs or tasks, not a strict wall-clock ordering. `R` and `W` mean reader and writer; `CS` means critical section; count values are hexadecimal snapshots. A dashed arrow is an optional or contended path.

---

## Table of Contents

1. [Why Sleeping Reader-Writer Locks Exist](#1-why-sleeping-reader-writer-locks-exist)
   - 1.1 [The Limits of a Mutex](#11-the-limits-of-a-mutex)
   - 1.2 [Shared/Exclusive Locking That Can Sleep](#12-sharedexclusive-locking-that-can-sleep)
   - 1.3 [How It Differs from a Plain Semaphore](#13-how-it-differs-from-a-plain-semaphore)
   - 1.4 [When Not to Use It](#14-when-not-to-use-it)
2. [The `rw_semaphore` Type on AArch64](#2-the-rw_semaphore-type-on-aarch64)
   - 2.1 [Source Layout and Type Hierarchy](#21-source-layout-and-type-hierarchy)
   - 2.2 [The Non-RT Structure](#22-the-non-rt-structure)
   - 2.3 [The Count Word](#23-the-count-word)
   - 2.4 [Important Count States](#24-important-count-states)
   - 2.5 [Size, Cache Lines, and the Owner Hint](#25-size-cache-lines-and-the-owner-hint)
   - 2.6 [The Waiter Structure](#26-the-waiter-structure)
3. [Initialization](#3-initialization)
   - 3.1 [Static Initialization](#31-static-initialization)
   - 3.2 [Dynamic Initialization](#32-dynamic-initialization)
   - 3.3 [What Initialization Actually Does](#33-what-initialization-actually-does)
   - 3.4 [Static Versus Dynamic](#34-static-versus-dynamic)
4. [Core API and Count Transitions](#4-core-api-and-count-transitions)
   - 4.1 [Readers: `down_read()` and `up_read()`](#41-readers-down_read-and-up_read)
   - 4.2 [Writers: `down_write()` and `up_write()`](#42-writers-down_write-and-up_write)
   - 4.3 [Trylock Variants](#43-trylock-variants)
   - 4.4 [Interruptible and Killable Variants](#44-interruptible-and-killable-variants)
   - 4.5 [Nested and Non-Owner Interfaces](#45-nested-and-non-owner-interfaces)
   - 4.6 [Complete API Table](#46-complete-api-table)
   - 4.7 [Count Transition Table](#47-count-transition-table)
   - 4.8 [State Checks and lockdep Assertions](#48-state-checks-and-lockdep-assertions)
5. [A Complete Thread Example](#5-a-complete-thread-example)
   - 5.1 [The Module](#51-the-module)
   - 5.2 [What the Output Demonstrates](#52-what-the-output-demonstrates)
6. [Internal Implementation](#6-internal-implementation)
   - 6.1 [Fast Path and Slow Path](#61-fast-path-and-slow-path)
   - 6.2 [Reader Fast Path](#62-reader-fast-path)
   - 6.3 [Reader Slow Path](#63-reader-slow-path)
   - 6.4 [Writer Fast Path](#64-writer-fast-path)
   - 6.5 [Writer Slow Path and Queuing](#65-writer-slow-path-and-queuing)
   - 6.6 [Waking Waiters](#66-waking-waiters)
   - 6.7 [Unlock and Downgrade](#67-unlock-and-downgrade)
   - 6.8 [The State Machine](#68-the-state-machine)
   - 6.9 [A Complete Contention Walkthrough](#69-a-complete-contention-walkthrough)
7. [Fairness and Starvation](#7-fairness-and-starvation)
   - 7.1 [Phase-Fair Behavior](#71-phase-fair-behavior)
   - 7.2 [The Waiters Bit](#72-the-waiters-bit)
   - 7.3 [The Handoff Bit](#73-the-handoff-bit)
   - 7.4 [Preventing Writer Starvation](#74-preventing-writer-starvation)
   - 7.5 [What Happens When a Writer Is Waiting and a New Reader Arrives](#75-what-happens-when-a-writer-is-waiting-and-a-new-reader-arrives)
   - 7.6 [Preventing Reader Starvation](#76-preventing-reader-starvation)
   - 7.7 [Where Fairness Is Deliberately Relaxed](#77-where-fairness-is-deliberately-relaxed)
8. [Optimistic Spinning](#8-optimistic-spinning)
   - 8.1 [Does `rw_semaphore` Spin Like a Mutex?](#81-does-rw_semaphore-spin-like-a-mutex)
   - 8.2 [The Optimistic Spin Queue](#82-the-optimistic-spin-queue)
   - 8.3 [Writer Spinning on the Owner](#83-writer-spinning-on-the-owner)
   - 8.4 [Reader-Owned Locks and the Spin Threshold](#84-reader-owned-locks-and-the-spin-threshold)
   - 8.5 [Reader Lock Stealing](#85-reader-lock-stealing)
   - 8.6 [Real-Time Tasks and Disabled Spinning](#86-real-time-tasks-and-disabled-spinning)
9. [Memory Ordering on AArch64](#9-memory-ordering-on-aarch64)
   - 9.1 [The Acquire/Release Contract](#91-the-acquirerelease-contract)
   - 9.2 [Atomics: LSE Versus Load-Exclusive/Store-Exclusive](#92-atomics-lse-versus-load-exclusivestore-exclusive)
   - 9.3 [Barriers and Instructions](#93-barriers-and-instructions)
   - 9.4 [The Wait Lock and Queued Spinlock](#94-the-wait-lock-and-queued-spinlock)
   - 9.5 [WFE, SEV, and `yield`](#95-wfe-sev-and-yield)
   - 9.6 [Ordering of the Owner Hint](#96-ordering-of-the-owner-hint)
10. [Recursion, Upgrade, and Downgrade](#10-recursion-upgrade-and-downgrade)
   - 10.1 [Recursive Read Acquisition](#101-recursive-read-acquisition)
   - 10.2 [Recursive Write Acquisition](#102-recursive-write-acquisition)
   - 10.3 [Read-to-Write Upgrade Deadlocks](#103-read-to-write-upgrade-deadlocks)
   - 10.4 [`downgrade_write()`](#104-downgrade_write)
   - 10.5 [Lockdep and Nested Subclasses](#105-lockdep-and-nested-subclasses)
11. [Context and Sleeping Rules](#11-context-and-sleeping-rules)
   - 11.1 [Process Context Only](#111-process-context-only)
   - 11.2 [Sleeping While Holding the Lock](#112-sleeping-while-holding-the-lock)
   - 11.3 [Spinlocks, Interrupts, and Preemption](#113-spinlocks-interrupts-and-preemption)
   - 11.4 [Signals, Killable Waits, and Timeouts](#114-signals-killable-waits-and-timeouts)
   - 11.5 [Ownership and Lifetime](#115-ownership-and-lifetime)
12. [`percpu_rw_semaphore`](#12-percpu_rw_semaphore)
   - 12.1 [Why a Per-CPU Reader Count Exists](#121-why-a-per-cpu-reader-count-exists)
   - 12.2 [The Structure](#122-the-structure)
   - 12.3 [The Read Fast Path](#123-the-read-fast-path)
   - 12.4 [The Write Slow Path](#124-the-write-slow-path)
   - 12.5 [Memory Ordering and RCU Synchronization](#125-memory-ordering-and-rcu-synchronization)
   - 12.6 [When to Use It](#126-when-to-use-it)
   - 12.7 [Real Users](#127-real-users)
13. [Real-World Users on AArch64](#13-real-world-users-on-aarch64)
   - 13.1 [`mmap_lock`](#131-mmap_lock)
   - 13.2 [Inode `i_rwsem`](#132-inode-i_rwsem)
   - 13.3 [Superblock `s_umount`](#133-superblock-s_umount)
   - 13.4 [Per-CPU Reader-Writer Semaphores in Practice](#134-per-cpu-reader-writer-semaphores-in-practice)
14. [Choosing the Right Primitive](#14-choosing-the-right-primitive)
   - 14.1 [Comparison Table](#141-comparison-table)
   - 14.2 [Selection Flow](#142-selection-flow)
   - 14.3 [RCU, Seqlocks, and Per-VMA Locks](#143-rcu-seqlocks-and-per-vma-locks)
15. [Debugging and Observability](#15-debugging-and-observability)
   - 15.1 [`CONFIG_DEBUG_RWSEMS`](#151-config_debug_rwsems)
   - 15.2 [Lockdep](#152-lockdep)
   - 15.3 [Atomic-Sleep and Hung-Task Diagnostics](#153-atomic-sleep-and-hung-task-diagnostics)
   - 15.4 [Tracepoints and Performance Counters](#154-tracepoints-and-performance-counters)
16. [Performance and Scalability](#16-performance-and-scalability)
   - 16.1 [The Reader Cache Line](#161-the-reader-cache-line)
   - 16.2 [Writer Latency and Handoff](#162-writer-latency-and-handoff)
   - 16.3 [Wakeup Batching](#163-wakeup-batching)
   - 16.4 [Alternatives at Scale](#164-alternatives-at-scale)
17. [`PREEMPT_RT` Contrast](#17-preempt_rt-contrast)
18. [Important Points](#18-important-points)
19. [References](#19-references)
   - 19.1 [Core Type and API](#191-core-type-and-api)
   - 19.2 [Generic Implementation](#192-generic-implementation)
   - 19.3 [AArch64 Atomics and Barriers](#193-aarch64-atomics-and-barriers)
   - 19.4 [Optimistic Spin Queue](#194-optimistic-spin-queue)
   - 19.5 [Per-CPU Reader-Writer Semaphores](#195-per-cpu-reader-writer-semaphores)
   - 19.6 [Documentation and Real Users](#196-documentation-and-real-users)

---

## 1. Why Sleeping Reader-Writer Locks Exist

### 1.1 The Limits of a Mutex

A mutex is an exclusive sleeping lock. It is simple to reason about: one owner, one critical section, and waiters that sleep. If a data structure is read by many tasks and modified by only a few, however, a mutex serializes the readers unnecessarily. Two page-fault paths that only need to walk the same VMA tree, or two directory lookups that only need to read the same inode, do not conflict with each other. Making them wait for one another converts a shared workload into a queue.

A reader-writer spinlock fixes that for short, non-blocking critical sections. It keeps a reader count in an atomic word, lets readers enter together, and makes writers wait until the last reader leaves. The price is that readers cannot sleep, cannot take page faults, and cannot call code that might block. The lock is also held with preemption disabled, so a reader that runs long enough can delay every task on that CPU.

### 1.2 Shared/Exclusive Locking That Can Sleep

`rw_semaphore` keeps the shared/exclusive model but gives up the spinning rule. A reader that cannot enter because a writer owns the lock is put to sleep. A writer that cannot enter because readers own the lock is also put to sleep, after it has had a chance to spin optimistically. Because the lock is a sleeping lock, a reader may hold it across a page fault or an I/O wait, and a writer may hold it across an operation that blocks. That is the defining trade-off: much heavier acquisition and wakeup machinery in exchange for a critical section that behaves like ordinary process context.

The public contract is deliberately close to a mutex. `down_read()` acquires shared access; `up_read()` releases it. `down_write()` acquires exclusive access; `up_write()` releases it. A task that cannot acquire the lock sleeps in `TASK_UNINTERRUPTIBLE` state unless it uses an interruptible or killable variant. The internal state is more complicated than a mutex because a reader count, a writer bit, a waiter list, a handoff mechanism, and an optimistic spin queue all have to agree with one another.

### 1.3 How It Differs from a Plain Semaphore

A plain `struct semaphore` has one integer count. A value of one is the classic **binary semaphore**; a value greater than one is a counting semaphore. `rw_semaphore` is not a `struct semaphore`, and it is not a binary semaphore with a special reader trick. Its count word encodes two different things at once: a single writer bit and a reader population count. The unlocked value is zero, not one. `down_read()` adds a reader bias; `down_write()` sets the writer bit. The writer side is exclusive, so it behaves like a binary lock from the writer's point of view. The primitive as a whole is not binary because the reader side is explicitly counting.

This distinction matters when reading older material that calls a reader-writer semaphore a "binary semaphore shared by readers." That description is misleading. There is no single semaphore count being handed from reader to reader. There is a reader count that can be greater than one, a separate writer bit, and a wait queue whose ordering rules are not those of a counting semaphore.

### 1.4 When Not to Use It

`rw_semaphore` is a poor fit when writers are frequent. Every writer excludes every reader, and the wakeup path is much more expensive than a mutex fast path. It is also a poor fit for tiny read-side critical sections: the reader fast path performs an atomic read-modify-write on a shared cache line, so a hot reader lock can bounce that line between CPUs. A plain mutex, a per-CPU counter, RCU, or a seqlock may be better.

It is not usable from hard interrupt context. It is not a replacement for `rwlock_t` in code that cannot sleep. On the non-RT implementation described here it does not support priority inheritance; a low-priority reader can delay a high-priority writer. (The `PREEMPT_RT` implementation is different; see [PREEMPT_RT Contrast](#17-preempt_rt-contrast).) It does not allow a read-to-write upgrade. And it should not be used for pointer-traversal workloads that RCU handles without any reader-side atomic operation at all.

The rest of this document explains how the non-RT implementation works and where those rules come from.

---

## 2. The `rw_semaphore` Type on AArch64

### 2.1 Source Layout and Type Hierarchy

The public type and API live in [`include/linux/rwsem.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/rwsem.h#L48-L67). The generic implementation lives in [`kernel/locking/rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwsem.c#L1-L60). AArch64 does not provide a separate architecture-specific `rw_semaphore` implementation. It uses the generic C code and supplies the pieces that matter to that code:

- 64-bit atomic operations on `atomic_long_t`, implemented with LSE instructions when the CPU supports them and with load-exclusive/store-exclusive loops otherwise.
- A queued spinlock for the internal `wait_lock`, because AArch64 selects `ARCH_USE_QUEUED_SPINLOCKS`.
- Optimistic spinning, because AArch64 selects `ARCH_SUPPORTS_ATOMIC_RMW`, which makes `RWSEM_SPIN_ON_OWNER` default to enabled on SMP.
- The usual acquire/release barriers: `DMB ISH`, `LDAR`, `STLR`, and the RCpc/RCsc rules that the atomic helpers expect.

The relevant architecture selections are visible in [`arch/arm64/Kconfig`](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/Kconfig#L66-L80): `ARCH_USE_QUEUED_RWLOCKS`, `ARCH_USE_QUEUED_SPINLOCKS`, and `ARCH_SUPPORTS_ATOMIC_RMW`. The Kconfig rule that turns the last one into `RWSEM_SPIN_ON_OWNER` is in [`kernel/Kconfig.locks`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/Kconfig.locks#L224-L237).

On a 64-bit kernel, `atomic_long_t` is `atomic64_t`; on a 32-bit kernel it is `atomic_t`. AArch64 is 64-bit, so the count is a 64-bit word. See [`include/linux/atomic/atomic-long.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/atomic/atomic-long.h#L9-L22).

```
source hierarchy
================

  include/linux/rwsem.h
       |
       +-- struct rw_semaphore
       +-- DECLARE_RWSEM(), init_rwsem()
       +-- down_read(), down_write(), up_read(), up_write(), ...
       |
       v
  kernel/locking/rwsem.c
       |
       +-- !CONFIG_PREEMPT_RT
       |     +-- count/owner encoding, fast and slow paths
       |     +-- wake, handoff, optimistic spinning
       |     +--> kernel/locking/osq_lock.c
       |            (CONFIG_RWSEM_SPIN_ON_OWNER)
       |
       +-- CONFIG_PREEMPT_RT
             +-- includes kernel/locking/rwbase_rt.c
             +--> kernel/locking/rtmutex.c

  include/linux/percpu-rwsem.h
       |
       +-- struct percpu_rw_semaphore ------------------+
                                                       |
                                                       v
                                         kernel/locking/percpu-rwsem.c
                                             (separate type and API)
```

The RT branch is selected inside `rwsem.c`, which includes `rwbase_rt.c`; it is not a helper called by the non-RT code. The per-CPU type is also separate: it has its own header and implementation, not a mode bit inside `rw_semaphore`.

There is no `arch/arm64/kernel/rwsem.c` and no AArch64-private copy of the algorithm. The architecture contributes atomics, barriers, the queued spinlock, and the `cpu_relax()` instruction; the lock semantics are generic.

### 2.2 The Non-RT Structure

The non-RT definition is guarded by `#ifndef CONFIG_PREEMPT_RT` and is declared with the kernel's `context_lock_struct()` helper (see [`include/linux/rwsem.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/rwsem.h#L48-L67)). In a normal build the helper expands to an ordinary `struct rw_semaphore`; in a context-analysis build it adds static lock-context annotations. The fields are:

```c
context_lock_struct(rw_semaphore) {
    atomic_long_t count;
    /*
     * Write owner or one of the read owners as well flags regarding
     * the current state of the rwsem. Can be used as a speculative
     * check to see if the write owner is running on the cpu.
     */
    atomic_long_t owner;
#ifdef CONFIG_RWSEM_SPIN_ON_OWNER
    struct optimistic_spin_queue osq; /* spinner MCS lock */
#endif
    raw_spinlock_t wait_lock;
    struct rwsem_waiter *first_waiter __guarded_by(&wait_lock);
#ifdef CONFIG_DEBUG_RWSEMS
    void *magic;
#endif
#ifdef CONFIG_DEBUG_LOCK_ALLOC
    struct lockdep_map dep_map;
#endif
};
```

The `__guarded_by(&wait_lock)` annotation is compile-time documentation: `first_waiter` is protected by `wait_lock`. It does not replace the runtime locking. The source orders `owner` after `count` and places them next to each other on purpose. The comment above the structure explains why: in the uncontended case, a task touches only `count` and `owner`, so packing them together increases the chance that they share a cache line. A contended lock touches the wait lock and the waiter list as well, but the fast path should not.

The fields have distinct jobs:

- **`count`** is the lock state. It contains the writer bit, the reader count, and several flag bits. All lock acquisition and release decisions are made from this word.
- **`owner`** records the current writer, or a reader that recently held the lock, with a special reader-owned bit. It is used by debugging and by optimistic spinning. It is not a reference count and it is not a complete list of readers.
- **`osq`** is the optimistic spin queue. It serializes writer spinners on per-CPU MCS nodes so they do not all hammer the owner cache line. It exists only when `CONFIG_RWSEM_SPIN_ON_OWNER` is enabled.
- **`wait_lock`** is a raw spinlock that protects the waiter list and the slow-path count manipulations. It is held only briefly and never across a sleep.
- **`first_waiter`** points to the first `rwsem_waiter` in the queue. Waiters are linked through their own `list_head`; the list is not allocated from a slab.
- **`magic`** is a debug cookie under `CONFIG_DEBUG_RWSEMS`.
- **`dep_map`** is the lockdep map under `CONFIG_DEBUG_LOCK_ALLOC`; its wait type is `LD_WAIT_SLEEP`.

```
uncontended fast path touches only:

   +----------------------+----------------------+
   |        count         |        owner         |
   +----------------------+----------------------+
   | writer | flags | rcnt | task pointer | flags |
   +----------------------+----------------------+
             ^                      ^
             |                      |
       atomic acquire/release   speculative hint
       (correctness)            (spinning/debug)
```

### 2.3 The Count Word

The count layout and the flag definitions are in [`kernel/locking/rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwsem.c#L82-L129); `RWSEM_UNLOCKED_VALUE` is defined alongside the public type in [`include/linux/rwsem.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/rwsem.h#L69-L71). On a 64-bit kernel it looks like this:

```text
 bit 63       bits 62 .. 8          bits 7 .. 3       bit 2       bit 1       bit 0
+--------+----------------------+----------------+-----------+-----------+-----------+
| READFAIL|    reader count      |    reserved    |  HANDOFF  |  WAITERS  |  WRITER   |
+--------+----------------------+----------------+-----------+-----------+-----------+
```

The constants are:

```c
#define RWSEM_UNLOCKED_VALUE      0UL
#define RWSEM_WRITER_LOCKED       (1UL << 0)          /* 0x0001 */
#define RWSEM_FLAG_WAITERS        (1UL << 1)          /* 0x0002 */
#define RWSEM_FLAG_HANDOFF        (1UL << 2)          /* 0x0004 */
#define RWSEM_FLAG_READFAIL       (1UL << (BITS_PER_LONG - 1))
#define RWSEM_READER_SHIFT        8
#define RWSEM_READER_BIAS         (1UL << RWSEM_READER_SHIFT)  /* 0x0100 */
#define RWSEM_READER_MASK         (~(RWSEM_READER_BIAS - 1))
#define RWSEM_WRITER_MASK         RWSEM_WRITER_LOCKED
#define RWSEM_LOCK_MASK           (RWSEM_WRITER_MASK | RWSEM_READER_MASK)
#define RWSEM_READ_FAILED_MASK    (RWSEM_WRITER_MASK | RWSEM_FLAG_WAITERS | \
                                   RWSEM_FLAG_HANDOFF | RWSEM_FLAG_READFAIL)
```

There are four details worth remembering.

First, **reader bias is 256**, not 1. Every reader adds `0x100`. A reader population of *N* therefore contributes `N * 0x100` to the count. The low byte is reserved for flags, which means a reader can be added with one atomic add and the flags can be tested without masking the reader count away.

Second, **the writer bit is bit 0**. A writer owns the lock when bit 0 is set. In a stable state the reader count is zero at the same time; a valid stable locked state never has both the writer bit and a nonzero reader count. The fast-path writer CAS requires the *entire* count to be zero, but the slow-path writer helper can acquire while the `WAITERS` flag is still set; it clears that flag when it was the last queued waiter.

Third, the high bit is a **read-failure guard**. If a reader sees it in the acquired count, the fast path treats the count as poisoned and calls `rwsem_set_nonspinnable()`. The `WARN_ON_ONCE(*cntp < 0)` in `rwsem_read_trylock()` is not conditional on `CONFIG_DEBUG_RWSEMS`; it is a last-resort warning because the bit should never occur in normal operation.

Fourth, `RWSEM_READER_MASK` covers bits 8 through 63, including the read-fail bit. `RWSEM_LOCK_MASK` is therefore the writer bit plus the whole upper word. That is why an unlock test such as `(count & (RWSEM_LOCK_MASK | RWSEM_FLAG_WAITERS)) == RWSEM_FLAG_WAITERS` proves that no writer and no reader remains.


The reader count is 55 bits wide on a 64-bit kernel. That is far more readers than a real system can have, but the width matters for arithmetic: the count is a signed `long` in several places, and the high bit is reserved for the read-failure marker.

### 2.4 Important Count States

The low bits are easiest to understand with concrete values:

| Count value | Meaning |
|-------------|---------|
| `0x0000` | Unlocked. No writer, no readers, no waiters. |
| `0x0001` | Writer-owned. |
| `0x0002` | No lock holder, but at least one waiter is queued. |
| `0x0003` | Writer-owned and at least one waiter is queued. |
| `0x0100` | One reader. |
| `0x0200` | Two readers. |
| `0x0102` | One reader plus at least one queued waiter. |
| `0x0104` | One reader plus the handoff bit. |
| `0x0106` | One reader, queued waiters, and the handoff bit. |
| `0x0007` | Writer-owned, waiters queued, handoff set. |

`RWSEM_FLAG_WAITERS` is not a count of waiters. It is a boolean saying "the waiter list is non-empty." `RWSEM_FLAG_HANDOFF` is a boolean saying "a writer has waited long enough, or a real-time/deadline writer is waiting, and the next acquisition should be handed to the queue head rather than stolen." The handoff bit is discussed in detail in [Fairness and Starvation](#7-fairness-and-starvation).

A *stable* locked state never has both the writer bit and a reader count. A reader fast path can transiently add its bias while a writer owns the lock; the slow path backs that bias out before the reader queues. The writer acquisition compare-and-swap requires the entire count to be exactly zero, and the downgrade path changes the writer bit and adds a reader bias in one atomic operation, so there is no stable state with both and no intermediate state in which the lock is free.

### 2.5 Size, Cache Lines, and the Owner Hint

Ignoring debug fields, the non-RT structure on AArch64 is roughly 32 bytes: 8 bytes for `count`, 8 for `owner`, 4 for `osq`, 4 for the queued `wait_lock`, and 8 for `first_waiter`. Debug configurations add the magic cookie and the lockdep map, which can push it well past a cache line. Even in the minimal configuration, `wait_lock` and `first_waiter` may share a line, while `count` and `owner` are deliberately adjacent.

The **owner hint** is not a normal owner pointer. In [`kernel/locking/rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwsem.c#L36-L66), the low bits of the owner word are used as flags:

```c
#define RWSEM_READER_OWNED        (1UL << 0)
#define RWSEM_NONSPINNABLE        (1UL << 1)
#define RWSEM_OWNER_FLAGS_MASK    (RWSEM_READER_OWNED | RWSEM_NONSPINNABLE)
```

```
owner word on 64-bit AArch64
============================

  bit 63                                                     bit 2  bit 1  bit 0
 +-----------------------------------------------------------+------+------+------+
 |                     task_struct pointer                    |  -   | NSP  | RDO  |
 +-----------------------------------------------------------+------+------+------+
                                                                  ^      ^
                                                                  |      |
                                      RWSEM_NONSPINNABLE --------+      |
                                      RWSEM_READER_OWNED -----------------+
```

A `task_struct` is aligned well beyond four bytes, so the low bits are free for flags. When a writer owns the lock, `owner` points at its task with no flags. When a reader acquires the lock, `rwsem_set_reader_owned()` writes the current task pointer with `RWSEM_READER_OWNED` set; if several readers hold the lock, the last writer of this hint wins. The reader-owned bit is therefore only a hint that *some* reader recently held the lock, not a statement that the recorded task still does. On the reader unlock path, `rwsem_clear_reader_owned()` clears the hint only when `CONFIG_DEBUG_RWSEMS` or `CONFIG_DETECT_HUNG_TASK_BLOCKER` is enabled; in a production build the owner word is often left untouched so that a hang report can still show the last reader.

When a writer gives up on spinning against readers, bit 1 is set so future spinners do not repeat the same futile work. The task pointer is written with `atomic_long_set()`; the flag bits are updated with atomic read-modify-write operations (`atomic_long_try_cmpxchg()` and `atomic_long_andnot()`). The field is read with `atomic_long_read()` without `wait_lock` and may be stale. It is a performance and debugging hint, not a correctness mechanism. The count word carries the synchronization. The comment in the source calls this out explicitly: writes are atomic to prevent store tearing because optimistic spinners read the value concurrently.


### 2.6 The Waiter Structure

Each waiting task puts a `struct rwsem_waiter` on its own kernel stack. The structure is defined in [`kernel/locking/rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwsem.c#L333-L344):

```c
struct rwsem_waiter {
    struct list_head list;
    struct task_struct *task;
    enum rwsem_waiter_type type;
    unsigned long timeout;
    bool handoff_set;
};
```

The fields are:

- **`list`** links the waiter into the queue. It is a normal circular list, so the first waiter can be found without a separate head allocation.
- **`task`** points at the sleeping task. When the waiter is granted the lock, the wake path sets `task` to `NULL` with release semantics; the waiting task observes the `NULL` with acquire semantics and returns. This is the handshake that tells the sleeper it owns the lock.
- **`type`** is `RWSEM_WAITING_FOR_READ` or `RWSEM_WAITING_FOR_WRITE`.
- **`timeout`** is `jiffies + RWSEM_WAIT_TIMEOUT`, the point at which the waiter is allowed to ask for a handoff. It is not an acquisition timeout.
- **`handoff_set`** marks the queue head as the waiter that owns a requested handoff. If the head is a writer, the flag lets it continue spinning through the owner transition instead of sleeping again; if the head is a reader, the flag marks the reader phase that should be granted next. The flag is set on the head even when a non-head waiter requested the handoff.

A waiter is therefore cheap in memory but not free in stack usage: every contending task carries the structure for the duration of its sleep. The lock itself does not allocate a waitqueue node, and there is no per-waiter slab allocation on the acquisition path.

---

## 3. Initialization

### 3.1 Static Initialization

The static macro is `DECLARE_RWSEM(name)`. A typical declaration looks like this:

```c
static DECLARE_RWSEM(my_rwsem);

static int protected_value;
```

The macro expands to a `struct rw_semaphore` with the unlocked count, a null owner, an empty optimistic spin queue, an unlocked raw spinlock, a null waiter list, and the debug/lockdep initializers. The public definition is in [`include/linux/rwsem.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/rwsem.h#L104-L114):

```c
#define __RWSEM_INITIALIZER(name)                                      \
    { __RWSEM_COUNT_INIT(name),                                        \
      .owner = ATOMIC_LONG_INIT(0),                                    \
      __RWSEM_OPT_INIT(name)                                          \
      .wait_lock = __RAW_SPIN_LOCK_UNLOCKED(name.wait_lock),           \
      .first_waiter = NULL,                                            \
      __RWSEM_DEBUG_INIT(name)                                        \
      __RWSEM_DEP_MAP_INIT(name) }

#define DECLARE_RWSEM(name) \
    struct rw_semaphore name = __RWSEM_INITIALIZER(name)
```

There is no `DEFINE_RWSEM` in the current API. The static initializer is `DECLARE_RWSEM`; this is different from `DEFINE_RWLOCK` for spinlocks and is a common source of confusion when switching between the two primitives.

### 3.2 Dynamic Initialization

For a lock embedded in a dynamically allocated structure, use `init_rwsem()`:

```c
struct my_device {
    struct rw_semaphore lock;
    int state;
};

static int my_probe(struct platform_device *pdev)
{
    struct my_device *dev;

    dev = devm_kzalloc(&pdev->dev, sizeof(*dev), GFP_KERNEL);
    if (!dev)
        return -ENOMEM;

    init_rwsem(&dev->lock);
    return 0;
}
```

`init_rwsem()` is a macro that passes a static lock-class key to `__init_rwsem()`, so lockdep sees each call site as a distinct class:

```c
#define init_rwsem(sem)                                                  \
do {                                                                     \
    static struct lock_class_key __key;                                  \
    __init_rwsem((sem), #sem, &__key);                                   \
} while (0)
```

The macro and the internal entry point are in [`include/linux/rwsem.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/rwsem.h#L119-L124) and [`kernel/locking/rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwsem.c#L309-L331).

A minimal dynamic-initialization module that logs the initial count:

```c
#include <linux/atomic.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/rwsem.h>
#include <linux/slab.h>

MODULE_LICENSE("GPL");

static struct rw_semaphore *demo_sem;

static int __init demo_init(void)
{
    demo_sem = kmalloc(sizeof(*demo_sem), GFP_KERNEL);
    if (!demo_sem)
        return -ENOMEM;

    init_rwsem(demo_sem);
    pr_info("initial rwsem count: %ld\n",
            atomic_long_read(&demo_sem->count));
    return 0;
}

static void __exit demo_exit(void)
{
    kfree(demo_sem);
    demo_sem = NULL;
}

module_init(demo_init);
module_exit(demo_exit);
```

### 3.3 What Initialization Actually Does

`__init_rwsem()` sets `count` to zero, `owner` to zero, initializes the optimistic spin queue, initializes `wait_lock` as an unlocked raw spinlock, clears `first_waiter`, and initializes the debug magic and lockdep map. It does not allocate memory and it cannot fail. The `percpu_rw_semaphore` initializer is different: `percpu_init_rwsem()` allocates per-CPU storage and can return `-ENOMEM`.

Initialization must happen before any task can see the lock. Reinitializing a lock while it is held or while waiters are queued corrupts the wait list and the count. In particular, do not call `init_rwsem()` from a driver's resume path on a lock that might still have sleepers.

### 3.4 Static Versus Dynamic

| Property | `DECLARE_RWSEM(name)` | `init_rwsem(&sem)` |
|----------|-----------------------|--------------------|
| Storage | Static or file-scope object | Caller-provided storage |
| Allocation | None | None |
| Failure | Cannot fail | Cannot fail |
| Lockdep class | One class for the declaration | One class per call site |
| Typical use | Global or subsystem-wide lock | Lock embedded in an allocated object |
| Reinitialization | Never while in use | Never while in use |

The static form is preferred when the lock has a natural global lifetime. The dynamic form is required when the lock is part of an object whose lifetime is managed by a driver or filesystem.

---

## 4. Core API and Count Transitions

### 4.1 Readers: `down_read()` and `up_read()`

`down_read()` acquires the lock in shared mode. Its public entry point performs the sleeping-lock checks and then calls the fast-path helper under `LOCK_CONTENDED` (see [`kernel/locking/rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwsem.c#L1570-L1578)):

```c
void __sched down_read(struct rw_semaphore *sem)
    __no_context_analysis
{
    might_sleep();
    rwsem_acquire_read(&sem->dep_map, 0, 0, _RET_IP_);
    LOCK_CONTENDED(sem, __down_read_trylock, __down_read);
}
```

The fast path is a single atomic add-return (see [`kernel/locking/rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwsem.c#L249-L262)):

```c
static inline bool rwsem_read_trylock(struct rw_semaphore *sem, long *cntp)
{
    *cntp = atomic_long_add_return_acquire(RWSEM_READER_BIAS, &sem->count);

    if (WARN_ON_ONCE(*cntp < 0))
        rwsem_set_nonspinnable(sem);

    if (!(*cntp & RWSEM_READ_FAILED_MASK)) {
        rwsem_set_reader_owned(sem);
        return true;
    }

    return false;
}
```

The operation is not a compare-and-swap. It unconditionally adds `0x100` and then checks whether the resulting count contains a writer, a queued waiter, a handoff, or the read-failure bit. If none of those bits is present, the reader has the lock and records the reader-owner hint. If one is present, the slow path either backs the bias out and queues, or finds a legal opportunity to steal the lock.

`LOCK_CONTENDED()` has a configuration-dependent detail. In the normal build it simply calls `__down_read()`, so the add-return above is the first attempt. Under `CONFIG_LOCK_STAT`, it first calls `__down_read_trylock()` to report contention, and only calls `__down_read()` if that trylock fails; the trylock path uses a compare-and-swap loop. The public API therefore has one extra probe in lock-statistics kernels, but the normal fast path remains the add-return. See [`include/linux/lockdep.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/lockdep.h#L444-L451).

The fact that the normal fast path is an **add**, not a CAS, is why readers scale. Two readers on different CPUs can both execute the atomic add; the hardware serializes the cache line, but neither reader needs to retry a compare-and-swap loop on the normal path. Under `CONFIG_LOCK_STAT`, the preliminary trylock probe does use a CAS loop, and a reader that loses that probe falls through to the add path. The cost of either form is that every reader still writes the shared count cache line, which is exactly the cost that `percpu_rw_semaphore` later removes.

`up_read()` subtracts the bias with release ordering (see [`kernel/locking/rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwsem.c#L1379-L1400)):

```c
static inline void __up_read(struct rw_semaphore *sem)
{
    long tmp;

    /* DEBUG_RWSEMS and trace calls omitted for clarity. */
    preempt_disable();
    rwsem_clear_reader_owned(sem);
    tmp = atomic_long_add_return_release(-RWSEM_READER_BIAS, &sem->count);
    if (unlikely((tmp & (RWSEM_LOCK_MASK | RWSEM_FLAG_WAITERS)) ==
                 RWSEM_FLAG_WAITERS)) {
        clear_nonspinnable(sem);
        rwsem_wake(sem);
    }
    preempt_enable();
}
```

The unlock wakes a waiter only when the count, after the subtraction, has no lock holder and the waiters flag is set; the handoff bit may also be set. If another reader is still active, the last reader will perform the wake. This avoids waking a writer that would immediately go back to sleep.

`rwsem_clear_reader_owned()` is not an unconditional store of zero. In the debug and hung-task configurations it clears the reader-owned hint; in a plain production build it is a no-op. `clear_nonspinnable()` is likewise only relevant when a writer previously recorded that spinning against readers was futile. Neither operation is part of the mutual-exclusion protocol; the count update is.

The public `up_read()` also performs the lockdep release and, when `CONFIG_DEBUG_RWSEMS` is enabled, checks the owner and the count for impossible states. The owner check is a correctness aid for the common case, not a restriction that every reader must be the same task; the special non-owner interface exists for cases where a read lock is handed off.

### 4.2 Writers: `down_write()` and `up_write()`

`down_write()` acquires the lock in exclusive mode. Its public entry point mirrors `down_read()` (see [`kernel/locking/rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwsem.c#L1627-L1634)):

```c
void __sched down_write(struct rw_semaphore *sem)
    __no_context_analysis
{
    might_sleep();
    rwsem_acquire(&sem->dep_map, 0, 0, _RET_IP_);
    LOCK_CONTENDED(sem, __down_write_trylock, __down_write);
}
```

The fast path is a compare-and-swap from the fully unlocked state to the writer-owned state (see [`kernel/locking/rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwsem.c#L264-L274)):

```c
static inline bool rwsem_write_trylock(struct rw_semaphore *sem)
{
    long tmp = RWSEM_UNLOCKED_VALUE;

    if (atomic_long_try_cmpxchg_acquire(&sem->count, &tmp, RWSEM_WRITER_LOCKED)) {
        rwsem_set_owner(sem);
        return true;
    }
    return false;
}
```

The compare-and-swap requires the entire count to be zero. It fails if any reader is present, if another writer owns the lock, if waiters are queued, or if the handoff bit is set. The writer then enters the slow path, which first tries optimistic spinning and then queues itself.

`up_write()` clears the writer bit with release ordering (see [`kernel/locking/rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwsem.c#L1403-L1422)):

```c
static inline void __up_write(struct rw_semaphore *sem)
{
    long tmp;

    /* DEBUG_RWSEMS and trace calls omitted for clarity. */
    preempt_disable();
    rwsem_clear_owner(sem);
    tmp = atomic_long_fetch_add_release(-RWSEM_WRITER_LOCKED, &sem->count);
    if (unlikely(tmp & RWSEM_FLAG_WAITERS))
        rwsem_wake(sem);
    preempt_enable();
}
```

The fetch-add release preserves the reader count and the flag bits while clearing the writer bit. A blind store of zero would be wrong: another reader may have added its bias in the slow-path race, and the waiters bit may need to survive. The release ordering ensures that the writer's critical-section stores are visible to a reader or writer that acquires the lock afterward.

### 4.3 Trylock Variants

`down_read_trylock()` and `down_write_trylock()` never sleep. They return `1` on success and `0` on failure. This is the opposite convention from `down_trylock()` on a `struct semaphore`, which returns `0` when it acquires the semaphore and `1` when it would block. The reader version uses a compare-and-swap loop so it does not leave a temporary bias behind when the lock is unavailable:

```c
int down_read_trylock(struct rw_semaphore *sem)
{
    int ret = __down_read_trylock(sem);

    if (ret == 1)
        rwsem_acquire_read(&sem->dep_map, 0, 1, _RET_IP_);
    return ret;
}
```

The writer version is the same fast-path compare-and-swap used by `down_write()`:

```c
int down_write_trylock(struct rw_semaphore *sem)
{
    int ret = __down_write_trylock(sem);

    if (ret == 1)
        rwsem_acquire(&sem->dep_map, 0, 1, _RET_IP_);
    return ret;
}
```

The trylock forms do not call `might_sleep()` and do not queue a waiter. They can be used as a non-blocking probe, but they are still part of a sleeping-lock API. The kernel documentation warns that acquiring a sleeping lock from a non-task context requires auditing both the trylock and the eventual unlock, because the unlock path may need to wake a waiter. Treat trylock as a process-context optimization, not as a general interrupt-safe primitive.

### 4.4 Interruptible and Killable Variants

The uninterruptible forms are `down_read()` and `down_write()`. The interruptible read form is `down_read_interruptible()`; the killable forms are `down_read_killable()` and `down_write_killable()`. They exist so a task waiting for a lock can respond to a fatal signal or a signal-delivery request.

The return values are:

- `down_read_interruptible()`: `0` on success, `-EINTR` if interrupted by a signal.
- `down_read_killable()`: `0` on success, `-EINTR` if killed.
- `down_write_killable()`: `0` on success, `-EINTR` if killed.

There is no `down_write_interruptible()` in the public API. Writers use the killable form when they need signal responsiveness. The slow-path state is `TASK_INTERRUPTIBLE` for the interruptible read and `TASK_KILLABLE` for the killable forms. A signal that arrives after the task has been granted the lock is handled by the normal lock-acquisition return path; a signal that arrives while the task is queued causes the waiter to be removed from the list and the next waiter to be woken if necessary.

The waiter's `timeout` field is not a user-visible timeout. `rw_semaphore` has no `down_timeout()` equivalent. The field is used only to decide when to request a handoff.

### 4.5 Nested and Non-Owner Interfaces

The nested interfaces are `down_read_nested()` and `down_write_nested()`. They take a lockdep subclass and exist for the case where a task must acquire two different locks of the same class in a defined order. They do **not** make recursive acquisition of the same lock instance safe.

The non-owner interfaces are `down_read_non_owner()` and `up_read_non_owner()`. They exist for special cases where a read lock is acquired in one context and released in another, such as a handoff between tasks. They bypass the normal lockdep acquisition and release annotations; the acquire variant also records `NULL` as the reader owner. They should not be used as a convenience. The writer side has no non-owner release because the writer bit and the owner field are tied to the task that acquired the lock.

There is also `down_write_nest_lock()`, which is used by lockdep-aware code that needs to nest a write lock under another lock class.

### 4.6 Complete API Table

| API | Mode | Sleeps? | Return | Notes |
|-----|------|---------|--------|-------|
| `DECLARE_RWSEM(name)` | — | — | — | Static initializer |
| `init_rwsem(sem)` | — | — | — | Dynamic initializer, cannot fail |
| `down_read(sem)` | Shared | Yes | — | Uninterruptible; calls `might_sleep()` |
| `down_read_interruptible(sem)` | Shared | Yes | `0` / `-EINTR` | Responds to signals |
| `down_read_killable(sem)` | Shared | Yes | `0` / `-EINTR` | Responds to fatal signals |
| `down_read_trylock(sem)` | Shared | No | `1` / `0` | Does not queue |
| `up_read(sem)` | Shared | No | — | Release; may wake waiters |
| `down_read_non_owner(sem)` | Shared | Yes | — | Special handoff use |
| `up_read_non_owner(sem)` | Shared | No | — | Pairs with the above |
| `down_read_nested(sem, subclass)` | Shared | Yes | — | Lockdep subclass |
| `down_write(sem)` | Exclusive | Yes | — | Uninterruptible; calls `might_sleep()` |
| `down_write_killable(sem)` | Exclusive | Yes | `0` / `-EINTR` | Responds to fatal signals |
| `down_write_trylock(sem)` | Exclusive | No | `1` / `0` | Does not queue |
| `up_write(sem)` | Exclusive | No | — | Release; may wake waiters |
| `down_write_nested(sem, subclass)` | Exclusive | Yes | — | Lockdep subclass |
| `down_read_killable_nested(sem, subclass)` | Shared | Yes | `0` / `-EINTR` | Killable plus subclass |
| `down_write_killable_nested(sem, subclass)` | Exclusive | Yes | `0` / `-EINTR` | Killable plus subclass |
| `down_write_nest_lock(sem, nest_lock)` | Exclusive | Yes | — | Lockdep nesting annotation |
| `downgrade_write(sem)` | Write→Read | No | — | Atomic conversion, no free window |
| `rwsem_is_locked(sem)` | — | No | Boolean | Count is nonzero |
| `rwsem_is_contended(sem)` | — | No | Boolean | A waiter is queued |
| `rwsem_assert_held(sem)` | — | No | — | Lockdep/debug assertion |
| `rwsem_assert_held_write(sem)` | — | No | — | Writer assertion |

### 4.7 Count Transition Table

The following table is the quickest way to reason about the lock word. It assumes an initially unlocked lock and no debug fields.

| Operation | Count change | Result | Wake condition |
|-----------|--------------|--------|----------------|
| `down_read()` fast path | `+0x100` | `N * 0x100` | No wake |
| `up_read()` | `-0x100` | `(N-1) * 0x100` | Wake if no lock holder remains and `WAITERS` is set (`HANDOFF` may also be set) |
| `down_write()` fast path | `0x0 -> 0x1` | `0x1` | No wake |
| `up_write()` | `-0x1` | `0x0` or flags | Wake if the old count had `WAITERS` |
| `down_read_trylock()` | `+0x100` if no failure bits | `N * 0x100` | No wake |
| `down_write_trylock()` | `0x0 -> 0x1` | `0x1` | No wake |
| `downgrade_write()` | `-0x1 + 0x100` | Writer becomes one reader | Wake readers if waiters |
| Queued writer | Sets `0x2` (waiters bit) when it becomes the first waiter | Current reader biases `+ 0x2` | Wake when readers drain |
| Queued reader | Bias backed out; sets `0x2` if it becomes the first waiter | Existing reader count `+ 0x2` if first, otherwise unchanged | Wake on release |

A few worked examples:

```text
unlocked                         0x0000
one reader                       0x0100
two readers                      0x0200
writer                           0x0001
writer + one waiter              0x0003
one reader + one waiter          0x0102
one reader + waiters + handoff   0x0106
```

The transition from `0x0200` to `0x0000` requires two `up_read()` calls. The first produces `0x0100` and does not wake anyone, because another reader is still present; the second produces `0x0000`. If a writer is already queued, the same sequence starts from `0x0202`: the first unlock produces `0x0102`, and the second produces `0x0002` and wakes the writer. If that writer was the only waiter, it converts the count to `0x0001`, removes itself, and later releases to `0x0000`. If another waiter is behind it, the writer converts the count to `0x0003`, removes itself, and later releases to `0x0002` so the next waiter can be woken.

### 4.8 State Checks and lockdep Assertions

`rwsem_is_locked()` reads the count and returns true if any bit is set. That includes the flag-only states, such as a count of `0x0002` (waiters queued, no current lock holder), so it is not a precise "some task holds the lock" test under contention. It is a snapshot, not a synchronization primitive. Do not use it to decide whether it is safe to access protected data; another task can change the state immediately after the read.

`rwsem_is_contended()` reads `first_waiter` with `data_race()` and returns whether the queue is non-empty. It is intended for diagnostics and adaptive behavior, not for correctness. The same caveat applies: the queue can change immediately after the check.

`rwsem_assert_held()` and `rwsem_assert_held_write()` are lockdep/debug assertions. In a `CONFIG_DEBUG_LOCK_ALLOC` kernel they ask lockdep whether the current task holds the lock in the required mode. In a non-lockdep kernel they may be compiled away or reduced to a count check. They are useful at the top of a function that expects a caller to hold the lock, but they are not a substitute for a real lock.

Lockdep records the distinction between shared and exclusive acquisition. A task that holds the lock for read and then tries to acquire it for write is a classic same-instance recursion that lockdep can report, and it is a real deadlock even if no other task is involved. A write acquisition followed by a read acquisition is also suspicious and should be replaced by `downgrade_write()` where the intent is a real conversion. A pure read-to-read recursion is not reliably diagnosed, because rwsem reads use lockdep's shared mode rather than recursive-read mode. The lockdep reports are covered in [Debugging and Observability](#15-debugging-and-observability).

---

## 5. A Complete Thread Example

### 5.1 The Module

The following module starts two reader kthreads and one writer kthread. The readers take the lock in shared mode and sleep for 200 ms while holding it; the writer takes it in exclusive mode and also sleeps while holding it. Sleeping while holding an `rw_semaphore` is legal, which is the whole point of the primitive. The example is intentionally slow so that the serialization is visible in `dmesg`.

```c
// SPDX-License-Identifier: GPL-2.0
#include <linux/err.h>
#include <linux/kthread.h>
#include <linux/module.h>
#include <linux/rwsem.h>
#include <linux/sched.h>
#include <linux/delay.h>

static DECLARE_RWSEM(demo_rwsem);
static int demo_value;

static struct task_struct *reader_one;
static struct task_struct *reader_two;
static struct task_struct *writer_task;

static int demo_reader(void *unused)
{
    while (!kthread_should_stop()) {
        down_read(&demo_rwsem);
        pr_info("%s: value=%d\n", current->comm, demo_value);
        msleep(200);
        up_read(&demo_rwsem);
        msleep(100);
    }
    return 0;
}

static int demo_writer(void *unused)
{
    int value = 0;

    while (!kthread_should_stop()) {
        down_write(&demo_rwsem);
        demo_value = ++value;
        pr_info("%s: value=%d\n", current->comm, demo_value);
        msleep(200);
        up_write(&demo_rwsem);
        msleep(500);
    }
    return 0;
}

static int __init demo_init(void)
{
    reader_one = kthread_run(demo_reader, NULL, "rwsem-r1");
    reader_two = kthread_run(demo_reader, NULL, "rwsem-r2");
    writer_task = kthread_run(demo_writer, NULL, "rwsem-w");

    if (IS_ERR(reader_one) || IS_ERR(reader_two) || IS_ERR(writer_task)) {
        if (!IS_ERR(reader_one))
            kthread_stop(reader_one);
        if (!IS_ERR(reader_two))
            kthread_stop(reader_two);
        if (!IS_ERR(writer_task))
            kthread_stop(writer_task);
        return -ENOMEM;
    }

    pr_info("rwsem demo loaded\n");
    return 0;
}

static void __exit demo_exit(void)
{
    kthread_stop(reader_one);
    kthread_stop(reader_two);
    kthread_stop(writer_task);
    pr_info("rwsem demo unloaded\n");
}

module_init(demo_init);
module_exit(demo_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Reader-writer semaphore kthread example");
```

A few details are worth calling out because they are common mistakes in examples of this kind:

- The lock is initialized statically with `DECLARE_RWSEM`, so no explicit `init_rwsem()` call is needed.
- The readers call `down_read()` and `up_read()`, not `down()` and `up()`. Those latter names belong to `struct semaphore`, not `rw_semaphore`.
- The writer calls `down_write()` and `up_write()`. A writer that calls `up_read()` will corrupt the count and trip the debug checks.
- Each kthread checks `kthread_should_stop()` at the top of its loop. The `kthread_stop()` calls in `demo_exit()` wait for the function to return, so a thread that ignored the stop request would hang module unload.
- The error path stops only the threads that were actually created. `kthread_run()` returns an `ERR_PTR()` on failure, and calling `kthread_stop()` on an error pointer would be a bug.
- The `pr_info()` format uses `current->comm`, which is the kthread's name. In a real driver, use the device name and the appropriate logging facility.

### 5.2 What the Output Demonstrates

While a reader holds the lock, the other reader can enter. The writer, however, waits until both readers have called `up_read()`. Once the writer owns the lock, both readers wait until `up_write()`. The timestamps in `dmesg` show the pattern:

```text
rwsem-r1: value=0
rwsem-r2: value=0
rwsem-w:  value=1
rwsem-r1: value=1
rwsem-r2: value=1
rwsem-w:  value=2
```

The exact interleaving depends on scheduling, but the invariant is stable: reader messages may overlap, writer messages never overlap with a reader message. The `msleep()` calls make the overlap easy to see. In production code, holding the lock across a long sleep is usually a bad idea for latency, even though it is legal.

The example also shows why `rw_semaphore` is not a drop-in replacement for `rwlock_t`. If the same critical section were protected by an `rwlock_t`, the `msleep()` calls would be illegal: the kernel would complain about sleeping in an atomic section, and the system could deadlock or stall.

---

## 6. Internal Implementation

### 6.1 Fast Path and Slow Path

The lock has two layers. The **fast path** is a single atomic operation on `count` plus an owner update. The **slow path** takes `wait_lock`, manipulates the waiter list, and sleeps. The public functions try the fast path first; the `LOCK_CONTENDED` macro exists to make that pattern uniform across lock types. The names in this section refer to the non-RT implementation in [`kernel/locking/rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwsem.c#L1284-L1330).

A simplified view is:

```text
down_read:
    preempt_disable()
    add 0x100 to count with acquire ordering
    if no writer/waiters/handoff/readfail:
        set reader owner
        preempt_enable()
        return
    slow path (may back out the add, queue, and sleep)
    preempt_enable()

down_write:
    compare-and-swap count from 0 to 1 with acquire ordering
    if success:
        set writer owner
        return
    slow path (optimistic spin, then queue and sleep)
```

```text
                         down_read() / down_write()
                                    |
                 +------------------+------------------+
                 |                                     |
          reader fast path                       writer fast path
          add +0x100 (acquire)                   CAS 0 -> 1 (acquire)
                 |                                     |
        +--------+--------+                   +--------+--------+
        |                 |                   |                 |
   no fail bits      fail bits            CAS success       CAS failure
        |                 |                   |                 |
   set owner hint    slow path            set owner        optimistic spin
   return            (steal/queue)         return           (osq)
                                                               |
                                                     +---------+---------+
                                                     |                   |
                                                  acquire              queue
                                                  return               sleep
```

The reader slow path may still steal the lock; the writer slow path may still spin. The diagram names the first decision, not the entire algorithm.

The fast paths are short enough to inline: `rwsem_read_trylock()`, `rwsem_write_trylock()`, and the unlock helpers are `static inline`. The slow-path functions are out of line, and some inner helpers such as `rwsem_spin_on_owner()` are deliberately `noinline` where the compiler would otherwise bloat the hot caller.

When the lock is unavailable, the behavior depends on the mode. A reader that fails the flag check may still steal the lock in the slow path if no writer or handoff is present; otherwise it backs its bias out, queues a stack waiter, and sleeps. A writer that fails the compare-and-swap first tries optimistic spinning; if that fails, it queues and sleeps. When the last conflicting holder releases, the unlock path sees the waiters flag, wakes the queue head (or a batch of readers), and the woken task re-checks the count and completes the acquisition.

### 6.2 Reader Fast Path

The reader fast path is `rwsem_read_trylock()` plus the small wrapper in `__down_read_common()`. The add-return both acquires the lock and reports the resulting state. The acquire ordering is important: it ensures that the reader sees all stores made by a previous writer before the writer released the lock.

The reader owner update uses `rwsem_set_reader_owned()`, which writes the current task pointer with the `RWSEM_READER_OWNED` bit set. This is not required for mutual exclusion. It exists so a writer spinning on the lock can tell that the owner is a reader and can apply the reader-specific spin threshold. If several readers hold the lock, the last one to set the owner wins; the field is only a hint.

The reader fast path does not touch `wait_lock`, does not allocate a waiter, and does not wake anyone. That is the path that matters for a read-mostly workload. It is also the path that makes the shared count cache line hot, which is the motivation for the per-CPU variant.

### 6.3 Reader Slow Path

The reader slow path is `rwsem_down_read_slowpath()` in [`kernel/locking/rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwsem.c#L1016-L1133). It receives the count value that already includes the temporary reader bias. Its job is to decide whether the reader can still steal the lock, or whether it must back the bias out and queue.

The decision sequence is roughly:

1. If the lock is reader-owned and more than one reader is present, and there is no writer, go straight to the queue. This prevents a stream of readers from continuously stealing the lock from a writer that is already waiting.
2. If there is no writer bit and no handoff bit, the reader can steal the lock. It sets the reader owner, possibly wakes readers at the head of the queue, and returns with the bias still in the count.
3. Otherwise, it initializes a stack waiter with type `RWSEM_WAITING_FOR_READ` and a handoff deadline, takes `wait_lock`, and checks the state again.
4. If the waiter list is still empty and no writer owns the lock, the reader releases `wait_lock`, sets the owner, and returns. This is the "fast path after all" case: the race resolved while the slow path was setting up.
5. If the list was empty, the waiter becomes `first_waiter` and the `WAITERS` bit is set. Otherwise it is appended behind the existing head. The temporary reader bias is then removed from the count with one atomic add. After that subtraction, the slow path calls `rwsem_cond_wake_waiter()`: if a writer owns the lock, there is nothing to wake; if readers own it, queued readers at the head can be woken; if no one owns it, any head waiter can be woken.
6. The task releases `wait_lock`, performs any queued wakeups, sets its state, and sleeps until the wake path clears `waiter.task`.
7. If a signal interrupts an interruptible or killable wait, the waiter is removed, a possible new head is woken, and the function returns `-EINTR`.

The important subtlety is that the count is modified twice in the queued case. The fast-path add made the reader visible for a moment; the slow path then subtracts that bias while holding `wait_lock`, so the final count reflects only the readers that actually own the lock. This two-step dance avoids taking `wait_lock` on the successful fast path at the cost of occasional extra atomic traffic under contention.

```text
rwsem_down_read_slowpath(sem, count_with_bias)
    |
    +--> owner hint says reader-owned, rcnt > 1, no writer?
    |        |
    |        +--> yes: go straight to queue
    |
    +--> no writer bit and no handoff bit?
             |
             +--> yes: keep bias, set reader hint,
             |         optionally wake queued readers,
             |         return with lock
             |
             +--> no: take wait_lock
                      |
                      +--> queue still empty and no writer?
                      |        |
                      |        +--> yes: drop lock, set hint,
                      |                  return with lock
                      |
                      +--> append waiter
                      +--> if first: install, set WAITERS
                      +--> count -= bias
                      +--> cond_wake_waiter()
                      +--> unlock wait_lock; wake_q; sleep
```

The wait loop uses acquire semantics when it observes `waiter.task == NULL`. The wake path sets `task` to `NULL` with release semantics after it has incremented the reader count for the woken reader. That pairing is what makes the handshake safe: the woken task cannot observe the lock as granted before the count update is visible.

### 6.4 Writer Fast Path

The writer fast path is `rwsem_write_trylock()`, a compare-and-swap from `0` to `RWSEM_WRITER_LOCKED`. It is correct only when the count is exactly zero. If a reader bias, a waiters flag, a handoff flag, or another writer is present, the CAS fails and the writer enters the slow path.

The CAS uses acquire ordering. The writer's critical section therefore sees all stores made by the previous lock holder before the release. On success, `rwsem_set_owner()` records the current task pointer. That pointer is read by optimistic spinners and by debug code.

### 6.5 Writer Slow Path and Queuing

The writer slow path is `rwsem_down_write_slowpath()` in [`kernel/locking/rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwsem.c#L1138-L1238). It has two phases: an optimistic spin phase, and a queued sleep phase.

The optimistic spin phase is attempted first when `CONFIG_RWSEM_SPIN_ON_OWNER` is enabled. If the owner is currently running and the count is not marked nonspinnable, the writer can spin without taking `wait_lock` and without adding itself to the waiter list. This is covered in detail in [Optimistic Spinning](#8-optimistic-spinning). If the spin succeeds, the writer never sleeps. If it fails, the writer queues.

The queued phase works like this:

1. Initialize a stack waiter with type `RWSEM_WAITING_FOR_WRITE` and a handoff deadline.
2. Take `wait_lock` with interrupts disabled.
3. If the waiter list is empty, install this waiter as `first_waiter` and set `RWSEM_FLAG_WAITERS` in the count. If the list is not empty, append the waiter.
4. If the list already had a head, call `rwsem_cond_wake_waiter()`. This may wake readers that are eligible to run alongside the current reader owner, or wake the head waiter if the count has no lock holder. A writer never wakes the newly appended writer directly; the new waiter must go around the loop and try the count itself.
5. Release `wait_lock`, check for signals, and sleep until the waiter is granted.
6. On wakeup, take `wait_lock` again and try to convert the count to the writer-owned state. If the conversion succeeds, remove the waiter, set the owner, and return.
7. If the conversion fails and the waiter is a real-time/deadline task or has waited past its handoff deadline, `rwsem_try_write_lock()` may set `RWSEM_FLAG_HANDOFF` in the count. It records `first->handoff_set = true` so the queue head can spin through the handoff transition; a non-head waiter does not take ownership of an existing head handoff.
8. If a signal interrupts a killable wait, remove the waiter, wake a replacement if necessary, and return `-EINTR`.

```text
writer CAS fails
    |
    v
can_spin_on_owner()?
    | yes                               | no
    v                                   v
osq_lock()                              queue
    | success          | failure          |
    v                  +------------------+
spin loop
    |
    +--> try_write_lock_unqueued() succeeds --> lock, osq_unlock, return
    +--> owner nonspinnable / need_resched / RT transition --> leave loop
    +--> reader threshold expired --> set NONSPINNABLE, leave loop
    |
    v
osq_unlock()
    |
    v
queue: waiter.task = current; timeout = jiffies + WAIT_TIMEOUT
       wait_lock
         |
         +--> list empty? install first; set WAITERS
         +--> list non-empty? append; cond_wake_waiter()
         |
       loop:
         try_write_lock()
           | success: remove waiter, set owner, return
           | failure: unlock wait_lock; signal?; optional handoff spin;
           |          schedule; relock
```

The writer's `rwsem_try_write_lock()` helper is in [`kernel/locking/rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwsem.c#L625-L689). It performs the compare-and-swap only when the count has no lock holder. If a reader or another writer holds the lock, it checks the handoff state and decides whether to set the handoff bit. Any waiter can request a handoff when it is a real-time/deadline task or has exceeded its deadline, but once a handoff is active the code records it on `first_waiter->handoff_set`. Other waiters yield when that head flag is set and they are not the head. The handoff is therefore owned by the queue head, not by whichever waiter happened to request it.

### 6.6 Waking Waiters

The wake path is `rwsem_mark_wake()` in [`kernel/locking/rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwsem.c#L429-L589). It runs with `wait_lock` held and does not call the scheduler directly. Instead, it builds a `wake_q` list and lets `wake_up_q()` perform the actual wakeups after the lock is released. That keeps the critical section short and avoids waking a task that would immediately block on `wait_lock`.

There are three wake modes:

- **`RWSEM_WAKE_ANY`** is used by `up_read()`, `up_write()`, and waiter removal. If the head waiter is a writer, wake that writer. If the head waiter is a reader, start a reader phase and grant a batch of queued readers.
- **`RWSEM_WAKE_READERS`** is used by the slow-path helper when the lock is reader-owned and only readers should be considered. It does not wake a writer.
- **`RWSEM_WAKE_READ_OWNED`** is used by `downgrade_write()`. The downgrader still holds a read lock, so it cannot hand the lock to a writer. It wakes only readers.

The reader wake path is more involved than the writer path because counting must be adjusted before the sleepers are told they own the lock. `rwsem_mark_wake()` performs two passes:

1. It collects up to `MAX_READERS_WAKEUP` (`0x100`, or 256) readers from the queue, skipping writers, and increments the count by one reader bias for each. This makes the readers' ownership visible before their `task` pointers are cleared.
2. It walks the same waiters again, clears `waiter.task` with release semantics, and adds them to the wake queue.

```text
wait_lock held; queue =  R1 -> W1 -> R2 -> R3 -> W2 -> ...
                           ^ head is reader

PASS 1: count and eligibility
    count += (number of readers selected) * 0x100
    move selected readers to a private wlist
        wlist = R1, R2, R3
    leave writers in the main queue
        queue = W1, W2

PASS 2: task handshake and wake queue
    for each waiter in wlist:
        get_task_struct(waiter->task)
        smp_store_release(&waiter->task, NULL)
        wake_q_add_safe(wake_q, task)

    if main queue is empty:
        clear WAITERS (and HANDOFF if set)
    else if readers were woken:
        clear HANDOFF only

unlock(wait_lock)
wake_up_q(wake_q)          <-- scheduler wakeups happen here
```

The two-pass order is not cosmetic. A reader that has not gone to sleep yet can observe `waiter.task == NULL` immediately, enter its critical section, and call `up_read()` before the wake path has finished. If the count were incremented in the second pass, that early unlock could decrement a reader count that had not yet been added. The first pass makes the count correct before any task can observe the grant.

If the queue becomes empty, the waiters flag is cleared. If the head is a writer, only that writer is woken; readers behind it must wait because a writer is at the head of the queue. The woken writer can still be beaten by another writer that is optimistically spinning before it runs, so the wake is an opportunity, not an exclusive grant. If the head is a reader, the wake path grants a batch of queued readers irrespective of their individual positions; writers remain ordered by the queue. This is the phase-fair part of the design: the queue is not a simple readers-first or writers-first policy, and readers are batched by phase rather than one at a time.

### 6.7 Unlock and Downgrade

The unlock paths are small but subtle:

```c
static inline void __up_read(struct rw_semaphore *sem)
{
    long tmp;

    /* DEBUG_RWSEMS and trace calls omitted for clarity. */
    preempt_disable();
    rwsem_clear_reader_owned(sem);
    tmp = atomic_long_add_return_release(-RWSEM_READER_BIAS, &sem->count);
    if (unlikely((tmp & (RWSEM_LOCK_MASK | RWSEM_FLAG_WAITERS)) ==
                 RWSEM_FLAG_WAITERS)) {
        clear_nonspinnable(sem);
        rwsem_wake(sem);
    }
    preempt_enable();
}

static inline void __up_write(struct rw_semaphore *sem)
{
    long tmp;

    /* DEBUG_RWSEMS and trace calls omitted for clarity. */
    preempt_disable();
    rwsem_clear_owner(sem);
    tmp = atomic_long_fetch_add_release(-RWSEM_WRITER_LOCKED, &sem->count);
    if (unlikely(tmp & RWSEM_FLAG_WAITERS))
        rwsem_wake(sem);
    preempt_enable();
}
```

`__up_read()` clears the reader owner hint when the debug/hung-task configuration enables that helper, subtracts the bias with release ordering, and wakes only when the resulting count contains no lock holder at all. `__up_write()` clears the writer owner hint, subtracts the writer bit with release ordering, and wakes if the old count had waiters. The `fetch_add` form is essential: it preserves reader biases that may have been added concurrently by the slow path, and it preserves the flag bits.

`downgrade_write()` is implemented in [`kernel/locking/rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwsem.c#L1428-L1449) as a single release fetch-add:

```c
static inline void __downgrade_write(struct rw_semaphore *sem)
{
    long tmp;

    preempt_disable();
    tmp = atomic_long_fetch_add_release(
            -RWSEM_WRITER_LOCKED + RWSEM_READER_BIAS, &sem->count);
    rwsem_set_reader_owned(sem);
    if (tmp & RWSEM_FLAG_WAITERS)
        rwsem_downgrade_wake(sem);
    preempt_enable();
}
```

The arithmetic is the key. Subtracting the writer bit and adding a reader bias in one atomic operation means there is no instant at which the lock is unlocked. A competing writer cannot slip in between "writer released" and "reader acquired," so the downgrade preserves the atomicity of the writer's critical section as it transitions into a read-only follow-up. The reader-owner hint is set immediately after the count update. The wake path is `RWSEM_WAKE_READ_OWNED`, because the downgrader is still a reader and a writer cannot be granted the lock yet.

### 6.8 The State Machine

The lock is a set of independent fields, not a single enum. The following diagram shows the common non-RT states and the transitions that matter for ordinary contention. It deliberately omits the reader-owned hint and the read-fail bit.

```text
A. Reader population (no writer queued)

   FREE --down_read--> N readers --down_read--> N+1 readers
     ^                   |    |
     |                   |    +---- down_read ----> ...
     |                   |
     |                   +---- up_read (N > 1) ---> N-1 readers
     |
     +---- up_read (N = 1) ------------------------ FREE


B. Writer and queue states

   FREE --down_write CAS 0->1--> WRITER (0x1)
                                    |
                                    | first queued waiter sets WAITERS
                                    v
                              WRITER + WAITERS (0x3)
                                    |
                                    | up_write (-1), queue non-empty
                                    v
                              WAITERS only (0x2)
                                    |
              +---------------------+---------------------+
              |                                           |
     head is writer                              head is reader
              |                                           |
              v                                           v
     head writer acquires:                   reader batch (0x100*N + flags)
       queue empty  -> WRITER (0x1)          (WAITERS cleared only if queue empty)
       queue remains-> WRITER+WAITERS (0x3)
     (writer removes itself and re-checks)
```

Readers that arrive while a writer is queued take this path:

```text
   reader fast add (+0x100)
       0x0002 -> 0x0102  (WAITERS makes the flag test fail)
              |
              v
   slow path backs out -0x100 and queues
       0x0102 -> 0x0002
              |
              v
   the reader waits behind the existing head
```

The handoff bit adds `0x4`:

```text
   WRITER + WAITERS (0x3)
        |
        | waiter is RT/DL or past RWSEM_WAIT_TIMEOUT
        v
   WRITER + WAITERS + HANDOFF (0x7)
        |
        | readers drain, unlock observes WAITERS|HANDOFF
        v
   WAITERS (+HANDOFF) --> head waiter is granted
        |
        +--> head writer: clears HANDOFF, installs WRITER
        +--> head reader: reader batch, clears HANDOFF
```

The reader-owned hint and the READFAIL bit are omitted. The count is a set of independent fields, not a single enum; the authoritative rules are the bit tests in the source, and the owner hint can lag the count.

### 6.9 A Complete Contention Walkthrough

Consider two readers, `R1` and `R2`, one writer `W`, and a later reader `R3`.

1. `R1` and `R2` call `down_read()`. The count becomes `0x0200`.
2. `W` calls `down_write()`. The CAS from zero fails. The slow path takes `wait_lock`, installs `W` as the first waiter, and sets `WAITERS`. The count becomes `0x0202`.
3. `R3` calls `down_read()`. The fast-path add produces `0x0302`. The `WAITERS` bit is set, so the fast path fails. The slow path sees that the lock is reader-owned and that the reader population is greater than one, so it does not steal. It appends itself behind `W` and backs its bias out. The count returns to `0x0202`.
4. `R1` calls `up_read()`. The count becomes `0x0102`. The result is not waiters-only because `R2` still holds a read lock, so no wake occurs.
5. `R2` calls `up_read()`. The count becomes `0x0002`. The result is waiters-only, so `rwsem_wake()` runs. The head is `W`, so `W` is woken.
6. `W` takes `wait_lock` and tries `rwsem_try_write_lock()`. The count has no lock holder, so it writes `0x0003` (writer bit plus waiters), removes its waiter, and returns. `R3` remains queued behind it.
7. `W` calls `up_write()`. The count becomes `0x0002`, and the old count had waiters, so `rwsem_wake()` runs. The head is now `R3`, a reader, so the wake path increments the count by one reader bias and clears the waiters flag. The count becomes `0x0100`, and `R3` wakes as the sole reader.

This walkthrough shows the two-phase nature of the queue: a writer at the head does not automatically own the lock; it must re-check after being woken. It also shows that a reader arriving while a writer is queued does not jump the queue in the common case, because the `WAITERS` bit makes the fast path fail and the reader-owned/`rcnt > 1` check sends it to the back.

---

## 7. Fairness and Starvation

### 7.1 Phase-Fair Behavior

The non-RT implementation is described in [`Documentation/locking/locktypes.rst`](https://github.com/torvalds/linux/blob/v7.3-rc7/Documentation/locking/locktypes.rst#L132-L155) as fair, specifically fair enough to prevent writer starvation. It is not a strict global FIFO lock. It is **phase-fair**: readers in a reader phase are batched, writers are ordered by the queue, and a handoff mechanism bounds how long either side can be postponed.

The queue order is the primary fairness mechanism. When the head is a writer, only that queued waiter is woken; a writer that has not yet queued can still steal the lock optimistically until a handoff bit is set. When the head is a reader, the wake path can grant the lock to up to 256 queued readers at once, skipping writers in the batch. A writer behind those readers waits until the reader phase drains. That is deliberate: waking readers one at a time would require a separate count adjustment and wake cycle for every reader and would give a stream of new readers more opportunities to interleave. Granting a batch amortizes the queue work while preserving reader throughput. Queued readers do not leapfrog a head writer, though the narrow slow-path single-reader steal described in [What happens when a writer is waiting and a new reader arrives](#75-what-happens-when-a-writer-is-waiting-and-a-new-reader-arrives) remains possible until a handoff bit is set.

The batching limit is `MAX_READERS_WAKEUP` in [`kernel/locking/rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwsem.c#L365). The value is `0x100`, or 256. It bounds the work done while holding `wait_lock` and the number of wakeups generated in one pass.

### 7.2 The Waiters Bit

`RWSEM_FLAG_WAITERS` means "the waiter list is non-empty." It is set when the first waiter is installed and cleared when the list becomes empty. It is not a count, and it is not incremented once per waiter.

The bit has two jobs. First, it makes new readers fail the fast path. A reader that sees `WAITERS` must go to the slow path, where the implementation decides whether the reader can steal the lock or must queue. Second, it tells the unlock path that there may be someone to wake, so `up_read()` and `up_write()` do not need to test `first_waiter` in the common uncontended case.

The bit is set and cleared under `wait_lock`. The count manipulations that add the bit use atomic operations because readers and writers can be updating the count concurrently, but the decision to set or clear it is serialized by the wait lock.

### 7.3 The Handoff Bit

`RWSEM_FLAG_HANDOFF` is the anti-starvation escape hatch. It is set when a writer has waited longer than `RWSEM_WAIT_TIMEOUT`, when a real-time or deadline writer needs the lock, or when a queued reader at the head has waited past its deadline while a writer owns the count. The timeout is defined in [`kernel/locking/rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwsem.c#L357):

```c
#define RWSEM_WAIT_TIMEOUT  DIV_ROUND_UP(HZ, 250)
```

At `HZ=1000` that is four milliseconds, and at `HZ=250` it is one jiffy, which is also four milliseconds. At `HZ=100` it is one jiffy, or ten milliseconds. The comment in the source notes that the timeout is not a hard acquisition timeout. It is the point after which the waiter is allowed to request a handoff.

When the handoff bit is set, new readers see it in the fast path and fail. Readers that are already queued behind the handoff owner are not allowed to steal. The current reader population drains, and the queue head gets the next acquisition. Once the handoff is granted or the waiter is removed, the bit is cleared.

The handoff bit has to be managed carefully because there can be multiple waiters with different deadlines. A writer that is not at the head may request the bit, but the implementation records the request on `first_waiter->handoff_set`; the handoff belongs to the queue head, not to the requester. If the head is a writer, the flag lets it spin through a writer/NULL owner transition rather than sleeping again; with a reader owner it still has to wait for the readers to drain. If the head is a reader, a queued reader can set the bit in `rwsem_mark_wake()` when it observes a writer-owned count and its deadline has expired; the reader is then granted the next reader phase when the writer releases. The `handoff_set` field is therefore a per-head flag, not a per-requester flag.

```text
handoff timeline: head writer
=============================

reader phase:   R1  R2  R3        (writer W1 queued as head)
                                  W2 queued behind W1
time ----------------------------------------------------------------->

W1 deadline expires while readers still own count:
    W1: rwsem_try_write_lock()
        count has LOCK_MASK -> cannot acquire
        new |= HANDOFF; first(W1)->handoff_set = true
        return false
        (on the next loop W1 may spin only on a writer/NULL owner;
         with reader owners it sleeps until they drain)

new readers:
    fast path sees HANDOFF -> fail; they do not steal

readers drain:
    up_read() sees count == WAITERS|HANDOFF -> rwsem_wake()
    head W1 is woken; W1 rechecks count
    W1 CAS: installs WRITER, clears HANDOFF, removes itself
    new readers now see WRITER and wait

If W2 is the one whose deadline expires, the code still marks W1,
the head, as handoff_set. W2 does not jump over W1.
```

A reader-owned head uses the same bit in the opposite direction: the reader records the handoff while a writer owns the count, and the next writer release wakes the reader phase instead of handing the lock to another writer.

### 7.4 Preventing Writer Starvation

Without a fairness mechanism, a continuous stream of readers could keep the reader count above zero forever. Each reader would arrive, add its bias, and leave; a writer waiting for the count to reach zero would never see the zero state. The `WAITERS` bit and the handoff bit prevent that:

- A queued writer sets `WAITERS`, which makes new readers fail the fast path.
- New readers normally queue behind the writer instead of stealing.
- If readers are already active, they eventually drain because new readers cannot join indefinitely.
- If a writer has waited past the timeout, the handoff bit prevents new readers from stealing at all.
- Optimistic reader stealing is bounded by the reader-owned/`rcnt > 1` rule, so a single reader cannot be used as a bridge for an endless stream.

The result is not a hard real-time guarantee. A reader that holds the lock for a long time still delays the writer; that is the nature of a reader-writer lock. The guarantee is that a writer is not indefinitely postponed by a sequence of short reader critical sections.

### 7.5 What Happens When a Writer Is Waiting and a New Reader Arrives

This is the question that most often exposes a misunderstanding of the primitive. The short answer is: **the new reader normally queues behind the writer.** The `WAITERS` bit is set once the writer is queued, so the reader's fast-path add ends with a failed flag test. In the slow path, the reader sees that the lock is reader-owned and that more than one reader is present, and it goes to the queue rather than stealing. In that normal case, it does not get to jump ahead of the writer that is already waiting.

There is a narrow exception worth understanding. If the writer is queued but no reader currently owns the lock, a new reader may still steal the lock in the slow path before the writer is scheduled to run. The reader's temporary bias makes the reader population one; the `rcnt > 1` guard does not trigger because there is no second active reader; and the handoff bit may not yet be set. That reader will release the lock quickly, and the writer remains at the head of the queue. The exception does not create a stream: a second reader arriving while the first is active sees `rcnt > 1` and queues. Once the handoff bit is set, even the single-reader steal is blocked.

So the precise statement is: a waiting writer is protected by `WAITERS` and `HANDOFF`; a new reader does not normally bypass it, and the one-reader race is bounded. If you need a strict guarantee that no reader can ever acquire after a writer starts waiting, `rw_semaphore` is not that primitive. Its contract is fairness and progress, not strict FIFO.

### 7.6 Preventing Reader Starvation

Readers can also be starved if writers keep acquiring the lock one after another. The queue prevents that in the normal case: once a reader reaches the head, it is eligible to be woken, readers in that reader phase are batched, and a queued writer behind the reader cannot jump ahead. An unqueued optimistic writer can still steal the count before the reader phase is actually granted; the reader-side handoff mechanism, described below, is what bounds that race.

The handoff bit can also be set in the reader's favor. A queued reader at the head can set it from `rwsem_mark_wake()` if a writer steals the lock between the reader's eligibility check and the wake attempt: `rwsem_mark_wake()` adds the temporary reader bias, observes the writer bit, and, if the head reader's deadline has expired, records `HANDOFF` and backs the bias out. The next unlock then treats the reader as the handoff owner and wakes a reader phase rather than continuing to let writers take the lock. This is the same mechanism used for a starved writer, applied to the reader at the head of the queue.

The batching limit has a fairness cost: a batch of 256 readers can delay a writer behind them. That is intentional. The alternative — waking one reader at a time and repeatedly rechecking the queue — would make reader-heavy workloads much slower without providing a stronger guarantee, because the writer would still have to wait for the readers that are already in the batch.

### 7.7 Where Fairness Is Deliberately Relaxed

`rw_semaphore` is not a strict FIFO lock. Several design choices relax ordering in exchange for throughput:

- A reader can steal the lock in the slow path if no writer or handoff is present and the earlier reader-owned/`rcnt > 1` guard did not send it to the queue. This is **reader optimistic lock stealing**.
- A writer can steal the lock during optimistic spinning before it ever queues. `rwsem_try_write_lock_unqueued()` only requires that no current holder and no handoff bit are present, so an unqueued spinner can acquire even while `WAITERS` is set. That is a deliberate throughput optimization, and it can delay the queued head. The handoff bit is what stops it once the queue head has been waiting long enough.
- Adjacent readers are batched, so the queue is not serviced one waiter at a time.
- The handoff bit belongs to the queue head. A non-head waiter does not inherit it and cannot use another waiter's request to jump the queue.
- The handoff timeout is a soft threshold, not a hard deadline.

These choices are safe because the lock still provides mutual exclusion and because the waiters bit and handoff bit bound the worst cases. They are not safe to model as a strict priority queue. If a driver needs strict ordering, it should add its own sequence numbers or use a different synchronization design.

---

## 8. Optimistic Spinning

### 8.1 Does `rw_semaphore` Spin Like a Mutex?

Yes, but only partly. On a non-RT kernel with `CONFIG_RWSEM_SPIN_ON_OWNER`, a writer that finds the lock held may spin optimistically before it queues. The spin is not a blind `while (locked)` loop. It uses an **optimistic spin queue** (`osq`) to serialize spinners, and it checks whether the owner is actually running. If a writer owner is not on a CPU, or if the current task needs to reschedule, the spinner stops and sleeps. If the owner is a reader or the owner hint is stale, the spin is bounded by the reader-specific time threshold instead.

Readers do not spin on the owner in the same way. A reader that fails the fast path may perform **reader lock stealing** in the slow path, which is a single optimistic acquisition attempt rather than a sustained spin. The distinction matters: writer spinning reduces the latency of handing the lock from a running writer to a waiting writer; reader stealing reduces unnecessary queueing when the lock is momentarily free.

The feature is controlled by `CONFIG_RWSEM_SPIN_ON_OWNER`, which is `def_bool y` when `SMP && ARCH_SUPPORTS_ATOMIC_RMW` (see [`kernel/Kconfig.locks`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/Kconfig.locks#L231-L237)). AArch64 selects `ARCH_SUPPORTS_ATOMIC_RMW`, so the default AArch64 SMP kernel has it enabled. `PREEMPT_RT` does not use this implementation at all; it uses the `rt_mutex`-based `rwbase` code.

### 8.2 The Optimistic Spin Queue

The `osq` is a compact MCS-style queue. Each CPU has a per-CPU `struct optimistic_spin_node` containing a `locked` flag, a `next` pointer, and a `prev` pointer. The queue tail is a single `atomic_t tail` embedded in the lock. The public type is in [`include/linux/osq_lock.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/osq_lock.h#L8-L21), and the implementation is in [`kernel/locking/osq_lock.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/osq_lock.c#L1-L234).

The point of the queue is to avoid having every writer spinner issue atomic operations on the same owner cache line. A spinner enqueues its per-CPU node and then waits for its own `locked` field to be set by its predecessor. Only the head of the queue is allowed to look at the lock. This is the same idea as a queued spinlock, but it is used only for optimistic spinning: the queue node can be abandoned if the spinner decides to sleep, and `osq_lock()` returns `false` when it loses that race.

```text
optimistic spin queue (osq)
===========================

  sem->osq.tail
       |
       v
  +---------+      +---------+      +---------+
  | node W3 |<---- | node W2 |<---- | node W1 |  (head)
  | (newest)| next |         | next |         |
  +---------+      +---------+      +---------+
       |                |                |
       +--- prev -------+--- prev -------+
                                        |
                                        v
                              spin on sem->count / owner

  W1 is allowed to look at the lock.
  W2 waits until W1's unlock sets W2->locked.
  W3 waits until W2's unlock sets W3->locked.
  A node that gives up unlinks itself and returns false from osq_lock().
```

`osq_lock()` uses `smp_cond_load_relaxed()` to wait on the node's `locked` field. On AArch64, the conditional-load helper is built from `__cmpwait_relaxed()`, which emits `sevl`, `wfe`, `ldxr`, and `wfe` (see [`arch/arm64/include/asm/cmpxchg.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/cmpxchg.h#L213-L234)). The `wfe` puts the CPU into a low-power wait state until an event or a store to the monitored location. The `sev` in the unlock path and the store itself provide the event.

`osq_unlock()` pops the spinner from the queue and wakes the next node. It does not touch the rwsem count. The actual lock acquisition is still performed by the rwsem code with an atomic compare-and-swap on `count`.

### 8.3 Writer Spinning on the Owner

The writer's optimistic spin is implemented by `rwsem_optimistic_spin()` and its helpers in [`kernel/locking/rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwsem.c#L692-L956). The high-level loop is:

```text
if (!rwsem_can_spin_on_owner(sem))
    return false;

if (!osq_lock(&sem->osq))
    return false;

for (;;) {
    state = rwsem_spin_on_owner(sem);
    if (state == OWNER_NONSPINNABLE)
        break;

    if (rwsem_try_write_lock_unqueued(sem)) {
        taken = true;
        break;
    }

    if (state == OWNER_READER) {
        if (previous state was not OWNER_READER)
            start/refresh the reader spin threshold;
        else if (threshold expired) {
            rwsem_set_nonspinnable(sem);
            break;
        }
    }

    if (state != OWNER_WRITER) {
        if (need_resched())
            break;
        if (rt_or_dl_task(current) && previous != OWNER_WRITER)
            break;
    }

    previous = state;
    cpu_relax();
}

osq_unlock(&sem->osq);
return taken;
```

The order matters: the spinner samples the owner state first, then attempts an unqueued acquisition, then applies the reader threshold and the scheduling checks. The previous-owner state is carried from one iteration to the next so an RT task gets exactly one extra look at a writer that has just released the lock.

The important checks are:

- **Is the lock worth spinning on?** `rwsem_can_spin_on_owner()` rejects the spin if the lock is marked `RWSEM_NONSPINNABLE`, if the current task needs to reschedule, or if a *writer* owner is not currently on a CPU. A reader-owned hint is not checked against `owner_on_cpu()` because that hint may be stale; the reader is handled by the separate time threshold.
- **Can the writer acquire without queuing?** `rwsem_try_write_lock_unqueued()` attempts a compare-and-swap from a count with no lock holder and no handoff bit to the writer-owned state. It may leave the `WAITERS` flag set, so it can acquire in front of queued waiters while the queue head has not yet been granted. If a reader is present, the loop waits for the reader population to change.
- **Is the owner still running?** `rwsem_spin_on_owner()` samples the owner. If the state is not `OWNER_WRITER`, it returns `OWNER_NULL`, `OWNER_READER`, or `OWNER_NONSPINNABLE` immediately. For a writer owner it loops until the owner changes, the owner leaves the CPU, or the task needs to reschedule. Spinning against a sleeping writer is pointless and wastes CPU.
- **Should the spinner yield?** `cpu_relax()` on AArch64 is `yield` (see [`arch/arm64/include/asm/vdso/processor.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/vdso/processor.h#L10-L13)), not a no-op. It is a hint to the CPU that the core is in a spin loop.

The owner pointer is read without a lock. It can be stale, which is why the spin code re-reads the count after every owner check. A stale owner only affects the decision to keep spinning; it cannot cause an incorrect acquisition, because the final acquisition is a compare-and-swap on `count`.

### 8.4 Reader-Owned Locks and the Spin Threshold

A writer can also spin while readers own the lock. The readers may be about to release it, so a short spin can avoid a sleep. But spinning on readers is less predictable than spinning on a writer: readers may be preempted, may take page faults, or may hold the lock for a long time. The implementation therefore uses a time threshold.

The threshold is computed in `rwsem_rspin_threshold()` from the current reader count. The formula is approximately `(20 + readers) / 2` microseconds, capped at 25 microseconds, with the reader count capped at 30 for the calculation. In practical terms, a writer spins for roughly 10 to 25 microseconds against readers, then gives up and queues. The exact code is in [`kernel/locking/rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwsem.c#L827-L838).

When the threshold is exceeded, the writer sets `RWSEM_NONSPINNABLE` in the owner word. The bit tells future spinners not to repeat the same futile spin. It is cleared when the code observes that no lock holder remains (for example, the last reader's `up_read()` reaches the waiters-only count). At that point the next owner is a writer or the lock is free, and spinning may be useful again.

This is a key difference from a mutex. A mutex spins on a single owner and can use a simple owner-on-CPU check. An rwsem writer may be spinning on a group of readers whose remaining hold time is unknown, so it needs a bounded trial period and a way to remember that the trial failed.

### 8.5 Reader Lock Stealing

Reader lock stealing happens in `rwsem_down_read_slowpath()`. The reader has already added its bias. If the count shows no writer and no handoff, and the earlier reader-owned/`rcnt > 1` guard did not send it to the queue, the reader can keep the bias and return as a lock owner. This avoids a sleep and a wakeup when the fast path lost a race but the lock is actually free.

The code deliberately restricts stealing when the lock is reader-owned and more than one reader is present. The comment explains the reason: without that restriction, a continuous stream of readers could each steal the lock from a writer that is waiting for the reader count to reach zero. The `rcnt > 1` check makes the lock behave as if it is "probably reader-owned" and sends new readers to the queue, where the writer is ahead of them.

The handoff bit is the second restriction. If a waiter has requested a handoff, the reader sees `RWSEM_FLAG_HANDOFF` and does not steal. This is what turns the soft fairness mechanism into a usable anti-starvation guarantee.

Reader stealing is not a spin. It is a single attempt made while the count is already in a register. If it fails, the reader queues. There is no `osq` involvement and no `need_resched()` loop.

### 8.6 Real-Time Tasks and Disabled Spinning

Real-time and deadline tasks have additional restrictions, but the restriction is not a blanket "never spin on a non-RT owner." The actual rules in [`kernel/locking/rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwsem.c#L728-L753) and [`kernel/locking/rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwsem.c#L904-L950) are:

- `rwsem_can_spin_on_owner()` still allows a running writer owner regardless of the owner's scheduling class, provided the owner is on a CPU.
- In the spin loop, an RT/DL task stops when the owner state is not `OWNER_WRITER` and the previous state was not `OWNER_WRITER`. This gives it one extra observation of a writer that has just released the lock, while avoiding an unbounded spin on a NULL or reader-owned state.
- If the owner is a writer, the `need_resched()` and owner-on-CPU checks inside `rwsem_spin_on_owner()` bound the spin.
- `CONFIG_PREEMPT_RT` replaces the whole implementation with `rt_mutex`-based code, where priority inheritance is the mechanism that bounds inversion rather than optimistic spinning.

The practical result is that an RT task may briefly spin on a running writer, including a non-RT writer, because the writer is expected to release soon. It does not spin indefinitely on absent, reader-owned, or nonspinnable states. The implementation does not attempt to compare the spinner's priority with the owner's priority; it relies on the owner-on-CPU and state-transition checks.

If `CONFIG_RWSEM_SPIN_ON_OWNER` is disabled, the writer goes straight to the queue after the fast-path CAS fails. The rest of the algorithm still works; it simply loses the latency benefit of spinning. The count encoding, fairness, and handoff logic are unchanged.

---

## 9. Memory Ordering on AArch64

### 9.1 The Acquire/Release Contract

The lock's correctness rests on the core atomic operations and the ordering they provide:

| Operation | Atomic primitive | Ordering | Purpose |
|-----------|------------------|----------|---------|
| Reader acquire | `atomic_long_add_return_acquire(+0x100)` | Acquire | Pairs with a prior release; makes the reader see the previous owner's stores |
| Reader release | `atomic_long_add_return_release(-0x100)` | Release | Publishes the reader's stores before the count drops |
| Writer acquire | `atomic_long_try_cmpxchg_acquire(0 -> 1)` | Acquire | Pairs with the previous release |
| Writer release | `atomic_long_fetch_add_release(-1)` | Release | Publishes the writer's stores before the writer bit clears |
| Downgrade | `atomic_long_fetch_add_release(-1 + 0x100)` | Release | Publishes the writer's stores and converts to reader in one step |
| Wait-list update | `raw_spin_lock_irq()` / `raw_spin_lock_irqsave()` | Acquire/release | Serializes the queue and the flag bits |

The acquire operation is not a full barrier in the `DMB ISH` sense. It is an acquire on the count location: a later load or store in the critical section cannot be reordered before it, but unrelated stores can still move. The release operation is the mirror image. This is exactly the ordering a lock needs. A reader that acquires after a writer releases is guaranteed to see the writer's protected stores; a reader that releases before another reader acquires is guaranteed to have its stores visible to that reader.

The `up_read()` and `up_write()` operations use release ordering, not a full barrier. The `down_read()` and `down_write()` operations use acquire ordering. The wait-lock operations use the architecture's spinlock barriers, which are stronger because they protect the queue and the count updates that happen under the lock.

```text
release/acquire handoff on AArch64
=================================

CPU 0 (previous writer)                 CPU 1 (next reader or writer)
------------------------                 ----------------------------
  protected store  A
  protected store  B
        |
        v
  STLR / LDADDL / CASL              (release)
  count = free                              LDAR / LDADDA / CASA
                                             (acquire)
                                                  |
                                                  v
                                            protected load  A
                                            protected load  B

  The release orders A,B before the count update.
  The acquire orders the count update before the later loads.
  The count value is the synchronization point; the owner hint is not.
```

### 9.2 Atomics: LSE Versus Load-Exclusive/Store-Exclusive

AArch64 can implement the 64-bit atomic operations in two ways:

- **LSE** (Large System Extensions, Armv8.1) provides single-instruction atomics such as `LDADD`, `LDCLR`, `LDSET`, and `CAS`. The kernel selects them at runtime when the CPU supports them.
- **LL/SC** (load-exclusive/store-exclusive) uses `LDAXR`/`STLXR` loops. It is the fallback on older CPUs and on CPUs where LSE is not enabled.

The selection is made by `__lse_ll_sc_body()` in [`arch/arm64/include/asm/lse.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/lse.h#L17-L26), which uses an alternative patched at boot based on the `ARM64_HAS_LSE_ATOMICS` capability. The LSE implementations are in [`arch/arm64/include/asm/atomic_lse.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/atomic_lse.h#L40-L280), and the LL/SC implementations are in [`arch/arm64/include/asm/atomic_ll_sc.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/atomic_ll_sc.h#L150-L240).

For the rwsem count, the relevant LSE instructions are:

- `LDADDA` for an add with acquire semantics. The reader acquire is an add-return, so the LSE sequence uses the fetch-add form, which returns the old count in one instruction while adding the reader bias.
- `LDADDL` for an add with release semantics. The reader and writer releases use this form.
- `CASA`, `CASL`, and `CASAL` for compare-and-swap with acquire, release, and full ordering. The writer fast path uses the acquire form.
- `LDADDAL` when a full acquire-release add is needed. The rwsem code uses the weaker acquire or release forms where the lock contract allows it.

The LL/SC fallback is not a simple load/store pair. It uses an exclusive load, a computation, and an exclusive store; if the store fails because another CPU touched the line, the loop retries. On AArch64, the exclusive load/store instructions themselves carry the acquire/release semantics (`LDAXR`/`STLXR`), and the kernel adds barriers where a particular operation needs more than the instruction provides. The implementation is carefully written so that the fallback and the LSE path have the same observable ordering.

The takeaway for a kernel programmer is not to memorize the instruction names. It is to remember that the rwsem count operations provide the acquire/release ordering the lock contract requires; weakening them to relaxed atomics would break the lock, even if the count arithmetic happened to look correct.

### 9.3 Barriers and Instructions

The AArch64 barrier vocabulary used by this code is small:

- **`DMB ISH`** is a full memory barrier for the inner-shareable domain. In Linux it is `smp_mb()`. It orders all loads and stores before the barrier against all loads and stores after it.
- **`LDAR`** is a load with acquire semantics. It orders later accesses after the load.
- **`STLR`** is a store with release semantics. It orders earlier accesses before the store.
- **`LDAPR`** is a load with RCpc acquire semantics. Linux uses it for some `smp_load_acquire()` cases where the weaker ordering is sufficient, but the rwsem count uses the stronger RCsc atomics.
- **`DMB ISHLD`** is a load-load/load-store barrier used for `smp_rmb()` in some paths.
- **`ISB`** is an instruction synchronization barrier, used after writing system registers or patching instructions, not in the rwsem fast path.

The qspinlock acquire path uses `smp_mb__after_spinlock()` on AArch64, which is defined as `smp_mb()` (see [`arch/arm64/include/asm/spinlock.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/spinlock.h#L10-L14)). This is the full `DMB ISH` after the lock is acquired. The unlock path uses a release store. The asymmetry is intentional: the acquire side must prevent later accesses from moving before the lock is held; the release side must prevent earlier accesses from moving after the unlock.

The `smp_mb()` definition is in [`arch/arm64/include/asm/barrier.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/barrier.h#L126-L128). The file also defines `sev()` and `wfe()` for the wait/wake instructions.

### 9.4 The Wait Lock and Queued Spinlock

`wait_lock` is a `raw_spinlock_t`. On AArch64 SMP it is an `arch_spinlock_t` backed by the generic **queued spinlock** (`qspinlock`) because AArch64 selects `ARCH_USE_QUEUED_SPINLOCKS`. The qspinlock type is in [`include/asm-generic/qspinlock_types.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/include/asm-generic/qspinlock_types.h#L14-L94), and the AArch64 spinlock header pulls it in through `asm/qspinlock.h` (see [`arch/arm64/include/asm/spinlock.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/spinlock.h#L1-L14)).

The qspinlock is a 32-bit word with a locked byte, a pending byte, and a tail index. Under contention, waiters form an MCS queue using a per-CPU node. The waiter at the head spins on its own node, and the previous owner hands the lock to it. This avoids the cache-line bouncing of a simple test-and-set spinlock. The rwsem uses it only for the slow path, so the queue is short in the common case.

The rwsem code takes `wait_lock` with interrupts disabled. In the reader and writer slow paths it uses `raw_spin_lock_irq()` because those paths run in process context with interrupts enabled and only need the queue lock for a short critical section. In `up_read()` and `up_write()` it uses `raw_spin_lock_irqsave()` so the wake path can be called from contexts that already have interrupts disabled. The exact choice depends on the call site; the invariant is that the lock is held only for the queue and count bookkeeping, never while sleeping.

### 9.5 WFE, SEV, and `yield`

AArch64 has two different waiting mechanisms in this code, and they are easy to confuse:

- **`WFE`/`SEV`** are used by the queued spinlock and the optimistic spin queue. `WFE` waits for an event; `SEV` sends an event to all CPUs. The `__cmpwait_relaxed()` helper emits `sevl` to prime the event register, `wfe` to wait, a load-exclusive to check the value, and another `wfe` if the value has not changed. This is a low-power spin.
- **`yield`** is used by `cpu_relax()`. It is a hint that the current CPU is in a spin loop and can give up execution resources to another hardware thread. It is not a sleep and does not guarantee that another task runs.

The writer's optimistic spin calls `cpu_relax()` between owner checks. The `osq` wait uses the conditional-load path with `WFE`. The qspinlock uses its own MCS wait loop with `WFE`/`SEV`. All three are bounded by the surrounding logic: the spinner checks `need_resched()`, the owner state, and the lock count.

### 9.6 Ordering of the Owner Hint

The owner field is written with `atomic_long_set()` and read with `atomic_long_read()` without a lock. It is not the synchronization point for the lock. The count's acquire/release operations are. This means a spinner can observe an owner pointer that is stale, miss a new owner until the next sample, or observe an owner before the count is visible, and still be correct because the final acquisition is a compare-and-swap on the count.

The owner field is nevertheless written in the right order relative to the count. On the writer path, the count CAS succeeds first, then the owner is set. On the reader path, the count add succeeds first, then the reader owner is set. The owner is cleared before the release subtraction in `__up_read()` and `__up_write()`; for readers, that clear is compiled in only when debugging or hung-task detection is enabled. A spinner therefore does not normally chase a task that is already leaving the lock. These orderings are performance optimizations, not correctness requirements; the count is the source of truth.

The `RWSEM_NONSPINNABLE` bit is set and cleared with atomic read-modify-write operations (`atomic_long_try_cmpxchg()` and `atomic_long_andnot()`), not with a plain store. It is still only a hint: it can be observed late, and the worst case is that a spinner wastes a few microseconds repeating a spin that another CPU has already marked futile.

---

## 10. Recursion, Upgrade, and Downgrade

### 10.1 Recursive Read Acquisition

A task that already holds a read lock and calls `down_read()` again will increment the reader count a second time. If no writer is waiting and no handoff is set, the second acquisition succeeds. The task now holds two read references and must call `up_read()` twice. This looks like recursion, but it is not a supported design pattern.

The danger is a waiting writer. Suppose task A holds one read reference and calls `down_read()` again while a writer is queued. The second acquisition sees `WAITERS` and cannot use the fast path. The slow path sees that the lock is reader-owned and that the reader population is greater than one, so it queues. The writer is ahead of A in the queue. A now waits for the writer, but the writer cannot acquire until A releases its first read reference. A cannot release because it is asleep waiting for the second reference. That is a self-deadlock.

Lockdep is not a reliable detector of a pure double read. `rwsem_acquire_read()` is implemented as a *shared* acquisition, not as lockdep's special recursive-read mode (see [`include/linux/lockdep.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/lockdep.h#L513-L541)), so a second `down_read()` can look like an ordinary shared acquisition to lockdep. Lockdep is more likely to catch the dangerous combinations: a read acquisition followed by a write acquisition of the same instance, or a write followed by a read. `down_read_nested()` is not a fix; it is for different lock instances of the same class, not for re-acquiring the same instance. The safe rule is: **do not recursively acquire the same `rw_semaphore` for read.** If a function needs to be callable both with and without the lock, pass an explicit "already locked" flag or split the locked and unlocked helpers.

### 10.2 Recursive Write Acquisition

A task that holds the write lock and calls `down_write()` again will self-deadlock. The writer bit is already set, so the second acquisition cannot succeed. It enters the slow path, queues behind itself, and waits for the first acquisition to release. The first acquisition cannot release because the task is asleep. There is no recursive writer mode.

The same applies to a write lock followed by a read lock: `down_read()` while holding `down_write()` sees the writer bit, queues, and waits for the writer (itself) to release. A writer that needs to read protected data should simply read it while holding the write lock; it does not need a nested read acquisition.

### 10.3 Read-to-Write Upgrade Deadlocks

There is no upgrade operation. A task cannot convert a read lock into a write lock while holding the read lock. The naive attempt is:

```c
down_read(&sem);
/* ... read ... */
down_write(&sem);   /* deadlock */
```

The writer acquisition waits for the reader count to reach zero. The caller is one of the readers, so the count cannot reach zero until the caller releases. The caller cannot release because it is blocked in `down_write()`. Even if the caller is the only reader, the deadlock still occurs: the writer waits for the reader, and the reader is the writer.

The correct patterns are:

1. Drop the read lock, acquire the write lock, and revalidate the state. This is what filesystems do when a read-only lookup discovers that it needs to modify something. The state may have changed while the lock was dropped, so the code must recheck.
2. Start with the write lock if the operation is known to need exclusive access.
3. Use `downgrade_write()` when the operation starts with a write lock and later only needs read access.

### 10.4 `downgrade_write()`

`downgrade_write()` converts an exclusive write lock into a shared read lock without ever releasing the lock. It is the only supported direction of conversion. The implementation is a single release fetch-add that subtracts the writer bit and adds one reader bias:

```c
down_write(&sem);

/* Modify the protected state. */
state->value = new_value;

/*
 * The expensive modification is done. Keep the lock, but allow other
 * readers to join and exclude new writers.
 */
downgrade_write(&sem);

/* Read-only follow-up. New writers cannot enter. */
consume(state->value);

up_read(&sem);
```

The operation is atomic with respect to other lock users: there is no window in which the count is zero, so a writer cannot sneak in between the write unlock and the read acquire. The downgrader becomes one of the readers, and the lock remains held in shared mode until `up_read()`.

`downgrade_write()` never grants the lock to a writer, because the downgrader is still a reader. If a writer is at the head of the queue, the downgrade wake path wakes nobody; the writer must wait until the downgrader calls `up_read()`. If a reader is at the head, the wake mode is `RWSEM_WAKE_READ_OWNED`, and the count arithmetic is `-RWSEM_WRITER_LOCKED + RWSEM_READER_BIAS`.

The function must be called by the task that holds the write lock. It cannot fail. It does not sleep. It is useful when a write-side operation has a long read-only tail: holding the write lock would block all readers, while dropping the lock and reacquiring it for read would allow a writer to interleave and invalidate the state.

A non-RT module that prints the count through write, read, and downgrade transitions:

```c
#include <linux/atomic.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/rwsem.h>
#include <linux/slab.h>

MODULE_LICENSE("GPL");

static struct rw_semaphore *demo_sem;

static void show_count(const char *step)
{
    pr_info("%-20s count=0x%lx\n", step,
            (unsigned long)atomic_long_read(&demo_sem->count));
}

static int __init demo_init(void)
{
    demo_sem = kmalloc(sizeof(*demo_sem), GFP_KERNEL);
    if (!demo_sem)
        return -ENOMEM;

    init_rwsem(demo_sem);

    show_count("init");
    down_write(demo_sem);
    show_count("down_write");
    up_write(demo_sem);
    show_count("up_write");

    down_read(demo_sem);
    show_count("down_read");
    up_read(demo_sem);
    show_count("up_read");

    down_write(demo_sem);
    show_count("down_write");
    downgrade_write(demo_sem);
    show_count("downgrade_write");
    up_read(demo_sem);
    show_count("up_read");

    return 0;
}

static void __exit demo_exit(void)
{
    kfree(demo_sem);
    demo_sem = NULL;
}

module_init(demo_init);
module_exit(demo_exit);
```

The count sequence is `0x0`, `0x1`, `0x0`, `0x100`, `0x0`, `0x1`, `0x100`, `0x0`.

A real example is `mmap_write_downgrade()` in [`include/linux/mmap_lock.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/mmap_lock.h#L590-L595), which converts the mmap write lock to a read lock after a VMA modification. The directory-iteration path in [`fs/readdir.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/fs/readdir.c#L33-L71) is entered with the inode's `i_rwsem` held for read; `wrap_directory_iterator()` drops that read lock, takes the write lock, revalidates the directory, and downgrades back to read before returning.

### 10.5 Lockdep and Nested Subclasses

Lockdep distinguishes read and write acquisitions and tracks the order in which lock classes are taken. The nested interfaces pass a subclass so lockdep can model a deliberate order between two locks of the same class:

```c
down_write_nested(&outer->lock, SINGLE_DEPTH_NESTING);
down_write_nested(&inner->lock, SINGLE_DEPTH_NESTING + 1);
```

The subclass is a lockdep annotation, not a runtime behavior change. It does not make recursive acquisition of the same instance safe, and it does not change the count. If the two locks are the same object, the second acquisition still deadlocks.

The non-owner interface is separate from nesting. `down_read_non_owner()` and `up_read_non_owner()` bypass the normal lockdep acquisition and release annotations (they call the internal `__down_read()`/`__up_read()` directly); the acquire variant records `NULL` as the reader owner. They are used in a few kernel subsystems where a read lock is handed from one context to another. They should be treated as a specialized tool, not as a way to avoid tracking ownership.

---

## 11. Context and Sleeping Rules

### 11.1 Process Context Only

`rw_semaphore` is a sleeping lock. The kernel documentation lists it among the sleeping lock types and states that sleeping locks can only be acquired in preemptible task context (see [`Documentation/locking/locktypes.rst`](https://github.com/torvalds/linux/blob/v7.3-rc7/Documentation/locking/locktypes.rst#L26-L44)). `down_read()` and `down_write()` call `might_sleep()`, so acquiring them from an atomic context produces a warning under `CONFIG_DEBUG_ATOMIC_SLEEP` and can deadlock in a production kernel.

The rule applies to hard IRQ, softirq, tasklet, and NMI context. It also applies to any region where preemption is disabled or a spinlock is held. The lock's slow path calls `schedule()`, and scheduling while atomic is a bug.

`down_read_trylock()` and `down_write_trylock()` do not sleep, but that does not make the surrounding API interrupt-safe. The unlock path may need to wake a waiter, which takes `wait_lock` and calls into the scheduler. The kernel documentation explicitly warns that using a sleeping lock's trylock from another context requires auditing both the trylock and the unlock. For ordinary driver code, the safe rule is: acquire and release `rw_semaphore` only from process context.

```text
context matrix for the normal, non-PREEMPT_RT API
=================================================

  context                  down_read/write   trylock        up_read/up_write
  -----------------------  ---------------   ------------   ----------------
  preemptible task         yes               yes            yes
  spinlock held            NO                not safe       not safe
  preemption disabled      NO                avoid          avoid
  hard IRQ                 NO                avoid*         avoid*
  softirq / tasklet        NO                avoid*         avoid*
  NMI                      NO                NO             NO

  * The primitive can execute atomically in some configurations, but the
    unlock can wake a task. The documentation requires a full audit; this
    is not a supported general-purpose interrupt-context lock.
```


### 11.2 Sleeping While Holding the Lock

A task may sleep while holding an `rw_semaphore`. This is the main reason to use it instead of `rwlock_t`. Examples of legal operations inside a read-side or write-side critical section include:

- `copy_to_user()` or `copy_from_user()` that may fault.
- `kmalloc(GFP_KERNEL)` or `vmalloc()` that may reclaim.
- `mutex_lock()` on another sleeping lock, provided the lock order is respected.
- File I/O, waitqueue waits, and `msleep()`.
- Page faults and filesystem operations that may block.

The lock does not disable preemption after acquisition. A reader can be preempted, migrated, and resumed while holding the lock. The count is per-lock, not per-CPU, so migration is harmless. The `percpu_rw_semaphore` read side is different: it disables preemption around the per-CPU counter update, but not for the whole read-side critical section.

Sleeping while holding the lock is legal but not free. A writer that holds the lock across a long I/O wait blocks every reader. A reader that holds the lock across a long wait blocks every writer and can delay the handoff. Keep critical sections as short as the correctness requirements allow, and do not use `msleep()` in production code merely because the lock permits it.

### 11.3 Spinlocks, Interrupts, and Preemption

Do not acquire an `rw_semaphore` while holding a spinlock, a raw spinlock, or a `rwlock_t`. The spinlock disables preemption, and the rwsem acquisition may sleep. Lockdep reports this as an invalid context, and the scheduler will complain if the slow path actually sleeps.

Do not disable interrupts and then acquire an rwsem. The interrupt-disable region is atomic from the scheduler's point of view. Even if the fast path succeeds, the lock's contract is broken because a later slow path or unlock may need to wake a task.

The reverse order is also a problem: do not acquire a spinlock while holding an rwsem if the spinlock can be taken by an interrupt handler that then tries to acquire the same rwsem. The interrupt handler cannot sleep, and the rwsem holder cannot release while waiting for the spinlock. This is the classic sleeping-lock-in-atomic-context deadlock, and lockdep will usually catch it.

### 11.4 Signals, Killable Waits, and Timeouts

`down_read()` and `down_write()` wait in `TASK_UNINTERRUPTIBLE` state. A fatal signal does not wake them; the task waits until the lock is granted. This is appropriate for kernel-internal operations that must complete, but it can produce unkillable tasks if the lock is never released.

`down_read_interruptible()` waits in `TASK_INTERRUPTIBLE` and returns `-EINTR` if a signal is pending. `down_read_killable()` and `down_write_killable()` wait in `TASK_KILLABLE` and return `-EINTR` for a fatal signal. These variants are used by system calls and filesystem paths that need to honor `SIGKILL` or a signal-based interruption.

There is no `down_timeout()` for `rw_semaphore`. The `timeout` field in `struct rwsem_waiter` is a handoff deadline, not an acquisition timeout. If a caller needs a bounded wait, it must use a trylock loop with its own timeout, or a different primitive. A trylock loop should include a sleep or a `cond_resched()` to avoid burning CPU.

### 11.5 Ownership and Lifetime

The writer side has a clear owner: the task that successfully performed the compare-and-swap. `up_write()` must be called by that task. Lockdep enforces this in a debug kernel, and the owner field is used for diagnostics and spinning. Releasing a write lock from a different task is a bug even if the count arithmetic happens to work, because the owner field and lockdep state become inconsistent.

The reader side is shared. Multiple tasks can hold the lock at once, and the owner field records only the last reader as a hint. The normal `up_read()` is expected to be called by a task that holds a read reference. The `down_read_non_owner()`/`up_read_non_owner()` pair exists for the rare case where a read lock is transferred between contexts; it tells lockdep not to enforce the usual owner relationship. It does not change the count semantics.

The lock object must outlive all waiters and all critical sections. A task sleeping in `down_read()` or `down_write()` has a waiter on its own stack that points into the lock, and a task that has just been woken may not have run yet. If the lock is freed while either task can still touch it, the wake path or the unlock path will use freed memory.

There is no `rwsem_destroy()` and no self-contained lifetime protocol in the lock. Before freeing an object that contains an `rw_semaphore`, the surrounding subsystem must prove that no task is queued and no new task can call `down_*()`. A reference count, an RCU grace period, or a subsystem-wide barrier is usually required. `up_read()` and `up_write()` return after the wake queue has been processed, but "processed" means the wakeups were issued; it does **not** mean the woken tasks have run. In particular, a woken reader already owns a read reference and will eventually call `up_read()`, and a woken writer is still on the waiter list until it reacquires the lock and removes itself. Do not free the lock merely because the last unlock returned.

`mutex` destruction has a similar rule, but `rw_semaphore` has no debug `destroy` helper to catch a mistake. The safe pattern is to make the lock part of an object whose lifetime is controlled independently, and to quiesce all users before dropping the final reference.

---

## 12. `percpu_rw_semaphore`

### 12.1 Why a Per-CPU Reader Count Exists

The reader fast path of `rw_semaphore` performs an atomic read-modify-write on a single shared `count` word. That is cheap when the lock is lightly used, but on a large AArch64 system with many CPUs reading the same data, the cache line containing `count` bounces between the CPUs' L1 caches. Each reader must obtain exclusive ownership of the line to perform the add, even though readers do not conflict with one another. The result is poor scaling: adding more readers adds more coherence traffic rather than more throughput.

`percpu_rw_semaphore` removes the shared atomic from the read fast path by giving each CPU its own reader counter. A reader increments its own CPU's counter with a normal per-CPU operation, not an atomic instruction on a shared line. The writer, which is rare by assumption, pays the cost of collecting and waiting for those counters. The design is documented in [`Documentation/locking/percpu-rw-semaphore.rst`](https://github.com/torvalds/linux/blob/v7.3-rc7/Documentation/locking/percpu-rw-semaphore.rst#L1-L24) and implemented in [`kernel/locking/percpu-rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/percpu-rwsem.c#L1-L318).

The trade-off is asymmetric. Read acquisition is extremely cheap; write acquisition can be extremely expensive because it waits for an RCU grace period and for every active reader to drain. That is acceptable for locks such as the CPU hotplug lock, where readers are on every hot path and writers are rare administrative operations.

### 12.2 The Structure

The type is defined in [`include/linux/percpu-rwsem.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/percpu-rwsem.h#L13-L22):

```c
struct percpu_rw_semaphore {
    struct rcu_sync        rss;
    unsigned int __percpu  *read_count;
    struct rcuwait         writer;
    wait_queue_head_t      waiters;
    atomic_t               block;
#ifdef CONFIG_DEBUG_LOCK_ALLOC
    struct lockdep_map     dep_map;
#endif
};
```

The fields are:

- **`rss`** is an `rcu_sync` state. It tells readers whether the fast path is currently allowed and gives the writer a way to wait for pre-existing readers.
- **`read_count`** is a per-CPU unsigned integer. Each CPU increments and decrements its own copy. The writer sums all copies to decide whether readers are still active.
- **`writer`** is an `rcuwait` used by the writer to sleep until the reader counters drain.
- **`waiters`** is a wait queue for readers and writers that lose the trylock race.
- **`block`** is an atomic flag. Zero means readers may use the fast path; one means a writer is active or wants to become active.
- **`dep_map`** is the lockdep map.

The static initializer is `DEFINE_STATIC_PERCPU_RWSEM(name)`, and `DEFINE_PERCPU_RWSEM(name)` provides a non-static version. The per-CPU counter is declared next to the lock by the macro, so the lock and its counters have the same lifetime. Dynamic initialization uses `percpu_init_rwsem()`, which allocates the per-CPU counter with `alloc_percpu()` and can fail with `-ENOMEM`; `percpu_free_rwsem()` releases it. See [`include/linux/percpu-rwsem.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/percpu-rwsem.h#L30-L44) and [`kernel/locking/percpu-rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/percpu-rwsem.c#L14-L46).

| API | Purpose |
|-----|---------|
| `DEFINE_STATIC_PERCPU_RWSEM(name)` | Static lock plus static per-CPU counter |
| `DEFINE_PERCPU_RWSEM(name)` | Non-static version of the same declaration |
| `percpu_init_rwsem(sem)` | Dynamic initialization; returns `0` or `-ENOMEM` |
| `percpu_free_rwsem(sem)` | Release the per-CPU counter and RCU-sync state; only after all users are quiesced |
| `percpu_down_read(sem)` | Read acquisition; may sleep in the slow path |
| `percpu_down_read_trylock(sem)` | Non-blocking read acquisition; returns `true` / `false` |
| `percpu_down_read_freezable(sem, freeze)` | Read acquisition with freezable slow-path wait |
| `percpu_up_read(sem)` | Read release |
| `percpu_down_write(sem)` | Write acquisition; may wait for readers and a grace period |
| `percpu_up_write(sem)` | Write release |
| `percpu_is_read_locked(sem)` | Diagnostic check for active readers |
| `percpu_is_write_locked(sem)` | Diagnostic check for the writer block flag |
| `percpu_rwsem_assert_held(sem)` | Lockdep assertion that the current task holds the lock |

`percpu_free_rwsem()` does not synchronize with active users. It only releases the per-CPU allocation and the RCU-sync state, so the caller must guarantee that no reader or writer can still touch the lock.

### 12.3 The Read Fast Path

The read fast path inside `percpu_down_read_internal()` is:

```c
static inline void percpu_down_read_internal(struct percpu_rw_semaphore *sem,
                                             bool freezable)
{
    might_sleep();
    rwsem_acquire_read(&sem->dep_map, 0, 0, _RET_IP_);

    preempt_disable();
    if (likely(rcu_sync_is_idle(&sem->rss)))
        this_cpu_inc(*sem->read_count);
    else
        __percpu_down_read(sem, false, freezable);
    preempt_enable();
}
```

This is in [`include/linux/percpu-rwsem.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/percpu-rwsem.h#L48-L78). The public `percpu_down_read()` is a thin wrapper that calls this routine with `freezable = false`. The important points are:

1. **Preemption is disabled.** The reader increments the counter for the CPU it is currently on. If it migrated between the increment and the decrement, it would decrement a different CPU's counter, and the writer's sum could see a transient value that never existed. Disabling preemption pins the reader to the CPU for the duration of the counter update.
2. **The fast path is a per-CPU increment.** It is not an atomic instruction on a shared cache line. The only shared read is `rcu_sync_is_idle()`, which is a flag check.
3. **The slow path is entered when the fast-path state is not idle.** If `rss` is not idle, either because a writer is active or because the writer has just released and the RCU-sync grace period is still in progress, the reader calls `__percpu_down_read()`, which either takes a read reference in the slow path or waits in the wait queue. The slow path is also where the `block` flag is checked with acquire semantics.
4. **`might_sleep()` is still present.** Even though the fast path is non-blocking, the lock is a sleeping lock and can take the slow path. It is not legal in hard IRQ context.

The preempt-disabled region around the counter update is the RCU-sched read-side section that closes the race with the writer. The comment in the header explains the synchronization: the writer cannot both change the fast-path state and start checking counters while the reader is in that region. If the reader sees the fast-path state as idle, the writer will either see the reader's increment or wait until the reader's counter decrement is visible. Preemption is enabled again after the counter update; the lock does not disable preemption for the entire read-side critical section.

The unlock path mirrors the lock path:

```c
static inline void percpu_up_read(struct percpu_rw_semaphore *sem)
{
    rwsem_release(&sem->dep_map, _RET_IP_);

    preempt_disable();
    if (likely(rcu_sync_is_idle(&sem->rss)))
        this_cpu_dec(*sem->read_count);
    else
        __percpu_up_read(sem);
    preempt_enable();
}
```

If the fast path is still idle, the decrement is a local operation. If a writer has entered, the slow unlock path performs the memory barrier and wakes the writer when the aggregate count reaches zero. See [`kernel/locking/percpu-rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/percpu-rwsem.c#L295-L318).

### 12.4 The Write Slow Path

The writer is expensive by design. `percpu_down_write()` does the following (see [`kernel/locking/percpu-rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/percpu-rwsem.c#L227-L260)):

1. `might_sleep()` and lockdep acquisition.
2. `rcu_sync_enter(&sem->rss)` to tell readers to stop using the fast path and to wait for pre-existing RCU-sched readers.
3. Try to set `block` from zero to one with `atomic_xchg()`. This provides writer-writer exclusion. If another writer already holds it, wait in the wait queue.
4. Wait with `rcuwait_wait_event()` until `readers_active_check()` reports that the sum of all per-CPU reader counters is zero.
5. At that point the writer owns the lock. The memory barrier in `readers_active_check()` ensures the writer sees the readers' critical sections.

The unlock path is equally deliberate:

1. Clear `block` with `atomic_set_release()`.
2. Wake one waiter from the wait queue. The wake function preserves FIFO order and may wake a batch of readers until it wakes one writer.
3. Call `rcu_sync_exit()` to end the writer's RCU-sync period. Readers can return to the fast path only after the grace period completes.

```text
percpu_rw_semaphore protocol
============================

reader fast path                     writer slow path
-----------------                    -----------------
preempt_disable()
rss idle?
  yes: this_cpu_inc(read_count)
  no:  slow path

                                     rcu_sync_enter(&rss)
                                     block = 1
                                     wait read_count sum == 0
                                     writer owns CS
                                     ...
                                     block = 0 (release)
                                     wake waiters
                                     rcu_sync_exit(&rss)
preempt_enable()
```

The time axis matters at the two boundaries:

```text
reader increment                 writer stores block=1
      |                                  |
      |<---- smp_mb() in reader --------->|
      |                                  |
      |   either writer sees increment   |
      |   or reader sees block=1         |
      v                                  v
   reader CS                         writer waits for sum=0
```

The writer's `rcu_sync_enter()`/`rcu_sync_exit()` pair supplies the grace period that makes the per-CPU counters safe without a shared atomic on the read side.

The reason `block` is not simply cleared and forgotten is that a new reader could otherwise miss the writer's critical-section stores. Forcing new readers through the slow path for one grace period guarantees that they perform an acquire that is ordered after the writer's release. That is the cost the design accepts: a write is not just a lock acquisition, it is a synchronization point with the entire machine.

### 12.5 Memory Ordering and RCU Synchronization

The per-CPU design relies on four ordering edges:

- **A**: the reader's increment and the writer's store of `block` are ordered by `smp_mb()` in `__percpu_down_read_trylock()`.
- **B/C**: the reader's slow-path decrement and the writer's `readers_active_check()` are ordered so that if the writer sees a zero sum, it also sees the reader's critical-section stores.
- **D**: the writer's `atomic_xchg()` of `block` is ordered with the reader's `atomic_read_acquire()`.
- **The RCU-sched grace period** ensures that a reader that entered before `rcu_sync_enter()` has left before the writer proceeds.

These edges are documented in the comments in [`kernel/locking/percpu-rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/percpu-rwsem.c#L48-L82) and [`kernel/locking/percpu-rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/percpu-rwsem.c#L204-L225). They are the reason the read fast path can be a plain per-CPU increment: the writer's slow path supplies the ordering that a shared atomic would otherwise provide.

On AArch64, `smp_mb()` is `DMB ISH`, `atomic_read_acquire()` is an acquire load, and `atomic_set_release()` is a release store. The per-CPU increment and decrement are ordinary loads and stores to a CPU-local variable; the barriers around the slow path are what make them visible to the writer's aggregate check.

### 12.6 When to Use It

Use `percpu_rw_semaphore` when all of the following are true:

- The read side is extremely hot and scales with CPU count.
- Writers are rare.
- Writer latency can tolerate an RCU grace period, potentially hundreds of milliseconds on a busy system.
- Readers run in process context; the fast path briefly disables preemption around the per-CPU counter update.
- The lock can be initialized dynamically if it is embedded in a heap object, and the initialization failure can be handled.

Do not use it when writers are frequent, when writer latency matters, or when the read-side critical section is so short that the per-CPU bookkeeping is not worth it. For a lock that is read-mostly but still has millisecond-scale writer requirements, a normal `rw_semaphore` is usually the better choice. For pointer traversal that does not need to sleep, RCU is usually better still.

### 12.7 Real Users

The classic user is the CPU hotplug lock in [`kernel/cpu.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/cpu.c#L484-L514). `cpus_read_lock()` and `cpus_write_lock()` wrap `percpu_down_read()` and `percpu_down_write()`. The read side is taken by code that needs a stable CPU mask; the write side is taken by CPU online/offline operations, which are rare and can afford to wait.

Other examples include:

- `mem_hotplug_lock` in [`mm/memory_hotplug.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/mm/memory_hotplug.c#L211-L270), protecting memory hotplug state.
- `file_rwsem` in [`fs/locks.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/fs/locks.c#L130-L140), protecting the global file-lock lists.
- `cgroup_threadgroup_rwsem` in [`kernel/cgroup/cgroup.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/cgroup/cgroup.c#L104), serializing thread-group changes against cgroup moves.
- `s_writepages_rwsem` in ext4, declared in [`fs/ext4/ext4.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/fs/ext4/ext4.h#L1804) and initialized in [`fs/ext4/super.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/fs/ext4/super.c#L1240), protecting the writepages path against a rarely changing state.
- `kclist_lock` in [`fs/proc/kcore.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/fs/proc/kcore.c#L70), protecting the kcore list.
- The superblock freeze locks initialized in [`fs/super.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/fs/super.c#L357-L359).

The common pattern is a lock whose read side is on a hot path and whose write side is an administrative operation. That is exactly the workload the design targets.

---

## 13. Real-World Users on AArch64

### 13.1 `mmap_lock`

The memory-management `mmap_lock` is one of the most important `rw_semaphore` users in the kernel. It is embedded in `struct mm_struct` at [`include/linux/mm_types.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/mm_types.h#L1250):

```c
struct rw_semaphore mmap_lock;
```

The lock protects the VMA list and related address-space state. Page-fault paths take it for read; `mmap()`, `munmap()`, `mprotect()`, and other operations that modify the address space take it for write. The read side is extremely hot: every anonymous page fault, file-backed page fault, and many `get_user_pages()` paths need to walk the VMA tree. The write side is comparatively rare but may sleep.

The wrappers are in [`include/linux/mmap_lock.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/mmap_lock.h#L541-L625). `mmap_read_lock()` calls `down_read()`, `mmap_write_lock()` calls `down_write()`, and `mmap_write_downgrade()` calls `downgrade_write()`. The killable variants are used by paths that must respond to `SIGKILL`, such as the AArch64 MTE access path in [`arch/arm64/kernel/mte.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/kernel/mte.c#L455-L456). AArch64 KVM also takes the lock for read while walking the current mm's mappings, for example in [`arch/arm64/kvm/mmu.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/kvm/mmu.c#L1119-L1121).

`mmap_lock` is a good example of the size of the read side and the reason the write side uses `downgrade_write()` where possible. A fault that only needs to read the VMA can hold the read lock across a page allocation or I/O wait; a modification that needs exclusive access can downgrade to a read lock once the VMA update is complete. The lock's contention profile is one of the reasons the kernel has been moving some page-fault handling to **per-VMA locks** (`CONFIG_PER_VMA_LOCK`), which allow many faults to proceed without taking `mmap_lock` for read at all. AArch64 selects `ARCH_SUPPORTS_PER_VMA_LOCK` in [`arch/arm64/Kconfig`](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/Kconfig#L84).

### 13.2 Inode `i_rwsem`

`struct inode` contains an `i_rwsem` at [`include/linux/fs.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/fs.h#L816):

```c
struct rw_semaphore i_rwsem;
```

It serializes inode operations that modify the inode's namespace or metadata against readers that need a stable view. The read side is used by lookup, readlink, permission checks, and directory iteration. The write side is used by create, unlink, rename, link, and truncate. This is a long-held lock in some paths, and it is a sleeping lock precisely because those paths may block on I/O.

The directory-iteration path is a clean example of the read-to-write-to-read pattern. In [`fs/readdir.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/fs/readdir.c#L33-L71), `wrap_directory_iterator()` is entered with `i_rwsem` held for read. It drops that read lock, takes the write lock, revalidates the directory, and then calls `downgrade_write()` before returning. The downgrade keeps the lock held in read mode for the caller, so a subsequent read-only operation cannot race with a writer.

### 13.3 Superblock `s_umount`

The superblock's `s_umount` lock is an `rw_semaphore` at [`include/linux/fs/super_types.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/fs/super_types.h#L151). It protects mount and unmount state. Read-side users include `sync`, `statfs`, and paths that need the superblock to remain alive; write-side users include mount, remount, freeze, and unmount. The lock is taken in [`fs/super.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/fs/super.c#L60-L62) and in many filesystem-specific paths.

This is a lock where the read side is frequent but not as hot as `mmap_lock`, and the write side can involve I/O and filesystem-specific work. It is a normal `rw_semaphore`, not a per-CPU variant, because writer latency matters and the read-side contention is not the dominant scalability problem.

### 13.4 Per-CPU Reader-Writer Semaphores in Practice

The per-CPU variant appears in hot paths where a writer is a rare administrative event:

- CPU hotplug: readers check CPU masks; the writer onlines or offlines a CPU.
- Memory hotplug: readers walk memory state; the writer adds or removes memory.
- File locking: readers traverse the global lock lists; the writer changes the global state.
- Cgroup thread-group changes: readers are on fork/exit paths; the writer moves tasks between cgroups.
- Filesystem freeze: readers are normal filesystem operations; the writer freezes the filesystem.

On AArch64, the per-CPU counter is especially valuable on many-core server and mobile SoCs, where a shared reader count would otherwise bounce between clusters. The writer cost is paid during a hotplug or freeze operation, which is already a slow path.

---

## 14. Choosing the Right Primitive

### 14.1 Comparison Table

| Primitive | Waits by | Multiple readers | Multiple writers | Sleeps | IRQ-safe | Priority inheritance | Typical use |
|-----------|----------|------------------|------------------|--------|----------|----------------------|-------------|
| `rw_semaphore` | Sleeping | Yes | No | Yes | No | No | Read-mostly data with blocking readers |
| `rwlock_t` | Spinning | Yes | No | No | Yes, with care | No | Short read-mostly critical sections in atomic context |
| `mutex` | Sleeping | No | No | Yes | No | Only with `rt_mutex` | Exclusive blocking critical sections |
| `struct semaphore` | Sleeping | No (counting only) | No | Yes | Limited | No | Counting resources, producer/consumer |
| `percpu_rw_semaphore` | Sleeping | Yes, per-CPU | No | Yes | No | No | Extremely read-heavy, rare writers |
| RCU | No lock | Yes | No | No (read side) | Read side yes | N/A | Pointer traversal with reclaimable objects |
| Seqlock | Retry | Yes | No | No | Yes, with care | No | Small read-mostly data with cheap retry |

The table is a starting point, not a decision procedure. The context in which the critical section runs is the first filter: if it cannot sleep, `rw_semaphore` is out. The second filter is the ratio of readers to writers and the cost of a writer. The third is whether the read side can tolerate a shared atomic cache line.

On `PREEMPT_RT`, `spinlock_t` and `rwlock_t` become sleeping rtmutex-based locks, and `rw_semaphore` becomes the `rwbase_rt` implementation. The IRQ-safe and priority-inheritance columns therefore describe the non-RT kernel unless explicitly marked otherwise.

### 14.2 Selection Flow

```text
Does the data need shared/exclusive protection?
|
+-- No: use a mutex or a spinlock, depending on context.
|
+-- Yes: can a reader block or sleep?
    |
    +-- No: use rwlock_t (and keep the critical section short).
    |
    +-- Yes: how often do writers run?
        |
        +-- Regular writers, writer latency matters:
        |     use rw_semaphore.
        |
        +-- Extremely rare writers, readers dominate:
        |     +-- Reader section is pointer traversal and objects are RCU-safe:
        |     |     use RCU.
        |     +-- Reader section needs a real lock and writer can wait for
        |           a grace period: use percpu_rw_semaphore.
        |
        +-- Writer-heavy: use a mutex, not a reader-writer lock.
```

A few practical rules follow from the table:

- Do not use `rw_semaphore` as a general mutex replacement. If every acquisition is a writer, the reader count and the queue are pure overhead.
- Do not use `rwlock_t` for a critical section that can block. The kernel will warn, and the system can deadlock.
- Do not use RCU for a data structure that readers must modify or for an object that can be freed without a grace period.
- Do not use `percpu_rw_semaphore` when a writer must complete in microseconds. The writer may wait for a grace period.
- Do not use a seqlock for a data structure that readers cannot easily retry or that contains pointers with lifetime rules.

### 14.3 RCU, Seqlocks, and Per-VMA Locks

RCU is the strongest alternative for read-mostly pointer traversal. A reader enters `rcu_read_lock()`, dereferences the pointer, and exits; there is no atomic operation on a shared lock word. The writer publishes a new pointer and waits for a grace period before freeing the old object. RCU is not a drop-in replacement for `rw_semaphore` because the read-side critical section has restrictions and the writer must manage object lifetime. But for routing tables, VMA lookup, and many other read-mostly structures, it is faster than any reader-writer lock.

A seqlock is a good fit for a small amount of data that readers can copy and validate. The reader reads a sequence number, copies the data, reads the sequence number again, and retries if the number changed or is odd. Writers increment the sequence number before and after the update. Seqlocks avoid writer starvation and are cheap for readers, but they can spin under heavy write traffic and are not suitable for data that cannot be copied cheaply.

Per-VMA locks are a specialized form of read-mostly locking used by the memory-management subsystem. They allow a page fault to lock an individual VMA instead of taking `mmap_lock` for read, which reduces contention on the global mmap lock. The mechanism is not a general replacement for `rw_semaphore`; it is a targeted optimization for a specific data structure. It illustrates the general principle: if a global reader-writer lock is too hot, the answer may be to partition the lock rather than to make the lock faster.

---

## 15. Debugging and Observability

### 15.1 `CONFIG_DEBUG_RWSEMS`

`CONFIG_DEBUG_RWSEMS` adds a magic cookie, stronger owner checks, and count/list warnings. The warning macro is in [`kernel/locking/rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwsem.c#L68-L79):

```c
#define DEBUG_RWSEMS_WARN_ON(c, sem)                                    \
do {                                                                    \
    if (!debug_locks_silent &&                                          \
        WARN_ONCE(c, "DEBUG_RWSEMS_WARN_ON(%s): count = 0x%lx, "        \
                     "magic = 0x%lx, owner = 0x%lx, curr 0x%lx, "        \
                     "list %sempty\n", #c,                               \
                     atomic_long_read(&(sem)->count),                    \
                     (unsigned long)(sem)->magic,                        \
                     atomic_long_read(&(sem)->owner), (long)current,     \
                     rwsem_is_contended(sem) ? "" : "not "))             \
            debug_locks_off();                                           \
} while (0)
```

The warning prints the count, the magic cookie, the owner, the current task, and whether the waiter list is empty. That is enough to distinguish the common failure modes:

- A release by a task that does not own the write lock.
- A reader count that went negative because `up_read()` was called too many times.
- A lock that was used after initialization but has the wrong magic value.
- A waiter list that is empty when the count says waiters are queued, or vice versa.
- A writer that released a lock still held by readers.

The debug code also provides `rwsem_owner()` and `is_rwsem_reader_owned()` when either `CONFIG_DEBUG_RWSEMS` or `CONFIG_DETECT_HUNG_TASK_BLOCKER` is enabled. `rwsem_owner()` strips the low flag bits and returns the task pointer; `is_rwsem_reader_owned()` checks the count for the writer bit and then tests the reader-owned flag. These helpers are in [`kernel/locking/rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwsem.c#L185-L225).

The debug checks are not a complete proof of correctness. In particular, the reader owner field records only the last reader, and `up_read_non_owner()` deliberately bypasses the usual owner relationship. A missing warning does not mean the locking protocol is correct.

### 15.2 Lockdep

`CONFIG_DEBUG_LOCK_ALLOC` gives the lock a `struct lockdep_map` with the name and wait type. The initializer sets `.wait_type_inner = LD_WAIT_SLEEP` (see [`include/linux/rwsem.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/rwsem.h#L20-L28)). That tells lockdep the lock may sleep, which is what allows it to report a `down_read()` under a spinlock as an invalid nesting.

Lockdep tracks read and write acquisitions separately. It can report:

- A read-then-write or write-then-read acquisition of the same lock instance.
- A lock-order inversion between two different lock classes.
- A lock acquired in atomic context but declared as sleeping.
- A lock released by a task that does not hold it.

A pure double read is a weaker case: rwsem read acquisitions use lockdep's *shared* mode, not the special recursive-read mode, so do not assume lockdep will flag every recursive `down_read()`. The runtime deadlock described in [Recursive read acquisition](#101-recursive-read-acquisition) remains real even when lockdep is silent.

The nested interfaces (`down_read_nested()`, `down_write_nested()`) pass a subclass so lockdep can distinguish two locks of the same class. They do not change runtime behavior. `lockdep_assert_held()` and `rwsem_assert_held_write()` are assertions that help catch a caller that forgot to take the lock; they are not synchronization.

### 15.3 Atomic-Sleep and Hung-Task Diagnostics

`might_sleep()` is the first line of defense. In a kernel with `CONFIG_DEBUG_ATOMIC_SLEEP`, calling `down_read()` or `down_write()` from a region with preemption disabled, interrupts disabled, or a spinlock held produces a warning with a stack trace. The warning points at the acquisition site, which is usually enough to find the bad caller.

`CONFIG_DETECT_HUNG_TASK_BLOCKER` adds a different kind of diagnostic. When a task blocks in the reader slow path, the kernel records `BLOCKER_TYPE_RWSEM_READER`; when it blocks in the writer slow path, it records `BLOCKER_TYPE_RWSEM_WRITER`. The calls are in [`kernel/locking/rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwsem.c#L1094-L1099) and [`kernel/locking/rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwsem.c#L1183-L1187). The hung-task detector can then report not just that a task is blocked, but what kind of lock it is blocked on. The owner field helps identify the writer that is holding the lock.

This is especially useful for a writer that is sleeping while holding the lock. A reader blocked behind it may be in an uninterruptible wait, and the hung-task report will show the writer's stack and the lock address. Without the blocker annotation, the report would only show a generic schedule call.

### 15.4 Tracepoints and Performance Counters

The rwsem slow paths call `trace_contention_begin()` and `trace_contention_end()` with flags such as `LCB_F_READ` and `LCB_F_WRITE`. These tracepoints are consumed by `perf lock`, by BPF programs, and by the kernel's lock-event counters. They report contention onset and duration, not every acquisition; the fast path is intentionally not traced to keep overhead low.

The trace events are useful for answering questions such as:

- Which lock is contended, and for how long?
- Is the contention read-read, read-write, or write-write?
- Is the lock mostly spinning or mostly sleeping?
- Is the handoff mechanism firing frequently?
- Is the reader count high enough that a per-CPU variant would help?

`rwsem_is_contended()` can be used as a cheap adaptive signal inside the kernel: for example, a caller may switch to a different allocation strategy when the lock has waiters. It is a snapshot, so it should not be used as a correctness condition.

A practical debugging checklist for an rwsem problem is:

1. Confirm the context is process context and preemption is enabled.
2. Check for a read-to-write or write-to-read transition in the same task.
3. Check for a recursive acquisition of the same lock instance.
4. Check the lock order against other sleeping locks.
5. Look at the count value in a `DEBUG_RWSEMS` report.
6. Look for a writer sleeping while holding the lock.
7. Measure contention before changing the lock type.

---

## 16. Performance and Scalability

### 16.1 The Reader Cache Line

The reader fast path is one atomic add-return on a single shared cache line. On a small system this is negligible. On a large AArch64 server with many CPUs reading the same lock, the line becomes a coherence hot spot: each reader must acquire the line exclusively, modify it, and release it. The readers do not conflict semantically, but the cache-coherence protocol serializes their updates.

There are three common responses:

1. **Reduce read frequency.** Cache the protected value outside the lock where the lifetime rules allow it.
2. **Partition the lock.** Use per-CPU or per-NUMA-node state so readers touch different cache lines.
3. **Remove the reader-side atomic entirely.** Use RCU for pointer traversal or `percpu_rw_semaphore` for a real shared/exclusive lock with per-CPU read counts.

`percpu_rw_semaphore` is the kernel's built-in answer when the lock itself must remain shared/exclusive but the reader count must not bounce. It trades an expensive writer for a nearly free reader. RCU goes further and removes the reader-side lock altogether, at the cost of restricting what the reader can do and requiring the writer to manage object lifetime.

### 16.2 Writer Latency and Handoff

A writer's latency has three components:

- The time to acquire the count, either by fast-path CAS or by optimistic spin.
- The time for existing readers to drain.
- The time to wake the writer and for the writer to be scheduled.

The handoff mechanism bounds the third component in the sense that it prevents a stream of new readers from repeatedly stealing the lock and forcing the waiting writer to be woken again. It cannot make the scheduler run the writer sooner, and it cannot shorten a reader's critical section. If a reader holds the lock across a page fault or an I/O wait, the writer waits. This is why long reader critical sections are the primary latency risk in an rwsem-based design. The lock is fair, but fairness does not create progress inside a reader that is asleep.

The `RWSEM_WAIT_TIMEOUT` threshold is a soft trigger. At `HZ=1000` it is about four milliseconds, while at lower rates it is one jiffy, which can be longer. Once the handoff bit is set, new readers stop stealing and the current readers drain. The writer still has to be at the head of the queue. A writer behind another waiter cannot use the handoff bit to jump ahead.

### 16.3 Wakeup Batching

Waking readers one at a time would be expensive for two reasons. First, each wakeup would require another pass through `wait_lock` and another count update. Second, a reader that was woken alone might find that a new writer or reader had already changed the state, forcing another wake cycle. The wake path therefore batches up to `MAX_READERS_WAKEUP` (256) readers in one pass. The batch is reflected in the count before the tasks are woken, so the woken readers already own their references and do not race with one another to acquire the lock. The trade-off is a burst of wakeups and a longer reader phase, not a correctness issue.

The batch size is a trade-off. A larger batch improves reader throughput but delays a writer behind the readers. A smaller batch improves writer latency but increases wakeup overhead. The current value is a compromise that works well for the common case; it is not a tunable that a driver should override.

### 16.4 Alternatives at Scale

The right answer to a contended reader-writer lock is often not a faster reader-writer lock. Consider these alternatives before optimizing the lock itself:

- **RCU** for read-mostly pointer traversal. The read side is free, and the writer pays a grace period. This is often the best choice for routing tables, configuration snapshots, and VMA lookup.
- **Per-VMA locks** for page-fault-heavy workloads. They partition the mmap lock so that faults on different VMAs do not contend on one global reader count.
- **Per-CPU data** for counters and statistics. A per-CPU counter avoids the shared cache line entirely, at the cost of aggregation.
- **Seqlocks** for small data that readers can copy and retry.
- **Immutable snapshots** for configuration that changes rarely. Publish a new pointer, let readers use the old snapshot under RCU, and reclaim after a grace period.
- **A mutex** when writers dominate. A reader-writer lock with mostly writers is just a slower mutex.

The general principle is to match the synchronization to the access pattern, not to pick the most sophisticated lock. `rw_semaphore` is an excellent default for read-mostly data with blocking readers. It is not a universal replacement for RCU, per-CPU data, or a mutex.

---

## 17. `PREEMPT_RT` Contrast

On a `PREEMPT_RT` kernel, `rw_semaphore` is not the structure described in this document. The `#else` branch in [`include/linux/rwsem.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/rwsem.h#L149-L201) defines it as a wrapper around `struct rwbase_rt`, which contains an `rt_mutex`-based implementation. The public API remains the same; the internals and the fairness properties change.

The RT implementation uses an `rt_mutex` to provide priority inheritance and deadline inheritance. The structure is not a count word plus owner hint; it is a single `atomic_t readers` and an `rt_mutex_base`:

```c
struct rwbase_rt {
    atomic_t          readers;
    struct rt_mutex_base rtmutex;
};

#define READER_BIAS  (1U << 31)
#define WRITER_BIAS  (1U << 30)
```

```text
RT readers word
===============

  READER_BIAS (0x80000000) = the reader fast path is open
  WRITER_BIAS (0x40000000) = a writer owns the lock

  initial:       0x80000000
  N readers:     0x80000000 + N
  writer pending: 0x00000000 + N   (writer subtracts READER_BIAS)
  writer owns:   0x40000000
```

A writer takes the rtmutex, subtracts `READER_BIAS` so readers stop using the fast path, waits until the reader word reaches zero, and then installs `WRITER_BIAS`. A reader takes the fast path while the word is negative (the reader bias is set); if it is not, the reader blocks on the rtmutex slow path. There is no separate `writelocked` boolean in this structure — the `WRITER_BIAS` value is the write-locked state. The design is described in [`kernel/locking/rwbase_rt.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwbase_rt.c#L1-L50) and the type in [`include/linux/rwbase_rt.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/rwbase_rt.h#L8-L26).

The fairness trade-off is different. The RT comments explain that a writer cannot grant its priority to multiple readers, so a preempted low-priority reader can starve a high-priority writer. Conversely, a preempted low-priority writer can be boosted by readers that block behind it. The RT implementation is therefore not writer-fair in the same way as the non-RT phase-fair implementation. The kernel documentation states this directly in [`Documentation/locking/locktypes.rst`](https://github.com/torvalds/linux/blob/v7.3-rc7/Documentation/locking/locktypes.rst#L144-L155).

This document's implementation details for `rw_semaphore` — the 64-bit count encoding, the `osq`, the waiter list, and the handoff bit — apply to the non-RT kernel. On RT, use the same API and the same context rules, but do not assume the non-RT fairness or spinning behavior. `percpu_rw_semaphore` is a separate implementation and remains RCU-sync based; its timing still depends on the RT scheduler and on RCU grace periods.

---

## 18. Important Points

A condensed revision table of the facts worth remembering; the body sections contain the full explanation.

| Area | Key point |
|---|---|
| Type (non-RT) | `struct rw_semaphore`: `atomic_long_t count`, `atomic_long_t owner`, optional `struct optimistic_spin_queue osq`, `raw_spinlock_t wait_lock`, `struct rwsem_waiter *first_waiter`, plus debug magic and lockdep map; about 32 bytes without debug options. |
| Type (RT) | Same API, different implementation: `struct rwbase_rt` with `atomic_t readers` and an `rt_mutex_base`. |
| `count` layout | Bit 0 `WRITER`, bit 1 `WAITERS`, bit 2 `HANDOFF`, bits 3–7 reserved, bits 8–62 reader count, bit 63 `READFAIL`. |
| Reader bias | `0x100`; N readers contribute `N * 0x100`, and the low byte is reserved for flags. |
| Flags | `WAITERS` (`0x2`) means the waiter list is non-empty; `HANDOFF` (`0x4`) means the queue head must get the next turn; `READFAIL` (bit 63) poisons the fast path. |
| States | `0x0` unlocked, `0x1` writer, `0x2` waiters only, `0x3` writer plus waiters, `0x100` one reader, `0x102` reader plus waiters, `0x106` reader plus waiters plus handoff. |
| Stable-state rule | A writer bit never coexists with a nonzero reader count; `downgrade_write()` does both in one atomic operation so there is no free window. |
| `owner` hint | Writer task pointer, or the last reader with `RWSEM_READER_OWNED`; may also carry `RWSEM_NONSPINNABLE`. It is a hint, never the correctness mechanism. |
| Waiter | Lives on the waiting task's stack: `list`, `task`, `type`, `timeout`, `handoff_set`; the wake path clears `task` with release semantics. |
| Static init | `DECLARE_RWSEM(name)`; there is no `DEFINE_RWSEM`. |
| Dynamic init | `init_rwsem(&sem)` cannot fail; `percpu_init_rwsem()` allocates per-CPU storage and can return `-ENOMEM`. |
| Init rules | Initialize once before the lock is visible; never reinitialize a held lock or one with queued waiters. |
| Reader acquire | `atomic_long_add_return_acquire(+0x100)`; fails if `WRITER`, `WAITERS`, `HANDOFF`, or `READFAIL` is present. |
| Reader release | `atomic_long_add_return_release(-0x100)`; wakes only when no lock holder remains and `WAITERS` is set. |
| Writer acquire | `atomic_long_try_cmpxchg_acquire(0 → 0x1)`; any nonzero count fails. |
| Writer release | `atomic_long_fetch_add_release(-0x1)`; preserves concurrent reader biases and all flag bits, and wakes if `WAITERS` was set. |
| Trylock | Returns `1` on success and `0` on failure (the opposite of `down_trylock()`); it does not sleep or queue, but the unlock path may still wake a waiter. |
| Interruptible / killable | `down_read_interruptible()`, `down_read_killable()`, `down_write_killable()` return `0` or `-EINTR`; there is no `down_write_interruptible()` and no timeout variant. |
| Nested | `down_read_nested()` / `down_write_nested()` pass a lockdep subclass; they are not recursion. |
| Non-owner | `down_read_non_owner()` / `up_read_non_owner()` bypass lockdep ownership checks; they exist for specialized read-lock handoff. |
| Downgrade | `downgrade_write()` performs `fetch_add(-1 + 0x100)` with release ordering, so the write lock becomes a read lock with no unlocked instant. |
| State queries | `rwsem_is_locked()` is true even for flag-only states such as `0x2`; `rwsem_is_contended()` reads `first_waiter`; both are snapshots, not synchronization. |
| Assertions | `rwsem_assert_held()` and `rwsem_assert_held_write()` are lockdep/debug checks, not locks. |
| Fast vs slow path | Fast path is one atomic operation on `count` plus the owner hint; the slow path takes `wait_lock`, queues a stack waiter, and sleeps. |
| Reader slow path | May steal the lock; otherwise it backs out the bias, queues, sets `WAITERS` if first, and sleeps until `waiter.task` becomes `NULL`. |
| Writer slow path | Tries optimistic spinning first; on failure it queues, sets `WAITERS`, sleeps, and re-checks `count` after each wake. |
| Wake path | Builds a `wake_q` under `wait_lock` and calls `wake_up_q()` after unlocking; modes are `RWSEM_WAKE_ANY`, `RWSEM_WAKE_READERS`, and `RWSEM_WAKE_READ_OWNED`. |
| Reader batching | Up to `MAX_READERS_WAKEUP` (256) readers are counted first, then their `task` pointers are cleared; this prevents an early unlock from underflowing the count. |
| Handoff | Set for an RT/DL writer or when a waiter passes its deadline; it belongs to the queue head (`first_waiter->handoff_set`), not to the requester. |
| Timeout | `RWSEM_WAIT_TIMEOUT = DIV_ROUND_UP(HZ, 250)` (about 4 ms at `HZ=1000`); it is a soft handoff deadline, not an acquisition timeout. |
| Fairness | Phase-fair, not strict FIFO: readers are batched per phase, writers stay ordered by the queue, and the handoff bit bounds starvation. |
| New reader vs waiting writer | Normally queues behind the writer because `WAITERS` is set; a narrow single-reader steal is possible if no reader owns the lock and no handoff is set yet. |
| Writer starvation | `WAITERS`, `HANDOFF`, and the reader-owned/`rcnt > 1` guard prevent indefinite postponement; a long reader hold still delays the writer. |
| Reader starvation | A head reader gets the next reader phase, and a reader-side handoff is recorded if a writer steals; the guarantee is bounded, not strict. |
| Optimistic spinning | Enabled by `CONFIG_RWSEM_SPIN_ON_OWNER` (`SMP && ARCH_SUPPORTS_ATOMIC_RMW`), which is on by default for AArch64 SMP. |
| `osq` | MCS-style per-CPU nodes with `locked`, `next`, and `prev`, plus a single tail; only the head looks at the lock, and `osq_lock()` can fail and be abandoned. |
| Writer spin exit | Stops on a nonspinnable owner, an owner off-CPU, `need_resched()`, an expired reader threshold, or an RT/DL task whose previous owner state was not `OWNER_WRITER`. |
| Reader spin threshold | Roughly `(20 + readers) / 2` microseconds, capped at 25 microseconds; on expiry the writer sets `RWSEM_NONSPINNABLE`. |
| Reader stealing | A single slow-path attempt; blocked when a writer or `HANDOFF` is present, or when the lock is reader-owned with `rcnt > 1`. |
| RT/DL spinners | May briefly spin on a running writer, including a non-RT writer; they stop once the previous owner state is not `OWNER_WRITER` and rely on owner-on-CPU checks, not priority comparison. |
| Memory ordering | Acquire on every acquisition, release on every release; `count` is the synchronization point, `owner` is not. |
| Instructions | LSE `LDADDA` / `LDADDL` / `CASA` / `CASL` / `LDADDAL`; LL/SC `LDAXR` / `STLXR`; barriers `DMB ISH`, `LDAR`, `STLR`, `LDAPR`. |
| Wait lock | A `raw_spinlock_t` backed by a qspinlock; held only for queue and count bookkeeping, never across a sleep; slow paths use `raw_spin_lock_irq()`, unlock paths use `raw_spin_lock_irqsave()`. |
| WFE / SEV / yield | Qspinlock and `osq` waits use `SEVL` / `WFE` / `LDXR`; `cpu_relax()` is `yield`, a hint rather than a sleep. |
| Recursive read | Not supported: a second `down_read()` can queue behind a waiting writer and self-deadlock; lockdep's shared mode may not flag a pure double read. |
| Recursive write | Deadlocks outright; write followed by read on the same lock also deadlocks. |
| Upgrade | No read-to-write upgrade; drop and reacquire with revalidation, or start with the write lock. |
| Context | Process context only; `might_sleep()` is called; never under a spinlock, with IRQs disabled, or in hardirq, softirq, tasklet, or NMI. |
| Sleeping while held | Legal (page fault, `GFP_KERNEL`, I/O, another mutex), but long holds block readers or writers and dominate latency. |
| Signals | Uninterruptible by default; `_interruptible` and `_killable` variants return `-EINTR`; there is no built-in timeout. |
| Ownership | The writer must release its own lock; readers normally release their own reference, with the non-owner interface as a specialized exception. |
| Lifetime | There is no `rwsem_destroy()`; quiesce all users before freeing, and remember that the last unlock does not mean woken tasks have run. |
| `percpu` read | `preempt_disable()`, then `this_cpu_inc(read_count)` if `rcu_sync_is_idle()`, otherwise the slow path; `might_sleep()` is still present. |
| `percpu` write | `rcu_sync_enter()`, set `block`, wait for the sum of per-CPU counters to reach zero, own the critical section, then `rcu_sync_exit()` on release. |
| `percpu` ordering | The reader increment and the writer's `block` store are ordered by `smp_mb()`; an RCU-sched grace period closes the entry race without a shared atomic. |
| `percpu` use | Hot readers, rare writers, and tolerable writer latency (a grace period); not for frequent writers or microsecond write latency. |
| Debug | `CONFIG_DEBUG_RWSEMS` adds the magic cookie and count/owner/list warnings; `CONFIG_DEBUG_LOCK_ALLOC` adds the `LD_WAIT_SLEEP` lockdep map. |
| Diagnostics | `CONFIG_DEBUG_ATOMIC_SLEEP` catches sleeping in atomic context; `CONFIG_DETECT_HUNG_TASK_BLOCKER` records rwsem reader/writer blockers. |
| Tracing | `trace_contention_begin/end` with `LCB_F_READ` / `LCB_F_WRITE` feeds `perf lock`; the fast path is not traced. |
| Scalability | The reader fast path is an atomic RMW on one shared cache line; cost rises with CPU count, and writer latency is spin time plus reader drain plus wakeup. |
| Alternatives | RCU, per-VMA locks, per-CPU data, seqlocks, immutable snapshots, or a plain mutex when writers dominate. |
| `PREEMPT_RT` | `rwbase_rt` uses `atomic_t readers` plus `rt_mutex_base`; readers take the fast path while `READER_BIAS` is set, and priority/deadline inheritance replaces non-RT fairness. |

Primitive selection at a glance:

| Situation | Preferred primitive |
|---|---|
| Read-mostly, readers may block, regular writers | `rw_semaphore` |
| Read-mostly, readers may block, extremely rare writers | `percpu_rw_semaphore` or RCU |
| Read-mostly, readers cannot sleep | `rwlock_t` |
| Writer-heavy or exclusive | `mutex` |
| Counting resources, no reader/writer distinction | `struct semaphore` |
| Pointer traversal with reclaimable objects | RCU |
| Small data with cheap retry | Seqlock |
| Page-fault scalability on a large mm | Per-VMA locks |

The lock is a tool, not a goal. It keeps shared/exclusive semantics while allowing readers and writers to sleep; when that property is not needed, a simpler or more specialized primitive is usually better.

---

## 19. References

### 19.1 Core Type and API

- [`include/linux/rwsem.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/rwsem.h#L48-L67) — non-RT structure and owner/count fields.
- [`include/linux/rwsem.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/rwsem.h#L104-L124) — `DECLARE_RWSEM()` and `init_rwsem()`.
- [`include/linux/rwsem.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/rwsem.h#L229-L288) — public acquisition, release, and downgrade API.
- [`include/linux/rwsem.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/rwsem.h#L304-L323) — nested interfaces.

### 19.2 Generic Implementation

- [`kernel/locking/rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwsem.c#L36-L129) — owner flags and count encoding.
- [`kernel/locking/rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwsem.c#L249-L274) — reader and writer fast paths.
- [`kernel/locking/rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwsem.c#L309-L344) — initialization and waiter structure.
- [`kernel/locking/rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwsem.c#L429-L589) — wake path and reader batching.
- [`kernel/locking/rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwsem.c#L625-L689) — writer lock attempt and handoff.
- [`kernel/locking/rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwsem.c#L692-L956) — optimistic spinning.
- [`kernel/locking/rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwsem.c#L1016-L1133) — reader slow path.
- [`kernel/locking/rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwsem.c#L1138-L1238) — writer slow path.
- [`kernel/locking/rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwsem.c#L1244-L1279) — wake and downgrade wake.
- [`kernel/locking/rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwsem.c#L1284-L1449) — acquisition helpers, unlock, and downgrade.
- [`kernel/locking/rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwsem.c#L1570-L1701) — public API entry points.

### 19.3 AArch64 Atomics and Barriers

- [`arch/arm64/Kconfig`](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/Kconfig#L66-L80) — queued spinlocks and atomic RMW support.
- [`kernel/Kconfig.locks`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/Kconfig.locks#L224-L237) — `RWSEM_SPIN_ON_OWNER` and `ARCH_SUPPORTS_ATOMIC_RMW`.
- [`arch/arm64/include/asm/atomic_lse.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/atomic_lse.h#L40-L280) — LSE atomics.
- [`arch/arm64/include/asm/atomic_ll_sc.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/atomic_ll_sc.h#L150-L240) — LL/SC atomics.
- [`arch/arm64/include/asm/lse.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/lse.h#L17-L26) — runtime LSE/LL-SC selection.
- [`arch/arm64/include/asm/barrier.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/barrier.h#L126-L128) — `smp_mb()`.
- [`arch/arm64/include/asm/cmpxchg.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/cmpxchg.h#L213-L234) — `WFE`-based conditional wait.
- [`arch/arm64/include/asm/vdso/processor.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/vdso/processor.h#L10-L13) — `cpu_relax()`.
- [`arch/arm64/include/asm/spinlock.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/spinlock.h#L1-L14) — queued spinlock integration.
- [`include/asm-generic/qspinlock_types.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/include/asm-generic/qspinlock_types.h#L14-L94) — qspinlock layout.

### 19.4 Optimistic Spin Queue

- [`include/linux/osq_lock.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/osq_lock.h#L8-L21) — optimistic spin queue type.
- [`kernel/locking/osq_lock.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/osq_lock.c#L1-L234) — queue implementation.
- [`include/linux/atomic/atomic-long.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/atomic/atomic-long.h#L9-L22) — `atomic_long_t` mapping.

### 19.5 Per-CPU Reader-Writer Semaphores

- [`include/linux/percpu-rwsem.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/percpu-rwsem.h#L13-L153) — type, initializers, and read fast path.
- [`kernel/locking/percpu-rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/percpu-rwsem.c#L14-L46) — initialization and teardown.
- [`kernel/locking/percpu-rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/percpu-rwsem.c#L48-L185) — reader slow path and wake function.
- [`kernel/locking/percpu-rwsem.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/percpu-rwsem.c#L204-L318) — writer path and reader drain.
- [`Documentation/locking/percpu-rw-semaphore.rst`](https://github.com/torvalds/linux/blob/v7.3-rc7/Documentation/locking/percpu-rw-semaphore.rst#L1-L24) — design overview.

### 19.6 Documentation and Real Users

- [`Documentation/locking/locktypes.rst`](https://github.com/torvalds/linux/blob/v7.3-rc7/Documentation/locking/locktypes.rst#L26-L44) — sleeping lock rules.
- [`Documentation/locking/locktypes.rst`](https://github.com/torvalds/linux/blob/v7.3-rc7/Documentation/locking/locktypes.rst#L132-L155) — rwsem fairness and RT behavior.
- [`include/linux/mm_types.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/mm_types.h#L1250) — `mmap_lock`.
- [`include/linux/mmap_lock.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/mmap_lock.h#L541-L625) — mmap lock wrappers and downgrade.
- [`arch/arm64/kernel/mte.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/kernel/mte.c#L455-L456) — killable mmap read lock in AArch64 MTE.
- [`arch/arm64/kvm/mmu.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/kvm/mmu.c#L1119-L1121) — mmap read lock in AArch64 KVM.
- [`include/linux/fs.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/fs.h#L816) — inode `i_rwsem`.
- [`fs/readdir.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/fs/readdir.c#L33-L71) — read/write/downgrade pattern.
- [`include/linux/fs/super_types.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/fs/super_types.h#L151) — superblock `s_umount`.
- [`fs/super.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/fs/super.c#L60-L62) — `s_umount` read/write use.
- [`kernel/cpu.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/cpu.c#L484-L514) — per-CPU CPU hotplug lock.
- [`mm/memory_hotplug.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/mm/memory_hotplug.c#L211-L270) — per-CPU memory hotplug lock.
- [`fs/locks.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/fs/locks.c#L130-L140) — `file_rwsem`.
- [`kernel/cgroup/cgroup.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/cgroup/cgroup.c#L104) — `cgroup_threadgroup_rwsem`.
- [`fs/ext4/ext4.h`](https://github.com/torvalds/linux/blob/v7.3-rc7/fs/ext4/ext4.h#L1804-L1906) — ext4 `s_writepages_rwsem`.
- [`fs/ext4/super.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/fs/ext4/super.c#L1240-L1255) — ext4 initialization and teardown.
- [`fs/proc/kcore.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/fs/proc/kcore.c#L70) — `kclist_lock`.
- [`kernel/locking/rwbase_rt.c`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwbase_rt.c#L1-L50) — RT contrast.