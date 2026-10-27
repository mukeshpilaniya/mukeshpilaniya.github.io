---
title: Atomic Operators in the Linux Kernel
published: true
categories: [Synchronization]
tags: [atomic, atomic_t, refcount, lse, llsc, memory-ordering]
mermaid: true
---
# Atomic Operators in the Linux Kernel

Modern multi-core systems demand that the kernel operate correctly when multiple CPUs touch shared data simultaneously. Most C expressions that look like single operations — `count++`, `flags |= BIT(3)` — actually compile into multiple load, modify, and store instructions, leaving a window where another CPU can slip in and corrupt the result. **Atomic operators close that window: they are indivisible read-modify-write primitives the hardware guarantees will complete without interference, forming the foundation on which spinlocks, reference counters, and wait queues are all ultimately built.**

---

## Table of Contents

1. [Why Atomic Operators Are Required](#1-why-atomic-operators-are-required)
2. [Are Atomic Operations Architecture-Specific?](#2-are-atomic-operations-architecture-specific)
3. [The Software Layering Model](#3-the-software-layering-model)
4. [`atomic_t`, `atomic64_t`, and `atomic_long_t`](#4-atomic_t-atomic64_t-and-atomic_long_t)
5. [Behavior Without SMP](#5-behavior-without-smp)
6. [Initializing `atomic_t`](#6-initializing-atomic_t)
7. [Core Atomic Operations](#7-core-atomic-operations)
8. [AArch64 Architecture Implementation](#8-aarch64-architecture-implementation)
   - [Runtime Dispatch: LL/SC vs LSE](#81-runtime-dispatch-llsc-vs-lse)
   - [Path 1 — LL/SC: `LDXR` / `STXR`](#82-path-1--llsc-ldxr--stxr)
   - [Path 2 — LSE: Dedicated Atomic Instructions](#83-path-2--lse-dedicated-atomic-instructions)
9. [Memory Ordering Guarantees](#9-memory-ordering-guarantees)
10. [Atomic Operations and Test](#10-atomic-operations-and-test)
11. [Atomic Bitwise Operations](#11-atomic-bitwise-operations)
12. [`atomic_cmpxchg` — Compare and Swap](#12-atomic_cmpxchg--compare-and-swap)
13. [`atomic_xchg` — Unconditional Exchange](#13-atomic_xchg--unconditional-exchange)
14. [Common Use Cases and Example](#14-common-use-cases-and-example)
15. [Problems With Atomic Instructions](#15-problems-with-atomic-instructions-limitations-on-complex-data)
   - [15.1 Width Limit](#151--problem-width-limit-single-word-only)
   - [15.2 Cache Line Bouncing / False Sharing](#152--problem-cache-line-bouncing-and-false-sharing)
   - [15.3 Reservation Granule Interference](#153--problem-llsc-exclusive-reservation-granule-interference)
   - [15.4 LL/SC Starvation Under Contention](#154--problem-llsc-starvation-under-high-contention)
   - [15.5 Spinning Wastes Power (WFE/SEVL)](#155--problem-spinning-wastes-power-and-the-wfesevl-solution)
   - [15.6 CLREX and Context Switches](#156--problem-clrex-and-exclusive-monitor-state-across-context-switches)
   - [15.7 Integer Overflow and `refcount_t`](#157--problem-integer-overflow-and-atomic_t-vs-refcount_t)
   - [15.8 Forbidden in `noinstr` Code](#158--problem-atomic_-is-forbidden-in-noinstr-code)
   - [15.9 Multi-Variable Invariants](#159--problem-atomics-cannot-replace-locks-for-multi-variable-invariants)
   - [Summary Table](#summary-table--problems-with-atomic-instructions)
   - [15.10 Per-CPU Variables vs Atomic Variables](#1510--per-cpu-variables-vs-atomic-variables)
16. [Lock-Free Programming: Trade-offs](#16-lock-free-programming-trade-offs)
17. [Complete Atomic Operation Reference](#17-complete-atomic-operation-reference)

---

## 1. Why Atomic Operators Are Required

A plain integer increment compiles to three separate machine instructions on any architecture:

```
ldr  w0, [x1]    ; (1) load current value
add  w0, w0, #1  ; (2) add one
str  w0, [x1]    ; (3) store result back
```

On an SMP system two CPUs executing those steps concurrently can both read the same stale value, both add one, and write the same result — losing a count. This is the classic **lost update** problem.

```
CPU 0                           CPU 1
─────────────────────────────────────────────────────
ldr  w0, [x1]   ; w0 = 5
                                ldr  w0, [x1]   ; w0 = 5
add  w0, w0, #1 ; w0 = 6
str  w0, [x1]   ; *x1 = 6
                                add  w0, w0, #1 ; w0 = 6
                                str  w0, [x1]   ; *x1 = 6  ← LOST UPDATE
```

Expected result: **7**. Actual result: **6**.

The same race is reproducible in user space. Two pthreads increment a shared counter one million times each — the final value is consistently less than 2,000,000:

```c
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

static int glob = 0;

static void *threadFunc(void *arg)
{
    int loops = *(int *)arg;
    for (int j = 0; j < loops; j++)
        glob++;          /* load → add → store: not atomic */
    return NULL;
}

int main(void)
{
    pthread_t t1, t2;
    int loops = 1000000;

    pthread_create(&t1, NULL, threadFunc, &loops);
    pthread_create(&t2, NULL, threadFunc, &loops);
    pthread_join(t1, NULL);
    pthread_join(t2, NULL);

    /* Expected: 2000000. Actual: something less due to lost updates. */
    printf("glob = %d\n", glob);
    return 0;
}
```

The only fixes are a lock or a hardware primitive that collapses those three steps into one indivisible operation. Locks work but carry non-trivial cost even when uncontended: **acquiring a spinlock requires exclusive cache-line ownership, a memory barrier, and a store. Atomic operators deliver the same safety guarantee at a fraction of that cost when all you need is a counter or a flag.**

---

## 2. Are Atomic Operations Architecture-Specific?

The **API is architecture-independent**. `atomic_inc()`, `atomic_read()`, `atomic_cmpxchg()`, and their siblings are the same C names on every architecture the kernel supports. What differs is the hardware instruction sequence behind them.

The generic header [/include/linux/atomic.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/atomic.h) pulls in `<asm/atomic.h>` from the current architecture and then provides fallback implementations for any operations the architecture did not supply. On AArch64 that architecture header is [/arch/arm64/include/asm/atomic.h](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/atomic.h), which selects between two entirely different instruction paths depending on the CPU's runtime capabilities.

---

## 3. The Software Layering Model

Every `atomic_add(i, v)` call travels through four distinct layers before reaching silicon:

```
 ┌──────────────────────────────────────────────────────────────────┐
 │                     User / Driver Code                           │
 │                  atomic_add(i, v)                                │
 └───────────────────────────┬──────────────────────────────────────┘
                             │
 ┌───────────────────────────▼──────────────────────────────────────┐
 │               Instrumented Layer                                 │
 │  include/linux/atomic/atomic-instrumented.h                      │
 │  • Hooks KASAN / KCSAN sanitizer tracking                        │
 │  • Calls raw_atomic_add()                                        │
 └───────────────────────────┬──────────────────────────────────────┘
                             │
 ┌───────────────────────────▼──────────────────────────────────────┐
 │             Generic Fallback Layer                               │
 │  include/linux/atomic/atomic-arch-fallback.h                     │
 │  • Synthesizes inc/dec/and/or from add/fetch_add                 │
 │  • Builds _acquire/_release variants from _relaxed + barriers    │
 └───────────────────────────┬──────────────────────────────────────┘
                             │
 ┌───────────────────────────▼──────────────────────────────────────┐
 │          AArch64 Architecture Layer                              │
 │  arch/arm64/include/asm/atomic.h                                 │
 │  • ATOMIC_OP / ATOMIC_FETCH_OP macro expansion                   │
 │  • Delegates to __lse_ll_sc_body()                               │
 └──────────────┬────────────────────────────┬─────────────────────┘
                │                            │
 ┌──────────────▼──────────┐  ┌──────────────▼──────────────────────┐
 │   LL/SC Path            │  │   LSE Path                          │
 │   atomic_ll_sc.h        │  │   atomic_lse.h                      │
 │   LDXR / STXR loop      │  │   STADD / LDADD / CAS / SWP         │
 │   (all ARMv8.0+ CPUs)   │  │   (ARMv8.1+ / LSE-capable CPUs)     │
 └─────────────────────────┘  └─────────────────────────────────────┘
```

---

## 4. `atomic_t`, `atomic64_t`, and `atomic_long_t`

### Why a Dedicated Type?

Wrapping the counter in a struct achieves two things. First, it makes misuse detectable at compile time — you cannot pass an `atomic_t *` to a function expecting `int *` without an explicit cast. Second, the kernel's **sparse** static checker can enforce that `->counter` is only touched through the proper API, catching accidental plain reads or writes in review.

### Definitions

Defined in [/include/linux/types.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/types.h#L188-L198):

```c
typedef struct {
    int __aligned(sizeof(int)) counter;
} atomic_t;

#ifdef CONFIG_64BIT
typedef struct {
    s64 counter;
} atomic64_t;
#endif

#define ATOMIC_INIT(i)  { (i) }
```

The **`__aligned(sizeof(int))`** annotation on `atomic_t` is not cosmetic. Misaligned multi-byte stores are not guaranteed to be atomic on any architecture; the alignment forces the compiler to place the counter at a natural 4-byte boundary, which is a hardware requirement for single-copy atomicity on AArch64.

`atomic64_t` is only present on `CONFIG_64BIT` builds. On AArch64 this is always true, so both types are always available.

### Type Hierarchy and Relationships

```
                    ┌──────────────────────────────────┐
                    │     Linux Atomic Type Hierarchy  │
                    └──────────────────────────────────┘

          atomic_t                          atomic64_t
    ┌───────────────────┐            ┌───────────────────┐
    │ struct {          │            │ struct {           │
    │   int counter;    │            │   s64 counter;     │
    │ } __aligned(4)    │            │ }                  │
    │                   │            │                    │
    │  Always present   │            │  CONFIG_64BIT only │
    │  (32-bit counter) │            │  (64-bit counter)  │
    └─────────┬─────────┘            └────────┬───────────┘
              │                               │
              │ (32-bit kernel)               │ (64-bit kernel / AArch64)
              └──────────────┬────────────────┘
                             │
                       atomic_long_t
                  ┌────────────────────┐
                  │ typedef atomic64_t │  ← on AArch64 (64-bit)
                  │ typedef atomic_t   │  ← on 32-bit
                  │                   │
                  │ Matches sizeof     │
                  │ (unsigned long)    │
                  └────────────────────┘
```

Defined in [/include/linux/atomic/atomic-long.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/atomic/atomic-long.h#L12-L22):

```c
#ifdef CONFIG_64BIT
typedef atomic64_t atomic_long_t;
#else
typedef atomic_t atomic_long_t;
#endif
```

**Use `atomic_long_t`** when the variable must match the width of a pointer — for masked pointers, addresses stored as integers, or bitmasks spanning the full pointer range. It keeps code portable to 32-bit without `#ifdef`.

`atomic64_t` operations mirror the 32-bit API exactly; the format specifier is `%lld` since the counter is `s64`:

```c
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/atomic.h>

MODULE_LICENSE("GPL");

static atomic64_t val = ATOMIC64_INIT(0);

static int test_hello_init(void)
{
    pr_info("%s: Value after initialization: %lld\n", __func__, atomic64_read(&val));
    atomic64_set(&val, 4);
    pr_info("%s: Value after set(4): %lld\n", __func__, atomic64_read(&val));
    atomic64_dec(&val);
    pr_info("%s: Value after dec: %lld\n", __func__, atomic64_read(&val));
    atomic64_inc(&val);
    pr_info("%s: Value after inc: %lld\n", __func__, atomic64_read(&val));
    atomic64_add(3, &val);
    pr_info("%s: Value after add(3): %lld\n", __func__, atomic64_read(&val));
    atomic64_sub(2, &val);
    pr_info("%s: Value after sub(2): %lld\n", __func__, atomic64_read(&val));
    return -1;
}

static void test_hello_exit(void)
{
    pr_info("%s: In exit\n", __func__);
}

module_init(test_hello_init);
module_exit(test_hello_exit);
```

---

## 5. Behavior Without SMP

When compiled without `CONFIG_SMP` (uniprocessor), only one CPU exists, so concurrent access from another core is impossible. The kernel exploits this:

```
                    ┌─────────────────────────┐
                    │   CONFIG_SMP enabled?    │
                    └────────────┬────────────┘
                                 │
              ┌──────────────────┴──────────────────┐
             YES                                    NO
              │                                      │
 ┌────────────▼────────────┐          ┌──────────────▼──────────────┐
 │ Full SMP atomics        │          │ Simplified UP atomics        │
 │ LDXR/STXR loops or      │          │ Plain load + store           │
 │ LSE instructions        │          │ DMB ISH barriers elided      │
 │ DMB ISH barriers active │          │ Exclusive instructions       │
 └─────────────────────────┘          │ may be omitted               │
                                      └─────────────────────────────┘
```

For most embedded AArch64 targets this is a meaningful performance win, though in practice AArch64 boards are almost universally multi-core.

---

## 6. Initializing `atomic_t`

Two initialization paths exist depending on when the variable is initialized:

```
        Need to initialize atomic_t
               │
    ┌──────────┴──────────┐
    │                     │
At compile time       At runtime
(global / static)    (on heap / stack)
    │                     │
    ▼                     ▼
ATOMIC_INIT(val)    atomic_set(&v, val)
struct initializer  __WRITE_ONCE(counter, val)
```

**Static initialization** (at definition time):

```c
#define ATOMIC_INIT(i)  { (i) }

static atomic_t refcount = ATOMIC_INIT(0);
static atomic_t active   = ATOMIC_INIT(1);
```

**Dynamic initialization** (at runtime):

```c
atomic_t refcount;
atomic_set(&refcount, 0);
```

`atomic_set()` traces through the instrumented layer in [/include/linux/atomic/atomic-instrumented.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/atomic/atomic-instrumented.h#L65-L68) to the AArch64 arch implementation at line 103 of [/arch/arm64/include/asm/atomic.h](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/atomic.h#L103):

```c
#define arch_atomic_set(v, i)   __WRITE_ONCE(((v)->counter), (i))
```

This is a plain store with a **compiler barrier**. No exclusive instruction is needed because a single naturally-aligned store is inherently atomic at the hardware level on AArch64.

---

## 7. Core Atomic Operations

| Function | Description | Returns |
|---|---|---|
| `atomic_read(v)` | Load counter, relaxed ordering | current value |
| `atomic_read_acquire(v)` | Load counter, acquire ordering | current value |
| `atomic_set(v, i)` | Store `i`, relaxed ordering | — |
| `atomic_set_release(v, i)` | Store `i`, release ordering | — |
| `atomic_add(i, v)` | Add `i` | — |
| `atomic_sub(i, v)` | Subtract `i` | — |
| `atomic_inc(v)` | Add 1 | — |
| `atomic_dec(v)` | Subtract 1 | — |
| `atomic_add_return(i, v)` | Add `i`, full barrier | **new** value |
| `atomic_sub_return(i, v)` | Subtract `i`, full barrier | **new** value |
| `atomic_fetch_add(i, v)` | Add `i`, full barrier | **old** value |
| `atomic_fetch_sub(i, v)` | Subtract `i`, full barrier | **old** value |
| `atomic_fetch_and(i, v)` | Bitwise AND | **old** value |
| `atomic_fetch_or(i, v)` | Bitwise OR | **old** value |
| `atomic_fetch_xor(i, v)` | Bitwise XOR | **old** value |
| `atomic_and(i, v)` | Bitwise AND, no return | — |
| `atomic_or(i, v)` | Bitwise OR, no return | — |
| `atomic_xor(i, v)` | Bitwise XOR, no return | — |
| `atomic_andnot(i, v)` | Clear bits in `i`, no return | — |

All fetch/return variants also come with `_relaxed`, `_acquire`, and `_release` suffixes — covered in depth in [§9](#9-memory-ordering-guarantees).

Kernel module demonstrating the fundamental read/set/inc/dec/add/sub operations:

```c
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/atomic.h>

MODULE_LICENSE("GPL");

static atomic_t val = ATOMIC_INIT(0);

static int test_hello_init(void)
{
    pr_info("%s: Value after initialization: %d\n", __func__, atomic_read(&val));
    atomic_set(&val, 4);
    pr_info("%s: Value after set(4): %d\n", __func__, atomic_read(&val));
    atomic_dec(&val);
    pr_info("%s: Value after dec: %d\n", __func__, atomic_read(&val));
    atomic_inc(&val);
    pr_info("%s: Value after inc: %d\n", __func__, atomic_read(&val));
    atomic_add(3, &val);
    pr_info("%s: Value after add(3): %d\n", __func__, atomic_read(&val));
    atomic_sub(2, &val);
    pr_info("%s: Value after sub(2): %d\n", __func__, atomic_read(&val));
    return -1;
}

static void test_hello_exit(void)
{
    pr_info("%s: In exit\n", __func__);
}

module_init(test_hello_init);
module_exit(test_hello_exit);
```

`add_return` and `sub_return` — return the value **after** the operation; `fetch_add` / `fetch_sub` return the value **before**:

```c
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/atomic.h>

MODULE_LICENSE("GPL");

static atomic_t val = ATOMIC_INIT(0);

static int test_hello_init(void)
{
    atomic_set(&val, 4);
    pr_info("%s: Value after set(4): %d\n", __func__, atomic_read(&val));

    /* val=4+3=7, returns 7 (new value) */
    pr_info("%s: atomic_add_return(3): %d\n", __func__, atomic_add_return(3, &val));
    /* val=7-2=5, returns 5 (new value) */
    pr_info("%s: atomic_sub_return(2): %d\n", __func__, atomic_sub_return(2, &val));
    /* val=5+1=6, returns 6 */
    pr_info("%s: atomic_inc_return: %d\n", __func__, atomic_inc_return(&val));
    /* val=6-1=5, returns 5 */
    pr_info("%s: atomic_dec_return: %d\n", __func__, atomic_dec_return(&val));
    return -1;
}

static void test_hello_exit(void)
{
    pr_info("%s: In exit\n", __func__);
}

module_init(test_hello_init);
module_exit(test_hello_exit);
```

---

## 8. AArch64 Architecture Implementation

AArch64 exposes two mechanisms for atomic read-modify-write. The kernel selects between them at **runtime** based on whether the CPU implements the **Large System Extensions (LSE)**, which became mandatory from Armv8.1-A.

### 8.1 Runtime Dispatch: LL/SC vs LSE

Every atomic operation in [/arch/arm64/include/asm/atomic.h](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/atomic.h#L19-L31) expands through the `ATOMIC_OP` macro to call `__lse_ll_sc_body`, defined in [/arch/arm64/include/asm/lse.h](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/lse.h#L17-L22):

```c
#define __lse_ll_sc_body(op, ...)                           \
({                                                          \
    alternative_has_cap_likely(ARM64_HAS_LSE_ATOMICS) ?     \
        __lse_##op(__VA_ARGS__) :                           \
        __ll_sc_##op(__VA_ARGS__);                          \
})
```

This is not a branch — it is an **in-place binary patch**. The boot sequence works like this:

```
Kernel image loaded into memory
           │
           ▼
  Boot CPU detected
           │
           ▼
  alternative_has_cap_likely(ARM64_HAS_LSE_ATOMICS)?
           │
    ┌──────┴───────┐
   YES             NO
    │               │
    ▼               ▼
Kernel walks    Binary stays
.altinstructions    as-is:
section and         LL/SC path
overwrites          executed
LL/SC bytes    at runtime
with LSE bytes
    │
    ▼
All future atomic ops
execute LSE path —
zero branch overhead
```

The `__LSE_PREAMBLE` directive emitted before every LSE instruction block (`.arch_extension lse\n`) tells the assembler to accept LSE opcodes, keeping the build compatible with toolchains targeting older ARM specifications.

The `ALTERNATIVE` macro in [/arch/arm64/include/asm/alternative-macros.h](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/alternative-macros.h#L56-L72) emits both the original (LL/SC) instruction block and the replacement (LSE) block into a `.altinstructions` ELF section, which the patching engine processes at boot:

```
ELF Sections (simplified)
┌─────────────────────────┐
│  .text                  │
│  661: LDXR / ADD / STXR │  ← original LL/SC code
│  662:                   │
├─────────────────────────┤
│  .altinstructions       │
│  { cap: LSE_ATOMICS,    │  ← metadata: "if LSE, patch 661→662
│    orig: 661, alt: 663 }│     with instructions at 663→664"
├─────────────────────────┤
│  .subsection 1          │
│  663: STADD             │  ← replacement LSE instruction(s)
│  664:                   │
└─────────────────────────┘
          │  at boot
          ▼
if ARM64_HAS_LSE_ATOMICS:
  memcpy(661, 663, len)   ← patch in place
```

---

### 8.2 Path 1 — LL/SC: `LDXR` / `STXR`

Defined in [/arch/arm64/include/asm/atomic_ll_sc.h](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/atomic_ll_sc.h#L25-L40).

The **Load-Link / Store-Conditional** mechanism uses a per-CPU **exclusive monitor** — a hardware state machine that tracks whether the reserved address has been written since the last `LDXR`.

#### LL/SC Retry Loop Flow

```
     atomic_add(i, v)
           │
           ▼
   prfm pstl1strm, [v]
   (prefetch cacheline for write)
           │
           ▼
    ┌──────────────────┐
    │  ldxr w0, [v]    │ ◄────────────────────────┐
    │  (Load Exclusive)│                          │
    │  Open reservation│                          │
    │  on address v    │                          │
    └────────┬─────────┘                          │
             │                                    │
             ▼                                    │
    add w0, w0, w_i                               │
    (modify in register)                          │
             │                                    │
             ▼                                    │
    ┌──────────────────────┐                      │
    │  stxr w1, w0, [v]    │                      │
    │  (Store Exclusive)   │                      │
    │  Reservation intact? │                      │
    └────────┬─────────────┘                      │
             │                                    │
      ┌──────┴──────┐                             │
      │             │                             │
     w1==0         w1==1                          │
   (SUCCESS)     (FAILED — another CPU            │
      │           wrote v, monitor cleared)       │
      ▼                    │                      │
   [done]                  └──────────────────────┘
                           (retry from ldxr)
```

The `prfm pstl1strm` (Prefetch Memory, PST=prepare-for-store, L1=L1 cache, STR=streaming) hint pulls the cache line into L1 with exclusive ownership before the `LDXR`, dramatically reducing the latency of the exclusive load.

#### Acquire and Release Variants

The macro in `atomic_ll_sc.h` generates four variants per operation by parameterizing the exclusive instruction suffixes:

```
Variant         Load instr    Store instr    Post-barrier
─────────────────────────────────────────────────────────
(default)       LDXR          STLXR          DMB ISH
_relaxed        LDXR          STXR           (none)
_acquire        LDAXR         STXR           (none)
_release        LDXR          STLXR          (none)
```

- **`LDAXR`** (Load-Acquire Exclusive) prevents any subsequent memory access from being reordered before the load.
- **`STLXR`** (Store-Release Exclusive) prevents any prior memory access from being reordered after the store.
- The fully-ordered default adds `DMB ISH` after the loop to drain all prior accesses from the store buffer.

---

### 8.3 Path 2 — LSE: Dedicated Atomic Instructions

Defined in [/arch/arm64/include/asm/atomic_lse.h](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/atomic_lse.h).

**LSE** (Large System Extensions), mandatory from Armv8.1-A, adds hardware-accelerated single-instruction atomics. The interconnect, not software, guarantees atomicity. No retry loop, no prefetch hint, no status register check.

#### LSE Instruction Mapping

| C operation | LSE instruction (no return) | LSE instruction (returns old value) |
|---|---|---|
| `atomic_add` | `STADD` | `LDADD` |
| `atomic_or` | `STSET` | `LDSET` |
| `atomic_andnot` | `STCLR` | `LDCLR` |
| `atomic_xor` | `STEOR` | `LDEOR` |
| `atomic_cmpxchg` | — | `CAS` |
| `atomic_xchg` | — | `SWP` |

#### Ordering Suffix Encoding

LSE instructions encode memory ordering directly into the opcode suffix, eliminating the need for separate barrier instructions:

```
Instruction suffix → Memory ordering

LDADD    → Relaxed   (no ordering)
LDADDA   → Acquire   (loads after cannot move before)
LDADDL   → Release   (stores before cannot move after)
LDADDAL  → Full      (both acquire + release)
```

The LSE `atomic_add` reduces to a single line of assembly:

```c
// From atomic_lse.h — __lse_atomic_add()
asm volatile(
    __LSE_PREAMBLE              // .arch_extension lse
    "   stadd   %w[i], %[v]\n"  // atomic: *v += i, no return value
    : [v] "+Q" (v->counter)
    : [i] "r" (i));
```

Compare this to the LL/SC loop: five instructions including a conditional branch vs one instruction with no loop.

---

## 9. Memory Ordering Guarantees

AArch64 implements a **weakly-ordered** memory model. The CPU and interconnect are free to reorder loads and stores for performance as long as no single-thread data dependency is violated. Atomic operations without explicit ordering constraints give no multi-thread ordering guarantees.

The kernel exposes four ordering tiers:

```
Strongest guarantee                               Weakest guarantee
      │                                                  │
      ▼                                                  ▼
 ┌──────────┐    ┌───────────┐    ┌───────────┐    ┌──────────┐
 │  (none)  │    │ _acquire  │    │ _release  │    │ _relaxed │
 │ Full     │    │ Loads     │    │ Stores    │    │ No order │
 │ barrier  │    │ after can │    │ before    │    │ guarantee│
 │ both     │    │ not move  │    │ cannot    │    │          │
 │ sides    │    │ before    │    │ move after│    │          │
 └────┬─────┘    └─────┬─────┘    └─────┬─────┘    └────┬─────┘
      │                │                │                │
LL/SC: LDXR       LDAXR+STXR      LDXR+STLXR       LDXR+STXR
       STLXR+                                       (no barriers)
       DMB ISH
LSE:  LDADDAL     LDADDA          LDADDL            LDADD
```

The SMP barrier macros in [/arch/arm64/include/asm/barrier.h](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/barrier.h#L126-L128) map directly to ARM barrier instructions:

```c
#define __smp_mb()   dmb(ish)    /* full barrier, Inner Shareable domain */
#define __smp_rmb()  dmb(ishld)  /* load-only barrier                   */
#define __smp_wmb()  dmb(ishst)  /* store-only barrier                  */
```

`ISH` (Inner Shareable) covers all CPUs in the cluster. DMA masters outside the cluster require `OSH` (Outer Shareable) barriers instead.

#### When to Add an Explicit Barrier

```
Using _relaxed variants?
        │
   ┌────┴────┐
  YES        NO
   │          │
   │     Default (fully-ordered) ops are sufficient
   │     for normal producer-consumer patterns.
   │
   ▼
Publishing result to another CPU?
        │
   ┌────┴────┐
  YES        NO
   │          │
   │     No barrier needed —
   │     the stats are self-contained.
   │
   ▼
Insert smp_mb() before the publish.
Use _acquire on consumer side,
_release on producer side for
the minimum correct overhead.
```

---

## 10. Atomic Operations and Test

Several operations combine a modification with a test of the result in a **single atomic step** — the test cannot be separated from the operation without re-introducing a race.

```c
/* Decrement; return true if result is zero */
bool atomic_dec_and_test(atomic_t *v);

/* Increment; return true if result is zero */
bool atomic_inc_and_test(atomic_t *v);

/* Subtract i; return true if result is zero */
bool atomic_sub_and_test(int i, atomic_t *v);

/* Add i; return true if result is negative */
bool atomic_add_negative(int i, atomic_t *v);
```

Defined in the generic fallback layer at [/include/linux/atomic/atomic-arch-fallback.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/atomic/atomic-arch-fallback.h#L2265-L2320). The pattern is: call `atomic_sub_return` (or `atomic_add_return`), then compare the result to zero.

#### Flow for `atomic_dec_and_test`

```
atomic_dec_and_test(v)
         │
         ▼
  atomic_sub_return(1, v)      ← atomic: v -= 1, returns new value
         │
         ▼
  result == 0 ?
     /        \
   YES          NO
    │            │
 return true   return false
 (last holder) (still live)
```

On AArch64 with LL/SC the subtract uses `SUBS` (sets condition flags as a side effect), so no extra comparison instruction is needed — the branch tests the zero flag directly. On LSE the fetch-sub returns the old value; the new value is computed by the caller and compared in software, but single-instruction atomicity of the decrement itself is preserved.

Kernel module tracing each test-and-operate variant through a sequence of known values:

```c
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/atomic.h>

MODULE_LICENSE("GPL");

static atomic_t val = ATOMIC_INIT(0);

static int test_hello_init(void)
{
    pr_info("%s: Value after initialization: %d\n", __func__, atomic_read(&val));
    atomic_set(&val, 4);
    pr_info("%s: Value after setting to 4: %d\n", __func__, atomic_read(&val));

    /* val=4, sub 4 → val=0, result is zero → returns 1 */
    pr_info("%s: atomic_sub_and_test(4): %d\n", __func__, atomic_sub_and_test(4, &val));

    /* val=0, add -1 → val=-1, result is negative → returns 1 */
    pr_info("%s: atomic_add_negative(-1): %d\n", __func__, atomic_add_negative(-1, &val));

    /* val=-1, inc → val=0, result is zero → returns 1 */
    pr_info("%s: atomic_inc_and_test: %d\n", __func__, atomic_inc_and_test(&val));

    /* val=0, inc → val=1, result non-zero → returns 0 */
    pr_info("%s: atomic_inc_and_test: %d\n", __func__, atomic_inc_and_test(&val));

    /* val=1, dec → val=0, result is zero → returns 1 */
    pr_info("%s: atomic_dec_and_test: %d\n", __func__, atomic_dec_and_test(&val));

    /* val=0, dec → val=-1, result non-zero → returns 0 */
    pr_info("%s: atomic_dec_and_test: %d\n", __func__, atomic_dec_and_test(&val));

    return -1;
}

static void test_hello_exit(void)
{
    pr_info("%s: In exit\n", __func__);
}

module_init(test_hello_init);
module_exit(test_hello_exit);
```

---

## 11. Atomic Bitwise Operations

The bitwise family operates on individual bits within `unsigned long` bitmaps — not on `atomic_t` values. The distinction is important: `atomic_t` wraps a 32-bit counter, while bitops work on arbitrarily large arrays of `unsigned long` words addressed by a bit index.

```c
void set_bit  (unsigned long nr, volatile unsigned long *addr); /* atomic */
void clear_bit(unsigned long nr, volatile unsigned long *addr); /* atomic */
int  test_bit (unsigned long nr, const volatile unsigned long *addr); /* not atomic */

int test_and_set_bit  (unsigned long nr, volatile unsigned long *addr); /* atomic, returns old */
int test_and_clear_bit(unsigned long nr, volatile unsigned long *addr); /* atomic, returns old */
int test_and_change_bit(unsigned long nr, volatile unsigned long *addr);/* atomic, returns old */

/* Non-atomic — only safe under lock or on UP */
void __set_bit  (unsigned long nr, volatile unsigned long *addr);
void __clear_bit(unsigned long nr, volatile unsigned long *addr);
int  __test_and_set_bit(unsigned long nr, volatile unsigned long *addr);
```

#### How `test_and_set_bit` Works on AArch64

```
LL/SC path:                         LSE path:
                                    (single instruction)
prfm pstl1strm, [word_addr]
1:                                  ldset  x_bit, x_old, [word_addr]
  ldxr   x_old, [word_addr]             │
  orr    x_new, x_old, x_bit_mask       │  atomically:
  stxr   w_tmp, x_new, [word_addr]      │    old = *word_addr
  cbnz   w_tmp, 1b                      │    *word_addr |= bit_mask
                                         │    return old
return (x_old >> nr) & 1           return (x_old >> nr) & 1
```

The sync variants (`sync_set_bit`, `sync_test_and_set_bit`) in [/arch/arm64/include/asm/sync_bitops.h](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/sync_bitops.h#L18-L24) are simple aliases for the fully-ordered versions — AArch64 always makes these SMP-safe.

`set_bit`, `clear_bit`, and `change_bit` on a raw `unsigned long`:

```c
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/bitops.h>

MODULE_LICENSE("GPL");

static unsigned long addr = 0x50;   /* 0101 0000 */

static int test_hello_init(void)
{
    pr_info("Initial value: %02lx\n", addr);

    set_bit(0, &addr);              /* 0101 0000 → 0101 0001 */
    pr_info("After set_bit(0):    %02lx\n", addr);

    clear_bit(4, &addr);            /* 0101 0001 → 0100 0001 */
    pr_info("After clear_bit(4):  %02lx\n", addr);

    change_bit(0, &addr);           /* 0100 0001 → 0100 0000 */
    pr_info("After change_bit(0): %02lx\n", addr);

    return -1;
}

static void test_hello_exit(void)
{
    pr_info("%s: In exit\n", __func__);
}

module_init(test_hello_init);
module_exit(test_hello_exit);
```

`test_and_set_bit`, `test_and_clear_bit`, and `test_and_change_bit` — each returns the bit's value **before** the operation:

```c
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/bitops.h>

MODULE_LICENSE("GPL");

static unsigned long addr = 0x50;   /* 0101 0000 — bit 0 is clear */

static int test_hello_init(void)
{
    pr_info("Initial value: %02lx\n", addr);

    /* bit 0 was 0 → returns 0, sets bit 0, addr = 0x51 */
    pr_info("test_and_set_bit(0):    %d\n", test_and_set_bit(0, &addr));
    pr_info("After: %02lx\n", addr);

    /* bit 0 was 1 → returns 1, clears bit 0, addr = 0x50 */
    pr_info("test_and_clear_bit(0):  %d\n", test_and_clear_bit(0, &addr));
    pr_info("After: %02lx\n", addr);

    /* bit 0 was 0 → returns 0, flips bit 0, addr = 0x51 */
    pr_info("test_and_change_bit(0): %d\n", test_and_change_bit(0, &addr));
    pr_info("After: %02lx\n", addr);

    return -1;
}

static void test_hello_exit(void)
{
    pr_info("%s: In exit\n", __func__);
}

module_init(test_hello_init);
module_exit(test_hello_exit);
```

---

## 12. `atomic_cmpxchg` — Compare and Swap

**Compare-and-swap (CAS)** is the foundational primitive for lock-free data structures. It atomically compares a value against an expected old value and, only if they match, replaces it with a new value — all in one uninterruptible operation.

```c
int atomic_cmpxchg(atomic_t *v, int old, int new);
/* Returns the value that was in *v at the moment of the operation */
```

#### CAS Decision Flow

```
atomic_cmpxchg(v, old, new)
        │
        ▼
   Read *v atomically
        │
   *v == old ?
   /           \
 YES            NO
  │              │
  Write new      Do NOT write
  to *v          to *v
  │              │
  └──────┬───────┘
         ▼
   Return the old value
   that was in *v
   (caller tests: returned == old
    means the swap succeeded)
```

### LL/SC Implementation

In [/arch/arm64/include/asm/atomic_ll_sc.h](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/atomic_ll_sc.h#L239-L271):

```asm
    prfm    pstl1strm, [ptr]
1:  ldxr    w_cur, [ptr]              ; exclusive load — open reservation
    eor     w_tmp, w_cur, w_old       ; compare: old XOR current
    cbnz    w_tmp, 2f                 ; not equal → exit, do not store
    stxr    w_tmp, w_new, [ptr]       ; equal → try to store new value
    cbnz    w_tmp, 1b                 ; store failed → retry entire loop
    dmb     ish
2:  ; w_cur holds the value that was at *ptr
```

The comparison uses `EOR` (XOR) followed by `CBNZ` (compare-and-branch-if-non-zero). This avoids touching the ARM condition flags (NZCV), which matters for callers that need to preserve flag state across the CAS.

### LSE Implementation

In [/arch/arm64/include/asm/atomic_lse.h](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/atomic_lse.h#L248-L282):

```asm
    casal   w_old, w_new, [ptr]
    ; CASAL: Compare-And-Swap Acquire-Release
    ; If *ptr == w_old: write w_new, w_old ← old value
    ; If *ptr != w_old: w_old ← *ptr       (no write)
```

`CASAL` is a single instruction. No loop, no retry, no prefetch. The `AL` suffix encodes full acquire-release ordering directly in the opcode. The register that held `old` is updated in-place with whatever value was actually in memory, making the result available to the caller immediately.

### LL/SC vs LSE CAS Comparison

```
LL/SC CAS (5+ instructions, may loop):    LSE CAS (1 instruction, no loop):

prfm pstl1strm, [ptr]                     casal  w_old, w_new, [ptr]
1:
  ldxr  w_cur, [ptr]
  eor   w_tmp, w_cur, w_old
  cbnz  w_tmp, 2f
  stxr  w_tmp, w_new, [ptr]
  cbnz  w_tmp, 1b
  dmb   ish
2:
```

Kernel module exercising `atomic_fetch_add`, `atomic_fetch_sub`, `atomic_cmpxchg` (matching and non-matching), and `atomic_xchg` in sequence:

```c
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/atomic.h>

MODULE_LICENSE("GPL");

atomic_t val = ATOMIC_INIT(0);

static int test_hello_init(void)
{
    pr_info("%s: Value after initialization: %d\n", __func__, atomic_read(&val));
    atomic_set(&val, 4);
    pr_info("%s: Value after setting to 4: %d\n", __func__, atomic_read(&val));

    /* returns old value (4), val becomes 6 */
    pr_info("%s: atomic_fetch_add(2): %d\n", __func__, atomic_fetch_add(2, &val));
    pr_info("%s: atomic_read: %d\n", __func__, atomic_read(&val));

    /* returns old value (6), val becomes 5 */
    pr_info("%s: atomic_fetch_sub(1): %d\n", __func__, atomic_fetch_sub(1, &val));
    pr_info("%s: atomic_read: %d\n", __func__, atomic_read(&val));

    /* expected=2, actual=5 → no swap, returns 5 */
    pr_info("%s: atomic_cmpxchg(2, 3): %d\n", __func__, atomic_cmpxchg(&val, 2, 3));
    /* expected=5, actual=5 → swap to 3, returns 5 */
    pr_info("%s: atomic_cmpxchg(5, 3): %d\n", __func__, atomic_cmpxchg(&val, 5, 3));
    pr_info("%s: atomic_read: %d\n", __func__, atomic_read(&val));

    /* unconditional swap: returns old (3), val becomes 5 */
    pr_info("%s: atomic_xchg(5): %d\n", __func__, atomic_xchg(&val, 5));
    pr_info("%s: atomic_read: %d\n", __func__, atomic_read(&val));

    return -1;
}

static void test_hello_exit(void)
{
    pr_info("%s: In exit\n", __func__);
}

module_init(test_hello_init);
module_exit(test_hello_exit);
```

---

## 13. `atomic_xchg` — Unconditional Exchange

`atomic_xchg(v, new)` stores `new` into `v` and returns the **previous** value, unconditionally. Unlike `atomic_set`, it guarantees the old value is captured atomically.

```c
int atomic_xchg(atomic_t *v, int new);
```

The dispatch is in [/arch/arm64/include/asm/cmpxchg.h](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/cmpxchg.h#L21-L61). The difference from `atomic_cmpxchg` is that no comparison is performed — the new value is always written:

```
LL/SC path:                         LSE path:

1: ldxr  w_ret, [ptr]               swp   w_new, w_ret, [ptr]
   stxr  w_tmp, w_new, [ptr]        ; Single instruction:
   cbnz  w_tmp, 1b                  ;   w_ret ← *ptr
   dmb   ish                        ;   *ptr  ← w_new
```

`SWP` (Swap) is the simplest LSE instruction: one unconditional exchange in a single opcode. Use `SWPA` / `SWPL` / `SWPAL` for acquire, release, or full ordering respectively.

---

## 14. Common Use Cases and Example

`atomic_t` is the right tool when a single shared counter or flag is accessed from multiple CPUs without needing to protect a larger critical section:

- **Reference counting** — `struct kref` internally wraps `atomic_t`; `atomic_dec_and_test` detects the last release
- **Module / device use counts** — prevent unloading while in use
- **File descriptor reference counts** — track open handles
- **Wait flags** — set a bit atomically to unblock a waiting thread
- **Sequence numbers** — monotonically increasing identifiers in lock-free rings

Avoid `atomic_t` when you need to update two fields together, or when the new value depends on reading a separate variable. Those cases require a lock.

### Example: Object Reference Counting

```c
#include <linux/atomic.h>
#include <linux/slab.h>

struct my_device {
    atomic_t    refcount;
    void       *priv;
    /* ... */
};

struct my_device *my_device_alloc(void)
{
    struct my_device *dev = kzalloc(sizeof(*dev), GFP_KERNEL);
    if (!dev)
        return NULL;
    atomic_set(&dev->refcount, 1);   /* starts at 1 — the allocator holds a ref */
    return dev;
}

void my_device_get(struct my_device *dev)
{
    atomic_inc(&dev->refcount);
}

void my_device_put(struct my_device *dev)
{
    /*
     * atomic_dec_and_test uses full barrier semantics, so writes to
     * dev->priv on any CPU are visible to whoever calls kfree here.
     */
    if (atomic_dec_and_test(&dev->refcount))
        kfree(dev);
}
```

The invariant: across all CPUs, exactly one will observe the counter transition from 1 to 0. The full-barrier semantics of `atomic_dec_and_test` guarantee that all earlier writes to the object are visible before `kfree` runs.

---

## 15. Problems With Atomic Instructions: Limitations on Complex Data

**Atomic operations are not a universal synchronization tool. They solve a very specific problem — a single register-width read-modify-write** — and break down in several important ways outside that scope. Understanding each failure mode is essential for writing correct kernel code.

---

### 15.1 — Problem: Width Limit (Single-Word Only)

Atomic operations solve the single-word problem elegantly, but fall apart the moment the data structure exceeds one register width:

```
Data size    AArch64 solution
─────────────────────────────────────────────────────────────────
32 bits      atomic_t    (LDXR/STXR 32-bit, or LDADD/STADD)
64 bits      atomic64_t  (LDXR/STXR 64-bit, or LDADD/STADD 64-bit)
128 bits     LDXP/STXP (LL/SC pair) or CASP (LSE Compare-Swap-Pair)
> 128 bits   *** No hardware atomic — must use a lock ***
```

The 128-bit path uses `LDXP`/`STXP` (Load/Store Exclusive Pair) in the LL/SC path and `CASP` (Compare And Swap Pair) in the LSE path, as seen in [/arch/arm64/include/asm/atomic_ll_sc.h](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/atomic_ll_sc.h#L304-L335).

Scenarios that require a lock regardless of data width:

- Updating two related counters that must stay consistent (e.g., bytes sent and packets sent)
- Modifying a doubly-linked list node where both `next` and a neighbor's `prev` must change together
- Any operation where the new value depends on the current values of multiple independent variables

---

### 15.2 — Problem: Cache Line Bouncing and False Sharing

Every atomic read-modify-write on AArch64 requires **exclusive ownership** of the cache line containing the target variable. When multiple CPUs write different atomic variables that happen to share the same 64-byte cache line, they inadvertently invalidate each other's copies even though they are touching entirely independent data. This is **false sharing**.

```
  ┌─────────────────────────── 64-byte cache line ──────────────────────────┐
  │  atomic_t rx_packets  │  atomic_t tx_packets  │  padding ...            │
  │  (offset 0, 4 bytes)  │  (offset 4, 4 bytes)  │                         │
  └───────────────────────┴───────────────────────┴─────────────────────────┘

  CPU 0: atomic_inc(&rx_packets)   ← exclusive write → invalidates line everywhere
  CPU 1: atomic_inc(&tx_packets)   ← exclusive write → invalidates line everywhere

  Result: Every increment by either CPU forces the other to reload the entire
          cache line from the interconnect. Bandwidth is wasted on a line that
          carries data neither CPU actually cares about.
```

The cache line size on AArch64 is defined in [/arch/arm64/include/asm/cache.h](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/cache.h#L8-L9):

```c
#define L1_CACHE_SHIFT  (6)
#define L1_CACHE_BYTES  (1 << L1_CACHE_SHIFT)  /* 64 bytes */
```

**The fix**: align frequently-written counters to their own cache lines using `____cacheline_aligned_in_smp`, or better — replace shared counters with **per-CPU counters** (`this_cpu_add`, `__this_cpu_inc`) which each CPU updates locally without any exclusive bus transactions. The kernel uses this pattern extensively for statistics counters (network packet counts, page fault counts, slab alloc counts).

```c
/* BAD: false sharing */
struct stats {
    atomic_t rx;   /* CPU 0 hammers this */
    atomic_t tx;   /* CPU 1 hammers this — same cache line! */
};

/* BETTER: separate cache lines */
struct stats {
    atomic_t rx ____cacheline_aligned_in_smp;
    atomic_t tx ____cacheline_aligned_in_smp;
};

/* BEST for statistics: no atomics needed at all */
DEFINE_PER_CPU(long, rx_packets);
DEFINE_PER_CPU(long, tx_packets);
this_cpu_inc(rx_packets);   /* plain store, no bus traffic */
```

---

### 15.3 — Problem: LL/SC Exclusive Reservation Granule Interference

AArch64's exclusive monitor does not track individual byte addresses. It tracks a **reservation granule** — a naturally-aligned power-of-two region whose minimum size is 16 bytes, but which in practice is often 64 bytes (one cache line) on real silicon. If any byte within that granule is written by any agent between a CPU's `LDXR` and `STXR`, the reservation is lost and the store fails.

```
  ┌──── Exclusive Reservation Granule (64 bytes, typical) ────────────────┐
  │  atomic_t var_A         │  atomic_t var_B         │  other data ...    │
  │  (offset 0)             │  (offset 4)             │                    │
  └─────────────────────────┴─────────────────────────┴────────────────────┘

  CPU 0: ldxr  w0, [var_A]      ← opens exclusive reservation on ENTIRE granule
  CPU 1: stadd w1, [var_B]      ← writes var_B (different variable, same granule)
                                   → CPU 0's exclusive monitor is CLEARED
  CPU 0: stxr  w2, w0, [var_A]  ← FAILS (w2 = 1), must loop back to ldxr

  CPU 0 and CPU 1 are updating completely independent variables,
  yet they interfere with each other's exclusive operations.
```

This is a particularly subtle failure mode: the code is logically correct (the STXR failure causes a retry that eventually succeeds), but the **performance** is significantly worse than expected. Two independent hot counters packed together will cause each other's LL/SC loops to retry unnecessarily. Cache-line alignment of separate atomic variables eliminates this.

---

### 15.4 — Problem: LL/SC Starvation Under High Contention

The LL/SC retry loop has no fairness guarantee. Under sufficiently high contention — many CPUs hammering the same address — some CPUs can be starved: their `STXR` keeps failing because another CPU always wins the race first.

```
  CPU 0         CPU 1         CPU 2         CPU 3
  ─────         ─────         ─────         ─────
  ldxr          ldxr
                              stxr ← wins  (CPU 2 stores first)
  stxr FAIL                             ldxr
  ldxr                        ldxr
                stxr FAIL
                              stxr FAIL
                ldxr
  stxr FAIL
  ldxr   ← CPU 0 has now failed twice; no bound on how many times this repeats
```

The ARMv8 architecture specification does not guarantee forward progress of `LDXR`/`STXR` loops in the presence of interference. It only guarantees that a loop will eventually succeed if the CPU is given exclusive access for long enough — which the OS scheduler arranges by eventually preempting the competing CPUs.

**The practical mitigation**: the kernel keeps the region between `LDXR` and `STXR` as short as possible — no function calls, no branches, no memory accesses to other locations. Any intervening access to a different memory address can itself clear the exclusive reservation on some microarchitectures. This is why the LL/SC macros in [/arch/arm64/include/asm/atomic_ll_sc.h](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/atomic_ll_sc.h#L25-L40) contain only the minimum sequence of instructions.

---

### 15.5 — Problem: Spinning Wastes Power (and the WFE/SEVL Solution)

A tight `LDXR`/`STXR` retry loop burns CPU cycles and generates continuous bus traffic even when the value being waited for has not changed. This wastes power on mobile SoCs and creates interconnect pressure that slows every other CPU on the cluster.

The kernel works around this with the `__CMPWAIT_CASE` helper in [/arch/arm64/include/asm/cmpxchg.h](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/cmpxchg.h#L213-L232), which uses `WFE` (Wait For Event) to put the CPU into a low-power standby state while it waits for the target address to change:

```c
// __CMPWAIT_CASE — wait for *ptr to differ from val, using WFE
asm volatile(
    "   sevl\n"                              // set local event reg (prime first WFE)
    "   wfe\n"                               // sleep: CPU halted, bus traffic stops
    "   ldxr" sfx "  %" w "[tmp], %[v]\n"   // exclusive load (wakes on write to v)
    "   eor   %" w "[tmp], %" w "[tmp], %" w "[val]\n"
    "   cbnz  %" w "[tmp], 1f\n"             // value changed → exit
    "   wfe\n"                               // value unchanged → sleep again
    "1:"
    ...
);
```

```
Without WFE (busy spin):           With WFE:

ldxr → check → fail → ldxr         sevl
ldxr → check → fail → ldxr         wfe  ← CPU sleeps
ldxr → check → fail → ldxr         ...  ← interconnect writes to *ptr
ldxr → check → success              ldxr ← CPU wakes on the write event
                                    check → success
```

`SEVL` (Set Event Local) primes the event register so the first `WFE` returns immediately rather than sleeping through an already-pending event. `WFE` then suspends the CPU pipeline until the hardware's global monitor signals that some address in the exclusives range was written — at which point the CPU wakes, re-reads with `LDXR`, and checks whether the value it was waiting for actually changed.

---

### 15.6 — Problem: CLREX and Exclusive Monitor State Across Context Switches

The exclusive monitor is **per-CPU hardware state**. When the kernel performs a context switch or takes an exception, the monitor's reservation is potentially stale — the task that was running may have had an open `LDXR` at the point of preemption.

On AArch64, taking any exception (IRQ, SError, synchronous abort) implicitly clears the exclusive monitor as part of the exception entry — `CLREX` is effectively executed automatically. This means any LL/SC loop that is interrupted by an IRQ will have its `STXR` fail on the next attempt, and the loop will retry cleanly. No explicit `CLREX` in the exception handler is required in most paths.

However, there is a subtlety: `CLREX` is a real instruction the kernel must use **explicitly** in places where the exclusive monitor might hold state it wants to discard — for example, in certain hypervisor paths or when context-switching between EL levels. The kernel identifies these cases with `aarch64_insn_is_clrex()` in [/arch/arm64/include/asm/insn.h](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/insn.h#L451).

```
IRQ fires between LDXR and STXR:

  CPU 0 executing user task:
    ldxr w0, [x1]    ← reservation opened
    add  w0, w0, #1
                     ← IRQ fires HERE
                     ← exception entry implicitly clears exclusive monitor
    (IRQ handler executes)
    (task resumes)
    stxr w1, w0, [x1]  ← STXR FAILS (monitor was cleared by IRQ)
    cbnz w1, retry      ← loop retries safely
```

This is a correct-by-design property: the implicit clear on exception entry means LL/SC loops in kernel code are naturally resilient to preemption.

---

### 15.7 — Problem: Integer Overflow and `atomic_t` vs `refcount_t`

`atomic_t` is a signed 32-bit integer. It silently wraps at `INT_MAX` (2,147,483,647). For general-purpose counters this is usually acceptable, but for **reference counts** it creates a security vulnerability: an attacker who can trigger enough increments to wrap the counter to zero can cause a premature `kfree()`, producing a use-after-free.

The kernel addresses this with `refcount_t`, defined in [/include/linux/refcount.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/refcount.h#L1-L55), which uses **saturation semantics**:

```
  refcount_t value range and behavior:

  0          INT_MAX   REFCOUNT_SATURATED    UINT_MAX
  │          │         │ (INT_MIN/2)         │
  ▼          ▼         ▼                     ▼
  ┌──────────┬─────────┬─────────────────────┐
  │  normal  │ (live)  │    SATURATED ZONE   │
  │  range   │         │ (never decremented) │
  └──────────┴─────────┴─────────────────────┘
        ▲
        │
  refcount_dec_and_test() returning true
  only possible inside the normal range

  If overflow pushes value into INT_MIN range:
  → kernel detects it via  old < 0  check
  → sets counter to REFCOUNT_SATURATED (0xc000_0000)
  → WARN() is triggered — guaranteed to catch the bug
  → object is NOT freed — use-after-free is prevented
```

```c
/* BAD for reference counts — wraps silently */
atomic_t refcount;
atomic_inc(&refcount);
if (atomic_dec_and_test(&refcount))
    kfree(obj);   /* could free while still referenced if counter wrapped */

/* CORRECT — saturates instead of wrapping */
refcount_t refcount;
refcount_inc(&refcount);
if (refcount_dec_and_test(&refcount))
    kfree(obj);   /* safe — counter can only reach 0 legitimately */
```

**Rule**: always use `refcount_t` (or `struct kref` which wraps it) for object lifetime counters. Use raw `atomic_t` only for counters where wrap-around is harmless — statistics, sequence numbers, indexes.

---

### 15.8 — Problem: `atomic_*` is Forbidden in `noinstr` Code

The `atomic_add()` / `atomic_read()` family goes through the **instrumented layer** in [/include/linux/atomic/atomic-instrumented.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/atomic/atomic-instrumented.h#L30-L35), which calls `instrument_atomic_read()` / `instrument_atomic_read_write()`. These functions may call into KASAN or KCSAN, which themselves use ordinary kernel code paths. Using them inside `noinstr` functions — which must not call any instrumented or traceable code — causes the objtool validator to reject the build.

```
noinstr void my_exception_handler(void)
{
    atomic_inc(&stats);     /* ERROR: atomic_inc → instrumented → KASAN
                               objtool: call to non-noinstr function */

    raw_atomic_inc(&stats); /* CORRECT: bypasses instrumentation layer,
                               calls arch_atomic_add(1, v) directly */
}
```

The `raw_atomic_*` family in [/include/linux/atomic/atomic-arch-fallback.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/atomic/atomic-arch-fallback.h) calls the architecture implementation directly, skipping KASAN/KCSAN hooks. Use `raw_atomic_*` in exception handlers, NMI handlers, and any other `noinstr` context.

```
  atomic_inc(v)                     raw_atomic_inc(v)
       │                                   │
       ▼                                   ▼
  instrument_atomic_read_write()    (no instrumentation)
       │                                   │
       ▼                                   ▼
  raw_atomic_inc(v)              arch_atomic_add(1, v)
       │                                   │
       ▼                                   ▼
  arch_atomic_add(1, v)          __lse_ll_sc_body(...)
       │
       ▼
  __lse_ll_sc_body(...)

  ← noinstr-safe path        ← noinstr-safe path
    starts HERE only             starts HERE
```

---

### 15.9 — Problem: Atomics Cannot Replace Locks for Multi-Variable Invariants

Even with the full ordering guarantees of `atomic_add()`, you cannot use two separate atomic operations to atomically update two separate variables in a way that appears consistent to all CPUs. Each atomic operation is individually atomic, but there is no hardware primitive that makes two operations appear as one.

```
  Thread A wants to transfer 10 from account_a to account_b:

  atomic_sub(10, &account_a);    ← CPU 0
  ...
  atomic_add(10, &account_b);    ← CPU 0

  Between these two ops, Thread B reads both accounts:
  atomic_read(&account_a) → deducted already
  atomic_read(&account_b) → not yet added

  Thread B sees: total = (original_a - 10) + original_b
                       ≠ original_a + original_b
  → Invariant (total balance is constant) is BROKEN
```

The only solution for multi-variable invariants is a lock that holds both operations within a single critical section, or a data structure redesign that makes the invariant expressible as a single atomic word (e.g., packing both counters into a single 64-bit value and using `atomic64_cmpxchg`).

---

### Summary Table — Problems With Atomic Instructions

| # | Problem | Root Cause | Consequence | Kernel Solution |
|---|---|---|---|---|
| 15.1 | **Width limit** | Hardware atomics max out at 128 bits | Cannot atomically update structs larger than 2 registers | Spinlock for > 128-bit data |
| 15.2 | **Cache line bouncing / false sharing** | Exclusive ownership required per cache line (64 bytes); unrelated `atomic_t` vars packed together | Every write by CPU A invalidates the line for CPU B, even if B touches a different field | `____cacheline_aligned_in_smp`; prefer per-CPU counters |
| 15.3 | **Reservation granule interference** | AArch64 exclusive monitor tracks a granule (≥16 bytes, typically 64 bytes), not individual bytes | `STXR` fails when a neighbour in the same granule is written, even to a different variable | Align hot atomics to separate cache lines |
| 15.4 | **LL/SC starvation** | No fairness guarantee in the ARMv8 spec; monitor can be repeatedly stolen | A CPU may spin indefinitely under pathological contention | Keep LDXR→STXR region minimal (no calls, no side loads) |
| 15.5 | **Spinning wastes power** | Tight LDXR retry loop burns CPU cycles and bus bandwidth | Excess heat, interconnect pressure, slower neighbours | `WFE`/`SEVL` sleep-on-event in `__CMPWAIT_CASE` ([cmpxchg.h](https://github.com/torvalds/linux/blob/v7.3-rc7/arch/arm64/include/asm/cmpxchg.h#L213-L232)) |
| 15.6 | **CLREX on context switch / exception** | Exclusive monitor is per-CPU hardware state | Stale reservation after preemption would cause silent failure | Exception entry implicitly clears monitor; STXR fails and loop retries cleanly |
| 15.7 | **Integer overflow / wrap** | `atomic_t` is signed 32-bit; wraps at `INT_MAX` silently | Counter wraps to 0 → premature `kfree` → use-after-free | Use `refcount_t` (saturates at `REFCOUNT_SATURATED`) for object lifetimes |
| 15.8 | **Forbidden in `noinstr` code** | `atomic_*()` hooks into KASAN/KCSAN instrumentation | `objtool` rejects the build; crash in NMI/exception context | Use `raw_atomic_*()` which skips instrumentation |
| 15.9 | **No multi-variable atomicity** | No hardware primitive spans two independent addresses | Observers can see partial updates between two separate atomic ops | Spinlock covering both operations, or pack into one CAS word |

---

## 15.10 — Per-CPU Variables vs Atomic Variables

Per-CPU variables and atomic variables both solve the concurrent-access problem, but they do so in fundamentally different ways and are suited to different workloads.

### How Per-CPU Variables Work

A per-CPU variable is **not shared**. The kernel allocates one private copy of the variable for each possible CPU, laid out in a special `.data..percpu` ELF section. When a CPU reads or writes its copy it touches memory that no other CPU ever touches — so no bus locking, no exclusive instructions, and no cache-line invalidation are needed.

```
  4-CPU system, DEFINE_PER_CPU(long, pkt_count):

  CPU 0 address space      CPU 1 address space
  ┌─────────────────┐      ┌─────────────────┐
  │ pkt_count = 12  │      │ pkt_count = 47  │
  └─────────────────┘      └─────────────────┘

  CPU 2 address space      CPU 3 address space
  ┌─────────────────┐      ┌─────────────────┐
  │ pkt_count = 3   │      │ pkt_count = 91  │
  └─────────────────┘      └─────────────────┘

  Each CPU updates only its own copy.
  No other CPU ever reads it during normal operation.
  To get the global total: sum all copies (e.g. in /proc read path).
```

Defined via [/include/linux/percpu-defs.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/percpu-defs.h#L108-L109):

```c
#define DEFINE_PER_CPU(type, name) \
    DEFINE_PER_CPU_SECTION(type, name, "")
```

Access uses `this_cpu_add()` / `this_cpu_inc()` / `this_cpu_read()` which resolve to the current CPU's copy with no locking. For multi-statement access that must not be interrupted, `get_cpu_var()` / `put_cpu_var()` disable preemption around the critical region:

```c
/* get_cpu_var disables preemption, put_cpu_var re-enables it */
#define get_cpu_var(var)   (*({ preempt_disable(); this_cpu_ptr(&var); }))
#define put_cpu_var(var)   do { (void)&(var); preempt_enable(); } while (0)
```

defined in [/include/linux/percpu-defs.h](https://github.com/torvalds/linux/blob/v7.3-rc7/include/linux/percpu-defs.h#L274-L288).

### Side-by-Side Comparison

```
                    atomic_t                        Per-CPU variable
                    ────────                        ────────────────
Storage             One shared memory location      N copies, one per CPU
                    (all CPUs see the same addr)    (each CPU has its own)

Write mechanism     LDXR/STXR loop or LSE           Plain store instruction
                    (exclusive bus transaction)      (no bus transaction at all)

Read mechanism      Plain load                      Plain load of local copy

Cross-CPU           Guaranteed immediately           Stale: other CPUs see their
visibility          after the atomic op             own copy, not yours

SMP overhead        High (cache-line ownership,      Zero (no contention possible)
                    bus traffic on every write)

Preemption          Safe — atomic op is             Unsafe unless preemption is
safety              indivisible                     disabled (task could migrate
                                                    to another CPU mid-update)

Global aggregate    Value IS the global total        Must sum all per-CPU copies
                                                    (e.g. for_each_possible_cpu)

Data type           atomic_t (int) /                Any plain C type: long, struct,
                    atomic64_t (s64)                pointer, array

Use case            Shared flags, reference          Per-CPU statistics, per-CPU
                    counts, lock-free primitives,    caches, scheduler runqueues,
                    objects with concurrent          network packet counters
                    readers AND writers
```

### Decision Guide

```
Need to update a counter or flag?
              │
   ┌──────────┴──────────┐
   │                     │
Is it ever read or       Is it only ever updated
written by more than     by the CPU that owns it,
one CPU at a time?       and aggregated rarely?
   │                     │
   ▼                     ▼
Use atomic_t /       Use DEFINE_PER_CPU —
atomic64_t           this_cpu_inc() is a plain
                     store, zero bus overhead.
   │
   ├── Only one CPU writes, many read?
   │   → consider seqlock or RCU instead
   │
   └── Multiple CPUs write + read always?
       → atomic_t is correct; consider
         refcount_t for lifetime counters
```

### When to Use Which

| Scenario | Use `atomic_t` / `atomic64_t` | Use `DEFINE_PER_CPU` |
|---|:---:|:---:|
| **Reference counting** — object freed when count hits zero | ✓ | ✗ — count must be globally accurate at all times |
| **High-frequency statistics** — packets received, bytes sent, page faults | ✗ — bus traffic per write | ✓ — aggregate with `for_each_possible_cpu` on read path |
| **Shared flag / bitmask** — e.g. device state, feature bits | ✓ | ✗ — all CPUs must see the same value instantly |
| **Module / device use count** — prevent unload while in use | ✓ | ✗ — any CPU may be the last user |
| **Scheduler run-queue length** — each CPU tracks its own queue depth | ✗ — unnecessary contention | ✓ — each CPU owns its own queue |
| **Sequence number / generation counter** read by multiple CPUs | ✓ | ✗ — readers on other CPUs need the latest value |
| **Lock-free algorithm state** — CAS loops, wait-free queues | ✓ — `atomic_cmpxchg` required | ✗ — per-CPU has no CAS |
| **Slab / memory allocator counters** — alloc/free counts per CPU | ✗ | ✓ — each CPU allocates from its own slab |
| **NMI / interrupt context counter** that must not sleep or lock | ✓ — `raw_atomic_*` if in `noinstr` | ✓ — `__this_cpu_inc` (preemption already off in IRQ) |
| **Object lifetime control** — prevent use-after-free | ✓ `refcount_t` | ✗ — local copy can reach zero while another CPU still holds a reference |
| **Work queue / task throttling** — global concurrency limit | ✓ | ✗ — limit must be enforced across all CPUs together |
| **Per-CPU cache hit/miss tracking** | ✗ | ✓ — reading your own cache is inherently CPU-local |
| **Network softirq budget** — packets processed per softirq burst | ✗ | ✓ — each CPU runs its own softirq independently |
| **Two variables that must stay consistent with each other** | ✗ — use a spinlock | ✗ — use a spinlock |

**Rule of thumb:**

- If the value must be **globally consistent at the moment of read** (refcount, flag, limit) → `atomic_t`
- If updates are **write-heavy and reads are rare or approximate** (statistics, counters, budgets) → per-CPU
- If in doubt: start with `atomic_t` for correctness; profile and switch to per-CPU only if the atomic appears in a hot path

---

### Code Example — Per-CPU Counter vs Atomic Counter

```c
#include <linux/percpu-defs.h>
#include <linux/atomic.h>
#include <linux/cpumask.h>

/* Per-CPU approach: zero bus overhead per increment */
DEFINE_PER_CPU(long, rx_bytes_percpu);

static inline void account_rx_percpu(int len)
{
    this_cpu_add(rx_bytes_percpu, len);   /* plain store, no lock */
}

static long total_rx_percpu(void)
{
    long total = 0;
    int cpu;
    for_each_possible_cpu(cpu)
        total += per_cpu(rx_bytes_percpu, cpu);
    return total;
}

/* Atomic approach: every increment is a bus transaction */
static atomic64_t rx_bytes_atomic = ATOMIC64_INIT(0);

static inline void account_rx_atomic(int len)
{
    atomic64_add(len, &rx_bytes_atomic);  /* LDXR/STXR or LDADD — bus traffic */
}

static long total_rx_atomic(void)
{
    return atomic64_read(&rx_bytes_atomic);   /* single load — instant */
}
```

The per-CPU path wins on write-heavy counters (network receive, page faults, slab allocations). The atomic path wins when the global total must be instantly consistent across all CPUs — for example, a reference count where the correct value at the moment of `dec_and_test` determines whether the object is freed.

---

## 16. Lock-Free Programming: Trade-offs

**Lock-free programming** is designing algorithms that guarantee system-wide progress even when individual threads are preempted — typically built from CAS loops rather than mutexes. The appeal is eliminating priority inversion, deadlock, and lock-convoy effects.

The trade-offs are substantial:

```
Lock-based                        Lock-free
──────────────────────────────────────────────────────────────────
Simple mental model               Complex correctness reasoning
Deadlock possible                 Deadlock impossible by construction
Priority inversion risk           No priority inversion
High contention → convoy          High contention → CAS storm
Memory reclamation trivial        Memory reclamation hard (ABA problem)
Debugging: lock order analysis    Debugging: nearly impossible to
                                  reproduce interleavings
```

**The ABA Problem** — the central hazard of lock-free design:

```
Thread A reads *ptr → value A
Thread A is preempted
    Thread B: *ptr changes A → B → A (e.g., free/realloc with same address)
Thread A resumes, CAS sees A, assumes unchanged, proceeds — WRONG
The object was freed and reallocated; A points to stale data
```

Solutions (hazard pointers, epoch-based reclamation, tagged pointers) all add significant complexity. The kernel uses **RCU** (Read-Copy-Update) as its main answer to this problem.

The kernel applies lock-free techniques selectively: reference counting with `atomic_t`, per-CPU counters, and wait-free queues for specific hot paths. The default advice for new kernel code: use a spinlock unless profiling demonstrates the lock is a genuine bottleneck.

---

## 17. Complete Atomic Operation Reference

### 17.1 — 32-bit (`atomic_t`)

| Operation | Description | Returns |
|---|---|---|
| `atomic_read(v)` | Relaxed load | value |
| `atomic_read_acquire(v)` | Acquire load | value |
| `atomic_set(v, i)` | Relaxed store | — |
| `atomic_set_release(v, i)` | Release store | — |
| `atomic_add(i, v)` | Add | — |
| `atomic_sub(i, v)` | Subtract | — |
| `atomic_inc(v)` | Add 1 | — |
| `atomic_dec(v)` | Subtract 1 | — |
| `atomic_add_return[_relaxed/_acquire/_release](i, v)` | Add | new value |
| `atomic_sub_return[_relaxed/_acquire/_release](i, v)` | Subtract | new value |
| `atomic_fetch_add[_relaxed/_acquire/_release](i, v)` | Add | old value |
| `atomic_fetch_sub[_relaxed/_acquire/_release](i, v)` | Subtract | old value |
| `atomic_fetch_and[_relaxed/_acquire/_release](i, v)` | AND | old value |
| `atomic_fetch_or[_relaxed/_acquire/_release](i, v)` | OR | old value |
| `atomic_fetch_xor[_relaxed/_acquire/_release](i, v)` | XOR | old value |
| `atomic_and(i, v)` | AND, no return | — |
| `atomic_or(i, v)` | OR, no return | — |
| `atomic_xor(i, v)` | XOR, no return | — |
| `atomic_andnot(i, v)` | Clear bits in `i` | — |
| `atomic_dec_and_test(v)` | Decrement | true if zero |
| `atomic_inc_and_test(v)` | Increment | true if zero |
| `atomic_sub_and_test(i, v)` | Subtract | true if zero |
| `atomic_add_negative(i, v)` | Add | true if result < 0 |
| `atomic_cmpxchg[_relaxed/_acquire/_release](v, old, new)` | CAS | old value |
| `atomic_xchg[_relaxed/_acquire/_release](v, new)` | Swap | old value |
| `atomic_inc_not_zero(v)` | Increment if non-zero | true if incremented |
| `atomic_dec_if_positive(v)` | Decrement if positive | new value |
| `atomic_add_unless(v, a, u)` | Add `a` unless equals `u` | true if added |

### 17.2 — 64-bit (`atomic64_t`)

All 32-bit operations have 64-bit counterparts prefixed with `atomic64_`. Additionally:

| Operation | Description | Returns |
|---|---|---|
| `atomic64_dec_if_positive(v)` | Decrement if > 0 | new value |

### 17.3 — Bitwise (`unsigned long` bitmaps)

| Operation | Atomic? | Description | Returns |
|---|---|---|---|
| `set_bit(nr, addr)` | Yes | Set bit `nr` | — |
| `clear_bit(nr, addr)` | Yes | Clear bit `nr` | — |
| `change_bit(nr, addr)` | Yes | Toggle bit `nr` | — |
| `test_bit(nr, addr)` | No | Read bit `nr` | bit value |
| `test_and_set_bit(nr, addr)` | Yes | Set, return old | old bit |
| `test_and_clear_bit(nr, addr)` | Yes | Clear, return old | old bit |
| `test_and_change_bit(nr, addr)` | Yes | Toggle, return old | old bit |
| `__set_bit(nr, addr)` | No | Non-atomic set | — |
| `__clear_bit(nr, addr)` | No | Non-atomic clear | — |
| `__test_and_set_bit(nr, addr)` | No | Non-atomic test-and-set | old bit |
