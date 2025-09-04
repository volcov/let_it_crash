# Contributing to LetItCrash

First of all, thank you for considering contributing to LetItCrash! 🎉

This project embraces Elixir's "let it crash" philosophy, and your contribution can help other developers test their supervised systems better.

## How to Contribute

### 🐛 Reporting Bugs

If you found a bug, please open an [issue](https://github.com/volcov/let_it_crash/issues) including:

- **Clear description** of the problem
- **Steps to reproduce** the bug
- **Expected behavior** vs **actual behavior**
- **Elixir version** and **library version**
- **Minimal code example** that reproduces the problem

Example bug report template:
```markdown
**Description**
Clear description of the bug.

**To Reproduce**
1. Set up a supervisor...
2. Crash the process with...
3. Run recovered?...
4. See error...

**Expected Behavior**
What should happen.

**Environment**
- Elixir: 1.17.0
- LetItCrash: 0.1.0
- OTP: 26.0
```

### 💡 Feature Suggestions

Have an idea to improve the library? Open an [issue](https://github.com/volcov/let_it_crash/issues) with:

- **Description of the desired functionality**
- **Use case** that justifies the feature
- **API proposal** (if applicable)
- **Usage examples** of the new functionality

### 🔧 Pull Requests

1. **Fork** the repository
2. **Create a branch** for your feature (`git checkout -b feature/my-feature`)
3. **Implement** your change
4. **Add tests** to cover the new functionality
5. **Run the tests** (`mix test`)
6. **Commit** your changes (`git commit -am 'Add my feature'`)
7. **Push** to the branch (`git push origin feature/my-feature`)
8. **Open a Pull Request**

### 📋 Pull Request Checklist

- [ ] Tests pass (`mix test`)
- [ ] Code follows Elixir style
- [ ] Documentation updated (if necessary)
- [ ] Tests added for new functionality
- [ ] CHANGELOG.md updated (if applicable)

## 🧪 Running Tests

```bash
# Install dependencies
mix deps.get

# Run all tests
mix test

# Run specific test
mix test test/let_it_crash_test.exs:101
```

## 📝 Code Style Standards

- Use **2 spaces** for indentation
- Use descriptive names for functions and variables
- Add **@doc** for public functions
- Add **@spec** for public functions
- Prefer **pattern matching** over conditionals when possible

## 🗂️ Project Structure

```
let_it_crash/
├── lib/
│   └── let_it_crash.ex          # Main module
├── test/
│   ├── let_it_crash_test.exs    # Main tests  
│   └── test_helper.exs          # Test setup
├── README.md                    # Main documentation
├── CONTRIBUTING.md             # This file
├── LICENSE                     # MIT License
└── mix.exs                     # Project configuration
```

## 🎯 Areas That Need Help

Some areas where contributions would be especially welcome:

- **Additional tests** for edge cases
- **Usage examples** with different types of supervisors
- **Performance improvements** in PID tracking
- **CI/CD integration** tooling

## 🤝 Code of Conduct

This project follows a simple code of conduct:

- **Be respectful** to other contributors
- **Be constructive** in feedback and discussions  
- **Be patient** with beginners
- **Be inclusive** and welcoming

## 📞 Questions?

- Open an [issue](https://github.com/volcov/let_it_crash/issues) with the `question` tag
- Contact via GitHub (@volcov)

Thank you for helping make LetItCrash better! 🚀
