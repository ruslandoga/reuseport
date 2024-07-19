Short demo of SO_REUSEPORT in Elixir.

1. App V1 starts listening on localhost:8000 with SO_REUSEPORT.
2. App V2 also starts listening on localhost:8000 with SO_REUSEPORT.
3. App V1 starts draining, i.e. it stops accepting new connections by closing the listen socket and waits for the old connections to end.
4. App V1 stops.

Please see [tests](./test/reuse_test.exs) for details.
