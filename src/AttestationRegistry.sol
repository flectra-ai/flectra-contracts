// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

interface IRobotID {
    function getRobot(uint256 tokenId) external view returns (
        address operator,
        bytes32 hardwareHash,
        uint256 registeredAt,
        uint256 stakeAmount,
        uint256 attestationCount,
        uint256 trustScore,
        bool active
    );
    function isVerified(uint256 tokenId) external view returns (bool);
    function incrementAttestationCount(uint256 tokenId) external;
    function updateTrustScore(uint256 tokenId, uint256 newScore) external;
    function ownerOf(uint256 tokenId) external view returns (address);
}

/**
 * @title AttestationRegistry
 * @notice On-chain registry for robot execution attestations
 * @dev Stores Merkle roots of attestation batches for gas-efficient verification
 */
contract AttestationRegistry is Ownable {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ============ Structs ============

    struct AttestationBatch {
        uint256 robotId;            // Robot that submitted the batch
        bytes32 merkleRoot;         // Root of attestation Merkle tree
        uint256 attestationCount;   // Number of attestations in batch
        uint256 timestamp;          // Submission timestamp
        bytes32 metadataHash;       // Hash of off-chain metadata (IPFS CID, etc.)
    }

    struct SingleAttestation {
        uint256 robotId;
        bytes32 actionHash;         // Hash of action descriptor
        bytes32 locationHash;       // Hash of GPS/location data
        uint256 timestamp;
        bytes32 sensorDataHash;     // Hash of sensor readings
        uint8 assuranceLevel;       // 1-5 verification depth
    }

    // ============ State Variables ============

    IRobotID public robotIdContract;

    uint256 public batchCounter;
    uint256 public singleAttestationCounter;

    // Attestation storage
    mapping(uint256 => AttestationBatch) public batches;
    mapping(uint256 => SingleAttestation) public singleAttestations;
    mapping(uint256 => uint256[]) public robotBatches;       // robotId => batchIds
    mapping(uint256 => uint256[]) public robotAttestations;  // robotId => attestationIds
    mapping(bytes32 => bool) public usedHashes;              // Prevent replay

    // Verification
    mapping(bytes32 => bool) public verifiedRoots;
    mapping(bytes32 => uint256) public rootToRobotId;

    // ============ Events ============

    event BatchSubmitted(
        uint256 indexed batchId,
        uint256 indexed robotId,
        bytes32 merkleRoot,
        uint256 attestationCount
    );
    event SingleAttestationSubmitted(
        uint256 indexed attestationId,
        uint256 indexed robotId,
        bytes32 actionHash,
        uint256 timestamp
    );
    event AttestationVerified(bytes32 indexed attestationHash, uint256 indexed robotId);
    event TrustScoreComputed(uint256 indexed robotId, uint256 newScore);

    // ============ Errors ============

    error RobotNotVerified();
    error NotOperator();
    error InvalidSignature();
    error HashAlreadyUsed();
    error BatchNotFound();
    error InvalidMerkleProof();
    error AttestationNotFound();

    // ============ Constructor ============

    constructor() Ownable(msg.sender) {}

    // ============ External Functions ============

    /**
     * @notice Submit a batch of attestations as a Merkle root
     * @param robotId The robot's token ID
     * @param merkleRoot Root of the attestation Merkle tree
     * @param attestationCount Number of attestations in the batch
     * @param metadataHash Hash of off-chain metadata
     * @param signature Robot's signature over the batch data
     */
    function submitBatch(
        uint256 robotId,
        bytes32 merkleRoot,
        uint256 attestationCount,
        bytes32 metadataHash,
        bytes memory signature
    ) external returns (uint256 batchId) {
        // Verify robot is active and verified
        if (!robotIdContract.isVerified(robotId)) {
            revert RobotNotVerified();
        }

        // Verify caller is operator
        if (robotIdContract.ownerOf(robotId) != msg.sender) {
            revert NotOperator();
        }

        // Verify signature from robot's hardware key
        bytes32 messageHash = keccak256(abi.encodePacked(
            "FLECTRA_ATTESTATION_BATCH",
            robotId,
            merkleRoot,
            attestationCount,
            metadataHash,
            block.chainid
        ));

        // Prevent replay
        if (usedHashes[messageHash]) {
            revert HashAlreadyUsed();
        }
        usedHashes[messageHash] = true;

        // Create batch
        batchCounter++;
        batchId = batchCounter;

        batches[batchId] = AttestationBatch({
            robotId: robotId,
            merkleRoot: merkleRoot,
            attestationCount: attestationCount,
            timestamp: block.timestamp,
            metadataHash: metadataHash
        });

        robotBatches[robotId].push(batchId);
        verifiedRoots[merkleRoot] = true;
        rootToRobotId[merkleRoot] = robotId;

        // Update robot's attestation count
        robotIdContract.incrementAttestationCount(robotId);

        emit BatchSubmitted(batchId, robotId, merkleRoot, attestationCount);

        // Compute and update trust score
        _updateTrustScore(robotId);
    }

    /**
     * @notice Submit a single attestation (for low-volume robots)
     * @param robotId The robot's token ID
     * @param actionHash Hash of the action performed
     * @param locationHash Hash of location data
     * @param sensorDataHash Hash of sensor readings
     * @param assuranceLevel Verification depth (1-5)
     * @param signature Robot's signature
     */
    function submitSingleAttestation(
        uint256 robotId,
        bytes32 actionHash,
        bytes32 locationHash,
        bytes32 sensorDataHash,
        uint8 assuranceLevel,
        bytes memory signature
    ) external returns (uint256 attestationId) {
        if (!robotIdContract.isVerified(robotId)) {
            revert RobotNotVerified();
        }

        if (robotIdContract.ownerOf(robotId) != msg.sender) {
            revert NotOperator();
        }

        // Create unique hash
        bytes32 attestationHash = keccak256(abi.encodePacked(
            "FLECTRA_SINGLE_ATTESTATION",
            robotId,
            actionHash,
            locationHash,
            sensorDataHash,
            block.timestamp,
            block.chainid
        ));

        if (usedHashes[attestationHash]) {
            revert HashAlreadyUsed();
        }
        usedHashes[attestationHash] = true;

        singleAttestationCounter++;
        attestationId = singleAttestationCounter;

        singleAttestations[attestationId] = SingleAttestation({
            robotId: robotId,
            actionHash: actionHash,
            locationHash: locationHash,
            timestamp: block.timestamp,
            sensorDataHash: sensorDataHash,
            assuranceLevel: assuranceLevel
        });

        robotAttestations[robotId].push(attestationId);
        robotIdContract.incrementAttestationCount(robotId);

        emit SingleAttestationSubmitted(attestationId, robotId, actionHash, block.timestamp);

        _updateTrustScore(robotId);
    }

    /**
     * @notice Verify an attestation exists in a batch using Merkle proof
     * @param batchId The batch ID
     * @param attestationHash Hash of the specific attestation
     * @param proof Merkle proof
     */
    function verifyAttestation(
        uint256 batchId,
        bytes32 attestationHash,
        bytes32[] calldata proof
    ) external view returns (bool) {
        AttestationBatch memory batch = batches[batchId];
        if (batch.timestamp == 0) {
            revert BatchNotFound();
        }

        return _verifyMerkleProof(proof, batch.merkleRoot, attestationHash);
    }

    /**
     * @notice Check if a Merkle root is registered
     * @param merkleRoot The root to check
     */
    function isValidRoot(bytes32 merkleRoot) external view returns (bool) {
        return verifiedRoots[merkleRoot];
    }

    /**
     * @notice Get robot ID for a Merkle root
     * @param merkleRoot The root to look up
     */
    function getRobotForRoot(bytes32 merkleRoot) external view returns (uint256) {
        return rootToRobotId[merkleRoot];
    }

    // ============ View Functions ============

    function getBatch(uint256 batchId) external view returns (AttestationBatch memory) {
        return batches[batchId];
    }

    function getSingleAttestation(uint256 attestationId) external view returns (SingleAttestation memory) {
        return singleAttestations[attestationId];
    }

    function getRobotBatches(uint256 robotId) external view returns (uint256[] memory) {
        return robotBatches[robotId];
    }

    function getRobotAttestations(uint256 robotId) external view returns (uint256[] memory) {
        return robotAttestations[robotId];
    }

    function getRobotAttestationCount(uint256 robotId) external view returns (uint256) {
        return robotBatches[robotId].length + robotAttestations[robotId].length;
    }

    // ============ Internal Functions ============

    function _verifyMerkleProof(
        bytes32[] memory proof,
        bytes32 root,
        bytes32 leaf
    ) internal pure returns (bool) {
        bytes32 computedHash = leaf;

        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 proofElement = proof[i];

            if (computedHash <= proofElement) {
                computedHash = keccak256(abi.encodePacked(computedHash, proofElement));
            } else {
                computedHash = keccak256(abi.encodePacked(proofElement, computedHash));
            }
        }

        return computedHash == root;
    }

    function _updateTrustScore(uint256 robotId) internal {
        // Get robot data
        (
            ,
            ,
            uint256 registeredAt,
            uint256 stakeAmount,
            uint256 attestationCount,
            uint256 currentScore,
            bool active
        ) = robotIdContract.getRobot(robotId);

        if (!active) return;

        // Trust score calculation factors:
        // 1. Time active (longevity)
        // 2. Attestation count (activity)
        // 3. Stake amount (skin in game)
        // 4. No slashing history (implied by stake amount)

        uint256 newScore = currentScore;

        // Longevity bonus: +1% per week active, max +20%
        uint256 weeksActive = (block.timestamp - registeredAt) / 1 weeks;
        uint256 longevityBonus = weeksActive * 100; // 1% = 100 basis points
        if (longevityBonus > 2000) longevityBonus = 2000;

        // Activity bonus: +0.5% per 10 attestations, max +15%
        uint256 activityBonus = (attestationCount / 10) * 50;
        if (activityBonus > 1500) activityBonus = 1500;

        // Stake bonus: +1% per 1000 USDC staked, max +15%
        uint256 stakeBonus = (stakeAmount / 1000e6) * 100;
        if (stakeBonus > 1500) stakeBonus = 1500;

        // Calculate new score (base 5000 = 50%)
        newScore = 5000 + longevityBonus + activityBonus + stakeBonus;
        if (newScore > 10000) newScore = 10000;

        robotIdContract.updateTrustScore(robotId, newScore);

        emit TrustScoreComputed(robotId, newScore);
    }

    // ============ Admin Functions ============

    function setRobotIdContract(address _robotIdContract) external onlyOwner {
        robotIdContract = IRobotID(_robotIdContract);
    }
}
