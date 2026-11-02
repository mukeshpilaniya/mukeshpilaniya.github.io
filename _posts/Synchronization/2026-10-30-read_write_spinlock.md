---
title: Reader-Writer Spinlocks in the Linux Kernel
published: true
categories: [Synchronization]
tags: [rwlock, qrwlock, spinlock]
mermaid: true
---
# Reader-Writer Spinlocks in the Linux Kernel

Most data structures in a kernel are read far more often than they are written. Configuration tables, routing entries, the process list, filesystem metadata, and driver state are inspected by many execution contexts but modified by relatively few. A plain **spinlock** treats every access identically: even two readers that only load a field must serialize against each other, and the second reader spins until the first is finished. That is correct, but unnecessarily expensive. A **reader-writer spinlock** — `rwlock_t` in Linux — relaxes the exclusion rule: **any number of readers may hold the lock at the same time, but a writer requires exclusive access, with no readers and no other writers present. The result is __shared/exclusive__ locking rather than plain mutual exclusion.**

On AArch64, `rwlock_t` is not a simple reader counter bolted onto a spinlock. Linux implements it as a **queued read-write lock** (`qrwlock`), a compact 32-bit reader/writer state word protected by an internal **queued spinlock** used to serialize the slow paths. The design has to solve several problems at once: allow readers to enter with a single atomic instruction, keep writers from starving, avoid deadlock when an interrupt-context reader arrives while a writer is waiting, preserve acquire/release ordering on a weakly ordered CPU, and avoid clearing a concurrent reader's count when a writer unlocks. Each of those requirements leaves a visible fingerprint in the source.

This document examines `rwlock_t` in detail on AArch64: why the primitive exists, how it is initialized and used, what the lock word means, how the fast and slow paths work, how fairness and starvation behave, what happens in interrupt and bottom-half context, how the AArch64 memory model and atomics are used, and where the sharp edges are. Unless stated otherwise, the discussion describes a non-`PREEMPT_RT` SMP kernel, which is the configuration in which `rwlock_t` is a spinning lock.

**Diagram conventions.** Timelines run from top to bottom. Columns that sit side by side represent concurrent CPUs or contexts, not a strict wall-clock ordering. `R` and `W` mean reader and writer, `CS` means critical section, and `cnts` values are hexadecimal snapshots used to make state transitions visible.

---

## Table of Contents

1. [Why Reader-Writer Locks Exist](#1-why-reader-writer-locks-exist)
   - 1.1 [The Limits of a Mutex](#11-the-limits-of-a-mutex)
   - 1.2 [Shared/Exclusive Locking](#12-sharedexclusive-locking)
   - 1.3 [Reader-Writer Spinlock vs. Reader-Writer Semaphore](#13-reader-writer-spinlock-vs-reader-writer-semaphore)
   - 1.4 [When an `rwlock_t` Is the Wrong Tool](#14-when-an-rwlock_t-is-the-wrong-tool)
2. [The `rwlock_t` Type on AArch64](#2-the-rwlock_t-type-on-aarch64)
   - 2.1 [Type Hierarchy](#21-type-hierarchy)
   - 2.2 [The Queued Read-Write Lock Structure](#22-the-queued-read-write-lock-structure)
   - 2.3 [Lock Word Bit Layout](#23-lock-word-bit-layout)
   - 2.4 [Lock States](#24-lock-states)
   - 2.5 [Size and Cache-Line Behavior](#25-size-and-cache-line-behavior)
3. [Initialization](#3-initialization)
   - 3.1 [Static Initialization](#31-static-initialization)
   - 3.2 [Dynamic Initialization](#32-dynamic-initialization)
   - 3.3 [What Initialization Actually Does](#33-what-initialization-actually-does)
4. [Core API and Call Chain](#4-core-api-and-call-chain)
   - 4.1 [`read_lock` and `read_unlock`](#41-read_lock-and-read_unlock)
   - 4.2 [`write_lock` and `write_unlock`](#42-write_lock-and-write_unlock)
   - 4.3 [Trylock Operations](#43-trylock-operations)
   - 4.4 [`rwlock_is_contended`](#44-rwlock_is_contended)
   - 4.5 [Complete API Table](#45-complete-api-table)
5. [A Complete `kthread` Example](#5-a-complete-kthread-example)
6. [Internal Implementation](#6-internal-implementation)
   - 6.1 [The Two-Level Design](#61-the-two-level-design)
   - 6.2 [Reader Fast Path](#62-reader-fast-path)
   - 6.3 [Reader Slow Path: Process Context](#63-reader-slow-path-process-context)
   - 6.4 [Reader Slow Path: Interrupt Context](#64-reader-slow-path-interrupt-context)
   - 6.5 [Writer Fast Path](#65-writer-fast-path)
   - 6.6 [Writer Slow Path](#66-writer-slow-path)
   - 6.7 [Unlock Paths and the Byte Store](#67-unlock-paths-and-the-byte-store)
   - 6.8 [End-to-End State Machine](#68-end-to-end-state-machine)
   - 6.9 [Walkthrough: Reader, Waiting Writer, New Reader](#69-walkthrough-reader-waiting-writer-new-reader)
7. [Memory Ordering on AArch64](#7-memory-ordering-on-aarch64)
   - 7.1 [Acquire/Release Contracts](#71-acquirerelease-contracts)
   - 7.2 [Instructions You Will See](#72-instructions-you-will-see)
   - 7.3 [WFE and the Conditional Wait Loop](#73-wfe-and-the-conditional-wait-loop)
   - 7.4 [The A-B-A Ordering Fix in the Writer Slow Path](#74-the-a-b-a-ordering-fix-in-the-writer-slow-path)
8. [Recursive Acquisition](#8-recursive-acquisition)
   - 8.1 [Recursive Read Locks: Conditionally Safe, Not Guaranteed](#81-recursive-read-locks-conditionally-safe-not-guaranteed)
   - 8.2 [Recursive Writes and Read-to-Write Upgrade](#82-recursive-writes-and-read-to-write-upgrade)
   - 8.3 [What Lockdep Does](#83-what-lockdep-does)
9. [Ordering, Fairness, and Starvation](#9-ordering-fairness-and-starvation)
   - 9.1 [Is Ordering CPU-Dependent?](#91-is-ordering-cpu-dependent)
   - 9.2 [How `qrwlock` Enforces Fairness](#92-how-qrwlock-enforces-fairness)
   - 9.3 [Writer Starvation](#93-writer-starvation)
   - 9.4 [Reader Starvation](#94-reader-starvation)
   - 9.5 [The Interrupt-Reader Exception](#95-the-interrupt-reader-exception)
10. [Interrupt and Bottom-Half Contexts](#10-interrupt-and-bottom-half-contexts)
    - 10.1 [The Same-CPU Deadlock](#101-the-same-cpu-deadlock)
    - 10.2 [What `_irqsave` Actually Saves on AArch64](#102-what-_irqsave-actually-saves-on-aarch64)
    - 10.3 [Read/Write Asymmetry](#103-readwrite-asymmetry)
    - 10.4 [Bottom-Half Variants](#104-bottom-half-variants)
    - 10.5 [Variant Selection Matrix](#105-variant-selection-matrix)
    - 10.6 [NMI Context](#106-nmi-context)
11. [Writing Correct `rwlock_t` Code](#11-writing-correct-rwlock_t-code)
    - 11.1 [Lock Data, Not Code](#111-lock-data-not-code)
    - 11.2 [Keep Critical Sections Short](#112-keep-critical-sections-short)
    - 11.3 [Never Sleep Under the Lock](#113-never-sleep-under-the-lock)
    - 11.4 [Lock Ordering and Ownership](#114-lock-ordering-and-ownership)
    - 11.5 [Lifetime and Initialization Rules](#115-lifetime-and-initialization-rules)
12. [Debugging and Observability](#12-debugging-and-observability)
    - 12.1 [`CONFIG_DEBUG_SPINLOCK`](#121-config_debug_spinlock)
    - 12.2 [Lockdep](#122-lockdep)
    - 12.3 [Sleep and Race Detectors](#123-sleep-and-race-detectors)
    - 12.4 [Contention Tracing](#124-contention-tracing)
13. [Performance and Scalability](#13-performance-and-scalability)
    - 13.1 [The Shared Counter Is Still a Contended Cache Line](#131-the-shared-counter-is-still-a-contended-cache-line)
    - 13.2 [NUMA](#132-numa)
    - 13.3 [Writer Handoff](#133-writer-handoff)
    - 13.4 [Alternatives](#134-alternatives)
14. [`PREEMPT_RT`](#14-preempt_rt)
15. [Summary: Rules of Thumb](#15-summary-rules-of-thumb)
16. [Important Points](#16-important-points)
17. [References](#17-references)
    - 17.1 [Core Type Definitions and API](#171-core-type-definitions-and-api)
    - 17.2 [Queued Read-Write Lock Implementation](#172-queued-read-write-lock-implementation)
    - 17.3 [AArch64 Memory Ordering and Atomics](#173-aarch64-memory-ordering-and-atomics)
    - 17.4 [Lockdep and Debugging](#174-lockdep-and-debugging)
    - 17.5 [Kernel Documentation and Real-World Usage](#175-kernel-documentation-and-real-world-usage)

---

## 1. Why Reader-Writer Locks Exist

### 1.1 The Limits of a Mutex

A **mutex** enforces mutual exclusion: exactly one task may be inside the critical section. That is the right tool when every access modifies the protected state, or when the operations are so short that the distinction between reading and writing does not matter. It is the wrong tool when the critical section is dominated by read-only work.

Consider a routing table with thousands of entries. A packet-forwarding path looks up a destination; a control-plane path occasionally inserts or removes a route. With a mutex, every lookup serializes against every other lookup, even though no lookup modifies anything. On a large system, the mutex becomes a global bottleneck: the cache line containing the lock bounces between CPUs, tasks queue, and the scheduler may put them to sleep. The protected data may be perfectly safe, but the system has paid for exclusivity it did not need.

A mutex also imposes context restrictions that are fatal for many read paths:

- A mutex **can sleep**. It cannot be acquired in hard IRQ, softirq, tasklet, or NMI context, and it cannot be used while holding a spinlock.
- A mutex has **owner semantics** and priority-inheritance machinery. Those are valuable for long, sleepable critical sections, but they are overhead for a read-side critical section that should last a few instructions.
- A mutex **serializes readers**. There is no way to say "these two callers only read; let them proceed together."

The reader-writer lock addresses the last point directly, while keeping the first two constraints in a form suitable for atomic context: `rwlock_t` is still a spinning lock, so it can be used where a mutex cannot, but it allows concurrent readers.

There is an important caveat, stated plainly in the kernel documentation: reader-writer locks require **more atomic memory operations** than a simple spinlock, and unless the reader critical section is long enough to amortize that cost, a plain spinlock is often faster. The benefit is concurrency, not lower per-operation cost. See [Documentation/locking/spinlocks.rst](https://github.com/torvalds/linux/blob/v7.3-rc7/Documentation/locking/spinlocks.rst#L52-L93).

### 1.2 Shared/Exclusive Locking

The model has two acquisition modes:

- **Shared** (read) mode: multiple holders are allowed, provided no writer holds the lock.
- **Exclusive** (write) mode: exactly one holder, provided no reader and no other writer holds the lock.

The compatibility matrix is simple:

| Existing holder | New reader | New writer |
|---|---|---|
| None | Allowed | Allowed |
| One or more readers | Allowed | Blocked |
| One writer | Blocked | Blocked |

```
                    UNLOCKED
                   /        \
          read_lock()      write_lock()
                 /            \
                v              v
        READ LOCKED          WRITE LOCKED
      (N readers share)      (one writer)
         |        |
   read_lock  write_lock
      OK       blocks
```

The terms **shared/exclusive** and **concurrent/exclusive** describe the same idea. Linux uses "read lock" and "write lock" in the API, and "shared" and "exclusive" in lockdep and documentation.

The key semantic difference from a mutex is not just performance. It is the shape of the critical section. A reader must be able to tolerate other readers observing the data at the same time. If the data has an invariant that spans multiple fields, a reader still sees a consistent snapshot only because no writer can be active while any reader is inside. That is the entire contract.

### 1.3 Reader-Writer Spinlock vs. Reader-Writer Semaphore

Linux has two reader-writer primitives, and they are not interchangeable:

| Property | `rwlock_t` | `rw_semaphore` |
|---|---|---|
| Waiting behavior | Spins | Sleeps |
| Context | Process, softirq, hardirq (with correct variant) | Process context only |
| Typical hold time | Very short, bounded | Longer; may sleep or block |
| Preemption | Disabled while held | May be enabled while held |
| Recursive readers | Conditional (see §8) | Conditional; lockdep models carefully |
| Upgrade/downgrade | No upgrade, no downgrade | `downgrade_write()` exists |
| Fairness | Queued, writer-preferring; process-context writer starvation prevented (interrupt readers can bypass) | Fair on non-RT; RT has different semantics |
| Best use | Tiny read-mostly data touched in atomic context | Read-mostly data that may be held across sleeps |

A **reader-writer semaphore** (`rw_semaphore`) is the sleeping counterpart. It is the right choice when the reader critical section may need to sleep, allocate memory with `GFP_KERNEL`, call into filesystem or block-layer code, or wait for I/O. `down_read()` and `down_write()` can block the caller; `up_read()` and `up_write()` release. It also provides `downgrade_write()` to atomically convert a write lock into a read lock — something `rwlock_t` does not offer.

An `rwlock_t` critical section, by contrast, runs with preemption disabled and must never sleep. It is for the same kind of code that would otherwise use a spinlock, but where reads dominate and reader concurrency is worth the extra atomic operations.

This document is about `rwlock_t`. The semaphore is mentioned only to keep the boundary clear.

### 1.4 When an `rwlock_t` Is the Wrong Tool

An `rwlock_t` is not a default replacement for a spinlock or a mutex. It is a specialized optimization with a narrow fit.

**It is a poor fit when writes are frequent.** Every writer excludes all readers, and every waiting writer forces new readers to queue. A write-heavy workload gets little concurrency benefit and pays the extra atomic operations and the internal wait lock.

**It is a poor fit when reader sections are tiny.** If a reader only loads one word, the atomic read-lock and read-unlock operations can cost more than a plain spinlock's single acquisition. The kernel documentation explicitly warns about this.

**It is a poor fit for pointer-based traversal that can use RCU.** RCU readers do not write to a shared lock word at all, can nest freely, and do not block writers. For linked-list traversal, routing lookups, and similar read-mostly structures, RCU is usually superior. The kernel documentation goes further: reader-writer spinlocks are being removed from most places, and new ones should not be added without consensus. See [Documentation/locking/spinlocks.rst](https://github.com/torvalds/linux/blob/v7.3-rc7/Documentation/locking/spinlocks.rst#L84-L93).

**It is a poor fit when the reader needs to sleep.** `rwlock_t` disables preemption; a sleeping reader is a bug.

**It is a poor fit when you need to upgrade.** There is no read-to-write upgrade. If a path might write, take the write lock from the start.

With those limits understood, the rest of this document looks at how the primitive actually works.

---

## 2. The `rwlock_t` Type on AArch64

### 2.1 Type Hierarchy

On a non-RT AArch64 SMP kernel, `rwlock_t` is a thin wrapper around an architecture-specific `arch_rwlock_t`, which on AArch64 is the generic **queued read-write lock**:

```
rwlock_t                              [include/linux/rwlock_types.h]
└── arch_rwlock_t  raw_lock           [arch/arm64/include/asm/spinlock_types.h]
    └── struct qrwlock                [include/asm-generic/qrwlock_types.h]
        ├── atomic_t cnts             ← reader count + writer state
        └── arch_spinlock_t wait_lock ← qspinlock, serializes slow paths
```

AArch64 selects the queued implementation unconditionally for SMP:

```c
select ARCH_USE_QUEUED_RWLOCKS
select ARCH_USE_QUEUED_SPINLOCKS
```

from [arch/arm64/Kconfig](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/Kconfig#L69-L70). The generic Kconfig then defaults `CONFIG_QUEUED_RWLOCKS` to `y` when the architecture asks for it, provided the kernel is SMP and not `PREEMPT_RT` — see [kernel/Kconfig.locks](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/Kconfig.locks#L269-L274).

Architecture code reaches the generic structure through [arch/arm64/include/asm/spinlock_types.h](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/spinlock_types.h#L12-L13):

```c
#include <asm-generic/qspinlock_types.h>
#include <asm-generic/qrwlock_types.h>
```

The outer `rwlock_t` definition comes from [include/linux/rwlock_types.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/rwlock_types.h#L25-L52):

```c
context_lock_struct(rwlock) {
    arch_rwlock_t raw_lock;
#ifdef CONFIG_DEBUG_SPINLOCK
    unsigned int magic, owner_cpu;
    void *owner;
#endif
#ifdef CONFIG_DEBUG_LOCK_ALLOC
    struct lockdep_map dep_map;
#endif
};
typedef struct rwlock rwlock_t;

#define RWLOCK_MAGIC 0xdeaf1eed
```

The debug fields are deliberately parallel to `spinlock_t`: a magic value to catch corruption, an owner CPU, an owner task pointer for write-lock recursion detection, and a lockdep map. In a production kernel without those options, `rwlock_t` is just the raw architecture lock.

### 2.2 The Queued Read-Write Lock Structure

The actual lock state lives in [include/asm-generic/qrwlock_types.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/asm-generic/qrwlock_types.h#L13-L32):

```c
typedef struct qrwlock {
    union {
        atomic_t cnts;
        struct {
#ifdef __LITTLE_ENDIAN
            u8 wlocked;    /* Locked for write? */
            u8 __lstate[3];
#else
            u8 __lstate[3];
            u8 wlocked;    /* Locked for write? */
#endif
        };
    };
    arch_spinlock_t wait_lock;
} arch_rwlock_t;
```

There are two members, and the split is the heart of the design:

- **`cnts`** is a single 32-bit atomic word. It holds both the writer state and the reader count. Readers update it with atomic add/subtract; writers update it with compare-and-swap and a byte store.
- **`wait_lock`** is an ordinary **queued spinlock**. It is not the reader-writer lock itself; it is the queue that serializes writers and process-context readers when they cannot take the fast path. Because it is a qspinlock, it has a FIFO **MCS** queue with per-CPU nodes and **WFE**-based waiting. Its internals are the subject of the spinlock document; here it is enough to know that it provides a fair, scalable queue for the slow path.

The class name `qrwlock` stands for **queued read-write lock**. The "queued" part refers to the `wait_lock` queue, not to a queue of every reader. Readers that take the fast path never touch `wait_lock`.

### 2.3 Lock Word Bit Layout

On little-endian AArch64, the 32-bit `cnts` word is divided as follows:

```
 31                        9  8   7                        0
┌───────────────────────────┬────┬──────────────────────────┐
│      reader count         │ W  │        wlocked           │
│   (each reader = 0x200)   │    │   (0xff = writer holds)  │
└───────────────────────────┴────┴──────────────────────────┘
                              │
                              └── _QW_WAITING = 0x100
```

The constants are defined in [include/asm-generic/qrwlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/asm-generic/qrwlock.h#L24-L31):

```c
#define _QW_WAITING 0x100   /* A writer is waiting        */
#define _QW_LOCKED  0x0ff   /* A writer holds the lock    */
#define _QW_WMASK   0x1ff   /* Writer mask                */
#define _QR_SHIFT   9       /* Reader count shift         */
#define _QR_BIAS    (1U << _QR_SHIFT)
```

The fields mean:

| Field | Bits | Width | Meaning |
|---|---|---|---|
| `wlocked` | 0–7 | 8 bits | Nonzero (`0xff`) while a writer holds the lock; zero otherwise |
| `_QW_WAITING` | 8 | 1 bit | A writer is queued and waiting for readers to drain |
| Reader count | 9–31 | 23 bits | Number of active readers, in units of `_QR_BIAS` (`0x200`) |

A reader adds `0x200`; ten readers produce `0x1400`. The low nine bits are reserved for writer state, so the reader count is incremented in steps that can never carry into the writer bits until the count exceeds 23 bits — roughly 8.3 million simultaneous readers, far beyond any practical kernel workload.

The byte-sized `wlocked` overlay exists for one reason: **writer unlock must clear only the writer byte**, leaving the reader count and the waiting bit untouched. That is why the writer's release path is a single byte store rather than a 32-bit store. We will return to this in §6.7.

The layout is endian-aware. On a big-endian AArch64 build, the `wlocked` byte is placed in the high-order byte by the `#else` branch, so the same C code still addresses the correct byte. The rest of this document assumes the common little-endian configuration.

### 2.4 Lock States

The raw word takes a small number of meaningful values. The following table uses `R` for the reader count contribution (`N * 0x200`):

| `cnts` value | Meaning |
|---|---|
| `0x00000000` | Unlocked: no writer, no readers, no waiter |
| `0x000000ff` | Write-locked; no readers, no other waiting writer |
| `0x00000200` | One reader; no writer |
| `0x00000400` | Two readers; no writer |
| `0x00000100` | A writer is waiting; no readers and no writer holder (transient) |
| `0x000001ff` | A writer holds the lock and another writer is waiting |
| `0x00000300` | One reader plus a waiting writer; no writer holder |
| `0x000002ff` | A writer holds the lock; one queued reader has already registered itself and is waiting for the writer to release |

The last state looks surprising: a reader count can be nonzero while a writer holds the lock. That happens because a process-context reader in the slow path adds its bias **before** it waits for the current writer to release. It is registered as a reader, but it is not yet inside its critical section. A new writer cannot jump in because the reader count keeps the word away from the `0x100` state the writer waits for.

A writer-held state with a reader count is also why unlock must be a byte store. If the writer cleared the whole word, it would erase that queued reader's count and corrupt the handoff.

### 2.5 Size and Cache-Line Behavior

On a non-debug, non-RT AArch64 kernel, `arch_rwlock_t` is two 32-bit words: `cnts` and the qspinlock `wait_lock`, for a total of **8 bytes**. With `CONFIG_DEBUG_SPINLOCK`, the outer `rwlock_t` grows by the magic, owner CPU, and owner pointer; with `CONFIG_DEBUG_LOCK_ALLOC`, it grows further by the lockdep map. On `PREEMPT_RT`, the type is replaced entirely by an rt-mutex-based structure.

The small size is deliberate. Embedding an 8-byte lock in a structure is cheap. But the two words usually share a cache line, and that has consequences:

- Every reader performs an atomic read-modify-write on `cnts`. Even though readers logically share the lock, they all contend for **exclusive ownership of the same cache line** in the coherency protocol. A read lock is not a read-only cache access; it is a write to the lock word.
- `wait_lock` sits in the same cache line as `cnts`. When a writer enters the slow path, its queue operations touch the same line that readers are actively modifying. The qspinlock's waiters spin on their own per-CPU MCS nodes, but the queue tail and lock bit are in the shared line.
- A lock embedded in a hot data structure can suffer **false sharing** with unrelated fields. The kernel sometimes aligns important locks to a cache line for this reason. A well-known example is `tasklist_lock`, declared as `__cacheline_aligned DEFINE_RWLOCK(tasklist_lock)` in [kernel/fork.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/fork.c#L159).

The practical lesson is that `rwlock_t` reduces logical serialization, not hardware serialization. Readers still serialize at the cache-coherency level for the duration of the atomic update; they simply do not serialize for the duration of the critical section.

---

## 3. Initialization

### 3.1 Static Initialization

For a lock with static storage duration, use `DEFINE_RWLOCK`:

```c
#include <linux/spinlock.h>

static DEFINE_RWLOCK(my_rwlock);
```

`<linux/spinlock.h>` is the ordinary include; the type declaration itself lives in `<linux/rwlock_types.h>`. This expands through `__RW_LOCK_UNLOCKED` to an initializer for the raw lock and, when debugging is enabled, the magic, owner, and lockdep fields. In [include/linux/rwlock_types.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/rwlock_types.h#L39-L52):

```c
#ifdef CONFIG_DEBUG_SPINLOCK
#define __RW_LOCK_UNLOCKED(lockname)                    \
    (rwlock_t) { .raw_lock = __ARCH_RW_LOCK_UNLOCKED,   \
                 .magic = RWLOCK_MAGIC,                 \
                 .owner = SPINLOCK_OWNER_INIT,          \
                 .owner_cpu = -1,                       \
                 RW_DEP_MAP_INIT(lockname) }
#else
#define __RW_LOCK_UNLOCKED(lockname) \
    (rwlock_t) { .raw_lock = __ARCH_RW_LOCK_UNLOCKED, \
                 RW_DEP_MAP_INIT(lockname) }
#endif

#define DEFINE_RWLOCK(x) rwlock_t x = __RW_LOCK_UNLOCKED(x)
```

The raw initializer is `__ARCH_RW_LOCK_UNLOCKED`, defined in [include/asm-generic/qrwlock_types.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/asm-generic/qrwlock_types.h#L29-L32), which zeroes `cnts` and initializes `wait_lock` to the unlocked qspinlock state. An all-zero `cnts` word means "no writer, no readers, no waiter," which is exactly the unlocked state.

### 3.2 Dynamic Initialization

For a lock allocated at runtime, call `rwlock_init`:

```c
#include <linux/slab.h>
#include <linux/spinlock.h>

static rwlock_t *dyn_lock;

static int __init init_dynamic_lock(void)
{
    dyn_lock = kzalloc(sizeof(*dyn_lock), GFP_KERNEL);
    if (!dyn_lock)
        return -ENOMEM;

    rwlock_init(dyn_lock);
    return 0;
}
```

The macro is defined in [include/linux/rwlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/rwlock.h#L17-L29):

```c
#ifdef CONFIG_DEBUG_SPINLOCK
extern void __rwlock_init(rwlock_t *lock, const char *name,
                          struct lock_class_key *key);
#define rwlock_init(lock)                    \
do {                                         \
    static struct lock_class_key __key;      \
    __rwlock_init((lock), #lock, &__key);    \
} while (0)
#else
#define rwlock_init(lock) \
    do { *(lock) = __RW_LOCK_UNLOCKED(lock); } while (0)
#endif
```

The `static struct lock_class_key __key` is important for lockdep: it gives the call site a stable identity, so two dynamically initialized locks at the same source location are treated as the same **lock class**, while locks initialized at different call sites are distinct classes.

A dynamically allocated lock must remain at the same address for its entire lifetime. Do not `krealloc` it, copy it, or free it while it is held or while any task is waiting on it. Waiters spin on the memory; freeing it is a use-after-free.

### 3.3 What Initialization Actually Does

In the non-debug case, initialization is a simple structure assignment. In the debug case, `__rwlock_init` in [kernel/locking/spinlock_debug.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/spinlock_debug.c#L36-L52) does more:

```c
void __rwlock_init(rwlock_t *lock, const char *name,
                   struct lock_class_key *key)
{
#ifdef CONFIG_DEBUG_LOCK_ALLOC
    debug_check_no_locks_freed((void *)lock, sizeof(*lock));
    lockdep_init_map_wait(&lock->dep_map, name, key, 0, LD_WAIT_CONFIG);
#endif
    lock->raw_lock = (arch_rwlock_t) __ARCH_RW_LOCK_UNLOCKED;
    lock->magic = RWLOCK_MAGIC;
    lock->owner = SPINLOCK_OWNER_INIT;
    lock->owner_cpu = -1;
}
```

`debug_check_no_locks_freed` checks whether the current task still holds a lock whose instance overlaps the memory being initialized, catching some use-after-free and reinitialization bugs (it is a per-current-task check, not a global guarantee). The magic value `RWLOCK_MAGIC` (`0xdeaf1eed`) is checked on every debug lock and unlock; a mismatch means the lock has been corrupted by a buffer overrun, use-after-free, or uninitialized memory.

Never initialize an `rwlock_t` by hand:

```c
/* Wrong: debug fields and lockdep state are not set up. */
memset(&my_lock, 0, sizeof(my_lock));

/* Also wrong: bypasses the API and any lockdep registration. */
my_lock = (rwlock_t){ };
```

Use `DEFINE_RWLOCK` or `rwlock_init`. The same rule applies to reinitialization: do not call `rwlock_init` on a held lock.

---

## 4. Core API and Call Chain

### 4.1 `read_lock` and `read_unlock`

The public macros are defined in [include/linux/rwlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/rwlock.h#L62-L66):

```c
#define read_trylock(lock)  _raw_read_trylock(lock)
#define write_trylock(lock) _raw_write_trylock(lock)

#define write_lock(lock)    _raw_write_lock(lock)
#define read_lock(lock)     _raw_read_lock(lock)
```

On a non-`PREEMPT_RT` kernel, `_raw_read_lock` resolves to the inline implementation in [include/linux/rwlock_api_smp.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/rwlock_api_smp.h#L159-L165):

```c
static inline void __raw_read_lock(rwlock_t *lock)
{
    preempt_disable();
    rwlock_acquire_read(&lock->dep_map, 0, 0, _RET_IP_);
    LOCK_CONTENDED(lock, do_raw_read_trylock, do_raw_read_lock);
}
```

The call chain on AArch64 is:

```
read_lock(lock)
  └── _raw_read_lock(&lock->rlock)              [include/linux/rwlock.h]
        └── __raw_read_lock()                   [include/linux/rwlock_api_smp.h]
              ├── preempt_disable()
              ├── rwlock_acquire_read()         ← lockdep
              └── do_raw_read_lock()
                    └── arch_read_lock() = queued_read_lock()
                          ├── atomic_add_return_acquire(0x200, &cnts)
                          └── queued_read_lock_slowpath() if writer state
```

There are three immediate consequences:

1. **Preemption is disabled** for the duration of the read-side critical section. A reader cannot be scheduled out. This is what makes it safe to use in atomic context, and what makes sleeping under the lock illegal.
2. **Lockdep sees a shared acquisition**, unless `read_lock_is_recursive()` says otherwise. The classification is subtle and is covered in §8.3.
3. **The fast path is one atomic read-modify-write** on `cnts`. There is no `wait_lock` access for an uncontended reader.

`read_unlock` is the mirror image. It calls `rwlock_release`, `do_raw_read_unlock`, and `preempt_enable`, with the architecture-specific body performing an atomic subtract:

```c
static inline void queued_read_unlock(struct qrwlock *lock)
{
    (void)atomic_sub_return_release(_QR_BIAS, &lock->cnts);
}
```

from [include/asm-generic/qrwlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/asm-generic/qrwlock.h#L104-L114). The release semantics ensure that all memory operations performed inside the reader's critical section are visible before the reader count drops. Writers depend on that ordering when they observe the count reaching zero.

### 4.2 `write_lock` and `write_unlock`

The writer path is defined in [include/linux/rwlock_api_smp.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/rwlock_api_smp.h#L225-L231):

```c
static inline void __raw_write_lock(rwlock_t *lock)
{
    preempt_disable();
    rwlock_acquire(&lock->dep_map, 0, 0, _RET_IP_);
    LOCK_CONTENDED(lock, do_raw_write_trylock, do_raw_write_lock);
}
```

The chain is:

```
write_lock(lock)
  └── _raw_write_lock()
        └── __raw_write_lock()
              ├── preempt_disable()
              ├── rwlock_acquire()             ← lockdep exclusive
              └── do_raw_write_lock()
                    └── arch_write_lock() = queued_write_lock()
                          ├── atomic_try_cmpxchg_acquire(0 → 0xff)
                          └── queued_write_lock_slowpath() if contended
```

`write_unlock` does not use an atomic read-modify-write on the whole word. It performs a **release byte store** to `wlocked`:

```c
static inline void queued_write_unlock(struct qrwlock *lock)
{
    smp_store_release(&lock->wlocked, 0);
}
```

from [include/asm-generic/qrwlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/asm-generic/qrwlock.h#L116-L123). On AArch64 this becomes `STLRB`, a store-release byte instruction. The byte store is not an optimization detail; it is required for correctness when a reader is concurrently updating the reader count in the same word. Section 6.7 explains why.

### 4.3 Trylock Operations

`read_trylock` attempts a read acquisition without waiting. It reads `cnts`; if no writer state is present, it adds the reader bias and checks again. If a writer appeared in the meantime, it subtracts the bias and returns 0. The implementation is in [include/asm-generic/qrwlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/asm-generic/qrwlock.h#L44-L56):

```c
static inline int queued_read_trylock(struct qrwlock *lock)
{
    int cnts;

    cnts = atomic_read(&lock->cnts);
    if (likely(!(cnts & _QW_WMASK))) {
        cnts = (u32)atomic_add_return_acquire(_QR_BIAS, &lock->cnts);
        if (likely(!(cnts & _QW_WMASK)))
            return 1;
        atomic_sub(_QR_BIAS, &lock->cnts);
    }
    return 0;
}
```

`write_trylock` is stricter: it succeeds only if the entire word is zero. A single reader or a single waiting writer makes it fail immediately. See [include/asm-generic/qrwlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/asm-generic/qrwlock.h#L58-L73).

The two non-blocking paths can be summarized as:

```
read_trylock(L)
  ├─ (cnts & 0x1ff) != 0 ──────────────────────→ return 0
  └─ atomic_add_return_acquire(0x200)
       ├─ (new_cnts & 0x1ff) == 0 ─────────────→ success
       └─ otherwise
            atomic_sub(0x200) ─────────────────→ return 0


write_trylock(L)
  ├─ cnts != 0 ────────────────────────────────→ return 0
  └─ atomic_try_cmpxchg_acquire(0 → 0xff)
       ├─ CAS succeeded ───────────────────────→ success
       └─ CAS failed ──────────────────────────→ return 0
```

A successful trylock is a real acquisition: it disables preemption and must be paired with the corresponding unlock. A failed trylock leaves the lock untouched and does not change the preemption count.

The public entry points are `read_trylock()` and `write_trylock()`. There is also `write_trylock_irqsave()`, which saves the IRQ state, attempts the write lock, and restores the state if the attempt fails:

```c
unsigned long flags;

if (write_trylock_irqsave(&my_lock, flags)) {
    /* exclusive access */
    write_unlock_irqrestore(&my_lock, flags);
}
```

There is no `read_trylock_irqsave()` in the non-RT API. If a non-blocking reader is needed with IRQ protection, the usual pattern is to disable interrupts, call `read_trylock()`, and restore the flags on failure. Be careful to restore the exact state, not blindly enable interrupts.

`trylock` does not disable preemption on failure. On success it behaves like the corresponding blocking acquisition and must be paired with the matching unlock.

### 4.4 `rwlock_is_contended`

`rwlock_is_contended()` is a hint, not a synchronization operation. On AArch64 it maps to:

```c
static inline int queued_rwlock_is_contended(struct qrwlock *lock)
{
    return arch_spin_is_locked(&lock->wait_lock);
}
```

from [include/asm-generic/qrwlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/asm-generic/qrwlock.h#L125-L133). It reports whether the internal wait lock is held, which usually means a writer or a queued reader is in the slow path. It does **not** detect fast-path reader contention on `cnts`, so a `false` result does not mean the lock is uncontended. It is used by `rwlock_needbreak()` in [include/linux/spinlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/spinlock.h#L500-L514) to decide whether a long-running kernel loop should break out, drop the lock, and reschedule.

There is no `rwlock_is_locked()` in the non-RT API. For debug assertions, use `lockdep_is_held(lock)` for a lock pointer (or `lockdep_is_held(&my_lock)` for a named lock), which checks the lock's embedded dep map. The assertion helpers `lockdep_assert_held()`, `lockdep_assert_held_read()`, and `lockdep_assert_held_write()` are also available in code compiled with lockdep.

### 4.5 Complete API Table

| Operation | Description |
|---|---|
| `read_lock(lock)` | Acquire shared access; disables preemption |
| `read_lock_bh(lock)` | Disable bottom halves, then acquire shared access |
| `read_lock_irq(lock)` | Disable local interrupts, then acquire shared access |
| `read_lock_irqsave(lock, flags)` | Save IRQ state, disable interrupts, acquire shared access |
| `read_unlock(lock)` | Release shared access; re-enable preemption |
| `read_unlock_bh(lock)` | Release shared access; re-enable bottom halves |
| `read_unlock_irq(lock)` | Release shared access; enable local interrupts |
| `read_unlock_irqrestore(lock, flags)` | Release shared access; restore saved IRQ state |
| `write_lock(lock)` | Acquire exclusive access; disables preemption |
| `write_lock_nested(lock, subclass)` | Exclusive acquire with a lockdep subclass (not recursive locking) |
| `write_lock_bh(lock)` | Disable bottom halves, then acquire exclusive access |
| `write_lock_irq(lock)` | Disable local interrupts, then acquire exclusive access |
| `write_lock_irqsave(lock, flags)` | Save IRQ state, disable interrupts, acquire exclusive access |
| `write_unlock(lock)` | Release exclusive access; re-enable preemption |
| `write_unlock_bh(lock)` | Release exclusive access; re-enable bottom halves |
| `write_unlock_irq(lock)` | Release exclusive access; enable local interrupts |
| `write_unlock_irqrestore(lock, flags)` | Release exclusive access; restore saved IRQ state |
| `read_trylock(lock)` | Non-blocking shared acquire; returns nonzero on success |
| `write_trylock(lock)` | Non-blocking exclusive acquire; returns nonzero on success |
| `write_trylock_irqsave(lock, flags)` | Non-blocking exclusive acquire with IRQ save/restore |
| `rwlock_init(lock)` | Initialize a dynamically allocated lock |
| `rwlock_is_contended(lock)` | Hint: is the internal wait lock held? |

The `_bh`, `_irq`, and `_irqsave` variants follow the same suffix rules as spinlocks. The difference is that they apply to both readers and writers, and the read side has an additional interrupt-context special case that we will examine in §6.4 and §10.

---

## 5. A Complete `kthread` Example

The following module creates one writer thread and three reader threads. The writer periodically updates a small sensor snapshot under the write lock; the readers copy the snapshot under the read lock and print it after unlocking. The critical sections are deliberately tiny, and `msleep()` is called only outside the lock.

```c
// SPDX-License-Identifier: GPL-2.0
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/kthread.h>
#include <linux/delay.h>
#include <linux/spinlock.h>

#define NR_READERS 3

struct sensor_state {
    int temperature;
    int humidity;
    u64 updates;
};

static struct sensor_state state;
static DEFINE_RWLOCK(state_lock);
static struct task_struct *readers[NR_READERS];
static struct task_struct *writer;

static int reader_fn(void *data)
{
    unsigned long id = (unsigned long)data;

    while (!kthread_should_stop()) {
        struct sensor_state snapshot;

        read_lock(&state_lock);
        snapshot = state;
        read_unlock(&state_lock);

        pr_info("reader%lu: temp=%dC humidity=%d%% updates=%llu\n",
                id, snapshot.temperature, snapshot.humidity,
                (unsigned long long)snapshot.updates);

        msleep(1000 + (unsigned int)id * 250);
    }
    return 0;
}

static int writer_fn(void *data)
{
    u64 count = 0;

    while (!kthread_should_stop()) {
        write_lock(&state_lock);
        state.temperature = 20 + (int)(count % 10);
        state.humidity = 40 + (int)(count % 20);
        state.updates = ++count;
        write_unlock(&state_lock);

        msleep(500);
    }
    return 0;
}

static void stop_all_threads(void)
{
    int i;

    if (writer)
        kthread_stop(writer);
    for (i = 0; i < NR_READERS; i++)
        if (readers[i])
            kthread_stop(readers[i]);
}

static int __init rwlock_demo_init(void)
{
    int i;

    writer = kthread_run(writer_fn, NULL, "rw-writer");
    if (IS_ERR(writer)) {
        int ret = PTR_ERR(writer);

        writer = NULL;
        return ret;
    }

    for (i = 0; i < NR_READERS; i++) {
        readers[i] = kthread_run(reader_fn, (void *)(unsigned long)i,
                                 "rw-reader%d", i);
        if (IS_ERR(readers[i])) {
            int ret = PTR_ERR(readers[i]);

            readers[i] = NULL;
            stop_all_threads();
            return ret;
        }
    }

    pr_info("rwlock demo loaded\n");
    return 0;
}

static void __exit rwlock_demo_exit(void)
{
    stop_all_threads();
    pr_info("rwlock demo unloaded\n");
}

module_init(rwlock_demo_init);
module_exit(rwlock_demo_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("rwlock_t reader/writer kthread example");
```

A few points are worth calling out:

- **The snapshot is copied under the lock.** Copying individual fields one at a time after unlocking would allow a writer to interleave and produce a torn view. The structure assignment inside the critical section gives a consistent snapshot.
- **Printing happens outside the lock.** `pr_info()` can be slow and may take internal locks. Even though it does not sleep in the usual sense, holding a spinlock across console output is poor practice and can create lock-order problems.
- **`msleep()` is outside the lock.** Sleeping while holding `rwlock_t` is illegal because preemption is disabled. The module would trigger `CONFIG_DEBUG_ATOMIC_SLEEP` warnings and could deadlock other CPUs.
- **The reader threads can run concurrently.** When the writer is asleep, all three readers can be inside `read_lock()` at the same time. The lock word's reader count reflects that.
- **The writer is exclusive.** While the writer is inside, no reader can enter, and while any reader is inside, the writer waits.

The companion variants — the continuous two-reader/one-writer loop and the one-shot two-reader/one-writer or two-writer/two-reader runs — show the same behavior; their interleaving is scheduler-dependent, so read the trace as an observation rather than a fixed order.

If you want to observe reader concurrency, add a temporary busy-wait or tracepoint inside the read-side critical section and watch the overlap. Do not replace it with `msleep()`; that changes the experiment into a bug.

---

## 6. Internal Implementation

### 6.1 The Two-Level Design

The queued read-write lock separates the **common case** from the **contended case**:

- **Common case:** a reader arrives and no writer is present. It performs one atomic add on `cnts` and enters. No queue, no wait lock, no per-CPU node.
- **Common case:** a writer arrives and the lock is completely free. It performs one compare-and-swap on `cnts` and enters. No queue.
- **Contended case:** a writer must wait for readers to drain, or a reader arrives while a writer holds or waits. These cases go through `wait_lock`, a fair qspinlock, which serializes the contenders and prevents barging.

```
Fast path (uncontended)                       Slow path (contended)
────────────────────────                      ──────────────────────
reader: atomic_add_return_acquire(cnts)       reader: queue on wait_lock
writer: atomic_try_cmpxchg_acquire(cnts)      writer: queue on wait_lock
        │                                             │
        └──────────────────┬──────────────────────────┘
                           ▼
                  one 32-bit `cnts` word
             ┌────────────┬────────┬────────────┐
             │  readers   │ waiter │   writer   │
             └────────────┴────────┴────────────┘
```

This split is why the design is compact and fast in the uncontended case while still being fair under contention. The `cnts` word is the fast-path state; `wait_lock` is the slow-path queue.

It also explains the unusual locking rule inside the slow paths: a writer holds `wait_lock` **while it waits for readers to drain**. That is not a deadlock, because readers do not need `wait_lock` to finish — they only need to decrement `cnts`. The writer's hold on `wait_lock` prevents new process-context readers and writers from entering the queue ahead of it, which is the mechanism that provides fairness.

### 6.2 Reader Fast Path

The fast path is in [include/asm-generic/qrwlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/asm-generic/qrwlock.h#L74-L88):

```c
static inline void queued_read_lock(struct qrwlock *lock)
{
    int cnts;

    cnts = atomic_add_return_acquire(_QR_BIAS, &lock->cnts);
    if (likely(!(cnts & _QW_WMASK)))
        return;

    /* The slowpath will decrement the reader count, if necessary. */
    queued_read_lock_slowpath(lock);
}
```

The reader unconditionally adds `0x200` and examines the **new** value. If the low nine bits are zero, there is no writer holder and no waiting writer, so the reader is in. The add itself is the acquisition; the acquire ordering ensures that subsequent loads in the critical section cannot be reordered before the lock acquisition.

If the low nine bits are nonzero, either a writer holds the lock (`0xff`) or a writer is waiting (`0x100`), or both. The reader has already incremented the count, so the slow path must either undo that increment (process context) or keep it while waiting (interrupt context). The comment in the code is a warning: the slow path is responsible for fixing the count.

There is a narrow race here that explains why the ordering is "mostly fair" rather than strictly FIFO. Suppose a writer is about to set the waiting bit, but a reader executes its atomic add first. The reader sees a value with no writer state and enters. The writer then sets the waiting bit and must wait for that reader. This is bounded by the short window between the reader's add and the writer's store; it is not a general reader-priority policy.

A second subtlety: `atomic_add_return_acquire` returns the **new** value, not the old one. The check is therefore against the state after this reader has joined. If another reader joins concurrently, the count is higher, but the low bits still encode only writer state.

### 6.3 Reader Slow Path: Process Context

When a process-context reader cannot take the fast path, it executes `queued_read_lock_slowpath` in [kernel/locking/qrwlock.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/qrwlock.c#L21-L60):

```c
void __lockfunc queued_read_lock_slowpath(struct qrwlock *lock)
{
    if (unlikely(in_interrupt())) {
        atomic_cond_read_acquire(&lock->cnts, !(VAL & _QW_LOCKED));
        return;
    }

    atomic_sub(_QR_BIAS, &lock->cnts);

    trace_contention_begin(lock, LCB_F_SPIN | LCB_F_READ);

    arch_spin_lock(&lock->wait_lock);
    atomic_add(_QR_BIAS, &lock->cnts);

    atomic_cond_read_acquire(&lock->cnts, !(VAL & _QW_LOCKED));

    arch_spin_unlock(&lock->wait_lock);

    trace_contention_end(lock, 0);
}
```

Ignoring the interrupt branch for a moment, the process-context sequence is:

1. **Undo the speculative reader increment.** The reader had added `0x200` in the fast path but did not acquire. Subtracting it restores the count to the state other contenders expect. This is important: a reader that is about to queue must not look like an active reader, or a waiting writer might wait for a critical section that has not even started.
2. **Queue on `wait_lock`.** This is where fairness comes from. If a writer is waiting, it already holds `wait_lock` while it drains readers, so the new reader blocks behind it. If another reader or writer is already queued, the qspinlock's FIFO order decides.
3. **Re-add the reader bias.** Once the reader owns the queue position, it registers itself as a reader again. From this point on, any writer that later tries to acquire will see this reader in `cnts` and wait for it to finish.
4. **Wait until no writer holds the lock.** The condition is `!(VAL & _QW_LOCKED)`, not "no waiting writer." The reader is allowed to proceed once the current writer releases, even if another writer is waiting behind it in the queue. The queue order ensures that the next writer does not jump ahead: the reader holds `wait_lock` until it has entered, and the next writer cannot acquire `wait_lock` until the reader releases it.
5. **Release `wait_lock`.** This hands the queue head to the next contender. The reader is now inside its critical section; it no longer needs the queue.

The fact that the reader holds `wait_lock` while waiting for the writer to release is the key to the fairness protocol. It means a new writer cannot slip in while the reader is waiting, and a new reader cannot jump the queue either.

There is a subtle consequence: a process-context reader that is waiting behind a writer is counted in `cnts` while it waits. That is the `0x2ff` state from §2.4. It is intentional. The writer currently holding the lock does not care about the count; the next writer will wait for this reader, as it should.

The whole reader path, including both slow-path branches, looks like this:

```
queued_read_lock()
  atomic_add_return_acquire(0x200)
        │
        ├─ low 9 bits == 0 ───────────────────→ return (reader CS)
        │
        └─ writer state present
              │
              ├─ in_interrupt()
              │     └─ spin until !(cnts & 0xff)  [keep the 0x200;
              │                                      never touch wait_lock]
              │
              └─ process context
                    atomic_sub(0x200)              [undo speculative add]
                    arch_spin_lock(wait_lock)      [queue behind writer]
                    atomic_add(0x200)              [register as waiter]
                    spin until !(cnts & 0xff)      [wait for holder only]
                    arch_spin_unlock(wait_lock)    [hand off queue head]
                    return (reader CS)
```

### 6.4 Reader Slow Path: Interrupt Context

The `in_interrupt()` branch is the most important special case in the whole implementation:

```c
if (unlikely(in_interrupt())) {
    /*
     * Readers in interrupt context will get the lock immediately
     * if the writer is just waiting (not holding the lock yet),
     * so spin with ACQUIRE semantics until the lock is available
     * without waiting in the queue.
     */
    atomic_cond_read_acquire(&lock->cnts, !(VAL & _QW_LOCKED));
    return;
}
```

An interrupt-context reader does **not** subtract its bias, does **not** take `wait_lock`, and does **not** queue. It keeps its reader count and spins until the **current writer holder** releases. If a writer is merely waiting (the waiting bit is set but `wlocked` is zero), the condition is already true and the interrupt reader enters immediately.

One precision: `in_interrupt()` is broader than "hardirq handler." It is true in hardirq, softirq, and NMI context, and also while bottom halves are disabled in process context; see [include/linux/preempt.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/preempt.h#L140-L169). A process-context `read_lock_bh()` therefore takes this bypass path if a writer is already waiting, because BH disabling makes `in_interrupt()` true. The code is really testing "this is an atomic context that must not queue behind a writer," not the narrower question "is this a hardware interrupt?"

Why this exception? Consider the following deadlock:

```
CPU 0 (process context)                 CPU 1
────────────────────────                ─────────────────────
read_lock(&L);          ← holds reader
                                        write_lock(&L);
                                          wait_lock held,
                                          _QW_WAITING set,
                                          waits for readers to drain

  ← hard IRQ fires on CPU 0

CPU 0 (IRQ handler)
  read_lock(&L);
    if it queued behind the writer:
      waits on wait_lock
      writer waits for CPU 0's process reader
      process reader cannot run until IRQ returns
      → deadlock
```

The interrupt reader cannot safely queue behind a waiting writer, because the interrupted context might itself be a reader that the writer is waiting for. The special path breaks the cycle: the interrupt reader ignores the waiting writer and waits only for an actual writer **holder** to finish. Since a writer holder cannot be the interrupted process reader on the same CPU (a writer excludes readers), this path makes progress.

The cost is a small fairness violation: an interrupt reader can enter ahead of a writer that is already waiting. That is a deliberate trade-off. It also means a continuous storm of interrupt-context readers can delay a writer, a point we return to in §9.5.

The special path does **not** protect against a writer that already **holds** the lock and was interrupted on the same CPU. If a process-context writer holds `wlocked` and an interrupt fires on that CPU, the interrupt reader will spin on `_QW_LOCKED` forever, because the writer cannot resume until the interrupt returns. That is why writers sharing a lock with hardirq readers must disable interrupts — see §10.

### 6.5 Writer Fast Path

The writer fast path is a single compare-and-swap in [include/asm-generic/qrwlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/asm-generic/qrwlock.h#L90-L102):

```c
static inline void queued_write_lock(struct qrwlock *lock)
{
    int cnts = 0;

    /* Optimize for the unfair lock case where the fair flag is 0. */
    if (likely(atomic_try_cmpxchg_acquire(&lock->cnts, &cnts, _QW_LOCKED)))
        return;

    queued_write_lock_slowpath(lock);
}
```

The CAS succeeds only when the entire word is zero: no readers, no waiting writer, no writer holder. On success, `cnts` becomes `0xff`. The acquire semantics order the writer's subsequent loads and stores after the acquisition. On AArch64 with LSE, this is a `CASA` instruction; without LSE, it is an `LDAXR`/`STLXR` loop.

A failed CAS returns the observed value in `cnts`, which the slow path uses to decide what to do. The comment about the "unfair lock case" means: if the lock is completely free, take it immediately even if there might be a queued contender that has not yet registered. The slow path is responsible for preserving fairness once contention actually exists.

### 6.6 Writer Slow Path

The slow path is where fairness is enforced. It is in [kernel/locking/qrwlock.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/qrwlock.c#L62-L91):

```c
void __lockfunc queued_write_lock_slowpath(struct qrwlock *lock)
{
    int cnts;

    trace_contention_begin(lock, LCB_F_SPIN | LCB_F_WRITE);

    /* Put the writer into the wait queue */
    arch_spin_lock(&lock->wait_lock);

    /* Try to acquire the lock directly if no reader is present */
    if (!(cnts = atomic_read(&lock->cnts)) &&
        atomic_try_cmpxchg_acquire(&lock->cnts, &cnts, _QW_LOCKED))
        goto unlock;

    /* Set the waiting flag to notify readers that a writer is pending */
    atomic_or(_QW_WAITING, &lock->cnts);

    /* When no more readers or writers, set the locked flag */
    do {
        cnts = atomic_cond_read_relaxed(&lock->cnts, VAL == _QW_WAITING);
    } while (!atomic_try_cmpxchg_acquire(&lock->cnts, &cnts, _QW_LOCKED));
unlock:
    arch_spin_unlock(&lock->wait_lock);

    trace_contention_end(lock, 0);
}
```

Step by step:

1. **Join the wait queue.** `arch_spin_lock(&lock->wait_lock)` takes the internal qspinlock. From this point until the writer acquires the rwlock, it owns the queue head. Any other slow-path contender — reader or writer — waits behind it.
2. **Retry the fast path while holding the queue.** The writer re-reads `cnts`. If it is zero, the writer can acquire immediately with a CAS. This handles the case where the readers that caused the original failure have already drained. It is also the "direct acquire" path that avoids setting the waiting bit unnecessarily.
3. **Set the waiting bit.** `atomic_or(_QW_WAITING, &cnts)` sets bit 8. This is the signal to process-context readers that a writer is queued. A new reader that sees this bit will not take the fast path; it will queue behind the writer on `wait_lock`.
4. **Wait for the word to become exactly `_QW_WAITING`.** The condition `VAL == _QW_WAITING` means all readers have drained and no other writer holds the lock. If readers are still present, the value is `0x100 + N*0x200`; if another writer holds the lock, the low byte is `0xff` (and readers may also be present). The writer stays in this loop until only its own waiting bit remains.
5. **Claim the lock with an acquire CAS.** The compare-and-swap changes `0x100` to `0xff`. The acquire semantics are essential: they ensure the writer sees all memory operations performed by the readers that just left. The CAS also clears the waiting bit, so the word is now the normal write-locked state.
6. **Release the wait queue.** `arch_spin_unlock(&lock->wait_lock)` lets the next contender proceed. If readers are queued behind the writer, the first one now acquires `wait_lock`, re-adds its bias, and waits for this writer to release.

The complete writer path can be reduced to the following decision tree:

```
queued_write_lock()
  atomic_try_cmpxchg_acquire(0 → 0xff)
        │
        ├─ success ─────────────────────────────→ return (writer CS)
        │
        └─ failure
              arch_spin_lock(wait_lock)
                    │
                    ├─ cnts == 0
                    │     └─ CAS 0 → 0xff succeeds
                    │           └─ unlock(wait_lock); return (writer CS)
                    │
                    └─ readers or writer present
                          atomic_or(_QW_WAITING)
                          spin until cnts == 0x100
                          CAS 0x100 → 0xff
                          unlock(wait_lock)
                          return (writer CS)
```

Two details in that tree matter. The direct `0 → 0xff` attempt inside the slow path avoids setting `_QW_WAITING` when the readers have already drained. And the final `0x100 → 0xff` CAS is the acquire operation that publishes the readers' prior stores to the writer.

The writer holds `wait_lock` for the entire drain period. That looks like a long time to hold a spinlock, and it is — but the "lock" here is only the internal queue, not the rwlock's data protection. Readers do not need `wait_lock` to leave their critical sections; they only need to decrement `cnts`. The writer is using `wait_lock` as a fairness barrier, not as a data lock.

The waiting bit is sticky in a useful way. Once set, it forces new process-context readers into the slow path, so they cannot continuously extend the writer's wait. When the writer acquires, the CAS to `0xff` clears the bit. When the writer later unlocks, the byte store leaves the word in whatever state the next contenders have established.

### 6.7 Unlock Paths and the Byte Store

The reader unlock path is an atomic subtract with release semantics:

```c
static inline void queued_read_unlock(struct qrwlock *lock)
{
    (void)atomic_sub_return_release(_QR_BIAS, &lock->cnts);
}
```

The writer unlock path is a release byte store:

```c
static inline void queued_write_unlock(struct qrwlock *lock)
{
    smp_store_release(&lock->wlocked, 0);
}
```

The asymmetry is not an accident. Consider what can be happening in the word when a writer unlocks:

```
Before unlock:

  cnts = 0x000002ff
         └──┬──┘└┬┘
            │   └── wlocked = 0xff  (writer holds)
            └────── reader count = 0x200 (one queued reader has
                    already registered and is waiting for the writer)
```

If the writer performed a 32-bit store of zero, it would erase the reader's `0x200`, and the reader would later subtract `0x200` from a word that no longer contains it, underflowing the count and corrupting the lock. If the writer performed a 32-bit store of `0x00000100` to preserve a waiting writer, it would still clobber any reader count that arrived concurrently.

The byte store avoids both problems:

```
After smp_store_release(&wlocked, 0):

  cnts = 0x00000200
         └────── reader count preserved; writer byte cleared
```

Only the low byte changes. The reader count and the waiting bit are untouched. A queued reader that was waiting for `_QW_LOCKED` to clear now sees the condition satisfied and enters. If a writer is also waiting behind that reader, it cannot claim the lock until the reader count drains and the word becomes exactly `0x100`; the byte store preserved both the reader count and the waiting bit for that later handoff.

The byte store is also ordered. `smp_store_release` on AArch64 emits `STLRB`, which ensures that all stores performed inside the writer's critical section are globally visible before the `wlocked` byte becomes zero. A reader that observes the cleared byte with acquire semantics is therefore guaranteed to see the writer's data updates.

The same reasoning applies when there is no queued reader. The writer unlocks from `0xff` to `0x00`; the byte store is simply a one-byte zeroing of the writer state. The reader count is already zero, so nothing is lost.

### 6.8 End-to-End State Machine

The following diagram shows the main states and transitions. It omits the transient races and shows the intended protocol.

```
                        0x00000000
                         UNLOCKED
                        /        \
          read_lock()  /          \  write_lock()
         (CAS/add)    /            \ (CAS 0 → 0xff)
                     v              v
              0x00000200        0x000000ff
              READ LOCKED       WRITE LOCKED
              (N readers)       (exclusive)
                 |    |               |
      read_lock  |    | read_unlock   | write_lock
      (more)     |    | (last)        | (slow path)
                 |    v               v
                 |  0x00000000   0x000001ff
                 |  UNLOCKED      WRITE LOCKED
                 |                + WAITER
                 |
                 | write_lock() slow path
                 v
              0x00000300
              READERS + WAITING
                 |
                 | last read_unlock
                 v
              0x00000100
              WAITING ONLY
                 |
                 | writer CAS 0x100 → 0xff
                 v
              0x000000ff
              WRITE LOCKED
                 |
                 | write_unlock
                 | (byte store 0)
                 v
              0x00000000 or 0x00000100
              UNLOCKED      next writer waiting
```

Some transitions deserve a note:

- **`READ LOCKED` → `READERS + WAITING`**: a writer enters the slow path, takes `wait_lock`, sets the waiting bit, and waits. The reader count remains.
- **`READERS + WAITING` → `WAITING ONLY`**: the last reader decrements `cnts`. The writer's poll observes `0x100`.
- **`WRITE LOCKED + WAITER`**: a second writer has set the waiting bit while the first writer holds the lock. The second writer waits for the first to release, then for readers to drain, then claims the lock.
- **`WRITE LOCKED` → `UNLOCKED or WAITING ONLY`**: writer unlock is a byte store, so if a writer is already waiting, the waiting bit survives and the next writer can proceed. If not, the word becomes fully zero.
- **Queued readers**: a process-context reader that is waiting behind a writer is counted in `cnts` while it waits. That is why `WRITE LOCKED` can appear with a nonzero reader count in the raw word, even though the state machine above simplifies it away.

### 6.9 Walkthrough: Reader, Waiting Writer, New Reader

This is the scenario from the outline: a reader holds the lock, a writer is waiting for exclusive access, and a new reader arrives. The exact interleaving matters, so let's walk it with three CPUs.

**Initial state:** CPU 0 holds a read lock. `cnts = 0x00000200`.

```
CPU 0                    CPU 1                         CPU 2
─────                    ─────                         ─────
read_lock(&L)
  cnts = 0x200
  (inside reader CS)
                         write_lock(&L)
                           CAS 0x200 → 0xff fails
                           slow path:
                             wait_lock acquired
                             CAS 0 fails (readers)
                             cnts |= 0x100
                             cnts = 0x300
                             waits for 0x100
                                                       read_lock(&L)
                                                         add 0x200
                                                         cnts = 0x500
                                                         sees WMASK
                                                         slow path
                                                           sub 0x200
                                                           cnts = 0x300
                                                           wait_lock
                                                           (blocked behind
                                                            writer)
```

At this point the new reader is **not** inside the critical section. It is queued behind the waiting writer. The writer, in turn, is waiting for CPU 0's reader to finish. The new reader's early atomic add was undone before it queued, so it does not artificially extend the writer's wait.

**CPU 0 releases:**

```
CPU 0                    CPU 1                         CPU 2
─────                    ─────                         ─────
read_unlock(&L)
  sub 0x200
  cnts = 0x100
                         sees cnts == 0x100
                         CAS 0x100 → 0xff
                         wait_lock released
                         (inside writer CS)
                                                       acquires wait_lock
                                                         add 0x200
                                                         cnts = 0x2ff
                                                         waits for
                                                         !(cnts & 0xff)
```

Now the writer holds the lock and the queued reader is counted (`0x2ff`). The reader is waiting for the writer to release. The writer's unlock will clear only the `wlocked` byte, leaving the reader's `0x200` intact.

**Writer releases:**

```
CPU 1                    CPU 2
─────                    ─────
write_unlock(&L)
  stlrb 0 → wlocked
  cnts = 0x200
                         sees !(cnts & 0xff)
                         releases wait_lock
                         (inside reader CS)
```

The reader enters. The cycle is complete.

**What if CPU 2 were an interrupt-context reader instead?** It would take the special path, keep its `0x200`, and spin only until `!(cnts & _QW_LOCKED)`. Since the writer is waiting but not holding, it would enter immediately, ahead of the writer. That is the deliberate interrupt exception. If the writer were holding, the interrupt reader would wait for the writer to release; if the writer were interrupted on the same CPU, that would be a deadlock, which is why the writer must disable interrupts.

**What about the race where CPU 2 arrives before CPU 1 sets the waiting bit?** Then CPU 2's add might observe only reader state and succeed. CPU 1 would set the waiting bit afterward and wait for both readers. This is the bounded window described earlier: the queue is fair once contention is visible, but a fast-path reader that races ahead of the waiting-bit store can still enter. The algorithm does not use CPU IDs or a global ticket to eliminate this; it relies on the atomic word and the ordering of the operations.

---

## 7. Memory Ordering on AArch64

### 7.1 Acquire/Release Contracts

AArch64 has a **weakly ordered** memory model. Loads and stores can be observed out of program order unless explicit ordering is provided. Locks are therefore not just mutual-exclusion objects; they are memory-ordering objects. The `rwlock_t` protocol uses acquire semantics on every successful acquisition and release semantics on every unlock:

- **Reader acquisition** uses `atomic_add_return_acquire`. The acquire half ensures that loads and stores inside the read-side critical section cannot be reordered before the lock is observed.
- **Reader release** uses `atomic_sub_return_release`. The release half ensures that memory operations inside the critical section are visible before the reader count is decremented.
- **Writer acquisition** uses `atomic_try_cmpxchg_acquire` in both the fast path and the slow-path claim. The acquire half ensures the writer sees all prior reader operations once the last reader has left.
- **Writer release** uses `smp_store_release(&wlocked, 0)`, which is `STLRB` on AArch64. The release half ensures the writer's data stores are visible before the lock is marked free.

The pairing is intentionally cross-word: the writer's release store to the low byte of `cnts` is observed by a reader's acquire read-modify-write of the whole word, and a reader's release decrement is observed by a writer's acquire compare-and-swap. Because all of these operations touch the same 32-bit word, the release/acquire pairs are well defined.

```
Reader side                                  Writer side
───────────                                  ───────────
read_lock()
  atomic_add_return_acquire(0x200)
  ── acquire ──┐
               │
               ▼
        read-side CS
        data loads/stores
               │
               ▼
  atomic_sub_return_release(0x200)
  ── release ──┐
               │
               │        same 32-bit cnts word
               ├──────────────────────────────┐
               │                              │
               │        ┌─────────────────────┘
               │        ▼
               │   write_lock()
               │     atomic_try_cmpxchg_acquire(0 → 0xff)
               │     ── acquire ──┐
               │                  ▼
               │           write-side CS
               │           data loads/stores
               │                  │
               │                  ▼
               │     smp_store_release(&wlocked, 0)
               │     ── release (STLRB) ──┐
               │                          │
               └──────────────────────────┘
                     next acquisition observes the release
```

The important point is not the exact drawing but the direction of the arrows: a release makes prior stores visible before the lock word changes, and an acquire makes later loads observe everything that happened before the lock word changed. The reader and writer use different instructions, but they synchronize through the same word.

If a code path requires **sequentially consistent** (RCsc) ordering rather than the acquire/release ordering a lock provides, the kernel provides `smp_mb__after_spinlock()`. On AArch64 it expands to `smp_mb()` (`DMB ISH`) in [arch/arm64/include/asm/spinlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/spinlock.h#L12). This is primarily relevant to the scheduler and other code that depends on the stronger ordering of qspinlock acquisition; ordinary rwlock users should not need it.

### 7.2 Instructions You Will See

The exact instruction depends on whether the CPU implements **Large System Extensions (LSE)**, the ARMv8.1 atomic instruction set. Linux selects between LSE and the older load-exclusive/store-exclusive (LL/SC) sequences at runtime through alternative patching, as shown in [arch/arm64/include/asm/lse.h](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/lse.h#L17-L26):

```c
#define __lse_ll_sc_body(op, ...)                    \
({                                                   \
    alternative_has_cap_likely(ARM64_HAS_LSE_ATOMICS) ? \
        __lse_##op(__VA_ARGS__) :                    \
        __ll_sc_##op(__VA_ARGS__);                   \
})
```

The rwlock operations map roughly as follows:

| Operation | LSE path | LL/SC path |
|---|---|---|
| Reader acquire (`atomic_add_return_acquire`) | `LDADDA` | `LDAXR` / `STLXR` loop |
| Reader release (`atomic_sub_return_release`) | `LDADDAL` in the current implementation (release or stronger) | `LDXR` / `STLXR` with release store |
| Writer fast acquire (`atomic_try_cmpxchg_acquire`) | `CASA` | `LDAXR` / `STLXR` loop |
| Writer unlock (`smp_store_release`) | `STLRB` | `STLRB` |
| Waiting bit (`atomic_or`) | `STSET` (relaxed) | `LDXR` / `STXR` loop |
| Conditional wait (`atomic_cond_read_acquire`) | `LDAR` check + `SEVL`/`WFE`/`LDXR` watch loop | same |

The LSE forms are single instructions that complete in the memory subsystem without an exclusive reservation. The LL/SC forms use a load-exclusive/store-exclusive pair that must retry if another CPU writes the line between the two operations. The kernel's `<asm/atomic.h>` and `<asm/atomic_lse.h>` wrappers hide the difference; the rwlock code is written against the generic atomic API.

The `LDADDAL` detail is worth a note. The LSE implementation of `arch_atomic_sub_return_release` in [arch/arm64/include/asm/atomic_lse.h](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/atomic_lse.h#L81-L97) uses the full `al` (acquire-release) variant for the subtract, which is stronger than the release ordering strictly required. That is harmless; stronger ordering never breaks correctness, only potentially costs performance.

### 7.3 WFE and the Conditional Wait Loop

The reader and writer slow paths spin on `cnts` using `atomic_cond_read_acquire` or `atomic_cond_read_relaxed`. These are defined in [include/linux/atomic.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/atomic.h#L28-L32):

```c
#define atomic_cond_read_acquire(v, c) smp_cond_load_acquire(&(v)->counter, (c))
#define atomic_cond_read_relaxed(v, c) smp_cond_load_relaxed(&(v)->counter, (c))
```

On AArch64, `smp_cond_load_acquire` is a loop that performs an acquire load, checks the condition, and otherwise calls `__cmpwait_relaxed`. The latter is defined in [arch/arm64/include/asm/cmpxchg.h](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/cmpxchg.h#L214-L264):

```c
asm volatile(
    " sevl\n"
    " wfe\n"
    " ldxr %w[tmp], %[v]\n"
    " eor  %w[tmp], %w[tmp], %w[val]\n"
    " cbnz %w[tmp], 1f\n"
    " wfe\n"
    "1:"
    : ...
);
```

The `SEVL`/`WFE` sequence puts the CPU into a low-power wait state rather than a hot busy-spin. A store to the watched location — or another event — wakes the CPU, which then rechecks the value. This is why a writer waiting for readers does not burn a core at full speed, and why the lock word's cache line is the natural wake-up channel.

The wait loop is still a spin in the logical sense: the writer does not sleep, does not schedule, and remains in atomic context. WFE only reduces the power and instruction overhead of the wait.

### 7.4 The A-B-A Ordering Fix in the Writer Slow Path

The writer slow path uses a **relaxed** conditional read followed by an **acquire** compare-and-swap. That combination is not arbitrary. An earlier version used an acquire conditional read and a relaxed CAS, which allowed a subtle A-B-A race:

```
Writer                                  Reader
──────                                  ──────
atomic_cond_read_acquire()
  observes 0x100 (no readers)
                                        read_lock()
                                          adds 0x200
                                        read_unlock()
                                          subtracts 0x200
atomic_cmpxchg_relaxed(0x100 → 0xff)
  succeeds
  reads protected data
  ← may observe stale data, because the
    acquire happened before the reader's
    temporary visit
```

The reader acquired and released the lock between the writer's observation and its CAS. The writer's acquire was attached to the earlier read, not to the CAS that actually granted the lock. On a weakly ordered CPU, a subsequent load could be speculated before the CAS completes and observe data from before the reader's visit.

The fix, commit `84a24bf8c52e` ("locking/qrwlock: Fix ordering in queued_write_lock_slowpath()"), makes the CAS acquire and the conditional read relaxed. The CAS is the operation that actually acquires the lock, so the acquire ordering must be attached to it. The current code in [kernel/locking/qrwlock.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/qrwlock.c#L80-L86) reflects that:

```c
atomic_or(_QW_WAITING, &lock->cnts);

do {
    cnts = atomic_cond_read_relaxed(&lock->cnts, VAL == _QW_WAITING);
} while (!atomic_try_cmpxchg_acquire(&lock->cnts, &cnts, _QW_LOCKED));
```

This is a good example of why lock code is subtle: the same two operations, with the acquire moved from the read to the CAS, have different correctness properties on a weakly ordered machine.

---

## 8. Recursive Acquisition

### 8.1 Recursive Read Locks: Conditionally Safe, Not Guaranteed

It is tempting to say "read locks are recursive because readers only increment a counter." That is only half true on Linux's queued rwlock, and the missing half can deadlock.

At the level of the lock word, a second `read_lock()` by the same CPU simply adds another `0x200` and succeeds **if no writer is present or waiting**. In that narrow sense, nested read acquisition works:

```c
read_lock(&L);
/* ... */
read_lock(&L);   /* succeeds if the lock word has no writer state */
/* ... */
read_unlock(&L);
read_unlock(&L);
```

An init-time sequence that takes the same read lock twice and releases it twice demonstrates the counter arithmetic because no other thread can be using the lock yet; it does not make recursive reads safe in general.

But the queued implementation adds a fairness rule: a writer that is waiting sets `_QW_WAITING`, and a new process-context reader that sees that bit must queue behind the writer. Now consider:

```
CPU 0                                      CPU 1
─────                                      ─────
read_lock(&L);          ← holds reader
                                           write_lock(&L);
                                             takes wait_lock
                                             sets _QW_WAITING
                                             waits for readers to drain

read_lock(&L);          ← second read_lock
  adds 0x200
  sees _QW_WAITING
  slow path:
    subtracts 0x200
    waits on wait_lock
    (blocked behind the writer)

                                           writer waits for CPU 0's
                                           first reader to release

  CPU 0 cannot proceed until the second
  read_lock returns; the second read_lock
  cannot return until the writer finishes;
  the writer cannot finish until CPU 0's
  first read_lock is released.
  → self-deadlock
```

This is exactly the "non-recursive reader" case described in [Documentation/locking/lockdep-design.rst](https://github.com/torvalds/linux/blob/v7.3-rc7/Documentation/locking/lockdep-design.rst#L399-L443). A reader is non-recursive if it can be blocked by a writer **waiter**, not just a writer holder. With qrwlock, process-context `read_lock()` is non-recursive in that sense.

The verdict:

- **Uncontended nested reads work** because they are just counter increments.
- **Nested reads are not guaranteed** and can deadlock as soon as a writer is waiting.
- **Lockdep models process-context `read_lock()` as non-recursive** on queued rwlocks, so it may warn about recursion even when the current test happens to pass.
- **If you need true recursive read-side nesting, use RCU**, whose `rcu_read_lock()` is explicitly recursive, or restructure the code so the lock is acquired once at the outermost level.

There is one exception: an **interrupt-context** reader takes the special slow path that ignores a waiting writer, so lockdep treats it as recursive. That is why `read_lock_is_recursive()` returns true when `in_interrupt()`. The same applies to a process-context caller that has disabled bottom halves: `read_lock_bh()` makes `in_interrupt()` true, so it can bypass a waiting writer and is classified as recursive. This does not make arbitrary process-context recursion safe, and relying on BH-disable state to make nested reads work is obscure and fragile. Use RCU or restructure the code instead.

### 8.2 Recursive Writes and Read-to-Write Upgrade

Writers have no recursion support at all. A writer already holds the lock exclusively; a second `write_lock()` on the same lock spins waiting for the first acquisition to be released, which cannot happen because the same CPU is now spinning:

```c
write_lock(&L);
/* ... */
write_lock(&L);   /* deadlock: the lock is already held by this CPU */
```

The same applies to attempting a write while holding a read lock:

```c
read_lock(&L);
write_lock(&L);   /* deadlock: the writer waits for all readers,
                     including the reader this CPU holds */
```

And a read while holding a write lock also deadlocks, because the reader waits for the writer to release:

```c
write_lock(&L);
read_lock(&L);    /* deadlock: waits for the writer (this CPU) */
```

There is **no upgrade operation** for `rwlock_t`. The documentation is explicit: if a code path might need to write, take the write lock at the very beginning. See [Documentation/locking/spinlocks.rst](https://github.com/torvalds/linux/blob/v7.3-rc7/Documentation/locking/spinlocks.rst#L87-L89). `rw_semaphore` has `downgrade_write()`, but `rwlock_t` does not have an equivalent, and it has no upgrade at all.

`write_lock_nested()` exists, but it is **not** a recursive lock. It only tells lockdep that this acquisition belongs to a different subclass for the purpose of lock-order validation. The hardware lock is still exclusive and still non-recursive.

### 8.3 What Lockdep Does

Lockdep treats an `rwlock_t` acquisition as one of two kinds, depending on `read_lock_is_recursive()` in [kernel/locking/lockdep.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/lockdep.c#L5881-L5893):

```c
bool read_lock_is_recursive(void)
{
    return force_read_lock_recursive ||
           !IS_ENABLED(CONFIG_QUEUED_RWLOCKS) ||
           in_interrupt();
}
```

The three conditions mean:

1. **Selftests can force the recursive model** with `force_read_lock_recursive`.
2. **A non-queued rwlock implementation is treated as recursive.** On AArch64 SMP, `CONFIG_QUEUED_RWLOCKS` is enabled, so this does not apply.
3. **Any acquisition in interrupt context is treated as recursive.** This matches the special slow path in §6.4.

The classification is used by `rwlock_acquire_read()` in [include/linux/lockdep.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/lockdep.h#L520-L527):

```c
#define rwlock_acquire_read(l, s, t, i)                  \
do {                                                     \
    if (read_lock_is_recursive())                        \
        lock_acquire_shared_recursive(l, s, t, NULL, i); \
    else                                                 \
        lock_acquire_shared(l, s, t, NULL, i);           \
} while (0)
```

The practical consequences:

- A process-context nested `read_lock()` may produce a **possible recursive locking** warning, because lockdep knows a writer waiter can block it.
- An interrupt-context `read_lock()` is modeled as a recursive reader, because the interrupt slow path only waits for writer holders.
- A `read_lock()` followed by `write_lock()` on the same lock is a classic self-deadlock and is caught by the dependency graph.
- A `write_lock()` recursion is caught both by lockdep and, with `CONFIG_DEBUG_SPINLOCK`, by the owner check in `debug_write_lock_before()`:

```c
RWLOCK_BUG_ON(READ_ONCE(lock->owner) == current, lock, "recursion");
RWLOCK_BUG_ON(READ_ONCE(lock->owner_cpu) == raw_smp_processor_id(),
              lock, "cpu recursion");
```

from [kernel/locking/spinlock_debug.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/spinlock_debug.c#L184-L196). Note that read locks do **not** set `owner`, so `CONFIG_DEBUG_SPINLOCK` cannot detect a read-to-write upgrade attempt by itself. Lockdep is the tool that catches that pattern.

---

## 9. Ordering, Fairness, and Starvation

### 9.1 Is Ordering CPU-Dependent?

No. The ordering of `rwlock_t` acquisitions is not determined by CPU number, NUMA node, or any hardware priority. It is determined by the atomic operations on `cnts` and by the FIFO order of the internal `wait_lock` qspinlock. The qspinlock tail encodes a CPU identifier so that waiters can find their per-CPU MCS nodes, but that identifier is bookkeeping, not priority.

That said, the ordering is **not a strict global FIFO** either. There are two intentional exceptions and one race:

1. **Fast-path readers race the waiting-bit store.** A reader whose atomic add completes before a writer sets `_QW_WAITING` can enter even though the writer is about to queue. This window is short.
2. **Interrupt-context readers bypass the queue.** They wait only for a writer holder, not for a waiting writer, by design (§6.4).
3. **Fast-path writers can take a completely free lock** before a queued writer has set the waiting bit. Separately, the slow path's direct-acquire retry handles the case where readers have already drained while the writer was obtaining `wait_lock`.

Once a contender is actually queued on `wait_lock`, the qspinlock's FIFO order applies. There is no CPU-dependent reordering after that point. The practical statement is: **fair and writer-preferring once contention is visible, with a bounded fast-path race and a deliberate interrupt-reader exception.**

### 9.2 How `qrwlock` Enforces Fairness

The fairness mechanism is the `_QW_WAITING` bit plus the `wait_lock` queue. The sequence is:

```
Writer W1 arrives, readers present:
  acquire wait_lock
  set _QW_WAITING
  wait for cnts == 0x100

New reader R2 arrives:
  sees _QW_WAITING
  slow path
  blocks on wait_lock (behind W1)

Last reader releases:
  cnts = 0x100
  W1 CAS 0x100 → 0xff
  W1 releases wait_lock
  W1 enters critical section

R2 acquires wait_lock:
  adds 0x200
  cnts = 0x2ff
  waits for !(cnts & 0xff)

W1 releases:
  byte store 0 → wlocked
  cnts = 0x200
  R2 enters
  R2 releases wait_lock
```

**Direct answer:** once the writer is queued (`_QW_WAITING` is set), if a reader holds the lock and a new process-context reader arrives, the **writer gets the next turn**. The new reader queues behind the writer and enters after the writer releases. Only an interrupt-context reader bypasses the waiting writer.

The key is that W1 holds `wait_lock` from the moment it starts waiting until it has acquired the rwlock. New readers cannot queue ahead of it because they cannot acquire `wait_lock`. When W1 finally releases `wait_lock`, the next contender is whoever was already queued; a new reader that arrives later goes to the back.

This is why the implementation is described as fair and why it prevents writer starvation. The commit that introduced the separate waiting bit, `d13316614633` ("locking/qrwlock: Prevent slowpath writers getting held up by fastpath"), explains the original problem: a fast-path writer could jump ahead of a slow-path writer that had not yet set the waiting flag, and a steady stream of fast-path writers could starve the waiter indefinitely. Moving `_QW_WAITING` out of the writer byte and into bit 8 forced concurrent lockers into the slow path.

### 9.3 Writer Starvation

**Writer starvation** means a writer never acquires the lock because new readers keep arriving and are always allowed in. This is the classic failure mode of a **reader-preferring** rwlock:

```
Writer W waits for readers to drain.
Reader R1 arrives → allowed (readers are welcome).
Reader R2 arrives → allowed.
Reader R3 arrives → allowed.
...
W waits forever.
```

Linux's qrwlock is designed to prevent this. Once a writer sets `_QW_WAITING`, new process-context readers must queue behind it, so the reader population drains to zero and the writer eventually acquires. The kernel documentation states the implementation is fair, "thus preventing writer starvation" — see [Documentation/locking/locktypes.rst](https://github.com/torvalds/linux/blob/v7.3-rc7/Documentation/locking/locktypes.rst#L317-L324).

There are two caveats:

- **Interrupt-context readers bypass a waiting writer.** A pathological, continuous storm of hardirq or softirq readers can keep the reader count nonzero and delay the writer. This is a deliberate trade-off to avoid the interrupt deadlock described in §6.4. Real interrupt loads are bounded, but the theoretical window exists.
- **`PREEMPT_RT` changes the rules.** The RT implementation is not writer-fair and explicitly acknowledges a writer-starvation risk; see [kernel/locking/rwbase_rt.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwbase_rt.c#L28-L42). That is a different lock model and is covered in §14.

### 9.4 Reader Starvation

**Reader starvation** means a reader never gets in because writers continuously hold or queue. In qrwlock, readers are not indefinitely starved under normal operation:

- A reader that cannot take the fast path queues on `wait_lock` in FIFO order.
- A writer that holds `wait_lock` eventually acquires the rwlock after the current readers drain.
- When that writer releases `wait_lock`, the next queued contender — which may be a reader — gets its turn.
- A reader that holds `wait_lock` and is waiting for the current writer to release prevents later writers from jumping ahead, because they cannot acquire `wait_lock`.

So the failure mode is **latency**, not indefinite starvation: a reader can wait behind the current writer and every writer already queued ahead of it, and a sustained writer load can make that wait long. But each queued reader eventually reaches the front.

The comparison is therefore:

| Scenario | Naive reader-preferring rwlock | Linux qrwlock |
|---|---|---|
| Continuous readers, one writer | Writer can starve | Writer queues; new readers queue behind it; no indefinite writer starvation |
| Continuous writers, one reader | Reader usually gets in | Reader queues FIFO; may wait a long time, but is not indefinitely starved |
| Interrupt-reader storm | Writer may be delayed | Writer may be delayed; interrupt readers bypass the queue |
| `PREEMPT_RT` | Different model | Writer starvation risk is acknowledged |

If someone asks "which starvation is more likely with rwlocks?", the historically correct answer is **writer starvation**, because the naive design favors readers. On current Linux/AArch64 qrwlock, that particular failure has been designed out for process-context readers; the practical concern shifts to long reader hold times, writer queue latency, and the interrupt-reader exception.

### 9.5 The Interrupt-Reader Exception

The interrupt-reader bypass deserves its own emphasis because it is the one place where the "fair" story is intentionally incomplete.

A hardirq reader that arrives while a writer is waiting:

```
cnts = 0x100 (writer waiting only)
interrupt reader:
  add 0x200 → 0x300
  sees _QW_WAITING
  special slow path:
    condition !(VAL & _QW_LOCKED) is true
    return immediately
```

The reader enters even though the writer has been waiting. If interrupts continue to arrive and each one takes a read lock, the writer's `VAL == _QW_WAITING` condition may never be observed. This is not a bug in the queue; it is the price of avoiding a deadlock with an interrupted reader. The kernel chooses forward progress for the interrupt handler over strict writer fairness.

In a driver, this is rarely a problem because interrupt rates are bounded and read-side critical sections are tiny. In a pathological setup — for example, a level-triggered interrupt that is only quiesced by a process-context writer — it can become a real priority inversion. If a writer must make progress against a high-rate interrupt reader, consider a different design: disable the interrupt around the write, use a raw spinlock with IRQ disabling, or move the read side to a lockless/RCU scheme.

---

## 10. Interrupt and Bottom-Half Contexts

### 10.1 The Same-CPU Deadlock

The fundamental interrupt problem is the same as for spinlocks: a context that holds a lock can be interrupted by a higher-priority context that tries to acquire the same lock on the same CPU. The holder cannot run until the interrupt returns; the interrupt cannot return until it acquires the lock. Deadlock.

For `rwlock_t`, the conflict exists whenever the two contexts are not both readers:

```
CPU 0, process context                CPU 0, hardirq
──────────────────────                ──────────────
write_lock(&L);      ← wlocked=0xff
  ... critical section ...
                                      read_lock(&L);
                                        spins on wlocked
                                        (writer cannot resume)
  ← interrupted by IRQ
  → deadlock
```

The reverse also deadlocks:

```
CPU 0, process context                CPU 0, hardirq
──────────────────────                ──────────────
read_lock(&L);       ← reader count > 0
  ... critical section ...
                                      write_lock(&L);
                                        waits for readers to drain
                                        (reader cannot resume)
  ← interrupted by IRQ
  → deadlock
```

Two readers do **not** conflict, so a process-context reader interrupted by an interrupt-context reader is safe. That asymmetry is useful: if the interrupt handler only reads, a process-context reader does not need to disable interrupts on its own account. But the **writer** still does, because the interrupt reader will spin on a writer holder.

The general rule is: **if a lock can be taken in hardirq context, every process-context acquisition that conflicts with it must disable interrupts.** In practice, because writers conflict with both readers and writers, a writer in process context usually needs `write_lock_irqsave()` when any hardirq handler touches the lock. A reader in process context needs `read_lock_irqsave()` if a hardirq handler can take the **write** lock.

### 10.2 What `_irqsave` Actually Saves on AArch64

`read_lock_irqsave()` and `write_lock_irqsave()` save the current interrupt state in an `unsigned long flags` and restore it on unlock. On AArch64, the state is the **DAIF** register (Debug, SError, IRQ, FIQ) or, on systems with GIC priority masking, the **ICC_PMR_EL1** priority mask. The low-level code is in [arch/arm64/include/asm/irqflags.h](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/irqflags.h#L23-L88):

```c
static __always_inline void __daif_local_irq_disable(void)
{
    barrier();
    asm volatile("msr daifset, #3");
    barrier();
}

static __always_inline unsigned long __daif_local_save_flags(void)
{
    return read_sysreg(daif);
}

static __always_inline void __daif_local_irq_enable(void)
{
    barrier();
    asm volatile("msr daifclr, #3");
    barrier();
}
```

The `_irqsave` variant captures the register value **before** masking interrupts and restores that exact value afterward. This is why `flags` is not a boolean:

- If interrupts were enabled, `flags` records that state; unlock re-enables them.
- If interrupts were already disabled, `flags` records that state; unlock leaves them disabled.
- If the code is nested inside another `_irqsave` section, the inner unlock does not prematurely enable interrupts.

The generic wrapper uses `typecheck(unsigned long, flags)` and assigns the return value of `_raw_read_lock_irqsave` or `_raw_write_lock_irqsave`; see [include/linux/rwlock.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/rwlock.h#L74-L100).

A typical pattern:

```c
unsigned long flags;

read_lock_irqsave(&my_lock, flags);
/* read shared data */
read_unlock_irqrestore(&my_lock, flags);
```

Use the matching `_irqrestore` unlock. Do not call `read_unlock_irq()` after `read_lock_irqsave()`, because `_irq` unconditionally enables interrupts and would discard the saved state.

### 10.3 Read/Write Asymmetry

The suffix rules are the same as for spinlocks, but the read/write distinction creates a few cases worth spelling out.

**Case 1: readers in hardirq, writer in process context.**

The writer must disable interrupts:

```c
static DEFINE_RWLOCK(event_lock);

static irqreturn_t event_irq(int irq, void *dev)
{
    read_lock(&event_lock);      /* IRQs are already disabled here */
    /* read event state */
    read_unlock(&event_lock);
    return IRQ_HANDLED;
}

static void event_update(void)
{
    unsigned long flags;

    write_lock_irqsave(&event_lock, flags);
    /* update event state */
    write_unlock_irqrestore(&event_lock, flags);
}
```

The interrupt reader uses plain `read_lock()` because local interrupts are already disabled in hardirq context. If it used `read_lock_irqsave()`, that would be harmless but redundant. The writer uses `_irqsave` so the interrupt cannot fire on the same CPU while the write lock is held.

**Case 2: writer in hardirq, readers in process context.**

Now the readers must disable interrupts, because the interrupt writer will wait for them:

```c
static irqreturn_t event_irq(int irq, void *dev)
{
    write_lock(&event_lock);     /* IRQs are already disabled here */
    /* update event state */
    write_unlock(&event_lock);
    return IRQ_HANDLED;
}

static void event_read(void)
{
    unsigned long flags;

    read_lock_irqsave(&event_lock, flags);
    /* read event state */
    read_unlock_irqrestore(&event_lock, flags);
}
```

**Case 3: both readers and writers in hardirq, and process-context access.**

Every process-context acquisition should use `_irqsave`, because either a reader or a writer in the interrupt handler can conflict. The hardirq side uses plain `read_lock()` or `write_lock()`.

**Case 4: only process context.**

Plain `read_lock()` and `write_lock()` are sufficient. Do not pay for interrupt disabling when no interrupt handler touches the lock.

The read-side interrupt special path from §6.4 is what makes Case 1 work even when a writer is waiting: the interrupt reader ignores a waiting writer and only waits for a holder. That is why the interrupt handler can use plain `read_lock()` without queueing behind the process writer.

### 10.4 Bottom-Half Variants

**Bottom halves** — softirqs and tasklets — run in interrupt context but below hardirq priority. They can be deferred without masking hardware interrupts. The `_bh` variants disable local bottom-half execution while the lock is held, using `__local_bh_disable_ip` and `__local_bh_enable_ip`; see [include/linux/rwlock_api_smp.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/rwlock_api_smp.h#L188-L194) and the unlock counterparts.

The same deadlock logic applies:

- If a **softirq reader** can run while a process-context **writer** holds the lock, the writer must use `write_lock_bh()` to prevent the softirq from preempting it on the same CPU.
- If a **softirq writer** can run while a process-context **reader** holds the lock, the reader must use `read_lock_bh()`.
- If both contexts are readers, they do not conflict, and `_bh` is unnecessary for that pair.
- A bottom-half handler itself does not need `_bh` to exclude other bottom halves on the same CPU; softirq execution is already serialized on a given CPU. It may still need `_irqsave` if a hardirq handler touches the same lock.

One subtle consequence of using `in_interrupt()` rather than a literal hardirq check is that a process-context `read_lock_bh()` caller, having disabled bottom halves, also takes the interrupt-reader bypass path in §6.4. It can therefore enter ahead of a waiting writer. This is consistent with the deadlock-avoidance goal, but it is another reason not to treat the queue as strict FIFO.

The context hierarchy is:

```
Priority (high → low)              Can be preempted by
─────────────────────              ───────────────────
Hard IRQ handler                   NMI only
Softirq / tasklet                  Hard IRQ
Kernel process context             Hard IRQ, softirq (if BH enabled)
User space                         everything above
```

A softirq never preempts another softirq on the same CPU. It can run concurrently with the same softirq type on another CPU. That is why bottom-half code still needs a lock for cross-CPU protection, but not for same-CPU reentrancy.

### 10.5 Variant Selection Matrix

The following matrix assumes the lock is shared between the listed contexts. "Process" means ordinary kernel task context. "BH" means softirq or tasklet. "IRQ" means hardirq. The entries are the acquisition variants to use **from that context**.

| Shared between | From process context | From BH context | From hardirq context |
|---|---|---|---|
| Process only | `read_lock` / `write_lock` | — | — |
| Process + BH | `read_lock_bh` / `write_lock_bh` | `read_lock` / `write_lock` | — |
| Process + hardirq | `read_lock_irqsave` / `write_lock_irqsave` | — | `read_lock` / `write_lock` |
| BH + hardirq | — | `read_lock_irqsave` / `write_lock_irqsave` | `read_lock` / `write_lock` |
| BH + BH (different types) | — | `read_lock` / `write_lock` | — |
| Hardirq + hardirq (different CPUs) | — | — | `read_lock` / `write_lock` |

Read the matrix through the following decision tree:

```
Does a hardirq handler touch the lock?
├─ yes
│   ├─ process context ──→ _irqsave  (or _irq if IRQ state is known enabled)
│   ├─ BH context      ──→ _irqsave
│   └─ hardirq         ──→ plain lock
│
└─ no
    └─ Does a softirq or tasklet touch the lock?
        ├─ yes
        │   ├─ process context ──→ _bh
        │   └─ BH context      ──→ plain lock
        │
        └─ no ───────────────────→ plain lock
```

The tree is the conservative answer. Narrow it with the read/write conflict test below: if both sides are readers, no exclusion is required between them, so the suffix can often be dropped.

A simple decision procedure:

1. **Does a hardirq handler touch the lock?**
   - Yes: every process-context and BH-context acquisition that conflicts should use `_irqsave` (or `_irq` if the IRQ state is known to be enabled). The hardirq handler uses plain locks because interrupts are already disabled there.
   - No: go to step 2.
2. **Does a softirq or tasklet touch the lock?**
   - Yes: process-context acquisitions that conflict use `_bh`. The BH handler uses plain locks. If a hardirq handler also touches the lock, use `_irqsave` from BH and process context.
   - No: use plain `read_lock` / `write_lock`.

The conflict test is about **read versus write**, not just context. A process reader and a BH reader can coexist; a process reader and a BH writer cannot. The table is deliberately conservative: it assumes the lock may be used in both modes in the listed contexts. If every user in two contexts is a reader, the contexts do not conflict and plain locks are sufficient. When in doubt, the safer suffix is `_irqsave`, at the cost of interrupt latency.

### 10.6 NMI Context

NMI handlers cannot be masked. If an NMI handler takes an `rwlock_t` that might be held by the interrupted context, it will spin forever, because the interrupted context cannot run until the NMI returns. There is no `_nmi` variant that fixes this; disabling interrupts does not mask an NMI.

Avoid taking `rwlock_t` in NMI context unless you can prove the lock is never held by any context that an NMI can interrupt. In practice, lockless algorithms, per-CPU data, or carefully designed raw atomic operations are used for NMI-safe code. The `in_interrupt()` check in the reader slow path includes NMI, but that only addresses the waiting-writer deadlock; it cannot save you from a lock held by the interrupted context.

---

## 11. Writing Correct `rwlock_t` Code

### 11.1 Lock Data, Not Code

A lock should be associated with the data it protects, not with a function or a code region. Name it after the data, place it next to the data, and acquire it at every access site.

```c
/* Good: the lock and the data are one unit. */
struct sensor_state {
    rwlock_t lock;
    int temperature;
    int humidity;
    u64 updates;
};
```

```c
/* Fragile: what does my_lock protect? */
static DEFINE_RWLOCK(my_lock);

void update_something(void)
{
    write_lock(&my_lock);
    /* ... arbitrary code ... */
    write_unlock(&my_lock);
}
```

The second pattern makes it impossible for a reviewer to verify that every access to the data is guarded. It also encourages lock nesting and inconsistent ordering. The first pattern makes the invariant obvious: `sensor_state.lock` protects the fields in `sensor_state`.

### 11.2 Keep Critical Sections Short

A writer waits for all readers to drain. A reader that holds the lock for a long time increases writer latency and, because readers disable preemption, can delay the scheduler on that CPU. Keep read-side critical sections to the minimum needed to copy or validate the data, and keep write-side critical sections to the minimum needed to update it.

Do not call functions that might sleep, allocate with `GFP_KERNEL`, wait for I/O, or take a mutex while holding the lock. Do not call `printk()` in a hot path if it can be avoided; console output can be slow and may take internal locks. Copy the data out and print after unlocking. `mdelay()` is legal in atomic context, but holding an `rwlock_t` for milliseconds or seconds is still a scalability bug; use short delays only in diagnostic harnesses.

The kernel documentation's warning is worth repeating: reader-writer locks require more atomic operations than plain spinlocks. If the reader section is only a few instructions, a plain spinlock may be faster. The benefit of `rwlock_t` appears when readers are long enough and frequent enough that concurrency matters.

### 11.3 Never Sleep Under the Lock

`read_lock()` and `write_lock()` call `preempt_disable()`. Sleeping while preemption is disabled is a bug. Forbidden operations include:

- `msleep()`, `ssleep()`, `usleep_range()`
- `schedule()`, `cond_resched()`
- `wait_event()` and friends
- `mutex_lock()` and `down()` on a semaphore
- `kmalloc(GFP_KERNEL)` and other sleeping allocations
- `copy_to_user()` / `copy_from_user()` when they may fault and sleep
- blocking I/O

User copies outside the lock, with only the in-kernel buffer protected:

```c
#include <linux/fs.h>
#include <linux/minmax.h>
#include <linux/spinlock.h>
#include <linux/uaccess.h>

#define MAX_SIZE 1024

static char kernel_buffer[MAX_SIZE];
static size_t buffer_len;
static DEFINE_RWLOCK(buffer_lock);

static ssize_t demo_read(struct file *file, char __user *ubuf,
                         size_t count, loff_t *ppos)
{
    char snapshot[MAX_SIZE];
    size_t n;

    read_lock(&buffer_lock);
    n = min(count, buffer_len);
    memcpy(snapshot, kernel_buffer, n);
    read_unlock(&buffer_lock);

    if (copy_to_user(ubuf, snapshot, n))
        return -EFAULT;

    *ppos += n;
    return n;
}

static ssize_t demo_write(struct file *file, const char __user *ubuf,
                          size_t count, loff_t *ppos)
{
    char staging[MAX_SIZE];
    size_t n = min(count, sizeof(staging));

    if (copy_from_user(staging, ubuf, n))
        return -EFAULT;

    write_lock(&buffer_lock);
    memcpy(kernel_buffer, staging, n);
    buffer_len = n;
    write_unlock(&buffer_lock);

    *ppos += n;
    return n;
}
```

With `CONFIG_DEBUG_ATOMIC_SLEEP`, the kernel's `might_sleep()` checks catch many of these and produce a warning with a stack trace. Without it, the bug may manifest as a hang: the sleeping task holds the lock, and other CPUs spin waiting for a task that will not run until it is scheduled.

### 11.4 Lock Ordering and Ownership

If a code path takes multiple locks, all code paths must take them in the same global order. A cycle in the lock-order graph is a deadlock waiting for the wrong interleaving. Lockdep can detect cycles at runtime when `CONFIG_PROVE_LOCKING` is enabled.

```c
/* Consistent order: A then B. */
write_lock(&A);
write_lock(&B);
...
write_unlock(&B);
write_unlock(&A);
```

Never acquire the same `rwlock_t` recursively for writing, and do not assume that a read lock can be upgraded. If a path needs to inspect data and then conditionally modify it, take the write lock from the start, or restructure the code so the decision is made before locking.

For `rwlock_t`, the writer has owner semantics: the task that acquired the write lock should be the one that releases it. Read locks do not record an owner in the hardware word, but because preemption is disabled, the same execution context that acquired the read lock is the one that releases it. Do not hand a lock to another task or release it from a different context.

### 11.5 Lifetime and Initialization Rules

- Initialize every lock exactly once, with `DEFINE_RWLOCK` or `rwlock_init`.
- Do not `memset`, copy, or hand-initialize an `rwlock_t`.
- Do not reinitialize a held lock.
- Do not free the memory containing a lock while it is held or while a waiter is spinning on it.
- Do not let a task exit while holding a write lock.
- Do not unload a module while its kthreads or interrupt handlers can still use the lock. Stop the threads and free the IRQ first.

These rules are not stylistic. A waiter spins on the lock word; if the memory is freed, the waiter dereferences freed memory. `CONFIG_DEBUG_SPINLOCK` catches some of these cases through the magic value, but it cannot catch every lifetime bug.

---

## 12. Debugging and Observability

### 12.1 `CONFIG_DEBUG_SPINLOCK`

`CONFIG_DEBUG_SPINLOCK` adds `magic`, `owner_cpu`, and `owner` to `rwlock_t` and enables checked implementations in [kernel/locking/spinlock_debug.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/spinlock_debug.c#L145-L234). The read-side checks are limited to the magic value:

```c
void do_raw_read_lock(rwlock_t *lock)
{
    RWLOCK_BUG_ON(lock->magic != RWLOCK_MAGIC, lock, "bad magic");
    arch_read_lock(&lock->raw_lock);
}
```

The write-side checks also detect recursion:

```c
static inline void debug_write_lock_before(rwlock_t *lock)
{
    RWLOCK_BUG_ON(lock->magic != RWLOCK_MAGIC, lock, "bad magic");
    RWLOCK_BUG_ON(READ_ONCE(lock->owner) == current, lock, "recursion");
    RWLOCK_BUG_ON(READ_ONCE(lock->owner_cpu) == raw_smp_processor_id(),
                  lock, "cpu recursion");
}
```

`RWLOCK_MAGIC` is `0xdeaf1eed`. A bad magic value usually means the lock was overwritten by a buffer overrun, used after free, or never initialized. The owner checks catch a writer reacquiring a lock it already holds, including the case where the same CPU holds it in a different task context.

Read locks do not set `owner`, so a read-to-write upgrade is not caught here. Use lockdep for that.

### 12.2 Lockdep

Lockdep builds a graph of lock classes and acquisition order. It catches:

- **AB-BA deadlocks** between two or more locks.
- **Recursive writer acquisitions** and read-to-write upgrade patterns.
- **Inconsistent read/write ordering**, such as taking a write lock while holding a read lock on the same class.
- **Interrupt-context inversions**, when the IRQ state annotations are correct.

For rwlocks, the key subtlety is the `read_lock_is_recursive()` classification described in §8.3. A process-context nested read may be flagged because a writer waiter can block it; an interrupt-context read is modeled as recursive because the slow path ignores waiting writers. This is not an arbitrary distinction; it mirrors the actual implementation.

Lockdep is enabled with `CONFIG_PROVE_LOCKING` (and related options such as `CONFIG_DEBUG_LOCK_ALLOC`). In a production kernel it is often disabled for performance and memory reasons, but it should be enabled in development and in any test kernel that exercises the locking paths.

### 12.3 Sleep and Race Detectors

- **`CONFIG_DEBUG_ATOMIC_SLEEP`** instruments `might_sleep()` and catches sleeping in atomic context, including under `rwlock_t`.
- **`CONFIG_KCSAN`** (Kernel Concurrency Sanitizer) detects data races that are not protected by the kernel's locking or atomic annotations. It can help find missing read locks or writes that bypass the lock. It complements, but does not replace, lockdep.
- **`CONFIG_DEBUG_SPINLOCK`** catches magic corruption and writer recursion.
- **`CONFIG_DEBUG_LOCK_ALLOC`** enables the lockdep map in the lock.

### 12.4 Contention Tracing

The qrwlock slow paths emit `trace_contention_begin()` and `trace_contention_end()` with `LCB_F_READ` or `LCB_F_WRITE`, as seen in [kernel/locking/qrwlock.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/qrwlock.c#L38-L58). These tracepoints feed tools such as `perf lock` and can show read vs. write contention, hold times, and the call sites that generate the most waiting.

`rwlock_is_contended()` is a cheap hint that the internal wait lock is held. It is used by `rwlock_needbreak()` to decide whether a long loop should break out, drop the lock, and reschedule. It is not a precise measure of reader contention, because fast-path readers contend on `cnts` without touching `wait_lock`.

For deeper analysis, `/proc/lock_stat` (when lock statistics are enabled) and `perf lock` provide per-lock contention counts and timing. These are the right tools for deciding whether an `rwlock_t` is actually helping or just adding overhead.

---

## 13. Performance and Scalability

### 13.1 The Shared Counter Is Still a Contended Cache Line

The central performance fact about `rwlock_t` is easy to miss: **a read lock is a write**. Every reader performs an atomic read-modify-write on `cnts`. In a cache-coherent multiprocessor, that means every reader must acquire the cache line in an exclusive state, update it, and release it. Readers do not conflict logically, but they do serialize at the coherency layer for the duration of the atomic operation.

This is different from a plain read-mostly pattern where all CPUs can hold the same cache line in shared state. Here, the line ping-pongs:

```
CPU 0: RMW cnts (exclusive)
CPU 1: RMW cnts (exclusive)
CPU 2: RMW cnts (exclusive)
...
```

The cost grows with the number of CPUs and the rate of read-lock acquisition. The critical section itself can run concurrently, so the lock is still a win when the section is long enough; but the lock word is a scalability bottleneck of its own.

The internal `wait_lock` does not change this for fast-path readers. It only helps when readers or writers are actually queued. There is no per-reader MCS node in qrwlock; all readers share `cnts`.

### 13.2 NUMA

On a **NUMA** system, the cache line containing `cnts` resides on one node. A reader on a remote node must fetch the line across the interconnect, update it, and send the invalidation back. Under heavy read-lock traffic, the interconnect traffic can become the bottleneck.

The qspinlock inside `wait_lock` mitigates the **waiter** side by giving each queued CPU a local MCS node to spin on, but it does not help fast-path readers, who still hammer `cnts`. For a highly read-heavy, NUMA-sensitive workload, the alternatives are:

- **RCU** — readers do not touch a shared lock word at all; they only need a grace-period mechanism on the writer side.
- **Per-CPU data** — each CPU updates its own copy, with a global aggregation only when needed.
- **Lock sharding** — replace one global rwlock with an array of locks indexed by a hash of the object, so different objects contend on different cache lines.
- **`rw_semaphore`** — if the section can sleep, a sleeping reader does not spin on a cache line; but the atomic reader count is still shared, and the wake-up path has its own costs.

### 13.3 Writer Handoff

Writer handoff is relatively cheap in qrwlock. The waiting writer holds `wait_lock` and polls `cnts` with WFE. When the last reader decrements `cnts`, the writer's condition becomes true and it performs one acquire CAS to claim the lock. There is no broadcast to all readers and no thundering herd on the lock word.

The handoff from a writer to queued readers is also targeted: the writer's byte store clears `wlocked`, and the queued reader that holds `wait_lock` observes the change. Other readers are either already counted (if they queued) or blocked on `wait_lock` behind the queue head. The design avoids waking every reader at once.

The cost is paid by the writer holding `wait_lock` while it drains readers. During that time, other slow-path contenders wait. That is the fairness mechanism, and it is why a long reader critical section can stall the entire writer queue.

### 13.4 Alternatives

| Alternative | Strength | Weakness |
|---|---|---|
| Plain `spinlock_t` | Lowest overhead for tiny sections; simple | No reader concurrency |
| `rwlock_t` | Reader concurrency; atomic context | Extra atomics; shared counter contention; no sleep |
| `rw_semaphore` | Reader concurrency; can sleep; downgrade | Process context only; wake-up cost |
| RCU | Perfect reader scalability; recursive readers; no reader lock word | Writer-side grace period; memory reclamation complexity; not for arbitrary mutation |
| `seqlock_t` | Readers never block writers; good for small, retryable data | Readers must retry; no pointers; writer serialization |
| Per-CPU data | No cross-CPU contention | Only for partitionable state; aggregation cost |

For a read-mostly linked list, RCU is usually the right answer. For a small integer or timestamp that readers can retry, a seqlock may be better. For a data structure that must be mutated in place and read consistently in atomic context, `rwlock_t` is a reasonable fit. For a long, sleepable read section, use `rw_semaphore`.

---

## 14. `PREEMPT_RT`

On a `PREEMPT_RT` kernel, `rwlock_t` is no longer a spinning lock. The type is replaced by an rt-mutex-based implementation in [include/linux/rwlock_types.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/rwlock_types.h#L54-L64):

```
non-RT:   rwlock_t ──→ arch_rwlock_t ──→ qrwlock
                                          ├── atomic_t cnts
                                          └── arch_spinlock_t wait_lock

PREEMPT_RT: rwlock_t ──→ rwbase_rt
                          ├── atomic_t readers
                          └── rt_mutex_base rtmutex
```

The public API is source-compatible; the implementation and the context rules are not. The RT type is:

```c
context_lock_struct(rwlock) {
    struct rwbase_rt rwbase;
    atomic_t readers;
#ifdef CONFIG_DEBUG_LOCK_ALLOC
    struct lockdep_map dep_map;
#endif
};
```

The outer `readers` field is present in the type definition; the reader accounting used by the RT implementation is the `readers` inside `rwbase`. The `rwbase_rt` structure contains an `rt_mutex_base` and that reader count, as shown in [include/linux/rwbase_rt.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/rwbase_rt.h#L8-L14):

```c
#define READER_BIAS (1U << 31)
#define WRITER_BIAS (1U << 30)

struct rwbase_rt {
    atomic_t readers;
    struct rt_mutex_base rtmutex;
};
```

The API remains source-compatible, but the semantics change:

- `read_lock()` can **sleep** on the rtmutex if a writer is active. It cannot be used in hardirq or softirq context (unless the context has been converted to a sleepable thread by RT).
- `read_lock_irqsave()` and `write_lock_irqsave()` set `flags = 0` and do not actually disable interrupts; the lock itself is sleepable. Code that relies on the `_irq` variants to mask interrupts must be reworked.
- The implementation is **not writer-fair**. The RT comments in [kernel/locking/rwbase_rt.c](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwbase_rt.c#L28-L42) explicitly acknowledge a writer-starvation risk, because a blocked writer cannot grant priority to multiple readers and the rtmutex handover is one reader at a time.
- Priority inheritance works for the writer (a single rtmutex owner) but not for multiple readers. A preempted low-priority reader can continue to hold the lock and delay a high-priority writer.

The RT model is a different synchronization design, not a drop-in replacement for the spinning `rwlock_t`. Code that is correct on non-RT may need changes: it must not assume atomic context, must not rely on interrupt disabling, and must be audited for the changed fairness and priority-inheritance behavior. The kernel documentation summarizes the semantic changes in [Documentation/locking/locktypes.rst](https://github.com/torvalds/linux/blob/v7.3-rc7/Documentation/locking/locktypes.rst#L326-L339).

---

## 15. Summary: Rules of Thumb

1. **Use `rwlock_t` only for short, read-mostly, atomic-context critical sections.** If the section can sleep, use `rw_semaphore`. If readers are tiny, a plain spinlock may be faster. If the data is pointer-based and read-mostly, use RCU.

2. **Initialize with `DEFINE_RWLOCK` or `rwlock_init`.** Never `memset`, copy, or hand-initialize a lock. Keep the lock at a stable address for its lifetime.

3. **`read_lock()` is shared; `write_lock()` is exclusive.** Multiple readers may coexist. A writer excludes everyone. Never upgrade a read lock to a write lock; take the write lock from the start if a write is possible.

4. **Recursive reads are conditional.** Nested `read_lock()` works only while no writer is waiting. With qrwlock, a waiting writer turns the second read into a self-deadlock. Lockdep models process-context reads as non-recursive. Use RCU if you need guaranteed recursive read-side nesting.

5. **Never recurse on a write lock.** A second `write_lock()` on the same lock deadlocks. `CONFIG_DEBUG_SPINLOCK` catches it; lockdep catches it too.

6. **Never sleep under the lock.** No `msleep`, `schedule`, `mutex_lock`, `GFP_KERNEL` allocation, or blocking I/O. Preemption is disabled.

7. **Choose the suffix by context.** `_irqsave` when hardirq handlers share the lock; `_bh` when softirqs or tasklets share it; plain locks when only process context is involved. When in doubt, `_irqsave` is the safe choice, at the cost of interrupt latency.

8. **A hardirq reader is special.** It bypasses a waiting writer to avoid deadlocking with an interrupted reader. A writer that shares the lock with hardirq readers must disable interrupts so the reader cannot interrupt it while it holds the write lock.

9. **The lock is fair, not strictly FIFO.** Process-context readers queue behind a waiting writer; interrupt readers do not. A reader that races the waiting-bit store can enter ahead of the writer. Ordering is determined by the atomic operations and the wait queue, not by CPU number.

10. **Writer starvation is designed out on non-RT qrwlock; reader latency is not.** Readers may wait behind a long writer queue. Interrupt-reader storms can delay a writer. On `PREEMPT_RT`, the model changes and writer starvation is acknowledged.

11. **Lock data, not code.** Put the lock next to the data it protects and acquire it at every access. Keep a consistent global lock order.

12. **Use the debug tools.** `CONFIG_DEBUG_SPINLOCK`, `CONFIG_PROVE_LOCKING`, `CONFIG_DEBUG_ATOMIC_SLEEP`, KCSAN, and contention tracepoints exist to catch the mistakes that are otherwise silent hangs.

The reader-writer spinlock is a precision tool. It buys reader concurrency at the cost of extra atomic operations, a shared cache line, fairness machinery, and a set of subtle context rules. Used for the right shape of data — short, read-dominant, atomic-context critical sections — it removes unnecessary serialization without weakening correctness. Used outside that shape, it is often slower and more fragile than the plain spinlock or the sleeping rw_semaphore it replaced. The source makes the trade-offs visible: one 32-bit word for the fast path, one queued spinlock for fairness, a waiting bit to protect writers, a byte store to protect readers, and acquire/release ordering to make it all work on AArch64.

---

## 16. Important Points

A condensed revision table of the facts worth remembering; the body sections contain the full explanation.

| Area | Key point |
|---|---|
| Type | Non-RT SMP AArch64: `rwlock_t` → `arch_rwlock_t` → `struct qrwlock { atomic_t cnts; arch_spinlock_t wait_lock; }`; 8 bytes without debug options. |
| `cnts` layout | Bits 0–7 `wlocked` (`0xff` = writer holds), bit 8 `_QW_WAITING` (`0x100`), bits 9–31 reader count in `0x200` steps (about 8.3 million readers). |
| States | `0x0` unlocked, `0xff` write-locked, `0x200` one reader, `0x100` writer waiting, `0x300` reader plus waiting writer, `0x2ff` writer holder plus one queued reader. |
| `wait_lock` | Slow-path fairness queue (a qspinlock); fast-path readers and fast-path writers never touch it. |
| `wlocked` byte | Exists so writer unlock clears only the writer byte; the reader count and waiting bit survive. |
| Modes | Readers share the lock; a writer excludes all readers and all other writers. |
| Preemption | Disabled by both acquisition modes; never sleep, allocate with `GFP_KERNEL`, wait for I/O, or take a mutex. |
| Cost | Every read lock is an atomic read-modify-write on one cache line; a plain spinlock can be faster for tiny sections. |
| Upgrade | None, and no downgrade either; take the write lock from the start (`rw_semaphore` has `downgrade_write()`). |
| Alternatives | RCU for pointer traversal, `rw_semaphore` for sleepable reads, `spinlock_t` for tiny sections, `seqlock_t` for retryable data. |
| Direction | Kernel documentation discourages new rwlocks and favors removing existing ones where another primitive fits. |
| Init | `DEFINE_RWLOCK(name)` or `rwlock_init(&lock)`; never `memset`, copy, or brace-initialize; keep the address stable. |
| Variants | Match `_irqsave` with `_irqrestore` and `_bh` with `_bh`; never pair `_irqsave` with `_irq`. |
| `flags` | `_irqsave` records the exact DAIF (or `ICC_PMR_EL1`) state, so nesting and already-disabled IRQs work. |
| Trylock | Success is a real acquisition and must be unlocked; failure changes nothing, including the preemption count. |
| No `read_trylock_irqsave` | Wrap `local_irq_save()` / `local_irq_restore()` around `read_trylock()`. |
| `rwlock_is_contended` | Only reports whether `wait_lock` is held; it misses fast-path reader contention. |
| `write_lock_nested` | Lockdep subclass only; it is not recursive locking. |
| `rwlock_is_locked` | Does not exist in the non-RT API; use `lockdep_is_held()` or `lockdep_assert_held*()`. |
| Reader fast path | `atomic_add_return_acquire(0x200)`; low nine bits zero means the reader is in. |
| Reader slow path (process) | Subtract `0x200`, take `wait_lock`, re-add `0x200`, wait for `!(cnts & 0xff)`, release `wait_lock`; the reader is counted while queued (`0x2ff`). |
| Reader slow path (interrupt) | Keep `0x200`, never touch `wait_lock`, wait only for a writer holder; a waiting writer does not block it. |
| `in_interrupt()` | True in hardirq, softirq, NMI, and BH-disabled process context, so `read_lock_bh()` can take the bypass too. |
| Writer fast path | `atomic_try_cmpxchg_acquire(0 → 0xff)`; any nonzero value sends the writer to the slow path. |
| Writer slow path | Take `wait_lock`, retry `0 → 0xff`, set `0x100`, wait for `cnts == 0x100`, CAS `0x100 → 0xff`, release `wait_lock`. |
| Writer drain | Holds `wait_lock` while readers drain; that is a fairness barrier, not a data lock. |
| Reader unlock | `atomic_sub_return_release(0x200)`. |
| Writer unlock | `smp_store_release(&wlocked, 0)` (`STLRB`); a 32-bit store would erase a queued reader's count. |
| A-B-A fix | Conditional read is relaxed and the CAS is acquire (commit `84a24bf8c52e`); acquire must attach to the granting CAS. |
| Waiting bit | Separate bit, not part of the writer byte (commit `d13316614633`); prevents fast-path writers from starving a queued writer. |
| Ordering | Not CPU- or NUMA-dependent; FIFO once a contender is queued on `wait_lock`. |
| Not strict FIFO | Fast-path reader race, interrupt-reader bypass, and the free-lock fast path are intentional exceptions. |
| Waiting-bit effect | Once set, new process readers queue behind the writer, which gets the next turn. |
| Writer starvation | Designed out for process readers on non-RT qrwlock; an interrupt-reader storm can still delay a writer. |
| Reader starvation | Not indefinite (FIFO queue), but latency can be long behind a writer queue. |
| `PREEMPT_RT` | Different model: rtmutex-based, sleepable, not writer-fair, and writer starvation is acknowledged. |
| Nested reads | Safe only while no writer is waiting; otherwise the second read self-deadlocks. |
| Lockdep model | Process-context read is non-recursive; interrupt and BH-disabled reads are recursive. |
| Deadlocks | `write_lock` recursion, read→write, and write→read on the same lock all deadlock. |
| `DEBUG_SPINLOCK` | Catches writer recursion via `owner` / `owner_cpu`; it cannot catch a read→write upgrade, because reads set no owner. |
| Recursive reads | Use RCU, or restructure the code to acquire the lock once at the outermost level. |
| Same-CPU danger | Interrupt re-entry in a conflicting mode; reader + reader is the only safe pair. |
| Hardirq present | Process context uses `_irqsave` for conflicting acquisitions; the hardirq handler uses plain locks. |
| BH only | Process context uses `_bh`; the BH handler uses plain locks. |
| Asymmetry | A process reader needs `_irqsave` only if a hardirq **writer** exists; a process writer almost always needs it. |
| BH bypass | `_bh` makes `in_interrupt()` true, so the caller can bypass a waiting writer. |
| NMI | Cannot be masked; avoid `rwlock_t` in NMI context entirely. |
| Acquire/release | Acquire on every lock and release on every unlock, pairing through the same `cnts` word. |
| Instructions | `LDADDA` or `LDAXR`-`STLXR` (read lock), `CASA` (write lock), `STLRB` (write unlock). |
| Reader release | `LDADDAL` in the current LSE code; stronger than release, safe but potentially slower. |
| Slow wait | `atomic_cond_read_*` becomes a `SEVL` / `WFE` / `LDXR` loop; it idles the CPU but stays atomic and never schedules. |
| `smp_mb__after_spinlock` | `DMB ISH`; only for code needing RCsc ordering after a qspinlock, not for ordinary rwlock users. |
| Debug configs | `CONFIG_DEBUG_SPINLOCK` (magic `0xdeaf1eed`), `CONFIG_PROVE_LOCKING`, `CONFIG_DEBUG_ATOMIC_SLEEP`, KCSAN. |
| Tracing | `trace_contention_begin/end` with `LCB_F_READ` / `LCB_F_WRITE` feeds `perf lock`; `/proc/lock_stat` when enabled. |
| Scalability | Read locks serialize on the shared cache line; cost rises with CPU count, and NUMA adds interconnect traffic. |
| Mitigations | RCU, per-CPU data, lock sharding, or `rw_semaphore` when sleeping is allowed. |
| Handoff | Targets the `wait_lock` queue head, not every reader; there is no thundering herd. |

---

## 17. References

### 17.1 Core Type Definitions and API

- [`rwlock_t` definition and initializers](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/rwlock_types.h#L25-L52)
- [`rwlock_t` API macros and `_irqsave` wrappers](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/rwlock.h#L17-L132)
- [`read_lock` / `write_lock` call chains](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/rwlock_api_smp.h#L159-L231)
- [AArch64 `arch_rwlock_t` selection](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/spinlock_types.h#L12-L13)
- [AArch64 queued rwlock Kconfig selection](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/Kconfig#L69-L70)
- [`CONFIG_QUEUED_RWLOCKS` definition](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/Kconfig.locks#L269-L274)

### 17.2 Queued Read-Write Lock Implementation

- [`struct qrwlock` layout](https://github.com/torvalds/linux/blob/v7.3-rc7/include/asm-generic/qrwlock_types.h#L13-L32)
- [Lock word constants and fast paths](https://github.com/torvalds/linux/blob/v7.3-rc7/include/asm-generic/qrwlock.h#L24-L133)
- [Reader and writer slow paths](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/qrwlock.c#L21-L91)
- [Writer unlock byte store](https://github.com/torvalds/linux/blob/v7.3-rc7/include/asm-generic/qrwlock.h#L116-L123)
- [A-B-A ordering fix commit](https://github.com/torvalds/linux/commit/84a24bf8c52e66b7ac89ada5e3cfbe72d65c1896)
- [Fairness fix commit](https://github.com/torvalds/linux/commit/d133166146333e1f13fc81c0e6c43c8d99290a8a)

### 17.3 AArch64 Memory Ordering and Atomics

- [AArch64 `smp_store_release` / `smp_load_acquire`](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/barrier.h#L130-L194)
- [AArch64 conditional load / WFE loop](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/barrier.h#L196-L220)
- [AArch64 `__cmpwait` implementation](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/cmpxchg.h#L214-L264)
- [LSE atomic implementations](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/atomic_lse.h#L36-L97)
- [LL/SC atomic implementations](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/atomic_ll_sc.h#L42-L82)
- [Runtime LSE/LL-SC selection](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/lse.h#L17-L26)
- [AArch64 IRQ flag save/restore](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/irqflags.h#L23-L88)
- [`smp_mb__after_spinlock` on AArch64](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/spinlock.h#L12)

### 17.4 Lockdep and Debugging

- [`read_lock_is_recursive()`](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/lockdep.c#L5881-L5893)
- [Lockdep read/shared acquisition classification](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/lockdep.h#L520-L527)
- [Lockdep recursive-reader design](https://github.com/torvalds/linux/blob/v7.3-rc7/Documentation/locking/lockdep-design.rst#L399-L443)
- [`rwlock_t` debug checks](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/spinlock_debug.c#L145-L234)
- [`rwlock_needbreak()`](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/spinlock.h#L500-L514)

### 17.5 Kernel Documentation and Real-World Usage

- [Reader-writer spinlock documentation](https://github.com/torvalds/linux/blob/v7.3-rc7/Documentation/locking/spinlocks.rst#L52-L93)
- [Lock type semantics, fairness, and PREEMPT_RT](https://github.com/torvalds/linux/blob/v7.3-rc7/Documentation/locking/locktypes.rst#L317-L339)
- [`tasklist_lock` as a cache-line-aligned rwlock](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/fork.c#L159)
- [`write_lock_irq(&tasklist_lock)` in fork](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/fork.c#L2459-L2562)
- [`read_lock(&tasklist_lock)` in process-tree walk](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/fork.c#L3082-L3106)
- [PREEMPT_RT rwbase implementation notes](https://github.com/torvalds/linux/blob/v7.3-rc7/kernel/locking/rwbase_rt.c#L28-L42)

---

*This document describes `rwlock_t` as implemented in Linux v7.3-rc7 on AArch64, in a non-`PREEMPT_RT` SMP configuration. Source line numbers refer to that tag; kernel code evolves, so verify against the tree you are building when using this as a reference.*
