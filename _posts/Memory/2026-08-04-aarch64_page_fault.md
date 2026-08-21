---
title: AArch64 Page Fault Handling
published: true
categories: [memory]
tags: [page fault]
---

# AArch64 Page Fault Handling

This document covers every aspect of page fault handling on AArch64 (ARM64) Linux, from the hardware trigger down to the kernel resolution and return, with references to the actual kernel source code (v7.2-rc5).

---

## 0. What Is a Page Fault?

In Linux, the actual physical allocation of userland memory occurs not on mapping but when a page fault occurs on access to that memory. A page fault arises when a user attempts to access virtual memory that either does not have a valid page table mapping or for which the page table mapping does not allow the attempted action (e.g. writing to a read-only mapping).

The page faults themselves arise due to the computer's Memory Management Unit (MMU) detecting an invalid access. The kernel can tell the hardware to invoke its handler when this occurs and modern hardware permits the mapping to be corrected, i.e. 'fixing up' the page fault, if the kernel deems the access to have been valid.

When page faults occur at an address contained within a valid mapping, the kernel is then able to 'back' this memory by performing the physical allocation of that memory and updating the page table mapping to correctly reference it. Doing so is termed **demand paging** because the actual allocation of memory occurs on demand rather than on mapping.

When this occurs, the pages are said to be 'faulted in' (which we can further subdivide into 'read faulting' and 'write faulting'). Note that a page fault can be pre-triggered when using `mmap()` via the `MAP_POPULATE` flag. This is, from the kernel's point of view, equivalent to write faulting them in.

The page fault mechanism permits a disconnect between mapping userland memory and both allocating physical memory and establishing page table mappings to it — all that is required for userland memory to be valid is for the range to be contained within a VMA with the appropriate flags.

Broadly speaking there are two types of page faults:

1. **Anonymous page faults** — arising for anonymous mappings (heap, stack, `mmap(MAP_ANONYMOUS)`). These allocate physical memory to back them.
2. **File-backed page faults** — arising for file-backed mappings. These check the page cache to see if the file data is already available and map to that if so; if not, invoke filesystem functionality to place the data into the page cache before mapping it.

Complexity arises around swap, page migration and NUMA balancing, each of which result in specific actions being taken on page faults.

---

## 1. Who Triggers a Page Fault — Software or Hardware?

**The MMU (Memory Management Unit) hardware triggers the page fault. It is NOT software.**

On AArch64, the MMU is an integral part of the CPU core itself (not a separate chip). When any instruction attempts to access a virtual address, the MMU performs a **hardware page table walk** to translate the virtual address to a physical address. The MMU walks through up to 4 levels of page tables (on a 48-bit VA / 4KB page configuration):

```
Virtual Address
    |
    +-- bits [47:39] --> Level 0 (PGD) --> 512 entries, each covers 512GB
    +-- bits [38:30] --> Level 1 (PUD) --> 512 entries, each covers 1GB
    +-- bits [29:21] --> Level 2 (PMD) --> 512 entries, each covers 2MB
    +-- bits [20:12] --> Level 3 (PTE) --> 512 entries, each covers 4KB
    +-- bits [11:0]  --> Page Offset   --> byte offset within the 4KB page
```

The page table base is stored in:

- **TTBR0_EL1** — for user-space addresses (lower half, typically `0x0000_0000_0000_0000` to `0x0000_FFFF_FFFF_FFFF`)
- **TTBR1_EL1** — for kernel addresses (upper half, typically `0xFFFF_0000_0000_0000` to `0xFFFF_FFFF_FFFF_FFFF`)

The CPU selects which TTBR to use based on the upper bits of the virtual address (bit 55 in a 48-bit VA configuration).

### When Does the MMU Raise a Fault?

The MMU raises a **synchronous exception** (data abort or instruction abort) when:

1. **Translation Fault (FSC 0x04--0x07)**: A page table descriptor at any level has bit 0 (`PTE_VALID`) clear -- meaning "no mapping exists." This is the classic demand paging case.

2. **Access Flag Fault (FSC 0x08--0x0B)**: The descriptor exists and is valid, but the **Access Flag** (bit 10, `PTE_AF`) is clear. ARM64 uses this for tracking whether a page has been accessed.

3. **Permission Fault (FSC 0x0C--0x0F)**: The mapping exists, but the access violates permissions:
   - Writing to a page with `PTE_RDONLY` (bit 7) set
   - User (EL0) accessing a page without `PTE_USER` (bit 6) set
   - Executing from a page with `PTE_UXN` (bit 54) or `PTE_PXN` (bit 53) set

These fault types are encoded in the **FSC (Fault Status Code)**, bits [5:0] of the ESR_EL1 register. The lower 2 bits encode the page table level (0--3) at which the fault occurred.

**Reference:** [arch/arm64/include/asm/esr.h](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/esr.h#L115-L123)

```c
#define ESR_ELx_FSC        (0x3F)    /* Fault Status Code mask */
#define ESR_ELx_FSC_TYPE   (0x3C)    /* Upper 4 bits = fault type */
#define ESR_ELx_FSC_LEVEL  (0x03)    /* Lower 2 bits = page table level */
#define ESR_ELx_FSC_ACCESS (0x08)    /* Access flag fault base */
#define ESR_ELx_FSC_FAULT  (0x04)    /* Translation fault base */
#define ESR_ELx_FSC_PERM   (0x0C)    /* Permission fault base */
```

### PTE Bit Layout (Hardware-Defined)

**Reference:** [arch/arm64/include/asm/pgtable-hwdef.h](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L164-L176)

| Bit(s) | Name | Meaning |
|--------|------|---------|
| 0 | [`PTE_VALID`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L164) | Valid bit -- if clear, MMU raises translation fault |
| [1:0]=0b11 | [`PTE_TYPE_PAGE`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L166) | Identifies a 4KB page descriptor |
| [4:2] | [`PTE_ATTRINDX`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L195) | Memory attribute index into MAIR register |
| 6 | [`PTE_USER`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L167) | AP[1] -- if set, EL0 (user) can access |
| 7 | [`PTE_RDONLY`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L168) | AP[2] -- if set, page is read-only |
| [9:8] | [`PTE_SHARED`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L169) | Shareability (inner shareable for SMP) |
| 10 | [`PTE_AF`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L170) | Access Flag -- if clear, first access raises access flag fault |
| 11 | [`PTE_NG`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L171) | not-Global (ASID-tagged in TLB) |
| 51 | [`PTE_DBM`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L173) | Dirty Bit Management (hardware dirty tracking) |
| 53 | [`PTE_PXN`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L175) | Privileged Execute Never |
| 54 | [`PTE_UXN`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h#L176) | User Execute Never |

**Software-defined bits** (used by Linux, invisible to MMU hardware):

**Reference:** [arch/arm64/include/asm/pgtable-prot.h](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-prot.h#L16-L19)

| Bit | Name | Meaning |
|-----|------|---------|
| 51 | [`PTE_WRITE`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-prot.h#L16) | Software writable flag (aliased to DBM bit) |
| 55 | [`PTE_DIRTY`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-prot.h#L18) | Software dirty bit |
| 56 | [`PTE_SPECIAL`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-prot.h#L19) | Special mapping (VM_PFNMAP, etc.) |

---

## 2. How the CPU Detects "This Should Be a Page Fault"

The detection is **entirely in hardware** and happens on every memory access. Here is the exact sequence:

### Step-by-Step Hardware Sequence

```
1. CPU core executes LDR X0, [X1]  (or any memory-accessing instruction)
                |
2. MMU receives the virtual address from X1
                |
3. MMU checks TLB (Translation Lookaside Buffer) first
   +-- TLB HIT:  Use cached translation, check permissions -> done
   +-- TLB MISS: Start hardware page table walk
                |
4. MMU reads TTBR0_EL1 (user addr) or TTBR1_EL1 (kernel addr)
   to get the base physical address of Level 0 page table
                |
5. MMU walks Level 0 -> Level 1 -> Level 2 -> Level 3
   At EACH level, the MMU checks:
   +-- Is descriptor valid? (bit 0)  -> NO: Translation Fault at this level
   +-- Is it a block/section?        -> YES: Check permissions, done
   +-- Is it a table descriptor?     -> YES: Follow pointer to next level
                |
6. At the final level (PTE), the MMU checks:
   +-- Is PTE_VALID set?       -> NO:  Translation fault (FSC 0x07)
   +-- Is PTE_AF set?          -> NO:  Access flag fault (FSC 0x0B)
   +-- Permission check:
   |   +-- Write to RDONLY?    -> YES: Permission fault (FSC 0x0F)
   |   +-- EL0 without USER?  -> YES: Permission fault (FSC 0x0F)
   |   +-- Execute with UXN?  -> YES: Permission fault (FSC 0x0F)
   +-- All checks pass         -> Translation succeeds, access physical memory
```

### What the CPU Does When a Fault is Detected

When the MMU detects a fault condition, the CPU hardware automatically performs these steps **in a single atomic operation** (no software involvement yet):

1. **Saves the current PC** -> `ELR_EL1` (Exception Link Register)
   - This is the address of the faulting instruction, so it can be retried later
2. **Saves the current PSTATE** -> `SPSR_EL1` (Saved Program Status Register)
   - This includes the exception level (EL0 or EL1), interrupt masks, condition flags
3. **Writes fault information** -> `ESR_EL1` (Exception Syndrome Register)
   - EC field [31:26]: Exception Class (0x24 = data abort from EL0, 0x25 = from EL1)
   - WnR bit [6]: Whether the access was a write (1) or read (0)
   - FSC bits [5:0]: The specific fault type and level
4. **Saves the faulting virtual address** -> `FAR_EL1` (Fault Address Register)
5. **Switches to EL1** (if coming from EL0) -- this is the user->kernel mode switch
6. **Sets PSTATE.DAIF** to mask certain exceptions
7. **Jumps to the exception vector** -- reads `VBAR_EL1` + offset

All of this is pure hardware -- no software has executed yet.

---

## 3. How the CPU Knows Which Handler to Call

### The Vector Base Address Register (VBAR_EL1)

The CPU does NOT know which "handler" to call. It only knows one thing: **jump to `VBAR_EL1 + offset`**. The offset depends on:

- Where the exception came from (EL0 or EL1)
- The type of exception (synchronous, IRQ, FIQ, SError)
- The execution state of the lower EL (AArch64 or AArch32)

### VBAR_EL1 is Set During Boot

**Reference:** [arch/arm64/kernel/head.S](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/head.S#L224-L226)

```asm
adr_l   x8, vectors          /* load address of vector table */
msr     vbar_el1, x8          /* program VBAR_EL1 */
isb                           /* instruction sync barrier */
```

This tells the CPU: "When any exception occurs at EL1, jump to the `vectors` symbol plus an offset."

### The Exception Vector Table Layout

**Reference:** [arch/arm64/kernel/entry.S](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry.S#L517-L537)

The vector table is 2KB-aligned and has 16 entries, each 128 bytes (32 instructions) apart:

```
VBAR_EL1 + 0x000: EL1t Sync   (EL1 using SP_EL0 -- not used in Linux)
VBAR_EL1 + 0x080: EL1t IRQ
VBAR_EL1 + 0x100: EL1t FIQ
VBAR_EL1 + 0x180: EL1t SError

VBAR_EL1 + 0x200: EL1h Sync   <-- KERNEL page fault lands here
VBAR_EL1 + 0x280: EL1h IRQ
VBAR_EL1 + 0x300: EL1h FIQ
VBAR_EL1 + 0x380: EL1h SError

VBAR_EL1 + 0x400: EL0_64 Sync <-- USER page fault lands here
VBAR_EL1 + 0x480: EL0_64 IRQ
VBAR_EL1 + 0x500: EL0_64 FIQ
VBAR_EL1 + 0x580: EL0_64 SError

VBAR_EL1 + 0x600: EL0_32 Sync (32-bit/AArch32 compat)
VBAR_EL1 + 0x680: EL0_32 IRQ
VBAR_EL1 + 0x700: EL0_32 FIQ
VBAR_EL1 + 0x780: EL0_32 SError
```

The actual kernel code:

```asm
SYM_CODE_START(vectors)
    kernel_ventry  1, t, 64, sync     // EL1t Sync
    kernel_ventry  1, t, 64, irq
    kernel_ventry  1, t, 64, fiq
    kernel_ventry  1, t, 64, error

    kernel_ventry  1, h, 64, sync     // EL1h Sync -- kernel faults
    kernel_ventry  1, h, 64, irq
    kernel_ventry  1, h, 64, fiq
    kernel_ventry  1, h, 64, error

    kernel_ventry  0, t, 64, sync     // EL0 64-bit Sync -- user faults
    kernel_ventry  0, t, 64, irq
    kernel_ventry  0, t, 64, fiq
    kernel_ventry  0, t, 64, error

    kernel_ventry  0, t, 32, sync     // EL0 32-bit (compat)
    kernel_ventry  0, t, 32, irq
    kernel_ventry  0, t, 32, fiq
    kernel_ventry  0, t, 32, error
SYM_CODE_END(vectors)
```

A page fault is a **synchronous exception**. So:

- **User-space page fault**: CPU jumps to `VBAR_EL1 + 0x400` -> `el0t_64_sync`
- **Kernel page fault**: CPU jumps to `VBAR_EL1 + 0x200` -> `el1h_64_sync`

At this point the CPU has done its job -- everything from here is **software (kernel code)**.

---

## 4. The Handler IS Kernel Software -- How the Kernel Distinguishes Fault Types

### 4.1 Assembly Entry: Save State and Call C

The [`kernel_ventry`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry.S#L39) macro (128 bytes per entry) does minimal work: reserves stack space for register save area and branches to the real handler stub.

**Reference:** [arch/arm64/kernel/entry.S -- `entry_handler` macro](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry.S#L568-L602)

```asm
.macro entry_handler el:req, ht:req, regsize:req, label:req
SYM_CODE_START_LOCAL(el\el\ht\()_\regsize\()_\label)
    kernel_entry \el, \regsize         // Save ALL 31 GPRs + ELR + SPSR to stack
    mov  x0, sp                        // x0 = pointer to pt_regs (C arg 1)
    bl   el\el\ht\()_\regsize\()_\label\()_handler  // Call C handler
    .if \el == 0
    b    ret_to_user                   // Return to userspace
    .else
    b    ret_to_kernel                 // Return to kernel
    .endif
SYM_CODE_END(...)
.endm
```

This generates two critical stubs:

- `el0t_64_sync` -> calls `el0t_64_sync_handler()` in C -> then `ret_to_user`
- `el1h_64_sync` -> calls `el1h_64_sync_handler()` in C -> then `ret_to_kernel`

The [`kernel_entry`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry.S#L197) macro saves the complete CPU state: all 31 general-purpose registers, `ELR_EL1`, `SPSR_EL1`, and the original `SP_EL0` (user stack pointer) into a `struct pt_regs` on the kernel stack.

### 4.2 C Handler: Read ESR and Dispatch by Exception Class

Now we are in C code. The kernel reads the ESR register to find out what kind of synchronous exception this is.

**Reference:** [arch/arm64/kernel/entry-common.c](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry-common.c)

**For user-space exceptions** -- [`el0t_64_sync_handler()`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry-common.c#L749):

```c
asmlinkage void noinstr el0t_64_sync_handler(struct pt_regs *regs)
{
    unsigned long esr = read_sysreg(esr_el1);   // Read ESR_EL1

    switch (ESR_ELx_EC(esr)) {                  // Extract EC field [31:26]
    case ESR_ELx_EC_DABT_LOW:                   // 0x24 = Data abort from EL0
        el0_da(regs, esr);
        break;
    case ESR_ELx_EC_IABT_LOW:                   // 0x20 = Instruction abort from EL0
        el0_ia(regs, esr);
        break;
    case ESR_ELx_EC_SVC64:                      // 0x15 = System call (SVC)
        el0_svc(regs);
        break;
    /* ... other exception classes ... */
    }
}
```

**For kernel exceptions** -- [`el1h_64_sync_handler()`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry-common.c#L442):

```c
asmlinkage void noinstr el1h_64_sync_handler(struct pt_regs *regs)
{
    unsigned long esr = read_sysreg(esr_el1);

    switch (ESR_ELx_EC(esr)) {
    case ESR_ELx_EC_DABT_CUR:                   // 0x25 = Data abort from EL1
    case ESR_ELx_EC_IABT_CUR:                   // 0x21 = Instruction abort from EL1
        el1_abort(regs, esr);
        break;
    /* ... */
    }
}
```

The EC values that identify page faults:

**Reference:** [arch/arm64/include/asm/esr.h](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/esr.h#L44-L49)

| EC Value | Constant | Meaning |
|----------|----------|---------|
| 0x20 | `ESR_ELx_EC_IABT_LOW` | Instruction abort from **user** (EL0) |
| 0x21 | `ESR_ELx_EC_IABT_CUR` | Instruction abort from **kernel** (EL1) |
| 0x24 | `ESR_ELx_EC_DABT_LOW` | Data abort from **user** (EL0) |
| 0x25 | `ESR_ELx_EC_DABT_CUR` | Data abort from **kernel** (EL1) |

### 4.3 Reading the Faulting Address and Calling do_mem_abort()

**User data abort** -- [`el0_da()`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry-common.c#L546):

```c
static void noinstr el0_da(struct pt_regs *regs, unsigned long esr)
{
    unsigned long far = read_sysreg(far_el1);   // Read faulting virtual address
    arm64_enter_from_user_mode(regs);            // Context tracking, RCU, etc.
    local_daif_restore(DAIF_PROCCTX);            // Re-enable interrupts
    do_mem_abort(far, esr, regs);                // THE CENTRAL DISPATCHER
    arm64_exit_to_user_mode(regs);               // Prepare return to user
}
```

**Kernel abort** -- [`el1_abort()`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry-common.c#L315):

```c
static void noinstr el1_abort(struct pt_regs *regs, unsigned long esr)
{
    unsigned long far = read_sysreg(far_el1);
    irqentry_state_t state;
    state = arm64_enter_from_kernel_mode(regs);
    local_daif_inherit(regs);
    do_mem_abort(far, esr, regs);
    arm64_exit_to_kernel_mode(regs, state);
}
```

Both paths converge at [`do_mem_abort()`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/mm/fault.c#L980).

### 4.4 The fault_info[] Table -- Mapping FSC to Specific Handlers

This is how the kernel distinguishes **different types** of page faults.

**Reference:** [arch/arm64/mm/fault.c -- `fault_info[]` array](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/mm/fault.c#L913-L978)

The [`esr_to_fault_info()`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/mm/fault.c#L59) function uses the FSC (bits [5:0] of ESR) as a **direct index** into a table of handler functions:

```c
static inline const struct fault_info *esr_to_fault_info(unsigned long esr)
{
    return fault_info + (esr & ESR_ELx_FSC);   // FSC is the array index
}
```

Key entries in the table:

| FSC | Handler Function | Fault Type |
|-----|-----------------|------------|
| 0x00--0x03 | [`do_bad`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/mm/fault.c#L861) | Address size fault (levels 0--3) |
| **0x04--0x07** | [**`do_translation_fault`**](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/mm/fault.c#L838) | **Translation fault (levels 0--3) -- page not mapped** |
| **0x08--0x0B** | [**`do_page_fault`**](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/mm/fault.c#L601) | **Access flag fault (levels 0--3)** |
| **0x0C--0x0F** | [**`do_page_fault`**](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/mm/fault.c#L601) | **Permission fault (levels 0--3) -- e.g., write to read-only** |
| 0x10 | [`do_sea`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/mm/fault.c#L866) | Synchronous external abort |
| 0x11 | [`do_tag_check_fault`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/mm/fault.c#L897) | MTE (Memory Tagging Extension) fault |
| 0x21 | [`do_alignment_fault`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/mm/fault.c#L851) | Alignment fault |

**Reference:** [arch/arm64/mm/fault.c -- `do_mem_abort()`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/mm/fault.c#L980-L998)

```c
void do_mem_abort(unsigned long far, unsigned long esr, struct pt_regs *regs)
{
    const struct fault_info *inf = esr_to_fault_info(esr);  // Look up handler
    unsigned long addr = untagged_addr(far);

    if (!inf->fn(far, esr, regs))    // Call the handler; 0 = success
        return;

    if (!user_mode(regs))
        die_kernel_fault(inf->name, addr, esr, regs);   // Kernel oops

    arm64_notify_die(inf->name, regs, inf->sig, inf->code, addr, esr);
}
```

### 4.5 Kernel Page Faults and Spurious Faults

The following diagram shows the overall hardware page fault dispatch flow (x86-64 naming, but the logic is architecturally analogous on AArch64 — `handle_page_fault()` corresponds to `do_mem_abort()`, `do_kern_addr_fault()` to the kernel abort path, `do_user_addr_fault()` to the user abort path):

![Overview of hardware page fault handling](/assets/images/23613fd1c0e7059388fde070213da320e24596f355e87ca9ccee061453721e49.jpg)
*Figure: Overview of hardware page fault dispatch — kernel vs user address, spurious fault check, VMA lookup, and handle_mm_fault() entry*

Kernel page faults require entirely separate handling from userland page faults. The usual functionality available to userspace — such as demand paging — is not available to the kernel, and therefore most of the time a page fault at a kernel address indicates an error state. However, there are occasions where this is not the case.

**Spurious Faults from Lazy TLB Invalidation:**

The Translation Lookaside Buffer (TLB) is a key hardware cache between virtual and physical addresses used to avoid having to walk the page table for every memory access. Due to lazy TLB invalidation, a kernel TLB entry is permitted to go stale, meaning that an invalid access to a write-protected or execution-protected region of memory may occur due to the TLB entry not reflecting a recent permission upgrade (e.g. RO -> RW or NX -> X).

When the kernel tries to write to memory that appears read-only or execute in apparently NX memory, the fault handler must check whether the **page table entry** actually permits the access despite the fault. If it does, the fault is spurious — the TLB simply needs to be refreshed — and the handler returns without taking further action.

This lazy approach avoids the very expensive operation of performing a full cross-processor TLB flush every time kernel page permissions are increased. There are no security implications to leaving a stale TLB when increasing permissions on a page (the stale entry is *more* restrictive than the current mapping).

The spurious fault check works by walking the page tables from PGD down to PTE at each level, checking:
1. Is the page table entry present at this level?
2. If it's a huge page entry (block mapping), does it permit the access?
3. At the PTE level, does the entry permit the write or execution?

If the page table allows the access, the fault was spurious (stale TLB) and is silently handled. If not, the fault proceeds to `bad_area` handling (kernel oops).

On AArch64, the equivalent check in `do_mem_abort()` handles kernel faults via the `fault_info[]` dispatch. If the handler cannot resolve the fault (returns non-zero), `die_kernel_fault()` is called for kernel-mode faults:

```c
if (!user_mode(regs))
    die_kernel_fault(inf->name, addr, esr, regs);   // Kernel oops
```

Legitimate kernel page faults include:
- Faults during `get_user()` / `put_user()` / `copy_from_user()` / `copy_to_user()` — these are handled via the **exception table** (`__ex_table`), which maps faulting instruction addresses to fixup code
- vmalloc faults — when kernel vmalloc mappings have not yet been synchronized to the current task's page tables

---

## 5. How the Kernel Knows This Is a User-Space Page Fault

The kernel determines this at **two levels**:

### Level 1: The Exception Vector Entry (Hardware-Provided)

The CPU itself tells the kernel which exception level the fault came from via the **vector offset**:

- Offset 0x400 (EL0 sync) -> [`el0t_64_sync_handler()`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry-common.c#L749) -> calls [`el0_da()`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry-common.c#L546) for data aborts
- Offset 0x200 (EL1 sync) -> [`el1h_64_sync_handler()`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry-common.c#L442) -> calls [`el1_abort()`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry-common.c#L315) for data aborts

This is the first discrimination.

### Level 2: The ESR EC Field

The EC field in ESR_EL1 explicitly encodes the origin:

- [`ESR_ELx_EC_DABT_LOW`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/esr.h#L48) (0x24) = abort from **lower** EL (i.e., EL0 = user)
- [`ESR_ELx_EC_DABT_CUR`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/esr.h#L49) (0x25) = abort from **current** EL (i.e., EL1 = kernel)

### Level 3: user_mode(regs) in do_page_fault()

**Reference:** [arch/arm64/mm/fault.c](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/mm/fault.c#L624-L625)

```c
if (user_mode(regs))
    mm_flags |= FAULT_FLAG_USER;
```

The `user_mode()` macro checks bit 4 of `regs->pstate` (the saved SPSR_EL1), which encodes the exception level the fault came from. If the M[3:0] field is 0b0000 (EL0), it is a user fault.

### Level 4: Address Range Check (TTBR0 vs TTBR1)

**Reference:** [arch/arm64/mm/fault.c -- `do_translation_fault()`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/mm/fault.c#L838-L848)

```c
if (is_ttbr0_addr(addr))
    return do_page_fault(far, esr, regs);   // User address range
```

On AArch64, `TTBR0` addresses (lower half of virtual address space) are user addresses, `TTBR1` addresses (upper half) are kernel addresses. The [`is_ttbr0_addr()`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/mm/fault.c#L844) function checks whether the faulting address falls in the user range.

---

## 6. How the Kernel Switches from User Mode to Kernel Mode

### This Is NOT a Software Operation -- The CPU Does It

When a page fault occurs while executing in EL0 (user mode), the CPU **automatically** performs the mode switch. There is no `syscall` or `svc` instruction involved -- the MMU fault itself triggers it.

### The Exact Hardware Sequence

```
User code at EL0 executes:  LDR X0, [X1]   (X1 points to unmapped page)
                                    |
                        +-----------+-----------+
                        |   MMU DETECTS FAULT    |  <-- Hardware
                        +-----------+-----------+
                                    |
                The CPU atomically does ALL of these:
                                    |
    +---------------------------------------------------------------+
    | 1. ELR_EL1  <- PC of faulting instruction                     |
    | 2. SPSR_EL1 <- Current PSTATE (includes EL0 indicator)        |
    | 3. ESR_EL1  <- Exception syndrome (EC=0x24, FSC, WnR)        |
    | 4. FAR_EL1  <- Faulting virtual address (value of X1)         |
    | 5. PSTATE   <- Switch to EL1, mask interrupts (DAIF)          |
    | 6. SP       <- Switch to SP_EL1 (kernel stack)                |
    | 7. PC       <- VBAR_EL1 + 0x400 (EL0 64-bit Sync entry)      |
    +---------------------------------------------------------------+
                                    |
                        Now executing at EL1 (kernel mode)
                        with kernel stack, at the vector entry
```

After this, the **kernel assembly code** takes over:

1. [`kernel_ventry`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry.S#L39) saves a few registers, branches to `el0t_64_sync`
2. [`kernel_entry 0`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry.S#L197) macro saves all 31 GPRs + ELR + SPSR onto the kernel stack as `struct pt_regs`
3. `bl el0t_64_sync_handler` calls into C code

The kernel stack (`SP_EL1`) was set up when the process was created. Each process has its own kernel stack. The `SP_EL1` value is loaded from the process's `thread_info` during context switch.

---

## 7. How the Kernel Resolves Different Types of Page Faults

### 7.1 The Central Flow

After `do_mem_abort()` dispatches to the right handler, page faults that can be resolved go through this chain:

```
do_mem_abort()
    |
    +-- do_translation_fault()     [FSC 0x04-0x07: page not mapped]
    |       +-- do_page_fault()
    |
    +-- do_page_fault()            [FSC 0x08-0x0F: access/permission faults]
            |
            +-- Find the VMA (vm_area_struct) for the faulting address
            +-- Check permissions against VMA flags
            +-- handle_mm_fault()  [Generic MM -- arch-independent from here]
                    |
                    +-- __handle_mm_fault()
                            |
                            +-- Walk/allocate PGD -> P4D -> PUD -> PMD
                            +-- handle_pte_fault()
                                    |
                                    +-- PTE missing     -> do_pte_missing()
                                    +-- PTE swapped out -> do_swap_page()
                                    +-- NUMA hint fault -> do_numa_page()
                                    +-- Write to RO     -> do_wp_page() [COW]
```

### 7.2 Fault Flags

Before examining the fault handler, it's important to understand the flags that control fault handling behavior. These are set in the `mm_flags` variable and passed through to `handle_mm_fault()`.

Key fault flags:

| Flag | Meaning |
|------|---------|
| `FAULT_FLAG_WRITE` | The fault was caused by a write access |
| `FAULT_FLAG_USER` | The fault originated from user mode |
| `FAULT_FLAG_ALLOW_RETRY` | The fault handler is allowed to retry if it drops locks |
| `FAULT_FLAG_KILLABLE` | The faulting task can be killed while waiting for I/O |
| `FAULT_FLAG_INTERRUPTIBLE` | The faulting task can be interrupted while waiting |
| `FAULT_FLAG_UNSHARE` | The faulting anonymous page should be 'unshared' if it is a CoW page marked exclusive. Used by GUP in `faultin_page()`. Invalid if `FAULT_FLAG_WRITE` is also set (which would copy the page anyway). This avoids situations where a forked folio might get CoW'd, causing the userland mapping to point at a different folio |
| `FAULT_FLAG_ORIG_PTE_VALID` | Indicates whether the `orig_pte` field in `struct vm_fault` contains a valid entry. Set or cleared in `handle_pte_fault()` depending on whether `vmf->pmd` is empty (as determined by `pmd_none()`) |

The default set of flags (`FAULT_FLAG_DEFAULT`) consists of `FAULT_FLAG_ALLOW_RETRY`, `FAULT_FLAG_KILLABLE` and `FAULT_FLAG_INTERRUPTIBLE`. These are set during hardware page fault handling.

The generic page handling function `handle_mm_fault()` is invoked both by the architecture-specific logic described above, and by other parts of the kernel — notably GUP via `faultin_page()` and `fixup_user_fault()`.

### 7.3 do_page_fault() -- The Core AArch64 Handler

**Reference:** [arch/arm64/mm/fault.c -- `do_page_fault()`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/mm/fault.c#L601-L836)

```c
static int __kprobes do_page_fault(unsigned long far, unsigned long esr,
                                   struct pt_regs *regs)
{
    /* 1. Determine fault type from ESR */
    if (is_el0_instruction_abort(esr)) {
        vm_flags = VM_EXEC;            // Instruction fetch fault
    } else if (is_write_abort(esr)) {
        vm_flags = VM_WRITE;           // Write fault
        mm_flags |= FAULT_FLAG_WRITE;
    } else {
        vm_flags = VM_READ;            // Read fault
    }

    if (user_mode(regs))
        mm_flags |= FAULT_FLAG_USER;

    /* 2. Find the VMA containing the faulting address */
    /* Fast path: per-VMA lock */
    vma = lock_vma_under_rcu(mm, addr);
    if (vma) {
        /* Check VMA permissions */
        if (!(vma->vm_flags & vm_flags)) {
            vma_end_read(vma);
            goto bad_area;              // SIGSEGV
        }
        fault = handle_mm_fault(vma, addr, mm_flags, regs);
        /* ... */
    }

    /* Slow path: mmap_read_lock */
    vma = lock_mm_and_find_vma(mm, addr, regs);
    fault = handle_mm_fault(vma, addr, mm_flags, regs);

    /* 3. Handle errors */
    if (fault & VM_FAULT_OOM)       -> out_of_memory()
    if (fault & VM_FAULT_SIGBUS)    -> SIGBUS to process
    if (fault & VM_FAULT_SIGSEGV)   -> SIGSEGV to process
}
```

Key helpers used:

- [`is_el0_instruction_abort()`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/mm/fault.c#L570) -- checks if fault is an instruction fetch from EL0
- [`is_write_abort()`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/mm/fault.c#L579) -- checks WnR bit in ESR
- [`lock_vma_under_rcu()`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/mm/fault.c#L681) -- fast-path VMA lookup
- [`lock_mm_and_find_vma()`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/mm/fault.c#L730) -- slow-path VMA lookup

### 7.4 Demand Paging -- Anonymous Pages (Heap, Stack, mmap MAP_ANONYMOUS)

When a process does `malloc()` -> `mmap(MAP_ANONYMOUS)`, the kernel only creates a VMA. No physical page is allocated, no PTE is created. The first access triggers a translation fault.

**Reference:** [mm/memory.c -- `do_pte_missing()`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/memory.c#L4561)

```c
static vm_fault_t do_pte_missing(struct vm_fault *vmf)
{
    if (vma_is_anonymous(vmf->vma))
        return do_anonymous_page(vmf);     // Heap/stack/anonymous mmap
    else
        return do_fault(vmf);              // File-backed mapping
}
```

Where [`vma_is_anonymous()`](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/mm.h#L1536) is defined in `include/linux/mm.h`.

**Reference:** [mm/memory.c -- `do_anonymous_page()`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/memory.c#L5287-L5390)

```
do_anonymous_page():
    |
    +-- READ fault:
    |   Allocate PTE table if needed: pte_alloc()
    |   Map the ZERO PAGE (shared, read-only, no physical allocation!):
    |       entry = pte_mkspecial(pfn_pte(zero_pfn, vm_page_prot))
    |       set_pte_at(mm, addr, pte, entry)
    |   > Process reads zeros. No real page allocated yet.
    |
    +-- WRITE fault:
        Allocate a real physical page (folio):
            folio = alloc_anon_folio(vmf)
        Zero the page:
            __folio_mark_uptodate(folio)
        Allocate PTE table if needed:
            pte_alloc(mm, pmd)
        Install the PTE:
            entry = mk_pte(page, vma->vm_page_prot)
            entry = pte_mkwrite(pte_mkdirty(entry))    // writable + dirty
            set_pte_at(mm, addr, pte, entry)
        Add to reverse mapping:
            folio_add_new_anon_rmap(folio, vma, addr)
        > Process now has a real physical page mapped R/W.
```

Key functions: [`alloc_anon_folio()`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/memory.c#L5161), [`set_pte_at()`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/memory.c#L5330)

### 7.5 File-Backed Page Faults

**Reference:** [mm/memory.c -- `do_fault()`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/memory.c#L5964-L6006)

```c
static vm_fault_t do_fault(struct vm_fault *vmf)
{
    if (!(vmf->flags & FAULT_FLAG_WRITE))
        return do_read_fault(vmf);          // Read from file -> page cache lookup
    else if (!(vma->vm_flags & VM_SHARED))
        return do_cow_fault(vmf);           // Write to private mapping -> COW copy
    else
        return do_shared_fault(vmf);        // Write to shared mapping
}
```

These call `vma->vm_ops->fault()` (typically `filemap_fault()`) which:

1. Looks up the page in the **page cache**
2. If not found, calls filesystem's `readahead()` to read from disk
3. Once the page is in the page cache, installs the PTE pointing to it

Sub-handlers:

- [`do_read_fault()`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/memory.c#L5840)
- [`do_cow_fault()`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/memory.c#L5872)
- [`do_shared_fault()`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/memory.c#L5914)

### 7.6 Swap Page Faults

**Reference:** [mm/memory.c -- `do_swap_page()`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/memory.c#L4747-L5123)

When a page was swapped out, the PTE is not "empty" -- it contains a **swap entry** (a non-present PTE encoding the swap device and offset).

```
do_swap_page():
    |
    +-- Decode swap entry from PTE
    +-- Look up folio in swap cache: swap_cache_get_folio()
    +-- If not cached: read from swap device: swapin_readahead()
    +-- Lock folio, verify swap entry still matches
    +-- Build new PTE: mk_pte(page, vma->vm_page_prot)
    +-- Install PTE: set_ptes(mm, addr, ptep, pte, nr_pages)
    +-- Free swap slot if possible: folio_free_swap()
```

### 7.7 Copy-on-Write (COW) Page Faults

When a process forks, both parent and child share the same physical pages, mapped **read-only**. When either writes, a permission fault occurs.

**Reference:** [mm/memory.c -- `do_wp_page()`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/memory.c#L4244)

```
do_wp_page():
    |
    +-- Is this page shared by multiple processes?
    |   YES -> Allocate a new page, copy contents, install new PTE (COW)
    |   NO  -> Just make the existing PTE writable (reuse optimization)
    |
    +-- set_pte_at(mm, addr, pte, entry)  // Install new/updated PTE
```

### 7.8 Page Table Allocation and struct vm_fault Setup

**Reference:** [mm/memory.c -- `__handle_mm_fault()`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/memory.c#L6417-L6518)

```c
static vm_fault_t __handle_mm_fault(struct vm_area_struct *vma,
        unsigned long address, unsigned int flags)
{
    struct vm_fault vmf = {
        .vma = vma,
        .address = address & PAGE_MASK,       // Page-aligned fault address
        .real_address = address,               // Original unaligned address
        .flags = flags,
        .pgoff = linear_page_index(vma, address), // Page offset within VMA
        .gfp_mask = __get_fault_gfp_mask(vma),    // Allocation flags
    };
    struct mm_struct *mm = vma->vm_mm;
    pgd_t *pgd;
    p4d_t *p4d;

    pgd = pgd_offset(mm, address);            // Level 0: always exists
    p4d = p4d_alloc(mm, pgd, address);        // Level 1: allocate if missing
    vmf.pud = pud_alloc(mm, p4d, address);    // Level 2: allocate if missing
    vmf.pmd = pmd_alloc(mm, vmf.pud, address);// Level 3: allocate if missing
    /* ... */
    return handle_pte_fault(&vmf);            // Level 4: PTE handling
}
```

Each `*_alloc()` call checks if the page table page exists at that level. If not, it allocates a new page (4KB), zeroes it, and installs it in the parent level's descriptor. This is how the page table tree grows on demand.

Page table walk references: [`pgd_offset`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/memory.c#L6434), [`p4d_alloc`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/memory.c#L6435), [`pud_alloc`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/memory.c#L6439), [`pmd_alloc`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/memory.c#L6469)

### 7.9 The PTE-Level Decision Tree (handle_pte_fault)

The following diagram shows the complete generic (architecture-independent) page fault logic from `handle_mm_fault()` through `handle_pte_fault()`, including both the "update mapping" path (PTE exists) and the "allocate mapping" path (PTE is empty):

![Overview of simplified non-huge generic page fault logic](/assets/images/3af2b21919bfdb45bf94612e7e6685dc7cd3841ef060e370e35ed16bb467bc39.jpg)
*Figure: Generic page fault logic — handle_mm_fault() through handle_pte_fault() decision tree*

After `__handle_mm_fault()` walks/allocates page tables down to the PMD level, `handle_pte_fault()` makes the critical decisions about what to do at the PTE level:

**Step 1: Check if PMD is newly allocated (empty)**

If the PMD was just allocated, the PTE page table doesn't exist yet. In this case, `vmf->pte` is set to NULL and `FAULT_FLAG_ORIG_PTE_VALID` is cleared — no PTE has been allocated.

**Step 2: If PMD exists, look up the PTE**

If the PMD already existed, the handler uses `pte_offset_map()` to find the PTE entry, takes a copy in `orig_pte`, and sets `FAULT_FLAG_ORIG_PTE_VALID`.

If the PTE entry is empty (as determined by `pte_none()` — a PTE entry might be empty but not fully zeroed as a mask is applied), the pte field is set to NULL.

**Step 3: Dispatch based on PTE state**

```
handle_pte_fault():
    |
    +-- PTE is NULL (no mapping exists):
    |   |
    |   +-- vma_is_anonymous(vma)?
    |   |   YES -> do_anonymous_page()    // Heap/stack/anon mmap
    |   |   NO  -> do_fault()             // File-backed mapping
    |
    +-- PTE is non-empty but not present (bit 0 clear):
    |   |
    |   +-- Is it a swap entry?
    |       YES -> do_swap_page()          // Page was swapped out
    |
    +-- PTE is present but NUMA-migrated:
    |   +-- do_numa_page()                 // NUMA balancing migration
    |
    +-- PTE is present, write to read-only:
        +-- do_wp_page()                   // Copy-on-Write handling
```

The function [`vma_is_anonymous()`](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/mm.h#L1536) is a key definition:

```c
static inline bool vma_is_anonymous(struct vm_area_struct *vma)
{
    return !vma->vm_ops;
}
```

If a VMA lacks customized `struct vm_operations_struct` (`vm_ops`), then it is anonymous. Only non-anonymous (typically file-backed) memory mappings require customized VMA operation handling. This is the fundamental distinction that routes the fault to either `do_anonymous_page()` (allocate physical memory) or `do_fault()` (look up page cache / invoke filesystem).

---

## 8. How the Kernel Returns to the CPU After Handling the Fault

Once the page fault is resolved (PTE installed, page table populated), the kernel must return to the faulting instruction so the CPU can **re-execute** it -- this time the MMU walk will succeed.

### Return Path from User-Space Fault

**Reference:** [arch/arm64/kernel/entry.S](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry.S)

After the C handler returns, execution reaches [`ret_to_user`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry.S#L608-L615):

```asm
SYM_CODE_START_LOCAL(ret_to_user)
    ldr    x19, [tsk, #TSK_TI_FLAGS]    // Check for pending work (signals, etc.)
    enable_step_tsk x19, x2              // Re-enable single-step if needed
    kernel_exit 0                        // <-- Exit to EL0
SYM_CODE_END(ret_to_user)
```

The [`kernel_exit 0`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry.S#L335) macro does:

```asm
kernel_exit 0:
    // 1. Restore ELR_EL1 and SPSR_EL1 from saved pt_regs
    ldp  x21, x22, [sp, #S_PC]          // x21 = saved ELR, x22 = saved SPSR
    // (ELR_EL1 holds the address of the faulting instruction)

    // 2. Restore user stack pointer
    ldr  x23, [sp, #S_SP]
    msr  sp_el0, x23

    // 3. Program return state
    msr  elr_el1, x21                   // Set return PC = faulting instruction
    msr  spsr_el1, x22                  // Set return PSTATE = original user PSTATE

    // 4. Restore all 31 general-purpose registers from pt_regs
    ldp  x0, x1, [sp, #16 * 0]
    ldp  x2, x3, [sp, #16 * 1]
    ...
    ldp  x28, x29, [sp, #16 * 14]
    // (restore x30/lr separately)

    // 5. Execute ERET -- the magic instruction
    eret                                 // <-- Return to EL0
    sb                                   // Speculation barrier
```

### What ERET Does (Hardware)

The `ERET` (Exception Return) instruction is the inverse of the exception entry. The CPU hardware atomically:

1. **Loads PC from ELR_EL1** -- this is the address of the faulting instruction
2. **Loads PSTATE from SPSR_EL1** -- this restores the original exception level (EL0), interrupt masks, condition flags
3. **Switches back to EL0** -- user mode
4. **Switches SP to SP_EL0** -- user stack

The faulting instruction now **re-executes**. The MMU performs the page table walk again. This time, because the kernel installed a valid PTE, the walk succeeds, the TLB caches the new translation, and execution continues normally. The user-space code never knows a fault occurred.

### Return Path from Kernel Fault

For kernel faults, the path goes through [`ret_to_kernel`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry.S#L604-L606) instead:

```asm
SYM_CODE_START_LOCAL(ret_to_kernel)
    kernel_exit 1                       // Exit back to EL1
SYM_CODE_END(ret_to_kernel)
```

`kernel_exit 1` restores all registers and executes `eret` which returns to the faulting kernel instruction (still at EL1).

### KPTI (Kernel Page Table Isolation) Impact

When `CONFIG_UNMAP_KERNEL_AT_EL0` is enabled (Meltdown mitigation), the return path goes through [`tramp_exit`](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry.S#L767-L772):

```asm
SYM_CODE_START_LOCAL(tramp_exit)
    tramp_unmap_kernel  x29             // Switch TTBR1 to trampoline page tables
    mrs     x29, far_el1               // Restore x29
    eret                               // Return to EL0 with kernel unmapped
    sb
SYM_CODE_END(tramp_exit)
```

This switches `TTBR1_EL1` to a minimal trampoline page table before returning to user space, so the kernel's address space is not mapped while user code runs.

---

## 9. Complete End-to-End Flow Diagram

Here is the entire page fault path for a typical demand paging scenario -- user code writes to a freshly `malloc()`'d page for the first time:

```
=====================================================================
HARDWARE (CPU + MMU)
=====================================================================

 1  User code at EL0:    STR X0, [X1]   (X1 = address from malloc, no physical page yet)
                             |
 2  MMU walks page tables via TTBR0_EL1
    Level 0 (PGD) -> Level 1 (PUD) -> Level 2 (PMD) -> Level 3 (PTE)
    Finds: PTE entry is EMPTY (all zeros) -> PTE_VALID (bit 0) is 0
                             |
 3  MMU raises: Translation Fault, Level 3 (FSC = 0x07)
                             |
 4  CPU saves state atomically:
    ELR_EL1  = PC of STR instruction
    SPSR_EL1 = PSTATE (EL0, interrupts enabled, etc.)
    ESR_EL1  = EC=0x24 (DABT_LOW) | WnR=1 (write) | FSC=0x07 (xlat L3)
    FAR_EL1  = value of X1 (faulting virtual address)
                             |
 5  CPU switches to EL1, jumps to VBAR_EL1 + 0x400

=====================================================================
KERNEL ASSEMBLY (arch/arm64/kernel/entry.S)
=====================================================================

 6  kernel_ventry 0,t,64,sync:
    Sub SP by PT_REGS_SIZE, check stack overflow, branch to el0t_64_sync

 7  el0t_64_sync:
    kernel_entry 0 -> save all 31 GPRs + ELR + SPSR into struct pt_regs
    mov x0, sp    -> x0 = pointer to pt_regs
    bl el0t_64_sync_handler

=====================================================================
KERNEL C -- ENTRY (arch/arm64/kernel/entry-common.c)
=====================================================================

 8  el0t_64_sync_handler(regs):                              [line 749]
    esr = read_sysreg(esr_el1)          -> 0x9600_0007 (example)
    ESR_ELx_EC(esr) = 0x24              -> ESR_ELx_EC_DABT_LOW
    switch -> el0_da(regs, esr)

 9  el0_da():                                                [line 546]
    far = read_sysreg(far_el1)          -> faulting virtual address
    do_mem_abort(far, esr, regs)

=====================================================================
KERNEL C -- FAULT DISPATCH (arch/arm64/mm/fault.c)
=====================================================================

10  do_mem_abort():                                          [line 980]
    inf = fault_info[esr & 0x3F]        -> fault_info[0x07]
    inf->fn = do_translation_fault      -> call it

11  do_translation_fault():                                  [line 838]
    is_ttbr0_addr(addr)?                -> YES (user address)
    do_page_fault(far, esr, regs)

12  do_page_fault():                                         [line 601]
    is_write_abort(esr)?                -> YES (WnR=1)
    vm_flags = VM_WRITE
    mm_flags |= FAULT_FLAG_WRITE | FAULT_FLAG_USER
    vma = find VMA containing addr      -> found (from malloc/mmap)
    vma->vm_flags & VM_WRITE?           -> YES (VMA allows writes)
    handle_mm_fault(vma, addr, mm_flags, regs)

=====================================================================
KERNEL C -- GENERIC MM (mm/memory.c)
=====================================================================

13  handle_mm_fault() -> __handle_mm_fault():                [line 6417]
    pgd = pgd_offset(mm, addr)          -> exists
    p4d = p4d_alloc(mm, pgd, addr)      -> exists or allocated
    pud = pud_alloc(mm, p4d, addr)      -> exists or allocated
    pmd = pmd_alloc(mm, pud, addr)      -> exists or allocated
    handle_pte_fault()

14  handle_pte_fault():                                      [line 6335]
    vmf->pte == NULL                    -> PTE missing
    do_pte_missing()

15  do_pte_missing():                                        [line 4561]
    vma_is_anonymous(vma)?              -> YES (malloc = anonymous)
    do_anonymous_page()

16  do_anonymous_page():                                     [line 5287]
    pte_alloc(mm, pmd)                  -> allocate PTE page table if needed
    folio = alloc_anon_folio(vmf)       -> allocate a physical 4KB page
    clear_huge_page(page, addr, 1)      -> zero the page
    entry = mk_pte(page, vma->vm_page_prot)  -> build PTE descriptor
    entry = pte_mkwrite(pte_mkdirty(entry))  -> make it writable + dirty
    set_pte_at(mm, addr, pte, entry)    -> WRITE PTE INTO PAGE TABLE *
    return VM_FAULT_NOPAGE              -> success, no signal needed

=====================================================================
RETURN PATH
=====================================================================

17  Returns unwind: do_anonymous_page -> handle_pte_fault -> __handle_mm_fault
    -> handle_mm_fault -> do_page_fault -> do_translation_fault
    -> do_mem_abort (returns 0 = success)
    -> el0_da -> arm64_exit_to_user_mode
    -> el0t_64_sync_handler returns

18  Back in entry.S: b ret_to_user -> kernel_exit 0         [line 608]
    Restore ELR_EL1 = faulting STR instruction address
    Restore SPSR_EL1 = original EL0 PSTATE
    Restore all GPRs
    ERET -> back to EL0

=====================================================================
HARDWARE (CPU + MMU) -- RETRY
=====================================================================

19  CPU re-executes: STR X0, [X1]
    MMU walks page tables -> finds valid PTE with AF set, writable
    Translation succeeds -> write to physical page
    User code continues, never aware a fault occurred
```

---

## 10. Summary Table

| Question | Answer |
|----------|--------|
| Who triggers the page fault? | The **MMU hardware** inside the CPU core |
| Software or hardware? | **Hardware** detects the fault. **Software** (kernel) resolves it |
| Which hardware unit? | The **MMU** (Memory Management Unit), integrated into the CPU core |
| How does CPU know it's a page fault? | MMU checks `PTE_VALID`, `PTE_AF`, and permission bits during page table walk |
| How does CPU know which handler? | CPU jumps to `VBAR_EL1 + offset`. The kernel's vector table is at that address |
| Is the handler software? | **Yes** -- the exception vector table and all handlers are kernel code |
| How does the kernel distinguish fault types? | Reads `ESR_EL1` register -- EC field for exception class, FSC field for fault subtype. Uses `fault_info[]` table to dispatch |
| How does the kernel resolve demand paging? | Allocates physical page via [`alloc_anon_folio()`](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/memory.c#L5161), installs PTE via `set_pte_at()` |
| How does the kernel return to the CPU? | Restores all registers, executes `ERET` instruction which atomically returns to the faulting instruction at EL0 |
| How does user->kernel switch happen? | **CPU hardware** does it atomically: saves PC/PSTATE/ESR/FAR, switches to EL1, jumps to vector |
| How does the kernel know it's a user fault? | Vector offset (0x400 vs 0x200), ESR EC field (`DABT_LOW` vs `DABT_CUR`), and `user_mode(regs)` check |

---

## Source File References

| File | What It Contains | Link |
|------|-----------------|------|
| `arch/arm64/kernel/entry.S` | Exception vector table, `kernel_entry`/`kernel_exit` macros, `ret_to_user` | [entry.S](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry.S) |
| `arch/arm64/kernel/entry-common.c` | C handlers: `el0t_64_sync_handler`, `el0_da`, `el1_abort` | [entry-common.c](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/entry-common.c) |
| `arch/arm64/kernel/head.S` | Boot-time `VBAR_EL1` programming | [head.S](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/kernel/head.S) |
| `arch/arm64/include/asm/esr.h` | ESR register bit definitions (EC, FSC, WnR) | [esr.h](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/esr.h) |
| `arch/arm64/include/asm/pgtable-hwdef.h` | Hardware PTE bit definitions | [pgtable-hwdef.h](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-hwdef.h) |
| `arch/arm64/include/asm/pgtable-prot.h` | Software PTE bit definitions | [pgtable-prot.h](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/include/asm/pgtable-prot.h) |
| `arch/arm64/mm/fault.c` | `do_mem_abort`, `fault_info[]` table, `do_page_fault`, `do_translation_fault` | [fault.c](https://github.com/torvalds/linux/blob/v7.2-rc5/arch/arm64/mm/fault.c) |
| `mm/memory.c` | `handle_mm_fault`, `__handle_mm_fault`, `do_anonymous_page`, `do_swap_page`, `do_wp_page` | [memory.c](https://github.com/torvalds/linux/blob/v7.2-rc5/mm/memory.c) |
| `include/linux/mm.h` | `vma_is_anonymous` and other MM helpers | [mm.h](https://github.com/torvalds/linux/blob/v7.2-rc5/include/linux/mm.h) |
