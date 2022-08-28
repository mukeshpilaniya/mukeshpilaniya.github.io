
---
### Process
---
  - Process contains common resources that may be allocated
by any process. These resources include but are not limited to a memory address
space, handles to files, devices, and threads. 
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

--- 
### Thread
---
  - Thread is a light weight process and an thread will share resources of the process like code, data, global variables, files and memory address space among all the thread within the process but **stack and register** cannot be shared, every thread have it's own stakcs and registers.
  - Advantages of threads
    - Enhanced throughput of system
    - Imporve responsiveness
    - Faster context switching due to less attributes
    - Effetive utilisation of multiprocessor system
    - Resource sharing (Code, Data, Address Space, Files, Global Variables)
  - User level thread also known as green thread, coroutine in C, **goroutine in Go** and fiber in Ruby.

| Process | Thread (Kernel Thread) | Goroutine / (User Thread) |
| :--- | :----: | ---: |
| Program under execution is known as a process. it should reside in the main memory and occupies cpu to execute instructions and should be in active state. | Kernel level thread is a light weight process and implemented by the Operating system| User level thread also light weighted process but implemented by the user/programmer/programming language |
| Context switching time between processes is more and creating a process will take more time. | Context switching time between kernel level thread will take less time than context switching between process also creation of kernel level thread also take less time than creation of a process. | User level thread is having less context switching time and creation of user level thread will take less time than kernel level thread. |
| OS schedular is responsible for scheduling process | The kernel thread scheduler is in charge of scheduling kernel threads. | User/Programming Schedular (Golang schedular) is responsible for shceduling user thread/goroutines. |

![Process_vs_Thread](https://github.com/mukeshpilaniya/blog/blob/master/_posts/Golang/images/process_vs_thread.png?raw=true)
> So it's more efficient to create multiple user thread(goroutine ) inside one process as compare to the process creation which is time consuming and resource intensive.

---
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
      - Parallel execution (each thread can run on different core)
      - would work but too expensive.
      - memory at least ~32k (memory for user stack and kernel stacks)
      - performance issues (calling syscall)
      - no infinite stack
2. N:1 Scheduling (Multilex all goroutine on a single kernel thread)
   - no concurrency (if one goroutine is performing blocking all than the thread will block which means all the other goroutine don't get run )
   - no parallelism (can only use a single CPU core, even if more cpu core are available)  

    ```go
    package main

    import (
      "fmt"
      "runtime"
      "sync"
    )

    func main(){
      // Allocate 1 logical processor for the scheduler to use.
      runtime.GOMAXPROCS(1)
      var wg sync.WaitGroup
      wg.Add(2)

      fmt.Println("Starting Goroutines")

      // Declare an anonymous function and create a goroutine.
      go func(){
        // Schedule the call to Done to tell main we are done.
        defer wg.Done()
        // Display the alphabet 3 times
          for count:=0;count<3;count++{
              for ch:='a';ch <'a'+26;ch++{
                  fmt.Printf("%c ",ch)
              }
              fmt.Println()
          }
      }()
        
      // Declare an anonymous function and create a goroutine.
      go func(){
        // Schedule the call to Done to tell main we are done.
        defer wg.Done()
        // Display the numbers 3 times
          for count:=0;count<3;count++{
              for n:=1;n <=26;n++{
                  fmt.Printf("%d ",n)
              }
              fmt.Println()
          }
      }()
        
      // Wait for the goroutines to finish.
      fmt.Println("Waiting To Finish")
      wg.Wait()
      fmt.Println("\nTerminating Program")
    }

    > go run main.go
    Starting Goroutines
    Waiting To Finish
    1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 
    1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 
    1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 
    a b c d e f g h i j k l m n o p q r s t u v w x y z 
    a b c d e f g h i j k l m n o p q r s t u v w x y z 
    a b c d e f g h i j k l m n o p q r s t u v w x y z 

    Terminating Program
    ```
  
   - At line 18 and 31 both functions are created as goroutines by the keyword go. You can see by the output that the code inside each goroutine is running concurrently within a single logical processor. Well you can question by seeing the output of this program they are running one after another, so then how it's running in concurrent mannar.

   > If we set rumtime.GOMAXPROCS() value to 1 than does my program run concurrently ?

   - Let's consider the same program with time.Sleep func inside the goroutine, which will force go schedular to shcedular another goroutine when first one is blocked.  

    ```go
    package main

    import (
      "fmt"
      "runtime"
      "sync"
      "time"
    )

    func main(){
      // Allocate 1 logical processor for the scheduler to use.
      runtime.GOMAXPROCS(1)
      var wg sync.WaitGroup
      wg.Add(2)

      fmt.Println("Starting Goroutines")

      // Declare an anonymous function and create a goroutine.
      go func(){
        // Schedule the call to Done to tell main we are done.
        defer wg.Done()
        // Display the alphabet 3 times
          for count:=0;count<3;count++{
              if count==1{
                  time.Sleep(10*time.Second)
              }
              for ch:='a';ch <'a'+26;ch++{
                  fmt.Printf("%c ",ch)
              }
              fmt.Println()
          }
      }()
        
      // Declare an anonymous function and create a goroutine.
      go func(){
        // Schedule the call to Done to tell main we are done.
        defer wg.Done()
        // Display the numbers 3 times
          for count:=0;count<3;count++{
              if count==0{
                  time.Sleep(5*time.Second)
              }
              if count==2{
                  time.Sleep(7*time.Second)
              }
              for n:=1;n <=26;n++{
                  fmt.Printf("%d ",n)
              }
              fmt.Println()
          }
      }()
        
      // Wait for the goroutines to finish.
      fmt.Println("Waiting To Finish")
      wg.Wait()
      fmt.Println("\nTerminating Program")
    }

    > go run main2.go 
    Starting Goroutines
    Waiting To Finish
    a b c d e f g h i j k l m n o p q r s t u v w x y z 
    1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 
    1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 
    a b c d e f g h i j k l m n o p q r s t u v w x y z 
    a b c d e f g h i j k l m n o p q r s t u v w x y z 
    1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 

    Terminating Program
    ```

    - Here you can see even if we set runtime.GOMAXPROCS(1) to 1, the program is running concurrently.
    - Number of Goroutine in Running sate can be max at 1, Block Goroutine can be more than one and all other Goroutine are in Runnable state.

3. Thread Pool  
   - Create thread when needed which means create a thread if there are goroutine to run but all the other threads are busy.
   - Once the thread complete it's execution rather than distroying reuse it.
   - this can  only faster goroutine creation because we can reuse threads
   - but still more memory consumption, performance issue and no infinite stacks. 

4. M:N Threading Shared Run Queue Schedular
   - M represents number of OS Thread
   - N represents number of goroutine
   - Creation of goroutine is cheap and we can fully control complete lifecycle of goroutine beacuse it's created in user space.
   - Creation of OS thread is expensive and we don't have control over it but using multiple thread we can achieve parallelism.
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
   - Blocked Goroutine example

   ```go
    package main

    import (
        "time"
        "fmt"
        "sync"
        "os"
        "net/http"
        "io/ioutil"
    )

    // Global worker variable
    var worker int

    func writeToFile(wg *sync.WaitGroup,){
        defer wg.Done()
        
        file, _ := os.OpenFile("file.txt", os.O_RDWR|os.O_CREATE, 0755)             // Blocking System Call
        resp, _ := http.Get("https://mukeshpilaniya.github.io/posts/Go-Schedular/") // Blocking Network IO Call
        body, _ := ioutil.ReadAll(resp.Body)                                        // Blocking System Call

        file.WriteString(string(body))
    }

    func workerCount(wg *sync.WaitGroup, m *sync.Mutex, ch chan string) { 
        // Lock() the mutex to ensure 
        // exclusive access to the state, 
        // increment the value,
        // Unlock() the mutex
        m.Lock()                                                                    // Blocked On Mutex
        worker = worker + 1
        ch <- fmt.Sprintf("Worker %d is ready",worker)
        m.Unlock()
      
        // On return, notify the 
        // WaitGroup that we’re done.
        wg.Done()
    }

    func printWorker(wg *sync.WaitGroup, done chan bool, ch chan string){
        
        for i:=0;i<100;i++{
            fmt.Println(<-ch)                                               // Blocked On Channel
        }
        wg.Done()
        done <-true
    }

    func main() {
        
        // Creating Channel
        ch :=make(chan string)
        done :=make(chan bool)
        
        // This mutex will synchronize access to state
        var mu sync.Mutex
        
        // This WaitGroup is used to wait for 
        // all the goroutines launched here to finish.
        var wg sync.WaitGroup
        
        for i:=1;i<=100;i++{
            wg.Add(1)
            go workerCount(&wg,&mu,ch)
        }
        
        wg.Add(2)
        go writeToFile(&wg)
        go printWorker(&wg,done,ch)
        
        // Waiting for program to Finish
        wg.Wait()
        
        <-done                                                             // Blocked On Channel
        
        <-time.After(1*time.Second)                                        //Blocked On Timer
        close(ch)
        close(done)
    }
   ```

   - In line number 18 and 20 Goroutine is blocked on System call, in line 19 blocked on network IO call, in line 30 blocked on mutex, in line 43 and 74 blocked on channel and in line 76 it's blocked on timer. Now we will look how goschedular will work in these cases.
  
   - If a goroutine is blocked on the channel then the channel is having wait Queue(line 10) and all blocked goroutine is listed on the wait queue and it's easly trackable. After the blocking call they will be placed into global run queue of schedular and OS Thread will again pick goroutine in FIFO order.

   ```go
    type hchan struct {
      qcount   uint           // total data in the queue
      dataqsiz uint           // size of the circular queue
      buf      unsafe.Pointer // points to an array of dataqsiz elements
      elemsize uint16
      closed   uint32
      elemtype *_type // element type
      sendx    uint   // send index
      recvx    uint   // receive index
      recvq    waitq  // list of recv waiters
      sendq    waitq  // list of send waiters
    
      // lock protects all fields in hchan, as well as several
      // fields in sudogs blocked on this channel.
      //
      // Do not change another G's status while holding this lock
      // (in particular, do not ready a G), as this can deadlock
      // with stack shrinking.
      lock mutex
    }
   ```

    ![Goroutiine Block On Channel](https://github.com/mukeshpilaniya/blog/blob/master/_posts/Golang/images/shared_queue_channel.gif?raw=true)
   - The same mechanism is used for Mutexes, Timers and Network IO.
   - If a goroutine is blocked on the system call then the situation is differnt because we don't know what is happing in the kernel space. Channels are created in the user space so we have full control over it but in the case of system call we don't have.
   - Blocking system call will block goroutine and underline kernel thread as well.
   - Let's suppose that one goroutine is made a syscall which is scheduled on one kernel thread, when a kernel thread is complete is execution it will wake up another kernel thread(thread reuse) that will pick up another goroutine and start executing it.This is a ideal scenario but in real case we don't know how much time syscall will take so we can't relay on the kernel thread to wake up another thread, we need some **code level logic** which will decide when to wake up another thread in case of syscall. This logic is implemented in golang as runtime·entersyscall()(line 2) and runtime·exitsyscall() (line 18). which means number of kernel thread can be more than number of core.
   - System call code snippet of golang 1.19 https://cs.opensource.google/go/go/+/refs/tags/go1.19:src/syscall/asm_linux_arm.s;l=18
    
   ```sh
    TEXT ·seek(SB),NOSPLIT,$0-28
      BL	runtime·entersyscall(SB)
      MOVW	$SYS__LLSEEK, R7	// syscall entry
      MOVW	fd+0(FP), R0
      MOVW	offset_hi+8(FP), R1
      MOVW	offset_lo+4(FP), R2
      MOVW	$newoffset_lo+16(FP), R3
      MOVW	whence+12(FP), R4
      SWI	$0
      MOVW	$0xfffff001, R6
      CMP	R6, R0
      BLS	okseek
      MOVW	$0, R1
      MOVW	R1, newoffset_lo+16(FP)
      MOVW	R1, newoffset_hi+20(FP)
      RSB	$0, R0, R0
      MOVW	R0, err+24(FP)
      BL	runtime·exitsyscall(SB)
      RET
    ```
   - When the system call is made to the kernel then it has two decideding points, one is entry point and another one is exit point.
    ![Goroutine Blocked on SysCall](https://github.com/mukeshpilaniya/blog/blob/master/_posts/Golang/images/shared_queue_syscall.gif?raw=true)

   > How many kernel thread OS can supports ?

   > How many goroutine per program Go can support ?

   > How many kernel thread per program GO can support ?
   - Conclusion
     - Number of kernel thread can be more than number of core. #kernel Thread >#Core
     - [x] lightweight goroutines
     - [x] handling of IO and syscalls
     - [x] parallel executions of goroutine
     - [ ] scalable (All the kernel level thread try to acess gloabl run queue with mutex enable. So due to **contention** this is not easy to scale)

5. M:N Threading Distributed Run Queue Scheduler  
   To solve the sclable problem where every thread is try to access the mutex at the same time, per thread local run queue is maintained. 
    - Per thread state (local run queue)
    - Still have global run queue  
    ![Distributed Run Queue](https://github.com/mukeshpilaniya/blog/blob/master/_posts/Golang/images/distributed_queue.gif?raw=true)
    
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
   - During the work stealing only fixed number number of queue has to be scan because number of logical processors are limited.
   - `work stealing`
   - `photo`  
   - Conclusion
     - [x] lightweight goroutines
     - [x] handling of IO and System calls
     - [x] Parallel execution of goroutines
     - [x] Scalable 
     - [x] Efficient/Work stealing
