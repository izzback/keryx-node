# Keryx gRPC protocol

`rpc.proto` and `messages.proto` in this directory are copied byte-for-byte from the Keryx node source used by Poolaris for RPC interoperability. Do not hand-edit protocol field numbers. When Keryx changes its protobuf schema, refresh these files from the matching Keryx release and run the compatibility tests.
