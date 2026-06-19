package protocol

// Version is the wire-protocol version; bump on any breaking change so
// the client can surface "rebuild your sidecar" instead of undefined behaviour.
const Version = 1

// Binary is the sidecar build version reported in the hello handshake.
const Binary = "0.1.0"
