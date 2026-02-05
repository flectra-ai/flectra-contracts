# Flectra Protocol

**Trust infrastructure for autonomous robots.**

Flectra provides the foundational smart contracts for establishing verifiable trust in autonomous robot operations. Our protocol enables hardware-bound identity, cryptographic execution attestations, and economic accountability—all on-chain.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Built on Base](https://img.shields.io/badge/Built%20on-Base-0052FF.svg)](https://base.org)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.24-363636.svg)](https://soliditylang.org)

## Overview

As autonomous robots become prevalent across industries—from delivery drones to warehouse automation—a critical question emerges: **How do you verify that a robot actually performed the actions it claims?**

Traditional systems rely on centralized authorities or human oversight. Flectra provides a decentralized alternative through three core primitives:

| Primitive | Contract | Description |
|-----------|----------|-------------|
| **Robot Identity** | `RobotID.sol` | Hardware-bound NFT identity tied to TPM/secure enclave |
| **Execution Attestation** | `AttestationRegistry.sol` | Cryptographic proofs of physical actions |
| **Economic Accountability** | `FlectraStaking.sol` | Stake-based enforcement with automated slashing |

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        FLECTRA PROTOCOL                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────┐    ┌──────────────────┐    ┌───────────────┐  │
│  │  RobotID    │───▶│ AttestationReg   │◀───│ FlectraStaking│  │
│  │   (NFT)     │    │    (Proofs)      │    │   (Stakes)    │  │
│  └─────────────┘    └──────────────────┘    └───────────────┘  │
│        │                    │                      │            │
│        ▼                    ▼                      ▼            │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                   Hardware Layer                         │   │
│  │         TPM / Secure Enclave / HSM Attestation          │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Contracts

### RobotID.sol

ERC-721 NFT representing a robot's on-chain identity, cryptographically bound to physical hardware.

**Key Features:**
- Hardware attestation verification via TPM/secure enclave signatures
- Sybil-resistant by design—each identity requires physical hardware
- Portable reputation across platforms
- Operator management and transfer controls

```solidity
function registerRobot(
    bytes32 hardwareHash,
    bytes memory attestationSignature,
    uint256 stakeAmount
) external returns (uint256 tokenId);
```

### AttestationRegistry.sol

On-chain registry for robot execution attestations with Merkle tree batching for gas efficiency.

**Key Features:**
- Proof of who, what, when, and where for physical actions
- Merkle-batched submissions for high-frequency attestations
- Independent verification by any party
- Trust score computation based on attestation history

```solidity
function submitBatch(
    uint256 robotId,
    bytes32 merkleRoot,
    uint256 attestationCount,
    bytes32 metadataHash,
    bytes memory signature
) external returns (uint256 batchId);
```

### FlectraStaking.sol

Stake management with automated slashing for economic accountability.

**Key Features:**
- Collateral staking for robot registration
- Automated slashing for fraudulent attestations
- Dispute resolution mechanism
- Configurable lock periods and fee distribution

```solidity
function stake(uint256 robotId, uint256 amount) external;
function proposeSlash(uint256 robotId, uint256 amount, string calldata reason) external returns (uint256 proposalId);
```

## Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- [Node.js](https://nodejs.org/) >= 18

### Installation

```bash
# Clone the repository
git clone https://github.com/flectra-ai/flectra-contracts.git
cd flectra-contracts

# Install dependencies
forge install

# Build contracts
forge build

# Run tests
forge test
```

### Configuration

Create a `.env` file:

```env
PRIVATE_KEY=your_private_key
BASESCAN_API_KEY=your_basescan_key
BASE_RPC_URL=https://mainnet.base.org
BASE_SEPOLIA_RPC_URL=https://sepolia.base.org
```

### Deployment

```bash
# Deploy to Base Sepolia (testnet)
forge script script/Deploy.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast --verify

# Deploy to Base Mainnet
forge script script/Deploy.s.sol --rpc-url $BASE_RPC_URL --broadcast --verify
```

## Network Deployments

| Network | RobotID | AttestationRegistry | FlectraStaking |
|---------|---------|---------------------|----------------|
| Base Sepolia | `TBD` | `TBD` | `TBD` |
| Base Mainnet | `TBD` | `TBD` | `TBD` |

## Security

Security is critical for trust infrastructure. Please review our [Security Policy](SECURITY.md).

**Audits:**
- [ ] Audit pending

**Bug Bounty:**
- Coming soon

If you discover a vulnerability, please report it responsibly. See [SECURITY.md](SECURITY.md) for details.

## Documentation

- [Architecture Overview](docs/ARCHITECTURE.md)
- [Robot Identity](docs/ROBOT_ID.md)
- [Attestation System](docs/ATTESTATIONS.md)
- [Staking & Slashing](docs/STAKING.md)
- [Integration Guide](docs/INTEGRATION.md)

## Contributing

We welcome contributions! Please read our [Contributing Guidelines](CONTRIBUTING.md) before submitting PRs.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Links

- **Website:** [flectra.xyz](https://flectra.xyz)
- **Documentation:** [docs.flectra.xyz](https://docs.flectra.xyz) *(coming soon)*
- **Twitter:** [@flectra_xyz](https://twitter.com/flectra_xyz)

---

Built with ❤️ for the future of autonomous robotics.
