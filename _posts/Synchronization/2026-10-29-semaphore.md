---
title: Semaphores in the Linux Kernel
published: true
categories: [Synchronization]
tags: [semaphore, sleeping-lock]
mermaid: true
---
# Semaphores in the Linux Kernel

At their core, semaphores are a classical synchronization primitive that predates the Linux kernel itself — Edsger Dijkstra introduced them in 1965. In the Linux kernel they serve a specific and narrower role than the name suggests: a semaphore is a **sleeping lock with a count**. A task that cannot acquire one is put to sleep on a wait queue rather than spinning. That one property explains most of the rest: why semaphores may only be used where blocking is legal, why they cost more than a spinlock in the uncontended case, why they have no owner, and why new kernel code is steered toward mutexes and completions.

Mechanically, a semaphore is a **counter with two operations and a wait queue**. The counter (`count`) records how many more tasks may acquire the semaphore. `down()` decrements it; `up()` increments it or hands the semaphore directly to a sleeper. When the counter reaches zero, a further `down()` cannot simply fail — it must wait — and the kernel implements that wait by linking a small record onto the semaphore's wait list and calling the scheduler. The record lives on the waiting task's own kernel stack, so the contended path performs no heap allocation.

Because the wait is a sleep, a semaphore can only be acquired from a context where blocking is legal. The implementation lives in [kernel/locking/semaphore.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/semaphore.c) and the public API [include/linux/semaphore.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/semaphore.h).

This document examines the primitive end to end: the type and its fields, initialization, the `down()`/`up()` call chains, the fast and slow paths, the exact sleep and wake protocol, the wait list and the wake queue, memory ordering, the variants and their task states, real-world usage patterns, the spinlock-versus-semaphore decision, debugging, testing, and why semaphores are being replaced. Unless stated otherwise, the discussion describes a non-`PREEMPT_RT` SMP kernel on AArch64.

**Diagram conventions.** Timelines run from top to bottom. Columns that sit side by side represent concurrent CPUs or tasks, not a strict wall-clock ordering. `CS` means critical section, and `count` values are the semaphore's counter as observed under its internal lock.

**Code references.** Every kernel reference names a file and links to the exact range in the v7.3-rc7 tag, in the form [kernel/locking/semaphore.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/semaphore.c#L91-L103). Line numbers are anchors into that tag, not into a distribution kernel. When reading on a different tree, compare the function name rather than trusting the line number.

| Question | Short answer |
|---|---|
| What is it? | A **sleeping lock with a counter and no owner** |
| Core state | `count`, a circular wait list headed by `first_waiter`, and an internal `raw_spinlock_t` |
| Acquire | `down()`, `down_interruptible()`, `down_killable()`, `down_trylock()`, `down_timeout()` |
| Release | `up()` — from any task or interrupt context |
| Uncontended cost | One IRQ-saving qspinlock round trip; no scheduler involvement |
| Contended cost | A waiter on the caller's kernel stack, an internal lock drop, `schedule_timeout()`, and a wake-queue handoff |
| Legal context | Blocking variants: process context only. `down_trylock()` and `up()`: also hardirq |
| Ownership | None; any context may release, so no priority inheritance and no owner-based debugging |
| Debuggability | **Weak by design**: lockdep does not model the semaphore itself, only its short-held internal spinlock |
| Best use | Limiting concurrency to **N identical resources**, and cross-context release patterns such as open/close |
| Worst use | As a general mutual-exclusion or event-signalling lock; use `mutex` or `completion` instead |
| Testing | No dedicated in-tree selftest; combine a custom module, hung-task detection, and memory/race sanitizers (Section 13) |

---

## Table of Contents

1. [Why Semaphores Exist](#1-why-semaphores-exist)
   - 1.1 [A Counter, Two Operations, and a Wait Queue](#11-a-counter-two-operations-and-a-wait-queue)
   - 1.2 [Binary and Counting Semaphores](#12-binary-and-counting-semaphores)
   - 1.3 [What Happens When the Semaphore Is Unavailable](#13-what-happens-when-the-semaphore-is-unavailable)
   - 1.4 [Where Semaphores Sit Among Linux Locks](#14-where-semaphores-sit-among-linux-locks)
2. [The `struct semaphore` in Detail](#2-the-struct-semaphore-in-detail)
   - 2.1 [Structure](#21-structure)
   - 2.2 [The Internal `raw_spinlock_t` on AArch64](#22-the-internal-raw_spinlock_t-on-aarch64)
   - 2.3 [`count`](#23-count)
   - 2.4 [`first_waiter` and the Wait List](#24-first_waiter-and-the-wait-list)
   - 2.5 [`last_holder` and Hung-Task Blocking](#25-last_holder-and-hung-task-blocking)
   - 2.6 [`struct semaphore_waiter`](#26-struct-semaphore_waiter)
   - 2.7 [Memory Layout](#27-memory-layout)
3. [Initialization](#3-initialization)
   - 3.1 [Static Initialization](#31-static-initialization)
   - 3.2 [Dynamic Initialization](#32-dynamic-initialization)
   - 3.3 [What the Initializers Actually Do](#33-what-the-initializers-actually-do)
   - 3.4 [Lifetime Rules](#34-lifetime-rules)
4. [The `down()` Family](#4-the-down-family)
   - 4.1 [The P/V Protocol](#41-the-pv-protocol)
   - 4.2 [`down()`](#42-down)
   - 4.3 [`down_interruptible()`](#43-down_interruptible)
   - 4.4 [`down_killable()`](#44-down_killable)
   - 4.5 [`down_trylock()`](#45-down_trylock)
   - 4.6 [`down_timeout()`](#46-down_timeout)
   - 4.7 [Task State Summary](#47-task-state-summary)
   - 4.8 [Complete API Table](#48-complete-api-table)
5. [Internal Implementation](#5-internal-implementation)
   - 5.1 [The Two-Level Design](#51-the-two-level-design)
   - 5.2 [The `down()` Fast Path](#52-the-down-fast-path)
   - 5.3 [The Slow Path: `__down_common()`](#53-the-slow-path-__down_common)
   - 5.4 [`___down_common()`: Registering the Waiter](#54-___down_common-registering-the-waiter)
   - 5.5 [The Sleep Loop](#55-the-sleep-loop)
   - 5.6 [Leaving the Wait List](#56-leaving-the-wait-list)
   - 5.7 [The `up()` Fast Path](#57-the-up-fast-path)
   - 5.8 [`__up()` and the Wake Queue](#58-__up-and-the-wake-queue)
   - 5.9 [Memory Ordering Around the Sleep](#59-memory-ordering-around-the-sleep)
   - 5.10 [End-to-End Walkthrough](#510-end-to-end-walkthrough)
6. [A Practical Example: One Hardware Resource](#6-a-practical-example-one-hardware-resource)
7. [Real-World Usage: InfiniBand Subnet Manager](#7-real-world-usage-infiniband-subnet-manager)
8. [Real-World Usage: Character Device Driver](#8-real-world-usage-character-device-driver)
9. [Producer/Consumer with Counting Semaphores](#9-producerconsumer-with-counting-semaphores)
    - 9.1 [The Ring-Buffer Pattern](#91-the-ring-buffer-pattern)
    - 9.2 [A Real Counting Semaphore in the Tree](#92-a-real-counting-semaphore-in-the-tree)
10. [Spinlock vs. Semaphore](#10-spinlock-vs-semaphore)
    - 10.1 [The Decision Tree](#101-the-decision-tree)
    - 10.2 [Key Differences at a Glance](#102-key-differences-at-a-glance)
    - 10.3 [Why Long Sections Need a Sleeping Lock](#103-why-long-sections-need-a-sleeping-lock)
11. [Writing Correct Semaphore Code](#11-writing-correct-semaphore-code)
    - 11.1 [Ownership](#111-ownership)
    - 11.2 [Context Rules](#112-context-rules)
    - 11.3 [Never Hold a Spinlock Across `down()`](#113-never-hold-a-spinlock-across-down)
    - 11.4 [Lock Ordering](#114-lock-ordering)
    - 11.5 [Priority Inversion](#115-priority-inversion)
    - 11.6 [Debugging and Observability](#116-debugging-and-observability)
12. [Why Semaphores Are Being Replaced](#12-why-semaphores-are-being-replaced)
    - 12.1 [`mutex`](#121-mutex)
    - 12.2 [`completion`](#122-completion)
    - 12.3 [The Counting Case Remains](#123-the-counting-case-remains)
    - 12.4 [The Problems That Drove the Shift](#124-the-problems-that-drove-the-shift)
    - 12.5 [`PREEMPT_RT`](#125-preempt_rt)
13. [Testing Semaphores](#13-testing-semaphores)
    - 13.1 [What Deserves a Test](#131-what-deserves-a-test)
    - 13.2 [A Debug Configuration That Catches Real Bugs](#132-a-debug-configuration-that-catches-real-bugs)
    - 13.3 [What Ships in the Tree](#133-what-ships-in-the-tree)
    - 13.4 [A Deterministic Semantics Test Module](#134-a-deterministic-semantics-test-module)
    - 13.5 [A Contention and Race Stress Test](#135-a-contention-and-race-stress-test)
    - 13.6 [Triggering the Hung-Task Blocker](#136-triggering-the-hung-task-blocker)
    - 13.7 [Sanitizers and Lock Debugging](#137-sanitizers-and-lock-debugging)
    - 13.8 [Observing Contention with Ftrace, perf, and BPF](#138-observing-contention-with-ftrace-perf-and-bpf)
    - 13.9 [Running the Tests Under QEMU on AArch64](#139-running-the-tests-under-qemu-on-aarch64)
    - 13.10 [A Test Matrix](#1310-a-test-matrix)
    - 13.11 [Reading the Failure Reports](#1311-reading-the-failure-reports)
14. [Summary: Rules of Thumb](#14-summary-rules-of-thumb)
15. [References](#15-references)

---

## 1. Why Semaphores Exist

A semaphore answers a question that a spinlock cannot: *what should a task do when the resource it needs is busy and the wait might be long?* Spinning is only sensible when the wait is measured in a handful of instructions. When the holder may need to allocate memory, wait for I/O, or call into a filesystem, the waiter should surrender the CPU. A semaphore makes that surrender explicit and reversible: the waiter records itself in a queue, changes its scheduler state, and calls `schedule()`. When the resource is released, the releaser wakes the waiter.

### 1.1 A Counter, Two Operations, and a Wait Queue

At the level of the API, a semaphore is a **counter with two atomic operations and a wait queue**. The counter represents how many concurrent holders the semaphore still allows. When the counter is greater than zero, a caller may acquire the semaphore by decrementing it. When the counter reaches zero, any further callers that try to acquire it are put to sleep on a wait queue and remain there until another thread increments the counter and wakes them.

The word "atomic" describes the *interface*, not the implementation. Internally the counter is an ordinary `unsigned int` protected by a small internal spinlock; all reads and writes happen with that lock held. The operations are atomic with respect to each other because they are serialized by the lock, not because the counter itself is an atomic type.

The wait queue is also deliberately cheap: each waiter is a `struct semaphore_waiter` embedded in the waiting task's kernel stack frame, linked into a circular list headed by `first_waiter`. The sleep path therefore allocates nothing and cannot fail for lack of memory.

This generalizes into two kinds of semaphore.

### 1.2 Binary and Counting Semaphores

- A **binary semaphore** has an initial count of 1. Only one holder at a time — it behaves superficially like a mutex, but without an ownership concept. The thread that calls `up()` does *not* have to be the same thread that called `down()`. It also has no priority inheritance, no optimistic spinning, and no lockdep owner checking.

- A **counting semaphore** has an initial count of N > 1. Up to N threads may hold it concurrently. This makes it the right tool for protecting a pool of N identical resources — N DMA channels, N device instances, N slots in a ring buffer.

A counting semaphore **can** be used to guard a critical section, but only if you set its initial count to 1. If you set it to more than 1, multiple threads enter simultaneously, and mutual exclusion is lost. In practice, any time you need mutual exclusion with sleeping, you should reach for a **mutex** or **completion** instead of a binary semaphore — those primitives carry stronger semantic guarantees.

The distinction matters because a binary semaphore is syntactically identical whether it is being used for mutual exclusion or for event signalling. Nothing in the type records which contract the author intended, and nothing in lockdep can enforce the difference.

### 1.3 What Happens When the Semaphore Is Unavailable

When a task calls `down()` (or any of its variants) and the semaphore count is already zero, the kernel places that task on the semaphore's internal wait queue and changes its **scheduler state** to `TASK_UNINTERRUPTIBLE` (or `TASK_INTERRUPTIBLE` / `TASK_KILLABLE` depending on which variant was called). The scheduler then switches the CPU to a different runnable task.

The task stays off the run queue until `up()` is called by some other context. Inside `up()`, the kernel wakes the first waiter — sets its `waiter.up = true` and adds it to the **wake queue** (`wake_q`) — then after releasing the internal spinlock, calls `wake_up_q()`, which transitions the task back to `TASK_RUNNING` and places it on a CPU's run queue. The scheduler then picks it up on its next opportunity.

A useful analogy: imagine a key hanging outside a locked room. A task that arrives and finds the key available takes it and enters. A second task that arrives while the key is gone does not spin waiting in the hallway — it writes its name on a list by the door and goes to sleep. When the first task exits, it checks the list, finds the sleeping task's name, and wakes it up so it can take the key and enter. This write-your-name-and-sleep behavior is what distinguishes semaphores from spinlocks, and it also explains their greater overhead: sleeping, maintaining the wait list, and waking back up all cost more than a brief busy-wait.

Two details of that story deserve emphasis because they shape the implementation:

1. **The handoff is explicit.** `up()` does not merely make the counter nonzero and let the sleeper race for it. It marks the specific waiter with `waiter.up = true` before waking it. The woken task checks that flag under the semaphore's lock, so it knows it owns the semaphore even if another task incremented `count` in the meantime.
2. **The wakeup is deferred.** The waker only queues the task while holding the internal spinlock; the actual `try_to_wake_up()` happens after the lock is dropped. This keeps the scheduler from running while the semaphore's internal lock is held.

### 1.4 Where Semaphores Sit Among Linux Locks

Linux has several sleeping synchronization primitives, and they are not interchangeable. The distinguishing feature of a semaphore is the combination of **a count** and **no owner**:

| Primitive | Waits by | Owner semantics | Concurrent holders | Typical use |
|---|---|---|---|---|
| `spinlock_t` | Spinning | No | 1 | Tiny critical sections, any context |
| `mutex` | Sleeping | Yes | 1 | Sleepable mutual exclusion |
| `rw_semaphore` | Sleeping | Yes (with reader exceptions) | 1 writer or N readers | Sleepable read-mostly data |
| `semaphore` | Sleeping | **No** | Up to `count` | Resource pools, cross-context signalling |
| `completion` | Sleeping | No | N/A (one-shot) | "Wait until X has happened" |

The absence of ownership is what allows `up()` to be called from a different task — or from an interrupt handler — than the one that called `down()`. It is also what prevents priority inheritance and what makes misuse hard for lockdep to detect. The count is what allows more than one holder, and therefore what makes semaphores irreplaceable for the true N-resource case.

---

## 2. The `struct semaphore` in Detail

### 2.1 Structure

Source: [include/linux/semaphore.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/semaphore.h#L15-L23):

```c
struct semaphore {
    raw_spinlock_t          lock;
    unsigned int            count;
    struct semaphore_waiter *first_waiter;

#ifdef CONFIG_DETECT_HUNG_TASK_BLOCKER
    unsigned long           last_holder;
#endif
};
```

The header prefaces the definition with a blunt instruction: *"Please don't access any members of this structure directly."* The fields are implementation details; the API is `down()`/`up()` and the initializers. Code that reads `sem->count` directly is reading state that can change the instant the internal lock is dropped.

Note also that the header only declares `struct semaphore_waiter *`. The waiter type itself is private to [kernel/locking/semaphore.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/semaphore.c#L245-L249), because no caller ever needs to name it.

### 2.2 The Internal `raw_spinlock_t` on AArch64

**`lock`** is a `raw_spinlock_t`. On AArch64, this expands through `arch_spinlock_t` to the **queued spinlock** type (`qspinlock`) defined in [include/asm-generic/qspinlock_types.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/asm-generic/qspinlock_types.h#L14-L44). The `qspinlock` is a 32-bit atomic integer with sub-fields: an 8-bit `locked` byte, an 8-bit `pending` byte, a 2-bit `tail_idx`, and a `tail_cpu` field. This layout (little-endian, as AArch64 normally runs) allows the lock and pending bits to be read and written as a 16-bit half-word with a single instruction, improving efficiency on multi-core systems.

The full AArch64 spinlock type hierarchy:

```text
raw_spinlock_t
  └─ arch_spinlock_t          [arch/arm64/include/asm/spinlock_types.h]
       └─ qspinlock            [include/asm-generic/qspinlock_types.h]
            └─ atomic_t val    (32-bit atomic integer)

  AArch64 little-endian bit layout of atomic_t val (NR_CPUS < 16K):
  ┌────────────────────────────────────────────────────────────────┐
  │ 31      18 │ 17  16 │   15      8   │     7       0            │
  │  tail_cpu  │tail_idx│   pending     │    locked                │
  │  (14 bits) │(2 bits)│   (8 bits)    │   (8 bits)               │
  └────────────────────────────────────────────────────────────────┘
  │◄──── tail (waiter queue position) ───►│◄── lock state ────────►│

  Byte-alias view (little-endian):
  byte[0] = locked    (1 = held)
  byte[1] = pending   (1 = one waiter spinning)
  byte[2..3] = tail   (MCS queue position)
```

The exact field widths are configuration-dependent. The layout above is the `CONFIG_NR_CPUS < 16K` case; with 16K or more CPUs the `pending` field shrinks to one bit and `tail` widens, as documented in the same header.

Locking this spinlock with `raw_spin_lock_irqsave` on AArch64 ultimately involves a `LDAXR/STXR` (load-acquire exclusive / store-exclusive) sequence or its **LSE** (Large System Extensions) equivalent `CASA`; the release is a store-release (`STLR`). Where a full barrier is required after acquisition, `smp_mb__after_spinlock()` defined in [arch/arm64/include/asm/spinlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/spinlock.h#L12) expands to a full `smp_mb()`, which on AArch64 is `dmb(ish)` — a bidirectional barrier across all inner-shareable CPUs.

Using `raw_spinlock_t` rather than `spinlock_t` is deliberate. On a `PREEMPT_RT` kernel, `spinlock_t` is reimplemented on top of an rt-mutex and can sleep; `raw_spinlock_t` remains a genuine spinning lock. The semaphore implementation is shared between RT and non-RT kernels, and its internal lock must never sleep, so it must be raw.

### 2.3 `count`

**`count`** is an `unsigned int` protected entirely by `lock`. It is never accessed atomically on its own; all reads and writes happen with the spinlock held.

Its meaning is *the number of additional acquisitions currently permitted*. The logical invariant is that `down()` never decrements it below zero: the check and the decrement happen under the same lock, and a task that would take it negative goes to the slow path instead. `up()` increments it only on the fast path; when a waiter exists, `up()` hands the semaphore directly to the waiter and leaves `count` at zero.

The source file states the contract in its header comment: *"The ->count variable represents how many more tasks can acquire this semaphore. If it's zero, there may be waiters."*

### 2.4 `first_waiter` and the Wait List

**`first_waiter`** is a pointer to the first `struct semaphore_waiter` in the wait list. The list is a circular linked list (`struct list_head`) embedded inside `semaphore_waiter`, with `first_waiter` giving direct O(1) access to the head for wakeup. The waiter structs live on the waiting tasks' **kernel stacks**, not heap-allocated — this avoids any dynamic allocation in the sleep path.

There is no separate list-head object. The head of the circular list *is* the `list` member of the first waiter:

- When a waiter arrives and `first_waiter` is `NULL`, it calls `INIT_LIST_HEAD(&waiter.list)` — the node points at itself — and stores its own address in `sem->first_waiter`.
- When a waiter arrives and a list already exists, it calls `list_add_tail(&waiter.list, &first->list)`, which inserts before the head node in circular order, i.e. at the tail.

That representation is why `sem_del_waiter()` can test `list_empty(&waiter->list)` to mean "this was the only waiter." A node with a self-referential `next` is both empty and alone.

FIFO order is preserved by always appending at the tail. The first waiter is the one that has waited longest, and `__up()` always wakes it.

### 2.5 `last_holder` and Hung-Task Blocking

**`last_holder`** exists only when `CONFIG_DETECT_HUNG_TASK_BLOCKER` is enabled (see [lib/Kconfig.debug](https://github.com/torvalds/linux/blob/v7.3-rc7/lib/Kconfig.debug#L1274-L1283)). It is written with `WRITE_ONCE()` when a task takes the semaphore on the fast path, and again when a waiter is handed the semaphore in `___down_common()`. It is cleared by `up()` only if the releasing task is also the recorded holder:

```c
static inline void hung_task_sem_set_holder(struct semaphore *sem)
{
    WRITE_ONCE((sem)->last_holder, (unsigned long)current);
}

static inline void hung_task_sem_clear_if_holder(struct semaphore *sem)
{
    if (READ_ONCE((sem)->last_holder) == (unsigned long)current)
        WRITE_ONCE((sem)->last_holder, 0UL);
}
```

When a task blocks on a semaphore, `__down_common()` records the semaphore in the task's `blocker` field via `hung_task_set_blocker(sem, BLOCKER_TYPE_SEM)`. The hung-task watchdog can then decode that field and print a line such as:

```text
INFO: task worker:1234 blocked on a semaphore likely last held by task producer:987
```

The message is emitted by `debug_show_blocker()` in [kernel/hung_task.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/hung_task.c#L137-L219). The blocker field encodes the lock type in the two low bits of the pointer, which are free because lock addresses are at least 4-byte aligned. The header [include/linux/hung_task.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/hung_task.h#L15-L56) documents the encoding, and `sem_last_holder()` returns the raw `task_struct` pointer (or `0` when the configuration is disabled).

This is purely diagnostic, and its accuracy is bounded by the implementation:

- `up()` from a task other than the recorded holder does not clear `last_holder`, so the report can name a stale task.
- If the holder exited without releasing, the recorded task is gone and the watchdog degenerates to "the last holder is not found".
- A semaphore acquired by the slow path records the holder only when the handoff completes, which is the correct moment but leaves a window while the task is still asleep.

It does not make the semaphore fair, and it cannot solve the underlying ownership problem — which is exactly why it exists as a diagnostic rather than a correctness mechanism.

### 2.6 `struct semaphore_waiter`

The `semaphore_waiter` is defined at [kernel/locking/semaphore.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/semaphore.c#L245-L249):

```c
struct semaphore_waiter {
    struct list_head    list;
    struct task_struct *task;
    bool                up;
};
```

`up` is the handoff flag: `up()` sets it to `true` and then adds the task to the wake queue. When the task wakes and sees `waiter.up == true`, it knows the semaphore was handed to it legitimately.

`task` is captured when the waiter is registered (`waiter.task = current`) and is used by `wake_q_add()` to wake the right task. `list` links the waiter into the semaphore's circular queue.

All three fields are written before the task sleeps, while the semaphore's internal lock is held; `up` is written by the waker under the same lock. That is what makes the protocol race-free without any extra barrier on the waiter's side.

### 2.7 Memory Layout

The memory layout of `struct semaphore` and its associated waiter structs (which live on waiting tasks' kernel stacks):

```text
struct semaphore (in .data or heap)
┌───────────────────────────────────────┐
│ lock        │ raw_spinlock_t          │ ← qspinlock: 4 bytes (AArch64)
│             │ (arch_spinlock_t)       │
├─────────────┼─────────────────────────┤
│ count       │ unsigned int            │ ← number of available slots
├─────────────┼─────────────────────────┤
│ first_waiter│ struct semaphore_waiter*│ ─────────────────────┐
├─────────────┼─────────────────────────┤                      │
│ last_holder │ unsigned long (optional)│ ← CONFIG_DETECT_HUNG │
└───────────────────────────────────────┘                      │
                                                               │
   Task A kernel stack          Task B kernel stack            │
┌─────────────────────┐    ┌─────────────────────┐             │
│ semaphore_waiter    │◄───┤ semaphore_waiter    │◄────────────┘
│  .list  ──────────────────► .list              │
│  .task = task_A     │    │  .task = task_B     │
│  .up   = false      │    │  .up   = false      │
└─────────────────────┘    └─────────────────────┘
       (first_waiter)             (next in list)
```

On a non-debug AArch64 kernel the structure is 16 bytes without `last_holder` and 24 bytes with it: a 4-byte qspinlock, a 4-byte `count`, an 8-byte pointer, and an optional 8-byte `last_holder`. With `CONFIG_DEBUG_SPINLOCK`, `raw_spinlock_t` grows by the magic value and owner bookkeeping, so the footprint grows accordingly.

The layout is cache-line-friendly for a lock that is usually uncontended: the hot fields (`lock`, `count`, `first_waiter`) fit in the first 16 bytes. But note that the semaphore does **not** align itself to a cache line. Embedding one next to a frequently written field in a hot structure can cause false sharing with unrelated data.

---

## 3. Initialization

### 3.1 Static Initialization

**Static initialization** is used when the semaphore and its initial count are known at compile time:

```c
/* Binary semaphore (count = 1) */
DEFINE_SEMAPHORE(my_sem, 1);

/* Counting semaphore with 4 slots */
DEFINE_SEMAPHORE(pool_sem, 4);
```

The macro is defined in [include/linux/semaphore.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/semaphore.h#L46-L47):

```c
#define DEFINE_SEMAPHORE(_name, _n)     \
    struct semaphore _name = __SEMAPHORE_INITIALIZER(_name, _n)
```

The count is explicit. There is no single-argument form that silently defaults to 1; if you want a binary semaphore, write the `1`.

### 3.2 Dynamic Initialization

**Dynamic initialization** is used when the semaphore is embedded in a struct allocated at runtime (common in driver `probe()` functions):

```c
struct my_device {
    struct semaphore sem;
    /* ... */
};

static int my_probe(struct platform_device *pdev)
{
    struct my_device *dev = devm_kzalloc(...);

    sema_init(&dev->sem, 1);
    /* ... */
}
```

`sema_init` is defined in [include/linux/semaphore.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/semaphore.h#L49-L54):

```c
static inline void sema_init(struct semaphore *sem, int val)
{
    static struct lock_class_key __key;

    *sem = (struct semaphore) __SEMAPHORE_INITIALIZER(*sem, val);
    lockdep_init_map(&sem->lock.dep_map, "semaphore->lock", &__key, 0);
}
```

Note that `sema_init()` returns `void`; it cannot fail. It also takes the initial value as an `int` but assigns it to the `unsigned int count` field, so pass a non-negative value.

### 3.3 What the Initializers Actually Do

Both forms reduce to `__SEMAPHORE_INITIALIZER()`, from [include/linux/semaphore.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/semaphore.h#L32-L38):

```c
#define __SEMAPHORE_INITIALIZER(name, n)                \
{                                                       \
    .lock           = __RAW_SPIN_LOCK_UNLOCKED((name).lock), \
    .count          = n,                                \
    .first_waiter   = NULL                              \
    __LAST_HOLDER_SEMAPHORE_INITIALIZER                 \
}
```

The expansion zeros `first_waiter`, initializes the embedded `raw_spinlock_t` to its unlocked state, and sets `count = n`. Everything is resolved at compile time, placed in `.data` (or in the enclosing allocation), and requires no runtime call.

The two forms differ in how they initialize the lockdep map of the **internal spinlock** (the semaphore itself has no lockdep map):

- **`DEFINE_SEMAPHORE`** embeds a `dep_map` with the internal lock's name and wait type but no explicit class key. Lockdep derives the class from the lock's own address when the lock is first acquired, so every statically defined semaphore instance gets its own internal-lock class.
- **`sema_init()`** passes `&__key`, a function-local `static struct lock_class_key`. Because `sema_init()` is a `static inline` function (not a macro), there is one `__key` per translation unit that uses it. All semaphores initialized through `sema_init()` in the same file therefore share an internal-lock class; semaphores initialized in different files do not.

This distinction is narrower than it looks. It affects only diagnostics for the short-held internal spinlock. Because `down()` releases that spinlock before sleeping, lockdep never sees a semaphore-to-semaphore ordering edge (Section 11.4).

The `static` storage class is what makes the key legal: lockdep requires a class key to have static lifetime, because it stores the pointer in the lock class for the life of the kernel.

`__RAW_SPIN_LOCK_UNLOCKED((name).lock)` also carries the lock's name into the embedded `dep_map` for diagnostics, and the `sema_init()` path overrides it with the explicit `"semaphore->lock"` string.

### 3.4 Lifetime Rules

A `struct semaphore` must live at a stable address for as long as any task can wait on it. In particular:

- Do not `kfree()` a semaphore while it is held or while any task is queued on it. A waiter's stack record contains pointers into the semaphore's list, and `up()` walks that list.
- Do not reinitialize a semaphore with `sema_init()` while it is held or contended.
- Do not copy a live `struct semaphore` with `memcpy()` or struct assignment. The initializers assign a fresh object before it is published, which is fine; copying an object that is already in use would duplicate the wait-list pointers and alias the queue.
- Do not let a task exit while it is conceptually holding the semaphore. Because there is no owner, nothing will clean it up automatically; the count simply stays consumed.

These are not stylistic rules. The kernel dereferences `first_waiter` and the waiter nodes from a different task's stack; a stale address is a use-after-free that no lockdep check will catch.

---

## 4. The `down()` Family

### 4.1 The P/V Protocol

The classical names come from Dijkstra's Dutch:

- **P() — proberen (to test)** — corresponds to `down()`: decrement the counter. If the counter was zero, block.
- **V() — verhogen (to increment)** — corresponds to `up()`: increment the counter and wake a waiter if any.

The Linux kernel implementation uses an internal `raw_spinlock_t` to protect the semaphore's own state during the P and V operations. The spinlock is held only for a very short duration — just long enough to check and update `count` and manipulate the wait list — then released. The sleeping itself happens with the spinlock *not* held.

Every `down()` and `up()` operation has two execution paths depending on whether the semaphore is contested:

**Fast path** — the uncontended case. `sem->count > 0` means a slot is available. The entire operation completes inside the spinlock in a handful of instructions: decrement `count`, record the holder, release the lock, return. No sleep, no scheduler invocation, no wait-list manipulation. The calling task never leaves the CPU. This is by far the common case in well-designed code.

**Slow path** — the contended case. `sem->count == 0` means all slots are taken. The kernel cannot proceed, so it takes the expensive route: it places a `semaphore_waiter` on the current task's **kernel stack**, links it into the semaphore's wait list, sets the task's scheduler state to the appropriate sleep mode (`TASK_UNINTERRUPTIBLE`, `TASK_INTERRUPTIBLE`, or `TASK_KILLABLE`), drops the spinlock, and calls `schedule_timeout()` — at which point the scheduler switches to another runnable task. The calling task does not run again until `up()` fires the wakeup by setting `waiter->up = true` and calling `wake_up_q()`.

The same split applies in `up()`: if no task is sleeping (`first_waiter == NULL`), the fast path simply increments `count` and returns. If a waiter is present, the slow path calls `__up()` to dequeue the first sleeper and hand it the semaphore.

```text
                 down(sem)                         up(sem)
                     │                                │
          count > 0? │                   first_waiter │ == NULL?
          ┌──────────┤                   ┌────────────┤
         YES         NO                 YES           NO
          │           │                  │             │
          ▼           ▼                  ▼             ▼
      FAST PATH   SLOW PATH         FAST PATH     SLOW PATH
     count--      sleep on          count++       __up():
   __sem_acquire  wait list                       dequeue waiter
                  schedule()                      waiter->up=true
                  wake on up()                    wake_up_q()
```

```text
 caller invokes down(sem)
          │
          ▼
   raw_spin_lock_irqsave(&sem->lock)
          │
          ▼
    sem->count > 0?
     ┌────┴────┐
    YES        NO
     │          │
     ▼          ▼
 __sem_acquire  __down(sem)
 sem->count--   [slow path: sleep]
     │          │
     └────┬─────┘
          ▼
   raw_spin_unlock_irqrestore
          │
          ▼
       return
```

The fast path is generic across the whole family. The only differences between the `down` variants are the **task state** used on the slow path and whether a **timeout** applies.

### 4.2 `down()`

```c
void __sched down(struct semaphore *sem)
{
    unsigned long flags;

    might_sleep();
    raw_spin_lock_irqsave(&sem->lock, flags);
    if (likely(sem->count > 0))
        __sem_acquire(sem);
    else
        __down(sem);
    raw_spin_unlock_irqrestore(&sem->lock, flags);
}
```

Source: [kernel/locking/semaphore.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/semaphore.c#L91-L103).

Sleeps with `TASK_UNINTERRUPTIBLE`. The task is invisible to signals — it cannot be killed until the semaphore is released. Use of this variant is deprecated in the kernel because an unresponsive `TASK_UNINTERRUPTIBLE` task contributes to load average and may trigger hung task warnings. Prefer `down_killable()`.

`might_sleep()` is a debug assertion that the current context is allowed to sleep. It does not sleep; it checks for atomic context, disabled interrupts, or a held spinlock and emits a warning with a stack trace if the caller is violating the rules. In a production kernel without `CONFIG_DEBUG_ATOMIC_SLEEP` it reduces to `might_resched()`, which is itself a no-op unless preemption is enabled.

`raw_spin_lock_irqsave` saves the CPU's DAIF flags (on AArch64, the **D**ebug, **A**synchronous, **I**RQ, and **F**IQ masking bits) and disables IRQs before taking the lock. This is necessary because `up()` can be called from interrupt context, so without IRQ disabling, an interrupt firing between the lock check and the lock acquisition could cause a deadlock.

The source file's header comment explains why *every* `down` variant — even the ones that always sleep — uses the IRQ-saving form:

> *The spinlock controls access to the other members of the semaphore. `down_trylock()` and `up()` can be called from interrupt context, so we have to disable interrupts when taking the lock. It turns out various parts of the kernel expect to be able to use `down()` on a semaphore in interrupt context when they know it will succeed, so we have to use `irqsave` variants for `down()`, `down_interruptible()` and `down_killable()` too.*

That last sentence describes an existing kernel idiom, not a license for new code. Calling a blocking `down()` from interrupt context is only "safe" when the count is guaranteed positive; if it is not, the task will try to schedule from atomic context and the kernel will break. New code should use `down_trylock()` in interrupt context.

### 4.3 `down_interruptible()`

```c
int __sched down_interruptible(struct semaphore *sem)
{
    unsigned long flags;
    int result = 0;

    might_sleep();
    raw_spin_lock_irqsave(&sem->lock, flags);
    if (likely(sem->count > 0))
        __sem_acquire(sem);
    else
        result = __down_interruptible(sem);
    raw_spin_unlock_irqrestore(&sem->lock, flags);

    return result;
}
```

Source: [kernel/locking/semaphore.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/semaphore.c#L114-L128).

Sleeps with `TASK_INTERRUPTIBLE`. **Any signal** — including `SIGPIPE`, `SIGUSR1`, and other non-fatal signals — will wake the task and return `-EINTR`. This is the most commonly used variant in driver code because it allows user space to interrupt a blocked `ioctl()` call. Returns `0` on success, `-EINTR` if interrupted.

The wakeup condition is evaluated by `signal_pending_state()`, which returns true for `TASK_INTERRUPTIBLE` whenever any signal is pending, and for `TASK_WAKEKILL` only when the pending signal is considered fatal — which in this tree means `SIGKILL`. That helper is the entire difference between `down_interruptible()` and `down_killable()`.

A caller that receives `-EINTR` has **not** acquired the semaphore. It must not call `up()`, and it must undo any partial work it did before the acquisition.

### 4.4 `down_killable()`

```c
int __sched down_killable(struct semaphore *sem)
{
    unsigned long flags;
    int result = 0;

    might_sleep();
    raw_spin_lock_irqsave(&sem->lock, flags);
    if (likely(sem->count > 0))
        __sem_acquire(sem);
    else
        result = __down_killable(sem);
    raw_spin_unlock_irqrestore(&sem->lock, flags);

    return result;
}
```

Source: [kernel/locking/semaphore.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/semaphore.c#L141-L156).

Sleeps with `TASK_KILLABLE = TASK_WAKEKILL | TASK_UNINTERRUPTIBLE`. Only a **fatal signal** aborts the wait, and the kernel's definition of fatal is narrow: `signal_pending_state()` calls `__fatal_signal_pending()`, which in this tree tests specifically for a pending `SIGKILL`:

```c
static inline int __fatal_signal_pending(struct task_struct *p)
{
    return unlikely(sigismember(&p->pending.signal, SIGKILL));
}
```

A default-action terminating signal such as `SIGTERM` reaches the same result indirectly: `complete_signal()` starts a group exit and injects `SIGKILL` into every thread's pending set, so the sleeper wakes and `down_killable()` returns `-EINTR`. A `SIGTERM` that has an installed handler is not fatal, so it does not abort the wait. Regular delivery-only signals never wake the task at all. This is the right choice when you want the process to be killable but not interruptible by every signal. Returns `0` on success, `-EINTR` when killed.

### 4.5 `down_trylock()`

```c
int __sched down_trylock(struct semaphore *sem)
{
    unsigned long flags;
    int count;

    raw_spin_lock_irqsave(&sem->lock, flags);
    count = sem->count - 1;
    if (likely(count >= 0))
        __sem_acquire(sem);
    raw_spin_unlock_irqrestore(&sem->lock, flags);

    return (count < 0);
}
```

Source: [kernel/locking/semaphore.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/semaphore.c#L171-L184).

Attempts to acquire without sleeping. Returns `0` on success, `1` on failure. This is the **only** `down` variant safe to call from interrupt context — it holds the spinlock briefly (with `irqsave`) but never sleeps. It is also the only variant that does not call `might_sleep()`.

The return value is inverted compared to `spin_trylock()` and `mutex_trylock()` — returning `1` means "could not acquire". This is a known inconsistency in the API, and the source file calls it out explicitly with a `NOTE:` in the kernel-doc comment.

The arithmetic deserves a second look. `sem->count` is `unsigned int`, so `sem->count - 1` is computed in unsigned arithmetic and then assigned to the `int count`. When `sem->count` is zero the subtraction wraps to `UINT_MAX`, which converts to `-1`; when it is positive, the result is the new non-negative count. The `count >= 0` test is therefore a valid "was there a slot?" test, and `__sem_acquire()` re-reads `sem->count` and decrements it again — the local copy is only used for the decision.

Because the check and the decrement both happen under `sem->lock`, no other task can consume the slot between them. A successful `down_trylock()` is a real acquisition and must be paired with `up()`. A failed one leaves the semaphore untouched.

`down_trylock` returning 1 immediately when count is already zero:

```c
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/semaphore.h>

MODULE_LICENSE("GPL");

static struct semaphore mysem;

static int __init test_hello_init(void)
{
    int ret;

    sema_init(&mysem, 1);
    pr_info("count before down: %u\n", mysem.count);
    down(&mysem);
    pr_info("count after down:  %u\n", mysem.count);
    ret = down_trylock(&mysem);
    pr_info("down_trylock returned %d (1 = could not acquire)\n", ret);
    up(&mysem);
    return -1;
}

static void __exit test_hello_exit(void) {}

module_init(test_hello_init);
module_exit(test_hello_exit);
```

### 4.6 `down_timeout()`

```c
int __sched down_timeout(struct semaphore *sem, long timeout)
{
    unsigned long flags;
    int result = 0;

    might_sleep();
    raw_spin_lock_irqsave(&sem->lock, flags);
    if (likely(sem->count > 0))
        __sem_acquire(sem);
    else
        result = __down_timeout(sem, timeout);
    raw_spin_unlock_irqrestore(&sem->lock, flags);

    return result;
}
```

Source: [kernel/locking/semaphore.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/semaphore.c#L196-L211).

Sleeps with `TASK_UNINTERRUPTIBLE` but gives up after `timeout` jiffies. Returns `0` on success, `-ETIME` on timeout. Use this when you must not wait indefinitely — for example, acquiring a lock before a hardware timeout expires.

Because the state is `TASK_UNINTERRUPTIBLE`, a signal does not shorten the wait. `down_timeout()` always waits for either the semaphore or the deadline.

Counting semaphore exhausted — third call times out after 1000 jiffies:

```c
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/semaphore.h>

MODULE_LICENSE("GPL");

static struct semaphore mysem;

static int __init test_hello_init(void)
{
    int ret;

    sema_init(&mysem, 2);
    pr_info("count: %u\n", mysem.count);               /* 2 */

    ret = down_timeout(&mysem, 1000);
    pr_info("count: %u  ret: %d\n", mysem.count, ret); /* 1, 0 */

    ret = down_timeout(&mysem, 1000);
    pr_info("count: %u  ret: %d\n", mysem.count, ret); /* 0, 0 */

    ret = down_timeout(&mysem, 1000);                   /* blocks, times out */
    pr_info("count: %u  ret: %d\n", mysem.count, ret); /* 0, -ETIME */

    return -1;
}

static void __exit test_hello_exit(void) {}

module_init(test_hello_init);
module_exit(test_hello_exit);
```

### 4.7 Task State Summary

```text
  down()              ──► TASK_UNINTERRUPTIBLE   (no signal wakeup, deprecated)
  down_interruptible()──► TASK_INTERRUPTIBLE     (any signal wakes, returns -EINTR)
  down_killable()     ──► TASK_KILLABLE          (fatal signal only, returns -EINTR)
  down_trylock()      ──► never sleeps           (IRQ-safe, returns 0/1)
  down_timeout()      ──► TASK_UNINTERRUPTIBLE   (with deadline, returns -ETIME)
```

In virtually all driver code that runs in process context, prefer `down_interruptible()` for locks that guard operations the user may want to cancel. Use `down_killable()` when you want the process killable but not interruptible by soft signals. Only reach for `down()` when you explicitly need uninterruptible sleep (rare), and never in new code.

The decision can be summarized:

```text
  Can the caller tolerate a signal?
  ├─ yes, any signal ────────────► down_interruptible()   (-EINTR)
  ├─ yes, but only fatal signals ► down_killable()        (-EINTR)
  └─ no
      ├─ must not block at all ──► down_trylock()         (0 / 1)
      └─ must not block forever ─► down_timeout()         (0 / -ETIME)
```

### 4.8 Complete API Table

| Operation | Returns | Task state on sleep | Notes |
|---|---|---|---|
| `down(sem)` | `void` | `TASK_UNINTERRUPTIBLE` | Deprecated; cannot be killed |
| `down_interruptible(sem)` | `0` / `-EINTR` | `TASK_INTERRUPTIBLE` | Any signal aborts the wait |
| `down_killable(sem)` | `0` / `-EINTR` | `TASK_KILLABLE` | Only fatal signals abort |
| `down_trylock(sem)` | `0` / `1` | never sleeps | Only IRQ-safe acquire; inverted result |
| `down_timeout(sem, jiffies)` | `0` / `-ETIME` | `TASK_UNINTERRUPTIBLE` | Deadline in jiffies |
| `up(sem)` | `void` | — | Releases; callable from any context |
| `sema_init(sem, val)` | `void` | — | Dynamic initialization |
| `DEFINE_SEMAPHORE(name, n)` | — | — | Static initialization |
| `sem_last_holder(sem)` | `task_struct *` as `unsigned long` | — | Debug only; `0` if not configured |

Three rules apply to every row:

1. A successful acquire must be paired with exactly one `up()`.
2. A failed acquire (`-EINTR`, `-ETIME`, or `down_trylock()` returning 1) must **not** be paired with `up()`.
3. From interrupt context, only `down_trylock()` and `up()` may be used.

---

## 5. Internal Implementation

### 5.1 The Two-Level Design

The semaphore separates the **common case** from the **contended case**:

- **Fast path:** `count > 0`. The operation is a decrement under the internal spinlock. No wait list, no scheduler, no wake queue.
- **Slow path:** `count == 0`. The task registers a waiter on its own stack, links it into the list, drops the lock, and sleeps.
- **Release fast path:** `first_waiter == NULL`. `up()` increments `count`.
- **Release slow path:** a waiter exists. `up()` dequeues the first waiter, sets its handoff flag, and queues a wakeup.

This split is what keeps the lock cheap when it is not contended and correct when it is. The internal spinlock is held for a constant, tiny amount of work on every path; the expensive work — scheduling and waking — happens entirely outside it.

### 5.2 The `down()` Fast Path

The `down()` fast path from [kernel/locking/semaphore.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/semaphore.c#L91-L103):

```c
void __sched down(struct semaphore *sem)
{
    unsigned long flags;

    might_sleep();
    raw_spin_lock_irqsave(&sem->lock, flags);
    if (likely(sem->count > 0))
        __sem_acquire(sem);
    else
        __down(sem);
    raw_spin_unlock_irqrestore(&sem->lock, flags);
}
```

The fast path — `count > 0` — simply calls `__sem_acquire(sem)` from [kernel/locking/semaphore.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/semaphore.c#L74-L78), which decrements the counter:

```c
static inline void __sem_acquire(struct semaphore *sem)
{
    sem->count--;
    hung_task_sem_set_holder(sem);
}
```

`hung_task_sem_set_holder` records `current` as the last holder (used by `CONFIG_DETECT_HUNG_TASK_BLOCKER` to identify who is blocking a hung task) using a `WRITE_ONCE` to prevent compiler tearing.

The acquisition is not a single atomic instruction. It is an IRQ-saving lock, a compare, a decrement, and an unlock. On AArch64 the lock itself is a qspinlock acquire (a `CASA` or `LDAXR`/`STLXR` sequence), so an uncontended `down()` costs roughly one spinlock round trip plus an IRQ mask/unmask and a branch.

The `likely()` annotation reflects reality: in a correctly sized pool, most acquisitions find a free slot.

### 5.3 The Slow Path: `__down_common()`

The slow path calls `__down(sem)`, which delegates to `__down_common()`:

```c
static noinline void __sched __down(struct semaphore *sem)
{
    __down_common(sem, TASK_UNINTERRUPTIBLE, MAX_SCHEDULE_TIMEOUT);
}
```

`__down()` itself is a one-liner — its only job is to forward into `__down_common()` with the right task state and an infinite timeout. The other variants are equally thin:

```c
static noinline int __sched __down_interruptible(struct semaphore *sem)
{
    return __down_common(sem, TASK_INTERRUPTIBLE, MAX_SCHEDULE_TIMEOUT);
}

static noinline int __sched __down_killable(struct semaphore *sem)
{
    return __down_common(sem, TASK_KILLABLE, MAX_SCHEDULE_TIMEOUT);
}

static noinline int __sched __down_timeout(struct semaphore *sem, long timeout)
{
    return __down_common(sem, TASK_UNINTERRUPTIBLE, timeout);
}
```

`MAX_SCHEDULE_TIMEOUT` is the "no deadline" sentinel. `schedule_timeout()` special-cases it by calling plain `schedule()`, so the no-timeout variants pay no timer cost at all.

`__down_common()` at [kernel/locking/semaphore.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/semaphore.c#L310-L324) is a thin but important wrapper: before entering the actual sleep loop it registers the semaphore with the **hung task blocker** infrastructure and fires a **lock contention trace event**, then clears both on return.

```c
static inline int __sched __down_common(struct semaphore *sem, long state,
                                        long timeout)
{
    int ret;

    hung_task_set_blocker(sem, BLOCKER_TYPE_SEM);

    trace_contention_begin(sem, 0);
    ret = ___down_common(sem, state, timeout);
    trace_contention_end(sem, ret);

    hung_task_clear_blocker();

    return ret;
}
```

`hung_task_set_blocker` marks the current task as being blocked on this semaphore, which is what allows the hung task watchdog to print "task X is blocked on semaphore Y" in kernel logs. `trace_contention_begin` / `trace_contention_end` are the tracepoints consumed by tools like `perf lock` and `BPF` programs that profile lock contention. The actual sleep mechanics live one level deeper, in `___down_common()`.

### 5.4 `___down_common()`: Registering the Waiter

`___down_common()` at [kernel/locking/semaphore.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/semaphore.c#L271-L308) is where the task is placed on the wait list, put to sleep, and eventually handed the semaphore. Its full source:

```c
static inline int __sched ___down_common(struct semaphore *sem, long state,
                                         long timeout)
{
    struct semaphore_waiter waiter, *first;

    first = sem->first_waiter;
    if (first) {
        list_add_tail(&waiter.list, &first->list);
    } else {
        INIT_LIST_HEAD(&waiter.list);
        sem->first_waiter = &waiter;
    }
    waiter.task = current;
    waiter.up = false;

    for (;;) {
        if (signal_pending_state(state, current))
            goto interrupted;
        if (unlikely(timeout <= 0))
            goto timed_out;
        __set_current_state(state);
        raw_spin_unlock_irq(&sem->lock);
        timeout = schedule_timeout(timeout);
        raw_spin_lock_irq(&sem->lock);
        if (waiter.up) {
            hung_task_sem_set_holder(sem);
            return 0;
        }
    }

 timed_out:
    sem_del_waiter(sem, &waiter);
    return -ETIME;

 interrupted:
    sem_del_waiter(sem, &waiter);
    return -EINTR;
}
```

The waiter struct is allocated on the **calling task's kernel stack** (a local variable inside `___down_common`), so no heap allocation occurs in the contended path. If `first_waiter` is already set, the new waiter is appended to the tail of the existing circular list with `list_add_tail`, preserving FIFO order. If there is no existing waiter, `INIT_LIST_HEAD` initialises an empty list and this task becomes `first_waiter`.

The function is `static inline` precisely so the compiler can constant-fold `state` and `timeout`. The comment above it in the source notes that `state` is constant at each call site and the `timeout` parameter is optimized away for the variants without a deadline. `__down_common()` is likewise `static inline`; it is folded into each of the four `noinline` `__down_*` wrappers and exists to keep the hung-task and tracepoint bookkeeping in one place rather than four.

The order of operations is important: the waiter is fully initialized and linked **before** the lock is dropped, so `up()` can never observe a partially constructed waiter.

### 5.5 The Sleep Loop

The task goes through the following sleep loop:

```text
  ___down_common(sem, state, timeout)
         │
         ▼
  Allocate semaphore_waiter on kernel stack
  Add to sem->wait list (FIFO)
  waiter.task = current
  waiter.up   = false
         │
         ▼
  ┌──────────────────────────────────┐
  │           SLEEP LOOP             │
  │                                  │
  │  signal_pending_state(state)?    │
  │    YES ──► goto interrupted      │
  │                                  │
  │  timeout <= 0?                   │
  │    YES ──► goto timed_out        │
  │                                  │
  │  __set_current_state(state)      │
  │    [WRITE_ONCE current->__state] │
  │                                  │
  │  raw_spin_unlock_irq(&sem->lock) │
  │  [IRQs re-enabled; lock dropped] │
  │                                  │
  │  timeout = schedule_timeout()    │
  │    [scheduler runs another task] │
  │                                  │
  │  raw_spin_lock_irq(&sem->lock)   │
  │                                  │
  │  waiter.up == true?              │
  │    YES ──► return 0 (acquired)   │
  │    NO  ──► loop again            │
  └──────────────────────────────────┘
         │
    interrupted ──► sem_del_waiter; return -EINTR
    timed_out   ──► sem_del_waiter; return -ETIME
```

The steps in order:

1. Allocates a `struct semaphore_waiter` on its **own kernel stack**.
2. Adds itself to the semaphore's wait list.
3. Calls `__set_current_state(state)` — a `WRITE_ONCE` to `current->__state`, setting it to `TASK_UNINTERRUPTIBLE` (or whichever state was requested).
4. Releases the internal spinlock with `raw_spin_unlock_irq` (interrupts are re-enabled here deliberately, because we're about to sleep).
5. Calls `schedule_timeout()`, which tells the scheduler to switch away from this task.
6. On return from `schedule_timeout()`, re-acquires the spinlock and checks `waiter.up` — if `true`, the semaphore was handed to this task by `up()` and the task proceeds.

This sleep-release-reschedule pattern is the heart of all sleeping locks in the kernel.

A few details are easy to miss:

- **The state is set before the lock is dropped.** Setting it afterward would open a window in which `up()` could fire between the unlock and the state change; the wakeup would be delivered to a task that still looks runnable, and the subsequent sleep would never see it. Doing it under the lock means the waker either sees the sleeping state or the sleeper will see `waiter.up` on the next loop iteration.
- **`raw_spin_unlock_irq`, not `_irqrestore`.** The sleeping path deliberately enables interrupts. A caller that invoked `down()` with interrupts disabled is already violating the sleep contract; `might_sleep()` is there to catch it. Since the task is about to schedule, leaving IRQs masked would be a bug in any case.
- **`schedule_timeout()` guarantees `TASK_RUNNING` on return.** The woken task re-acquires the lock in a runnable state, checks `waiter.up`, and either returns or loops. No explicit `__set_current_state(TASK_RUNNING)` is needed at the check.
- **The timeout is recomputed by `schedule_timeout()`.** On each iteration it returns the remaining time in jiffies; the loop exits with `-ETIME` when the remaining time reaches zero. Because the timer is started before `schedule()` and deleted after it returns, a wakeup and a timeout racing each other resolve through `waiter.up` and the `timeout <= 0` test.

`schedule_timeout()` itself is interesting on modern kernels. It places a `struct process_timer` on the *stack* of the caller, initializes it as a timer whose callback wakes `current`, arms it for the deadline, and calls `schedule()`:

```c
expire = timeout + jiffies;

timer.task = current;
timer_setup_on_stack(&timer.timer, process_timeout, 0);
timer.timer.expires = expire;
add_timer(&timer.timer);
schedule();
timer_delete_sync(&timer.timer);

timer_destroy_on_stack(&timer.timer);
```

That is why the semaphore's slow path does not need to allocate a timer: the timeout machinery is entirely stack-based for the duration of one sleep. For `MAX_SCHEDULE_TIMEOUT`, `schedule_timeout()` skips all of this and calls `schedule()` directly.

### 5.6 Leaving the Wait List

The two exit paths — `timed_out` and `interrupted` — both call `sem_del_waiter` to remove the waiter from the list before returning the error code. This is necessary because `up()` walks `first_waiter` and would otherwise hand the semaphore to a task that has already given up waiting.

`sem_del_waiter` at [kernel/locking/semaphore.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/semaphore.c#L251-L264):

```c
static inline
void sem_del_waiter(struct semaphore *sem, struct semaphore_waiter *waiter)
{
    if (list_empty(&waiter->list)) {
        sem->first_waiter = NULL;
        return;
    }

    if (sem->first_waiter == waiter) {
        sem->first_waiter = list_first_entry(&waiter->list,
                                             struct semaphore_waiter, list);
    }
    list_del(&waiter->list);
}
```

If the list becomes empty after the removal (`list_empty`), `first_waiter` is set to `NULL` so `up()` takes the fast path next time. If the removed waiter was `first_waiter` but the list still has entries, `first_waiter` is advanced to the next entry before `list_del` unlinks this waiter. This keeps the `first_waiter` pointer valid at all times without requiring a separate list traversal.

The `list_empty()` test is really "am I the only waiter?" The list is circular and the head is embedded in the first waiter, so a lone waiter's `list` is self-referential. If the list has more than one element and the departing waiter is not at the head, `list_del()` alone is sufficient; `first_waiter` is unchanged.

The error paths in `___down_common()` and the handoff in `__up()` both call this helper, so the removal logic has exactly one implementation.

### 5.7 The `up()` Fast Path

The release side, `up()`, is the V() operation — it mirrors `down()` but increments the count and wakes a sleeper if one is waiting.

```c
void __sched up(struct semaphore *sem)
{
    unsigned long flags;
    DEFINE_WAKE_Q(wake_q);

    raw_spin_lock_irqsave(&sem->lock, flags);

    hung_task_sem_clear_if_holder(sem);

    if (likely(!sem->first_waiter))
        sem->count++;
    else
        __up(sem, &wake_q);

    if (trace_contended_release_enabled() && !wake_q_empty(&wake_q))
        trace_call__contended_release(sem);

    raw_spin_unlock_irqrestore(&sem->lock, flags);
    if (!wake_q_empty(&wake_q))
        wake_up_q(&wake_q);
}
```

Source: [kernel/locking/semaphore.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/semaphore.c#L220-L241).

The fast path (`!first_waiter`) simply increments `count`. It is the mirror image of the `down()` fast path: one lock, one branch, one increment, one unlock.

The `trace_contended_release_enabled()` line is a v7.3 addition that annotates releases which actually wake someone. It is compiled out when the tracepoint is disabled, and it runs while the lock is still held so the trace record is consistent with the state transition.

Note the shape of the function: the wake queue is a local variable, the lock is dropped **before** `wake_up_q()`, and the wakeup is skipped entirely when the queue is empty. That empty check matters: `wake_up_q()` on an empty queue is harmless but would still touch the scheduler path.

```text
caller invokes up(sem)
         │
         ▼
  raw_spin_lock_irqsave(&sem->lock)
         │
         ▼
   first_waiter == NULL?
    ┌────┴────┐
   YES        NO
    │          │
    ▼          ▼
  count++    __up(sem, &wake_q)
             ├─ sem_del_waiter(first_waiter)
             ├─ waiter->up = true
             └─ wake_q_add(&wake_q, waiter->task)
    │          │
    └────┬─────┘
         ▼
  raw_spin_unlock_irqrestore        ← lock dropped BEFORE wakeup
         │
         ▼
  wake_q_empty(&wake_q)?
    ┌────┴────┐
   YES        NO
    │          │
    ▼          ▼
  return    wake_up_q(&wake_q)
              └─ try_to_wake_up(task)
                   ├─ smp_mb__after_spinlock()  [DMB ISH on AArch64]
                   ├─ p->__state = TASK_RUNNING
                   └─ enqueue on CPU runqueue
```

### 5.8 `__up()` and the Wake Queue

The slow path delegates to `__up()` at [kernel/locking/semaphore.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/semaphore.c#L346-L354):

```c
static noinline void __sched __up(struct semaphore *sem,
                                  struct wake_q_head *wake_q)
{
    struct semaphore_waiter *waiter = sem->first_waiter;

    sem_del_waiter(sem, waiter);
    waiter->up = true;
    wake_q_add(wake_q, waiter->task);
}
```

`__up()` does three things in order. First, `sem_del_waiter` removes the first waiter from the list and advances `first_waiter` to the next entry (or sets it to `NULL` if the list is now empty) — exactly the same helper used in the `___down_common` error paths. Second, `waiter->up = true` is written while the semaphore's internal spinlock is still held; this is the **handoff flag** that the sleeping task checks when it wakes up inside `___down_common`. Third, `wake_q_add` appends the waiter's `task_struct` to the wake queue.

Importantly, `__up()` does not call `wake_up_process()` directly — it only queues the task. The actual wakeup happens after `raw_spin_unlock_irqrestore` in the public `up()` function, so the internal spinlock is never held when the scheduler is invoked. This two-phase approach avoids a situation where `wake_up_process()` tries to move the task to a run queue while we still hold the internal spinlock, which could cause lock ordering issues. The wake queue (`DEFINE_WAKE_Q`) is a singly linked list of tasks — the wakeup itself happens **after** the spinlock is released.

The wake queue also solves a lifetime problem. `wake_q_add()` takes a reference on the task, so the `task_struct` cannot disappear between queueing and waking even if the task exits in the meantime. `wake_up_q()` drops that reference after `wake_up_process()`.

`wake_up_q()` eventually calls `try_to_wake_up()` per task, which sets `p->__state = TASK_RUNNING` and enqueues the task on an appropriate CPU's run queue. On AArch64, this involves a `smp_mb()` (`DMB ISH`) before reading the task's state, ensuring all prior stores from the releasing CPU are visible to the waking CPU before it begins executing the task.

### 5.9 Memory Ordering Around the Sleep

A semaphore is a lock, so it must provide the same acquire/release guarantees as any other lock: stores performed before `up()` must be visible to the task that acquires the semaphore afterward, and stores performed inside the critical section must not be reordered before the acquisition. The implementation gets this from two places — the internal `raw_spinlock_t`, and the wakeup protocol.

**The critical section is ordered by the internal lock.** `down()` takes `sem->lock`, decrements `count`, and releases it; `up()` takes the same lock. The qspinlock's acquire and release semantics order the surrounding memory accesses, so a task that acquires the semaphore after `up()` has released it observes all the stores made inside the releasing task's critical section. That is the ordinary lock contract, and it is why the semaphore's data protection works on a weakly ordered CPU.

**The handoff flag needs no extra barrier.** `waiter.up = true` is written under `sem->lock`, and the sleeping task reads it under the same lock after `schedule_timeout()` returns. The lock's release/acquire pair orders the flag and everything the releaser did before setting it. This is why `___down_common()` can use plain stores and loads for `up`.

**The task state uses `__set_current_state()`, not `set_current_state()`.** The difference is a barrier:

```c
#define __set_current_state(state_value)                                \
    do {                                                                \
        debug_normal_state_change((state_value));                       \
        trace_set_current_state(state_value);                           \
        WRITE_ONCE(current->__state, (state_value));                    \
    } while (0)

#define set_current_state(state_value)                                  \
    do {                                                                \
        debug_normal_state_change((state_value));                       \
        trace_set_current_state(state_value);                           \
        smp_store_mb(current->__state, (state_value));                  \
    } while (0)
```

The barrier-free version is correct here because the wakeup condition (`waiter.up`) is checked under the same lock that the waker uses to set it. The comment in [include/linux/sched.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/sched.h#L215-L245) states the rule: use `__set_current_state()` when *"the CONDITION test and condition change and wakeup are under the same lock."* That is exactly the semaphore's situation. Using `set_current_state()` would add a `DMB ISH` per sleep for no benefit.

**The wake queue supplies the cross-CPU ordering.** `wake_q_add()` does not publish the task with a plain store; the work happens in `__wake_q_add()`:

```c
smp_mb__before_atomic();
if (unlikely(cmpxchg_relaxed(&node->next, NULL, WAKE_Q_TAIL)))
    return false;
```

The `smp_mb__before_atomic()` ensures that a pending wakeup observes the sleeper's state even in the race where the task was already queued by someone else. `wake_up_process()` then performs a full barrier, which pairs with the queueing so that a wakeup cannot be lost. On AArch64 these barriers are `DMB ISH` operations.

Put together: the internal lock orders the data and the handoff flag; the task-state store is barrier-free because it is inside that lock's scope; and the wake queue supplies the barrier needed to publish a task that is being moved between CPUs. None of these are decorative — removing any one of them produces a lost-wakeup or a stale-data bug that only appears on a weakly ordered machine.

### 5.10 End-to-End Walkthrough

Consider two tasks and a semaphore initialized with count 1.

**Task A acquires first.**

```text
Task A (CPU 0)                          Task B (CPU 1)
──────────────                          ──────────────
down(sem)
  raw_spin_lock_irqsave
  count = 1 → 0
  hung_task_sem_set_holder(A)
  raw_spin_unlock_irqrestore
  return 0
  (inside CS)
```

**Task B arrives while A holds the semaphore.**

```text
Task A (CPU 0)                          Task B (CPU 1)
──────────────                          ──────────────
(inside CS)                             down(sem)
                                          raw_spin_lock_irqsave
                                          count == 0
                                          __down(sem)
                                            waiter on B's stack
                                            linked as first_waiter
                                            waiter.up = false
                                            __set_current_state(
                                              TASK_UNINTERRUPTIBLE)
                                            raw_spin_unlock_irq
                                            schedule_timeout(MAX)
                                            → sleeps
```

At this point `count == 0`, `first_waiter` points at B's stack frame, and B is off the run queue.

**Task A releases.**

```text
Task A (CPU 0)                          Task B (CPU 1)
──────────────                          ──────────────
up(sem)
  raw_spin_lock_irqsave
  first_waiter != NULL
  __up:
    sem_del_waiter(first_waiter)
    waiter->up = true
    wake_q_add(&wake_q, B)
  trace_call__contended_release
  raw_spin_unlock_irqrestore
  wake_up_q
    try_to_wake_up(B)
      p->__state = TASK_RUNNING
      enqueue B on a runqueue
  return
                                        (scheduled back in)
                                        raw_spin_lock_irq
                                        waiter.up == true
                                        hung_task_sem_set_holder(B)
                                        return 0
                                        (inside CS)
```

`count` stayed at zero throughout the handoff: the semaphore was transferred directly from A to B, not released and re-acquired. That is the meaning of the handoff flag. If a third task C had called `down()` between A's `up()` and B's wakeup, C would have found `count == 0` and registered itself as the new `first_waiter`; it would still enter after B, because B already owns the handoff and will hand the semaphore to C when it releases.

**What if B times out instead?** B's `schedule_timeout()` returns zero, the loop re-checks `waiter.up` (still false), then `timeout <= 0` sends it to `timed_out`, where `sem_del_waiter()` unlinks it and the function returns `-ETIME`. `count` remains zero. If A then calls `up()`, `first_waiter` is `NULL`, so `count` becomes one and the next `down()` takes the fast path.

**What if B is interrupted?** With `down_interruptible()`, `signal_pending_state()` is true at the top of the loop, so B jumps to `interrupted`, unlinks itself, and returns `-EINTR`. As with the timeout case, the semaphore is not held and must not be released.

---

## 6. A Practical Example: One Hardware Resource

A driver managing a single hardware resource that user-space threads compete over:

```c
struct hw_resource {
    struct semaphore access_sem;
    void __iomem *regs;
};

static int hw_resource_init(struct hw_resource *res)
{
    sema_init(&res->access_sem, 1);
    return 0;
}

static int hw_resource_use(struct hw_resource *res)
{
    if (down_interruptible(&res->access_sem))
        return -ERESTARTSYS;

    /* exclusive access to hardware */
    writel(0x1, res->regs + CTRL_REG);

    up(&res->access_sem);
    return 0;
}
```

When a second thread calls `hw_resource_use()` while the first holds the semaphore, the scheduler puts it to sleep in `TASK_INTERRUPTIBLE` state. If the user sends a signal (Ctrl-C), `down_interruptible()` returns `-EINTR`, and the thread exits gracefully. The hardware is never accessed by both threads simultaneously.

Three things in this example are deliberate:

- **The lock protects a resource, not a code path.** `access_sem` lives next to the register mapping it guards.
- **The critical section contains only hardware access.** No allocation, no user copy, no sleeping call. If the section needed any of those, a semaphore would still be legal (unlike with a spinlock) but the hold time would grow and the choice of a mutex would deserve reconsideration.
- **The error path does not call `up()`.** A failed `down_interruptible()` means the semaphore was never acquired.

`-ERESTARTSYS` is meaningful when the caller is a syscall that can be restarted; in an `ioctl()` or `read()`/`write()` handler the same value tells the syscall layer to restart or return `-EINTR` depending on `SA_RESTART`. In other contexts, `-EINTR` may be more appropriate.

Counting semaphore showing the count field decrement on each acquisition:

```c
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/semaphore.h>
#include <linux/slab.h>

MODULE_LICENSE("GPL");

struct semaphore *mysem;

static int __init test_hello_init(void)
{
    mysem = kmalloc(sizeof(*mysem), GFP_KERNEL);
    if (!mysem)
        return -ENOMEM;

    sema_init(mysem, 4);
    pr_info("semaphore count:%u\n", mysem->count);
    down(mysem);
    pr_info("semaphore count:%u\n", mysem->count);
    pr_info("Starting critical region\n");
    pr_info("Ending critical region\n");
    up(mysem);
    pr_info("semaphore count:%u\n", mysem->count);
    kfree(mysem);
    return -1;
}

static void __exit test_hello_exit(void) {}

module_init(test_hello_init);
module_exit(test_hello_exit);
```

The module prints the count at each step; the middle print happens while the semaphore is held. That is safe here only because no other task can access `mysem`. In real code, reading `sem->count` without the internal lock is a data race; the header's "don't access members directly" warning applies.

---

## 7. Real-World Usage: InfiniBand Subnet Manager

The InfiniBand MAD (Management Agent Device) driver in [drivers/infiniband/core/user_mad.c](https://github.com/torvalds/linux/blob/v7.3-rc7/drivers/infiniband/core/user_mad.c) uses a binary semaphore to serialize access to the Subnet Manager port:

```c
struct ib_umad_port {
    struct semaphore sm_sem;    /* line 98 */
    /* ... */
};
```

Initialized at port creation:

```c
sema_init(&port->sm_sem, 1);  /* line 1312 */
```

And acquired when a user-space process opens the SM device file:

```c
if (filp->f_flags & O_NONBLOCK) {
    if (down_trylock(&port->sm_sem)) {
        ret = -EAGAIN;
        goto fail;
    }
} else {
    if (down_interruptible(&port->sm_sem)) {   /* line 1107 */
        ret = -ERESTARTSYS;
        goto fail;
    }
}
```

This is a canonical pattern: non-blocking opens get `down_trylock`, blocking opens get `down_interruptible`, and the semaphore is released in an error-unwind label `err_up_sem`. The SM port cannot be reconfigured by two processes simultaneously — the semaphore enforces that.

The release side is split across the close path:

```c
up(&port->sm_sem);      /* line 1147, ib_umad_sm_close() */
```

and the open error path:

```c
err_up_sem:
    up(&port->sm_sem);
```

This is a good illustration of the non-ownership property. The acquire happens in `ib_umad_sm_open()`; the release happens in `ib_umad_sm_close()` or in the open failure path. If the process exits without closing, the file-release path still runs and still releases the semaphore.

---

## 8. Real-World Usage: Character Device Driver

A common pattern in character drivers is to use a static binary semaphore to ensure only one process holds the device open at a time, blocking any subsequent `open()` call until the current holder closes the file.

Character device driver serialising open/release with a static binary semaphore:

```c
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/kdev_t.h>
#include <linux/fs.h>
#include <linux/device.h>
#include <linux/cdev.h>
#include <linux/uaccess.h>
#include <linux/semaphore.h>

MODULE_LICENSE("GPL");

#define MAX_SIZE        1024

static int base_minor = 0;
static char *device_name = "msg";
static int count = 1;
static dev_t devicenumber;
static struct class *class;
static struct device *device;
static struct cdev mycdev;
static char kernel_buffer[MAX_SIZE];
static int buffer_index;

DEFINE_SEMAPHORE(my_lock, 1);

static int device_open(struct inode *inode, struct file *file)
{
    pr_info("%s: trying to acquire semaphore on cpu:%d\n",
            __func__, smp_processor_id());
    down(&my_lock);
    pr_info("%s: semaphore acquired on cpu:%d\n",
            __func__, smp_processor_id());
    file->f_pos = 0;
    buffer_index = 0;
    return 0;
}

static int device_release(struct inode *inode, struct file *file)
{
    pr_info("%s: releasing semaphore on cpu:%d\n",
            __func__, smp_processor_id());
    up(&my_lock);
    return 0;
}

static ssize_t device_read(struct file *file, char __user *user_buffer,
                            size_t read_count, loff_t *offset)
{
    int bytes_to_read;

    if (buffer_index <= *offset)
        return 0;
    bytes_to_read = min_t(int, read_count, buffer_index - *offset);
    bytes_to_read -= copy_to_user(user_buffer,
                                  kernel_buffer + *offset, bytes_to_read);
    *offset += bytes_to_read;
    return bytes_to_read;
}

static ssize_t device_write(struct file *file, const char __user *user_buffer,
                             size_t write_count, loff_t *offset)
{
    int available = MAX_SIZE - *offset;
    int bytes_to_write = min_t(int, write_count, available);

    if (bytes_to_write == 0)
        return -ENOSPC;
    bytes_to_write -= copy_from_user(kernel_buffer + *offset,
                                     user_buffer, bytes_to_write);
    *offset += bytes_to_write;
    buffer_index += bytes_to_write;
    return bytes_to_write;
}

static const struct file_operations device_fops = {
    .read    = device_read,
    .write   = device_write,
    .open    = device_open,
    .release = device_release,
};

static int __init test_hello_init(void)
{
    if (alloc_chrdev_region(&devicenumber, base_minor, count, device_name))
        return -ENODEV;
    class = class_create("myclass");
    device = device_create(class, NULL, devicenumber, NULL, device_name);
    cdev_init(&mycdev, &device_fops);
    mycdev.owner = THIS_MODULE;
    cdev_add(&mycdev, devicenumber, count);
    return 0;
}

static void __exit test_hello_exit(void)
{
    device_destroy(class, devicenumber);
    class_destroy(class);
    cdev_del(&mycdev);
    unregister_chrdev_region(devicenumber, count);
}

module_init(test_hello_init);
module_exit(test_hello_exit);
```

Every `open()` call acquires the semaphore; every `close()` releases it. A second process that calls `open()` while the first has the file open will sleep in `down()` until `device_release` calls `up()`. Since `down()` is called in file-open context (process context, schedulable), sleeping is legal. `DEFINE_SEMAPHORE(my_lock, 1)` places the semaphore in the module's `.data` section — no `sema_init` call is needed at `module_init` time.

Two caveats about this example as production code:

- `down()` is deprecated and unkillable. A driver that may block a process indefinitely should use `down_interruptible()` and return `-ERESTARTSYS` on failure, so that a hung or killed user process does not pin the device forever.
- The initialization path ignores errors. `class_create()` returns an `ERR_PTR()` on failure and `device_create()` can fail; a real driver must check both and unwind with `class_destroy()`, `cdev_del()`, and `unregister_chrdev_region()`.

The example also shows the intended symmetry: the semaphore is acquired in `open()` and released in `release()`, not in `read()` or `write()`. That gives one process exclusive ownership of the *file*, while the actual data buffer is still per-open (`file->f_pos`) and needs no additional lock in this design.

---

## 9. Producer/Consumer with Counting Semaphores

Two kthreads sharing a character buffer, with a single binary semaphore enforcing mutual exclusion:

kthread producer and consumer sharing a char buffer via a binary semaphore:

```c
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/semaphore.h>
#include <linux/slab.h>
#include <linux/kthread.h>
#include <linux/delay.h>

MODULE_LICENSE("GPL");

static struct semaphore *mysem;
static struct task_struct *thread1, *thread2;
static char buffer[10];

static int producer(void *arg)
{
    char ch = 'A';

    while (!kthread_should_stop()) {
        pr_info("producer: waiting for semaphore on cpu %d\n",
                smp_processor_id());
        down(mysem);
        pr_info("producer: acquired on cpu %d\n", smp_processor_id());
        memset(buffer, ch, sizeof(buffer) - 1);
        buffer[sizeof(buffer) - 1] = '\0';
        msleep(2000);
        pr_info("producer: releasing (wrote '%c')\n", ch);
        up(mysem);
        ch++;
    }
    return 0;
}

static int consumer(void *arg)
{
    while (!kthread_should_stop()) {
        pr_info("consumer: waiting for semaphore on cpu %d\n",
                smp_processor_id());
        down(mysem);
        pr_info("consumer: acquired on cpu %d\n", smp_processor_id());
        pr_info("consumer: data = \"%s\"\n", buffer);
        memset(buffer, 0, sizeof(buffer));
        msleep(2000);
        pr_info("consumer: releasing\n");
        up(mysem);
    }
    return 0;
}

static int __init test_hello_init(void)
{
    mysem = kmalloc(sizeof(*mysem), GFP_KERNEL);
    if (!mysem)
        return -ENOMEM;
    memset(buffer, 0, sizeof(buffer));
    sema_init(mysem, 1);
    thread1 = kthread_run(producer, NULL, "producer");
    thread2 = kthread_run(consumer, NULL, "consumer");
    return 0;
}

static void __exit test_hello_exit(void)
{
    kthread_stop(thread1);
    kthread_stop(thread2);
    kfree(mysem);
}

module_init(test_hello_init);
module_exit(test_hello_exit);
```

The binary semaphore (count=1) ensures only one of the two kthreads is inside the shared buffer region at a time. The producer fills the buffer then releases; the consumer acquires only after the producer releases. This pattern provides mutual exclusion but does not coordinate ordering — the consumer may run again before the producer has written new data, and the producer may overwrite data the consumer has not yet read.

### 9.1 The ring-buffer pattern

For true producer/consumer flow control you need two semaphores: one counting available slots (initially N) that the producer decrements before writing, and one counting filled slots (initially 0) that the consumer decrements before reading. Each release increments the other's semaphore, creating back-pressure in both directions. With a ring of `N` slots:

```c
static DEFINE_SEMAPHORE(empty_slots, N);   /* producer waits here */
static DEFINE_SEMAPHORE(filled_slots, 0);  /* consumer waits here */

/* producer */
down(&empty_slots);        /* wait for a free slot */
buffer[in] = value;
in = (in + 1) % N;
up(&filled_slots);         /* publish one item */

/* consumer */
down(&filled_slots);       /* wait for a published item */
value = buffer[out];
out = (out + 1) % N;
up(&empty_slots);          /* return one slot */
```

With a ring buffer of N slots, the producer blocks when the ring is full and the consumer blocks when it is empty. Unlike the single-semaphore version, this pattern cannot overwrite unread data or read stale data, and it does not need a separate mutex when there is exactly one producer and one consumer. With multiple producers or consumers, the index updates also need protection — another semaphore, a mutex, or a spinlock, depending on context.

### 9.2 A real counting semaphore in the tree

The canonical in-tree counting semaphore is the module loader's concurrency limit. [kernel/module/kmod.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/module/kmod.c#L45-L48) defines:

```c
#define MAX_KMOD_CONCURRENT 50
static DEFINE_SEMAPHORE(kmod_concurrent_max, MAX_KMOD_CONCURRENT);
```

`request_module()` then does a bounded acquire, and releases on every exit path:

```c
ret = down_timeout(&kmod_concurrent_max, MAX_KMOD_ALL_BUSY_TIMEOUT * HZ);
if (ret) {
    pr_warn_ratelimited("request_module: modprobe %s cannot be processed, kmod busy with %d threads ...",
                        module_name, MAX_KMOD_CONCURRENT, MAX_KMOD_ALL_BUSY_TIMEOUT);
    return ret;
}
...
out:
    up(&kmod_concurrent_max);
```

Source: [kernel/module/kmod.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/module/kmod.c#L159-L178).

Every property of the design is intentional:

- **The count is the resource.** Fifty slots means at most fifty helper processes at once, which bounds the damage from a recursive module dependency.
- **The timeout is part of the contract.** Without it, a dependency loop would queue requests forever; with it, the fifty-first request fails after five seconds and the caller sees an error.
- **Release is path-based, not owner-based.** `up()` runs on every return path, including the duplicate-request and call-failure paths, which is exactly the cross-context release a semaphore permits.
- **No priority inheritance is wanted here.** The waiters are user-triggered helper invocations, not real-time tasks.

This is the shape the primitive is for: a pool of N identical, sleepable resources with a bounded wait. A mutex cannot express N > 1, and a completion signals an event rather than a slot.

---

## 10. Spinlock vs. Semaphore

| Factor | Spinlock | Semaphore |
|---|---|---|
| Contention behavior | Busy-waits (burns CPU) | Sleeps (yields CPU) |
| Context | Any (IRQ, softirq, task) | Process context only |
| Lock duration | Very short (microseconds) | Can be long (ms range) |
| Preemption | Disabled while held | Preemption allowed |
| Can sleep while held? | No | Yes |
| Count > 1 possible? | No | Yes |
| Ownership enforced? | No | No |
| Overhead | Very low | Higher (scheduler involvement) |

### 10.1 The Decision Tree

```text
  Need to acquire lock from IRQ/softirq context?
  ┌──────────┴──────────┐
 YES                    NO
  │                      │
  ▼                      ▼
Spinlock        Critical section may block
                (copy_to_user, DMA, I/O)?
                ┌──────────┴──────────┐
               YES                    NO
                │                      │
                ▼                      ▼
           Semaphore              Critical section
           (or mutex)             very short?
                                  ┌────┴────┐
                                 YES        NO
                                  │          │
                                  ▼          ▼
                               Spinlock   Semaphore
                                          (or mutex)
```

The key architectural reason comes down to what happens on AArch64 when a spinlock is taken but unavailable: the CPU idles on a `WFE` (Wait For Event) instruction in the queued-spinlock slow path, burning cycles and preventing those cycles from being used by other runnable tasks. `WFE` reduces the power and instruction cost of the wait, but it does not let another task run. For long critical sections this is wasteful. A sleeping lock allows the scheduler to run another task entirely.

Use a spinlock when the critical section is very short (a few instructions), when the lock may be acquired in interrupt context, or when you cannot afford to sleep (inside a tasklet, softirq, or with `rcu_read_lock()` held). Use a semaphore when the critical section may block, when you need a counting lock, or when you are in process context and sleeping is acceptable.

### 10.2 Key Differences at a Glance

| Property | Spinlock | Semaphore |
|---|---|---|
| Waiting behavior | Busy-loops (LDAXR/STXR on AArch64) | Sleeps (`schedule_timeout`) |
| IRQ context safe | Yes | Only `down_trylock()` and `up()` |
| Preemption while held | Disabled | Allowed |
| Scheduling latency impact | Increases (preemption off) | None |
| Lock hold duration | Microseconds | Milliseconds or longer |
| Recursive acquisition | Deadlocks immediately | Count 1: deadlocks; count > 1: succeeds, but must release twice |
| Ownership model | No | No (any task can `up()`) |
| Count > 1 | No | Yes |
| `lockdep` ownership checks | Yes (must release on same CPU) | No release-owner enforcement |
| Can sleep while held | No — illegal | Yes — safe |
| Can hold while calling `down()` | No — deadlock risk | No — holding spinlock while sleeping is illegal |
| Suitable for user-space sync | No | Yes (sleeping is legal in syscall context) |
| Memory overhead | Tiny (4 bytes, one `qspinlock`) | Larger (`lock` + `count` + `first_waiter`) |
| Wakeup mechanism | `SEV` broadcast / MCS queue | `wake_q` + `try_to_wake_up()` |

"Recursive acquisition" deserves a note. A semaphore does not track owners, so a task that calls `down()` twice on a count-2 semaphore will succeed both times; the danger is that it must also call `up()` twice, and nothing enforces that. With a count-1 semaphore the second `down()` self-deadlocks exactly like a spinlock. Neither behaviour is recursion support; neither is safe to rely on.

### 10.3 Why Long Sections Need a Sleeping Lock

A factor often overlooked is **scheduling latency**. A spinlock disables kernel preemption while held, which can delay other runnable tasks on the same CPU. A semaphore does not disable preemption, so code holding it remains preemptible and scheduling latency is unaffected.

When synchronizing with user space — common in driver `read()`/`write()` handlers and `ioctl()` implementations — semaphores are frequently the only viable option, because operations like `copy_to_user()` and page faults can sleep and a spinlock cannot be held across them. The same reasoning applies to `kmalloc(GFP_KERNEL)`, I/O waits, and any function that might take a mutex internally.

The inverse is also true: a semaphore is not a drop-in replacement for a spinlock in atomic context. If interrupt handlers share the state, a semaphore cannot be the only lock. The usual arrangement is a spinlock for the interrupt-visible state and a semaphore (or mutex) for the sleepable, process-context work above it.

---

## 11. Writing Correct Semaphore Code

### 11.1 Ownership

Unlike mutexes, **there is no concept of ownership**. The task that calls `up()` does not have to be the task that called `down()`. This is both their strength and their danger — it enables the producer/consumer pattern and the open/close pattern in §8, but it also means lockdep cannot enforce "release by owner" rules.

The practical consequences:

- A bug that releases the semaphore from the wrong context will not be caught by lockdep. It may show up much later as a count that drifts or a task that blocks forever.
- A task that acquires and then exits without releasing leaks a slot permanently. Nothing detects the leak, because there is no owner to reclaim from.
- `up()` can be called by a task that never called `down()`. That is legal and is exactly how event signalling with a binary semaphore works — but it is also how a stray `up()` silently corrupts the count.

The kernel documentation is explicit that the lack of owners is also why `PREEMPT_RT` cannot give semaphores priority inheritance: an unknown owner cannot be boosted.

### 11.2 Context Rules

- `down_trylock()` and `up()` are **safe from interrupt context**. `down_trylock()` never sleeps, and `up()` only takes the internal spinlock with IRQs disabled.
- The other `down` variants are **not** safe from interrupt context in general, because they may sleep. As noted in §4.2, the kernel has historically called blocking `down()` from interrupt context in paths where the count is known to be positive, which is why every variant uses `raw_spin_lock_irqsave`. That idiom is not a guarantee.
- A semaphore's internal `raw_spinlock_t` is always acquired with **IRQ save/restore** (`raw_spin_lock_irqsave`) — even in `down()` — because `up()` can be called from an interrupt handler. Without IRQ disabling, you could take the lock in process context, get interrupted, and then deadlock trying to take the same lock inside the IRQ handler.
- Because the internal lock is a `raw_spinlock_t`, it remains a real spinlock even on `PREEMPT_RT`. The semaphore itself changes semantics less than `spinlock_t` does on RT, but it is still a sleeping lock and still cannot be used from hardirq context.

### 11.3 Never Hold a Spinlock Across `down()`

**You cannot hold a spinlock while trying to acquire a semaphore.** Acquiring a semaphore may put the calling task to sleep. Sleeping while holding a spinlock is illegal — the spinlock remains held, preemption may be disabled, and on a uniprocessor system no other task can run to release the semaphore, resulting in a deadlock.

On an SMP system the failure is subtler: another CPU can release the semaphore and wake the sleeper, but the sleeper cannot be scheduled while it is in an atomic section. The result is a hang that looks like a lost wakeup. `CONFIG_DEBUG_ATOMIC_SLEEP` catches the common cases through `might_sleep()`.

The reverse is fine and is a normal design: **you can sleep while holding a semaphore without deadlocking.** If another task tries to acquire the same semaphore while you are sleeping, it will be placed on the wait queue and sleep in turn. It does not deadlock — it just waits until you eventually wake up and call `up()`. This is in sharp contrast to spinlocks, where sleeping while holding is illegal.

### 11.4 Lock Ordering

**Lock ordering still matters.** If you take two semaphores in different orders on different code paths, you can deadlock:

```c
/* Consistent order: A then B. */
down(&A);
down(&B);
...
up(&B);
up(&A);
```

The rule is the same as for any lock: every path that takes both must take them in the same global order. A cycle in the dependency graph is a deadlock waiting for the wrong interleaving.

The important surprise is that **lockdep cannot see this cycle**. `down()` and `up()` never call `lock_acquire()` or `lock_release()` on a semaphore's own lockdep map, and `struct semaphore` has no such map; the only map is embedded inside the internal `raw_spinlock_t`:

- It is taken with `raw_spin_lock_irqsave()` and dropped before `schedule_timeout()`, so it is never held across another `down()`.
- Consequently lockdep builds no edge from semaphore A to semaphore B, and an ABBA deadlock between two semaphores produces **no lockdep report at all** — just a hang.
- The same blind spot applies to a semaphore-versus-mutex cycle. The mutex side is instrumented, but the semaphore side contributes no held-lock edge.

The class granularity described in Section 3.3 therefore matters only for diagnosing the internal spinlock. It does not give lockdep visibility into semaphore ordering, and it should not be read as partial coverage of the semaphore itself.

Because static analysis is absent, correct ordering must be established by design and verified dynamically:

- Document the order next to the declarations and at every multi-lock site.
- Keep the number of semaphores that are ever held simultaneously small; prefer one semaphore plus a mutex or completion where possible.
- If mutual exclusion and lockdep coverage are what you need, use a `mutex` instead. Deadlock detection is one of the concrete reasons the kernel steers new code there.
- Test with contention and with the hung-task detector enabled (Section 13); an ABBA bug will surface as a hung task, not as a lockdep splat.

**Non-owner release** compounds the problem. Even if lockdep could see the acquisition order, its model assumes that the task that acquires a lock also releases it. A semaphore handed from one task to another (the normal `up()` path, and the `open()`/`close()` pattern) breaks that assumption.

### 11.5 Priority Inversion

Semaphores do not participate in **priority inheritance**. If a high-priority task waits on a semaphore held (conceptually) by a low-priority task, priority inversion can occur and there is no mechanism to prevent it. Mutexes with `CONFIG_RT_MUTEX` support PI on `PREEMPT_RT`; semaphores do not, for the same reason they have no owner: the kernel cannot know whom to boost.

The classic three-task scenario applies:

1. A low-priority task L holds the semaphore.
2. A high-priority task H blocks on it.
3. A medium-priority task M becomes runnable and preempts L.

L cannot run to release the semaphore, so H waits for M — an unbounded inversion. A mutex with PI would boost L to H's priority and let it finish. A semaphore cannot.

On a non-RT kernel, priority inversion is bounded by the fact that kernel preemption is limited and the holder will eventually run; on `PREEMPT_RT` it is a real-time hazard, and the kernel documentation says so explicitly.

### 11.6 Debugging and Observability

- **Lockdep** (`CONFIG_PROVE_LOCKING`, `CONFIG_DEBUG_LOCK_ALLOC`) validates the much narrower internal `raw_spinlock_t`. It does **not** model the semaphore itself and cannot catch an ABBA cycle between semaphores, wrong-task release, or a leaked slot.
- **`CONFIG_DEBUG_ATOMIC_SLEEP`** turns `might_sleep()` into a useful check and warns when a blocking `down` variant is called in atomic context or a spinlock is held across it.
- **`CONFIG_DEBUG_LIST`** validates the circular waiter list, so corruption from a lifetime bug is caught at the next `list_add_tail()` or `list_del()`.
- **`CONFIG_DETECT_HUNG_TASK_BLOCKER`** records the last fast-path holder in `sem->last_holder` and prints it when the hung-task watchdog fires. It is the closest thing to owner diagnostics that a semaphore has.
- **Contention tracepoints** (`trace_contention_begin` / `trace_contention_end`) feed `perf lock` and BPF tools. They show how often the slow path is taken and how long waiters block.
- **`sem_last_holder()`** exposes the diagnostic holder pointer to custom tooling; it returns zero when the configuration is off.

None of these tools can prove that a semaphore is used correctly. The lockdep limitation is structural, not a configuration error: the primitive is invisible to the lock graph. Testing therefore has to lean on stress, hung-task detection, and explicit invariant checks, which Section 13 develops in detail.

---

## 12. Why Semaphores Are Being Replaced

In modern kernel code, semaphores are being phased out in favor of two more narrowly-scoped primitives. The choice depends on what you actually need:

```text
  What do you need?
  │
  ├─ Mutual exclusion (one holder, same task acquires and releases)?
  │    └─► mutex  [include/linux/mutex.h]
  │         ├─ ownership enforced by lockdep
  │         ├─ optimistic spinning via osq_lock
  │         └─ priority inheritance with CONFIG_RT_MUTEX
  │
  ├─ One task signals another that an event occurred?
  │    └─► completion  [include/linux/completion.h]
  │         ├─ complete() / wait_for_completion()
  │         ├─ explicit one-shot semantics
  │         └─ uses swait_queue_head (lower overhead)
  │
  └─ Limit concurrent access to N identical resources?
       └─► counting semaphore  [include/linux/semaphore.h]
            └─ no better replacement exists for true N > 1 case
```

### 12.1 `mutex`

**Mutex** (`struct mutex`, [include/linux/mutex.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/mutex.h)) enforces **ownership semantics**: only the acquiring task can release it, lockdep detects misuse at runtime, and the kernel can print the `mutex_lock` owner in `show_held_locks()`. Mutexes also support **optimistic spinning** (via `osq_lock`) — before sleeping, a mutex waiter briefly spins watching for the lock owner to release, which dramatically reduces latency when the owner is running on another CPU. This optimization alone makes mutexes faster than semaphores in most real workloads.

The ownership rule is also a safety property: a mutex cannot be released from an interrupt handler, so the compiler and lockdep can reason about its lifetime in a way they cannot for a semaphore.

### 12.2 `completion`

**Completion** (`struct completion`, [include/linux/completion.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/completion.h)) is cleaner than a binary semaphore initialized to 0 for event notification. The semantics are explicit: `complete()` signals, `wait_for_completion()` blocks. The name documents intent, and the kernel provides timeout and interruptible variants. Internally, a completion uses a `swait_queue_head` (a simpler wait queue variant with fewer features but lower overhead than `wait_queue_head_t`).

A completion also makes the one-shot nature of the event clear. A binary semaphore used for signalling can accumulate multiple `up()` calls and let a waiter through more than once; a completion's state machine is designed around "this happened" rather than "a slot is free."

### 12.3 The Counting Case Remains

The one case with no good replacement is limiting concurrent access to N identical resources. A mutex serializes to one; a completion is one-shot. If you genuinely need N holders, a counting semaphore is still the primitive. What has changed is that new code is expected to use semaphores **only** for that case — not for mutual exclusion and not for event signalling.

### 12.4 The Problems That Drove the Shift

The specific problems with semaphores that drove this shift:

| Problem | Impact | Better alternative |
|---|---|---|
| No ownership tracking | `lockdep` cannot detect wrong-task release; cross-task unlock bugs go unnoticed at compile time | `mutex` — owner-only release enforced by lockdep |
| No optimistic spinning | Waiters always sleep, even when the holder is actively running on another CPU | `mutex` — spins briefly via `osq_lock` before sleeping, reducing latency |
| No priority inheritance | A high-priority task blocked on a low-priority holder suffers priority inversion with no remedy | `mutex` with `CONFIG_RT_MUTEX` — supports priority propagation |
| Semantic ambiguity | A binary semaphore for mutual exclusion is syntactically identical to one used for event signalling | `mutex` (mutual exclusion) or `completion` (event notification) |
| Deprecated `down()` | Forces `TASK_UNINTERRUPTIBLE`; inflates load average; task cannot be killed while waiting | `down_killable()` or `down_interruptible()` |
| Invisible to lockdep | `down()`/`up()` do not create lock-graph edges, so an ABBA deadlock between semaphores is never reported | `mutex` — fully instrumented, with order validation |

### 12.5 `PREEMPT_RT`

`PREEMPT_RT` does **not** change the semaphore implementation, unlike `spinlock_t` and `rwlock_t`, which become rt-mutex based. The reason is stated in [Documentation/locking/locktypes.rst](https://github.com/torvalds/linux/blob/v7.3-rc7/Documentation/locking/locktypes.rst#L113-L130): counting semaphores have no concept of owners, so the kernel cannot provide priority inheritance for them — *"an unknown owner cannot be boosted."*

Two consequences follow:

- Blocking on a semaphore can result in priority inversion on a real-time kernel. A mutex is the right choice when the lock protects a single resource and the RT guarantee matters.
- The internal `raw_spinlock_t` stays raw on RT, so `up()` and `down_trylock()` remain usable from hardirq context. The sleeping paths (`down()`, `down_interruptible()`, `down_killable()`, `down_timeout()`) still require process context.

For new kernel code the guidance is simple: need mutual exclusion → mutex; need to signal event completion → completion; need to limit concurrent access to N resources → counting semaphore (no good replacement exists for the true counting case). In all other scenarios, the specialized primitives carry better debuggability, lower latency, and cleaner semantics.

---

## 13. Testing Semaphores

Semaphores are awkward to test for three reasons. Their failures are timing-dependent, so a passing run proves little. Their most valuable diagnostic, lockdep, is blind to them. And the kernel ships no dedicated test suite for `struct semaphore`, so the test has to be built rather than invoked.

A workable strategy has three layers:

1. **Deterministic API tests** for counting, return values, timeouts, and signal behaviour. These are fast and repeatable.
2. **Contention and stress tests** that run many threads through the slow path and check invariants, so lost wakeups and mutual-exclusion violations have a chance to appear.
3. **Watchdogs and observability** that turn a hang into a report: hung-task detection, tracepoints, `perf lock`, and the sanitizers.

No single layer is sufficient. The first cannot reach the race, the second cannot prove absence of a race, and the third only reports what already went wrong.

### 13.1 What Deserves a Test

| Property | Failure mode | Best test |
|---|---|---|
| Counting | `count` drifts, slot leak, negative count | Deterministic acquire/release sequence |
| Mutual exclusion at count 1 | Two tasks in the critical section | Multi-thread invariant check |
| N-slot limit | More than N concurrent holders | High-water-mark counter |
| Blocking and wakeup | Lost wakeup, task sleeps forever | Timeout on acquire plus hung-task detector |
| Handoff | Waiter woken but does not own the semaphore | Stress with a shared counter and a timeout |
| `down_trylock()` result | Caller misreads the inverted return value | One-shot API assertions |
| `down_timeout()` | Returns success on timeout, or `-ETIME` after acquiring | Deterministic timeout case |
| `down_interruptible()` | Ignores a signal, or returns the wrong errno | kthread plus `send_sig()` |
| `down_killable()` | Wakes on a non-fatal signal | Signal matrix |
| Wait-list order | Reordering or starvation | Ordered wake test (implementation detail, not API guarantee) |
| Lifetime | Semaphore freed while a waiter is queued | KASAN plus a negative test |
| Context | Blocking `down()` in atomic context | `CONFIG_DEBUG_ATOMIC_SLEEP` |
| Lock order | ABBA hang between two semaphores | Stress plus hung-task detector; lockdep will not help |
| Fast/slow path | Regression in the uncontended case | Cycle-level measurement with `perf`/ftrace |

Two cautions about the table. First, **FIFO wake order is an implementation property, not part of the API contract**. The current code appends at the tail and wakes `first_waiter`, so a test can observe FIFO, but a future implementation is free to change it; assert it only as a regression check, not as a semantic requirement. Second, a semaphore test that only ever runs the fast path exercises almost none of the code. Force contention deliberately.

### 13.2 A Debug Configuration That Catches Real Bugs

Start from a normal `defconfig` and add the following fragment. The options are not free — KASAN in particular changes timing and memory consumption — so keep a fast build and a debug build separate.

```text
CONFIG_SMP=y
CONFIG_DEBUG_KERNEL=y
CONFIG_DEBUG_FS=y
CONFIG_DEBUG_INFO=y
CONFIG_DEBUG_INFO_BTF=y
CONFIG_MAGIC_SYSRQ=y

# Lock and context checking
CONFIG_PROVE_LOCKING=y
CONFIG_DEBUG_LOCK_ALLOC=y
CONFIG_DEBUG_SPINLOCK=y
CONFIG_DEBUG_ATOMIC_SLEEP=y
CONFIG_DEBUG_LIST=y

# Hang detection
CONFIG_DETECT_HUNG_TASK=y
CONFIG_DETECT_HUNG_TASK_BLOCKER=y
CONFIG_DEFAULT_HUNG_TASK_TIMEOUT=30

# Memory and race sanitizers (one per build: KCSAN depends on !KASAN)
CONFIG_KASAN=y
# CONFIG_KCSAN=y
# CONFIG_KFENCE=y

# In-tree test material
CONFIG_SAMPLE_HUNG_TASK=m
CONFIG_LOCK_TORTURE_TEST=m
CONFIG_DEBUG_LOCKING_API_SELFTESTS=y
```

What each option actually buys for semaphores:

| Option | Catches | Does **not** catch |
|---|---|---|
| `CONFIG_PROVE_LOCKING` | Misuse of the internal `raw_spinlock_t`, IRQ-state inversions around it | ABBA order between semaphores, wrong-task release, slot leaks |
| `CONFIG_DEBUG_ATOMIC_SLEEP` | Blocking `down()` under a spinlock, in IRQ context, or with preemption disabled | A legal-looking sleep that is simply too long |
| `CONFIG_DEBUG_LIST` | Corruption of the circular waiter list | A logically wrong but well-formed list |
| `CONFIG_DEBUG_SPINLOCK` | Bad unlock, double unlock, or unlock by the wrong CPU on the internal lock | Anything about the semaphore count |
| `CONFIG_DETECT_HUNG_TASK` | A task stuck in `D` state long enough | A task that is blocked but keeps switching, or an interruptible sleeper |
| `CONFIG_DETECT_HUNG_TASK_BLOCKER` | Names the last recorded holder of the semaphore | A holder that exited, or a release by a third task |
| `CONFIG_KASAN` | Use-after-free of the semaphore or waiter, out-of-bounds access | A leaked slot with a live semaphore |
| `CONFIG_KCSAN` | Data races on the object the semaphore is supposed to protect | A missing `up()`, or ordering bugs |
| `CONFIG_KFENCE` | Heap use-after-free with low overhead, sampled | Stack-allocated waiters |
| `CONFIG_LOCK_STAT` | Spinlock and rwsem contention statistics | Semaphores: lock events do not cover them |

Two limits are worth stating explicitly because they surprise people:

- `CONFIG_DEBUG_LOCKING_API_SELFTESTS` runs `locking_selftest()` at boot, but its own Kconfig text says it covers "spinlocks, rwlocks, mutexes and rwsems" — see [lib/Kconfig.debug](https://github.com/torvalds/linux/blob/v7.3-rc7/lib/Kconfig.debug#L1626-L1635). `struct semaphore` is not in that list.
- `CONFIG_LOCK_STAT` and its `lock_events` counters exist for qspinlocks, rwsems, and rtlocks; there is no semaphore counter among them [kernel/locking/lock_events_list.h](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/lock_events_list.h)). Use the contention tracepoints instead.

KCSAN also depends on `!KASAN` in this tree [lib/Kconfig.kcsan](https://github.com/torvalds/linux/blob/v7.3-rc7/lib/Kconfig.kcsan#L13-L16)), so KASAN and KCSAN are separate builds, not two options in one kernel. KCSAN additionally needs a compiler with TSan instrumentation support.

`CONFIG_DETECT_HUNG_TASK_BLOCKER` also depends on `!PREEMPT_RT` in this tree. On an RT build the blocker line is unavailable, and the hung-task report is the only signal you get.

### 13.3 What Ships in the Tree

| In-tree artifact | What it does | Covers `struct semaphore`? |
|---|---|---|
| `samples/hung_task/hung_task_tests.c` | Debugfs files that hold a mutex, semaphore, or rwsem for 256 seconds so the hung-task detector fires | **Yes**, as a watchdog test |
| `lib/locking-selftest.c` | Boot-time false-positive/false-negative checks for lockdep | No — spinlocks, rwlocks, mutexes, rwsems |
| `kernel/locking/locktorture.c` | Randomized torture of spinlocks, rwlocks, mutexes, ww_mutex, rwsems, percpu rwsems | No — there is no semaphore op in the list |
| `tools/testing/selftests/locking/` | Runs the `test-ww_mutex` module | No — only `ww_mutex.sh` |
| `tools/testing/selftests/ipc/` | SysV IPC tests | No — userspace IPC, a different mechanism |

The locktorture gap is easy to verify. Its operation table is [kernel/locking/locktorture.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/locktorture.c#L1225-L1240), and it contains `spin_lock_ops`, `raw_spin_lock_ops`, `rw_lock_ops`, `mutex_lock_ops`, `ww_mutex_lock_ops`, `rtmutex_lock_ops`, `rwsem_lock_ops`, and `percpu_rwsem_lock_ops` — no `semaphore_ops`. The selftest directory is equally small: [tools/testing/selftests/locking/Makefile](https://github.com/torvalds/linux/blob/v7.3-rc7/tools/testing/selftests/locking/Makefile#L8) declares a single program, `ww_mutex.sh`.

The one genuinely useful in-tree piece is the hung-task sample. Its semaphore handler is short and honest about what it tests:

```c
static ssize_t read_dummy_semaphore(struct file *file, char __user *user_buf,
                                    size_t count, loff_t *ppos)
{
    if (*ppos >= sizeof(dummy_string))
        return 0;

    down(&dummy_sem);
    msleep_interruptible(SLEEP_SECOND * 1000);
    up(&dummy_sem);

    return simple_read_from_buffer(user_buf, count, ppos, dummy_string,
                                   sizeof(dummy_string));
}
```

Source: [samples/hung_task/hung_task_tests.c](https://github.com/torvalds/linux/blob/v7.3-rc7/samples/hung_task/hung_task_tests.c#L54-L72). The module is enabled by `CONFIG_SAMPLE_HUNG_TASK` [samples/Kconfig](https://github.com/torvalds/linux/blob/v7.3-rc7/samples/Kconfig#L316-L323)) and creates `/sys/kernel/debug/hung_task/semaphore` along with mutex and rwsem variants.

**The practical conclusion:** if you need a regression test for semaphore semantics, you write it. The rest of this section does exactly that.

### 13.4 A Deterministic Semantics Test Module

The module below exposes four debugfs files. Each read runs one test and returns a human-readable report. Keeping the tests in a module means they can be rebuilt and reloaded without rebooting, and the code can deliberately do things a normal driver would not.

```c
// SPDX-License-Identifier: GPL-2.0
/*
 * semtest.c - deterministic and stress tests for struct semaphore.
 *
 * Build out of tree:
 *   make -C /path/to/linux M=$PWD ARCH=arm64 \
 *        CROSS_COMPILE=aarch64-linux-gnu- modules
 *
 * Each debugfs file runs one test per read:
 *   /sys/kernel/debug/semtest/semantics
 *   /sys/kernel/debug/semtest/interrupt
 *   /sys/kernel/debug/semtest/fifo
 *   /sys/kernel/debug/semtest/stress
 */
#include <linux/atomic.h>
#include <linux/completion.h>
#include <linux/debugfs.h>
#include <linux/delay.h>
#include <linux/fs.h>
#include <linux/jiffies.h>
#include <linux/kernel.h>
#include <linux/kthread.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/sched/signal.h>
#include <linux/semaphore.h>
#include <linux/string.h>

#define SEMTEST_THREADS 8
#define SEMTEST_ITERS   20000
#define SEMTEST_TIMEOUT (5 * HZ)

static struct dentry *semtest_dir;
static char semtest_buf[4096];
static DEFINE_MUTEX(semtest_lock);

static int run_semantics(char *buf, size_t len)
{
    struct semaphore sem;
    int i, ret, n = 0;

    sema_init(&sem, 3);
    for (i = 0; i < 3; i++) {
        ret = down_trylock(&sem);
        n += scnprintf(buf + n, len - n,
                       "trylock %d of 3: %d (expect 0)\n", i + 1, ret);
    }

    ret = down_trylock(&sem);
    n += scnprintf(buf + n, len - n,
                   "trylock 4 of 3: %d (expect 1)\n", ret);

    for (i = 0; i < 3; i++)
        up(&sem);

    sema_init(&sem, 1);
    down(&sem);
    ret = down_timeout(&sem, 1);
    n += scnprintf(buf + n, len - n,
                   "down_timeout on held count-1: %d (expect %d)\n",
                   ret, -ETIME);
    up(&sem);

    return n;
}

struct intr_test {
    struct semaphore sem;
    struct completion started;
    int result;
};

static int intr_thread(void *arg)
{
    struct intr_test *t = arg;

    complete(&t->started);
    t->result = down_interruptible(&t->sem);
    return 0;
}

static int run_interrupt(char *buf, size_t len)
{
    struct intr_test t;
    struct task_struct *task;

    sema_init(&t.sem, 0);
    init_completion(&t.started);
    t.result = 0;

    task = kthread_run(intr_thread, &t, "semtest-intr");
    if (IS_ERR(task))
        return scnprintf(buf, len, "kthread_run failed: %ld\n",
                         PTR_ERR(task));

    wait_for_completion(&t.started);
    msleep(20);
    if (send_sig(SIGKILL, task, 0)) {
        up(&t.sem);
        kthread_stop(task);
        return scnprintf(buf, len, "send_sig(SIGKILL) failed\n");
    }
    kthread_stop(task);

    return scnprintf(buf, len,
                     "down_interruptible after SIGKILL: %d (expect %d)\n",
                     t.result, -EINTR);
}

struct fifo_test {
    struct semaphore *sem;
    struct completion started;
    int id;
};

static struct fifo_test fifo_tests[3];
static atomic_t fifo_seq;
static int fifo_order[3];

static int fifo_thread(void *arg)
{
    struct fifo_test *t = arg;

    complete(&t->started);
    down(t->sem);
    fifo_order[t->id] = atomic_inc_return(&fifo_seq);
    up(t->sem);
    return 0;
}

static int run_fifo(char *buf, size_t len)
{
    struct task_struct *tasks[3];
    struct semaphore sem;
    int i, n = 0;

    sema_init(&sem, 0);
    atomic_set(&fifo_seq, 0);
    memset(fifo_order, 0, sizeof(fifo_order));

    for (i = 0; i < 3; i++) {
        fifo_tests[i].sem = &sem;
        fifo_tests[i].id = i;
        init_completion(&fifo_tests[i].started);
        tasks[i] = kthread_run(fifo_thread, &fifo_tests[i],
                               "semtest-fifo%d", i);
        if (IS_ERR(tasks[i])) {
            int j;

            for (j = 0; j < i; j++)
                up(&sem);
            for (j = 0; j < i; j++)
                kthread_stop(tasks[j]);
            return scnprintf(buf, len, "kthread_run failed for %d\n", i);
        }
        wait_for_completion(&fifo_tests[i].started);
        msleep(20);
    }

    /* One up() is enough: each woken waiter hands the semaphore to the next. */
    up(&sem);
    for (i = 0; i < 3; i++)
        kthread_stop(tasks[i]);

    n += scnprintf(buf + n, len - n, "wake order:");
    for (i = 0; i < 3; i++)
        n += scnprintf(buf + n, len - n, " %d", fifo_order[i]);
    n += scnprintf(buf + n, len - n, " (expect 1 2 3)\n");
    return n;
}

static struct semaphore stress_sem;
static atomic_t in_cs;
static atomic_t mismatches;
static atomic_t timeouts;

static int stress_thread(void *arg)
{
    int i;

    for (i = 0; i < SEMTEST_ITERS; i++) {
        if (down_timeout(&stress_sem, SEMTEST_TIMEOUT)) {
            atomic_inc(&timeouts);
            return 0;
        }
        if (atomic_inc_return(&in_cs) != 1)
            atomic_inc(&mismatches);
        udelay(1);
        atomic_dec(&in_cs);
        up(&stress_sem);
    }
    return 0;
}

static int run_stress(char *buf, size_t len)
{
    struct task_struct *tasks[SEMTEST_THREADS];
    int i, ret = 0;

    sema_init(&stress_sem, 1);
    atomic_set(&in_cs, 0);
    atomic_set(&mismatches, 0);
    atomic_set(&timeouts, 0);

    for (i = 0; i < SEMTEST_THREADS; i++) {
        tasks[i] = kthread_run(stress_thread, NULL, "semtest/%d", i);
        if (IS_ERR(tasks[i])) {
            ret = PTR_ERR(tasks[i]);
            break;
        }
    }
    while (i--)
        kthread_stop(tasks[i]);

    return scnprintf(buf, len,
                     "stress: threads=%d iters=%d mismatches=%d timeouts=%d%s\n",
                     SEMTEST_THREADS, SEMTEST_ITERS,
                     atomic_read(&mismatches), atomic_read(&timeouts),
                     ret ? " (thread creation failed)" : "");
}

static ssize_t run_and_read(struct file *file, char __user *ubuf,
                            size_t count, loff_t *ppos,
                            int (*run)(char *, size_t))
{
    int len;

    if (*ppos)
        return 0;

    mutex_lock(&semtest_lock);
    len = run(semtest_buf, sizeof(semtest_buf));
    mutex_unlock(&semtest_lock);

    return simple_read_from_buffer(ubuf, count, ppos, semtest_buf, len);
}

static ssize_t semantics_read(struct file *f, char __user *u, size_t c,
                              loff_t *p)
{
    return run_and_read(f, u, c, p, run_semantics);
}

static ssize_t interrupt_read(struct file *f, char __user *u, size_t c,
                              loff_t *p)
{
    return run_and_read(f, u, c, p, run_interrupt);
}

static ssize_t fifo_read(struct file *f, char __user *u, size_t c, loff_t *p)
{
    return run_and_read(f, u, c, p, run_fifo);
}

static ssize_t stress_read(struct file *f, char __user *u, size_t c,
                           loff_t *p)
{
    return run_and_read(f, u, c, p, run_stress);
}

static const struct file_operations semantics_fops = { .read = semantics_read };
static const struct file_operations interrupt_fops = { .read = interrupt_read };
static const struct file_operations fifo_fops      = { .read = fifo_read };
static const struct file_operations stress_fops    = { .read = stress_read };

static int __init semtest_init(void)
{
    semtest_dir = debugfs_create_dir("semtest", NULL);
    if (IS_ERR(semtest_dir))
        return PTR_ERR(semtest_dir);

    debugfs_create_file("semantics", 0400, semtest_dir, NULL, &semantics_fops);
    debugfs_create_file("interrupt", 0400, semtest_dir, NULL, &interrupt_fops);
    debugfs_create_file("fifo",      0400, semtest_dir, NULL, &fifo_fops);
    debugfs_create_file("stress",    0400, semtest_dir, NULL, &stress_fops);
    return 0;
}

static void __exit semtest_exit(void)
{
    debugfs_remove_recursive(semtest_dir);
}

module_init(semtest_init);
module_exit(semtest_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Semaphore semantics and stress tests");
```

The module needs a one-line `Makefile`:

```make
obj-m += semtest.o
```

What each test proves, and what it does not:

- **`semantics`** exercises the inverted `down_trylock()` result and the `-ETIME` path. It is deterministic and should pass on every build. It does not touch the wait list at all.
- **`interrupt`** parks a kthread in `down_interruptible()` and sends `SIGKILL`. The expected result is `-EINTR`, and the test fails loudly if the task ignores the signal. Because the signal is fatal, this also exercises the `TASK_INTERRUPTIBLE` wakeup path.
- **`fifo`** queues three waiters and checks the observed wake order. Run it as a regression check only; FIFO is not promised by the API. The 20 ms spacing between thread starts is a best-effort way to get all three queued in order; increase it on a slow or emulated machine.
- **`stress`** is the important one. Eight threads, 20,000 iterations each, a count-1 semaphore, and an `in_cs` high-water mark that must never exceed one. A timeout converts a lost wakeup into a reported failure instead of an indefinite hang. On a healthy kernel the output is `mismatches=0 timeouts=0`.

The stress test deliberately uses `down_timeout()` rather than `down()`. That choice is what makes a lost wakeup observable: the waiter eventually gives up and increments `timeouts`, instead of sleeping until the hung-task watchdog fires.

### 13.5 A Contention and Race Stress Test

The module's `stress` file is a starting point, not a complete stress harness. A more aggressive configuration changes several dimensions at once:

| Dimension | Values to try | Why |
|---|---|---|
| Thread count | 1, 2, 8, `4 × nr_cpus` | More waiters than CPUs forces the slow path |
| Initial count | 1 and N | Mutual exclusion versus slot accounting |
| Holder delay | none, `udelay(1)`, `msleep(1)` | Long hold times widen the handoff window |
| Acquire variant | `down`, `down_interruptible`, `down_timeout` | Different task states and wakeup conditions |
| CPU count | `-smp 1` and `-smp 8` | UP changes the scheduler and IPI behaviour |
| Preemption | `PREEMPT_NONE`, `PREEMPT`, `PREEMPT_RT` | Different `might_sleep()` and wakeup behaviour |

For a counting test, replace the boolean invariant with a high-water mark:

```c
static atomic_t holders;
static atomic_t max_holders;

static int counting_thread(void *arg)
{
    int i;

    for (i = 0; i < SEMTEST_ITERS; i++) {
        int now;

        if (down_timeout(&stress_sem, SEMTEST_TIMEOUT))
            return -ETIME;

        now = atomic_inc_return(&holders);
        if (now > atomic_read(&max_holders))
            atomic_set(&max_holders, now);
        udelay(1);
        atomic_dec(&holders);
        up(&stress_sem);
    }
    return 0;
}
```

With `sema_init(&stress_sem, N)`, the final `max_holders` must be at most N. This is the test that distinguishes a counting semaphore from a mutex: set N to 4 and verify that four holders really do run concurrently, then verify that a fifth cannot. To prove overlap rather than just the upper bound, hold the semaphore long enough (`msleep(10)`) and synchronize the threads so that all N arrive before any releases; with a short `udelay(1)` section, timing alone can serialize the holders.

The `max_holders` update is itself racy — `atomic_read` followed by `atomic_set` can lose an update. That is acceptable for a coarse high-water mark but should not be copied into production code. Use `atomic_try_cmpxchg()` if the exact maximum matters.

### 13.6 Triggering the Hung-Task Blocker

The in-tree sample is the fastest way to see the semaphore diagnostics work end to end. Enable `CONFIG_SAMPLE_HUNG_TASK=m`, `CONFIG_DETECT_HUNG_TASK=y`, and `CONFIG_DETECT_HUNG_TASK_BLOCKER=y`, then:

```sh
modprobe hung_task_tests
echo 10 > /proc/sys/kernel/hung_task_timeout_secs

# Shell 1: acquire the semaphore and sleep for 256 seconds
cat /sys/kernel/debug/hung_task/semaphore

# Shell 2: block behind it
cat /sys/kernel/debug/hung_task/semaphore
```

After ten seconds the watchdog prints a report for the second `cat`, including the blocker line:

```text
INFO: task cat:412 blocked for more than 10 seconds.
      Not tainted 7.3.0-rc7 #1
"echo 0 > /proc/sys/kernel/hung_task_timeout_secs" disables this message.
task:cat             state:D stack:...
Call Trace:
 __schedule+0x...
 schedule+0x...
 schedule_timeout+0x...
 ___down_common+0x...
 __down+0x...
 down+0x...
 read_dummy_semaphore+0x...
...
INFO: task cat:412 blocked on a semaphore likely last held by task cat:411
```

The exact stack depends on inlining and configuration, but the shape is stable: the blocked task's stack ends in `___down_common()`, and the blocker line names the task that last took the semaphore. That is the payoff of `last_holder`.

This test also demonstrates the limitation. The holder here is alive, so the report is accurate. If the holder had exited without calling `up()`, the watchdog would print "the last holder is not found" — which is still useful, but does not identify the leak.

### 13.7 Sanitizers and Lock Debugging

**KASAN.** The most common semaphore lifetime bug is freeing the object while a waiter is still queued. KASAN turns that into an immediate report when `up()` walks the wait list and touches freed memory. A deliberate negative test is easy to describe and should never be committed as a normal test: allocate a semaphore, start a thread that blocks in `down()`, free the semaphore, then call `up()` from another context. The expected result is a KASAN use-after-free in `__up()`, not a silent hang.

**KCSAN.** KCSAN reports concurrent accesses to the data a semaphore is supposed to protect when one side forgets the lock. It is most useful with a test that deliberately omits the lock in a debug-only path:

```c
#ifdef CONFIG_SEMTEST_NEGATIVE
    WRITE_ONCE(shared_counter, shared_counter + 1);  /* unlocked */
#endif
```

Run KCSAN in a separate build from KASAN (Kconfig requires it), and isolate `CONFIG_DEBUG_ATOMIC_SLEEP` if the reports become hard to attribute; all three change timing enough to hide each other's bugs.

**`CONFIG_DEBUG_ATOMIC_SLEEP`.** To validate that the option is actually active, a negative test can hold a spinlock across a fast-path `down()`:

```c
static DEFINE_SPINLOCK(dummy_spin);
static struct semaphore dummy_sem;

static ssize_t atomic_read(struct file *f, char __user *u, size_t c,
                           loff_t *p)
{
    sema_init(&dummy_sem, 1);   /* count 1 means down() will not sleep */
    spin_lock(&dummy_spin);
    down(&dummy_sem);           /* but might_sleep() still fires */
    up(&dummy_sem);
    spin_unlock(&dummy_spin);
    return 0;
}
```

The expected splat is `BUG: sleeping function called from invalid context`, pointing at `might_sleep()` in `down()`. If that splat does not appear, `CONFIG_DEBUG_ATOMIC_SLEEP` is not enabled and the rest of the context testing is meaningless.

**Lockdep.** Keep `CONFIG_PROVE_LOCKING=y` for the internal spinlock and IRQ-state checks, but do not expect it to find a semaphore deadlock. A useful sanity check is to build a two-semaphore ABBA test, confirm that lockdep stays silent, and confirm that the hung-task detector eventually reports the hang. That experiment makes the limitation concrete.

### 13.8 Observing Contention with Ftrace, perf, and BPF

The semaphore implementation emits `lock:contention_begin` and `lock:contention_end` around the slow path. The tracepoint definitions are in [include/trace/events/lock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/trace/events/lock.h#L94-L138), and the calls are in `__down_common()` at [kernel/locking/semaphore.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/semaphore.c#L310-L324).

Enable them directly:

```sh
cd /sys/kernel/tracing
echo 1 > events/lock/contention_begin/enable
echo 1 > events/lock/contention_end/enable
cat trace_pipe
```

A run of the stress test produces one begin/end pair per slow-path attempt, including attempts that time out or are interrupted. To focus on one semaphore, get its address from `/proc/kallsyms` and install a filter (if the static symbol is hidden, enable `CONFIG_KALLSYMS_ALL` or read the address from an unfiltered trace):

```sh
grep stress_sem /proc/kallsyms
echo 'lock_addr == 0xffff8000deadbeef' > events/lock/contention_begin/filter
echo 'lock_addr == 0xffff8000deadbeef' > events/lock/contention_end/filter
```

Two details matter when interpreting the output:

- Semaphores call `trace_contention_begin(sem, 0)`, so the `flags` field is zero. There is no dedicated semaphore bit in the tracepoint; `perf` maps a zero `flags` value to the `semaphore` type in its lock-type table [tools/perf/builtin-lock.c](https://github.com/torvalds/linux/blob/v7.3-rc7/tools/perf/builtin-lock.c#L1489-L1490)), and `perf lock contention --type-filter semaphore` relies on that mapping. The address and caller still identify the individual semaphore.
- `contention_begin` fires before the waiter sleeps, and `contention_end` fires after it wakes or fails. The pair therefore measures the full wait, including time spent off-CPU.

With `perf`:

```sh
# Lockdep acquire/release view: mostly the internal spinlock
perf lock record -- cat /sys/kernel/debug/semtest/stress
perf lock report

# Contention tracepoint view: the semaphore wait itself
perf lock contention -b --type-filter semaphore -- \
    cat /sys/kernel/debug/semtest/stress
```

The `-b` form uses BPF and is usually the most readable, but it needs a kernel built with BTF (`CONFIG_DEBUG_INFO_BTF`) and a `perf` built with BPF support. Without `-b`, `perf lock contention` falls back to the tracepoints. Note that `perf lock record`/`report` consume the lockdep acquire/release events; for a semaphore those mostly describe the internal `semaphore->lock` spinlock, not the wait itself. `perf lock contention` is the command that reports the semaphore slow path, and `--type-filter semaphore` selects it explicitly.

With `bpftrace`, a minimal contention histogram:

```sh
bpftrace -e '
tracepoint:lock:contention_begin
{
    @[args->lock_addr] = count();
}'
```

A more useful version records the wait time by pairing begin and end per CPU, but that requires state and is easier to write as a small BPF program than as a one-liner. For most debugging, the ftrace timestamps are enough.

### 13.9 Running the Tests Under QEMU on AArch64

A QEMU `virt` machine is the cheapest way to run the module against an AArch64 kernel, and it is the same model used by the kselftest workflows. The important caveat is that QEMU's TCG emulation does not faithfully model weak memory ordering; a test that passes under QEMU can still fail on real hardware if it depends on ordering. Treat QEMU as the functional and configuration test, and run the stress test on real silicon before trusting it.

**Build the kernel and the module.**

```sh
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-

make defconfig
scripts/config --enable DEBUG_FS --enable PROVE_LOCKING \
    --enable DEBUG_ATOMIC_SLEEP --enable DEBUG_LIST \
    --enable DETECT_HUNG_TASK --enable DETECT_HUNG_TASK_BLOCKER \
    --set-val DEFAULT_HUNG_TASK_TIMEOUT 30 \
    --enable KASAN --enable MAGIC_SYSRQ \
    --enable DEBUG_INFO --enable DEBUG_INFO_BTF \
    --enable SAMPLES --module SAMPLE_HUNG_TASK

make -j"$(nproc)" Image modules

make -C . M="$PWD/semtest" modules
```

The out-of-tree module must be built against the same tree and configuration that produced `Image`; a vermagic mismatch makes `insmod` fail with `Invalid module format`.

**Boot with an initramfs.** Put the module and a static `busybox` in a small initramfs, or mount the host directory over 9p. The initramfs route is self-contained:

```sh
mkdir -p initramfs/{bin,proc,sys,dev}
cp /path/to/aarch64/busybox initramfs/bin/
cp semtest/semtest.ko initramfs/
cat > initramfs/init <<'EOF'
#!/bin/sh
mount -t proc none /proc
mount -t sysfs none /sys
mkdir -p /sys/kernel/debug
mount -t debugfs none /sys/kernel/debug
mknod -m 600 /dev/console c 5 1 2>/dev/null || true
insmod /semtest.ko
echo "semtest ready"
exec sh
EOF
chmod +x initramfs/init
(cd initramfs && find . | cpio -o -H newc | gzip) > initramfs.cpio.gz
```

Then:

```sh
qemu-system-aarch64 \
    -M virt -cpu max -smp 4 -m 2G -nographic \
    -kernel arch/arm64/boot/Image \
    -initrd initramfs.cpio.gz \
    -append "console=ttyAMA0 rdinit=/init loglevel=7"
```

Inside the guest:

```sh
cat /sys/kernel/debug/semtest/semantics
cat /sys/kernel/debug/semtest/interrupt
cat /sys/kernel/debug/semtest/fifo
cat /sys/kernel/debug/semtest/stress
```

The 9p alternative avoids rebuilding the initramfs for every module change:

```sh
qemu-system-aarch64 \
    -M virt -cpu max -smp 4 -m 2G -nographic \
    -kernel arch/arm64/boot/Image \
    -initrd initramfs.cpio.gz \
    -virtfs local,path="$PWD/semtest",mount_tag=host0,security_model=none \
    -append "console=ttyAMA0 rdinit=/init loglevel=7"
```

```sh
mkdir -p /mnt/host
mount -t 9p -o trans=virtio,version=9p2000.L host0 /mnt/host
insmod /mnt/host/semtest.ko
```

**Vary the machine, not just the test.** A single QEMU invocation exercises one configuration. Useful variations:

| QEMU option | What it changes |
|---|---|
| `-smp 1` | Uniprocessor scheduling; the handoff has nowhere else to run |
| `-smp 8` | Real contention on the internal qspinlock and the wake queue |
| `-cpu max` | LSE atomics (`CASA`), which change the qspinlock instruction sequence |
| `-cpu cortex-a57` | LL/SC atomics (`LDAXR`/`STXR`), the pre-LSE path |
| `-m 512M` | Memory pressure and a smaller pool of free pages for stack allocation |
| `-d int` | Interrupt tracing, useful when a wakeup goes missing |

Run the stress test at least once with `-smp 1` and once with `-smp 8`. A lost wakeup that requires a preemption race may only appear with more threads than CPUs.

### 13.10 A Test Matrix

| Test | Build configuration | Command | Pass criterion |
|---|---|---|---|
| API semantics | any | `cat .../semantics` | All lines match the expected values |
| Signal handling | any | `cat .../interrupt` | `-EINTR` |
| Wake order | any | `cat .../fifo` | `1 2 3` (regression only) |
| Mutual exclusion | `SMP`, `PREEMPT` | `cat .../stress` | `mismatches=0 timeouts=0` |
| Counting limit | `SMP` | custom N-slot variant | `max_holders <= N` |
| Context violation | `DEBUG_ATOMIC_SLEEP` | atomic negative test | One `sleeping function called from invalid context` |
| Hung task | `DETECT_HUNG_TASK_BLOCKER` | two `cat`s on the sample | Blocker line names the holder |
| UAF | `KASAN` | deliberate free-while-waiting | KASAN report on the freed semaphore |
| Data race | `KCSAN` | unlocked access to guarded data | KCSAN report |
| ABBA deadlock | `DETECT_HUNG_TASK` | two-semaphore inversion | Hung-task report; **no lockdep report** |
| Contention profile | `FTRACE` (+ `LOCKDEP` for `perf lock record`) | `perf lock contention` | Slow-path pairs with plausible wait times |
| Real hardware | arm64, `SMP` | repeat stress for hours | No mismatches, no timeouts, no watchdog |

Two rows deserve emphasis. The ABBA row is expected to produce **no lockdep output**; if your test plan assumes otherwise, it is testing the wrong thing. The real-hardware row is not optional for a primitive whose correctness depends on memory ordering and scheduler timing.

### 13.11 Reading the Failure Reports

**Hung task.** The report starts with `INFO: task <comm>:<pid> blocked for more than <n> seconds.` and includes a stack. If the stack contains `___down_common()` and `__down*()`, the task is on a semaphore. The next line, when `CONFIG_DETECT_HUNG_TASK_BLOCKER` is enabled, is either `blocked on a semaphore likely last held by task ...` or `blocked on a semaphore, but the last holder is not found.` The first means the recorded holder is still alive; the second means it exited or the record is stale.

**Lockdep.** A `possible circular locking dependency detected` report is about a lock that lockdep can see: a mutex, rwsem, spinlock, or the internal semaphore spinlock. If the two locks in the cycle are semaphores, there will be no report at all. Do not read silence as proof of correctness.

**`DEBUG_ATOMIC_SLEEP`.** The splat is `BUG: sleeping function called from invalid context at kernel/locking/semaphore.c:<line>`, followed by the caller's stack and the preemption/IRQ state. The fix is structural: move the `down()` out of the atomic section, or replace the semaphore with a trylock plus deferred work.

**KASAN.** A use-after-free report names the freed object and the allocation/free stacks. For a semaphore, the free stack usually points at the driver's teardown path, and the use stack points at `__up()` or `___down_common()`. The fix is to ensure no waiter can exist before the object is freed, typically by draining the wait queue or by holding a reference on the object.

**KCSAN.** A data-race report names the two accesses and the two stacks. If one stack is outside the intended critical section, it is a real missing lock; if both stacks are inside it, check whether the two paths are actually serialized by the same semaphore (a different lock, an early return, or a missing `up()` can break the assumption). KCSAN samples executions and can miss races, so a clean run is not proof of absence.

**Tracepoints.** A `contention_begin` without a matching `contention_end` for the same address means the waiter never woke. That is the signature of a lost wakeup. Pair the addresses and timestamps rather than counting events.

---

## 14. Summary: Rules of Thumb

1. **A semaphore is a sleeping lock with a count.** Use it when the wait may be long, when the critical section may block, and when you are in process context.

2. **Use a binary semaphore only when you need cross-context release.** For ordinary mutual exclusion, use a mutex; for event signalling, use a completion. A binary semaphore is the right tool for "acquire in `open()`, release in `close()`" and for interrupt-to-task handoff.

3. **Use a counting semaphore for N identical resources.** Set the count to N. Do not set it above 1 and then expect mutual exclusion.

4. **Never use a blocking `down()` variant in interrupt context.** Only `down_trylock()` and `up()` are IRQ-safe. The fact that the kernel has legacy paths that call `down()` in interrupt context does not make it a rule.

5. **Never sleep while holding a spinlock, and never hold a spinlock while calling `down()`.** The reverse is fine: you may sleep while holding a semaphore.

6. **Always pair a successful acquire with exactly one `up()`.** A failed acquire (`-EINTR`, `-ETIME`, or `down_trylock()` returning 1) must not be released.

7. **Prefer `down_interruptible()` in driver code; use `down_killable()` when only fatal signals should abort the wait.** Avoid `down()` in new code — it is unkillable and deprecated.

8. **Remember that there is no owner.** `up()` may be called by any task or context, which enables producer/consumer and open/close patterns but defeats owner-based debugging and priority inheritance. Keep the acquire/release pairing obvious in the code.

9. **Keep a consistent lock order — and do not expect lockdep to enforce it.** `down()` and `up()` create no lockdep graph edges, so an ABBA cycle between semaphores produces a hang and no report. Document the order, keep multi-semaphore sites rare, and use a mutex when you need deadlock detection.

10. **Test the failures that static analysis cannot see.** Build a deterministic API test, a multi-thread stress test with timeouts, and a hung-task run. Enable `CONFIG_DEBUG_ATOMIC_SLEEP`, `CONFIG_DEBUG_LIST`, KASAN, and the blocker diagnostics. None of them can prove correctness, but they turn silent hangs into actionable reports.

A semaphore is a small, old, and deceptively simple primitive. Its implementation is a counter, a circular wait list, and a wake queue; its semantics are one lock word and a scheduler call. The complexity is not in the code but in the rules it imposes: sleep only in process context, never hold a spinlock across it, never expect an owner, and never confuse a count with mutual exclusion. Used for the right shape of problem — N resources, long waits, cross-context release — it is exactly the right tool. Used as a general-purpose lock, it is slower, less debuggable, and more fragile than the mutex or completion that should have been there instead.

---

## 15. References

### 15.1 Core Type Definitions and API

- [include/linux/semaphore.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/semaphore.h#L15-L23) — `struct semaphore` definition
- [include/linux/semaphore.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/semaphore.h#L32-L47) — `__SEMAPHORE_INITIALIZER` and `DEFINE_SEMAPHORE`
- [include/linux/semaphore.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/semaphore.h#L49-L54) — `sema_init()`
- [include/linux/semaphore.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/semaphore.h#L56-L62) — public `down()`/`up()` declarations
- [kernel/locking/semaphore.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/semaphore.c#L245-L249) — `struct semaphore_waiter`

### 15.2 Implementation

- [kernel/locking/semaphore.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/semaphore.c#L12-L25) — implementation notes
- [kernel/locking/semaphore.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/semaphore.c#L74-L78) — `__sem_acquire()`
- [kernel/locking/semaphore.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/semaphore.c#L91-L103) — `down()`
- [kernel/locking/semaphore.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/semaphore.c#L114-L128) — `down_interruptible()`
- [kernel/locking/semaphore.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/semaphore.c#L141-L156) — `down_killable()`
- [kernel/locking/semaphore.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/semaphore.c#L171-L184) — `down_trylock()`
- [kernel/locking/semaphore.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/semaphore.c#L196-L211) — `down_timeout()`
- [kernel/locking/semaphore.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/semaphore.c#L220-L241) — `up()`
- [kernel/locking/semaphore.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/semaphore.c#L251-L264) — `sem_del_waiter()`
- [kernel/locking/semaphore.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/semaphore.c#L271-L308) — `___down_common()`
- [kernel/locking/semaphore.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/semaphore.c#L310-L324) — `__down_common()`
- [kernel/locking/semaphore.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/semaphore.c#L326-L344) — `__down*()` wrappers
- [kernel/locking/semaphore.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/semaphore.c#L346-L354) — `__up()`

### 15.3 Wake Queue and Scheduling

- [include/linux/sched/wake_q.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/sched/wake_q.h) — wake queue types
- [kernel/sched/core.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/sched/core.c#L1101-L1185) — `wake_q_add()` / `wake_up_q()`
- [kernel/sched/core.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/sched/core.c#L4238-L4400) — `try_to_wake_up()`
- [include/linux/sched.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/sched.h#L215-L251) — `__set_current_state()` vs. `set_current_state()`
- [include/linux/sched/signal.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/sched/signal.h#L409-L417) — `signal_pending_state()`
- [kernel/time/sleep_timeout.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/time/sleep_timeout.c#L61-L110) — `schedule_timeout()`

### 15.4 AArch64 Spinlocks and Ordering

- [include/asm-generic/qspinlock_types.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/asm-generic/qspinlock_types.h#L14-L64) — `qspinlock` type and bit layout
- [arch/arm64/include/asm/spinlock_types.h](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/spinlock_types.h#L12-L13) — `arch_spinlock_t` selection
- [arch/arm64/include/asm/spinlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/spinlock.h#L12) — `smp_mb__after_spinlock()`
- [arch/arm64/include/asm/irqflags.h](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/irqflags.h#L23-L88) — IRQ flag save/restore

### 15.5 Debugging and Testing

- [lib/Kconfig.debug](https://github.com/torvalds/linux/blob/v7.3-rc7/lib/Kconfig.debug#L1406-L1451) — `CONFIG_PROVE_LOCKING`
- [lib/Kconfig.debug](https://github.com/torvalds/linux/blob/v7.3-rc7/lib/Kconfig.debug#L1462-L1480) — `CONFIG_LOCK_STAT` and `perf lock`
- [lib/Kconfig.debug](https://github.com/torvalds/linux/blob/v7.3-rc7/lib/Kconfig.debug#L1615-L1624) — `CONFIG_DEBUG_ATOMIC_SLEEP`
- [lib/Kconfig.debug](https://github.com/torvalds/linux/blob/v7.3-rc7/lib/Kconfig.debug#L1626-L1635) — boot-time locking API selftests (no semaphore coverage)
- [lib/Kconfig.debug](https://github.com/torvalds/linux/blob/v7.3-rc7/lib/Kconfig.debug#L1637-L1649) — `CONFIG_LOCK_TORTURE_TEST`
- [lib/Kconfig.debug](https://github.com/torvalds/linux/blob/v7.3-rc7/lib/Kconfig.debug#L1274-L1283) — `CONFIG_DETECT_HUNG_TASK_BLOCKER`
- [lib/Kconfig.debug](https://github.com/torvalds/linux/blob/v7.3-rc7/lib/Kconfig.debug#L1766-L1778) — `CONFIG_DEBUG_LIST`
- [kernel/hung_task.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/hung_task.c#L137-L219) — blocker reporting
- [include/linux/hung_task.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/hung_task.h#L15-L56) — blocker encoding
- [samples/hung_task/hung_task_tests.c](https://github.com/torvalds/linux/blob/v7.3-rc7/samples/hung_task/hung_task_tests.c#L54-L72) — semaphore read handler
- [samples/Kconfig](https://github.com/torvalds/linux/blob/v7.3-rc7/samples/Kconfig#L316-L323) — `CONFIG_SAMPLE_HUNG_TASK`
- [kernel/locking/locktorture.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/locktorture.c#L1225-L1240) — operation table (no semaphore)
- [tools/testing/selftests/locking/Makefile](https://github.com/torvalds/linux/blob/v7.3-rc7/tools/testing/selftests/locking/Makefile#L8) — only `ww_mutex.sh`
- [include/trace/events/lock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/trace/events/lock.h#L94-L138) — contention tracepoints
- [tools/perf/builtin-lock.c](https://github.com/torvalds/linux/blob/v7.3-rc7/tools/perf/builtin-lock.c#L1489-L1490) — zero contention flags map to the `semaphore` type
- [Documentation/locking/lockstat.rst](https://github.com/torvalds/linux/blob/v7.3-rc7/Documentation/locking/lockstat.rst) — lock statistics and `perf lock`
- [Documentation/locking/lockdep-design.rst](https://github.com/torvalds/linux/blob/v7.3-rc7/Documentation/locking/lockdep-design.rst) — lockdep model
- [Documentation/dev-tools/kcsan.rst](https://github.com/torvalds/linux/blob/v7.3-rc7/Documentation/dev-tools/kcsan.rst) — KCSAN usage
- [Documentation/admin-guide/lockup-watchdogs.rst](https://github.com/torvalds/linux/blob/v7.3-rc7/Documentation/admin-guide/lockup-watchdogs.rst) — hung-task and lockup detectors

### 15.6 Semantics, Comparison, and Real-World Usage

- [Documentation/locking/locktypes.rst](https://github.com/torvalds/linux/blob/v7.3-rc7/Documentation/locking/locktypes.rst#L113-L130) — semaphores and `PREEMPT_RT`
- [Documentation/locking/locktorture.rst](https://github.com/torvalds/linux/blob/v7.3-rc7/Documentation/locking/locktorture.rst) — torture test parameters
- [Documentation/locking/mutex-design.rst](https://github.com/torvalds/linux/blob/v7.3-rc7/Documentation/locking/mutex-design.rst) — mutex semantics and ownership
- [include/linux/mutex.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/mutex.h#L60-L65) — per-call-site lock class key
- [kernel/module/kmod.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/module/kmod.c#L46-L47) — `kmod_concurrent_max` counting semaphore
- [kernel/module/kmod.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/module/kmod.c#L159-L178) — bounded acquire and path-based release
- [drivers/infiniband/core/user_mad.c](https://github.com/torvalds/linux/blob/v7.3-rc7/drivers/infiniband/core/user_mad.c#L98) — `sm_sem` in `struct ib_umad_port`
- [drivers/infiniband/core/user_mad.c](https://github.com/torvalds/linux/blob/v7.3-rc7/drivers/infiniband/core/user_mad.c#L1099-L1147) — non-blocking and blocking open paths, plus close
- [drivers/infiniband/core/user_mad.c](https://github.com/torvalds/linux/blob/v7.3-rc7/drivers/infiniband/core/user_mad.c#L1312) — `sema_init()` at port creation

---

*This document describes semaphores as implemented in Linux v7.3-rc7 on AArch64, in a non-`PREEMPT_RT` SMP configuration. Source line numbers refer to that tag; kernel code evolves, so verify against the tree you are building when using this as a reference.*
