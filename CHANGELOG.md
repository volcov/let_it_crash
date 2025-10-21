# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2025-10-21

### Changed (Breaking)
- **Refactored `crash` API** - Following Elixir best practices, removed `crash!/1` function in favor of `crash/2`
  - `crash!/1` has been removed (the `!` suffix is conventionally reserved for functions that raise exceptions)
  - New signature: `crash(process, type \\ :shutdown)` where `type` can be `:shutdown` or `:kill`
  - Follows the same convention as `Process.exit/2` with the process as the first argument
  - Enables easy piping: `Process.whereis(:name) |> LetItCrash.crash(:kill)`
  - `crash(pid)` - default behavior (`:shutdown` signal)
  - `crash(pid, :kill)` - guarantees termination (cannot be trapped)
  - Maintains support for both PID and registered name with automatic PID tracking
  - Tests updated to use the new API

### Migration Guide
- Replace `crash!(process)` with `crash(process, :kill)`
- `crash(process)` continues to work the same way (uses `:shutdown` by default)
- Argument order follows `Process.exit/2`: process first, type second

## [0.2.0] - 2025-10-01

### Added
- **`crash!/1` function** - "Bang" version that uses `:kill` signal for guaranteed process termination
  - Works with processes that have `Process.flag(:trap_exit, true)`
  - Cannot be trapped by the target process
  - Particularly useful for testing GenServers with cleanup logic in `handle_info({:EXIT, ...})`
  - Supports both PID and registered name with automatic PID tracking
  - Complete test suite including `TrapExitServer` demonstration

### Changed
- Updated module documentation to explain the difference between `crash/1` and `crash!/1`
- Enhanced README with "When to use `crash!/1`?" section and practical examples
- Added comparison table between `:shutdown` and `:kill` exit signals

### Technical Details
- `:kill` exit signal bypasses process trapping mechanisms
- Maintains same API signature as `crash/1` for consistency
- Includes integration tests with supervised trap_exit processes

## [0.1.0] - 2025-01-03

### Core Functions
- `crash/1` - Crashes processes by PID or registered name with automatic PID tracking
- `recovered?/1,2,3` - Detects process recovery after crashes with multiple signatures
  - Automatic PID tracking when crashing by name
  - Configurable timeout and interval options
  - Manual PID comparison support
- `test_restart/2,3` - Tests complete crash/recovery workflow by running functions before and after

### Advanced Testing Functions
- `assert_clean_registry/2,3` - Verifies Registry entries are properly cleaned up on crash and recreated on recovery
- `verify_ets_cleanup/2,3` - Monitors ETS table entries for proper cleanup during process crashes
  - Support for `expect_cleanup` and `expect_recreate` options
  - Configurable timeout for verification
  - Detects resource leaks and improper state management

### Development Infrastructure  
- **Code Quality**: Credo static code analysis integration with strict mode (0 issues)
- **CI/CD Pipeline**: GitHub Actions with comprehensive testing
  - Tests on Elixir 1.17.2 + OTP 26.0 
  - Automated formatting, compilation warnings, and Credo checks
  - 15 tests covering all functionality, 0 failures
- **Documentation**: ExDoc integration with HTML output
  - Complete API documentation with practical examples
  - Advanced usage examples for Registry and ETS testing
  - README and CHANGELOG integration

### Technical Features
- ✅ Safe process crashes (automatic unlink to prevent test failures)
- ✅ Real recovery detection via PID comparison
- ✅ Supervised process support (GenServers, Agents, custom processes)
- ✅ Resource cleanup validation (Registry entries, ETS tables)
- ✅ Simple and intuitive API with comprehensive error handling
- ✅ Zero external runtime dependencies
- ✅ Automatic tracking system using ETS for PID management

### Project Setup
- MIT License with complete contribution guidelines
- Project badges for CI status, license, and Elixir compatibility
- Issue and PR templates for community contributions
- Comprehensive test coverage with realistic usage examples

[0.3.0]: https://github.com/volcov/let_it_crash/releases/tag/v0.3.0
[0.2.0]: https://github.com/volcov/let_it_crash/releases/tag/v0.2.0
[0.1.0]: https://github.com/volcov/let_it_crash/releases/tag/v0.1.0
