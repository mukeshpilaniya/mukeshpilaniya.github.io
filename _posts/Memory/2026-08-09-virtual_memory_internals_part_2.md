---
published: true
categories: [memory]
tags: [virtual memory,page tables]
---
# Virtual Memory Internals — Part 2

A deep-dive covering PTE flags and page table operations, virtual address space layout, TLB
management, kernel memory allocators, and virtualization address translation — with kernel
source references throughout and an AArch64-first perspective.

---

##   4: PTE Flags & Page Table Operations

### 4a. AArch64 PTE Bit Layout (Hardware-Defined)

Every page table entry on AArch64 is a 64-bit descriptor. The architecture defines two leaf
descriptor types — **Page Descriptors** (at PTE level 3, mapping 4 KiB frames) and **Block
Descriptors** (at PMD level 2 or PUD level 1, mapping 2 MiB or 1 GiB frames). Both share the
same flag layout, differing only in their type bits and the width of the output address field.
The remaining bits encode permissions, cacheability, shareability, and status information that
the MMU checks on every memory access. Some bits are set by the hardware automatically (the
Access Flag on first touch, the Dirty Bit via DBM on first write), while others are purely
software-defined and invisible to the MMU — Linux uses these spare bits to track state like
dirty-via-software, write intent, and special mappings. Understanding this bit layout is
foundational: every page fault handler decision, every COW operation, every TLB flush
ultimately reads or modifies these 64 bits.

Reference: [`arch/arm64/include/asm/pgtable-hwdef.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L164-L176)

```
AArch64 Level 3 Page Descriptor (PTE) — 64-bit layout:

 Bit: 63  62..60  [58:55] 54  53  52  51  50  [49:12]        11  10  [9:8]  7   6  [4:2]  [1:0]
    ┌────┬───────┬───────┬───┬───┬───┬───┬───┬───────────────┬───┬───┬─────┬───┬───┬─────┬──────┐
    │ SW │  PO   │  SW   │UXN│PXN│Con│DBM│ GP│ Output Addr   │ nG│ AF│ SH  │AP │AP │Attr │ Type │
    │bit │  Idx  │  bits │   │   │ t │   │   │ (PA bits)     │   │   │[1:0]│[2]│[1]│Indx │      │
    └────┴───────┴───────┴───┴───┴───┴───┴───┴───────────────┴───┴───┴─────┴───┴───┴─────┴──────┘
      63  62..60  58..55   54  53  52  51  50    49..12         11  10  9:8   7   6  4:2   1..0
```

**Hardware-defined bits:**

| Bit(s) | Name | Kernel Macro | Meaning |
|--------|------|------------|---------|
| 0 | Valid | `PTE_VALID` | If clear, MMU raises a translation fault on any access |
| [1:0]=0b11 | Type | `PTE_TYPE_PAGE` | Page descriptor (4 KiB). Block descriptors use 0b01 |
| [4:2] | AttrIndx | `PTE_ATTRINDX(t)` | Index into `MAIR_EL1` register selecting memory type (Normal, Device, etc.) |
| 6 | AP[1] | `PTE_USER` | If set, EL0 (user mode) can access this page |
| 7 | AP[2] | `PTE_RDONLY` | If set, page is read-only (subject to DBM interaction — see 4c) |
| [9:8] | SH | `PTE_SHARED` | Shareability domain. Inner Shareable (0b11) for SMP coherency |
| 10 | AF | `PTE_AF` | Access Flag. If clear, first access raises an Access Flag fault. Hardware can set this automatically if `TCR_EL1.HA=1` |
| 11 | nG | `PTE_NG` | not-Global. If set, the TLB entry is tagged with an ASID and is specific to one address space |
| [49:12] | OA | — | Output Address — the physical page frame address (up to 50 bits with LPA2) |
| 50 | GP | `PTE_GP` | Guarded Page — enables BTI (Branch Target Identification) enforcement |
| 51 | DBM | `PTE_DBM` | Dirty Bit Management — hardware clears AP[2] on write when `TCR_EL1.HD=1` |
| 52 | Cont | `PTE_CONT` | Contiguous hint — TLB may merge 16 adjacent entries into one large TLB entry |
| 53 | PXN | `PTE_PXN` | Privileged Execute Never — prevents kernel from executing code in this page |
| 54 | UXN | `PTE_UXN` | User Execute Never — prevents user mode from executing code in this page |

```c
/* arch/arm64/include/asm/pgtable-hwdef.h */
#define PTE_VALID       (_AT(pteval_t, 1) << 0)
#define PTE_TYPE_PAGE   (_AT(pteval_t, 3) << 0)
#define PTE_USER        (_AT(pteval_t, 1) << 6)     /* AP[1] */
#define PTE_RDONLY      (_AT(pteval_t, 1) << 7)     /* AP[2] */
#define PTE_SHARED      (_AT(pteval_t, 3) << 8)     /* SH[1:0], inner shareable */
#define PTE_AF          (_AT(pteval_t, 1) << 10)    /* Access Flag */
#define PTE_NG          (_AT(pteval_t, 1) << 11)    /* nG */
#define PTE_GP          (_AT(pteval_t, 1) << 50)    /* BTI guarded */
#define PTE_DBM         (_AT(pteval_t, 1) << 51)    /* Dirty Bit Management */
#define PTE_CONT        (_AT(pteval_t, 1) << 52)    /* Contiguous range */
#define PTE_PXN         (_AT(pteval_t, 1) << 53)    /* Privileged XN */
#define PTE_UXN         (_AT(pteval_t, 1) << 54)    /* User XN */
```

**Software-defined bits (used by Linux, invisible to MMU hardware):**

Reference: [`arch/arm64/include/asm/pgtable-prot.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-prot.h#L16-L31)

| Bit | Kernel Macro | Meaning |
|-----|------------|---------|
| 51 | `PTE_WRITE` | Software writable flag. Aliased to the DBM bit position — Linux reuses this bit to track whether the mapping is logically writable |
| 55 | `PTE_DIRTY` | Software dirty bit. Records that the page has been modified, independent of the hardware dirty mechanism |
| 56 | `PTE_SPECIAL` | Special mapping flag (`VM_PFNMAP`, `VM_IO`, etc.). Tells the kernel this PTE does not have a backing `struct page` |
| 11 | `PTE_PRESENT_INVALID` | Present to software, invalid to hardware. Aliased to the nG bit position, but only meaningful when `PTE_VALID=0`. Used for NUMA hint faults and protnone mappings |
| 58 | `PTE_UFFD_WP` | Userfaultfd write-protect tracking |

```c
/* arch/arm64/include/asm/pgtable-prot.h */
#define PTE_WRITE           (PTE_DBM)                      /* same as DBM (bit 51) */
#define PTE_DIRTY           (_AT(pteval_t, 1) << 55)
#define PTE_SPECIAL         (_AT(pteval_t, 1) << 56)
#define PTE_PRESENT_INVALID (PTE_NG)                       /* only when !PTE_VALID */
```

### 4b. Kernel Page vs User Page — The AP[1] Bit

On AArch64 the User/Supervisor distinction is controlled by a single bit — **AP[1]** (bit 6,
`PTE_USER`). Unlike x86-64 where the U/S bit provides a binary kernel-or-user switch, AArch64
combines AP[1] with execute-never bits to create a richer permission model. The hardware checks
the current Exception Level on every access: code running at EL0 (user) can only access pages
with AP[1]=1, while code at EL1 (kernel) can access all pages — subject to SMAP-equivalent
protections provided by PAN (Privileged Access Never).

```
AP[1] = 0 (PTE_USER not set):
  - Only EL1 (kernel) code can access this page
  - EL0 access causes a Permission fault
  - Used for: kernel text, kernel data, kernel stacks, page tables themselves

AP[1] = 1 (PTE_USER set):
  - Both EL0 (user) and EL1 (kernel) code can access this page
  - Used for: process text, data, heap, stack, shared libraries, mmap regions
```

**Hardware enforcement mechanisms on AArch64:**

- **PAN** (Privileged Access Never, `PSTATE.PAN`): the AArch64 equivalent of x86's SMAP.
  When `PAN=1`, the kernel cannot read or write user-mapped pages (AP[1]=1) — any attempt
  raises a Permission fault. The kernel temporarily clears PAN when it needs to access user
  memory via `copy_from_user()` / `copy_to_user()`. Since ARMv8.1, PAN is mandatory.

- **PXN** (Privileged Execute Never, bit 53): prevents the kernel from executing code in a
  page. All user-space pages have PXN set in the kernel's mapping, blocking the class of
  exploits where an attacker places shellcode in user memory and tricks the kernel into jumping
  to it. This is the AArch64 equivalent of x86's SMEP.

- **UXN** (User Execute Never, bit 54): prevents user-space from executing code in a page.
  Used to enforce W^X — writable data pages always have UXN set.

- **Kernel access to user memory**: the kernel never dereferences user pointers directly. It
  uses `copy_from_user()` / `copy_to_user()` which:
  1. Verify the address is in the user (TTBR0) range
  2. Temporarily disable PAN via `uaccess_enable_not_uao()`
  3. Handle faults gracefully (return `-EFAULT` instead of crashing)
  4. Re-enable PAN via `uaccess_disable_not_uao()`

#### Execute-Only Mappings

AArch64 supports a permission combination that x86-64 cannot express: execute-only memory
(readable by neither user nor kernel, but executable by user). This is achieved by clearing
both `PTE_USER` and `PTE_UXN` while setting `PTE_PXN`:

Reference: [`arch/arm64/include/asm/pgtable-prot.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-prot.h#L65)

```c
#define _PAGE_EXECONLY  (_PAGE_DEFAULT | PTE_RDONLY | PTE_NG | PTE_PXN)
/* Note: no PTE_USER and no PTE_UXN — user can execute but not read */
```

When **EPAN** (Enhanced Privileged Access Never) is available, the hardware enforces that
EL0 cannot read pages without `PTE_USER`, even though they are executable. This gives true
execute-only semantics.

### 4c. The AArch64 Dirty Bit Dance

AArch64 uses a two-part scheme for dirty tracking that interleaves hardware DBM with software
bits. Understanding this is essential for reading the kernel's PTE helpers, because a "dirty"
page can be detected through two different mechanisms, and write-protection must carefully
preserve the dirty state across both.

The hardware **DBM** (Dirty Bit Management, bit 51) works as follows: when `TCR_EL1.HD=1` and
a page has `DBM=1` with `AP[2]=1` (read-only), the hardware will automatically clear `AP[2]`
on the first write — making the page read-write. This acts as an automatic dirty detection
mechanism without requiring a page fault.

Linux overlays this with a software `PTE_DIRTY` bit (bit 55). The combined truth table:

| State | PTE_RDONLY (AP[2]) | PTE_WRITE (bit 51) | PTE_DIRTY (bit 55) |
|-------|--------------------|--------------------|---------------------|
| Clean, read-only | 1 | 0 | 0 |
| Clean, writable | 1 | 1 | 0 |
| Dirty, read-only | 1 | 0 | 1 |
| Dirty, writable | 0 | 1 | (don't care) |

A writable page starts with `AP[2]=1` (read-only to hardware) and `PTE_WRITE=1`. When the
process writes, the hardware clears `AP[2]`, making it truly writable. The kernel detects this:

Reference: [`arch/arm64/include/asm/pgtable.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable.h#L167-L169)

```c
#define pte_hw_dirty(pte)  (pte_write(pte) && !pte_rdonly(pte))  // hardware dirtied
#define pte_sw_dirty(pte)  (!!(pte_val(pte) & PTE_DIRTY))       // software dirtied
#define pte_dirty(pte)     (pte_sw_dirty(pte) || pte_hw_dirty(pte))
```

When the kernel write-protects a page (e.g., for COW), `pte_wrprotect()` must preserve the
dirty state: if the hardware already cleared `AP[2]` (hardware-dirty), it saves this to the
software `PTE_DIRTY` bit before setting `AP[2]` back to read-only:

Reference: [`arch/arm64/include/asm/pgtable.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable.h#L280-L292)

```c
static inline pte_t pte_wrprotect(pte_t pte)
{
    if (pte_hw_dirty(pte))
        pte = set_pte_bit(pte, __pgprot(PTE_DIRTY));  // save hw-dirty to sw bit

    pte = clear_pte_bit(pte, __pgprot(PTE_WRITE));
    pte = set_pte_bit(pte, __pgprot(PTE_RDONLY));
    return pte;
}
```

Similarly, `pte_mkdirty()` sets the software dirty bit and — if the page is writable — clears
`AP[2]` so the hardware can proceed without faulting:

```c
static inline pte_t pte_mkdirty(pte_t pte)
{
    pte = set_pte_bit(pte, __pgprot(PTE_DIRTY));
    if (pte_write(pte))
        pte = clear_pte_bit(pte, __pgprot(PTE_RDONLY));
    return pte;
}
```

And `pte_mkwrite()` sets the write intent and — only if already software-dirty — clears
`AP[2]`:

```c
static inline pte_t pte_mkwrite_novma(pte_t pte)
{
    pte = set_pte_bit(pte, __pgprot(PTE_WRITE));
    if (pte_sw_dirty(pte))
        pte = clear_pte_bit(pte, __pgprot(PTE_RDONLY));
    return pte;
}
```

This interplay ensures that dirty state is never lost across write-protect/restore cycles —
critical for correct COW, dirty page tracking, and writeback.

### 4d. Memory Attributes — MAIR_EL1 and AttrIndx

On AArch64, cacheability and memory ordering properties are not encoded directly in the PTE
flags. Instead, the PTE's `AttrIndx[2:0]` field (bits [4:2]) selects one of eight
attribute slots configured in the `MAIR_EL1` (Memory Attribute Indirection Register). Each
slot defines an 8-bit encoding specifying the memory type — Normal (cacheable), Device
(non-cacheable, ordered), or various intermediate types.

The kernel defines the following memory types as indices into `MAIR_EL1`:

Reference: [`arch/arm64/include/asm/memory.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/memory.h#L171-L176)

```c
#define MT_NORMAL           0   // Normal cacheable (write-back, read/write allocate)
#define MT_NORMAL_TAGGED    1   // Normal with MTE (Memory Tagging Extension) support
#define MT_NORMAL_NC        2   // Normal non-cacheable
#define MT_DEVICE_nGnRnE    3   // Device: non-Gathering, non-Reordering, no Early-write-ack
#define MT_DEVICE_nGnRE     4   // Device: non-Gathering, non-Reordering, Early-write-ack
```

This design gives AArch64 a crucial advantage: you can change the memory type of a mapping by
just changing 3 PTE bits, without needing the complex combination of PAT/PCD/PWT bits that
x86-64 requires. The MAIR approach is also extensible — the hardware provides 8 slots, and the
kernel can redefine them.

Page protection macros combine the memory type with permission bits:

Reference: [`arch/arm64/include/asm/pgtable-prot.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-prot.h#L38-L58)

```c
#define PROT_DEFAULT    (PTE_TYPE_PAGE | PTE_MAYBE_NG | PTE_MAYBE_SHARED | PTE_AF)

#define PROT_NORMAL     (PROT_DEFAULT | PTE_PXN | PTE_UXN | PTE_WRITE | PTE_ATTRINDX(MT_NORMAL))
#define PROT_DEVICE_nGnRnE (PROT_DEFAULT | PTE_PXN | PTE_UXN | PTE_WRITE | PTE_ATTRINDX(MT_DEVICE_nGnRnE))

#define _PAGE_KERNEL    (PROT_NORMAL | PTE_DIRTY)
#define _PAGE_KERNEL_RO ((PROT_NORMAL & ~PTE_WRITE) | PTE_RDONLY | PTE_DIRTY)
#define _PAGE_SHARED    (_PAGE_DEFAULT | PTE_USER | PTE_RDONLY | PTE_NG | PTE_PXN | PTE_UXN | PTE_WRITE)
```

### 4e. Block Descriptors (PMD / PUD Level)

Block descriptors at the PMD and PUD levels have the same flag layout as Page descriptors,
with type bits `[1:0] = 0b01` instead of `0b11`. The kernel defines level-specific macros:

Reference: [`arch/arm64/include/asm/pgtable-hwdef.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L137-L151)

```c
#define PMD_TYPE_TABLE   (_AT(pmdval_t, 3) << 0)    // 0b11 — Table descriptor
#define PMD_TYPE_SECT    (_AT(pmdval_t, 1) << 0)    // 0b01 — Block (section) descriptor
#define PMD_SECT_AF      (_AT(pmdval_t, 1) << 10)
#define PMD_SECT_RDONLY  (_AT(pmdval_t, 1) << 7)
#define PMD_SECT_USER    (_AT(pmdval_t, 1) << 6)
#define PMD_SECT_PXN     (_AT(pmdval_t, 2) << 53)
#define PMD_SECT_UXN     (_AT(pmdval_t, 1) << 54)
#define PMD_SECT_CONT    (_AT(pmdval_t, 1) << 52)
```

All PMD-level operations delegate through conversion to PTE operations. This is an elegant
design choice — the kernel writes the complex dirty/write/access logic once for PTEs and
reuses it at every level:

Reference: [`arch/arm64/include/asm/pgtable.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable.h#L580-L605)

```c
#define pmd_present(pmd)     pte_present(pmd_pte(pmd))
#define pmd_dirty(pmd)       pte_dirty(pmd_pte(pmd))
#define pmd_write(pmd)       pte_write(pmd_pte(pmd))
#define pmd_wrprotect(pmd)   pte_pmd(pte_wrprotect(pmd_pte(pmd)))
#define pmd_mkdirty(pmd)     pte_pmd(pte_mkdirty(pmd_pte(pmd)))
```

### 4f. Page Table Operations — Linux Kernel API (AArch64)

#### Testing PTE Flags

Reference: [`arch/arm64/include/asm/pgtable.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable.h#L140-L171)

```c
pte_none(pte)          // PTE value is 0 — no mapping exists
pte_valid(pte)         // bit 0 (PTE_VALID) — is entry valid to hardware?
pte_present(pte)       // valid OR present-invalid — is page present to software?
pte_write(pte)         // bit 51 (PTE_WRITE/DBM) — is page logically writable?
pte_rdonly(pte)        // bit 7 (AP[2]) — is AP currently read-only?
pte_dirty(pte)         // software dirty OR hardware dirty — has page been written?
pte_young(pte)         // bit 10 (AF) — has page been accessed?
pte_user(pte)          // bit 6 (AP[1]) — is page user-accessible?
pte_user_exec(pte)     // !(UXN) — is user execution allowed?
pte_cont(pte)          // bit 52 (Cont) — part of a contiguous group?
pte_special(pte)       // bit 56 — is this a special mapping (VM_PFNMAP)?
```

The `pte_present()` check is subtler than `pte_valid()`:

```c
#define pte_present(pte)  (pte_valid(pte) || pte_present_invalid(pte))
```

A PTE can be "present to software" but "invalid to hardware" — this is how NUMA hint faults
and `PROT_NONE` mappings work. The PTE retains its PFN and software flags, but the MMU sees it
as not-present and faults.

#### Modifying PTE Flags

Reference: [`arch/arm64/include/asm/pgtable.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable.h#L254-L331)

```c
pte_mkwrite(pte)       // set PTE_WRITE; if sw-dirty, clear PTE_RDONLY
pte_wrprotect(pte)     // clear PTE_WRITE, set PTE_RDONLY; preserve dirty in SW bit
pte_mkdirty(pte)       // set PTE_DIRTY; if writable, clear PTE_RDONLY
pte_mkclean(pte)       // clear PTE_DIRTY, set PTE_RDONLY
pte_mkyoung(pte)       // set AF (Access Flag)
pte_mkold(pte)         // clear AF
pte_mkspecial(pte)     // set PTE_SPECIAL
pte_mkcont(pte)        // set Contiguous bit
pte_mknoncont(pte)     // clear Contiguous bit
pte_mkinvalid(pte)     // set PTE_PRESENT_INVALID, clear PTE_VALID (for NUMA hints)
pte_mkvalid_k(pte)     // restore PTE_VALID, clear PTE_PRESENT_INVALID
```

#### Creating and Installing PTEs

Reference: [`arch/arm64/include/asm/pgtable.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable.h#L137-L138)

```c
pte_t pte = pfn_pte(pfn, prot);          // create PTE from PFN + pgprot_t
pte_t pte = mk_pte(page, prot);          // create PTE from struct page + pgprot_t
set_pte(ptep, pte);                       // write PTE to page table
set_pte_at(mm, addr, ptep, pte);          // write PTE with barriers for SMP
```

On AArch64, `__set_pte()` uses `WRITE_ONCE` followed by `dsb(ishst); isb()` barriers for
valid kernel PTEs — this ensures the store is visible to the hardware page table walker on all
cores before the CPU continues executing.

#### Atomic PTE Operations

These operations are critical for SMP correctness — multiple CPUs may be modifying PTEs
concurrently:

Reference: [`arch/arm64/include/asm/pgtable.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable.h#L1305-L1424)

```c
__ptep_test_and_clear_young(ptep)   // atomically clear AF using cmpxchg_relaxed
__ptep_get_and_clear(ptep)          // atomically read and zero PTE using xchg_relaxed
___ptep_set_wrprotect(ptep)         // atomically write-protect, preserving hw dirty
```

The atomic write-protect is especially delicate — it must use `cmpxchg` in a loop because the
hardware may concurrently clear `AP[2]` via DBM while the kernel is trying to set it.

#### Complete Page Table Helper Function Table

| Operation | PUD | PMD | PTE |
|-----------|-----|-----|-----|
| Get raw value | `pud_val()` | `pmd_val()` | `pte_val()` |
| Cast raw value | `__pud()` | `__pmd()` | `__pte()` |
| Get index | `pud_index()` | `pmd_index()` | `pte_index()` |
| Get next level | `pud_offset()` | `pmd_offset()` | `pte_offset_map()` |
| Get flags | `pud_pgprot()` | `pmd_pgprot()` | `pte_pgprot()` |
| Get PFN | `pud_pfn()` | `pmd_pfn()` | `pte_pfn()` |
| Get struct page | `pud_page()` | `pmd_page()` | `pte_page()` |
| Is empty? | `pud_none()` | `pmd_none()` | `pte_none()` |
| Are same? | `pud_same()` | `pmd_same()` | `pte_same()` |
| Is leaf (huge)? | `pud_leaf()` | `pmd_leaf()` | — |
| Is table? | `pud_table()` | `pmd_table()` | — |
| In bad state? | `pud_bad()` | `pmd_bad()` | — |
| From PFN+flags | `pfn_pud()` | `pfn_pmd()` | `pfn_pte()` |
| From struct page | — | `mk_pmd()` | `mk_pte()` |
| Modify flags | — | `pmd_modify()` | `pte_modify()` |
| Set flags | `pud_set_flags()` | `pmd_set_flags()` | `pte_set_flags()` |
| Clear flags | `pud_clear_flags()` | `pmd_clear_flags()` | `pte_clear_flags()` |
| Set entry | `set_pud()` | `set_pmd()` | `set_pte()` |
| Set entry with check | `set_pud_at()` | `set_pmd_at()` | `set_pte_at()` |
| Clear | `pud_clear()` | `pmd_clear()` | `pte_clear()` |
| Allocate next level | `pud_alloc()` | `pmd_alloc()` | `pte_alloc()` |
| Allocate (internal) | `__pud_alloc()` | `__pmd_alloc()` | `__pte_alloc()` |
| Free | `pud_free()` | `pmd_free()` | `pte_free()` |
| Populate from page | `pud_populate()` | `pmd_populate()` | — |
| Fine-grained lock | `pud_lockptr()` | `pmd_lockptr()` | `pte_lockptr()` |
| Acquire lock | `pud_lock()` | `pmd_lock()` | — |

### 4g. Page Table Walk — Complete Example

Given a `mm_struct` and a virtual address, the full page table walk to find the physical
address. This function handles both normal pages and huge pages (Block Descriptors) at the
PMD and PUD levels:

```c
unsigned long va_to_pa(struct mm_struct *mm, unsigned long addr)
{
    pgd_t *pgd;
    p4d_t *p4d;
    pud_t *pud;
    pmd_t *pmd;
    pte_t *pte;

    /* Level 0: PGD — mm->pgd is loaded into TTBR0_EL1 */
    pgd = pgd_offset(mm, addr);
    if (pgd_none(*pgd) || pgd_bad(*pgd))
        return -1;

    /* P4D — folded on < 5 levels (most AArch64 configs) */
    p4d = p4d_offset(pgd, addr);
    if (p4d_none(*p4d) || p4d_bad(*p4d))
        return -1;

    /* Level 1: PUD */
    pud = pud_offset(p4d, addr);
    if (pud_none(*pud))
        return -1;
    if (pud_leaf(*pud))
        // 1 GiB block descriptor: PA from PUD entry + 30-bit offset
        return (pud_pfn(*pud) << PAGE_SHIFT) | (addr & ~PUD_MASK);

    /* Level 2: PMD */
    pmd = pmd_offset(pud, addr);
    if (pmd_none(*pmd))
        return -1;
    if (pmd_leaf(*pmd))
        // 2 MiB block descriptor: PA from PMD entry + 21-bit offset
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
2. Is it a block/huge page? (`*_leaf()` checks — Block descriptor, type bits = 0b01)
3. If neither, follow the pointer to the next-level table page

---

##   5: Virtual Address Space Layout

### 5a. Kernel/User Address Space Split (AArch64)

On AArch64 the virtual address space is architecturally divided into two halves, each served
by its own Translation Table Base Register. This is fundamentally different from x86-64, where
a single CR3 register points to a unified page table for both kernel and user. On AArch64, the
hardware uses **bit 55** of the virtual address to select which TTBR to consult: if bit 55 is
0, the MMU uses `TTBR0_EL1` (user-space tables); if bit 55 is 1, it uses `TTBR1_EL1` (kernel
tables). All addresses where the upper bits are neither all-zeros nor all-ones fall into a
non-canonical "hole" — any access to these addresses raises a fault immediately, without
consulting any page table. This design means user and kernel page tables are completely separate
structures, making context switches cheaper (only TTBR0 needs to change) and isolation
stronger (the kernel page tables are never exposed to user-space speculation).

```
 AArch64 Virtual Address Space (48-bit VA, 4 KiB pages):

 0xFFFF_FFFF_FFFF_FFFF ┌────────────────────────┐
                        │                        │
                        │   Kernel Space          │  ← TTBR1_EL1 (swapper_pg_dir)
                        │   256 TiB               │     Bit 55 = 1
                        │                        │     Bits [63:48] all 1s
                        │                        │
 0xFFFF_0000_0000_0000 ├────────────────────────┤
                        │                        │
                        │   Non-Canonical Hole    │  ← Access causes Translation Fault
                        │   (~16 million TiB)     │     Bits [63:48] neither all-0 nor all-1
                        │                        │
 0x0000_FFFF_FFFF_FFFF ├────────────────────────┤
                        │                        │
                        │   User Space            │  ← TTBR0_EL1 (per-process)
                        │   256 TiB               │     Bit 55 = 0
                        │                        │     Bits [63:48] all 0s
                        │                        │
 0x0000_0000_0000_0000 └────────────────────────┘
```

The kernel upper half is the **same** mapping in every process's page tables — it always points
to `swapper_pg_dir` via `TTBR1_EL1`, which is never switched. When a context switch occurs,
only `TTBR0_EL1` is updated to point to the new process's page tables. Kernel pages clear the
**nG** (not-Global) bit so their TLB entries survive TTBR0 switches; user pages set nG so
their TLB entries are tagged with an ASID and automatically ignored after a switch to a
different address space.

### 5b. Kernel Virtual Address Space Layout (AArch64, 48-bit VA)

Within the kernel's 256 TiB (for 48-bit VA), different regions serve specific purposes. The
layout is determined by macros in `arch/arm64/include/asm/memory.h`.

Reference: [`arch/arm64/include/asm/memory.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/memory.h#L43-L54), [`Documentation/arch/arm64/memory.rst`](https://github.com/torvalds/linux/blob/v7.2-rc5/Documentation/arch/arm64/memory.rst)

```
 AArch64 Kernel Virtual Address Space (48-bit VA, CONFIG_ARM64_VA_BITS=48):

 0xFFFF_FFFF_FFFF_FFFF ┌────────────────────────────────────────────────┐
                        │ Fixmap                                        │ FIXADDR_TOP = -8M
                        │ Fixed compile-time virtual addresses:          │ Fixed VA for early-boot HW,
                        │ local APIC, VDSO, early console, etc.          │ FDT, earlycon
 ~0xFFFF_FFFF_FF80_0000├────────────────────────────────────────────────┤
                        │ PCI I/O space (16 MiB)                        │ PCI_IO_START = VMEMMAP_END + 8M
                        │ Window for PCI I/O port emulation              │ PCI_IO_END = PCI_IO_START + 16M
 ~0xFFFF_FFFF_C100_0000├────────────────────────────────────────────────┤
                        │ vmemmap (virtual memory map)                   │ VMEMMAP_END = -1G
                        │ Array of struct page — one 64-byte entry       │ VMEMMAP_START = VMEMMAP_END -
                        │ per physical page frame in the system           │   VMEMMAP_SIZE
                        │ Enables pfn_to_page() / page_to_pfn() as       │
                        │ simple array indexing                          │
 ~0xFFFF_FFFF_0000_0000├────────────────────────────────────────────────┤
                        │ vmalloc / ioremap space                        │ VMALLOC_START (arch-defined)
                        │ Non-contiguous virtual mappings:                │ VMALLOC_END (arch-defined)
                        │ vmalloc(), ioremap(), vmap()                   │
                        │ Each mapping gets a vmap_area + guard page     │
                        ├────────────────────────────────────────────────┤
                        │ Kernel image (.text, .data, .rodata, etc.)     │ KIMAGE_VADDR =  S_END
                        │ Located here for KASLR randomization           │
                        ├────────────────────────────────────────────────┤
                        │   mapping space (2 GiB)                   │  S_VADDR = _PAGE_END(VA_BITS_MIN)
                        │ Where loadable kernel  s (.ko) are        │  S_END =  S_VADDR + 2G
                        │ mapped. Within ±2 GiB of kernel text for       │
                        │ direct branch instructions (B/BL range)        │
 ~0xFFFF_8000_0000_0000├────────────────────────────────────────────────┤
                        │ Direct mapping (linear map) of all             │ PAGE_OFFSET = -(1 << VA_BITS)
                        │ physical memory                                │   = 0xFFFF_0000_0000_0000
                        │ Linear 1:1 map:                                │ PAGE_END = _PAGE_END(VA_BITS_MIN)
                        │   VA = PA + PAGE_OFFSET + PHYS_OFFSET adj      │   = 0xFFFF_8000_0000_0000
                        │ Kernel can access any physical address          │
                        │ through this window                            │ Max 128 TiB (quarter of total)
 0xFFFF_0000_0000_0000 └────────────────────────────────────────────────┘
```

Key macros from the kernel source:

```c
/* arch/arm64/include/asm/memory.h */
#define VA_BITS           (CONFIG_ARM64_VA_BITS)          // 48 for typical servers
#define PAGE_OFFSET       (-(UL(1) << VA_BITS))           // start of linear map
#define _PAGE_END(va)     (-(UL(1) << ((va) - 1)))        // end of linear map
#define  S_VADDR     (_PAGE_END(VA_BITS_MIN))        // start of   space
#define  S_VSIZE     (SZ_2G)                         // 2 GiB for  s
#define  S_END       ( S_VADDR +  S_VSIZE)
#define KIMAGE_VADDR      ( S_END)                   // kernel image follows  s
#define VMEMMAP_END       (-UL(SZ_1G))                    // vmemmap ends 1 GiB below top
#define VMEMMAP_START     (VMEMMAP_END - VMEMMAP_SIZE)
#define PCI_IO_START      (VMEMMAP_END + SZ_8M)
#define PCI_IO_END        (PCI_IO_START + PCI_IO_SIZE)    // PCI_IO_SIZE = 16M
#define FIXADDR_TOP       (-UL(SZ_8M))                    // fixmap at very top
```

### 5c. Direct Mapping — The Kernel's Linear Map

The kernel maintains a **direct mapping** (also called "linear mapping" or "linear map") of
all physical RAM into a contiguous virtual range starting at `PAGE_OFFSET`. This region
occupies the bottom quarter of the kernel's virtual address space — up to 128 TiB for 48-bit
VA, constrained by hardware to `MAX_PHYSMEM_BITS` of actual physical address space (46 bits
= 64 TiB for 4-level, limited to 52 bits by hardware for 5-level). This mapping is "hugely
convenient" as the book describes — it makes converting between virtual and physical addresses
trivially simple and avoids the need for temporary page table mappings for the vast majority of
kernel memory tasks.

```
Physical Memory:                    Kernel Virtual (Direct Map):

  PA 0x0_0000_0000 ◄────────────── VA 0xFFFF_0000_0000_0000 + PHYS_OFFSET adj
  PA 0x0_0000_1000 ◄────────────── VA 0xFFFF_0000_0000_1000 + PHYS_OFFSET adj
  ...                               ...
  PA (end of RAM)  ◄────────────── VA (PAGE_OFFSET + RAM_SIZE + PHYS_OFFSET adj)

  Relationship:
    VA  = PA - PHYS_OFFSET + PAGE_OFFSET      (simplified: __phys_to_virt)
    PA  = VA - PAGE_OFFSET + PHYS_OFFSET      (simplified: __lm_to_phys)
```

### 5d. `__pa()` and `__va()` — Direct Mapping Macros (AArch64)

These macros convert between kernel virtual addresses and physical addresses. On AArch64, the
implementation is slightly more complex than x86-64 because the kernel image may not live in
the linear map — KASLR places it at `KIMAGE_VADDR` with a separate offset:

Reference: [`arch/arm64/include/asm/memory.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/memory.h#L340-L392)

```c
#define __lm_to_phys(addr)    (((addr) - PAGE_OFFSET) + PHYS_OFFSET)
#define __kimg_to_phys(addr)  ((addr) - kimage_voffset)

#define __virt_to_phys_nodebug(x) ({                                \
    phys_addr_t __x = (phys_addr_t)(__tag_reset(x));                \
    __is_lm_address(__x) ? __lm_to_phys(__x) : __kimg_to_phys(__x); \
})

#define __phys_to_virt(x)    ((unsigned long)((x) - PHYS_OFFSET) | PAGE_OFFSET)

#define __pa(x)              __virt_to_phys((unsigned long)(x))
#define __va(x)              ((void *)__phys_to_virt((phys_addr_t)(x)))
```

`__pa()` first checks whether the address is in the linear map (`__is_lm_address`). If so, it
uses the `PAGE_OFFSET + PHYS_OFFSET` arithmetic. If not (i.e., it is a kernel image address),
it uses the `kimage_voffset` which is computed at boot time.

**Critical constraint:** `__pa()` and `__va()` **only** work for addresses in the
direct-mapped region or the kernel image. They do **not** work for:
- `vmalloc()` addresses (non-contiguous mapping, different VA region)
- `ioremap()` addresses (MMIO mappings)
- User-space addresses
-   addresses (use `__pa_symbol()` for kernel symbols)

For vmalloc addresses, use `vmalloc_to_pfn()` or `vmalloc_to_page()` to find the physical page.

### 5e. Kernel Reserved Memory Regions (AArch64)

| Region | Purpose | Location |
| --- | --- | --- |
| **Direct mapping** | Linear map of all physical RAM. `kmalloc`, `page_address()`, `__va()` all return addresses here | `PAGE_OFFSET` to `PAGE_END`, up to ~128 TiB |
| **Modules space** | Loadable kernel modules (`.ko`). Within ±2 GiB of kernel text for `B`/`BL` direct branch instructions (26-bit signed offset × 4) | `MODULES_VADDR` to `MODULES_END`, 2 GiB |
| **Kernel image** | `.text`, `.rodata`, `.data`, `.bss` of the kernel itself. Placed above modules space, KASLR-randomized via `kimage_voffset` | `KIMAGE_VADDR` upwards |
| **vmalloc space** | Non-contiguous kernel allocations: `vmalloc()`, `ioremap()`, `vmap()`. Each mapping gets a `vmap_area` entry and a guard page | `VMALLOC_START` to `VMALLOC_END` |
| **vmemmap** | Virtual memory map — array of `struct page`. One 64-byte entry per 4 KiB physical page frame. Enables `pfn_to_page()` / `page_to_pfn()` as simple array indexing | `VMEMMAP_START` to `VMEMMAP_END` (-1 GiB) |
| **PCI I/O space** | Window for legacy PCI I/O port access emulation | `PCI_IO_START`, 16 MiB |
| **Fixmap** | Fixed virtual addresses assigned at compile time. Used for early boot (before full VM is set up), FDT access, early console, VDSO page | Ends at `FIXADDR_TOP` (-8 MiB) |


### 5f. 52-bit VA Support

With ARMv8.2-LVA and 4 KiB pages, AArch64 can extend the virtual address space to 52 bits
(4 PiB). To support this while remaining compatible with 48-bit hardware, the kernel keeps
`PAGE_OFFSET` constant at `0xFFF0_0000_0000_0000` (the 52-bit value) and adjusts offsets at
boot time based on `vabits_actual`:

```c
/* arch/arm64/include/asm/memory.h */
#if VA_BITS > 48
#define vabits_actual  (64 - ((read_tcr() >> 16) & 63))  // read from TCR_EL1.T1SZ
#else
#define vabits_actual  ((u64)VA_BITS)                     // compile-time constant
#endif
```

This means a single kernel binary can run on both 48-bit and 52-bit hardware — on 48-bit
hardware, the effective address space is smaller but the code works identically because
`PAGE_OFFSET` still makes arithmetic correct (unused address ranges are simply never mapped).

---

##   6: TLB (Translation Lookaside Buffer)

### 6a. What Is the TLB?

The TLB is a hardware cache inside the CPU that stores recent virtual-to-physical address
translations. Without it, every single memory access would require a full page table walk — 3
to 5 sequential memory reads just to resolve one virtual address. The TLB makes virtual memory
practical by caching the result of these walks so that repeated accesses to the same page
translate in 1–2 cycles instead of 10–100. AArch64 TLBs are more sophisticated than their
x86-64 counterparts: they natively support **ASIDs** (Address Space Identifiers) to tag
entries per-process, eliminating the need to flush the TLB on most context switches. They also
support **level hints** in invalidation instructions (telling the TLB exactly which page table
level to evict) and **range invalidation** (flushing a contiguous range with a single
instruction). These architectural features directly shape the kernel's TLB management strategy.

```
Memory access with TLB:

                        ┌─────────┐
    Virtual Address ───▶│   TLB   │──── Hit ──▶ Physical Address (1-2 cycles)
                        │ (cache) │
                        └────┬────┘
                             │
                            Miss
                             │
                             ▼
                        ┌─────────┐
                        │  Page   │──────────▶ Physical Address (10-100 cycles)
                        │  Table  │            + result cached in TLB for next time
                        │  Walk   │
                        │(3-5 mem │
                        │ reads)  │
                        └─────────┘
```

- **TLB hit**: ~1-2 CPU cycles — essentially free
- **TLB miss**: ~10-100 cycles (hardware page table walker reads 3-5 levels from memory/cache)
- **Huge pages** (2 MiB, 1 GiB) use separate TLB entries and cover more memory per entry —
  dramatically reduce TLB miss rate. 2 MiB huge pages cover 512× as much memory as a single
  4 KiB TLB entry. 1 GiB pages cover 262,144× as much.

### 6b. ASIDs — AArch64's TLB Tagging

On x86-64, a context switch writes a new value to CR3, which flushes all non-Global TLB
entries. PCIDs (12-bit) were added later to mitigate this, but support is optional and limited.

AArch64 takes a fundamentally different approach. Each TLB entry is tagged with an **ASID**
(Address Space Identifier) stored in `TTBR0_EL1`. When the MMU looks up a translation, it only
matches entries whose ASID matches the current one (or entries marked as Global with nG=0).

```
AArch64 TTBR0_EL1 layout:

 [63:48] = ASID (8 or 16 bits, depending on TCR_EL1.AS)
 [47:1]  = BADDR (physical address of the level-0 page table)
 [0]     = CnP (Common not Private — enables TTBR sharing across CPUs in a cluster)
```

On context switch, the kernel writes a new TTBR0 with the new process's ASID and PGD base
address. The TLB does **not** need to be flushed — the old process's entries remain cached but
are simply ignored because their ASIDs don't match. When the old process is scheduled back, its
TLB entries may still be present, avoiding expensive refill misses.

```
Context switch: Process A (ASID=5) → Process B (ASID=12)

  1. Write TTBR0_EL1 with {ASID=12, BADDR=B's PGD physical address}
  2. ISB (instruction synchronization barrier)
  3. No TLB flush needed!

  TLB state after switch:
  ┌──────────────────────────────────────────────────┐
  │ VA 0x400000 → PA 0x1000  [ASID=5]  ← ignored   │
  │ VA 0x400000 → PA 0x9000  [ASID=12] ← active    │
  │ VA 0x7FFF0000 → PA 0x3000 [ASID=5] ← ignored   │
  │ Kernel VA → PA            [Global]  ← always     │
  └──────────────────────────────────────────────────┘
```

The ASID space is limited (8 or 16 bits → 256 or 65536 unique IDs), so the kernel must manage
ASID allocation. When ASIDs are exhausted, the kernel performs a **generation rollover** —
incrementing a global generation counter and flushing all TLBs, then reassigning ASIDs to
currently-active processes from the new generation.

### 6c. TLB Invalidation on AArch64 — TLBI Instructions

AArch64 provides dedicated `TLBI` (TLB Invalidate) instructions rather than the single
`invlpg` used by x86-64. These instructions are far more granular, specifying the scope
(inner-shareable = all cores in the cluster), the address space (by ASID, by VA, all), and
optionally the page table level:

Reference: [`arch/arm64/include/asm/tlbflush.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/tlbflush.h#L32-L56)

```c
/* Raw TLBI instruction wrapper */
#define __tlbi(op, ...)  asm ("tlbi " #op ", %x0" : : "rZ" (arg))

/* TLBI address encoding: VA >> 12 in bits [43:0], ASID in bits [63:48] */
#define __TLBI_VADDR(addr, asid) ({                      \
    unsigned long __ta = (addr) >> 12;                    \
    __ta &= GENMASK_ULL(43, 0);                          \
    __ta |= (unsigned long)(asid) << 48;                  \
    __ta;                                                 \
})
```

**Key TLBI instruction variants:**

| TLBI Instruction | Meaning |
|------------------|---------|
| `TLBI VMALLE1IS` | Invalidate all EL1 entries, Inner Shareable (all cores) |
| `TLBI ASIDE1IS, Xt` | Invalidate all entries for a given ASID, Inner Shareable |
| `TLBI VAE1IS, Xt` | Invalidate by VA + ASID, Inner Shareable |
| `TLBI VALE1IS, Xt` | Invalidate by VA + ASID, last-level only (leaf), Inner Shareable |
| `TLBI VAAE1IS, Xt` | Invalidate by VA, all ASIDs, Inner Shareable |
| `TLBI IPAS2E1IS, Xt` | Invalidate Stage-2 (IPA) entry, Inner Shareable |
| `TLBI RVAE1IS, Xt` | Range invalidation by VA + ASID (ARMv8.4-TLBI) |

The `IS` suffix means "Inner Shareable" — the invalidation is broadcast to all CPUs in the
shareability domain. This is AArch64's equivalent of x86's IPI-based TLB shootdown, but
implemented in hardware — the CPU issues the `TLBI` instruction and the interconnect handles
propagation, followed by a `DSB ISH` barrier to wait for completion.

### 6d. Kernel TLB Flush API

Reference: [`arch/arm64/include/asm/tlbflush.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/tlbflush.h#L283-L683)

Every invalidation operation follows this template:

```
DSB ISHST      // Ensure prior page-table stores have completed
TLBI ...       // Invalidate the TLB entry/entries
DSB ISH        // Ensure the TLB invalidation has completed on all cores
if (invalidated kernel mappings)
    ISB        // Discard any instructions fetched from the old mapping
```

**Core API functions:**

```c
flush_tlb_all()
    // Invalidate entire TLB (kernel + user) on all CPUs
    // Issues: TLBI VMALLE1IS
    dsb(ishst);
    __tlbi(vmalle1is);
    dsb(ish);
    isb();

flush_tlb_mm(mm)
    // Invalidate all entries for an address space (by ASID)
    // Issues: TLBI ASIDE1IS, <ASID>
    dsb(ishst);
    __tlbi(aside1is, __TLBI_VADDR(0, ASID(mm)));
    dsb(ish);

flush_tlb_page(vma, addr)
    // Invalidate a single user page (last-level only, no walk-cache eviction)
    // Issues: TLBI VALE1IS, <addr | ASID>
    // Efficient: does not flush intermediate page table walk-cache entries

flush_tlb_range(vma, start, end)
    // Invalidate a virtual address range for a given mm
    // May issue multiple TLBI instructions, or fall back to flush_tlb_mm
    // if the range is too large (> MAX_DVM_OPS pages)

flush_tlb_kernel_range(start, end)
    // Same as flush_tlb_range but for kernel mappings (ASID=0)
    // Issues: TLBI VAALE1IS (all-ASID variant)
    // Used when unmapping pages from vmalloc/ioremap space
```

### 6e. Range TLBI (ARMv8.4-TLBI)

Modern AArch64 CPUs support **range invalidation** — a single `TLBI` instruction can
invalidate a contiguous range of pages, avoiding the per-page invalidation loop:

Reference: [`arch/arm64/include/asm/tlbflush.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/tlbflush.h#L197-L225)

```
Range TLBI operand encoding:

+----------+------+-------+-------+-------+----------------------+
|   ASID   |  TG  | SCALE |  NUM  |  TTL  |        BADDR         |
+----------+------+-------+-------+-------+----------------------+
|63      48|47  46|45   44|43   39|38   37|36                   0|

Range = [BADDR, BADDR + (NUM + 1) × 2^(5×SCALE + 1) × PAGESIZE)
```

The kernel uses range TLBI when available, falling back to per-page invalidation:

```c
static __always_inline void __flush_tlb_range_op(...)
{
    while (addr != end) {
        pages = (end - addr) >> PAGE_SHIFT;

        if (!system_supports_tlb_range() || pages == 1)
            goto invalidate_one;    // single TLBI VALE1IS

        num = __TLBI_RANGE_NUM(pages, scale);
        if (num >= 0) {
            __tlbi_range(rop, addr, asid, scale, num, level, lpa2);
            addr += __TLBI_RANGE_PAGES(num, scale) << PAGE_SHIFT;
        }
        scale--;
        continue;
    invalidate_one:
        __tlbi_level_asid(lop, addr, level, asid);
        addr += stride;
    }
}
```

### 6f. TLB Shootdown — AArch64 vs x86-64

AArch64 does **not** use IPIs (Inter-Processor Interrupts) for TLB shootdowns. Instead, the
`TLBI` instruction with the `IS` (Inner Shareable) suffix causes the hardware interconnect to
broadcast the invalidation to all CPUs in the shareability domain. This is significantly more
efficient than x86's software IPI approach:

```
x86-64 TLB Shootdown:                     AArch64 TLB Invalidation:

CPU 0: modify PTE                          CPU 0: modify PTE
CPU 0: invlpg (local flush)               CPU 0: DSB ISHST  (ensure PTE write visible)
CPU 0: send IPI to CPUs 1,2,3             CPU 0: TLBI VAE1IS (broadcast via interconnect)
CPU 1: receive IPI                         CPU 0: DSB ISH    (wait for completion)
CPU 1: invlpg (flush)                      (hardware handles all cores atomically)
CPU 1: acknowledge
CPU 2: receive IPI → flush → ack
CPU 3: receive IPI → flush → ack
CPU 0: wait for all acks
CPU 0: continue
```

The hardware broadcast eliminates IPI send/receive latency, pipeline flushes on receiving
CPUs, and the synchronous wait-for-acknowledgment protocol. This is one of the reasons
AArch64 performs well on many-core systems.

### 6g. Level Hints (ARMv8.4-TTL)

AArch64's `TLBI` instructions optionally accept a **TTL** (Translation Table Level) hint that
tells the TLB which page table level the invalidated entry corresponds to. If the level is
correct, the hardware can invalidate more efficiently by only checking entries at that level.
If the level is wrong or unknown, the instruction still works — it just may be less efficient.

Reference: [`arch/arm64/include/asm/tlbflush.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/tlbflush.h#L116-L130)

```c
static __always_inline void __tlbi_level_asid(tlbi_op op, u64 addr,
                                              u32 level, u16 asid)
{
    u64 arg = __TLBI_VADDR(addr, asid);

    if (alternative_has_cap_unlikely(ARM64_HAS_ARMv8_4_TTL) && level <= 3) {
        u64 ttl = level | (get_trans_granule() << 2);
        FIELD_MODIFY(TLBI_TTL_MASK, &arg, ttl);
    }

    op(arg);
}
```

### 6h. Optimizing TLB Flush Decisions

The kernel avoids unnecessary flushes with a helper that checks whether a PTE change actually
requires a TLB invalidation:

Reference: [`arch/arm64/include/asm/tlbflush.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/tlbflush.h#L695-L707)

```c
static inline bool __pte_flags_need_flush(ptval_t oldval, ptval_t newval)
{
    ptval_t diff = oldval ^ newval;

    /* invalid to valid transition requires no flush */
    if (!(oldval & PTE_VALID))
        return false;

    /* Transition in the SW bits requires no flush */
    diff &= ~PTE_SWBITS_MASK;

    return diff;
}
```

If the old PTE was not valid (not in TLB), or the only changes are in software-defined bits
(invisible to TLB), no flush is needed.

### 6i. Batched TLB Flush

For operations that unmap many pages (like `munmap()`), the kernel batches TLBI instructions
and issues a single DSB barrier at the end, rather than paying the DSB cost per page:

```c
static inline void arch_tlbbatch_add_pending(...)
{
    /* Issue TLBI without trailing DSB (TLBF_NOSYNC) */
    __flush_tlb_range(&vma, start, end, PAGE_SIZE, 3,
                      TLBF_NOWALKCACHE | TLBF_NOSYNC);
}

static inline void arch_tlbbatch_flush(...)
{
    /* Single DSB ISH to synchronize all pending TLBIs */
    dsb(ish);
}
```

---

##   7: vmalloc, kmalloc, kvmalloc & Memory Allocation

### 7a. vmalloc — Non-Contiguous Virtual Allocation

Allocating memory in the kernel is typically performed using the slab allocator via `kmalloc()`,
which acts solely as a physical memory allocator and uses the direct mapping to return a virtual
address. Since contiguous physical memory is in short supply, trying to allocate larger blocks
of memory using the slab allocator may not be useful or wise. The kernel provides vmalloc as
a mechanism for the allocation of **virtually contiguous** but **physically non-contiguous**
memory. `vmalloc()` allocates individual 4 KiB pages from anywhere in physical RAM, then maps
them into the vmalloc address range (`VMALLOC_START` to `VMALLOC_END`) by creating page table
entries in the kernel page tables. The caller gets a contiguous virtual pointer, but the
underlying physical pages may be scattered anywhere. This is the right tool for large
allocations (tens of KiB and above) where physical contiguity is not required — and it is the
mechanism used for loading kernel  s, mapping device I/O regions (`ioremap`), and
allocating large kernel buffers.

```c
void *buf = vmalloc(1048576);  // 1 MiB — 256 individual 4 KiB pages
// buf points to a contiguous 1 MiB virtual range in vmalloc space
// but the 256 underlying physical pages may be scattered anywhere in RAM
```

#### Internal Implementation

Reference: [`mm/vmalloc.c`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/vmalloc.c#L4003)

```
vmalloc(size)
  └─▶ __vmalloc_node_range_noprof(size, align, VMALLOC_START, VMALLOC_END, ...)

      Step 1: Find free virtual address range
      ┌──────────────────────────────────────────────────────────┐
      │ The vmalloc space is managed by a red-black tree of     │
      │ struct vmap_area nodes.                                 │
      │                                                         │
      │   vmap_area_root (RB tree, keyed by va_start)           │
      │          ┌───────────┐                                  │
      │         ╱             ╲                                 │
      │   ┌─────────┐   ┌─────────┐                            │
      │   │va: 100- │   │va: 500- │                            │
      │   │    200  │   │    600  │                            │
      │   └─────────┘   └─────────┘                            │
      │                                                         │
      │ A separate "free" RB tree (free_vmap_area_root) uses    │
      │ augmented rbtree with subtree_max_size for O(log n)     │
      │ allocation of gaps between existing vmap_areas.         │
      │                                                         │
      │ __get_vm_area_node() finds a gap >= requested size,     │
      │ creates new vmap_area + vm_struct.                      │
      │ A guard page (PAGE_SIZE) is added after each            │
      │ allocation to detect buffer overruns.                   │
      └──────────────────────────────────────────────────────────┘

      Step 2: Allocate physical pages
      ┌──────────────────────────────────────────────────────────┐
      │ __vmalloc_area_node():                                  │
      │ For each page in the range:                             │
      │   page = alloc_page(gfp_flags)                         │
      │   // allocates a single order-0 (4 KiB) page           │
      │   // each page independently — no contiguity needed     │
      │   // stores pointers in vm_struct->pages[] array        │
      │                                                         │
      │ If arch supports huge vmap (VM_ALLOW_HUGE_VMAP):        │
      │   try PMD-sized (2 MiB) allocations first for speed     │
      └──────────────────────────────────────────────────────────┘

      Step 3: Map pages into the virtual range
      ┌──────────────────────────────────────────────────────────┐
      │ vmap_pages_range(va_start, va_end, prot, pages)         │
      │                                                         │
      │ For each page in the range:                             │
      │   Walk the kernel page table (init_mm / swapper_pg_dir) │
      │   Allocate intermediate table pages if needed           │
      │   (PUD, PMD pages via pud_alloc, pmd_alloc)             │
      │   Set PTE: virtual address → physical page frame        │
      │                                                         │
      │ After mapping, flush TLB for the new range              │
      └──────────────────────────────────────────────────────────┘

      Step 4: Return virtual address (va_start)
```

**Key data structures:**

Reference: [`include/linux/vmalloc.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/vmalloc.h#L52-L89)

![Overview of vmalloc alloctors](/assets/vmalloc_alloctors.png)

```c
struct vm_struct {
    void            *addr;          // virtual address (same as vmap_area.va_start)
    unsigned long    size;          // size including guard page
    unsigned long    flags;         // VM_ALLOC, VM_IOREMAP, VM_MAP, etc.
    struct page    **pages;         // array of pointers to physical pages
    unsigned int     page_order;    // order if huge vmap pages were used
    unsigned int     nr_pages;      // number of pages
    phys_addr_t      phys_addr;     // for ioremap: the physical base address
    const void      *caller;        // __builtin_return_address for debugging
    unsigned long    requested_size; // original size before rounding
};

struct vmap_area {
    unsigned long va_start;         // start of this vmalloc region
    unsigned long va_end;           // end (exclusive)
    struct rb_node rb_node;         // red-black tree node (keyed by va_start)
    struct list_head list;          // address-sorted linked list
    union {
        unsigned long subtree_max_size; // in "free" tree — augmented max of subtree
        struct vm_struct *vm;           // in "busy" tree — pointer to higher-level descriptor
    };
    unsigned long flags;            // type of vm_map_ram area
};
```

**Variants:**

| Function | Behavior |
|---|---|
| `vmalloc(size)` | Allocate virtually contiguous pages, may sleep |
| `vzalloc(size)` | `vmalloc` + zero-fill |
| `vmalloc_user(size)` | `vmalloc` with pages suitable for mapping into user-space |
| `vmalloc_node(size, node)` | `vmalloc` on a specific NUMA node |
| `vfree(addr)` | Free: unmap PTEs, flush TLB, free each physical page, free vmap_area |

### 7b. kmalloc — Physically Contiguous Allocation

`kmalloc()` returns memory that is both **virtually and physically contiguous**, allocated from
the **direct-mapped** kernel region. Because it uses the direct map, no page table setup is
needed — the mapping already exists. This makes `kmalloc` the fastest kernel allocator, ideal
for small, hot-path allocations. The tradeoff is that large allocations require finding
physically contiguous pages, which becomes difficult as the system runs and memory fragments.

```c
void *buf = kmalloc(256, GFP_KERNEL);   // 256 bytes from slab allocator
void *buf = kmalloc(65536, GFP_KERNEL); // 64 KiB — may use page allocator directly
```

**Implementation layers:**

```
kmalloc(size, flags)
  ├── size <= KMALLOC_MAX_CACHE_SIZE (typically 8 KiB or 192 KiB)
  │     └─▶ SLUB slab allocator
  │           - Pre-allocated pools of fixed-size objects (32, 64, 128, 256, ... bytes)
  │           - Very fast: grab the next free object from the per-CPU freelist
  │           - Minimal internal fragmentation (rounded up to nearest slab size)
  │
  └── size > KMALLOC_MAX_CACHE_SIZE
        └─▶ Page allocator (buddy system)
              - alloc_pages(order) — allocates 2^order contiguous pages
              - Must find a physically contiguous block of the right size
              - May fail under memory fragmentation
```

**Why it's fast:** No page table manipulation needed. The direct map already maps all physical
RAM — `kmalloc` just carves out a piece from the slab (or buddy allocator) and returns the
direct-map virtual address for that physical memory.

**Limitation:** Large allocations require physically contiguous pages, which become scarce as
the system runs. A 4 MiB `kmalloc` needs 1024 contiguous physical pages — this frequently
fails on long-running systems.

**Free:** `kfree(ptr)`

### 7c. kvmalloc — Adaptive Allocation

`kvmalloc()` provides the best of both worlds — it tries `kmalloc` first for speed, then
falls back to `vmalloc` if contiguous physical pages are unavailable:

Reference: [`mm/slub.c`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/slub.c#L6890-L6936)

```c
void *__kvmalloc_node_noprof(..., unsigned long align, gfp_t flags, int node)
{
    /* Try kmalloc first — fast, physically contiguous */
    ret = __do_kmalloc_node(..., kmalloc_gfp_adjust(flags, size), node, ...);
    if (ret || size <= PAGE_SIZE)
        return ret;

    /* kmalloc failed and size > PAGE_SIZE — fall back to vmalloc */
    return __vmalloc_node_range_noprof(size, align, VMALLOC_START, VMALLOC_END,
            flags, PAGE_KERNEL,
            allow_block ? VM_ALLOW_HUGE_VMAP : 0,
            node, __builtin_return_address(0));
}
```

**Free:** `kvfree(ptr)` — internally detects whether the pointer is in vmalloc space or the
direct map, and calls the appropriate free function:

```c
void kvfree(const void *addr)
{
    if (is_vmalloc_addr(addr))
        vfree(addr);
    else
        kfree(addr);
}
```

### 7d. Comparison Table

```
┌──────────────────┬──────────────────┬──────────────────┬──────────────────┐
│                  │    kmalloc       │    vmalloc       │    kvmalloc      │
├──────────────────┼──────────────────┼──────────────────┼──────────────────┤
│ Phys contiguous  │ Yes              │ No               │ Maybe            │
│ Virt contiguous  │ Yes              │ Yes              │ Yes              │
│ VA region        │ Direct map       │ vmalloc space    │ Either           │
│ Max practical    │ ~4 MiB (limited  │ Limited by       │ Same as vmalloc  │
│ size             │ by contiguity)   │ vmalloc space    │                  │
│ Speed            │ Fast (no PTE     │ Slower (PTE      │ Fast if kmalloc  │
│                  │ setup)           │ setup + TLB      │ succeeds         │
│                  │                  │ flush)           │                  │
│ Sleepable?       │ Depends on flags │ Always (must     │ Always           │
│                  │ (GFP_ATOMIC: no) │ sleep)           │                  │
│ DMA-capable      │ Yes (with        │ No (pages not    │ Only if kmalloc  │
│                  │ GFP_DMA)         │ contiguous)      │ path taken       │
│ Usable in IRQ    │ Yes (GFP_ATOMIC) │ No               │ No               │
│ __pa() works?    │ Yes              │ No               │ Only if kmalloc  │
│ Free with        │ kfree()          │ vfree()          │ kvfree()         │
│ Typical use      │ Small objects,   │ Large buffers,   │ Variable-size    │
│                  │ DMA buffers,     │   loading,  │ buffers where    │
│                  │ hot paths        │ ioremap          │ size varies      │
└──────────────────┴──────────────────┴──────────────────┴──────────────────┘
```

### 7e. GFP Flags (Get Free Pages — Memory Allocation Flags)

GFP flags control **how** the page allocator behaves — where it allocates from, whether it can
sleep, and how hard it tries:

**Commonly used composite flags:**

| Flag | Can Sleep? | Meaning |
|---|---|---|
| `GFP_KERNEL` | Yes | Normal kernel allocation. Can sleep, reclaim memory, invoke OOM killer |
| `GFP_ATOMIC` | No | Allocation in interrupt/atomic context. Cannot sleep. Uses emergency reserves |
| `GFP_USER` | Yes | For user-space allocations (mapped into process address space) |
| `GFP_DMA` | Depends | Allocate from DMA zone (for devices with address limits) |
| `GFP_DMA32` | Depends | Allocate from DMA32 zone (first 4 GiB, for 32-bit DMA devices) |

**Modifier flags (combined with above):**

| Flag | Meaning |
|---|---|
| `__GFP_ZERO` | Zero-fill the allocated pages. `kzalloc(size, flags)` = `kmalloc(size, flags \| __GFP_ZERO)` |
| `__GFP_NOWARN` | Suppress allocation failure warnings in kernel log |
| `__GFP_NORETRY` | Don't try very hard — return NULL quickly rather than reclaiming aggressively |
| `__GFP_NOFAIL` | Must succeed — loop forever until allocation succeeds. Use with extreme caution |
| `__GFP_COMP` | Allocate a compound page (for huge pages and certain subsystems) |

---

##   8: Virtualization Addresses — VPA, IPA, PA

### 8a. Address Types in Virtualized Systems

In a system running a hypervisor, there are **three** levels of address translation. This is
a natural extension of virtual memory: just as the OS gives each process the illusion of owning
all memory through Stage-1 page tables, the hypervisor gives each guest OS the illusion of
owning all physical memory through Stage-2 page tables. The guest OS builds its page tables
exactly as it would on bare metal — it does not know (or need to know) that it is running in a
VM. What the guest calls "physical addresses" are actually **Intermediate Physical Addresses**
(IPAs), which the hypervisor's Stage-2 page tables then translate to actual hardware physical
addresses. This two-stage translation is the foundation of hardware-assisted virtualization: it
provides guest isolation (Guest A cannot access Guest B's memory), memory overcommit (the
hypervisor can promise more IPA space than physical RAM exists), and device emulation (the
hypervisor can trap accesses to emulated device MMIO ranges).

```
┌──────────────────────┐       ┌──────────────────────┐       ┌──────────────────────┐
│                      │       │                      │       │                      │
│  VA                  │       │  IPA                 │       │  PA                  │
│  (Virtual Address)   │       │  (Intermediate       │       │  (Physical           │
│                      │       │   Physical Address)  │       │   Address)           │
│  What the guest      │       │  What the guest OS   │       │  What actually       │
│  process sees        │       │  thinks is physical  │       │  appears on the      │
│                      │       │  memory              │       │  memory bus          │
│                      │       │                      │       │                      │
│  Translated by:      │       │  Translated by:      │       │                      │
│  Guest page tables   │──────▶│  Hypervisor page     │──────▶│  Final hardware      │
│  (Stage-1)           │       │  tables (Stage-2)    │       │  address             │
│  TTBR0/1_EL1         │       │  VTTBR_EL2           │       │                      │
│                      │       │                      │       │                      │
└──────────────────────┘       └──────────────────────┘       └──────────────────────┘
     Guest OS manages               Hypervisor (EL2)                  Hardware
     these page tables               manages these
```

### 8b. Without Virtualization (Bare Metal)

```
VA ──[Stage-1 page table]──▶ PA
     TTBR0/1_EL1
```

Only one stage of translation. The OS page tables map virtual addresses directly to physical
addresses. What the OS calls "physical" really is the hardware physical address.

### 8c. With Virtualization (Two-Stage Translation on AArch64)

```
VA ──[Stage-1: Guest page table]──▶ IPA ──[Stage-2: Hypervisor page table]──▶ PA
     TTBR0/1_EL1                          VTTBR_EL2
```

**Stage-1 (Guest page tables, controlled by EL1):**
- Managed by the guest OS — it uses `TTBR0_EL1` / `TTBR1_EL1` exactly as on bare metal
- Maps VA → IPA (what the guest thinks is "physical address" is actually IPA)
- The guest builds its page tables, handles its own page faults, manages its own TLB — all
  unaware that an additional translation layer exists

**Stage-2 (Hypervisor page tables, controlled by EL2):**
- Managed by the hypervisor (KVM running at EL2 on the host)
- Maps IPA → PA via page tables pointed to by `VTTBR_EL2` (Virtualization Translation Table
  Base Register)
- The hypervisor controls `VTCR_EL2` (Virtualization Translation Control Register) which
  configures the IPA size, number of levels, and translation granule for Stage-2
- Allows the hypervisor to:
  - **Isolate guests**: Guest A and Guest B have independent IPA spaces mapped to different PAs
  - **Overcommit memory**: IPA pages need no backing PA until accessed (demand paging at EL2)
  - **Emulate devices**: Map guest device MMIO regions to trap into the hypervisor
  - **Track dirty pages**: Use Stage-2 permissions for live migration dirty tracking

### 8d. AArch64 Hardware Support

On AArch64, Stage-2 translation is a first-class architectural feature, not a bolt-on
extension:

| Component | Register / Mechanism |
|-----------|---------------------|
| Stage-2 page table base | `VTTBR_EL2` — holds IPA-space ASID (VMID) and PGD physical address |
| Stage-2 translation control | `VTCR_EL2` — configures IPA bits, page size, start level, shareability |
| Stage-2 enable/disable | `HCR_EL2.VM` bit — enables/disables Stage-2 translation |
| Stage-2 TLB invalidation | `TLBI IPAS2E1IS` — invalidates by IPA, Inner Shareable |
| Virtual Machine ID | VMID in `VTTBR_EL2[63:48]` — tags TLB entries per-VM (like ASID for VMs) |

The VMID is analogous to the ASID but for Stage-2: TLB entries from different VMs are tagged
with different VMIDs, so switching between VMs does not require a TLB flush.

### 8e. Stage-2 Page Table Structure (KVM on AArch64)

KVM uses a dedicated page table structure for Stage-2, defined independently from the
kernel's Stage-1 page tables:

Reference: [`arch/arm64/include/asm/kvm_pgtable.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/kvm_pgtable.h#L51-L101)

```c
typedef u64 kvm_pte_t;

#define KVM_PTE_VALID                   BIT(0)
#define KVM_PTE_TYPE                    BIT(1)
#define KVM_PTE_TYPE_BLOCK              0       // Block descriptor (huge page)
#define KVM_PTE_TYPE_PAGE               1       // Page descriptor
#define KVM_PTE_TYPE_TABLE              1       // Table descriptor (non-leaf)

/* Stage-2 specific attribute bits */
#define KVM_PTE_LEAF_ATTR_LO_S2_MEMATTR GENMASK(5, 2)   // Memory type
#define KVM_PTE_LEAF_ATTR_LO_S2_S2AP_R  BIT(6)          // Stage-2 Read permission
#define KVM_PTE_LEAF_ATTR_LO_S2_S2AP_W  BIT(7)          // Stage-2 Write permission
#define KVM_PTE_LEAF_ATTR_LO_S2_AF      BIT(10)         // Access Flag
#define KVM_PTE_LEAF_ATTR_HI_S2_XN      GENMASK(54, 53) // Execute Never
```

Stage-2 permissions use **S2AP** (Stage-2 Access Permissions) instead of AP:
- `S2AP[0]` (bit 6) = Read permission
- `S2AP[1]` (bit 7) = Write permission

This is simpler than Stage-1's AP scheme — each permission is an independent bit.

The KVM page table structure:

```c
struct kvm_pgtable {
    u32                         ia_bits;      // IPA size in bits
    s8                          start_level;  // first page table level (-1 to 3)
    kvm_pteref_t                pgd;          // pointer to top-level table
    struct kvm_pgtable_mm_ops   *mm_ops;      // memory management callbacks
    enum kvm_pgtable_stage2_flags flags;
    kvm_pgtable_force_pte_cb_t  force_pte_cb; // callback to force page-level mappings
    struct kvm_s2_mmu           *mmu;         // parent MMU structure
};
```

#### Stage-2 Table Concatenation

AArch64 supports **concatenation of up to 16 tables** at the Stage-2 entry level. This
effectively resolves 4 additional IPA bits at the top level without adding another page table
level, reducing the total number of levels needed:

Reference: [`arch/arm64/include/asm/stage2_pgtable.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/stage2_pgtable.h#L23)

```c
#define stage2_pgtable_levels(ipa)  ARM64_HW_PGTABLE_LEVELS((ipa) - 4)
```

For example, with 4 KiB pages and 40-bit IPA: `ARM64_HW_PGTABLE_LEVELS(40 - 4) = 3` levels
instead of the 4 levels that a 40-bit walk would normally require.

### 8f. Two-Stage Walk Example (AArch64)

```
Guest process at EL0 accesses virtual address 0x0040_0000:

Stage-1 walk (guest page tables, TTBR0_EL1):
  ┌──────────────────────────────────────────────────────┐
  │ PGD → PUD → PMD → PTE                               │
  │ Each table's base address is an IPA                  │
  │ → must be translated via Stage-2 before memory read! │
  │                                                       │
  │ Result: IPA = 0x8000_1000                             │
  └──────────────────────────────────────────────────────┘

Stage-2 walk (hypervisor page tables, VTTBR_EL2):
  ┌──────────────────────────────────────────────────────┐
  │ IPA 0x8000_1000 → Stage-2 PGD → PUD → PMD → PTE    │
  │ These tables use real physical addresses              │
  │                                                       │
  │ Result: PA = 0x2_4000_1000                            │
  └──────────────────────────────────────────────────────┘

Total: VA 0x0040_0000 → IPA 0x8000_1000 → PA 0x2_4000_1000
```

**Performance note:** A two-stage walk is expensive. Each of the 4 Stage-1 table reads
generates an IPA that itself needs a Stage-2 walk (up to 4 memory reads). Plus the final
data page IPA needs one more Stage-2 walk. Worst case for 4-level/4-level:

```
4 Stage-1 levels × 4 Stage-2 reads per level = 16 reads
+ 1 final Stage-2 walk for the data page (4 reads) = 4
Total = 20 sequential memory reads for one address translation
```

This is why TLBs and hardware-cached intermediate translations are critical for virtualization
performance. The TLB caches the final VA→PA result, so subsequent accesses to the same page
avoid the entire 20-read walk. Additionally, the hardware caches Stage-2 intermediate results
so that even on TLB miss, the full 20-read worst case rarely occurs.

### 8g. Stage-2 Faults and Guest Abort Handling

When the Stage-2 walk finds a "not present" entry or a permission violation, the hardware
generates a trap to EL2. On AArch64 this is handled by the hypervisor's abort handler:

Reference: [`arch/arm64/kvm/mmu.c`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kvm/mmu.c#L2247-L2300)

```
Guest accesses unmapped IPA
  │
  ▼
Hardware: Stage-2 translation fault → trap to EL2
  │
  ▼
kvm_handle_guest_abort(vcpu) (arch/arm64/kvm/mmu.c:2247)
  │
  │  1. Read ESR_EL2 for fault status (FSC)
  │  2. Read HPFAR_EL2 for faulting IPA
  │  3. Check FSC type:
  │       esr_fsc_is_translation_fault()  → needs mapping
  │       esr_fsc_is_permission_fault()   → COW or dirty tracking
  │       esr_fsc_is_access_flag_fault()  → needs AF set
  │
  │  4. Look up IPA in KVM memory slot table
  │
  ├── IPA maps to a registered memory slot:
  │     └── user_mem_abort()
  │           1. Translate IPA → HVA (host virtual address)
  │           2. get_user_pages() to pin the host physical page
  │           3. kvm_pgtable_stage2_map() to install Stage-2 PTE
  │           4. Return to guest — hardware retries the access
  │
  ├── IPA maps to an MMIO region (no memory slot):
  │     └── Emulate the device access in QEMU/userspace
  │           io_mem_abort() → return to userspace for emulation
  │
  └── IPA is beyond valid range:
        └── Inject fault back into guest (Data Abort to EL1)
```

The hypervisor uses the same demand-paging strategy as the kernel's Stage-1 fault handler:
Stage-2 mappings are created lazily on first access, and the guest is never aware that a trap
occurred.

### 8h. Stage-2 Memory Attributes

Stage-2 uses its own memory attribute encoding, separate from Stage-1's `MAIR_EL1`:

Reference: [`arch/arm64/include/asm/memory.h`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/memory.h#L182-L196)

```c
/* Without FWB (Forwarded Write-Back) */
#define MT_S2_NORMAL       0xf    // Normal cacheable
#define MT_S2_NORMAL_NC    0x5    // Normal non-cacheable
#define MT_S2_DEVICE_nGnRE 0x1    // Device memory

/* With FWB (ARMv8.4) — Stage-2 can override Stage-1 attributes */
#define MT_S2_FWB_NORMAL       6  // Force Normal Write-Back
#define MT_S2_FWB_NORMAL_NC    5  // Force Normal Non-Cacheable
#define MT_S2_FWB_DEVICE_nGnRE 1  // Force Device
#define MT_S2_FWB_AS_S1        7  // Use whatever Stage-1 specified
```

When **FWB** (Forwarded Write-Back, `HCR_EL2.FWB=1`) is available, Stage-2 can force the
final memory type regardless of what Stage-1 requested. Without FWB, the final type is the
"most restrictive" combination of Stage-1 and Stage-2 attributes.

### 8i. Comparison with x86-64 Virtualization

| Aspect | AArch64 | x86-64 (Intel) | x86-64 (AMD) |
|--------|---------|----------------|--------------|
| Stage-2 mechanism | VTTBR_EL2 + VTCR_EL2 | EPT (Extended Page Tables), EPTP in VMCS | NPT (Nested Page Tables), nCR3 in VMCB |
| VM identifier | VMID in VTTBR_EL2 (8/16-bit) | VPID (16-bit) | ASID in VMCB (not same as host ASID) |
| Stage-2 TLB invalidation | `TLBI IPAS2E1IS` (hardware broadcast) | `INVEPT` | `INVLPGA` |
| Max IPA size | Configurable via VTCR_EL2 (up to 52-bit) | Configurable via EPTP (up to 57-bit) | Configurable in VMCB |
| Table concatenation | Up to 16 tables at entry level (saves a level) | No equivalent | No equivalent |
| Memory attribute control | S2 MemAttr, optional FWB override | EPT memory type in leaf entries | Uses PAT from guest |
| Hypervisor exception level | EL2 (dedicated) | VMX root mode | SVM host mode |

---

## Summary: The Complete Picture (AArch64)

```
User Process (EL0)
     │
     │ accesses virtual address (bit 55 = 0 → TTBR0_EL1)
     ▼
┌─────────────────┐
│ MMU + TLB       │◄── TLB hit (matched by VA + ASID)? → PA (done, 1-2 cycles)
│                 │
│ TLB miss:       │
│ Stage-1 walk    │
│ PGD→PUD→PMD→PTE│
└────────┬────────┘
         │
         ├── Entry valid + AF set + permissions OK → PA, cache in TLB
         │
         ├── AF clear → Access Flag fault (FSC 0x08-0x0B)
         │    → Kernel sets AF bit, restores PTE
         │
         └── Entry not present or permission fault → exception to EL1
              │
              ▼
         ┌─────────────────────────────────┐
         │ Kernel fault handler (EL1)       │
         │ do_mem_abort → do_page_fault     │
         │                                 │
         │ • Demand paging → alloc + map   │
         │ • COW → copy + remap            │
         │ • NUMA → migrate + remap        │
         │ • Invalid → SIGSEGV             │
         └─────────────────────────────────┘

Kernel allocators:
  kmalloc  → slab/buddy → direct-map VA (PA = VA - PAGE_OFFSET + PHYS_OFFSET)
  vmalloc  → individual pages → mapped via PTEs in vmalloc space
  kvmalloc → kmalloc first, vmalloc fallback

TLB management:
  Context switch → write TTBR0_EL1 (ASID tags entries, no flush needed)
  Page unmap     → TLBI VAE1IS / RVAE1IS (hardware broadcast, no IPIs)
  Batched ops    → multiple TLBIs + single DSB ISH

Virtualization adds Stage-2 (EL2):
  VA → [Stage-1, TTBR0_EL1] → IPA → [Stage-2, VTTBR_EL2] → PA
  Stage-2 fault → trap to EL2 → kvm_handle_guest_abort → map/emulate
```
