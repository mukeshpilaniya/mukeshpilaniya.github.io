## Solving modern programming challenges with Go

- Development speed
    -  Consequently, many Go applications compile in under a second. The entire Go source tree compiles in under 20 seconds on modern hardware.
    - Writing applications in dynamic languages makes you productive quickly because
there are no intermediate steps between writing code and executing it. The trade-off
is that dynamic languages don’t offer the type safety that static languages do and often
need a comprehensive test suite to avoid discovering incorrect type bugs at runtime
- Concurrency
    - Go’s concurrency support is one of its strongest features. Goroutines are like
threads, but use far less memory and require less code to use. Channels are data structures that let you send typed messages between goroutines with synchronization built
in.
    - Goroutines
        -  In other languages, you’d use threads to accomplish the
same thing, but in Go many goroutines execute on a single thread
        -  In other languages, you’d use threads to accomplish the
same thing, but in Go many goroutines execute on a single thread
![Roroutine](https://github.com/mukeshpilaniya/blog/blob/master/_posts/Golang/images/Screenshot%20from%202022-08-06%2000-35-50.png?raw=true)
    - Channels
        - Channels are data structures that enable safe data communication between goroutines. Channels help you to avoid problems typically seen in programming languages
that allow shared memory access
        - The hardest part of concurrency is ensuring that your data isn’t unexpectedly
modified by concurrently running processes, threads, or goroutines. 
        -  Channels help to enforce the pattern that only one goroutine should modify the data at any time.
        - This safe exchange of data between goroutines requires no other locks or synchronization mechanisms.
- Go's Type System
    - It’s still object-oriented development, but without the traditional headaches.
    -  Go developers simply embed types to reuse functionality in a design pattern
called composition.
    -  Many interfaces in Go’s standard library are
very small, exposing only a few functions. 
    - You don’t even need to
declare that you’re implementing an interface; you just need to write the implementation, You don’t need to declare that you’re implementing, an interface in Go; the compiler does the work of determining whether values of your
types satisfy the interfaces you’re using.
- Memory Management
    -  Go has a modern garbage collector that does the
hard work for you. 
    -  It isn’t
always easy to track a piece of memory when it’s no longer needed; threads and heavy
concurrency make it even harder.
- Summary
    - Go is modern, fast, and comes with a powerful standard library.
    - Go has concurrency built in.
    - Go uses interfaces as the building blocks of code reuse.
