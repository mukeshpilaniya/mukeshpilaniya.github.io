---
title: Interrupt Handling in the Linux Kernel — Part 2
published: true
categories: [Interrupt]
tags: [interrupt]
---
# Interrupt Handling in the Linux Kernel — Part 2: Interrupt Control, Context, and Constraints

> **Part 1** covers handler registration, IRQ data structures, forced threading, flags, shared interrupts, the full execution path, masking/unmasking, and IRQ affinity: `part3_doc_part1.md`

This document covers the interrupt control APIs (`local_irq_disable`, `local_irq_save`, `disable_irq`, `disable_irq_nosync`, `synchronize_irq`), execution context (hardirq, softirq, process), the `preempt_count` bitfield, context detection macros, the value of `current` inside a handler, why sleeping is forbidden, and the per-CPU IRQ stack on AArch64.

---

## Table of Contents

1. [Enabling and Disabling Interrupts](#enabling-and-disabling-interrupts)
2. [The Conceptual Model: What local_irq_disable and local_irq_enable Actually Do](#the-conceptual-model-what-local_irq_disable-and-local_irq_enable-actually-do)
3. [The Problem That local_irq_save and local_irq_restore Solve](#the-problem-that-local_irq_save-and-local_irq_restore-solve)
4. [Per-Line Interrupt Control: disable_irq and enable_irq](#per-line-interrupt-control-disable_irq-and-enable_irq)
5. [What Happens If disable_irq Is Called Twice and enable_irq Only Once](#what-happens-if-disable_irq-is-called-twice-and-enable_irq-only-once)
6. [What Happens When You Disable a Shared Interrupt Line](#what-happens-when-you-disable-a-shared-interrupt-line)
7. [Is There an API to Disable All Interrupts on All CPUs](#is-there-an-api-to-disable-all-interrupts-on-all-cpus)
8. [Process Context vs. Interrupt Context](#process-context-vs-interrupt-context)
9. [Hardirq Context vs. Softirq Context](#hardirq-context-vs-softirq-context)
10. [The preempt_count Bitfield](#the-preempt_count-bitfield)
11. [Checking Your Execution Context](#checking-your-execution-context)
12. [The Value of current Inside an Interrupt Handler](#the-value-of-current-inside-an-interrupt-handler)
13. [Why You Cannot Sleep in an Interrupt Handler](#why-you-cannot-sleep-in-an-interrupt-handler)
14. [The Per-CPU IRQ Stack on AArch64](#the-per-cpu-irq-stack-on-aarch64)
15. [Summary](#summary)

---

## Enabling and Disabling Interrupts

The kernel provides two fundamentally different categories of interrupt control: **local CPU interrupt masking** (affects only the current processor) and **per-IRQ-line control** (affects a specific interrupt across all CPUs). Understanding the distinction is essential for writing correct synchronization code.

### Two Categories of Interrupt Control

```
 ┌─────────────────────────────────────────────────────────────────────────┐
 │                INTERRUPT CONTROL IN LINUX                               │
 ├─────────────────────────────────┬───────────────────────────────────────┤
 │  LOCAL CPU INTERRUPT MASKING    │  PER-IRQ-LINE CONTROL                │
 │  (affects THIS CPU only)       │  (affects ONE line across ALL CPUs)   │
 ├─────────────────────────────────┼───────────────────────────────────────┤
 │                                 │                                       │
 │  local_irq_disable()           │  disable_irq(irq)                    │
 │  local_irq_enable()            │  enable_irq(irq)                     │
 │  local_irq_save(flags)         │  disable_irq_nosync(irq)             │
 │  local_irq_restore(flags)      │                                       │
 │                                 │                                       │
 │  Mechanism:                     │  Mechanism:                           │
 │  ┌─────────────────────────┐   │  ┌─────────────────────────────────┐ │
 │  │ Path 1 (standard):      │   │  │ irq_desc->depth counter         │ │
 │  │  PSTATE.I/F bits        │   │  │ depth 0→1: mask at GIC          │ │
 │  │  msr daifset/daifclr    │   │  │ depth 1→0: unmask at GIC        │ │
 │  │                         │   │  │                                   │ │
 │  │ Path 2 (pseudo-NMI):   │   │  │ GIC registers:                   │ │
 │  │  ICC_PMR_EL1 register   │   │  │  GICD_ICENABLER (mask)           │ │
 │  │  Priority-based masking │   │  │  GICD_ISENABLER (unmask)         │ │
 │  └─────────────────────────┘   │  └─────────────────────────────────┘ │
 │                                 │                                       │
 │  Scope: per-CPU PSTATE         │  Scope: GIC Distributor/Redistributor│
 │  Latency: ~1 instruction      │  Latency: register write + RWP wait  │
 │  Nesting: use save/restore     │  Nesting: depth counter              │
 └─────────────────────────────────┴───────────────────────────────────────┘
```

### Local CPU Interrupt Masking on AArch64

These functions mask or unmask interrupts on the **local CPU only**. They are the most common synchronization primitive in the kernel — used to protect per-CPU data structures from interrupt handler corruption.

On AArch64, there are **two paths** depending on whether the system uses **GIC priority masking** for pseudo-NMI support. The selection is made at runtime by `system_uses_irq_prio_masking()`. Both paths are defined in [arch/arm64/include/asm/irqflags.h](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/irqflags.h).

#### Path 1: DAIF-Based (Standard)

The traditional approach toggles the **PSTATE.I** and **PSTATE.F** bits using dedicated ARM instructions:

```c
/* arch/arm64/include/asm/irqflags.h, lines 23-28 */
static __always_inline void __daif_local_irq_enable(void)
{
    barrier();
    asm volatile("msr daifclr, #3");
    barrier();
}

/* lines 52-57 */
static __always_inline void __daif_local_irq_disable(void)
{
    barrier();
    asm volatile("msr daifset, #3");
    barrier();
}
```

The immediate operand `#3` is a 4-bit field where bit[3]=D, bit[2]=A, bit[1]=I, bit[0]=F. So `#3` = `0b0011` = bits I and F — both IRQ and FIQ masking. `msr daifset, #3` **sets** these bits (masking interrupts), and `msr daifclr, #3` **clears** them (unmasking).

The DAIF bits in PSTATE occupy bits [9:6], defined in [arch/arm64/include/uapi/asm/ptrace.h, lines 45–48](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/uapi/asm/ptrace.h#L45-L48):

```
PSTATE Bit [9] = D (Debug mask)      PSR_D_BIT = 0x00000200
PSTATE Bit [8] = A (SError mask)     PSR_A_BIT = 0x00000100
PSTATE Bit [7] = I (IRQ mask)        PSR_I_BIT = 0x00000080
PSTATE Bit [6] = F (FIQ mask)        PSR_F_BIT = 0x00000040
```

When `PSTATE.I` is set, the CPU will not take IRQ exceptions. The interrupt remains pending at the GIC — it is not lost — and will be delivered as soon as the bit is cleared.

#### Path 2: PMR-Based (Priority Masking, for Pseudo-NMI)

When the system supports pseudo-NMI (`ARM64_HAS_GIC_PRIO_MASKING`), the kernel does not toggle PSTATE.I. Instead, it writes to the GIC's **ICC_PMR_EL1** (Interrupt Controller Priority Mask Register):

```c
/* arch/arm64/include/asm/irqflags.h, lines 30-41 */
static __always_inline void __pmr_local_irq_enable(void)
{
    barrier();
    write_sysreg_s(GIC_PRIO_IRQON, SYS_ICC_PMR_EL1);
    pmr_sync();
    barrier();
}

/* lines 59-68 */
static __always_inline void __pmr_local_irq_disable(void)
{
    barrier();
    write_sysreg_s(GIC_PRIO_IRQOFF, SYS_ICC_PMR_EL1);
    barrier();
}
```

The priority values, defined in [include/linux/irqchip/arm-gic-v3-prio.h, lines 28–30](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/irqchip/arm-gic-v3-prio.h#L28-L30), implement a three-tier scheme:

```
 Priority Value    Meaning                   Numeric (lower = higher priority)
 ──────────────    ─────────────────────────  ─────────────────────────────────
 0x80              GICV3_PRIO_NMI            Pseudo-NMI priority (highest)
 0xc0              GICV3_PRIO_IRQ            Normal IRQ priority
 0xe0              GICV3_PRIO_UNMASKED       All interrupts allowed (lowest mask)
```

- `GIC_PRIO_IRQON` = `0xe0` — the mask allows everything through.
- `GIC_PRIO_IRQOFF` = `0xc0` — only interrupts with priority numerically lower than `0xc0` (i.e., higher priority) get through. This blocks normal IRQs (`0xc0`) but allows pseudo-NMIs (`0x80`).

This is the mechanism that enables **pseudo-NMI on AArch64** — the kernel can mask normal interrupts while leaving the pseudo-NMI path open.

The `pmr_sync()` function in `__pmr_local_irq_enable()` issues a `dsb sy` instruction to ensure the PMR write completes before any subsequent instruction might be interrupted. Without this barrier, a pending interrupt could sneak in before the PMR update takes effect.

#### The Dispatch Layer

```
 local_irq_disable() / local_irq_enable()
          │
          ▼
 ┌────────────────────────────────────┐
 │ system_uses_irq_prio_masking()?   │
 └──────┬────────────────────┬───────┘
        │                    │
       Yes                   No
        │                    │
        ▼                    ▼
 ┌──────────────┐    ┌──────────────┐
 │ PMR Path     │    │ DAIF Path    │
 │              │    │              │
 │ Write to     │    │ msr daifset  │
 │ ICC_PMR_EL1  │    │ msr daifclr  │
 │              │    │              │
 │ IRQ off:     │    │ IRQ off:     │
 │ PMR = 0xc0   │    │ PSTATE.I=1   │
 │ (blocks ≥    │    │ PSTATE.F=1   │
 │  0xc0 prio)  │    │              │
 │              │    │ IRQ on:      │
 │ IRQ on:      │    │ PSTATE.I=0   │
 │ PMR = 0xe0   │    │ PSTATE.F=0   │
 │ (all thru)   │    │              │
 │              │    │              │
 │ Allows       │    │ Blocks ALL   │
 │ pseudo-NMI   │    │ interrupts   │
 │ (prio 0x80)  │    │              │
 └──────────────┘    └──────────────┘
```

The public API selects the correct path at runtime:

```c
/* arch/arm64/include/asm/irqflags.h, lines 43-78 */
static __always_inline void arch_local_irq_enable(void)
{
    if (system_uses_irq_prio_masking())
        __pmr_local_irq_enable();
    else
        __daif_local_irq_enable();
}

static __always_inline void arch_local_irq_disable(void)
{
    if (system_uses_irq_prio_masking())
        __pmr_local_irq_disable();
    else
        __daif_local_irq_disable();
}
```

These are wrapped by the generic layer in [include/linux/irqflags.h, lines 200–238](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/irqflags.h#L200-L238), which adds lockdep and tracing instrumentation when `CONFIG_TRACE_IRQFLAGS` is enabled:

```
local_irq_disable()  →  raw_local_irq_disable()  →  arch_local_irq_disable()
local_irq_enable()   →  raw_local_irq_enable()   →  arch_local_irq_enable()
```

---

## The Conceptual Model: What local_irq_disable and local_irq_enable Actually Do

Before diving into the implementation, it is worth understanding what these functions conceptually accomplish and when to use them.

**`local_irq_disable()`** tells the current CPU: "do not deliver any hardware interrupts to me until I say otherwise." The CPU finishes its current instruction, and from that point forward, even if a device asserts an interrupt and the GIC forwards it, the CPU will not take the exception. The interrupt stays **pending** — it is not lost — and will be delivered the moment `local_irq_enable()` clears the mask.

The word **local** is critical: this only affects the CPU executing the call. If the system has 8 CPUs and CPU 3 calls `local_irq_disable()`, CPUs 0–2 and 4–7 continue receiving and handling interrupts normally. There is no way to disable another CPU's interrupts from software — each CPU's PSTATE is private to that CPU.

**Why does the kernel need this?** The primary use case is protecting **per-CPU data structures** from corruption by interrupt handlers. Consider a per-CPU counter that the kernel increments during normal execution and also reads inside an interrupt handler. If an interrupt arrives between a read and a write of the counter, the handler sees a half-updated value. Disabling interrupts around the critical section guarantees atomicity with respect to interrupt handlers on the same CPU:

```c
unsigned long val;

local_irq_disable();
val = this_cpu_read(my_counter);
val++;
this_cpu_write(my_counter, val);
local_irq_enable();
```

Between `local_irq_disable()` and `local_irq_enable()`, no interrupt handler can run on this CPU, so the read-modify-write is safe. Note that this does **not** protect against concurrent access from other CPUs — for that, you need a spinlock (typically combined with interrupt disabling via `spin_lock_irqsave()`).

**`local_irq_disable()` and `local_irq_enable()` affect only the local CPU.** They read and write the CPU's own `PSTATE.I` bit (or `ICC_PMR_EL1` on systems with priority masking). Each CPU has its own PSTATE — there is no shared register, no IPI, and no bus transaction involved. This is why the operation is extremely fast (a single `msr` instruction) and why it cannot affect other CPUs.

### Module Example: local_irq_disable / local_irq_enable

The following module disables interrupts on the loading CPU for 10 seconds. **Do not run this on a production system** — the CPU will be completely unresponsive to all hardware interrupts (including the keyboard and timer) for the entire delay:

```c
/* day34/10 — demonstrates the effect of local_irq_disable */
#include <linux/module.h>
#include <linux/init.h>
#include <linux/delay.h>
#include <linux/irqflags.h>

static int __init my_init(void)
{
    pr_info("module is loaded on processor:%d\n", smp_processor_id());
    local_irq_disable();
    pr_info("interrupts disabled on processor:%d\n", smp_processor_id());
    mdelay(10000L);      /* busy-wait 10 seconds with IRQs disabled */
    local_irq_enable();
    return 0;
}

static void __exit my_exit(void) {}

MODULE_LICENSE("GPL");
module_init(my_init);
module_exit(my_exit);
```

What you observe when this module loads:
- The kernel log shows "interrupts disabled on processor:N"
- For 10 seconds, **only this CPU** is deaf to hardware interrupts. On a multiprocessor system, other CPUs continue normally — timer ticks, network interrupts, and disk I/O still arrive on other CPUs.
- After `local_irq_enable()`, the CPU immediately processes any interrupts that became pending during the disabled window (the GIC held them; they were not lost).
- `mdelay()` is a busy-wait (polling a hardware timer), not a sleep — it does not call `schedule()`, so it is legal in this context. However, 10 seconds is absurdly long for a critical section and would cause real system problems.

---

## The Problem That local_irq_save and local_irq_restore Solve

`local_irq_disable()` and `local_irq_enable()` have a fundamental limitation: **`local_irq_enable()` unconditionally enables interrupts**, regardless of whether they were enabled before the corresponding `local_irq_disable()`. This is dangerous in code that can be called from multiple contexts.

Consider a function that protects a critical section by disabling interrupts:

```c
void update_device_register(struct my_device *dev)
{
    local_irq_disable();
    writel(dev->cached_val, dev->reg);
    dev->cached_val++;
    local_irq_enable();        /* ← BUG if caller already had interrupts disabled */
}
```

This function works correctly when called from process context (where interrupts are normally enabled). But what if it is called from another critical section that has already disabled interrupts?

```c
void higher_level_operation(struct my_device *dev)
{
    local_irq_disable();
    /* ... do something that requires interrupts disabled ... */
    update_device_register(dev);   /* calls local_irq_enable() inside! */
    /* ← INTERRUPTS ARE NOW ENABLED — but we still need them disabled */
    do_something_else_critical();  /* ← this runs with interrupts enabled — BUG */
    local_irq_enable();
}
```

The inner `local_irq_enable()` blindly re-enables interrupts, breaking the outer caller's assumption that interrupts would remain disabled throughout its critical section. This is a real class of kernel bugs.

**`local_irq_save(flags)` and `local_irq_restore(flags)` solve this problem.** `local_irq_save()` reads the current interrupt state into `flags` **before** disabling interrupts. `local_irq_restore()` writes the saved state back — re-enabling interrupts only if they were enabled at the time of the save. If interrupts were already disabled, they stay disabled after the restore:

```c
void update_device_register(struct my_device *dev)
{
    unsigned long flags;
    local_irq_save(flags);              /* save state, then disable */
    writel(dev->cached_val, dev->reg);
    dev->cached_val++;
    local_irq_restore(flags);           /* restore whatever state we found */
}
```

Now this function is safe to call from **any context** — whether interrupts were enabled or disabled when it was called. If the caller had interrupts disabled, `flags` captures that disabled state, and `local_irq_restore()` leaves them disabled. If the caller had interrupts enabled, `flags` captures that, and `local_irq_restore()` re-enables them.

The rule of thumb: **use `local_irq_save()`/`local_irq_restore()` in any code that might be called from both interrupt-enabled and interrupt-disabled contexts** — which is most utility functions, library code, and any function called from more than one site. Use `local_irq_disable()`/`local_irq_enable()` only when you are certain that interrupts are currently enabled (e.g., at the top level of a system call path).

Like `local_irq_disable()`/`local_irq_enable()`, the save/restore pair affects **only the local CPU**. The saved `flags` value contains the CPU's own PSTATE (DAIF register value or PMR value), which is a per-CPU register. There is no mechanism to save or restore another CPU's interrupt state.

### local_irq_save() and local_irq_restore() — AArch64 Implementation

**`local_irq_save(flags)`** saves the current interrupt state into `flags` and then disables interrupts. **`local_irq_restore(flags)`** restores the saved state — re-enabling interrupts only if they were enabled before the save. This is the **nest-safe** variant and should be used whenever the code cannot guarantee that interrupts are currently enabled:

```c
/* arch/arm64/include/asm/irqflags.h, lines 140-147 (DAIF path) */
static __always_inline unsigned long __daif_local_irq_save(void)
{
    unsigned long flags = __daif_local_save_flags();   /* reads DAIF register */
    __daif_local_irq_disable();                         /* msr daifset, #3 */
    return flags;
}

/* lines 172-177 */
static __always_inline void __daif_local_irq_restore(unsigned long flags)
{
    barrier();
    write_sysreg(flags, daif);    /* writes saved value back to DAIF */
    barrier();
}
```

The critical difference from `local_irq_disable()`/`local_irq_enable()` is that the save/restore pair is **idempotent with respect to nesting**: if interrupts were already disabled when `local_irq_save()` was called, `local_irq_restore()` will leave them disabled. This prevents the following bug:

```c
/* WRONG — if interrupts were already disabled, this re-enables them */
local_irq_disable();
/* ... critical section ... */
local_irq_enable();    /* ← oops, interrupts may have been disabled by caller */

/* CORRECT — preserves the caller's interrupt state */
unsigned long flags;
local_irq_save(flags);
/* ... critical section ... */
local_irq_restore(flags);
```

### irqs_disabled() — Checking Interrupt State

**`irqs_disabled()`** returns true if local interrupts are currently disabled on this CPU, defined in [include/linux/irqflags.h, lines 253–260](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/irqflags.h#L253-L260). On AArch64:

- **DAIF path**: reads the DAIF register and checks `PSR_I_BIT` (bit 7) — [arch/arm64/include/asm/irqflags.h, lines 102–105](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/irqflags.h#L102-L105).
- **PMR path**: reads `ICC_PMR_EL1` and checks if it is not equal to `GIC_PRIO_IRQON` (`0xe0`) — [arch/arm64/include/asm/irqflags.h, lines 107–110](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/irqflags.h#L107-L110).

The primary use of `irqs_disabled()` is **assertion checking** — verifying that a critical section requiring interrupts to be disabled is actually entered correctly:

```c
void update_percpu_counter(void)
{
    WARN_ON(!irqs_disabled());    /* catch callers who forgot to disable */

    /* ... operate on per-CPU data that interrupts must not disturb ... */
}
```

It is also used by the kernel's own code in diagnostic paths. For example, `__schedule()` calls `preempt_schedule_common()` which uses `irqs_disabled()` to distinguish a voluntary sleep from a preemption event — the two paths require different accounting.

**Do not use `irqs_disabled()` as a condition to skip locking.** Interrupts being disabled does not mean the data is safe from concurrent access on other CPUs. The correct pattern is: choose the right lock (`spin_lock_irqsave`), not a conditional based on `irqs_disabled()`.

```
 irqs_disabled() Quick Reference
 ════════════════════════════════

 Context                  irqs_disabled()  Why
 ───────────────────────  ───────────────  ─────────────────────────────────────
 Normal process code           false       PSTATE.I=0, IRQs enabled
 After local_irq_disable()      true       PSTATE.I=1 or PMR=0xc0
 Inside hardirq handler          true       Entry path set PSTATE.I=1
 Inside softirq handler         false       handle_softirqs() re-enabled IRQs
 After local_irq_save()          true       Save+disable sets PSTATE.I=1
 spin_lock_irqsave() held        true       Saves flags then disables
```

### Module Example: local_irq_save / local_irq_restore

The following module demonstrates `local_irq_save()` and prints the saved flags value, which on AArch64 is the DAIF register content:

```c
/* day34/11 — demonstrates local_irq_save / local_irq_restore */
#include <linux/module.h>
#include <linux/init.h>
#include <linux/delay.h>
#include <linux/irqflags.h>

static int __init my_init(void)
{
    unsigned long flags;
    pr_info("module is loaded on processor:%d\n", smp_processor_id());
    local_irq_save(flags);
    pr_info("flags:%02lx\n", flags);   /* prints saved DAIF value */
    mdelay(1000L);
    local_irq_restore(flags);          /* restores exactly what was saved */
    return 0;
}

static void __exit my_exit(void) {}

MODULE_LICENSE("GPL");
module_init(my_init);
module_exit(my_exit);
```

The `flags` value printed by `pr_info("flags:%02lx\n", flags)` is the AArch64 DAIF register value captured before the disable. On a standard kernel with interrupts enabled at the time of `insmod`, the I-bit (bit 7 = 0x80) and F-bit (bit 6 = 0x40) are both clear — so you would see `flags:0`. On a PMR-based system the value is `ICC_PMR_EL1 = 0xe0` (all interrupts allowed). The key point is that `local_irq_restore(flags)` writes this exact value back — so if interrupts were enabled before the save (flags has bits clear), they are re-enabled; if disabled (bits set), they remain disabled.

---

## Per-Line Interrupt Control: disable_irq and enable_irq

While `local_irq_disable()` masks interrupts on the current CPU, **`disable_irq()`** and **`enable_irq()`** control a **specific interrupt line** — preventing it from being delivered to any CPU. These operate on the IRQ descriptor, not on the CPU's PSTATE.

### disable_irq() vs. disable_irq_nosync()

Both functions disable a specific IRQ line, but they differ in whether they wait for a currently-running handler to complete.

**`disable_irq_nosync()`** at [kernel/irq/manage.c, lines 691–705](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/irq/manage.c#L691-L705) disables the IRQ and returns immediately, even if the handler is currently executing on another CPU:

```c
void disable_irq_nosync(unsigned int irq)
{
    __disable_irq_nosync(irq);
}
```

**`disable_irq()`** at [kernel/irq/manage.c, lines 708–727](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/irq/manage.c#L708-L727) disables the IRQ **and waits** for any in-flight handler (hardirq or threaded) to finish:

```c
void disable_irq(unsigned int irq)
{
    might_sleep();
    if (!__disable_irq_nosync(irq))
        synchronize_irq(irq);
}
```

The `might_sleep()` call tells the kernel that this function may sleep — it is a warning if called from atomic context. The subsequent `synchronize_irq()` does the waiting.

The difference matters for correctness: after `disable_irq()` returns, the handler is guaranteed to not be running on any CPU. After `disable_irq_nosync()`, the handler might still be running. The nosync variant can be called from interrupt context (it does not sleep), but the caller must handle the race themselves.

### synchronize_irq() — Waiting for In-Flight Handlers

**`synchronize_irq()`** at [kernel/irq/manage.c, lines 145–152](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/irq/manage.c#L145-L152) guarantees that after it returns, no instance of the IRQ's handler is executing on any CPU. It does this via three-level waiting:

1. **Spin** on the `IRQD_IRQ_INPROGRESS` flag (set when a hardirq handler is running) — via `__synchronize_hardirq()` at [lines 50–82](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/irq/manage.c#L50-L82).
2. **Check** the chip-level `IRQCHIP_STATE_ACTIVE` flag (interrupt still pending in hardware).
3. **Sleep** on `desc->wait_for_threads` until `desc->threads_active` reaches zero — waiting for all threaded handlers to finish.

`synchronize_irq()` **may sleep** — it must not be called from interrupt context. It is used in two situations:

- **Inside `disable_irq()`**: after masking the line at the GIC, `disable_irq()` calls `synchronize_irq()` to wait for any currently-executing handler to finish. After `disable_irq()` returns, the caller knows the handler is not running and will not start again.
- **During driver teardown**: a driver may call `disable_irq_nosync()` (which does not wait) and then `synchronize_irq()` separately — useful when the teardown code itself cannot sleep at the point of the nosync call but can sleep later.

```c
/* Pattern: disable then wait (equivalent to disable_irq()) */
disable_irq_nosync(irq);
/* ... do some teardown that does not need to wait ... */
synchronize_irq(irq);           /* now guaranteed: handler is not running */
/* ... safe to remove shared data structures ... */
```

### Module Example: disable_irq and enable_irq

The following module disables IRQ 19 (overridable via module parameter), holds the disable for 10 seconds, then re-enables it. During the 10-second window, no handler registered on that line will be called on any CPU:

```c
/* day34/12 — demonstrates disable_irq / enable_irq */
#include <linux/module.h>
#include <linux/init.h>
#include <linux/delay.h>
#include <linux/interrupt.h>

unsigned int irq = 19;
module_param(irq, int, 0);

static int __init my_init(void)
{
    pr_info("module is loaded on processor:%d\n", smp_processor_id());
    pr_info("Disabling Interrupt:%u\n", irq);
    disable_irq(irq);              /* masks at GIC + waits for in-flight handler */
    pr_info("Disabled Interrupt:%u\n", irq);
    mdelay(10000L);                /* 10 seconds — IRQ line is silent */
    pr_info("Enabling Interrupt:%u\n", irq);
    enable_irq(irq);               /* unmasks at GIC, depth 1 → 0 */
    pr_info("Enabled Interrupt:%u\n", irq);
    return 0;
}

static void __exit my_exit(void) {}

MODULE_LICENSE("GPL");
module_init(my_init);
module_exit(my_exit);
```

Note: `disable_irq()` may sleep (it calls `synchronize_irq()` internally). It is safe here because `module_init` runs in process context. If this were called from an interrupt handler, it would deadlock.

### Module Example: disable_irq_nosync

The nosync variant returns immediately without waiting for the in-flight handler. The delay here is only 10 ms — short enough that the handler is almost certainly done, but the caller takes responsibility for any remaining race:

```c
/* day34/13 — demonstrates disable_irq_nosync */
unsigned int irq = 1;
module_param(irq, int, 0);

static int __init my_init(void)
{
    pr_info("Disabling Interrupt:%u\n", irq);
    disable_irq_nosync(irq);       /* masks at GIC, returns immediately */
    pr_info("Disabled Interrupt:%u\n", irq);
    mdelay(10);                    /* caller's responsibility to wait if needed */
    pr_info("Enabling Interrupt:%u\n", irq);
    enable_irq(irq);
    pr_info("Enabled Interrupt:%u\n", irq);
    return 0;
}
```

The practical difference: use `disable_irq()` when you need to guarantee the handler is not running before proceeding. Use `disable_irq_nosync()` when you cannot sleep (e.g., from a spinlock-protected region) and will call `synchronize_irq()` separately later.

### The Depth Counter State Machine

```
                     disable_irq()                disable_irq()
                 ┌──────────────────┐         ┌──────────────────┐
                 │                  │         │                  │
                 │   HW MASKED     │         │   no HW change   │
                 │   irq_disable() │         │   depth++ only   │
                 ▼                  │         ▼                  │
 ┌──────────┐       ┌──────────┐       ┌──────────┐       ┌──────────┐
 │ depth=0  │──────>│ depth=1  │──────>│ depth=2  │──────>│ depth=N  │
 │ ENABLED  │       │ DISABLED │       │ DISABLED │       │ DISABLED │
 └──────────┘       └──────────┘       └──────────┘       └──────────┘
      ▲                  │  ▲               │                  │
      │                  │  │               │                  │
      │  HW UNMASKED     │  │ no HW change  │                  │
      │  irq_startup()   │  │ depth-- only  │                  │
      │                  │  │               │                  │
      └──────────────────┘  └───────────────┘                  │
           enable_irq()          enable_irq()                  │
                                                               │
        ┌───────────────────────────────────────────────────────┘
        │          enable_irq() (repeated)
        ▼
  Eventually depth reaches 1, then 0 → HW re-enabled

  Calling enable_irq() when depth==0:
  ┌──────────┐
  │ depth=0  │ ←── WARN("Unbalanced enable for IRQ %d")
  │ ENABLED  │     No state change
  └──────────┘
```

### The Core: __disable_irq() and the Depth Counter

Both `disable_irq()` and `disable_irq_nosync()` call **`__disable_irq()`** at [kernel/irq/manage.c, lines 675–679](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/irq/manage.c#L675-L679):

```c
void __disable_irq(struct irq_desc *desc)
{
    if (!desc->depth++)
        irq_disable(desc);
}
```

The **`depth`** field in `struct irq_desc` ([include/linux/irqdesc.h, line 89](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/irqdesc.h#L89)) is a nesting counter. The post-increment `!desc->depth++` evaluates to true only when `depth` was zero — the first disable. Only on the first call does `irq_disable()` actually tell the hardware to mask the line. Subsequent calls simply increment the counter.

**`enable_irq()`** uses **`__enable_irq()`** at [kernel/irq/manage.c, lines 769–799](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/irq/manage.c#L769-L799), which has a three-way switch:

```c
void __enable_irq(struct irq_desc *desc)
{
    switch (desc->depth) {
    case 0:
        WARN(1, KERN_WARNING "Unbalanced enable for IRQ %d\n",
             irq_desc_get_irq(desc));
        break;
    case 1:
        irq_startup(desc, IRQ_RESEND, IRQ_START_FORCE);
        break;
    default:
        desc->depth--;
    }
}
```

- **`depth == 0`**: The IRQ is already enabled. Calling `enable_irq()` again is a bug — the kernel prints a `WARN` with "Unbalanced enable."
- **`depth == 1`**: This is the final enable matching the first disable. The hardware is actually re-enabled via `irq_startup()`.
- **`depth > 1`**: Only the counter decrements. The hardware remains disabled.

### Hardware-Level Disable: Lazy Masking

When `irq_disable()` is called, the kernel calls **`__irq_disable()`** at [kernel/irq/chip.c, lines 361–399](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/irq/chip.c#L361-L399):

```c
static void __irq_disable(struct irq_desc *desc, bool mask)
{
    if (irqd_irq_disabled(&desc->irq_data)) {
        if (mask)
            mask_irq(desc);
    } else {
        irq_state_set_disabled(desc);
        if (desc->irq_data.chip->irq_disable) {
            desc->irq_data.chip->irq_disable(&desc->irq_data);
            irq_state_set_masked(desc);
        } else if (mask) {
            mask_irq(desc);
        }
    }
}
```

If the irq_chip provides an `irq_disable` callback, it is called to disable the line at the hardware level. Otherwise, the kernel uses **lazy disabling** — it marks the IRQ as disabled in software but leaves the hardware unmasked. If an interrupt arrives while lazily disabled, the flow handler detects the disabled state, masks the hardware at that point, and discards the interrupt. This optimization avoids unnecessary hardware accesses when no interrupt occurs during the disabled period.

---

## What Happens If disable_irq Is Called Twice and enable_irq Only Once

This is entirely determined by the `depth` counter in `irq_desc`:

```
State                    depth    Hardware
─────────────────────    ─────    ─────────────────────
Initial                  0        Enabled
After disable_irq()      1        Disabled (irq_disable called)
After disable_irq()      2        Still disabled (no HW change)
After enable_irq()       1        Still disabled (default: case, depth--)
```

The IRQ **remains disabled**. The depth counter went 0 → 1 → 2 → 1. Hardware disable happened at the 0 → 1 transition, and hardware re-enable only happens at the 1 → 0 transition (the `case 1:` branch in `__enable_irq()`). Since depth is still 1 after the single enable, the interrupt stays masked.

A second `enable_irq()` call is required to bring depth to zero and actually re-enable the hardware:

```
After enable_irq()       0        Enabled (irq_startup called)
```

This design is intentional — it allows multiple subsystems or code paths to independently disable the same IRQ without coordinating with each other. Each disable/enable pair is balanced, and the hardware state only changes at the outermost boundaries. However, it also means that an unbalanced enable (calling `enable_irq()` without a matching `disable_irq()`) triggers a `WARN` when depth is already zero.

---

## What Happens When You Disable a Shared Interrupt Line

**`disable_irq()` operates on the IRQ line, not on individual handlers.** When you call `disable_irq(irq)` on a shared line:

1. The `depth` counter in `irq_desc` increments.
2. The interrupt line is masked at the GIC level — `gic_mask_irq()` clears the enable bit in `GICD_ICENABLER`.
3. **All** handlers registered on that line stop being called — not just the caller's handler.

This is a well-known constraint. If driver A and driver B share IRQ 42, and driver A calls `disable_irq(42)`, driver B's handler will also stop being invoked. Driver B's device will continue to assert the interrupt line, but the GIC will not deliver it to any CPU. The interrupt is not lost — it remains pending — but it will not be serviced until `enable_irq(42)` brings the depth counter back to zero.

This is why drivers on shared lines should use `disable_irq()` carefully and for the shortest possible duration. If a driver needs to suppress only its own interrupts, it should use device-level masking (e.g., writing to the device's own interrupt-enable register) rather than `disable_irq()`.

---

## Is There an API to Disable All Interrupts on All CPUs

**No.** There is no kernel API to atomically disable all interrupts across all CPUs simultaneously. The two categories of interrupt control are:

- **`local_irq_disable()`** — affects only the current CPU's `PSTATE.I` or `ICC_PMR_EL1`. There is no mechanism to modify another CPU's PSTATE from software.
- **`disable_irq(N)`** — affects a specific IRQ line across all CPUs, but only that one line.

The fundamental reason is architectural: on AArch64, interrupt masking is per-CPU via PSTATE or the GIC CPU Interface's PMR. There is no hardware register that globally disables all interrupts on all PEs. To achieve such a thing, you would need to IPI every CPU and have each one disable its own interrupts — but the IPI itself is an interrupt, creating an inherent race condition and potential deadlock.

The closest mechanisms are:

- **`stop_machine()`** — stops all CPUs (via IPIs) and runs a function with interrupts disabled and preemption off on every CPU. This is a heavy synchronization tool used for things like module loading and live patching, not a general-purpose interrupt disable.
- **Early boot / panic** — during early boot (before secondary CPUs are online) or after a panic (all CPUs except one are stopped), only one CPU is running, which is effectively the same as global interrupt disable.
- **Individual `disable_irq()` calls** — a driver could iterate over every IRQ and disable each one, but this is impractical, racy, and would break the system.

The old Linux 2.4 kernel had `cli()`/`sti()` that disabled interrupts globally on uniprocessor systems. On SMP, they used a global spinlock — `cli()` acquired it and disabled local interrupts, and `sti()` released it. This was removed in Linux 2.6 because the global lock was a catastrophic scalability bottleneck. The modern kernel requires fine-grained locking and per-CPU interrupt control.

---

## Process Context vs. Interrupt Context

The Linux kernel distinguishes between two fundamentally different execution environments: **process context** and **interrupt context**. The distinction determines what operations the code is allowed to perform.

### Process Context

Code runs in **process context** when it executes on behalf of a specific process — during a system call, inside a kernel thread, or in a workqueue handler. In process context:

- **`current` points to the calling process's `task_struct`** — this is meaningful. You can access `current->pid`, `current->mm`, `current->files`.
- **The code can sleep** — it can call `schedule()`, wait on mutexes, perform allocations with `GFP_KERNEL`, or block on I/O.
- **The code can be preempted** (if `CONFIG_PREEMPTION` is enabled).
- The process entered the kernel voluntarily (via a system call) or quasi-voluntarily (via a page fault that will be resolved).

### Interrupt Context

Code runs in **interrupt context** when the CPU was interrupted by a hardware event. The interrupt handler runs on behalf of no particular process — it borrowed the CPU from whatever task happened to be running. In interrupt context:

- **`current` still points to a `task_struct`** — but it is the interrupted process, not the handler's owner. You should not act on its behalf.
- **The code cannot sleep** — calling `schedule()`, `mutex_lock()`, `kmalloc(GFP_KERNEL)`, or any function that might block is **forbidden**.
- **The code cannot be preempted** — preemption is implicitly disabled.
- **The handler runs to completion** — there is no mechanism to pause and resume an interrupt handler.

The kernel further subdivides interrupt context into **hardirq context** (executing a hardware interrupt handler, between `irq_enter()` and `irq_exit()`) and **softirq context** (executing a softirq, tasklet, or bottom-half handler after the hardirq completes). The rules are similar for both, though softirq context is slightly less constrained (it runs with interrupts enabled on the local CPU).

```
                    Execution Contexts in the Linux Kernel
                    ═══════════════════════════════════════

  ┌─────────────────────────────────────────────────────────────────┐
  │                      Process Context                            │
  │  ┌──────────────┐  ┌──────────────┐  ┌────────────────────┐    │
  │  │  System Call  │  │ Kernel Thread│  │ Workqueue Handler  │    │
  │  │ (read, write, │  │ (kworker,    │  │ (deferred work     │    │
  │  │  ioctl, ...)  │  │  kswapd, ...) │  │  from interrupts)  │    │
  │  └──────────────┘  └──────────────┘  └────────────────────┘    │
  │  ✓ Can sleep    ✓ Has meaningful current    ✓ Can use mutexes  │
  └─────────────────────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────────────────────┐
  │                     Interrupt Context                           │
  │  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────┐  │
  │  │  Hardirq Handler  │  │  Softirq Handler  │  │   Tasklet    │  │
  │  │  (device ISR,     │  │  (NET_RX, TIMER,  │  │   Handler    │  │
  │  │   timer tick)     │  │   BLOCK, ...)     │  │              │  │
  │  └──────────────────┘  └──────────────────┘  └──────────────┘  │
  │  ✗ Cannot sleep   ✗ current is borrowed   ✗ No mutexes        │
  └─────────────────────────────────────────────────────────────────┘
```

---

## Hardirq Context vs. Softirq Context

The previous section introduced "interrupt context" as a single concept opposed to "process context." But within interrupt context, there is a critical subdivision: **hardirq context** and **softirq context**. They share the prohibition against sleeping, but they differ in interrupt masking, preemptibility, and what can preempt what. Understanding this distinction is essential for choosing the right locking primitive and memory allocation flag.

### Hardirq Context

**Hardirq context** is the execution environment of a hardware interrupt handler — the code that runs between `irq_enter()` and `irq_exit()`. It has the most restrictive rules in the kernel:

- **Interrupts are disabled on the local CPU.** On AArch64, the entry path sets `PSTATE.I` and `PSTATE.F` via `write_sysreg(DAIF_PROCCTX_NOIRQ, daif)` at [arch/arm64/kernel/entry-common.c, line 517](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry-common.c#L517), where `DAIF_PROCCTX_NOIRQ = PSR_I_BIT | PSR_F_BIT`. The kernel even verifies this after each handler returns — `__handle_irq_event_percpu()` at [kernel/irq/handle.c, lines 214–216](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/irq/handle.c#L214-L216) warns if a handler re-enabled interrupts:

```c
if (WARN_ONCE(!irqs_disabled(),
              "irq %u handler %pS enabled interrupts\n",
              irq, action->handler))
    local_irq_disable();
```

- **`preempt_count`** has `HARDIRQ_OFFSET` set in bits [19:16]. This makes `in_hardirq()` return true, `in_interrupt()` return true, `in_task()` return false, and `in_atomic()` return true.
- **Nothing can preempt a hardirq handler** on its local CPU. Other CPUs can run their own hardirq handlers concurrently, but on this CPU, the handler runs to completion.
- **Cannot sleep, cannot acquire mutexes, cannot allocate with `GFP_KERNEL`.**
- Duration should be minimized — every microsecond spent in hardirq context delays all other interrupts on that CPU.

### Softirq Context

**Softirq context** is the execution environment of softirq handlers, tasklets, and networking bottom-halves. Softirqs are deferred work that runs immediately after hardirq handlers complete — the transition happens in `irq_exit()` when it calls `invoke_softirq()`. The actual execution is in **`handle_softirqs()`** at [kernel/softirq.c, lines 579–652](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/softirq.c#L579-L652):

```c
static void handle_softirqs(bool ksirqd)
{
    softirq_handle_begin();         /* preempt_count += SOFTIRQ_OFFSET */

    set_softirq_pending(0);
    local_irq_enable();             /* ← interrupts RE-ENABLED */

    while ((softirq_bit = ffs(pending))) {
        h->action();                /* run softirq handler with IRQs enabled */
        pending >>= softirq_bit;
    }

    local_irq_disable();            /* ← interrupts disabled again */
    softirq_handle_end();           /* preempt_count -= SOFTIRQ_OFFSET */
}
```

The key differences from hardirq context:

- **Interrupts are enabled.** `handle_softirqs()` explicitly calls `local_irq_enable()` before running handlers (line 606) and `local_irq_disable()` after they complete (line 637). This means **a hardirq can preempt a softirq handler** — a device interrupt can arrive while a softirq handler is running, and the CPU will take the hardirq exception, handle it, and then return to the softirq.

- **`preempt_count`** has `SOFTIRQ_OFFSET` (0x100) set in bits [15:8]. This makes `in_serving_softirq()` return true and `in_task()` return false. `in_atomic()` is true, so sleeping is still forbidden.

- **Cannot sleep.** Although interrupts are enabled, `preempt_count` is nonzero, so `schedule()` will trigger "scheduling while atomic." Mutexes and `GFP_KERNEL` allocations are prohibited — use `GFP_ATOMIC` instead.

- **Softirqs of the same type cannot nest** on the same CPU. The kernel disables bottom-halves (via `softirq_handle_begin()`) before running handlers. But a different softirq can be raised during execution and will be processed in the next iteration of the loop.

### When Softirqs Run

Softirqs are processed in three places:

1. **At `irq_exit()`** — immediately after a hardirq handler completes. `__irq_exit_rcu()` at [kernel/softirq.c, lines 720–743](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/softirq.c#L720-L743) checks `local_softirq_pending()` and calls `invoke_softirq()` if pending softirqs exist and we are not in nested interrupt context.

2. **At `local_bh_enable()`** — when code that called `local_bh_disable()` re-enables bottom-halves, pending softirqs are processed at [kernel/softirq.c, lines 427–458](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/softirq.c#L427-L458).

3. **In `ksoftirqd`** — a per-CPU kernel thread at [kernel/softirq.c, lines 1063–1082](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/softirq.c#L1063-L1082). If softirqs keep being raised faster than they can be processed (more than 10 restarts or more than 2ms), `handle_softirqs()` stops processing inline and wakes `ksoftirqd` to handle the remaining work in process context. When force-threading is enabled (`threadirqs`), softirqs always go through `ksoftirqd` rather than being processed inline.

### The local_bh_disable Subtlety

**`local_bh_disable()`** adds `SOFTIRQ_DISABLE_OFFSET` (which is `2 × SOFTIRQ_OFFSET` = `0x200`) to `preempt_count`, while `softirq_handle_begin()` (entering an actual softirq handler) adds only `SOFTIRQ_OFFSET` (`0x100`). This distinction is what makes `in_serving_softirq()` work correctly:

- Code inside a real softirq handler: `preempt_count` has bit 8 set (0x100) → `in_serving_softirq()` returns true.
- Code that merely called `local_bh_disable()`: `preempt_count` has bit 9 set (0x200), bit 8 clear → `in_serving_softirq()` returns false.
- Both cases: `in_softirq()` (deprecated) returns true because it checks the entire `SOFTIRQ_MASK`, which covers both bits. This is why `in_softirq()` is deprecated — it conflates "actually serving a softirq" with "bottom-halves are just disabled."

### Comparison Table

| Property | Hardirq Context | Softirq Context | Process Context |
|----------|----------------|-----------------|-----------------|
| **Interrupts on local CPU** | Disabled | Enabled | Enabled |
| **Can be preempted by hardirq** | No | Yes | Yes |
| **Can be preempted by softirq** | No | No (same CPU) | Yes (unless BH disabled) |
| **Can sleep / call schedule()** | No | No | Yes |
| **Can acquire mutex** | No | No | Yes |
| **`kmalloc()` flag** | `GFP_ATOMIC` only | `GFP_ATOMIC` only | `GFP_KERNEL` allowed |
| **`spin_lock()` safe** | Yes | Yes | Yes |
| **`spin_lock_irqsave()` safe** | Yes | Yes (recommended if data shared with hardirq) | Yes |
| **`spin_lock_bh()` safe** | No (WARN) | Callable but pointless | Yes (intended use) |
| **`current` is meaningful** | No (borrowed) | No (borrowed) | Yes |
| **`in_task()` returns** | false | false | true |
| **`preempt_count` bits set** | HARDIRQ field | SOFTIRQ field | None (or PREEMPT if preempt_disable) |

### Choosing the Right Locking Primitive

```
 Which lock do I need?
 ═════════════════════

 Is the data shared with a HARDIRQ handler?
          │
     ┌────┴────┐
    Yes         No
     │          │
     ▼          ▼
 spin_lock_    Is the data shared with a SOFTIRQ handler?
 irqsave()          │
 (disables      ┌───┴───┐
  IRQs +       Yes       No
  acquires      │        │
  lock)         ▼        ▼
            spin_lock_   Is the data shared across CPUs?
            bh()              │
            (disables     ┌───┴───┐
             bottom-     Yes       No
             halves)      │        │
                          ▼        ▼
                      spin_lock()  No lock needed
                      (SMP only)   (per-CPU, single context)


 Quick Reference — Lock Selection by Sharing Pattern:
 ┌──────────────────────────────┬────────────────────────────────────────┐
 │ Data shared between          │ Lock to use                            │
 ├──────────────────────────────┼────────────────────────────────────────┤
 │ Process ↔ Hardirq            │ spin_lock_irqsave / _irqrestore       │
 │ Process ↔ Softirq            │ spin_lock_bh / spin_unlock_bh         │
 │ Hardirq ↔ Softirq            │ spin_lock in hardirq (IRQs off)       │
 │                              │ spin_lock_irqsave in softirq          │
 │ Softirq ↔ Softirq (same)    │ No lock (runs serialized per-CPU)     │
 │ Softirq ↔ Softirq (diff)    │ spin_lock (different CPUs only)        │
 │ Process ↔ Process            │ mutex (can sleep) or spin_lock         │
 └──────────────────────────────┴────────────────────────────────────────┘
```

The locking choice follows directly from the context table:

- **Data shared between process context and hardirq** → `spin_lock_irqsave()` / `spin_unlock_irqrestore()`. This disables interrupts and acquires the lock, protecting against both interrupt handler and cross-CPU races.

- **Data shared between process context and softirq** → `spin_lock_bh()` / `spin_unlock_bh()`. This disables bottom-halves and acquires the lock, protecting against softirq preemption without unnecessarily disabling hardware interrupts.

- **Data shared between hardirq and softirq** → `spin_lock()` / `spin_unlock()` in the hardirq handler (interrupts are already disabled), and `spin_lock_irqsave()` / `spin_unlock_irqrestore()` in the softirq handler (need to disable interrupts to prevent hardirq preemption).

- **Data accessed only from softirq context (same type)** → No lock needed if the softirq only runs on one CPU at a time. But different softirq types can run concurrently on different CPUs, so data shared between softirq types needs `spin_lock()`.

---

## The preempt_count Bitfield

The kernel tracks the current execution context using a 32-bit per-CPU variable called **`preempt_count`**. On AArch64, it lives in `thread_info->preempt.count`, accessed via `current_thread_info()`. The AArch64-specific accessor is in [arch/arm64/include/asm/preempt.h, lines 10–13](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/preempt.h#L10-L13):

```c
static inline int preempt_count(void)
{
    return READ_ONCE(current_thread_info()->preempt.count);
}
```

The 32 bits are divided into fields, defined in [include/linux/preempt.h, lines 14–53](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/preempt.h#L14-L53):

```
 Bit 31         23:20        19:16        15:8           7:0
┌──────────┬──────────┬──────────────┬──────────────┬──────────────┐
│NEED_RSCD │   NMI    │   HARDIRQ    │   SOFTIRQ    │   PREEMPT    │
│ (1 bit)  │ (4 bits) │  (4 bits)    │  (8 bits)    │  (8 bits)    │
└──────────┴──────────┴──────────────┴──────────────┴──────────────┘
```

| Field | Mask | Bits | Offset | Purpose |
|-------|------|------|--------|---------|
| **PREEMPT** | `0x000000ff` | [7:0] | `PREEMPT_OFFSET = 1` | Preemption disable count. Incremented by `preempt_disable()`, decremented by `preempt_enable()`. |
| **SOFTIRQ** | `0x0000ff00` | [15:8] | `SOFTIRQ_OFFSET = 1 << 8` | Softirq context counter. Incremented by `local_bh_disable()` and when entering softirq handlers. |
| **HARDIRQ** | `0x000f0000` | [19:16] | `HARDIRQ_OFFSET = 1 << 16` | Hardware interrupt nesting depth. Incremented by `__irq_enter()`, decremented by `__irq_exit()`. |
| **NMI** | `0x00f00000` | [23:20] | `NMI_OFFSET = 1 << 20` | NMI nesting depth. |
| **NEED_RESCHED** | `0x80000000` | [31] | — | Set by the scheduler when a reschedule is needed. |

### preempt_count in Different Contexts

```
 Context            preempt_count value        Which bits are set
 ════════════════   ═══════════════════════    ════════════════════════════
 Process context    0x00000000                 (none — in_task()=true)
 (normal)

 preempt_disable()  0x00000001                 PREEMPT [7:0] = 1
                    ───────────────────────
                    preempt_disable() ×2:
                    0x00000002                 PREEMPT [7:0] = 2

 local_bh_disable() 0x00000200                 SOFTIRQ [15:8]:
                    ───────────────────────     bit 9 set (SOFTIRQ_DISABLE_OFFSET)
                    in_softirq()=true           NOT in_serving_softirq()

 Softirq handler    0x00000100                 SOFTIRQ [15:8]:
 (actual)           ───────────────────────     bit 8 set (SOFTIRQ_OFFSET)
                    in_serving_softirq()=true

 Hardirq handler    0x00010000                 HARDIRQ [19:16]:
                    ───────────────────────     bit 16 set (HARDIRQ_OFFSET)
                    in_hardirq()=true

 NMI handler        0x00100000                 NMI [23:20]:
                    ───────────────────────     bit 20 set (NMI_OFFSET)
                    in_nmi()=true

 Hardirq during     0x00010100                 HARDIRQ [19:16] = 1
 softirq            ───────────────────────     SOFTIRQ [15:8] = 1
 (nested)           Both in_hardirq() and
                    in_serving_softirq() true
```

When an interrupt arrives, the entry path calls `irq_enter()` (defined in [kernel/softirq.c, lines 683–687](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/softirq.c#L683-L687)), which calls `__irq_enter_raw()` (defined in [include/linux/hardirq.h, lines 34–39](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/hardirq.h#L34-L39)):

```c
#define __irq_enter_raw()                   \
    do {                                    \
        preempt_count_add(HARDIRQ_OFFSET);  \
        lockdep_hardirq_enter();            \
    } while (0)
```

This adds `HARDIRQ_OFFSET` (0x00010000) to `preempt_count`, setting bits in the HARDIRQ field. Now `in_hardirq()` returns nonzero, `in_interrupt()` returns nonzero, `in_task()` returns false, and `in_atomic()` returns true. The entire character of the execution context changes with a single addition.

On exit, `irq_exit()` calls `__irq_exit_rcu()` at [kernel/softirq.c, lines 720–743](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/softirq.c#L720-L743):

```c
static inline void __irq_exit_rcu(void)
{
    local_irq_disable();
    preempt_count_sub(HARDIRQ_OFFSET);
    if (!in_interrupt() && local_softirq_pending())
        invoke_softirq();
    tick_irq_exit();
}
```

After subtracting `HARDIRQ_OFFSET`, if we are no longer in any interrupt context and there are pending softirqs, `invoke_softirq()` runs them. This is how softirqs are processed immediately after hardirq handlers complete.

---

## Checking Your Execution Context

The kernel provides a set of macros in [include/linux/preempt.h, lines 108–141](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/preempt.h#L108-L141) for testing which context the current code is running in:

| Macro | What It Tests | True When |
|-------|---------------|-----------|
| **`in_hardirq()`** | `preempt_count() & HARDIRQ_MASK` | Executing a hardware interrupt handler (between `irq_enter()` and `irq_exit()`). |
| **`in_serving_softirq()`** | `softirq_count() & SOFTIRQ_OFFSET` | Actively executing a softirq handler. |
| **`in_nmi()`** | `preempt_count() & NMI_MASK` | Executing in NMI context. |
| **`in_task()`** | `!(preempt_count() & (NMI_MASK \| HARDIRQ_MASK \| SOFTIRQ_OFFSET))` | In normal process context — not in any interrupt or softirq handler. **This is the recommended way to check "can I sleep?"** |
| **`in_interrupt()`** *(deprecated)* | `preempt_count() & (NMI_MASK \| HARDIRQ_MASK \| SOFTIRQ_MASK)` | In any interrupt context — hardirq, softirq, NMI, or code that has merely called `local_bh_disable()`. Deprecated because the name implies "in an interrupt handler" but it also catches BH-disabled sections. |
| **`in_softirq()`** *(deprecated)* | `preempt_count() & SOFTIRQ_MASK` | In softirq context **or** bottom-halves disabled. Deprecated because it conflates two different states. Use `in_serving_softirq()` to test only for active softirq execution. |
| **`in_atomic()`** | `preempt_count() != 0` | Preemption is disabled for any reason — hardirq, softirq, `preempt_disable()`, or spinlock held. |

A more structured approach is **`interrupt_context_level()`** at [include/linux/preempt.h, lines 90–100](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/preempt.h#L90-L100):

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

This returns a numeric level: **0** = process context, **1** = softirq, **2** = hardirq, **3** = NMI. Higher levels can preempt lower levels but not vice versa.

### Context Detection Decision Tree

```
 How to determine your execution context:
 ═════════════════════════════════════════

                 ┌──────────────┐
                 │ in_nmi()?    │
                 └───┬──────┬───┘
                    Yes      No
                     │       │
                     ▼       ▼
              Level 3    ┌──────────────┐
              NMI ctx    │ in_hardirq()?│
                         └───┬──────┬───┘
                            Yes      No
                             │       │
                             ▼       ▼
                      Level 2    ┌─────────────────────┐
                      Hardirq    │in_serving_softirq()?│
                                 └───┬──────┬──────────┘
                                    Yes      No
                                     │       │
                                     ▼       ▼
                              Level 1    ┌──────────────┐
                              Softirq    │  in_task()   │
                                         └──────┬───────┘
                                                │
                                                ▼
                                         Level 0
                                         Process ctx
                                         CAN SLEEP ✓

 Recommended check for "can I sleep?":

   if (in_task()) {
       /* Safe to sleep, use GFP_KERNEL, acquire mutexes */
   } else {
       /* Cannot sleep — use GFP_ATOMIC, spin_lock only */
   }
```

### Module Example: Detecting Execution Context at Runtime

The following module uses `in_interrupt()` to print which context the code is running in. It is called from both process context (init/exit) and interrupt context (handler):

```c
/* day34/18 — detecting process vs interrupt context */
#include <linux/module.h>
#include <linux/init.h>
#include <linux/interrupt.h>

#define SHARED_IRQ 12
static int irq = SHARED_IRQ, my_dev_id;

void print_context(void)
{
    if (in_interrupt())
        pr_info("Code is running in interrupt context\n");
    else
        pr_info("Code is running in process context\n");
}

static irqreturn_t my_interrupt(int irq, void *dev_id)
{
    print_context();   /* prints: interrupt context */
    return IRQ_NONE;
}

static int __init my_init(void)
{
    print_context();   /* prints: process context */
    request_irq(irq, my_interrupt, IRQF_SHARED, "my_interrupt", &my_dev_id);
    return 0;
}

static void __exit my_exit(void)
{
    print_context();   /* prints: process context */
    synchronize_irq(irq);
    free_irq(irq, &my_dev_id);
}

MODULE_LICENSE("GPL");
module_init(my_init);
module_exit(my_exit);
```

**Note**: `in_interrupt()` is deprecated. It returns true in hardirq context, softirq context, *and* when bottom-halves are merely disabled via `local_bh_disable()` — conflating three different states. Prefer `in_hardirq()` + `in_serving_softirq()` or, for the most common check ("can I sleep?"), use `!in_task()`.

### Module Example: Context-Aware Memory Allocation

This pattern is common in drivers that can be called from both process and interrupt context — use `in_interrupt()` to select the correct GFP flag:

```c
/* day34/19 — GFP_ATOMIC vs GFP_KERNEL based on context */
#include <linux/module.h>
#include <linux/interrupt.h>
#include <linux/slab.h>

void *alloc_mem(unsigned int size)
{
    if (in_interrupt())
        return kmalloc(size, GFP_ATOMIC);   /* cannot sleep */
    else
        return kmalloc(size, GFP_KERNEL);   /* can sleep, may reclaim */
}

static irqreturn_t my_interrupt(int irq, void *dev_id)
{
    void *mem = alloc_mem(1024);   /* GFP_ATOMIC path taken */
    kfree(mem);
    return IRQ_NONE;
}

static int __init my_init(void)
{
    void *mem = alloc_mem(1024);   /* GFP_KERNEL path taken */
    kfree(mem);
    /* ... register handler ... */
    return 0;
}
```

`GFP_ATOMIC` never sleeps — if memory is not immediately available it returns `NULL` rather than waiting for reclaim. Always check the return value when using `GFP_ATOMIC`:

```c
void *mem = kmalloc(size, GFP_ATOMIC);
if (!mem) {
    /* handle allocation failure — cannot retry with schedule() */
    return IRQ_NONE;
}
```

The same `!in_task()` idiom is the preferred replacement for `in_interrupt()` in new code.

---

## The Value of current Inside an Interrupt Handler

On AArch64, the **`current`** macro reads the `task_struct` pointer from the **SP_EL0** system register, defined in [arch/arm64/include/asm/current.h, lines 15–24](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/current.h#L15-L24):

```c
static __always_inline struct task_struct *get_current(void)
{
    unsigned long sp_el0;
    asm ("mrs %0, sp_el0" : "=r" (sp_el0));
    return (struct task_struct *)sp_el0;
}

#define current get_current()
```

This works because the Linux kernel on AArch64 repurposes `SP_EL0` as a **thread pointer**. The kernel runs at EL1 and uses `SP_EL1` as its actual stack pointer. `SP_EL0` is the user-space stack pointer register, which is not used while executing in EL1. The kernel stores the `task_struct` pointer of the current task in `SP_EL0` at every context switch. Since taking an exception to EL1 does not modify `SP_EL0` (the hardware only saves PSTATE into SPSR_EL1 and the return address into ELR_EL1), `SP_EL0` retains the `task_struct` pointer even after entering the interrupt handler.

**Inside an interrupt handler, `current` points to the `task_struct` of whatever process was running when the interrupt arrived.** It is not a special "interrupt task" — it is the interrupted task itself. This means:

- **`current->pid`** is the PID of the interrupted process.
- **`current->comm`** is the name of the interrupted process.
- The kernel uses this legitimately — for example, `account_hardirq_enter(current)` updates CPU accounting for the interrupted task during interrupt entry.

However, the interrupt handler should not perform operations that depend on process identity or modify process state. The interrupted task did not voluntarily enter the kernel — it was preempted by hardware — and acting on its behalf (modifying its address space, changing its signal masks, etc.) would be incorrect.

```
 User Task "myapp" running at EL0
 ┌──────────────────────────────────┐
 │  SP_EL0 = &task_struct(myapp)    │ ← set by context switch
 │  SP_EL1 = kernel stack of myapp  │
 │  Executing user code...          │
 └──────────────────┬───────────────┘
                    │  ← IRQ fires, CPU takes exception to EL1
                    ▼
 Interrupt Handler at EL1
 ┌──────────────────────────────────┐
 │  SP_EL0 = &task_struct(myapp)    │ ← unchanged by exception entry
 │  SP_EL1 = IRQ stack (switched)   │ ← kernel switched to per-CPU IRQ stack
 │  current->pid = myapp's PID      │
 │  current->comm = "myapp"         │
 │  in_hardirq() = true             │
 └──────────────────────────────────┘
```

### Module Example: Printing current Inside an ISR

The following module prints `current->pid` and `current->comm` from inside a hardware interrupt handler, demonstrating that `current` is the interrupted task:

```c
/* day34/22 — printing current->pid and current->comm from an ISR */
#include <linux/module.h>
#include <linux/init.h>
#include <linux/interrupt.h>
#include <linux/sched.h>
#include <asm/current.h>

#define SHARED_IRQ 12
static int irq = SHARED_IRQ, my_dev_id, irq_counter = 0;
module_param(irq, int, S_IRUGO);

static irqreturn_t my_interrupt(int irq, void *dev_id)
{
    irq_counter++;
    pr_info("In the ISR: counter = %d\n", irq_counter);
    pr_info("current pid:%d  current process:%s\n",
            current->pid, current->comm);
    return IRQ_NONE;
}

static int __init my_init(void)
{
    return request_irq(irq, my_interrupt, IRQF_SHARED, "my_interrupt", &my_dev_id);
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

When this module is loaded and the interrupt fires, the kernel log will show something like:

```
In the ISR: counter = 1
current pid:1842  current process:bash
```

The process shown (`bash` in this example) is whichever task happened to be scheduled on this CPU at the moment the interrupt arrived. It has nothing to do with the interrupt or the driver — it is the **borrowed** identity. The same handler invoked a moment later might show `pid:0 process:swapper/0` (the idle task) or `pid:42 process:kworker/0:1`, depending on what the CPU was doing. This is why an interrupt handler must never act on `current`'s behalf (e.g., send it a signal, modify its memory map, or access its file descriptors).

---

## Why You Cannot Sleep in an Interrupt Handler

Calling `schedule()` — directly or indirectly through `mutex_lock()`, `kmalloc(GFP_KERNEL)`, `wait_event()`, or any other blocking function — from interrupt context triggers a kernel BUG. The detection and the reasons are both worth understanding.

### How the Kernel Detects It

When `schedule()` is called, it invokes **`__schedule()`** at [kernel/sched/core.c, line 7083](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/sched/core.c#L7083), which calls **`schedule_debug()`** at [lines 6070–6099](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/sched/core.c#L6070-L6099):

```c
static inline void schedule_debug(struct task_struct *prev, bool preempt)
{
    if (unlikely(in_atomic_preempt_off())) {
        __schedule_bug(prev);
        preempt_count_set(PREEMPT_DISABLED);
    }
    rcu_sleep_check();
}
```

In hardirq context, `preempt_count` has `HARDIRQ_OFFSET` set in bits [19:16], making `in_atomic_preempt_off()` return true. This triggers **`__schedule_bug()`** at [lines 6042–6065](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/sched/core.c#L6042-L6065):

```c
static noinline void __schedule_bug(struct task_struct *prev)
{
    printk(KERN_ERR "BUG: scheduling while atomic: %s/%d/0x%08x\n",
           prev->comm, prev->pid, preempt_count());
    dump_stack();
    add_taint(TAINT_WARN, LOCKDEP_STILL_OK);
}
```

The message `"BUG: scheduling while atomic"` is one of the most common kernel debugging messages. The "atomic" refers to the nonzero `preempt_count` — the kernel is in a context where scheduling is not allowed.

Additionally, many sleeping functions proactively warn via **`might_sleep()`**, which calls **`__might_resched()`** at [kernel/sched/core.c, lines 9151–9199](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/sched/core.c#L9151-L9199). This checks both `in_atomic()` and `irqs_disabled()` and prints:

```
BUG: sleeping function called from invalid context at <file>:<line>
in_atomic(): 1, irqs_disabled(): 1, ...
```

### Why It Is Forbidden

```
 Why schedule() Is Forbidden in Interrupt Context
 ═════════════════════════════════════════════════

 ┌─────────────────────────────────────────────────────────────────────────┐
 │ REASON 1: preempt_count blocks it                                      │
 │                                                                         │
 │   schedule() → __schedule() → schedule_debug()                          │
 │     if (in_atomic_preempt_off())     ◄── preempt_count has              │
 │       __schedule_bug(prev);               HARDIRQ_OFFSET set            │
 │       "BUG: scheduling while atomic"                                    │
 └─────────────────────────────────────────────────────────────────────────┘

 ┌─────────────────────────────────────────────────────────────────────────┐
 │ REASON 2: Interrupts are disabled (PSTATE.I=1)                         │
 │                                                                         │
 │   Scheduler needs:                                                      │
 │     • Timer ticks for preemption      ✗ blocked by PSTATE.I             │
 │     • IPIs for cross-CPU wakeups      ✗ blocked by PSTATE.I             │
 │     • Eventual wakeup of sleeper      ✗ blocked by PSTATE.I             │
 │                                                                         │
 │   Result: CPU hangs indefinitely                                        │
 └─────────────────────────────────────────────────────────────────────────┘

 ┌─────────────────────────────────────────────────────────────────────────┐
 │ REASON 3: No process identity to sleep                                  │
 │                                                                         │
 │   sleep = "remove THIS task from runqueue, switch to another"           │
 │                                                                         │
 │   But in hardirq context:                                               │
 │     • current points to the INTERRUPTED task (borrowed, not owned)       │
 │     • The handler is NOT a schedulable entity                            │
 │     • If scheduler switched away:                                        │
 │       ┌─────────────────────────────────────────────┐                   │
 │       │ Interrupt never completes                    │                   │
 │       │ Device stays un-serviced                     │                   │
 │       │ Level-triggered: interrupt storm             │                   │
 │       │ Interrupted task's context: corrupted        │                   │
 │       └─────────────────────────────────────────────┘                   │
 └─────────────────────────────────────────────────────────────────────────┘
```

The prohibition is not merely a convention — there are three fundamental reasons:

**1. The preempt_count prevents it.** Hardirq context has `HARDIRQ_OFFSET` set in `preempt_count`. The scheduler checks this and refuses to proceed. Even if you somehow bypassed the check, the scheduler would save the interrupt handler's register state as the interrupted task's state — corrupting that task's context.

**2. Interrupts are disabled.** On AArch64, `PSTATE.I` is set during hardirq handler execution. The scheduler requires interrupts to be enabled to handle timer ticks, IPIs, and the eventual wakeup of the sleeping task. With interrupts masked, the CPU would hang.

**3. There is no process to sleep.** Sleeping means "take this task off the run queue and switch to another task." But the interrupt handler is not a task — it is a transient execution that borrowed the CPU from whatever task was running. If the scheduler switched away, the interrupt would never complete. The device would remain un-serviced, potentially causing an interrupt storm on level-triggered lines. And the "current" task (which was innocently running when the interrupt arrived) would have its context corrupted.

### Module Examples: What Happens When You Try to Sleep

#### Example 1: mdelay — Legal but Harmful

`mdelay()` is a busy-wait loop, not a sleep — it does not call `schedule()`. This is technically legal from interrupt context but catastrophic for system responsiveness:

```c
/* day34/20 — mdelay in ISR: legal busy-wait but CPU is frozen */
static irqreturn_t my_interrupt(int irq, void *dev_id)
{
    mdelay(1000);   /* busy-wait 1 second with IRQs disabled on this CPU */
    return IRQ_NONE;
}
```

Because hardirq context has `PSTATE.I=1` (local IRQs disabled), the CPU cannot service any other interrupt for the entire 1-second delay. On a uniprocessor system this would freeze the keyboard, network, and timer tick for 1 second every time IRQ 12 fires. The kernel does not detect or prevent this — mdelay is not a sleeping function. This illustrates **why interrupt handlers must be as short as possible**. Any slow work must be deferred to a workqueue or threaded handler.

#### Example 2: ssleep — Triggers "scheduling while atomic"

`ssleep()` calls `schedule_timeout()`, which puts the current task to sleep. Calling it from interrupt context triggers the kernel's "scheduling while atomic" BUG:

```c
/* day34/23 — ssleep in ISR: triggers BUG: scheduling while atomic */
static irqreturn_t my_interrupt(int irq, void *dev_id)
{
    ssleep(1);      /* calls schedule() internally — forbidden in hardirq context */
    return IRQ_NONE;
}
```

When this fires, the kernel log shows:

```
BUG: scheduling while atomic: <interrupted-task>/<pid>/0x00010000
Modules linked in: hello(O)
CPU: 0 PID: 1234 Comm: bash Tainted: G        O
Call trace:
 __schedule_bug+0x60/0x80
 __schedule+0x74/0x6e0
 schedule_timeout+0x9c/0x180
 msleep+0x28/0x40
 ssleep+0x14/0x20
 my_interrupt+0x14/0x30 [hello]
 ...
```

The `0x00010000` in the message is `preempt_count` with `HARDIRQ_OFFSET` set — the kernel reports the exact value so you can identify which lock/context caused the atomic region.

#### Example 3: schedule — Same BUG, Directly

Calling `schedule()` directly produces the same result:

```c
/* day34/24 — schedule() in ISR: triggers BUG: scheduling while atomic */
static irqreturn_t my_interrupt(int irq, void *dev_id)
{
    schedule();     /* direct schedule call — immediately triggers __schedule_bug() */
    return IRQ_NONE;
}
```

```
BUG: scheduling while atomic: <process>/<pid>/0x00010000
```

The detection path: `schedule()` → `__schedule()` → `schedule_debug()` → `in_atomic_preempt_off()` returns true (HARDIRQ_OFFSET is set) → `__schedule_bug()` prints the message, adds `TAINT_WARN`, and dumps the stack. On kernels with `CONFIG_DEBUG_ATOMIC_SLEEP`, additional checks fire earlier via `might_sleep()` inside any blocking primitive.

**The correct fix for any work that takes time**: use a workqueue (process context, can sleep) or a threaded interrupt handler via `request_threaded_irq()`.

---

## The Per-CPU IRQ Stack on AArch64

When an interrupt arrives, the kernel could use the interrupted task's kernel stack to run the handler. But task kernel stacks on AArch64 are only **16 KB** (defined by `THREAD_SIZE = 1 << THREAD_SHIFT` where `THREAD_SHIFT` is typically 14, at [arch/arm64/include/asm/memory.h, lines 115–122](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/memory.h#L115-L122)). An interrupt can arrive at any point — including when the task's stack is already deep into a call chain. Running the handler on the same stack risks stack overflow.

The solution is a **per-CPU IRQ stack** — a dedicated stack for interrupt handler execution, allocated at boot time.

### Stack Allocation

The IRQ stacks are allocated in `init_irq_stacks()` at [arch/arm64/kernel/irq.c, lines 60–73](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/irq.c#L60-L73):

```c
DEFINE_PER_CPU(unsigned long *, irq_stack_ptr);

static int __init init_irq_stacks(void)
{
    int cpu;
    unsigned long *p;

    for_each_possible_cpu(cpu) {
        p = arch_alloc_vmap_stack(IRQ_STACK_SIZE, early_cpu_to_node(cpu));
        per_cpu(irq_stack_ptr, cpu) = p;
    }
    return 0;
}
```

Each CPU gets its own `IRQ_STACK_SIZE` (= `THREAD_SIZE` = 16 KB) stack, allocated via `arch_alloc_vmap_stack()` which uses virtually-mapped pages with guard pages for overflow detection.

### Stack Switching

The stack switch happens in **`do_interrupt_handler()`** at [arch/arm64/kernel/entry-common.c, lines 152–163](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry-common.c#L152-L163):

```c
static void do_interrupt_handler(struct pt_regs *regs,
                                 void (*handler)(struct pt_regs *))
{
    struct pt_regs *old_regs = set_irq_regs(regs);

    if (on_thread_stack())
        call_on_irq_stack(regs, handler);
    else
        handler(regs);

    set_irq_regs(old_regs);
}
```

If the current stack is the task's kernel stack (`on_thread_stack()` returns true), it calls `call_on_irq_stack()` to switch to the per-CPU IRQ stack. If already on the IRQ stack (a nested interrupt), it just calls the handler directly — nesting uses the same IRQ stack.

The assembly implementation of **`call_on_irq_stack`** lives at [arch/arm64/kernel/entry.S, lines 872–901](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry.S#L872-L901):

```asm
SYM_FUNC_START(call_on_irq_stack)
    /* Save frame pointer and link register */
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    /* Load this CPU's IRQ stack pointer */
    ldr_this_cpu x16, irq_stack_ptr, x17

    /* Set SP to the TOP of the IRQ stack */
    add     sp, x16, #IRQ_STACK_SIZE

    /* Call the handler */
    blr     x1

    /* Restore the original SP from the frame pointer */
    mov     sp, x29
    ldp     x29, x30, [sp], #16
    ret
SYM_FUNC_END(call_on_irq_stack)
```

The function saves the current frame pointer and link register, loads `irq_stack_ptr` for this CPU, sets SP to the top of the IRQ stack (`base + IRQ_STACK_SIZE` — stacks grow downward), calls the handler, and restores the original SP afterward. The IRQ stack is used only for the duration of the handler call.

### Integration with the Interrupt Path

The stack switch is invoked from both the EL1 (kernel) and EL0 (user) interrupt entry paths:

**From EL1** — `__el1_irq()` at [arch/arm64/kernel/entry-common.c, lines 501–513](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry-common.c#L501-L513):

```c
static __always_inline void __el1_irq(struct pt_regs *regs,
                                      void (*handler)(struct pt_regs *))
{
    irqentry_state_t state = arm64_enter_from_kernel_mode(regs);
    irq_enter_rcu();
    do_interrupt_handler(regs, handler);
    irq_exit_rcu();
    arm64_exit_to_kernel_mode(regs, state);
}
```

**From EL0** — `el0_interrupt()` at [arch/arm64/kernel/entry-common.c, lines 817–832](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry-common.c#L817-L832):

```c
static void noinstr el0_interrupt(struct pt_regs *regs,
                                  void (*handler)(struct pt_regs *))
{
    arm64_enter_from_user_mode(regs);
    irq_enter_rcu();
    do_interrupt_handler(regs, handler);
    irq_exit_rcu();
    arm64_exit_to_user_mode(regs);
}
```

In both cases, the sequence is: enter from the interrupted context → mark hardirq context (`irq_enter_rcu()`) → switch to IRQ stack and run handler (`do_interrupt_handler()`) → leave hardirq context and process softirqs (`irq_exit_rcu()`) → return to the interrupted context.

```
 Interrupt arrives while task's kernel code runs on task stack
 ┌──────────────────────────────────────────────────────────────┐
 │                    Task Kernel Stack (16 KB)                 │
 │                                                              │
 │  ┌─────────────────┐                                         │
 │  │ syscall frames   │ ← already using some stack             │
 │  │ ...              │                                        │
 │  │ deep call chain  │                                        │
 │  ├─────────────────┤ ← SP at interrupt time                  │
 │  │ saved x29, x30  │ ← call_on_irq_stack saves frame here   │
 │  └─────────────────┘                                         │
 └──────────────────────────────────────────────────────────────┘
                    │
                    │  SP switches to IRQ stack
                    ▼
 ┌──────────────────────────────────────────────────────────────┐
 │               Per-CPU IRQ Stack (16 KB)                      │
 │                                                              │
 │                                                   (top) ← SP│
 │  ┌─────────────────┐                                         │
 │  │ handler frames   │ ← handler runs here with full 16 KB   │
 │  │ ...              │                                        │
 │  └─────────────────┘                                         │
 │                                                              │
 └──────────────────────────────────────────────────────────────┘
                    │
                    │  Handler returns, SP restored to task stack
                    ▼
 Back on task kernel stack, continue where interrupted
```

---

## Summary

This document covered the complete software-level interrupt handling framework in the Linux kernel on AArch64, from handler registration through execution and context management:

- **Handler registration** uses `request_irq()` → `request_threaded_irq()` → `__setup_irq()`, which allocates an `irqaction` structure, validates sharing compatibility, optionally creates a kernel thread for threaded handlers, and links the action into the `irq_desc->action` linked list.

- **Three core data structures** drive interrupt management: `irqaction` (per-handler), `irq_desc` (per-IRQ-line), and `irq_data` / `irq_common_data` (hardware-facing state). The `irq_desc->action` chain links all handlers on a shared line.

- **`IRQF_COND_ONESHOT`** is automatically added by `request_irq()` so that simple non-threaded handlers can transparently join shared lines that have existing `IRQF_ONESHOT` handlers.

- **Force-threading** (`threadirqs` boot parameter or `PREEMPT_RT`) converts hardirq handlers into kernel threads at registration time, reducing interrupt latency for real-time workloads. Handlers with `IRQF_NO_THREAD` are exempt.

- **Handler return values** (`IRQ_NONE`, `IRQ_HANDLED`, `IRQ_WAKE_THREAD`) drive both the shared-interrupt dispatch loop and the spurious interrupt detector.

- **IRQF flags** control sharing (`IRQF_SHARED`), threading (`IRQF_ONESHOT`, `IRQF_NO_THREAD`), power management (`IRQF_NO_SUSPEND`), and balancing (`IRQF_NOBALANCING`). Real-world examples include PL011 UART (`IRQF_SHARED`) and TPS6586x PMIC (`IRQF_ONESHOT` with threaded handler).

- **Shared interrupt identification** requires each handler to read its device's hardware status register — the kernel calls every handler on a shared line and relies on `IRQ_NONE`/`IRQ_HANDLED` to sort it out.

- **End-to-end execution** traces from device assertion through the GIC (IAR read, priority drop), CPU exception entry, irq stack switch, `gic_handle_irq()`, `handle_fasteoi_irq()`, and finally `__handle_irq_event_percpu()` walking the action chain to call each driver handler.

- **Masking/unmasking** is a GIC-level operation (writing to `GICD_ICENABLER`/`GICD_ISENABLER`). Normal non-ONESHOT interrupts are not explicitly masked around handler execution; ONESHOT interrupts are masked before the handler and stay masked until the threaded handler finishes.

- **`local_irq_disable()`/`local_irq_enable()`** are per-CPU operations that tell the processor not to take interrupt exceptions. They protect per-CPU data structures from interrupt handler corruption.

- **`local_irq_save()`/`local_irq_restore()`** solve the nesting problem — they preserve the caller's interrupt state, making them safe to call from any context. Both pairs affect only the local CPU.

- **Per-line interrupt control** (`disable_irq`/`enable_irq`) uses a depth counter for nesting — hardware is only disabled on the first call and re-enabled on the last. Disabling a shared line affects all handlers on that line.

- **There is no API to disable all interrupts on all CPUs** — interrupt masking is fundamentally per-CPU on AArch64.

- **Hardirq context** runs with interrupts disabled, cannot be preempted, and must use `GFP_ATOMIC` for allocations. **Softirq context** runs with interrupts enabled (so hardirqs can preempt it), but still cannot sleep. The locking primitive choice follows directly from which contexts share the data.

- **Interrupt context** is tracked via the `preempt_count` bitfield — `HARDIRQ_OFFSET` is added on entry and subtracted on exit. The `in_hardirq()`, `in_task()`, and `in_serving_softirq()` macros test these bits.

- **`current` in an interrupt handler** points to the interrupted task's `task_struct` via `SP_EL0` — valid but borrowed, not owned.

- **Sleeping in interrupt context is forbidden** because `preempt_count` is nonzero, interrupts are disabled, and there is no meaningful process to sleep.

- **The per-CPU IRQ stack** provides a dedicated 16 KB stack for interrupt handlers, preventing stack overflow when interrupts arrive during deep kernel call chains.
