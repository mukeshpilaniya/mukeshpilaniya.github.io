---
title: Interrupts and Exceptions on AArch64
published: true
categories: [Interrupt]
tags: [interrupt]
---
# Interrupts and Exceptions on AArch64: From Hardware Signal to Kernel Handler

The AArch64 architecture handles interrupts and exceptions through a unified mechanism rooted in the concept of **exception levels**, a **fixed-layout vector table**, and a tightly specified set of system registers that the hardware manipulates automatically when an exception is taken. Unlike x86, where a numbered interrupt vector directly selects a handler from the IDT, AArch64 uses the *type* of the exception and the *level from which it was taken* to index into a compact vector table — and defers the identification of the specific interrupt source to software, which queries the interrupt controller afterward. This design reflects ARM's philosophy of keeping the CPU core simple and pushing policy into software and peripheral controllers like the GIC. This document walks through the complete exception and interrupt architecture on AArch64 as implemented in the Linux kernel, tracing every step from how the hardware classifies events, through the vector table layout and GIC internals, to the C-level dispatch functions that ultimately invoke driver handlers or resolve page faults.

---

## Table of Contents

1. [Interrupts vs. Exceptions on AArch64](#interrupts-vs-exceptions-on-aarch64)
2. [Exception Levels and Their Role](#exception-levels-and-their-role)
3. [The Exception Vector Table](#the-exception-vector-table)
4. [Synchronous Exceptions: How They Are Generated and Dispatched](#synchronous-exceptions-how-they-are-generated-and-dispatched)
5. [The GIC v3 in Detail](#the-gic-v3-in-detail)
6. [Complete Path: Device IRQ to Kernel Driver Handler](#device-irq-to-kernel-driver-handler)
7. [Complete Path: Page Fault (Software Exception) Compared to Device IRQ](#page-fault-software-exception)
8. [The kernel_entry and kernel_exit Macros](#the-kernel_entry-and-kernel_exit-macros)
9. [The IRQ Stack](#the-irq-stack)
10. [Pseudo-NMI: Non-Maskable Interrupts on AArch64](#pseudo-nmi-non-maskable-interrupts-on-aarch64)
11. [GIC Initialization: How It All Comes Together](#gic-initialization-how-it-all-comes-together)
12. [Summary](#summary)

---

## Interrupts vs. Exceptions on AArch64

The AArch64 architecture groups all deviations from normal instruction flow under the umbrella term **exception**. An exception is any event — hardware or software, synchronous or asynchronous — that causes the processor to save its current state and transfer control to a handler at a higher (or same) exception level. Within this broad category, the [ARM Architecture Reference Manual](https://support.arm.com/documentation/ihi0069/hb/) draws a fundamental distinction based on whether the event is tied to the instruction stream or arrives independently of it.

### Synchronous Exceptions

A **synchronous exception** is generated *because of* the instruction the CPU is currently executing or has just attempted to execute. The critical property is **reproducibility**: run the same instruction in the same state, and the same exception fires every time. The processor knows exactly which instruction caused it, and records a precise return address in **ELR_EL1** (Exception Link Register) along with a detailed syndrome in **ESR_EL1** (Exception Syndrome Register). Synchronous exceptions include data aborts (a load or store that hits an unmapped page), instruction aborts (a fetch from an invalid address), SVCs (system calls), undefined instructions, alignment faults, breakpoints, watchpoints, and single-step traps. The kernel uses the **Exception Class (EC)** field in ESR_EL1 (bits [31:26]) to distinguish between these — a 6-bit field that encodes dozens of different exception types, defined in [`arch/arm64/include/asm/esr.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/esr.h).

### Asynchronous Exceptions (Interrupts)

An **asynchronous exception** (in ARM terminology, simply an **interrupt**) has no relationship to the instruction currently executing. It arrives from an external source — a device, another CPU, or an internal error reporting mechanism — at whatever point the processor happens to be in its instruction stream. AArch64 defines three types of asynchronous exceptions:

| Type | Description | Mask Bit |
|------|-------------|----------|
| **IRQ** | The standard hardware interrupt line. This is what peripheral devices use (via the GIC) to signal the CPU. It is **maskable**. | `PSTATE.I` |
| **FIQ** | The Fast Interrupt Request. A second, independent interrupt line. In practice, on systems running Linux under a hypervisor or secure monitor, FIQs are often routed to EL3 (the secure world) or used for pseudo-NMI implementations. The Linux kernel registers a separate handler for FIQs via `handle_arch_fiq`, declared in [`arch/arm64/kernel/irq.c`, line 98](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/irq.c#L98). | `PSTATE.F` |
| **SError** | System Error — an asynchronous abort, typically caused by an uncorrectable hardware fault such as a poisoned cache line or an external memory error. The AArch64 equivalent of x86's Machine Check Exception, treated as NMI-like events in the kernel. | `PSTATE.A` |

The processor itself makes no distinction between "this is a device interrupt" and "this is a page fault" at the fundamental mechanism level — both cause it to save state, switch to the exception handler, and branch to the vector table. The difference is *where in the vector table* it branches, *what system registers* contain the syndrome information, and *how the kernel handler identifies the source* after entry.

```
                         AArch64 Exception Taxonomy
                         ==========================
                                    │
                 ┌──────────────────┴──────────────────┐
                 │                                     │
        Synchronous Exceptions              Asynchronous Exceptions
        (caused by instruction)              (external events)
                 │                                     │
    ┌────────────┼────────────┐           ┌────────────┼────────────┐
    │            │            │           │            │            │
  Data/Insn    SVC          Debug       IRQ          FIQ         SError
  Aborts    (syscall)    (BRK/step)  (maskable)  (maskable)    (maskable)
    │                        │         PSTATE.I    PSTATE.F     PSTATE.A
    │                        │
 Page Fault              Breakpoint
 Alignment               Watchpoint
 Permission              Single-step
 Translation
```

---

## Exception Levels and Their Role

AArch64 defines four **exception levels** (EL0 through EL3), each representing a different privilege tier. This hierarchy is central to how exceptions are routed and handled.

```
  ┌─────────────────────────────────────────────────────────────┐
  │  EL3  │  Secure Monitor Firmware (ARM TF-A)                 │  Highest
  ├───────┼─────────────────────────────────────────────────────┤  privilege
  │  EL2  │  Hypervisor (KVM)                                   │
  ├───────┼─────────────────────────────────────────────────────┤
  │  EL1  │  OS Kernel (Linux)                                  │
  ├───────┼─────────────────────────────────────────────────────┤
  │  EL0  │  User-space Applications                            │  Lowest
  └───────┴─────────────────────────────────────────────────────┘  privilege
```

| Level | Name | Purpose |
|-------|------|---------|
| **EL0** | User space | Applications run here with the least privilege. They cannot directly access hardware, modify critical system registers, or handle exceptions. Any exception taken from EL0 elevates execution to a higher level. |
| **EL1** | Kernel | The Linux kernel runs at EL1. It handles all interrupts and exceptions from both user space and its own context. The vector table, GIC CPU interface registers, page table configuration, and most exception-related system registers are accessible at this level. |
| **EL2** | Hypervisor | Used by KVM and other virtualization hosts. EL2 can intercept exceptions destined for EL1, enabling guest operating systems to run beneath it. |
| **EL3** | Secure Monitor | EL3 controls the split between the secure and non-secure worlds and is typically implemented as ARM Trusted Firmware (TF-A). It can trap FIQs and route them to the secure side, which is why FIQ behavior from the kernel's perspective depends on the firmware configuration. |

When an exception occurs, the processor decides which exception level to take it to based on the exception type and the current EL. For the kernel's purposes, the most important cases are:

- **Exception from EL0 → taken at EL1**: a user-space page fault, system call, or device interrupt while running a user process.
- **Exception from EL1 → taken at EL1**: a page fault during kernel execution, or a device interrupt arriving while already in kernel code.

### PSTATE and the DAIF Flags

The current exception level and stack pointer selection are encoded in **PSTATE**, the processor state that is saved into **SPSR_EL1** (Saved Program Status Register) when an exception is taken. The key fields are:

| PSTATE Field | Purpose |
|---|---|
| **PSTATE.M[3:0]** | Current exception level and stack pointer (EL0, EL1h, EL1t) |
| **PSTATE.D** | Debug exception mask |
| **PSTATE.A** | SError (asynchronous abort) mask |
| **PSTATE.I** | IRQ mask |
| **PSTATE.F** | FIQ mask |

The Linux kernel represents these four mask bits collectively as the **DAIF** flags (Debug, Abort, IRQ, FIQ). Manipulating DAIF is how the kernel enables and disables interrupts. The macros for this are defined in [`arch/arm64/include/asm/daifflags.h`, lines 15–18](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/daifflags.h#L15-L18):

```c
#define DAIF_PROCCTX        0                                    // all exceptions unmasked (normal process context)
#define DAIF_PROCCTX_NOIRQ  (PSR_I_BIT | PSR_F_BIT)             // IRQ+FIQ masked, aborts/debug unmasked
#define DAIF_ERRCTX         (PSR_A_BIT | PSR_I_BIT | PSR_F_BIT) // only debug unmasked
#define DAIF_MASK           (PSR_D_BIT | PSR_A_BIT | PSR_I_BIT | PSR_F_BIT) // everything masked
```

When the CPU takes an exception, it *automatically* sets PSTATE.I (masking further IRQs) and PSTATE.A (masking SErrors). This gives the handler a brief window of safety to save register state before any nested interrupts can arrive. The software entry stubs later selectively unmask interrupts once a safe environment has been established.

---

## The Exception Vector Table

The exception vector table is the AArch64 equivalent of x86's IDT, but with a fundamentally different structure. Instead of one entry per interrupt vector number, AArch64 has a **fixed layout of 16 entries**, organized along two axes: *where the exception came from* and *what kind of exception it is*.

### Table Layout

The vector table occupies 2048 bytes (2 KB) of memory, aligned to an 0x800-byte boundary. It is located through the **VBAR_EL1** register (Vector Base Address Register), which the kernel sets during boot. Each of the 16 entries is exactly **128 bytes** (32 instructions) wide — enough space for a small stub that performs initial setup before branching to the full handler.

The table is organized as a 4×4 matrix:

**Rows** — Exception source:

| Row | Shorthand | Meaning |
|-----|-----------|---------|
| 0 | **EL1t** | Exception from EL1 while using **SP_EL0** (the thread stack pointer). Unusual — the kernel normally uses SP_EL1. |
| 1 | **EL1h** | Exception from EL1 while using **SP_EL1** (normal kernel mode). The common case for interrupts arriving while the kernel is already running. |
| 2 | **EL0 AArch64** | Exception from EL0 (user space) running a 64-bit process. |
| 3 | **EL0 AArch32** | Exception from EL0 (user space) running a 32-bit (compat) process. |

**Columns** — Exception type:

| Column | Offset | Type |
|--------|--------|------|
| 0 | `+0x000` | **Synchronous** — data abort, instruction abort, SVC, BRK, undefined instruction, etc. |
| 1 | `+0x080` | **IRQ** — standard hardware interrupt from GIC |
| 2 | `+0x100` | **FIQ** — fast interrupt |
| 3 | `+0x180` | **SError** — asynchronous system error |

This produces the complete table:

```
  Exception Vector Table (16 entries × 128 bytes = 2048 bytes)
  Base address: VBAR_EL1

  Offset    Source        Type         Linux Entry Point
  ──────    ──────        ────         ─────────────────
  +0x000    EL1t (SP0)    Sync         el1t_64_sync        ──┐
  +0x080    EL1t (SP0)    IRQ          el1t_64_irq           │ Not used in
  +0x100    EL1t (SP0)    FIQ          el1t_64_fiq           │ normal operation.
  +0x180    EL1t (SP0)    SError       el1t_64_error       ──┘ Panic if reached.

  +0x200    EL1h (SP1)    Sync         el1h_64_sync        ── kernel sync exceptions
  +0x280    EL1h (SP1)    IRQ          el1h_64_irq         ── kernel IRQ handler
  +0x300    EL1h (SP1)    FIQ          el1h_64_fiq         ── kernel FIQ handler
  +0x380    EL1h (SP1)    SError       el1h_64_error       ── kernel SError handler

  +0x400    EL0 64-bit    Sync         el0t_64_sync        ── user sync exceptions
  +0x480    EL0 64-bit    IRQ          el0t_64_irq         ── user IRQ handler
  +0x500    EL0 64-bit    FIQ          el0t_64_fiq         ── user FIQ handler
  +0x580    EL0 64-bit    SError       el0t_64_error       ── user SError handler

  +0x600    EL0 32-bit    Sync         el0t_32_sync        ── compat (AArch32) sync
  +0x680    EL0 32-bit    IRQ          el0t_32_irq         ── compat IRQ handler
  +0x700    EL0 32-bit    FIQ          el0t_32_fiq         ── compat FIQ handler
  +0x780    EL0 32-bit    SError       el0t_32_error       ── compat SError handler
```

### How the CPU Uses the Table

When an exception occurs, the hardware performs these steps atomically:

```
  ┌─────────────────────────────────────────────────────────────────┐
  │                  CPU Exception Entry (Hardware)                 │
  ├─────────────────────────────────────────────────────────────────┤
  │                                                                 │
  │  1. Save PSTATE ──────────────────────────────► SPSR_EL1        │
  │                                                                 │
  │  2. Save return address ──────────────────────► ELR_EL1         │
  │     • Sync fault: address of faulting instruction               │
  │     • Sync trap (SVC): address of next instruction              │
  │     • Async (IRQ/FIQ/SError): address about to execute          │
  │                                                                 │
  │  3. Write syndrome (sync only) ───────────────► ESR_EL1         │
  │                                                                 │
  │  4. Write faulting VA (aborts only) ──────────► FAR_EL1         │
  │                                                                 │
  │  5. Set PSTATE:                                                 │
  │     • Mask I (IRQ), F (FIQ), A (SError)                         │
  │     • Set EL to EL1                                             │
  │     • Select SP_EL1                                             │
  │                                                                 │
  │  6. Compute offset from (source, type)                          │
  │     Set PC = VBAR_EL1 + offset                                  │
  │                                                                 │
  └─────────────────────────────────────────────────────────────────┘
```

The CPU then begins executing at the computed vector entry.

### The Vector Table in Linux Source Code

The vector table is defined in [`arch/arm64/kernel/entry.S`, line 513](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry.S#L513):

```asm
    .align  11
SYM_CODE_START(vectors)
    kernel_ventry   1, t, 64, sync      // Synchronous EL1t
    kernel_ventry   1, t, 64, irq       // IRQ EL1t
    kernel_ventry   1, t, 64, fiq       // FIQ EL1t
    kernel_ventry   1, t, 64, error     // Error EL1t

    kernel_ventry   1, h, 64, sync      // Synchronous EL1h
    kernel_ventry   1, h, 64, irq       // IRQ EL1h
    kernel_ventry   1, h, 64, fiq       // FIQ EL1h
    kernel_ventry   1, h, 64, error     // Error EL1h

    kernel_ventry   0, t, 64, sync      // Synchronous 64-bit EL0
    kernel_ventry   0, t, 64, irq       // IRQ 64-bit EL0
    kernel_ventry   0, t, 64, fiq       // FIQ 64-bit EL0
    kernel_ventry   0, t, 64, error     // Error 64-bit EL0

    kernel_ventry   0, t, 32, sync      // Synchronous 32-bit EL0
    kernel_ventry   0, t, 32, irq       // IRQ 32-bit EL0
    kernel_ventry   0, t, 32, fiq       // FIQ 32-bit EL0
    kernel_ventry   0, t, 32, error     // Error 32-bit EL0
SYM_CODE_END(vectors)
```

Each entry uses the [`kernel_ventry` macro](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry.S#L39), which fits within the 128-byte slot. This macro:

1. Subtracts `PT_REGS_SIZE` from the stack pointer to allocate space for the saved register frame.
2. Checks for stack overflow by testing a bit at `THREAD_SHIFT` — if the stack has overflowed, it switches to a per-CPU overflow stack.
3. Branches to the corresponding full entry handler (e.g., `el1h_64_irq`).

### Vector Entry → Full Handler Flow

The full entry handlers are generated by the [`entry_handler` macro](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry.S#L569):

```asm
    .macro entry_handler el:req, ht:req, regsize:req, label:req
SYM_CODE_START_LOCAL(el\el\ht\()_\regsize\()_\label)
    kernel_entry \el, \regsize      // save all registers
    mov x0, sp                      // pass pt_regs as first argument
    bl  el\el\ht\()_\regsize\()_\label\()_handler  // call C handler
    .if \el == 0
    b   ret_to_user                 // return to user space
    .else
    b   ret_to_kernel               // return to kernel
    .endif
SYM_CODE_END(el\el\ht\()_\regsize\()_\label)
    .endm
```

So when an IRQ arrives while the kernel is running (the most common case), the CPU branches to `VBAR_EL1 + 0x280`, executes the `kernel_ventry 1, h, 64, irq` stub, which then branches to `el1h_64_irq`. This function calls `kernel_entry` to save all registers, then calls the C function `el1h_64_irq_handler()` with a pointer to `pt_regs` on the stack.

```
  Vector Entry → Handler Flow (IRQ from EL1h example)
  ════════════════════════════════════════════════════

  CPU exception ──► VBAR_EL1 + 0x280
                        │
                        ▼
               ┌──────────────────┐
               │  kernel_ventry   │  128-byte stub
               │  1, h, 64, irq   │
               │                  │
               │  sub SP, PT_REGS │
               │  check overflow  │
               │  b el1h_64_irq   │
               └────────┬─────────┘
                        │
                        ▼
               ┌──────────────────┐
               │  entry_handler   │  Generated by macro
               │                  │
               │  kernel_entry 1  │ ◄─ save all registers
               │  mov x0, sp     │ ◄─ pt_regs* arg
               │  bl el1h_64_irq │
               │     _handler    │ ◄─ call C handler
               │  b ret_to_kernel│ ◄─ return path
               └──────────────────┘
```

### The EL1t Entries: Why They Panic

The first four entries (EL1t) correspond to exceptions taken at EL1 while using SP_EL0. The kernel never operates with SP_EL0 as its active stack pointer at EL1 — it always uses SP_EL1 (the "h" suffix in EL1h). If an exception somehow arrives in the EL1t context, something has gone catastrophically wrong. These handlers simply panic via `__panic_unhandled()`, as defined in [`arch/arm64/kernel/entry-common.c`, lines 330–333](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry-common.c#L330-L333):

```c
UNHANDLED(el1t, 64, sync)
UNHANDLED(el1t, 64, irq)
UNHANDLED(el1t, 64, fiq)
UNHANDLED(el1t, 64, error)
```

---

## Synchronous Exceptions: How They Are Generated and Dispatched

Synchronous exceptions are the processor's way of reporting problems or requests that arise directly from the instruction being executed. The CPU knows exactly which instruction caused the exception, records detailed information about what went wrong, and diverts execution to the vector table.

### The ESR_EL1 Register and Exception Classes

When a synchronous exception is taken, the hardware writes a syndrome value into the **ESR_EL1** (Exception Syndrome Register). This register is the kernel's primary tool for identifying what happened. Its layout:

```
  ESR_EL1 Layout (64-bit register)
  ┌────────────┬─────┬──────────────────────────────────┐
  │ EC [31:26] │ IL  │ ISS [24:0]                       │
  │ (6 bits)   │(1b) │ (25 bits, EC-specific)           │
  └─────┬──────┴──┬──┴────────────────┬─────────────────┘
        │         │                   │
        │         │                   └── Instruction-Specific Syndrome
        │         │                       (meaning varies by EC)
        │         └── Instruction Length (0 = 16-bit, 1 = 32-bit)
        └── Exception Class (identifies the type of exception)
```

The **Exception Class (EC)** field is extracted by the macro `ESR_ELx_EC(esr)` defined in [`arch/arm64/include/asm/esr.h`, line 76](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/esr.h#L76):

```c
#define ESR_ELx_EC(esr)  (((esr) & ESR_ELx_EC_MASK) >> ESR_ELx_EC_SHIFT)
```

The most important exception classes from the kernel's perspective (defined across [`esr.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/esr.h)):

| EC Value | Constant | Meaning |
|----------|----------|---------|
| `0x15` | `ESR_ELx_EC_SVC64` | **SVC instruction** — a 64-bit system call |
| `0x20` | `ESR_ELx_EC_IABT_LOW` | **Instruction abort from EL0** — fetch from an unmapped or protected address in user space |
| `0x21` | `ESR_ELx_EC_IABT_CUR` | **Instruction abort from EL1** — fetch fault in kernel mode |
| `0x24` | `ESR_ELx_EC_DABT_LOW` | **Data abort from EL0** — load/store to an unmapped or protected address in user space |
| `0x25` | `ESR_ELx_EC_DABT_CUR` | **Data abort from EL1** — load/store fault in kernel mode |
| `0x22` | `ESR_ELx_EC_PC_ALIGN` | **PC alignment fault** |
| `0x26` | `ESR_ELx_EC_SP_ALIGN` | **SP alignment fault** |
| `0x00` | `ESR_ELx_EC_UNKNOWN` | **Unknown reason** — undefined instruction |
| `0x07` | `ESR_ELx_EC_FP_ASIMD` | **FP/SIMD access trap** |
| `0x0D` | `ESR_ELx_EC_BTI` | **Branch Target Identification fault** |
| `0x30` | `ESR_ELx_EC_BREAKPT_LOW` | **Hardware breakpoint from EL0** |
| `0x32` | `ESR_ELx_EC_SOFTSTP_LOW` | **Software step from EL0** |
| `0x34` | `ESR_ELx_EC_WATCHPT_LOW` | **Watchpoint from EL0** |
| `0x3C` | `ESR_ELx_EC_BRK64` | **BRK instruction** — software breakpoint |
| `0x1C` | `ESR_ELx_EC_FPAC` | **Pointer authentication failure** |

### Dispatch: The Synchronous Exception Switch Statement

#### User-space Synchronous Exceptions (EL0)

When a synchronous exception arrives from EL0 (user space), the CPU branches to `VBAR_EL1 + 0x400`, which reaches the `el0t_64_sync` entry. After saving registers, it calls [`el0t_64_sync_handler()`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry-common.c#L771), which reads ESR_EL1 and dispatches based on the EC:

```c
asmlinkage void noinstr el0t_64_sync_handler(struct pt_regs *regs)
{
    unsigned long esr = read_sysreg(esr_el1);

    switch (ESR_ELx_EC(esr)) {
    case ESR_ELx_EC_SVC64:
        el0_svc(regs);          // system call
        break;
    case ESR_ELx_EC_DABT_LOW:
        el0_da(regs, esr);      // data abort → page fault
        break;
    case ESR_ELx_EC_IABT_LOW:
        el0_ia(regs, esr);      // instruction abort → page fault
        break;
    case ESR_ELx_EC_FP_ASIMD:
        el0_fpsimd_acc(regs, esr);
        break;
    case ESR_ELx_EC_BREAKPT_LOW:
        el0_breakpt(regs, esr); // hardware breakpoint
        break;
    case ESR_ELx_EC_BRK64:
        el0_brk64(regs, esr);   // BRK instruction (software breakpoint)
        break;
    // ... many more cases ...
    default:
        el0_inv(regs, esr);     // invalid/unknown → bad_el0_sync()
    }
}
```

```
  EL0 Synchronous Exception Dispatch
  ═══════════════════════════════════

  ESR_EL1.EC ─────┬──── 0x15 (SVC64) ────────► el0_svc()     → syscall
                   │
                   ├──── 0x24 (DABT_LOW) ─────► el0_da()      → page fault
                   │
                   ├──── 0x20 (IABT_LOW) ─────► el0_ia()      → page fault
                   │
                   ├──── 0x07 (FP_ASIMD) ─────► el0_fpsimd_acc()
                   │
                   ├──── 0x30 (BREAKPT) ──────► el0_breakpt()
                   │
                   ├──── 0x3C (BRK64) ────────► el0_brk64()
                   │
                   └──── default ─────────────► el0_inv()     → bad_el0_sync()
```

#### Kernel-mode Synchronous Exceptions (EL1)

Similarly, synchronous exceptions from EL1 (kernel mode) are dispatched by [`el1h_64_sync_handler()`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry-common.c#L462):

```c
asmlinkage void noinstr el1h_64_sync_handler(struct pt_regs *regs)
{
    unsigned long esr = read_sysreg(esr_el1);

    switch (ESR_ELx_EC(esr)) {
    case ESR_ELx_EC_DABT_CUR:
    case ESR_ELx_EC_IABT_CUR:
        el1_abort(regs, esr);   // data/instruction abort in kernel
        break;
    case ESR_ELx_EC_PC_ALIGN:
        el1_pc(regs, esr);
        break;
    case ESR_ELx_EC_SYS64:
    case ESR_ELx_EC_UNKNOWN:
        el1_undef(regs, esr);
        break;
    case ESR_ELx_EC_BREAKPT_CUR:
        el1_breakpt(regs, esr);
        break;
    case ESR_ELx_EC_BRK64:
        el1_brk64(regs, esr);
        break;
    // ... more cases ...
    default:
        __panic_unhandled(regs, "64-bit el1h sync", esr);
    }
}
```

### How the CPU Distinguishes Hardware Interrupts from Software Exceptions

The question of "how does the CPU know whether an event is hardware-generated or software-generated?" has a straightforward architectural answer: **the CPU does not need to check on every cycle**. The mechanism is different for each type:

**For asynchronous interrupts (IRQ, FIQ, SError):** The GIC asserts a physical signal line to the CPU core. The CPU samples this signal between instructions (at instruction retirement boundaries). If the signal is asserted and the corresponding PSTATE mask bit is clear (PSTATE.I = 0 for IRQ, PSTATE.F = 0 for FIQ), the CPU takes the exception. It branches to the appropriate vector table entry (offset +0x080 for IRQ, +0x100 for FIQ, +0x180 for SError). There is no syndrome in ESR_EL1 for IRQs — the kernel must query the GIC to determine which device fired.

**For synchronous exceptions (aborts, SVC, BRK, etc.):** The CPU detects the exceptional condition during instruction execution itself — a page table walk that fails, an SVC opcode being decoded, a BRK opcode, an alignment check failure. The processor immediately takes the exception, branches to the synchronous vector entry (offset +0x000), and fills ESR_EL1 with detailed syndrome information including the Exception Class.

In other words, the CPU distinguishes the two by *when and how* it detects the event:

```
  How the CPU Detects Each Exception Type
  ════════════════════════════════════════

  Hardware Interrupts (IRQ/FIQ/SError)     Software Exceptions (Sync)
  ─────────────────────────────────────    ─────────────────────────────
  GIC asserts IRQ/FIQ signal line          Detected during instruction
  to CPU core                              execution pipeline stages
       │                                        │
       ▼                                        ▼
  CPU samples signal at instruction        CPU detects fault during
  retirement boundaries                    decode / address translation /
       │                                   memory access
       ▼                                        │
  If PSTATE mask clear → take exception         ▼
       │                                   Immediately take exception
       ▼                                        │
  Branch to vector column 1/2/3                 ▼
  (IRQ / FIQ / SError)                     Branch to vector column 0
       │                                   (Synchronous)
       ▼                                        │
  No ESR_EL1 syndrome                           ▼
  Must query GIC (IAR) to                  ESR_EL1 filled with EC + ISS
  identify interrupt source                ESR dispatches to handler
```

---

## [The GIC v3 in Detail](https://support.arm.com/documentation/ihi0069/hb/)

The **Generic Interrupt Controller version 3 (GICv3)** is the interrupt controller used on modern AArch64 systems. It sits between peripheral devices and the CPU cores, collecting interrupt signals, prioritizing them, and delivering them to the appropriate processor. The GIC is the *only* component that deals with hardware-generated device interrupts — the CPU core itself just sees the GIC's IRQ output line go active. Software-generated exceptions (page faults, SVCs, BRK) bypass the GIC entirely; they are detected internally by the CPU during instruction execution.

### Does the GIC Only Deal with Hardware Interrupts?

No, but with a nuance. The GIC handles:

1. **Hardware-generated device interrupts** (SPIs, PPIs, LPIs) — these are what most people think of as "hardware interrupts." A UART, an ethernet controller, a timer — these assert interrupt lines that the GIC routes to CPUs.

2. **Software Generated Interrupts (SGIs)** — these are *triggered by software*, but they travel *through* the GIC. One CPU writes to the **ICC_SGI1R_EL1** system register to send an IPI to another CPU. The GIC receives this, routes it to the target CPU(s), and delivers it as an IRQ. From the target CPU's perspective, it looks exactly like a hardware interrupt — it arrives on the IRQ line and is acknowledged via the GIC's IAR register. SGIs are the mechanism for TLB flush IPIs, reschedule IPIs, and function-call IPIs in Linux.

What the GIC does *not* deal with: **synchronous exceptions**. A page fault, an undefined instruction, an SVC — these have nothing to do with the GIC. They are generated internally by the CPU's own pipeline and handled directly through the synchronous exception vector entry. The GIC is purely for asynchronous interrupt routing.

### Architecture: Distributor, Redistributor, CPU Interface

The GICv3 is structured as three logical components, reflecting the need to handle interrupts at both system-wide and per-CPU granularity:

```
                           GICv3 Architecture
  ┌────────────────────────────────────────────────────────────────────┐
  │                                                                    │
  │   ┌──────────┐  ┌──────────┐  ┌──────────┐     ┌──────────┐      │
  │   │ Device A │  │ Device B │  │ Timer    │     │ Device N │      │
  │   │ (SPI 47) │  │ (SPI 80) │  │ (PPI 30) │     │ (SPI 200)│      │
  │   └────┬─────┘  └────┬─────┘  └────┬─────┘     └────┬─────┘      │
  │        │              │             │                 │            │
  │   ┌────▼──────────────▼─────────────┼─────────────────▼──────┐    │
  │   │             Distributor (GICD)  │                        │    │
  │   │                                 │                        │    │
  │   │  • Global for the entire system │                        │    │
  │   │  • Manages SPIs (INTID 32-1019) │                        │    │
  │   │  • Enable/disable per interrupt │                        │    │
  │   │  • Priority assignment          │                        │    │
  │   │  • Affinity routing (IROUTER)   │                        │    │
  │   │  • Trigger type (level/edge)    │                        │    │
  │   └────────────────┬────────────────┘                        │    │
  │                    │                                         │    │
  │        ┌───────────┼───────────┐                             │    │
  │        ▼           ▼           ▼                             │    │
  │  ┌──────────┐ ┌──────────┐ ┌──────────┐                     │    │
  │  │ Redist 0 │ │ Redist 1 │ │ Redist N │                     │    │
  │  │ (GICR)   │ │ (GICR)   │ │ (GICR)   │◄────────────────────┘    │
  │  │          │ │          │ │          │  PPIs go directly         │
  │  │ •Per-CPU │ │ •Per-CPU │ │ •Per-CPU │  to the Redistributor    │
  │  │ •SGIs    │ │ •SGIs    │ │ •SGIs    │                          │
  │  │ •PPIs    │ │ •PPIs    │ │ •PPIs    │                          │
  │  └────┬─────┘ └────┬─────┘ └────┬─────┘                          │
  │       ▼            ▼            ▼                                 │
  │  ┌──────────┐ ┌──────────┐ ┌──────────┐                          │
  │  │CPU Iface │ │CPU Iface │ │CPU Iface │                          │
  │  │ICC_* sys │ │ICC_* sys │ │ICC_* sys │                          │
  │  │registers │ │registers │ │registers │                          │
  │  └────┬─────┘ └────┬─────┘ └────┬─────┘                          │
  │       ▼            ▼            ▼                                 │
  │    ┌─────┐      ┌─────┐      ┌─────┐                             │
  │    │CPU 0│      │CPU 1│      │CPU N│                              │
  │    └─────┘      └─────┘      └─────┘                              │
  └────────────────────────────────────────────────────────────────────┘
```

#### The Distributor (GICD)

The **Distributor** is a single, global unit shared by all CPUs. It is responsible for:

- Maintaining the enable state, priority, and trigger type (level/edge) for each SPI and ESPI.
- Routing SPIs to specific CPUs via the **GICD_IROUTER** registers. Each SPI has a 64-bit routing register that specifies the target CPU's MPIDR affinity.
- Arbitrating between multiple pending interrupts based on priority.

The Distributor is initialized by [`gic_dist_init()`](https://github.com/torvalds/linux/blob/v7.2-rc5/drivers/irqchip/irq-gic-v3.c#L923). During initialization, it:

1. Disables the distributor by clearing `GICD_CTLR`.
2. Configures all SPIs as non-secure Group 1 interrupts.
3. Sets default priority for all SPIs using `dist_prio_irq`.
4. Routes all SPIs to the boot CPU.
5. Re-enables the distributor with `GICD_CTLR_ARE_NS | GICD_CTLR_ENABLE_G1A | GICD_CTLR_ENABLE_G1`.

The Distributor's memory-mapped registers are accessed via `gic_data.dist_base`, and the driver waits for register writes to propagate via `gic_dist_wait_for_rwp()`, which polls the **RWP** (Register Write Pending) bit in `GICD_CTLR`.

#### The Redistributor (GICR)

There is one **Redistributor** per CPU core. Each Redistributor manages the per-CPU interrupts: **SGIs** (INTIDs 0–15) and **PPIs** (INTIDs 16–31). The Redistributor also acts as the conduit between the Distributor and the CPU Interface — SPIs routed by the Distributor pass through the target CPU's Redistributor.

Each Redistributor has two 64 KB frames:

- **RD_base** — the main Redistributor frame (control, type, status registers).
- **SGI_base** — the frame for SGI and PPI configuration (enable, priority, trigger type).

The per-CPU Redistributor initialization happens in [`gic_cpu_init()`](https://github.com/torvalds/linux/blob/v7.2-rc5/drivers/irqchip/irq-gic-v3.c#L1274):

1. Finds the Redistributor for the current CPU by matching the MPIDR affinity value against `GICR_TYPER`.
2. Wakes the Redistributor from its sleep state.
3. Configures SGIs and PPIs as non-secure Group 1.
4. Sets default priorities.

The Redistributor also has a critical role in **LPI** (Locality-specific Peripheral Interrupt) support. LPIs are message-based interrupts managed through in-memory tables rather than MMIO registers, and the Redistributor coordinates with the **ITS** (Interrupt Translation Service) to handle them. The ITS driver lives at [`drivers/irqchip/irq-gic-v3-its.c`](https://github.com/torvalds/linux/blob/v7.2-rc5/drivers/irqchip/irq-gic-v3-its.c).

#### The CPU Interface (ICC_* System Registers)

The **CPU Interface** is the component closest to the processor core. In GICv3 (unlike GICv2, which used memory-mapped registers), the CPU Interface is accessed through **system registers** — the `ICC_*` register family. This is significantly faster because system register accesses go through the CPU's internal bus rather than the external interconnect.

Key CPU Interface system registers:

| Register | Purpose |
|----------|---------|
| **ICC_IAR1_EL1** | **Interrupt Acknowledge Register** — reading this acknowledges the highest-priority pending interrupt and returns its INTID. This is how the kernel discovers *which* interrupt fired. |
| **ICC_EOIR1_EL1** | **End of Interrupt Register** — writing an INTID here signals that the interrupt has been handled. In **EOI mode 1** (split priority drop / deactivation), this drops the priority; deactivation is a separate step. |
| **ICC_PMR_EL1** | **Priority Mask Register** — sets the minimum priority an interrupt must have to be delivered. The kernel uses this for pseudo-NMI support. |
| **ICC_SGI1R_EL1** | **SGI Generation Register** — writing to this register sends an SGI (IPI) to specified target CPUs. |
| **ICC_CTLR_EL1** | **Control Register** — configures EOI mode, priority bits, etc. |
| **ICC_SRE_EL1** | **System Register Enable** — enables system register access to the CPU Interface (as opposed to memory-mapped). |
| **ICC_DIR_EL1** | **Deactivate Interrupt Register** — in EOI mode 1, used to deactivate an interrupt separately from the priority drop. |
| **ICC_RPR_EL1** | **Running Priority Register** — reports the priority of the currently running interrupt. Used by the pseudo-NMI implementation to distinguish NMIs from regular IRQs. |
| **ICC_BPR1_EL1** | **Binary Point Register** — controls interrupt preemption grouping. |

The CPU Interface is initialized per-CPU in [`gic_cpu_sys_reg_init()`](https://github.com/torvalds/linux/blob/v7.2-rc5/drivers/irqchip/irq-gic-v3.c#L1150). The key steps:

1. Enable system register access (`gic_enable_sre()`).
2. Set the Priority Mask Register to allow all interrupts (`DEFAULT_PMR_VALUE = 0xf0`).
3. Reset the Binary Point Register to 0 (maximum preemption granularity).
4. Configure EOI mode: if a hypervisor is present, use **EOI mode 1** (split drop/deactivate, allowing KVM to manage deactivation for forwarded interrupts); otherwise, use EOI mode 0.
5. Clear all active priority registers.
6. Enable Group 1 interrupts.

### Interrupt Types and INTID Ranges

The GIC organizes interrupts by their **INTID** (hardware interrupt number) into distinct categories, each with different scope and routing behavior. The kernel classifies these ranges in the [`gic_intid_range` enum](https://github.com/torvalds/linux/blob/v7.2-rc5/drivers/irqchip/irq-gic-v3.c#L245):

```c
enum gic_intid_range {
    SGI_RANGE,       // INTID 0-15
    PPI_RANGE,       // INTID 16-31
    SPI_RANGE,       // INTID 32-1019
    EPPI_RANGE,      // INTID 1056-1119 (Extended PPIs)
    ESPI_RANGE,      // INTID 4096-5119 (Extended SPIs)
    LPI_RANGE,       // INTID 8192+
    __INVALID_RANGE__
};
```

```
  INTID Space
  ═══════════

  0          15 16        31 32                     1019
  ├──SGIs──────┤├──PPIs─────┤├──────────SPIs──────────┤
  │ per-CPU    ││ per-CPU   ││ global, shared         │
  │ IPIs       ││ timer,PMU ││ UARTs, NICs, etc.      │
  └────────────┘└───────────┘└────────────────────────┘

  1056      1119  4096      5119  8192          ...
  ├──EPPIs────┤   ├──ESPIs────┤   ├────LPIs────────►
  │ extended  │   │ extended  │   │ message-based
  │ per-CPU   │   │ global    │   │ (ITS/MSI)
  └───────────┘   └───────────┘   └────────────────
```

#### SGIs — Software Generated Interrupts (INTID 0–15)

**SGIs** are the GIC's mechanism for **Inter-Processor Interrupts (IPIs)**. A CPU sends an SGI by writing to the `ICC_SGI1R_EL1` system register, specifying the target CPU(s) and the SGI number. Linux uses 8 of the 16 available SGIs (the other 8 are reserved for the secure world), allocated in [`gic_smp_init()`](https://github.com/torvalds/linux/blob/v7.2-rc5/drivers/irqchip/irq-gic-v3.c#L1401):

```c
base_sgi = irq_domain_alloc_irqs(gic_data.domain, 8, NUMA_NO_NODE, &sgi_fwspec);
set_smp_ipi_range(base_sgi, 8);
```

SGIs are always **edge-triggered** (they are one-shot events) and are **per-CPU** — each CPU has its own set of 16 SGI states. The [`gic_ipi_send_mask()`](https://github.com/torvalds/linux/blob/v7.2-rc5/drivers/irqchip/irq-gic-v3.c#L1376) function implements the actual SGI transmission:

```c
static void gic_ipi_send_mask(struct irq_data *d, const struct cpumask *mask)
{
    // ...
    dsb(ishst);  // ensure stores visible to other CPUs before sending IPI
    for_each_cpu(cpu, mask) {
        u64 cluster_id = MPIDR_TO_SGI_CLUSTER_ID(gic_cpu_to_affinity(cpu));
        u16 tlist;
        tlist = gic_compute_target_list(&cpu, mask, cluster_id);
        gic_send_sgi(cluster_id, tlist, d->hwirq);
    }
    isb();  // force the SGI writes to execute
}
```

The `ICC_SGI1R_EL1` register encodes the target CPU(s) using MPIDR affinity levels and a target list bitmask, allowing a single register write to send an SGI to multiple CPUs within the same cluster.

#### PPIs — Private Peripheral Interrupts (INTID 16–31)

**PPIs** are **per-CPU** interrupts from devices that are private to each core — most importantly the **ARM Generic Timer** (typically PPI 30 for the non-secure physical timer, PPI 27 for the virtual timer) and the **Performance Monitoring Unit (PMU)**. Each CPU has its own independent state for each PPI. PPIs are configured through the Redistributor, not the Distributor.

#### SPIs — Shared Peripheral Interrupts (INTID 32–1019)

**SPIs** are global, system-wide interrupts from peripheral devices: UARTs, network controllers, storage controllers, GPIO controllers, and so on. An SPI can be routed to any CPU through the Distributor's `GICD_IROUTER` registers. The kernel's [`gic_set_affinity()`](https://github.com/torvalds/linux/blob/v7.2-rc5/drivers/irqchip/irq-gic-v3.c#L1425) function changes which CPU handles a given SPI by writing the target CPU's affinity to the IROUTER register.

SPIs support both **level-triggered** and **edge-triggered** configurations, set via the `GICD_ICFGR` registers and controlled by [`gic_set_type()`](https://github.com/torvalds/linux/blob/v7.2-rc5/drivers/irqchip/irq-gic-v3.c#L701).

#### LPIs — Locality-specific Peripheral Interrupts (INTID 8192+)

**LPIs** are message-based interrupts, managed through the **Interrupt Translation Service (ITS)** rather than the Distributor's MMIO registers. They are used by modern bus protocols like PCIe MSI/MSI-X. The ITS translates a device's event ID and device ID into a specific INTID and target CPU, using in-memory tables. This allows scaling to thousands of interrupt sources without consuming MMIO register space. The ITS driver lives in [`drivers/irqchip/irq-gic-v3-its.c`](https://github.com/torvalds/linux/blob/v7.2-rc5/drivers/irqchip/irq-gic-v3-its.c).

### How the CPU Knows an Interrupt Has Arrived

The CPU does not "poll" the GIC. The connection between the GIC and the CPU core is a pair of dedicated electrical signal lines: the **IRQ line** and the **FIQ line**. These are internal to the SoC — they are not software-visible registers or memory locations that the CPU checks.

```
  GIC-to-CPU Signal Delivery
  ══════════════════════════

  ┌──────────┐     ┌──────────────────────┐     ┌──────────────┐
  │  Device   │────►│  GIC                 │     │    CPU Core   │
  │  asserts  │     │                      │     │              │
  │  IRQ pin  │     │  Distributor         │     │              │
  └──────────┘     │    ↓ route by IROUTER│     │              │
                    │  Redistributor       │     │              │
                    │    ↓ priority check  │     │              │
                    │  CPU Interface       │     │              │
                    │    ↓                 │     │              │
                    │  Assert IRQ signal ──╋────►│  Sample at   │
                    │  line (electrical)   │     │  instruction │
                    │                      │     │  boundary    │
                    └──────────────────────┘     │              │
                                                 │  PSTATE.I=0? │
                                                 │  Yes → take  │
                                                 │  exception   │
                                                 └──────────────┘
```

The flow is:

1. A device asserts its interrupt output (e.g., a UART receives a byte and raises its IRQ line).
2. The GIC Distributor receives the interrupt, checks that it is enabled, determines its priority, and consults the routing (IROUTER) to find the target CPU.
3. The GIC forwards the interrupt to the target CPU's Redistributor, which passes it to the CPU Interface.
4. The CPU Interface compares the interrupt's priority against the current running priority (ICC_RPR_EL1) and the priority mask (ICC_PMR_EL1). If the interrupt qualifies, the CPU Interface **asserts the physical IRQ signal line** to the CPU core.
5. The CPU core, at the next instruction boundary, detects the IRQ signal assertion. If PSTATE.I is clear (IRQs unmasked), the CPU takes the IRQ exception — it saves state and branches to `VBAR_EL1 + 0x280` (for EL1h IRQ) or `VBAR_EL1 + 0x480` (for EL0 IRQ).
6. The software handler reads `ICC_IAR1_EL1` to **acknowledge** the interrupt and discover its INTID. This also causes the GIC to de-assert the IRQ signal (until the next pending interrupt, if any).

For software exceptions, none of this involves the GIC at all. The CPU detects a page fault during its own page table walk, or decodes an SVC instruction in its pipeline, and generates the exception internally. The GIC signal lines remain unchanged.

---

## Device IRQ to Kernel Driver Handler

Here is the step-by-step journey of a hardware interrupt from a peripheral device through the GIC and into the Linux kernel's driver handler, using the example of a UART receiving a character while a user-space process is running.

### Step 1: Device Asserts Its Interrupt Line

The UART controller has received a byte in its receive FIFO. Its internal logic asserts the interrupt output pin. This electrical signal is wired to the GIC Distributor's SPI input — say, SPI 47 (INTID 79).

### Step 2: GIC Distributor Receives and Routes

The Distributor checks `GICD_ISENABLER[79/32]` to confirm this SPI is enabled. It reads the priority from `GICD_IPRIORITYR[79]`. It looks up the target CPU from `GICD_IROUTER[79]`, which contains the MPIDR affinity value of CPU 0. The Distributor forwards the interrupt to CPU 0's Redistributor.

### Step 3: GIC CPU Interface Signals the Core

CPU 0's Redistributor passes the interrupt to the CPU Interface. The CPU Interface compares the interrupt's priority against `ICC_PMR_EL1` (the priority mask). The interrupt's priority is high enough (numerically lower than the mask), so the CPU Interface asserts the **physical IRQ line** to CPU 0.

### Step 4: CPU Takes the IRQ Exception

CPU 0 is executing a user-space `read()` system call. At the next instruction boundary, it detects the IRQ assertion. Since PSTATE.I = 0 (IRQs are unmasked in normal user context), the CPU takes the exception:

1. **Saves PSTATE** into SPSR_EL1.
2. **Saves the return PC** into ELR_EL1 (the address of the next instruction that would have executed).
3. **Sets PSTATE**: masks I, F, and A bits; switches to EL1; selects SP_EL1.
4. **Branches to** `VBAR_EL1 + 0x480` (EL0, 64-bit, IRQ).

### Step 5: kernel_ventry Stub Runs

The CPU is now executing at `vectors + 0x480`, inside the [`kernel_ventry 0, t, 64, irq`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry.S#L39) slot. This macro:

1. Subtracts `PT_REGS_SIZE` from SP to allocate the register save area.
2. Checks for stack overflow.
3. Branches to `el0t_64_irq`.

### Step 6: kernel_entry Saves All Registers

The `el0t_64_irq` entry handler calls [`kernel_entry 0`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry.S#L197), which saves all 31 general-purpose registers (x0–x30) plus the link register, saved SP (from SP_EL0), ELR_EL1, and SPSR_EL1 into the `pt_regs` structure on the stack. For EL0 entries, it also:

- Saves the user-space SP from `SP_EL0`.
- Loads the current task pointer into `tsk` (x28).
- Disables single-stepping if it was active.
- Checks for MTE asynchronous tag check faults.
- Installs kernel pointer authentication keys.
- Applies Spectre v4 mitigations (SSBD).

### Step 7: C Handler el0t_64_irq_handler() Is Called

After `kernel_entry`, the entry handler loads SP into x0 (passing `pt_regs *` as the argument) and calls [`el0t_64_irq_handler()`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry-common.c#L861):

```c
asmlinkage void noinstr el0t_64_irq_handler(struct pt_regs *regs)
{
    __el0_irq_handler_common(regs);
}
```

Which calls [`el0_interrupt()`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry-common.c#L839):

```c
static void noinstr el0_interrupt(struct pt_regs *regs,
                                  void (*handler)(struct pt_regs *))
{
    arm64_enter_from_user_mode(regs);    // context tracking, RCU, MTE setup

    write_sysreg(DAIF_PROCCTX_NOIRQ, daif);  // unmask SError/Debug, keep IRQ/FIQ masked

    if (regs->pc & BIT(55))
        arm64_apply_bp_hardening();      // Spectre mitigations

    irq_enter_rcu();                     // update preempt count, account time
    do_interrupt_handler(regs, handler); // invoke the GIC handler
    irq_exit_rcu();                      // process softirqs, account time

    arm64_exit_to_user_mode(regs);       // signal delivery, rescheduling
}
```

### Step 8: Switch to IRQ Stack

[`do_interrupt_handler()`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry-common.c#L172) checks if the kernel is currently on the thread stack, and if so, switches to the per-CPU IRQ stack to avoid overflowing the relatively small kernel thread stack:

```c
static void do_interrupt_handler(struct pt_regs *regs,
                                 void (*handler)(struct pt_regs *))
{
    struct pt_regs *old_regs = set_irq_regs(regs);

    if (on_thread_stack())
        call_on_irq_stack(regs, handler);   // switch to per-CPU IRQ stack
    else
        handler(regs);                       // already on IRQ stack

    set_irq_regs(old_regs);
}
```

The IRQ stack is allocated during boot by [`init_irq_stacks()`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/irq.c#L60), one per CPU. The [`call_on_irq_stack()`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry.S#L868) assembly function saves the current frame, switches SP to the top of the IRQ stack, calls the handler, then switches back.

### Step 9: gic_handle_irq() Reads the IAR

The `handler` function pointer is `handle_arch_irq`, which was set to `gic_handle_irq()` during GIC initialization via `set_handle_irq()` at [`irq-gic-v3.c`, line 2042](https://github.com/torvalds/linux/blob/v7.2-rc5/drivers/irqchip/irq-gic-v3.c#L2045). The global function pointer is declared in [`arch/arm64/kernel/irq.c`, line 97](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/irq.c#L97):

```c
void (*handle_arch_irq)(struct pt_regs *) __ro_after_init = default_handle_irq;
```

[`gic_handle_irq()`](https://github.com/torvalds/linux/blob/v7.2-rc5/drivers/irqchip/irq-gic-v3.c#L912) reads the **ICC_IAR1_EL1** register to acknowledge the interrupt and obtain the hardware INTID:

```c
static void __exception_irq_entry gic_handle_irq(struct pt_regs *regs)
{
    if (unlikely(gic_supports_nmi() && !interrupts_enabled(regs)))
        __gic_handle_irq_from_irqsoff(regs);  // pseudo-NMI path
    else
        __gic_handle_irq_from_irqson(regs);    // normal path
}
```

In the normal path, [`__gic_handle_irq_from_irqson()`](https://github.com/torvalds/linux/blob/v7.2-rc5/drivers/irqchip/irq-gic-v3.c#L855):

```c
static void __gic_handle_irq_from_irqson(struct pt_regs *regs)
{
    bool is_nmi;
    u32 irqnr;

    irqnr = gic_read_iar();           // read ICC_IAR1_EL1 → returns INTID (e.g., 79)

    is_nmi = gic_rpr_is_nmi_prio();   // check if this is a pseudo-NMI

    if (is_nmi) {
        nmi_enter();
        __gic_handle_nmi(irqnr, regs);
        nmi_exit();
    }

    gic_unmask_pnmis();               // re-enable pseudo-NMIs

    if (!is_nmi)
        __gic_handle_irq(irqnr, regs); // handle as a normal IRQ
}
```

### Step 10: Priority Drop and Domain Lookup

[`__gic_handle_irq()`](https://github.com/torvalds/linux/blob/v7.2-rc5/drivers/irqchip/irq-gic-v3.c#L818) first checks for special INTIDs (1020–1023 are reserved for spurious interrupts), then performs the **priority drop** and dispatches through the IRQ domain:

```c
static void __gic_handle_irq(u32 irqnr, struct pt_regs *regs)
{
    if (gic_irqnr_is_special(irqnr))
        return;                             // spurious, ignore

    gic_complete_ack(irqnr);                // write ICC_EOIR1_EL1 (priority drop) + ISB

    if (generic_handle_domain_irq(gic_data.domain, irqnr)) {
        WARN_ONCE(true, "Unexpected interrupt (irqnr %u)\n", irqnr);
        gic_deactivate_unhandled(irqnr);    // deactivate if no handler found
    }
}
```

[`gic_complete_ack()`](https://github.com/torvalds/linux/blob/v7.2-rc5/drivers/irqchip/irq-gic-v3.c#L797) writes the INTID back to `ICC_EOIR1_EL1`. In **EOI mode 1** (the default when a hypervisor is present), this only performs a **priority drop** — it tells the GIC that the CPU has begun handling this interrupt and can accept higher-priority interrupts. The actual **deactivation** (removing the interrupt from the active state) happens later, in the `irq_chip.irq_eoi` callback.

`generic_handle_domain_irq()` translates the hardware INTID (79) through the GIC's **IRQ domain** into a Linux virtual IRQ number, finds the corresponding `irq_desc`, and invokes its flow handler.

### Step 11: Flow Handler and Driver ISR Execute

The `irq_desc` for this interrupt has a flow handler — for SPIs, this is `handle_fasteoi_irq()` (set during [`gic_irq_domain_map()`](https://github.com/torvalds/linux/blob/v7.2-rc5/drivers/irqchip/irq-gic-v3.c#L1544) at [line 1565](https://github.com/torvalds/linux/blob/v7.2-rc5/drivers/irqchip/irq-gic-v3.c#L1565)). This flow handler:

1. Masks the interrupt if necessary.
2. Walks the `irqaction` chain and calls each registered handler.
3. Signals EOI to the irq_chip (calling `gic_eoimode1_eoi_irq()`, which writes `ICC_DIR_EL1` to deactivate the interrupt).

The driver's handler (registered via `request_irq()`) runs here — for our UART example, it reads the received byte from the UART's data register and places it in a buffer.

### Step 12: Return Path

After the handler returns, control flows back through:

1. `irq_exit_rcu()` — decrements the preempt count, processes pending softirqs.
2. `arm64_exit_to_user_mode()` — checks for pending signals, reschedule requests, and other deferred work. If `TIF_NEED_RESCHED` is set, the scheduler runs here.
3. [`ret_to_user`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry.S#L604) — calls [`kernel_exit 0`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry.S#L335), which:
   - Restores ELR_EL1 and SPSR_EL1.
   - Restores all 31 general-purpose registers from `pt_regs`.
   - Restores SP_EL0 (the user stack pointer).
   - Executes **`eret`** — the Exception Return instruction, which atomically restores PC from ELR_EL1 and PSTATE from SPSR_EL1, returning to user space.

### Complete Flow Diagram

```
  Complete Path: Device IRQ → Kernel Driver Handler
  ═════════════════════════════════════════════════

  ┌──────────┐    ┌─────────────┐    ┌──────────────┐    ┌──────────────┐
  │  Device   │───►│     GIC      │───►│   CPU HW     │───►│ kernel_ventry│
  │  asserts  │    │  Distributor │    │ saves PSTATE  │    │  (entry.S)   │
  │  SPI line │    │  → Redist    │    │ → SPSR_EL1    │    │  sub SP      │
  │           │    │  → CPU Iface │    │ saves PC      │    │  check stack │
  │           │    │  → assert    │    │ → ELR_EL1     │    │  branch to   │
  │           │    │    IRQ line  │    │ mask DAIF     │    │  el0t_64_irq │
  └──────────┘    └─────────────┘    │ branch to     │    └───────┬──────┘
                                      │ VBAR+0x480    │            │
                                      └──────────────┘            │
                                                                   ▼
                                                          ┌──────────────┐
                                                          │ kernel_entry │
                                                          │ saves x0-x30 │
                                                          │ saves ELR,   │
                                                          │ SPSR, SP_EL0 │
                                                          └───────┬──────┘
                                                                   │
                                                                   ▼
                                                          ┌──────────────┐
                                                          │ el0_interrupt │
                                                          │              │
                                                          │ context track│
                                                          │ Spectre      │
                                                          │ mitigation   │
                                                          │ irq_enter_rcu│
                                                          └───────┬──────┘
                                                                   │
                                                                   ▼
                                                          ┌──────────────┐
                                                          │do_interrupt  │
                                                          │  _handler    │
                                                          │              │
                                                          │ switch to    │
                                                          │ per-CPU IRQ  │
                                                          │ stack        │
                                                          └───────┬──────┘
                                                                   │
                                                                   ▼
                                                          ┌──────────────┐
                                                          │gic_handle_irq│
                                                          │              │
                                                          │ read IAR     │
                                                          │ (INTID=79)   │
                                                          │ priority drop│
                                                          │ (EOIR)       │
                                                          └───────┬──────┘
                                                                   │
                                                                   ▼
                                                          ┌──────────────┐
                                                          │ domain lookup│
                                                          │              │
                                                          │ INTID → virq │
                                                          │ → irq_desc   │
                                                          │ → flow       │
                                                          │   handler    │
                                                          └───────┬──────┘
                                                                   │
                                                                   ▼
                                                          ┌──────────────┐
                                                          │ Driver ISR   │
                                                          │ (reads UART  │
                                                          │  data reg)   │
                                                          │              │
                                                          │ EOI/deact    │
                                                          │ (ICC_DIR)    │
                                                          └───────┬──────┘
                                                                   │
                                                                   ▼
  ┌──────────┐    ┌─────────────┐    ┌──────────────┐    ┌──────────────┐
  │ eret to   │◄───│ ret_to_user │◄───│ irq_exit_rcu │◄───│ handler      │
  │ user space│    │ kernel_exit │    │ softirqs     │    │ returns      │
  │ restore   │    │ signal/sched│    │ account time │    │              │
  │ PC,PSTATE │    │ check       │    │              │    │              │
  └──────────┘    └─────────────┘    └──────────────┘    └──────────────┘
```

---

## Page Fault (Software Exception)

To contrast with the hardware interrupt path above, here is the complete journey of a **page fault** — a purely synchronous, software-generated exception — from the faulting instruction to resolution and resumption.

### The Scenario

A user-space process executes a `load` instruction that accesses a valid virtual address, but the page is not currently present in physical memory (it has been swapped out, or was never faulted in — a **demand paging** scenario).

### Step 1: CPU Detects the Fault During Page Table Walk

The CPU's MMU performs a page table walk for the virtual address. It walks from PGD → PUD → PMD → PTE and finds either a missing entry (translation fault) or an entry with the Access Flag clear (access flag fault). The MMU signals the exception to the core internally — **no GIC involvement, no external signal**.

### Step 2: CPU Takes the Synchronous Exception

Since the faulting instruction was executing in user space (EL0), the CPU:

1. Saves **PSTATE** → **SPSR_EL1**.
2. Saves the **PC of the faulting instruction** → **ELR_EL1**. This is the load instruction itself, because a data abort is a **fault** (the instruction must be retried after the handler fixes the condition).
3. Writes the **syndrome** to **ESR_EL1**:
   - EC = 0x24 (`ESR_ELx_EC_DABT_LOW`) — data abort from a lower exception level.
   - ISS contains the **Fault Status Code (FSC)**, which indicates the specific type of abort: translation fault at level 2 (FSC = 0x06), access flag fault at level 3 (FSC = 0x0B), permission fault at level 3 (FSC = 0x0F), etc.
   - WnR bit indicates whether it was a read or write.
4. Writes the **faulting virtual address** to **FAR_EL1** (Fault Address Register). The IRQ path has no equivalent — there is no "faulting address" for an interrupt.
5. Masks DAIF and branches to **VBAR_EL1 + 0x400** (EL0, 64-bit, Synchronous).

### Step 3: Entry Through the Vector Table

The CPU enters `kernel_ventry 0, t, 64, sync`, which branches to `el0t_64_sync`. This calls [`kernel_entry 0`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry.S#L197) (identical register saving as the IRQ path), then calls `el0t_64_sync_handler()`.

### Step 4: Synchronous Exception Dispatch

[`el0t_64_sync_handler()`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry-common.c#L771) reads `ESR_EL1` and dispatches on the Exception Class:

```c
switch (ESR_ELx_EC(esr)) {
case ESR_ELx_EC_DABT_LOW:
    el0_da(regs, esr);    // ← data abort from user space
    break;
// ...
}
```

### Step 5: el0_da() — Data Abort Handler

[`el0_da()`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry-common.c#L568):

```c
static void noinstr el0_da(struct pt_regs *regs, unsigned long esr)
{
    unsigned long far = read_sysreg(far_el1);   // read the faulting address

    arm64_enter_from_user_mode(regs);            // context tracking, RCU
    local_daif_restore(DAIF_PROCCTX);            // unmask all exceptions (enable IRQs!)
    do_mem_abort(far, esr, regs);                // handle the abort
    arm64_exit_to_user_mode(regs);               // return path
}
```

> **Critical difference from the IRQ path:** the data abort handler **re-enables interrupts** (`local_daif_restore(DAIF_PROCCTX)`) before doing the actual work. Page fault handling can be slow (it may need to read from disk for swap-in), and the system cannot afford to block all interrupts for that duration. By contrast, the IRQ handler keeps interrupts masked until it has finished the critical GIC acknowledgment.

### Step 6: do_mem_abort() — Fault Dispatch Table

[`do_mem_abort()`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/mm/fault.c#L980) uses the **Fault Status Code (FSC)** from the lower 6 bits of ESR_EL1 to index into the [`fault_info[]`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/mm/fault.c#L913) dispatch table:

```c
void do_mem_abort(unsigned long far, unsigned long esr, struct pt_regs *regs)
{
    const struct fault_info *inf = esr_to_fault_info(esr);
    // inf->fn points to the appropriate handler based on the FSC
    if (!inf->fn(far, esr, regs))
        return;
    // ... error handling ...
}
```

The `fault_info[]` table maps each FSC value to a handler function:

| FSC | Handler | Description |
|-----|---------|-------------|
| 0x04–0x07 | [`do_translation_fault`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/mm/fault.c#L838) | Translation fault at level 0–3 (no page table entry exists) |
| 0x08–0x0B | [`do_page_fault`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/mm/fault.c#L601) | Access flag fault at level 0–3 (page exists but Access Flag is clear) |
| 0x0C–0x0F | [`do_page_fault`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/mm/fault.c#L601) | Permission fault at level 0–3 (page exists but permissions deny the access) |
| 0x10 | `do_sea` | Synchronous external abort (hardware memory error) |
| 0x21 | `do_alignment_fault` | Alignment fault |

### Step 7: [do_page_fault() — The Core MM Handler](https://mukeshpilaniya.github.io/posts/aarch64_page_fault/)

[`do_page_fault()`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/mm/fault.c#L601) is where the architecture-specific code meets the architecture-independent Linux MM subsystem. It:

1. Determines whether the fault was a read, write, or execute based on ESR_EL1 fields (WnR bit, EC for instruction vs data abort).
2. Checks if the fault address falls within a valid VMA (`lock_vma_under_rcu()` or `lock_mm_and_find_vma()`).
3. Calls `handle_mm_fault()` — the generic, architecture-independent function that:
   - Allocates a physical page if needed.
   - Reads the page from swap if it was swapped out.
   - Performs copy-on-write if it is a write to a shared mapping.
   - Updates the page table entry with the new physical address and correct permissions.
4. Returns to `do_mem_abort()`, which returns to `el0_da()`.

### Step 8: Return to User Space — Instruction Retry

The return path is identical to the IRQ path: `arm64_exit_to_user_mode()` checks for signals and reschedule, [`ret_to_user`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry.S#L604) calls [`kernel_exit 0`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry.S#L335), and `eret` restores PC from ELR_EL1 and PSTATE from SPSR_EL1.

The crucial difference: **ELR_EL1 points to the faulting load instruction**, not the next one. The CPU re-executes the load, and this time the MMU walk succeeds because `do_page_fault()` has populated the page table entry. The load completes normally, and the process continues without ever knowing the fault occurred.

### Page Fault Flow Diagram

```
  Page Fault Path: EL0 Data Abort
  ════════════════════════════════

  User-space load instruction
       │
       ▼
  ┌─────────────────┐
  │ MMU page table   │  No GIC.
  │ walk fails       │  Entirely
  │ (internal to CPU)│  internal.
  └────────┬────────┘
           │
           ▼
  ┌─────────────────┐     ┌────────────────────────┐
  │ CPU takes sync   │     │ Registers set:          │
  │ exception        │────►│  ESR_EL1 = EC:0x24+FSC │
  │                  │     │  FAR_EL1 = fault addr   │
  │ VBAR + 0x400     │     │  ELR_EL1 = faulting PC  │
  └────────┬────────┘     └────────────────────────┘
           │
           ▼
  ┌─────────────────┐
  │ kernel_entry     │
  │ save all regs    │
  └────────┬────────┘
           │
           ▼
  ┌─────────────────┐
  │ el0t_64_sync     │
  │ _handler()       │
  │ switch on EC     │
  │ → el0_da()       │
  └────────┬────────┘
           │
           ▼
  ┌─────────────────┐     ┌────────────────────────┐
  │ el0_da()         │     │ IRQs RE-ENABLED here!  │
  │ read FAR_EL1     │────►│ Page fault may do I/O  │
  │ enable IRQs      │     │ (swap-in from disk)    │
  │ do_mem_abort()   │     └────────────────────────┘
  └────────┬────────┘
           │
           ▼
  ┌─────────────────┐
  │ fault_info[]     │
  │ dispatch by FSC  │
  │ → do_page_fault()│
  └────────┬────────┘
           │
           ▼
  ┌─────────────────┐
  │ handle_mm_fault()│
  │ allocate page    │
  │ update PTE       │
  └────────┬────────┘
           │
           ▼
  ┌─────────────────┐
  │ ret_to_user      │
  │ kernel_exit 0    │
  │ eret             │
  │                  │
  │ PC = ELR_EL1     │  ◄── points to faulting instruction
  │ (retry the load) │
  └─────────────────┘
```

### Side-by-Side Comparison

| Aspect | Device IRQ (Hardware) | Page Fault (Software) |
|--------|----------------------|----------------------|
| **Origin** | External device, via GIC | CPU's own MMU, during instruction execution |
| **Timing** | Asynchronous — no relation to instruction stream | Synchronous — caused by the current instruction |
| **GIC involvement** | Yes — routes, prioritizes, delivers | None — entirely internal to the CPU |
| **Vector entry** | Column 1 (IRQ, offset +0x080) | Column 0 (Sync, offset +0x000) |
| **ESR_EL1** | Not meaningful — handler reads GIC IAR instead | Critical — contains EC and FSC for dispatch |
| **FAR_EL1** | Not set | Set to the faulting virtual address |
| **ELR_EL1** | Address of next instruction (resumes after) | Address of faulting instruction (retried after fix) |
| **Interrupt masking** | IRQs stay masked until GIC acknowledged | IRQs re-enabled early (fault handling may be slow) |
| **Source identification** | Read GIC ICC_IAR1_EL1 → INTID → domain lookup | Read ESR_EL1 → EC + FSC → `fault_info[]` dispatch |
| **Handler outcome** | Driver's ISR services the device | MM subsystem maps the page, instruction retries |

---

## The kernel_entry and kernel_exit Macros

These two assembly macros form the bookends of every exception handler. Understanding them is essential to understanding how the kernel preserves and restores the interrupted context.

### kernel_entry ([entry.S, line 197](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry.S#L197))

`kernel_entry` saves the complete CPU state into a `pt_regs` structure on the stack. The stack space was already allocated by `kernel_ventry`. The macro takes two arguments: the exception level (0 or 1) and the register size (64 or 32).

For all entries, it saves the 30 general-purpose registers (x0–x29) using **store pair** instructions (`stp`), which write two 64-bit registers per instruction for efficiency:

```asm
stp x0, x1, [sp, #16 * 0]
stp x2, x3, [sp, #16 * 1]
// ... through ...
stp x28, x29, [sp, #16 * 14]
```

Then it saves ELR_EL1 (the return address) and SPSR_EL1 (the saved processor state):

```asm
mrs x22, elr_el1
mrs x23, spsr_el1
stp x22, x23, [sp, #S_PC]
```

**For EL0 entries** (from user space), it additionally:

- Saves the user stack pointer from `SP_EL0`.
- Loads the current task pointer.
- Sets up kernel pointer authentication keys.
- Clears all general-purpose registers (to prevent leaking kernel data to user space on exception return).

**For EL1 entries** (from kernel), it saves the interrupted kernel SP by computing `sp + PT_REGS_SIZE` (since SP was decremented to make room for pt_regs, the original SP is the current SP plus the frame size).

```
  pt_regs Layout on Stack (after kernel_entry)
  ═════════════════════════════════════════════

  SP + PT_REGS_SIZE ──► ┌──────────────────────┐ ◄── original SP
                        │ regs[0]  (x0)        │  offset 0x000
                        │ regs[1]  (x1)        │  offset 0x008
                        │ ...                  │
                        │ regs[29] (x29/FP)    │  offset 0x0E8
                        │ regs[30] (x30/LR)    │  offset 0x0F0
                        │ sp       (saved SP)  │  offset 0x0F8
                        │ pc       (ELR_EL1)   │  offset 0x100
                        │ pstate   (SPSR_EL1)  │  offset 0x108
                        │ orig_x0              │  offset 0x110
                        │ syscallno            │  offset 0x118
                        │ orig_addr_limit      │  offset 0x120
                        │ pmr      (ICC_PMR)   │  offset 0x128
                        │ stackframe[0]        │  offset 0x130
                        │ stackframe[1]        │  offset 0x138
  SP ──────────────────►└──────────────────────┘
```

### kernel_exit ([entry.S, line 335](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry.S#L335))

`kernel_exit` restores the saved state and executes `eret` to return from the exception. It is the mirror image of `kernel_entry`:

1. Restores ELR_EL1 and SPSR_EL1 from the saved `pt_regs`.
2. For EL0 returns: restores SP_EL0, applies Spectre mitigations, restores pointer authentication keys.
3. Restores all 30 general-purpose registers via `ldp` (load pair) instructions.
4. Restores the link register (x30) and adjusts SP back.
5. Executes `eret`, which atomically:
   - Sets PC from ELR_EL1.
   - Restores PSTATE from SPSR_EL1 (including the exception level, stack pointer selection, and DAIF mask bits).
   - If returning to EL0, switches to the user-mode exception level.

The `sb` instruction immediately after `eret` is a **speculation barrier** — architecturally, execution never reaches it (eret is an unconditional control transfer), but it prevents speculative execution past the return in case of microarchitectural speculation.

```
  kernel_entry / kernel_exit Symmetry
  ════════════════════════════════════

  kernel_entry                              kernel_exit
  ────────────                              ───────────
  stp x0, x1, [sp, #16*0]         ldp x0, x1, [sp, #16*0]
  stp x2, x3, [sp, #16*1]         ldp x2, x3, [sp, #16*1]
  ...                               ...
  stp x28, x29, [sp, #16*14]      ldp x28, x29, [sp, #16*14]
  mrs x22, elr_el1                 msr elr_el1, x22
  mrs x23, spsr_el1                msr spsr_el1, x23
  stp x22, x23, [sp, #S_PC]       ldp x22, x23, [sp, #S_PC]
                                    eret       ◄── atomically restore PC + PSTATE
                                    sb         ◄── speculation barrier
```

---

## The IRQ Stack

Linux allocates a separate per-CPU **IRQ stack** for handling interrupts. This is critical because kernel thread stacks are relatively small (typically 16 KB on AArch64), and an interrupt can arrive at any point — including when the kernel is already deep in a call chain and the stack is nearly full. Without a separate IRQ stack, a nested interrupt could overflow the thread stack and corrupt kernel memory.

The IRQ stacks are allocated during boot by [`init_irq_stacks()`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/irq.c#L60):

```c
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

The stack switch happens in [`call_on_irq_stack()`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry.S#L868), which creates a frame record on the current stack (for unwinding), switches SP to the top of the per-CPU IRQ stack, calls the handler, then switches back:

```asm
SYM_FUNC_START(call_on_irq_stack)
    // save frame pointer and link register
    stp x29, x30, [sp, #-16]!
    mov x29, sp

    // load IRQ stack pointer and switch
    ldr_this_cpu x16, irq_stack_ptr, x17
    add sp, x16, #IRQ_STACK_SIZE
    blr x1                          // call the handler

    // switch back to original stack
    mov sp, x29
    ldp x29, x30, [sp], #16
    ret
SYM_FUNC_END(call_on_irq_stack)
```

```
  IRQ Stack Switch (call_on_irq_stack)
  ════════════════════════════════════

  Thread Stack                       Per-CPU IRQ Stack
  ────────────                       ─────────────────

  ┌────────────────┐                 ┌────────────────┐
  │ ... thread     │                 │                │
  │ call chain ... │                 │                │
  │                │                 │  IRQ handler   │
  │ ┌────────────┐ │    SP switch    │  call chain    │
  │ │ x29 (FP)   │ │ ═══════════►   │                │
  │ │ x30 (LR)   │ │                │                │
  │ └────────────┘ │                 │                │
  │ x29 = sp ──────╋────────────────►│ SP = top of    │
  │                │                 │ IRQ stack      │
  │                │    SP restore   │                │
  │                │ ◄═══════════    │                │
  └────────────────┘                 └────────────────┘
```

---

## Pseudo-NMI: Non-Maskable Interrupts on AArch64

AArch64 does not have a true hardware NMI in the way x86 does. However, the kernel implements **pseudo-NMI** support using the GIC's priority mechanism. The idea: instead of masking IRQs by setting PSTATE.I, the kernel masks them by raising the **Priority Mask Register (ICC_PMR_EL1)** to a threshold that blocks normal interrupts but still allows high-priority ones through. Interrupts with priority higher (numerically lower) than the mask can still be delivered even when "IRQs are disabled," effectively giving them NMI-like behavior.

```
  Pseudo-NMI Priority Scheme
  ══════════════════════════

  Priority     │  PMR threshold
  (lower =     │  ════════════
  higher       │
  priority)    │
               │
  0x00 ────────┤  ← NMI-priority interrupts  (ABOVE threshold → delivered)
               │
  0x20 ────────┤
               │
  0x40 ────────┤  ← PMR set here when "masking IRQs"
               │     ──────────────────────────────
  0x60 ────────┤
               │
  0x80 ────────┤  ← Normal IRQ priority       (BELOW threshold → blocked)
               │
  0xA0 ────────┤
               │
  0xF0 ────────┤  ← DEFAULT_PMR_VALUE (all interrupts pass)
               │
```

This feature is enabled by [`gic_enable_nmi_support()`](https://github.com/torvalds/linux/blob/v7.2-rc5/drivers/irqchip/irq-gic-v3.c#L1958) and requires `CONFIG_ARM64_PSEUDO_NMI` to be set. The entry code in `kernel_entry` saves and restores `ICC_PMR_EL1` alongside the normal register state ([`entry.S`, lines 312–322](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry.S#L312-L322)).

The GIC handler distinguishes pseudo-NMIs from regular IRQs by checking the **Running Priority Register (ICC_RPR_EL1)** via [`gic_rpr_is_nmi_prio()`](https://github.com/torvalds/linux/blob/v7.2-rc5/drivers/irqchip/irq-gic-v3.c#L805). If the running priority matches the NMI priority level, the interrupt is handled through the NMI path with `nmi_enter()`/`nmi_exit()` bracketing, which uses a more restrictive execution environment (no sleeping, limited lock acquisition).

---

## GIC Initialization: How It All Comes Together

The GIC driver initializes through a chain of function calls during kernel boot, starting from the device tree or ACPI table match:

```
  GIC Initialization Call Chain
  ═════════════════════════════

  gic_of_init()  or  gic_acpi_init()
      │
      ▼
  gic_init_bases()                            // central initialization
      │
      ├──► set_handle_irq(gic_handle_irq)     // install as root IRQ handler
      │
      ├──► gic_prio_init()                    // determine priority space
      │
      ├──► gic_dist_init()                    // configure the Distributor
      │        ├── disable Distributor
      │        ├── configure SPIs as Group 1
      │        ├── set default priorities
      │        ├── route all SPIs to boot CPU
      │        └── enable Distributor (ARE + G1A + G1)
      │
      ├──► gic_cpu_init()                     // configure this CPU's Redistributor
      │        ├── find Redistributor by MPIDR match
      │        ├── wake Redistributor
      │        ├── configure SGIs/PPIs as Group 1
      │        └── gic_cpu_sys_reg_init()     // configure CPU Interface registers
      │                ├── set PMR
      │                ├── reset BPR
      │                ├── configure EOI mode
      │                └── enable Group 1
      │
      ├──► gic_enable_nmi_support()           // enable pseudo-NMI if available
      │
      ├──► gic_smp_init()                     // allocate 8 SGIs for IPIs
      │
      └──► its_init() [if LPIs supported]    // initialize the ITS
```

The [`set_handle_irq()`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/irq.c#L100) call is the moment when the GIC driver plugs itself into the generic AArch64 interrupt framework. It writes the `gic_handle_irq` function pointer into the global [`handle_arch_irq`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/irq.c#L97) variable:

```c
int __init set_handle_irq(void (*handle_irq)(struct pt_regs *))
{
    if (handle_arch_irq != default_handle_irq)
        return -EBUSY;

    handle_arch_irq = handle_irq;
    pr_info("Root IRQ handler: %ps\n", handle_irq);
    return 0;
}
```

From this point on, every IRQ exception eventually calls `gic_handle_irq()`. The GIC driver is bound to the device tree via `IRQCHIP_DECLARE` at [`irq-gic-v3.c`, line 2268](https://github.com/torvalds/linux/blob/v7.2-rc5/drivers/irqchip/irq-gic-v3.c#L2268):

```c
IRQCHIP_DECLARE(gic_v3, "arm,gic-v3", gic_of_init);
```

---

## Summary

The AArch64 interrupt and exception architecture is a layered collaboration between hardware and software:

```
  Layered Architecture Overview
  ═════════════════════════════

  ┌─────────────────────────────────────────────────────────────────┐
  │  Layer 5: Driver Handlers                                       │
  │  request_irq() ISRs, do_page_fault(), do_el0_svc()             │
  ├─────────────────────────────────────────────────────────────────┤
  │  Layer 4: Kernel Dispatch                                       │
  │  gic_handle_irq() → domain → flow handler (IRQ path)           │
  │  el0t_64_sync_handler() → EC switch → fault_info[] (sync path) │
  ├─────────────────────────────────────────────────────────────────┤
  │  Layer 3: C Entry Handlers                                      │
  │  el0_interrupt(), el1_abort(), el0_da(), etc.                   │
  ├─────────────────────────────────────────────────────────────────┤
  │  Layer 2: Assembly Entry (entry.S)                              │
  │  kernel_ventry → entry_handler → kernel_entry / kernel_exit     │
  ├─────────────────────────────────────────────────────────────────┤
  │  Layer 1: Vector Table (16 entries, VBAR_EL1)                   │
  │  Routes by (source EL, exception type) → assembly stub          │
  ├─────────────────────────────────────────────────────────────────┤
  │  Layer 0: Hardware                                              │
  │  CPU: save PSTATE/ELR/ESR/FAR, mask DAIF, branch to vector     │
  │  GIC: collect, prioritize, route, signal IRQ/FIQ to core       │
  └─────────────────────────────────────────────────────────────────┘
```

1. **The CPU** detects events — either internally (synchronous exceptions like page faults) or via external signal lines from the GIC (asynchronous interrupts). It saves minimal state (PSTATE → SPSR_EL1, return address → ELR_EL1, syndrome → ESR_EL1), masks further exceptions, and branches to the vector table.

2. **The vector table** (16 entries, organized by source level and exception type) routes to the correct assembly stub in [`entry.S`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry.S), which saves the full register state and calls the appropriate C handler.

3. **For synchronous exceptions**, the C handler reads ESR_EL1 to determine the Exception Class, then dispatches to specialized handlers — [`do_mem_abort()`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/mm/fault.c#L980) for data/instruction aborts (which further dispatches through the [`fault_info[]`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/mm/fault.c#L913) table), `do_el0_svc()` for system calls, debug handlers for breakpoints and watchpoints.

4. **For asynchronous interrupts**, the C handler calls [`gic_handle_irq()`](https://github.com/torvalds/linux/blob/v7.2-rc5/drivers/irqchip/irq-gic-v3.c#L912), which reads the GIC's IAR register to discover the hardware INTID, performs the priority drop, and dispatches through the IRQ domain to the registered driver handler.

5. **The return path** restores all saved state and executes `eret` to atomically return to the interrupted context. For faults, the faulting instruction is retried; for interrupts, the next instruction continues.

The fundamental architectural insight is that AArch64 keeps the CPU core's exception mechanism simple and uniform — the same save/vector/restore cycle handles everything from a timer tick to a page fault to a system call — and pushes the complexity of interrupt source identification into the GIC and the kernel's software dispatch logic.

## References:
- https://support.arm.com/documentation/ihi0069/hb/
