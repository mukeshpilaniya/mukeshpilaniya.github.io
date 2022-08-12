
Github:- [https://github.com/mukeshpilaniya/meltdown](https://github.com/mukeshpilaniya/meltdown)
<p align="center">
    <h1><b>International Institute of Information Technology(IIIT), Bangalore</b></h1>
</p>
<p align="center">
  <img src="https://www.iiitb.ac.in/includefiles/userfiles/images/iiitb_logo.png" width="150" height="120" >
</p>
<p>
  <p align="center">
    <br>
    <br>
    <b>Meltdown Attack</b>
  </p>
  <br>
  <p align="center">
    <b>Mentor</b><br>
    <b>Prof.Thangaraju B</b><br>
    <b>Professor,IIIT-Bangalore</b>
    <br>
  </p>
  <br>
  <pre>
         Mukesh Kumar Pilaniya                                Shreyansh Jain
         M.Tech 1 st Year                                     M.Tech 1 st Year
         MT2019068                                            MT2019106
  </pre>
</p>

## Contents
1. Introduction
2. Background<br>
    2.1 Cache Side Channel and Attacks<br>
        2.1.1 FLUSH+RELOAD attack<br>
    2.2 Out-Of-Order Execution<br>
    2.3 Address Space Randomization<br>
3. Meltdown and its Components<br>
    3.1 Transient Instruction<br>
    3.2 Attack Description<br>
4. Evaluation<br>
    4.1 Environment Setting<br>
    4.2 Code Compilation<br>
    4.3 Reading from Cache versus Main Memory<br>
    4.4 Using Cache as Side-Channel<br>
    4.5 Prepration for Meltdown Attack<br>
    4.6 Exception Handling<br>
    4.7 Out-of-Order Execution<br>
    4.8 Meltdown Attack<br>
5. Prevention of Meltdown Attack - KAISER Patch
6. Conclusion

## Abstract
```
Application security relies on the memory mapping in the system as well as isolation
if memory unit and memory management unit is responsible for that like kernel address
system space that are marked as not accessible from user space and are marked as
priviliged. In this paper, we present Meltdown, Meltdown exploit vulnerabilities of
out-of-order execution which allows a user program to read data stored inside the
kernel-level memory that are marked as not accessible from user-level program.
Such, accessing of data is not allowed by the hardware level protection mechanism
implemented in Central Processing Unit(CPU), but the vulnerability exists in the
design of these CPU and mostly intel CPU are affected by meltdown. Meltdown
breaks all the security guarantees of a system which is not patched by KASLR.
```

## 1 Introduction
A operating system provide security to each application using memory isolation technique.Operating system provide guarantee that one application or program can not access other application data without permission of operating system(kernel).Kernel level permission bit is set by hardware level mechanism known as supervisor bit. Supervisor bit provide isolation between kernel address space and user address space. So, the aim is that this bit could only be set when entering into kernel space and it’s cleared when switching to user process(mode) space. This hardware feature allows OS to map kernel address space to address space of other user process and it is an very efficient address transitions scehme.(1)(9)
In this paper, we present Meltdown, the attack itself is quite complex,therefore we break it down into quite small steps so that each step is easy to understand.(1)(9) Meltdown does not exploit any kind of software vulnerability i.e it does not use or break internal software system but it is a hardware attack and it works on all the major intel system. The major cause of meltdown attack isout-of-order execution.(1)(9)
Out-of-order execution increases CPU efficiency and allows CPU to execute instruction faster and, in a second half of the paper we have describe it in short. Through Out-of-Order execution we exploit cache side channel to catch data store in L3 cache. However, out-of-order attacks cache side channel and the result allows an attacker to dump whole kernel memory by reading cache memory in an out-of-order execution manner.(1)(9)

### Outline
- In this section we will describe about
    - Cache Side channel and attacks
    - Out-Of-Order Execution
    - Address Spaces Randomization
- Meltdown and Its Components
- Evluation
- Conclusion

## 2 Background

In this section we describe cache side channel, out-of-order execution and address space randomization.

### 2.1 Cache Side Channel and Attacks

Cache based attack on the processor were happening for a number of years, meltdown and spectre are famous known attacks of Cache side channel. Cache side channel attacks are enabled using the micro architecture design of the processor. They are part of hardware design and thus they are very difficult to defeat.(9)(10) In order to speed up memory access and address translation CPU contains the small memory known as cache memory that store frequently used data. Every instruction and every piece of data that require main memory. The CPU retrieves the instruction and data from main memory execute that instruction and store result back in main memory. So, to improve per-formance of accessing main memory a hardware level access is made to various level of cache memory. If the require instruction or data already in cache memory CPU retrieved that data from cache execute it and save back to cache, with the help of various write back policy cache data is written back to main memory eg: - write back and write through.(1)(4)(9)
Here, the main point is cache memory is used for storing frequently access data.
    The attacker can not directly read data stored in cache memory but this does not mean that there is not information leakage, the cache is much smaller than main memory and nearest to the CPU, so data retrieving from cache memory is much faster than accessing data from main memory. Cache side channel exploit this timing difference for retrieving data. Differ-ent cache technique has been proposed in the past including Evict+Time, Prime+Probe and Flush+Reload.(2) The next piece of background information required to understand the CPU cache topology of modern processors. Figure [1] shows a generic topology that is common to most of modern CPU’s. Modern CPU’s generally contain multiple levels of cache memory. In this figure we assume that CPU is dual core and each core contains its own L1 and L2 cache memory and L3 cache is shared in between core0 and core1. We exploiting cache side channel attack in L3 cache only because that is practical to exploit and for side channel attack, we are using
Flush+Reload technique because it’s works on a single cache line granularity.(1)(4)(9)
All the technique works this way: manipulate cache to known state, wait for victim activity
and examine what has changed. Program virtual address map to physical address with the
help of page table. L1 cache is nearest to the CPU and split between a data and an instruc-
tion cache. If the data not found in L1 cache than load instruction passed to the next Cache
hierarchy. This is the point where the page table come into play. Page table are used to

<p align="center"> <img src="https://raw.githubusercontent.com/mukeshpilaniya/blog/gh-pages/_posts/Meltdown-Attack/images/images.004.png"></p>

```
Figure 1: Cache Architecture
```
translate virtual address into a physical address, once’s we have physical address CPU can
query into L2 cache and if data is not found in L2 cache then Load instruction is passed to
L3 cache. L3 is inclusive shared cache between core0 and core1.(3)(9)

#### 2.1.1 FLUSH+RELOAD attack

Using Flush+Reload an attacker can exploit last-level shared inclusive cache i.e Level3 cache,an attacker frequently flush a targeted memory location using theclflush instruction and thereby measuring the time it takes to reload the data, now the attacker can know whether data was loaded into the cache memory by another application or any current process in the meantime.(1)(9)

### 2.2 Out-Of-Order Execution

Out-Of-Order execution allows processor to execute the instructions one after the other, the processor uses the resources not to its full extent which makes CPU performance ineffi-cient.Thus, to improve the efficiency of CPU, there are two methods,first by executing various sub-steps of sequential instructions at the same time(simultaneously) or secondly maybe by executing instructions simultaneously depending on the resources availability. Further im-provement within the CPU can be achieved byOut-of-Order Execution. Out-of-order
instruction execution are usually achieved by executing the instruction in an various different form.(4)(9)
Out-of-order execution is a method or approach that is utilized in high performance micro-processors. Out-Of-Order efficiently uses instruction cycles (Instruction Cycles is a process by which a computer system pulls program instruction from the memory which can invoke pre-fetching or pre-processing, also determines what action the instruction requires or what resources it needs and carries out those actions.) and reduces costly delay due to resource
unavailability. A processor will execute the instruction order of availability of knowledge or operands or resources rather than original order of the instructions in the program. Through
this, the CPU will avoid being idle or free while data is retrieved for the next instruction in advance for a program.(4)(9) Out-of-Order Execution can be regarded asA Room guarded by a Security Officer.The attacker wants to enter the room to get some secret value but the Security Guard have 2 options either it can allow the attacker to access the data depending on the permissions or
it can deny the attacker to access the room’s data.(4)(9)

<p align="center"> <img src="https://raw.githubusercontent.com/mukeshpilaniya/blog/gh-pages/_posts/Meltdown-Attack/images/images.005.png"></p>
```
Figure 2: Out-Of-Order Execution
```
In figure 2 the line 3 causes an interrupt because user(attacker) wants to access the kerneldata, this line leads CPU to do two things
1. The CPU raises an exception since user level program want to access kernel level data, this causes program or application to either crash if the program doesn’t have exception handling mechanism.
2. Mean-while when CPU is busy in permission check the CPU doesn’t want the other com-putational parts to be idle since this may degrade the performance or efficiency so the CPU execute the adjacent instructions depending on the availability of data operands.

Now the user is either allowed or denied to access the data, but in both cases due to Out-of-Order Executionthe adjacent instructions are executed. If the permission is granted then the adjacent instructions are successfully executed but if the permission is denied the program or application may abruptly end(or may show appropriate message depending on the Exception Handling Mechanism) but in both cases the value from the kernel is fetched by the CPU and stored in a temporary register inCache Memory. The Cache Memory is not flushed in either case of access permission check, that means the data is still available
somewhere in the Cache. So from outside or user point of view the attacker has not accessed the data but from inside it can still access the data through Cache Memory via Timing Difference.(1)(4)(9)
We will show in the Evaluation(Section 5) the proof of Out-of-Order Execution that how the attacker can access the secret data.

### 2.3 Address Space Randomization

CPU’s support two kind of address spaces so that processes are isolated from each other. Virtual Address Spacescan be defined as virtual addresses that are translated to phys-ical(logical) addresses through page translation tables. Virtual address space is divided into a group of pages that will be mapped to the corresponding logical or physical memory through a multi-level page translation table. The page translation tables are used to define the specific mapping virtual to physical address and also protection bit(like dirty bit etc)
properties that are used to force privilege checks, like read access, write access, executable or not and user-accessible or not. The currently used translation table is stored in a special CPU register. On each context switch(change of process states), the OS updates this register with corresponding process translation table address so as to implement per-process virtual
address spaces.Thus, each process can only refer to data that belongs to its own virtual address space. Every virtual address space is divided into two categories which are User and Kernelparts so that each process gets a user and kernel address space. The currently running application uses the user address space, while the kernel address space would only be accessed if CPU is running(active) and also in privileged mode(mode bit set to 1). This is done by the operating system which disable the user-accessible property of the current or
specific translation tables. The kernel address space does not only have memory mapped for the kernel’s own use, but it must also perform operations on the user pages. As a result of this, the whole physical memory is mapped with the kernel.(1)(4)(9)

## 3 Meltdown and its Components

Meltdown Attack uses flaw in most of the modern processors.These flaws exists in the CPU’s itself i.e it can be regrded as a Hardware Defect rather than a software bug, it allows a user-level program to read data stored inside the kernel memory. We cannot access kernel space due to the hardware protection mechanism, but a defect exists in the design of these CPU’s which allows to defeat the hardware protection and thus carry out these types of attacks.
Because the defect exists within the hardware,it is very difficult to fundamentally fix the problem, unless we change the CPU’s in our computers.(1)(4)(9)

### 3.1 Transient Instruction

Before doing an in-depth analysis of how meltdown takes place, first we need to understand what is Transient Instruction.
`Any Instruction that executes Out-of-order in the program and has measurable side effects is known as Transient Instruction.`
Transient instructions occur all the time, because the CPU runs ahead of the current in-struction all the time to minimize the experienced latency and, thereby, to maximize the performance or efficiency.These instructions introduce an exploitable side channel if their operation depend on a secret value. We specialise in addresses that are mapped within the attacker’s process, i.e., the user-accessible user space addresses as well as the user-inaccessible which may kernel space addresses or other user’s address space.The attacks targeting code that is executed within the context (i.e., address space) of other user processess are also possible, but out of context in this work, because the physical memory (including the memory of other user processes) they are read through the kernel space.(1)(4)(9)

### 3.2 Attack Description

Meltdown attack can be divided into 3 steps:
1. To know Secret Kernel Address SpaceThe content of an attacker chosen memory
location which is stored in kernel space address and which can not be accessed by the attacker, is loaded into a register.
2. Out-of-Order Instruction ExecutionA transient instruction which is an out-of-order instruction accesses the cache line supported by the register.
3. Using Cache as Side Channel to read the secret dataThe attacker uses Flush+Reload technique (Timing Difference Attack) to work out the cache line accessed in the previous step and thus the secret stored at the specified memory location.Since these is only applicable for single memory location if the attacker uses these technique for other locations then it can get the secret from other locations in kernel space as well
which may lead to unavoidable consequences.(1)(2)(4)(9)

## 4 Evaluation

In this section we describe each step that need to done for performing meltdown attack.

### 4.1 Environment Setting

For setting up our lab environment we are using 64-bit ubuntu 16.04 LTS in oracle virtual box 6.0, setting related to hardware device is specified in given 3.

<p align="center"> <img src="https://raw.githubusercontent.com/mukeshpilaniya/blog/gh-pages/_posts/Meltdown-Attack/images/images.006.png"></p>

```
Figure 3: Environment Setting
```
### 4.2 Code Compilation

While compiling source code we have to add -march=native flag. while compiling the pro-gram -march=native flag tells the compiler to produce specific code for the local machine.
For, example to compile a myprogram.c we are using the following command :

```
gcc-march=native -o myprogram myprogram.c
```
### 4.3 Reading from Cache versus Main Memory

Cache memory is nearest to CPU so, first CPU check data in cache, if data is present in cache than it will fetch directly from it and if data is not present than it will fetch from main memory. Fetching data from cache is much faster than fetching data from main memory.

```
gcc -march=native -o CacheTime CacheTime.c
```
In the Figure 4 at line number 19, first we have initialized an array of size 10*PAZESIZE.For finding PAGESIZE run the following command in terminal “getconf PAGESIZE” and put your own PAGESIZE in line 8. After that we flush the array address to make sure that array indexes are not cached and in the next phase, we are accessing index 4 and 7 as shown in line number 25 and 26 so that index 4 and 7 is cached by cache. From line number 29 to 35 we are accessing the array index and measuring the timing using rdtscp time stamp.

<p align="center"> <img src="https://raw.githubusercontent.com/mukeshpilaniya/blog/gh-pages/_posts/Meltdown-Attack/images/images.007.png"></p>
```
Figure 4: Program Illustrating the Timing Difference of Probing Array
```
Figure 5 illustrate the timing difference where accessing the array index 3 and 7 is much faster than others.

<p align="center"> <img src="https://raw.githubusercontent.com/mukeshpilaniya/blog/gh-pages/_posts/Meltdown-Attack/images/images.008.png"></p>

```
Figure 5: Access Timing of Probing Array
```
### 4.4 Using Cache as Side-Channel

The objective of this section is extracting a secret value used by the victim function. We are assuming that victim(); function at line 53 uses a secret value define in line 14, as index to load values from an array and the secret value cannot be accessed from the outside. Our objective is to use side channel to get this secret value. The technique that we are using for
retrieving secret value is Flush(line 16)+Reload(line27) Functions.

As Shown in Figure 6 at line 14, first we set one-byte secretValue variable equal to 105.Since for a one-byte secret value there are 256 possibilities so in line 12 we declare array of size 256*PAGESIZE. We multiply by PAGESIZE because caching is done at a block level, not at a byte level so, if one byte is cached by cpu than adjacent byte will also cached. Since the first array[0*PAGESIZE] may also cached by some cache block as a default behavior of cache. Therefore, to make sure array[0*PAGESIZE] will not cached we are accessing array[i*PAGESIZE+DELTA], where DELTA is a constant define in line number 10.

<p align="center"> <img src="https://raw.githubusercontent.com/mukeshpilaniya/blog/gh-pages/_posts/Meltdown-Attack/images/images.009.png"></p>
```
Figure 6: Program showing Cache is used as a Side Channel
```

First Flush the entire array using flushSideChannel(); from the cache memory to make sure that array is not cached. After that we invoke the victim(); function, which access of the array element based on the value of secret, that array index value is cached by the cache memory. And the final step is calling the reloadSideChannel(); function which reload the entire array and measure the time it takes to reload each element. So, if the array index is previously cached than it requires less CPU cycle. The output of the program illustrates in Figure 7.
The output of the program shown in fig 6 below:

<p align="center"> <img src="https://raw.githubusercontent.com/mukeshpilaniya/blog/gh-pages/_posts/Meltdown-Attack/images/images.010.png"></p>
```
Figure 7: Reading of Secret Value from Cache
```
### 4.5 Prepration for Meltdown Attack

For preparing meltdown attack we have to placed secret value in kernel space and we show that how a user-level program can access that data without going into kernel space. To store the Secret value in kernel space we are using kernel Module approach and the code is listed in 8.

<p align="center"> <img src="https://raw.githubusercontent.com/mukeshpilaniya/blog/gh-pages/_posts/Meltdown-Attack/images/images.011.png"></p>
```
Figure 8: Program illustrating Meltdown Attack
```
For executing the meltdown attack first, we need to know address of secret value so, the kernel module saves the address of secret value in kernel buffer at line 41. which we will get it using ‘dmseg‘ command as shown in Figure 9. The next thing is this secret value need to be cached so to achieve this we are creating a file /proc/secretdata at line number 46. Which provide a link to communicate a user level program to kernel module. Therefore, when a user-level program read /proc/secretdata file then it will invoke readproc() function at line 23. The readproc() function will load the secret value (line 25) which is cached by CPU. readproc() function will not return secret value so it does not leak secret value.
 1. Compile the kernel module<br>
  ``make``
 2. Install the kernel module<br>
 ``sudo insmod MeltdownKernel.ko``
 3. Print secret value address<br>
 ``dmesg``

<p align="center"> <img src="https://raw.githubusercontent.com/mukeshpilaniya/blog/gh-pages/_posts/Meltdown-Attack/images/images.012.png"></p>
```
Figure 9: dmesg command
```
### 4.6 Exception Handling

When user program tries to access kernel memory in Figure 10 at line 23 than memory access violation is triggered and segmentation fault is generated. To avoid segmentation fault, we are using `SIGSEGV` signal because c does not provide try/catch techniques like java. So to implement try/catch in c we are using `sigsetjmp()` at line 21 and `siglongjmp` at line 10.

<p align="center"> <img src="https://raw.githubusercontent.com/mukeshpilaniya/blog/gh-pages/_posts/Meltdown-Attack/images/images.013.png"></p>
```
Figure 10: Exception Handling
```
The execution of this program is quite complex but let’s understand it line by line. First,we register a SIGSEGV signal handler in line 19 which will invoke catchsegv function (line7). once’s the signal handler complete processing it let the program to continue its execution so for that we have to define a checkpoint that we are achieve by sigsetjmp(buffer,1) at line 21. sigsetjmp save the stack context in buffer that it latter used by siglongjmp (line 10).
siglongjmp rollback the stack context in buffer and return the second argument which is 1 so the program execution is start form else part (line 29), output is illustrate in 11.

<p align="center"> <img src="https://raw.githubusercontent.com/mukeshpilaniya/blog/gh-pages/_posts/Meltdown-Attack/images/images.014.png"></p>
```
Figure 11: Output of Exception Handling Program
```
### 4.7 Out-of-Order Execution

Meltdown is a race condition vulnerability, which involves racing between out-of-order exe-cution and access block so, for exploiting meltdown successfully we must have to win race
condition. To win race condition we have to keep CPU execution busy somehow and for
that we are using assembly level code.

<p align="center"> <img src="https://raw.githubusercontent.com/mukeshpilaniya/blog/gh-pages/_posts/Meltdown-Attack/images/images.015.png"></p>
```
Figure 12: Out-of-Order Execution
```
The code in Figure 12 is simply a loop over 400 times (line 63). In the next line it adds a
number `0X141` (321 in decimal) to the eax register to keep rax register busy so that we can
win race condition.

### 4.8 Meltdown Attack

To make attack more practical and improve efficiency of attack we create a score array of size 256. The reason of creating an array of size 256 is that for one byte there is 256 possibilities.
Therefore, one element for each possible secret value and we run attack multiple times as
shown in Figure 13 at line 92. This step is combination of all step that are describe above,
after running multiple times the highest value of score array is our answer. The output of
this step is illustrated in Figure 14.

<p align="center"> <img src="https://raw.githubusercontent.com/mukeshpilaniya/blog/gh-pages/_posts/Meltdown-Attack/images/images.016.png"></p>
```
Figure 13: Reading Secret Value from Kernel
```
<p align="center"> <img src="https://raw.githubusercontent.com/mukeshpilaniya/blog/gh-pages/_posts/Meltdown-Attack/images/images.017.png"></p>
```
Figure 14: Output- Program Reading Secret Value from Kernel
```
`
The code in MeltdownAttack can only steals a one byte secret from the kernel.
`

## 5 Prevention of Meltdown Attack - KAISER Patch

The exploitation in the memory attacks usually requires correct knowledge of addresses of
specific data. So in order to carry out these attacks,`Address Space Layout Random-ization (ASLR)`has been introduced. To protect kernel, KASLR randomizes the offsets
which means the starting address from where the system is loaded and is changed every time
the system is booted , making attacks harder as the attacker now require to guess the situa-
tion of kernel data structures.(1)(4)(9) But, with side channel, the attacker has to precisely
determine the kernel address. A combination of a software bug and the knowledge of the
physical addresses can lead to privileged code execution.(1)(4)(9)
To Prevent Meltdown KAISER technique can be used more accurately or we can say that it
is a counter measure to Meltdown Attack. KAISER hide the kernel space from user space
using randomization technique. KAISER allow the kernel to randomize the kernel location
at boot time. The Output of same program after applying KAISER patch is illustrated in Figure 15.

<p align="center"> <img src="https://raw.githubusercontent.com/mukeshpilaniya/blog/gh-pages/_posts/Meltdown-Attack/images/images.018.png"></p>
```
Figure 15: KAISER PATCH
```

## 6 Conclusion

In this paper we presented Meltdown, a vulnerability or attack to the software system which
can read kernel data or secret data from an underprivileged user-level program, since it does
not depend on any software vulnerability as well as it is independent of the type of Operating
System.
To prevent Meltdown KAISER can be used more accurately we can say that it is a counter-
measure to Meltdown Attack, it is a kernel modification to not have the kernel mapped in
the user space.This modification to protect side channel attacks breaking KASLR(Kernel
Address Space Layout Randomization) but it also prevents Meltdown.

## References

[1] ZhengZmy(2019)Meltdown: Reading Kernel Memory from User Space
  [https://blog.csdn.net/zheng_zmy/article/details/](https://blog.csdn.net/zheng_zmy/article/details/)

[2] Wenliang Du, Syracuse University(2018)Meltdown Attack Lab
  [http://www.cis.syr.edu/~wedu/seed/Labs_16.04/System/Meltdown_Attack](http://www.cis.syr.edu/~wedu/seed/Labs_16.04/System/Meltdown_Attack)

[3] Areej(2020) -Difference between l1 l2 and l3 cache memory

[4] Moritz Lipp,Michael Schwarz,Daniel Gruss Metldown paper
  [https://arxiv.org/pdf/1801.01207.pdf](https://arxiv.org/pdf/1801.01207.pdf)

[5] Jacek Galowicz Metldown paper
  [https://blog.cyberus-technology.de/posts/2018-01-03-meltdown.html](https://blog.cyberus-technology.de/posts/2018-01-03-meltdown.html)

[6] Jann Horn, Project Zero Reading privileged memory with a side channel
  [https://googleprojectzero.blogspot.com/2018/01/reading-privileged-memory-with-side.html](https://googleprojectzero.blogspot.com/2018/01/reading-privileged-memory-with-side.html)

[7] Jake Edge Kernel Address Space Layout Randomization(KASLR)
  [https://lwn.net/Articles/569635/](https://lwn.net/Articles/569635/)

[8] Daniel Gruss,Clementine Maurice, Klaus Wagner, and Stefan Mangard
Flush+Flush:A Fast and Stealthy Cache Attack
  [https://gruss.cc/files/flushflush.pdf](https://gruss.cc/files/flushflush.pdf)

[9] Jann Horn, Project Zero Reading privileged memory with a side channel
  [https://cryptome.org/2018/01/spectre-meltdown.pdf](https://cryptome.org/2018/01/spectre-meltdown.pdf)

[10] Yinqian Zhang Cache Side Channels: State of the Art and Research Oppor tunities
  [http://web.cse.ohio-state.edu/~zhang.834/slides/tutorial17.pdf](http://web.cse.ohio-state.edu/~zhang.834/slides/tutorial17.pdf)
