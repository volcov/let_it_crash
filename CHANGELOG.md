# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2025-01-03

### Added
- `crash/1` function to crash processes by PID or registered name
- `recovered?/1,2,3` function to check recovery of supervised processes
  - Multiple signatures supported
  - Automatic PID tracking when crashing by name
  - Configurable timeout and interval options
- `test_restart/2,3` function to test behavior before and after crashes
- Automatic tracking system using ETS table
- Safe link handling to prevent test process crashes
- Complete documentation with practical examples
- Comprehensive tests (10 tests covering all use cases)
- MIT License
- Contributing guide
- README with working examples

### Features
- ✅ Safe process crashes (automatic unlink)
- ✅ Real recovery detection via PID comparison
- ✅ Supervised process support
- ✅ Simple and intuitive API
- ✅ No external dependencies
- ✅ Works with GenServers, Agents, and custom processes

### Documentation
- README with tested practical examples
- Complete inline documentation (@doc and @spec)
- Detailed contribution guide
- Templates for issues and PRs

[Unreleased]: https://github.com/volcov/let_it_crash/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/volcov/let_it_crash/releases/tag/v0.1.0
