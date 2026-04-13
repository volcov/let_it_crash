# Agents - Project Guidelines

## Elixir Style Preferences

### Control Flow

- **Never nest `case` inside `case`.** Use `with` chains instead to flatten nested pattern matching.
- If a `with` chain is not suitable, extract the inner logic into private helper functions.
- Prefer `with` for sequential operations that depend on previous results.
- Use `cond` for multi-branch conditionals that are not pattern-match dependent.

### General

- Keep functions small and focused on a single responsibility.
- Extract complex logic into well-named private functions rather than deeply nesting control flow.
- Follow standard Elixir formatting conventions (`mix format`).
