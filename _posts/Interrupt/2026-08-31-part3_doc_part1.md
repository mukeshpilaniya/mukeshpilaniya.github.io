---
title: Interrupt Handling in the Linux Kernel — Part 1
published: true
categories: [Interrupt]
tags: [interrupt]
---
# Interrupt Handling in the Linux Kernel — Part 1: Registration, Dispatch, and Execution

> **Part 2** covers interrupt control APIs (enable/disable), execution context, the `preempt_count` bitfield, and why sleeping in interrupt handlers is forbidden: `part3_doc_part2.md`

When a device raises an interrupt, the Linux kernel must locate the correct handler, invoke it in a context with strict constraints, and ensure the system remains responsive throughout. The previous documents traced the journey of an interrupt from the hardware signal through the GIC and into the kernel's vector table entry. This document picks up where that journey lands — at the C-level interrupt handling framework. It covers how device drivers register and unregister interrupt handlers with `request_irq()` and `free_irq()`, what flags control handler behavior, how the kernel dispatches handlers on shared interrupt lines, how drivers identify whether an interrupt belongs to their device, the mechanisms for enabling and disabling interrupts at both the local CPU and interrupt-line level, and the critical distinction between process context and interrupt context — including why sleeping in an interrupt handler is forbidden, what `current` points to during handler execution, and how the kernel's per-CPU IRQ stack keeps things isolated. The focus is exclusively on the AArch64 architecture, with all code references drawn from the [Linux 7.2-rc5](https://github.com/torvalds/linux/blob/v7.2-rc5/) kernel source.


---

## Table of Contents

1. [What an Interrupt Handler Must Do](#what-an-interrupt-handler-must-do)
2. [Registering an Interrupt Handler](#registering-an-interrupt-handler)
3. [The irqaction Structure](#the-irqaction-structure)
4. [The irq_desc and irq_data Structures](#the-irq_desc-and-irq_data-structures)
5. [Inside __setup_irq: How Handlers Get Linked](#inside-__setup_irq-how-handlers-get-linked)
6. [Forced Threading: The threadirqs Boot Parameter and PREEMPT_RT](#forced-threading-the-threadirqs-boot-parameter-and-preempt_rt)
7. [Interrupt Handler Return Values](#interrupt-handler-return-values)
8. [Interrupt Flags (IRQF_*)](#interrupt-flags-irqf_)
9. [Shared Interrupts: How Drivers Identify Their Device](#shared-interrupts-how-drivers-identify-their-device)
10. [Unregistering an Interrupt Handler](#unregistering-an-interrupt-handler)
11. [From Registration to Execution: How a Device Interrupt Is Handled](#from-registration-to-execution-how-a-device-interrupt-is-handled)
12. [Masking and Unmasking: What It Means and Who Does It](#masking-and-unmasking-what-it-means-and-who-does-it)
13. [IRQ Affinity and Balancing](#irq-affinity-and-balancing)

→ Continued in **Part 2** (`part3_doc_part2.md`): Enabling/Disabling Interrupts, local_irq_* APIs, disable_irq, Execution Context, preempt_count, current in ISR, sleeping prohibition, per-CPU IRQ stack.

---

## What an Interrupt Handler Must Do

An **interrupt handler** (also called an **interrupt service routine**, or ISR) is a C function that the kernel calls in response to a hardware interrupt. The handler runs in a special execution environment — **hardirq context** — where it must obey strict rules: **it cannot sleep, it cannot acquire mutexes, and it should complete as quickly as possible because all other interrupts on the local CPU at the same priority level or below are deferred until it returns.**

The core responsibilities of an interrupt handler are:

1. **Acknowledge the interrupt at the device level** — read the device's status register to determine what happened and clear the interrupt condition so the device de-asserts its interrupt line.
2. **Perform the minimum necessary work** — copy data from device registers to memory, update driver state, or kick off a DMA transfer. Any work that can be deferred should be pushed to a **bottom half** (softirq, tasklet, or workqueue).
3. **Return the correct status** — tell the kernel whether this handler actually serviced the interrupt (`IRQ_HANDLED`), whether it should wake a threaded handler (`IRQ_WAKE_THREAD`), or whether the interrupt was not from this device (`IRQ_NONE`).

The handler function signature is defined by the **`irq_handler_t`** typedef in [include/linux/interrupt.h, line 104](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/interrupt.h#L104):

```c
typedef irqreturn_t (*irq_handler_t)(int, void *);
```

The first argument is the IRQ number, and the second is the **`dev_id`** — an opaque cookie that the driver passed at registration time. For shared interrupts, `dev_id` is the mechanism the kernel uses to distinguish between handlers on the same line, and the driver typically passes a pointer to its private data structure.

---

## Registering an Interrupt Handler

A device driver registers its interrupt handler by calling **`request_irq()`**, which is a thin inline wrapper defined in [include/linux/interrupt.h, lines 172–177](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/interrupt.h#L172-L177):

```c
static inline int __must_check
request_irq(unsigned int irq, irq_handler_t handler, unsigned long flags,
            const char *name, void *dev)
{
    return request_threaded_irq(irq, handler, NULL, flags | IRQF_COND_ONESHOT, name, dev);
}
```

It delegates entirely to **`request_threaded_irq()`**, passing `thread_fn = NULL` (no threaded handler) and adding the `IRQF_COND_ONESHOT` flag. The parameters are:

| Parameter | Purpose |
|-----------|---------|
| `irq` | The interrupt number to register for. Obtained from the platform (device tree, ACPI, or PCI subsystem). |
| `handler` | The function to call in hardirq context when the interrupt fires. |
| `flags` | A bitmask of `IRQF_*` flags controlling sharing, trigger type, threading, and other behavior. |
| `name` | A human-readable string identifying the device. Appears in `/proc/interrupts` and in the `/proc/irq/N/` directory. |
| `dev` | An opaque pointer passed back to the handler as its second argument. For shared interrupts, this **must** be non-NULL and unique per handler — the kernel uses it as the key to find the correct handler during `free_irq()`. Typically a pointer to the driver's private data structure. |

### The Real Entry Point: request_threaded_irq

The actual registration logic lives in **`request_threaded_irq()`** at [kernel/irq/manage.c, lines 2084–2212](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/irq/manage.c#L2084-L2212). This function handles both simple **hardirq-only handlers** and the **threaded interrupt** model where a lightweight hardirq handler acknowledges the device and wakes a kernel thread for the heavy processing:

```c
int request_threaded_irq(unsigned int irq, irq_handler_t handler,
                         irq_handler_t thread_fn, unsigned long irqflags,
                         const char *devname, void *dev_id)
```

The function performs several validation checks before doing any real work:

1. **`IRQ_NOTCONNECTED` check** — if the IRQ number is `IRQ_NOTCONNECTED` (a sentinel value equal to `1U << 31`), the function returns `-ENOTCONN` immediately. This allows drivers to gracefully handle platforms where a device's interrupt is not wired up.

2. **Shared IRQ validation** — if `IRQF_SHARED` is set, `dev_id` must be non-NULL (the kernel uses it to identify handlers on `free_irq()`). `IRQF_SHARED` and `IRQF_NO_AUTOEN` are mutually exclusive — you cannot register a shared handler that starts disabled, because the other devices on that line need the interrupt active.

3. **Suspend flag validation** — `IRQF_NO_SUSPEND` and `IRQF_COND_SUSPEND` are mutually exclusive. `IRQF_COND_SUSPEND` is only valid for shared IRQs.

4. **NULL handler handling** — if `handler` is NULL but `thread_fn` is provided, the kernel installs **`irq_default_primary_handler`** as the hardirq handler. This function does nothing except return `IRQ_WAKE_THREAD`:

```c
static irqreturn_t irq_default_primary_handler(int irq, void *dev_id)
{
    return IRQ_WAKE_THREAD;
}
```

After validation, the function resolves the IRQ number to its descriptor, allocates an **`irqaction`** structure, fills in its fields, and calls **`__setup_irq()`** to perform the actual registration.

### Getting irq_desc from the IRQ Number During Registration

Before anything else, `request_threaded_irq()` maps the caller-supplied Linux IRQ number (`virq`) to its `irq_desc` using **`irq_to_desc()`** at [kernel/irq/irqdesc.c](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/irq/irqdesc.c):

```c
/* kernel/irq/manage.c — first thing inside request_threaded_irq() */
struct irq_desc *desc;
desc = irq_to_desc(irq);
if (!desc)
    return -EINVAL;
```

The implementation of `irq_to_desc()` depends on `CONFIG_SPARSE_IRQ`:

```c
/* With CONFIG_SPARSE_IRQ=y — default on all AArch64 kernels */
struct irq_desc *irq_to_desc(unsigned int irq)
{
    return radix_tree_lookup(&irq_desc_tree, irq);   /* O(log n) */
}

/* Without CONFIG_SPARSE_IRQ — legacy / small embedded */
struct irq_desc *irq_to_desc(unsigned int irq)
{
    return (irq < NR_IRQS) ? irq_desc + irq : NULL;  /* O(1) array */
}
```

`CONFIG_SPARSE_IRQ` is always enabled on AArch64 because GICv3's INTID space (up to 1020 SPIs + 65536 LPIs) is large and sparse — preallocating `irq_desc` for every possible INTID would waste megabytes. With sparse IRQ, descriptors are allocated on demand when the GIC driver maps a hardware interrupt into the Linux IRQ domain at boot, and stored in a radix tree keyed by the Linux IRQ number.

```
 virq (Linux IRQ number, e.g., 42)
         │
         ▼
 irq_to_desc(42)
         │
         ├─ SPARSE_IRQ=y  →  radix_tree_lookup(&irq_desc_tree, 42)
         │                    tree populated at boot by irq_domain_alloc_descs()
         │
         └─ SPARSE_IRQ=n  →  &irq_desc[42]  (static array, NR_IRQS entries)
         │
         ▼
 struct irq_desc *desc   (NULL → irq never allocated → return -EINVAL)
```

All subsequent registration steps — `__setup_irq()`, shared IRQ validation, thread creation, `/proc` entry creation — operate on this `desc` pointer.

### Registration Call Chain

```
 Driver calls request_irq()
          │
          ▼
 ┌────────────────────────────────────────────────────────────────────┐
 │ request_irq(irq, handler, flags, name, dev)                       │
 │   include/linux/interrupt.h:172                                    │
 │   Thin inline wrapper — adds IRQF_COND_ONESHOT,                   │
 │   passes thread_fn = NULL                                          │
 └──────────────────────────┬─────────────────────────────────────────┘
                            │
                            ▼
 ┌────────────────────────────────────────────────────────────────────┐
 │ request_threaded_irq(irq, handler, thread_fn, flags, name, dev)   │
 │   kernel/irq/manage.c:2084                                         │
 │                                                                    │
 │   ① Validate: IRQ_NOTCONNECTED? IRQF_SHARED + NULL dev_id?        │
 │   ② Validate: IRQF_NO_SUSPEND vs IRQF_COND_SUSPEND?              │
 │   ③ If handler==NULL && thread_fn!=NULL:                           │
 │        handler = irq_default_primary_handler (returns IRQ_WAKE_     │
 │        THREAD)                                                     │
 │   ④ Allocate struct irqaction via kzalloc(GFP_KERNEL)              │
 │   ⑤ Fill in: handler, thread_fn, flags, name, dev_id              │
 └──────────────────────────┬─────────────────────────────────────────┘
                            │
                            ▼
 ┌────────────────────────────────────────────────────────────────────┐
 │ __setup_irq(irq, desc, new_action)                                │
 │   kernel/irq/manage.c:1471                                         │
 │                                                                    │
 │   ① Force-threading check (irq_setup_forced_threading)            │
 │   ② Create kernel thread if thread_fn present                      │
 │   ③ Shared IRQ validation (flags, trigger type, ONESHOT)           │
 │   ④ Link irqaction into desc->action chain                        │
 │   ⑤ Enable IRQ at hardware (irq_startup → GIC unmask)             │
 │   ⑥ Create /proc/irq/N/ entries                                    │
 └────────────────────────────────────────────────────────────────────┘
```

---

## The irqaction Structure

The Linux kernel does not call driver interrupt handlers directly from the flow handler. Instead, it uses an intermediate data structure — **`struct irqaction`** — that wraps the handler function along with everything the kernel needs to manage it: the device cookie, the threading state, the flags, and the linkage into the shared-interrupt chain. When a driver calls `request_irq()`, the kernel allocates an `irqaction`, fills it in, and links it into the per-IRQ descriptor. When the interrupt fires, the flow handler walks the `irqaction` chain and calls each handler in turn. When the driver calls `free_irq()`, the kernel finds the matching `irqaction` by `dev_id`, unlinks it, waits for any in-flight handlers to complete, and frees it. The `irqaction` is the central bookkeeping structure that ties a driver's handler to the kernel's interrupt framework.

Every registered interrupt handler is represented by a **`struct irqaction`**, defined in [include/linux/interrupt.h, lines 106–140](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/interrupt.h#L106-L140):

```c
struct irqaction {
    irq_handler_t       handler;
    union {
        void            *dev_id;
        void __percpu   *percpu_dev_id;
    };
    const struct cpumask *affinity;
    struct irqaction    *next;
    irq_handler_t       thread_fn;
    struct task_struct  *thread;
    struct irqaction    *secondary;
    unsigned int        irq;
    unsigned int        flags;
    unsigned long       thread_flags;
    unsigned long       thread_mask;
    const char          *name;
    struct proc_dir_entry *dir;
} ____cacheline_internodealigned_in_smp;
```

The key fields and their roles:

| Field | Purpose |
|-------|---------|
| `handler` | The function called in hardirq context. |
| `dev_id` | Opaque cookie passed to the handler and used as the lookup key in `free_irq()`. |
| `next` | Pointer to the next `irqaction` on the same IRQ line — forms a **singly-linked list** for shared interrupts. |
| `thread_fn` | The function to run in the handler's kernel thread (process context). Only used for threaded interrupts. |
| `thread` | The `task_struct` pointer for the kernel thread, named `irq/<irq_num>-<name>` (e.g., `irq/42-mydevice`). Created by `setup_irq_thread()`. |
| `secondary` | A second `irqaction` used when force-threading splits a handler into primary (hardirq) and secondary (threaded) parts. |
| `thread_mask` | A bitmask used for `IRQF_ONESHOT` tracking — each shared handler gets a unique bit, so the line is only unmasked after all threaded handlers complete. |
| `flags` | The `IRQF_*` flags passed at registration time. |
| `name` | The device name string visible in `/proc/interrupts`. |

The `irqaction` structures are chained together via the `next` pointer. The head of this chain is stored in **`irq_desc->action`**, a field of the **`struct irq_desc`** (the per-IRQ descriptor) defined in [include/linux/irqdesc.h, lines 45–135](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/irqdesc.h#L45-L135). The kernel iterates this chain with the `for_each_action_of_desc()` macro from [kernel/irq/internals.h, line 169](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/irq/internals.h#L169):

```c
#define for_each_action_of_desc(desc, act) \
    for (act = desc->action; act; act = act->next)
```

The relationship between these structures looks like this:

```
 irq_desc (per IRQ line)
 ┌────────────────────────────┐
 │ irq_data                   │
 │   .chip → gic_chip         │     irqaction (driver A)         irqaction (driver B)
 │   .hwirq                   │     ┌──────────────────┐         ┌──────────────────┐
 │ handle_irq → handle_       │     │ handler  → funcA │         │ handler  → funcB │
 │              fasteoi_irq   │     │ dev_id   → privA │    ┌───>│ dev_id   → privB │
 │ action ──────────────────────────>│ next ────────────┼────┘    │ next     → NULL  │
 │ depth = 0                  │     │ name     → "devA"│         │ name     → "devB"│
 │ lock                       │     │ flags    → SHARED│         │ flags    → SHARED│
 │ threads_active             │     │ thread_fn        │         │ thread_fn        │
 │ wait_for_threads           │     │ thread_mask=0x01 │         │ thread_mask=0x02 │
 └────────────────────────────┘     └──────────────────┘         └──────────────────┘
```

---

## The irq_desc and irq_data Structures

While `irqaction` represents a single driver's handler, the kernel needs a higher-level structure to represent the interrupt line itself — its hardware configuration, its chip driver, its CPU affinity, its enable/disable state, its statistics, and the chain of all handlers registered on it. That structure is **`struct irq_desc`**, the **interrupt descriptor**. There is one `irq_desc` for every Linux IRQ number in the system. It is the central hub through which all interrupt management flows — registration, dispatch, enable/disable, affinity, and statistics all operate on the `irq_desc`.

### struct irq_desc

Defined in [include/linux/irqdesc.h, lines 81–135](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/irqdesc.h#L81-L135):

```c
struct irq_desc {
    struct irq_common_data  irq_common_data;    /* shared data across chip hierarchy */
    struct irq_data         irq_data;           /* per-chip data: chip, hwirq, domain */
    struct irqstat __percpu *kstat_irqs;         /* per-CPU interrupt counters */
    irq_flow_handler_t      handle_irq;         /* flow handler (e.g., handle_fasteoi_irq) */
    struct irqaction        *action;            /* linked list of driver handlers */
    unsigned int            status_use_accessors;
    unsigned int            core_internal_state__do_not_mess_with_it;
    unsigned int            depth;              /* nested disable_irq() counter */
    unsigned int            wake_depth;         /* nested wakeup enable counter */
    unsigned long           tot_count;          /* total interrupt count */
    unsigned long           last_unhandled;     /* timestamp of last unhandled IRQ */
    unsigned int            irq_count;          /* for spurious detection window */
    unsigned int            irqs_unhandled;     /* count of unhandled IRQs in window */
    atomic_t                threads_handled;
    int                     threads_handled_last;
    raw_spinlock_t          lock;               /* SMP serialization */
    struct cpumask          *percpu_enabled;
    unsigned long           threads_oneshot;    /* bitmask: which ONESHOT threads are active */
    atomic_t                threads_active;     /* number of active threaded handlers */
    wait_queue_head_t       wait_for_threads;   /* synchronize_irq() sleeps here */
    unsigned int            nr_actions;
    unsigned int            no_suspend_depth;
    unsigned int            cond_suspend_depth;
    unsigned int            force_resume_depth;
    struct proc_dir_entry   *dir;              /* /proc/irq/N/ directory */
    rcuref_t                refcnt;
    struct rcu_head         rcu;
    struct kobject          kobj;
    struct mutex            request_mutex;      /* serializes request/free_irq */
    int                     parent_irq;
    struct module           *owner;
    const char              *name;             /* flow handler name for /proc/interrupts */
} ____cacheline_internodealigned_in_smp;
```

The most important fields:

- **`handle_irq`** is the **flow handler** — not the driver handler. For GICv3 SPIs, this is `handle_fasteoi_irq`. For PPIs and SGIs, it is `handle_percpu_devid_irq`. The flow handler is responsible for the interrupt-controller-level protocol (acknowledging, masking/unmasking, sending EOI) and then calling into the driver handler chain. It is set by the irqchip driver during IRQ domain mapping — for GICv3, at [drivers/irqchip/irq-gic-v3.c, lines 1567–1568](https://github.com/torvalds/linux/blob/v7.2-rc5/drivers/irqchip/irq-gic-v3.c#L1567-L1568).

- **`action`** is the head of the `irqaction` linked list. All driver handlers registered on this IRQ line hang off this pointer.

- **`depth`** is the nested `disable_irq()` counter. The hardware is disabled when depth transitions from 0 to 1, and re-enabled when it transitions from 1 to 0.

- **`lock`** is a raw spinlock that protects the descriptor from concurrent access. The flow handler holds this lock while checking state and calling the handler chain (it drops it during actual handler execution to allow other CPUs to modify the descriptor).

- **`threads_oneshot`** is a bitmask where each bit corresponds to one `irqaction`'s `thread_mask`. When a threaded `IRQF_ONESHOT` handler is woken, its bit is set. The line stays masked until all bits are cleared (all threaded handlers have completed).

- **`threads_active`** / **`wait_for_threads`** are used by `synchronize_irq()` — it sleeps on `wait_for_threads` until `threads_active` reaches zero.

- **`request_mutex`** serializes `request_irq()` and `free_irq()` calls. It is taken before `lock` to prevent concurrent registration/removal.

- **`kstat_irqs`** is a per-CPU counter structure. Each time an interrupt fires on a CPU, the counter for that CPU is incremented. This is what `/proc/interrupts` reads.

### struct irq_data and struct irq_common_data

The `irq_desc` embeds two more structures that hold the hardware-facing information. These are separated because the kernel's IRQ domain hierarchy allows interrupts to be translated through multiple layers (e.g., a GPIO controller behind a GIC), and each layer needs its own `irq_data` while sharing the `irq_common_data`.

**`struct irq_common_data`** at [include/linux/irq.h, lines 150–164](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/irq.h#L150-L164):

```c
struct irq_common_data {
    unsigned int        state_use_accessors;    /* IRQD_* state flags */
    unsigned int        node;                   /* NUMA node */
    void                *handler_data;          /* per-IRQ data for chip methods */
    struct msi_desc     *msi_desc;              /* MSI descriptor */
    cpumask_var_t       affinity;               /* CPU affinity mask */
    cpumask_var_t       effective_affinity;     /* actual HW affinity */
};
```

The `state_use_accessors` field holds **`IRQD_*`** flags that track the runtime state of the interrupt:

| Flag | Meaning |
|------|---------|
| `IRQD_IRQ_DISABLED` | The IRQ is software-disabled (via `disable_irq()`) |
| `IRQD_IRQ_MASKED` | The IRQ is masked at the hardware level (GIC enable register cleared) |
| `IRQD_IRQ_INPROGRESS` | A hardirq handler is currently executing — `synchronize_irq()` spins on this |
| `IRQD_LEVEL` | The interrupt is level-triggered (as opposed to edge-triggered) |
| `IRQD_NO_BALANCING` | Excluded from IRQ balancing (set by `IRQF_NOBALANCING`) |
| `IRQD_AFFINITY_MANAGED` | The kernel auto-manages this interrupt's CPU affinity |

**`struct irq_data`** at [include/linux/irq.h, lines 170–193](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/irq.h#L170-L193):

```c
struct irq_data {
    u32                 mask;           /* precomputed bitmask for chip register access */
    unsigned int        irq;            /* Linux virtual IRQ number */
    irq_hw_number_t     hwirq;          /* hardware IRQ number (GIC INTID) */
    struct irq_common_data *common;     /* points back to irq_desc.irq_common_data */
    struct irq_chip     *chip;          /* low-level HW operations (e.g., gic_eoimode1_chip) */
    struct irq_domain   *domain;        /* translation domain (hwirq ↔ Linux irq) */
    struct irq_data     *parent_data;   /* parent in the hierarchy (e.g., GIC above GPIO) */
    void                *chip_data;     /* chip-private data (e.g., GIC distributor base) */
};
```

The key relationship: `irq_data.chip` points to the **`irq_chip`** structure — the set of callbacks that the generic IRQ code calls to control the hardware. For GICv3, this is `gic_eoimode1_chip`, which provides `.irq_mask = gic_mask_irq`, `.irq_unmask = gic_unmask_irq`, `.irq_eoi = gic_eoimode1_eoi_irq`, `.irq_set_affinity = gic_set_affinity`, and other operations. The `irq_data.hwirq` is the GIC's INTID — the number the GIC uses to identify the interrupt, which is different from the Linux `irq` number.

The `irq_data.common` pointer points back to the `irq_common_data` embedded in the same `irq_desc`. The helper `irq_data_to_desc()` uses `container_of()` to navigate from an `irq_data` back to the owning `irq_desc`.

```
 irq_desc
 ┌─────────────────────────────────────────────────────────┐
 │ irq_common_data (embedded)                              │
 │ ┌─────────────────────────────────────────────────────┐ │
 │ │ state_use_accessors  (IRQD_IRQ_DISABLED, etc.)      │ │
 │ │ affinity             (cpumask for this IRQ)         │ │
 │ │ effective_affinity   (actual HW routing)            │ │
 │ └────────────────────────────────────▲────────────────┘ │
 │                                      │ .common          │
 │ irq_data (embedded)                  │                  │
 │ ┌────────────────────────────────────┼────────────────┐ │
 │ │ irq    = 42           (Linux IRQ number)            │ │
 │ │ hwirq  = 79           (GIC INTID)                   │ │
 │ │ chip   → gic_eoimode1_chip  (irq_chip callbacks)    │ │
 │ │ domain → gic_irq_domain     (hwirq ↔ irq mapping)  │ │
 │ │ common ────────────────────────────┘                 │ │
 │ └─────────────────────────────────────────────────────┘ │
 │                                                         │
 │ handle_irq → handle_fasteoi_irq  (flow handler)        │
 │ action    → irqaction chain      (driver handlers)     │
 │ depth     = 0                    (enable/disable nest) │
 │ lock                             (raw spinlock)        │
 └─────────────────────────────────────────────────────────┘
```

---

## Inside __setup_irq: How Handlers Get Linked

The internal function **`__setup_irq()`** at [kernel/irq/manage.c, lines 1471–1853](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/irq/manage.c#L1471-L1853) is where the real registration work happens. It is the heart of the interrupt registration subsystem, and understanding it reveals **how the kernel manages shared interrupts, threaded handlers, forced threading, and the `/proc` interface.**

### __setup_irq Internal Flow

```
 __setup_irq(irq, desc, new)
          │
          ▼
 ┌─── Module ref + inherit trigger type ───┐
 │  try_module_get(chip->owner)            │
 │  if no IRQF_TRIGGER_MASK in new->flags: │
 │    inherit from desc->irq_data          │
 └──────────────────┬──────────────────────┘
                    │
                    ▼
          ┌─────────────────┐     Yes    ┌───────────────────────────────────┐
          │ Nested threaded? ├──────────>│ handler = irq_nested_primary_     │
          └────────┬────────┘            │ handler (warn-only stub)          │
                   │ No                  └───────────────────────────────────┘
                   ▼
          ┌──────────────────┐    Yes    ┌───────────────────────────────────┐
          │ force_irqthreads │──────────>│ irq_setup_forced_threading()      │
          │ && eligible?     │           │ (see decision tree below)         │
          └────────┬─────────┘           └───────────────────────────────────┘
                   │ No
                   ▼
          ┌──────────────────┐    Yes    ┌───────────────────────────────────┐
          │ thread_fn set?   ├──────────>│ setup_irq_thread()                │
          │                  │           │ kthread_create("irq/%d-%s", ...)  │
          └────────┬─────────┘           └───────────────────────────────────┘
                   │ No
                   ▼
          ┌──────────────────┐    Yes    ┌───────────────────────────────────┐
          │ desc->action     ├──────────>│ Shared IRQ validation:            │
          │ already has      │           │  • Both must have IRQF_SHARED     │
          │ handlers?        │           │  • Trigger types must match       │
          └────────┬─────────┘           │  • IRQF_PERCPU must match        │
                   │ No (first handler)  │  • IRQF_ONESHOT compatibility    │
                   │                     │ Walk list to find tail            │
                   │                     │ Assign unique thread_mask bit     │
                   │                     └──────────────┬────────────────────┘
                   │                                    │
                   │◄───────────────────────────────────┘
                   ▼
 ┌─────────────────────────────────────────────────────────┐
 │ Link: *old_ptr = new                                    │
 │                                                         │
 │ If first handler:                                       │
 │   __irq_set_trigger() → configure GIC trigger type      │
 │   irq_activate()      → activate in irq domain          │
 │   irq_startup()       → unmask at GIC (unless NOAUTOEN) │
 │                                                         │
 │ register_irq_proc()   → create /proc/irq/N/             │
 │ register_handler_proc → create /proc/irq/N/<name>       │
 └─────────────────────────────────────────────────────────┘
```

### Step 1: Module Reference and Trigger Type (lines 1481–1496)

The function first takes a module reference on the IRQ chip's owner (preventing the chip driver from being unloaded while handlers are registered) and inherits the trigger type from the IRQ descriptor if the caller did not specify one:

```c
if (!(new->flags & IRQF_TRIGGER_MASK))
    new->flags |= irqd_get_trigger_type(&desc->irq_data);
```

### Step 2: Threading Setup (lines 1508–1554)

If the IRQ is marked as a **nested thread** (set by the parent irqchip for GPIO-like controllers), the hardirq handler is replaced with `irq_nested_primary_handler` — a function that prints a warning if it is ever called, because nested threaded handlers should only run in thread context.

If the IRQ supports threading and the kernel has **force-threading** enabled (via the `threadirqs` boot parameter or `PREEMPT_RT`), **`irq_setup_forced_threading()`** at [kernel/irq/manage.c, lines 1312–1349](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/irq/manage.c#L1312-L1349) converts the hardirq handler into a threaded one:

```c
static int irq_setup_forced_threading(struct irqaction *new)
{
    if (!force_irqthreads())
        return 0;
    if (new->flags & (IRQF_NO_THREAD | IRQF_PERCPU | IRQF_ONESHOT))
        return 0;

    new->thread_fn = new->handler;
    new->handler = irq_default_primary_handler;
    new->flags |= IRQF_ONESHOT;
    ...
}
```

The original handler becomes `thread_fn` (to run in process context), and the hardirq handler is replaced with `irq_default_primary_handler` (which just returns `IRQ_WAKE_THREAD`). The `IRQF_ONESHOT` flag is added to keep the line masked until the thread finishes — without this, the device could re-interrupt before the thread runs.

If a `thread_fn` is present (either originally or after force-threading), **`setup_irq_thread()`** at [kernel/irq/manage.c, lines 1402–1441](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/irq/manage.c#L1402-L1441) creates a dedicated kernel thread:

```c
t = kthread_create(irq_thread, new, "irq/%d-%s", irq, new->name);
```

This creates a thread named `irq/42-mydevice` (for IRQ 42, device "mydevice") that runs the `irq_thread()` loop function. The thread runs at `SCHED_FIFO` priority and waits to be woken by the hardirq handler returning `IRQ_WAKE_THREAD`.

### Step 3: Shared IRQ Validation (lines 1563–1653)

When the IRQ line already has handlers registered (`desc->action` is non-NULL), `__setup_irq()` enforces several compatibility requirements:

1. **Both old and new handlers must have `IRQF_SHARED` set** — if either side did not agree to sharing, the registration fails with `-EBUSY`.
2. **Trigger types must match** — you cannot mix edge-triggered and level-triggered handlers on the same line.
3. **`IRQF_PERCPU` must match** — per-CPU and non-per-CPU handlers cannot coexist.
4. **`IRQF_ONESHOT` must be compatible** — if existing handlers use `IRQF_ONESHOT`, the new handler must either also use it or set `IRQF_COND_ONESHOT` to agree to the constraint.

If validation passes, the function walks the linked list to find the tail:

```c
do {
    thread_mask |= old->thread_mask;
    old_ptr = &old->next;
    old = *old_ptr;
} while (old);
```

The new `irqaction` is appended at the end. The `thread_mask` accumulation ensures each handler on the line gets a unique bit for `IRQF_ONESHOT` tracking.

### Step 4: Link and Enable (lines 1715–1806)

For the first handler on a line, `__setup_irq()` configures the trigger type at the hardware level via `__irq_set_trigger()`, activates the IRQ in the irq domain hierarchy via `irq_activate()`, and starts the IRQ (unmasks it at the GIC) via `irq_startup()` — unless `IRQF_NO_AUTOEN` was specified, in which case `desc->depth` is set to 1 (disabled).

The actual link is a single pointer assignment:

```c
*old_ptr = new;
```

This appends the new `irqaction` at the tail of the linked list (or sets it as the first action if the line was previously unused).

### Step 5: Post-Registration Housekeeping (lines 1810–1815)

After linking, the function creates the `/proc/irq/N/` directory (via `register_irq_proc()`) and a per-handler entry `/proc/irq/N/<name>` (via `register_handler_proc()`). If the handler has a thread, it wakes the thread and waits for it to signal readiness.

---

## Forced Threading: The threadirqs Boot Parameter and PREEMPT_RT

The kernel can convert hardirq handlers into threaded handlers at registration time, moving their execution from hardirq context into dedicated kernel threads that run in process context. This is controlled by **`force_irqthreads()`**, defined in [include/linux/interrupt.h, lines 511–520](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/interrupt.h#L511-L520):

```c
#ifdef CONFIG_IRQ_FORCED_THREADING
# ifdef CONFIG_PREEMPT_RT
#  define force_irqthreads()    (true)
# else
DECLARE_STATIC_KEY_FALSE(force_irqthreads_key);
#  define force_irqthreads()    (static_branch_unlikely(&force_irqthreads_key))
# endif
#else
#define force_irqthreads()      (false)
#endif
```

There are three configurations:

| Configuration | `force_irqthreads()` | How to enable |
|--------------|---------------------|---------------|
| **`CONFIG_PREEMPT_RT`** | Always `true` | Automatic — PREEMPT_RT forces all eligible handlers into threads. No boot parameter needed. |
| **`CONFIG_IRQ_FORCED_THREADING`** (without RT) | Checks a static key, off by default | Pass `threadirqs` on the kernel command line. |
| **Neither configured** | Always `false` | Force-threading is unavailable. |

The **`threadirqs`** boot parameter is registered at [kernel/irq/manage.c, lines 27–35](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/irq/manage.c#L27-L35):

```c
static int __init setup_forced_irqthreads(char *arg)
{
    static_branch_enable(&force_irqthreads_key);
    return 0;
}
early_param("threadirqs", setup_forced_irqthreads);
```

### Force-Threading Decision Tree

```
 irq_setup_forced_threading(new)
          │
          ▼
 ┌───────────────────────────┐
 │ force_irqthreads() true?  │──── No ──→ return 0 (no change)
 └────────────┬──────────────┘
              │ Yes
              ▼
 ┌───────────────────────────┐
 │ IRQF_NO_THREAD set?      │──── Yes ─→ return 0 (exempt: timers, IPIs)
 └────────────┬──────────────┘
              │ No
              ▼
 ┌───────────────────────────┐
 │ IRQF_PERCPU set?         │──── Yes ─→ return 0 (exempt: PPIs)
 └────────────┬──────────────┘
              │ No
              ▼
 ┌───────────────────────────┐
 │ IRQF_ONESHOT set?        │──── Yes ─→ return 0 (already threaded)
 └────────────┬──────────────┘
              │ No
              ▼
 ┌───────────────────────────┐
 │ thread_fn already set?   │
 │ (driver provided both    │
 │  handler AND thread_fn)  │
 └─────┬─────────────┬──────┘
       │ No           │ Yes
       ▼              ▼
 ┌────────────┐  ┌──────────────────────────────────────────┐
 │ CASE 1     │  │ CASE 2                                   │
 │ (common)   │  │ (split into primary + secondary threads) │
 │            │  │                                          │
 │ thread_fn  │  │ secondary = kzalloc(irqaction)           │
 │  = handler │  │ secondary->thread_fn = orig thread_fn    │
 │ handler    │  │ new->thread_fn = orig handler             │
 │  = stub    │  │ new->handler = stub                       │
 │ +ONESHOT   │  │ +ONESHOT                                  │
 │            │  │                                          │
 │ Result:    │  │ Result:                                   │
 │ 1 thread   │  │ 2 threads                                │
 │ irq/N-name │  │ irq/N-name + irq/N-s-name                │
 └────────────┘  └──────────────────────────────────────────┘
```

### What Force-Threading Does

When `force_irqthreads()` returns true, **`irq_setup_forced_threading()`** at [kernel/irq/manage.c, lines 1312–1349](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/irq/manage.c#L1312-L1349) transforms the handler at registration time. The transformation depends on what the driver provided:

**Case 1: Driver provides only `handler` (no `thread_fn`)** — the common case for `request_irq()`:

```c
new->thread_fn = new->handler;              /* move handler to thread */
new->handler = irq_default_primary_handler; /* stub: returns IRQ_WAKE_THREAD */
new->flags |= IRQF_ONESHOT;                /* keep line masked until thread finishes */
```

The original handler becomes the `thread_fn` and runs in a kernel thread (`irq/42-mydevice`). The hardirq handler is replaced with a stub that just wakes the thread. `IRQF_ONESHOT` is added because without it, on a level-triggered line, the device would immediately re-assert the interrupt before the thread runs — causing an interrupt storm.

**Case 2: Driver provides both `handler` and `thread_fn`** — used by drivers that split work between a quick hardirq acknowledgment and a slow threaded handler:

```c
new->secondary = kzalloc(sizeof(struct irqaction), GFP_KERNEL);
new->secondary->handler = irq_forced_secondary_handler;
new->secondary->thread_fn = new->thread_fn;   /* original thread_fn → secondary */
new->secondary->dev_id = new->dev_id;
new->secondary->name = new->name;

new->thread_fn = new->handler;                 /* original handler → primary thread */
new->handler = irq_default_primary_handler;    /* stub */
```

The kernel creates a **secondary `irqaction`** to hold the original `thread_fn`. This results in **two kernel threads**: `irq/42-mydevice` (runs the original hardirq handler, now in thread context) and `irq/42-s-mydevice` (runs the original `thread_fn`). The primary thread wakes the secondary when it completes.

**Handlers exempt from force-threading** — three flags prevent conversion:

- **`IRQF_NO_THREAD`** — the handler explicitly opted out. Timer interrupts and IPI handlers use this because they must run in true hardirq context with minimal latency.
- **`IRQF_PERCPU`** — per-CPU interrupts like the ARM generic timer's PPI.
- **`IRQF_ONESHOT`** — already threaded (adding ONESHOT again would conflict).

### Execution Context of the Handler: request_irq Without thread_fn

This is a common source of confusion. When `request_irq()` is used (no `thread_fn`), the execution context of the handler depends on whether force-threading is active:

#### Normal kernel (no `threadirqs`, no `PREEMPT_RT`)

`thread_fn = NULL` → no kernel thread is created → the handler is the only callable → it runs directly in **hardirq context**:

```
 preempt_count   0x00010000   HARDIRQ_OFFSET set (bits [19:16])
 PSTATE.I        1            local IRQs disabled
 Stack           per-CPU IRQ stack (16 KB)
 current         borrowed — interrupted task's task_struct
 in_hardirq()    true
 in_task()       false
 Can sleep       NO
 GFP flag        GFP_ATOMIC only
```

#### Force-threaded kernel (`threadirqs` boot param or `PREEMPT_RT`)

`irq_setup_forced_threading()` converts the registration so there are now **two callables**:

```
 ┌───────────────────────────────────────────┬───────────────────────────────────────────┐
 │ irq_default_primary_handler               │ your original handler (now thread_fn)     │
 │ (replaces handler at registration)        │ (moved to thread_fn at registration)      │
 ├───────────────────────────────────────────┼───────────────────────────────────────────┤
 │ Context: HARDIRQ                          │ Context: PROCESS                          │
 │ preempt_count: HARDIRQ_OFFSET set         │ preempt_count: 0                          │
 │ PSTATE.I: 1 (IRQs disabled)               │ PSTATE.I: 0 (IRQs enabled)               │
 │ Can sleep: NO                             │ Can sleep: YES                            │
 │ GFP flag: GFP_ATOMIC only                 │ GFP flag: GFP_KERNEL allowed              │
 │ current: borrowed                         │ current: irq/N-name thread's task_struct  │
 │ Returns: IRQ_WAKE_THREAD (always)         │ Returns: IRQ_HANDLED / IRQ_NONE           │
 └───────────────────────────────────────────┴───────────────────────────────────────────┘
```

#### Full Decision Tree

```
 request_irq(irq, handler, flags, name, dev)   [thread_fn = NULL]
         │
         ▼
 force_irqthreads() ?
         │
    ┌────┴────┐
   No         Yes  (threadirqs boot param or PREEMPT_RT)
    │          │
    ▼          ▼
 No thread  irq_setup_forced_threading():
 created      thread_fn  = handler   (your code)
              handler    = stub      (irq_default_primary_handler)
              flags     |= IRQF_ONESHOT
    │          │
    ▼          ▼
 handler    stub runs in HARDIRQ context
 runs in    returns IRQ_WAKE_THREAD
 HARDIRQ    │
 context    ▼
            kernel thread irq/N-name wakes up
            runs your original handler in PROCESS context
```

#### Summary Table — All request_irq / request_threaded_irq Combinations

| Registration call | force-threading | Hardirq callable | Context | thread_fn callable | Context |
|---|---|---|---|---|---|
| `request_irq(h)` | off | `h` (your handler) | **Hardirq** | — | — |
| `request_irq(h)` | on | stub | **Hardirq** | `h` (your handler, promoted) | **Process** |
| `request_threaded_irq(h, tf)` | off | `h` | **Hardirq** | `tf` | **Process** |
| `request_threaded_irq(h, tf)` | on | stub | **Hardirq** | `h` → primary thread, `tf` → secondary thread | **Process** (×2) |
| `request_threaded_irq(NULL, tf)` | off | stub | **Hardirq** | `tf` | **Process** |

The answer is always: **hardirq handler runs in hardirq context; thread_fn always runs in process context**. Force-threading only determines whether your `request_irq()` handler becomes a thread_fn at runtime.

### Why Force-Threading Exists

The primary motivation is **reducing interrupt latency on real-time systems**. When all device handlers run in kernel threads, they become schedulable — a high-priority real-time task can preempt a network driver's interrupt handler. Without force-threading, a long-running hardirq handler blocks all other work on that CPU (including real-time tasks) until it completes.

On `PREEMPT_RT` kernels, this is mandatory: the RT patch replaces spinlocks with sleeping mutexes, and sleeping requires process context. If a handler tried to acquire a sleeping mutex from hardirq context, it would deadlock. Force-threading moves the handler into a kernel thread where sleeping is safe.

On non-RT kernels with `threadirqs`, it is a debugging and latency-analysis tool — developers can observe whether threading their handlers would change behavior before committing to `PREEMPT_RT`.

---

## Interrupt Handler Return Values

Every interrupt handler must return one of three values, defined in [include/linux/irqreturn.h, lines 6–18](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/irqreturn.h#L6-L18):

```c
enum irqreturn {
    IRQ_NONE        = (0 << 0),
    IRQ_HANDLED     = (1 << 0),
    IRQ_WAKE_THREAD = (1 << 1),
};
```

| Return Value | Meaning |
|-------------|---------|
| **`IRQ_NONE`** | The interrupt was **not** generated by this device. The handler examined the device's status register and found no pending work. On shared interrupt lines, this tells the kernel to try the next handler in the chain. |
| **`IRQ_HANDLED`** | The interrupt **was** from this device and has been fully serviced in hardirq context. No further action is needed. |
| **`IRQ_WAKE_THREAD`** | The interrupt was from this device, but the handler only did the minimum acknowledgment work. The kernel should wake the associated kernel thread to run `thread_fn` in process context for the heavy processing. Only valid if the handler was registered with a `thread_fn`. |

A convenience macro `IRQ_RETVAL(x)` converts a boolean to `IRQ_HANDLED` (if true) or `IRQ_NONE` (if false).

### Handler Return Value Dispatch Flow

```
 __handle_irq_event_percpu()
          │
          ▼
 for each irqaction in desc->action chain:
          │
          ├─→ action->handler(irq, dev_id)
          │              │
          │              ▼
          │   ┌──────────────────────┐
          │   │   Return Value?      │
          │   └──┬──────┬───────┬───┘
          │      │      │       │
          │      ▼      │       ▼
          │  IRQ_NONE   │   IRQ_WAKE_THREAD
          │  (not mine) │   (ack'd, wake thread)
          │      │      │       │
          │      │      ▼       ▼
          │      │  IRQ_HANDLED  __irq_wake_thread()
          │      │  (fully       wake_up_process(action->thread)
          │      │   serviced)        │
          │      │      │             ▼
          │      │      │      irq_thread() loop runs thread_fn
          │      │      │      in process context
          │      ▼      ▼             │
          │   retval |= res           │ (if IRQF_ONESHOT)
          │      │                    ▼
          │      │            irq_finalize_oneshot()
          │      │            unmask the interrupt line
          ├─→ next action (if any)
          │
          ▼
 All actions called, retval OR'd together
          │
          ▼
 ┌──────────────────────────────────────────────────────┐
 │ If retval == IRQ_NONE (all handlers said "not mine") │
 │   → spurious interrupt detector increments counter   │
 │   → after 100,000 consecutive: disable the line      │
 └──────────────────────────────────────────────────────┘
```

The return values matter for two reasons beyond simple dispatch. First, the kernel's **spurious interrupt detector** in [kernel/irq/spurious.c](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/irq/spurious.c) tracks how often all handlers on a line return `IRQ_NONE`. If an interrupt fires and every handler says "not mine" — returning `IRQ_NONE` — the kernel increments an `irqs_unhandled` counter in the IRQ descriptor. After 100,000 consecutive unhandled interrupts, the kernel disables the line entirely and logs a warning. This prevents a hardware-stuck interrupt line from consuming all CPU time. Second, the `IRQ_WAKE_THREAD` path interacts with the `IRQF_ONESHOT` mechanism — the interrupt line stays masked until the threaded handler completes, preventing re-interruption on level-triggered lines.

---

## Interrupt Flags (IRQF_*)

The `flags` parameter to `request_irq()` is a bitmask of **`IRQF_*`** constants defined in [include/linux/interrupt.h, lines 31–90](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/interrupt.h#L31-L90). These flags control trigger type, sharing behavior, threading, power management, and balancing.

### Trigger Type Flags

```
IRQF_TRIGGER_NONE     0x00000000    No trigger type specified (inherit from firmware/DT)
IRQF_TRIGGER_RISING   0x00000001    Trigger on rising edge
IRQF_TRIGGER_FALLING  0x00000002    Trigger on falling edge
IRQF_TRIGGER_HIGH     0x00000004    Trigger on active-high level
IRQF_TRIGGER_LOW      0x00000008    Trigger on active-low level
```

On AArch64 with GICv3, SPIs are typically configured as **level-high** or **edge-rising** in the device tree. If the driver does not specify a trigger type (`IRQF_TRIGGER_NONE`), `__setup_irq()` inherits whatever the firmware or device tree specified.

### Sharing and Identification Flags

| Flag | Value | Purpose |
|------|-------|---------|
| **`IRQF_SHARED`** | `0x00000080` | Allow multiple devices to share this interrupt line. Each handler on the line is called in sequence when the interrupt fires. Requires a non-NULL `dev_id`. |
| **`IRQF_PROBE_SHARED`** | `0x00000100` | The caller expects that sharing mismatches might occur. If `__setup_irq()` fails because of incompatible flags between the existing handler and the new one, this flag **suppresses** the kernel error log. Drivers use this during probe to test whether sharing is possible — a mismatch returns `-EBUSY` silently instead of logging a loud error. |

### Threading and Execution Flags

| Flag | Value | Purpose |
|------|-------|---------|
| **`IRQF_ONESHOT`** | `0x00002000` | Keep the interrupt line masked after the hardirq handler returns, until the threaded handler (`thread_fn`) finishes. Essential for level-triggered shared interrupts with threaded handlers — without it, the device would re-trigger the interrupt before the thread runs, creating an interrupt storm. |
| **`IRQF_NO_THREAD`** | `0x00010000` | Prevent this handler from being converted to a threaded handler, even when the kernel has force-threading enabled (`threadirqs` boot parameter or `PREEMPT_RT`). Used for handlers that must run in true hardirq context — timer interrupts, IPI handlers, and other time-critical paths. |
| **`IRQF_COND_ONESHOT`** | `0x00200000` | Conditionally agree to participate in `IRQF_ONESHOT` behavior if the line already has `IRQF_ONESHOT` set. Added automatically by `request_irq()`. See detailed explanation below. |
| **`IRQF_PERCPU`** | `0x00000400` | The interrupt is per-CPU (each CPU has its own instance). On AArch64, PPIs (Private Peripheral Interrupts, such as the generic timer) use this. Per-CPU interrupts cannot be shared and are not subject to IRQ balancing. |

### Power Management Flags

| Flag | Value | Purpose |
|------|-------|---------|
| **`IRQF_NO_SUSPEND`** | `0x00004000` | Do not disable this interrupt during system suspend. Used for wakeup-capable devices and the timer. |
| **`IRQF_FORCE_RESUME`** | `0x00008000` | Force re-enable during resume even if `IRQF_NO_SUSPEND` is set. |
| **`IRQF_EARLY_RESUME`** | `0x00020000` | Resume this IRQ during the early `syscore` phase rather than the normal device resume phase. |
| **`IRQF_COND_SUSPEND`** | `0x00040000` | For shared IRQs: still run this handler during suspend if the line is kept alive by another handler's `IRQF_NO_SUSPEND`. |

### Balancing and Debugging Flags

| Flag | Value | Purpose |
|------|-------|---------|
| **`IRQF_NOBALANCING`** | `0x00000800` | Exclude this interrupt from IRQ balancing. The per-CPU timer interrupt and IPIs use this. When set, `__setup_irq()` marks the descriptor with `IRQD_NO_BALANCING`. |
| **`IRQF_IRQPOLL`** | `0x00001000` | Mark the first handler on a shared line as the one to call during IRQ polling (used by the `irqpoll` recovery mechanism for misrouted interrupts). |
| **`IRQF_NO_AUTOEN`** | `0x00080000` | Do not automatically enable the IRQ after registration. The driver must explicitly call `enable_irq()` later. Cannot be used with `IRQF_SHARED`. |
| **`IRQF_NO_DEBUG`** | `0x00100000` | Exclude from the spurious interrupt detector. Used for IPI-like handlers where all handlers returning `IRQ_NONE` is normal. |

### The Timer Composite

**`IRQF_TIMER`** is a composite flag combining `__IRQF_TIMER | IRQF_NO_SUSPEND | IRQF_NO_THREAD`. Timer interrupts must survive suspend, must not be converted to threaded handlers, and must always run in hardirq context — they are the heartbeat of the scheduler.

### IRQF_COND_ONESHOT in Detail

**`IRQF_COND_ONESHOT`** solves a subtle compatibility problem on shared interrupt lines. Consider a shared IRQ line where one driver has already registered a threaded handler with `IRQF_ONESHOT`, and a second driver now wants to register a simple non-threaded handler via `request_irq()`. Without `IRQF_COND_ONESHOT`, this would fail.

During shared IRQ validation in `__setup_irq()`, the kernel checks that the `IRQF_ONESHOT` flags agree between the existing and new handlers. The check at [kernel/irq/manage.c, lines 1631–1635](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/irq/manage.c#L1631-L1635):

```c
if ((old->flags & IRQF_ONESHOT) &&
    (new->flags & IRQF_COND_ONESHOT))
    new->flags |= IRQF_ONESHOT;        /* promote: agree to ONESHOT */
else if ((old->flags ^ new->flags) & IRQF_ONESHOT)
    goto mismatch;                      /* incompatible → -EBUSY */
```

The logic works in two steps:

1. If the existing handler has `IRQF_ONESHOT` and the new handler has `IRQF_COND_ONESHOT`, the kernel **promotes** the new handler to `IRQF_ONESHOT` by ORing it in. The registration succeeds — the new handler transparently participates in the one-shot protocol.

2. If step 1 did not apply and the `IRQF_ONESHOT` flags disagree (XOR is nonzero), the registration fails with `-EBUSY`.

`request_irq()` adds `IRQF_COND_ONESHOT` automatically in its call to `request_threaded_irq()`. This means every handler registered via `request_irq()` — the simple non-threaded path — automatically agrees to participate in one-shot behavior if the line already requires it. Without this, a simple `request_irq()` handler could never join a shared line that has existing `IRQF_ONESHOT` handlers, even though the simple handler has no functional conflict with one-shot semantics.

### Real Driver Examples of IRQF Flags

**PL011 UART — `IRQF_SHARED`:**

The ARM PL011 UART driver registers its handler with `IRQF_SHARED` because multiple AMBA peripherals may share an interrupt line. From [drivers/tty/serial/amba-pl011.c, line 1898](https://github.com/torvalds/linux/blob/v7.2-rc5/drivers/tty/serial/amba-pl011.c#L1898):

```c
ret = request_irq(uap->port.irq, pl011_int, IRQF_SHARED, "uart-pl011", uap);
```

The handler reads the Raw Interrupt Status register and checks whether this UART generated the interrupt — the classic shared-interrupt pattern (lines [1656–1694](https://github.com/torvalds/linux/blob/v7.2-rc5/drivers/tty/serial/amba-pl011.c#L1656-L1694)):

```c
static irqreturn_t pl011_int(int irq, void *dev_id)
{
    struct uart_amba_port *uap = dev_id;
    unsigned int status, pass_counter = AMBA_ISR_PASS_LIMIT;
    int handled = 0;

    uart_port_lock(&uap->port);
    status = pl011_read(uap, REG_RIS) & uap->im;
    if (status) {
        do {
            pl011_write(status & ~(UART011_TXIS|UART011_RTIS|UART011_RXIS),
                        uap, REG_ICR);

            if (status & (UART011_RTIS | UART011_RXIS))
                pl011_rx_chars(uap);
            if (status & UART011_TXIS)
                pl011_tx_chars(uap, true);

            if (pass_counter-- == 0) break;
            status = pl011_read(uap, REG_RIS) & uap->im;
        } while (status != 0);
        handled = 1;
    }
    uart_unlock_and_check_sysrq(&uap->port);
    return IRQ_RETVAL(handled);
}
```

The handler reads `REG_RIS` (Raw Interrupt Status) AND'd with the interrupt mask `uap->im`. If the result is zero, this UART did not interrupt — `handled` stays 0, and `IRQ_RETVAL(0)` returns `IRQ_NONE`. If the result is nonzero, the handler processes receive/transmit events and returns `IRQ_HANDLED`.

**TPS6586x PMIC — `IRQF_ONESHOT` with threaded handler:**

The TPS6586x PMIC driver uses a purely threaded handler because it needs to perform slow I2C reads to determine the interrupt source — impossible in hardirq context. From [drivers/mfd/tps6586x.c, line 373](https://github.com/torvalds/linux/blob/v7.2-rc5/drivers/mfd/tps6586x.c#L373):

```c
ret = request_threaded_irq(irq, NULL, tps6586x_irq,
                           IRQF_ONESHOT, "tps6586x", tps6586x);
```

- `handler = NULL` — the kernel installs `irq_default_primary_handler`, which simply returns `IRQ_WAKE_THREAD`.
- `thread_fn = tps6586x_irq` — the actual work runs in a kernel thread (`irq/<N>-tps6586x`).
- `IRQF_ONESHOT` — the interrupt line stays masked until the threaded handler completes. This is essential because the PMIC's interrupt line is level-triggered. If the line were unmasked before the I2C read clears the interrupt condition, the GIC would immediately re-signal the interrupt, creating an infinite loop.

### Minimal Working Module: request_irq + free_irq

The following loadable kernel module demonstrates the complete registration and unregistration lifecycle for a shared interrupt. It registers on IRQ 19 (overridable via `module_param`), increments a counter on each invocation, and properly cleans up on unload:

```c
/* day33/19 — minimal shared IRQ observer module */
#include <linux/module.h>
#include <linux/init.h>
#include <linux/interrupt.h>

#define SHARED_IRQ 19
static int irq = SHARED_IRQ, my_dev_id, irq_counter = 0;
module_param(irq, int, S_IRUGO);   /* override IRQ at insmod time */

static irqreturn_t my_interrupt(int irq, void *dev_id)
{
    irq_counter++;
    pr_info("In the ISR: counter = %d\n", irq_counter);
    return IRQ_NONE;   /* observing only — interrupt belongs to real owner */
}

static int __init my_init(void)
{
    if (request_irq(irq, my_interrupt, IRQF_SHARED, "my_interrupt", &my_dev_id)) {
        pr_info("Failed to reserve irq %d\n", irq);
        return -1;
    }
    pr_info("Successfully loading ISR handler\n");
    return 0;
}

static void __exit my_exit(void)
{
    synchronize_irq(irq);          /* wait for any in-flight handler */
    free_irq(irq, &my_dev_id);    /* dev_id must match what was passed to request_irq */
    pr_info("Successfully unloading, irq_counter = %d\n", irq_counter);
}

MODULE_LICENSE("GPL");
module_init(my_init);
module_exit(my_exit);
```

Key points in this module:
- `&my_dev_id` is passed as the `dev_id` cookie — the same pointer is used in both `request_irq()` and `free_irq()`. The kernel uses it as the lookup key to find this specific `irqaction` in the chain.
- `IRQF_SHARED` requires a non-NULL `dev_id`. The kernel enforces this: `if ((irqflags & IRQF_SHARED) && !dev_id) return -EINVAL;`
- `synchronize_irq()` before `free_irq()` ensures the handler is not executing on any CPU at the moment the module is unloaded. Skipping it would be a race condition.
- The handler returns `IRQ_NONE` because it does not own this interrupt — it is just observing. On a real shared line the other device's handler will return `IRQ_HANDLED`.

### Common Bug: IRQF_SHARED With NULL dev_id

The following module is intentionally broken — it passes `NULL` as `dev_id` on a shared interrupt line:

```c
/* day34/8 — BROKEN: IRQF_SHARED + NULL dev_id, request_irq returns -EINVAL */
static int __init my_init(void)
{
    if (request_irq(irq, my_interrupt, IRQF_SHARED, "my_interrupt", NULL)) {
        pr_info("Failed to reserve irq %d\n", irq);   /* ← this path is taken */
        return -1;
    }
    ...
}
```

`request_threaded_irq()` checks at [kernel/irq/manage.c](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/irq/manage.c):

```c
if ((irqflags & IRQF_SHARED) && !dev_id)
    return -EINVAL;
```

The registration fails before `__setup_irq()` is even called. The module's `my_init()` will print "Failed to reserve irq" and return `-1`, causing `insmod` to report an error. This is the most common mistake when first using shared interrupts.

### One Handler Registered on Multiple IRQ Lines

A single handler function can be registered on more than one IRQ line by calling `request_irq()` multiple times with different IRQ numbers but the same `dev_id`:

```c
/* day34/9 — same handler on irq1=12 and irq2=1 */
static int irq1 = 12, irq2 = 1, dev_id;

static irqreturn_t my_interrupt(int irq, void *dev_id)
{
    pr_info("irq:%d\t dev_id:%02x\n", irq, *(int *)dev_id);
    return IRQ_NONE;
}

static int __init my_init(void)
{
    dev_id = 0x1234;
    if (request_irq(irq1, my_interrupt, IRQF_SHARED, "my_interrupt", &dev_id))
        return -1;
    if (request_irq(irq2, my_interrupt, IRQF_SHARED, "my_interrupt", &dev_id))
        return -1;
    return 0;
}

static void __exit my_exit(void)
{
    synchronize_irq(irq1);
    synchronize_irq(irq2);
    free_irq(irq1, &dev_id);
    free_irq(irq2, &dev_id);
}
```

When `my_interrupt` fires, the `irq` argument tells it which line triggered — the same `dev_id` is passed in both cases, so the handler can use the `irq` number to distinguish which device needs servicing. `free_irq()` must be called once per `request_irq()` call, and `synchronize_irq()` must be called for each line separately.

---

## Shared Interrupts: How Drivers Identify Their Device

When multiple devices share a single interrupt line, the kernel calls **every** handler registered on that line. The dispatch loop lives in **`__handle_irq_event_percpu()`** at [kernel/irq/handle.c, lines 185–240](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/irq/handle.c#L185-L240):

```c
irqreturn_t __handle_irq_event_percpu(struct irq_desc *desc)
{
    irqreturn_t retval = IRQ_NONE;
    struct irqaction *action;

    for_each_action_of_desc(desc, action) {
        irqreturn_t res;
        res = action->handler(irq, action->dev_id);

        switch (res) {
        case IRQ_WAKE_THREAD:
            __irq_wake_thread(desc, action);
            break;
        default:
            break;
        }
        retval |= res;
    }
    return retval;
}
```

Every handler in the chain is called regardless of what prior handlers returned. The return values are OR'd together. If no handler claims the interrupt (all return `IRQ_NONE`), the spurious interrupt detector increments its counter.

The critical question for each handler is: **was this interrupt generated by my device, or by one of the other devices sharing this line?** The answer always involves reading a hardware status register on the device itself. There is no software-level mechanism to answer this question — the driver must ask its own hardware.

Here is how real drivers do it:

### Example: Intel e100 (Ethernet)

From [drivers/net/ethernet/intel/e100.c, lines 2193–2219](https://github.com/torvalds/linux/blob/v7.2-rc5/drivers/net/ethernet/intel/e100.c#L2193-L2219):

```c
static irqreturn_t e100_intr(int irq, void *dev_id)
{
    struct net_device *netdev = dev_id;
    struct nic *nic = netdev_priv(netdev);
    u8 stat_ack = ioread8(&nic->csr->scb.stat_ack);

    if (stat_ack == stat_ack_not_ours ||
        stat_ack == stat_ack_not_present)
        return IRQ_NONE;

    iowrite8(stat_ack, &nic->csr->scb.stat_ack);
    /* ... handle interrupt ... */
    return IRQ_HANDLED;
}
```

The driver reads the NIC's **SCB Status/Ack register**. If it reads `stat_ack_not_ours` (no pending interrupt bits), the interrupt came from another device on the shared line, and the handler returns `IRQ_NONE`.

### Example: Realtek 8139 (Ethernet)

From [drivers/net/ethernet/realtek/8139too.c, lines 2139–2190](https://github.com/torvalds/linux/blob/v7.2-rc5/drivers/net/ethernet/realtek/8139too.c#L2139-L2190):

```c
static irqreturn_t rtl8139_interrupt(int irq, void *dev_instance)
{
    struct net_device *dev = dev_instance;
    struct rtl8139_private *tp = netdev_priv(dev);
    u16 status = RTL_R16(IntrStatus);

    if (unlikely((status & rtl8139_intr_mask) == 0))
        goto out;

    /* ... handle interrupt ... */
}
```

The driver reads the **IntrStatus register** and ANDs it with the interrupt mask. If the result is zero, no interrupt bits are pending for this device.

The universal pattern is: **read a hardware status register → check if any interrupt-pending bits are set → return `IRQ_NONE` if not → service and return `IRQ_HANDLED` if yes.**

### Shared Interrupt Dispatch — Universal Pattern

```
 IRQ fires on shared line (e.g., IRQ 42)
          │
          ▼
 ┌──────────────────────────────────────┐
 │ Kernel calls EVERY handler on chain  │
 └───────────────────┬──────────────────┘
                     │
          ┌──────────┼──────────────────────┐
          ▼          ▼                      ▼
    Handler A     Handler B             Handler C
       │              │                     │
       ▼              ▼                     ▼
  Read device    Read device           Read device
  status reg     status reg            status reg
       │              │                     │
       ▼              ▼                     ▼
  ┌─────────┐   ┌─────────┐           ┌─────────┐
  │Bits set?│   │Bits set?│           │Bits set?│
  └──┬───┬──┘   └──┬───┬──┘           └──┬───┬──┘
     │   │         │   │                  │   │
    No  Yes       No  Yes                No  Yes
     │   │         │   │                  │   │
     ▼   ▼         ▼   ▼                  ▼   ▼
  IRQ_  IRQ_    IRQ_  IRQ_             IRQ_  IRQ_
  NONE  HANDLED NONE  HANDLED          NONE  HANDLED
     │   │         │   │                  │   │
     └───┴─────────┴───┴──────────────────┴───┘
                     │
                     ▼
          retval = A | B | C   (OR'd together)
```

---

## Unregistering an Interrupt Handler

A driver removes its interrupt handler by calling **`free_irq()`**, defined at [kernel/irq/manage.c, lines 2006–2029](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/irq/manage.c#L2006-L2029). The function takes the IRQ number and the `dev_id` that was passed to `request_irq()`:

```c
const void *free_irq(unsigned int irq, void *dev_id)
```

Internally, **`__free_irq()`** at [kernel/irq/manage.c, lines 1859–1989](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/irq/manage.c#L1859-L1989) walks the linked list of `irqaction` structures, searching by `dev_id`:

```c
action_ptr = &desc->action;
for (;;) {
    action = *action_ptr;
    if (!action) {
        WARN(1, "Trying to free already-free IRQ %d\n", irq);
        return NULL;
    }
    if (action->dev_id == dev_id)
        break;
    action_ptr = &action->next;
}
*action_ptr = action->next;   /* unlink from the chain */
```

After unlinking:

1. If this was the **last handler** on the line (`!desc->action` after removal), the function calls `irq_shutdown()` to disable the IRQ at the hardware level, `irq_domain_deactivate_irq()` to deactivate it in the irq domain hierarchy, and `irq_release_resources()` to release chip-level resources.

2. It calls **`__synchronize_irq()`** — this is critical. It waits for any currently-executing hardirq handler to finish (by spinning on the `IRQD_IRQ_INPROGRESS` flag) and waits for any active threaded handlers to complete (by sleeping on `desc->wait_for_threads`). This guarantees that by the time `free_irq()` returns, no instance of the handler is running on any CPU, and no future instance will be invoked.

3. If the handler had a kernel thread, `kthread_stop_put()` stops and releases it.

**`free_irq()` must not be called from interrupt context** — it may sleep while waiting for threads to finish, and the function includes a `WARN(in_interrupt(), ...)` to catch this mistake.

### Unregistration Flow

```
 Driver calls free_irq(irq, dev_id)
          │
          ▼
 ┌────────────────────────────────────────────────────────────────┐
 │ free_irq()   kernel/irq/manage.c:2006                         │
 │   mutex_lock(&desc->request_mutex)                             │
 │   chip_bus_lock(desc)                                          │
 └──────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
 ┌────────────────────────────────────────────────────────────────┐
 │ __free_irq()   kernel/irq/manage.c:1859                       │
 │                                                                │
 │   Walk desc->action linked list, match by dev_id:             │
 │                                                                │
 │   action_ptr = &desc->action                                  │
 │   for (;;) {                                                   │
 │       action = *action_ptr                                    │
 │       if (action->dev_id == dev_id) break;  ← found it        │
 │       action_ptr = &action->next;           ← keep walking    │
 │   }                                                            │
 │   *action_ptr = action->next;               ← unlink          │
 └──────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
                 ┌────────────────────┐
                 │ Last handler       │
                 │ on this line?      │
                 └───┬──────────┬─────┘
                     │          │
                    Yes         No
                     │          │
                     ▼          │
          ┌──────────────────┐  │
          │ irq_shutdown()   │  │
          │ (mask at GIC)    │  │
          │                  │  │
          │ irq_domain_      │  │
          │ deactivate_irq() │  │
          │                  │  │
          │ irq_release_     │  │
          │ resources()      │  │
          └────────┬─────────┘  │
                   │            │
                   │◄───────────┘
                   ▼
 ┌────────────────────────────────────────────────────────────────┐
 │ __synchronize_irq()                                            │
 │                                                                │
 │   ① Spin on IRQD_IRQ_INPROGRESS     (wait for hardirq)        │
 │   ② Check IRQCHIP_STATE_ACTIVE      (wait for HW to settle)   │
 │   ③ Sleep on wait_for_threads       (wait for threaded         │
 │      until threads_active == 0        handlers to finish)      │
 │                                                                │
 │   Guarantee: NO handler instance running on ANY CPU            │
 └──────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
 ┌────────────────────────────────────────────────────────────────┐
 │ If handler had kernel thread:                                  │
 │   kthread_stop_put(action->thread)                             │
 │                                                                │
 │ kfree(action)                                                  │
 │ return action->dev_id to caller                                │
 └────────────────────────────────────────────────────────────────┘
```

---

## From Registration to Execution: How a Device Interrupt Is Handled

After a driver calls `request_irq()` and the handler is linked into the `irq_desc->action` chain, the next question is: what exactly happens when the device generates an interrupt? The path from hardware signal to driver handler involves the GIC, the CPU exception mechanism, the kernel's entry code, and several layers of the generic IRQ framework. Here is the complete end-to-end chain on AArch64 with GICv3:

```
 ① Device asserts interrupt line
           │
           ▼
 ② GIC Distributor receives the signal
    GICD_IROUTER determines target CPU
           │
           ▼
 ③ GIC CPU Interface signals IRQ to the PE
    CPU sees IRQ pending, checks PSTATE.I
           │
           ▼
 ④ CPU takes exception to EL1 vector table
    Branches to el1h_64_irq or el0_64_irq (depending on source EL)
           │
           ▼
 ⑤ el1_interrupt() / el0_interrupt()                    entry-common.c
    ├→ write_sysreg(DAIF_PROCCTX_NOIRQ, daif)          mask IRQ+FIQ in PSTATE
    ├→ irq_enter_rcu()                                  preempt_count += HARDIRQ_OFFSET
    ├→ do_interrupt_handler(regs, handle_arch_irq)
    │    └→ call_on_irq_stack()                         switch to per-CPU IRQ stack
    │         └→ gic_handle_irq(regs)                   ⑥ GIC driver entry
    │
    ⑥ gic_handle_irq()                                  irq-gic-v3.c:915
    ├→ irqnr = gic_read_iar()                          read ICC_IAR1_EL1 (acknowledge)
    ├→ gic_complete_ack(irqnr)                          write ICC_EOIR1_EL1 (priority drop)
    └→ generic_handle_domain_irq(domain, irqnr)        hwirq → virq → irq_desc
         │  [see "Getting irq_desc when IRQ fires" below]
         └→ desc->handle_irq(desc)                     ⑦ call flow handler
              │
              ⑦ handle_fasteoi_irq(desc)                chip.c:740
              ├→ [if ONESHOT] mask_irq(desc)            mask at GIC before handler
              ├→ handle_irq_event(desc)                 ⑧ dispatch to drivers
              │    ├→ set IRQD_IRQ_INPROGRESS
              │    ├→ raw_spin_unlock(&desc->lock)      drop lock during handler
              │    ├→ __handle_irq_event_percpu(desc)
              │    │    └→ for each action in chain:
              │    │         action->handler(irq, action->dev_id)  ← DRIVER HANDLER
              │    │         [if IRQ_WAKE_THREAD] wake handler thread
              │    ├→ raw_spin_lock(&desc->lock)
              │    └→ clear IRQD_IRQ_INPROGRESS
              └→ cond_unmask_eoi_irq()                  EOI + unmask (if not ONESHOT)
    │
    ├→ irq_exit_rcu()                                   preempt_count -= HARDIRQ_OFFSET
    │    └→ [if softirqs pending] invoke_softirq()
    └→ arm64_exit_to_{kernel,user}_mode(regs)           return to interrupted code
```

### Getting irq_desc When an IRQ Fires

When the GIC delivers an interrupt, the kernel has the **hardware IRQ number** (`hwirq` — the GIC INTID read from `ICC_IAR1_EL1`) but needs the **`irq_desc`** to invoke the flow handler. The translation is a two-step lookup:

```c
/* kernel/irq/irqdomain.c */
int generic_handle_domain_irq(struct irq_domain *domain, unsigned int hwirq)
{
    return handle_irq_desc(irq_resolve_mapping(domain, hwirq));
}

struct irq_desc *irq_resolve_mapping(struct irq_domain *domain,
                                      irq_hw_number_t hwirq)
{
    /* Step 1: hwirq (GIC INTID) → Linux virq number */
    unsigned int virq = irq_find_mapping(domain, hwirq);

    /* Step 2: Linux virq → irq_desc (same radix tree as at registration) */
    return irq_to_desc(virq);
}
```

```
 GIC fires INTID 79  (hardware number inside the GIC Distributor)
         │
         ▼
 gic_read_iar()  →  hwirq = 79
         │
         ▼
 Step 1: irq_find_mapping(gic_domain, 79)
         │  looks up the IRQ domain's reverse mapping
         │  (linear map for INTIDs < 256, radix tree for larger)
         ▼
 virq = 42   (Linux IRQ number assigned when GIC domain was mapped at boot)
         │
         ▼
 Step 2: irq_to_desc(42)
         │  radix_tree_lookup(&irq_desc_tree, 42)
         │  same descriptor that was registered into during request_irq()
         ▼
 struct irq_desc *desc
         │
         ▼
 handle_irq_desc(desc)
   → desc->handle_irq(desc)     ← handle_fasteoi_irq for GICv3 SPIs
       → handle_irq_event(desc)
           → action->handler(irq, dev_id)  ← your driver ISR
```

The separation of `hwirq` and `virq` exists because multiple irqchip layers can sit between a device and the GIC (e.g., a GPIO controller behind a GIC). Each layer has its own IRQ domain, and `irq_find_mapping` resolves through the correct one. The `virq` is what the driver knows (received at `request_irq()` time from the platform), and the `irq_desc` is always found via `virq`, never via `hwirq` directly.

### Hardirq and Softirq Lifecycle During Interrupt Handling

The following diagram shows the complete lifecycle of an interrupt on a single CPU, highlighting exactly when hardirq context begins and ends, when softirq processing kicks in, and what can preempt what:

```
 TIME ─────────────────────────────────────────────────────────────────────────►

 ╔═══════════════════════════════════════════════════════════════════════════════╗
 ║                        PROCESS CONTEXT                                      ║
 ║  Task "myapp" running (in_task()=true, preempt_count=0)                     ║
 ║  Interrupts: ENABLED    Can sleep: YES    current = &task_struct(myapp)      ║
 ╚════════════════╤════════════════════════════════════════════════════════════╝
                  │
                  │  ◄── IRQ fires, CPU takes exception to EL1
                  │      Hardware saves PSTATE→SPSR_EL1, PC→ELR_EL1
                  │
 ╔════════════════╧═════════════════════════════════════════════════════════════╗
 ║  ▐█▌  HARDIRQ CONTEXT   (in_hardirq()=true)                                ║
 ║  ▐█▌                                                                        ║
 ║  ▐█▌  Interrupts: DISABLED on local CPU (PSTATE.I=1, PSTATE.F=1)           ║
 ║  ▐█▌  Can sleep: NO       Can be preempted: NO                              ║
 ║  ▐█▌  preempt_count: += HARDIRQ_OFFSET (0x00010000)                        ║
 ║  ▐█▌  current: still &task_struct(myapp) — BORROWED, not owned              ║
 ║  ▐█▌  Stack: switched to per-CPU IRQ stack (16 KB)                          ║
 ║  ▐█▌                                                                        ║
 ║  ▐█▌  ┌─────────────────────────────────────────────────────────────┐       ║
 ║  ▐█▌  │ irq_enter_rcu()         preempt_count += HARDIRQ_OFFSET    │       ║
 ║  ▐█▌  │                                                             │       ║
 ║  ▐█▌  │ gic_handle_irq()        read IAR, priority drop (EOI)       │       ║
 ║  ▐█▌  │   │                                                         │       ║
 ║  ▐█▌  │   ├→ handle_fasteoi_irq()   (flow handler)                 │       ║
 ║  ▐█▌  │   │    │                                                    │       ║
 ║  ▐█▌  │   │    ├→ [ONESHOT] mask_irq(desc)                         │       ║
 ║  ▐█▌  │   │    │                                                    │       ║
 ║  ▐█▌  │   │    ├→ handle_irq_event()                               │       ║
 ║  ▐█▌  │   │    │    set IRQD_IRQ_INPROGRESS                        │       ║
 ║  ▐█▌  │   │    │    raw_spin_unlock(&desc->lock)                   │       ║
 ║  ▐█▌  │   │    │    ┌──────────────────────────────────────┐       │       ║
 ║  ▐█▌  │   │    │    │ __handle_irq_event_percpu()          │       │       ║
 ║  ▐█▌  │   │    │    │  for each action:                    │       │       ║
 ║  ▐█▌  │   │    │    │    action->handler(irq, dev_id)      │       │       ║
 ║  ▐█▌  │   │    │    │    ↳ DRIVER ISR RUNS HERE            │       │       ║
 ║  ▐█▌  │   │    │    │    if IRQ_WAKE_THREAD:               │       │       ║
 ║  ▐█▌  │   │    │    │      wake_up_process(action->thread) │       │       ║
 ║  ▐█▌  │   │    │    └──────────────────────────────────────┘       │       ║
 ║  ▐█▌  │   │    │    raw_spin_lock(&desc->lock)                    │       ║
 ║  ▐█▌  │   │    │    clear IRQD_IRQ_INPROGRESS                     │       ║
 ║  ▐█▌  │   │    │                                                    │       ║
 ║  ▐█▌  │   │    └→ cond_unmask_eoi_irq()   EOI + unmask             │       ║
 ║  ▐█▌  │   │       (unless ONESHOT — stays masked until thread)      │       ║
 ║  ▐█▌  │                                                             │       ║
 ║  ▐█▌  │ irq_exit_rcu()         preempt_count -= HARDIRQ_OFFSET    │       ║
 ║  ▐█▌  │   in_interrupt() now false                                  │       ║
 ║  ▐█▌  │   local_softirq_pending() ? ───────────────────────┐       │       ║
 ║  ▐█▌  └─────────────────────────────────────────────────────│───────┘       ║
 ╚════════════════╤════════════════════════════════════════════│════════════════╝
                  │                                            │
                  │                    Yes, softirqs pending    │
                  │                                            ▼
 ╔════════════════╧═══════════════════════════════════════════════════════════════╗
 ║  ░░░  SOFTIRQ CONTEXT   (in_serving_softirq()=true)                          ║
 ║  ░░░                                                                          ║
 ║  ░░░  Interrupts: ENABLED on local CPU  (local_irq_enable() called)          ║
 ║  ░░░  Can sleep: NO        Can be preempted by hardirq: YES                   ║
 ║  ░░░  preempt_count: += SOFTIRQ_OFFSET (0x00000100)                          ║
 ║  ░░░  current: still &task_struct(myapp) — BORROWED                           ║
 ║  ░░░  Stack: still on per-CPU IRQ stack or task stack                         ║
 ║  ░░░                                                                          ║
 ║  ░░░  ┌────────────────────────────────────────────────────────────┐          ║
 ║  ░░░  │ handle_softirqs()       kernel/softirq.c:579              │          ║
 ║  ░░░  │                                                            │          ║
 ║  ░░░  │   softirq_handle_begin()   preempt_count += SOFTIRQ_OFFSET│          ║
 ║  ░░░  │   set_softirq_pending(0)   clear pending bits              │          ║
 ║  ░░░  │   local_irq_enable()       ◄── INTERRUPTS RE-ENABLED      │          ║
 ║  ░░░  │                                                            │          ║
 ║  ░░░  │   while (pending) {                                        │          ║
 ║  ░░░  │     h->action()     ← run softirq handler                 │          ║
 ║  ░░░  │                       (NET_RX, TIMER, TASKLET, etc.)       │          ║
 ║  ░░░  │     ┌──────────────────────────────────────────┐          │          ║
 ║  ░░░  │     │ ◄── A NEW HARDIRQ CAN PREEMPT HERE ──►  │          │          ║
 ║  ░░░  │     │ Hardirq runs, returns, softirq resumes   │          │          ║
 ║  ░░░  │     └──────────────────────────────────────────┘          │          ║
 ║  ░░░  │   }                                                        │          ║
 ║  ░░░  │                                                            │          ║
 ║  ░░░  │   local_irq_disable()      ◄── INTERRUPTS DISABLED AGAIN  │          ║
 ║  ░░░  │   softirq_handle_end()     preempt_count -= SOFTIRQ_OFFSET│          ║
 ║  ░░░  │                                                            │          ║
 ║  ░░░  │   If more softirqs raised (>10 restarts or >2ms):         │          ║
 ║  ░░░  │     wakeup_softirqd()  → defer to ksoftirqd thread        │          ║
 ║  ░░░  └────────────────────────────────────────────────────────────┘          ║
 ╚════════════════╤══════════════════════════════════════════════════════════════╝
                  │
                  │  ◄── Return from exception (eret)
                  │
 ╔════════════════╧════════════════════════════════════════════════════════════╗
 ║                        PROCESS CONTEXT (resumed)                            ║
 ║  Task "myapp" continues (in_task()=true, preempt_count=0)                   ║
 ║  Interrupts: ENABLED    Can sleep: YES                                      ║
 ╚═════════════════════════════════════════════════════════════════════════════╝
```

### Hardirq vs. Softirq: Preemption Hierarchy

```
                    PREEMPTION HIERARCHY
                    ════════════════════

  ┌─────────────┐   can preempt    ┌─────────────┐   can preempt    ┌───────────────┐
  │    NMI      │ ──────────────→  │   Hardirq   │ ──────────────→  │    Softirq    │
  │ (pseudo)    │                  │             │                  │               │
  │ Priority    │                  │ PSTATE.I=1  │                  │ PSTATE.I=0    │
  │ 0x80        │                  │ on local    │                  │ on local      │
  │             │                  │ CPU         │                  │ CPU           │
  └─────────────┘                  └─────────────┘                  └───────┬───────┘
                                                                           │
                                                                   can preempt
                                                                           │
                                                                           ▼
                                                                   ┌───────────────┐
                                                                   │   Process      │
                                                                   │   Context      │
                                                                   │               │
                                                                   │ Schedulable,  │
                                                                   │ can sleep     │
                                                                   └───────────────┘

 ═══════════════════════════════════════════════════════════════════════════════
  preempt_count bits after each transition:
 ═══════════════════════════════════════════════════════════════════════════════

  Process ctx:    0x00000000   (all clear — in_task()=true)
                      │
                      │ IRQ fires
                      ▼
  Hardirq ctx:    0x000100xx   HARDIRQ bits [19:16] set
                      │         (in_hardirq()=true, in_task()=false)
                      │
                      │ irq_exit, softirq pending
                      ▼
  Softirq ctx:    0x00000100   SOFTIRQ bit [8] set, HARDIRQ cleared
                      │         (in_serving_softirq()=true, in_task()=false)
                      │
                      │ softirq_handle_end
                      ▼
  Process ctx:    0x00000000   (back to normal)
```

Several details in this path deserve emphasis:

**Step 6 — IAR read and EOI write.** When `gic_handle_irq()` reads `ICC_IAR1_EL1` at [arch/arm64/include/asm/arch_gicv3.h, lines 35–42](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/arch_gicv3.h#L35-L42), the GIC acknowledges the interrupt and returns the hardware IRQ number (INTID). The kernel immediately writes `ICC_EOIR1_EL1` via `gic_complete_ack()` — in GICv3's **EOI mode 1**, this is a **priority drop** only, not a deactivation. The interrupt remains active (preventing the same priority from re-interrupting) until explicitly deactivated later. This split between priority drop and deactivation allows the kernel to drop the interrupt's priority early (so higher-priority interrupts can preempt) while still keeping the interrupt active until the handler finishes.

**Step 7 — Flow handler.** `handle_fasteoi_irq` is the flow handler for GICv3 SPIs, set during irq domain mapping at [drivers/irqchip/irq-gic-v3.c, lines 1567–1568](https://github.com/torvalds/linux/blob/v7.2-rc5/drivers/irqchip/irq-gic-v3.c#L1567-L1568). For normal (non-ONESHOT) interrupts, it does **not** mask the line before calling the handler — the GIC's EOI mode handles this transparently. For `IRQF_ONESHOT` interrupts, it explicitly masks the line (writes to `GICD_ICENABLER`) before the handler runs, and the line stays masked until the threaded handler finishes.

**Step 8 — Lock drop during handler execution.** `handle_irq_event()` at [kernel/irq/handle.c, line 255](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/irq/handle.c#L255) drops `desc->lock` before calling the handlers and reacquires it afterward. This means driver handlers run **without** the descriptor lock — other CPUs can concurrently call `disable_irq()`, change affinity, or register/remove handlers. The `IRQD_IRQ_INPROGRESS` flag is set before the lock drop so that `synchronize_irq()` on another CPU can detect that a handler is running.

**The `handle_arch_irq` registration.** `gic_handle_irq` is registered as the global `handle_arch_irq` callback during GIC initialization via `set_handle_irq()` at [drivers/irqchip/irq-gic-v3.c, line 2045](https://github.com/torvalds/linux/blob/v7.2-rc5/drivers/irqchip/irq-gic-v3.c#L2045). The function pointer is stored in [arch/arm64/kernel/irq.c, line 97](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/irq.c#L97) and passed to the entry code at step 5.

### Flow Handler Selection: Why handle_fasteoi_irq and What Else Exists

`desc->handle_irq` — the **flow handler** — is not a kernel-wide constant. It is assigned by the irqchip driver at the moment it maps a hardware interrupt into the Linux IRQ domain. On AArch64 with GICv3 the assignment happens in `gic_irq_domain_map()` at [drivers/irqchip/irq-gic-v3.c, lines 1549–1575](https://github.com/torvalds/linux/blob/v7.2-rc5/drivers/irqchip/irq-gic-v3.c#L1549-L1575):

```c
static int gic_irq_domain_map(struct irq_domain *d, unsigned int irq,
                               irq_hw_number_t hw)
{
    struct irq_chip *chip = &gic_chip;

    /* SGIs and PPIs live in the Redistributor — per-CPU */
    if (gic_irq_in_rdist(d, hw)) {
        irq_set_chip_and_handler(irq, chip,
                                 handle_percpu_devid_irq);
        irq_set_status_flags(irq, IRQ_NOAUTOEN | IRQ_PER_CPU |
                             IRQ_NOTHREAD | IRQ_NOPROBE |
                             IRQ_PERCPU_DEVID);
        return 0;
    }

    /* SPIs (and LPIs via ITS) go to the Distributor */
    irq_set_chip_and_handler(irq, chip, handle_fasteoi_irq);
    irq_set_probe(irq);
    irqd_set_single_target(irq_desc_get_irq_data(irq_to_desc(irq)));
    return 0;
}
```

The choice is determined entirely by the GIC's own architecture:

#### Why SPIs use handle_fasteoi_irq

GICv3 implements an **EOI model with split priority-drop and deactivation** (controlled by `GICD_CTLR.DS` and `ICC_CTLR_EL1.EOImode`). When the Linux GIC driver initialises it sets `EOImode=1`, which means:

```
ICC_IAR1_EL1 read  →  acknowledge + priority drop
                       (interrupt is now "active" inside GIC;
                        same-priority interrupts cannot preempt)
ICC_EOIR1_EL1 write →  deactivation only
                        (GIC releases the "active" slot)
```

Because the interrupt is held "active" inside the GIC from `IAR` read until `EOIR` write, the hardware **automatically prevents the same interrupt from firing again** while the handler runs. There is no need to mask the line at `GICD_ICENABLER` around the handler invocation. `handle_fasteoi_irq` exploits this: it calls the driver handlers without masking and issues EOI (deactivation) at the end via `chip->irq_eoi` → `gic_eoimode1_eoi_irq()`.

This contrasts with older designs where you had to mask-before-handle and unmask-after, because the controller had no concept of an "active" interrupt state.

#### Why PPIs and SGIs use handle_percpu_devid_irq

PPIs (Private Peripheral Interrupts, INTIDs 16–31) and SGIs (Software-Generated Interrupts, INTIDs 0–15) are **per-CPU by nature** — each CPU has its own private instance in its Redistributor. They cannot be shared across CPUs and need no SMP serialisation of `irq_desc`. `handle_percpu_devid_irq` skips `desc->lock` entirely and calls a per-CPU handler variant, which is both faster and correct for this topology.

#### All Flow Handlers Available on AArch64

The table below covers every flow handler a driver or irqchip on AArch64 might encounter. They are all defined in [kernel/irq/chip.c](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/irq/chip.c).

| Handler | Masking protocol | Used on AArch64 for |
|---------|-----------------|---------------------|
| **`handle_fasteoi_irq`** | No mask before handler; `chip->irq_eoi` after | GICv3 SPIs (all shared device interrupts) |
| **`handle_percpu_devid_irq`** | No `desc->lock`; per-CPU `chip->irq_eoi` | GICv3 PPIs and SGIs (timer, IPI, local devices) |
| **`handle_level_irq`** | Mask → handler → unmask (explicit `GICD_ICENABLER` / `GICD_ISENABLER`) | GICv2 SPIs; non-GIC controllers on AArch64 SoCs (e.g., Broadcom, Marvell) |
| **`handle_edge_irq`** | ACK immediately; never mask; set `IRQS_PENDING` if re-fires during handler | Edge-triggered GPIO lines; some SoC-local IRQ controllers |
| **`handle_simple_irq`** | No masking, no EOI, no lock — bare handler call | Virtual IRQs; IPI demux; chips that do all flow control themselves |
| **`handle_nested_irq`** | Wakes parent's threaded handler; runs in process context | GPIO controllers behind GIC (chained / cascaded IRQ domains) |
| **`handle_bad_irq`** | Logs "unexpected IRQ" and returns | Unmapped or spurious Linux IRQ numbers |
| **`handle_percpu_irq`** | Like `handle_percpu_devid_irq` but no per-CPU dev_id | Older per-CPU irqchip drivers |

#### How a Wrong Flow Handler Causes Silent Bugs

The flow handler choice is not advisory — a mismatch causes hard-to-diagnose failures:

```
 Level-triggered SPI with handle_edge_irq
 ─────────────────────────────────────────
 IRQ asserted (level HIGH)
   → handle_edge_irq ACKs and calls handler
   → handler clears device register → level goes LOW
   → no new edge occurs → IRQ never fires again
   → device stalls silently forever

 Edge-triggered line with handle_level_irq
 ──────────────────────────────────────────
 Edge arrives → handle_level_irq MASKS line
   → calls handler → handler finishes
   → handle_level_irq UNMASKs line
   → BUT the edge has already passed; GIC has no pending signal
   → if second edge arrived during mask window: dropped silently

 GICv3 SPI with handle_level_irq (less wrong, but wasteful)
 ───────────────────────────────────────────────────────────
 Works correctly: mask → handler → unmask
 BUT: two extra GIC register writes per interrupt
 AND: misses the EOI deactivation step → GIC's "active"
      slot remains occupied → same-priority interrupts blocked
      until the GIC times out internally
```

#### Flow Handler Assignment in Practice

```
 GICv3 IRQ domain map()
         │
         ├─ hwirq 0–15  (SGIs)   → handle_percpu_devid_irq
         │                          (per-CPU, no SMP lock)
         │
         ├─ hwirq 16–31 (PPIs)   → handle_percpu_devid_irq
         │    e.g., arch_timer (INTID 30), PMU (INTID 23)
         │
         ├─ hwirq 32–1019 (SPIs) → handle_fasteoi_irq
         │    e.g., UART, Ethernet, USB, GPIO-bank IRQs
         │
         └─ hwirq 8192+ (LPIs)   → handle_fasteoi_irq
              (MSI via ITS; same EOI model as SPIs)

 Non-GIC irqchip (GPIO controller behind GIC)
         │
         └─ parent domain: GIC SPI → handle_fasteoi_irq
            child  domain: GPIO pin → handle_nested_irq
                                      (or handle_edge_irq /
                                       handle_level_irq
                                       depending on chip)
```

---

## Masking and Unmasking: What It Means and Who Does It

The terms **masking** and **unmasking** refer to telling the interrupt controller (GIC) whether to forward a specific interrupt to the CPU. A **masked** interrupt is blocked at the GIC hardware level — the device can still assert its interrupt line and the interrupt can become **pending** in the distributor, but the GIC will not signal the CPU until the interrupt is **unmasked**. No interrupts are lost; they are deferred.

This is fundamentally different from **disabling interrupts on the CPU** (`local_irq_disable()`), which masks all interrupts at the processor level via `PSTATE.I`. Masking is per-interrupt-line; CPU-level disabling is per-CPU and affects all lines.

### How Masking Works at the GIC Level

On GICv3, each interrupt has an enable bit in the distributor. Two registers control it:

- **`GICD_ISENABLER`** (offset `0x0100`) — writing a 1-bit to a position **sets** (enables/unmasks) the corresponding interrupt. Defined at [include/linux/irqchip/arm-gic-v3.h, line 23](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/irqchip/arm-gic-v3.h#L23).
- **`GICD_ICENABLER`** (offset `0x0180`) — writing a 1-bit to a position **clears** (disables/masks) the corresponding interrupt. Defined at [include/linux/irqchip/arm-gic-v3.h, line 24](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/irqchip/arm-gic-v3.h#L24).

These are **set/clear** registers — writing a 1-bit to `ISENABLER` enables that interrupt, and writing a 1-bit to `ICENABLER` disables it. Writing a 0-bit has no effect. This design avoids read-modify-write races.

The kernel's GIC driver implements masking and unmasking as:

**`gic_mask_irq()`** at [drivers/irqchip/irq-gic-v3.c, lines 486–493](https://github.com/torvalds/linux/blob/v7.2-rc5/drivers/irqchip/irq-gic-v3.c#L486-L493):

```c
static void gic_mask_irq(struct irq_data *d)
{
    gic_poke_irq(d, GICD_ICENABLER);     /* write 1 to clear-enable register */
    if (gic_irq_in_rdist(d))
        gic_redist_wait_for_rwp();        /* wait for Redistributor (PPIs) */
    else
        gic_dist_wait_for_rwp();          /* wait for Distributor (SPIs) */
}
```

**`gic_unmask_irq()`** at [drivers/irqchip/irq-gic-v3.c, lines 510–513](https://github.com/torvalds/linux/blob/v7.2-rc5/drivers/irqchip/irq-gic-v3.c#L510-L513):

```c
static void gic_unmask_irq(struct irq_data *d)
{
    gic_poke_irq(d, GICD_ISENABLER);     /* write 1 to set-enable register */
}
```

Note that masking waits for the **Register Write Pending (RWP)** bit to clear — the GIC needs time to process the disable request, and the kernel must wait to ensure the mask takes effect before returning. Unmasking does not need this wait.

For **PPIs and SGIs** (per-CPU interrupts), the registers are in the **Redistributor** (`GICR_ICENABLER0` / `GICR_ISENABLER0`). For **SPIs** (shared peripheral interrupts), they are in the **Distributor**.

### Who Masks and When

The generic IRQ layer calls masking/unmasking through the `irq_chip` callbacks (`chip->irq_mask` and `chip->irq_unmask`), wrapped by **`mask_irq()`** and **`unmask_irq()`** at [kernel/irq/chip.c, lines 432–452](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/irq/chip.c#L432-L452). These functions also track the `IRQD_IRQ_MASKED` state flag.

Masking and unmasking happen in these situations:

| Who | When | Why |
|-----|------|-----|
| **`handle_fasteoi_irq`** | Before calling handler, if `IRQF_ONESHOT` | Keep line masked until threaded handler finishes. Prevents interrupt storm on level-triggered lines. |
| **`handle_fasteoi_irq`** | After handler returns, if IRQ is disabled or has no handlers | Mask to prevent re-signaling a dead or disabled line. |
| **`cond_unmask_eoi_irq`** | After handler returns, if not ONESHOT and not disabled | Unmask and send EOI so the GIC can deliver the next instance. |
| **`irq_thread_fn` / `irq_finalize_oneshot`** | After threaded handler completes | Unmask the ONESHOT line now that the thread has cleared the device condition. |
| **`disable_irq()` → `irq_disable()`** | When a driver disables an IRQ line | Mask the line so no CPU receives it. |
| **`enable_irq()` → `irq_startup()`** | When depth returns to zero | Unmask the line to resume delivery. |
| **`__setup_irq()` → `irq_startup()`** | First handler registered on a line | Unmask to begin delivery. |
| **`__free_irq()` → `irq_shutdown()`** | Last handler removed from a line | Mask because there are no handlers left. |

### Masking/Unmasking Decision Flow in handle_fasteoi_irq

```
 handle_fasteoi_irq(desc)
          │
          ▼
 ┌──────────────────────────┐
 │ Check desc state:        │
 │ IRQ disabled? No action? │
 │ In-progress on this CPU? │
 └───────────┬──────────────┘
             │
        ┌────┴─────┐
        │          │
      Normal     Bad state
        │          │
        │          ▼
        │    mask_irq(desc) + return
        │    (prevent further signaling)
        │
        ▼
 ┌──────────────────────────┐
 │ IRQF_ONESHOT set?        │
 └───────┬──────────┬───────┘
         │          │
        Yes         No
         │          │
         ▼          │
  mask_irq(desc)    │
  (write GICD_      │
   ICENABLER)       │
  Line stays masked │
  until thread done │
         │          │
         │◄─────────┘
         ▼
 ┌──────────────────────────┐
 │ handle_irq_event(desc)   │
 │   Call all handlers      │
 └───────────┬──────────────┘
             │
             ▼
 ┌──────────────────────────┐
 │ IRQF_ONESHOT?            │
 └───────┬──────────┬───────┘
         │          │
        Yes         No
         │          │
         ▼          ▼
  Line stays     cond_unmask_eoi_irq()
  MASKED         ├→ write GICD_ISENABLER (unmask)
  Thread will    └→ deactivate (EOI to GIC)
  unmask via          │
  irq_finalize_       │
  oneshot() when      │
  it completes        │
         │            │
         └────────────┘
```

The key insight is that **normal (non-ONESHOT) interrupts on GICv3 are not explicitly masked and unmasked around each handler invocation**. The GIC's EOI mode and priority-drop mechanism handle re-entrancy transparently — `handle_fasteoi_irq` simply calls the handler and then sends EOI. Only ONESHOT interrupts need explicit masking because the line must stay quiet until the threaded handler runs.

---

## IRQ Affinity and Balancing

On a multiprocessor system, each hardware interrupt is routed to a specific CPU. The kernel provides mechanisms to control and observe this routing, and userspace daemons (notably **`irqbalance`**) use these to distribute interrupt load across CPUs.

### How Affinity Works at the GIC Level

On AArch64 with GICv3, each **SPI** (Shared Peripheral Interrupt) has a 64-bit **GICD_IROUTER** register at offset `0x6000 + (intid × 8)` in the GIC Distributor's register space, defined in [include/linux/irqchip/arm-gic-v3.h, line 42](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/irqchip/arm-gic-v3.h#L42). This register holds the **MPIDR affinity** of the target CPU — the GIC reads it to decide which CPU (which Redistributor and CPU Interface) should receive the interrupt.

The function **`gic_set_affinity()`** at [drivers/irqchip/irq-gic-v3.c, lines 1428–1469](https://github.com/torvalds/linux/blob/v7.2-rc5/drivers/irqchip/irq-gic-v3.c#L1428-L1469) programs this register:

```c
static int gic_set_affinity(struct irq_data *d, const struct cpumask *mask_val,
                            bool force)
{
    unsigned int cpu;

    if (force)
        cpu = cpumask_first(mask_val);
    else
        cpu = cpumask_any_and(mask_val, cpu_online_mask);

    if (gic_irq_in_rdist(d))    /* SGIs/PPIs cannot be rerouted */
        return -EINVAL;

    enabled = gic_peek_irq(d, GICD_ISENABLER);
    if (enabled)
        gic_mask_irq(d);

    reg = gic_dist_base(d) + offset + (index * 8);
    val = gic_cpu_to_affinity(cpu);
    gic_write_irouter(val, reg);

    if (enabled)
        gic_unmask_irq(d);

    irq_data_update_effective_affinity(d, cpumask_of(cpu));
    return IRQ_SET_MASK_OK_DONE;
}
```

The function selects one CPU from the requested cpumask, converts its Linux CPU number to an MPIDR affinity value (using `gic_cpu_to_affinity()` at [drivers/irqchip/irq-gic-v3.c, lines 749–762](https://github.com/torvalds/linux/blob/v7.2-rc5/drivers/irqchip/irq-gic-v3.c#L749-L762)), and writes it to GICD_IROUTER. If the interrupt was enabled, it temporarily masks it during the reroute and unmasks afterward.

Key constraint: **only SPIs can be rerouted**. SGIs (0–15) and PPIs (16–31) live in the per-CPU Redistributor and are inherently bound to their CPU — `gic_irq_in_rdist()` returns true for them, and the function returns `-EINVAL`.

GICD_IROUTER bit 31 controls the routing mode: `GICD_IROUTER_SPI_MODE_ONE` (0, specific CPU) vs `GICD_IROUTER_SPI_MODE_ANY` (1, any participating PE). Linux always uses `SPI_MODE_ONE` — routing to a specific CPU.

### The Kernel Affinity API

```
 IRQ Affinity Control: Userspace → Kernel → Hardware
 ════════════════════════════════════════════════════

  Userspace                  Kernel                           Hardware (GICv3)
 ┌───────────────┐    ┌───────────────────────┐    ┌──────────────────────────┐
 │ echo "f" >    │    │ write_irq_affinity()  │    │                          │
 │ /proc/irq/N/  │───>│   kernel/irq/proc.c   │    │  GICD_IROUTER[N]        │
 │ smp_affinity  │    │     │                 │    │  (64-bit register per    │
 └───────────────┘    │     ▼                 │    │   SPI, holds target      │
                      │ irq_set_affinity()    │    │   CPU's MPIDR affinity)  │
 ┌───────────────┐    │     │                 │    │                          │
 │ irqbalance    │    │     ▼                 │    │  ┌─────────────────────┐ │
 │ daemon reads  │    │ irq_do_set_affinity() │───>│  │ 1. Mask interrupt   │ │
 │ /proc/irq/N/  │    │     │                 │    │  │ 2. Write IROUTER   │ │
 │ affinity_hint │    │     ▼                 │    │  │ 3. Unmask interrupt │ │
 └───────────────┘    │ gic_set_affinity()    │    │  └─────────────────────┘ │
                      └───────────────────────┘    └──────────────────────────┘
```

The call chain from the public API to the hardware is:

```
irq_set_affinity()                          kernel/irq/manage.c:481
  → __irq_set_affinity()                    kernel/irq/manage.c:462
    → irq_set_affinity_locked()             kernel/irq/manage.c:376
      → irq_try_set_affinity()
        → irq_do_set_affinity()             kernel/irq/manage.c:232
          → chip->irq_set_affinity()        → gic_set_affinity()
```

**`irq_do_set_affinity()`** at [kernel/irq/manage.c, lines 232–302](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/irq/manage.c#L232-L302) is the workhorse. It intersects the requested cpumask with `cpu_online_mask` (for safety), calls the chip's `irq_set_affinity` callback, and on success stores the new mask in `desc->irq_common_data.affinity`. For managed interrupts with CPU isolation enabled, it also intersects with the housekeeping cpumask to avoid routing I/O interrupts to isolated CPUs.

Drivers can set an **affinity hint** — a suggested cpumask — using `irq_set_affinity_hint()` at [kernel/irq/manage.c, line 504](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/irq/manage.c#L504). This does not change the affinity directly but is exposed to userspace via `/proc/irq/N/affinity_hint`, where `irqbalance` can read it and factor it into its decisions.

### The Userspace Interface

The `/proc/irq/` hierarchy is created by `register_irq_proc()` at [kernel/irq/proc.c, lines 332–385](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/irq/proc.c#L332-L385):

| File | Purpose |
|------|---------|
| `/proc/irq/N/smp_affinity` | Read/write the IRQ's CPU affinity as a hexadecimal cpumask. Writing `f` routes to CPUs 0–3. |
| `/proc/irq/N/smp_affinity_list` | Same, but in CPU-list format (`0-3,7`). More readable for large systems. |
| `/proc/irq/N/affinity_hint` | Read-only. The driver's suggested affinity. |
| `/proc/irq/N/effective_affinity` | Read-only. The actual CPU currently servicing the interrupt (may be a subset of the requested affinity). |
| `/proc/irq/N/node` | The NUMA node associated with the interrupt. |
| `/proc/irq/default_smp_affinity` | Global default affinity for newly allocated IRQs. |

Writing to `smp_affinity` is handled by `write_irq_affinity()` at [kernel/irq/proc.c, lines 137–177](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/irq/proc.c#L137-L177), which parses the cpumask, validates that it intersects `cpu_online_mask`, and calls `irq_set_affinity()`.

### /proc/interrupts — Observing Interrupt Distribution

The `/proc/interrupts` file is implemented by `irq_seq_show()` at [kernel/irq/proc.c, lines 539–608](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/irq/proc.c#L539-L608). For each IRQ, it prints:

```
  <irq>:  <count-cpu0>  <count-cpu1>  ...  <chip_name>  <hwirq>  <type>  <action_names>
```

On AArch64, **`arch_show_interrupts()`** at [arch/arm64/kernel/smp.c, lines 837–850](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/smp.c#L837-L850) appends IPI counts after the device IRQs — showing per-CPU counts for rescheduling IPIs (IPI0), call-function IPIs (IPI1), CPU stop (IPI2), timer (IPI4), IRQ work (IPI5), and others.

### Checking IRQ State on a Running System

The following commands let you observe interrupt routing and counts on a live kernel without any kernel modifications:

```bash
# Show per-CPU interrupt counts for every IRQ line
# Columns: IRQ  CPU0  CPU1  ...  chip  hwirq  type  handler-names
cat /proc/interrupts

# Example output on a 4-CPU AArch64 system:
#            CPU0       CPU1       CPU2       CPU3
#  27:      1024          0          0          0   GICv3  27 Level     arch_timer
#  42:       318        201        172        309   GICv3  79 Level     uart-pl011
#  65:      8821          0          0          0   GICv3 102 Edge      eth0

# Read the current affinity mask for IRQ 42 (hex cpumask)
cat /proc/irq/42/smp_affinity
# 0f   ← means CPUs 0–3 (bits 0–3 set)

# Same in list format (more readable on large systems)
cat /proc/irq/42/smp_affinity_list
# 0-3

# Read the ACTUAL CPU currently receiving IRQ 42
# (may differ from requested affinity if HW cannot honour it)
cat /proc/irq/42/effective_affinity
# 01   ← GIC actually routes it to CPU 0 only

# Move IRQ 42 to CPU 3 only (requires root)
echo 8 > /proc/irq/42/smp_affinity       # 0x8 = bit 3 = CPU 3
# or equivalently:
echo 3 > /proc/irq/42/smp_affinity_list

# Check driver affinity hint (set by driver, read-only)
cat /proc/irq/42/affinity_hint

# NUMA node for this IRQ (useful on NUMA systems)
cat /proc/irq/42/node

# Global default affinity for newly allocated IRQs
cat /proc/irq/default_smp_affinity
```

The `irqbalance` daemon reads `/proc/interrupts` periodically, detects per-CPU imbalances, and automatically writes new affinity masks to `/proc/irq/N/smp_affinity`. To see what `irqbalance` is doing in real time:

```bash
# Show irqbalance policy hints (if installed)
irqbalance --debug --oneshot

# Watch /proc/interrupts change over time (1-second refresh)
watch -n1 cat /proc/interrupts
```

### IRQ Balancing

The Linux kernel does **not** contain an interrupt balancer. Instead, it exposes all the data and control interfaces that a userspace daemon needs:

- `/proc/interrupts` — the daemon reads per-CPU counts to detect imbalance.
- `/proc/irq/N/smp_affinity` — the daemon writes new affinity masks to redistribute load.
- `/proc/irq/N/affinity_hint` — the daemon reads driver hints to make NUMA-aware decisions.
- `/proc/irq/N/node` — NUMA topology information.

The **`irqbalance`** daemon is the standard userspace solution. It periodically reads interrupt counts, identifies imbalances, and moves interrupts by writing to `smp_affinity`. It respects driver affinity hints and NUMA topology to keep interrupts close to the CPUs accessing the device's memory.

Interrupts marked with **`IRQF_NOBALANCING`** are excluded. When this flag is set, `__setup_irq()` calls `irqd_set(&desc->irq_data, IRQD_NO_BALANCING)` at [kernel/irq/manage.c, lines 1758–1761](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/irq/manage.c#L1758-L1761), and the `/proc` write handler rejects affinity changes for such IRQs.

---
