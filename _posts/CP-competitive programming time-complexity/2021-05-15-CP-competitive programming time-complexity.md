---
published: true
categories: [Competitive Programming, Time Complexity]
tags: [cp]
---

Hello all, when you doing competitive programming or solving any coding questions on coding platform like leetcode, hackerearth or hackerrank then sometime you might be faced TLE error, while submitting your code on online judges. So today, I will talk about how you can train your mind before solving any coding problems and can get rid of TLE error. I'm sharing my personal experiences this might be useful for you, while solving online assessment on hackerrank and hackerearth.

`` For this table construction i have assumed that on average online judge will be able to finished 10^6 Instruction per second.``

| Range of N |                                           Allowed Time Complexity |                                    Most Used tech |
|------------|------------------------------------------------------------------:|--------------------------------------------------:|
| N≤10       |                                                             O(N!) |                                       Brute Force |
| N≤25       |                                                            O(2^N) |                Recursion/Brute force/Backtracking |
| N≤100      |                                                            O(N^4) |                                                   |
| N≤500      |                                                            O(N^3) |                                                   |
| N≤5*10^3   |                                                            O(N^2) | 2D-dp table construction/Brute force-two for loop |
| N≤5*10^5   |                                              O(N√(N)),O(N Log(N)) |                             Sorting/Binary search |
| N≤10^6     |                                                 O(N), O(N Log(N)) |             Prefixarray/Suffixarray/Sorting/1D-dp |
| N≤10^7     | Optimized O(N),Optimized O(N Log(N)), O(N Log(Log(n))), O(Log(N)) |                                                   |
| N≤10^8     |                                                         O(Log(N)) |                                                   |
| N≤10^9     |                                                         O(Log(N)) |                                     Binary Search |
| N≤10^12    |                                                             O(√N) |                                                   |
| N≤10^16    |                                                   Optimized O(√N) |                                       Bit mapping |
| N≤10^18    |                                                         O(Log(N)) |                                       Bit mapping |



