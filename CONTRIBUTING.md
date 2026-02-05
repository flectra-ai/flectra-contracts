# Contributing to Flectra

Thank you for your interest in contributing to Flectra! This document provides guidelines for contributing to the project.

## Code of Conduct

By participating in this project, you agree to maintain a respectful and inclusive environment for everyone.

## How to Contribute

### Reporting Bugs

1. Check if the bug has already been reported in [Issues](https://github.com/flectra-ai/flectra-contracts/issues)
2. If not, create a new issue with:
   - Clear, descriptive title
   - Steps to reproduce
   - Expected vs actual behavior
   - Environment details (Solidity version, network, etc.)

### Suggesting Features

1. Open an issue with the `enhancement` label
2. Describe the feature and its use case
3. Explain why it would benefit the protocol

### Submitting Changes

1. **Fork** the repository
2. **Create a branch** for your feature: `git checkout -b feature/your-feature-name`
3. **Write tests** for your changes
4. **Ensure all tests pass**: `forge test`
5. **Follow code style** guidelines (see below)
6. **Commit** with clear messages
7. **Push** to your fork
8. **Open a Pull Request**

## Development Setup

```bash
# Clone your fork
git clone https://github.com/YOUR_USERNAME/flectra-contracts.git
cd flectra-contracts

# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Install dependencies
forge install

# Build
forge build

# Test
forge test

# Test with verbosity
forge test -vvv

# Gas report
forge test --gas-report
```

## Code Style

### Solidity

- Use Solidity 0.8.24
- Follow [Solidity Style Guide](https://docs.soliditylang.org/en/latest/style-guide.html)
- Use NatSpec comments for all public functions
- Order contract elements:
  1. State variables
  2. Events
  3. Errors
  4. Modifiers
  5. Constructor
  6. External functions
  7. Public functions
  8. Internal functions
  9. Private functions

### Naming Conventions

- Contracts: `PascalCase`
- Functions: `camelCase`
- Variables: `camelCase`
- Constants: `SCREAMING_SNAKE_CASE`
- Events: `PascalCase`
- Errors: `PascalCase`

### Example

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ExampleContract
 * @notice Brief description of what the contract does
 * @dev Technical details for developers
 */
contract ExampleContract {
    // ============ Constants ============
    uint256 public constant MAX_VALUE = 1000;

    // ============ State Variables ============
    uint256 public value;

    // ============ Events ============
    event ValueUpdated(uint256 indexed oldValue, uint256 indexed newValue);

    // ============ Errors ============
    error ValueTooHigh(uint256 provided, uint256 maximum);

    // ============ Constructor ============
    constructor(uint256 _initialValue) {
        value = _initialValue;
    }

    // ============ External Functions ============

    /**
     * @notice Updates the stored value
     * @param _newValue The new value to store
     */
    function updateValue(uint256 _newValue) external {
        if (_newValue > MAX_VALUE) {
            revert ValueTooHigh(_newValue, MAX_VALUE);
        }
        uint256 oldValue = value;
        value = _newValue;
        emit ValueUpdated(oldValue, _newValue);
    }
}
```

## Testing

- Write tests for all new functionality
- Aim for high test coverage
- Include both positive and negative test cases
- Test edge cases and boundary conditions

```bash
# Run all tests
forge test

# Run specific test
forge test --match-test testFunctionName

# Run with coverage
forge coverage
```

## Pull Request Process

1. Update documentation if needed
2. Add tests for new functionality
3. Ensure CI passes
4. Request review from maintainers
5. Address review feedback
6. Maintainer will merge once approved

## Questions?

Open an issue with the `question` label or reach out on [Twitter](https://twitter.com/flectra_xyz).

---

Thank you for contributing to Flectra!
