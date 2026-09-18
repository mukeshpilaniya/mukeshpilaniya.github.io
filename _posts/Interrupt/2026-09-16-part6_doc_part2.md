---
title: Interrupt Handling in the Linux Kernel — Part 6b
published: true
categories: [Interrupt]
tags: [workqueue,interrupt,delayed_work,rcu_work]
---
# Interrupt Handling in the Linux Kernel — Part 6b: Workqueues — Delayed Work, Custom Workqueues, and Advanced Topics

> **Part 6a** covers workqueue architecture, data structures (`work_struct`, `workqueue_struct`, `worker_pool`, `pool_workqueue`, `worker`), core queueing/execution APIs, `container_of`, `worker_thread()`, `process_one_work()`, enable/disable, cancel, and flush: `part6_doc_part1.md`
>
> **Part 5** covers tasklets in depth: `part5_doc.md`

This document continues the workqueue coverage from Part 6a, covering delayed work items, RCU work, timer-based deferral, the complete API comparison, custom workqueue creation, workqueue flags, concurrency control (`max_active`), advanced execution patterns, and boot-time initialization. Source references from the v7.2-rc5 kernel.

---

## Table of Contents

1. [Delayed Work: struct delayed_work](#delayed-work-struct-delayed_work)
2. [How the Timer Expiry Triggers Work Execution](#how-the-timer-expiry-triggers-work-execution)
3. [schedule_delayed_work() and schedule_delayed_work_on()](#schedule_delayed_work-and-schedule_delayed_work_on)
4. [A Simple Delayed Work Example](#a-simple-delayed-work-example)
5. [schedule_delayed_work() vs queue_delayed_work()](#schedule_delayed_work-vs-queue_delayed_work)
6. [Flushing a Delayed Work: flush_delayed_work()](#flushing-a-delayed-work-flush_delayed_work)
7. [Canceling a Delayed Work: cancel_delayed_work() and cancel_delayed_work_sync()](#canceling-a-delayed-work-cancel_delayed_work-and-cancel_delayed_work_sync)
8. [cancel_delayed_work_sync() vs flush_delayed_work()](#cancel_delayed_work_sync-vs-flush_delayed_work)
9. [Modifying a Delayed Work's Timer: mod_delayed_work()](#modifying-a-delayed-works-timer-mod_delayed_work)
10. [RCU Work: struct rcu_work and queue_rcu_work()](#rcu-work-struct-rcu_work-and-queue_rcu_work)
11. [When to Use Which API](#when-to-use-which-api)
12. [Softirq vs Tasklet vs Workqueue vs Threaded IRQ vs WQ_BH: Complete Comparison](#softirq-vs-tasklet-vs-workqueue-vs-threaded-irq-vs-wq_bh-complete-comparison)
13. [Creating Your Own Workqueue: alloc_workqueue()](#creating-your-own-workqueue-alloc_workqueue)
14. [How Workqueues, PWQs, and Worker Pools Connect](#how-workqueues-pwqs-and-worker-pools-connect)
15. [destroy_workqueue()](#destroy_workqueue)
16. [Workqueue Flags In Depth](#workqueue-flags-in-depth)
17. [max_active: Controlling Concurrency](#max_active-controlling-concurrency)
18. [Runtime Tuning: workqueue_set_max_active() and workqueue_set_min_active()](#runtime-tuning-workqueue_set_max_active-and-workqueue_set_min_active)
19. [Queueing Multiple Work Items: Concurrent vs Sequential Execution](#queueing-multiple-work-items-concurrent-vs-sequential-execution)
20. [Two High Priority Queues with Different Work Items](#two-high-priority-queues-with-different-work-items)
21. [Periodic Tasks Using Workqueues](#periodic-tasks-using-workqueues)
22. [flush_workqueue(): Drain All Pending Work](#flush_workqueue-drain-all-pending-work)
23. [alloc_ordered_workqueue(): Strictly Sequential Execution](#alloc_ordered_workqueue-strictly-sequential-execution)
24. [Workqueue Initialization During Boot](#workqueue-initialization-during-boot)
25. [Summary](#summary)

---

## Delayed Work: struct delayed_work

A **`struct delayed_work`** combines a work item with a kernel timer, allowing you to queue work that will execute after a specified delay. This is the mechanism to reach for whenever you need to defer work to a specific point in the future — polling a hardware register after a timeout, retrying a failed operation with exponential backoff, implementing watchdog timeouts, debouncing rapid events, or building periodic tasks by re-queueing from the handler. If your work needs to run immediately (no delay), use a plain `work_struct` instead — `delayed_work` carries the overhead of an embedded `timer_list` that would go unused. Defined at [include/linux/workqueue.h, lines 114–121](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/workqueue.h#L114-L121):

```c
struct delayed_work {
    struct work_struct work;
    struct timer_list timer;

    /* target workqueue and CPU ->timer uses to queue ->work */
    struct workqueue_struct *wq;
    int cpu;
};
```

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  struct delayed_work                                                            │
 ├───────────────┬─────────────────────────────────────────────────────────────────┤
 │  work         │  struct work_struct — the embedded work item                    │
 ├───────────────┼─────────────────────────────────────────────────────────────────┤
 │  timer        │  struct timer_list — the kernel timer that fires after delay    │
 │               │  Timer callback = delayed_work_timer_fn()                       │
 ├───────────────┼─────────────────────────────────────────────────────────────────┤
 │  wq           │  Target workqueue (set when work is queued with delay > 0)      │
 ├───────────────┼─────────────────────────────────────────────────────────────────┤
 │  cpu          │  Target CPU (set when work is queued with delay > 0)            │
 └───────────────┴─────────────────────────────────────────────────────────────────┘
```

### Static Initialization

**`DECLARE_DELAYED_WORK`** at [include/linux/workqueue.h, lines 255–256](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/workqueue.h#L255-L256):

```c
#define DECLARE_DELAYED_WORK(n, f)   \
    struct delayed_work n = __DELAYED_WORK_INITIALIZER(n, f, 0)
```

### Dynamic Initialization

**`INIT_DELAYED_WORK`** at [include/linux/workqueue.h, lines 334–335](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/workqueue.h#L334-L335):

```c
#define INIT_DELAYED_WORK(_work, _func)   \
    __INIT_DELAYED_WORK(_work, _func, 0)
```

Which expands to at [include/linux/workqueue.h, lines 318–324](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/workqueue.h#L318-L324):

```c
#define __INIT_DELAYED_WORK(_work, _func, _tflags)          \
    do {                                                    \
        INIT_WORK(&(_work)->work, (_func));                 \
        __timer_init(&(_work)->timer,                       \
                     delayed_work_timer_fn,                  \
                     (_tflags) | TIMER_IRQSAFE);            \
    } while (0)
```

The timer is initialized with `delayed_work_timer_fn` as its callback and the `TIMER_IRQSAFE` flag (making it safe to fire from hardirq context).

---

## How the Timer Expiry Triggers Work Execution

Understanding this two-stage pipeline — timer fires in hardirq context, `delayed_work_timer_fn()` queues the work, kworker runs the handler in process context — is essential for debugging delayed work timing issues. The actual execution time is always `delay + scheduling latency`, never exactly `delay`, because the timer only queues the work; the kworker must then be scheduled.

When you queue a delayed work item with `queue_delayed_work(wq, &dwork, delay)`, the kernel does **not** immediately insert the work into the pool's worklist. Instead, it starts the timer. When the timer fires, the timer callback function **`delayed_work_timer_fn()`** at [kernel/workqueue.c, lines 2542–2549](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L2542-L2549) queues the actual work:

```c
void delayed_work_timer_fn(struct timer_list *t)
{
    struct delayed_work *dwork = timer_container_of(dwork, t, timer);

    /* should have been called from irqsafe timer with irq already off */
    __queue_work(dwork->cpu, dwork->wq, &dwork->work);
}
```

The internal `__queue_delayed_work()` at [kernel/workqueue.c, lines 2551–2589](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L2551-L2589) handles the initial setup:

```c
static void __queue_delayed_work(int cpu, struct workqueue_struct *wq,
                                struct delayed_work *dwork, unsigned long delay)
{
    struct timer_list *timer = &dwork->timer;
    struct work_struct *work = &dwork->work;

    /* If delay is 0, queue immediately — no timer */
    if (!delay) {
        __queue_work(cpu, wq, &dwork->work);
        return;
    }

    dwork->wq = wq;
    dwork->cpu = cpu;
    timer->expires = jiffies + delay;

    if (likely(cpu == WORK_CPU_UNBOUND))
        add_timer_global(timer);
    else
        add_timer_on(timer, cpu);
}
```

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  Delayed Work Execution Flow                                                    │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  queue_delayed_work(wq, &dwork, delay)                                          │
 │    │                                                                            │
 │    ├── delay == 0?                                                              │
 │    │     YES → __queue_work() immediately (same as queue_work)                  │
 │    │     NO  ↓                                                                  │
 │    │                                                                            │
 │    ├── Save wq and cpu in dwork                                                 │
 │    ├── Set timer->expires = jiffies + delay                                     │
 │    └── add_timer() → kernel timer subsystem                                     │
 │                                                                                 │
 │         ─── delay jiffies pass ───                                              │
 │                                                                                 │
 │    Timer fires in hardirq context                                               │
 │    │                                                                            │
 │    └── delayed_work_timer_fn()                                                  │
 │          │                                                                      │
 │          └── __queue_work(dwork->cpu, dwork->wq, &dwork->work)                  │
 │                │                                                                │
 │                └── Work inserted into pool->worklist                            │
 │                    │                                                            │
 │                    └── kick_pool() → wake idle kworker                          │
 │                          │                                                      │
 │                          └── kworker calls work->func(work) in process context  │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

An important optimization: **if `delay == 0`**, the timer is skipped entirely and the work is queued immediately via `__queue_work()`. This avoids unnecessary timer overhead for the zero-delay case.

---

## schedule_delayed_work() and schedule_delayed_work_on()

`schedule_delayed_work()` is the common case — deferred work on the system per-CPU workqueue with no CPU preference. `schedule_delayed_work_on()` targets a specific CPU, which is useful when the work needs to access per-CPU data without cross-CPU synchronization, when you want cache locality by keeping work on the same CPU that generated the event, or when you need to spread work across CPUs for load balancing. If you need to target a custom workqueue instead of the system workqueue, use `queue_delayed_work()` or `queue_delayed_work_on()` directly.

**`schedule_delayed_work()`** at [include/linux/workqueue.h, lines 853–857](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/workqueue.h#L853-L857) is the convenience wrapper for queueing delayed work on the system per-CPU workqueue:

```c
static inline bool schedule_delayed_work(struct delayed_work *dwork,
                                         unsigned long delay)
{
    return queue_delayed_work(system_percpu_wq, dwork, delay);
}
```

**`schedule_delayed_work_on()`** at [include/linux/workqueue.h, lines 839–843](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/workqueue.h#L839-L843) targets a specific CPU:

```c
static inline bool schedule_delayed_work_on(int cpu, struct delayed_work *dwork,
                                            unsigned long delay)
{
    return queue_delayed_work_on(cpu, system_percpu_wq, dwork, delay);
}
```

Both call `queue_delayed_work_on()` at [kernel/workqueue.c, lines 2608–2627](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L2608-L2627):

```c
bool queue_delayed_work_on(int cpu, struct workqueue_struct *wq,
                           struct delayed_work *dwork, unsigned long delay)
{
    struct work_struct *work = &dwork->work;
    bool ret = false;
    unsigned long irq_flags;

    local_irq_save(irq_flags);

    if (!test_and_set_bit(WORK_STRUCT_PENDING_BIT, work_data_bits(work)) &&
        !clear_pending_if_disabled(work)) {
        __queue_delayed_work(cpu, wq, dwork, delay);
        ret = true;
    }

    local_irq_restore(irq_flags);
    return ret;
}
```

The same `PENDING` bit mechanism prevents double-queueing for delayed work items.

### Practical Example: schedule_delayed_work() and schedule_delayed_work_on()

This example demonstrates basic delayed work scheduling. The work handler runs 5 seconds after module load. A module parameter selects the target CPU for `schedule_delayed_work_on()`.

```c
// hello.c — basic delayed work with CPU targeting
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/workqueue.h>
#include <linux/jiffies.h>

MODULE_LICENSE("GPL");

static struct delayed_work my_dwork;
static int cpu = -1;
module_param(cpu, int, 0644);
MODULE_PARM_DESC(cpu, "Target CPU (-1 = any, default)");

static void my_delayed_handler(struct work_struct *work)
{
	pr_info("delayed_work: running on CPU %d, pid %d\n",
		smp_processor_id(), current->pid);
}

static int __init delayed_work_init(void)
{
	pr_info("delayed_work: init on CPU %d\n", smp_processor_id());
	INIT_DELAYED_WORK(&my_dwork, my_delayed_handler);

	if (cpu >= 0)
		schedule_delayed_work_on(cpu, &my_dwork, msecs_to_jiffies(5000));
	else
		schedule_delayed_work(&my_dwork, msecs_to_jiffies(5000));

	return 0;
}

static void __exit delayed_work_exit(void)
{
	cancel_delayed_work_sync(&my_dwork);
	pr_info("delayed_work: exit\n");
}

module_init(delayed_work_init);
module_exit(delayed_work_exit);
```

**Build and test:**
```bash
make -C /lib/modules/$(uname -r)/build M=$(pwd) modules
sudo insmod hello.ko           # uses schedule_delayed_work (any CPU)
# wait 5 seconds
dmesg | tail
sudo rmmod hello

sudo insmod hello.ko cpu=2     # uses schedule_delayed_work_on (CPU 2)
# wait 5 seconds
dmesg | tail
sudo rmmod hello
```

**Expected output:**
```
[  10.001] delayed_work: init on CPU 0
[  15.004] delayed_work: running on CPU 3, pid 42    # any CPU (default)
[  20.010] delayed_work: exit

[  25.001] delayed_work: init on CPU 0
[  30.004] delayed_work: running on CPU 2, pid 58    # forced to CPU 2
[  35.010] delayed_work: exit
```

**Analysis:** With `cpu=-1`, `schedule_delayed_work()` queues onto `system_percpu_wq`, and the work runs on whichever CPU the timer fires on. With `cpu=2`, `schedule_delayed_work_on()` calls `queue_delayed_work_on(2, system_percpu_wq, ...)`, which sets `dwork->cpu = 2` — when the timer fires, `delayed_work_timer_fn()` calls `__queue_work(2, ...)`, inserting the work into CPU 2's normal pool worklist. The `cancel_delayed_work_sync()` in exit is essential — without it, if you `rmmod` before the 5-second timer fires, the timer callback would call into freed module code.

---

## A Simple Delayed Work Example

```c
#include <linux/module.h>
#include <linux/workqueue.h>

struct my_device {
    struct delayed_work dwork;
    int counter;
};

static struct my_device mydev;

static void my_delayed_handler(struct work_struct *work)
{
    struct delayed_work *dwork = to_delayed_work(work);
    struct my_device *dev = container_of(dwork, struct my_device, dwork);

    dev->counter++;
    pr_info("Delayed work: counter = %d, pid = %d\n",
            dev->counter, current->pid);

    /* Re-queue for periodic execution (every 2 seconds) */
    schedule_delayed_work(&dev->dwork, msecs_to_jiffies(2000));
}

static int __init my_init(void)
{
    INIT_DELAYED_WORK(&mydev.dwork, my_delayed_handler);
    mydev.counter = 0;

    /* First execution after 1 second */
    schedule_delayed_work(&mydev.dwork, msecs_to_jiffies(1000));
    return 0;
}

static void __exit my_exit(void)
{
    cancel_delayed_work_sync(&mydev.dwork);
}

module_init(my_init);
module_exit(my_exit);
MODULE_LICENSE("GPL");
```

Note the use of `to_delayed_work()` at [include/linux/workqueue.h, lines 213–216](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/workqueue.h#L213-L216) to convert from the `work_struct` pointer received by the handler to the enclosing `delayed_work`:

```c
static inline struct delayed_work *to_delayed_work(struct work_struct *work)
{
    return container_of(work, struct delayed_work, work);
}
```

---

## schedule_delayed_work() vs queue_delayed_work()

`schedule_delayed_work()` and `queue_delayed_work()` both queue a `delayed_work` with a timer-based delay, but they differ in one fundamental way: which workqueue the work runs on.

`schedule_delayed_work()` is a convenience wrapper that always targets `system_percpu_wq` — the kernel's default per-CPU workqueue shared by every subsystem. You don't pass a workqueue, because the choice is hardcoded. `queue_delayed_work()` takes an explicit workqueue argument, letting you target a custom workqueue you created with `alloc_workqueue()`.

Looking at the source, the relationship is transparent — `schedule_delayed_work()` literally calls `queue_delayed_work()`:

```c
/* schedule_delayed_work — uses the system per-CPU workqueue */
static inline bool schedule_delayed_work(struct delayed_work *dwork,
                                         unsigned long delay)
{
    return queue_delayed_work(system_percpu_wq, dwork, delay);
}

/* queue_delayed_work — targets any workqueue you specify */
static inline bool queue_delayed_work(struct workqueue_struct *wq,
                                      struct delayed_work *dwork,
                                      unsigned long delay)
{
    return queue_delayed_work_on(WORK_CPU_UNBOUND, wq, dwork, delay);
}
```

```
 ┌────────────────────────────────────────────────────────────────────────────────┐
 │  schedule_delayed_work() vs queue_delayed_work()                               │
 ├─────────────────────────────┬──────────────────────────────────────────────────┤
 │  Property                   │  schedule_delayed_work  │  queue_delayed_work    │
 ├─────────────────────────────┼─────────────────────────┼────────────────────────┤
 │  Target workqueue           │  system_percpu_wq       │  Caller-specified      │
 │                             │  (hardcoded)            │  (any custom WQ)       │
 ├─────────────────────────────┼─────────────────────────┼────────────────────────┤
 │  Isolation                  │  Shared with all        │  Dedicated to your     │
 │                             │  subsystems             │  subsystem             │
 ├─────────────────────────────┼─────────────────────────┼────────────────────────┤
 │  Flags                      │  System WQ flags        │  Whatever you passed   │
 │                             │  (no MEM_RECLAIM,       │  to alloc_workqueue()  │
 │                             │  no HIGHPRI)            │                        │
 ├─────────────────────────────┼─────────────────────────┼────────────────────────┤
 │  flush_workqueue()          │  Drains ALL subsystems  │  Drains only your      │
 │                             │  (dangerous)            │  work items            │
 ├─────────────────────────────┼─────────────────────────┼────────────────────────┤
 │  Typical use case           │  Short, non-critical    │  Long-running work,    │
 │                             │  deferred work          │  memory reclaim path,  │
 │                             │                         │  high-priority work    │
 └─────────────────────────────┴─────────────────────────┴────────────────────────┘
```

The rule is simple: if the system workqueue is fine for your needs (short work, no special flags, no isolation requirement), use `schedule_delayed_work()` for brevity. If you need `WQ_MEM_RECLAIM`, `WQ_HIGHPRI`, concurrency control via `max_active`, or the ability to flush/destroy only your own workqueue, create one with `alloc_workqueue()` and use `queue_delayed_work()`.

The same relationship exists for the non-delayed variants: `schedule_work()` wraps `queue_work(system_percpu_wq, ...)`, and for the CPU-pinned variants: `schedule_delayed_work_on()` wraps `queue_delayed_work_on(cpu, system_percpu_wq, ...)`.

---

## Flushing a Delayed Work: flush_delayed_work()

Sometimes you need to guarantee that a specific delayed work item has finished executing before proceeding — before reading data that the work item produces, before shutting down a subsystem that the work item depends on, or in test/diagnostic code where you need deterministic execution. Unlike `cancel_delayed_work_sync()` which prevents execution, `flush_delayed_work()` forces execution — the work handler will run even if the timer hasn't fired yet. It must be called from a sleepable context because it blocks until the handler completes.

**`flush_delayed_work()`** at [kernel/workqueue.c, lines 4411–4419](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L4411-L4419) cancels the timer, immediately queues the work (if the timer was still pending), and then flushes it:

```c
bool flush_delayed_work(struct delayed_work *dwork)
{
    local_irq_disable();
    if (timer_delete_sync(&dwork->timer))
        __queue_work(dwork->cpu, dwork->wq, &dwork->work);
    local_irq_enable();
    return flush_work(&dwork->work);
}
```

This guarantees that when `flush_delayed_work()` returns, the delayed work has completed execution — regardless of whether it was still waiting on the timer, queued in a pool, or currently executing.

### Practical Example: flush_delayed_work()

This example schedules delayed work with a 5-second delay, then immediately calls `flush_delayed_work()`. The flush cancels the pending timer and forces immediate execution, so the work runs during `module_init` — not 5 seconds later.

```c
// hello.c — flush_delayed_work forces immediate execution
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/workqueue.h>
#include <linux/jiffies.h>

MODULE_LICENSE("GPL");

static struct delayed_work my_dwork;

static void my_delayed_handler(struct work_struct *work)
{
	pr_info("flush_demo: handler running on CPU %d, pid %d\n",
		smp_processor_id(), current->pid);
}

static int __init flush_demo_init(void)
{
	pr_info("flush_demo: scheduling work with 5s delay\n");
	INIT_DELAYED_WORK(&my_dwork, my_delayed_handler);
	schedule_delayed_work(&my_dwork, msecs_to_jiffies(5000));

	pr_info("flush_demo: calling flush_delayed_work() — will block until handler completes\n");
	flush_delayed_work(&my_dwork);
	pr_info("flush_demo: flush returned — handler has completed\n");

	return 0;
}

static void __exit flush_demo_exit(void)
{
	cancel_delayed_work_sync(&my_dwork);
	pr_info("flush_demo: exit\n");
}

module_init(flush_demo_init);
module_exit(flush_demo_exit);
```

**Expected output:**
```
[  10.001] flush_demo: scheduling work with 5s delay
[  10.001] flush_demo: calling flush_delayed_work() — will block until handler completes
[  10.002] flush_demo: handler running on CPU 2, pid 38
[  10.002] flush_demo: flush returned — handler has completed
```

**Analysis:** Despite the 5-second delay, the handler runs immediately at `[10.002]`. Internally, `flush_delayed_work()` calls `timer_delete_sync()` to cancel the pending timer, then `__queue_work()` to insert the work directly into the pool's worklist, and finally `flush_work()` to block until the handler completes. The `module_init` function blocks at the `flush_delayed_work()` call until the kworker thread finishes the handler — all three log lines appear within the same millisecond.

---

## Canceling a Delayed Work: cancel_delayed_work() and cancel_delayed_work_sync()

The kernel provides two cancellation variants with different context and safety guarantees. `cancel_delayed_work()` is the fast, non-blocking variant safe from any context — interrupt handlers, spinlock-protected regions, or timers. It prevents the handler from running if the work hasn't started yet, but does **not** wait for an already-running handler to finish. `cancel_delayed_work_sync()` provides the stronger guarantee that the handler is not running and will never run after the call returns — the critical case is `module_exit()` / driver `remove()`, where the module's code and data will be freed. If the handler is still running during unload, the kernel jumps into unmapped memory and crashes. Always prefer `cancel_delayed_work_sync()` in cleanup paths unless you are in a non-sleepable context (in which case, use `cancel_delayed_work()` and ensure the handler cannot access freed resources).

**`cancel_delayed_work()`** at [kernel/workqueue.c, lines 4551–4555](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L4551-L4555):

```c
bool cancel_delayed_work(struct delayed_work *dwork)
{
    return __cancel_work(&dwork->work, WORK_CANCEL_DELAYED);
}
```

This cancels the delayed work — if the timer is pending, it is stopped; if the work is queued, it is dequeued. But it does **not** wait for a currently-executing instance to finish. The work handler may still be running on return. Returns `true` if the work was pending, `false` otherwise. Safe to call from **any context**, including hardirq.

**`cancel_delayed_work_sync()`** at [kernel/workqueue.c, lines 4566–4570](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L4566-L4570):

```c
bool cancel_delayed_work_sync(struct delayed_work *dwork)
{
    return __cancel_work_sync(&dwork->work, WORK_CANCEL_DELAYED);
}
```

This is the synchronous version — it cancels and waits for any currently-executing instance to complete. Must be called from a **sleepable context**.

```
 ┌──────────────────────────────────┬──────────────────────────────────────────────┐
 │  cancel_delayed_work()           │  cancel_delayed_work_sync()                  │
 ├──────────────────────────────────┼──────────────────────────────────────────────┤
 │  Cancels timer + dequeues work   │  Cancels timer + dequeues work + waits       │
 │  Does NOT wait for completion    │  Waits for handler to finish                 │
 │  Safe from ANY context           │  Must be called from sleepable context       │
 │  Handler may still be running    │  Handler guaranteed done on return           │
 └──────────────────────────────────┴──────────────────────────────────────────────┘
```

### Practical Example: cancel_delayed_work()

This example schedules delayed work with a 5-second delay, then immediately cancels it with `cancel_delayed_work()`. The handler never runs because the cancellation dequeues the pending timer before it fires.

```c
// hello.c — cancel_delayed_work prevents execution
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/workqueue.h>
#include <linux/jiffies.h>

MODULE_LICENSE("GPL");

static struct delayed_work my_dwork;

static void my_delayed_handler(struct work_struct *work)
{
	pr_info("cancel_demo: handler running on CPU %d\n", smp_processor_id());
}

static int __init cancel_demo_init(void)
{
	bool was_pending;

	pr_info("cancel_demo: scheduling work with 5s delay\n");
	INIT_DELAYED_WORK(&my_dwork, my_delayed_handler);
	schedule_delayed_work(&my_dwork, msecs_to_jiffies(5000));

	was_pending = cancel_delayed_work(&my_dwork);
	pr_info("cancel_demo: cancel_delayed_work returned %s\n",
		was_pending ? "true (was pending)" : "false (was not pending)");

	return 0;
}

static void __exit cancel_demo_exit(void)
{
	cancel_delayed_work_sync(&my_dwork);
	pr_info("cancel_demo: exit\n");
}

module_init(cancel_demo_init);
module_exit(cancel_demo_exit);
```

**Expected output:**
```
[  10.001] cancel_demo: scheduling work with 5s delay
[  10.001] cancel_demo: cancel_delayed_work returned true (was pending)
```

**Analysis:** The handler never appears in `dmesg` — `cancel_delayed_work()` stopped the timer before it could fire. The return value `true` confirms the work was pending when cancelled. Note the use of `cancel_delayed_work()` (async, safe from any context) for the immediate cancellation in `init`, but `cancel_delayed_work_sync()` (sync, sleepable) in `exit` as a safety net — if the work were somehow re-queued, the sync variant guarantees the handler has completed before module unload.

---

## cancel_delayed_work_sync() vs flush_delayed_work()

Both `cancel_delayed_work_sync()` and `flush_delayed_work()` block until the delayed work handler has completed, and both must be called from a sleepable context. But they have opposite intentions: `cancel_delayed_work_sync()` **prevents** execution, while `flush_delayed_work()` **forces** execution.

`cancel_delayed_work_sync()` stops the timer if it's pending, dequeues the work if it's on the worklist, and waits for any currently-running handler instance to finish. When it returns, the handler is guaranteed to not be running and will not run in the future. The work item is left in an idle state. This is the cleanup function — you call it when tearing down a subsystem, removing a module, or releasing a device. The handler's side effects must not happen after this point.

`flush_delayed_work()` does the opposite — it cancels the timer but then **immediately queues** the work (via `__queue_work()`) and blocks until the handler finishes. The handler is guaranteed to have run when `flush_delayed_work()` returns. This is the synchronization function — you call it when you need the handler's side effects to be visible before proceeding, like flushing pending writes before reading results or ensuring a configuration update has been applied.

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  cancel_delayed_work_sync() vs flush_delayed_work()                             │
 ├───────────────────────────────┬─────────────────────────────────────────────────┤
 │  cancel_delayed_work_sync()   │  flush_delayed_work()                           │
 ├───────────────────────────────┼─────────────────────────────────────────────────┤
 │  Intent: PREVENT execution    │  Intent: FORCE execution                        │
 ├───────────────────────────────┼─────────────────────────────────────────────────┤
 │  Timer pending?               │  Timer pending?                                 │
 │    Cancel timer, dequeue work │    Cancel timer, immediately queue work         │
 ├───────────────────────────────┼─────────────────────────────────────────────────┤
 │  Handler running?             │  Handler running?                               │
 │    Wait for it to finish      │    Wait for it to finish                        │
 ├───────────────────────────────┼─────────────────────────────────────────────────┤
 │  On return:                   │  On return:                                     │
 │    Handler will NEVER run     │    Handler has ALREADY run                      │
 ├───────────────────────────────┼─────────────────────────────────────────────────┤
 │  Work state after:            │  Work state after:                              │
 │    Idle (can be re-queued)    │    Idle (can be re-queued)                      │
 ├───────────────────────────────┼─────────────────────────────────────────────────┤
 │  Context: sleepable only      │  Context: sleepable only                        │
 ├───────────────────────────────┼─────────────────────────────────────────────────┤
 │  Typical use:                 │  Typical use:                                   │
 │    module_exit(), driver      │    Synchronization before reading results,      │
 │    remove(), teardown paths   │    forcing pending updates, test/diagnostic     │
 └───────────────────────────────┴─────────────────────────────────────────────────┘
```

A concrete example shows the difference:

```c
/* Scenario: driver with delayed health check */
INIT_DELAYED_WORK(&dev->health_check, check_health);
schedule_delayed_work(&dev->health_check, msecs_to_jiffies(5000));

/* Case 1: Shutting down — don't want the check to run */
cancel_delayed_work_sync(&dev->health_check);
/* Handler will NOT run. Safe to free dev. */

/* Case 2: Need health status NOW, can't wait 5 seconds */
flush_delayed_work(&dev->health_check);
/* Handler HAS run. dev->health_status is up to date. */
```

The internal difference is in what happens to a timer-pending work item. `cancel_delayed_work_sync()` calls `__cancel_work_sync()` which grabs the pending bit, cancels the timer, and never queues the work. `flush_delayed_work()` calls `timer_delete_sync()` to cancel the timer, then `__queue_work()` to put the work on the pool's worklist immediately, then `flush_work()` to wait for the kworker to execute it.

---

## Modifying a Delayed Work's Timer: mod_delayed_work()

`mod_delayed_work()` is the right choice for **debouncing** — when events fire rapidly (interrupt storms, sysfs writes, configuration changes) and you want the handler to run only once after the storm subsides. Each call resets the timer, so only the last event triggers execution. It is also the way to reschedule an already-pending delayed work with a different delay — `schedule_delayed_work()` would fail because the `PENDING` bit is already set, but `mod_delayed_work()` grabs the pending work, cancels the old timer, and re-queues with the new delay. Safe from any context including hardirq.

**`mod_delayed_work()`** at [include/linux/workqueue.h, lines 725–729](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/workqueue.h#L725-L729) modifies the delay of an already-pending delayed work item, or queues it if idle:

```c
static inline bool mod_delayed_work(struct workqueue_struct *wq,
                                    struct delayed_work *dwork,
                                    unsigned long delay)
{
    return mod_delayed_work_on(WORK_CPU_UNBOUND, wq, dwork, delay);
}
```

The implementation at [kernel/workqueue.c, lines 2647–2660](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L2647-L2660):

```c
bool mod_delayed_work_on(int cpu, struct workqueue_struct *wq,
                         struct delayed_work *dwork, unsigned long delay)
{
    unsigned long irq_flags;
    bool ret;

    ret = work_grab_pending(&dwork->work, WORK_CANCEL_DELAYED, &irq_flags);

    if (!clear_pending_if_disabled(&dwork->work))
        __queue_delayed_work(cpu, wq, dwork, delay);

    local_irq_restore(irq_flags);
    return ret;
}
```

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  mod_delayed_work() Behavior                                                    │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  If dwork is IDLE:                                                              │
 │    → Equivalent to queue_delayed_work() — starts the timer                      │
 │    → Returns false (was not pending)                                            │
 │                                                                                 │
 │  If dwork is PENDING (timer running):                                           │
 │    → Cancels the old timer, re-queues with the new delay                        │
 │    → Returns true (was pending, timer modified)                                 │
 │                                                                                 │
 │  If delay == 0:                                                                 │
 │    → Work is guaranteed to be scheduled immediately                             │
 │                                                                                 │
 │  Context: Safe from ANY context, including hardirq                              │
 │                                                                                 │
 │  Common use case:                                                               │
 │    Debouncing — each event resets the timer. Only the last event fires.         │
 │                                                                                 │
 │    mod_delayed_work(system_wq, &my_dwork, msecs_to_jiffies(500));               │
 │    /* If called again within 500ms, the timer restarts */                       │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

This is particularly useful for **debouncing**: if an event can fire rapidly, use `mod_delayed_work()` instead of `schedule_delayed_work()` — each call resets the timer, ensuring the handler runs only once after the events stop.

---

## RCU Work: struct rcu_work and queue_rcu_work()

An **`struct rcu_work`** combines a work item with an RCU callback head, allowing you to queue work that will execute **after an RCU grace period completes**. Defined at [include/linux/workqueue.h, lines 123–129](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/workqueue.h#L123-L129). To understand why this mechanism exists and why a plain workqueue is not enough, you need to understand the problem RCU solves at its core.

Consider a shared data structure — a routing table, a list of open file descriptors, a hash table of cached objects — accessed by multiple CPUs simultaneously. The traditional approach is to protect it with a lock (spinlock or mutex). Every reader takes the lock, reads the data, releases the lock. Every writer takes the lock, modifies the data, releases the lock. This is correct, but it has a fundamental scalability problem: on a 256-CPU system, if 200 CPUs are reading the routing table simultaneously, they all serialize on the same lock. Each reader waits for every other reader. The read side — which does nothing destructive and could safely run in parallel — becomes a bottleneck. For read-mostly data structures (routing tables are read millions of times per second but updated rarely), this lock contention dominates performance.

RCU (Read-Copy-Update) solves this by making **readers completely lock-free**. An RCU reader calls `rcu_read_lock()`, which on non-preemptible kernels is just `preempt_disable()` — zero lock acquisition, zero cache-line bouncing, zero contention. Readers on all 256 CPUs proceed in parallel with no synchronization overhead whatsoever. The reader dereferences a pointer with `rcu_dereference()` (a load with a memory barrier) and uses the object. When done, `rcu_read_unlock()` re-enables preemption. The cost is essentially zero — no atomic operations, no shared cache lines, no spinning.

The tradeoff is that **writers do all the heavy lifting**. To update the data structure, the writer allocates a new version of the object, copies the old data, modifies the copy, and atomically publishes the new pointer with `rcu_assign_pointer()` (a store with a write barrier). From this moment, new readers see the new version. But old readers — those who called `rcu_read_lock()` before the pointer swap — may still be using the old object. The writer cannot free the old object until every pre-existing reader has finished.

This is the fundamental constraint that creates the need for RCU grace periods: the writer must wait until all CPUs have passed through a **quiescent state** (a context switch, idle, or user-mode execution — any point where the CPU is guaranteed to not be in an RCU read-side critical section). The interval between the pointer swap and the last pre-existing reader finishing is the **grace period**.

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  Why RCU Exists: The Read-Side Scalability Problem                              │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  Traditional locking (rwlock):                                                  │
 │  ─────────────────────────────                                                  │
 │  CPU 0: read_lock() ──────── read data ──────── read_unlock()                   │
 │  CPU 1:    ↓ WAITS for CPU 0 ↓ read_lock() ──── read data ── read_unlock()      │
 │  CPU 2:       ↓ WAITS for CPU 1 ↓                read_lock() ── ...             │
 │  CPU 3:          ↓ WAITS for CPU 2 ↓                                            │
 │                                                                                 │
 │  Even rwlock_t has atomic ops on every read_lock() — cache line bounces         │
 │  across all CPUs. On 256 CPUs, this is devastating.                             │
 │                                                                                 │
 │  RCU:                                                                           │
 │  ─────                                                                          │
 │  CPU 0: rcu_read_lock() ── rcu_dereference(ptr) ── use ── rcu_read_unlock()     │
 │  CPU 1: rcu_read_lock() ── rcu_dereference(ptr) ── use ── rcu_read_unlock()     │
 │  CPU 2: rcu_read_lock() ── rcu_dereference(ptr) ── use ── rcu_read_unlock()     │
 │  CPU 3: rcu_read_lock() ── rcu_dereference(ptr) ── use ── rcu_read_unlock()     │
 │                                                                                 │
 │  All CPUs run in PARALLEL. Zero contention. rcu_read_lock() is just             │
 │  preempt_disable() — no atomic ops, no shared cache lines.                      │
 │                                                                                 │
 │  The cost shifts to the WRITER:                                                 │
 │                                                                                 │
 │  Writer: allocate new → copy old → modify copy → rcu_assign_pointer(new)        │
 │          ↓                                                                      │
 │          old object still referenced by pre-existing readers                    │
 │          ↓                                                                      │
 │          WAIT for grace period (all CPUs pass through quiescent state)          │
 │          ↓                                                                      │
 │          NOW safe to free old object                                            │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

Now, why can't a plain workqueue solve this? A workqueue runs work in process context, and you could queue a work item that frees the old object. But the workqueue has no awareness of when RCU readers have finished — it would execute immediately (or after a delay if using `delayed_work`), potentially freeing the object while readers are still using it. The key insight is that the timing must be tied to the **RCU grace period**, not to a fixed delay or an immediate schedule. You cannot predict how long readers will hold their references — it depends on preemption, scheduling, and what the reader does inside the critical section. Only the RCU subsystem knows when all pre-existing readers have completed, because it tracks quiescent states per CPU.

This is where `queue_rcu_work()` bridges the gap. It registers an RCU callback with `call_rcu_hurry()` that the RCU subsystem will invoke after the grace period — at exactly the right time, not a moment too early. But unlike `call_rcu()`, whose callback runs in softirq context (cannot sleep, cannot take mutexes, cannot do `GFP_KERNEL` allocations), `queue_rcu_work()`'s callback (`rcu_work_rcufn()`) just queues the real work onto a workqueue. The handler then runs in process context on a kworker thread with full sleeping capability.

The kernel provides three mechanisms for post-grace-period cleanup, each running in a different execution context:

1. **`call_rcu(&head, func)`** — Registers a callback that fires **in softirq context** after the grace period. Cannot sleep, no mutexes, `GFP_ATOMIC` only. Fine for simple memory freeing or atomic bookkeeping, but breaks down when cleanup requires process context.

2. **`kfree_rcu(ptr, rcu_member)`** — A specialized variant that frees the object after the grace period. It runs in softirq context and only does `kfree()` — you cannot attach custom logic. If you need to release other resources (close file descriptors, unregister from subsystems, flush I/O), `kfree_rcu()` is insufficient.

3. **`queue_rcu_work(wq, &rwork)`** — The two-stage pipeline: `call_rcu_hurry()` registers `rcu_work_rcufn()` as a softirq-context callback. When the grace period ends, `rcu_work_rcufn()` does minimal work — it calls `__queue_work()` to move the real work to the target workqueue. The handler runs in **process context** on a kworker thread — it can sleep, take mutexes, do blocking I/O, allocate with `GFP_KERNEL`. Common real-world cases include filesystem inode cleanup after RCU-protected lookup table removal, network device teardown after routing table update, and driver object release that must unregister from multiple subsystems. If the cleanup is just `kfree()`, use `kfree_rcu()` instead — it avoids the workqueue overhead. If the cleanup is simple and non-sleeping, use `call_rcu()` directly.

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  Three Post-Grace-Period Cleanup Mechanisms                                     │
 ├───────────────────────┬─────────────────────────────────────────────────────────┤
 │  Mechanism            │  Behavior                                               │
 ├───────────────────────┼─────────────────────────────────────────────────────────┤
 │  call_rcu()           │  Callback runs in softirq context after grace period    │
 │                       │  Cannot sleep, no mutexes, GFP_ATOMIC only              │
 │                       │  Use for: atomic bookkeeping, spinlock-protected ops    │
 ├───────────────────────┼─────────────────────────────────────────────────────────┤
 │  kfree_rcu()          │  Frees object via kfree() after grace period            │
 │                       │  No custom callback, just memory release                │
 │                       │  Use for: simple object deallocation                    │
 ├───────────────────────┼─────────────────────────────────────────────────────────┤
 │  queue_rcu_work()     │  Queues work to workqueue after grace period            │
 │                       │  Handler runs in process context (kworker thread)       │
 │                       │  CAN sleep, take mutexes, GFP_KERNEL, blocking I/O      │
 │                       │  Use for: complex cleanup needing process context       │
 ├───────────────────────┼─────────────────────────────────────────────────────────┤
 │                       │                                                         │
 │  The problem          │  rcu_read_lock()                                        │
 │  RCU solves:          │    ptr = rcu_dereference(global_ptr);                   │
 │                       │    use(ptr);     <-- reader still sees old pointer      │
 │                       │  rcu_read_unlock()                                      │
 │                       │                                                         │
 │                       │  Writer: rcu_assign_pointer(global_ptr, new_obj);       │
 │                       │          queue_rcu_work(wq, &old_obj->rwork);           │
 │                       │          // old_obj freed ONLY after all readers done   │
 │                       │                                                         │
 └───────────────────────┴─────────────────────────────────────────────────────────┘
```

```c
struct rcu_work {
    struct work_struct work;
    struct rcu_head rcu;

    /* target workqueue ->rcu uses to queue ->work */
    struct workqueue_struct *wq;
};
```

Initialized with `INIT_RCU_WORK()` at [include/linux/workqueue.h, lines 346–347](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/workqueue.h#L346-L347):

```c
#define INIT_RCU_WORK(_work, _func)   \
    INIT_WORK(&(_work)->work, (_func))
```

**`queue_rcu_work()`** at [kernel/workqueue.c, lines 2683–2699](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L2683-L2699):

```c
bool queue_rcu_work(struct workqueue_struct *wq, struct rcu_work *rwork)
{
    struct work_struct *work = &rwork->work;

    if (!test_and_set_bit(WORK_STRUCT_PENDING_BIT, work_data_bits(work)) &&
        !WARN_ON_ONCE(clear_pending_if_disabled(work))) {
        rwork->wq = wq;
        call_rcu_hurry(&rwork->rcu, rcu_work_rcufn);
        return true;
    }

    return false;
}
```

The internal callback `rcu_work_rcufn()` at [kernel/workqueue.c, lines 2663–2671](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L2663-L2671) fires after the RCU grace period and queues the actual work:

```c
static void rcu_work_rcufn(struct rcu_head *rcu)
{
    struct rcu_work *rwork = container_of(rcu, struct rcu_work, rcu);

    /* read the comment in __queue_work() */
    local_irq_disable();
    __queue_work(WORK_CPU_UNBOUND, rwork->wq, &rwork->work);
    local_irq_enable();
}
```

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  RCU Work Execution Flow                                                        │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  queue_rcu_work(wq, &rwork)                                                     │
 │    │                                                                            │
 │    ├── Set PENDING bit (prevents double-queue)                                  │
 │    └── call_rcu_hurry(&rwork->rcu, rcu_work_rcufn)                              │
 │          │                                                                      │
 │          │  ─── RCU grace period passes ───                                     │
 │          │  (all pre-existing RCU read-side critical sections complete)         │
 │          │                                                                      │
 │          └── rcu_work_rcufn()                                                   │
 │                │                                                                │
 │                └── __queue_work(UNBOUND, rwork->wq, &rwork->work)               │
 │                      │                                                          │
 │                      └── kworker calls work->func(work)                         │
 │                                                                                 │
 │  Use case: Free RCU-protected data from process context                         │
 │    → Can sleep (unlike kfree_rcu which runs in softirq)                         │
 │    → Useful when cleanup needs mutexes, blocking I/O, etc.                      │
 │                                                                                 │
 │  Limitations: rcu_work CANNOT be canceled or disabled.                          │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

**`flush_rcu_work()`** at [kernel/workqueue.c, lines 4429–4438](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L4429-L4438) waits for the RCU grace period and then the work completion:

```c
bool flush_rcu_work(struct rcu_work *rwork)
{
    if (test_bit(WORK_STRUCT_PENDING_BIT, work_data_bits(&rwork->work))) {
        rcu_barrier();
        flush_work(&rwork->work);
        return true;
    } else {
        return flush_work(&rwork->work);
    }
}
```

If the work is still pending (waiting for the RCU grace period), `flush_rcu_work()` calls `rcu_barrier()` to force completion of all pending RCU callbacks, then flushes the work itself.

---

## When to Use Which API

> **Note:** For detailed coverage of basic APIs (`schedule_work`, `queue_work`, `flush_work`, `cancel_work_sync`, `disable_work`/`enable_work`), see Part 6a. This table covers APIs introduced in Part 6b — delayed work, RCU work, custom workqueue management, and runtime tuning.

```
 ┌────────────────────────────────────┬─────────────────────────────────────────────┐
 │  API                               │  When to Use                                │
 ├────────────────────────────────────┼─────────────────────────────────────────────┤
 │  schedule_delayed_work(&dw, delay) │  Deferred work that should execute after    │
 │                                    │  a delay (in jiffies).                      │
 │                                    │  Uses system_percpu_wq.                     │
 ├────────────────────────────────────┼─────────────────────────────────────────────┤
 │  schedule_delayed_work_on()        │  Delayed work on a specific CPU.            │
 ├────────────────────────────────────┼─────────────────────────────────────────────┤
 │  queue_delayed_work(wq, &dw, d)    │  Delayed work on a specific workqueue.      │
 ├────────────────────────────────────┼─────────────────────────────────────────────┤
 │  mod_delayed_work(wq, &dw, d)      │  Modify delay of pending delayed work, or   │
 │                                    │  queue if idle. Ideal for debouncing.       │
 │                                    │  Safe from any context incl. hardirq.       │
 ├────────────────────────────────────┼─────────────────────────────────────────────┤
 │  queue_rcu_work(wq, &rwork)        │  Queue work to run after an RCU grace       │
 │                                    │  period. Use when cleanup needs process     │
 │                                    │  context (mutexes, blocking I/O).           │
 ├────────────────────────────────────┼─────────────────────────────────────────────┤
 │  flush_delayed_work(&dwork)        │  Cancel timer, immediately queue and flush  │
 │                                    │  the delayed work.                          │
 ├────────────────────────────────────┼─────────────────────────────────────────────┤
 │  flush_rcu_work(&rwork)            │  Wait for RCU grace period + work           │
 │                                    │  completion.                                │
 ├────────────────────────────────────┼─────────────────────────────────────────────┤
 │  cancel_delayed_work(&dwork)       │  Cancel without waiting. Safe from any      │
 │                                    │  context (including hardirq).               │
 ├────────────────────────────────────┼─────────────────────────────────────────────┤
 │  cancel_delayed_work_sync(&dwork)  │  Cancel + wait. Use in module exit /        │
 │                                    │  driver remove for delayed work.            │
 ├────────────────────────────────────┼─────────────────────────────────────────────┤
 │  alloc_workqueue(name, flags, max) │  Create a custom workqueue with specific    │
 │                                    │  flags and concurrency limits.              │
 ├────────────────────────────────────┼─────────────────────────────────────────────┤
 │  alloc_ordered_workqueue(name, f)  │  Create a strictly sequential workqueue     │
 │                                    │  (max_active=1, WQ_UNBOUND).                │
 ├────────────────────────────────────┼─────────────────────────────────────────────┤
 │  destroy_workqueue(wq)             │  Drain and destroy a custom workqueue.      │
 │                                    │  Never call from a work item on same wq.    │
 ├────────────────────────────────────┼─────────────────────────────────────────────┤
 │  workqueue_set_max_active(wq, n)   │  Adjust concurrency limit at runtime.       │
 │                                    │  Cannot be used on ordered workqueues.      │
 ├────────────────────────────────────┼─────────────────────────────────────────────┤
 │  workqueue_set_min_active(wq, n)   │  Set minimum per-node concurrency for       │
 │                                    │  unbound workqueues. Prevents deadlock.     │
 └────────────────────────────────────┴─────────────────────────────────────────────┘
```

---

## Softirq vs Tasklet vs Workqueue vs Threaded IRQ vs WQ_BH: Complete Comparison

> **Quick reference.** The motivation for why workqueues exist — why softirqs and tasklets cannot sleep, and the structural constraints of softirq context — is covered in Part 6a, Section 1. Softirq internals are in Part 3, tasklet internals are in Part 5. This table is a side-by-side summary for fast lookup, including the two newer mechanisms: **threaded IRQs** (the recommended replacement for tasklets in new drivers) and **WQ_BH workqueues** (the workqueue-based replacement for tasklets in the kernel's ongoing conversion).

Threaded IRQs (`request_threaded_irq()`) move interrupt handling into a dedicated kernel thread per IRQ line. The hardirq handler (the "primary" handler) runs in hardirq context and does the minimum — acknowledge the hardware, read status registers — then returns `IRQ_WAKE_THREAD`. The kernel wakes the IRQ thread, which runs the "thread function" in full process context. This splits the interrupt into two halves without requiring an explicit bottom-half mechanism. The `IRQF_ONESHOT` flag keeps the IRQ line masked until the thread function completes, preventing interrupt storms.

`WQ_BH` workqueues are the kernel's bridge between the old tasklet API and the workqueue infrastructure. They execute work items in softirq context (like tasklets), but use the workqueue programming model (`work_struct`, `queue_work()`, etc.). Internally, `WQ_BH` workqueues use dedicated `bh_worker_pools` per CPU, and the work is processed inside `workqueue_softirq_action()` — called from the tasklet softirq vector. This is the mechanism the kernel uses to convert tasklet users to workqueues without changing their execution context.

```
 ┌──────────────────┬──────────────────┬──────────────────┬──────────────────┬──────────────────┬──────────────────┐
 │  Property        │  Softirq         │  Tasklet         │  Workqueue       │  Threaded IRQ    │  WQ_BH           │
 ├──────────────────┼──────────────────┼──────────────────┼──────────────────┼──────────────────┼──────────────────┤
 │  Execution       │  Softirq         │  Softirq         │  Process         │  Process         │  Softirq         │
 │  context         │  (SOFTIRQ_OFFSET)│  (SOFTIRQ_OFFSET)│  (kworker)       │  (irq/%d-name)   │  (SOFTIRQ_OFFSET)│
 ├──────────────────┼──────────────────┼──────────────────┼──────────────────┼──────────────────┼──────────────────┤
 │  Can sleep?      │  NO              │  NO              │  YES             │  YES             │  NO              │
 ├──────────────────┼──────────────────┼──────────────────┼──────────────────┼──────────────────┼──────────────────┤
 │  Can take        │  NO              │  NO              │  YES             │  YES             │  NO              │
 │  mutexes?        │                  │                  │                  │                  │                  │
 ├──────────────────┼──────────────────┼──────────────────┼──────────────────┼──────────────────┼──────────────────┤
 │  GFP_KERNEL?     │  NO              │  NO              │  YES             │  YES             │  NO              │
 ├──────────────────┼──────────────────┼──────────────────┼──────────────────┼──────────────────┼──────────────────┤
 │  Concurrency     │  Same handler    │  Same instance   │  Non-reentrant   │  Serialized per  │  Non-reentrant   │
 │  model           │  on ALL CPUs     │  serialized      │  per work item.  │  IRQ line. One   │  per work item.  │
 │                  │  simultaneously  │  (never on 2     │  Multiple items  │  thread per IRQ. │  Same softirq    │
 │                  │                  │  CPUs at once)   │  run in parallel │  Never reentrant │  rules as tasklet│
 ├──────────────────┼──────────────────┼──────────────────┼──────────────────┼──────────────────┼──────────────────┤
 │  Number of       │  10 (static)     │  Unlimited       │  Unlimited       │  One per IRQ     │  Unlimited       │
 │  instances       │                  │  (dynamic)       │  (dynamic)       │  line registered │  (dynamic)       │
 ├──────────────────┼──────────────────┼──────────────────┼──────────────────┼──────────────────┼──────────────────┤
 │  Latency         │  Lowest (runs    │  Low (runs in    │  Higher (context │  Higher (thread  │  Low (runs in    │
 │                  │  on irq_exit)    │  softirq after   │  switch to       │  wake + schedule │  softirq, same   │
 │                  │                  │  softirqs)       │  kworker)        │  + context sw)   │  as tasklet)     │
 ├──────────────────┼──────────────────┼──────────────────┼──────────────────┼──────────────────┼──────────────────┤
 │  current         │  Borrowed        │  Borrowed        │  kworker's own   │  irq thread's    │  Borrowed        │
 │                  │  (interrupted    │  (interrupted    │  task_struct     │  own task_struct │  (interrupted    │
 │                  │  task/ksoftirqd) │  task/ksoftirqd) │                  │                  │  task/ksoftirqd) │
 ├──────────────────┼──────────────────┼──────────────────┼──────────────────┼──────────────────┼──────────────────┤
 │  Hardware IRQs   │  Enabled         │  Enabled         │  Enabled         │  Enabled         │  Enabled         │
 ├──────────────────┼──────────────────┼──────────────────┼──────────────────┼──────────────────┼──────────────────┤
 │  in_softirq()    │  true            │  true            │  false           │  false           │  true            │
 ├──────────────────┼──────────────────┼──────────────────┼──────────────────┼──────────────────┼──────────────────┤
 │  in_task()       │  false           │  false           │  true            │  true            │  false           │
 ├──────────────────┼──────────────────┼──────────────────┼──────────────────┼──────────────────┼──────────────────┤
 │  Delayed         │  No built-in     │  No built-in     │  Yes             │  No (hardirq     │  No (same as     │
 │  execution       │                  │                  │  (delayed_work)  │  triggers thread)│  softirq)        │
 ├──────────────────┼──────────────────┼──────────────────┼──────────────────┼──────────────────┼──────────────────┤
 │  API status      │  Active (core    │  DEPRECATED      │  Active          │  Active          │  Active          │
 │                  │  kernel only)    │  (being replaced)│  (recommended)   │  (recommended    │  (tasklet        │
 │                  │                  │                  │                  │  for drivers)    │  replacement)    │
 ├──────────────────┼──────────────────┼──────────────────┼──────────────────┼──────────────────┼──────────────────┤
 │  Locking         │  Per-CPU +       │  spin_lock       │  mutex or        │  mutex or        │  Per-CPU +       │
 │  needed          │  spinlock        │  between         │  spinlock        │  spinlock        │  spinlock        │
 │                  │  (complex)       │  instances       │  (normal rules)  │  (normal rules)  │  (softirq rules) │
 ├──────────────────┼──────────────────┼──────────────────┼──────────────────┼──────────────────┼──────────────────┤
 │  Thread          │  None            │  None            │  kworker/N:M     │  irq/N-name      │  None (runs in   │
 │                  │  (borrows ctx)   │  (borrows ctx)   │  (shared pool)   │  (dedicated,     │  softirq via     │
 │                  │                  │                  │                  │  1 per IRQ line) │  bh_worker_pools)│
 ├──────────────────┼──────────────────┼──────────────────┼──────────────────┼──────────────────┼──────────────────┤
 │  Use case        │  Networking,     │  Legacy driver   │  Anything that   │  Driver IRQ      │  Converting      │
 │                  │  block layer,    │  bottom halves   │  needs to sleep  │  handling that   │  tasklet code    │
 │                  │  timers, RCU     │  (being          │  (USB, FS,       │  needs process   │  to workqueue    │
 │                  │  (performance-   │  converted to    │  memory reclaim, │  context (I2C,   │  API while       │
 │                  │  critical)       │  WQ_BH)          │  general work)   │  SPI, USB, GPIO) │  keeping softirq │
 │                  │                  │                  │                  │                  │  context         │
 └──────────────────┴──────────────────┴──────────────────┴──────────────────┴──────────────────┴──────────────────┘
```

The progression shows the kernel's direction: tasklets are deprecated, and code is being migrated either to **threaded IRQs** (for driver interrupt handlers that need process context) or to **WQ_BH workqueues** (for code that needs to stay in softirq context but should use the workqueue API). New driver code should use `request_threaded_irq()` instead of a hardirq + tasklet combination. The `WQ_BH` mechanism exists primarily for the kernel's internal conversion of existing tasklet users — you would only use it directly if you have a specific need for softirq-context execution with workqueue semantics.

---

## Creating Your Own Workqueue: alloc_workqueue()

When the system workqueue is insufficient — because your work items are long-running, need special attributes, or you need isolation from other subsystems — you create your own workqueue with **`alloc_workqueue()`**. The system workqueue (`system_wq`, `system_percpu_wq`) is fine for short, non-blocking work that doesn't need special treatment. Create a custom workqueue when you need isolation (your long-running work would starve other subsystems on the shared queue), specific flags like `WQ_MEM_RECLAIM` for the memory reclaim path or `WQ_HIGHPRI` for latency-sensitive work, a specific `max_active` concurrency limit, or the ability to flush only your own work items without draining the entire system workqueue.

Declared at [include/linux/workqueue.h, lines 517–519](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/workqueue.h#L517-L519):

```c
__printf(1, 4) struct workqueue_struct *
alloc_workqueue_noprof(const char *fmt, unsigned int flags, int max_active, ...);
#define alloc_workqueue(...)  alloc_hooks(alloc_workqueue_noprof(__VA_ARGS__))
```

**Parameters:**
- `fmt` — printf-style format for the workqueue name (e.g., `"my_driver_wq"`)
- `flags` — combination of `WQ_*` flags
- `max_active` — maximum number of concurrently active work items (0 = default = `WQ_DFL_ACTIVE` = 1024)

**Example:**

```c
struct workqueue_struct *my_wq;

static int __init my_init(void)
{
    my_wq = alloc_workqueue("my_driver_wq",
                            WQ_UNBOUND | WQ_MEM_RECLAIM | WQ_HIGHPRI,
                            4);  /* max 4 concurrent items */
    if (!my_wq)
        return -ENOMEM;

    queue_work(my_wq, &my_work);
    return 0;
}

static void __exit my_exit(void)
{
    cancel_work_sync(&my_work);
    destroy_workqueue(my_wq);
}
```

Internally, `alloc_workqueue()` calls `__alloc_workqueue()` which allocates the `workqueue_struct`, creates the per-CPU pwqs (or unbound pwqs), links them to the appropriate worker pools, and optionally creates a rescuer thread. The implementation is at [kernel/workqueue.c, lines 5802–5936](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L5802-L5936).

**Important behavior:** One of `WQ_PERCPU` or `WQ_UNBOUND` must be set. If neither is set, the kernel defaults to `WQ_PERCPU` with a warning. If both are set, it drops `WQ_PERCPU` and keeps `WQ_UNBOUND`.

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  alloc_workqueue() Internal Flow                                                │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  alloc_workqueue(fmt, flags, max_active)                                        │
 │    │                                                                            │
 │    ├── Validate flags                                                           │
 │    │     ├── WQ_BH? → reject disallowed flags, force max_active=INT_MAX         │
 │    │     └── WQ_POWER_EFFICIENT + param set? → replace WQ_PERCPU with UNBOUND   │
 │    │                                                                            │
 │    ├── kzalloc(workqueue_struct)                                                │
 │    │     └── WQ_UNBOUND? → extra space for node_nr_active[]                     │
 │    │                                                                            │
 │    ├── WQ_UNBOUND? → alloc_workqueue_attrs()                                    │
 │    ├── vsnprintf(wq->name, fmt, args)                                           │
 │    │                                                                            │
 │    ├── Resolve WQ_PERCPU vs WQ_UNBOUND                                          │
 │    │     ├── Neither set → WARN, default to WQ_PERCPU                           │
 │    │     └── Both set   → WARN, drop WQ_PERCPU, keep WQ_UNBOUND                 │
 │    │                                                                            │
 │    ├── Clamp max_active (0 → WQ_DFL_ACTIVE=1024, cap at WQ_MAX_ACTIVE=2048)     │
 │    ├── Init wq fields (flags, mutex, pwqs list, flusher_queue, maydays)         │
 │    ├── WQ_UNBOUND? → alloc_node_nr_active()                                     │
 │    │                                                                            │
 │    ├── LOCK wq_pool_mutex                                                       │
 │    ├── alloc_and_link_pwqs(wq)                                                  │
 │    │     ├── Per-CPU path: for each CPU → init_pwq(pool) → link_pwq             │
 │    │     └── Unbound path: apply_workqueue_attrs_locked()                       │
 │    │                                                                            │
 │    ├── wq_adjust_max_active(wq)                                                 │
 │    ├── list_add_tail_rcu(&wq->list, &workqueues)                                │
 │    ├── wq_online? → init_rescuer(wq)  [if WQ_MEM_RECLAIM → creates kthread]     │
 │    ├── UNLOCK wq_pool_mutex                                                     │
 │    ├── WQ_SYSFS? → workqueue_sysfs_register(wq)                                 │
 │    └── return wq                                                                │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

---

## How Workqueues, PWQs, and Worker Pools Connect

A common misconception is that each workqueue gets a low-priority pwq, a high-priority pwq, and an unbound pwq per CPU. That is not how it works. Each workqueue gets **one pwq per CPU** (for per-CPU workqueues) or **one pwq per pod/NUMA node** (for unbound workqueues), and each pwq points to **exactly one** worker pool determined by the workqueue's flags at creation time.

The kernel pre-creates a fixed set of worker pools per CPU at boot. There are `NR_STD_WORKER_POOLS = 2` pools per CPU for process-context work, and 2 more for BH (softirq-context) work, defined at [kernel/workqueue.c, lines 501–504](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L501-L504):

```c
static DEFINE_PER_CPU(struct worker_pool [NR_STD_WORKER_POOLS], bh_worker_pools);
static DEFINE_PER_CPU(struct worker_pool [NR_STD_WORKER_POOLS], cpu_worker_pools);
```

So per CPU: `cpu_worker_pools[0]` is the normal-priority pool (nice=0), `cpu_worker_pools[1]` is the high-priority pool (nice=-20). The BH pools follow the same pattern. Unbound pools are created dynamically per NUMA node/pod and are not per-CPU.

When `alloc_and_link_pwqs()` creates the pwqs for a per-CPU workqueue, the selection is at [kernel/workqueue.c, line 5625](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L5625):

```c
bool highpri = wq->flags & WQ_HIGHPRI;
pool = &(per_cpu_ptr(pools, cpu)[highpri]);
```

`highpri` is 0 or 1, used as an array index. A `WQ_HIGHPRI` workqueue gets `pools[1]` (high-priority), everything else gets `pools[0]` (normal). Each workqueue picks **one** pool per CPU — not both.

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  PWQ Allocation: One PWQ Per CPU, Pointing to One Pool                          │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  Per-CPU pools (pre-created at boot, shared by ALL per-CPU workqueues):         │
 │                                                                                 │
 │  CPU 0                    CPU 1                    CPU 2                        │
 │  ┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐           │
 │  │ pool[0] nice=0   │    │ pool[0] nice=0   │    │ pool[0] nice=0   │           │
 │  │ pool[1] nice=-20 │    │ pool[1] nice=-20 │    │ pool[1] nice=-20 │           │
 │  └──────────────────┘    └──────────────────┘    └──────────────────┘           │
 │                                                                                 │
 │  system_percpu_wq (WQ_PERCPU, no WQ_HIGHPRI):                                   │
 │    cpu_pwq[0] ──→ CPU 0 pool[0]  (normal)                                       │
 │    cpu_pwq[1] ──→ CPU 1 pool[0]  (normal)                                       │
 │    cpu_pwq[2] ──→ CPU 2 pool[0]  (normal)                                       │
 │                                                                                 │
 │  system_highpri_wq (WQ_PERCPU | WQ_HIGHPRI):                                    │
 │    cpu_pwq[0] ──→ CPU 0 pool[1]  (high-priority)                                │
 │    cpu_pwq[1] ──→ CPU 1 pool[1]  (high-priority)                                │
 │    cpu_pwq[2] ──→ CPU 2 pool[1]  (high-priority)                                │
 │                                                                                 │
 │  my_custom_wq (WQ_PERCPU, no WQ_HIGHPRI):                                       │
 │    cpu_pwq[0] ──→ CPU 0 pool[0]  (normal)     ← SAME pool as system_percpu_wq   │
 │    cpu_pwq[1] ──→ CPU 1 pool[0]  (normal)     ← pools are SHARED                │
 │    cpu_pwq[2] ──→ CPU 2 pool[0]  (normal)                                       │
 │                                                                                 │
 │  my_highpri_wq (WQ_PERCPU | WQ_HIGHPRI):                                        │
 │    cpu_pwq[0] ──→ CPU 0 pool[1]  (high-priority) ← SAME pool as highpri_wq      │
 │    cpu_pwq[1] ──→ CPU 1 pool[1]  (high-priority)                                │
 │    cpu_pwq[2] ──→ CPU 2 pool[1]  (high-priority)                                │
 │                                                                                 │
 │  Unbound workqueues (WQ_UNBOUND) — pools created dynamically:                   │
 │                                                                                 │
 │  system_unbound_wq (WQ_UNBOUND):                                                │
 │    pwq[node0] ──→ unbound pool (NUMA node 0, nice=0)                            │
 │    pwq[node1] ──→ unbound pool (NUMA node 1, nice=0)                            │
 │                                                                                 │
 │  my_unbound_wq (WQ_UNBOUND | WQ_HIGHPRI):                                       │
 │    pwq[node0] ──→ unbound pool (NUMA node 0, nice=-20)                          │
 │    pwq[node1] ──→ unbound pool (NUMA node 1, nice=-20)                          │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

This design has important consequences. Multiple workqueues with the same flags share the **same** underlying worker pool. `system_percpu_wq` and your custom `WQ_PERCPU` workqueue both use `cpu_worker_pools[0]` on each CPU — the same kworker threads execute work from both. The pwq is the layer that provides per-workqueue isolation on a shared pool: each pwq has its own `nr_active` counter and `max_active` limit, its own `inactive_works` list, and its own flush/color accounting. So while the pool is shared, the concurrency enforcement is per-workqueue.

For unbound workqueues, pools are created dynamically by `get_unbound_pool()` based on the workqueue's attributes (cpumask, nice level, affinity scope). Two unbound workqueues with identical attributes share the same pool; two with different attributes (different nice level, or different cpumask) get separate pools. The pool granularity depends on the affinity scope — the default `WQ_AFFN_CACHE_SHARD` creates pools per cache-shard group of CPUs, while `WQ_AFFN_NUMA` creates pools per NUMA node.

For ordered workqueues (`alloc_ordered_workqueue()`), there is exactly **one** pwq — the default pwq (`dfl_pwq`). All CPUs' `cpu_pwq` entries point to this single pwq, which in turn points to a single unbound pool. This is how ordering is guaranteed: every work item, regardless of which CPU queued it, funnels through one pwq with `max_active=1`.

---

## destroy_workqueue()

Every `alloc_workqueue()` must be paired with `destroy_workqueue()` in module exit, driver removal (`remove()`), or any teardown path where the custom workqueue is no longer needed — leaking a workqueue leaks kernel memory, kworker threads, and sysfs entries. Always cancel or flush all pending work **before** calling `destroy_workqueue()` — the drain phase will wait for them, which can hang indefinitely if a work item re-queues itself. Never call `destroy_workqueue()` from a work item running on the same workqueue — that deadlocks because drain waits for the caller to finish, but the caller is waiting for drain.

**`destroy_workqueue()`** at [kernel/workqueue.c, lines 6051–6124](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L6051-L6124) destroys a workqueue:

```c
void destroy_workqueue(struct workqueue_struct *wq)
{
    /* mark destruction in progress */
    mutex_lock(&wq->mutex);
    wq->flags |= __WQ_DESTROYING;
    mutex_unlock(&wq->mutex);

    /* drain all pending work */
    drain_workqueue(wq);

    /* kill rescuer if present */
    if (wq->rescuer) {
        kthread_stop(wq->rescuer->task);
        kfree(wq->rescuer);
        wq->rescuer = NULL;
    }

    /* sanity checks — all pwqs must be idle */
    /* ... */

    /* remove from global list and release pwqs */
    list_del_rcu(&wq->list);
    /* ... */
}
```

The function first sets `__WQ_DESTROYING` to prevent new work from being queued, then calls `drain_workqueue()` which waits for all pending and executing work items to complete. Then it stops the rescuer thread, performs sanity checks, and releases all pwqs and the workqueue structure.

**You must cancel or flush all pending work before calling `destroy_workqueue()`**, or the drain will wait for them. Never call `destroy_workqueue()` from a work item executing on that same workqueue — that would deadlock.

System workqueues (`system_wq`, `system_percpu_wq`, `system_highpri_wq`, `system_long_wq`, `system_unbound_wq`, `system_freezable_wq`, `system_power_efficient_wq`, `system_bh_wq`, `system_bh_highpri_wq`, etc.) cannot and must not be destroyed. They are created once during boot in `workqueue_init_early()` and are declared with the `__ro_after_init` annotation at [kernel/workqueue.c, lines 524–546](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L524-L546):

```c
struct workqueue_struct *system_wq __ro_after_init;
struct workqueue_struct *system_percpu_wq __ro_after_init;
struct workqueue_struct *system_highpri_wq __ro_after_init;
struct workqueue_struct *system_long_wq __ro_after_init;
/* ... 7 more system workqueues ... */
```

The `__ro_after_init` annotation means these pointers are writable only during kernel initialization — after boot completes, the memory pages holding them are marked read-only by the kernel's memory protection, so any attempt to overwrite the pointer (e.g., setting it to `NULL` after destroying) would trigger a page fault. While `destroy_workqueue()` itself has no explicit check preventing destruction of a system workqueue, doing so would be catastrophic — every subsystem in the kernel (networking, block layer, filesystems, drivers, RCU, timers) queues work on these shared workqueues. Destroying `system_wq` would drain and free the workqueue structure, and any subsequent `schedule_work()` or `queue_work(system_wq, ...)` call from anywhere in the kernel would dereference a freed pointer, causing an immediate kernel crash. The 11 system workqueues are designed to exist for the entire lifetime of the kernel — from early boot until power-off. Only workqueues you create with `alloc_workqueue()` should be destroyed.

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  destroy_workqueue() Teardown Flow                                              │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  destroy_workqueue(wq)                                                          │
 │    │                                                                            │
 │    ├── workqueue_sysfs_unregister(wq)    ← remove sysfs first (avoids name      │
 │    │                                       conflicts if sanity check fails)     │
 │    │                                                                            │
 │    ├── LOCK wq->mutex                                                           │
 │    │     └── wq->flags |= __WQ_DESTROYING   ← prevents new work from queueing   │
 │    ├── UNLOCK wq->mutex                                                         │
 │    │                                                                            │
 │    ├── drain_workqueue(wq)               ← BLOCKS until all pending +           │
 │    │                                       executing work completes             │
 │    │                                                                            │
 │    ├── if wq->rescuer:                                                          │
 │    │     ├── kthread_stop(rescuer->task)  ← rescuer empties maydays list first  │
 │    │     └── kfree(rescuer)                                                     │
 │    │                                                                            │
 │    ├── LOCK wq_pool_mutex + wq->mutex                                           │
 │    │     └── for_each_pwq(pwq, wq):                                             │
 │    │           ├── LOCK pool->lock                                              │
 │    │           ├── WARN_ON(pwq_busy(pwq))  ← sanity: all pwqs must be idle      │
 │    │           └── UNLOCK pool->lock                                            │
 │    ├── UNLOCK wq->mutex                                                         │
 │    │                                                                            │
 │    ├── list_del_rcu(&wq->list)           ← remove from global workqueues list   │
 │    ├── UNLOCK wq_pool_mutex                                                     │
 │    │                                                                            │
 │    └── RCU read lock:                                                           │
 │          ├── for_each_possible_cpu(cpu):                                        │
 │          │     └── put_pwq_unlocked(pwq)  ← drop per-CPU pwq refs               │
 │          └── put_pwq_unlocked(dfl_pwq)    ← drop default pwq ref                │
 │                └── wq freed when last pwq refcount drops to 0                   │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

---

## Workqueue Flags In Depth

The flags passed to `alloc_workqueue()` determine the workqueue's execution context, scheduling behavior, and resource allocation. The most critical flag is `WQ_MEM_RECLAIM` — always set it if your workqueue is used in any memory reclaim path (block I/O completion, filesystem writeback, swap), because without it, the workqueue has no rescuer thread and can deadlock the reclaim path under memory pressure. Set `WQ_UNBOUND` for long-running work that doesn't benefit from CPU cache locality, or when you need system-wide concurrency control — unbound pools are shared per NUMA node. `WQ_HIGHPRI` makes work preempt normal-priority kworkers at the scheduler level (nice=-20), which is common for latency-sensitive paths like storage I/O completion. `WQ_CPU_INTENSIVE` is for handlers that run for a long time without sleeping — it prevents the concurrency manager from starving other work items on the same pool. `WQ_FREEZABLE` pauses work during system suspend/hibernate, which you need for anything that accesses hardware that may be powered down.

The workqueue flags are defined at [include/linux/workqueue.h, lines 371–416](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/workqueue.h#L371-L416):

```
 ┌───────────────────────┬───────┬───────────────────────────────────────────────────┐
 │  Flag                 │ Value │  Description                                      │
 ├───────────────────────┼───────┼───────────────────────────────────────────────────┤
 │  WQ_BH                │ 1<<0  │  Execute in bottom half (softirq) context, not    │
 │                       │       │  process context. Cannot sleep. Used for BH wqs.  │
 ├───────────────────────┼───────┼───────────────────────────────────────────────────┤
 │  WQ_UNBOUND           │ 1<<1  │  Workers not bound to any CPU. Work can migrate   │
 │                       │       │  across CPUs. Good for long-running work that     │
 │                       │       │  doesn't need cache locality. Dynamically         │
 │                       │       │  created worker pools per NUMA node.              │
 ├───────────────────────┼───────┼───────────────────────────────────────────────────┤
 │  WQ_FREEZABLE         │ 1<<2  │  Workqueue participates in system freeze during   │
 │                       │       │  suspend/hibernate. Pending work items are held   │
 │                       │       │  until thaw.                                      │
 ├───────────────────────┼───────┼───────────────────────────────────────────────────┤
 │  WQ_MEM_RECLAIM       │ 1<<3  │  Creates a dedicated rescuer thread that can      │
 │                       │       │  execute work items when normal worker creation   │
 │                       │       │  fails due to memory pressure. Essential for      │
 │                       │       │  workqueues in the memory reclaim path.           │
 ├───────────────────────┼───────┼───────────────────────────────────────────────────┤
 │  WQ_HIGHPRI           │ 1<<4  │  Use the high-priority worker pool (nice=-20).    │
 │                       │       │  Workers run at highest scheduler priority.       │
 │                       │       │  Check in running kernel:                         │
 │                       │       │    ps -ef | grep 'kworker.*:H'                    │
 ├───────────────────────┼───────┼───────────────────────────────────────────────────┤
 │  WQ_CPU_INTENSIVE     │ 1<<5  │  Worker is marked CPU-intensive, excluded from    │
 │                       │       │  concurrency management. The pool will wake       │
 │                       │       │  another worker to handle other pending work,     │
 │                       │       │  preventing starvation.                           │
 ├───────────────────────┼───────┼───────────────────────────────────────────────────┤
 │  WQ_SYSFS             │ 1<<6  │  Expose workqueue attributes in sysfs at          │
 │                       │       │  /sys/bus/workqueue/devices/<name>/ allowing      │
 │                       │       │  runtime tuning of affinity scope and cpumask.    │
 ├───────────────────────┼───────┼───────────────────────────────────────────────────┤
 │  WQ_POWER_EFFICIENT   │ 1<<7  │  Per-CPU normally, but becomes unbound if the     │
 │                       │       │  workqueue.power_efficient kernel param is set.   │
 │                       │       │  Saves power by letting idle CPUs stay idle.      │
 ├───────────────────────┼───────┼───────────────────────────────────────────────────┤
 │  WQ_PERCPU            │ 1<<8  │  Per-CPU workqueue. Each CPU has its own pwq      │
 │                       │       │  and worker pool. Best cache locality.            │
 └───────────────────────┴───────┴───────────────────────────────────────────────────┘
```

**`WQ_MEM_RECLAIM`** deserves special attention. When the system is under extreme memory pressure, creating new kworker threads (which requires `GFP_KERNEL` allocation) can fail. If work items in the memory reclaim path are stuck because no worker can be created, the system deadlocks. `WQ_MEM_RECLAIM` creates a dedicated **rescuer thread** at workqueue creation time that can step in and execute pending work items when the pool cannot create normal workers.

**`WQ_CPU_INTENSIVE`** is important for work items that perform long computation. Normally, the concurrency manager tracks how many workers are running in a pool — when a worker sleeps, it wakes another one. But a CPU-intensive worker never sleeps, so `nr_running` stays positive, and the pool doesn't wake additional workers even if other work items are pending. By marking the workqueue `WQ_CPU_INTENSIVE`, the worker is excluded from the `nr_running` count, and `kick_pool()` in `process_one_work()` will wake another worker to handle other pending items.

---

## max_active: Controlling Concurrency

The `max_active` parameter to `alloc_workqueue()` limits how many work items from that workqueue can be **executing concurrently** in a given pool. Set it explicitly when you need to limit resource consumption — for example, `max_active=4` for a disk I/O workqueue to avoid overwhelming the storage controller, or `max_active=1` for strict serialization (though `alloc_ordered_workqueue()` is clearer for that intent). Pass `max_active=0` to use the default (`WQ_DFL_ACTIVE=1024`) when you don't need concurrency limiting. The constants are at [include/linux/workqueue.h, lines 418–429](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/workqueue.h#L418-L429):

```c
enum wq_consts {
    WQ_MAX_ACTIVE       = 2048,
    WQ_UNBOUND_MAX_ACTIVE = WQ_MAX_ACTIVE,
    WQ_DFL_ACTIVE       = WQ_MAX_ACTIVE / 2,      /* 1024 */
    WQ_DFL_MIN_ACTIVE   = 8,
};
```

- **`max_active = 0`** → uses the default `WQ_DFL_ACTIVE = 1024`
- **`max_active = 1`** → only one work item executes at a time (per CPU for per-CPU, system-wide for unbound)
- **`max_active = N`** → at most N work items execute concurrently

For **per-CPU workqueues**, `max_active` is enforced per CPU. If `max_active = 4`, each CPU can have at most 4 active work items from this workqueue.

For **unbound workqueues**, `max_active` applies system-wide, distributed across NUMA nodes proportionally. The `min_active` (default `WQ_DFL_MIN_ACTIVE = 8`) guarantees a minimum per-node concurrency level to prevent deadlock when work items depend on each other.

The enforcement happens inside `__queue_work()` (covered in detail in Part 6a, "The Internal Queueing Path: \_\_queue\_work()"). In brief: if `pwq_tryinc_nr_active()` succeeds (meaning `nr_active < max_active`), the work is placed on `pool->worklist` (active). Otherwise, it goes to `pwq->inactive_works` (inactive, marked `WORK_STRUCT_INACTIVE`). Inactive work items are activated when in-flight items complete and `pwq_dec_nr_in_flight()` drops `nr_active` below `max_active`.

---

## Runtime Tuning: workqueue_set_max_active() and workqueue_set_min_active()

The `max_active` and `min_active` limits can be adjusted at runtime after workqueue creation. `workqueue_set_max_active()` is useful when a driver or subsystem needs to dynamically throttle or expand its concurrency based on runtime conditions — reducing concurrency during memory pressure, increasing it when more hardware resources become available, or adapting to user-configurable performance profiles. `workqueue_set_min_active()` applies to unbound workqueues where work items have dependencies on each other and you need to guarantee a minimum level of concurrency per NUMA node to prevent deadlock chains. Neither can be used on BH or ordered workqueues.

**`workqueue_set_max_active()`** at [kernel/workqueue.c, lines 6137–6157](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L6137-L6157):

```c
void workqueue_set_max_active(struct workqueue_struct *wq, int max_active)
{
    /* max_active doesn't mean anything for BH workqueues */
    if (WARN_ON(wq->flags & WQ_BH))
        return;
    /* disallow meddling with max_active for ordered workqueues */
    if (WARN_ON(wq->flags & __WQ_ORDERED))
        return;

    max_active = wq_clamp_max_active(max_active, wq->flags, wq->name);

    mutex_lock(&wq->mutex);

    wq->saved_max_active = max_active;
    if (wq->flags & WQ_UNBOUND)
        wq->saved_min_active = min(wq->saved_min_active, max_active);

    wq_adjust_max_active(wq);

    mutex_unlock(&wq->mutex);
}
```

**`workqueue_set_min_active()`** at [kernel/workqueue.c, lines 6174–6185](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L6174-L6185) adjusts the minimum guaranteed concurrency for **unbound** workqueues:

```c
void workqueue_set_min_active(struct workqueue_struct *wq, int min_active)
{
    /* min_active is only meaningful for non-ordered unbound workqueues */
    if (WARN_ON((wq->flags & (WQ_BH | WQ_UNBOUND | __WQ_ORDERED)) !=
                WQ_UNBOUND))
        return;

    mutex_lock(&wq->mutex);
    wq->saved_min_active = clamp(min_active, 0, wq->saved_max_active);
    wq_adjust_max_active(wq);
    mutex_unlock(&wq->mutex);
}
```

```
 ┌───────────────────────────────────────┬───────────────────────────────────────────┐
 │  Constraint                           │  Details                                  │
 ├───────────────────────────────────────┼───────────────────────────────────────────┤
 │  Cannot be used on BH workqueues      │  WQ_BH workqueues have no max_active      │
 ├───────────────────────────────────────┼───────────────────────────────────────────┤
 │  Cannot be used on ordered workqueues │  __WQ_ORDERED requires max_active = 1     │
 ├───────────────────────────────────────┼───────────────────────────────────────────┤
 │  min_active only for unbound WQs      │  Per-CPU WQs don't need min guarantee     │
 ├───────────────────────────────────────┼───────────────────────────────────────────┤
 │  Context: Don't call from IRQ         │  Takes wq->mutex internally               │
 └───────────────────────────────────────┴───────────────────────────────────────────┘
```

Use `workqueue_set_max_active()` when a driver or subsystem needs to dynamically throttle or expand its concurrency — for example, adjusting based on available system resources or load conditions.

---

## Queueing Multiple Work Items: Concurrent vs Sequential Execution

When you queue multiple different work items to the same workqueue, how they execute depends on `max_active` and the workqueue type. Use `max_active > 1` (or the default 1024) when work items are independent and benefit from parallel execution — for example, processing I/O completions for different devices. Use `max_active = 1` (or `alloc_ordered_workqueue()`) when work items share state and must not run concurrently — for example, a state machine where each event must be fully processed before the next one starts. The internal activation mechanism (`pwq_dec_nr_in_flight()` → `pwq_activate_first_inactive()`) is covered in Part 6a's `process_one_work()` section — this section focuses on the observable behavior:

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  Multiple Work Items Execution                                                  │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  CONCURRENT EXECUTION (max_active > 1):                                         │
 │  ──────────────────────────────────────                                         │
 │  queue_work(my_wq, &work_A);                                                    │
 │  queue_work(my_wq, &work_B);                                                    │
 │  queue_work(my_wq, &work_C);                                                    │
 │                                                                                 │
 │  If max_active >= 3, all three can execute concurrently on different workers.   │
 │  The concurrency manager will wake up to max_active workers.                    │
 │                                                                                 │
 │  SEQUENTIAL EXECUTION (max_active = 1):                                         │
 │  ──────────────────────────────────────                                         │
 │  queue_work(my_wq, &work_A);   → executes first                                 │
 │  queue_work(my_wq, &work_B);   → waits until A completes                        │
 │  queue_work(my_wq, &work_C);   → waits until B completes                        │
 │                                                                                 │
 │  Only one work item at a time. Work B and C go to pwq->inactive_works           │
 │  and are activated one by one.                                                  │
 │                                                                                 │
 │  EXAMPLE: Two work items on WQ_HIGHPRI with max_active = 1:                     │
 │  ──────────────────────────────────────────────────────────                     │
 │  alloc_workqueue("my_wq", WQ_HIGHPRI | WQ_PERCPU, 1);                           │
 │  queue_work(my_wq, &work_A);   → goes to pool->worklist (active)                │
 │  queue_work(my_wq, &work_B);   → goes to pwq->inactive_works (inactive)         │
 │                                                                                 │
 │  When work_A completes:                                                         │
 │    pwq_dec_nr_in_flight() → nr_active drops → activates work_B                  │
 │    work_B moves from pwq->inactive_works to pool->worklist                      │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

---

## Two High Priority Queues with Different Work Items

If you create **two separate** `WQ_HIGHPRI` workqueues, they both route to the **same** high-priority worker pool on each CPU (pool index = `cpu × 2 + 1`, as established in Part 6a's priority determination section). The high-priority pool has one `worklist`, and items from both workqueues are interleaved on it:

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  Two WQ_HIGHPRI Workqueues Sharing One Pool                                     │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  wq_A = alloc_workqueue("wq_A", WQ_HIGHPRI | WQ_PERCPU, 0);                     │
 │  wq_B = alloc_workqueue("wq_B", WQ_HIGHPRI | WQ_PERCPU, 0);                     │
 │                                                                                 │
 │  Both wq_A->cpu_pwq[0]->pool  and  wq_B->cpu_pwq[0]->pool                       │
 │  point to the SAME high-priority pool on CPU 0.                                 │
 │                                                                                 │
 │  CPU 0's high-priority pool worklist:                                           │
 │    [work_A1] → [work_B1] → [work_A2] → [work_B2]                                │
 │                                                                                 │
 │  The worker picks items from the head of the worklist in FIFO order.            │
 │  The first item queued is executed first — regardless of which                  │
 │  workqueue it belongs to. Priority between workqueues is NOT                    │
 │  differentiated — the pool's worklist is a single FIFO.                         │
 │                                                                                 │
 │  However, each workqueue has its OWN max_active enforcement via its pwq.        │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

The high-priority pool's workers run at `nice = -20` (highest priority), so they will be scheduled before normal-priority workers by the CFS scheduler. But within the high-priority pool itself, work items are processed FIFO — whichever was queued first runs first. Creating separate workqueues gives you per-workqueue `max_active` enforcement and independent `flush_workqueue()` / `destroy_workqueue()` scoping, but not scheduling priority differentiation between them. If you need true priority between workqueues, use different flag combinations — one `WQ_HIGHPRI`, the other normal.

---

## Periodic Tasks Using Workqueues

The workqueue API does not have a built-in "periodic work" primitive, but the re-queue-from-handler pattern fills this gap for periodic tasks that need process context — polling hardware status registers, periodic health checks, statistics collection, or watchdog timers. This is preferred over kernel timers alone when the periodic work needs to sleep (mutexes, blocking I/O, `GFP_KERNEL` allocations). For periodic work that must not sleep, use a recurring `hrtimer` or `timer_list` directly. The re-queue pattern naturally handles cancellation via `cancel_delayed_work_sync()` — it breaks the cycle by cancelling the timer and waiting for any in-flight handler to finish. To perform periodic tasks, **re-queue the work at the end of the handler**:

```c
static void my_periodic_handler(struct work_struct *work)
{
    struct delayed_work *dwork = to_delayed_work(work);
    struct my_device *dev = container_of(dwork, struct my_device, dwork);

    /* Do the periodic work */
    dev->counter++;
    pr_info("Periodic: counter = %d\n", dev->counter);

    /* Re-queue for next iteration (every 1 second) */
    schedule_delayed_work(&dev->dwork, HZ);
}
```

This works because `PENDING` is cleared before the handler is called (in `process_one_work()`), so `schedule_delayed_work()` can set it again and start the timer. The timer fires 1 second later, `delayed_work_timer_fn()` queues the work, and the cycle repeats.

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  Periodic Delayed Work Lifecycle                                                │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  module_init:                                                                   │
 │    INIT_DELAYED_WORK(&dw, handler)                                              │
 │    schedule_delayed_work(&dw, HZ)                                               │
 │       │                                                                         │
 │       ▼                                                                         │
 │  ┌─── Set PENDING bit ◄──────────────────────────────────────────────┐          │
 │  │    Start timer (expires = jiffies + HZ)                           │          │
 │  │       │                                                           │          │
 │  │       │  ─── delay passes ───                                     │          │
 │  │       ▼                                                           │          │
 │  │    delayed_work_timer_fn()         [hardirq context]              │          │
 │  │       │                                                           │          │
 │  │       └── __queue_work() → pool->worklist                         │          │
 │  │              │                                                    │          │
 │  │              ▼                                                    │          │
 │  │    kworker wakes → process_one_work()                             │          │
 │  │       │                                                           │          │
 │  │       ├── Clear PENDING bit        ← enables re-queue             │          │
 │  │       └── Call handler()                                          │          │
 │  │              │                                                    │          │
 │  │              ├── Do periodic work                                 │          │
 │  │              └── schedule_delayed_work(&dw, HZ) ──────────────────┘          │
 │  │                                                  CYCLE REPEATS               │
 │  │                                                                              │
 │  │  module_exit:                                                                │
 │  │    cancel_delayed_work_sync(&dw)                                             │
 │  │       │                                                                      │
 │  │       ├── Cancels timer (if pending)                                         │
 │  │       ├── Dequeues work (if queued)                                          │
 │  │       └── Waits for handler (if running) → cycle broken                      │
 │  │                                                                              │
 └───────┴─────────────────────────────────────────────────────────────────────────┘
```

To stop the periodic work, call `cancel_delayed_work_sync()` from outside the handler — typically in the module exit or driver remove function.

---

## flush_workqueue(): Drain All Pending Work

**`flush_workqueue()`** waits for all **currently pending** work items on a workqueue to complete. It is typically used before reconfiguring the workqueue, before a state transition that all work items must observe, or as part of a suspend/shutdown sequence. Prefer `flush_work(&specific_work)` when you only need to wait for a single work item — it is faster and avoids the system-wide stall. Never flush system workqueues (`system_wq`, `system_percpu_wq`) — it drains work from all subsystems and can cause deadlocks if your work item depends on another subsystem's work item on the same queue. The kernel emits a compile-time warning if you try. Defined as a macro at [include/linux/workqueue.h, lines 806–828](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/workqueue.h#L806-L828), which calls `__flush_workqueue()` at [kernel/workqueue.c, lines 4067–4214](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L4067-L4214):

The implementation uses a **color-based protocol**. Each work item is tagged with a "color" when queued. When `flush_workqueue()` is called, it advances the workqueue's `work_color` and waits for all work items of the previous color to complete. This ensures that only work items queued **before** the flush call are waited for — work items queued after the flush returns immediately.

The color space uses `WORK_NR_COLORS = 16` (4 bits), tracked per-pwq in `nr_in_flight[16]`:

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  flush_workqueue() Color-Based Protocol                                         │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  State: work_color=C, flush_color=C (no flush in progress)                      │
 │  All new work items are tagged with color C                                     │
 │                                                                                 │
 │  ════════════════════════════════════════════════════════════════               │
 │  Flush #1 arrives:                                                              │
 │  ════════════════════════════════════════════════════════════════               │
 │    │                                                                            │
 │    ├── next_color = C+1                                                         │
 │    ├── next_color != flush_color → color space not full                         │
 │    ├── this_flusher.flush_color = C   (wait for color C items)                  │
 │    ├── wq->work_color = C+1           (new items get color C+1)                 │
 │    │                                                                            │
 │    ├── No first_flusher → become first_flusher                                  │
 │    ├── flush_workqueue_prep_pwqs(flush_color=C, work_color=C+1)                 │
 │    │     └── for each pwq: set pwq->flush_color=C                               │
 │    │         check nr_in_flight[C] — if all zero, nothing to flush              │
 │    │                                                                            │
 │    └── wait_for_completion(&this_flusher.done)  ← BLOCKS                        │
 │                                                                                 │
 │         Meanwhile: new work gets color C+1 (won't be waited for)                │
 │                                                                                 │
 │         As workers finish color-C items:                                        │
 │           pwq_dec_nr_in_flight() → nr_in_flight[C]--                            │
 │           When nr_in_flight[C] == 0 → complete(&first_flusher->done)            │
 │                                                                                 │
 │  ════════════════════════════════════════════════════════════════               │
 │  Flush #2 arrives while Flush #1 pending:                                       │
 │  ════════════════════════════════════════════════════════════════               │
 │    │                                                                            │
 │    ├── next_color = C+2                                                         │
 │    ├── next_color != flush_color → color space not full                         │
 │    ├── this_flusher.flush_color = C+1                                           │
 │    ├── wq->work_color = C+2                                                     │
 │    │                                                                            │
 │    ├── first_flusher exists → add to flusher_queue (wait behind)                │
 │    └── wait_for_completion()  ← BLOCKS                                          │
 │                                                                                 │
 │  ════════════════════════════════════════════════════════════════               │
 │  Wake-up-and-cascade (when Flush #1 completes):                                 │
 │  ════════════════════════════════════════════════════════════════               │
 │    │                                                                            │
 │    ├── complete all flushers with same flush_color                              │
 │    ├── wq->flush_color = work_next_color(flush_color)                           │
 │    ├── Process flusher_overflow → assign colors, splice to flusher_queue        │
 │    └── Arm next flusher as first_flusher                                        │
 │          └── flush_workqueue_prep_pwqs() → if all done, cascade again           │
 │                                                                                 │
 │  Color space: 16 slots (0..15), wraps around. If all 16 are in use,             │
 │  new flushers go to flusher_overflow and wait for a color to free up.           │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

**Important warning:** The kernel discourages flushing system-wide workqueues. If you call `flush_workqueue(system_percpu_wq)`, a compile-time warning is generated (via `__warn_flushing_systemwide_wq()`). Flushing a system workqueue drains work from all subsystems, not just yours — it is slow and can cause deadlocks if your work item depends on another subsystem's work item on the same queue.

Use `flush_work(&specific_work)` instead whenever possible — it only waits for your specific work item, not everything on the queue.

---

## alloc_ordered_workqueue(): Strictly Sequential Execution

An **ordered workqueue** guarantees that work items execute **one at a time, in the order they were queued**. This is the right choice when work items modify shared state that would corrupt under concurrent access, when later work items depend on results from earlier ones, or when you need transaction-like semantics where each work item sees the complete effect of all previous ones. Common real-world uses include firmware loading sequences, configuration update pipelines where each step depends on the previous, journal/log commit paths, and state machines where events must be processed one at a time. If concurrent execution is acceptable and you only need mutual exclusion on specific data, use a regular workqueue with a mutex inside the handler instead — an ordered workqueue serializes **all** work items, which limits throughput. Defined at [include/linux/workqueue.h, lines 597–598](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/workqueue.h#L597-L598):

```c
#define alloc_ordered_workqueue(fmt, flags, args...)                  \
    alloc_workqueue(fmt, WQ_UNBOUND | __WQ_ORDERED | (flags), 1, ##args)
```

An ordered workqueue is simply an **unbound workqueue with `max_active = 1`** and the `__WQ_ORDERED` internal flag. Since `max_active = 1`, only one work item executes at a time. Since it is unbound, it uses a single pwq, which means work items across all CPUs are funneled through a single concurrency slot. The `__WQ_ORDERED` flag additionally prevents the non-reentrance logic from splitting work across pools (which could violate ordering).

```c
struct workqueue_struct *my_ordered_wq;

my_ordered_wq = alloc_ordered_workqueue("my_ordered_wq", WQ_MEM_RECLAIM);

queue_work(my_ordered_wq, &work_A);    /* executes first */
queue_work(my_ordered_wq, &work_B);    /* executes after A completes */
queue_work(my_ordered_wq, &work_C);    /* executes after B completes */
```

Use ordered workqueues when you need strict ordering guarantees — for example, when work items modify a shared data structure and must not run concurrently.

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  Ordered vs Normal Workqueue Execution                                          │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  Normal Per-CPU WQ (max_active=N):     Ordered WQ (max_active=1, WQ_UNBOUND):   │
 │  ─────────────────────────────────     ──────────────────────────────────────   │
 │                                                                                 │
 │  CPU 0 pwq ──→ pool 0                 Single unbound pwq ──→ one unbound pool   │
 │  CPU 1 pwq ──→ pool 2                                                           │
 │  CPU 2 pwq ──→ pool 4                 queue_work(wq, &A)  → [A active]          │
 │                                        queue_work(wq, &B)  → [B inactive]       │
 │  queue_work(wq, &A) → CPU 0           queue_work(wq, &C)  → [C inactive]        │
 │  queue_work(wq, &B) → CPU 1                                                     │
 │  queue_work(wq, &C) → CPU 2           Execution:                                │
 │                                          A runs  → completes → B activates      │
 │  A, B, C run in PARALLEL                 B runs  → completes → C activates      │
 │  on different workers/CPUs               C runs  → completes                    │
 │                                                                                 │
 │  No ordering guarantees                FIFO ordering guaranteed                 │
 │                                        __WQ_ORDERED prevents pool splitting     │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

---

## Workqueue Initialization During Boot

The workqueue subsystem is initialized in **three stages** during kernel boot:

**Stage 1: `workqueue_init_early()`** at [kernel/workqueue.c, lines 7971–8077](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L7971-L8077)

Called very early during boot, before kthreads can be created. This function:

1. Initializes cpumasks (`wq_online_cpumask`, `wq_unbound_cpumask`)
2. Allocates the `pwq_cache` slab
3. Initializes per-CPU worker pools (both BH and normal) with `init_cpu_worker_pool()`
4. Creates default unbound workqueue attributes (normal nice=0, highpri nice=-20)
5. **Creates all system workqueues** (see Part 6a, "System Workqueues: The Built-In Workqueues" for the complete listing and flags of each)

At this stage, work items can be queued but **no workers exist yet** — they sit on the worklist until stage 2.

**Stage 2: `workqueue_init()`** at [kernel/workqueue.c, lines 8127–8178](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L8127-L8178)

Called once kthreads can be created. This function:

1. Fixes up node hints for per-CPU pools
2. Creates rescuer threads for workqueues that need them
3. **Creates the initial workers** — `create_worker()` for every online CPU's pools and all unbound pools
4. Sets `wq_online = true` — from this point, full concurrency management is active

**Stage 3: `workqueue_init_topology()`** at [kernel/workqueue.c, line 8425](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/workqueue.c#L8425)

Called after SMP is fully online. Initializes the pod types (CPU, SMT, cache, NUMA topology) for unbound workqueue affinity scoping.

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │  Workqueue Boot Initialization Timeline                                         │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  start_kernel()                                                                 │
 │    │                                                                            │
 │    ├── workqueue_init_early()                    ── STAGE 1 ──                  │
 │    │     ├── Alloc cpumasks (wq_online_cpumask, wq_unbound_cpumask)             │
 │    │     ├── Alloc pwq_cache slab                                               │
 │    │     ├── Init per-CPU worker pools (BH + normal + highpri)                  │
 │    │     ├── Create default unbound WQ attrs (nice=0, nice=-20)                 │
 │    │     └── Create all 11 system workqueues (system_wq, system_percpu_wq,      │
 │    │           system_highpri_wq, system_long_wq, system_dfl_wq, etc.)          │
 │    │                                                                            │
 │    │     ┌──────────────────────────────────────────────────────────────┐       │
 │    │     │  Work CAN be queued but NO workers exist yet.                │       │
 │    │     │  Items sit on pool->worklist until Stage 2.                  │       │
 │    │     └──────────────────────────────────────────────────────────────┘       │
 │    │                                                                            │
 │    ├── ... (more kernel init — kthreads now possible) ...                       │
 │    │                                                                            │
 │    ├── workqueue_init()                          ── STAGE 2 ──                  │
 │    │     ├── Fix per-CPU pool NUMA node hints                                   │
 │    │     ├── Create rescuer threads (for WQ_MEM_RECLAIM workqueues)             │
 │    │     ├── Create BH pseudo-workers (all possible CPUs)                       │
 │    │     ├── Create initial kworkers (online CPUs + all unbound pools)          │
 │    │     └── wq_online = true                                                   │
 │    │                                                                            │
 │    │     ┌──────────────────────────────────────────────────────────────┐       │
 │    │     │  Full concurrency management ACTIVE.                         │       │
 │    │     │  Queued work from Stage 1 begins executing.                  │       │
 │    │     └──────────────────────────────────────────────────────────────┘       │
 │    │                                                                            │
 │    ├── ... (SMP bringup completes — all CPUs online) ...                        │
 │    │                                                                            │
 │    └── workqueue_init_topology()                 ── STAGE 3 ──                  │
 │          ├── init_pod_type(WQ_AFFN_CPU)                                         │
 │          ├── init_pod_type(WQ_AFFN_SMT)                                         │
 │          ├── init_pod_type(WQ_AFFN_CACHE)                                       │
 │          ├── precompute_cache_shard_ids()                                       │
 │          ├── init_pod_type(WQ_AFFN_CACHE_SHARD)                                 │
 │          ├── init_pod_type(WQ_AFFN_NUMA)                                        │
 │          ├── wq_topo_initialized = true                                         │
 │          └── Update all unbound WQ pwqs per pod topology                        │
 │                                                                                 │
 │          ┌──────────────────────────────────────────────────────────────┐       │
 │          │  NUMA-aware pool assignment now active.                      │       │
 │          │  Unbound work items route to topology-local pools.           │       │
 │          └──────────────────────────────────────────────────────────────┘       │
 │                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

---

## Summary

> For foundational concepts — data structures (`work_struct`, `workqueue_struct`, `worker_pool`, `pool_workqueue`, `worker`), execution context, queueing mechanics (`PENDING` bit, non-reentrance), worker pool concurrency management (`nr_running`, `need_more_worker()`), and the core APIs (`queue_work`, `schedule_work`, `flush_work`, `cancel_work_sync`, `disable_work`/`enable_work`) — see **Part 6a**.

This part covered the advanced workqueue features:

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │ Delayed work                                                                    │
 │                                                                                 │
 │  delayed_work:    Embeds work_struct + timer_list + target wq/cpu               │
 │  Timer callback:  delayed_work_timer_fn() → __queue_work() on timer fire        │
 │  Optimization:    delay == 0 skips the timer, queues immediately                │
 │  Init:            DECLARE_DELAYED_WORK() / INIT_DELAYED_WORK()                  │
 │  Queue:           schedule_delayed_work(&dw, delay) → system_percpu_wq          │
 │  Modify:          mod_delayed_work() — resets timer, ideal for debouncing       │
 │  Cancel:          cancel_delayed_work() (async, any ctx)                        │
 │                   cancel_delayed_work_sync() (sync, sleepable only)             │
 │  Flush:           flush_delayed_work() — cancel timer + queue + wait            │
 └─────────────────────────────────────────────────────────────────────────────────┘

 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │ RCU work                                                                        │
 │                                                                                 │
 │  Problem:         call_rcu() runs in softirq (no sleep, no mutexes).            │
 │                   kfree_rcu() only does kfree(). Neither supports complex       │
 │                   cleanup that needs process context.                           │
 │  Solution:        queue_rcu_work() — two-stage pipeline:                        │
 │                   call_rcu_hurry() → grace period → rcu_work_rcufn() →          │
 │                   __queue_work() → handler runs on kworker (can sleep)          │
 │  rcu_work:        Embeds work_struct + rcu_head + target wq                     │
 │  Use case:        Cleanup needing mutexes, blocking I/O, GFP_KERNEL             │
 │  Limitation:      Cannot be canceled or disabled                                │
 │  Flush:           flush_rcu_work() — rcu_barrier() + flush_work()               │
 └─────────────────────────────────────────────────────────────────────────────────┘

 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │ Custom workqueues                                                               │
 │                                                                                 │
 │  Create:          alloc_workqueue(name, flags, max_active)                      │
 │  Ordered:         alloc_ordered_workqueue(name, flags) — WQ_UNBOUND,            │
 │                   __WQ_ORDERED, max_active=1. Strict sequential execution.      │
 │  Destroy:         destroy_workqueue(wq) — sets __WQ_DESTROYING, drains,         │
 │                   stops rescuer, releases pwqs. Never call from own work item.  │
 │  Must set:        WQ_PERCPU or WQ_UNBOUND (kernel defaults to WQ_PERCPU)        │
 └─────────────────────────────────────────────────────────────────────────────────┘

 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │ Workqueue flags (WQ_*)                                                          │
 │                                                                                 │
 │  WQ_BH:           Execute in softirq context (cannot sleep)                     │
 │  WQ_UNBOUND:      Not CPU-bound, dynamic pools per NUMA node                    │
 │  WQ_FREEZABLE:    Participates in suspend/hibernate freeze                      │
 │  WQ_MEM_RECLAIM:  Creates rescuer thread for memory pressure safety             │
 │  WQ_HIGHPRI:      Uses high-priority pool (nice=-20)                            │
 │  WQ_CPU_INTENSIVE: Excluded from nr_running, prevents starvation                │
 │  WQ_SYSFS:        Exposes attributes in /sys/bus/workqueue/devices/             │
 │  WQ_POWER_EFFICIENT: Per-CPU normally, unbound if power_efficient param set     │
 │  WQ_PERCPU:       Per-CPU workqueue, best cache locality                        │
 └─────────────────────────────────────────────────────────────────────────────────┘

 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │ Concurrency control                                                             │
 │                                                                                 │
 │  max_active:      Limits concurrent work items per pool (per-CPU) or            │
 │                   system-wide (unbound). Default = WQ_DFL_ACTIVE (1024).        │
 │  min_active:      Minimum per-node concurrency for unbound WQs (default 8).     │
 │  Runtime tuning:  workqueue_set_max_active() / workqueue_set_min_active()       │
 │  Constraints:     Cannot tune BH or ordered workqueues                          │
 │  Periodic tasks:  Re-queue delayed_work inside handler (PENDING cleared         │
 │                   before handler runs, so re-queue is safe)                     │
 └─────────────────────────────────────────────────────────────────────────────────┘

 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │ Boot initialization                                                             │
 │                                                                                 │
 │  Stage 1: workqueue_init_early() — pools, system WQs. No workers yet.           │
 │  Stage 2: workqueue_init()       — create initial workers, rescuer threads.     │
 │  Stage 3: workqueue_init_topology() — NUMA/pod affinity scoping.                │
 └─────────────────────────────────────────────────────────────────────────────────┘
```
