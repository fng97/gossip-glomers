# Gossip Glomers

My solutions to the [Gossip Glomers](https://fly.io/dist-sys/) distributed systems challenges,
written in Zig. [Maelstrom](https://github.com/jepsen-io/maelstrom) doesn't yet have a Zig client --
if you'd like a head-start using Zig, check out [`Message`](https://github.com/fng97/gossip-glomers/blob/651115fdb0023b7bd3dbd4f7621c6fe43563edb5/src/main.zig#L212-L465).

## Challenges

- [x] 1: Echo
- [x] 2: Unique ID Generation
- 3: Broadcast
  - [x] a: Single-Node Broadcast
  - [x] b: Multi-Node Broadcast
  - [x] c: Fault Tolerant Broadcast
  - [ ] d: Efficient Broadcast, Part I
  - [ ] e: Efficient Broadcast, Part II
- 4: Grow-Only Counter
  - [ ] Grow-Only Counter
- 5: Kafka-Style Log
  - [ ] a: Single-Node Kafka-Style Log
  - [ ] b: Multi-Node Kafka-Style Log
  - [ ] c: Efficient Kafka-Style Log
- 6: Totally-Available Transactions
  - [ ] a: Single-Node, Totally-Available Transactions
  - [ ] b: Totally-Available, Read Uncommitted Transactions
  - [ ] c: Totally-Available, Read Committed Transactions
