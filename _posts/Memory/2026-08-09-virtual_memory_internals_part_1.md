---
title: Virtual Memory Internals — Part 1
published: true
categories: [memory]
tags: [virtual memory,page tables]
---
# Virtual Memory Internals — Part 1

A deep-dive covering why virtual memory exists, how page faults drive the system, and how
AArch64 page tables are structured — with kernel source references throughout.

---

##   1: Why Virtual Memory Exists

### The Problem Without Virtual Memory

Without virtual memory every process accesses physical RAM directly. The hardware places no
restriction on which addresses a program reads or writes. This is catastrophic for five
independent reasons:

**1. No Isolation (Stability & Security)**

Any program can read or write any byte — its own, another program's, or the kernel's. A
single off-by-one bug in one process can silently corrupt the data of another, or overwrite
kernel structures and crash the machine. There is no security boundary: every process is as
privileged as every other.

**2. Fragmentation**

Physical memory is allocated and freed as processes start and exit. Over time RAM becomes a
patchwork of used and free holes. A process that needs 100 MiB of contiguous memory may fail
even though 200 MiB is free — scattered across dozens of small gaps. Worse, existing
allocations cannot be moved because every process holds raw physical pointers that would be
invalidated.

**3. Address Conflicts**

Two programs compiled to begin at address `0x400000` cannot run simultaneously. Every process
must coordinate which physical addresses it uses. Loading programs becomes a nightmare — the OS
must find holes that do not overlap any other program or any memory those programs might use in
the future.

**4. No Overcommit / Capacity Limits**

When physical memory is exposed directly, you can use only what physically exists. Facilities
like demand paging and swap are impossible, so running out of RAM is a fatal system error.

**5. No Contiguity Guarantees**

A sensible program expects to receive contiguous memory from an allocator, but without virtual
memory the allocator can only hand out physically contiguous ranges — which become scarce as
the system runs.

### The Abstraction

Virtual memory solves all five problems with a single idea: **give each process its own
private, flat, contiguous address space**. The hardware (the MMU — Memory Management Unit)
translates virtual addresses to physical addresses transparently on every memory access.

```
Process A sees:              Process B sees:              Physical RAM:
┌──────────────┐             ┌──────────────┐             ┌──────────────┐
│ 0x0000..     │             │ 0x0000..     │             │ Frame 0      │
│ .text        │──┐          │ .text        │──┐          │ (kernel)     │
│ .data        │  │          │ .data        │  │          ├──────────────┤
│ heap         │  │          │ heap         │  │          │ Frame 1      │
│ ...          │  │          │ ...          │  │          │ (A's .text)  │
│ stack        │  │          │ stack        │  │          ├──────────────┤
└──────────────┘  │          └──────────────┘  │          │ Frame 2      │
                  │                            │          │ (B's .text)  │
                  └────────────────────────►    │          ├──────────────┤
                               └───────────────────────►  │ Frame 3      │
                                                          │ (A's heap)  │
                                                          ├──────────────┤
                                                          │ Frame 4      │
                                                          │ (B's stack) │
                                                          └──────────────┘
```

Each process believes it starts at address 0 with a contiguous range. The MMU maps these
virtual addresses to scattered physical frames behind the scenes.

The concept really does necessitate a separation between "privileged" kernel code and
"unprivileged" user space — the ability to map virtual memory to physical implies access to all
memory, so only the kernel can be permitted to do this.

On AArch64 this privilege split is enforced by Exception Levels: user-space runs at EL0, the
kernel at EL1. The hardware checks the current EL on every memory access and enforces the
page-table permission bits accordingly.

### Key Benefits

| Benefit | How VM Enables It |
|---|---|
| **Process isolation** | Each process has its own page tables; it cannot see another process's physical pages |
| **Memory overcommit** | Kernel can promise more virtual memory than physical RAM exists — pages are only allocated on first access |
| **Shared libraries** | Multiple processes map the same physical page (e.g., libc) into their own virtual address spaces — one copy in RAM |
| **Demand paging** | Pages are loaded from disk only when accessed — processes start faster, less RAM is wasted |
| **ASLR** | Virtual addresses can be randomized per-process; the physical layout is irrelevant to user-space |
| **Swapping** | Kernel can evict rarely-used pages to disk and reclaim physical frames for active processes |

### How Virtual Memory Maps to Hardware (AArch64)

On AArch64 the kernel uses two Translation Table Base Registers simultaneously:

- **TTBR0_EL1** — points to the page tables for the **lower** (user-space) half of the address
  space. Each process has its own set of tables; the kernel swaps TTBR0 on context switch.
- **TTBR1_EL1** — points to the page tables for the **upper** (kernel) half. This is shared
  across all processes and is never switched — it always points to `swapper_pg_dir`.

The hardware selects which TTBR to use based on **bit 55** of the virtual address:
- Bit 55 = 0 → TTBR0 (user)
- Bit 55 = 1 → TTBR1 (kernel)

This replaces the x86 model where a single CR3 register points to a unified page table
containing both user and kernel entries. On AArch64 the separation is architectural.

```
 AArch64 Virtual Address Space (48-bit VA example):

 0xFFFF_FFFF_FFFF_FFFF ┌────────────────────────┐
                        │                        │
                        │   Kernel Space          │  ← TTBR1_EL1 (swapper_pg_dir)
                        │   256 TiB               │     Bit 55 = 1
                        │                        │
 0xFFFF_0000_0000_0000 ├────────────────────────┤
                        │                        │
                        │   Non-Canonical Hole    │  ← Access causes fault
                        │   (huge gap)            │
                        │                        │
 0x0000_FFFF_FFFF_FFFF ├────────────────────────┤
                        │                        │
                        │   User Space            │  ← TTBR0_EL1 (per-process)
                        │   256 TiB               │     Bit 55 = 0
                        │                        │
 0x0000_0000_0000_0000 └────────────────────────┘
```

The kernel mapping in the upper half is the **same** in every process. The user mapping in the
lower half changes on each context switch. Kernel pages use the **nG** (not-Global) bit cleared
so their TLB entries survive TTBR0 switches; user pages set nG so their TLB entries are tagged
with an ASID and flushed or ignored on context switch.

---

##   2: Page Faults as a Mechanism

A page fault is not an error — it is the kernel's hook into memory access. When the MMU
cannot translate a virtual address (page table entry not present, permissions violated, access
flag not set), it raises an exception. The kernel's fault handler decides what to do: allocate
a page, load data from disk, copy a page on write, migrate to a different NUMA node, or kill
the process.

### 2a. The AArch64 Fault Handling Path

On AArch64 a failed address translation generates a **synchronous exception** — either a
**Data Abort** (for loads/stores) or an **Instruction Abort** (for instruction fetches). The
CPU records two pieces of information:

- **FAR_EL1** (Fault Address Register) — the virtual address that caused the fault
- **ESR_EL1** (Exception Syndrome Register) — a 64-bit register encoding the cause

#### ESR_EL1 Layout for Data / Instruction Aborts

Reference: [`arch/arm64/include/asm/esr.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/esr.h#L44-L49) (EC values), [`FSC definitions`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/esr.h#L115-L123)

```
 Bits [31:26] = EC  (Exception Class)
   0x20 = Instruction Abort from EL0
   0x21 = Instruction Abort from EL1
   0x24 = Data Abort from EL0
   0x25 = Data Abort from EL1

 Bit  [25]    = IL  (Instruction Length)

 Bits [24:0]  = ISS (Instruction Specific Syndrome)
   Bit  [6]   = WnR  (Write-not-Read: 1 = write caused the abort)
   Bit  [8]   = CM   (Cache Maintenance operation)
   Bit  [10]  = FnV  (FAR not Valid)
   Bits [5:0] = FSC  (Fault Status Code — the key discriminator)
```

The **FSC** (bits [5:0]) tells the kernel exactly what went wrong:

| FSC | Fault Type | Meaning |
|-----|-----------|---------|
| 0x04–0x07 | Translation fault (levels 0–3) | Page table entry does not exist |
| 0x08–0x0B | Access Flag fault (levels 0–3) | Entry exists but AF bit is clear |
| 0x0C–0x0F | Permission fault (levels 0–3) | Entry exists, AF set, but permissions deny the access |
| 0x10 | Synchronous External Abort | Hardware memory error |
| 0x21 | Alignment fault | Unaligned access to device memory |

The kernel classifies these with inline helpers:

Reference: [`arch/arm64/include/asm/esr.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/esr.h#L463-L484)

```c
esr_fsc_is_translation_fault(esr)   // FSC 0x04–0x07
esr_fsc_is_access_flag_fault(esr)   // FSC 0x08–0x0B
esr_fsc_is_permission_fault(esr)    // FSC 0x0C–0x0F
```

#### Complete Call Chain: Hardware Exception → Kernel Handler

```
Hardware Exception (Data Abort / Instruction Abort)
  │
  ▼
VBAR_EL1 → vectors (arch/arm64/kernel/entry.S:517)
  │  CPU jumps to the exception vector table. Each entry is a
  │  kernel_ventry macro that:
  │    1. Allocates struct pt_regs on the stack
  │    2. Checks for stack overflow
  │    3. Branches to the entry_handler
  │
  ▼
entry_handler (entry.S:568)
  │  Calls kernel_entry to save all 31 GPRs, ELR_EL1 (return PC),
  │  and SPSR_EL1 (saved PSTATE) into pt_regs.
  │  Sets x0 = sp (pointer to pt_regs).
  │  Branches to the C handler:
  │    • el1h_64_sync_handler  (fault from kernel / EL1)
  │    • el0t_64_sync_handler  (fault from user / EL0)
  │
  ▼
el1h_64_sync_handler / el0t_64_sync_handler (entry-common.c)
  │  Reads ESR_EL1, switches on EC (Exception Class):
  │    EC 0x24 (DABT_LOW)  → el0_da()  → reads FAR_EL1
  │    EC 0x20 (IABT_LOW)  → el0_ia()  → reads FAR_EL1
  │    EC 0x25 (DABT_CUR)  → el1_abort() → reads FAR_EL1
  │    EC 0x21 (IABT_CUR)  → el1_abort() → reads FAR_EL1
  │  All paths call: do_mem_abort(far, esr, regs)
  │
  ▼
do_mem_abort (arch/arm64/mm/fault.c:980)
  │  Indexes the fault_info[] table by FSC (bottom 6 bits of ESR).
  │  Each entry maps to a handler function:
  │    FSC 0x04–0x07 → do_translation_fault()
  │    FSC 0x08–0x0F → do_page_fault()
  │    FSC 0x21      → do_alignment_fault()
  │    FSC 0x10      → do_sea()  (external abort)
  │
  ▼
do_translation_fault (fault.c:838)
  │  If the faulting address is in user space (TTBR0 range):
  │    → falls through to do_page_fault()
  │  If the faulting address is in kernel space:
  │    → do_bad_area() → __do_kernel_fault() → die()
  │    (a kernel translation fault means a bug)
  │
  ▼
do_page_fault (fault.c:601)  — the main handler
  │
  │  1. Determine access type from ESR:
  │       WnR=1 (write)         → vm_flags = VM_WRITE
  │       Instruction abort     → vm_flags = VM_EXEC
  │       Otherwise             → vm_flags = VM_READ
  │
  │  2. Find the VMA covering the faulting address
  │     (first tries lock_vma_under_rcu for lockless lookup,
  │      falls back to mmap_read_lock + find_vma)
  │
  │  3. Check permissions: do VMA flags permit this access?
  │       No  → SIGSEGV (SEGV_ACCERR)
  │       Yes → continue
  │
  │  4. Call handle_mm_fault(vma, addr, mm_flags, regs)
  │     ──── crosses into architecture-independent MM code ────
  │
  │  5. Handle the result:
  │       VM_FAULT_OOM    → pagefault_out_of_memory()
  │       VM_FAULT_SIGBUS → send SIGBUS
  │       VM_FAULT_RETRY  → retry the fault
  │       Success         → return to user, CPU retries the instruction
  │
  ▼
handle_mm_fault (mm/memory.c:6651) — generic, arch-independent
  │  Dispatches to __handle_mm_fault() for normal pages,
  │  or hugetlb_fault() for hugetlb VMAs.
  │
  ▼
__handle_mm_fault (mm/memory.c:6417) — page table walk
  │  Walks PGD → P4D → PUD → PMD, allocating table pages as needed.
  │  At each level checks for transparent huge pages and NUMA hints.
  │  Falls through to handle_pte_fault().
  │
  ▼
handle_pte_fault (mm/memory.c:6335) — PTE-level dispatch
  │
  ├── PTE is none (no mapping)
  │     ├── Anonymous VMA → do_anonymous_page()
  │     └── File-backed   → do_fault()
  │
  ├── PTE not present (swapped out) → do_swap_page()
  │
  ├── pte_protnone && vma_is_accessible → do_numa_page()
  │
  └── PTE present, write fault, !pte_write → do_wp_page()  (COW)
```

**Source files referenced in the call chain above:**

| Function / Symbol | Source |
|---|---|
| `vectors` | [`arch/arm64/kernel/entry.S`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry.S#L517) |
| `kernel_ventry` | [`arch/arm64/kernel/entry.S`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry.S#L39) |
| `entry_handler` | [`arch/arm64/kernel/entry.S`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry.S#L568) |
| `el1h_64_sync_handler` | [`arch/arm64/kernel/entry-common.c`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry-common.c#L442) |
| `el0t_64_sync_handler` | [`arch/arm64/kernel/entry-common.c`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry-common.c#L749) |
| `el0_da` / `el0_ia` | [`arch/arm64/kernel/entry-common.c`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry-common.c#L546-L556) |
| `el1_abort` | [`arch/arm64/kernel/entry-common.c`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry-common.c#L315) |
| `do_mem_abort` | [`arch/arm64/mm/fault.c`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/mm/fault.c#L980) |
| `fault_info[]` | [`arch/arm64/mm/fault.c`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/mm/fault.c#L913-L957) |
| `do_translation_fault` | [`arch/arm64/mm/fault.c`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/mm/fault.c#L838) |
| `do_page_fault` | [`arch/arm64/mm/fault.c`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/mm/fault.c#L601) |
| `__do_kernel_fault` | [`arch/arm64/mm/fault.c`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/mm/fault.c#L405) |
| `handle_mm_fault` | [`mm/memory.c`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/memory.c#L6651) |
| `__handle_mm_fault` | [`mm/memory.c`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/memory.c#L6417) |
| `handle_pte_fault` | [`mm/memory.c`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/memory.c#L6335) |

### 2b. Demand Paging

Demand paging is the strategy of deferring physical memory allocation until the moment a process actually touches a virtual address. Instead of eagerly allocating and populating every page when a mapping is created, the kernel leaves the page table empty and waits. The first access triggers a page fault, at which point the kernel allocates a physical frame, fills it (with zeros for anonymous memory, or with file data for file-backed mappings), installs a page table entry, and lets the process continue. This matters because most processes map far more virtual memory than they ever use — shared libraries, large heap reservations, memory-mapped files read sparsely — so allocating upfront would waste both RAM and time. Demand paging turns `fork()` + `exec()` from an O(memory-size) operation into an O(1) operation, and it is the foundation that makes overcommit, swap, and memory-mapped I/O practical.

When a process calls `mmap()` or the kernel sets up a new mapping, the kernel creates a VMA
(Virtual Memory Area) describing the virtual range but does **not** allocate physical pages or
create PTEs. The page tables have no entry for these addresses.

On first access:

```
1. Process accesses virtual address 0x7f00001000
2. MMU walks page table → entry not present at some level
3. CPU generates synchronous exception (Data Abort)
   ESR_EL1.FSC = 0x04..0x07 (translation fault)
4. Kernel path: do_mem_abort → do_translation_fault → do_page_fault
               → handle_mm_fault → handle_pte_fault → do_pte_missing
5. Kernel checks: is this address in a valid VMA?
   - No  → SIGSEGV (segmentation fault)
   - Yes → proceed
6. do_pte_missing dispatches:
   - Anonymous VMA → do_anonymous_page()
     • Read fault: map the shared zero page (read-only, special)
       No physical page allocated — deferred until first write
     • Write fault: allocate a zeroed physical page via alloc_anon_folio()
   - File-backed VMA → do_fault()
     • Calls vma->vm_ops->fault() to read the page from disk
7. Install PTE: create page table entry mapping VA → PA
   set_pte_at(mm, addr, ptep, entry)
8. Return from exception → CPU retries the instruction → succeeds
```

**Minor fault** — the page is already in the page cache (another process mapped the same file,
or the page was recently evicted but not yet reclaimed). No disk I/O needed. Cost: ~microseconds.

**Major fault** — the page must be read from disk. Cost: ~milliseconds.

You can observe this per-process via `/proc/[pid]/stat` fields 10 (minor faults) and 12
(major faults).

#### Read-Fault Zero-Page Optimization

When `do_anonymous_page()` handles a read fault, it does not allocate a private page. Instead
it maps the kernel's shared **zero page** — a single read-only page filled with zeros that is
shared across all processes. This avoids wasting memory for pages that have only been read
(never written). If the process later writes to this page, a permission fault triggers COW
(see 2c), which finally allocates a private page.

### 2c. Copy-on-Write (COW)

Copy-on-Write is a deferred-copy optimization that avoids duplicating memory until it is actually modified. The problem it solves is `fork()`: creating a child process conceptually requires a complete copy of the parent's address space — potentially hundreds of megabytes of heap, stack, and mapped files. Copying all of this eagerly is enormously expensive, and almost always wasteful because the child typically calls `exec()` immediately (replacing its entire address space) or shares most pages read-only with the parent. COW eliminates this waste by sharing the physical pages between parent and child and marking them read-only in both page tables. Neither process knows the pages are shared. Only when one of them actually writes to a shared page does the hardware trigger a permission fault, and the kernel steps in to allocate a private copy of just that one page. The result: `fork()` becomes nearly instantaneous regardless of process size, and only the pages that are genuinely modified ever get copied.

When `fork()` creates a child process, the kernel shares the physical pages and marks them
read-only in both processes' page tables:

```
Before fork():
  Parent PTE: VA 0x1000 → PA 0x5000 [Writable]    mapcount=1

After fork():
  Parent PTE: VA 0x1000 → PA 0x5000 [Read-Only]   mapcount=2  ← write-protected
  Child  PTE: VA 0x1000 → PA 0x5000 [Read-Only]   mapcount=2  ← shares same page
```

When either process writes to this shared page:

```
1. Process writes to VA 0x1000
2. MMU: PTE says read-only → permission fault
   ESR_EL1.FSC = 0x0C..0x0F, WnR=1
3. Kernel path: do_page_fault → handle_pte_fault
   Detects: FAULT_FLAG_WRITE && !pte_write(entry) → do_wp_page()
4. do_wp_page checks: can the page be reused?
   - PageAnonExclusive? (sole owner) → wp_page_reuse() — just make writable
   - folio refcount == 1? (no other references) → wp_page_reuse()
   - Otherwise → must copy → wp_page_copy()
5. wp_page_copy():
   a. Allocate new physical page: folio_prealloc()
   b. Copy contents: __wp_page_copy_user(new_page, old_page)
   c. Build new PTE: entry = mk_pte(new_page, vma->vm_page_prot)
      Make it dirty and writable: entry = maybe_mkwrite(pte_mkdirty(entry))
   d. Atomically clear old PTE and flush TLB:
      ptep_clear_flush(vma, addr, ptep)
   e. Add new page to reverse mapping:
      folio_add_new_anon_rmap(new_folio, vma, addr, RMAP_EXCLUSIVE)
   f. Install new PTE: set_pte_at(mm, addr, ptep, entry)
   g. Remove old page from reverse mapping:
      folio_remove_rmap_pte(old_folio, old_page, vma)
6. Return from fault → CPU retries the write → succeeds on private copy
```

**After the COW copy:**
```
  Parent PTE: VA 0x1000 → PA 0x5000 [Writable]    mapcount=1  ← sole owner
  Child  PTE: VA 0x1000 → PA 0x9000 [Writable]    mapcount=1  ← private copy
```

This is critical for `fork()` + `exec()` patterns: the child typically calls `exec()`
immediately, replacing its entire address space. Without COW, `fork()` would wastefully copy
hundreds of MiB only to discard them on `exec()`.

#### COW Reuse Optimization

Not every COW fault requires a copy. `do_wp_page()` first checks whether the process is the
**sole owner** of the page:

Reference: [`mm/memory.c` — `do_wp_page()`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/memory.c#L4314-L4324)

```c
if (folio && folio_test_anon(folio) &&
    (PageAnonExclusive(vmf->page) || wp_can_reuse_anon_folio(folio, vma))) {
    wp_page_reuse(vmf);
}
```

[`wp_can_reuse_anon_folio()`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/memory.c#L4181-L4220) checks:
- For small folios: refcount must be exactly 1 (after draining LRU and freeing swapcache)
- For large (THP) folios: `folio_large_mapcount == folio_ref_count` and the mm_ids are not shared

If the child `exec()`s before the parent writes, the parent's COW faults become no-copy
reuses — the page's refcount drops to 1 when the child's mappings are torn down.

#### COW for File-Backed Private Mappings

When a process writes to a `MAP_PRIVATE` file mapping, the fault goes through:

```
handle_pte_fault → do_pte_missing → do_fault → do_cow_fault
```

Reference: [`mm/memory.c` — `do_cow_fault()`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/memory.c#L5872-L5912)

`do_cow_fault()` pre-allocates a new anonymous page, calls the file's `->fault()` handler to
read the original data, then copies the data from the file page to the new anonymous page via
`copy_mc_user_highpage()`. The resulting PTE points to the private anonymous copy, not the
file page.

### 2d. NUMA Balancing

On multi-socket servers, physical memory is divided across NUMA (Non-Uniform Memory Access) nodes — each CPU socket has its own local memory bank. Accessing memory attached to the local socket is fast (tens of nanoseconds), while accessing memory on a remote socket must traverse an interconnect (QPI, UPI, or CCIX) and costs 2–3× more latency. A process that was migrated from one CPU to another may now be accessing all of its pages over the slow interconnect, degrading performance significantly. The kernel cannot know at allocation time where a process will ultimately run, so it needs a runtime mechanism to detect misplaced pages and migrate them closer to where they are being used. NUMA balancing provides this by exploiting the page fault mechanism: the kernel periodically revokes hardware access to selected pages, waits for the process to fault on them, and uses the fault to record which CPU accessed which page. If a page is consistently accessed from a different node than where it resides, the kernel migrates it.

The kernel uses page faults to detect and fix this suboptimal placement:

Reference: [`mm/memory.c` — `do_numa_page()`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/memory.c#L6109-L6198)

```
1. The NUMA balancing scanner (task_tick_numa in kernel/sched/fair.c)
   periodically walks the task's page tables
2. Sets selected PTEs to PROT_NONE using change_prot_numa():
   clears the accessible bits while preserving the PFN
   (On AArch64: uses pte_mkinvalid() which sets PTE_PRESENT_INVALID
    and clears PTE_VALID — software-present but hardware-invalid)
3. Process accesses the page → Data Abort (translation fault)
4. Kernel path: handle_pte_fault detects:
     pte_protnone(orig_pte) && vma_is_accessible(vma)
   This is the key detection: the PTE is "not accessible" to hardware
   but the VMA itself allows access → this is a NUMA hint fault,
   not a real protection violation
5. Calls do_numa_page() (mm/memory.c:6109):
   a. Restores access bits: pte_modify(old_pte, vma->vm_page_prot)
   b. Calls numa_migrate_check():
      - Records access pattern (which task, which node, how often)
      - Calls mpol_misplaced() to determine target NUMA node
   c. If page is on the wrong node:
      - migrate_misplaced_folio() → migrates the page to the local node
   d. Calls task_numa_fault() to update the scheduler's NUMA statistics
   e. Restores the PTE to be accessible again
6. Over time, pages migrate to where they are most frequently accessed
```

Controlled via: `/proc/sys/kernel/numa_balancing` (0=off, 1=on)

The key insight: page faults are the **only** mechanism the kernel has to observe which virtual
addresses a process actually accesses at runtime. By intentionally creating "fake" faults, the
kernel gains observability into memory access patterns.

### 2e. Summary: Complete Fault Dispatch Tree

```
handle_mm_fault()
  │
  ├── hugetlb_fault()                     [hugetlb VMA]
  │
  └── __handle_mm_fault()                  [normal VMA]
        │
        ├── [PMD level]
        │     ├── do_huge_pmd_numa_page()   [pmd_protnone, THP NUMA]
        │     └── do_huge_pmd_wp_page()     [write on read-only THP → COW or split]
        │
        └── handle_pte_fault()
              │
              ├── do_pte_missing()          [PTE is none — first access]
              │     ├── do_anonymous_page() [anon: zero-page or new page]
              │     └── do_fault()          [file-backed]
              │           ├── do_read_fault()     [read from file]
              │           ├── do_cow_fault()      [write on private file mapping]
              │           └── do_shared_fault()   [write on shared file mapping]
              │
              ├── do_swap_page()            [swapped out]
              │
              ├── do_numa_page()            [NUMA hint fault]
              │
              └── do_wp_page()              [write on read-only → COW]
                    ├── wp_page_reuse()     [sole owner: just make writable]
                    ├── wp_page_shared()    [shared mapping: make writable in place]
                    └── wp_page_copy()      [copy page, update PTE, flush TLB]
```

**Source locations for the dispatch tree above** ([`mm/memory.c`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/memory.c)):

| Handler | Line |
|---|---|
| [`do_anonymous_page()`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/memory.c#L5287) | 5287 |
| [`do_fault()`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/memory.c#L5964) | 5964 |
| [`do_read_fault()`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/memory.c#L5840) | 5840 |
| [`do_cow_fault()`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/memory.c#L5872) | 5872 |
| [`do_shared_fault()`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/memory.c#L5914) | 5914 |
| [`do_swap_page()`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/memory.c#L4747) | 4747 |
| [`do_numa_page()`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/memory.c#L6109) | 6109 |
| [`do_wp_page()`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/memory.c#L4244) | 4244 |
| [`wp_page_reuse()`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/memory.c#L3759) | 3759 |
| [`wp_page_shared()`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/memory.c#L4067) | 4067 |
| [`wp_page_copy()`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/memory.c#L3853) | 3853 |

---

##   3: Page Table Theory & Structure (AArch64)

### 3a. Why Multi-Level Page Tables

A single-level page table for a 48-bit virtual address space with 4 KiB pages would need:

```
2^48 / 2^12 = 2^36 = 64 billion entries
64 billion × 8 bytes = 512 GiB per process
```

This is obviously impossible — the page table would be larger than most systems' total RAM.

**Multi-level page tables** solve this by being **sparse**. Only the portions of the address
space that are actually mapped need page table pages allocated. A process using 100 MiB of
virtual address space might need only a few hundred KiB of page table pages, not 512 GiB.

Each level of the table covers a portion of the virtual address bits. If an entry at any level
is "not present", the entire sub-tree below it does not exist — no memory allocated for those
table pages.

As the book puts it: "Page tables are arranged in a hierarchy of page table levels; for a page
to exist at a lower level in the hierarchy, at least one entry has to exist at a higher level
pointing to it. This means we only ever allocate metadata if we have at least one mapping in
it."

### 3b. AArch64 Page Size & Level Configurations

AArch64 uniquely supports three different base page sizes, unlike x86-64 which is fixed at 4 KiB.
The page size determines how many bits each page table level resolves and how many levels are
needed.

Each page table page is always one base page in size. With 8-byte entries, the number of entries
per table is:

```
entries_per_table = page_size / 8
```

The kernel computes this as:

Reference: [`arch/arm64/include/asm/pgtable-hwdef.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L10-L13)

```c
#define PTDESC_ORDER           3                           // log2(8) = 3 (entry size)
#define PTDESC_TABLE_SHIFT     (PAGE_SHIFT - PTDESC_ORDER) // bits resolved per level
```

| Page Size | PAGE_SHIFT | PTDESC_TABLE_SHIFT | Entries per Table |
|-----------|------------|--------------------|----|
| 4 KiB     | 12         | 9                  | 512 (2^9) |
| 16 KiB    | 14         | 11                 | 2048 (2^11) |
| 64 KiB    | 16         | 13                 | 8192 (2^13) |

The number of page table levels depends on the configured virtual address width (`VA_BITS`):

Reference: [`arch/arm64/include/asm/pgtable-hwdef.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L31-L32)

```c
#define ARM64_HW_PGTABLE_LEVELS(va_bits) \
    (((va_bits) - PTDESC_ORDER - 1) / PTDESC_TABLE_SHIFT)
```

The shift for each level is computed as:

Reference: [`arch/arm64/include/asm/pgtable-hwdef.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L47)

```c
#define ARM64_HW_PGTABLE_LEVEL_SHIFT(n) \
    (PTDESC_TABLE_SHIFT * (4 - (n)) + PTDESC_ORDER)
```

Where `n` is the ARM-defined level number (0 = highest, 3 = lowest/PTE level).

#### Common AArch64 Configurations

| Config | VA_BITS | Levels | PGDIR_SHIFT | PUD_SHIFT | PMD_SHIFT | PAGE_SHIFT |
|--------|---------|--------|-------------|-----------|-----------|------------|
| 4K / 39-bit | 39 | 3 | 30 | — | 21 | 12 |
| **4K / 48-bit** | **48** | **4** | **39** | **30** | **21** | **12** |
| 4K / 52-bit | 52 | 5 | 48 | 39 | 21 | 12 |
| 16K / 47-bit | 47 | 3 | 36 | — | 25 | 14 |
| 16K / 48-bit | 48 | 4 | 47 | 36 | 25 | 14 |
| 64K / 42-bit | 42 | 2 | 42 | — | 29 | 16 |
| 64K / 48-bit | 48 | 3 | 42 | — | 29 | 16 |

When fewer levels are configured, the kernel folds away unused levels. For example, with 3
levels (4K/39-bit), `p4d_offset()` and `pud_offset()` become no-ops — the code still
references them but they compile away:

Reference: [`arch/arm64/include/asm/pgtable-types.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-types.h#L61-L66)

```c
#if CONFIG_PGTABLE_LEVELS == 2
#include <asm-generic/pgtable-nopmd.h>
#elif CONFIG_PGTABLE_LEVELS == 3
#include <asm-generic/pgtable-nopud.h>
#elif CONFIG_PGTABLE_LEVELS == 4
#include <asm-generic/pgtable-nop4d.h>
#endif
```

### 3c. AArch64 4-Level Page Table (4 KiB Pages, 48-bit VA)

This is the most common configuration for modern AArch64 servers.

The 48-bit virtual address is split into 5 fields:

```
Virtual Address (48 bits used, upper bits select TTBR0 or TTBR1):

 63      55 54..48   47      39 38      30 29      21 20      12 11         0
┌──────────┬───────┬──────────┬──────────┬──────────┬──────────┬────────────┐
│ TTBR sel │ (tag) │   PGD    │   PUD    │   PMD    │   PTE    │  Offset    │
│ bit 55   │       │  index   │  index   │  index   │  index   │            │
│          │       │  9 bits  │  9 bits  │  9 bits  │  9 bits  │  12 bits   │
└──────────┴───────┴──────────┴──────────┴──────────┴──────────┴────────────┘
                    PGDIR_SHIFT PUD_SHIFT  PMD_SHIFT PAGE_SHIFT
                       =39        =30        =21       =12
```

**Verification**: 9 + 9 + 9 + 9 + 12 = 48 bits. Correct.

| Level | Kernel Name | ARM Level | Entries | Each Entry Covers | Index Bits |
|-------|-------------|-----------|---------|-------------------|------------|
| L0 (top) | PGD (Page Global Directory) | Level 0 | 512 | 512 GiB | [47:39] |
| L1 | PUD (Page Upper Directory) | Level 1 | 512 | 1 GiB | [38:30] |
| L2 | PMD (Page Middle Directory) | Level 2 | 512 | 2 MiB | [29:21] |
| L3 (bottom) | PTE (Page Table Entry) | Level 3 | 512 | 4 KiB | [20:12] |

Each table page: 512 entries × 8 bytes = 4096 bytes = exactly one 4 KiB page.

Total addressable per TTBR: 2^48 = 256 TiB.

```
Virtual Address: 1111111111111111 110101110 011000111 011110101 011011011 111011101111
                 (0xFFFFD731DEADBEEF)

[63:48] 1111111111111111 ──▶ Selects TTBR1_EL1 (Kernel Space)
                                 │
                                 ▼
                         ┌──────────────┐
                         │ TTBR1_EL1    │
                         │ [47:12] Base ├─────────────────────────────────┐
                         └──────────────┘                                 │
                                                                          │ Points to Table Base
                                                                          ▼
                                                                 ┌──────────────────┐
                                                                 │ Level 0 / PGD    │
                                                                 ├──────────────────┤
                                                                 │ entry 0          │
                                                                 │ ...              │
[47:39] 110101110 (Index 430) ──────────────────────────────────▶│ entry 430        ├──────┐ Table Descriptor:
                                                                 │ ...              │      │ bits [47:12] = Level 1 Base PA
                                                                 │ entry 511        │      │ bits [1:0]   = 0b11 (Table)
                                                                 └──────────────────┘      │
                                                                                           ▼
                                                                                  ┌──────────────────┐
                                                                                  │ Level 1 / PUD    │
                                                                                  ├──────────────────┤
                                                                                  │ entry 0          │
                                                                                  │ ...              │
[38:30] 011000111 (Index 199) ───────────────────────────────────────────────────▶│ entry 199        ├──────┐ Table Descriptor:
                                                                                  │ ...              │      │ bits [47:12] = Level 2 Base PA
                                                                                  │ entry 511        │      │ bits [1:0]   = 0b11 (Table)
                                                                                  └──────────────────┘      │
                                                                                                            ▼
                                                                                                   ┌──────────────────┐
                                                                                                   │ Level 2 / PMD    │
                                                                                                   ├──────────────────┤
                                                                                                   │ entry 0          │
                                                                                                   │ ...              │
[29:21] 011110101 (Index 245) ────────────────────────────────────────────────────────────────────▶│ entry 245        ├──────┐ Table Descriptor:
                                                                                                   │ ...              │      │ bits [47:12] = Level 3 Base PA
                                                                                                   │ entry 511        │      │ bits [1:0]   = 0b11 (Table)
                                                                                                   └──────────────────┘      │
                                                                                                                             ▼
                                                                                                                    ┌──────────────────┐
                                                                                                                    │ Level 3 / PTE    │
                                                                                                                    ├──────────────────┤
                                                                                                                    │ entry 0          │
                                                                                                                    │ ...              │
[20:12] 011011011 (Index 219) ─────────────────────────────────────────────────────────────────────────────────────▶│ entry 219        ├──────┐ Page Descriptor:
                                                                                                                    │ ...              │      │ bits [47:12] = Frame Base PA
                                                                                                                    └──────────────────┘      │ bits [1:0]   = 0b11 (Page)
                                                                                                                                              ▼
                                                                                                                                   Physical Page Frame
                                                                                                                                   Base Address [47:12]
                                                                                                                                              │
                                                                                                                                        (Concatenate)
                                                                                                                                              │
[11:0]  111011101111 (Offset 0xEEF / 3823) ───────────────────────────────────────────────────────────────────────────────────────────────────▶ Offset [11:0]
                                                                                                                                              │
                                                                                                                                              ▼
                                                                                                                                   Target Physical Address

 Each non-leaf entry is a Table Descriptor:
   bits [47:12] = physical address of next-level table page
   bits [1:0]   = 0b11 (Table type)
   remaining bits = attributes/flags

 Each leaf (PTE) entry is a Page Descriptor:
   bits [47:12] = physical address of the 4 KiB page frame
   bits [1:0]   = 0b11 (Page type)
   remaining bits = permission/attribute flags
```

![Figure 3-4: 4-level page table layout, 4 KiB pages](/assets/x86_64_4kb_4_level_page_table.png.png)

### 3d. AArch64 5-Level Page Table (4 KiB Pages, 52-bit VA)

5-level paging adds an extra level above PGD, extending the virtual address space from 48 to
52 bits. In the Linux kernel this extra level is called **P4D** (Page 4th-level Directory).

```
Virtual Address (52 bits used):

 63  55 54..52  51      48 47      39 38      30 29      21 20      12 11         0
┌──────┬──────┬──────────┬──────────┬──────────┬──────────┬──────────┬────────────┐
│ TTBR │ tag  │   P4D    │   PGD    │   PUD    │   PMD    │   PTE    │  Offset    │
│ sel  │      │  index   │  index   │  index   │  index   │  index   │            │
│      │      │  4 bits  │  9 bits  │  9 bits  │  9 bits  │  9 bits  │  12 bits   │
└──────┴──────┴──────────┴──────────┴──────────┴──────────┴──────────┴────────────┘
```

**Verification**: 4 + 9 + 9 + 9 + 9 + 12 = 52 bits.

Note that the P4D index is only 4 bits (16 entries), not 9 bits — it uses the bits between the
PGDIR_SHIFT at 48 and bit 51. This asymmetry is because 52 = 48 + 4.

| Level | Name | Each Entry Covers |
|-------|------|-------------------|
| L5 | P4D | 256 TiB |
| L4 | PGD | 512 GiB |
| L3 | PUD | 1 GiB |
| L2 | PMD | 2 MiB |
| L1 | PTE | 4 KiB |

Total addressable per TTBR: 2^52 = 4 PiB.

On 4-level systems P4D is folded — the kernel code still references it but it compiles to a
no-op via `asm-generic/pgtable-nop4d.h`.

![Figure 3-1: 5-level page table layout, 4 KiB pages]( /assets/x86_64_4kb_5_level_page_table.png)

### 3e. Huge Pages — Dropping a Page Table Level

Standard 4 KiB pages work well for general-purpose allocation, but they impose overhead for large, contiguous memory regions: each page requires its own PTE, and the TLB (Translation Lookaside Buffer) — the hardware cache of recent address translations — can only hold a limited number of entries. A workload accessing 1 GiB of memory through 4 KiB pages needs 262,144 PTEs and will constantly evict TLB entries, causing expensive page table walks on every miss. Huge pages solve this by mapping a single page table entry to a much larger physical frame — 2 MiB or 1 GiB — drastically reducing both page table memory consumption and TLB pressure. On AArch64, huge pages are implemented via **Block Descriptors**: instead of an intermediate-level entry pointing to the next page table level, it points directly to a large aligned physical frame. The entry's type bits are set to 0b01 (Block) instead of 0b11 (Table), and the remaining address bits below that level become the offset within the huge page.

#### 2 MiB Huge Pages (PMD-level block)

The PMD entry points directly to a 2 MiB physical frame. The PTE level is eliminated:

```
Virtual Address (48-bit, 2 MiB pages):

 63  55 47      39 38      30 29      21 20                          0
┌──────┬──────────┬──────────┬──────────┬────────────────────────────┐
│ TTBR │   PGD    │   PUD    │   PMD    │       Offset               │
│ sel  │  index   │  index   │  index   │       21 bits              │
│      │  9 bits  │  9 bits  │  9 bits  │       (2^21 = 2 MiB)      │
└──────┴──────────┴──────────┴──────────┴────────────────────────────┘
```

```
 TTBR
  │
  ▼
┌──────┐    ┌──────┐    ┌──────────┐
│ PGD  │───▶│ PUD  │───▶│   PMD    │──▶ 2 MiB Physical Frame
│ L0   │    │ L1   │    │   L2     │    + Offset [20:0]
│[47:39│    │[38:30│    │ [29:21]  │
│  ]   │    │  ]   │    │ Type=    │
└──────┘    └──────┘    │ Block    │    ← Block descriptor (bits[1:0]=01)
                        └──────────┘
                        PMD entry is a Block Descriptor
                        → No PTE level, PMD IS the last level
                        → Offset is 21 bits (2 MiB)
```

![Figure 3-2: 5-level page table layout, 2 MiB huge pages]( /assets/x86_64_2mb_5_level_page_table.png.png)

#### 1 GiB Huge Pages (PUD-level block)

Similarly, 1 GiB huge pages eliminate both PMD and PTE levels — the PUD entry is a Block
Descriptor pointing directly to a 1 GiB physical frame, and the offset is 30 bits.

The kernel detects huge pages during the page table walk:

Reference: [`arch/arm64/include/asm/pgtable.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable.h#L779-L785), [`pud_leaf`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable.h#L876-L879)

```c
#define pmd_table(pmd)  ((pmd_val(pmd) & PMD_TYPE_MASK) == PMD_TYPE_TABLE)
#define pmd_leaf(pmd)   (pmd_present(pmd) && !pmd_table(pmd))  // Block descriptor

#define pud_table(pud)  ((pud_val(pud) & PUD_TYPE_MASK) == PUD_TYPE_TABLE)
#define pud_leaf(pud)   (pud_present(pud) && !pud_table(pud))  // 1 GiB block
```

#### Contiguous Bit (AArch64-specific)

AArch64 provides a **Contiguous** bit (`PTE_CONT`, bit 52) that hints to the TLB that a group
of adjacent entries all map contiguous physical memory with the same attributes. This allows
the TLB to cache a single entry for the entire group rather than one entry per page:

- With 4 KiB pages: 16 contiguous PTEs → one 64 KiB TLB entry
- With 4 KiB pages: 16 contiguous PMD blocks → one 32 MiB TLB entry

Reference: [`arch/arm64/include/asm/pgtable-hwdef.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L90-L91)

```c
#define CONT_PTE_SHIFT   (CONFIG_ARM64_CONT_PTE_SHIFT + PAGE_SHIFT)
#define CONT_PTES        (1 << (CONT_PTE_SHIFT - PAGE_SHIFT))
```

When `CONFIG_ARM64_CONTPTE` is enabled, the kernel's PTE manipulation API transparently
folds and unfolds contiguous PTE groups.

### 3f. AArch64 Page Table Descriptor Bit Layout

Each page table entry is 64 bits (8 bytes). The format differs between Table Descriptors
(non-leaf entries pointing to the next level) and Block/Page Descriptors (leaf entries pointing
to physical memory).

#### Level 3 Page Descriptor (PTE)

```
 Bit: 63  58..55  54  53  52  51  50  [49:12]        11  10  [9:8]  7   6  [4:2]  1  0
    ┌────┬───────┬───┬───┬───┬───┬───┬───────────────┬───┬───┬─────┬───┬───┬─────┬───┬───┐
    │ SW │  SW   │UXN│PXN│Con│DBM│ GP│ Output Addr   │ nG│ AF│ SH  │AP │AP │Attr │Typ│ V │
    │bits│  bits │   │   │ t │   │   │ (PA bits)     │   │   │[1:0]│[2]│[1]│Indx │   │   │
    └────┴───────┴───┴───┴───┴───┴───┴───────────────┴───┴───┴─────┴───┴───┴─────┴───┴───┘
      55   58-55   54  53  52  51  50    49..12         11  10  9:8   7   6  4:2   1   0
```

**PTE Bit Layout (Hardware-Defined)**

Reference: [`arch/arm64/include/asm/pgtable-hwdef.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L164-L176)

| Bit(s) | Name | Meaning |
|--------|------|---------|
| 0 | PTE_VALID | Valid bit – if clear, MMU raises translation fault |
| [1:0]=0b11 | PTE_TYPE_PAGE | Identifies a 4 KiB page descriptor |
| [4:2] | PTE_ATTRINDX | Memory attribute index into MAIR register |
| 6 | PTE_USER | AP[1] – if set, EL0 (user) can access |
| 7 | PTE_RDONLY | AP[2] – if set, page is read-only |
| [9:8] | PTE_SHARED | Shareability (inner shareable for SMP) |
| 10 | PTE_AF | Access Flag – if clear, first access raises access flag fault |
| 11 | PTE_NG | not-Global (ASID-tagged in TLB) |
| [49:12] | Output Address | Physical page frame address (up to 50 bits for 52-bit PA) |
| 50 | PTE_GP | Guarded Page – BTI branch target enforcement |
| 51 | PTE_DBM | Dirty Bit Management (hardware dirty tracking) |
| 52 | PTE_CONT | Contiguous hint – TLB can merge with adjacent entries (see 3e) |
| 53 | PTE_PXN | Privileged Execute Never |
| 54 | PTE_UXN | User Execute Never |

**Software-defined bits** (used by Linux, invisible to MMU hardware):

Reference: [`arch/arm64/include/asm/pgtable-prot.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-prot.h#L16-L31)

| Bit | Name | Meaning |
|-----|------|---------|
| 51 | PTE_WRITE | Software writable flag (aliased to DBM bit) |
| 55 | PTE_DIRTY | Software dirty bit |
| 56 | PTE_SPECIAL | Special mapping (VM_PFNMAP, etc.) |
| 11 | PTE_PRESENT_INVALID | Present to software, invalid to hardware (aliased to PTE_NG) |
| 58 | PTE_UFFD_WP | Userfaultfd write-protect |

#### The AArch64 Dirty Bit Dance

AArch64 uses a clever two-part scheme for dirty tracking that interleaves hardware DBM with
software bits. Understanding this is essential for reading the kernel's PTE helpers.

The hardware **DBM** (Dirty Bit Management, bit 51) works as follows: when a page is writable
and AP[2]=1 (read-only), the hardware will automatically clear AP[2] on the first write,
making the page read-write. This acts as an automatic dirty detection mechanism.

Linux overlays this with a software `PTE_DIRTY` bit (bit 55). The combined truth table:

| State | PTE_RDONLY (AP[2]) | PTE_WRITE (bit 51) | PTE_DIRTY (bit 55) |
|-------|--------------------|--------------------|---------------------|
| Clean, read-only | 1 | 0 | 0 |
| Clean, writable | 1 | 1 | 0 |
| Dirty, read-only | 1 | 0 | 1 |
| Dirty, writable | 0 | 1 | (don't care) |

A page that is writable starts with AP[2]=1 (read-only to hardware). When the process writes,
the hardware clears AP[2], making it truly writable. The kernel detects this by checking:

Reference: [`arch/arm64/include/asm/pgtable.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable.h#L167-L169)

```c
#define pte_hw_dirty(pte)  (pte_write(pte) && !pte_rdonly(pte))  // hardware dirtied
#define pte_sw_dirty(pte)  (!!(pte_val(pte) & PTE_DIRTY))       // software dirtied
#define pte_dirty(pte)     (pte_sw_dirty(pte) || pte_hw_dirty(pte))
```

When the kernel write-protects a page (e.g., for COW), `pte_wrprotect()` must preserve the
dirty state: if the hardware already cleared AP[2] (hardware-dirty), it saves this to the
software `PTE_DIRTY` bit before setting AP[2] back to read-only and clearing PTE_WRITE:

Reference: [`arch/arm64/include/asm/pgtable.h` — `pte_wrprotect()`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable.h#L280-L292)

```c
static inline pte_t pte_wrprotect(pte_t pte)
{
    // If hw-dirty, save to software dirty bit before write-protecting
    if (pte_hw_dirty(pte))
        pte = pte_mkdirty(pte);    // sets PTE_DIRTY (bit 55)
    pte = clear_pte_bit(pte, __pgprot(PTE_WRITE));
    pte = set_pte_bit(pte, __pgprot(PTE_RDONLY));
    return pte;
}
```

#### Block Descriptors (PMD / PUD level)

Block descriptors at the PMD and PUD levels have the same flag layout as Page descriptors,
with type bits [1:0] = 0b01 instead of 0b11. The kernel defines level-specific macros:

Reference: [`arch/arm64/include/asm/pgtable-hwdef.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L137-L151)

```c
#define PMD_TYPE_TABLE   (_AT(pmdval_t, 3) << 0)   // 0b11 — Table descriptor
#define PMD_TYPE_SECT    (_AT(pmdval_t, 1) << 0)   // 0b01 — Block (section) descriptor
#define PMD_SECT_AF      (_AT(pmdval_t, 1) << 10)
#define PMD_SECT_RDONLY  (_AT(pmdval_t, 1) << 7)
#define PMD_SECT_USER    (_AT(pmdval_t, 1) << 6)
#define PMD_SECT_PXN     (_AT(pmdval_t, 2) << 53)
#define PMD_SECT_UXN     (_AT(pmdval_t, 1) << 54)
#define PMD_SECT_CONT    (_AT(pmdval_t, 1) << 52)
```

All PMD-level operations delegate through conversion to PTE operations:

Reference: [`arch/arm64/include/asm/pgtable.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable.h#L580-L605)

```c
#define pmd_present(pmd)       pte_present(pmd_pte(pmd))
#define pmd_dirty(pmd)         pte_dirty(pmd_pte(pmd))
#define pmd_write(pmd)         pte_write(pmd_pte(pmd))
#define pmd_wrprotect(pmd)     pte_pmd(pte_wrprotect(pmd_pte(pmd)))
#define pmd_mkdirty(pmd)       pte_pmd(pte_mkdirty(pmd_pte(pmd)))
// ... etc.
```

### 3g. Kernel Page Table Entry Types (Type Safety)

The kernel wraps each level's 64-bit descriptor in a struct for compile-time type safety,
preventing a PGD entry from accidentally being used where a PMD entry is expected:

Reference: [`arch/arm64/include/asm/pgtable-types.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-types.h#L20-L57)

```c
typedef u64 ptval_t;

typedef ptval_t pteval_t;   // PTE (level 3)
typedef ptval_t pmdval_t;   // PMD (level 2)
typedef ptval_t pudval_t;   // PUD (level 1)
typedef ptval_t p4dval_t;   // P4D (level 0)
typedef ptval_t pgdval_t;   // PGD

typedef struct { pteval_t pte; } pte_t;
typedef struct { pmdval_t pmd; } pmd_t;    // when CONFIG_PGTABLE_LEVELS > 2
typedef struct { pudval_t pud; } pud_t;    // when CONFIG_PGTABLE_LEVELS > 3
typedef struct { pgdval_t pgd; } pgd_t;
typedef struct { ptval_t pgprot; } pgprot_t;  // page protection flags
```

Each type has accessor macros:
- `pte_val(x)` — extracts the raw u64 from a `pte_t`
- `__pte(x)` — constructs a `pte_t` from a raw u64

### 3h. Page Table Operations — Linux Kernel API (AArch64)

#### Walking the Page Table

Reference: [`pgd_offset`](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/pgtable.h#L149), [`pte_offset_map`](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/mm.h#L3832)

```c
pgd_t *pgd = pgd_offset(mm, addr);       // mm->pgd + PGD index from addr
p4d_t *p4d = p4d_offset(pgd, addr);      // folded to no-op on < 5 levels
pud_t *pud = pud_offset(p4d, addr);      // folded to no-op on < 4 levels
pmd_t *pmd = pmd_offset(pud, addr);
pte_t *pte = pte_offset_map(pmd, addr);  // maps the PTE page + returns pointer
// ... use the PTE ...
pte_unmap(pte);                           // unmap when done
```

#### Testing PTE Flags

Reference: [`arch/arm64/include/asm/pgtable.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable.h#L146-L171)

```c
pte_valid(pte)     // bit 0 (Valid) — is entry valid to hardware?
pte_present(pte)   // valid OR present-invalid — is page present to software?
pte_write(pte)     // bit 51 (PTE_WRITE/DBM) — is page writable?
pte_rdonly(pte)    // bit 7 (AP[2]) — is AP read-only?
pte_dirty(pte)     // software dirty OR hardware dirty — has page been written?
pte_young(pte)     // bit 10 (AF) — has page been accessed recently?
pte_user(pte)      // bit 6 (AP[1]) — is page user-accessible?
pte_user_exec(pte) // !(UXN) — is user execution allowed?
pte_cont(pte)      // bit 52 (Cont) — is this part of a contiguous group?
pte_special(pte)   // bit 56 (SW) — is this a special mapping?
```

#### Modifying PTE Flags

Reference: [`arch/arm64/include/asm/pgtable.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable.h#L254-L314)

```c
pte_mkwrite(pte)     // set PTE_WRITE; if sw-dirty, clear PTE_RDONLY
pte_wrprotect(pte)   // clear PTE_WRITE, set PTE_RDONLY; preserve dirty in SW bit
pte_mkdirty(pte)     // set PTE_DIRTY; if writable, clear PTE_RDONLY
pte_mkclean(pte)     // clear PTE_DIRTY, set PTE_RDONLY
pte_mkyoung(pte)     // set AF (Access Flag)
pte_mkold(pte)       // clear AF (Access Flag)
pte_mkspecial(pte)   // set PTE_SPECIAL
pte_mkcont(pte)      // set Contiguous bit
pte_mknoncont(pte)   // clear Contiguous bit
```

#### Creating and Installing PTEs

Reference: [`arch/arm64/include/asm/pgtable.h` — `pfn_pte`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable.h#L137), [`__set_pte`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable.h#L375)

```c
pte_t pte = pfn_pte(pfn, prot);          // create PTE from PFN + pgprot_t
pte_t pte = mk_pte(page, prot);          // create PTE from struct page + pgprot_t
set_pte(ptep, pte);                       // write PTE to page table
set_pte_at(mm, addr, ptep, pte);          // write PTE with barriers
```

On AArch64, [`__set_pte()`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable.h#L375) uses `WRITE_ONCE` followed by `dsb(ishst); isb()` barriers for
valid kernel PTEs — this ensures the store is visible to the hardware page table walker on all
cores before the CPU continues executing.

#### Atomic PTE Operations

These are critical for SMP correctness:

Reference: [`__ptep_test_and_clear_young`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable.h#L1305), [`__ptep_get_and_clear`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable.h#L1378), [`___ptep_set_wrprotect`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable.h#L1424)

```c
__ptep_test_and_clear_young(ptep)   // atomically clear AF using cmpxchg_relaxed
__ptep_get_and_clear(ptep)          // atomically read and zero PTE using xchg_relaxed
___ptep_set_wrprotect(ptep)         // atomically write-protect, preserving hw dirty
```

#### Complete Page Table Helper Function Table

| Operation | PUD | PMD | PTE |
|-----------|-----|-----|-----|
| Get raw value | `pud_val()` | `pmd_val()` | `pte_val()` |
| Cast raw value | `__pud()` | `__pmd()` | `__pte()` |
| Get index | `pud_index()` | `pmd_index()` | `pte_index()` |
| Get next level | `pud_offset()` | `pmd_offset()` | `pte_offset_map()` |
| Get PFN | `pud_pfn()` | `pmd_pfn()` | `pte_pfn()` |
| Is empty? | `pud_none()` | `pmd_none()` | `pte_none()` |
| Are same? | `pud_same()` | `pmd_same()` | `pte_same()` |
| Is leaf (huge)? | `pud_leaf()` | `pmd_leaf()` | — |
| Is table? | `pud_table()` | `pmd_table()` | — |
| From PFN+flags | `pfn_pud()` | `pfn_pmd()` | `pfn_pte()` |
| Set entry | `set_pud()` | `set_pmd()` | `set_pte()` |
| Clear | `pud_clear()` | `pmd_clear()` | `pte_clear()` |
| Allocate next level | `pud_alloc()` | `pmd_alloc()` | `pte_alloc()` |
| Free | `pud_free()` | `pmd_free()` | `pte_free()` |

### 3i. Page Table Walk — Complete Example

Given a `mm_struct` and a virtual address, the full page table walk to find the physical
address:

```c
unsigned long va_to_pa(struct mm_struct *mm, unsigned long addr)
{
    pgd_t *pgd;
    p4d_t *p4d;
    pud_t *pud;
    pmd_t *pmd;
    pte_t *pte;

    /* Level 0: PGD — mm->pgd is the TTBR value */
    pgd = pgd_offset(mm, addr);
    if (pgd_none(*pgd) || pgd_bad(*pgd))
        return -1;

    /* Level 0.5: P4D — folded on < 5 levels */
    p4d = p4d_offset(pgd, addr);
    if (p4d_none(*p4d) || p4d_bad(*p4d))
        return -1;

    /* Level 1: PUD */
    pud = pud_offset(p4d, addr);
    if (pud_none(*pud))
        return -1;
    if (pud_leaf(*pud))
        // 1 GiB block: PA from PUD entry + 30-bit offset
        return (pud_pfn(*pud) << PAGE_SHIFT) | (addr & ~PUD_MASK);

    /* Level 2: PMD */
    pmd = pmd_offset(pud, addr);
    if (pmd_none(*pmd))
        return -1;
    if (pmd_leaf(*pmd))
        // 2 MiB block: PA from PMD entry + 21-bit offset
        return (pmd_pfn(*pmd) << PAGE_SHIFT) | (addr & ~PMD_MASK);

    /* Level 3: PTE */
    pte = pte_offset_map(pmd, addr);
    if (!pte || !pte_present(*pte)) {
        if (pte) pte_unmap(pte);
        return -1;
    }

    unsigned long pa = (pte_pfn(*pte) << PAGE_SHIFT) | (addr & ~PAGE_MASK);
    pte_unmap(pte);
    return pa;
}
```

At each level, the walker checks:
1. Is the entry present? (`*_none()` checks)
2. Is it a block/huge page? (`*_leaf()` checks — Block descriptor type)
3. If neither, follow the pointer to the next-level table page

![Page table walk visualization]( /assets/page_table.png)

### 3j. AArch64 vs x86-64 Key Differences

| Aspect | AArch64 | x86-64 |
|--------|---------|--------|
| Base page sizes | 4K, 16K, or 64K (configurable) | 4K only |
| TTBR registers | Two: TTBR0 (user), TTBR1 (kernel) | One: CR3 (both) |
| User/kernel split | Bit 55 selects TTBR | Canonical address hole |
| ASID | Hardware ASID in TTBR0 (8 or 16 bit) | PCID (12-bit) in CR3 |
| Dirty tracking | DBM + AP[2] hardware mechanism | Hardware D bit (bit 6) |
| Execute-never | Separate PXN and UXN bits | Single NX bit (bit 63) |
| Global bit | nG=0 means global | G=1 means global |
| Huge page indicator | Block descriptor (type bits = 0b01) | PS bit (bit 7) in PMD/PUD |
| Contiguous hint | PTE_CONT (bit 52) for TLB optimization | Not available |
| Memory types | MAIR_EL1 register (8 types) | PAT + PCD + PWT bits |
| Table folding | Up to 5 levels, folded via generic headers | 4 or 5 levels |
| 4KB 4 level page table | 48 bit | 48 bit |
| 4KB 5 level page table | 52 bit | 57 bit |
