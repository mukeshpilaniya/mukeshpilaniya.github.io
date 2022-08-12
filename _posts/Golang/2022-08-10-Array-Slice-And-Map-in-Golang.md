1. Array 
    - Array Internals and fundamentals
        - An array in Go is a fixed-length data type that contains a contiguous block of elements
    of the same type.
        - Arrays are valuable data structures because the memory is allocated sequentially. 
        - Having memory in a contiguous form can help to keep the memory you use stay loaded
    within CPU caches longer.
        - An array is a value in Go. This means you can use it in an assignment operation. The
variable name denotes the entire array and, therefore, an array can be assigned to
other arrays of the same type. 
        - When an array is initialized in Go, each
individual element that belongs to the array is initialized to its zero value.
![array](https://github.com/mukeshpilaniya/blog/blob/master/_posts/Golang/images/array.png?raw=true)
    - Declaring and Initializing
        - Declare an integer array of five elements  
            `var array [5]int` 
        - Array literals allow you to declare the number of elements you need and specify values for those
elements  
        - Declaring and Initialize an array using an array literal  
            `array := [5]int{10, 20, 30, 40, 50}`
        - Declaring and Initialize an array with Go calculating size  
            `array := [...]int{10, 20, 30, 40, 50}`
        - Declaring an array initializing specific elements  
            `array := [5]int{1: 10, 2: 20}`
        - Declaring two-dimensional arrays  
            `var array [4][2]int`
    - Passing arrays between functions
        - Passing an array between functions can be an expensive operation in terms of memory and performance. 
        - When your variable is an array, this means the entire array, regardless
of its size, is copied and passed to the function.
2. Slice 
    - Slice internals and fundamentals
        - Slices are built around the concept of dynamic arrays that can grow and
shrink 
        - They’re three field data structures that contain the metadata. The three fields are a pointer to the underlying array, the length or the number of elements the slice has access to, and the capacity or the number of elements the slice has
available for growth. 
        - Remember, if you specify a value inside the [ ] operator, you’re creating an array. If
you don’t specify a value, you’re creating a slice.
            - Create an array of three integers.  
                `array := [3]int{10, 20, 30}`
            -  Create a slice of integers with a length and capacity of three.  
                `slice := []int{10, 20, 30}`
![Slice](https://github.com/mukeshpilaniya/blog/blob/master/_posts/Golang/images/slice.png?raw=true)
    - Creating and Initializing
        - When you use make, one
option you have is to specify the length of the slice.
        - Declaring a slice of strings by length  
            `slice := make([]string, 5)`
        - Declaring a slice of integers by length and capacity  
            `slice := make([]int, 3, 5)`  
            Contains a length of 3 and has a capacity of 5 elements. Trying to create a slice with a capacity that’s smaller than the length is not allowed
        - Declaring a slice with a slice literal  
            `slice := []string{"Red", "Blue", "Green", "Yellow", "Pink"}`
    - NIL and empty slices
        - Declaring an nil slice.  
            `var slice []int`  
             A nil slice is created
by declaring a slice without any initialization.
![Nil Slice ](https://github.com/mukeshpilaniya/blog/blob/master/_posts/Golang/images/nil_slice.png?raw=true)
        - Declaring an empty slice  
            `slice := make([]int, 0)`  
            `slice := []int{}`  
![empty Slice](https://github.com/mukeshpilaniya/blog/blob/master/_posts/Golang/images/empty_slice.png?raw=true)
        - NIL useful when you want to represent a slice that doesn’t exist, such as when an exception
occurs in a function that returns a slice.
        - Empty slices are useful when you want to represent an empty collection, such as when
a database query returns zero results .
        - Regardless of whether you’re using a nil slice or an empty slice, the built-in functions
append, len, and cap work the same.
    - Working with slices
        - Slices are called such because you can slice a portion of the underlying array to create
a new slice.
            ```
            slice := []int{10, 20, 30, 40, 50}
            newSlice := slice[1:3]
            ```
            Changes made to the shared section of the underlying array by one slice can be
seen by the other slice.
            ![newSlice](https://github.com/mukeshpilaniya/blog/blob/master/_posts/Golang/images/working_with_slice.png?raw=true)
        - Calculating Length and Capacity of Slice  
            For slice[i:j:k] or [2:3:4]  
            Length: j - i or 3 - 2 = 1  
            Capacity: k - i or 4 - 2 = 2
        - To use append, you need a source slice and a value that is to be appended. When
your append call returns, it provides you a new slice with the changes.The append function will always increase the length of the new slice. 
            ```go
            func main() {
                slice := []int{10,20,30,40,50}
                newSlice := slice[1:3]
                fmt.Println(slice)
                fmt.Println(newSlice)
                newSlice =append(newSlice,60)
                fmt.Println(slice)
                fmt.Println(newSlice)
            }
            [10 20 30 40 50]
            [20 30]
            [10 20 30 60 50]
            [20 30 60]
            ```
            Because there was available capacity in the underlying array for newSlice, the
append operation incorporated the available element into the slice’s length and
assigned the value. Since the original slice is sharing the underlying array, slice also changed.
![Slice Changed](https://github.com/mukeshpilaniya/blog/blob/master/_posts/Golang/images/slice_changes.png?raw=true)
        - When there’s no available capacity in the underlying array for a slice, the append function will create a new underlying array, copy the existing values that are being referenced, and assign the new value  
            ```go
            func main() {
                slice := []int{10,20,30,40}
                newSlice :=append(slice,60)
                fmt.Println(slice)
                fmt.Println(newSlice)
            }
            [10 20 30 40]
            [10 20 30 40 60]
            ```
            ![Slice not Changed](https://github.com/mukeshpilaniya/blog/blob/master/_posts/Golang/images/slice_not_changed.png?raw=true)
        - By having the option to set the capacity of a new slice to be the same as the length,
you can force the first append operation to detach the new slice from the underlying
array. Detaching the new slice from its original source array makes it safe to change.
            - newSlice len=1 and capacity=2
                ```go
                func main() {
                    slice := []string{"Apple", "Orange", "Plum", "Banana", "Grape"}
                    newSlice :=slice[2:3:4]
                    fmt.Println(slice)
                    fmt.Println(newSlice)
                    newSlice =append(newSlice,"mango")
                    fmt.Println(slice)
                    fmt.Println(newSlice)
                }
                [Apple Orange Plum Banana Grape]
                [Plum]
                [Apple Orange Plum mango Grape]
                [Plum mango]
                ```
            - newSlice len=1 and capacity=1
                ```go
                func main() {
                    slice := []string{"Apple", "Orange", "Plum", "Banana", "Grape"}
                    newSlice :=slice[2:3:3]
                    fmt.Println(slice)
                    fmt.Println(newSlice)
                    newSlice =append(newSlice,"mango")
                    fmt.Println(slice)
                    fmt.Println(newSlice)
                }
                [Apple Orange Plum Banana Grape]
                [Plum]
                [Apple Orange Plum Banana Grape]
                [Plum mango]
                ```
    - Iterating over slices
        - Go has a special keyword
called range that you use in conjunction with the keyword for to iterate over slices.
            ```go
            //Create a slice of integers.
            // Contains a length and capacity of 4 elements.
            slice := []int{10, 20, 30, 40}
            
            // Iterate over each element and display each value.
            for index, value := range slice {
                fmt.Printf("Index: %d Value: %d\n", index, value)
            }
            ```
        - The first value
is the index position and the second value is a copy of the value in that index position. It’s important to know that range is making a copy of the value, not returning a reference
![range loop](https://github.com/mukeshpilaniya/blog/blob/master/_posts/Golang/images/range_value_copy.png?raw=true)
        - If you don’t need the index value, you can use the underscore character to discard
the value.
            ```go
            // Create a slice of integers.
            // Contains a length and capacity of 4 elements.
            slice := []int{10, 20, 30, 40}
            
            // Iterate over each element and display each value.
            for _, value := range slice {
                fmt.Printf("Value: %d\n", value)
            }
            ```
        - The keyword range will always start iterating over a slice from the beginning. If you
need more control iterating over a slice, you can always use a traditional for loop.
            ```go
            // Create a slice of integers.
            // Contains a length and capacity of 4 elements.
            slice := []int{10, 20, 30, 40}
            
            // Iterate over each element starting at element 3.
            for index := 2; index < len(slice); index++ {
                fmt.Printf("Index: %d Value: %d\n", index, slice[index])
            }
            ```
    - Passing slices between functions
        - Passing a slice between two functions requires nothing more than passing the slice by value.Since the size of a slice(address, Length, Capacity) is small, it’s cheap to copy and pass between functions.
        - The data associated with a slice is contained in the underlying array, there are no problems passing a copy of a slice to any function. Only the slice is being copied, not the
underlying array 
            ```go
            slice := make([]int, 1e6)
            // Pass the slice to the function foo.
            slice = foo(slice)
            
            // Function foo accepts a slice of integers and returns the slice back.
            func foo(slice []int) []int {
                //code logic 
                return slice
            }
            ```
            ![Slice passing to func](https://github.com/mukeshpilaniya/blog/blob/master/_posts/Golang/images/slice_pass_func.png?raw=true)
        - On a 64-bit architecture, a slice requires 24 bytes of memory while passing to functions.The pointer field
requires 8 bytes, and the length and capacity fields require 8 bytes respectively
3. Map
    - Map internals and fundamentals
        - A map is a data structure that provides you with an unordered collection of key/value pairs.
        - The strength of a map is its ability to
retrieve data quickly based on the key. A key works like an index, pointing to the value
you associate with that key.
        - Maps are unordered collections, and there’s no way to predict the order in
which the key/value pairs will be returned, this is
because a map is implemented using a hash table.
    - Creating and Initializing
        -  You can use the builtin function make, or you can use a map literal.
        - Declaring a map  
            `var mp map[string]int`
        - Declaring and Initializing a map using make  
            `mp := make(map[string]int)`
        - Delcaring and Initializing a map using literal  
            `mp := map[string]string{"Red": "#da1337", "Orange": "#e95a22"}`
        -  Slices, functions, and struct types that
contain slices can’t be used as map keys.   
            `dict := map[[]string]int{}` // compiler error
        - There’s nothing stopping you from using a slice as a map value.  
            `dict := map[int][]string{}`
    - Working with maps
        - Assiging values to a map
            ```go
            // Create an empty map to store colors and their color codes.
            colors := map[string]string{}
            
            // Add the Red color code to the map.
            colors["Red"] = "#da1337"
            ```
        - Runtime error assigned to a nil map
            ```go
            // Create a nil map by just declaring the map.
            var colors map[string]string
            
            // Add the Red color code to the map.
            colors["Red"] = "#da1337"
            
            Runtime Error:
            panic: runtime error: assignment to entry in nil map
            ```
        - Retrieving a value from a map and testing existence.
            ```go
            // Retrieve the value for the key "Blue".
            value, exists := colors["Blue"]
            
            // Did this key exist?
            if exists {
                fmt.Println(value)
            }
            ```
        - **Wrong way of checking existence of Key**
            ```go
            // Retrieve the value for the key "Blue".
            value := colors["Blue"]
            
            // Did this key exist?
            if value != "" {
                fmt.Println(value)
            }
            ```
            When you index a map in Go, it will always return a value, even when the key doesn’t
exist. In this case, the zero value for the value’s type is returned.
        - Iterating over a map using for range
            ```go
            // Create a map of colors and color hex codes.
                colors := map[string]string{
                "AliceBlue": "#f0f8ff",
                "Coral": "#ff7F50",
                "DarkGray": "#a9a9a9",
                "ForestGreen": "#228b22",
            }
            // Display all the colors in the map.
            for key, value := range colors {
                fmt.Printf("Key: %s Value: %s\n", key, value)
            }
            ```
        - Removing an item from a map  
            `delete(colors, "Coral")`
    - Passing maps between functions
        - Passing a map between two functions doesn’t make a copy of the map. 
        - you can
pass a map to a function and make changes to the map, and the changes will be
reflected by all references to the map.
            ```go
            func main() {
                mp :=map[int]int{
                    10:1,
                    20:2,
                    30:3,
                    40:4,
                    50:5,
                }
                fmt.Println(mp)
                removeKey(mp,20)
                fmt.Println(mp)
            }

            func removeKey(mp map[int]int, key int){
                delete(mp,key)
            }

            output:-
            map[10:1 20:2 30:3 40:4 50:5]
            map[10:1 30:3 40:4 50:5]
            ```
        
4. Summary
    - Arrays are the building blocks for both slices and maps.
    - Slices are the idiomatic way in Go you work with collections of data. Maps are
the way you work with key/value pairs of data.
    - The built-in function make allows you to create slices and maps with initial
length and capacity. Slice and map literals can be used as well and support setting initial values for use.
    - Slices have a capacity restriction, but can be extended using the built-in function append.
    - Maps don’t have a capacity or any restriction on growth.
    - The built-in function len can be used to retrieve the length of a slice or map.
    - The built-in function cap only works on slices.
    - Through the use of composition, you can create multidimensional arrays and
slices. You can also create maps with values that are slices and other maps. A
slice can’t be used as a map key.
    - Passing a slice or map to a function is cheap and doesn’t make a copy of the
underlying data structure.