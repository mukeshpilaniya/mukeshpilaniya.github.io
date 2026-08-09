---
published: true
categories: [memory]
tags: [virtual memory]
---
# ARM64 (AArch64) Virtual Memory FAQ

Reference kernel source: [`linux/`](https://github.com/torvalds/linux/tree/v7.2-rc5) (v7.2-rc5)
Architecture: AArch64 with 4KB pages, 48-bit VA, 4-level page table (PGD → PUD → PMD → PTE)

```
Virtual Address layout (48 bits used, upper bits select TTBR0 or TTBR1):

 63      55 54..48   47      39 38      30 29      21 20      12 11         0
┌──────────┬───────┬──────────┬──────────┬──────────┬──────────┬────────────┐
│ TTBR sel │ (tag) │   PGD    │   PUD    │   PMD    │   PTE    │  Offset    │
│ bit 55   │       │  index   │  index   │  index   │  index   │            │
│          │       │  9 bits  │  9 bits  │  9 bits  │  9 bits  │  12 bits   │
└──────────┴───────┴──────────┴──────────┴──────────┴──────────┴────────────┘
                    PGDIR_SHIFT PUD_SHIFT  PMD_SHIFT PAGE_SHIFT
                       =39        =30        =21       =12
```

---

## Table of Contents

1. [How does the CPU know which page table level it is reading?](#1-how-does-the-cpu-know-which-page-table-level-it-is-reading)
2. [What is stored in TTBR0_EL1 and where does the PGD base address come from?](#2-what-is-stored-in-ttbr0_el1-and-where-does-the-pgd-base-address-come-from)
3. [Does TTBR0_EL1 store a physical address? How does the CPU work with virtual addresses then?](#3-does-ttbr0_el1-store-a-physical-address-how-does-the-cpu-work-with-virtual-addresses-then)
4. [Is TTBR0_EL1 the same for all virtual addresses within a process?](#4-is-ttbr0_el1-the-same-for-all-virtual-addresses-within-a-process)
5. [How does the kernel allocate a new PGD when a process starts? Can two processes share a PGD?](#5-how-does-the-kernel-allocate-a-new-pgd-when-a-process-starts-can-two-processes-share-a-pgd)
6. [How does the kernel ensure a PGD page contains no stale data? Can page table pages be swapped to disk?](#6-how-does-the-kernel-ensure-a-pgd-page-contains-no-stale-data-can-page-table-pages-be-swapped-to-disk)
7. [How does virt_to_phys() work? Does it perform a page table walk?](#7-how-does-virt_to_phys-work-does-it-perform-a-page-table-walk)
8. [How does pgd_alloc() work? Does it call vmalloc?](#8-how-does-pgd_alloc-work-does-it-call-vmalloc)
9. [How does the kernel track free physical pages?](#9-how-does-the-kernel-track-free-physical-pages)
10. [Are all 4 levels of page tables established when a process starts?](#10-are-all-4-levels-of-page-tables-established-when-a-process-starts)
11. [If virt_to_phys() exists, why is a page table walk needed for the kernel? Does the linear map limit the kernel?](#11-if-virt_to_phys-exists-why-is-a-page-table-walk-needed-for-the-kernel-does-the-linear-map-limit-the-kernel)
12. [If bits [1:0] determine descriptor type, can a physical address ending in 0b11 conflict with a table descriptor?](#12-if-bits-10-determine-descriptor-type-can-a-physical-address-ending-in-0b11-conflict-with-a-table-descriptor)
13. [Are page table entries the same format at every level? How does the kernel set the lower 12 bits?](#13-are-page-table-entries-the-same-format-at-every-level-how-does-the-kernel-set-the-lower-12-bits)

---

## 1. How does the CPU know which page table level it is reading?

**The CPU does not read the level from the page table entry — it tracks the level internally as a hardware counter.**

The MMU is a hardwired state machine. It starts at level 0 (from TTBR) and increments after each table descriptor. What bits [1:0] of each entry tell the CPU is whether to **keep walking deeper** or **stop here**.

### Descriptor type bits — bits [1:0]

Every page table entry on ARM64 encodes its type in the bottom two bits. The encoding depends on the level:

| Bits [1:0] | At levels 0, 1, 2 (non-last) | At level 3 (last level) |
|------------|-------------------------------|------------------------|
| `0b00`     | Invalid (fault)               | Invalid (fault)        |
| `0b01`     | Block descriptor              | Reserved (fault)       |
| `0b11`     | Table descriptor              | Page descriptor        |

Source — [`arch/arm64/include/asm/pgtable-hwdef.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L125-L166):

```c
/* Level 1 (PUD) */
#define PUD_TYPE_TABLE   (_AT(pudval_t, 3) << 0)   /* 0b11 → next-level table */
#define PUD_TYPE_SECT    (_AT(pudval_t, 1) << 0)   /* 0b01 → 1GB block mapping */

/* Level 2 (PMD) */
#define PMD_TYPE_TABLE   (_AT(pmdval_t, 3) << 0)   /* 0b11 → next-level table */
#define PMD_TYPE_SECT    (_AT(pmdval_t, 1) << 0)   /* 0b01 → 2MB block mapping */

/* Level 3 (PTE) */
#define PTE_TYPE_PAGE    (_AT(pteval_t, 3) << 0)    /* 0b11 → 4KB page */
```

Linux uses `_SECT` (section) rather than `_BLOCK` — a naming convention inherited from ARM32.

### The walk as a state machine

```
                     TTBR0/TTBR1 register
                           │
                           ▼
         ┌─── Level 0 (PGD) ◄── CPU knows this is level 0
         │    Read entry, check bits[1:0]
         │
         ├── 0b11 (Table) → extract address[47:12], go to Level 1
         ├── 0b01 (Block) → 512GB mapping, STOP (translation done)
         └── 0b00         → PAGE FAULT
                           │
                           ▼
         ┌─── Level 1 (PUD) ◄── CPU knows this is level 1
         │    Read entry, check bits[1:0]
         │
         ├── 0b11 (Table) → extract address, go to Level 2
         ├── 0b01 (Block) → 1GB mapping, STOP
         └── 0b00         → PAGE FAULT
                           │
                           ▼
         ┌─── Level 2 (PMD) ◄── CPU knows this is level 2
         │    Read entry, check bits[1:0]
         │
         ├── 0b11 (Table) → extract address, go to Level 3
         ├── 0b01 (Block) → 2MB huge page, STOP
         └── 0b00         → PAGE FAULT
                           │
                           ▼
         ┌─── Level 3 (PTE) ◄── CPU knows this is level 3
         │    Read entry, check bits[1:0]
         │
         ├── 0b11 (Page)  → 4KB page, STOP (translation done)
         ├── 0b01         → RESERVED → PAGE FAULT
         └── 0b00         → PAGE FAULT
```

Key points:
- **Bit 1 is the decision bit**: at non-last levels, `bit[1]=1` means "keep walking", `bit[1]=0` means "stop here (block/section)."
- **Same encoding (0b11), different meaning by level**: at levels 0–2 it means table descriptor; at level 3 it means page descriptor. The CPU knows which interpretation to use because it tracks its level.
- **Block descriptors (0b01) are how huge pages work**: a `PMD_TYPE_SECT` at level 2 maps 2MB directly; a `PUD_TYPE_SECT` at level 1 maps 1GB directly. The walk terminates early.

The kernel checks these in [`arch/arm64/include/asm/pgtable.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable.h#L779-L786):

```c
#define pmd_table(pmd)   ((pmd_val(pmd) & PMD_TYPE_MASK) == \
                          PMD_TYPE_TABLE)

#define pmd_leaf pmd_leaf
static inline bool pmd_leaf(pmd_t pmd)
{
    return pmd_present(pmd) && !pmd_table(pmd);
}
```

---

## 2. What is stored in TTBR0_EL1 and where does the PGD base address come from?

**Both `mm->pgd` (kernel virtual address) and `TTBR0_EL1` (physical address) point to the same PGD page — they are the same value at different layers.**

- **`mm->pgd`** — kernel virtual address, used by software (Linux kernel C code)
- **`TTBR0_EL1`** — physical address, used by hardware (CPU MMU)

During every context switch, the kernel converts one into the other:

```
mm->pgd  (virtual addr, e.g. 0xFFFF_0000_1234_0000)
    │
    │  virt_to_phys()
    ▼
pgd_phys (physical addr, e.g. 0x0000_0000_1234_0000)
    │
    │  write_sysreg(ttbr0, ttbr0_el1)
    ▼
TTBR0_EL1 register  ← CPU MMU reads this to start the page walk
```

### The context switch call chain

```
scheduler context_switch()
  → switch_mm(prev_mm, next_mm, next_task)             [mmu_context.h]
    → __switch_mm(next_mm)
      → check_and_switch_context(next_mm)               [context.c]
        → cpu_switch_mm(mm->pgd, mm)                    [mmu_context.h]
          → cpu_do_switch_mm(virt_to_phys(mm->pgd), mm) [context.c]
```

The key conversion — [`arch/arm64/include/asm/mmu_context.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/mmu_context.h#L58-L62):

```c
static inline void cpu_switch_mm(pgd_t *pgd, struct mm_struct *mm)
{
    BUG_ON(pgd == swapper_pg_dir);
    cpu_do_switch_mm(virt_to_phys(pgd), mm);  // virtual → physical
}
```

The actual hardware write — [`arch/arm64/mm/context.c`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/mm/context.c#L349-L372):

```c
void cpu_do_switch_mm(phys_addr_t pgd_phys, struct mm_struct *mm)
{
    unsigned long ttbr1 = read_sysreg(ttbr1_el1);
    unsigned long asid = ASID(mm);
    unsigned long ttbr0 = phys_to_ttbr(pgd_phys);

    /* Skip CNP for the reserved ASID */
    if (system_supports_cnp() && asid)
        ttbr0 |= TTBRx_EL1_CnP;

    /* SW PAN needs a copy of the ASID in TTBR0 for entry */
    if (IS_ENABLED(CONFIG_ARM64_SW_TTBR0_PAN))
        ttbr0 |= FIELD_PREP(TTBRx_EL1_ASID_MASK, asid);

    /* Set ASID in TTBR1 since TCR.A1 is set */
    ttbr1 &= ~TTBRx_EL1_ASID_MASK;
    ttbr1 |= FIELD_PREP(TTBRx_EL1_ASID_MASK, asid);

    cpu_set_reserved_ttbr0_nosync();
    write_sysreg(ttbr1, ttbr1_el1);      // ASID into TTBR1
    write_sysreg(ttbr0, ttbr0_el1);      // PGD physical addr into hardware
    isb();                                // synchronization barrier
    post_ttbr_update_workaround();
}
```

### Who uses what

```
┌─────────────────────────────────────────────────────────┐
│  SOFTWARE (kernel)                                      │
│  task->mm->pgd = 0xFFFF_0000_1234_0000  (virtual addr)  │
│  Kernel uses this to walk/modify page tables in C code  │
├─────────────── context switch ──────────────────────────┤
│  virt_to_phys(mm->pgd) → 0x0000_0000_1234_0000         │
│  write_sysreg(ttbr0, ttbr0_el1)                        │
├─────────────────────────────────────────────────────────┤
│  HARDWARE (CPU MMU)                                     │
│  TTBR0_EL1 = 0x0000_0000_1234_0000  (physical addr)     │
│  MMU reads this to start the 4-level page table walk    │
└─────────────────────────────────────────────────────────┘
```

---

## 3. Does TTBR0_EL1 store a physical address? How does the CPU work with virtual addresses then?

**Yes, TTBR0_EL1 stores a physical address — and it MUST.**

The page table is what translates virtual addresses to physical. If the CPU needed to translate the address of the page table itself, it would need another page table to find it — infinite recursion.

### How every memory access works

When code accesses a virtual address, the MMU intercepts it before it reaches the memory bus:

```
   CPU core                           Memory Bus
  ┌────────┐                         ┌────────┐
  │  mov x0,│    virtual addr        │        │
  │ [0x4000]├───────┐                │  RAM   │
  │         │       │                │        │
  └────────┘       ▼                └───┬────┘
              ┌─────────┐              │
              │   MMU   │              │
              │         │  physical    │
              │ VA→PA   ├──────────────┘
              │ translate│
              └────┬────┘
                   │ reads page tables
                   │ using PHYSICAL addresses
                   │ (these reads bypass VA→PA
                   │  translation entirely)
                   ▼
                 RAM (page table pages)
```

The MMU's table walk reads use physical addresses directly on the memory bus. They do not go through VA→PA translation. This is called a **hardware table walk**, and it operates in physical address space.

### Full walk for one memory access

```
Code:  ldr x0, [x1]     // x1 = 0x0000_7FFF_DEAD_B000 (virtual)

Step 1: CPU asks MMU — "translate 0x0000_7FFF_DEAD_B000"
Step 2: MMU reads TTBR0_EL1 = 0x4200_0000 (physical, no translation needed)
Step 3: PGD entry addr = 0x4200_0000 + (index × 8)   ← PHYSICAL read
Step 4: PGD entry → PUD at physical 0x4300_0000       ← PHYSICAL read
Step 5: PUD entry → PMD at physical 0x4400_0000       ← PHYSICAL read
Step 6: PMD entry → PTE at physical 0x4500_0000       ← PHYSICAL read
Step 7: PTE entry → page frame at 0x8800_0000
Step 8: Final PA = 0x8800_0000 + offset (VA bits [11:0])
```

Every address the MMU uses during the walk is physical. Only the original address from code is virtual.

### What uses which type of address

| Component | Addresses it uses |
|-----------|------------------|
| Userspace code | Virtual (translated by MMU via TTBR0) |
| Kernel code | Virtual (kernel's own mapping, via TTBR1) |
| MMU table walker | **Physical** (reads TTBR + page table entries directly) |
| DMA devices | Physical (bypass MMU, unless behind an IOMMU) |

---

## 4. Is TTBR0_EL1 the same for all virtual addresses within a process?

**Yes. One process = one PGD = one TTBR0 value for ALL its virtual addresses.**

The PGD is the root of a tree, and each VA takes a different path through that tree based on its index bits:

```
Process A:  TTBR0_EL1 = 0x4200_0000 (physical addr of its PGD)

    VA 0x0000_7FFF_1234_0000  ─┐
    VA 0x0000_7FFF_1457_0000  ─┼── all start from the SAME PGD at 0x4200_0000
    VA 0x0000_7FFF_6731_0000  ─┘

Different VAs → different index bits → different paths → different physical pages
```

### What changes between processes is the TTBR0 value

```
Process A running:   TTBR0_EL1 = 0x4200_0000 → Process A's PGD
        ── context switch (kernel writes new TTBR0) ──
Process B running:   TTBR0_EL1 = 0x8100_0000 → Process B's PGD
```

Both processes can use the same VA (e.g., `0x0000_7FFF_1234_0000`), but because they have different PGDs, the walk follows different trees and lands on different physical pages. This is how virtual memory provides process isolation.

### TTBR0 vs TTBR1

```
┌─────────────────────────────────────────────┐
│ Bit 55 = 0  →  TTBR0_EL1  →  user space    │
│ e.g. 0x0000_7FFF_xxxx_xxxx                  │
│ Different per process (swapped on ctx switch)│
├─────────────────────────────────────────────┤
│ Bit 55 = 1  →  TTBR1_EL1  →  kernel space  │
│ e.g. 0xFFFF_0000_xxxx_xxxx                  │
│ Same for ALL processes (swapper_pg_dir)      │
└─────────────────────────────────────────────┘
```

---

## 5. How does the kernel allocate a new PGD when a process starts? Can two processes share a PGD?

**The kernel doesn't detect a "new process" — the `fork()`/`clone()` syscall itself triggers PGD allocation.**

### The fork path — new PGD

```
fork() or clone()
  → copy_process()                        [kernel/fork.c]
    → copy_mm(clone_flags, tsk)
```

Inside [`copy_mm()`](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/fork.c#L1568-L1603), the `CLONE_VM` flag determines the path:

```c
// kernel/fork.c, line 1591
if (clone_flags & CLONE_VM) {
    // THREAD path — share the parent's mm (and PGD)
    mmget(oldmm);           // increment refcount
    mm = oldmm;             // same mm, same pgd, same page tables
} else {
    // FORK path — create a brand new mm with its own PGD
    mm = dup_mm(tsk, current->mm);
    if (!mm)
        return -ENOMEM;
}
tsk->mm = mm;
```

The fork path calls [`dup_mm()`](https://github.com/torvalds/linux/blob/v7.2-rc5/kernel/fork.c#L1527-L1566), which:

```
dup_mm()
  ├─ 1. allocate_mm()          ← new mm_struct from slab cache
  ├─ 2. mm_init()
  │     └─ mm_alloc_pgd()
  │         └─ pgd_alloc(mm)   ← ALLOCATES A FRESH PGD PAGE (zeroed)
  └─ 3. dup_mmap()             ← copies parent's VMAs + page tables
        └─ copy_page_range()      into the new PGD tree (with COW)
```

ARM64's [`pgd_alloc()`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/mm/pgd.c#L31-L40):

```c
pgd_t *pgd_alloc(struct mm_struct *mm)
{
    gfp_t gfp = GFP_PGTABLE_USER;

    if (pgdir_is_page_size())
        return __pgd_alloc(mm, 0);                // page allocator
    else
        return kmem_cache_alloc(pgd_cache, gfp);  // slab cache
}
```

This always returns a fresh, unique physical page.

### Can two processes share a PGD?

**Only threads, never independent processes.**

```
fork() (new process):            clone(CLONE_VM) (new thread):

┌──────────────────┐            ┌──────────────────┐
│ Parent (pid 100) │            │ Parent (pid 200) │
│ mm->pgd = 0x4200 │            │ mm->pgd = 0x8100 │
└──────────────────┘            └──────────────────┘
        │                               │
        ▼                               ▼
┌──────────────────┐            ┌──────────────────┐
│ Child  (pid 101) │            │ Thread (pid 201) │
│ mm->pgd = 0x5300 │            │ mm->pgd = 0x8100 │
│      NEW PGD     │            │   SHARED PGD     │
└──────────────────┘            └──────────────────┘
Different mm, different PGD     Same mm, same PGD
```

Every `fork()` guarantees a new PGD. Two independent processes can never share one. Only threads (created with `CLONE_VM`) share a PGD because they share the entire virtual address space by design.

---

## 6. How does the kernel ensure a PGD page contains no stale data? Can page table pages be swapped to disk?

### Part A: Ensuring a clean PGD — `__GFP_ZERO`

Every page table allocation includes the `__GFP_ZERO` flag, which causes the page allocator to zero the page before returning it.

Source — [`include/asm-generic/pgalloc.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/include/asm-generic/pgalloc.h#L7-L8):

```c
#define GFP_PGTABLE_KERNEL  (GFP_KERNEL | __GFP_ZERO | __GFP_SKIP_KASAN)
#define GFP_PGTABLE_USER    (GFP_PGTABLE_KERNEL | __GFP_ACCOUNT)
                                          ^^^^^^^^^^
                                          guarantees zeroed page
```

The page allocator zeroes the page in `post_alloc_hook()` ([`mm/page_alloc.c`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/page_alloc.c)) before returning it. Every PGD entry starts as `0x0000_0000_0000_0000` — bits [1:0] = `0b00` = invalid. No stale data, no stale mappings.

### Part B: Can page table pages be swapped to disk?

**No. Never.** There is a fundamental circular dependency that makes it impossible:

```
If a page table page were swapped out:

CPU translates VA → walks page table → page table page is on disk
→ need to read from disk → kernel runs code → uses virtual addresses
→ which need page table translation → which needs the page on disk
→ DEADLOCK — unrecoverable
```

Four layers of protection prevent this:

**1. Kernel memory allocation (not swappable by design)**

Page tables use `GFP_KERNEL` which does NOT include `__GFP_MOVABLE` or `__GFP_HIGHMEM`. They are allocated from `ZONE_NORMAL` — non-swappable kernel memory.

**2. Never placed on LRU lists**

The swap subsystem only reclaims pages from LRU lists. Page table pages are never added to any LRU list.

Source — [`include/linux/mm.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/mm.h#L3798-L3804):

```c
static inline void __pagetable_ctor(struct ptdesc *ptdesc)
{
    struct folio *folio = ptdesc_folio(ptdesc);

    __folio_set_pgtable(folio);
    lruvec_stat_add_folio(folio, NR_PAGETABLE);  // accounting only, NOT LRU insertion
}
```

**3. Marked with special page type**

Page table pages are tagged with [`PGTY_table`](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/page-flags.h#L919) (`include/linux/page-flags.h`). The reclaim subsystem knows these are not regular user pages.

**4. Only freed when empty, never swapped**

When all PTEs in a table become invalid, the kernel frees the empty page table page back to the buddy allocator — not to swap.

Source — [`mm/memory.c`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/memory.c#L1984):

```c
pte_free_tlb(tlb, pmd_pgtable(pmdval), addr);  // returns to buddy allocator
```

### What CAN vs what CANNOT be swapped

| Can be swapped to disk | CANNOT be swapped — must stay in RAM |
|---|---|
| User data pages (stack, heap, mmap) | Page table pages (PGD, PUD, PMD, PTE) |
| Anonymous pages (malloc'd memory) | Kernel code and data (vmlinux) |
| Pages on LRU lists | Kernel stack pages |
| | DMA buffers |
| | mlocked user pages (`mlock()`) |

---

## 7. How does virt_to_phys() work? Does it perform a page table walk?

**No page table walk. It is pure arithmetic — a single subtraction.**

The kernel's virtual address space has a region called the **linear map** where ALL of physical RAM is mapped at a fixed offset. Since the offset is constant, converting is just subtraction.

### The implementation

Source — [`arch/arm64/include/asm/memory.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/memory.h#L340-L346):

```c
#define __lm_to_phys(addr)     ((addr) - PAGE_OFFSET + PHYS_OFFSET)
#define __kimg_to_phys(addr)   ((addr) - kimage_voffset)

#define __virt_to_phys_nodebug(x) ({                              \
    phys_addr_t __x = (phys_addr_t)(__tag_reset(x));              \
    __is_lm_address(__x) ? __lm_to_phys(__x)                     \
                         : __kimg_to_phys(__x);                   \
})
```

Two cases handled by pure arithmetic:

| Address region | Formula | Notes |
|---|---|---|
| Linear map (`PAGE_OFFSET` region) | `addr - PAGE_OFFSET + PHYS_OFFSET` | Maps all of physical RAM |
| Kernel image (`KIMAGE_VADDR` region) | `addr - kimage_voffset` | vmlinux text/data/bss |

### Example

```
PAGE_OFFSET  = 0xFFFF_0000_0000_0000   (start of linear map)
PHYS_OFFSET  = 0x0000_0000_0000_0000   (start of physical RAM)

virt   = 0xFFFF_0000_4200_0000
phys   = 0xFFFF_0000_4200_0000 - 0xFFFF_0000_0000_0000 + 0x0
       = 0x0000_0000_4200_0000

Just subtraction — no page walk.
```

### Why it works — the linear map

At boot, [`map_mem()`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/mm/mmu.c#L1143) in `arch/arm64/mm/mmu.c` creates page tables (`swapper_pg_dir`) that map the entire physical RAM at a fixed virtual offset. The page tables exist for the MMU hardware, but the kernel software knows the offset is constant and uses the arithmetic shortcut.

### Critical limitation

`virt_to_phys()` **only works for kernel addresses** (linear map and kernel image). It does **NOT** work for:
- User process virtual addresses (arbitrary per-process mappings)
- `vmalloc` addresses (physically non-contiguous)

For these, a software page table walk is required. See [FAQ #11](#11-if-virt_to_phys-exists-why-is-a-page-table-walk-needed-for-the-kernel-does-the-linear-map-limit-the-kernel) for details.

---

## 8. How does pgd_alloc() work? Does it call vmalloc?

**No. `pgd_alloc()` uses the buddy page allocator (`alloc_pages`) or a slab cache — never `vmalloc`.**

Source — [`arch/arm64/mm/pgd.c`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/mm/pgd.c#L31-L40):

```c
pgd_t *pgd_alloc(struct mm_struct *mm)
{
    gfp_t gfp = GFP_PGTABLE_USER;

    if (pgdir_is_page_size())
        return __pgd_alloc(mm, 0);              // path A: buddy allocator
    else
        return kmem_cache_alloc(pgd_cache, gfp); // path B: slab cache
}
```

**Path A** — [`__pgd_alloc()`](https://github.com/torvalds/linux/blob/v7.2-rc5/include/asm-generic/pgalloc.h#L277-L296) calls `pagetable_alloc()` which calls `alloc_pages()`. Returns a page from the linear map with a known physical address.

**Path B** — `kmem_cache_alloc()` from a dedicated slab cache (`pgd_cache`). Slab memory also comes from the buddy allocator.

### Why not vmalloc?

`vmalloc` returns virtually-contiguous but **physically-scattered** pages. Page table pages need a known, stable physical address because:

1. The CPU MMU reads them using physical addresses during the hardware walk.
2. Parent page table entries store the physical address of child tables.
3. `virt_to_phys()` must work on them, and it only works on linear-map addresses.

| Allocation type | Physically contiguous? | `virt_to_phys()` works? | Used for page tables? |
|---|---|---|---|
| `alloc_pages` (buddy) | Yes | Yes | **Yes** |
| `kmem_cache_alloc` (slab) | Yes (within slab) | Yes | **Yes** |
| `vmalloc` | No (scattered) | **No** | **No** |

---

## 9. How does the kernel track free physical pages?

**The buddy allocator** — a per-zone array of free lists organized by power-of-2 block sizes.

### Data structure hierarchy

```
pg_data_t (per NUMA node)
 └─ zone[] (DMA, DMA32, Normal, HighMem, Movable)
     └─ free_area[NR_PAGE_ORDERS]          (orders 0..10)
          └─ free_list[MIGRATE_TYPES]      (UNMOVABLE, MOVABLE, RECLAIMABLE, ...)
               └─ struct page (linked via page->buddy_list)
```

Source — [`include/linux/mmzone.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/mmzone.h#L195-L198):

```c
struct free_area {
    struct list_head   free_list[MIGRATE_TYPES];  // linked lists of free blocks
    unsigned long      nr_free;                    // count at this order
};
```

The `free_area` array lives inside [`struct zone`](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/mmzone.h#L968) (member at [line 1088](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/mmzone.h#L1088)):

```c
struct zone {
    /* ... */
    struct free_area   free_area[NR_PAGE_ORDERS];  // orders 0..10
    /* ... */
};
```

Each order holds blocks of `2^order` contiguous pages:

```
free_area[0]:   blocks of 1 page     (4KB)
free_area[1]:   blocks of 2 pages    (8KB)
free_area[2]:   blocks of 4 pages    (16KB)
  ...
free_area[10]:  blocks of 1024 pages (4MB)
```

### Allocation: find and split

When you need 1 page (order 0) but only order-3 (8 pages) is available — [`mm/page_alloc.c`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/page_alloc.c#L1889-L1912), `__rmqueue_smallest()`:

```c
for (current_order = order; current_order < NR_PAGE_ORDERS; ++current_order) {
    area = &(zone->free_area[current_order]);
    page = get_page_from_free_area(area, migratetype);
    if (!page)
        continue;
    page_del_and_expand(zone, page, order, current_order, migratetype);
    return page;
}
```

The [`expand()`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/page_alloc.c#L1702-L1728) function splits the larger block, returning unused halves to lower-order free lists:

```
Request: 1 page (order 0), found order-3 block [A B C D E F G H]

Split:
  free_area[2] ← [E F G H]    (return 4 pages to order-2)
  free_area[1] ← [C D]        (return 2 pages to order-1)
  free_area[0] ← [B]          (return 1 page to order-0)
  Return [A] to caller         (the requested page)
```

### Freeing: coalesce with buddy

When a page is freed, the kernel tries to merge it with its **buddy** (adjacent block) into a larger block — [`mm/page_alloc.c`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/page_alloc.c#L936-L1022), `__free_one_page()`:

```c
while (order < MAX_PAGE_ORDER) {
    buddy = find_buddy_page_pfn(page, pfn, order, &buddy_pfn);
    if (!buddy)
        goto done_merging;
    __del_page_from_free_list(buddy, zone, order, buddy_mt);
    combined_pfn = buddy_pfn & pfn;
    page = page + (combined_pfn - pfn);
    pfn = combined_pfn;
    order++;
}
```

Buddy PFN is found with XOR — [`mm/internal.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/internal.h#L767-L771):

```c
static inline unsigned long __find_buddy_pfn(unsigned long page_pfn, unsigned int order)
{
    return page_pfn ^ (1 << order);   // flip the bit at position 'order'
}
```

```
Free page [A] at order 0:
  Buddy [B] free? YES → merge [AB] → order 1
    Buddy [CD] free? YES → merge [ABCD] → order 2
      Buddy [EFGH] free? NO → stop, insert [ABCD] into free_area[2]
```

---

## 10. Are all 4 levels of page tables established when a process starts?

**No. Only the PGD is allocated at process creation. Everything below is allocated lazily via demand paging — one page fault at a time.**

### At fork() time

[`copy_page_range()`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/memory.c#L1507) in `mm/memory.c` walks the parent's tables but **skips all empty entries**:

```c
do {
    if (pgd_none_or_clear_bad(src_pgd))    // empty PGD entry?
        continue;                           // SKIP — nothing created in child
    copy_p4d_range(...);                    // only descend into populated entries
} while (dst_pgd++, src_pgd++, ...);
```

The same skip-if-empty check repeats at every level ([`pgd_none_or_clear_bad`](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/pgtable.h#L1561) and its `p4d`/`pud`/`pmd` variants).

Even entire VMAs can be skipped — [`mm/memory.c`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/memory.c#L1482-L1504), `vma_needs_copy()`:

```c
static bool vma_needs_copy(struct vm_area_struct *dst_vma,
                           struct vm_area_struct *src_vma)
{
    if (dst_vma->vm_flags & VM_COPY_ON_FORK)
        return true;
    if (src_vma->anon_vma)
        return true;
    // File-backed VMAs never written to — skip entirely.
    // Child will fault them in from the file later.
    return false;
}
```

Shared libraries (libc, ld-linux, etc.) are read-only file mappings — their page tables are **not copied at all**.

### After exec() — completely empty

After `exec()`, the old mm is destroyed and a brand new one is created:

```
PGD: [0]=empty [1]=empty [2]=empty ... [511]=empty
     (all 512 entries are zero — no PUDs, PMDs, or PTEs exist)
```

### First instruction triggers demand paging

```
Process executes first instruction at VA 0x0000_0040_0000
  → CPU walks PGD → entry is 0 (invalid) → TRANSLATION FAULT
    → ARM64: do_mem_abort() → do_translation_fault() → do_page_fault()
      → handle_mm_fault() → __handle_mm_fault():
          pgd_offset(mm, addr)     → finds PGD entry (exists but empty)
          p4d_alloc(mm, pgd, addr) → ALLOCATES P4D, installs in PGD
          pud_alloc(mm, p4d, addr) → ALLOCATES PUD, installs in P4D
          pmd_alloc(mm, pud, addr) → ALLOCATES PMD, installs in PUD
          handle_pte_fault()
            → do_pte_missing()
              → do_fault()           (file-backed: the ELF binary)
                  pte_alloc()        → ALLOCATES PTE table
                  __do_fault()       → reads page from ELF file
                  set_pte_at()       → installs PTE → physical page
```

One page fault built all 4 levels for that single address. Nearby addresses sharing the same PGD/PUD/PMD path only need the lower levels filled in.

### The on-demand allocation functions

Source — [`mm/memory.c`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/memory.c#L6417), `__handle_mm_fault()`:

```c
static vm_fault_t __handle_mm_fault(struct vm_area_struct *vma,
        unsigned long address, unsigned int flags)
{
    /* ... vmf initialization ... */
    pgd = pgd_offset(mm, address);          // lookup — PGD always exists
    p4d = p4d_alloc(mm, pgd, address);      // ALLOCATE P4D if missing
    vmf.pud = pud_alloc(mm, p4d, address);  // ALLOCATE PUD if missing
    vmf.pmd = pmd_alloc(mm, vmf.pud, address); // ALLOCATE PMD if missing
    /* ... huge page checks ... */
    return handle_pte_fault(&vmf);           // handle PTE level
}
```

Each `*_alloc()` checks if the entry exists; if not, it allocates a new page table page, acquires a lock, checks for races, and installs it.

Source — [`mm/memory.c`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/memory.c#L6769-L6787), `__pmd_alloc()`:

```c
int __pmd_alloc(struct mm_struct *mm, pud_t *pud, unsigned long address)
{
    spinlock_t *ptl;
    pmd_t *new = pmd_alloc_one(mm, address);   // allocate a PMD page
    if (!new)
        return -ENOMEM;

    ptl = pud_lock(mm, pud);
    if (!pud_present(*pud)) {
        mm_inc_nr_pmds(mm);
        smp_wmb(); /* See comment in pmd_install() */
        pud_populate(mm, pud, new);             // install in PUD entry
    } else {   /* Another has populated it */
        pmd_free(mm, new);                      // someone raced us, free ours
    }
    spin_unlock(ptl);
    return 0;
}
```

### Lifecycle visualization

```
exec():          PGD allocated, completely empty
                 ┌─────┐
                 │ PGD │  512 entries, all zero
                 └─────┘

1st fault:       All 4 levels created for ONE address
                 ┌─────┐
                 │ PGD │→ PUD → PMD → PTE → physical page
                 └─────┘

More faults:     Levels fill in gradually
                 ┌─────┐
                 │ PGD │→ PUD → PMD → PTE → pages
                 └─────┘      → PMD → PTE → pages
                         → PUD → PMD → PTE → pages

Running program: Only touched regions have page tables
                 Of 256TB address space, maybe 50MB has page tables
```

---

## 11. If virt_to_phys() exists, why is a page table walk needed for the kernel? Does the linear map limit the kernel?

### Part A: Why the kernel still needs page tables

**`virt_to_phys()` is a SOFTWARE shortcut. The MMU HARDWARE always walks page tables — for every memory access, including the kernel's own.**

```
Two separate worlds:

SOFTWARE (kernel C code):
    virt_to_phys(x) = x - PAGE_OFFSET       ← arithmetic shortcut
    Used only when kernel EXPLICITLY needs a physical address as a data value
    (writing TTBR, programming DMA, filling page table entries)

HARDWARE (MMU, always active):
    Every instruction fetch, every load, every store
    → MMU walks TTBR1's page tables → finds physical address
    The MMU doesn't know about virt_to_phys() — it always walks
```

The kernel page tables (`swapper_pg_dir` / TTBR1) must exist because the MMU is always on. `virt_to_phys()` is the kernel being clever — *"I know the mapping is linear, so I can compute the answer without walking the tables myself."* But the hardware still walks them transparently on every access.

### Part B: Does the linear map limit the kernel?

**Yes, but the kernel virtual address space is NOT just the linear map.** It has multiple regions:

```
Kernel VA space (TTBR1): 0xFFFF_0000_0000_0000 to 0xFFFF_FFFF_FFFF_FFFF (128TB)

┌──────────────────────────────────────┐  0xFFFF_FFFF_FFFF_FFFF
│  Fixed mappings (fixmap)             │
├──────────────────────────────────────┤
│  PCI I/O space                       │
├──────────────────────────────────────┤
│  vmemmap (struct page array)         │
├──────────────────────────────────────┤
│  vmalloc / ioremap region            │  virt_to_phys() DOES NOT WORK
│  (physically non-contiguous)         │
├──────────────────────────────────────┤
│  LINEAR MAP (all of RAM)             │  virt_to_phys() WORKS
│  PAGE_OFFSET to PAGE_END             │
├──────────────────────────────────────┤
│  Kernel image (text, rodata, data)   │
├──────────────────────────────────────┤
│  Modules region                      │
└──────────────────────────────────────┘  0xFFFF_0000_0000_0000
```

With 48-bit VA, the linear map can cover ~128TB of RAM — sufficient for any current system.

### The vmalloc region — where `virt_to_phys()` breaks

`vmalloc()` allocates virtually-contiguous but physically-scattered pages:

```
vmalloc(16384):
Virtual (contiguous):           Physical (scattered):
0xFFFF_8000_0001_0000  →  0x7A00_0000
0xFFFF_8000_0001_1000  →  0x1_2300_0000  ← not adjacent!
0xFFFF_8000_0001_2000  →  0x0500_0000    ← completely different!
```

No fixed offset — `virt_to_phys()` cannot work. The kernel must do a software page table walk via `slow_virt_to_phys()`.

### Summary: three situations

| Address type | Software VA→PA method | Hardware VA→PA method |
|---|---|---|
| Kernel linear map | `virt_to_phys()` — O(1) arithmetic | Page table walk via TTBR1 (or TLB) |
| Kernel vmalloc | `slow_virt_to_phys()` — software walk | Page table walk via TTBR1 (or TLB) |
| User process VA | Software walk via `mm->pgd` | Page table walk via TTBR0 (or TLB) |

Hardware ALWAYS walks page tables (or uses TLB). Software has a shortcut ONLY for the linear map.

---

## 12. If bits [1:0] determine descriptor type, can a physical address ending in 0b11 conflict with a table descriptor?

**No — because the physical address and the descriptor type bits occupy DIFFERENT bit positions in the entry. They never overlap.**

### The entry format

```
A page table entry (64 bits) on ARM64:

 63    55 54  48 47                           12 11    2 1 0
┌────────┬──────┬──────────────────────────────┬────────┬───┐
│ upper  │ res/ │    Physical Address [47:12]   │ lower  │ T │
│ attrs  │ PBHA │    (page-aligned, so bits     │ attrs  │ y │
│        │      │     [11:0] are always 0)      │        │ p │
│        │      │                               │        │ e │
└────────┴──────┴──────────────────────────────┴────────┴───┘
                  ▲                               ▲       ▲
          Physical addr bits               Permission  Descriptor
          [47:12] only!                    bits, AF,   type bits
                                           SH, AP     [1:0]
```

### Why there is no conflict

All pages and page table pages are **aligned to 4KB** (2^12 bytes). This means the bottom 12 bits of any page's physical address are **guaranteed to be zero**. The hardware repurposes these otherwise-wasted bits for flags and type information.

```
Physical address of any page = always a multiple of 4096 (0x1000)

Valid page addresses:
  0x0000_0000_1234_0000  ← bits [11:0] = 0x000
  0x0000_0000_8000_0000  ← bits [11:0] = 0x000

IMPOSSIBLE page address:
  0x0000_0000_1234_0003  ← NOT page-aligned, can never be a page base
```

The physical address is stored in bits [47:12]. The type bits [1:0] are free to use for descriptor type. The CPU extracts the address by masking:

```c
next_table_phys = entry_value & PTE_ADDR_LOW    // mask out bits [11:0]
```

### Block descriptors have even more free bits

A PMD block descriptor (level 2) maps 2MB. 2MB = 2^21, so bits [20:0] are all zero in the address — giving even more room for attributes:

```
PMD Block descriptor (2MB mapping):
 63                47                    21 20        12 11    2 1 0
┌──────────────────┬─────────────────────┬─────────────┬────────┬───┐
│   upper attrs    │  PA bits [47:21]    │  MUST BE 0  │ lower  │0 1│
│                  │  (27 bits)          │  (2MB       │ attrs  │   │
│                  │                     │   aligned)  │        │   │
└──────────────────┴─────────────────────┴─────────────┴────────┴───┘

PUD Block descriptor (1GB): PA bits [47:30] only — bits [29:0] free
```

This is not a limitation — it is an elegant reuse of bits that would otherwise be wasted due to alignment requirements.

---

## 13. Are page table entries the same format at every level? How does the kernel set the lower 12 bits?

**Yes — every level uses the same 64-bit integer. The general layout (address in bits [47:12], type in bits [1:0]) is identical. But the meaning of the attribute bits changes depending on the level and descriptor type.**

### All levels are the same raw type — `u64`

Source — [`arch/arm64/include/asm/pgtable-types.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-types.h#L20-L53):

```c
typedef u64 ptval_t;

typedef ptval_t pteval_t;    // all aliases of the same u64
typedef ptval_t pmdval_t;
typedef ptval_t pudval_t;
typedef ptval_t pgdval_t;

typedef struct { pteval_t pte; } pte_t;   // struct wrappers for C type safety
typedef struct { pmdval_t pmd; } pmd_t;
typedef struct { pudval_t pud; } pud_t;
typedef struct { pgdval_t pgd; } pgd_t;
```

The struct wrappers exist only for compile-time type checking — so you can't accidentally pass a `pmd_t` where a `pte_t` is expected. At the hardware level, every entry is just a 64-bit integer.

### Same skeleton, different attribute bits per level

Every entry shares this structure:

```
 63       54  53  52  51  50 47           12 11  10  9:8  7   6  4:2  1:0
┌──────────┬───┬───┬───┬───┬──────────────┬───┬───┬────┬───┬───┬────┬────┐
│ upper    │UXN│PXN│   │   │  PA [47:12]  │   │AF │ SH │AP2│AP1│Attr│Type│
│ attrs    │   │   │   │   │              │   │   │    │   │   │Idx │    │
└──────────┴───┴───┴───┴───┴──────────────┴───┴───┴────┴───┴───┴────┴────┘
```

But which attribute bits are **defined** depends on the level and descriptor type:

Source — [`arch/arm64/include/asm/pgtable-hwdef.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L105-L196):

| Bit(s) | PTE (L3 page) | PMD (L2 section) | PMD (L2 table) | PUD (L1 table) | PGD (L0 table) |
|--------|---------------|------------------|----------------|----------------|----------------|
| [1:0]  | [`PTE_TYPE_PAGE`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L166) (0b11) | [`PMD_TYPE_SECT`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L138) (0b01) | [`PMD_TYPE_TABLE`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L137) (0b11) | [`PUD_TYPE_TABLE`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L125) (0b11) | [`PGD_TYPE_TABLE`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L105) (0b11) |
| [4:2]  | [`PTE_ATTRINDX`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L195) | [`PMD_ATTRINDX`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L158) | — | — | — |
| 6      | [`PTE_USER`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L167) | [`PMD_SECT_USER`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L144) | — | — | — |
| 7      | [`PTE_RDONLY`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L168) | [`PMD_SECT_RDONLY`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L145) | — | [`PUD_SECT_RDONLY`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L128) | — |
| [9:8]  | [`PTE_SHARED`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L169) | [`PMD_SECT_S`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L146) | — | — | — |
| 10     | [`PTE_AF`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L170) | [`PMD_SECT_AF`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L147) | [`PMD_TABLE_AF`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L139) | [`PUD_TABLE_AF`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L129) | [`PGD_TABLE_AF`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L107) |
| 53     | [`PTE_PXN`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L175) | [`PMD_SECT_PXN`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L150) | — | — | — |
| 59     | — | — | [`PMD_TABLE_PXN`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L152) | [`PUD_TABLE_PXN`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L130) | [`PGD_TABLE_PXN`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L108) |
| 60     | — | — | [`PMD_TABLE_UXN`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L153) | [`PUD_TABLE_UXN`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L131) | [`PGD_TABLE_UXN`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L109) |

The key distinction:
- **Table descriptors** (pointing to the next level) have very few attribute bits — just `TYPE_TABLE`, `TABLE_AF`, `TABLE_PXN`, `TABLE_UXN`.
- **Page/block descriptors** (terminal — mapping actual memory) have the full set of permission and memory attribute bits.

### How the kernel constructs entries — pure OR, no masking needed

The physical address is **always page-aligned** (a multiple of 4096 = 2^12), so its bottom 12 bits are naturally zero. The kernel constructs an entry by simply ORing the address with the attribute/type bits — the two occupy **different bit lanes** and never overlap.

#### Constructing a PTE (level 3 page descriptor)

Source — [`arch/arm64/include/asm/pgtable.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable.h#L137-L138):

```c
#define pfn_pte(pfn, prot)  \
    __pte(__phys_to_pte_val((phys_addr_t)(pfn) << PAGE_SHIFT) | pgprot_val(prot))
//                          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^   ^^^^^^^^^^^^^^^^
//                          physical addr (bits[11:0] are zero)   type + attr bits
//                                         just OR them together
```

Worked example:

```
pfn = 0x42000  (page frame number)

pfn << PAGE_SHIFT  = 0x42000 << 12 = 0x0000_0000_4200_0000
                                      ──────────────── ───
                                        PA bits[47:12]  [11:0] = 0x000

prot = PTE_TYPE_PAGE | PTE_AF | PTE_SHARED | ...
     = 0x0000_0000_0000_0743

Result = 0x0000_0000_4200_0000 | 0x0000_0000_0000_0743
       = 0x0000_0000_4200_0743
         ├────────────────────┤ ├──┤
           PA in bits[47:12]    attrs in bits[11:0]
```

#### Constructing a table descriptor (PMD → PTE table)

Source — [`arch/arm64/include/asm/pgalloc.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgalloc.h#L116-L122):

```c
static inline void
pmd_populate(struct mm_struct *mm, pmd_t *pmdp, pgtable_t ptep)
{
    __pmd_populate(pmdp, page_to_phys(ptep),
                   PMD_TYPE_TABLE | PMD_TABLE_AF | PMD_TABLE_PXN);
//                 ^^^^^^^^^^^^^^   ^^^^^^^^^^^^   ^^^^^^^^^^^^^
//                 bits[1:0]=0b11   bit 10         bit 59
}
```

Same pattern at every level — [`pud_populate()`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgalloc.h#L29-L35):

```c
static inline void pud_populate(struct mm_struct *mm, pud_t *pudp, pmd_t *pmdp)
{
    pudval_t pudval = PUD_TYPE_TABLE | PUD_TABLE_AF;
    pudval |= (mm == &init_mm) ? PUD_TABLE_UXN : PUD_TABLE_PXN;
    __pud_populate(pudp, __pa(pmdp), pudval);
//                       ^^^^^^^^^^  ^^^^^^
//                       phys addr   type + attrs, OR'd together
}
```

And [`pgd_populate()`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgalloc.h#L80-L86):

```c
static inline void pgd_populate(struct mm_struct *mm, pgd_t *pgdp, p4d_t *p4dp)
{
    pgdval_t pgdval = PGD_TYPE_TABLE | PGD_TABLE_AF;
    pgdval |= (mm == &init_mm) ? PGD_TABLE_UXN : PGD_TABLE_PXN;
    __pgd_populate(pgdp, __pa(p4dp), pgdval);
}
```

The kernel also distinguishes **kernel vs user** table descriptors: kernel tables get `TABLE_UXN` (bit 60, no user execute), user tables get `TABLE_PXN` (bit 59, no privileged execute).

### How hardware (and kernel) reads back the address — AND mask

The reverse operation extracts just the physical address by ANDing with a mask that selects bits [47:12].

Source — [`arch/arm64/include/asm/pgtable.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable.h#L125-L132):

```c
static inline phys_addr_t __pte_to_phys(pte_t pte)
{
    return pte_val(pte) & PTE_ADDR_LOW;    // mask: keep only bits[47:12]
}
```

Where [`PTE_ADDR_LOW`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L179) is:

```c
#define PTE_ADDR_LOW  (((_AT(pteval_t, 1) << (50 - PAGE_SHIFT)) - 1) << PAGE_SHIFT)
//                   = 0x0000_FFFF_FFFF_F000  (bits [47:12] set, all others clear)
```

All levels reuse this same extraction through casts — [`arch/arm64/include/asm/pgtable.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable.h#L136-L138):

```c
#define pte_pfn(pte)        (__pte_to_phys(pte) >> PAGE_SHIFT)       // L136
#define __pmd_to_phys(pmd)  __pte_to_phys(pmd_pte(pmd))             // L628
#define __pud_to_phys(pud)  __pte_to_phys(pud_pte(pud))             // L652
#define __pgd_to_phys(pgd)  __pte_to_phys(pgd_pte(pgd))             // L734
```

The `_pte()` cast strips the struct wrapper and treats any level's entry as a raw PTE — safe because the address bits are in the same position at every level.

### The actual PTE write — `WRITE_ONCE`

When the kernel installs an entry, it uses an atomic store — [`arch/arm64/include/asm/pgtable.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable.h#L360-L363):

```c
static inline void __set_pte_nosync(pte_t *ptep, pte_t pte)
{
    WRITE_ONCE(*ptep, pte);
}
```

No special encoding or transformation — the fully-constructed 64-bit value (address | attributes) is written directly to the page table page in RAM. The MMU reads these same 64-bit values during its hardware walk.

### The complete picture

```
KERNEL writes an entry:                    HARDWARE reads the entry:

  phys_addr  = 0x0000_0000_4200_0000       raw entry = 0x0000_0000_4200_0743
  prot_bits  = 0x0000_0000_0000_0743
                                            phys_addr = entry & PTE_ADDR_LOW
  entry = phys_addr | prot_bits                       = 0x0000_0000_4200_0743
        = 0x0000_0000_4200_0743                       & 0x0000_FFFF_FFFF_F000
                                                      = 0x0000_0000_4200_0000  ✓
  WRITE_ONCE(*ptep, entry)
                                            type = entry & 0x3
  No conflict because:                           = 0x3 → page/table descriptor  ✓
    phys_addr bits[11:0] = 0x000
    prot_bits bits[47:12] = 0x00000            attrs = bits [11:2]
    They occupy different bit lanes                  = AF, SH, AP, AttrIdx, ...
```

No masking or unmasking — it's a clean OR to write, clean AND to read, because page alignment guarantees the bit lanes never overlap.
