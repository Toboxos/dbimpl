# Database Implementation

A study project following the course "Implementation of Database Systems" at LMU Munich, implementing various components of a database system from scratch in Zig.

## Overview

This project aims to build a simple but functional database system by implementing fundamental database components. The implementation is written entirely in Zig, focusing on understanding the core concepts of database systems through hands-on development.

### Components

- **Buffer Manager**: Buffer pool management for managing loading pages into memory.

## Building the Project

### Using Zig

Requirements:
- Zig compiler

```bash
# Build the project
zig build

# Run main application (currently only tests)
./zig-out/bin/dbimpl

# Run benchmarks
./zig-out/bin/benchmark
```

### Using Nix
The repo is configured that every target can be built and packaged via nix:

```bash
# Enter development shell
nix develop

# Build the main executable
nix build

# Run the executable
./result/bin/dbimpl

# Build and run benchmarks
nix build .#benchmark
nix run .#benchmark
```

