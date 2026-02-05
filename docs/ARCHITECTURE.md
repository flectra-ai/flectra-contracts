# Flectra Protocol Architecture

## Overview

Flectra is a trust infrastructure protocol for autonomous robots, providing three core primitives that work together to enable verifiable, trustless robot operations.

## System Architecture

```
                                    ┌──────────────────┐
                                    │   Robot Fleet    │
                                    │  (Physical Layer)│
                                    └────────┬─────────┘
                                             │
                                    ┌────────▼─────────┐
                                    │   Flectra SDK    │
                                    │ (Robot Software) │
                                    └────────┬─────────┘
                                             │
           ┌─────────────────────────────────┼─────────────────────────────────┐
           │                                 │                                 │
           │                    FLECTRA PROTOCOL (On-Chain)                    │
           │                                 │                                 │
           │    ┌────────────────────────────┼────────────────────────────┐   │
           │    │                            │                            │   │
           │    ▼                            ▼                            ▼   │
           │ ┌──────────┐            ┌───────────────┐            ┌─────────┐ │
           │ │ RobotID  │◀──────────▶│  Attestation  │◀──────────▶│ Staking │ │
           │ │  (NFT)   │            │   Registry    │            │         │ │
           │ └──────────┘            └───────────────┘            └─────────┘ │
           │                                                                   │
           └───────────────────────────────────────────────────────────────────┘
                                             │
                                    ┌────────▼─────────┐
                                    │  Base Blockchain │
                                    │   (Ethereum L2)  │
                                    └──────────────────┘
```

## Core Contracts

### 1. RobotID (Identity Layer)

**Purpose:** Establish unique, hardware-bound identities for robots.

**Key Mechanisms:**
- ERC-721 NFT representing robot identity
- Hardware attestation verification (TPM/secure enclave)
- Reputation score tracking
- Operator management

**Data Model:**
```solidity
struct Robot {
    address operator;           // Robot operator address
    bytes32 hardwareHash;       // Hash of hardware attestation
    uint256 registeredAt;       // Registration timestamp
    uint256 stakeAmount;        // Linked stake amount
    uint256 attestationCount;   // Total attestations
    uint256 trustScore;         // 0-10000 (basis points)
    bool active;                // Active status
}
```

### 2. AttestationRegistry (Verification Layer)

**Purpose:** Store and verify cryptographic proofs of robot actions.

**Key Mechanisms:**
- Merkle tree batching for gas efficiency
- Individual attestation support for low-volume robots
- Trust score computation
- Historical proof verification

**Data Model:**
```solidity
struct AttestationBatch {
    uint256 robotId;            // Robot that submitted
    bytes32 merkleRoot;         // Root of attestation tree
    uint256 attestationCount;   // Attestations in batch
    uint256 timestamp;          // Submission time
    bytes32 metadataHash;       // Off-chain metadata reference
}

struct SingleAttestation {
    uint256 robotId;
    bytes32 actionHash;         // What was done
    bytes32 locationHash;       // Where it happened
    uint256 timestamp;          // When it happened
    bytes32 sensorDataHash;     // Sensor readings hash
    uint8 assuranceLevel;       // Verification depth (1-5)
}
```

### 3. FlectraStaking (Accountability Layer)

**Purpose:** Provide economic incentives for honest behavior.

**Key Mechanisms:**
- Collateral staking for robot registration
- Slashing proposals with voting
- Dispute resolution
- Fee distribution to protocol and reporters

**Data Model:**
```solidity
struct Stake {
    uint256 amount;             // Staked amount
    uint256 lockedUntil;        // Lock period end
    uint256 slashedAmount;      // Total slashed
    bool exists;
}

struct SlashProposal {
    uint256 robotId;
    uint256 amount;
    string reason;
    address proposer;
    uint256 votesFor;
    uint256 votesAgainst;
    bool executed;
}
```

## Trust Score Computation

The trust score is computed based on multiple factors:

```
TrustScore = BaseScore + LongevityBonus + ActivityBonus + StakeBonus

Where:
- BaseScore = 5000 (50%)
- LongevityBonus = min(weeksActive * 100, 2000) // Max 20%
- ActivityBonus = min((attestationCount / 10) * 50, 1500) // Max 15%
- StakeBonus = min((stakeAmount / 1000 USDC) * 100, 1500) // Max 15%

Maximum possible score: 10000 (100%)
```

## Contract Interactions

### Robot Registration Flow

```
1. Operator calls RobotID.registerRobot()
   ├── Verify hardware attestation signature
   ├── Mint RobotID NFT
   └── Initialize robot data

2. Operator calls FlectraStaking.stake()
   ├── Transfer USDC to staking contract
   ├── Update stake record
   └── Update RobotID stake amount
```

### Attestation Submission Flow

```
1. Robot SDK generates attestations
   ├── Sign with hardware key
   └── Batch into Merkle tree

2. Operator calls AttestationRegistry.submitBatch()
   ├── Verify robot is active and staked
   ├── Store Merkle root
   ├── Increment attestation count
   └── Update trust score
```

### Slashing Flow

```
1. Reporter calls FlectraStaking.proposeSlash()
   └── Create slash proposal

2. Voters call FlectraStaking.voteOnSlash()
   └── Record votes

3. After delay, anyone calls FlectraStaking.executeSlash()
   ├── Verify majority support
   ├── Slash stake
   ├── Distribute funds
   └── Update RobotID stake amount
```

## Gas Optimization

- **Merkle Batching:** Bundle multiple attestations into single on-chain transaction
- **Minimal Storage:** Store hashes and roots, not full data
- **Efficient Data Structures:** Packed structs, mappings over arrays

## Security Considerations

1. **Hardware Binding:** Identities tied to physical TPM chips
2. **Economic Security:** Slashing deters fraudulent behavior
3. **Decentralized Verification:** Anyone can verify attestations
4. **Access Controls:** Role-based permissions for sensitive operations

## Upgrade Path

Contracts are non-upgradeable by default. For future upgrades:
- Deploy new versions
- Migrate data via governance
- Support parallel operation during transition

---

For implementation details, see individual contract documentation.
