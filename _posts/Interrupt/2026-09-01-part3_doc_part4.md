---
title: Interrupt Handling in the Linux Kernel — Part 4
published: true
categories: [Interrupt]
tags: [interrupt]
---
# Interrupt Handling in the Linux Kernel — Part 4: Top Halves, Bottom Halves, and Softirqs

> **Part 1** covers handler registration, IRQ data structures, forced threading, flags, shared interrupts, the full execution path, masking/unmasking, and IRQ affinity: `part3_doc_part1.md`
>
> **Part 2** covers interrupt control APIs (`local_irq_*`, `disable_irq`), execution context, `preempt_count`, `current` in ISR, and why sleeping is forbidden: `part3_doc_part2.md`
>
> **Part 3** covers threaded IRQ in depth: `request_irq()` vs `request_threaded_irq()`, thread function execution, `IRQF_ONESHOT`, and the difference from classic bottom halves: `part3_doc_part3.md`

When a hardware interrupt fires, the processor stops whatever it was doing, saves state, and jumps to the kernel's interrupt entry point. From that moment, every microsecond the handler spends running is a microsecond during which the local CPU cannot process any other interrupt — the timer tick, the network card, the storage controller — all pend silently at the GIC. The kernel resolves this tension with a fundamental architectural pattern: split the work into a **top half** that runs fast in hardirq context and a **bottom half** that does the slow work later. This document covers the bottom-half mechanisms in depth, focusing on **softirqs** — the lowest-level deferred-execution framework in the kernel — with architecture-specific detail for AArch64. It also covers `ksoftirqd`, `local_bh_disable`/`local_bh_enable`, and the interaction between spinlock variants and interrupt state.

---

## Table of Contents

1. [Why Split Into Top Half and Bottom Half?](#why-split-into-top-half-and-bottom-half)
2. [Top Half and Bottom Half: The Execution Model](#top-half-and-bottom-half-the-execution-model)
3. [The Bottom-Half Mechanisms](#the-bottom-half-mechanisms)
4. [Softirqs: Architecture and Data Structures](#softirqs-architecture-and-data-structures)
5. [The softirq_action Structure](#the-softirq_action-structure)
6. [The Ten Softirq Vectors](#the-ten-softirq-vectors)
7. [Registering a Softirq Handler: open_softirq](#registering-a-softirq-handler-open_softirq)
8. [Raising a Softirq: raise_softirq](#raising-a-softirq-raise_softirq)
9. [The Per-CPU Pending Bitmask](#the-per-cpu-pending-bitmask)
10. [How Softirqs Are Executed: handle_softirqs](#how-softirqs-are-executed-handle_softirqs)
11. [When Are Pending Softirqs Actually Run?](#when-are-pending-softirqs-actually-run)
12. [Are Hardware Interrupts Enabled During Softirq Execution?](#are-hardware-interrupts-enabled-during-softirq-execution)
13. [Does the Softirq Run on the Same CPU Where the Interrupt Occurred?](#does-the-softirq-run-on-the-same-cpu-where-the-interrupt-occurred)
14. [Softirq Execution Context: Hardirq or Softirq or Process?](#softirq-execution-context-hardirq-or-softirq-or-process)
15. [The Softirq Stack on AArch64](#the-softirq-stack-on-aarch64)
16. [The Value of current While Running in a Softirq](#the-value-of-current-while-running-in-a-softirq)
17. [Rules and Constraints While Running in Softirq Context](#rules-and-constraints-while-running-in-softirq-context)
18. [How to Detect Whether You Are Running in Softirq Context](#how-to-detect-whether-you-are-running-in-softirq-context)
19. [Checking Per-CPU Softirq Statistics: /proc/softirqs](#checking-per-cpu-softirq-statistics-procsoftirqs)
20. [Finding Pending Softirqs](#finding-pending-softirqs)
21. [Does Creating a New Softirq Require Recompiling the Kernel?](#does-creating-a-new-softirq-require-recompiling-the-kernel)
22. [ksoftirqd: The Per-CPU Softirq Thread](#ksoftirqd-the-per-cpu-softirq-thread)
23. [Disabling and Enabling Softirqs: local_bh_disable and local_bh_enable](#disabling-and-enabling-softirqs-local_bh_disable-and-local_bh_enable)
24. [Interrupt State Under Different Spinlock Variants](#interrupt-state-under-different-spinlock-variants)
25. [Summary](#summary)

---

## Why Split Into Top Half and Bottom Half?

A hardware interrupt handler runs with **local interrupts disabled** on the current CPU. On AArch64, the entry path sets `PSTATE.I=1` and `PSTATE.F=1` via `write_sysreg(DAIF_PROCCTX_NOIRQ, daif)` at [arch/arm64/kernel/entry-common.c, line 517](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry-common.c#L517). This means:

- **No other interrupt** can be delivered to this CPU while the handler runs.
- **Every microsecond** spent in the handler increases interrupt latency for all other devices.
- The **timer tick** is delayed, so the scheduler cannot preempt tasks and time accounting drifts.
- **Network packets** queue up, **disk completions** pend, and **user input** stalls.

Some devices need extensive processing when an interrupt fires — reading a block of data from an I2C bus, processing an incoming network packet through the protocol stack, or walking a USB descriptor tree. Doing all of this with interrupts disabled would be catastrophic for system responsiveness.

The solution is to split the work:

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │                        THE TOP/BOTTOM HALF PATTERN                              │
 ├────────────────────────────────────────┬────────────────────────────────────────┤
 │   TOP HALF (hardirq handler)           │   BOTTOM HALF (deferred work)          │
 │   ════════════════════════════         │   ═══════════════════════════          │
 │                                        │                                        │
 │   • Runs in hardirq context            │   • Runs later, in a less              │
 │   • Interrupts DISABLED on             │     restricted context                 │
 │     local CPU (PSTATE.I=1)             │   • Interrupts ENABLED                 │
 │   • Must be FAST                       │   • Can take its time                  │
 │   • Acknowledge the device             │   • Process the data                   │
 │   • Copy time-critical data            │   • Update data structures             │
 │   • Schedule the bottom half           │   • Call into subsystems               │
 │   • Return immediately                 │   • (May or may not sleep,             │
 │                                        │     depending on mechanism)            │
 │                                        │                                        │
 │   Duration: microseconds               │   Duration: can be longer              │
 └────────────────────────────────────────┴────────────────────────────────────────┘
```

The **top half** does only what must be done immediately: acknowledge the interrupt at the device level, copy any data that might be lost (e.g., from a hardware FIFO that will overflow), and schedule the bottom half. Then it returns, allowing the CPU to re-enable interrupts and service other devices.

The **bottom half** performs the bulk of the work — parsing packets, updating file system metadata, completing I/O requests — in a context where interrupts are enabled and (depending on the mechanism) sleeping may be possible.

---

## Top Half and Bottom Half: The Execution Model

```
 Hardware Interrupt Lifecycle
 ════════════════════════════

 Device asserts IRQ line
         │
         ▼
 GIC delivers interrupt to target CPU
         │
         ▼
 CPU takes exception to EL1
         │
         ▼
 ┌─────────────────────────────────┐
 │         TOP HALF                │
 │      (hardirq handler)          │
 │                                 │
 │  PSTATE.I = 1  (IRQs OFF)      │
 │  in_hardirq() = true            │
 │  Cannot sleep                   │
 │                                 │
 │  1. Acknowledge device          │
 │  2. Grab urgent data            │
 │  3. Schedule bottom half        │
 │  4. Return IRQ_HANDLED          │
 └───────────────┬─────────────────┘
                 │
                 ▼
 ┌─────────────────────────────────┐
 │          irq_exit()             │
 │                                 │
 │  preempt_count -= HARDIRQ_OFFSET│
 │                                 │
 │  Pending softirqs?              │
 └─────────┬───────────┬───────────┘
          YES          NO
           │            │
           ▼            ▼
 ┌──────────────────┐  Return to
 │   BOTTOM HALF    │  interrupted
 │                  │  code
 │  Softirq handler │
 │  or ksoftirqd    │
 │  or workqueue    │
 │                  │
 │  PSTATE.I = 0    │
 │  Interrupts ON   │
 │  Bulk processing │
 └──────────────────┘
```

The execution model has a hard constraint: the top half must be **as short as possible**. The kernel even verifies this — `__handle_irq_event_percpu()` at [kernel/irq/handle.c, lines 214–216](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/irq/handle.c#L214-L216) warns if a handler re-enables interrupts, and the runtime monitors for handlers that take excessively long.

---

## The Bottom-Half Mechanisms

The Linux kernel provides four mechanisms for deferring work from interrupt context. They differ in execution context, sleeping capability, concurrency model, and overhead:

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │                         BOTTOM-HALF MECHANISMS                                  │
 ├────────────────────┬─────────────────┬─────────────────────┬────────────────────┤
 │      Softirq       │     Tasklet     │      Workqueue      │    Threaded IRQ    │
 ├────────────────────┼─────────────────┼─────────────────────┼────────────────────┤
 │ 10 static vectors  │ Dynamic, any    │ kworker threads     │ irq/N-name thread  │
 │ compiled into      │ module can      │ (process context)   │ (per IRQ line)     │
 │ the kernel         │ create them     │                     │                    │
 ├────────────────────┼─────────────────┼─────────────────────┼────────────────────┤
 │ Softirq context    │ Softirq context │ Process context     │ Process context    │
 │ in_serving_        │ (runs inside    │ in_task() = true    │ in_task() = true   │
 │   softirq() = T    │  softirq)       │                     │                    │
 ├────────────────────┼─────────────────┼─────────────────────┼────────────────────┤
 │ CANNOT sleep       │ CANNOT sleep    │ CAN sleep           │ CAN sleep          │
 ├────────────────────┼─────────────────┼─────────────────────┼────────────────────┤
 │ IRQs: ENABLED      │ IRQs: ENABLED   │ IRQs: ENABLED       │ IRQs: ENABLED      │
 ├────────────────────┼─────────────────┼─────────────────────┼────────────────────┤
 │ Same softirq can   │ Same tasklet    │ Multiple workers    │ One thread per     │
 │ run on multiple    │ serialized      │ can run in          │ IRQ line           │
 │ CPUs at once       │ (one CPU only)  │ parallel            │                    │
 ├────────────────────┼─────────────────┼─────────────────────┼────────────────────┤
 │ Highest throughput │ Simpler than    │ Full scheduler      │ Tight binding to   │
 │ Lowest latency     │ softirq, auto   │ support: priority,  │ specific IRQ       │
 │ Most complex       │ serialization   │ affinity, cgroups   │ SCHED_FIFO prio 50 │
 ├────────────────────┼─────────────────┼─────────────────────┼────────────────────┤
 │ Used for:          │ Used for:       │ Used for:           │ Used for:          │
 │ NET_RX, TIMER,     │ Legacy driver   │ Filesystem work,    │ I2C reads, PMIC    │
 │ BLOCK, RCU, SCHED  │ bottom halves   │ slow device I/O,    │ handling, level-   │
 │                    │                 │ deferred probe      │ triggered + ONESHOT │
 └────────────────────┴─────────────────┴─────────────────────┴────────────────────┘
```

This document focuses primarily on **softirqs**, with tasklets and workqueues covered in dedicated sections at the end.

---

## Softirqs: Architecture and Data Structures

**Softirqs** are the kernel's lowest-level deferred-execution mechanism. They run immediately after a hardirq handler completes (or at explicit processing points), with hardware interrupts **re-enabled** but `preempt_count` set to prevent scheduling. They are designed for the highest-throughput bottom-half work in the kernel — network packet processing, timer callbacks, block I/O completion, and RCU.

The key properties of softirqs:

- **Statically defined** — there are exactly **10 softirq vectors** compiled into the kernel. You cannot add a new one from a module.
- **Per-CPU pending bitmask** — each CPU has its own 32-bit bitmask tracking which softirqs are pending. Raising a softirq sets a bit; the processing loop clears and iterates the mask.
- **Re-entrant across CPUs** — the same softirq type can execute simultaneously on different CPUs. The handler must use its own locking if it accesses shared data.
- **Not re-entrant on the same CPU** — a softirq cannot preempt another softirq on the same CPU. The `SOFTIRQ_OFFSET` in `preempt_count` prevents this.

```
 Softirq Data Structure Relationships
 ═════════════════════════════════════

 include/linux/interrupt.h                      kernel/softirq.c
 ┌──────────────────────────────┐               ┌──────────────────────────────────────┐
 │  enum {                      │               │  static struct softirq_action        │
 │    HI_SOFTIRQ = 0,           │  indexes      │    softirq_vec[NR_SOFTIRQS]          │
 │    TIMER_SOFTIRQ,            │ ────────────► │    __cacheline_aligned_in_smp;       │
 │    NET_TX_SOFTIRQ,           │               │                                      │
 │    ...                       │               │  ┌────────────────────────────────┐   │
 │    RCU_SOFTIRQ,              │               │  │ [0] .action = tasklet_hi_action│   │
 │    NR_SOFTIRQS               │               │  │ [1] .action = run_timer_softirq│   │
 │  };                          │               │  │ [2] .action = net_tx_action    │   │
 └──────────────────────────────┘               │  │ [3] .action = net_rx_action    │   │
                                                │  │ [4] .action = blk_done_softirq │   │
 ┌──────────────────────────────┐               │  │ [5] .action = irq_poll_softirq │   │
 │  struct softirq_action {     │               │  │ [6] .action = tasklet_action   │   │
 │    void (*action)(void);     │               │  │ [7] .action = sched_bal_softirq│   │
 │  };                          │               │  │ [8] .action = hrtimer_run_si   │   │
 └──────────────────────────────┘               │  │ [9] .action = rcu_core_si      │   │
                                                │  └────────────────────────────────┘   │
 include/asm-generic/hardirq.h                  └──────────────────────────────────────┘
 ┌──────────────────────────────┐
 │  typedef struct {            │    Per-CPU instance (one per CPU):
 │    unsigned int              │    ┌──────────────────────────────────────────────┐
 │      __softirq_pending;      │    │  DEFINE_PER_CPU_ALIGNED(irq_cpustat_t,      │
 │  } irq_cpustat_t;            │    │                         irq_stat);           │
 └──────────────────────────────┘    └──────────────────────────────────────────────┘
```

---

## The softirq_action Structure

Each softirq vector is represented by a **`struct softirq_action`**, defined in [include/linux/interrupt.h, lines 590–593](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/interrupt.h#L590-L593):

```c
struct softirq_action
{
    void	(*action)(void);
};
```

The structure contains a single function pointer — the handler to call when this softirq is processed. The simplicity is intentional: softirqs are a minimal, high-performance mechanism. There is no per-invocation data pointer, no priority field, no linked list — just a function to call.

The kernel maintains an array of 10 such structures, one per softirq vector, at [kernel/softirq.c, line 60](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/softirq.c#L60):

```c
static struct softirq_action softirq_vec[NR_SOFTIRQS] __cacheline_aligned_in_smp;
```

The `__cacheline_aligned_in_smp` attribute ensures the array is aligned to a cache line boundary on SMP systems, preventing false sharing when different CPUs access different softirq handlers.

---

## The Ten Softirq Vectors

The softirq vectors are defined as an enum in [include/linux/interrupt.h, lines 550–563](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/interrupt.h#L550-L563):

```c
enum
{
    HI_SOFTIRQ=0,
    TIMER_SOFTIRQ,
    NET_TX_SOFTIRQ,
    NET_RX_SOFTIRQ,
    BLOCK_SOFTIRQ,
    IRQ_POLL_SOFTIRQ,
    TASKLET_SOFTIRQ,
    SCHED_SOFTIRQ,
    HRTIMER_SOFTIRQ,
    RCU_SOFTIRQ,    /* Preferable RCU should always be the last softirq */

    NR_SOFTIRQS
};
```

The human-readable names are defined in [kernel/softirq.c, lines 64–67](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/softirq.c#L64-L67):

```c
const char * const softirq_to_name[NR_SOFTIRQS] = {
    "HI", "TIMER", "NET_TX", "NET_RX", "BLOCK", "IRQ_POLL",
    "TASKLET", "SCHED", "HRTIMER", "RCU"
};
```

The **order matters** — softirqs are processed from index 0 (highest priority) to index 9 (lowest). `HI_SOFTIRQ` runs before `TIMER_SOFTIRQ`, which runs before `NET_TX_SOFTIRQ`, and so on.

Each vector has a specific handler registered via `open_softirq()`:

```
 ┌──────────────────────────────────────────────────────────────────────────────────┐
 │  Vector              Index   Handler                     Registered In           │
 │  ──────────────────  ─────   ──────────────────────────  ────────────────────── │
 │  HI_SOFTIRQ          0      tasklet_hi_action           kernel/softirq.c:1060   │
 │  TIMER_SOFTIRQ       1      run_timer_softirq           kernel/time/timer.c     │
 │  NET_TX_SOFTIRQ      2      net_tx_action               net/core/dev.c          │
 │  NET_RX_SOFTIRQ      3      net_rx_action               net/core/dev.c          │
 │  BLOCK_SOFTIRQ       4      blk_done_softirq            block/blk-mq.c          │
 │  IRQ_POLL_SOFTIRQ    5      irq_poll_softirq            lib/irq_poll.c          │
 │  TASKLET_SOFTIRQ     6      tasklet_action              kernel/softirq.c:1059   │
 │  SCHED_SOFTIRQ       7      sched_balance_softirq       kernel/sched/fair.c     │
 │  HRTIMER_SOFTIRQ     8      hrtimer_run_softirq         kernel/time/hrtimer.c   │
 │  RCU_SOFTIRQ         9      rcu_core_si                 kernel/rcu/tree.c       │
 └──────────────────────────────────────────────────────────────────────────────────┘

 Priority:  ◄─── HIGHEST (0)                                   LOWEST (9) ───►
            HI  TIMER  NET_TX  NET_RX  BLOCK  IRQ_POLL  TASKLET  SCHED  HRTIMER  RCU
             │                                                                    │
             └── Processed first by ffs()                     Processed last ────┘
```

The comment above the enum in the kernel source explicitly warns against adding new vectors ([include/linux/interrupt.h, lines 544–548](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/interrupt.h#L544-L548)):

```
/* PLEASE, avoid to allocate new softirqs, if you need not _really_ high
   frequency threaded job scheduling. For almost all the purposes
   tasklets are more than enough. */
```

---

## Registering a Softirq Handler: open_softirq

A softirq handler is registered by calling **`open_softirq()`**, defined at [kernel/softirq.c, lines 806–809](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/softirq.c#L806-L809):

```c
void open_softirq(int nr, void (*action)(void))
{
    softirq_vec[nr].action = action;
}
```

The function simply stores the handler function pointer into the `softirq_vec` array at the given index. There is no locking, no validation, no reference counting — `open_softirq()` is called during kernel initialization, before SMP is active, so no concurrency protection is needed.

```
 Softirq Registration During Boot
 ═════════════════════════════════

 start_kernel()
     │
     ├── softirq_init()                          kernel/softirq.c
     │     ├── Initialize per-CPU tasklet lists
     │     ├── open_softirq(TASKLET_SOFTIRQ, tasklet_action)
     │     └── open_softirq(HI_SOFTIRQ, tasklet_hi_action)
     │
     ├── init_timers()                           kernel/time/timer.c
     │     └── open_softirq(TIMER_SOFTIRQ, run_timer_softirq)
     │
     ├── hrtimers_init()                         kernel/time/hrtimer.c
     │     └── open_softirq(HRTIMER_SOFTIRQ, hrtimer_run_softirq)
     │
     ├── net_dev_init()                          net/core/dev.c
     │     ├── open_softirq(NET_TX_SOFTIRQ, net_tx_action)
     │     └── open_softirq(NET_RX_SOFTIRQ, net_rx_action)
     │
     ├── blk_softirq_init()                      block/blk-mq.c
     │     └── open_softirq(BLOCK_SOFTIRQ, blk_done_softirq)
     │
     ├── rcu_init()                              kernel/rcu/tree.c
     │     └── open_softirq(RCU_SOFTIRQ, rcu_core_si)
     │
     └── sched_init()                            kernel/sched/fair.c
           └── open_softirq(SCHED_SOFTIRQ, sched_balance_softirq)
```

For example, during kernel boot, **`softirq_init()`** at [kernel/softirq.c, lines 1048–1061](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/softirq.c#L1048-L1061) registers the two tasklet softirqs:

```c
void __init softirq_init(void)
{
    int cpu;

    for_each_possible_cpu(cpu) {
        per_cpu(tasklet_vec, cpu).tail = &per_cpu(tasklet_vec, cpu).head;
        per_cpu(tasklet_hi_vec, cpu).tail = &per_cpu(tasklet_hi_vec, cpu).head;
    }

    open_softirq(TASKLET_SOFTIRQ, tasklet_action);
    open_softirq(HI_SOFTIRQ, tasklet_hi_action);
}
```

And the networking subsystem registers its softirqs during `net_dev_init()`:

```c
/* net/core/dev.c */
open_softirq(NET_TX_SOFTIRQ, net_tx_action);
open_softirq(NET_RX_SOFTIRQ, net_rx_action);
```

Since there are only 10 vectors and all are registered during boot, **you cannot register a softirq from a loadable module**. The vector indices are compile-time constants in the kernel's enum. **This is by design — softirqs are reserved for the kernel's highest-throughput subsystems.**

---

## Raising a Softirq: raise_softirq

To mark a softirq as pending (requesting that it be processed at the next opportunity), the kernel calls **`raise_softirq()`** or its interrupt-safe variant **`raise_softirq_irqoff()`**.

```
 raise_softirq() Call Hierarchy
 ══════════════════════════════

 raise_softirq(nr)                                    kernel/softirq.c:790-797
   │
   ├── local_irq_save(flags)          ← save IRQ state, disable IRQs
   │
   ├── raise_softirq_irqoff(nr)                       kernel/softirq.c:773-788
   │     │
   │     ├── __raise_softirq_irqoff(nr)               kernel/softirq.c:799-804
   │     │     │
   │     │     ├── lockdep_assert_irqs_disabled()
   │     │     ├── trace_softirq_raise(nr)
   │     │     └── or_softirq_pending(1UL << nr)      ← SET THE BIT
   │     │
   │     └── if (!in_interrupt() && should_wake_ksoftirqd())
   │           └── wakeup_softirqd()  ← only if raised from process context
   │
   └── local_irq_restore(flags)       ← restore IRQ state
```

**`raise_softirq()`** at [kernel/softirq.c, lines 790–797](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/softirq.c#L790-L797) wraps the operation with interrupt save/restore:

```c
void raise_softirq(unsigned int nr)
{
    unsigned long flags;

    local_irq_save(flags);
    raise_softirq_irqoff(nr);
    local_irq_restore(flags);
}
```

**`raise_softirq_irqoff()`** at [kernel/softirq.c, lines 773–788](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/softirq.c#L773-L788) is the version called when interrupts are already disabled (e.g., from inside a hardirq handler):

```c
inline void raise_softirq_irqoff(unsigned int nr)
{
    __raise_softirq_irqoff(nr);

    if (!in_interrupt() && should_wake_ksoftirqd())
        wakeup_softirqd();
}
```

The core operation is **`__raise_softirq_irqoff()`** at [kernel/softirq.c, lines 799–804](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/softirq.c#L799-L804):

```c
void __raise_softirq_irqoff(unsigned int nr)
{
    lockdep_assert_irqs_disabled();
    trace_softirq_raise(nr);
    or_softirq_pending(1UL << nr);
}
```

This is the moment the softirq becomes pending: `or_softirq_pending(1UL << nr)` performs a per-CPU **OR** of `(1 << nr)` into the pending bitmask. For example, raising `NET_RX_SOFTIRQ` (index 3) ORs `0x00000008` into the current CPU's `__softirq_pending` field.

```
 raise_softirq(NET_RX_SOFTIRQ) — bitmask operation
 ═══════════════════════════════════════════════════

 or_softirq_pending(1UL << 3) on CPU 2:

 ┌───────────────────────────────────────────────────────────────┐
 │  CPU 2's __softirq_pending:                                   │
 │                                                               │
 │  Before:  0b 0000 0000 0000 0000 0000 0000 0000 0010          │
 │                                                     ▲         │
 │                                                     │         │
 │                                              TIMER (bit 1)    │
 │                                                               │
 │  OR mask: 0b 0000 0000 0000 0000 0000 0000 0000 1000          │
 │                                                  ▲            │
 │                                                  │            │
 │                                          NET_RX (bit 3)       │
 │                                                               │
 │  After:   0b 0000 0000 0000 0000 0000 0000 0000 1010          │
 │                                                  ▲  ▲         │
 │                                                  │  │         │
 │                                          NET_RX  TIMER        │
 └───────────────────────────────────────────────────────────────┘
```

The `if (!in_interrupt() && should_wake_ksoftirqd())` check in `raise_softirq_irqoff()` handles the case where a softirq is raised from process context (not from a hardirq handler). In that case, there is no upcoming `irq_exit()` to process it, so `ksoftirqd` is woken to handle it.

When called from hardirq context (the common case), `in_interrupt()` returns true and `ksoftirqd` is not woken — the softirq will be processed when `irq_exit()` is called at the end of the hardirq handler.

```
 raise_softirq_irqoff() — two calling contexts
 ═══════════════════════════════════════════════

 CASE 1: Called from hardirq context (common)
 ─────────────────────────────────────────────
 in_interrupt() = true  →  ksoftirqd NOT woken
 Softirq will be processed at irq_exit() → invoke_softirq()

 CASE 2: Called from process context
 ────────────────────────────────────
 in_interrupt() = false  →  wakeup_softirqd()
 No upcoming irq_exit(), so ksoftirqd must process it
```

---

## The Per-CPU Pending Bitmask

Each CPU maintains its own **`__softirq_pending`** bitmask — a 32-bit unsigned integer inside a per-CPU `irq_cpustat_t` structure. The type is defined in [include/asm-generic/hardirq.h, lines 8–13](https://github.com/torvalds/linux/blob/v7.2-rc5/include/asm-generic/hardirq.h#L8-L13):

```c
typedef struct {
    unsigned int __softirq_pending;
} ____cacheline_aligned irq_cpustat_t;
```

AArch64 does not define `__ARCH_IRQ_STAT`, so the generic per-CPU instantiation at [kernel/softirq.c, lines 55–58](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/softirq.c#L55-L58) is used:

```c
#ifndef __ARCH_IRQ_STAT
DEFINE_PER_CPU_ALIGNED(irq_cpustat_t, irq_stat);
EXPORT_PER_CPU_SYMBOL(irq_stat);
#endif
```

The accessor macros are defined in [include/linux/interrupt.h, lines 522–532](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/interrupt.h#L522-L532):

```c
#define local_softirq_pending_ref   irq_stat.__softirq_pending

#define local_softirq_pending()     (__this_cpu_read(local_softirq_pending_ref))
#define set_softirq_pending(x)      (__this_cpu_write(local_softirq_pending_ref, (x)))
#define or_softirq_pending(x)       (__this_cpu_or(local_softirq_pending_ref, (x)))
```

### Why Per-CPU?

```
 ┌───────────────────────────────────────────────────────────────────────────────┐
 │                   PER-CPU SOFTIRQ BITMASK — WHY IT MATTERS                    │
 ├───────────────────────────────────────────────────────────────────────────────┤
 │                                                                               │
 │  1. NO LOCKING REQUIRED                                                       │
 │     Each CPU reads/writes only its own bitmask.                               │
 │     or_softirq_pending() uses __this_cpu_or() — a single instruction          │
 │     that operates on the local CPU's per-CPU data without any lock,           │
 │     atomic operation, or memory barrier.                                      │
 │                                                                               │
 │  2. NO CACHE BOUNCING                                                         │
 │     If the bitmask were global, every raise_softirq() on any CPU              │
 │     would invalidate all other CPUs' cache lines containing the               │
 │     bitmask — a catastrophic scalability bottleneck on machines with          │
 │     hundreds of CPUs processing millions of interrupts per second.            │
 │                                                                               │
 │  3. NATURAL AFFINITY                                                          │
 │     A softirq raised by a hardirq handler on CPU 3 is processed on            │
 │     CPU 3. The data the hardirq handler just touched is hot in CPU 3's        │
 │     cache — processing the softirq on the same CPU gets cache hits.           │
 │                                                                               │
 │  4. NO CROSS-CPU SYNCHRONIZATION                                              │
 │     Processing softirqs does not require coordinating with other CPUs.        │
 │     handle_softirqs() reads the local pending mask, clears it, and            │
 │     iterates — all per-CPU operations.                                        │
 └───────────────────────────────────────────────────────────────────────────────┘
```

```
 Per-CPU Bitmask Snapshot (4-CPU system)
 ═══════════════════════════════════════

 CPU 0                    CPU 1                    CPU 2                    CPU 3
 ┌───────────────────┐    ┌───────────────────┐    ┌───────────────────┐    ┌───────────────────┐
 │ __softirq_pending  │    │ __softirq_pending  │    │ __softirq_pending  │    │ __softirq_pending  │
 │ = 0x00000002       │    │ = 0x00000000       │    │ = 0x00000108       │    │ = 0x00000008       │
 │                    │    │                    │    │                    │    │                    │
 │ Bit 1: TIMER       │    │ (nothing pending)  │    │ Bit 3: NET_RX      │    │ Bit 3: NET_RX      │
 │                    │    │                    │    │ Bit 8: HRTIMER     │    │                    │
 └────────┬───────────┘    └───────────────────┘    └────────┬───────────┘    └────────┬───────────┘
          │                                                  │                         │
          ▼                                                  ▼                         ▼
   Processes TIMER                                    Processes NET_RX          Processes NET_RX
   on CPU 0                                           then HRTIMER              on CPU 3
                                                      on CPU 2
```

---

## How Softirqs Are Executed: handle_softirqs

The core softirq processing function is **`handle_softirqs()`** at [kernel/softirq.c, lines 579–652](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/softirq.c#L579-L652). This is the function that actually iterates the pending bitmask and calls each softirq handler:

```c
static void handle_softirqs(bool ksirqd)
{
    unsigned long end = jiffies + MAX_SOFTIRQ_TIME;
    unsigned long old_flags = current->flags;
    int max_restart = MAX_SOFTIRQ_RESTART;
    struct softirq_action *h;
    bool in_hardirq;
    __u32 pending;
    int softirq_bit;

    current->flags &= ~PF_MEMALLOC;

    pending = local_softirq_pending();

    softirq_handle_begin();             /* preempt_count += SOFTIRQ_OFFSET */

    in_hardirq = lockdep_softirq_start();
    account_softirq_enter(current);

restart:
    set_softirq_pending(0);             /* clear pending bitmask */

    local_irq_enable();                 /* INTERRUPTS RE-ENABLED */

    h = softirq_vec;

    while ((softirq_bit = ffs(pending))) {
        unsigned int vec_nr;
        int prev_count;

        h += softirq_bit - 1;
        vec_nr = h - softirq_vec;
        prev_count = preempt_count();

        kstat_incr_softirqs_this_cpu(vec_nr);
        trace_softirq_entry(vec_nr);
        h->action();                    /* CALL THE SOFTIRQ HANDLER */
        trace_softirq_exit(vec_nr);

        if (unlikely(prev_count != preempt_count())) {
            pr_err("huh, entered softirq %u %s %p with preempt_count %08x, "
                   "exited with %08x?\n",
                   vec_nr, softirq_to_name[vec_nr], h->action,
                   prev_count, preempt_count());
            preempt_count_set(prev_count);
        }

        h++;
        pending >>= softirq_bit;
    }

    if (!IS_ENABLED(CONFIG_PREEMPT_RT) && ksirqd)
        rcu_softirq_qs();

    local_irq_disable();                /* INTERRUPTS DISABLED AGAIN */

    pending = local_softirq_pending();
    if (pending) {
        if (time_before(jiffies, end) && !need_resched() && --max_restart)
            goto restart;

        wakeup_softirqd();              /* defer remaining to ksoftirqd */
    }

    account_softirq_exit(current);
    lockdep_softirq_end(in_hardirq);
    softirq_handle_end();               /* preempt_count -= SOFTIRQ_OFFSET */
    current_restore_flags(old_flags, PF_MEMALLOC);
}
```

### Execution Flow Step by Step

```
 handle_softirqs() Execution Flow
 ═════════════════════════════════

 ┌─────────────────────────────────────────────────────────────────────────────┐
 │  1. Read local_softirq_pending() → pending                                 │
 │                                                                             │
 │  2. softirq_handle_begin()                                                  │
 │       └── preempt_count += SOFTIRQ_OFFSET (0x100)                           │
 │       ┌──────────────────────────────────────────────────────┐              │
 │       │ Now: in_serving_softirq() = true                     │              │
 │       │      in_task() = false                               │              │
 │       │      Sleeping is FORBIDDEN                           │              │
 │       └──────────────────────────────────────────────────────┘              │
 │                                                                             │
 │  3. set_softirq_pending(0)                                                  │
 │       └── Clear bitmask (new softirqs raised during processing              │
 │           will set fresh bits)                                              │
 │                                                                             │
 │  4. local_irq_enable()                                                      │
 │       └── HARDWARE INTERRUPTS RE-ENABLED                                    │
 │       ┌──────────────────────────────────────────────────────┐              │
 │       │ A hardirq CAN preempt this softirq handler.          │              │
 │       │ If a hardirq fires, it runs, may raise more          │              │
 │       │ softirqs, and returns here.                          │              │
 │       └──────────────────────────────────────────────────────┘              │
 │                                                                             │
 │  5. Loop: ffs(pending) finds lowest set bit                                 │
 │       └── Call h->action() for each pending softirq                         │
 │           In priority order: HI(0), TIMER(1), NET_TX(2), ...                │
 │           Verify preempt_count unchanged after each handler                 │
 │                                                                             │
 │  6. local_irq_disable()                                                     │
 │       └── HARDWARE INTERRUPTS DISABLED                                      │
 │                                                                             │
 │  7. Re-read local_softirq_pending()                                         │
 │       │                                                                     │
 │       ├── New softirqs pending?                                             │
 │       │     │                                                               │
 │       │    YES ──► time < 2ms AND restarts < 10 AND !need_resched()?        │
 │       │            │                                                        │
 │       │           YES ──► goto step 3 (restart)                             │
 │       │            │                                                        │
 │       │            NO ──► wakeup_softirqd() (defer to ksoftirqd)            │
 │       │                                                                     │
 │       └── No ──► proceed to step 8                                          │
 │                                                                             │
 │  8. softirq_handle_end()                                                    │
 │       └── preempt_count -= SOFTIRQ_OFFSET                                   │
 └─────────────────────────────────────────────────────────────────────────────┘
```

### The Restart Limits

The restart-limiting constants are defined at [kernel/softirq.c, lines 530–544](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/softirq.c#L530-L544):

```c
#define MAX_SOFTIRQ_TIME  msecs_to_jiffies(2)
#define MAX_SOFTIRQ_RESTART 10
```

These limits prevent softirq processing from monopolizing the CPU. High-throughput devices (e.g., a 100 Gbit NIC) can raise softirqs faster than they are processed. Without limits, `handle_softirqs()` would loop forever, starving user-space processes. The three conditions for a restart are:

1. **Time**: less than 2 milliseconds have elapsed since `handle_softirqs()` started.
2. **Restart count**: fewer than 10 restarts have occurred.
3. **Scheduler**: `need_resched()` is false — no higher-priority task is waiting.

If any condition fails, `wakeup_softirqd()` is called to defer the remaining softirqs to the per-CPU `ksoftirqd` kernel thread.

```
 Restart Decision Logic
 ══════════════════════

 After processing all pending softirqs:

                     ┌──────────────────────────────────┐
                     │  local_softirq_pending() != 0 ?  │
                     └──────────┬───────────┬────────────┘
                               YES          NO
                                │            │
                                ▼            ▼
                     ┌────────────────┐    Done — return
                     │ time < 2 ms ?  │
                     └───┬────────┬───┘
                        YES       NO
                         │         │
                         ▼         ▼
                  ┌──────────┐   wakeup_softirqd()
                  │ restarts │   (defer to ksoftirqd)
                  │  < 10 ?  │
                  └──┬────┬──┘
                    YES    NO
                     │      │
                     ▼      ▼
              ┌──────────┐  wakeup_softirqd()
              │ !need_   │
              │ resched()│
              │    ?     │
              └──┬────┬──┘
                YES    NO
                 │      │
                 ▼      ▼
              goto    wakeup_softirqd()
              restart
```

### The softirq_handle_begin / softirq_handle_end Pair

These functions mark the entry and exit of softirq context by manipulating `preempt_count`, defined at [kernel/softirq.c, lines 461–470](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/softirq.c#L461-L470):

```c
static inline void softirq_handle_begin(void)
{
    __local_bh_disable_ip(_RET_IP_, SOFTIRQ_OFFSET);
}

static inline void softirq_handle_end(void)
{
    __local_bh_enable(SOFTIRQ_OFFSET);
    WARN_ON_ONCE(in_interrupt());
}
```

**`softirq_handle_begin()`** adds `SOFTIRQ_OFFSET` (0x100) to `preempt_count`, setting bit 8. This is the marker that says "we are inside a softirq handler." The value 0x100 is critically different from the 0x200 used by `local_bh_disable()` — this distinction is what allows `in_serving_softirq()` to work correctly (discussed later).

---

## When Are Pending Softirqs Actually Run?

Softirqs are processed at **three specific points** in the kernel:

```
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │                        WHERE SOFTIRQS ARE PROCESSED                             │
 ├─────────────────────────────────────────────────────────────────────────────────┤
 │                                                                                 │
 │  1. AT irq_exit()                                                               │
 │     ─────────────                                                               │
 │     After every hardirq handler completes.                                      │
 │     __irq_exit_rcu() checks local_softirq_pending() and calls                   │
 │     invoke_softirq() if pending and not in nested interrupt context.             │
 │     This is the MOST COMMON trigger.                                            │
 │                                                                                 │
 │  2. AT local_bh_enable()                                                        │
 │     ────────────────────                                                        │
 │     When code that called local_bh_disable() re-enables bottom halves.          │
 │     __local_bh_enable_ip() checks local_softirq_pending() and calls             │
 │     do_softirq() if pending.                                                    │
 │                                                                                 │
 │  3. IN ksoftirqd                                                                │
 │     ────────────                                                                │
 │     A per-CPU kernel thread that runs when:                                     │
 │     - handle_softirqs() exceeded its restart budget (10 restarts / 2ms)         │
 │     - force_irqthreads() is active (PREEMPT_RT or threadirqs boot param)        │
 │     - A softirq was raised from process context (not from a hardirq)            │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

### Point 1: At irq_exit() — The Most Common Path

The function **`__irq_exit_rcu()`** at [kernel/softirq.c, lines 720–743](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/softirq.c#L720-L743) is called at the end of every hardware interrupt:

```c
static inline void __irq_exit_rcu(void)
{
#ifndef __ARCH_IRQ_EXIT_IRQS_DISABLED
    local_irq_disable();
#else
    lockdep_assert_irqs_disabled();
#endif
    account_hardirq_exit(current);
    preempt_count_sub(HARDIRQ_OFFSET);
    if (!in_interrupt() && local_softirq_pending())
        invoke_softirq();
    /* ... */
}
```

AArch64 defines `__ARCH_IRQ_EXIT_IRQS_DISABLED` at [arch/arm64/include/asm/hardirq.h, line 19](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/hardirq.h#L19), so it asserts IRQs are already disabled rather than disabling them again — the AArch64 exception return path keeps PSTATE.I set at this point.

The critical check is `!in_interrupt() && local_softirq_pending()`. After `preempt_count_sub(HARDIRQ_OFFSET)`, `in_interrupt()` returns false only if we are not in a nested interrupt and no `local_bh_disable()` is active. If there are pending softirqs, `invoke_softirq()` is called.

**`invoke_softirq()`** at [kernel/softirq.c, lines 487–508](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/softirq.c#L487-L508) decides how to process them:

```c
static inline void invoke_softirq(void)
{
    if (!force_irqthreads() || !__this_cpu_read(ksoftirqd)) {
#ifdef CONFIG_HAVE_IRQ_EXIT_ON_IRQ_STACK
        __do_softirq();
#else
        do_softirq_own_stack();
#endif
    } else {
        wakeup_softirqd();
    }
}
```

```
 invoke_softirq() Decision Tree on AArch64
 ══════════════════════════════════════════

 invoke_softirq()
       │
       ▼
 force_irqthreads() ?  ──────────────────────────────────────────────────┐
       │                                                                  │
      NO (normal)                                                    YES (RT)
       │                                                                  │
       ▼                                                                  ▼
 AArch64 does NOT define                                         wakeup_softirqd()
 CONFIG_HAVE_IRQ_EXIT_ON_IRQ_STACK                               (defer all to
       │                                                          ksoftirqd thread)
       ▼
 AArch64 DOES select
 HAVE_SOFTIRQ_ON_OWN_STACK
       │
       ▼
 do_softirq_own_stack()
       │
       ▼
 call_on_irq_stack(NULL, ____do_softirq)
       │
       ▼
 __do_softirq() → handle_softirqs(false)
 (runs on per-CPU IRQ stack)
```

When `force_irqthreads()` is true (the `threadirqs` boot parameter or `PREEMPT_RT`), softirqs are not processed inline — instead `wakeup_softirqd()` defers everything to `ksoftirqd`.

### Point 2: At local_bh_enable()

**`__local_bh_enable_ip()`** at [kernel/softirq.c, lines 427–458](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/softirq.c#L427-L458) checks for pending softirqs when re-enabling bottom halves:

```c
void __local_bh_enable_ip(unsigned long ip, unsigned int cnt)
{
    WARN_ON_ONCE(in_hardirq());
    lockdep_assert_irqs_enabled();
    /* ... */
    __preempt_count_sub(cnt - 1);

    if (unlikely(!in_interrupt() && local_softirq_pending())) {
        do_softirq();
    }

    preempt_count_dec();
    /* ... */
}
```

### Point 3: In ksoftirqd

The `ksoftirqd` thread processes softirqs in process context when inline processing is not possible or has been exhausted. This is discussed in its own section below.

### The Complete End-to-End Flow

```
 Complete Softirq Lifecycle: From Device Interrupt to Handler Execution
 ═══════════════════════════════════════════════════════════════════════

 ┌──────────┐     ┌──────────┐     ┌──────────────────────────────────────────┐
 │  Device   │     │   GIC    │     │  CPU 2 — running "myapp" in user space   │
 │  asserts  │────►│ delivers │────►│  CPU takes exception to EL1              │
 │  IRQ line │     │  to CPU2 │     └──────────────────┬───────────────────────┘
 └──────────┘     └──────────┘                         │
                                                       ▼
                                    ┌──────────────────────────────────────┐
                                    │  el1_interrupt()                      │
                                    │    write_sysreg(DAIF_PROCCTX_NOIRQ)  │
                                    │    preempt_count += HARDIRQ_OFFSET    │
                                    │    → gic_handle_irq()                │
                                    │      → handle_domain_irq()           │
                                    │        → my_hardirq_handler()        │
                                    │                                      │
                                    │  Inside handler:                      │
                                    │    ack device, grab data              │
                                    │    raise_softirq_irqoff(NET_RX)      │
                                    │      → or_softirq_pending(1<<3)      │
                                    │    return IRQ_HANDLED                │
                                    └──────────────────┬───────────────────┘
                                                       │
                                                       ▼
                                    ┌──────────────────────────────────────┐
                                    │  __irq_exit_rcu()                    │
                                    │    preempt_count -= HARDIRQ_OFFSET   │
                                    │    !in_interrupt()? ── YES            │
                                    │    local_softirq_pending()? ── YES   │
                                    │    → invoke_softirq()                │
                                    └──────────────────┬───────────────────┘
                                                       │
                                                       ▼
                                    ┌──────────────────────────────────────┐
                                    │  do_softirq_own_stack()              │
                                    │    → call_on_irq_stack()             │
                                    │      → handle_softirqs(false)        │
                                    │                                      │
                                    │    1. pending = 0x00000008           │
                                    │    2. softirq_handle_begin()         │
                                    │         preempt_count += 0x100       │
                                    │    3. set_softirq_pending(0)         │
                                    │    4. local_irq_enable()             │
                                    │    5. ffs(0x8) = 4 → vec_nr = 3     │
                                    │       → net_rx_action() runs         │
                                    │    6. local_irq_disable()            │
                                    │    7. Check for more pending         │
                                    │    8. softirq_handle_end()           │
                                    │         preempt_count -= 0x100       │
                                    └──────────────────┬───────────────────┘
                                                       │
                                                       ▼
                                    ┌──────────────────────────────────────┐
                                    │  Return to "myapp" in user space     │
                                    └──────────────────────────────────────┘
```

---

## Are Hardware Interrupts Enabled During Softirq Execution?

**Yes.** Hardware interrupts are **explicitly re-enabled** during softirq handler execution. The `handle_softirqs()` function calls `local_irq_enable()` at [kernel/softirq.c, line 606](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/softirq.c#L606) before entering the handler loop, and `local_irq_disable()` at [line 637](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/softirq.c#L637) after the loop completes.

This means:

- A **hardirq can preempt a softirq handler** at any point. If a device asserts an interrupt while `net_rx_action()` is processing packets, the CPU will take the hardirq exception, run the hardirq handler, and then return to the softirq handler.
- The hardirq handler may raise additional softirqs (by calling `raise_softirq_irqoff()`), which will be detected on the next pass through `handle_softirqs()`.
- A softirq handler should use `spin_lock_irqsave()` when accessing data shared with hardirq handlers — because a hardirq can arrive at any time.

```
 Timeline: Hardirq Preempting a Softirq on the Same CPU
 ══════════════════════════════════════════════════════

 ──────────────── Time ──────────────────────────────────────────────────────►

 Softirq    ║ net_rx_action() running       ║                               ║
 Handler    ║ (IRQs ENABLED, PSTATE.I=0)    ║                               ║
            ║                               ║                               ║
            ║                               ║  net_rx_action() resumes      ║
            ╠═══════════════╗               ╠═══════════════════════════════╣
                            ║               ║
 Hardirq                    ║  IRQ fires!   ║
 Handler                    ║               ║
                            ║ gic_handle_irq()
                            ║ handler() runs
                            ║ raise_softirq_irqoff()
                            ║ returns
                            ╚═══════════════╝

 preempt_count:  0x00000100  │  0x00010100   │  0x00000100
                 (softirq)   │ (hardirq+si)  │  (softirq)
```

**This is a critical difference from hardirq context, where interrupts are disabled throughout. The fact that softirq handlers run with interrupts enabled is what makes them suitable for potentially longer work — they do not block other interrupt delivery.**

### Module Example: Verifying IRQ State in a Softirq Handler

```c
void my_softirq_handler(void)
{
    if (irqs_disabled())
        pr_info("IRQs are DISABLED in softirq\n");
    else
        pr_info("IRQs are ENABLED in softirq\n");
    /* Expected output: IRQs are ENABLED in softirq */
}
```

---

## Does the Softirq Run on the Same CPU Where the Interrupt Occurred?

**Yes — in the common case.** The softirq is processed on the **same CPU** that ran the hardirq handler that raised it. **This is a direct consequence of the per-CPU pending bitmask design.**

When a hardirq handler calls `raise_softirq_irqoff(NET_RX_SOFTIRQ)`, it calls `or_softirq_pending(1UL << 3)`, which uses `__this_cpu_or()` to set the bit on **the current CPU's** pending mask. When `irq_exit()` subsequently calls `invoke_softirq()`, it reads `local_softirq_pending()` — which uses `__this_cpu_read()` — finding the bit set on **the same CPU**. The softirq handler then runs on that same CPU.

```
 CPU Affinity of Softirq Processing
 ═══════════════════════════════════

 CPU 0          CPU 1          CPU 2          CPU 3
 ┌────────┐    ┌────────┐    ┌────────┐    ┌────────┐
 │        │    │        │    │ NIC IRQ│    │        │
 │        │    │        │    │ fires  │    │        │
 │        │    │        │    │   │    │    │        │
 │        │    │        │    │   ▼    │    │        │
 │        │    │        │    │ hardirq│    │        │
 │        │    │        │    │ handler│    │        │
 │        │    │        │    │   │    │    │        │
 │        │    │        │    │   ▼    │    │        │
 │        │    │        │    │ raise_ │    │        │
 │        │    │        │    │ softirq│    │        │
 │        │    │        │    │ _irqoff│    │        │
 │        │    │        │    │ (bit 3)│    │        │
 │        │    │        │    │   │    │    │        │
 │        │    │        │    │   ▼    │    │        │
 │        │    │        │    │irq_exit│    │        │
 │        │    │        │    │   │    │    │        │
 │        │    │        │    │   ▼    │    │        │
 │        │    │        │    │net_rx_ │    │        │
 │        │    │        │    │action()│    │        │
 │        │    │        │    │ runs   │    │        │
 └────────┘    └────────┘    └────────┘    └────────┘
 pending=0     pending=0     pending was    pending=0
                             0x8, now 0

 Cache benefit: NIC ring buffer data is hot in CPU 2's L1/L2 cache
```

This locality is not just for convenience — it is essential for **cache performance**. The hardirq handler likely touched data structures (ring buffers, DMA descriptors, device registers) that are now hot in CPU 2's L1/L2 cache. Running the softirq on the same CPU means the softirq handler gets cache hits on that data rather than cache misses.

However, there is an exception: when `handle_softirqs()` exceeds its restart budget and defers work to **`ksoftirqd`**, the `ksoftirqd` thread is per-CPU, so it still runs on the same CPU. The only way a softirq's work can migrate to a different CPU is if the softirq handler itself enqueues work (e.g., a workqueue item) that the scheduler places on another CPU.

### Module Example: Verifying CPU Affinity

```c
/* Inside a hardirq handler */
static irqreturn_t my_handler(int irq, void *dev_id)
{
    pr_info("hardirq on CPU %d\n", smp_processor_id());
    raise_softirq_irqoff(TASKLET_SOFTIRQ);
    return IRQ_HANDLED;
}

/* The tasklet runs as part of TASKLET_SOFTIRQ processing */
void my_tasklet_func(struct tasklet_struct *t)
{
    pr_info("tasklet on CPU %d\n", smp_processor_id());
    /* Will show the SAME CPU number as the hardirq handler */
}
```

---

## Softirq Execution Context: Hardirq or Softirq or Process?

Softirq handlers run in **softirq context** — a distinct execution context that is neither hardirq nor process context. The context is tracked by the `preempt_count` bitfield.

When `softirq_handle_begin()` is called at the start of `handle_softirqs()`, it adds `SOFTIRQ_OFFSET` (0x100) to `preempt_count`, setting bit 8. This puts the code in softirq context:

```
 preempt_count Bitfield — Inside a Softirq Handler
 ══════════════════════════════════════════════════

 Bits:  31  ...  24  23  22  21  20  19  18  17  16  15  ...  9   8   7  ...  0
       ┌──────────┬───┬───┬───┬───┬───┬───┬───┬───┬──────────┬───┬──────────┐
       │          │   │   │   │   │   │   │   │   │          │ 1 │          │
       │ (unused) │       NMI     │     HARDIRQ    │  SOFTIRQ │   │ PREEMPT  │
       │          │               │                │   MASK   │   │  COUNT   │
       └──────────┴───────────────┴────────────────┴──────────┴───┴──────────┘
                                                               ▲
                                                               │
                                              SOFTIRQ_OFFSET (bit 8) = 0x100
                                              Set by softirq_handle_begin()

 preempt_count value: 0x00000100

 Context Detection:
 ┌──────────────────────────┬─────────┬──────────────────────────────────────┐
 │  Macro                   │  Value  │  Why                                 │
 ├──────────────────────────┼─────────┼──────────────────────────────────────┤
 │  in_hardirq()            │  false  │  HARDIRQ bits [19:16] are zero       │
 │  in_serving_softirq()    │  true   │  SOFTIRQ bit 8 (SOFTIRQ_OFFSET) set │
 │  in_softirq()            │  true   │  Any SOFTIRQ bit [15:8] set          │
 │  in_task()               │  false  │  SOFTIRQ_OFFSET bit is set           │
 │  in_interrupt()          │  true   │  SOFTIRQ_MASK is nonzero             │
 │  in_atomic()             │  true   │  preempt_count != 0                  │
 │  in_nmi()                │  false  │  NMI bits [23:20] are zero           │
 └──────────────────────────┴─────────┴──────────────────────────────────────┘
```

The `interrupt_context_level()` function at [include/linux/preempt.h, lines 90–100](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/preempt.h#L90-L100) returns **1** (softirq) for this context:

```c
static __always_inline unsigned char interrupt_context_level(void)
{
    unsigned long pc = preempt_count();
    unsigned char level = 0;

    level += !!(pc & (NMI_MASK));
    level += !!(pc & (NMI_MASK | HARDIRQ_MASK));
    level += !!(pc & (NMI_MASK | HARDIRQ_MASK | SOFTIRQ_OFFSET));

    return level;
}
```

With `preempt_count = 0x00000100`:
- `!!(0x100 & NMI_MASK)` = 0
- `!!(0x100 & (NMI_MASK | HARDIRQ_MASK))` = 0
- `!!(0x100 & (NMI_MASK | HARDIRQ_MASK | SOFTIRQ_OFFSET))` = 1

Result: level = 1 = **softirq context**.

### What If a Hardirq Fires During a Softirq?

If a hardware interrupt arrives while a softirq handler is running, `preempt_count` gets both `SOFTIRQ_OFFSET` (from the softirq) and `HARDIRQ_OFFSET` (from `irq_enter()`):

```
 preempt_count During Nested Hardirq-in-Softirq
 ═══════════════════════════════════════════════

 Bits:  19  18  17  16  ...  9   8   7  ...  0
       ┌───┬───┬───┬───┬──────────┬───┬──────────┐
       │ 0 │ 0 │ 0 │ 1 │    0     │ 1 │    0     │
       │     HARDIRQ    │  SOFTIRQ │   │ PREEMPT  │
       └───────────────┘└──────────┘───┘──────────┘
                │                    │
                │                    └── SOFTIRQ_OFFSET (bit 8) — was in softirq
                └─────────────────────── HARDIRQ_OFFSET (bit 16) — now in hardirq

 preempt_count = 0x00010100

 in_hardirq()             = true   (HARDIRQ bit set)
 in_serving_softirq()     = true   (SOFTIRQ bit 8 still set)
 interrupt_context_level() = 2     (hardirq — the innermost context)
```

---

## The Softirq Stack on AArch64

On AArch64, softirqs can run on the **per-CPU IRQ stack** rather than the task's kernel stack. This reuses the same stack-switching infrastructure used for hardirq handlers, preventing stack overflow when softirqs are processed deep in a call chain.

AArch64 selects `HAVE_SOFTIRQ_ON_OWN_STACK` at [arch/arm64/Kconfig, line 258](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/Kconfig#L258), which enables `CONFIG_SOFTIRQ_ON_OWN_STACK` (when not using `PREEMPT_RT`).

The implementation is at [arch/arm64/kernel/irq.c, lines 75–85](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/irq.c#L75-L85):

```c
#ifdef CONFIG_SOFTIRQ_ON_OWN_STACK
static void ____do_softirq(struct pt_regs *regs)
{
    __do_softirq();
}

void do_softirq_own_stack(void)
{
    call_on_irq_stack(NULL, ____do_softirq);
}
#endif
```

This calls the same `call_on_irq_stack()` assembly function used for hardirq handlers (at [arch/arm64/kernel/entry.S, lines 872–901](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry.S#L872-L901)). The function saves the current frame pointer and link register, loads the per-CPU `irq_stack_ptr`, switches SP to the top of the IRQ stack, calls the handler, and restores the original SP.

```
 Softirq Stack Switching on AArch64
 ═══════════════════════════════════

 Task kernel stack (16 KB)             Per-CPU IRQ stack (16 KB)
 ┌─────────────────────────┐          ┌─────────────────────────┐
 │                         │          │                         │
 │  syscall entry frame    │          │                (top)    │
 │  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─  │          │                  ▲     │
 │  VFS layer frames       │          │                  │ SP   │
 │  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─  │          │  ┌─────────────────┐   │
 │  filesystem frames      │          │  │handle_softirqs() │   │
 │  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─  │          │  │net_rx_action()   │   │
 │  block layer frames     │          │  │  ...             │   │
 │  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─  │          │  └─────────────────┘   │
 │  deep call chain        │          │                         │
 ├─────────────────────────┤   SP     │                         │
 │  saved x29, x30         │ switch   │                         │
 │  (call_on_irq_stack     │ ──────►  │                         │
 │   saves frame here)     │          │                         │
 │                         │          │                         │
 │  ↕ only ~2 KB left!     │          │  ↕ full 16 KB available │
 └─────────────────────────┘          └─────────────────────────┘

 Without the IRQ stack, softirq frames pile on top of the existing
 deep call chain → stack overflow risk.
```

---

## The Value of current While Running in a Softirq

Inside a softirq handler, **`current` points to whichever task was running when the softirq was triggered** — just like in hardirq context. The softirq handler does not have its own `task_struct`; it borrows the CPU from the interrupted task.

```
 current in Softirq Context — Two Paths
 ═══════════════════════════════════════

 PATH 1: Inline at irq_exit() (common)       PATH 2: Via ksoftirqd (fallback)
 ──────────────────────────────────────       ─────────────────────────────────

 Task "myapp" running on CPU 2                ksoftirqd/2 running on CPU 2
          │                                            │
          ▼                                            ▼
 IRQ fires → hardirq → irq_exit()             run_ksoftirqd()
          │                                            │
          ▼                                            ▼
 handle_softirqs()                             handle_softirqs(true)
   → net_rx_action()                             → net_rx_action()
                                                
 current = task_struct of "myapp"              current = task_struct of
 current->pid  = 1842                          "ksoftirqd/2"
 current->comm = "myapp"                       current->pid  = 15
                                               current->comm = "ksoftirqd/2"
          │                                            │
          ▼                                            ▼
 BORROWED identity                             OWNED identity (but no
 (coincidental — do not act on it)             user-space context: no mm,
                                               no open files)
```

The `current` pointer is valid but **borrowed** — the softirq handler must not act on it. It should not send signals to `current`, modify its address space, or make any decisions based on `current->pid`. The fact that "myapp" happened to be running when the interrupt arrived is coincidental.

When softirqs run in `ksoftirqd` (the fallback path), `current` points to the `ksoftirqd/N` kernel thread — which is an **owned** identity but has no user-space context (no `mm`, no open files). The softirq handler should not depend on which path it took.

### Module Example: Printing current in a Tasklet (Softirq Context)

```c
/* Tasklets run inside TASKLET_SOFTIRQ — they are in softirq context */
void my_tasklet_func(struct tasklet_struct *t)
{
    pr_info("tasklet: current->pid=%d, current->comm=%s\n",
            current->pid, current->comm);
    /* Output depends on what was running when the interrupt fired:
     *   tasklet: current->pid=1842, current->comm=bash
     * or if running in ksoftirqd:
     *   tasklet: current->pid=15, current->comm=ksoftirqd/2
     */
}
```

---

## Rules and Constraints While Running in Softirq Context

Softirq context is more permissive than hardirq context (interrupts are enabled) but more restrictive than process context (sleeping is forbidden):

```
 ┌───────────────────────────────────────────────────────────────────────────────┐
 │                     RULES FOR SOFTIRQ CONTEXT                                 │
 ├───────────────────────────────────────────────────────────────────────────────┤
 │                                                                               │
 │  ALLOWED:                                                                     │
 │  ────────                                                                     │
 │    spin_lock() / spin_unlock()                                                │
 │    spin_lock_irqsave() / spin_unlock_irqrestore()  (for hardirq data)         │
 │    kmalloc(GFP_ATOMIC)                                                        │
 │    kfree()                                                                    │
 │    atomic operations                                                          │
 │    per-CPU variable access                                                    │
 │    raise_softirq()                                                            │
 │    tasklet_schedule()                                                         │
 │    queue_work() / schedule_work()                                             │
 │    pr_info() / printk()                                                       │
 │    del_timer() / mod_timer()                                                  │
 │                                                                               │
 │  FORBIDDEN:                                                                   │
 │  ──────────                                                                   │
 │    schedule()              — triggers "BUG: scheduling while atomic"          │
 │    mutex_lock()            — calls schedule() internally                      │
 │    kmalloc(GFP_KERNEL)     — may sleep for reclaim                            │
 │    msleep() / ssleep()     — calls schedule_timeout()                         │
 │    wait_event()            — may sleep                                        │
 │    copy_from_user/to_user  — may page fault and sleep                         │
 │    down()                  — semaphore acquire may sleep                      │
 │                                                                               │
 │  LOCKING RULES:                                                               │
 │  ──────────────                                                               │
 │    A softirq never preempts another softirq on the same CPU                   │
 │    The same softirq type CAN run concurrently on different CPUs               │
 │    Data shared between softirq instances → spin_lock()                        │
 │    Data shared with hardirq handlers → spin_lock_irqsave()                    │
 │    current is borrowed — do not act on it                                     │
 └───────────────────────────────────────────────────────────────────────────────┘
```

The prohibition on sleeping works exactly as in hardirq context: `preempt_count` is nonzero (has `SOFTIRQ_OFFSET` set), so `schedule()` → `__schedule()` → `schedule_debug()` → `in_atomic_preempt_off()` returns true → `__schedule_bug()` prints `"BUG: scheduling while atomic"`.

```
 Why Sleeping Is Forbidden — The Detection Chain
 ════════════════════════════════════════════════

 schedule()
   └── __schedule()
         └── schedule_debug()
               └── in_atomic_preempt_off()
                     └── preempt_count() != 0 ?
                           │
                           ▼
                     preempt_count = 0x00000100  (SOFTIRQ_OFFSET set)
                           │
                           ▼
                     YES → __schedule_bug()
                           → "BUG: scheduling while atomic: comm/pid/preempt_count"
```

---

## How to Detect Whether You Are Running in Softirq Context

The kernel provides several macros for context detection, but they have subtleties that matter. The relevant ones for softirq context are defined in [include/linux/preempt.h, lines 108–141](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/preempt.h#L108-L141):

### in_serving_softirq() — The Correct Check

```c
#define softirq_count()       (preempt_count() & SOFTIRQ_MASK)
#define in_serving_softirq()  (softirq_count() & SOFTIRQ_OFFSET)
```

**`in_serving_softirq()`** returns true **only** when the code is actively inside a softirq handler — between `softirq_handle_begin()` and `softirq_handle_end()`. This is the **correct** check for "am I in a softirq handler?"

It works because `softirq_handle_begin()` adds `SOFTIRQ_OFFSET` (0x100 — bit 8), while `local_bh_disable()` adds `SOFTIRQ_DISABLE_OFFSET` (0x200 — bit 9). The check `softirq_count() & SOFTIRQ_OFFSET` tests specifically for bit 8.

```
 SOFTIRQ Field in preempt_count — Bit 8 vs Bit 9
 ════════════════════════════════════════════════

 preempt_count bits [15:8]:

 ┌──────────────────────────────────┬────────┬────────┬──────────────────────┬──────────────┐
 │ Scenario                         │ Bit 9  │ Bit 8  │ in_serving_softirq() │ in_softirq() │
 ├──────────────────────────────────┼────────┼────────┼──────────────────────┼──────────────┤
 │ Normal process context           │   0    │   0    │ false                │ false        │
 │ Inside softirq handler           │   0    │   1    │ TRUE                 │ true         │
 │ After local_bh_disable()         │   1    │   0    │ false                │ true  ← !!   │
 │ local_bh_disable() + in softirq  │   1    │   1    │ TRUE                 │ true         │
 └──────────────────────────────────┴────────┴────────┴──────────────────────┴──────────────┘

 Key insight: in_softirq() conflates "in softirq handler" with
              "bottom halves disabled" — use in_serving_softirq() instead.
```

### in_softirq() — Deprecated, Do Not Use

```c
#define in_softirq()    (softirq_count())
```

**`in_softirq()`** checks the **entire** SOFTIRQ_MASK (bits [15:8]). It returns true in two different situations: (1) actually inside a softirq handler, and (2) code that has merely called `local_bh_disable()`. This conflation makes it unreliable for determining execution context. **Do not use `in_softirq()` in new code** — use `in_serving_softirq()` to check for actual softirq execution, or `!in_task()` to check "can I sleep?"

### in_task() — The "Can I Sleep?" Check

```c
#define in_task()  (!(preempt_count() & (NMI_MASK | HARDIRQ_MASK | SOFTIRQ_OFFSET)))
```

`in_task()` returns true only in process context — when none of the NMI, hardirq, or softirq handler bits are set. This is the **recommended** check for whether sleeping is allowed.

```
 Context Detection Quick Reference
 ═════════════════════════════════

 Question                              Use this macro
 ──────────────────────────────────    ─────────────────────────
 "Am I in a softirq handler?"          in_serving_softirq()
 "Can I sleep?"                        in_task()
 "Am I in a hardirq handler?"          in_hardirq()
 "Am I in any interrupt context?"      !in_task()  (NOT in_interrupt())
 "Am I in NMI?"                        in_nmi()

 AVOID: in_softirq(), in_interrupt() — deprecated, misleading
```

### Module Example: Context Detection in a Tasklet

```c
void my_tasklet_func(struct tasklet_struct *t)
{
    pr_info("in_hardirq()=%d\n", !!in_hardirq());
    pr_info("in_serving_softirq()=%d\n", !!in_serving_softirq());
    pr_info("in_softirq()=%d\n", !!in_softirq());
    pr_info("in_task()=%d\n", !!in_task());
    pr_info("in_interrupt()=%d\n", !!in_interrupt());
    pr_info("in_atomic()=%d\n", !!in_atomic());
    pr_info("irqs_disabled()=%d\n", irqs_disabled());
    /*
     * Expected output:
     *   in_hardirq()=0
     *   in_serving_softirq()=1
     *   in_softirq()=1
     *   in_task()=0
     *   in_interrupt()=1
     *   in_atomic()=1
     *   irqs_disabled()=0
     */
}
```

---

## Checking Per-CPU Softirq Statistics: /proc/softirqs

The kernel exposes per-CPU softirq execution counts via **`/proc/softirqs`**. Each time a softirq handler runs, the counter is incremented by `kstat_incr_softirqs_this_cpu()` inside `handle_softirqs()` at [kernel/softirq.c, line 619](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/softirq.c#L619).

The counter is a per-CPU field in `struct kernel_stat`, defined at [include/linux/kernel_stat.h, lines 47–50](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/kernel_stat.h#L47-L50):

```c
struct kernel_stat {
    unsigned long irqs_sum;
    unsigned int softirqs[NR_SOFTIRQS];
};
```

The `/proc/softirqs` file is generated by `show_softirqs()` at [fs/proc/softirqs.c, lines 11–27](https://github.com/torvalds/linux/blob/v7.2-rc5/fs/proc/softirqs.c#L11-L27):

```c
static int show_softirqs(struct seq_file *p, void *v)
{
    int i, j;

    seq_puts(p, "                    ");
    for_each_possible_cpu(i)
        seq_printf(p, "CPU%-8d", i);
    seq_putc(p, '\n');

    for (i = 0; i < NR_SOFTIRQS; i++) {
        seq_printf(p, "%12s:", softirq_to_name[i]);
        for_each_possible_cpu(j)
            seq_put_decimal_ull_width(p, " ",
                        kstat_softirqs_cpu(i, j), 10);
        seq_putc(p, '\n');
    }
    return 0;
}
```

Example output on a 4-CPU AArch64 system:

```
$ cat /proc/softirqs
                    CPU0       CPU1       CPU2       CPU3
          HI:          0          0          0          0
       TIMER:     284652     271843     262917     258431
      NET_TX:          3          1          0          2
      NET_RX:      98421      87234      91653      89127
       BLOCK:      14523      12847      13691      11234
    IRQ_POLL:          0          0          0          0
     TASKLET:        847        392        156        284
       SCHED:     152834     148927     143562     139284
     HRTIMER:       4521       4387       4291       4156
         RCU:     198234     195127     191843     188562
```

```
 Reading /proc/softirqs — What the Numbers Tell You
 ═══════════════════════════════════════════════════

 TIMER    284652  271843  262917  258431   ← Every timer tick generates one.
                                             Roughly proportional to uptime * HZ.
                                             Nearly equal across CPUs = good.

 NET_RX    98421   87234   91653   89127   ← Per-CPU network packet processing.
                                             Large imbalance = RSS misconfigured.
                                             One CPU >> others = IRQ affinity issue.

 SCHED    152834  148927  143562  139284   ← Scheduler load-balancing activity.
                                             Higher on busier CPUs.

 TASKLET      847     392     156     284   ← Relatively low — not a high-throughput
                                             mechanism. High counts here = driver issue.

 HI            0       0       0       0   ← High-priority tasklets rarely used
                                             in modern drivers.
```

---

## Finding Pending Softirqs

To determine which softirqs are currently pending (raised but not yet processed), you can read the per-CPU `__softirq_pending` bitmask. From kernel code:

```c
__u32 pending = local_softirq_pending();
```

Each bit position corresponds to a softirq vector:

```
 __softirq_pending Bitmask Layout
 ═════════════════════════════════

 Bit:   9        8        7       6        5         4       3        2        1       0
       ┌────────┬────────┬───────┬────────┬─────────┬───────┬────────┬────────┬───────┬────────┐
       │  RCU   │HRTIMER │ SCHED │TASKLET │IRQ_POLL │ BLOCK │ NET_RX │ NET_TX │ TIMER │   HI   │
       └────────┴────────┴───────┴────────┴─────────┴───────┴────────┴────────┴───────┴────────┘

 Processing order: ffs() finds lowest set bit first
                   ◄── HIGHEST PRIORITY                              LOWEST PRIORITY ──►
                   bit 0 (HI) processed first          bit 9 (RCU) processed last
```

The `handle_softirqs()` loop uses `ffs()` (find first set bit) to iterate pending softirqs from lowest index (highest priority) to highest. Before entering the loop, it clears the pending mask with `set_softirq_pending(0)` — any new softirqs raised during handler execution will set new bits, which will be detected in the restart check after the loop.

---

## Does Creating a New Softirq Require Recompiling the Kernel?

**Yes.** Adding a new softirq vector requires modifying the enum in `include/linux/interrupt.h` (to add the new constant before `NR_SOFTIRQS`), updating the `softirq_to_name` array in `kernel/softirq.c`, and adding an `open_softirq()` call in the appropriate subsystem initialization function. All of these are compile-time changes to the core kernel.

This is deliberate: softirqs are the kernel's most performance-critical deferred execution mechanism. Each new softirq vector has global implications:

- **Every CPU** gains a bit in its pending bitmask that must be checked on every `irq_exit()`.
- **Every softirq processing loop** iterates one more potential handler.
- **The entire interaction matrix** between softirq handlers grows — locking and priority analysis become more complex.

The kernel source explicitly discourages new softirqs. For almost all driver and subsystem needs, **tasklets** (dynamic, module-safe, built on existing softirq vectors) or **workqueues** (process context, can sleep) are the correct choice.

```
 Bottom-Half Mechanism Selection — Decision Tree
 ════════════════════════════════════════════════

                       ┌──────────────────────────────────┐
                       │  Need deferred work from hardirq  │
                       └──────────────┬───────────────────┘
                                      │
                                      ▼
                ┌─────────────────────────────────────────┐
                │  Need per-interrupt-line deferred work?  │
                └───────┬─────────────────────────┬───────┘
                       YES                        NO
                        │                          │
                        ▼                          ▼
               request_threaded_irq()    ┌────────────────────────┐
               with thread_fn            │  Need to sleep in BH?  │
                                         └───┬────────────────┬───┘
                                            YES               NO
                                             │                 │
                                             ▼                 ▼
                                     workqueue          ┌──────────────────┐
                                     (schedule_work /   │  Need max thru-  │
                                      queue_work)       │  put, per-CPU,   │
                                                        │  re-entrant?     │
                                                        └──┬───────────┬───┘
                                                          YES          NO
                                                           │            │
                                                           ▼            ▼
                                                     softirq        tasklet
                                                     (are you       (tasklet_setup /
                                                     writing a       tasklet_schedule)
                                                     new network
                                                     stack? if
                                                     not → tasklet)
```

---

## ksoftirqd: The Per-CPU Softirq Thread

**`ksoftirqd`** is a per-CPU kernel thread that processes softirqs when inline processing (at `irq_exit()`) is insufficient or inappropriate. There is one `ksoftirqd` per CPU, named `ksoftirqd/N` where N is the CPU number.

### Why ksoftirqd Exists

The fundamental problem: softirqs can be raised faster than they are processed. A high-throughput network card can generate thousands of interrupts per second, each raising `NET_RX_SOFTIRQ`. If `handle_softirqs()` processes all pending softirqs and then finds more have been raised during processing, it faces a dilemma:

- **Process them immediately** → risk starving user-space processes indefinitely. The CPU could spend 100% of its time in softirq processing, never running any application.
- **Ignore them** → packets queue up, latency increases, throughput drops.

```
 The ksoftirqd Compromise
 ════════════════════════

 ┌──────────────────────────────────────────────────────────────────────────┐
 │                                                                          │
 │   Inline processing at irq_exit()                                        │
 │   ──────────────────────────────                                        │
 │   Fast: softirqs processed immediately after hardirq.                   │
 │   Limited: max 10 restarts or 2 ms.                                     │
 │   Problem: can starve user-space if softirqs keep arriving.             │
 │                                                                          │
 │                     ┌───────────────┐                                    │
 │                     │ Budget        │                                    │
 │                     │ exceeded?     │                                    │
 │                     └───┬───────┬───┘                                    │
 │                        NO      YES                                       │
 │                         │       │                                        │
 │                         ▼       ▼                                        │
 │                    goto       wakeup_softirqd()                          │
 │                    restart     │                                         │
 │                                ▼                                         │
 │   ksoftirqd processing                                                   │
 │   ────────────────────                                                  │
 │   Regular kernel thread: scheduler can balance it against user tasks.    │
 │   Runs with SCHED_NORMAL priority.                                       │
 │   Calls cond_resched() between iterations → can be preempted.           │
 │   Ensures progress on softirq work without starving applications.       │
 │                                                                          │
 └──────────────────────────────────────────────────────────────────────────┘
```

### ksoftirqd Implementation

The per-CPU thread is stored at [kernel/softirq.c, line 62](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/softirq.c#L62):

```c
DEFINE_PER_CPU(struct task_struct *, ksoftirqd);
```

The thread is registered and spawned during early boot via `smpboot_register_percpu_thread()` at [kernel/softirq.c, lines 1116–1121 and 1165–1176](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/softirq.c#L1116-L1176):

```c
static struct smp_hotplug_thread softirq_threads = {
    .store              = &ksoftirqd,
    .thread_should_run  = ksoftirqd_should_run,
    .thread_fn          = run_ksoftirqd,
    .thread_comm        = "ksoftirqd/%u",
};

static __init int spawn_ksoftirqd(void)
{
    cpuhp_setup_state_nocalls(CPUHP_SOFTIRQ_DEAD, "softirq:dead",
                              NULL, takeover_tasklets);
    BUG_ON(smpboot_register_percpu_thread(&softirq_threads));
    return 0;
}
early_initcall(spawn_ksoftirqd);
```

The thread's "should I run?" check at [kernel/softirq.c, lines 1063–1066](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/softirq.c#L1063-L1066):

```c
static int ksoftirqd_should_run(unsigned int cpu)
{
    return local_softirq_pending();
}
```

The main execution function at [kernel/softirq.c, lines 1068–1082](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/softirq.c#L1068-L1082):

```c
static void run_ksoftirqd(unsigned int cpu)
{
    ksoftirqd_run_begin();              /* local_irq_disable() */

    if (local_softirq_pending()) {
        handle_softirqs(true);          /* ksirqd = true */
        ksoftirqd_run_end();            /* local_irq_enable() */
        cond_resched();
        return;
    }

    ksoftirqd_run_end();
}
```

The thread loops: check if there are pending softirqs → if yes, call `handle_softirqs(true)` → call `cond_resched()` to give other tasks a chance → repeat. The `cond_resched()` is critical — it is the point where the scheduler can preempt `ksoftirqd` in favor of a higher-priority task.

### ksoftirqd Execution Context: Process or Softirq?

**Both — at different points in its execution.** This is one of the most commonly confused aspects of `ksoftirqd`. The thread itself is a kernel thread (process context), but it **transitions into softirq context** when it calls `handle_softirqs()`.

The key is to trace the `preempt_count` transitions:

```
 ksoftirqd/2 Lifecycle — preempt_count Transitions
 ═══════════════════════════════════════════════════

 ┌────────────────────────────────────────────────────────────────────────────┐
 │  run_ksoftirqd():                                                          │
 │                                                                            │
 │  ksoftirqd_run_begin()                                                     │
 │    └── local_irq_disable()             preempt_count: 0x00000000           │
 │                                        context: PROCESS (IRQs off)         │
 │                                                                            │
 │  handle_softirqs(true):                                                    │
 │    ├── softirq_handle_begin()                                              │
 │    │     └── preempt_count += SOFTIRQ_OFFSET                               │
 │    │                                   preempt_count: 0x00000100           │
 │    │                                   context: ──► SOFTIRQ                │
 │    │                                                                       │
 │    ├── local_irq_enable()              IRQs: ENABLED                       │
 │    │                                                                       │
 │    │   ┌─────────────────────────────────────────────────────────────┐     │
 │    │   │  h->action()  ← softirq handlers run HERE                  │     │
 │    │   │                                                             │     │
 │    │   │  in_serving_softirq() = true                                │     │
 │    │   │  in_task()             = false                              │     │
 │    │   │  in_atomic()           = true                               │     │
 │    │   │  CANNOT SLEEP                                               │     │
 │    │   │  Interrupts: ENABLED (hardirq CAN preempt)                  │     │
 │    │   └─────────────────────────────────────────────────────────────┘     │
 │    │                                                                       │
 │    ├── local_irq_disable()                                                 │
 │    │                                                                       │
 │    └── softirq_handle_end()                                                │
 │          └── preempt_count -= SOFTIRQ_OFFSET                               │
 │                                        preempt_count: 0x00000000           │
 │                                        context: ──► PROCESS                │
 │          └── WARN_ON_ONCE(in_interrupt())  ← verifies back in process ctx  │
 │                                                                            │
 │  ksoftirqd_run_end()                                                       │
 │    └── local_irq_enable()              IRQs: ENABLED                       │
 │                                                                            │
 │  cond_resched()                        CAN BE PREEMPTED HERE               │
 │                                        CAN SLEEP (preempt_count == 0)      │
 └────────────────────────────────────────────────────────────────────────────┘
```

The implementation (non-RT path) at [kernel/softirq.c, lines 472–477](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/softirq.c#L472-L477):

```c
/* Non-RT path */
static inline void ksoftirqd_run_begin(void)
{
    local_irq_disable();                /* just disables IRQs, no BH change */
}

static inline void ksoftirqd_run_end(void)
{
    local_irq_enable();
}
```

And inside `handle_softirqs()` at [kernel/softirq.c, lines 461–469](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/softirq.c#L461-L469):

```c
static inline void softirq_handle_begin(void)
{
    __local_bh_disable_ip(_RET_IP_, SOFTIRQ_OFFSET);   /* adds 0x100 to preempt_count */
}

static inline void softirq_handle_end(void)
{
    __local_bh_enable(SOFTIRQ_OFFSET);                  /* subtracts 0x100 */
    WARN_ON_ONCE(in_interrupt());                        /* asserts: back in process ctx */
}
```

The `WARN_ON_ONCE(in_interrupt())` in `softirq_handle_end()` is the kernel's own assertion that the transition back to process context actually happened.

### Can ksoftirqd Sleep?

| Phase | `preempt_count` | `in_task()` | Can sleep? |
|-------|-----------------|-------------|------------|
| Inside `handle_softirqs()` (running `h->action()`) | `0x100` (SOFTIRQ_OFFSET) | false | **No** — `schedule()` would trigger "BUG: scheduling while atomic" |
| At `cond_resched()` after `ksoftirqd_run_end()` | `0x000` | true | **Yes** — full process context, scheduler can preempt |

### Are Interrupts Enabled Inside ksoftirqd?

**Yes.** `handle_softirqs()` explicitly calls `local_irq_enable()` at [line 606](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/softirq.c#L606) before entering the handler loop, and `local_irq_disable()` at [line 637](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/softirq.c#L637) after the loop completes. This means a **hardirq can preempt a softirq handler** running inside `ksoftirqd` — the same behavior as inline softirq processing at `irq_exit()`.

### RT Path Difference

On `PREEMPT_RT` kernels, the context transition is structured differently. `ksoftirqd_run_begin()` at [kernel/softirq.c, lines 314–319](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/softirq.c#L314-L319) adds `SOFTIRQ_OFFSET` **before** entering `handle_softirqs()`, and `softirq_handle_begin()`/`softirq_handle_end()` become no-ops. The effect is the same — softirq handlers run with `SOFTIRQ_OFFSET` set — but the BH disable is held across the entire `run_ksoftirqd()` call rather than only inside `handle_softirqs()`.

### When ksoftirqd Is Woken

**`wakeup_softirqd()`** at [kernel/softirq.c, lines 75–82](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/softirq.c#L75-L82):

```c
static void wakeup_softirqd(void)
{
    struct task_struct *tsk = __this_cpu_read(ksoftirqd);

    if (tsk)
        wake_up_process(tsk);
}
```

This is called from three places:

1. **`handle_softirqs()`** — when the restart budget is exceeded (line 645).
2. **`invoke_softirq()`** — when `force_irqthreads()` is active (line 506), routing all softirqs through `ksoftirqd` instead of inline processing.
3. **`raise_softirq_irqoff()`** — when a softirq is raised from process context (line 787), because there is no upcoming `irq_exit()` to process it.

```
 ksoftirqd Lifecycle
 ═══════════════════

 ┌─────────────────────────────────────────────────────────────────────────┐
 │                                                                         │
 │   ksoftirqd/2 (sleeping — TASK_INTERRUPTIBLE)                           │
 │        │                                                                │
 │        │  wakeup_softirqd() called from one of:                         │
 │        │    1. handle_softirqs() restart budget exceeded                 │
 │        │    2. invoke_softirq() with force_irqthreads                   │
 │        │    3. raise_softirq from process context                       │
 │        ▼                                                                │
 │   ksoftirqd_should_run()                                                │
 │     └── local_softirq_pending() → nonzero                               │
 │        │                                                                │
 │        ▼                                                                │
 │   run_ksoftirqd():                                                      │
 │     ├── local_irq_disable()                                             │
 │     ├── handle_softirqs(true)  ← same processing as inline path         │
 │     ├── local_irq_enable()                                              │
 │     └── cond_resched()         ← yield to scheduler if needed           │
 │        │                                                                │
 │        ▼                                                                │
 │   ksoftirqd_should_run()                                                │
 │     └── local_softirq_pending()                                         │
 │        │                                                                │
 │     ┌──┴──┐                                                             │
 │     │     │                                                             │
 │  nonzero  zero                                                          │
 │     │     │                                                             │
 │     ▼     ▼                                                             │
 │   loop   sleep until next wakeup                                        │
 │                                                                         │
 └─────────────────────────────────────────────────────────────────────────┘
```

### Observing ksoftirqd

```bash
# List ksoftirqd threads (one per CPU)
ps -eo pid,psr,comm | grep ksoftirqd
#   PID  CPU  COMM
#    12    0  ksoftirqd/0
#    18    1  ksoftirqd/1
#    24    2  ksoftirqd/2
#    30    3  ksoftirqd/3

# Check if ksoftirqd is consuming CPU time (sign of softirq pressure)
top -bn1 | grep ksoftirqd

# If ksoftirqd is using significant CPU, check which softirqs are heavy
cat /proc/softirqs
# High NET_RX counts → network saturation
# High TIMER counts  → expected, proportional to HZ
```

---

## Disabling and Enabling Softirqs: local_bh_disable and local_bh_enable

**`local_bh_disable()`** and **`local_bh_enable()`** prevent softirq and tasklet execution on the current CPU. They are the softirq equivalent of `local_irq_disable()`/`local_irq_enable()` — used to protect data shared between process context and softirq handlers.

### Implementation

**`local_bh_disable()`** is defined in [include/linux/bottom_half.h, lines 18–21](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/bottom_half.h#L18-L21):

```c
static inline void local_bh_disable(void)
{
    __local_bh_disable_ip(_THIS_IP_, SOFTIRQ_DISABLE_OFFSET);
}
```

On the non-RT, non-trace path, `__local_bh_disable_ip()` at [include/linux/bottom_half.h, lines 11–15](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/bottom_half.h#L11-L15) is:

```c
static __always_inline void __local_bh_disable_ip(unsigned long ip, unsigned int cnt)
{
    preempt_count_add(cnt);
    barrier();
}
```

It adds **`SOFTIRQ_DISABLE_OFFSET`** (0x200, which is `2 * SOFTIRQ_OFFSET`) to `preempt_count`. This sets bit 9 in the SOFTIRQ field. The `barrier()` prevents the compiler from reordering code across the disable.

**`local_bh_enable()`** at [include/linux/bottom_half.h, lines 31–34](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/bottom_half.h#L31-L34) calls `__local_bh_enable_ip()` at [kernel/softirq.c, lines 427–458](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/softirq.c#L427-L458), which subtracts the offset and processes pending softirqs if any exist:

```c
void __local_bh_enable_ip(unsigned long ip, unsigned int cnt)
{
    WARN_ON_ONCE(in_hardirq());
    lockdep_assert_irqs_enabled();
    /* ... */
    __preempt_count_sub(cnt - 1);

    if (unlikely(!in_interrupt() && local_softirq_pending())) {
        do_softirq();
    }

    preempt_count_dec();
    /* ... */
}
```

### Why SOFTIRQ_DISABLE_OFFSET Is 0x200, Not 0x100

The **key design point** is that `local_bh_disable()` adds `0x200` (bit 9) while `softirq_handle_begin()` adds `0x100` (bit 8). This allows the kernel to distinguish:

```
 SOFTIRQ_OFFSET (0x100) vs SOFTIRQ_DISABLE_OFFSET (0x200)
 ════════════════════════════════════════════════════════

 ┌──────────────────────────────────────────────────────────────────────┐
 │  After local_bh_disable():                                          │
 │    preempt_count & SOFTIRQ_MASK   = 0x200                           │
 │    preempt_count & SOFTIRQ_OFFSET = 0       (bit 8 is CLEAR)       │
 │    in_serving_softirq() = false              ← not in handler       │
 │    in_softirq()         = true               ← misleading!          │
 ├──────────────────────────────────────────────────────────────────────┤
 │  Inside a real softirq handler:                                     │
 │    preempt_count & SOFTIRQ_MASK   = 0x100                           │
 │    preempt_count & SOFTIRQ_OFFSET = 0x100   (bit 8 is SET)         │
 │    in_serving_softirq() = true               ← in handler           │
 │    in_softirq()         = true                                      │
 └──────────────────────────────────────────────────────────────────────┘
```

### Nesting

`local_bh_disable()` is nestable — each call adds `SOFTIRQ_DISABLE_OFFSET` (0x200), and each `local_bh_enable()` subtracts it. Softirqs only run again when the count returns to zero on the **outermost** `local_bh_enable()`.

```
 local_bh_disable/enable Nesting — preempt_count SOFTIRQ Field
 ═════════════════════════════════════════════════════════════

 outer_function()                      SOFTIRQ field    Softirqs can run?
 ├── local_bh_disable()                0x000 → 0x200    NO
 │   ├── inner_function()
 │   │   ├── local_bh_disable()        0x200 → 0x400    NO
 │   │   │   └── ... modify data ...
 │   │   └── local_bh_enable()         0x400 → 0x200    NO  (still nested)
 │   └── ... more work ...
 └── local_bh_enable()                 0x200 → 0x000    YES ← pending softirqs
                                                              processed HERE
```

This works because `__local_bh_enable_ip()` at [kernel/softirq.c, lines 427–458](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/softirq.c#L427-L458) checks `!in_interrupt()` before processing pending softirqs. The check uses the **entire** `SOFTIRQ_MASK | HARDIRQ_MASK | NMI_MASK` — so if any bits remain set in the SOFTIRQ field (i.e., there are still outer `local_bh_disable()` calls), `in_interrupt()` returns true and softirqs are not processed:

```c
void __local_bh_enable_ip(unsigned long ip, unsigned int cnt)
{
    /* ... */
    __preempt_count_sub(cnt - 1);

    if (unlikely(!in_interrupt() && local_softirq_pending())) {
        do_softirq();                /* only runs when SOFTIRQ field reaches 0 */
    }

    preempt_count_dec();             /* subtract the remaining 1 */
}
```

The subtraction is done in two steps: first `cnt - 1` (subtracts 0x1ff for `SOFTIRQ_DISABLE_OFFSET`), then a final `preempt_count_dec()` (subtracts the remaining 1). The `!in_interrupt()` check happens between these two subtractions — at that point, if this is the outermost enable, the SOFTIRQ field is zero and pending softirqs are processed.

### Comparison: local_irq_disable vs local_bh_disable Nesting

```
 ┌──────────────────────────────────────────────────────────────────────┐
 │  local_irq_disable/enable:                                          │
 │    Uses a single bit (PSTATE.I) — no nesting counter                │
 │    Problem: inner enable clobbers outer disable                     │
 │    Solution: local_irq_save() / local_irq_restore()                │
 │                                                                      │
 │  local_bh_disable/enable:                                           │
 │    Uses an additive counter (SOFTIRQ field in preempt_count)        │
 │    Each disable adds 0x200, each enable subtracts 0x200             │
 │    Softirqs only re-enabled when counter reaches zero               │
 │    Nesting is inherently safe — no save/restore variant needed      │
 └──────────────────────────────────────────────────────────────────────┘
```

### When to Use local_bh_disable

Use `local_bh_disable()`/`local_bh_enable()` when process-context code accesses data that is also accessed by a softirq handler, but **not** by a hardirq handler:

```c
/* Process context code that shares data with a softirq handler */
local_bh_disable();
/* ... modify shared data ... */
/* No softirq can run on this CPU during this section */
local_bh_enable();     /* pending softirqs processed here if any */
```

If the data is also accessed by a hardirq handler, you need `spin_lock_irqsave()` instead — `local_bh_disable()` does **not** disable hardware interrupts. The reason is explained in the next section.

---

## Interrupt State Under Different Spinlock Variants

A common question is: when I hold a spinlock, are interrupts enabled or disabled? The answer depends on which variant is used. The implementations are in [include/linux/spinlock_api_smp.h](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/spinlock_api_smp.h):

### spin_lock()

```c
/* include/linux/spinlock_api_smp.h, lines 154-160 */
static inline void __raw_spin_lock(raw_spinlock_t *lock)
{
    preempt_disable();
    /* ... acquire lock ... */
}
```

- **Hardware IRQs**: **ENABLED** (PSTATE.I unchanged)
- **Softirqs (BH)**: **ENABLED**
- **Preemption**: **DISABLED** (preempt_count incremented)
- **Use when**: Data is shared only between process contexts across CPUs. No interrupt handler accesses this data.

### spin_lock_irqsave()

```c
/* include/linux/spinlock_api_smp.h, lines 125-135 */
static inline unsigned long __raw_spin_lock_irqsave(raw_spinlock_t *lock)
{
    unsigned long flags;
    local_irq_save(flags);    /* saves DAIF and disables IRQs */
    preempt_disable();
    /* ... acquire lock ... */
    return flags;
}
```

- **Hardware IRQs**: **DISABLED** (PSTATE.I=1 or PMR=0xc0)
- **Softirqs (BH)**: **DISABLED** (cannot run because IRQs are off)
- **Preemption**: **DISABLED**
- **Use when**: Data is shared with a hardirq handler. The saved `flags` are passed to `spin_unlock_irqrestore()` to restore the original interrupt state.

### spin_lock_bh()

```c
/* include/linux/spinlock_api_smp.h, lines 146-152 */
static inline void __raw_spin_lock_bh(raw_spinlock_t *lock)
{
    __local_bh_disable_ip(_RET_IP_, SOFTIRQ_LOCK_OFFSET);
    /* ... acquire lock ... */
}
```

- **Hardware IRQs**: **ENABLED** (PSTATE.I unchanged)
- **Softirqs (BH)**: **DISABLED** (preempt_count has SOFTIRQ bits set)
- **Preemption**: **DISABLED** (preempt_count nonzero)
- **Use when**: Data is shared with a softirq handler but NOT with a hardirq handler. Cheaper than `spin_lock_irqsave()` because it does not touch PSTATE.

### Comparison Table

```
 ┌───────────────────────────┬─────────────┬─────────────┬──────────────┐
 │ Lock Variant               │ HW IRQs     │ Softirqs    │ Preemption   │
 ├───────────────────────────┼─────────────┼─────────────┼──────────────┤
 │ spin_lock()                │ ENABLED     │ ENABLED     │ DISABLED     │
 │ spin_lock_irq()            │ DISABLED    │ DISABLED    │ DISABLED     │
 │ spin_lock_irqsave()        │ DISABLED    │ DISABLED    │ DISABLED     │
 │ spin_lock_bh()             │ ENABLED     │ DISABLED    │ DISABLED     │
 ├───────────────────────────┼─────────────┼─────────────┼──────────────┤
 │ spin_unlock()              │ unchanged   │ unchanged   │ ENABLED      │
 │ spin_unlock_irq()          │ ENABLED     │ ENABLED     │ ENABLED      │
 │ spin_unlock_irqrestore()   │ RESTORED    │ RESTORED    │ ENABLED      │
 │ spin_unlock_bh()           │ unchanged   │ ENABLED*    │ ENABLED      │
 └───────────────────────────┴─────────────┴─────────────┴──────────────┘

 * spin_unlock_bh() re-enables BH and may process pending softirqs
   at the __local_bh_enable_ip() call inside the unlock path.
```

### Choosing the Right Spinlock

```
 Spinlock Selection — Decision Tree
 ═══════════════════════════════════

 Is the data shared with a HARDIRQ handler?
       │
    ┌──┴──┐
   YES     NO
    │      │
    ▼      ▼
 spin_lock_       Is the data shared with a SOFTIRQ/tasklet handler?
 irqsave()              │
                    ┌───┴───┐
                   YES       NO
                    │        │
                    ▼        ▼
                spin_lock_   Is the data shared across CPUs?
                bh()              │
                              ┌───┴───┐
                             YES       NO
                              │        │
                              ▼        ▼
                          spin_lock()  No lock needed
                                       (per-CPU, single context)
```

### Why Each Spinlock Variant Exists: The Same-CPU Deadlock

The decision tree above is not arbitrary — each variant exists to prevent a specific **same-CPU deadlock**. The underlying principle: **disable whatever can preempt you and try to take the same lock on the same CPU.** If you don't, the preempting context spins on a lock held by the code it just preempted, and neither can make progress.

#### Why spin_lock_irqsave() for Data Shared with Hardirq

If process-context code holds a plain `spin_lock()` and a hardirq fires on the **same CPU**, the hardirq handler preempts the lock holder. If the handler tries to acquire the same lock, it spins forever — the lock holder can never resume because the hardirq has higher priority and runs to completion:

```
 Same-CPU Deadlock: spin_lock() + Hardirq
 ═════════════════════════════════════════

 CPU 0 — process context              CPU 0 — hardirq context
 ──────────────────────────            ───────────────────────────

 spin_lock(&my_lock)                   
   └── acquires lock                   
                                       
 val = shared_data                     
   │                                   
   │  ← IRQ fires on this CPU         
   │                                   ┌──────────────────────────┐
   │  (PREEMPTED — cannot run          │  hardirq handler()       │
   │   until hardirq returns)          │                          │
   │                                   │  spin_lock(&my_lock)     │
   │                                   │    └── SPINS FOREVER     │
   │                                   │                          │
   │                                   │  Lock holder = the code  │
   │                                   │  we just preempted.      │
   │                                   │  We run at higher prio.  │
   │                                   │  Lock holder can never   │
   │                                   │  resume.                 │
   │                                   │                          │
   │                                   │  ═══ DEADLOCK ═══        │
   │                                   └──────────────────────────┘
```

`spin_lock_irqsave()` prevents this by disabling interrupts **before** acquiring the lock. The hardirq cannot fire on this CPU while the lock is held. The IRQ stays pending at the GIC and is delivered after `spin_unlock_irqrestore()` restores PSTATE:

```c
spin_lock_irqsave(&my_lock, flags);
    → local_irq_save(flags)       /* PSTATE.I=1, hardirq cannot preempt */
    → preempt_disable()
    → acquire lock

/* ... access shared data safely ... */
/* hardirq CANNOT fire on this CPU */

spin_unlock_irqrestore(&my_lock, flags);
    → release lock
    → local_irq_restore(flags)    /* PSTATE.I restored, pending IRQ delivered */
```

If the same IRQ fires on a **different CPU**, the handler spins on the lock briefly and acquires it when this CPU releases it. Cross-CPU spinning is what spinlocks are designed for — same-CPU spinning is a deadlock.

#### Why spin_lock_bh() for Data Shared with Softirq

The same deadlock pattern applies one level down. If process-context code holds a plain `spin_lock()` and a softirq fires on the same CPU (at `irq_exit()` or `local_bh_enable()`), the softirq handler preempts the lock holder and deadlocks if it tries to acquire the same lock:

```
 Same-CPU Deadlock: spin_lock() + Softirq
 ═════════════════════════════════════════

 CPU 0 — process context              CPU 0 — softirq context
 ──────────────────────────            ─────────────────────────

 spin_lock(&my_lock)                   
   └── acquires lock                   
                                       
 ← hardirq fires, handler returns     
 ← irq_exit() → softirq runs          
   │                                   ┌──────────────────────────┐
   │  (PREEMPTED — softirq handler     │  softirq handler()       │
   │   runs before process resumes)    │                          │
   │                                   │  spin_lock(&my_lock)     │
   │                                   │    └── SPINS FOREVER     │
   │                                   │                          │
   │                                   │  ═══ DEADLOCK ═══        │
   │                                   └──────────────────────────┘
```

`spin_lock_bh()` prevents this by disabling bottom halves (adding `SOFTIRQ_DISABLE_OFFSET` to `preempt_count`) before acquiring the lock. Softirqs cannot run on this CPU while the lock is held.

#### The General Rule

```
 ┌─────────────────────────────────────────────────────────────────────────┐
 │  The rule: disable whatever can preempt you and take the lock           │
 │                                                                         │
 │  Data shared with...     What can preempt you?     Disable it with      │
 │  ═══════════════════     ══════════════════════     ════════════════     │
 │  Hardirq handler         Hardirq (PSTATE.I=0)      spin_lock_irqsave   │
 │  Softirq handler         Softirq (at irq_exit)     spin_lock_bh        │
 │  Process ctx only        Nothing relevant           spin_lock           │
 │  (other CPUs)            (just cross-CPU spin)      (preempt_disable)   │
 └─────────────────────────────────────────────────────────────────────────┘
```

- **Data shared between process context and hardirq** → `spin_lock_irqsave()` / `spin_unlock_irqrestore()`. Disables interrupts and acquires the lock, protecting against both hardirq preemption and cross-CPU races.

- **Data shared between process context and softirq** → `spin_lock_bh()` / `spin_unlock_bh()`. Disables bottom-halves and acquires the lock, protecting against softirq preemption without unnecessarily disabling hardware interrupts.

- **Data shared between hardirq and softirq** → `spin_lock()` / `spin_unlock()` in the hardirq handler (interrupts are already disabled, so no preemption possible), and `spin_lock_irqsave()` / `spin_unlock_irqrestore()` in the softirq handler (need to disable interrupts to prevent hardirq preemption while holding the lock).

- **Data accessed only from softirq context (same type)** → No lock needed if the softirq only runs on one CPU at a time. But different softirq types can run concurrently on different CPUs, so data shared between softirq types needs `spin_lock()`.

```
 Locking Summary Matrix
 ══════════════════════

 ┌────────────────────┬──────────────┬──────────────────┬───────────────────┐
 │                    │ From process │ From softirq     │ From hardirq      │
 │                    │ context      │ handler          │ handler           │
 ├────────────────────┼──────────────┼──────────────────┼───────────────────┤
 │ Shared with        │ spin_lock_   │ spin_lock_       │ spin_lock()       │
 │ hardirq            │ irqsave()    │ irqsave()        │ (IRQs already off)│
 ├────────────────────┼──────────────┼──────────────────┼───────────────────┤
 │ Shared with        │ spin_lock_   │ spin_lock()      │ N/A               │
 │ softirq only       │ bh()         │ (can't preempt   │                   │
 │                    │              │  on same CPU)    │                   │
 ├────────────────────┼──────────────┼──────────────────┼───────────────────┤
 │ Shared with        │ spin_lock()  │ N/A              │ N/A               │
 │ process ctx only   │              │                  │                   │
 └────────────────────┴──────────────┴──────────────────┴───────────────────┘
```

---

## Summary

This document covered the top-half/bottom-half architecture of the Linux kernel on AArch64, focusing on softirqs:

- **The top/bottom half split** exists because hardirq handlers run with interrupts disabled (`PSTATE.I=1`) — keeping them short minimizes latency for all other devices. The top half does the minimum (acknowledge device, grab time-critical data), and the bottom half does the bulk processing later with interrupts re-enabled.

- **Softirqs** are the lowest-level bottom-half mechanism. There are exactly **10 statically defined vectors** (`HI`, `TIMER`, `NET_TX`, `NET_RX`, `BLOCK`, `IRQ_POLL`, `TASKLET`, `SCHED`, `HRTIMER`, `RCU`), each with a handler registered via `open_softirq()`. New vectors require kernel recompilation.

- **The per-CPU pending bitmask** (`__softirq_pending`) is the key data structure. `raise_softirq()` sets a bit; `handle_softirqs()` clears and iterates the mask. The per-CPU design eliminates locking, prevents cache bouncing, and ensures cache locality — softirqs run on the same CPU that raised them.

- **`handle_softirqs()`** is the core processing function. It adds `SOFTIRQ_OFFSET` to `preempt_count`, clears the pending mask, **re-enables interrupts**, iterates pending vectors calling each handler, then checks for new pending softirqs. It restarts up to **10 times** or **2 ms**, then defers to `ksoftirqd`.

- **Softirqs run in softirq context** — `in_serving_softirq()` returns true, `in_task()` returns false. Hardware interrupts are **enabled** (a hardirq can preempt a softirq), but sleeping is **forbidden** (`preempt_count` is nonzero). Memory allocation must use `GFP_ATOMIC`.

- **Softirqs are processed at three points**: (1) `irq_exit()` after every hardirq handler, (2) `local_bh_enable()` when re-enabling bottom halves, and (3) in `ksoftirqd` when inline processing is exhausted or force-threaded.

- **`ksoftirqd`** is a per-CPU kernel thread (process context) that transitions into softirq context when it calls `handle_softirqs()`. Inside `handle_softirqs()`, sleeping is forbidden and interrupts are enabled. Between iterations (at `cond_resched()`), it returns to process context and can be preempted by the scheduler.

- **`current` in a softirq handler** points to whatever task was running when the interrupt fired (borrowed identity) — or to `ksoftirqd/N` if processed by the softirq thread. The handler must not act on `current`.

- **`local_bh_disable()`/`local_bh_enable()`** prevent softirq execution on the current CPU. They add `SOFTIRQ_DISABLE_OFFSET` (0x200) to `preempt_count` — distinct from the `SOFTIRQ_OFFSET` (0x100) used by actual softirq handlers, enabling `in_serving_softirq()` to distinguish the two states. Nesting is safe — each call adds/subtracts 0x200, and softirqs only run when the count returns to zero.

- **Spinlock variants** provide different interrupt/BH masking: `spin_lock()` disables only preemption; `spin_lock_bh()` disables softirqs; `spin_lock_irqsave()` disables hardware interrupts. The choice depends on which contexts share the protected data — the rule is to disable whatever can preempt you and try to take the same lock on the same CPU.

- **On AArch64**, softirqs run on the per-CPU IRQ stack via `do_softirq_own_stack()` → `call_on_irq_stack()`, reusing the same stack-switching infrastructure as hardirq handlers to prevent kernel stack overflow.
