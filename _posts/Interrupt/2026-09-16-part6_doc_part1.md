---
title: Interrupt Handling in the Linux Kernel — Part 6a
published: true
categories: [Interrupt]
tags: [workqueue,interrupt]
---
# Interrupt Handling in the Linux Kernel — Part 6a: Workqueues — Architecture, Data Structures, and Core API

> **Part 4** covers top halves, bottom halves, softirqs, ksoftirqd, `local_bh_disable`/`local_bh_enable`, and spinlock variants in interrupt context: `part3_doc_part4.md`
>
> **Part 5** covers tasklets in depth — `tasklet_struct`, scheduling, serialization, HI_SOFTIRQ vs TASKLET_SOFTIRQ, enable/disable, and deprecation: `part5_doc.md`
>
> **Part 6b** covers delayed work, RCU work, custom workqueues, flags, concurrency control, and advanced patterns: `part6_doc_part2.md`

Softirqs and tasklets give the kernel a way to defer work from a hardirq handler into a non-sleeping, softirq-context bottom half — but they cannot sleep. A network driver that needs to allocate memory with `GFP_KERNEL`, a USB driver that needs to call `usb_submit_urb()` with blocking, a filesystem driver that needs to take a mutex — none of these can use a softirq or a tasklet. **Workqueues** solve this fundamental limitation. A workqueue executes deferred **work items** in **process context** via dedicated kernel threads called **kworker** threads. Because work handlers run in process context, they can sleep, take mutexes, perform blocking I/O, and call any function that would be illegal in softirq context. The modern workqueue subsystem — called **Concurrency Managed Workqueues (cmwq)** — replaces the original per-workqueue-thread model with a shared pool of kernel threads, managed by the kernel's own concurrency logic. This document covers the architecture, data structures, core APIs, queueing internals, execution flow, and work lifecycle management of the workqueue subsystem, with source references from the [v7.2-rc5](https://github.com/torvalds/linux/blob/v7.2-rc5/) kernel.

---

## Table of Contents

1. [Why Workqueues Exist: The Problem Softirqs and Tasklets Cannot Solve](#why-workqueues-exist-the-problem-softirqs-and-tasklets-cannot-solve)
2. [Process Context vs Interrupt Context](#process-context-vs-interrupt-context)
3. [The Workqueue Architecture: Work Items, Workqueues, Worker Pools, and Workers](#the-workqueue-architecture-work-items-workqueues-worker-pools-and-workers)
4. [The work_struct Structure](#the-work_struct-structure)
5. [The data Field: Encoding Pending State, Pool ID, and PWQ Pointer](#the-data-field-encoding-pending-state-pool-id-and-pwq-pointer)
6. [Initializing Work Items: Static and Dynamic](#initializing-work-items-static-and-dynamic)
7. [The workqueue_struct Structure](#the-workqueue_struct-structure)
8. [The worker_pool Structure](#the-worker_pool-structure)
9. [The pool_workqueue (pwq) Structure: The Bridge Between Workqueue and Pool](#the-pool_workqueue-pwq-structure-the-bridge-between-workqueue-and-pool)
10. [The worker Structure](#the-worker-structure)
11. [Unbound Workqueues and Why Worker Pools Are Required](#unbound-workqueues-and-why-worker-pools-are-required)
12. [Creating a Worker: create_worker()](#creating-a-worker-create_worker)
13. [kworker Thread Naming: CPU-Bound vs CPU-Unbound](#kworker-thread-naming-cpu-bound-vs-cpu-unbound)
14. [System Workqueues: The Built-In Workqueues](#system-workqueues-the-built-in-workqueues)
15. [Queueing Work: queue_work() and queue_work_on()](#queueing-work-queue_work-and-queue_work_on)
16. [The Internal Queueing Path: __queue_work()](#the-internal-queueing-path-__queue_work)
17. [How the Target Worker Pool Is Determined](#how-the-target-worker-pool-is-determined)
18. [How Priority Is Determined: Normal vs High Priority Worker Pool](#how-priority-is-determined-normal-vs-high-priority-worker-pool)
19. [What Happens If You Queue the Same Work Twice?](#what-happens-if-you-queue-the-same-work-twice)
20. [What Happens When You Create Work vs When You Queue Work](#what-happens-when-you-create-work-vs-when-you-queue-work)
21. [insert_work(): Linking the Work Item to the Pool](#insert_work-linking-the-work-item-to-the-pool)
22. [schedule_work() and schedule_work_on()](#schedule_work-and-schedule_work_on)
23. [How to Pass Private Data to a Work Function](#how-to-pass-private-data-to-a-work-function)
24. [container_of in the Linux Kernel](#container_of-in-the-linux-kernel)
25. [The Worker Thread Function: worker_thread()](#the-worker-thread-function-worker_thread)
26. [Processing a Single Work Item: process_one_work()](#processing-a-single-work-item-process_one_work)
27. [Execution Context: Process Context, Not Interrupt Context](#execution-context-process-context-not-interrupt-context)
28. [The Value of current for a Worker Thread](#the-value-of-current-for-a-worker-thread)
29. [A Simple Example Using the System Workqueue](#a-simple-example-using-the-system-workqueue)
30. [Enabling and Disabling Work Items](#enabling-and-disabling-work-items)
31. [cancel_work_sync(): Cancel and Wait](#cancel_work_sync-cancel-and-wait)
32. [flush_work(): Wait for Completion](#flush_work-wait-for-completion)
33. [Complete Work Item Lifecycle](#complete-work-item-lifecycle)
34. [End-to-End Under the Hood: From INIT_WORK to Handler Execution](#end-to-end-under-the-hood-from-init_work-to-handler-execution)

→ Continued in **Part 6b** (`part6_doc_part2.md`): Delayed work, RCU work, custom workqueue creation, workqueue flags, concurrency control, and advanced patterns.

---

## Why Workqueues Exist: The Problem Softirqs and Tasklets Cannot Solve

### The Fundamental Constraint: Softirq Context Cannot Sleep

Softirqs and tasklets run in **softirq context** — they execute with `preempt_count` having `SOFTIRQ_OFFSET` set, hardware interrupts enabled, but with a critical constraint: **they cannot sleep**. This is not a convention — it is a hard architectural constraint enforced by the kernel at multiple levels.

**Why sleeping in softirq context is structurally impossible:**

When `handle_softirqs()` runs on the return path from a hardware interrupt, it borrows the interrupted task's kernel stack and `current` pointer. The interrupted task might be in any state — it might be holding spinlocks, it might be in the middle of a critical section, it might be a user process executing a system call. If the softirq handler calls `schedule()`, the scheduler would context-switch away from the interrupted task using a stack frame that belongs to the softirq path, leaving the interrupted task in a corrupted state — its stack contains softirq frames that are no longer valid, and any locks it held are now abandoned.

Even when softirqs run via `ksoftirqd` (which has its own stack), `preempt_count` still has `SOFTIRQ_OFFSET` set. The scheduler explicitly checks this.

**What happens if you try to sleep in softirq context:**

The kernel enforces the no-sleep rule through two complementary mechanisms:

**Mechanism 1: `might_sleep()` / `__might_resched()` — compile-time annotations.** Functions that may sleep (like `mutex_lock()`, `kmalloc(GFP_KERNEL)`, `wait_for_completion()`) call `might_sleep()` at their entry point. At [kernel/sched/core.c, lines 9151–9199](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/sched/core.c#L9151-L9199), `__might_resched()` checks `preempt_count()`:

```c
void __might_resched(const char *file, int line, unsigned int offsets)
{
    if ((resched_offsets_ok(offsets) && !irqs_disabled() &&
         !is_idle_task(current) && !current->non_block_count) ||
        system_state == SYSTEM_BOOTING || system_state > SYSTEM_RUNNING ||
        oops_in_progress)
        return;

    pr_err("BUG: sleeping function called from invalid context at %s:%d\n",
           file, line);
    pr_err("in_atomic(): %d, irqs_disabled(): %d, non_block: %d, pid: %d, name: %s\n",
           in_atomic(), irqs_disabled(), current->non_block_count,
           current->pid, current->comm);
    pr_err("preempt_count: %x, expected: %x\n", preempt_count(),
           offsets & MIGHT_RESCHED_PREEMPT_MASK);
    dump_stack();
}
```

When called from softirq context, `preempt_count()` includes `SOFTIRQ_OFFSET`, so `resched_offsets_ok()` returns false (the nested count doesn't match the expected zero), triggering the BUG message. This fires at the *attempt* to sleep, before any actual damage.

**Mechanism 2: `schedule_debug()` / `__schedule_bug()` — runtime enforcement.** If a softirq handler somehow reaches `schedule()` despite the `might_sleep()` check (e.g., through a code path that lacks the annotation), the scheduler itself catches it. At [kernel/sched/core.c, lines 6089–6091](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/sched/core.c#L6089-L6091):

```c
if (unlikely(in_atomic_preempt_off())) {
    __schedule_bug(prev);
    preempt_count_set(PREEMPT_DISABLED);
}
```

`__schedule_bug()` at [kernel/sched/core.c, lines 6042–6065](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/sched/core.c#L6042-L6065) prints:

```
BUG: scheduling while atomic: <process>/<pid>/0x<preempt_count>
```

This is the last line of defense — the scheduler detects that `preempt_count` is non-zero and refuses to switch context. With `CONFIG_PANIC_ON_WARN`, this crashes the kernel.

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  What Happens If You Try to Sleep in Softirq Context                            │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  Softirq handler calls mutex_lock()                                             │
 │    │                                                                            │
 │    └── mutex_lock() calls might_sleep()                                         │
 │          │                                                                      │
 │          └── __might_resched() checks preempt_count()                           │
 │                │                                                                │
 │                preempt_count has SOFTIRQ_OFFSET set                             │
 │                resched_offsets_ok() returns false                               │
 │                │                                                                │
 │                ▼                                                                │
 │    "BUG: sleeping function called from invalid context"                         │
 │    dump_stack() → full backtrace showing the offending call chain               │
 │                                                                                 │
 │  If CONFIG_DEBUG_ATOMIC_SLEEP is not set and the mutex is uncontended:          │
 │    mutex_lock() may succeed without actually sleeping                           │
 │    (the fast path uses atomic cmpxchg, no schedule() call)                      │
 │    BUT: this is a latent bug — the next time the mutex IS contended,            │
 │    schedule() is called, and __schedule_bug() fires:                            │
 │                                                                                 │
 │    "BUG: scheduling while atomic: <process>/<pid>/0x<preempt_count>"            │
 │    → kernel stack dump, potential panic                                         │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

### What Specifically Cannot Be Done in Softirq Context

The no-sleep constraint cascades through the entire kernel API surface. Any function that internally calls `schedule()` — directly or transitively — is off-limits:

```
 ┌────────────────────────────────┬────────────────────────────────────────────────┐
 │  Operation                     │  Why It Cannot Be Done in Softirq Context      │
 ├────────────────────────────────┼────────────────────────────────────────────────┤
 │  mutex_lock()                  │  Calls might_sleep(). If mutex is contended,   │
 │                                │  calls schedule() to wait for the owner.       │
 │                                │  mutex.c line 316: might_sleep()               │
 ├────────────────────────────────┼────────────────────────────────────────────────┤
 │  kmalloc(GFP_KERNEL)           │  GFP_KERNEL includes __GFP_DIRECT_RECLAIM.     │
 │                                │  When memory is low, the allocator enters      │
 │                                │  direct reclaim — shrinks caches, writes back  │
 │                                │  dirty pages, which requires sleeping.         │
 │                                │  Must use GFP_ATOMIC (no direct reclaim).      │
 ├────────────────────────────────┼────────────────────────────────────────────────┤
 │  copy_from_user() /            │  May trigger a page fault. If the page is      │
 │  copy_to_user()                │  not resident, the fault handler calls         │
 │                                │  schedule() to wait for I/O.                   │
 ├────────────────────────────────┼────────────────────────────────────────────────┤
 │  msleep() / ssleep()           │  Directly calls schedule_timeout().            │
 ├────────────────────────────────┼────────────────────────────────────────────────┤
 │  wait_for_completion()         │  Calls schedule() in a loop until the          │
 │                                │  completion is signaled.                       │
 ├────────────────────────────────┼────────────────────────────────────────────────┤
 │  usb_control_msg()             │  Submits a URB and sleeps until the USB host   │
 │                                │  controller completes the transfer.            │
 ├────────────────────────────────┼────────────────────────────────────────────────┤
 │  vfs_read() / vfs_write()      │  File I/O may require disk access, which       │
 │                                │  involves sleeping for DMA completion.         │
 ├────────────────────────────────┼────────────────────────────────────────────────┤
 │  request_firmware()            │  Waits for userspace to provide a firmware     │
 │                                │  blob — may sleep for seconds or longer.       │
 └────────────────────────────────┴────────────────────────────────────────────────┘
```

The constraint is transitive: if function A calls function B, and B calls `schedule()`, then A cannot be called from softirq context. This makes the no-sleep rule pervasive — a large fraction of the kernel's API is off-limits.

### The GFP_KERNEL vs GFP_ATOMIC Distinction

The memory allocation constraint deserves special attention because it directly affects reliability. At [include/linux/gfp_types.h, lines 376–377](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/gfp_types.h#L376-L377):

```c
#define GFP_ATOMIC  (__GFP_HIGH|__GFP_KSWAPD_RECLAIM)
#define GFP_KERNEL  (__GFP_RECLAIM | __GFP_IO | __GFP_FS)
```

`GFP_KERNEL` includes `__GFP_DIRECT_RECLAIM` (inside `__GFP_RECLAIM`), which allows the allocator to enter direct reclaim — synchronously shrinking caches, writing dirty pages, and compacting memory. This is the allocator's most powerful mode and has the highest success rate, but it sleeps.

`GFP_ATOMIC` omits `__GFP_DIRECT_RECLAIM`. The allocator can only use free pages from the per-CPU page lists and the buddy allocator's free lists. If free memory is exhausted, `__GFP_HIGH` allows dipping into emergency reserves, but the allocation can still fail. In softirq context, `GFP_ATOMIC` is the only safe option — and it means **every allocation can fail**, and the softirq handler must handle that failure gracefully.

Workqueue handlers use `GFP_KERNEL`, so allocations virtually never fail under normal conditions. This dramatically simplifies driver code.

### Real-World Examples: Why Drivers Need Workqueues

The workqueue API is the most heavily used deferred-execution mechanism in the kernel. In the v7.2-rc5 source tree, the `drivers/` directory alone contains over **2,000 `INIT_WORK` calls**, **1,400+ `schedule_work` calls**, and **1,800+ `queue_work` calls**. Nearly every major subsystem depends on workqueues.

**Example: USB hub event handling.** The USB hub driver at [drivers/usb/core/hub.c, line 5874](https://github.com/torvalds/linux/blob/v7.2-rc5/drivers/usb/core/hub.c#L5874) uses a work item to handle hub events:

```c
static void hub_event(struct work_struct *work)
{
    struct usb_hub *hub = container_of(work, struct usb_hub, events);
    /* ... */
    usb_lock_device(hdev);        /* takes a mutex — sleeps if contended */
    /* ... */
    msleep(hub_power_on_good_delay(hub));  /* sleeps for milliseconds */
    mutex_lock(&hub->status_mutex);        /* another mutex */
    /* ... */
}
```

This handler **must** sleep — it takes mutexes, calls `msleep()`, performs USB control transfers that block until the host controller completes them. It could never run as a softirq or tasklet.

**Example: Block layer I/O completion.** When a disk I/O operation completes, the block layer often needs to do post-processing that involves memory allocation with `GFP_KERNEL`, filesystem callbacks, or waking userspace processes waiting on I/O — all operations that may sleep.

**Example: Network device link state changes.** When a network link goes up or down, the driver needs to reconfigure hardware, potentially load firmware (`request_firmware()`), update routing tables (which requires mutex-protected data structures), and notify userspace — tasks that span multiple sleeping operations.

### Why Threaded IRQs Are Not Enough

Threaded IRQs (`request_threaded_irq()`) provide process context for interrupt handling, but they have fundamental limitations:

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  Threaded IRQ Limitations vs Workqueue Capabilities                             │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  THREADED IRQs:                                                                 │
 │  ● Tied to a specific IRQ line — one handler per IRQ                            │
 │  ● Cannot be queued from arbitrary contexts (timer callbacks, other             │
 │    work handlers, tasklets, kernel threads)                                     │
 │  ● Cannot be deferred with a timer delay                                        │
 │  ● Cannot have multiple independent work items on the same "channel"            │
 │  ● Cannot be shared across modules or subsystems                                │
 │  ● Thread is created at request_irq() time and persists for the IRQ's           │
 │    lifetime — one thread per IRQ, cannot be pooled                              │
 │                                                                                 │
 │  WORKQUEUES:                                                                    │
 │  ● Not tied to any IRQ — can be queued from anywhere                            │
 │  ● Can be queued from hardirq, softirq, timer, process context                  │
 │  ● Built-in delayed execution (delayed_work + timer)                            │
 │  ● Multiple work items can share a single workqueue                             │
 │  ● Shared worker pools — no per-workqueue thread explosion                      │
 │  ● Concurrency management — automatic thread scaling                            │
 │  ● Can be canceled, flushed, disabled, re-queued                                │
 │                                                                                 │
 │  USE THREADED IRQ WHEN:                                                         │
 │  ● Your bottom half is directly tied to a specific hardware interrupt           │
 │  ● You need the kernel's IRQ framework (masking, affinity, /proc/interrupts)    │
 │                                                                                 │
 │  USE WORKQUEUE WHEN:                                                            │
 │  ● Work is not tied to a specific IRQ                                           │
 │  ● Work can be queued from multiple contexts                                    │
 │  ● You need delayed execution, cancellation, or flushing                        │
 │  ● You need multiple independent deferred tasks                                 │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

### The Old Workqueue Model and Why cmwq Replaced It

The modern workqueue subsystem — **Concurrency Managed Workqueues (cmwq)** — was introduced in Linux 2.6.36 (2010) by Tejun Heo to replace the original workqueue implementation. Understanding what was wrong with the old model explains why the current architecture looks the way it does.

**The old model:** Each `create_workqueue()` call created a dedicated kernel thread per CPU for multi-threaded workqueues (MT wq), or a single system-wide thread for single-threaded workqueues (ST wq). The workqueue owned its threads exclusively.

**The problem: thread explosion.** As the kernel grew more workqueue users over the years (networking, block layer, USB, filesystems, power management, device-mapper, crypto, etc.), the number of kernel threads exploded. A multi-threaded workqueue on a 64-core system created 64 threads. With dozens of workqueues, the system could saturate the default 32,768 PID space just during boot — before any userspace process even started.

**The second problem: concurrency starvation.** Despite the thread explosion, the old model provided *poor* concurrency. An MT workqueue had exactly one thread per CPU. If that thread's work item slept (e.g., waiting for I/O), no other work item from the same workqueue could run on that CPU until it woke up — even if there were dozens of pending work items. This led to deadlocks when work items depended on each other.

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  Old Workqueue Model vs cmwq                                                    │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  OLD MODEL (pre-2.6.36):                                                        │
 │  ───────────────────────                                                        │
 │                                                                                 │
 │    create_workqueue("foo")  →  1 kthread/CPU  →  64 threads on 64-core          │
 │    create_workqueue("bar")  →  1 kthread/CPU  →  64 threads                     │
 │    create_workqueue("baz")  →  1 kthread/CPU  →  64 threads                     │
 │    ...                                                                          │
 │    Total: N workqueues × M CPUs = N×M threads                                   │
 │                                                                                 │
 │    Problem: 50 workqueues × 64 CPUs = 3,200 kernel threads                      │
 │    Most are idle most of the time — massive waste                               │
 │                                                                                 │
 │    Per-workqueue thread sleeps → ALL work items on that CPU stall               │
 │    No cross-workqueue thread sharing                                            │
 │                                                                                 │
 │  cmwq (2.6.36+):                                                                │
 │  ───────────────                                                                │
 │                                                                                 │
 │    alloc_workqueue("foo")  ─┐                                                   │
 │    alloc_workqueue("bar")  ─┤→ shared per-CPU worker pools (2 per CPU)          │
 │    alloc_workqueue("baz")  ─┘  + dynamic unbound pools as needed                │
 │                                                                                 │
 │    Total: 2 pools/CPU + unbound pools = ~2×M + small number                     │
 │    Workers created on demand, reaped after 5 min idle                           │
 │                                                                                 │
 │    Worker sleeps → pool automatically wakes another worker                      │
 │    Concurrency managed by tracking nr_running per pool                          │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

The cmwq design achieves three goals simultaneously: fewer threads (shared pools instead of per-workqueue threads), better concurrency (automatic worker creation when existing workers sleep), and simpler API (drivers don't manage thread lifecycle).

### BH Workqueues: Bridging the Gap

Linux 6.9+ introduced **BH workqueues** (`WQ_BH` flag) as a modern replacement for tasklets. A BH workqueue executes work items in **softirq context** (not process context), using the workqueue API but without the ability to sleep. This provides the familiar workqueue API (`INIT_WORK`, `queue_work`, `cancel_work_sync`) for code that needs softirq-level latency without needing to sleep.

The system BH workqueue `system_bh_wq` is created during early boot alongside the regular system workqueues. This is the recommended replacement path for code migrating away from deprecated tasklets.

### The Complete Deferred-Execution Landscape

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │                 DEFERRED EXECUTION IN THE LINUX KERNEL                          │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  MECHANISM         CONTEXT        CAN SLEEP?   STATUS          USE CASE         │
 │  ─────────         ───────        ──────────   ──────          ────────         │
 │                                                                                 │
 │  Softirq           Softirq        NO           Active          Core kernel:     │
 │                    (SOFTIRQ_OFFSET)            (10 static)     networking,      │
 │                                                                 block, timers,  │
 │                                                                 RCU             │
 │                                                                                 │
 │  Tasklet           Softirq        NO           DEPRECATED      Legacy driver    │
 │                    (SOFTIRQ_OFFSET)            → use BH wq     bottom halves    │
 │                                                 or threaded IRQ                 │
 │                                                                                 │
 │  BH Workqueue      Softirq        NO           Active          Modern tasklet   │
 │  (WQ_BH)           (SOFTIRQ_OFFSET)            (since 6.9)    replacement,      │
 │                                                                 workqueue API   │
 │                                                                                 │
 │  Threaded IRQ      Process         YES          Active          IRQ-specific    │
 │                    (preempt_count=0)                            bottom halves   │
 │                                                                                 │
 │  Workqueue         Process         YES          Active          General-purpose │
 │                    (preempt_count=0)            (RECOMMENDED)   deferred work,  │
 │                                                                 driver I/O,     │
 │                                                                 2000+ users     │
 │                                                                 in drivers/     │
 │                                                                                 │
 │  ◄── Lower latency                           Higher latency ──►                 │
 │  ◄── More restrictions                       Fewer restrictions ──►             │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

---

## Process Context vs Interrupt Context

To understand why workqueues matter, recall the execution context hierarchy:

```
 Hardirq Context (preempt_count has HARDIRQ_OFFSET set)
   │  ● Cannot sleep, cannot take mutexes
   │  ● Interrupts may be disabled on local CPU
   │  ● current points to the interrupted task (borrowed)
   │
   │  CAN preempt ───────────────────────────────────────┐
   ▼                                                      │
 Softirq Context (preempt_count has SOFTIRQ_OFFSET set)  │
   │  ● Cannot sleep, cannot take mutexes                 │
   │  ● Hardware interrupts ENABLED                       │
   │  ● Tasklets and softirqs run here                    │
   │                                                      │
   │  CAN preempt ───────────────────────────────────────┘
   ▼
 Process Context (preempt_count = 0, can sleep)
   ● CAN sleep, take mutexes, do blocking I/O
   ● Has a proper task_struct with its own kernel stack
   ● Workqueue work handlers run HERE
   ● Threaded IRQ handlers run HERE
   ● Regular kernel threads run HERE
```

Workqueue work handlers run in **process context** — they are executed by **kworker** kernel threads that have their own `task_struct`, their own kernel stack, and are fully schedulable by the kernel's scheduler. This is what makes sleeping legal.

---

## The Workqueue Architecture: Work Items, Workqueues, Worker Pools, and Workers

The modern workqueue subsystem (**cmwq** — Concurrency Managed Workqueues) has four key abstractions. Understanding their relationships is critical.

```
┌───────────────────────────────────────────────────────────────────────────────────┐
│                     WORKQUEUE ARCHITECTURE (cmwq) w/ EXAMPLES                     │
├───────────────────────────────────────────────────────────────────────────────────┤
│                                                                                   │
│ [1] WORK ITEM (struct work_struct) & DELAYED WORK (struct delayed_work)           │
│ ───────────────────────────────────────────────────────────────────────           │
│ Defines the job.                                                                  │
│ Concrete Example: DECLARE_WORK(my_work, my_rx_handler);                           │
│ Real-World: Network packet processing (net/core/dev.c), Ext4 inode eviction,      │
│ thermal sensor polling (delayed work).                                            │
│                                                                                   │
│ [2] WORKQUEUE (struct workqueue_struct)                                           │
│ ───────────────────────────────────────                                           │
│ The frontend API.                                                                 │
│ Shared System WQs: system_wq, system_highpri_wq, system_unbound_wq                │
│ Custom WQ Example: alloc_workqueue("ext4-rsv-conv", WQ_MEM_RECLAIM, 0);           │
│                                                                                   │
│ [3] POOL WORKQUEUE (struct pool_workqueue / pwq)                                  │
│ ──────────────────────────────────────────────────────                            │
│ The multiplexer. Links the specific WQ to the specific CPU/Node pool.             │
│ Example: Links the "ext4-rsv-conv" WQ to the worker_pool handling CPU 0.          │
│                                                                                   │
│ [4] WORKER POOL (struct worker_pool)                                              │
│ ────────────────────────────────────                                              │
│ The backend thread manager.                                                       │
│ Example: Pool #0 (Normal priority, CPU 0), Pool #1 (High-pri, CPU 0),             │
│ Pool #4 (Unbound, NUMA node 1).                                                   │
│                                                                                   │
│ [5] WORKER (struct worker / kworker thread)                                       │
│ ───────────────────────────────────────────                                       │
│ The execution thread visible in 'ps' or 'top'.                                    │
│ Naming Examples:                                                                  │
│  [kworker/0:1-events] -> CPU 0, Thread 1, bound to 'events' (system_wq)           │
│  [kworker/u4:2-ext4]  -> Unbound ('u'), Pool 4, Thread 2, handling 'ext4'         │
│                                                                                   │
│                                                                                   │
│ RELATIONSHIPS & DATA FLOW:                                                        │
│                                                                                   │
│   Kernel Subsystem / Driver (e.g., Network driver receiving a frame)              │
│      │                                                                            │
│      │ queue_work(system_wq, &my_work);                                           │
│      ▼                                                                            │
│   workqueue_struct ──── Attributes: (WQ_UNBOUND, WQ_MEM_RECLAIM)                  │
│   (system_wq)           │                                                         │
│      │                  └─────────── (If WQ_MEM_RECLAIM) ──► rescuer_thread       │
│      │                                                       [kworker/R-ext4]     │
│      │ routes to local execution context                                          │
│      ▼                                                                            │
│   pool_workqueue (pwq) ─── Intermediary for (system_wq + CPU 0 Pool)              │
│      │                                                                            │
│      │ flushes item onto the backend pool's shared list                           │
│      ▼                                                                            │
│   worker_pool ──────────── e.g., Pool #0 (Bound to CPU 0, Normal Priority)        │
│      │                     Limits concurrency (e.g., max_active = 256)            │
│      │                                                                            │
│      │ wakes up an idle worker thread, or creates a new one                       │
│      ▼                                                                            │
│   worker (kworker) ─────── e.g., Thread [kworker/0:1-events] awakens              │
│                            Calls my_rx_handler(&my_work)                          │
│                                                                                   │
└───────────────────────────────────────────────────────────────────────────────────┘
```

```
┌─────────────────────────────────────────────────────────────────────────────────────────────────┐
│  How Work Items, Workqueues, Worker Pools, and Workers Relate (Concrete Example)                │
├─────────────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                                 │
│  DRIVER / SUBSYSTEM CODE                                                                        │
│  ──────────────────────                                                                         │
│  struct my_device {                                                                             │
│      struct work_struct rx_work;  ─────────┐                                                    │
│      struct work_struct io_work;  ────────┐│                                                    │
│  };                                       ││     WORK ITEMS (struct work_struct)                │
│                                           ││     The actual jobs being deferred.                │
│  INIT_WORK(&dev->rx_work, net_rx_func);   ││       .func   = net_rx_func / ext4_io_func         │
│  INIT_WORK(&dev->io_work, ext4_io_func);  ││       .data   = flags + pwq pointer (when queued)  │
│                                           ││       .entry  = list linkage into pool->worklist   │
│                                           ││                                                    │
│  queue_work(system_wq, &dev->rx_work); ───┘│                                                    │
│  queue_work(ext4_wq,   &dev->io_work); ────┘                                                    │
│       │                │                                                                        │
│       ▼                ▼                                                                        │
│  ┌──────────┐    ┌──────────┐                                                                   │
│  │system_wq │    │ ext4_wq  │     WORKQUEUES (struct workqueue_struct)                          │
│  │ "events" │    │  "ext4"  │     The frontend API channels. They do NOT own threads!           │
│  └─────┬────┘    └────┬─────┘     They simply route work to backend pools.                      │
│        │              │                                                                         │
│        ▼              ▼                                                                         │
│  ┌──────────┐    ┌──────────┐     POOL_WORKQUEUE (struct pool_workqueue, "pwq")                 │
│  │ pwq_sys  │    │ pwq_ext4 │     The bridge. One per (workqueue, pool) pair.                   │
│  │.nr_active│    │.nr_active│     Enforces max_active limits per workqueue.                     │
│  └───┬──────┘    └───┬──────┘                                                                   │
│      │               │                                                                          │
│      └───────┬───────┘   << cmwq magic: Different WQs map to the SAME shared CPU pool!          │
│              ▼                                                                                  │
│  ┌──────────────────────────────────────────────────────────────────────────────┐               │
│  │  WORKER POOL #0 (struct worker_pool)       CPU 0, Normal Priority (nice=0)   │               │
│  │                                                                              │               │
│  │  .worklist ──→ [rx_work] ──→ [io_work] ──→ [other_work] ──→ ...              │               │
│  │                   │                                                          │               │
│  │                   │ workers dequeue and run work->func(work)                 │               │
│  │                   ▼                                                          │               │
│  │  .workers (Dynamic Thread Pool):                                             │               │
│  │  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐               │               │
│  │  │ WORKER 0        │  │ WORKER 1        │  │ WORKER 2        │               │               │
│  │  │ [kworker/0:0]   │  │ [kworker/0:1]   │  │ [kworker/0:2]   │               │               │
│  │  │                 │  │                 │  │                 │               │               │
│  │  │ BUSY (Running)  │  │ IDLE (Sleeping) │  │ BUSY (Blocked)  │               │               │
│  │  │ current_work=   │  │ sleeping on     │  │ current_work=   │               │               │
│  │  │   rx_work       │  │ pool->idle_list │  │   io_work       │               │               │
│  │  │ executing       │  │                 │  │ executing       │               │               │
│  │  │   net_rx_func() │  │ ready if needed │  │ ext4_io_func()  │               │               │
│  │  └─────────────────┘  └─────────────────┘  └─────────────────┘               │               │
│  │                                                                              │               │
│  │  CONCURRENCY MANAGEMENT (The 'cm' in cmwq):                                  │               │
│  │    * Goal: Keep exactly ONE worker thread running per CPU to avoid thrashing.│               │
│  │    * If Worker 0 is executing (nr_running=1), Worker 1 stays asleep.         │               │
│  │    * If Worker 2 blocks on a lock or disk I/O, it hooks into the scheduler.  │               │
│  │    * The pool sees nr_running=0 and wakes Worker 1 to keep the CPU busy.     │               │
│  │    * Idle workers are reaped after 5 minutes to save memory.                 │               │
│  └──────────────────────────────────────────────────────────────────────────────┘               │
│                                                                                                 │
│  MULTIPLICITY SUMMARY:                                                                          │
│    Many work items ──→ queued on ──→ Few workqueues ──→ routed to ──→ Shared worker pools       │
│    (Thousands)                       (Tens)             (via pwq)     (2 per CPU + Unbound)     │
│                                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────────────────────┘
 ```

**Interactive Architecture Diagram:** For a complete 7-layer visual with hover tooltips on every component, open [`workqueue_architecture.html`](/assets/images/workqueue_architecture.html) in a browser. A static snapshot is also available:

![Linux Kernel Workqueue Architecture (cmwq)](/assets/images/workqueue_architecture.png)

The **pool_workqueue** (`struct pool_workqueue`, abbreviated **pwq**) is the bridge between a workqueue and a worker pool. Each workqueue has one pwq per CPU (for per-CPU workqueues) or one pwq per NUMA node (for unbound workqueues). The pwq tracks how many work items from a given workqueue are active in a given pool, and enforces the `max_active` concurrency limit.

---

## The work_struct Structure

Every work item is represented by a **`struct work_struct`**, defined at [include/linux/workqueue_types.h, lines 16–23](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/workqueue_types.h#L16-L23):

```c
struct work_struct {
    atomic_long_t data;
    struct list_head entry;
    work_func_t func;
#ifdef CONFIG_LOCKDEP
    struct lockdep_map lockdep_map;
#endif
};
```

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  struct work_struct — The Unit of Deferred Work                                 │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │  data         │  atomic_long_t — multipurpose field:                            │
 │               │    When queued (WORK_STRUCT_PWQ set):                           │
 │               │      High bits = pointer to pool_workqueue (pwq)                │
 │               │      Low bits  = flags (PENDING, INACTIVE, PWQ, LINKED, color)  │
 │               │    When off-queue (WORK_STRUCT_PWQ clear):                      │
 │               │      High bits = last pool ID                                   │
 │               │      Mid bits  = disable depth (16 bits)                        │
 │               │      Low bits  = flags (PENDING + off-queue flags)              │
 ├──────────────┼──────────────────────────────────────────────────────────────────┤
 │  entry        │  struct list_head — links into pool->worklist or                │
 │               │  pwq->inactive_works while queued                               │
 ├──────────────┼──────────────────────────────────────────────────────────────────┤
 │  func         │  work_func_t — the callback: void (*)(struct work_struct *)     │
 │               │  This is the function the worker thread will call               │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

The work function type is defined at [include/linux/workqueue_types.h, line 13](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/workqueue_types.h#L13):

```c
typedef void (*work_func_t)(struct work_struct *work);
```

The handler receives a pointer to the `work_struct` itself — not a `void *` data pointer. This means you must use **`container_of()`** to get back to your enclosing structure (covered later in this document).

---

## The data Field: Encoding Pending State, Pool ID, and PWQ Pointer

The `data` field is the most complex part of `work_struct`. It is an `atomic_long_t` (64 bits on AArch64) that encodes different information depending on the work item's state. The bit layout is defined at [include/linux/workqueue.h, lines 26–74](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/workqueue.h#L26-L74):

```c
enum work_bits {
    WORK_STRUCT_PENDING_BIT  = 0,    /* work item is pending execution */
    WORK_STRUCT_INACTIVE_BIT,        /* work item is inactive */
    WORK_STRUCT_PWQ_BIT,             /* data points to pwq */
    WORK_STRUCT_LINKED_BIT,          /* next work is linked to this one */
    WORK_STRUCT_FLAG_BITS,           /* 4 bits (or 5 with DEBUG_OBJECTS_WORK) */

    WORK_STRUCT_COLOR_SHIFT  = WORK_STRUCT_FLAG_BITS,
    WORK_STRUCT_COLOR_BITS   = 4,    /* 16 flush colors */

    WORK_STRUCT_PWQ_SHIFT    = WORK_STRUCT_COLOR_SHIFT + WORK_STRUCT_COLOR_BITS,
    /* ... */
};
```

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  work_struct->data Bit Layout (64-bit, AArch64)                                 │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  WHEN QUEUED (WORK_STRUCT_PWQ bit set):                                         │
 │  ──────────────────────────────────────                                         │
 │  MSB                                                          LSB               │
 │  [ pwq pointer (aligned to 256 bytes) ] [ color 4b ] [ flags 4b ]               │
 │                                                        ▲                        │
 │                                            bit 0: PENDING                       │
 │                                            bit 1: INACTIVE                      │
 │                                            bit 2: PWQ (= 1)                     │
 │                                            bit 3: LINKED                        │
 │                                                                                 │
 │  WHEN OFF-QUEUE (WORK_STRUCT_PWQ bit clear):                                    │
 │  ───────────────────────────────────────────                                    │
 │  MSB                                                          LSB               │
 │  [ pool ID (31b) ] [ disable depth (16b) ] [ offq flags ] [ flags 4b ]          │
 │                                                              ▲                  │
 │                                            bit 0: PENDING                       │
 │                                            bit 2: PWQ (= 0)                     │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

**`WORK_STRUCT_PENDING_BIT`** (bit 0) is the key bit. It is set when a work item has been queued and cleared when the worker starts executing it. This single bit is how `queue_work_on()` prevents double-queueing — it atomically tests and sets this bit, and if it was already set, the call returns `false` without re-queueing.

---

## Initializing Work Items: Static and Dynamic

Work items can be initialized at compile time (static) or at runtime (dynamic).

### Static Initialization

The **`DECLARE_WORK`** macro creates and initializes a `work_struct` at compile time, defined at [include/linux/workqueue.h, lines 252–253](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/workqueue.h#L252-L253):

```c
#define DECLARE_WORK(n, f)   \
    struct work_struct n = __WORK_INITIALIZER(n, f)
```

Which expands using `__WORK_INITIALIZER` at [include/linux/workqueue.h, lines 239–244](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/workqueue.h#L239-L244):

```c
#define __WORK_INITIALIZER(n, f) {                \
    .data = WORK_DATA_STATIC_INIT(),              \
    .entry = { &(n).entry, &(n).entry },          \
    .func = (f),                                  \
}
```

**Example — static initialization:**

```c
static void my_work_handler(struct work_struct *work);

static DECLARE_WORK(my_work, my_work_handler);
```

This creates a global `struct work_struct` named `my_work` with `my_work_handler` as its callback. The `data` field is initialized with `WORK_STRUCT_NO_POOL` (no pool association), `entry` is initialized as an empty list (pointing to itself), and `func` is set to the handler.

### Dynamic Initialization

The **`INIT_WORK`** macro initializes a `work_struct` at runtime, defined at [include/linux/workqueue.h, lines 309–310](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/workqueue.h#L309-L310):

```c
#define INIT_WORK(_work, _func)   \
    __INIT_WORK((_work), (_func), 0)
```

Which expands to `__INIT_WORK_KEY` at [include/linux/workqueue.h, lines 293–299](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/workqueue.h#L293-L299):

```c
#define __INIT_WORK_KEY(_work, _func, _onstack, _key)      \
    do {                                                    \
        __init_work((_work), _onstack);                     \
        (_work)->data = (atomic_long_t) WORK_DATA_INIT();   \
        INIT_LIST_HEAD(&(_work)->entry);                    \
        (_work)->func = (_func);                            \
    } while (0)
```

**Example — dynamic initialization:**

```c
struct my_device {
    struct work_struct work;
    int irq_status;
};

static void my_work_handler(struct work_struct *work)
{
    struct my_device *dev = container_of(work, struct my_device, work);
    /* dev->irq_status is accessible here */
}

static int my_probe(struct platform_device *pdev)
{
    struct my_device *dev = devm_kzalloc(&pdev->dev, sizeof(*dev), GFP_KERNEL);
    INIT_WORK(&dev->work, my_work_handler);
    return 0;
}
```

Dynamic initialization is the common case in drivers, because the `work_struct` is typically embedded inside a device-specific structure that is allocated at probe time.

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  Static vs Dynamic Initialization                                               │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  STATIC (compile-time):                                                         │
 │  ──────────────────────                                                         │
 │    DECLARE_WORK(my_work, handler)                                               │
 │      │                                                                          │
 │      ├── Allocates struct work_struct as a global/static variable               │
 │      ├── .data = WORK_DATA_STATIC_INIT()  (pool=NONE, PENDING=0)                │
 │      ├── .entry = { &self, &self }        (empty list)                          │
 │      └── .func = handler                                                        │
 │                                                                                 │
 │    Use when: global/static work items, module-level singletons                  │
 │                                                                                 │
 │  DYNAMIC (runtime):                                                             │
 │  ──────────────────                                                             │
 │    INIT_WORK(&dev->work, handler)                                               │
 │      │                                                                          │
 │      ├── Initializes an already-allocated work_struct                           │
 │      ├── .data = WORK_DATA_INIT()         (pool=NONE, PENDING=0)                │
 │      ├── INIT_LIST_HEAD(&entry)           (empty list)                          │
 │      └── .func = handler                                                        │
 │                                                                                 │
 │    Use when: work_struct embedded in dynamically allocated structures           │
 │              (driver probe, per-device, per-connection)                         │
 │                                                                                 │
 │  Both produce the same initial state:                                           │
 │    data = no pool, not pending  │  entry = empty  │  func = handler             │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

---

## The workqueue_struct Structure

The **`struct workqueue_struct`** is the externally visible workqueue — the named channel through which work items are submitted. It is defined at [kernel/workqueue.c, lines 349–397](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L349-L397):

```c
struct workqueue_struct {
    struct list_head    pwqs;           /* WR: all pwqs of this wq */
    struct list_head    list;           /* PR: list of all workqueues */

    struct mutex        mutex;          /* protects this wq */
    int                 work_color;     /* WQ: current work color */
    int                 flush_color;    /* WQ: current flush color */
    atomic_t            nr_pwqs_to_flush; /* flush in progress */
    struct wq_flusher  *first_flusher;  /* WQ: first flusher */
    struct list_head    flusher_queue;  /* WQ: flush waiters */
    struct list_head    flusher_overflow; /* WQ: flush overflow list */

    struct list_head    maydays;        /* MD: pwqs requesting rescue */
    struct worker      *rescuer;        /* MD: rescue worker */

    int                 nr_drainers;    /* WQ: drain in progress */

    int                 max_active;     /* WO: max active works */
    int                 min_active;     /* WO: min active works */
    int                 saved_max_active; /* WQ: saved max_active */
    int                 saved_min_active; /* WQ: saved min_active */

    struct workqueue_attrs *unbound_attrs;   /* PW: only for unbound wqs */
    struct pool_workqueue __rcu *dfl_pwq;    /* PW: only for unbound wqs */

    char                name[WQ_NAME_LEN]; /* I: workqueue name */

    unsigned int        flags ____cacheline_aligned; /* WQ: WQ_* flags */
    struct pool_workqueue __rcu * __percpu *cpu_pwq; /* I: per-cpu pwqs */
    struct wq_node_nr_active *node_nr_active[]; /* I: per-node nr_active */
};
```

A workqueue **does not own any threads**. It routes work items to the appropriate **worker pool** through **pool_workqueue** (pwq) intermediaries. The `cpu_pwq` field is a per-CPU pointer to the pwq for each CPU — this is how `queue_work()` finds the right pool for the current CPU.

The `max_active` field limits how many work items from this workqueue can be executing concurrently in a given pool. The `rescuer` field points to a dedicated rescue worker (created if `WQ_MEM_RECLAIM` is set) that can execute work items when normal worker creation fails due to memory pressure.

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  workqueue_struct Key Fields                                                    │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  workqueue_struct ("events")                                                    │
 │  ┌───────────────────────────────────────────────────────────────────┐          │
 │  │  name[]          = "events"                                       │          │
 │  │  flags           = WQ_PERCPU                                      │          │
 │  │  max_active      = 1024 (WQ_DFL_ACTIVE)                           │          │
 │  │                                                                   │          │
 │  │  cpu_pwq ──────→ per-CPU array of pwq pointers                    │          │
 │  │    │  [CPU 0] → pwq₀ → worker_pool (CPU 0, normal)               │          │
 │  │    │  [CPU 1] → pwq₁ → worker_pool (CPU 1, normal)               │          │
 │  │    │  [CPU N] → pwqₙ → worker_pool (CPU N, normal)               │          │
 │  │                                                                   │          │
 │  │  pwqs            = list of all pwqs belonging to this wq          │          │
 │  │  list            = node on global workqueues list                 │          │
 │  │  rescuer         = rescue worker (if WQ_MEM_RECLAIM set)          │          │
 │  │                                                                   │          │
 │  │  flush machinery:                                                 │          │
 │  │    work_color / flush_color / flusher_queue                       │          │
 │  │    (color-based flush protocol for flush_workqueue)               │          │
 │  └───────────────────────────────────────────────────────────────────┘          │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

---

## The worker_pool Structure

The **`struct worker_pool`** is where the actual execution happens. It maintains a list of pending work items (`worklist`), a set of idle workers, a hash table of busy workers, and the concurrency management state. Defined at [kernel/workqueue.c, lines 195–244](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L195-L244):

```c
struct worker_pool {
    raw_spinlock_t     lock;           /* the pool lock */
    int                cpu;            /* I: the associated cpu */
    int                node;           /* I: the associated node ID */
    int                id;             /* I: pool ID */
    unsigned int       flags;          /* L: flags */

    int                nr_running;     /* concurrency management counter */

    struct list_head   worklist;       /* L: list of pending works */

    int                nr_workers;     /* L: total number of workers */
    int                nr_idle;        /* L: currently idle workers */

    struct list_head   idle_list;      /* L: list of idle workers */
    struct timer_list  idle_timer;     /* L: worker idle timeout */
    struct work_struct idle_cull_work; /* L: worker idle cleanup */

    struct timer_list  mayday_timer;   /* L: SOS timer for workers */

    DECLARE_HASHTABLE(busy_hash, BUSY_WORKER_HASH_ORDER);
                                       /* L: hash of busy workers */

    struct worker      *manager;       /* L: purely informational */
    struct list_head   workers;        /* A: attached workers */

    struct workqueue_attrs *attrs;     /* I: worker attributes */
    int                refcnt;         /* PL: refcnt for unbound pools */
    struct rcu_head    rcu;
};
```

There are **two standard worker pools per CPU** — one for normal priority work and one for high priority work (`WQ_HIGHPRI`). This is encoded in the constant at [kernel/workqueue.c, line 107](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L107):

```c
NR_STD_WORKER_POOLS = 2,   /* # standard pools per cpu */
```

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  Worker Pools Per CPU                                                           │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  CPU 0                          CPU 1                          CPU N            │
 │  ┌──────────────────┐          ┌──────────────────┐                             │
 │  │ Pool 0 (normal)  │          │ Pool 2 (normal)  │           ...               │
 │  │  nice = 0        │          │  nice = 0        │                             │
 │  │  worklist ──→... │          │  worklist ──→... │                             │
 │  │  workers: kw0,.. │          │  workers: kw2,.. │                             │
 │  ├──────────────────┤          ├──────────────────┤                             │
 │  │ Pool 1 (highpri) │          │ Pool 3 (highpri) │           ...               │
 │  │  nice = MIN_NICE │          │  nice = MIN_NICE │                             │
 │  │  worklist ──→... │          │  worklist ──→... │                             │
 │  │  workers: kw1,.. │          │  workers: kw3,.. │                             │
 │  └──────────────────┘          └──────────────────┘                             │
 │                                                                                 │
 │  Additionally, unbound pools are created dynamically                            │
 │  (shared across CPUs, not tied to any specific CPU)                             │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

The **concurrency management** is built around `nr_running` — a count of how many workers from this pool are currently on-CPU (not sleeping). The scheduler hooks `wq_worker_running()` and `wq_worker_sleeping()` (called from `schedule()`) increment and decrement this counter. When `nr_running` drops to zero (all workers are sleeping), the pool wakes another idle worker to process pending work items. This ensures forward progress even when work items block.

The design principle is simple: **the pool wants exactly one worker running at a time**. If that worker blocks (sleeps on a mutex, waits for I/O), `nr_running` drops to 0 and another worker is woken. When the blocked worker resumes, `nr_running` temporarily exceeds 1, and `keep_working()` (which checks `nr_running <= 1`) causes the excess worker to go back to sleep. This self-regulating mechanism means the pool automatically scales concurrency to match the number of blocking work items — without any explicit management from the workqueue user.

The `busy_hash` is a hash table keyed by work item address. When `process_one_work()` starts executing a work item, the worker is inserted into `busy_hash`. This allows `find_worker_executing_work()` to quickly locate whether a given work item is currently being executed by any worker in the pool — the critical lookup for the non-reentrance guarantee in `__queue_work()`.

---

## The pool_workqueue (pwq) Structure: The Bridge Between Workqueue and Pool

The **`struct pool_workqueue`** connects a specific workqueue to a specific worker pool. It enforces per-workqueue concurrency limits (`max_active`) and maintains the inactive work list. Defined at [kernel/workqueue.c, lines 269–312](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L269-L312):

```c
struct pool_workqueue {
    struct worker_pool  *pool;          /* I: the associated pool */
    struct workqueue_struct *wq;        /* I: the owning workqueue */
    int                 work_color;     /* L: current color */
    int                 flush_color;    /* L: flushing color */
    int                 refcnt;         /* L: reference count */
    int                 nr_in_flight[WORK_NR_COLORS];
                                        /* L: nr of in_flight works */
    bool                plugged;        /* L: execution suspended */

    int                 nr_active;      /* L: nr of active works */
    struct list_head    inactive_works; /* L: inactive works */
    struct list_head    pwqs_node;      /* WR: node on wq->pwqs */
    /* ... */
};
```

The `pool_workqueue` exists because **worker pools are shared across multiple workqueues** — the per-CPU normal-priority pool on CPU 0 serves `system_percpu_wq`, `system_long_wq`, and every custom per-CPU workqueue simultaneously. Each of these workqueues may have different `max_active` limits. The pwq holds this **per-workqueue-per-pool state** — the `nr_active` counter, the `inactive_works` list, and the flush/color accounting — so each workqueue maintains independent throttling on a shared pool.

The pwq lookup in the queueing path — `per_cpu_ptr(wq->cpu_pwq, cpu)` — is the critical step that connects the abstract workqueue to the concrete pool where work will execute. For per-CPU workqueues, each CPU's pwq was wired to that CPU's normal or highpri pool during `alloc_and_link_pwqs()`. For unbound workqueues, the pwq points to a dynamically created unbound pool matching the workqueue's NUMA affinity scope.

When `pwq->nr_active >= max_active`, new work items are placed on `pwq->inactive_works` instead of the pool's `worklist`, and marked with `WORK_STRUCT_INACTIVE`. They are activated (moved to `pool->worklist`) as in-flight work items complete via `pwq_dec_nr_in_flight()`. This throttling prevents any single workqueue from monopolizing a shared pool — an ordered workqueue (`max_active=1`) guarantees serial execution by keeping all but one item inactive.

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  The pwq Bridge                                                                 │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │   workqueue_struct ("events")                                                   │
 │     │                                                                           │
 │     ├── pwq[CPU 0] ──→ worker_pool (CPU 0, normal)                              │
 │     │     nr_active: 3                                                          │
 │     │     inactive_works: [work_D, work_E]                                      │
 │     │                                                                           │
 │     ├── pwq[CPU 1] ──→ worker_pool (CPU 1, normal)                              │
 │     │     nr_active: 1                                                          │
 │     │     inactive_works: []                                                    │
 │     │                                                                           │
 │     └── pwq[CPU N] ──→ worker_pool (CPU N, normal)                              │
 │           nr_active: 0                                                          │
 │           inactive_works: []                                                    │
 │                                                                                 │
 │   When max_active = 3 and CPU 0 already has 3 active items,                     │
 │   work_D and work_E go to inactive_works instead of pool->worklist              │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

---

## The worker Structure

The **`struct worker`** represents a single kworker thread. Defined at [kernel/workqueue_internal.h, lines 24–63](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue_internal.h#L24-L63):

```c
struct worker {
    /* on idle list while idle, on busy hash table while busy */
    union {
        struct list_head  entry;    /* L: while idle */
        struct hlist_node hentry;   /* L: while busy */
    };

    struct work_struct   *current_work;   /* K: work being processed */
    work_func_t          current_func;    /* K: its function */
    struct pool_workqueue *current_pwq;   /* K: its pwq */
    unsigned int         current_color;   /* K: color */
    int                  sleeping;        /* S: is worker sleeping? */
    work_func_t          last_func;       /* K: last work's fn */
    struct list_head     scheduled;       /* L: scheduled works */
    struct task_struct   *task;           /* I: worker task */
    struct worker_pool   *pool;           /* A: the associated pool */
    struct list_head     node;            /* A: anchored at pool->workers */
    unsigned int         flags;           /* L: flags */
    int                  id;              /* I: worker id */
    char                 desc[WORKER_DESC_LEN];
    struct workqueue_struct *rescue_wq;   /* I: the workqueue to rescue */
};
```

A worker is either **idle** (on `pool->idle_list`) or **busy** (in `pool->busy_hash`). The union of `entry`/`hentry` reflects this — it is a `list_head` when idle and an `hlist_node` when busy (hashed by the address of the work item it is executing). The `current_work`, `current_func`, and `current_pwq` fields are set when the worker starts processing a work item and cleared when it finishes.

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  Worker State Transitions                                                       │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  IDLE STATE                              BUSY STATE                             │
 │  ──────────                              ──────────                             │
 │  worker.entry → pool->idle_list          worker.hentry → pool->busy_hash        │
 │  worker.current_work = NULL              worker.current_work = work             │
 │  worker.current_func = NULL              worker.current_func = work->func       │
 │  worker.current_pwq  = NULL              worker.current_pwq  = pwq              │
 │  worker.sleeping = 0                     worker.sleeping = 0 or 1               │
 │                                                                                 │
 │                                                                                 │
 │        create_worker()                                                          │
 │              │                                                                  │
 │              ▼                                                                  │
 │  ┌──── IDLE (waiting) ◄──────────────────────────────┐                          │
 │  │     schedule() / TASK_IDLE                         │                         │
 │  │          │                                         │                         │
 │  │          │ woken: need_more_worker() == true       │                         │
 │  │          ▼                                         │                         │
 │  │     BUSY (processing)                              │                         │
 │  │     ├── assign_work(work, worker)                  │                         │
 │  │     ├── process_one_work(worker, work)             │                         │
 │  │     │     ├── hash_add(busy_hash)                  │                         │
 │  │     │     ├── clear PENDING bit                    │                         │
 │  │     │     ├── call work->func(work)                │                         │
 │  │     │     └── hash_del(busy_hash)                  │                         │
 │  │     └── keep_working(pool)? ──YES──→ pick next     │                         │
 │  │                              └─NO──→ enter idle ───┘                         │
 │  │                                                                              │
 │  │     DYING                                                                    │
 │  │     WORKER_DIE flag set → thread exits                                       │
 │  └──── (after IDLE_WORKER_TIMEOUT = 300*HZ = 5 minutes idle)                    │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

---

## Unbound Workqueues and Why Worker Pools Are Required

A **per-CPU workqueue** (the default, `WQ_PERCPU`) binds work items to the CPU where they were queued. Each CPU has its own worker pool, and the kworker threads are bound to that CPU. This provides excellent cache locality — data accessed by the work handler is likely hot in the CPU's cache.

An **unbound workqueue** (`WQ_UNBOUND`) does not bind work items to any specific CPU. Instead, unbound workqueues use dynamically created worker pools whose workers can migrate across CPUs within a NUMA node or the entire system, depending on the workqueue's **affinity scope**. This is the default for `system_dfl_wq` (the "events_unbound" workqueue) — work items can be load-balanced across CPUs by the CFS scheduler, which is ideal for longer-running work where cache locality matters less than throughput. Note: the original `system_unbound_wq` is now `__WQ_DEPRECATED`; `system_dfl_wq` is its replacement. The tradeoff is that accessing per-CPU data from an unbound worker requires explicit CPU pinning or per-CPU primitives, since the worker may run on any CPU in its affinity scope.

Worker pools are required because they provide:

1. **Thread reuse** — Instead of creating a new kernel thread for every work item, workers are reused across work items and even across different workqueues. The old pre-cmwq model created a dedicated kthread per workqueue per CPU, which led to an explosion of threads as the number of workqueues grew.

2. **Concurrency management** — The pool tracks how many workers are actively running (`nr_running`) and automatically wakes additional idle workers when all running workers block. This prevents deadlock when a work item sleeps waiting for something that another work item in the same pool could provide.

3. **Dynamic scaling** — Workers are created on demand and reaped after an idle timeout (`IDLE_WORKER_TIMEOUT = 300 * HZ`, i.e., 5 minutes), keeping resource usage proportional to actual load.

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  Per-CPU vs Unbound Worker Pools                                                │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  PER-CPU (WQ_PERCPU):                                                           │
 │  ────────────────────                                                           │
 │    ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐                           │
 │    │  CPU 0  │  │  CPU 1  │  │  CPU 2  │  │  CPU 3  │                           │
 │    │ pool(N) │  │ pool(N) │  │ pool(N) │  │ pool(N) │                           │
 │    │ pool(H) │  │ pool(H) │  │ pool(H) │  │ pool(H) │                           │
 │    └────┬────┘  └────┬────┘  └────┬────┘  └────┬────┘                           │
 │         │            │            │            │                                │
 │    Workers bound     Workers bound             Workers bound                    │
 │    to CPU 0 only     to CPU 1 only             to CPU 3 only                    │
 │                                                                                 │
 │    ● Best cache locality  ● Work stays on queueing CPU                          │
 │    ● Concurrency managed per-CPU                                                │
 │                                                                                 │
 │  UNBOUND (WQ_UNBOUND):                                                          │
 │  ─────────────────────                                                          │
 │    ┌──────────────────────────┐  ┌──────────────────────────┐                   │
 │    │     NUMA Node 0          │  │     NUMA Node 1          │                   │
 │    │  ┌────────────────────┐  │  │  ┌────────────────────┐  │                   │
 │    │  │  Unbound pool      │  │  │  │  Unbound pool      │  │                   │
 │    │  │  Workers can run   │  │  │  │  Workers can run   │  │                   │
 │    │  │  on CPU 0,1,2,3    │  │  │  │  on CPU 4,5,6,7    │  │                   │
 │    │  └────────────────────┘  │  │  └────────────────────┘  │                   │
 │    └──────────────────────────┘  └──────────────────────────┘                   │
 │                                                                                 │
 │    ● Workers migrate across CPUs within scope                                   │
 │    ● Good for long-running work that doesn't need locality                      │
 │    ● Scope controlled by wq_affn_scope                                          │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

The affinity scope for unbound workqueues is defined at [include/linux/workqueue.h, lines 131–141](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/workqueue.h#L131-L141):

```c
enum wq_affn_scope {
    WQ_AFFN_DFL,           /* use system default */
    WQ_AFFN_CPU,           /* one pod per CPU */
    WQ_AFFN_SMT,           /* one pod per SMT */
    WQ_AFFN_CACHE,         /* one pod per LLC */
    WQ_AFFN_CACHE_SHARD,   /* synthetic sub-LLC shards */
    WQ_AFFN_NUMA,          /* one pod per NUMA node */
    WQ_AFFN_SYSTEM,        /* one pod across the whole system */
};
```

---

## Creating a Worker: create_worker()

Workers are created by `create_worker()` at [kernel/workqueue.c, lines 2836–2903](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L2836-L2903). The function allocates a worker structure, creates a kernel thread via `kthread_create_on_node()`, and attaches the worker to the pool:

```c
static struct worker *create_worker(struct worker_pool *pool)
{
    struct worker *worker;
    int id;

    id = ida_alloc(&pool->worker_ida, GFP_KERNEL);
    if (id < 0)
        return NULL;

    worker = alloc_worker(pool->node);
    if (!worker)
        goto fail;

    worker->id = id;

    if (!(pool->flags & POOL_BH)) {
        char id_buf[WORKER_ID_LEN];

        format_worker_id(id_buf, sizeof(id_buf), worker, pool);
        worker->task = kthread_create_on_node(worker_thread, worker,
                                              pool->node, "%s", id_buf);
        if (IS_ERR(worker->task))
            goto fail;

        set_user_nice(worker->task, pool->attrs->nice);
        kthread_bind_mask(worker->task, pool_allowed_cpus(pool));
    }

    /* successful, attach the worker to the pool */
    worker_attach_to_pool(worker, pool);

    raw_spin_lock_irq(&pool->lock);
    worker->pool->nr_workers++;
    worker_enter_idle(worker);

    if (worker->task)
        wake_up_process(worker->task);

    raw_spin_unlock_irq(&pool->lock);
    return worker;
}
```

The kernel thread is created with `worker_thread` as its function. The worker's nice value is set from the pool's attributes — normal pools use `nice = 0`, high-priority pools use `nice = MIN_NICE` (= -20), as set at [kernel/workqueue.c, line 128](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L128):

```c
HIGHPRI_NICE_LEVEL = MIN_NICE,
```

The new worker starts in the **idle** state (`worker_enter_idle()`), and `wake_up_process()` wakes it so it enters the `worker_thread()` main loop.

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  create_worker() Flow                                                           │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  create_worker(pool)                                                            │
 │    │                                                                            │
 │    ├── ida_alloc(&pool->worker_ida)        → get unique worker ID               │
 │    │     failure → return NULL                                                  │
 │    │                                                                            │
 │    ├── alloc_worker(pool->node)            → kzalloc struct worker              │
 │    │     failure → free ID, return NULL                                         │
 │    │                                                                            │
 │    ├── worker->id = id                                                          │
 │    │                                                                            │
 │    ├── format_worker_id(id_buf, ...)       → "kworker/0:1" or "kworker/u8:0"    │
 │    │                                                                            │
 │    ├── kthread_create_on_node(             → create the kthread                 │
 │    │       worker_thread,                  ← thread function                    │
 │    │       worker,                         ← passed as __worker arg             │
 │    │       pool->node,                     ← NUMA node affinity                 │
 │    │       "%s", id_buf)                   ← thread name                        │
 │    │     failure → free worker, return NULL                                     │
 │    │                                                                            │
 │    ├── set_user_nice(task, pool->attrs->nice)                                   │
 │    │     Normal pool: nice = 0                                                  │
 │    │     Highpri pool: nice = MIN_NICE (-20)                                    │
 │    │                                                                            │
 │    ├── kthread_bind_mask(task, pool_allowed_cpus(pool))                         │
 │    │     Per-CPU pool: bind to single CPU                                       │
 │    │     Unbound pool: bind to pod/node cpumask                                 │
 │    │                                                                            │
 │    ├── worker_attach_to_pool(worker, pool)                                      │
 │    │                                                                            │
 │    ├── raw_spin_lock_irq(&pool->lock)                                           │
 │    │     pool->nr_workers++                                                     │
 │    │     worker_enter_idle(worker)         → put on pool->idle_list             │
 │    │     wake_up_process(worker->task)     → start running worker_thread()      │
 │    └── raw_spin_unlock_irq(&pool->lock)                                         │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

### When Are kworkers Created?

kworkers are **not** all created at boot. They are created **on demand** and destroyed after idle. The lifecycle has three phases:

**Phase 1: Boot-Time Initialization**

During kernel boot, the workqueue subsystem initializes in two stages:

1. **`workqueue_init_early()`** at [kernel/workqueue.c, lines 7620–7710](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L7620-L7710) — runs during early boot (`early_initcall`). Creates the per-CPU worker pool structures (2 per CPU: normal + highpri), allocates unbound pool attributes, and creates all system workqueues (`system_wq`, `system_highpri_wq`, etc.). At this point, the pools exist but have **zero workers** — all work items are executed directly in the queueing context because `wq_online` is still `false`.

2. **`workqueue_init()`** at [kernel/workqueue.c, lines 7721–7787](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L7721-L7787) — runs later in boot (`init_workqueues` initcall). Creates the **initial worker** for each per-CPU pool and each unbound pool by calling `create_worker()`. Sets `wq_online = true`, after which work items are queued normally and executed by kworker threads.

```c
/* From workqueue_init() — creating initial workers for each CPU pool */
for_each_online_cpu(cpu) {
    for_each_cpu_worker_pool(pool, cpu) {
        pool->flags &= ~POOL_DISASSOCIATED;
        BUG_ON(!create_worker(pool));
    }
}
```

After `workqueue_init()` completes, a system with 8 CPUs has at minimum 16 kworkers (1 per pool × 2 pools per CPU × 8 CPUs), plus workers for any unbound pools.

**Phase 2: On-Demand Creation**

After boot, additional workers are created when the concurrency manager detects that a pool has no idle workers to handle pending work. This happens inside `worker_thread()` at the `recheck` label:

```c
/* no more worker necessary? */
if (!need_more_worker(pool))     /* worklist empty or someone running */
    goto sleep;

/* do we need to manage? */
if (unlikely(!may_start_working(pool)) && manage_workers(worker))
    goto recheck;
```

The trigger chain is:

1. **`need_more_worker(pool)`** returns `true` — the pool has pending work AND `nr_running == 0` (no worker is actively running on-CPU)
2. **`may_start_working(pool)`** returns `false` — `pool->nr_idle == 0` (no idle workers available to process work)
3. **`manage_workers(worker)`** is called — this calls `create_worker(pool)` to spawn a new kworker thread

The other on-demand trigger is **`kick_pool()`**, called after inserting work into the worklist. `kick_pool()` at [kernel/workqueue.c, lines 1237–1260](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L1237-L1260) wakes the first idle worker via `wake_up_process()`. If there are no idle workers, a **mayday timer** is set — when it fires, the pool's rescuer (if `WQ_MEM_RECLAIM` is set) takes over to ensure forward progress even under memory pressure.

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  When kworkers Are Created                                                      │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  BOOT TIME                                                                      │
 │  ─────────                                                                      │
 │  workqueue_init_early()     → Create pool structures (no workers yet)           │
 │  workqueue_init()           → Create 1 initial worker per pool                  │
 │                                                                                 │
 │    Per 8-CPU system: 8 CPUs × 2 pools/CPU = 16 initial kworkers                │
 │    Plus 1+ worker per unbound pool                                              │
 │                                                                                 │
 │  RUNTIME (on-demand)                                                            │
 │  ───────────────────                                                            │
 │  Trigger: work is queued AND pool has no idle workers                           │
 │                                                                                 │
 │  worker_thread() loop:                                                          │
 │    need_more_worker(pool)?     ← worklist not empty AND nr_running == 0         │
 │      YES → may_start_working(pool)?  ← nr_idle > 0?                            │
 │              NO → manage_workers()                                              │
 │                     └── create_worker(pool) → new kworker thread                │
 │              YES → proceed to process work                                      │
 │                                                                                 │
 │  kick_pool() (called from insert_work):                                         │
 │    nr_idle > 0?                                                                 │
 │      YES → wake_up_process(first_idle_worker)                                   │
 │      NO  → mayday_timer fires → rescuer takes over (WQ_MEM_RECLAIM)             │
 │                                                                                 │
 │  IDLE TIMEOUT (destruction)                                                     │
 │  ──────────────────────────                                                     │
 │  Trigger: worker idle for IDLE_WORKER_TIMEOUT (300*HZ = 5 minutes)              │
 │                                                                                 │
 │  idle_worker_timeout() fires:                                                   │
 │    Too many idle workers? (nr_idle > 1)                                         │
 │      YES → set WORKER_DIE flag → worker exits worker_thread() loop              │
 │      NO  → keep the last idle worker alive (minimum 1 per pool)                 │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

**Phase 3: Idle Timeout and Destruction**

Workers that have been idle for `IDLE_WORKER_TIMEOUT` (= `300 * HZ`, i.e., 5 minutes) are candidates for destruction. The `idle_timer` in the pool fires `idle_worker_timeout()` at [kernel/workqueue.c, lines 2907–2923](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L2907-L2923), which sets the `WORKER_DIE` flag on excess idle workers. The pool always keeps at least one idle worker alive. When the dying worker wakes up in `worker_thread()`, it checks `WORKER_DIE` and exits:

```c
/* am I supposed to die? */
if (unlikely(worker->flags & WORKER_DIE)) {
    raw_spin_unlock_irq(&pool->lock);
    set_pf_worker(false);
    worker->pool = NULL;
    ida_free(&pool->worker_ida, worker->id);
    return 0;       /* kthread exits */
}
```

### How kworkers Are Assigned to CPUs

CPU assignment happens in `create_worker()` via a single call:

```c
kthread_bind_mask(worker->task, pool_allowed_cpus(pool));
```

**`pool_allowed_cpus(pool)`** at [kernel/workqueue.c, lines 1189–1195](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L1189-L1195) returns the cpumask that determines which CPUs the kworker is allowed to run on:

- **Per-CPU pools**: Returns a mask with **exactly one CPU** — the CPU this pool belongs to. The kworker thread is hard-bound to that single CPU and will never migrate.
- **Unbound pools**: Returns `pool->attrs->cpumask`, which is typically the NUMA node's cpumask or a subset thereof. The kworker can migrate across all CPUs in that mask, scheduled by the kernel's CFS scheduler.

**`kthread_bind_mask()`** at [kernel/kthread.c, lines 602–612](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/kthread.c#L602-L612) sets the thread's `cpus_mask` (also called `cpu_affinity`) — the same mechanism as `sched_setaffinity()` but callable from within the kernel.

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  How kworkers Are Bound to CPUs                                                 │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  create_worker(pool)                                                            │
 │    │                                                                            │
 │    └── kthread_bind_mask(task, pool_allowed_cpus(pool))                         │
 │                                                                                 │
 │  Per-CPU pool (e.g., CPU 2, normal priority):                                   │
 │  ─────────────────────────────────────────────                                  │
 │    pool_allowed_cpus(pool) → cpumask = { CPU 2 }                                │
 │    kthread_bind_mask(task, { CPU 2 })                                           │
 │    → kworker/2:0 runs ONLY on CPU 2, forever                                    │
 │    → Ensures per-CPU data locality and cache affinity                           │
 │                                                                                 │
 │  Unbound pool (NUMA node 0 with CPUs 0-3):                                     │
 │  ─────────────────────────────────────────                                      │
 │    pool_allowed_cpus(pool) → pool->attrs->cpumask = { CPU 0,1,2,3 }            │
 │    kthread_bind_mask(task, { CPU 0,1,2,3 })                                     │
 │    → kworker/u8:0 can run on any of CPUs 0-3                                    │
 │    → CFS scheduler decides which CPU based on load balancing                    │
 │                                                                                 │
 │  What about CPU hotplug?                                                        │
 │  ───────────────────────                                                        │
 │    When a CPU goes offline:                                                     │
 │      - Per-CPU pool: workers are unbound (WORKER_UNBOUND flag set),             │
 │        pending work is drained or migrated                                      │
 │      - Pool is marked POOL_DISASSOCIATED                                        │
 │    When CPU comes back online:                                                  │
 │      - Pool is reassociated, workers rebound to the CPU                         │
 │      - Handled by workqueue_online_cpu() / workqueue_offline_cpu()              │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

### Concurrency Management: The nr_running Dance

The pool's concurrency management ensures that **exactly the right number of workers are active** — not too many (wasting CPU), not too few (stalling work). The key counter is `pool->nr_running`, which tracks how many workers from this pool are currently on-CPU (not sleeping).

The scheduler integrates with the workqueue subsystem through two hooks at [kernel/sched/core.c](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/sched/core.c):

**`wq_worker_sleeping()`** — called when a kworker (`PF_WQ_WORKER`) is about to sleep:
```c
void wq_worker_sleeping(struct task_struct *task)
{
    struct worker *w = kthread_data(task);
    struct worker_pool *pool = w->pool;

    if (w->flags & WORKER_NOT_RUNNING)
        return;

    w->sleeping = 1;
    raw_spin_lock_irq(&pool->lock);
    if (need_more_worker(pool))           /* nr_running dropped to 0? */
        wake_up_worker(pool);             /* wake an idle worker */
    raw_spin_unlock_irq(&pool->lock);
}
```

**`wq_worker_running()`** — called when a kworker wakes up and resumes execution:
```c
void wq_worker_running(struct task_struct *task)
{
    struct worker *w = kthread_data(task);

    if (w->sleeping) {
        w->sleeping = 0;
        WRITE_ONCE(w->pool->nr_running, w->pool->nr_running + 1);
    }
}
```

This creates a self-regulating feedback loop:

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  Concurrency Management — The nr_running Dance                                  │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  Pool starts: 1 worker running, nr_running = 1                                 │
 │                                                                                 │
 │  Scenario 1: Worker blocks (e.g., mutex_lock())                                │
 │  ──────────────────────────────────────────────                                 │
 │    schedule() → wq_worker_sleeping()                                            │
 │      nr_running-- → nr_running = 0                                              │
 │      need_more_worker() == true (worklist not empty, nr_running == 0)           │
 │      → wake_up_worker() → wake an idle worker                                   │
 │      → new worker starts processing, nr_running = 1 again                       │
 │                                                                                 │
 │  Scenario 2: Blocked worker wakes up                                           │
 │  ──────────────────────────────────                                             │
 │    wq_worker_running()                                                          │
 │      nr_running++ → nr_running = 2                                              │
 │      → keep_working() returns false (nr_running > 1)                            │
 │      → one worker goes back to sleep, nr_running = 1                            │
 │                                                                                 │
 │  Scenario 3: CPU-intensive work (WQ_CPU_INTENSIVE)                              │
 │  ─────────────────────────────────────────────────                               │
 │    process_one_work() sets WORKER_CPU_INTENSIVE                                 │
 │      → WORKER_NOT_RUNNING flag → excluded from nr_running                       │
 │      → kick_pool() wakes another worker for remaining work                      │
 │      → CPU-intensive handler runs without blocking the pool                     │
 │                                                                                 │
 │  Result: The pool naturally converges to 1 running worker.                      │
 │  If that worker blocks, another takes over instantly.                           │
 │  No coordination needed — the scheduler does it via PF_WQ_WORKER hooks.         │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

---

## kworker Thread Naming: CPU-Bound vs CPU-Unbound

You can observe kworker threads on a running system with:

```bash
ps -ef | grep kworker
```

The naming convention is defined by `format_worker_id()` and follows the pattern specified at [kernel/workqueue.c, line 131](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L131):

```c
WORKER_ID_LEN = 10 + WQ_NAME_LEN,   /* "kworker/R-" + WQ_NAME_LEN */
```

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  kworker Thread Naming Convention                                               │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  CPU-BOUND (per-CPU) workers:                                                   │
 │  ────────────────────────────                                                   │
 │    kworker/<cpu>:<id>             Normal priority pool                          │
 │    kworker/<cpu>:H<id>            High priority pool (WQ_HIGHPRI)               │
 │                                                                                 │
 │    Examples:                                                                    │
 │      kworker/0:0       → CPU 0, normal pool, worker ID 0                        │
 │      kworker/0:1       → CPU 0, normal pool, worker ID 1                        │
 │      kworker/3:H0      → CPU 3, high priority pool, worker ID 0                 │
 │                                                                                 │
 │  CPU-UNBOUND workers:                                                           │
 │  ────────────────────                                                           │
 │    kworker/u<pool_id>:<id>                                                      │
 │                                                                                 │
 │    Examples:                                                                    │
 │      kworker/u8:0      → unbound pool ID 8, worker ID 0                         │
 │      kworker/u12:3     → unbound pool ID 12, worker ID 3                        │
 │                                                                                 │
 │  RESCUER workers (for WQ_MEM_RECLAIM workqueues):                               │
 │    kworker/R-<wq_name>                                                          │
 │                                                                                 │
 │    Example:                                                                     │
 │      kworker/R-events  → rescuer for the "events" workqueue                     │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

To check for high priority worker threads on a running kernel:

```bash
ps -ef | grep 'kworker.*:H'
```

---

## System Workqueues: The Built-In Workqueues

The kernel provides several **system-wide workqueues** that are always present. These are created during early boot by `workqueue_init_early()` at [kernel/workqueue.c, lines 8055–8071](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L8055-L8071) and declared at [include/linux/workqueue.h, lines 465–476](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/workqueue.h#L465-L476):

```c
system_wq = alloc_workqueue("events", WQ_PERCPU | __WQ_DEPRECATED, 0);
system_percpu_wq = alloc_workqueue("events", WQ_PERCPU, 0);
system_highpri_wq = alloc_workqueue("events_highpri", WQ_HIGHPRI | WQ_PERCPU, 0);
system_long_wq = alloc_workqueue("events_long", WQ_PERCPU, 0);
system_unbound_wq = alloc_workqueue("events_unbound", WQ_UNBOUND | __WQ_DEPRECATED, WQ_MAX_ACTIVE);
system_dfl_wq = alloc_workqueue("events_unbound", WQ_UNBOUND, WQ_MAX_ACTIVE);
system_freezable_wq = alloc_workqueue("events_freezable", WQ_FREEZABLE | WQ_PERCPU, 0);
system_bh_wq = alloc_workqueue("events_bh", WQ_BH | WQ_PERCPU, 0);
system_bh_highpri_wq = alloc_workqueue("events_bh_highpri", WQ_BH | WQ_HIGHPRI | WQ_PERCPU, 0);
```

```
 ┌───────────────────────────────────────┬─────────────────────────────────────────┐
 │  System Workqueue                     │  Purpose and Characteristics            │
 ├───────────────────────────────────────┼─────────────────────────────────────────┤
 │  system_percpu_wq ("events")          │  Default per-CPU workqueue for          │
 │                                       │  schedule_work(). Short-lived work      │
 │                                       │  items only. Users expect fast flush.   │
 ├───────────────────────────────────────┼─────────────────────────────────────────┤
 │  system_highpri_wq ("events_highpri") │  Per-CPU, high priority (nice=-20).     │
 │                                       │  For latency-sensitive work.            │
 ├───────────────────────────────────────┼─────────────────────────────────────────┤
 │  system_long_wq ("events_long")       │  Per-CPU. For long-running work items   │
 │                                       │  that would block the regular wq.       │
 ├───────────────────────────────────────┼─────────────────────────────────────────┤
 │  system_dfl_wq ("events_unbound")     │  Unbound. Workers not bound to any      │
 │                                       │  CPU. Not concurrency managed.          │
 ├───────────────────────────────────────┼─────────────────────────────────────────┤
 │  system_freezable_wq                  │  Per-CPU, freezable during suspend.     │
 │  ("events_freezable")                 │  Work items frozen during suspend/      │
 │                                       │  hibernate.                             │
 ├───────────────────────────────────────┼─────────────────────────────────────────┤
 │  system_bh_wq ("events_bh")           │  BH workqueue. Executes in softirq     │
 │                                       │  context, not process context.          │
 ├───────────────────────────────────────┼─────────────────────────────────────────┤
 │  system_power_efficient_wq            │  Per-CPU normally; becomes unbound      │
 │                                       │  if workqueue.power_efficient is set.   │
 └───────────────────────────────────────┴─────────────────────────────────────────┘
```

Most drivers that need a simple deferred-work channel should use the **system workqueue** via `schedule_work()` or `queue_work(system_percpu_wq, ...)` rather than creating their own workqueue, as long as the work items are short-lived and don't need special attributes.

---

## Queueing Work: queue_work() and queue_work_on()

**`queue_work()`** is the primary API for submitting a work item to a workqueue. Defined at [include/linux/workqueue.h, lines 696–700](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/workqueue.h#L696-L700):

```c
static inline bool queue_work(struct workqueue_struct *wq,
                              struct work_struct *work)
{
    return queue_work_on(WORK_CPU_UNBOUND, wq, work);
}
```

It is a thin wrapper around **`queue_work_on()`**, which is the real entry point. `queue_work_on()` is defined at [kernel/workqueue.c, lines 2442–2458](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L2442-L2458):

```c
bool queue_work_on(int cpu, struct workqueue_struct *wq,
                   struct work_struct *work)
{
    bool ret = false;
    unsigned long irq_flags;

    local_irq_save(irq_flags);

    if (!test_and_set_bit(WORK_STRUCT_PENDING_BIT, work_data_bits(work)) &&
        !clear_pending_if_disabled(work)) {
        __queue_work(cpu, wq, work);
        ret = true;
    }

    local_irq_restore(irq_flags);
    return ret;
}
```

The critical operation is **`test_and_set_bit(WORK_STRUCT_PENDING_BIT, ...)`**. This atomically tests bit 0 of `work->data` and sets it. If the bit was already set (the work is already pending), the function returns `false` without queueing. This is the mechanism that prevents double-queueing. Only if the `PENDING` bit was clear (and the work is not disabled) does it proceed to call `__queue_work()`.

The function disables local IRQs (`local_irq_save`) to ensure atomicity — between setting the PENDING bit and actually inserting the work into the pool's worklist, no interrupt can re-enter and find the work in an inconsistent state.

**Return value:** `true` if the work was successfully queued (it was not already pending), `false` if it was already on a queue.

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  queue_work() / queue_work_on() High-Level Flow                                 │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  Driver calls: queue_work(wq, &work)                                            │
 │    │                                                                            │
 │    │ equivalent to: queue_work_on(WORK_CPU_UNBOUND, wq, &work)                  │
 │    ▼                                                                            │
 │  queue_work_on(cpu, wq, &work)                                                  │
 │    │                                                                            │
 │    ├── local_irq_save(irq_flags)                                                │
 │    │                                                                            │
 │    ├── test_and_set_bit(PENDING, &work->data)                                   │
 │    │     │                                                                      │
 │    │     ├── bit was 1 (already pending)                                        │
 │    │     │     → return false (do nothing)                                      │
 │    │     │                                                                      │
 │    │     └── bit was 0 (not pending, now set to 1)                              │
 │    │           │                                                                │
 │    │           ├── clear_pending_if_disabled(work)?                             │
 │    │           │     YES (work is disabled) → return false                      │
 │    │           │     NO  → continue                                             │
 │    │           │                                                                │
 │    │           └── __queue_work(cpu, wq, &work)                                 │
 │    │                 ├── determine target pool                                  │
 │    │                 ├── handle non-reentrance                                  │
 │    │                 ├── insert_work() into pool->worklist                      │
 │    │                 └── kick_pool() → wake idle kworker                        │
 │    │                                                                            │
 │    ├── local_irq_restore(irq_flags)                                             │
 │    └── return true                                                              │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

### Example: Queueing Work on a Specific CPU with queue_work_on()

This module queues a work item on a user-specified CPU via a module parameter, then verifies which CPU the handler actually runs on:

```c
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/workqueue.h>
#include <linux/sched.h>

MODULE_LICENSE("GPL");

static int cpu = 2;
module_param(cpu, int, 0644);

struct my_work {
    struct work_struct work;
    char data[20];
};

static struct my_work deferred_work;

static void work_fn(struct work_struct *work)
{
    struct my_work *mw = container_of(work, struct my_work, work);

    pr_info("handler running on CPU %d, pid %d (%s), data: %s\n",
            smp_processor_id(), current->pid, current->comm, mw->data);
}

static int __init test_wq_init(void)
{
    pr_info("queueing from CPU %d\n", smp_processor_id());
    INIT_WORK(&deferred_work.work, work_fn);
    strscpy(deferred_work.data, "hello from wq");

    if (queue_work_on(cpu, system_wq, &deferred_work.work))
        pr_info("work queued on CPU %d\n", cpu);
    else
        pr_err("work queuing failed\n");

    return 0;
}

static void __exit test_wq_exit(void)
{
    cancel_work_sync(&deferred_work.work);
}

module_init(test_wq_init);
module_exit(test_wq_exit);
```

Load with `insmod hello.ko cpu=3` and check `dmesg`:

```
[  42.001] queueing from CPU 0
[  42.002] work queued on CPU 3
[  42.003] handler running on CPU 3, pid 85 (kworker/3:1), data: hello from wq
```

The `kworker/3:1` name confirms the handler ran on CPU 3's normal-priority pool, worker ID 1. The `queue_work_on()` call forced the work item to CPU 3's per-CPU pwq regardless of which CPU the module was loaded from. Note: `system_wq` is a per-CPU workqueue (`WQ_PERCPU | __WQ_DEPRECATED`), so `queue_work_on(cpu, system_wq, ...)` targets that CPU's normal pool directly.

---

## The Internal Queueing Path: __queue_work()

**`__queue_work()`** at [kernel/workqueue.c, lines 2275–2411](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L2275-L2411) is the heart of the queueing logic. It determines the target pool, handles the non-reentrance guarantee, and inserts the work item.

The flow is:

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  __queue_work() Internal Flow                                                   │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  1. DETERMINE CPU                                                               │
 │     ● If cpu == WORK_CPU_UNBOUND:                                               │
 │       - For WQ_UNBOUND: call wq_select_unbound_cpu() to pick a CPU              │
 │       - For WQ_PERCPU: use raw_smp_processor_id() (current CPU)                 │
 │                                                                                 │
 │  2. FIND THE pwq AND pool                                                       │
 │     ● pwq = rcu_dereference(*per_cpu_ptr(wq->cpu_pwq, cpu))                     │
 │     ● pool = pwq->pool                                                          │
 │                                                                                 │
 │  3. NON-REENTRANCE CHECK                                                        │
 │     ● Get last_pool = pool where this work item was last executed               │
 │     ● If last_pool != current pool AND work is still running on last_pool:      │
 │       → Queue on last_pool instead (to prevent concurrent execution)            │
 │     ● Exception: ordered workqueues skip this (ordering guarantees exclusion)   │
 │                                                                                 │
 │  4. LOCK THE POOL                                                               │
 │     ● raw_spin_lock(&pool->lock)                                                │
 │                                                                                 │
 │  5. INSERT THE WORK                                                             │
 │     ● If pwq->nr_active < max_active:                                           │
 │       → insert_work(pwq, work, &pool->worklist)  ← active                       │
 │       → kick_pool(pool) to wake an idle worker                                  │
 │     ● Else:                                                                     │
 │       → insert_work(pwq, work, &pwq->inactive_works)  ← inactive                │
 │       → Mark work with WORK_STRUCT_INACTIVE                                     │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

Key excerpt from the function showing the non-reentrance logic at [kernel/workqueue.c, lines 2343–2362](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L2343-L2362):

```c
last_pool = get_work_pool(work);
if (last_pool && last_pool != pool && !(wq->flags & __WQ_ORDERED)) {
    struct worker *worker;

    raw_spin_lock(&last_pool->lock);

    worker = find_worker_executing_work(last_pool, work);

    if (worker && worker->current_pwq->wq == wq) {
        pwq = worker->current_pwq;
        pool = pwq->pool;
    } else {
        /* not running there, queue here */
        raw_spin_unlock(&last_pool->lock);
        raw_spin_lock(&pool->lock);
    }
}
```

This guarantees that if a work item is re-queued while it is still executing on a different pool, it will be queued on the **same pool** where it is currently running. This prevents the same work item's function from running on two CPUs simultaneously — the workqueue's **non-reentrance guarantee**.

---

## How the Target Worker Pool Is Determined

When a work item is queued, the target worker pool is selected based on the workqueue type and the CPU:

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  Worker Pool Selection                                                          │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  queue_work(wq, &work)    →  cpu = WORK_CPU_UNBOUND                             │
 │                                                                                 │
 │  Is wq WQ_UNBOUND?                                                              │
 │    YES → cpu = wq_select_unbound_cpu(raw_smp_processor_id())                    │
 │          Prefers local CPU if in wq_unbound_cpumask,                            │
 │          otherwise round-robin among allowed CPUs                               │
 │    NO  → cpu = raw_smp_processor_id()   (queue on current CPU)                  │
 │                                                                                 │
 │  Then:  pwq = per_cpu_ptr(wq->cpu_pwq, cpu)                                     │
 │         pool = pwq->pool                                                        │
 │                                                                                 │
 │  For per-CPU workqueues:                                                        │
 │    pool is one of the two per-CPU pools (normal or highpri)                     │
 │  For unbound workqueues:                                                        │
 │    pool is a dynamically created unbound pool for the pod/node                  │
 │                                                                                 │
 │  queue_work_on(cpu, wq, &work)  →  forces a specific CPU                        │
 │    The pwq lookup is done with the specified cpu                                │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

The `wq_select_unbound_cpu()` function at [kernel/workqueue.c, lines 2255–2273](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L2255-L2273) tries to use the local CPU if it is in the allowed cpumask; otherwise it round-robins among allowed CPUs using a per-CPU `wq_rr_cpu_last` counter.

---

## How Priority Is Determined: Normal vs High Priority Worker Pool

Each CPU has **two** worker pools: normal priority (`nice = 0`) and high priority (`nice = MIN_NICE = -20`). Which pool a work item ends up in depends on the workqueue's **`WQ_HIGHPRI`** flag.

When a workqueue is created with `WQ_HIGHPRI`, its per-CPU pwqs point to the **high priority** worker pool. When created without `WQ_HIGHPRI`, they point to the **normal priority** pool. This mapping is established in `alloc_and_link_pwqs()` during workqueue creation.

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  Priority Pool Selection                                                        │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  alloc_workqueue("my_wq", WQ_PERCPU, 0)                                         │
 │    → pwq->pool = per-CPU normal pool (nice = 0)                                 │
 │    → Workers run at normal scheduler priority                                   │
 │                                                                                 │
 │  alloc_workqueue("my_wq", WQ_HIGHPRI | WQ_PERCPU, 0)                            │
 │    → pwq->pool = per-CPU high-priority pool (nice = -20)                        │
 │    → Workers run at highest priority (MIN_NICE)                                 │
 │    → Work items execute before normal-priority work on the same CPU             │
 │                                                                                 │
 │  The scheduler decides which kworker runs first:                                │
 │    kworker/0:H0 (nice=-20) will be scheduled before                             │
 │    kworker/0:0  (nice=0)   when both have pending work                          │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

---

## What Happens If You Queue the Same Work Twice?

If you call `queue_work()` (or `schedule_work()`) on a work item that is **already pending**, the call **fails silently and returns `false`**. The work item is **not** queued a second time.

The mechanism is the **`WORK_STRUCT_PENDING_BIT`** (bit 0 of `work->data`). In `queue_work_on()` at [kernel/workqueue.c, lines 2448–2454](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L2448-L2454):

```c
if (!test_and_set_bit(WORK_STRUCT_PENDING_BIT, work_data_bits(work)) &&
    !clear_pending_if_disabled(work)) {
    __queue_work(cpu, wq, work);
    ret = true;
}
```

**`test_and_set_bit()`** is an atomic operation. On AArch64, it compiles to an `LDXR`/`STXR` (load-exclusive/store-exclusive) loop that atomically reads the current value of bit 0, sets it, and returns the old value. If the old value was already 1 (PENDING), the `test_and_set_bit()` returns `true`, the `if` condition fails, and `__queue_work()` is never called.

The `PENDING` bit is cleared later by `set_work_pool_and_clear_pending()` inside `process_one_work()` — **just before** the work handler function is called. This means:

- While the work is queued and waiting: `PENDING = 1` → re-queueing fails
- While the work handler is executing: `PENDING = 0` → re-queueing succeeds (the work can be queued again even while its handler runs on a different invocation)

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  PENDING Bit Lifecycle                                                          │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  queue_work()                                                                   │
 │    test_and_set_bit(PENDING) ─── was 0? ──→ set to 1, call __queue_work()       │
 │                               └─ was 1? ──→ return false (already queued)       │
 │                                                                                 │
 │       ─── time passes, worker picks up work ───                                 │
 │                                                                                 │
 │  process_one_work()                                                             │
 │    set_work_pool_and_clear_pending() ─── clears PENDING bit (bit 0 → 0)         │
 │    worker->current_func(work)        ─── calls the handler                      │
 │                                                                                 │
 │       ─── during handler execution, PENDING is 0 ───                            │
 │       ─── re-queueing with queue_work() is now possible ───                     │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

### Example: Attempting to Queue the Same Work Twice

This module calls `queue_work()` twice on the same work item without waiting. The second call fails because the PENDING bit is already set:

```c
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/workqueue.h>

MODULE_LICENSE("GPL");

static struct work_struct work;

static void work_fn(struct work_struct *work)
{
    pr_info("handler executed on CPU %d\n", smp_processor_id());
}

static int __init test_wq_init(void)
{
    INIT_WORK(&work, work_fn);

    if (queue_work(system_wq, &work))
        pr_info("first queue_work: success (PENDING was 0, now 1)\n");
    else
        pr_info("first queue_work: failed\n");

    if (queue_work(system_wq, &work))
        pr_info("second queue_work: success\n");
    else
        pr_info("second queue_work: failed (PENDING already 1)\n");

    return 0;
}

static void __exit test_wq_exit(void)
{
    cancel_work_sync(&work);
}

module_init(test_wq_init);
module_exit(test_wq_exit);
```

Expected `dmesg` output:

```
[  10.001] first queue_work: success (PENDING was 0, now 1)
[  10.002] second queue_work: failed (PENDING already 1)
[  10.003] handler executed on CPU 0
```

The handler runs only once. The second `queue_work()` returns `false` because `test_and_set_bit(WORK_STRUCT_PENDING_BIT)` found the bit already set by the first call. This is the kernel's protection against duplicate queueing — not an error, just a no-op. The work item can be re-queued after the handler runs (PENDING is cleared by `process_one_work()` before calling the handler).

---

## What Happens When You Create Work vs When You Queue Work

**Creating work** (`INIT_WORK` or `DECLARE_WORK`) does nothing but initialize the `work_struct` fields — no threads are spawned, no data structures are modified, no locks are taken:

```c
/* INIT_WORK just sets three fields: */
(_work)->data = (atomic_long_t) WORK_DATA_INIT();   /* pool=NONE, PENDING=0 */
INIT_LIST_HEAD(&(_work)->entry);                     /* empty list */
(_work)->func = (_func);                             /* handler function */
```

**Queueing work** (`queue_work()`, `schedule_work()`) is where the actual mechanism engages:

1. **`local_irq_save()`** — disable local interrupts
2. **`test_and_set_bit(PENDING)`** — atomically claim the work item
3. **`__queue_work()`** — determine the target pool, lock it, and insert the work
4. **`insert_work()`** — link the work into the pool's worklist via `list_add_tail()`
5. **`kick_pool()`** — wake an idle worker to process the work
6. **`local_irq_restore()`** — re-enable interrupts

The idle worker wakes up in `worker_thread()`, finds the work on `pool->worklist`, calls `process_one_work()`, which calls `work->func(work)`.

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  Create Work vs Queue Work — Timeline                                           │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  INIT_WORK(&work, handler)          queue_work(wq, &work)                       │
 │  ─────────────────────              ──────────────────────                      │
 │  │                                  │                                           │
 │  ├ Set data = WORK_DATA_INIT()      ├ local_irq_save()                          │
 │  ├ Set entry = empty list           ├ test_and_set_bit(PENDING)                 │
 │  ├ Set func = handler               ├ __queue_work()                            │
 │  │                                  │   ├ determine target pool                 │
 │  │ Nothing else happens.            │   ├ lock pool                             │
 │  │ No pool, no thread, no lock.     │   ├ insert_work() → list_add_tail         │
 │  │                                  │   └ kick_pool() → wake kworker            │
 │  │ Cost: ~3 stores                  ├ local_irq_restore()                       │
 │  │                                  │                                           │
 │  │                                  │ Cost: atomic op + spinlock + list insert  │
 │  │                                  │       + potential thread wakeup           │
 │  ▼                                  ▼                                           │
 │  work is initialized but            work is on pool->worklist,                  │
 │  dormant — does nothing             kworker will call handler                   │
 │  until queued                                                                   │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

---

## insert_work(): Linking the Work Item to the Pool

**`insert_work()`** at [kernel/workqueue.c, lines 2220–2232](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L2220-L2232) performs the actual linkage:

```c
static void insert_work(struct pool_workqueue *pwq, struct work_struct *work,
                        struct list_head *head, unsigned int extra_flags)
{
    debug_work_activate(work);

    /* record the work call stack in order to print it in KASAN reports */
    kasan_record_aux_stack(work);

    /* we own @work, set data and link */
    set_work_pwq(work, pwq, extra_flags);
    list_add_tail(&work->entry, head);
    get_pwq(pwq);
}
```

`set_work_pwq()` writes the pwq pointer and flags into `work->data` (setting the `WORK_STRUCT_PWQ` bit to indicate that `data` now points to a pwq). `list_add_tail()` appends the work to the tail of either `pool->worklist` (if active) or `pwq->inactive_works` (if the `max_active` limit is reached). `get_pwq()` increments the pwq's reference count to prevent it from being freed while work is in flight.

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  insert_work() — List Linkage                                                   │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  BEFORE insert_work():                                                          │
 │                                                                                 │
 │  pool->worklist ──→ [work_A] ──→ [work_B] ──→ (back to head)                    │
 │                                                                                 │
 │  new_work->data   = old pool ID (off-queue encoding)                            │
 │  new_work->entry  = empty list (points to self)                                 │
 │                                                                                 │
 │  AFTER insert_work(pwq, new_work, &pool->worklist, flags):                      │
 │                                                                                 │
 │  1. set_work_pwq(new_work, pwq, flags)                                          │
 │     → new_work->data = pwq pointer | PENDING | PWQ | color | flags              │
 │                                                                                 │
 │  2. list_add_tail(&new_work->entry, &pool->worklist)                            │
 │     → appends to tail (FIFO order)                                              │
 │                                                                                 │
 │  pool->worklist ──→ [work_A] ──→ [work_B] ──→ [new_work] ──→ (back to head)     │
 │                      ▲                                                          │
 │                      │                                                          │
 │                      worker picks from HEAD (first in, first out)               │
 │                                                                                 │
 │  3. get_pwq(pwq)                                                                │
 │     → pwq->refcnt++ (prevents pwq teardown while work is in flight)             │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

---

## schedule_work() and schedule_work_on()

**`schedule_work()`** and **`schedule_work_on()`** are convenience wrappers that queue work on the **system per-CPU workqueue** (`system_percpu_wq`). Defined at [include/linux/workqueue.h, lines 758–761](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/workqueue.h#L758-L761) and [lines 739–742](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/workqueue.h#L739-L742):

```c
static inline bool schedule_work(struct work_struct *work)
{
    return queue_work(system_percpu_wq, work);
}

static inline bool schedule_work_on(int cpu, struct work_struct *work)
{
    return queue_work_on(cpu, system_percpu_wq, work);
}
```

**`schedule_work(&work)`** is equivalent to `queue_work(system_percpu_wq, &work)` — it queues on the default per-CPU system workqueue. The work will execute on the CPU where it was queued (though it may migrate if that CPU goes offline).

**`schedule_work_on(cpu, &work)`** forces the work to run on a specific CPU by calling `queue_work_on()` with that CPU number. This is useful when the work handler needs to access per-CPU data or when you want to ensure locality.

Use `schedule_work()` when your work item is short-lived and doesn't need special workqueue attributes. Use `queue_work()` with your own workqueue when you need specific flags or isolation.

### schedule_work vs queue_work — The Key Difference

Both `schedule_work()` and `queue_work()` end up calling `queue_work_on()` → `__queue_work()` → `insert_work()`. The **only difference** is the target workqueue:

- **`schedule_work(&work)`** = `queue_work(system_percpu_wq, &work)` — uses the global per-CPU system workqueue. Simple, no allocation needed, but shared with all other users of `system_percpu_wq`. If your handler runs for a long time, it delays other work items on the same CPU's pool.

- **`queue_work(wq, &work)`** — uses a workqueue you specify. This could be `system_highpri_wq` (for priority), `system_long_wq` (flagged `WQ_CPU_INTENSIVE` so long-running handlers don't block concurrency management), `system_dfl_wq` (unbound, for CPU-agnostic work), or a custom workqueue created with `alloc_workqueue()`.

The work handler executes in the same way regardless — both run in process context via a kworker thread. The choice only affects **which pool** the work lands in (which determines priority, CPU binding, and concurrency accounting) and whether your work items share `max_active` limits with other subsystems.

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  schedule_work() vs queue_work() — Decision Guide                               │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  Need to defer work to process context?                                         │
 │    │                                                                            │
 │    ├── Short-lived, no special requirements?                                    │
 │    │     → schedule_work(&work)                                                 │
 │    │       Uses system_percpu_wq, current CPU, normal priority                  │
 │    │                                                                            │
 │    ├── Need a specific CPU?                                                     │
 │    │     → schedule_work_on(cpu, &work)                                         │
 │    │       Still uses system_percpu_wq                                          │
 │    │                                                                            │
 │    ├── Need high priority?                                                      │
 │    │     → queue_work(system_highpri_wq, &work)                                 │
 │    │                                                                            │
 │    ├── Long-running work?                                                       │
 │    │     → queue_work(system_long_wq, &work)                                    │
 │    │                                                                            │
 │    ├── Need CPU-unbound execution?                                              │
 │    │     → queue_work(system_dfl_wq, &work)                                     │
 │    │                                                                            │
 │    └── Need isolation / custom flags / max_active control?                      │
 │          → alloc_workqueue() + queue_work(my_wq, &work)                         │
 │            (See Part 6b for custom workqueue creation)                          │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

### Example: Multiple Work Items Sharing the Same Handler (FIFO Order)

Two separate `work_struct` instances can use the same handler function. Each carries its own private data via `container_of()`. They execute in FIFO order on the pool's worklist:

```c
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/workqueue.h>
#include <linux/sched.h>

MODULE_LICENSE("GPL");

struct my_work {
    struct work_struct work;
    char data[20];
};

static struct my_work deferred_work1, deferred_work2;

static void work_fn(struct work_struct *work)
{
    struct my_work *mw = container_of(work, struct my_work, work);

    pr_info("CPU %d, pid %d (%s), data: %s\n",
            smp_processor_id(), current->pid, current->comm, mw->data);
}

static int __init test_wq_init(void)
{
    INIT_WORK(&deferred_work1.work, work_fn);
    INIT_WORK(&deferred_work2.work, work_fn);
    strscpy(deferred_work1.data, "first item");
    strscpy(deferred_work2.data, "second item");

    schedule_work(&deferred_work1.work);
    schedule_work(&deferred_work2.work);

    return 0;
}

static void __exit test_wq_exit(void)
{
    cancel_work_sync(&deferred_work1.work);
    cancel_work_sync(&deferred_work2.work);
}

module_init(test_wq_init);
module_exit(test_wq_exit);
```

Expected `dmesg` output:

```
[  15.001] CPU 0, pid 42 (kworker/0:1), data: first item
[  15.002] CPU 0, pid 42 (kworker/0:1), data: second item
```

Both work items are separate `work_struct` instances — each has its own PENDING bit, so both are queued successfully. They share the same handler function, which uses `container_of()` to retrieve the correct private data for each invocation. The items execute in FIFO order because `insert_work()` appends to the **tail** of the worklist via `list_add_tail()`, and the worker picks from the **head** via `list_first_entry()`. Both run on the same kworker because `keep_working()` returns `true` (the worker processes the second item without sleeping, since `nr_running` is still 1).

---

## How to Pass Private Data to a Work Function

The work function signature is `void (*)(struct work_struct *work)` — it receives a pointer to the `work_struct`, not a generic data pointer. To pass private data, **embed the `work_struct` inside your own structure** and use `container_of()` (or the workqueue-specific `from_work()` macro) to recover the enclosing structure:

```c
struct my_device {
    struct pci_dev *pdev;
    void __iomem *regs;
    int irq_status;
    struct work_struct irq_work;       /* embedded work_struct */
};

static void my_work_handler(struct work_struct *work)
{
    /* Recover the enclosing my_device from the work_struct pointer */
    struct my_device *dev = container_of(work, struct my_device, irq_work);

    /* Now access private data freely */
    pr_info("Processing IRQ status: %d\n", dev->irq_status);
    iowrite32(0, dev->regs + IRQ_ACK);
}
```

The `from_work()` macro at [include/linux/workqueue.h, lines 610–611](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/workqueue.h#L610-L611) provides a type-safe alternative:

```c
#define from_work(var, callback_work, work_fieldname)  \
    container_of(callback_work, typeof(*var), work_fieldname)
```

Used as:

```c
static void my_work_handler(struct work_struct *work)
{
    struct my_device *dev = from_work(dev, work, irq_work);
    /* ... */
}
```

---

## container_of in the Linux Kernel

**`container_of()`** is one of the most heavily used macros in the Linux kernel. It takes a pointer to a member of a structure and calculates the pointer to the enclosing structure. Defined at [include/linux/container_of.h, lines 19–24](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/container_of.h#L19-L24):

```c
#define container_of(ptr, type, member) ({                  \
    void *__mptr = (void *)(ptr);                           \
    static_assert(__same_type(*(ptr), ((type *)0)->member) || \
                  __same_type(*(ptr), void),                 \
                  "pointer type mismatch in container_of()"); \
    ((type *)(__mptr - offsetof(type, member))); })
```

The math is simple: subtract the offset of the member from the member's address to get the start of the enclosing structure.

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  container_of() — How It Works                                                  │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  struct my_device {                                                             │
 │      struct pci_dev *pdev;        /* offset 0  */                               │
 │      void __iomem *regs;          /* offset 8  */                               │
 │      int irq_status;              /* offset 16 */                               │
 │      struct work_struct irq_work; /* offset 24 */   ← ptr points here           │
 │  };                                                                             │
 │                                                                                 │
 │  container_of(ptr, struct my_device, irq_work)                                  │
 │                                                                                 │
 │  = (struct my_device *)(ptr - offsetof(struct my_device, irq_work))             │
 │  = (struct my_device *)(ptr - 24)                                               │
 │  = pointer to the beginning of my_device                                        │
 │                                                                                 │
 │  Memory layout:                                                                 │
 │  ┌────────┬────────┬────────────┬─────────────────┐                             │
 │  │ pdev   │ regs   │ irq_status │ irq_work        │                             │
 │  └────────┴────────┴────────────┴─────────────────┘                             │
 │  ▲                                ▲                                             │
 │  │                                │                                             │
 │  result (ptr - 24)                ptr (passed to work handler)                  │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

The `static_assert` ensures at compile time that the pointer type matches the member type — a compile error is generated if you pass the wrong pointer or member name.

For new code, **`container_of_const()`** at [include/linux/container_of.h, lines 35–39](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/container_of.h#L35-L39) is preferred because it preserves const-ness using `_Generic`.

---

## The Worker Thread Function: worker_thread()

Every kworker thread runs the **`worker_thread()`** function at [kernel/workqueue.c, lines 3431–3503](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L3431-L3503). This is the main execution loop:

```c
static int worker_thread(void *__worker)
{
    struct worker *worker = __worker;
    struct worker_pool *pool = worker->pool;

    /* tell the scheduler that this is a workqueue worker */
    set_pf_worker(true);
woke_up:
    raw_spin_lock_irq(&pool->lock);

    /* am I supposed to die? */
    if (unlikely(worker->flags & WORKER_DIE)) {
        raw_spin_unlock_irq(&pool->lock);
        set_pf_worker(false);
        worker->pool = NULL;
        ida_free(&pool->worker_ida, worker->id);
        return 0;
    }

    worker_leave_idle(worker);
recheck:
    /* no more worker necessary? */
    if (!need_more_worker(pool))
        goto sleep;

    /* do we need to manage? */
    if (unlikely(!may_start_working(pool)) && manage_workers(worker))
        goto recheck;

    worker_clr_flags(worker, WORKER_PREP | WORKER_REBOUND);

    do {
        struct work_struct *work =
            list_first_entry(&pool->worklist,
                             struct work_struct, entry);

        if (assign_work(work, worker, NULL))
            process_scheduled_works(worker);
    } while (keep_working(pool));

    worker_set_flags(worker, WORKER_PREP);
sleep:
    worker_enter_idle(worker);
    __set_current_state(TASK_IDLE);
    raw_spin_unlock_irq(&pool->lock);
    schedule();
    goto woke_up;
}
```

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  worker_thread() Main Loop                                                      │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  woke_up:                                                                       │
 │    ├── Lock pool                                                                │
 │    ├── Check WORKER_DIE flag → exit if set                                      │
 │    ├── Leave idle state                                                         │
 │    │                                                                            │
 │  recheck:                                                                       │
 │    ├── need_more_worker(pool)?                                                  │
 │    │     = !list_empty(&pool->worklist) && !pool->nr_running                    │
 │    │     NO  → goto sleep                                                       │
 │    │     YES → continue                                                         │
 │    │                                                                            │
 │    ├── may_start_working(pool)?                                                 │
 │    │     = pool->nr_idle > 0                                                    │
 │    │     NO  → manage_workers() (create new workers)                            │
 │    │                                                                            │
 │    ├── PROCESS WORK LOOP:                                                       │
 │    │     do {                                                                   │
 │    │       work = first entry from pool->worklist                               │
 │    │       assign_work(work, worker)                                            │
 │    │       process_scheduled_works(worker)                                      │
 │    │     } while (keep_working(pool))                                           │
 │    │                                                                            │
 │    │     keep_working(pool) =                                                   │
 │    │       !list_empty(&pool->worklist) && pool->nr_running <= 1                │
 │    │                                                                            │
 │  sleep:                                                                         │
 │    ├── Enter idle state                                                         │
 │    ├── __set_current_state(TASK_IDLE)                                           │
 │    ├── Unlock pool                                                              │
 │    ├── schedule()  ← goes to sleep here                                         │
 │    └── goto woke_up                                                             │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

The concurrency management functions at [kernel/workqueue.c, lines 950–965](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L950-L965) control the loop:

```c
static bool need_more_worker(struct worker_pool *pool)
{
    return !list_empty(&pool->worklist) && !pool->nr_running;
}

static bool may_start_working(struct worker_pool *pool)
{
    return pool->nr_idle;
}

static bool keep_working(struct worker_pool *pool)
{
    return !list_empty(&pool->worklist) && (pool->nr_running <= 1);
}
```

`keep_working()` returns `true` as long as there are pending work items and at most one worker is running. The `nr_running <= 1` check ensures that a worker keeps processing items without creating unnecessary concurrency — only when the worker sleeps (`nr_running` drops to 0) does another worker get woken.

These three functions together implement the pool's concurrency policy:

- **`need_more_worker()`**: "Should any worker wake up?" — Only if there's work AND nobody is running. This prevents thundering herd — if one worker is already processing, don't wake more.
- **`may_start_working()`**: "Is there a safety net?" — Only if there's at least one idle worker left. If `nr_idle == 0`, we must create a new worker before processing work, so that if the current work handler blocks, there's someone to take over.
- **`keep_working()`**: "Should I keep going after finishing one item?" — Only if there's more work AND I'm the sole runner (`nr_running <= 1`). If another worker woke up (perhaps because I blocked mid-item and a replacement was created), I should yield.

The `may_start_working()` check before `manage_workers()` is the key to forward progress. Without it, a pool could reach a state where the only worker is about to call a handler that might sleep, with no idle workers to take over — a potential deadlock if the handler waits for something that requires another work item on the same pool.

---

## Processing a Single Work Item: process_one_work()

**`process_one_work()`** at [kernel/workqueue.c, lines 3220–3380](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L3220-L3380) handles the execution of a single work item. It releases `pool->lock`, calls the work function, and re-acquires the lock:

```c
static void process_one_work(struct worker *worker, struct work_struct *work)
{
    struct pool_workqueue *pwq = get_work_pwq(work);
    struct worker_pool *pool = worker->pool;

    /* claim and dequeue */
    hash_add(pool->busy_hash, &worker->hentry, (unsigned long)work);
    worker->current_work = work;
    worker->current_func = work->func;
    worker->current_pwq = pwq;

    list_del_init(&work->entry);

    /* CPU intensive works don't participate in concurrency management */
    if (unlikely(pwq->wq->flags & WQ_CPU_INTENSIVE))
        worker_set_flags(worker, WORKER_CPU_INTENSIVE);

    /* wake another worker if needed (for UNBOUND and CPU_INTENSIVE) */
    kick_pool(pool);

    /* clear PENDING — the work item is now "running", can be re-queued */
    set_work_pool_and_clear_pending(work, pool->id, pool_offq_flags(pool));

    pwq->stats[PWQ_STAT_STARTED]++;
    raw_spin_unlock_irq(&pool->lock);

    /* ──── EXECUTE THE WORK HANDLER ──── */
    worker->current_func(work);

    /* cond_resched() to prevent hogging CPU on !PREEMPTION kernels */
    if (worker->task)
        cond_resched();

    raw_spin_lock_irq(&pool->lock);

    pwq->stats[PWQ_STAT_COMPLETED]++;
    worker_clr_flags(worker, WORKER_CPU_INTENSIVE);

    /* release */
    hash_del(&worker->hentry);
    worker->current_work = NULL;
    worker->current_func = NULL;
    worker->current_pwq = NULL;

    pwq_dec_nr_in_flight(pwq, work_data);
}
```

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  process_one_work() Execution Flow                                              │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  process_one_work(worker, work)                   [pool->lock HELD]             │
 │    │                                                                            │
 │    ├── hash_add(pool->busy_hash, worker, work)    mark worker as busy           │
 │    ├── worker->current_work = work                                              │
 │    ├── worker->current_func = work->func                                        │
 │    ├── worker->current_pwq  = pwq                                               │
 │    │                                                                            │
 │    ├── list_del_init(&work->entry)                remove from worklist          │
 │    │                                                                            │
 │    ├── WQ_CPU_INTENSIVE?                                                        │
 │    │     YES → worker_set_flags(WORKER_CPU_INTENSIVE)                           │
 │    │           (excluded from nr_running count)                                 │
 │    │                                                                            │
 │    ├── kick_pool(pool)                            wake another worker           │
 │    │                                              if needed                     │
 │    │                                                                            │
 │    ├── set_work_pool_and_clear_pending(work)       ◄── PENDING bit cleared      │
 │    │     (work can now be re-queued!)                   BEFORE handler runs     │
 │    │                                                                            │
 │    ├── raw_spin_unlock_irq(&pool->lock)           ◄── LOCK RELEASED             │
 │    │                                                                            │
 │    │   ╔═══════════════════════════════════════╗                                │
 │    │   ║  worker->current_func(work)           ║   ◄── HANDLER EXECUTES         │
 │    │   ║  (runs in process context, can sleep) ║       with pool lock released  │
 │    │   ╚═══════════════════════════════════════╝                                │
 │    │                                                                            │
 │    ├── cond_resched()                             yield CPU if needed           │
 │    │                                                                            │
 │    ├── raw_spin_lock_irq(&pool->lock)             ◄── LOCK RE-ACQUIRED          │
 │    │                                                                            │
 │    ├── hash_del(&worker->hentry)                  remove from busy_hash         │
 │    ├── worker->current_work = NULL                clear current state           │
 │    ├── worker->current_func = NULL                                              │
 │    ├── worker->current_pwq  = NULL                                              │
 │    │                                                                            │
 │    └── pwq_dec_nr_in_flight(pwq)                  may activate inactive work    │
 │          nr_active-- → if below max_active,                                     │
 │          move work from pwq->inactive_works to pool->worklist                   │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

Key points:

1. The worker is added to `pool->busy_hash` keyed by the work item's address — this is how `find_worker_executing_work()` can find which worker is executing a given work item (used by `__queue_work()` for the non-reentrance check).

2. **`set_work_pool_and_clear_pending()`** clears the `PENDING` bit **before** calling the handler. This design choice is deliberate: it allows the work item to be re-queued from within its own handler (e.g., for periodic work that re-queues itself at the end of each invocation) or from an interrupt handler that fires while the work handler is running. The re-queued instance will run **after** the current handler returns — the non-reentrance check in `__queue_work()` ensures it is queued on the same pool, and `keep_working()` ensures sequential execution.

3. For `WQ_CPU_INTENSIVE` workqueues, the worker is marked `WORKER_CPU_INTENSIVE`, which makes it no longer participate in concurrency management (`WORKER_NOT_RUNNING`). `kick_pool()` then wakes another idle worker to handle other pending work items, ensuring that CPU-intensive work doesn't starve the pool.

4. After the handler returns, `cond_resched()` is called to yield the CPU if needed — this prevents a re-queueing work item from monopolizing the CPU on non-preemptible kernels.

---

## Execution Context: Process Context, Not Interrupt Context

Both the **work handler** and the **worker thread** run in **process context**. This is the fundamental difference between workqueues and softirqs/tasklets:

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  Workqueue Execution Context                                                    │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  Context:         Process context (preempt_count = 0)                           │
 │  IRQs:            ENABLED                                                       │
 │  Sleeping:        ALLOWED — can take mutexes, do blocking I/O                   │
 │  Preemption:      ENABLED (on PREEMPT kernels)                                  │
 │  in_hardirq():    false                                                         │
 │  in_softirq():    false                                                         │
 │  in_task():       true                                                          │
 │  in_interrupt():  false                                                         │
 │  current:         points to the kworker thread's own task_struct                │
 │                                                                                 │
 │  WHAT YOU CAN DO:                                                               │
 │  ● Sleep (schedule())                                                           │
 │  ● Take mutexes (mutex_lock())                                                  │
 │  ● Allocate memory with GFP_KERNEL                                              │
 │  ● Do blocking I/O                                                              │
 │  ● Call any function that is legal in process context                           │
 │                                                                                 │
 │  WHAT YOU SHOULD AVOID:                                                         │
 │  ● Holding spinlocks for long periods (blocks other work items)                 │
 │  ● Very long-running operations on system_percpu_wq (blocks flush)              │
 │  ● Deadlock with your own flush/cancel calls                                    │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

The worker thread sets `PF_WQ_WORKER` in its `task_struct->flags` at the beginning of `worker_thread()` via `set_pf_worker(true)` at [kernel/workqueue.c, line 3437](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L3437). The scheduler checks this flag to hook into the concurrency management (via `wq_worker_running()` and `wq_worker_sleeping()`).

### Example: Verifying Process Context and IRQ State at Runtime

This module proves that workqueue handlers run in process context with IRQs enabled — confirming the theory above with runtime checks:

```c
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/workqueue.h>
#include <linux/sched.h>

MODULE_LICENSE("GPL");

struct my_work {
    struct work_struct work;
    char data[20];
};

static struct my_work deferred_work;

static void work_fn(struct work_struct *work)
{
    struct my_work *mw = container_of(work, struct my_work, work);

    pr_info("data: %s\n", mw->data);
    pr_info("current pid: %d, process: %s\n", current->pid, current->comm);

    if (in_interrupt())
        pr_info("UNEXPECTED: running in interrupt context\n");
    else
        pr_info("running in process context (as expected)\n");

    if (irqs_disabled())
        pr_info("UNEXPECTED: IRQs disabled\n");
    else
        pr_info("IRQs enabled (as expected)\n");

    pr_info("in_task(): %d, in_softirq(): %d, in_hardirq(): %d\n",
            in_task(), in_softirq(), in_hardirq());
}

static int __init test_wq_init(void)
{
    INIT_WORK(&deferred_work.work, work_fn);
    strscpy(deferred_work.data, "context test");
    schedule_work(&deferred_work.work);
    return 0;
}

static void __exit test_wq_exit(void)
{
    cancel_work_sync(&deferred_work.work);
}

module_init(test_wq_init);
module_exit(test_wq_exit);
```

Expected `dmesg` output:

```
[  20.001] data: context test
[  20.002] current pid: 42, process: kworker/0:1
[  20.003] running in process context (as expected)
[  20.004] IRQs enabled (as expected)
[  20.005] in_task(): 1, in_softirq(): 0, in_hardirq(): 0
```

The output confirms: `in_interrupt()` returns `false` (not in interrupt context), `irqs_disabled()` returns `false` (interrupts are enabled), `in_task()` returns `true`, and both `in_softirq()` and `in_hardirq()` return `false`. This is why workqueue handlers can safely call `mutex_lock()`, `kmalloc(GFP_KERNEL)`, `msleep()`, and any other function that requires process context. Compare this with a tasklet handler, where `in_interrupt()` would return `true` and `in_softirq()` would return non-zero.

---

## The Value of current for a Worker Thread

Inside a work handler, **`current`** points to the **kworker thread's own `task_struct`** — not a borrowed reference like in softirq context. The kworker thread has its own PID, its own kernel stack, and its own scheduling state.

```c
static void my_work_handler(struct work_struct *work)
{
    /* current is the kworker thread itself */
    pr_info("Running in process: %s (pid %d)\n",
            current->comm, task_pid_nr(current));
    /* Output: "Running in process: kworker/0:1 (pid 42)" */
}
```

You can verify this by calling `current_wq_worker()` at [kernel/workqueue_internal.h, lines 68–73](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue_internal.h#L68-L73):

```c
static inline struct worker *current_wq_worker(void)
{
    if (in_task() && (current->flags & PF_WQ_WORKER))
        return kthread_data(current);
    return NULL;
}
```

If called from a work handler, this returns a non-NULL pointer to the `struct worker` executing the current work.

---

## A Simple Example Using the System Workqueue

Here is a complete, minimal kernel module that uses the system workqueue to defer work from a timer callback:

```c
#include <linux/module.h>
#include <linux/workqueue.h>
#include <linux/timer.h>
#include <linux/jiffies.h>

struct my_device {
    struct work_struct work;
    int counter;
};

static struct my_device mydev;

static void my_work_handler(struct work_struct *work)
{
    struct my_device *dev = container_of(work, struct my_device, work);

    dev->counter++;
    pr_info("Work handler: counter = %d, pid = %d (%s)\n",
            dev->counter, current->pid, current->comm);
}

static int __init my_init(void)
{
    INIT_WORK(&mydev.work, my_work_handler);
    mydev.counter = 0;

    /* Queue work on the system per-CPU workqueue */
    schedule_work(&mydev.work);

    return 0;
}

static void __exit my_exit(void)
{
    cancel_work_sync(&mydev.work);
}

module_init(my_init);
module_exit(my_exit);
MODULE_LICENSE("GPL");
```

`schedule_work(&mydev.work)` queues the work on `system_percpu_wq`. The handler runs in process context — `current->comm` will print something like `kworker/0:1`. In the module exit function, `cancel_work_sync()` ensures the work item has completed before the module is unloaded.

---

## Enabling and Disabling Work Items

Unlike tasklets (which use a reference-counted `count` field to enable/disable), work items in the modern kernel have **`disable_work()`** and **`enable_work()`** APIs. Defined at [kernel/workqueue.c, lines 4584–4634](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L4584-L4634):

```c
bool disable_work(struct work_struct *work)
{
    return __cancel_work(work, WORK_CANCEL_DISABLE);
}

bool disable_work_sync(struct work_struct *work)
{
    return __cancel_work_sync(work, WORK_CANCEL_DISABLE);
}

bool enable_work(struct work_struct *work)
{
    struct work_offq_data offqd;
    unsigned long irq_flags;

    work_grab_pending(work, 0, &irq_flags);

    work_offqd_unpack(&offqd, *work_data_bits(work));
    work_offqd_enable(&offqd);
    set_work_pool_and_clear_pending(work, offqd.pool_id,
                                    work_offqd_pack_flags(&offqd));
    local_irq_restore(irq_flags);

    return !offqd.disable;
}
```

**`disable_work()`** increments the work item's **disable depth** (a 16-bit counter stored in the off-queue `data` field) and cancels the work if currently pending. While the disable count is non-zero, any call to `queue_work()` on this work item will fail — the `clear_pending_if_disabled()` check in `queue_work_on()` will clear the PENDING bit without actually queueing.

**`disable_work_sync()`** is like `disable_work()` but also waits for the work item to finish if it is currently executing.

**`enable_work()`** decrements the disable depth. When the depth reaches zero, the work can be queued again.

The maximum supported disable depth is 2^16 - 1 = 65535, encoded in `WORK_OFFQ_DISABLE_BITS = 16` at [include/linux/workqueue.h, line 64](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/workqueue.h#L64).

### Delayed Work Disable/Enable Variants

For delayed work items, equivalent APIs exist at [kernel/workqueue.c, lines 4642–4672](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L4642-L4672):

```c
bool disable_delayed_work(struct delayed_work *dwork)
{
    return __cancel_work(&dwork->work,
                         WORK_CANCEL_DELAYED | WORK_CANCEL_DISABLE);
}

bool disable_delayed_work_sync(struct delayed_work *dwork)
{
    return __cancel_work_sync(&dwork->work,
                              WORK_CANCEL_DELAYED | WORK_CANCEL_DISABLE);
}

bool enable_delayed_work(struct delayed_work *dwork)
{
    return enable_work(&dwork->work);
}
```

These mirror the non-delayed variants but also handle the timer cancellation via `WORK_CANCEL_DELAYED`. Use `disable_delayed_work()` / `enable_delayed_work()` instead of `disable_work()` / `enable_work()` when operating on a `delayed_work`.

```
 ┌──────────────────────────────┬───────────────────────────────────────────────┐
 │  API                          │  Description                                 │
 ├──────────────────────────────┼───────────────────────────────────────────────┤
 │  disable_work(&work)          │  Disable + cancel, no wait. Any context.     │
 │  disable_work_sync(&work)     │  Disable + cancel + wait. Sleepable context. │
 │  enable_work(&work)           │  Decrement disable depth. Re-enables at 0.   │
 ├──────────────────────────────┼───────────────────────────────────────────────┤
 │  disable_delayed_work(&dw)    │  Same + handles timer. Any context.          │
 │  disable_delayed_work_sync()  │  Same + handles timer + waits. Sleepable.    │
 │  enable_delayed_work(&dw)     │  Calls enable_work() on embedded work.       │
 └──────────────────────────────┴───────────────────────────────────────────────┘
```

---

## cancel_work_sync(): Cancel and Wait

**`cancel_work_sync()`** at [kernel/workqueue.c, lines 4529–4533](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L4529-L4533) cancels a pending work item **and** waits for it to finish if it is currently executing:

```c
bool cancel_work_sync(struct work_struct *work)
{
    return __cancel_work_sync(work, 0);
}
```

The internal `__cancel_work_sync()` at [kernel/workqueue.c, lines 4478–4500](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L4478-L4500):

```c
static bool __cancel_work_sync(struct work_struct *work, u32 cflags)
{
    bool ret;

    ret = __cancel_work(work, cflags | WORK_CANCEL_DISABLE);

    if (*work_data_bits(work) & WORK_OFFQ_BH)
        WARN_ON_ONCE(in_hardirq());
    else
        might_sleep();

    /* wait for the work to finish if currently executing */
    if (wq_online)
        __flush_work(work, true);

    if (!(cflags & WORK_CANCEL_DISABLE))
        enable_work(work);

    return ret;
}
```

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  cancel_work_sync() Flow                                                        │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  cancel_work_sync(&work)                                                        │
 │    │                                                                            │
 │    └── __cancel_work_sync(&work, 0)                                             │
 │          │                                                                      │
 │          ├── __cancel_work(&work, WORK_CANCEL_DISABLE)                          │
 │          │     │                                                                │
 │          │     ├── work_grab_pending(&work)                                     │
 │          │     │     ├── test_and_set_bit(PENDING)                              │
 │          │     │     │     was 1 → work was pending, dequeue it                 │
 │          │     │     │     was 0 → work was not pending                         │
 │          │     │     └── returns: true if was pending                           │
 │          │     │                                                                │
 │          │     └── increment disable depth (prevents re-queueing during wait)   │
 │          │                                                                      │
 │          ├── might_sleep()                   ← enforces process context         │
 │          │                                                                      │
 │          ├── wq_online?                                                         │
 │          │     YES → __flush_work(&work, true)                                  │
 │          │           ├── work currently executing?                              │
 │          │           │     YES → insert barrier, sleep until handler finishes   │
 │          │           │     NO  → return immediately                             │
 │          │           └── guaranteed: handler is done on return                  │
 │          │                                                                      │
 │          ├── enable_work(&work)              ← re-enable (decrement disable)    │
 │          │                                                                      │
 │          └── return: true if work was pending, false if already idle            │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

The function first grabs the PENDING bit (which dequeues the work if it was pending), then calls `__flush_work()` to wait for any currently-executing instance to complete. It temporarily disables the work (to prevent re-queueing during the wait) and then re-enables it before returning.

**Return value:** `true` if the work was pending (was actually canceled), `false` if it was already idle.

**Context requirement:** Must be called from a sleepable context (process context). It calls `might_sleep()` to enforce this.

**Important:** `cancel_work_sync(&delayed_work->work)` must **not** be used for `delayed_work` — use `cancel_delayed_work_sync()` instead, which handles the timer as well.

### When to Use cancel_work_sync vs flush_work

The choice between these two APIs depends on your intent:

- **`cancel_work_sync()`** — Use in **teardown paths** (module exit, device removal, error cleanup). The intent is "stop this work and make sure it's done." After `cancel_work_sync()` returns, the work will not execute — if it was pending, it was dequeued; if it was running, it finished. It is safe to free the `work_struct` (and its containing structure) immediately after this call.

- **`flush_work()`** — Use when you need **ordering** ("wait for this work to finish, then proceed"). The intent is "let it finish, I need its result." If the work is pending, `flush_work()` waits for it to execute AND complete. It does **not** prevent the work from being re-queued. Typical use: a driver queues a firmware load via a work item, then calls `flush_work()` before using the firmware.

- **Neither** — If you just need to know whether work is pending, use `work_pending(&work)` (checks the PENDING bit). If you need to disable a work item temporarily without canceling it, use `disable_work()`/`enable_work()`.

A common anti-pattern is calling `flush_work()` in module exit instead of `cancel_work_sync()`. If the work re-queues itself (periodic pattern), `flush_work()` only waits for the current instance — the work will re-queue during the handler and execute again after `flush_work()` returns. `cancel_work_sync()` avoids this because it temporarily disables the work during the wait.

### Example: cancel_work_sync() Waiting for a Long-Running Handler

This module demonstrates that `cancel_work_sync()` **blocks until a running handler completes**. The handler sleeps for 10 seconds — if you `rmmod` during that window, the module exit function blocks inside `cancel_work_sync()` until the sleep finishes:

```c
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/workqueue.h>
#include <linux/sched.h>
#include <linux/delay.h>

MODULE_LICENSE("GPL");

struct my_work {
    struct work_struct work;
    char data[20];
};

static struct my_work deferred_work;

static void work_fn(struct work_struct *work)
{
    struct my_work *mw = container_of(work, struct my_work, work);

    pr_info("handler start on CPU %d (%s), data: %s\n",
            smp_processor_id(), current->comm, mw->data);
    msleep(10000);
    pr_info("handler done after 10s sleep\n");
}

static int __init test_wq_init(void)
{
    INIT_WORK(&deferred_work.work, work_fn);
    strscpy(deferred_work.data, "long work");
    schedule_work(&deferred_work.work);
    pr_info("work queued, module loaded\n");
    return 0;
}

static void __exit test_wq_exit(void)
{
    pr_info("exit: calling cancel_work_sync (will block if handler is running)...\n");
    if (cancel_work_sync(&deferred_work.work))
        pr_info("exit: work was pending, cancelled before execution\n");
    else
        pr_info("exit: work was not pending (already ran or currently running)\n");
    pr_info("exit: cancel_work_sync returned, safe to unload\n");
}

module_init(test_wq_init);
module_exit(test_wq_exit);
```

If you `rmmod` within 10 seconds of `insmod`, the `rmmod` command hangs until the handler finishes:

```
[  50.001] work queued, module loaded
[  50.002] handler start on CPU 0 (kworker/0:1), data: long work
                  ← rmmod issued at ~52s, shell blocks here
[  60.002] handler done after 10s sleep
[  60.003] exit: calling cancel_work_sync (will block if handler is running)...
[  60.003] exit: work was not pending (already ran or currently running)
[  60.003] exit: cancel_work_sync returned, safe to unload
```

This is the correct pattern for module cleanup. `cancel_work_sync()` returns `false` because the work was not **pending** (it was already executing, not waiting in the worklist). Internally, `cancel_work_sync()` calls `__flush_work()` which inserts a barrier work item after the currently-executing item and sleeps until the barrier completes. Without `cancel_work_sync()` in the exit function, `rmmod` would free the module's code and data while the handler is still accessing `deferred_work.data` — a use-after-free crash.

---

## flush_work(): Wait for Completion

**`flush_work()`** at [kernel/workqueue.c, lines 4392–4397](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L4392-L4397) waits for a work item to finish executing:

```c
bool flush_work(struct work_struct *work)
{
    might_sleep();
    return __flush_work(work, false);
}
```

Unlike `cancel_work_sync()`, `flush_work()` does **not** dequeue the work item. If the work is pending (queued but not yet executing), `flush_work()` waits for it to be executed and complete. If the work is currently executing, it waits for that execution to finish.

**Return value:** `true` if it waited for the work to finish, `false` if the work was already idle (neither pending nor executing).

**Note:** If the work is re-queued while `flush_work()` is waiting, the flush only guarantees completion of the instance that was pending at the time of the call.

```
 ┌──────────────────────────────────┬──────────────────────────────────────────────┐
 │  flush_work()                    │  cancel_work_sync()                          │
 ├──────────────────────────────────┼──────────────────────────────────────────────┤
 │  Waits for execution             │  Dequeues + waits for execution              │
 │  Does NOT dequeue pending work   │  Dequeues pending work                       │
 │  Work will still execute         │  Work will NOT execute (if pending)          │
 │  Returns true if waited          │  Returns true if was pending                 │
 │  Sleepable context required      │  Sleepable context required                  │
 │  Use: "let it finish"            │  Use: "stop it now" (module exit)            │
 └──────────────────────────────────┴──────────────────────────────────────────────┘
```

### Example: Using flush_work() to Synchronize Before Proceeding

This module queues two work items and calls `flush_work()` on the second one to ensure both complete before `module_init` finishes. Unlike `cancel_work_sync()`, `flush_work()` does not dequeue — it waits for the work to execute and finish:

```c
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/workqueue.h>
#include <linux/sched.h>

MODULE_LICENSE("GPL");

struct my_work {
    struct work_struct work;
    char data[20];
};

static struct my_work deferred_work1, deferred_work2;

static void work_fn(struct work_struct *work)
{
    struct my_work *mw = container_of(work, struct my_work, work);

    pr_info("CPU %d (%s): %s\n",
            smp_processor_id(), current->comm, mw->data);
}

static int __init test_wq_init(void)
{
    INIT_WORK(&deferred_work1.work, work_fn);
    INIT_WORK(&deferred_work2.work, work_fn);
    strscpy(deferred_work1.data, "first item");
    strscpy(deferred_work2.data, "second item");

    schedule_work(&deferred_work1.work);
    schedule_work(&deferred_work2.work);

    if (flush_work(&deferred_work2.work))
        pr_info("flush_work returned true: waited for work2 to finish\n");
    else
        pr_info("flush_work returned false: work2 was already idle\n");

    pr_info("init complete — both work items are done\n");
    return 0;
}

static void __exit test_wq_exit(void)
{
    cancel_work_sync(&deferred_work1.work);
    cancel_work_sync(&deferred_work2.work);
}

module_init(test_wq_init);
module_exit(test_wq_exit);
```

Expected `dmesg` output:

```
[  30.001] CPU 0 (kworker/0:1): first item
[  30.002] CPU 0 (kworker/0:1): second item
[  30.003] flush_work returned true: waited for work2 to finish
[  30.004] init complete — both work items are done
```

`flush_work(&deferred_work2.work)` blocks the `module_init` thread until the second work item finishes. Since work items execute in FIFO order on the same pool, by the time work2 finishes, work1 has already finished too. `flush_work()` returns `true` because it actually waited (the work was still pending or executing when `flush_work()` was called). Use this pattern when you need ordering — "do X, then do Y after X finishes" — rather than cleanup.

---

## Complete Work Item Lifecycle

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  Work Item Lifecycle — End-to-End                                               │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  1. INIT                                                                        │
 │     INIT_WORK(&dev->work, handler)                                              │
 │     → data=0, entry=empty, func=handler                                         │
 │     → PENDING = 0                                                               │
 │                                                                                 │
 │  2. QUEUE                                                                       │
 │     schedule_work(&dev->work) / queue_work(wq, &dev->work)                      │
 │     → PENDING = 1 (atomic test-and-set)                                         │
 │     → data = pwq pointer | flags                                                │
 │     → entry linked into pool->worklist                                          │
 │     → kick_pool() wakes idle kworker                                            │
 │                                                                                 │
 │  3. WAIT                                                                        │
 │     work sits on pool->worklist until a kworker picks it up                     │
 │     (FIFO order within the pool)                                                │
 │                                                                                 │
 │  4. EXECUTE                                                                     │
 │     process_one_work():                                                         │
 │     → worker added to busy_hash                                                 │
 │     → work removed from worklist                                                │
 │     → PENDING = 0 (cleared BEFORE handler call)                                 │
 │     → pool lock released                                                        │
 │     → handler(work) called in process context                                   │
 │     → handler can re-queue this work (PENDING is 0)                             │
 │     → pool lock re-acquired                                                     │
 │     → worker removed from busy_hash                                             │
 │     → pwq_dec_nr_in_flight() may activate inactive work                         │
 │                                                                                 │
 │  5. IDLE                                                                        │
 │     work_struct is dormant again                                                │
 │     → data = pool ID (off-queue encoding)                                       │
 │     → PENDING = 0                                                               │
 │     → can be re-queued with queue_work()                                        │
 │                                                                                 │
 │  6. CLEANUP (module exit)                                                       │
 │     cancel_work_sync(&dev->work)                                                │
 │     → dequeues if pending, waits if executing                                   │
 │     → safe to free the containing structure after this returns                  │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

---

## End-to-End Under the Hood: From INIT_WORK to Handler Execution

This section traces the **complete internal path** of a work item through the workqueue subsystem — from creation, through queueing with per-CPU pwq lookup, to execution by a kworker. Every function call, every data structure access, every lock acquisition.

### Phase 1: Creating the Work Item — INIT_WORK

```c
INIT_WORK(&dev->work, my_handler);
```

This is a **pure initialization** — no locks, no allocations, no scheduling. The macro at [include/linux/workqueue.h, lines 269–275](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/workqueue.h#L269-L275) expands to three stores:

```c
(_work)->data = (atomic_long_t) WORK_DATA_INIT();
    /* = WORK_STRUCT_NO_POOL (0xFFFFFFE0) | PENDING=0 */
INIT_LIST_HEAD(&(_work)->entry);
    /* = entry.next = entry.prev = &entry  (empty circular list) */
(_work)->func = (_func);
    /* = pointer to the handler function */
```

After `INIT_WORK`, the work item is **dormant** — it exists in memory but is not associated with any workqueue, pool, or worker. The `WORK_STRUCT_NO_POOL` sentinel in the `data` field indicates "not queued anywhere." The `PENDING` bit (bit 0) is `0`, meaning `queue_work()` will accept it.

### Phase 2: Queueing the Work — queue_work() Under the Hood

```c
queue_work(wq, &dev->work);       /* or: schedule_work(&dev->work) */
```

The full internal call chain:

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  QUEUEING PATH — Complete Internal Trace                                        │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  ① queue_work(wq, &work)                                                        │
 │     │  [include/linux/workqueue.h]                                              │
 │     │  Calls queue_work_on(WORK_CPU_UNBOUND, wq, &work)                         │
 │     │  WORK_CPU_UNBOUND = NR_CPUS (special value meaning "pick CPU for me")     │
 │     │                                                                           │
 │  ② queue_work_on(cpu, wq, &work)                                                │
 │     │  [kernel/workqueue.c, lines 2448-2454]                                    │
 │     │                                                                           │
 │     ├── local_irq_save(flags)                                                   │
 │     │     → Disables local IRQs, saves IRQ state                                │
 │     │     → Prevents this CPU from being interrupted mid-queue                  │
 │     │                                                                           │
 │     ├── test_and_set_bit(WORK_STRUCT_PENDING_BIT, work_data_bits(work))         │
 │     │     → ATOMIC operation (LDXR/STXR on ARM64, LOCK BTS on x86)             │
 │     │     → Returns OLD value of bit 0:                                         │
 │     │       was 0 → set to 1, proceed (work was idle)                           │
 │     │       was 1 → return false (work already queued, bail out)                │
 │     │                                                                           │
 │     ├── clear_pending_if_disabled(work)                                         │
 │     │     → If work has disable depth > 0, clear PENDING and abort              │
 │     │                                                                           │
 │     ├── __queue_work(cpu, wq, &work)    ← THE REAL WORK                         │
 │     │                                                                           │
 │     └── local_irq_restore(flags)                                                │
 │           → Re-enables IRQs                                                     │
 │                                                                                 │
 │  ③ __queue_work(cpu, wq, &work)                                                 │
 │     │  [kernel/workqueue.c, lines 2359-2430]                                    │
 │     │                                                                           │
 │     │  ┌─────────────────────────────────────────────────────────────┐           │
 │     │  │  STEP A: Determine the CPU                                 │           │
 │     │  ├─────────────────────────────────────────────────────────────┤           │
 │     │  │                                                            │           │
 │     │  │  if (cpu == WORK_CPU_UNBOUND) {                            │           │
 │     │  │      if (wq->flags & WQ_UNBOUND)                           │           │
 │     │  │          cpu = wq_select_unbound_cpu(raw_smp_processor_id) │           │
 │     │  │      else                                                  │           │
 │     │  │          cpu = raw_smp_processor_id()  ← CURRENT CPU       │           │
 │     │  │  }                                                         │           │
 │     │  └─────────────────────────────────────────────────────────────┘           │
 │     │                                                                           │
 │     │  ┌─────────────────────────────────────────────────────────────┐           │
 │     │  │  STEP B: Look up the per-CPU pool_workqueue (pwq)          │           │
 │     │  ├─────────────────────────────────────────────────────────────┤           │
 │     │  │                                                            │           │
 │     │  │  pwq = per_cpu_ptr(wq->cpu_pwq, cpu)                       │           │
 │     │  │                                                            │           │
 │     │  │  This is THE key lookup. wq->cpu_pwq is a per-CPU          │           │
 │     │  │  pointer that was set up when the workqueue was created.   │           │
 │     │  │  Each CPU's pwq points to the correct worker_pool:        │           │
 │     │  │    - Per-CPU normal wq → per-CPU normal pool (nice=0)     │           │
 │     │  │    - Per-CPU highpri wq → per-CPU highpri pool (nice=-20) │           │
 │     │  │    - Unbound wq → unbound pool for this CPU's NUMA node   │           │
 │     │  └─────────────────────────────────────────────────────────────┘           │
 │     │                                                                           │
 │     │  ┌─────────────────────────────────────────────────────────────┐           │
 │     │  │  STEP C: Get the worker_pool from the pwq                  │           │
 │     │  ├─────────────────────────────────────────────────────────────┤           │
 │     │  │                                                            │           │
 │     │  │  pool = pwq->pool                                          │           │
 │     │  │                                                            │           │
 │     │  │  pwq is the BRIDGE — it connects the abstract workqueue   │           │
 │     │  │  to the concrete pool of threads that will do the work.   │           │
 │     │  │  The pool has the worklist, the workers, and the locks.   │           │
 │     │  └─────────────────────────────────────────────────────────────┘           │
 │     │                                                                           │
 │     ├── raw_spin_lock(&pool->lock)                                              │
 │     │     → Lock the target pool (protects worklist and worker state)           │
 │     │                                                                           │
 │     │  ┌─────────────────────────────────────────────────────────────┐           │
 │     │  │  STEP D: Non-reentrance check                              │           │
 │     │  ├─────────────────────────────────────────────────────────────┤           │
 │     │  │                                                            │           │
 │     │  │  worker = find_worker_executing_work(pool, work)           │           │
 │     │  │  → Searches pool->busy_hash for a worker whose             │           │
 │     │  │    current_work == this work                               │           │
 │     │  │                                                            │           │
 │     │  │  If found: this work is currently executing on a different │           │
 │     │  │  pool. Queue it on THAT pool instead to guarantee the      │           │
 │     │  │  work handler never runs concurrently with itself.        │           │
 │     │  │    pwq = worker->current_pwq                               │           │
 │     │  └─────────────────────────────────────────────────────────────┘           │
 │     │                                                                           │
 │     │  ┌─────────────────────────────────────────────────────────────┐           │
 │     │  │  STEP E: Insert work into the worklist                     │           │
 │     │  ├─────────────────────────────────────────────────────────────┤           │
 │     │  │                                                            │           │
 │     │  │  if (pwq->nr_active < max_active)                          │           │
 │     │  │      insert_work(pwq, work, &pool->worklist)               │           │
 │     │  │        1. set_work_pwq(work, pwq, flags)                   │           │
 │     │  │           → work->data = pwq | PENDING | PWQ | color       │           │
 │     │  │        2. list_add_tail(&work->entry, &pool->worklist)     │           │
 │     │  │           → APPENDED TO END OF WORKLIST (FIFO)             │           │
 │     │  │        3. get_pwq(pwq)                                     │           │
 │     │  │           → pwq->refcnt++ (prevent teardown)               │           │
 │     │  │  else                                                      │           │
 │     │  │      list_add_tail(&work->entry, &pwq->inactive_works)     │           │
 │     │  │      → Throttled: too many active items for this wq/pool   │           │
 │     │  └─────────────────────────────────────────────────────────────┘           │
 │     │                                                                           │
 │     │  ┌─────────────────────────────────────────────────────────────┐           │
 │     │  │  STEP F: Wake a worker to process the work                 │           │
 │     │  ├─────────────────────────────────────────────────────────────┤           │
 │     │  │                                                            │           │
 │     │  │  kick_pool(pool)                                           │           │
 │     │  │    → if (!pool->nr_running && !list_empty(&pool->worklist))│           │
 │     │  │          first_idle = first_idle_worker(pool)              │           │
 │     │  │          wake_up_process(first_idle->task)                 │           │
 │     │  │    → Wakes one idle kworker to start processing            │           │
 │     │  └─────────────────────────────────────────────────────────────┘           │
 │     │                                                                           │
 │     └── raw_spin_unlock(&pool->lock)                                            │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

### The Per-CPU pwq Lookup Visualized

This is the central data structure traversal that routes a work item from a workqueue to a specific pool on a specific CPU:

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  Per-CPU pwq Lookup — How Work Reaches a Worker Pool                            │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  queue_work(system_percpu_wq, &work)    on CPU 2                                │
 │                                                                                 │
 │  system_percpu_wq (workqueue_struct)                                            │
 │    │                                                                            │
 │    │  wq->cpu_pwq is a __percpu pointer array:                                  │
 │    │  ┌──────────┬──────────┬──────────┬──────────┐                             │
 │    │  │ cpu_pwq  │ cpu_pwq  │ cpu_pwq  │ cpu_pwq  │                             │
 │    │  │ [CPU 0]  │ [CPU 1]  │ [CPU 2]  │ [CPU 3]  │                             │
 │    │  └────┬─────┴─────┬────┴────┬─────┴─────┬────┘                             │
 │    │       │           │         │           │                                   │
 │    │       ▼           ▼         ▼           ▼                                   │
 │    │     pwq_0       pwq_1     pwq_2       pwq_3                                │
 │    │       │           │         │           │                                   │
 │    │       ▼           ▼         ▼           ▼                                   │
 │    │   pool(CPU0)  pool(CPU1) pool(CPU2) pool(CPU3)                             │
 │    │     normal      normal     normal     normal                               │
 │    │                                                                            │
 │    └── per_cpu_ptr(wq->cpu_pwq, 2)  → pwq_2                                    │
 │          pwq_2->pool  → pool(CPU2, normal)                                      │
 │            pool->worklist  → [work_X] → [work_Y] → ... → [NEW WORK]            │
 │                                                      ▲                          │
 │                                                      │                          │
 │                                          list_add_tail() adds here              │
 │                                                                                 │
 │  The work item is now on CPU 2's normal-priority pool worklist.                 │
 │  A kworker/2:N thread will pick it up.                                          │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

### Phase 3: Executing the Work — worker_thread() and process_one_work()

After `kick_pool()` wakes an idle kworker, the worker runs through this path:

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  EXECUTION PATH — Complete Internal Trace                                       │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  ① kworker wakes up in worker_thread()                                          │
 │     │  [kernel/workqueue.c, lines 3431-3503]                                    │
 │     │                                                                           │
 │     ├── raw_spin_lock_irq(&pool->lock)                                          │
 │     │                                                                           │
 │     ├── Check WORKER_DIE → no, continue                                         │
 │     │                                                                           │
 │     ├── worker_leave_idle(worker)                                               │
 │     │     → Remove from pool->idle_list                                         │
 │     │     → pool->nr_idle--                                                     │
 │     │                                                                           │
 │  ② recheck:                                                                     │
 │     ├── need_more_worker(pool)?                                                 │
 │     │     = !list_empty(&pool->worklist) && !pool->nr_running                   │
 │     │     NO  → goto sleep (someone else is handling it)                        │
 │     │     YES → continue                                                        │
 │     │                                                                           │
 │     ├── may_start_working(pool)?                                                │
 │     │     = pool->nr_idle > 0                                                   │
 │     │     NO  → manage_workers() → create_worker(pool) → goto recheck           │
 │     │     YES → continue (there's a backup idle worker)                         │
 │     │                                                                           │
 │  ③ WORK PROCESSING LOOP:                                                        │
 │     │  do {                                                                     │
 │     │    work = list_first_entry(&pool->worklist, ...)                           │
 │     │      → PICKS FROM HEAD OF WORKLIST (FIFO — oldest first)                  │
 │     │                                                                           │
 │     │    assign_work(work, worker, NULL)                                         │
 │     │      → Move work to worker->scheduled list                                │
 │     │                                                                           │
 │     │    process_scheduled_works(worker)                                         │
 │     │      └── process_one_work(worker, work)  ← see below                      │
 │     │                                                                           │
 │     │  } while (keep_working(pool))                                             │
 │     │      keep_working = !list_empty(&worklist) && nr_running <= 1             │
 │     │      → Keep going if there's more work AND this is the only runner        │
 │     │                                                                           │
 │  ④ sleep:                                                                       │
 │     ├── worker_enter_idle(worker)                                               │
 │     │     → Add to pool->idle_list, pool->nr_idle++                             │
 │     │     → Start idle_timer (5 min timeout for destruction)                    │
 │     ├── __set_current_state(TASK_IDLE)                                           │
 │     ├── raw_spin_unlock_irq(&pool->lock)                                        │
 │     ├── schedule()  → CPU runs other tasks, kworker sleeps                      │
 │     └── goto woke_up (when kicked again)                                        │
 │                                                                                 │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  ⑤ process_one_work(worker, work)  — INSIDE THE HANDLER EXECUTION               │
 │     │  [kernel/workqueue.c, lines 3220-3380]                                    │
 │     │                                                                           │
 │     ├── pwq = get_work_pwq(work)         ← extract pwq from work->data         │
 │     │                                                                           │
 │     ├── hash_add(pool->busy_hash, &worker->hentry, (unsigned long)work)         │
 │     │     → Register in busy_hash (keyed by work address)                       │
 │     │     → find_worker_executing_work() can now find this worker               │
 │     │                                                                           │
 │     ├── worker->current_work = work                                             │
 │     ├── worker->current_func = work->func                                       │
 │     ├── worker->current_pwq  = pwq                                              │
 │     │                                                                           │
 │     ├── list_del_init(&work->entry)      ← REMOVE from worklist                │
 │     │                                                                           │
 │     ├── if (WQ_CPU_INTENSIVE)                                                   │
 │     │     worker_set_flags(WORKER_CPU_INTENSIVE)                                │
 │     │     → excluded from nr_running, won't block concurrency mgmt             │
 │     │                                                                           │
 │     ├── kick_pool(pool)                  ← wake another worker if needed        │
 │     │                                                                           │
 │     ├── set_work_pool_and_clear_pending(work, pool->id, flags)                  │
 │     │     → CLEARS PENDING BIT (bit 0 → 0)                                     │
 │     │     → work->data now encodes pool ID (off-queue format)                   │
 │     │     → FROM THIS POINT: work can be re-queued by another context           │
 │     │                                                                           │
 │     ├── raw_spin_unlock_irq(&pool->lock)  ◄── POOL LOCK RELEASED               │
 │     │                                                                           │
 │     │   ╔═══════════════════════════════════════════════════════════╗             │
 │     │   ║                                                         ║             │
 │     │   ║   worker->current_func(work)                            ║             │
 │     │   ║                                                         ║             │
 │     │   ║   YOUR HANDLER RUNS HERE — IN PROCESS CONTEXT           ║             │
 │     │   ║   ● Can sleep (mutex_lock, kmalloc GFP_KERNEL, I/O)     ║             │
 │     │   ║   ● Has its own task_struct (current = kworker thread)  ║             │
 │     │   ║   ● Pool lock is NOT held — other work can proceed      ║             │
 │     │   ║   ● If handler blocks, wq_worker_sleeping() fires:      ║             │
 │     │   ║     nr_running-- → may wake another idle worker         ║             │
 │     │   ║                                                         ║             │
 │     │   ╚═══════════════════════════════════════════════════════════╝             │
 │     │                                                                           │
 │     ├── cond_resched()                   ← yield if needed (voluntary preempt)  │
 │     │                                                                           │
 │     ├── raw_spin_lock_irq(&pool->lock)   ◄── POOL LOCK RE-ACQUIRED             │
 │     │                                                                           │
 │     ├── hash_del(&worker->hentry)        ← remove from busy_hash               │
 │     ├── worker->current_work = NULL      ← clear current state                 │
 │     ├── worker->current_func = NULL                                             │
 │     ├── worker->current_pwq  = NULL                                             │
 │     │                                                                           │
 │     └── pwq_dec_nr_in_flight(pwq, work_data)                                    │
 │           nr_active--                                                           │
 │           → if (nr_active < max_active && !list_empty(inactive_works))          │
 │               move work from pwq->inactive_works to pool->worklist              │
 │               → previously throttled work now becomes active                    │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

### Complete Data Structure Traversal: One Diagram

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  The Full Journey of a Work Item                                                │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  PHASE 1: INIT_WORK(&work, handler)                                            │
 │  ═══════════════════════════════════                                            │
 │                                                                                 │
 │  work_struct                                                                    │
 │  ┌────────────────────────────────────┐                                         │
 │  │ data  = WORK_STRUCT_NO_POOL | 0   │  (PENDING=0, no pool)                   │
 │  │ entry = { &entry, &entry }        │  (empty circular list)                  │
 │  │ func  = handler                   │  (function pointer)                     │
 │  └────────────────────────────────────┘                                         │
 │          Dormant. No connection to any pool or workqueue.                       │
 │                                                                                 │
 │  PHASE 2: queue_work(wq, &work) on CPU 2                                       │
 │  ════════════════════════════════════════                                        │
 │                                                                                 │
 │  wq (workqueue_struct)                                                          │
 │  ┌──────────────────────┐                                                       │
 │  │ cpu_pwq (per-CPU)    │                                                       │
 │  │  [0] [1] [2] [3]    │                                                       │
 │  └───────────┬──────────┘                                                       │
 │              │  per_cpu_ptr(wq->cpu_pwq, 2)                                     │
 │              ▼                                                                  │
 │  pwq (pool_workqueue)                                                           │
 │  ┌──────────────────────┐                                                       │
 │  │ pool ─────────────┐  │                                                       │
 │  │ wq ← back to wq   │  │                                                       │
 │  │ nr_active = 2      │  │                                                       │
 │  │ inactive_works     │  │                                                       │
 │  └────────────────────┼──┘                                                       │
 │                       │  pwq->pool                                              │
 │                       ▼                                                         │
 │  pool (worker_pool for CPU 2, normal)                                           │
 │  ┌──────────────────────────────────────────┐                                   │
 │  │ cpu = 2                                  │                                   │
 │  │ worklist ──→ [work_X] → [work_Y] → [NEW]│                                   │
 │  │                                     ▲    │                                   │
 │  │                        list_add_tail │    │                                   │
 │  │ nr_running = 0  (triggers kick)     │    │                                   │
 │  │ nr_idle = 1     (worker available)  │    │                                   │
 │  │ idle_list ──→ [kworker/2:1]         │    │                                   │
 │  └──────────────────────────────────────┼───┘                                   │
 │                                         │                                       │
 │  work.data = pwq | PENDING(1) | PWQ_BIT | color                                │
 │  work.entry linked into pool->worklist tail                                     │
 │  kick_pool() → wake_up_process(kworker/2:1)                                    │
 │                                                                                 │
 │  PHASE 3: kworker/2:1 executes the work                                        │
 │  ═══════════════════════════════════════                                         │
 │                                                                                 │
 │  kworker/2:1 wakes up in worker_thread()                                        │
 │  ┌──────────────────────────────────────────┐                                   │
 │  │ worker_leave_idle()                      │                                   │
 │  │   pool->nr_idle-- → 0                    │                                   │
 │  │                                          │                                   │
 │  │ work = list_first_entry(&pool->worklist) │                                   │
 │  │   → picks work_X first (FIFO from HEAD)  │                                   │
 │  │   → eventually reaches NEW work          │                                   │
 │  │                                          │                                   │
 │  │ process_one_work(worker, work):          │                                   │
 │  │   hash_add(busy_hash, worker, work)      │                                   │
 │  │   list_del_init(&work->entry)            │                                   │
 │  │   clear PENDING bit                      │                                   │
 │  │   UNLOCK pool                            │                                   │
 │  │   ┌────────────────────────────┐         │                                   │
 │  │   │ handler(work) EXECUTES    │         │                                   │
 │  │   │ can sleep, take mutexes   │         │                                   │
 │  │   └────────────────────────────┘         │                                   │
 │  │   LOCK pool                              │                                   │
 │  │   cleanup (hash_del, clear current_*)    │                                   │
 │  │   pwq_dec_nr_in_flight()                 │                                   │
 │  │                                          │                                   │
 │  │ keep_working()? → process next or sleep  │                                   │
 │  └──────────────────────────────────────────┘                                   │
 │                                                                                 │
 │  After handler returns:                                                         │
 │  work.data = pool_id | flags  (off-queue encoding, PENDING=0)                   │
 │  work.entry = empty list (detached)                                             │
 │  Work is dormant again — ready to be re-queued.                                 │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

### Why the pwq Bridge Exists — The Design Insight

A natural question is: why not have the workqueue point directly to the worker pool? Why the indirection through `pool_workqueue`?

The answer is that **multiple workqueues share the same worker pool**, but each workqueue needs its own **concurrency limits** and **accounting**. Consider:

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  Why pwq Is Necessary — Per-Workqueue Accounting on Shared Pools                │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  Without pwq (hypothetical — would NOT work):                                   │
 │  ─────────────────────────────────────────────                                   │
 │    system_percpu_wq (max_active=256)  ──→ pool(CPU0, normal)                    │
 │    system_long_wq   (max_active=256)  ──→ pool(CPU0, normal) ← same pool!      │
 │    my_driver_wq     (max_active=1)    ──→ pool(CPU0, normal) ← same pool!      │
 │                                                                                 │
 │    Problem: Where does max_active state live? In the pool? But three            │
 │    workqueues share it with different limits. In the wq? But each wq           │
 │    needs per-CPU state. There's no place for it.                               │
 │                                                                                 │
 │  With pwq (actual design):                                                      │
 │  ─────────────────────────                                                      │
 │    system_percpu_wq ──→ pwq_A ──→ pool(CPU0, normal)                            │
 │                          nr_active=5, max_active=256                            │
 │    system_long_wq   ──→ pwq_B ──→ pool(CPU0, normal)  ← same pool             │
 │                          nr_active=3, max_active=256                            │
 │    my_driver_wq     ──→ pwq_C ──→ pool(CPU0, normal)  ← same pool             │
 │                          nr_active=1, max_active=1                              │
 │                                                                                 │
 │    Each pwq maintains ITS OWN nr_active counter and inactive_works list.        │
 │    my_driver_wq is limited to 1 active item on this CPU, even though           │
 │    the same pool serves hundreds of items from other workqueues.               │
 │                                                                                 │
 │  pwq exists because:                                                            │
 │    1. Pools are shared → per-wq state needs its own structure                  │
 │    2. Limits are per-wq-per-CPU → (workqueue × CPU) = pwq                       │
 │    3. inactive_works are per-wq → throttled work is wq-specific                │
 │    4. Flush/drain is per-wq → need per-wq accounting of in-flight work         │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

→ Continued in **Part 6b** (`part6_doc_part2.md`): Delayed work, RCU work, `mod_delayed_work()`, custom workqueue creation, workqueue flags, `max_active`, concurrency patterns, periodic tasks, ordered workqueues, and boot initialization.

---
