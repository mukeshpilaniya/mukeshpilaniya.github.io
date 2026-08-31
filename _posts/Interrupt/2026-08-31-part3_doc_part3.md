---
title: Interrupt Handling in the Linux Kernel — Part 3
published: true
categories: [Interrupt]
tags: [interrupt, threaded IRQ]
---
# Interrupt Handling in the Linux Kernel — Part 3: Threaded IRQ

> **Part 1** covers handler registration, data structures, forced threading, flags, shared interrupts, the full execution path, masking/unmasking, and IRQ affinity: `part3_doc_part1.md`
>
> **Part 2** covers interrupt control APIs (`local_irq_*`, `disable_irq`), execution context, `preempt_count`, `current` in ISR, and why sleeping is forbidden: `part3_doc_part2.md`

This document covers the **threaded interrupt model** in depth: what it is, how it relates to bottom halves, the precise difference between `request_irq()` and `request_threaded_irq()`, when the thread function executes, IRQ state inside each callable, and the `IRQF_ONESHOT` flag. All code examples are loadable kernel modules tested on AArch64.

---

## Table of Contents

1. [Is Threaded IRQ a Bottom Half?](#is-threaded-irq-a-bottom-half)
2. [request_irq vs request_threaded_irq](#request_irq-vs-request_threaded_irq)
3. [request_irq: Handler Always Runs in Hardirq Context](#request_irq-handler-always-runs-in-hardirq-context)
4. [request_threaded_irq: Handler in Hardirq, thread_fn in Process Context](#request_threaded_irq-handler-in-hardirq-thread_fn-in-process-context)
5. [When Is the Thread Function Executed?](#when-is-the-thread-function-executed)
6. [Difference Between Bottom Half and Threaded IRQ](#difference-between-bottom-half-and-threaded-irq)
7. [Checking the Threaded IRQ Kernel Thread](#checking-the-threaded-irq-kernel-thread)
8. [IRQs Enabled or Disabled in Handler and thread_fn?](#irqs-enabled-or-disabled-in-handler-and-thread_fn)
9. [IRQF_ONESHOT: Why It Is Required](#irqf_oneshot-why-it-is-required)
10. [Summary](#summary)

---

## Is Threaded IRQ a Bottom Half?

The short answer: **threaded IRQ is conceptually a bottom-half mechanism but is architecturally distinct from the classic bottom-half implementations**.

### The Bottom-Half Philosophy

When a hardware interrupt fires, the driver must acknowledge the device quickly and return. Any slow work — reading I2C registers, updating large data structures, doing network processing — is **deferred** to run later, outside hardirq context. This deferred work is called the **bottom half**; the fast acknowledgment is the **top half**.

The Linux kernel has four mechanisms for this deferral:

```
 ┌─────────────────────────────────────────────────────────────────────────────┐
 │                    BOTTOM-HALF MECHANISMS                                   │
 ├──────────────────┬─────────────────┬───────────────────┬────────────────────┤
 │   Softirq        │   Tasklet       │   Workqueue       │  Threaded IRQ      │
 ├──────────────────┼─────────────────┼───────────────────┼────────────────────┤
 │ Static: 10 fixed │ Dynamic, built  │ Kernel threads    │ Dedicated kernel   │
 │ vectors in kernel│ on softirq      │ (kworker/N:M)     │ thread per IRQ     │
 │                  │                 │                   │ (irq/N-name)       │
 ├──────────────────┼─────────────────┼───────────────────┼────────────────────┤
 │ Softirq context  │ Softirq context │ Process context   │ Process context    │
 │ in_interrupt()=T │ in_interrupt()=T│ in_interrupt()=F  │ in_interrupt()=F   │
 ├──────────────────┼─────────────────┼───────────────────┼────────────────────┤
 │ Cannot sleep     │ Cannot sleep    │ CAN sleep         │ CAN sleep          │
 ├──────────────────┼─────────────────┼───────────────────┼────────────────────┤
 │ IRQs: ENABLED    │ IRQs: ENABLED   │ IRQs: ENABLED     │ IRQs: ENABLED      │
 │ (hardirq can     │ (same)          │ (full process     │ (full process      │
 │  preempt)        │                 │  scheduling)      │  scheduling)       │
 ├──────────────────┼─────────────────┼───────────────────┼────────────────────┤
 │ Raises: NET_RX,  │ Raises: network │ Used by:          │ Used by:           │
 │ TIMER, BLOCK,    │ driver tasklets,│ slow device work, │ slow device I/O,   │
 │ TASKLET, RCU...  │ USB completions │ filesystem, ...   │ I2C reads, ONESHOT │
 └──────────────────┴─────────────────┴───────────────────┴────────────────────┘
```

### Where Does Threaded IRQ Fit?

Threaded IRQ is **not implemented using the softirq/tasklet infrastructure**. It does not touch `raise_softirq()`, the softirq pending bitmask, or any of the classic bottom-half accounting. Instead it creates a **real kernel thread** (`irq/N-name`) that is blocked in `irq_thread()`, waiting to be woken by the hardirq handler returning `IRQ_WAKE_THREAD`.

```
 Classic bottom half (softirq/tasklet):
 ──────────────────────────────────────
 hardirq handler → raise_softirq(NET_RX_SOFTIRQ)
                         ↓ irq_exit()
                   handle_softirqs()     ← softirq context, in_interrupt()=true
                   NET_RX action()

 Threaded IRQ bottom half:
 ─────────────────────────
 hardirq handler → return IRQ_WAKE_THREAD
                         ↓ __irq_wake_thread()
                   wake_up_process(action->thread)
                         ↓ scheduler picks irq/N-name
                   irq_thread() → thread_fn()    ← process context, in_interrupt()=false
```

**Verdict**: Threaded IRQ is a bottom-half mechanism in the philosophical sense (defers work from hardirq context) but NOT in the implementation sense (does not use softirq vectors). It is closer to a workqueue but tightly bound to a specific IRQ line and registered at the same time as the hardirq handler.

---

## request_irq vs request_threaded_irq

### Signatures

```c
/* include/linux/interrupt.h */

/* Simple wrapper — no thread_fn, adds IRQF_COND_ONESHOT */
static inline int request_irq(unsigned int irq, irq_handler_t handler,
                               unsigned long flags, const char *name, void *dev)
{
    return request_threaded_irq(irq, handler, NULL,
                                flags | IRQF_COND_ONESHOT, name, dev);
}

/* Full API */
int request_threaded_irq(unsigned int irq,
                         irq_handler_t handler,      /* hardirq handler */
                         irq_handler_t thread_fn,    /* thread function (may be NULL) */
                         unsigned long irqflags,
                         const char *devname,
                         void *dev_id);
```

`request_irq()` is literally a one-line inline that calls `request_threaded_irq()` with `thread_fn = NULL`. There is no separate code path.

### Side-by-Side Comparison

```
 ┌─────────────────────────────────┬──────────────────────────────────────────────┐
 │         request_irq()           │        request_threaded_irq()                │
 ├─────────────────────────────────┼──────────────────────────────────────────────┤
 │ thread_fn = NULL                │ thread_fn = user-provided function           │
 │ No kernel thread created        │ Creates irq/N-name kernel thread             │
 │                                 │                                              │
 │ handler runs:                   │ handler runs:                                │
 │   HARDIRQ context               │   HARDIRQ context                            │
 │   in_hardirq() = true           │   in_hardirq() = true                        │
 │   Cannot sleep                  │   Cannot sleep                               │
 │   IRQs: DISABLED (PSTATE.I=1)   │   IRQs: DISABLED (PSTATE.I=1)               │
 │                                 │                                              │
 │ No thread_fn                    │ thread_fn runs:                              │
 │                                 │   PROCESS context                            │
 │                                 │   in_task() = true                           │
 │                                 │   CAN sleep                                  │
 │                                 │   IRQs: ENABLED (PSTATE.I=0)                │
 │                                 │   current = irq/N-name task_struct (owned)   │
 │                                 │                                              │
 │ handler returns:                │ handler returns:                             │
 │   IRQ_HANDLED — done            │   IRQ_WAKE_THREAD → wakes thread_fn          │
 │   IRQ_NONE    — not mine        │   IRQ_HANDLED     → does NOT wake thread_fn  │
 │                                 │   IRQ_NONE        → does NOT wake thread_fn  │
 ├─────────────────────────────────┼──────────────────────────────────────────────┤
 │ Use when:                       │ Use when:                                    │
 │   Handler is fast               │   Slow work needed (I2C, USB, DMA)           │
 │   No sleeping needed            │   Must sleep or acquire mutex                │
 │   Realtime constraints          │   Level-triggered + IRQF_ONESHOT required    │
 └─────────────────────────────────┴──────────────────────────────────────────────┘
```

### With Respect to hardirq and softirq

```
 request_irq():
 ══════════════
 IRQ fires → hardirq handler (your handler) → irq_exit() → softirqs run (if pending)
                   ↑
             HARDIRQ context
             preempt_count has HARDIRQ_OFFSET
             in_hardirq() = true

 request_threaded_irq():
 ═══════════════════════
 IRQ fires → hardirq handler → return IRQ_WAKE_THREAD
                   ↑                      ↓
             HARDIRQ context    __irq_wake_thread() wakes irq/N-name
                                          ↓
             irq_exit() → softirqs run   scheduler runs irq/N-name
                                          ↓
                                   thread_fn() runs
                                          ↑
                                   PROCESS context
                                   preempt_count = 0
                                   in_task() = true
```

Neither the hardirq handler nor the thread_fn runs in **softirq context**. Softirqs are a separate mechanism that runs after the hardirq handler returns, independent of the threaded IRQ thread.

---

## request_irq: Handler Always Runs in Hardirq Context

When `request_irq()` registers a handler (no force-threading), the handler is called directly from `__handle_irq_event_percpu()` while the CPU is in hardirq context:

```c
/* kernel/irq/handle.c */
for_each_action_of_desc(desc, action) {
    res = action->handler(irq, action->dev_id);   /* ← your handler, hardirq context */
    ...
}
```

At this point:
- `preempt_count` has `HARDIRQ_OFFSET` (0x00010000) set
- `PSTATE.I = 1` — local IRQs are disabled
- `in_hardirq()` returns true
- `in_task()` returns false
- `current` points to the interrupted task (borrowed, not owned)
- Sleeping is **forbidden**

```c
/* Minimal example — handler always runs in hardirq context */
static irqreturn_t my_handler(int irq, void *dev_id)
{
    /* HARDIRQ CONTEXT:
     * - Cannot call msleep(), mutex_lock(), kmalloc(GFP_KERNEL)
     * - Can call pr_info(), spin_lock_irqsave(), del_timer()
     * - current->pid is the interrupted task — do not act on it
     */
    pr_info("handler: in_hardirq=%d in_task=%d\n",
            in_hardirq(), in_task());
    /* expected output: handler: in_hardirq=1 in_task=0 */
    return IRQ_HANDLED;
}

static int __init my_init(void)
{
    return request_irq(19, my_handler, IRQF_SHARED, "demo", &my_handler);
}
```

---

## request_threaded_irq: Handler in Hardirq, thread_fn in Process Context

`request_threaded_irq()` splits the work into two callables with different execution contexts.

### Example 1: Basic Structure — IRQ_NONE (thread never woken)

The following module shows the structural skeleton. The handler returns `IRQ_NONE` so the thread function is **never woken** — this demonstrates that `IRQ_WAKE_THREAD` is the trigger:

```c
/* day35/4 — request_threaded_irq structure; thread NOT woken (IRQ_NONE) */
#include <linux/module.h>
#include <linux/init.h>
#include <linux/interrupt.h>

#define SHARED_IRQ 19
static int irq = SHARED_IRQ, my_dev_id;
module_param(irq, int, S_IRUGO);

static irqreturn_t my_interrupt(int irq, void *dev_id)
{
    pr_info("%s: hardirq handler called\n", __func__);
    return IRQ_NONE;      /* ← thread is NOT woken; my_threaded_interrupt never runs */
}

static irqreturn_t my_threaded_interrupt(int irq, void *dev_id)
{
    pr_info("%s: thread function called\n", __func__);
    return IRQ_NONE;
}

static int __init my_init(void)
{
    int ret = request_threaded_irq(irq,
                my_interrupt,          /* hardirq handler */
                my_threaded_interrupt, /* thread function */
                IRQF_SHARED, "my_interrupt", &my_dev_id);
    if (ret)
        pr_info("Failed: %d\n", ret);
    return ret ? -1 : 0;
}

static void __exit my_exit(void)
{
    synchronize_irq(irq);
    free_irq(irq, &my_dev_id);
}

MODULE_LICENSE("GPL");
module_init(my_init);
module_exit(my_exit);
```

### Example 2: Correct Usage — IRQ_WAKE_THREAD Wakes the Thread

Changing the handler return value to `IRQ_WAKE_THREAD` causes the kernel thread to be scheduled:

```c
/* day35/5 — correct: handler returns IRQ_WAKE_THREAD, thread woken */
static irqreturn_t my_interrupt(int irq, void *dev_id)
{
    pr_info("%s: hardirq handler\n", __func__);
    return IRQ_WAKE_THREAD;   /* ← kernel calls __irq_wake_thread() after this */
}

static irqreturn_t my_threaded_interrupt(int irq, void *dev_id)
{
    pr_info("%s: thread function\n", __func__);
    return IRQ_NONE;
}
```

Observed kernel log when IRQ 19 fires:

```
my_interrupt: hardirq handler
my_threaded_interrupt: thread function
```

The two lines may not be adjacent in the log — other messages can appear between them because the thread runs later under the scheduler.

### Example 3: Context Verification — in_interrupt() in Both Callables

```c
/* day35/6 — context detection: handler=interrupt, thread=process */
void print_context(void)
{
    if (in_interrupt())
        pr_info("Code is running in interrupt context\n");
    else
        pr_info("Code is running in process context\n");
}

static irqreturn_t my_interrupt(int irq, void *dev_id)
{
    pr_info("%s\n", __func__);
    print_context();          /* prints: interrupt context */
    return IRQ_WAKE_THREAD;
}

static irqreturn_t my_threaded_interrupt(int irq, void *dev_id)
{
    pr_info("%s\n", __func__);
    print_context();          /* prints: process context */
    return IRQ_NONE;
}
```

Expected output:

```
my_interrupt
Code is running in interrupt context
my_threaded_interrupt
Code is running in process context
```

**Note**: `in_interrupt()` is deprecated; `in_hardirq()` is the correct check for the handler, and `in_task()` for the thread_fn. The output would be identical using the modern macros.

### Example 4: Real Hardware — Raspberry Pi GPIO Button

This module registers a falling-edge interrupt on GPIO 15 (a physical button). The thread function safely does a 4-second `mdelay()` — impossible in hardirq context but legal in process context:

```c
/* day35/7 — RPi GPIO button: handler wakes thread, thread does slow work */
static irqreturn_t button_handler(int irq, void *dev_id)
{
    pr_info("hardirq: button pressed (irq=%d)\n", irq);
    return IRQ_WAKE_THREAD;    /* ← acknowledge, defer slow work to thread */
}

static irqreturn_t button_threaded_handler(int irq, void *dev_id)
{
    pr_info("thread: processing button press\n");
    mdelay(4000);              /* 4 second delay — safe here, scheduler runs */
    return IRQ_HANDLED;
}

/* Registration */
irq_number = gpio_to_irq(gpio_button);
request_threaded_irq(irq_number,
    button_handler,
    button_threaded_handler,
    IRQF_TRIGGER_FALLING,      /* note: no IRQF_SHARED — GPIO line is exclusive */
    "button_interrupt",
    NULL);                     /* NULL dev_id is OK for non-shared interrupts */
```

Key difference from shared IRQ examples: `dev_id = NULL` is valid here because `IRQF_SHARED` is not set. Without `IRQF_SHARED`, `dev_id` is not used as a lookup key.

---

## When Is the Thread Function Executed?

The thread function runs only when the hardirq handler explicitly returns `IRQ_WAKE_THREAD`. The full path:

```
 IRQ fires on CPU
         │
         ▼
 hardirq handler called
 (action->handler(irq, dev_id))
         │
         ├─── returns IRQ_HANDLED  →  thread NOT woken, done
         ├─── returns IRQ_NONE     →  thread NOT woken, done
         │
         └─── returns IRQ_WAKE_THREAD
                      │
                      ▼
              __irq_wake_thread(desc, action)
              kernel/irq/handle.c
                      │
                      ▼
              Check IRQTF_RUNTHREAD flag not set
              (prevent double-wakeup if thread still running)
                      │
                      ▼
              set_bit(IRQTF_RUNTHREAD, &action->thread_flags)
              wake_up_process(action->thread)
                      │
                      ▼
              irq/N-name thread is woken by scheduler
                      │
                      ▼
              irq_thread()   kernel/irq/manage.c
                      │
                      ├─ set IRQTF_RUNTHREAD
                      ├─ irq_thread_fn()
                      │    └─ action->thread_fn(irq, dev_id)  ← YOUR thread_fn
                      │
                      └─ [if IRQF_ONESHOT] irq_finalize_oneshot()
                             └─ unmask the IRQ line (now safe to re-trigger)
```

The `irq/N-name` thread runs the `irq_thread()` loop at `SCHED_FIFO` priority. It blocks on a wait condition, is woken by `wake_up_process()`, executes the thread_fn, and blocks again. The `IRQTF_RUNTHREAD` flag prevents a second wakeup if the thread is already processing a previous event — events fired during thread execution are coalesced into one re-run.

### Example 5: Proving thread_fn Runs in Its Own Thread

```c
/* day35/10 — current->comm shows the irq/N-name thread identity */
static irqreturn_t my_threaded_interrupt(int irq, void *dev_id)
{
    pr_info("COMM:%s\t PID:%d\n", current->comm, current->pid);
    return IRQ_NONE;
}
```

Expected output when IRQ 19 fires:

```
COMM:irq/19-my_inter   PID:247
```

Compare this with what the hardirq handler would show:

```c
static irqreturn_t my_interrupt(int irq, void *dev_id)
{
    pr_info("COMM:%s\t PID:%d\n", current->comm, current->pid);
    /* output: COMM:bash   PID:1842   ← borrowed, interrupted task */
    return IRQ_WAKE_THREAD;
}
```

In the hardirq handler, `current` is the **interrupted task** (e.g., `bash`, `kworker`, `swapper`). In the thread_fn, `current` is the **`irq/N-name` thread itself** — a real, owned identity. This is why the thread_fn can call `mutex_lock()`, `msleep()`, and other functions that depend on task identity.

---

## Difference Between Bottom Half and Threaded IRQ

```
 ┌──────────────────────────────────┬─────────────────────────────────────────────┐
 │    Classic Bottom Half           │         Threaded IRQ                        │
 │    (softirq / tasklet)           │         (request_threaded_irq)              │
 ├──────────────────────────────────┼─────────────────────────────────────────────┤
 │ Triggered by raise_softirq()     │ Triggered by returning IRQ_WAKE_THREAD       │
 │                                  │                                             │
 │ Runs in softirq context          │ Runs in process context                     │
 │ in_serving_softirq() = true      │ in_task() = true                            │
 │ in_interrupt() = true            │ in_interrupt() = false                      │
 │                                  │                                             │
 │ IRQs: ENABLED                    │ IRQs: ENABLED                               │
 │ Hardirq CAN preempt softirq      │ Hardirq CAN preempt thread                  │
 │                                  │                                             │
 │ Cannot sleep                     │ CAN sleep                                   │
 │ kmalloc: GFP_ATOMIC only         │ kmalloc: GFP_KERNEL allowed                 │
 │ No mutex_lock()                  │ mutex_lock() allowed                        │
 │                                  │                                             │
 │ Runs immediately after hardirq   │ Scheduled by the kernel scheduler           │
 │ on the same CPU                  │ may run on a different CPU                  │
 │                                  │                                             │
 │ Shared: NET_RX, TIMER used       │ Private: one thread per IRQ line            │
 │ by many drivers                  │                                             │
 │                                  │                                             │
 │ Higher throughput (less          │ Lower throughput (thread switch overhead)   │
 │ scheduling overhead)             │                                             │
 │                                  │                                             │
 │ Used for: network RX, timer,     │ Used for: slow I2C reads, USB completions,  │
 │ block I/O completion, RCU        │ PMIC interrupt handling, GPIO demux         │
 └──────────────────────────────────┴─────────────────────────────────────────────┘
```

The practical decision rule:
- Need to sleep or acquire a mutex → use threaded IRQ
- Need maximum throughput with minimal latency → use softirq/tasklet
- Already using workqueue and want loose coupling → workqueue is fine
- Tight coupling to a specific IRQ line → threaded IRQ is more natural

---

## Checking the Threaded IRQ Kernel Thread

When `request_threaded_irq()` creates a thread, it is visible in the process list under the name `irq/N-name` where N is the Linux IRQ number and name is the string passed to `request_threaded_irq()`.

```bash
# List all threaded IRQ kernel threads
ps -ef | grep 'irq/'

# Example output on a running system:
#   UID   PID  PPID  CMD
#   root   15     2   [irq/9-acpi]
#   root   16     2   [irq/16-ehci_hcd]
#   root   51     2   [irq/19-my_inter]     ← our module's thread
#   root   52     2   [irq/27-arch_timer]

# Show all kernel threads (PID 2 = kthreadd is the parent of all kernel threads)
ps -ef | grep '\[irq/'

# Alternatively, with thread details:
ps aux | grep 'irq/'

# Check the scheduling policy and priority of the IRQ thread
# (threaded IRQ threads run at SCHED_FIFO priority 50 by default)
chrt -p $(pgrep -f 'irq/19-my_inter')
# output: scheduling policy: SCHED_FIFO   scheduling priority: 50

# Find which CPU the thread is running on
ps -eo pid,psr,comm | grep 'irq/'
# PSR column shows the CPU number

# After insmod of the module, verify thread created:
cat /proc/interrupts | grep my_interrupt
#  19:    1024    0    0    0   GICv3  19 Level   my_interrupt

# The thread name is truncated to 15 characters (TASK_COMM_LEN limit):
# "irq/19-my_interrupt" becomes "irq/19-my_inter"
```

The thread is created by `setup_irq_thread()` at [kernel/irq/manage.c](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/irq/manage.c):

```c
t = kthread_create(irq_thread, new, "irq/%d-%s", irq, new->name);
sched_set_fifo(t);    /* SCHED_FIFO at priority 50 */
```

The thread runs the `irq_thread()` loop, which blocks waiting for `wake_up_process()` from the hardirq handler. When the module is unloaded and `free_irq()` is called, `kthread_stop_put()` terminates the thread — it disappears from `ps` output.

---

## IRQs Enabled or Disabled in Handler and thread_fn?

This is directly verifiable with `irqs_disabled()` inside each callable.

### Example: irqs_disabled() in Handler and Thread Function

```c
/* day35/11 — IRQ state in handler vs thread_fn */
#include <linux/module.h>
#include <linux/init.h>
#include <linux/interrupt.h>
#include <linux/irqflags.h>
#include <linux/sched.h>

#define SHARED_IRQ 19
static int irq = SHARED_IRQ, my_dev_id;
module_param(irq, int, S_IRUGO);

void is_irq_disabled(void)
{
    if (irqs_disabled())
        pr_info("IRQ Disabled\n");
    else
        pr_info("IRQ Enabled\n");
}

static irqreturn_t my_interrupt(int irq, void *dev_id)
{
    is_irq_disabled();          /* prints: IRQ Disabled */
    return IRQ_WAKE_THREAD;
}

static irqreturn_t my_threaded_interrupt(int irq, void *dev_id)
{
    pr_info("COMM:%s\t PID:%d\n", current->comm, current->pid);
    is_irq_disabled();          /* prints: IRQ Enabled */
    return IRQ_NONE;
}

static int __init my_init(void)
{
    return request_threaded_irq(irq, my_interrupt, my_threaded_interrupt,
                                IRQF_SHARED, "my_interrupt", &my_dev_id);
}

static void __exit my_exit(void)
{
    synchronize_irq(irq);
    free_irq(irq, &my_dev_id);
}

MODULE_LICENSE("GPL");
module_init(my_init);
module_exit(my_exit);
```

Expected kernel log output:

```
IRQ Disabled                         ← from my_interrupt (hardirq context)
COMM:irq/19-my_inter    PID:247      ← from my_threaded_interrupt
IRQ Enabled                          ← from my_threaded_interrupt (process context)
```

### Why the Difference?

```
 ┌─────────────────────────────────────────────────────────────────────────────┐
 │              handler (my_interrupt)                                         │
 │              runs in HARDIRQ context                                        │
 │                                                                             │
 │  Entry path sets PSTATE.I=1 via:                                            │
 │    write_sysreg(DAIF_PROCCTX_NOIRQ, daif)                                   │
 │    where DAIF_PROCCTX_NOIRQ = PSR_I_BIT | PSR_F_BIT                        │
 │                                                                             │
 │  irqs_disabled() reads DAIF register → PSR_I_BIT is SET → returns true     │
 │  Result: IRQ Disabled                                                       │
 └─────────────────────────────────────────────────────────────────────────────┘

 ┌─────────────────────────────────────────────────────────────────────────────┐
 │              my_threaded_interrupt (thread_fn)                              │
 │              runs in PROCESS context inside irq/N-name thread               │
 │                                                                             │
 │  The irq/N-name thread is a normal kernel thread scheduled by the           │
 │  scheduler. It runs with interrupts ENABLED — no special masking.           │
 │                                                                             │
 │  irqs_disabled() reads DAIF register → PSR_I_BIT is CLEAR → returns false  │
 │  Result: IRQ Enabled                                                        │
 └─────────────────────────────────────────────────────────────────────────────┘
```

### Summary Table: IRQ State by Context

```
 Callable                   Context        irqs_disabled()   Can sleep
 ──────────────────────────────────────────────────────────────────────
 handler (request_irq)      hardirq        true              NO
 handler (request_threaded) hardirq        true              NO
 thread_fn                  process        false             YES
 softirq action             softirq        false*            NO
 tasklet action             softirq        false*            NO
 workqueue handler          process        false             YES

 * IRQs re-enabled by handle_softirqs() before running actions;
   a hardirq CAN preempt a softirq handler.
```

---

## IRQF_ONESHOT: Why It Is Required

`IRQF_ONESHOT` is one of the most misunderstood flags in the interrupt subsystem. It is essential for **level-triggered interrupts with threaded handlers**.

### The Problem Without IRQF_ONESHOT

Consider a level-triggered interrupt (the GIC line stays HIGH while the device has work to do):

```
 WITHOUT IRQF_ONESHOT — interrupt storm on level-triggered line
 ══════════════════════════════════════════════════════════════

 1. Device asserts IRQ line (level HIGH)
         │
         ▼
 2. GIC delivers interrupt to CPU
         │
         ▼
 3. hardirq handler runs, returns IRQ_WAKE_THREAD
         │
         ▼
 4. handle_fasteoi_irq sends EOI → GIC unmasks the line
         │
         ▼
 5. IRQ line is STILL HIGH (device not yet serviced — thread hasn't run)
         │
         ▼
 6. GIC immediately re-delivers the interrupt! ← interrupt storm
         │
         ▼
 7. CPU re-enters handler before thread even starts
         │
         ▼
 8. Loop: steps 2–7 repeat thousands of times per second
         │
         ▼
 9. thread_fn never gets CPU time to actually service the device
         CPU is stuck in an interrupt loop
```

### How IRQF_ONESHOT Solves It

```
 WITH IRQF_ONESHOT — line masked until thread completes
 ══════════════════════════════════════════════════════

 1. Device asserts IRQ line (level HIGH)
         │
         ▼
 2. handle_fasteoi_irq: mask_irq(desc)    ← MASK LINE before calling handler
    (writes to GICD_ICENABLER)
         │
         ▼
 3. hardirq handler runs, returns IRQ_WAKE_THREAD
         │
         ▼
 4. handle_fasteoi_irq: does NOT send EOI that unmasks
    IRQ line stays MASKED at GIC level
         │
         ▼
 5. thread_fn runs in irq/N-name process context
    Reads I2C register / clears device condition
    Device de-asserts IRQ line (level goes LOW)
         │
         ▼
 6. irq_finalize_oneshot() → unmask_irq(desc)
    (writes to GICD_ISENABLER)
    Line is safe to unmask: device cleared its interrupt
         │
         ▼
 7. System is ready for the next genuine interrupt
```

### The Depth Tracking for Multiple ONESHOT Handlers

When multiple `IRQF_ONESHOT` handlers share a line, each gets a unique bit in `action->thread_mask`. The line is only unmasked when **all** bits are cleared — i.e., every threaded handler on the line has finished:

```c
/* irq_finalize_oneshot() — kernel/irq/manage.c */
static void irq_finalize_oneshot(struct irq_desc *desc,
                                  struct irqaction *action)
{
    /* Clear this handler's bit from threads_oneshot */
    action->thread_mask &= ~desc->threads_oneshot;  /* clear our bit */
    if (!desc->threads_oneshot)                      /* all bits clear? */
        unmask_irq(desc);                            /* → unmask hardware */
}
```

```
 Shared line with two IRQF_ONESHOT handlers:

 threads_oneshot bitmask: 0b11  (both handlers running)
         │
         │ Handler A thread finishes
         ▼
 threads_oneshot bitmask: 0b10  (still masked — B still running)
         │
         │ Handler B thread finishes
         ▼
 threads_oneshot bitmask: 0b00  (all done → unmask hardware)
```

### When Is IRQF_ONESHOT Mandatory?

| Interrupt type | Trigger | IRQF_ONESHOT needed? | Reason |
|---|---|---|---|
| Level-triggered | HIGH/LOW | **YES** | Without it: interrupt storm before thread runs |
| Edge-triggered | Rising/Falling | Not strictly needed | Edge is self-clearing; no re-assertion |
| NULL handler + thread_fn | Any | **YES** (kernel enforces it) | kernel adds it automatically via `irq_default_primary_handler` |
| `request_irq()` with force-threading | Level | **YES** (kernel adds it) | `irq_setup_forced_threading()` adds `IRQF_ONESHOT` |

The kernel enforces the rule: if `handler == NULL` and `thread_fn` is set, `__setup_irq()` requires `IRQF_ONESHOT` and will return `-EINVAL` without it:

```c
/* kernel/irq/manage.c — inside __setup_irq() */
if (!new->thread_fn && (new->flags & IRQF_ONESHOT)) {
    pr_err("Interrupt %d: IRQF_ONESHOT set but no thread function\n", irq);
    return -EINVAL;
}
if (new->thread_fn && !(new->flags & IRQF_ONESHOT)) {
    /* For NULL handler + thread_fn case, kernel adds IRQF_ONESHOT */
}
```

### Code Example: Thread-Only Handler (NULL handler + IRQF_ONESHOT)

The most common pattern for slow devices — no hardirq handler at all:

```c
static irqreturn_t pmic_thread_handler(int irq, void *dev_id)
{
    struct my_pmic *pmic = dev_id;

    /* Safe: running in process context */
    i2c_smbus_read_byte_data(pmic->client, STATUS_REG);  /* can sleep */
    handle_pmic_event(pmic);
    return IRQ_HANDLED;
}

static int pmic_probe(struct i2c_client *client)
{
    return request_threaded_irq(client->irq,
        NULL,                  /* handler = NULL → kernel installs stub */
        pmic_thread_handler,   /* thread_fn = slow I2C read */
        IRQF_ONESHOT,          /* MANDATORY for NULL handler + thread_fn */
        "pmic-irq",
        pmic);
}
```

Without `IRQF_ONESHOT` here, `request_threaded_irq()` returns `-EINVAL`.

### IRQF_COND_ONESHOT: Transparent Compatibility

`request_irq()` automatically adds `IRQF_COND_ONESHOT` to its flags. This flag means "if the line already has `IRQF_ONESHOT`, I agree to participate in the one-shot protocol." It allows a plain `request_irq()` handler to share a line with a `request_threaded_irq(IRQF_ONESHOT)` handler without explicit coordination from the driver:

```c
/* request_irq() adds this automatically: */
flags | IRQF_COND_ONESHOT

/* In __setup_irq() shared IRQ validation: */
if ((old->flags & IRQF_ONESHOT) && (new->flags & IRQF_COND_ONESHOT))
    new->flags |= IRQF_ONESHOT;   /* promote: new handler joins ONESHOT protocol */
```

---

## Summary

```
 ┌─────────────────────────────────────────────────────────────────────────────┐
 │ request_irq(irq, handler, flags, name, dev)                                │
 │                                                                             │
 │  Kernel thread:  NONE                                                       │
 │  handler:        HARDIRQ context — IRQs disabled, cannot sleep             │
 │  thread_fn:      (none)                                                     │
 │  current:        borrowed (interrupted task)                                │
 └─────────────────────────────────────────────────────────────────────────────┘

 ┌─────────────────────────────────────────────────────────────────────────────┐
 │ request_threaded_irq(irq, handler, thread_fn, flags, name, dev)            │
 │                                                                             │
 │  Kernel thread:  irq/N-name  (SCHED_FIFO priority 50)                      │
 │  handler:        HARDIRQ context — IRQs disabled, cannot sleep             │
 │                  must return IRQ_WAKE_THREAD to activate thread_fn          │
 │  thread_fn:      PROCESS context — IRQs enabled, CAN sleep                 │
 │                  current is owned (irq/N-name task_struct)                  │
 └─────────────────────────────────────────────────────────────────────────────┘

 Is threaded IRQ a bottom half?
   Conceptually YES — defers work from hardirq context
   Mechanically NO  — not softirq; creates a real kernel thread

 Difference from softirq/tasklet:
   Softirq: softirq context, cannot sleep, in_interrupt()=true
   Threaded: process context, CAN sleep, in_interrupt()=false

 IRQF_ONESHOT:
   MANDATORY for level-triggered lines with thread_fn
   Keeps GIC line MASKED from handler invocation until thread_fn completes
   Prevents interrupt storm (device re-asserts before thread services it)

 Verify thread:
   ps -ef | grep 'irq/'
   chrt -p $(pgrep -f 'irq/N-name')   → SCHED_FIFO priority 50
```

## References:
- https://0xax.gitbook.io/linux-insides/summary/interrupts/linux-interrupts-4
- https://static.lwn.net/images/pdf/LDD3/ch10.pdf
- https://www.xml.com/ldd/chapter/book/ch09.html
- https://linux-kernel-labs.github.io/refs/heads/master/lectures/interrupts.html
- https://www.udemy.com/course/interrupts-and-bottom-halves-in-deep/
- https://github.com/jyfc/ebook/blob/master/03_operating_system/Linux.Kernel.Development.3rd.Edition.pdf
    - chapter 7 and 8.
- https://github.com/firmianay/Life-long-Learner/blob/master/linux-kernel-development/chapter-7.md
- https://github.com/firmianay/Life-long-Learner/blob/master/linux-kernel-development/chapter-8.md
- ./UnderStanding-The-Linux-Kernel-3rd-Edition.pdf
    - Interrupt and Exception chapter
- [Arm Interrupt Documents](https://support.arm.com/documentation/198123/0302/Arm-GIC-fundamentals)
- [Arm Interrupt and Exception](https://support.arm.com/documentation/den0042/0100/Exceptions-and-Interrupts)
- [IRQs: the Hard, the Soft, the Threaded and the Preemptible Video](https://www.youtube.com/watch?v=-pehAzaP1eg)
- [IRQs: the Hard, the Soft, the Threaded and the Preemptible Slide](https://she-devel.com/Chaiken_ELCE2016.pdf)
