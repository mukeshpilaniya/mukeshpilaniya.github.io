
### Process
---
  - Process will have various attributes like
    - Process ID
    - Process State
    - Process Priority
    - Program Counter
    - General purpose register
    - List of open files
    - List of open devices
    - Protection information
    - List of child process
    - Pending alarms
    - Signals and signal handlers
    - Accounting information
  

### Thread
---
  - Thread is a light weight process and an thread will share resources of the process like code, data, global variables, files and memory address space among all the thread within the process but **stack and register** cannot be shared, every thread have it's own stakcs and registers.
  - Advantages of threads
    - Enhanced throughput of system
    - Imporve responsiveness
    - Faster context switching due to less attributes
    - Effetive utilisation of multiprocessor system
    - Resource sharing (Code, Data, Address Space, Files, Global Variables)
  - User level thread also known as green thread, coroutine in C, goroutinr in Go and fiber in Ruby.
  


| Process      | Thread (Kernel Thread) | Goroutine / (User Thread)     |
| :---        |    :----:   |          ---: |
| Program under execution is known as a process. it should reside in the main memory and occupies cpu to execute instructions and should be in active state. | Kernel level thread is a light weight process and implemented by the Operating system| User level thread also light weighted process but implemented by the user/programmer/programming language |
| Context switching time between processes is more and creating a process will take more time. | Context switching time between kernel level thread will take less time than context switching between process also creation of kernel level thread also take less time than creation of a process. | User level thread is having less context switching time and creation of user level thread will take less time than kernel level thread. |
| OS schedular is responsible for scheduling process | The kernel thread scheduler is in charge of scheduling kernel threads. | User/Programming Schedular (Golang schedular) is responsible for shceduling user thread/goroutines. |


> So it's more efficient to create multiple user thread(goroutine ) inside one process as compare to the process creation which is time consuming and resource intensive.

### Go Specific 
---
  - In Go user level thread is known as **Goroutine**.
  - Go has took some decision when creating goroutines
    - Easy to create
    - Lightweight
    - Parallel execution
    - Scalable
    - Handling of blocking calls
      - Sending and Receing on Channel
      - Network IO calls
      - Blocking System calls/ syscalls
      - Timers
      - Mutexes
    - Efficient (work stealing)

> Why Go have a schedular ?  

Go uses user level thread known as **goroutine** , which are lighter and cheaper than kernel level thread. for example creation of initial goroutine will take 2KB of stack size and kernel level thread will take 8KB of stack size. Also goroutine has faster creation, destruction and faster context switches than kernel thread So go schedular needs to exits to schedule goroutine.OS can't schedule user level thread, OS only know about kernel level thread. Go schedular multiplexes goroutines to kernel level threads, which will run on the differnet CPU core.

> When to schedule goroutines ?

If there is any operation that should or would affect goroutine execution like goroutine starting and blocking call etc...
  
> How go schedular will multiplexes goroutines into kernel threads ?

1. 1:1 Scheduling (Thread per goroutine)
      - would work but too expensive.
      - memory at least ~32k (memory for user stack and kernel stacks)
      - performance issues (calling syscall)
      - no infinite stack
2. N:1 Scheduling (Multilex all goroutine on a single kernel thread)
  - no concurrency (if one goroutine is performing blocking all than the thread will block which means all the other goroutine don't get run )
  - no parallelism (can only use a single CPU core, even if more cpur core are available)
  - `example form go in action book`
3. Thread Pool  
  - Create thread when needed which means create a thread if there are goroutine to run but all the other threads are busy.
  - Once the thread complete it's execution rather than distroying reuse it.
  - this can  only faster goroutine creation because we can reuse threads
  - but still more memory consumption, performance issue and no infinite stacks. 
4. M:N Threading Shared Run Queue Schedular
  - M represents number of OS Thread
  - N represents number of goroutine
  - Creation of goroutine is cheap and we can fully control complete lifecycle of goroutine beacuse it's created in user space.
  - Creation of OS thread is expensive and we don't have control over it but using multiple thread we can achieve  parallelism.
  - In this model multiple goroutine is multiplex into kernel threads.
  - Goroutine state
      - Running
      - Runnable
      - Blocked
        - Blocked on the Channel 
        - Mutexes
        - Network IO
        - Timers
        - System Call
  - ` a proper example of block goroutine`
  - `M:N model photo`
  - If a goroutine is blocked on the channel then the channel is having wait Queue and all blocked goroutine is listed on the wait queue and it's easly trackable. After the blocking call they will be placed into global run queue of schedular and OS Thread will again pick goroutine in FIFO order.
  - `channel struct`
  - The same mechanism is used for Mutexes, Timers and Network IO.
  - If a goroutine is blocked on the system call then the situation is differnt because we don't know what is happing in the kernel space. Channels are created in the user space so we have full control over it but in the case of system call we don't have.
  - Blocking system call will block goroutine and underline kernel thread as well.
  - Blocking system call might cause a deadloack situation, let's suppose that all Running goroutine is requires semaphore to execute some task. but the semaphore is already accquired by a runnable goroutine which is in a run queue of global schedular(due to peremption)but we can't schedule that goroutine because we don't have enough os thread to execute a goroutine.This seems to be a common problem for any schedular with the fixed number of OS threads.
  - `deadlock exmaple`
  - Let's suppose that one goroutine is made a syscall which is scheduled on one kernel thread, when the kernel thread is complete is execution it will wake up another kernel thread(thread reuse) that will pick up another goroutine and start executing it.This is a ideal scenario but in real case we don't know how much time syscall will take so we can't relay on the kernel thread to wake up another thread, we need some code level logic which will decide when to wake up another thread in case of syscall. which means number of kernel thread can be more than number of core.
  - When the system call is made to the kernel then it has two decideding points, one is entry point and another one is exit point.
  - `system call struct`

  > How many kernel thread OS can supports ?

  > How many goroutine per program Go can support ?

  > How many kernel thread per program GO can support ?
  - Conclusion
    - Number of kernel thread can be more than number of core. #kernel Thread >#Core
    - [x] lightweight goroutines
    - [x] handling of IO and syscalls
    - [x] parallel executions of goroutine
    - [ ] not scalable (All the kernel level thread try to acess gloabl run queue with mutex enable. So due to **contention** this is not easy to scale)
5. Distributed Run Queue Scheduler  
  To solve the sclable problem where every thread is try to access the mutex at the same time, per thread local run queue is maintained. 
    - Per thread state (local run queue)
    - Still have global run queue  
    
  > What is the next goroutine to run ?  
  
  Go schedular will check in this order to pick next goroutine to execute
  - Local Run Queue
  - Global Run Queue
  - Network Poller
  - Work Stealing

  - Conclusion
    - [x] lightweight goroutines
    - [x] handling of IO and SystemCalls
    - [x] Parallel execution of goroutines
    - [x] Scalable
    - [ ] Efficient (#threads > #cores)

  > If number of thread is more than number of cores than what is the problem ?  

    In distributed run queue schedular we know that each thread is having their own local run queue which contains information about which goroutine going to be execute next. So if the number of threads are greater than number of cores than during the **work stealing** process each thread has to scan all the thread local run queue so if threads are more than thid process is time consuming and the solution is not efficent so we need to limit thread scanning to a constant which is solve using M:P:N threading model.
6. M:P:N Threading  
    - P represented Processor that are resource required to run the go code.
    - Generally number of processor is same as number of **logical Processor**.
    - Processor are created before starting of the main go routine. 
    - During the work stealing only fixed number number of queue has to be checked because number of processors are limited.  
    - Conclusion
      - [x] lightweight goroutines
      - [x] handling of IO and System calls
      - [x] Parallel execution of goroutines
      - [x] Scalable 
      - [x] Efficient/Work stealing