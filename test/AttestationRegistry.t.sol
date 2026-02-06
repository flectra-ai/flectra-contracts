// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {AttestationRegistry} from "../src/AttestationRegistry.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

contract MockRobotIDForRegistry {
    mapping(uint256 => address) public owners;
    mapping(uint256 => address) public hardwareAddresses;
    mapping(uint256 => bool) public verified;
    mapping(uint256 => uint256) public attestationCounts;
    mapping(uint256 => uint256) public trustScores;
    mapping(uint256 => uint256) public stakeAmounts;
    mapping(uint256 => uint256) public registeredAt;
    mapping(uint256 => bool) public active;

    function setup(
        uint256 tokenId,
        address _owner,
        address _hardwareAddress,
        uint256 _stakeAmount
    ) external {
        owners[tokenId] = _owner;
        hardwareAddresses[tokenId] = _hardwareAddress;
        verified[tokenId] = true;
        stakeAmounts[tokenId] = _stakeAmount;
        registeredAt[tokenId] = block.timestamp;
        active[tokenId] = true;
        trustScores[tokenId] = 5000;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return owners[tokenId];
    }

    function getHardwareAddress(uint256 tokenId) external view returns (address) {
        return hardwareAddresses[tokenId];
    }

    function isVerified(uint256 tokenId) external view returns (bool) {
        return verified[tokenId];
    }

    function incrementAttestationCount(uint256 tokenId) external {
        attestationCounts[tokenId]++;
    }

    function updateTrustScore(uint256 tokenId, uint256 newScore) external {
        trustScores[tokenId] = newScore;
    }

    function getRobot(uint256 tokenId) external view returns (
        address operator,
        bytes32 hardwareHash,
        address hardwareAddress,
        uint256 _registeredAt,
        uint256 stakeAmount,
        uint256 attestationCount,
        uint256 trustScore,
        bool _active
    ) {
        operator = owners[tokenId];
        hardwareHash = bytes32(0);
        hardwareAddress = hardwareAddresses[tokenId];
        _registeredAt = registeredAt[tokenId];
        stakeAmount = stakeAmounts[tokenId];
        attestationCount = attestationCounts[tokenId];
        trustScore = trustScores[tokenId];
        _active = active[tokenId];
    }

    function setVerified(uint256 tokenId, bool _verified) external {
        verified[tokenId] = _verified;
    }
}

contract AttestationRegistryTest is Test {
    AttestationRegistry public registry;
    MockRobotIDForRegistry public robotId;

    address public owner;
    address public operator;
    address public attacker;

    uint256 public hardwarePrivateKey;
    address public hardwareAddress;

    uint256 public constant ROBOT_ID = 1;
    uint256 public constant MIN_STAKE = 100 * 1e6;

    event BatchSubmitted(
        uint256 indexed batchId,
        uint256 indexed robotId,
        bytes32 indexed merkleRoot,
        uint256 attestationCount,
        bytes32 metadataHash
    );

    event SingleAttestationSubmitted(
        uint256 indexed attestationId,
        uint256 indexed robotId,
        bytes32 indexed actionHash,
        uint8 assuranceLevel
    );

    function setUp() public {
        owner = address(this);
        operator = makeAddr("operator");
        attacker = makeAddr("attacker");

        // Generate hardware key
        hardwarePrivateKey = 0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890;
        hardwareAddress = vm.addr(hardwarePrivateKey);

        robotId = new MockRobotIDForRegistry();
        registry = new AttestationRegistry();

        registry.setRobotIdContract(address(robotId));

        // Setup robot
        robotId.setup(ROBOT_ID, operator, hardwareAddress, MIN_STAKE);

        // Warp to a reasonable timestamp (past rate limit window)
        vm.warp(1000000);
    }

    // ============ Deployment Tests ============

    function test_Deployment() public view {
        assertEq(registry.batchCounter(), 0);
        assertEq(registry.singleAttestationCounter(), 0);
        assertEq(address(registry.robotIdContract()), address(robotId));
    }

    function test_Constants() public view {
        assertEq(registry.MAX_TRUST_SCORE(), 10_000);
        assertEq(registry.BASE_TRUST_SCORE(), 5_000);
        assertEq(registry.MAX_BATCH_SIZE(), 10_000);
        assertEq(registry.MIN_BATCH_INTERVAL(), 1 minutes);
    }

    function test_DefaultTrustScoreConfig() public view {
        (
            uint256 longevityWeight,
            uint256 activityWeight,
            uint256 stakeWeight,
            uint256 maxLongevityBonus,
            uint256 maxActivityBonus,
            uint256 maxStakeBonus
        ) = registry.trustScoreConfig();

        assertEq(longevityWeight, 100);
        assertEq(activityWeight, 50);
        assertEq(stakeWeight, 100);
        assertEq(maxLongevityBonus, 2000);
        assertEq(maxActivityBonus, 1500);
        assertEq(maxStakeBonus, 1500);
    }

    // ============ Submit Batch Tests ============

    function test_SubmitBatch() public {
        bytes32 merkleRoot = keccak256("merkle_root");
        uint256 attestationCount = 100;
        bytes32 metadataHash = keccak256("metadata");

        bytes memory sig = _createBatchSignature(
            ROBOT_ID,
            merkleRoot,
            attestationCount,
            metadataHash,
            0 // nonce
        );

        vm.prank(operator);
        uint256 batchId = registry.submitBatch(
            ROBOT_ID,
            merkleRoot,
            attestationCount,
            metadataHash,
            sig
        );

        assertEq(batchId, 1);
        assertTrue(registry.verifiedRoots(merkleRoot));
        assertEq(registry.rootToRobotId(merkleRoot), ROBOT_ID);

        AttestationRegistry.AttestationBatch memory batch = registry.getBatch(batchId);
        assertEq(batch.robotId, ROBOT_ID);
        assertEq(batch.merkleRoot, merkleRoot);
        assertEq(batch.attestationCount, attestationCount);
        assertEq(batch.metadataHash, metadataHash);
    }

    function test_SubmitBatch_EmitsEvent() public {
        bytes32 merkleRoot = keccak256("merkle_root");
        bytes32 metadataHash = keccak256("metadata");

        bytes memory sig = _createBatchSignature(ROBOT_ID, merkleRoot, 100, metadataHash, 0);

        vm.expectEmit(true, true, true, true);
        emit BatchSubmitted(1, ROBOT_ID, merkleRoot, 100, metadataHash);

        vm.prank(operator);
        registry.submitBatch(ROBOT_ID, merkleRoot, 100, metadataHash, sig);
    }

    function test_SubmitBatch_IncrementsAttestationCount() public {
        bytes32 merkleRoot = keccak256("merkle_root");
        bytes memory sig = _createBatchSignature(ROBOT_ID, merkleRoot, 100, bytes32(0), 0);

        vm.prank(operator);
        registry.submitBatch(ROBOT_ID, merkleRoot, 100, bytes32(0), sig);

        assertEq(robotId.attestationCounts(ROBOT_ID), 1);
    }

    function test_SubmitBatch_RevertIfNotOperator() public {
        bytes32 merkleRoot = keccak256("merkle_root");
        bytes memory sig = _createBatchSignature(ROBOT_ID, merkleRoot, 100, bytes32(0), 0);

        vm.prank(attacker);
        vm.expectRevert(AttestationRegistry.NotOperator.selector);
        registry.submitBatch(ROBOT_ID, merkleRoot, 100, bytes32(0), sig);
    }

    function test_SubmitBatch_RevertIfRobotNotVerified() public {
        robotId.setVerified(ROBOT_ID, false);

        bytes32 merkleRoot = keccak256("merkle_root");
        bytes memory sig = _createBatchSignature(ROBOT_ID, merkleRoot, 100, bytes32(0), 0);

        vm.prank(operator);
        vm.expectRevert(AttestationRegistry.RobotNotVerified.selector);
        registry.submitBatch(ROBOT_ID, merkleRoot, 100, bytes32(0), sig);
    }

    function test_SubmitBatch_RevertIfDuplicateRoot() public {
        bytes32 merkleRoot = keccak256("merkle_root");

        bytes memory sig1 = _createBatchSignature(ROBOT_ID, merkleRoot, 100, bytes32(0), 0);
        vm.prank(operator);
        registry.submitBatch(ROBOT_ID, merkleRoot, 100, bytes32(0), sig1);

        // Wait for rate limit
        vm.warp(block.timestamp + 2 minutes);

        bytes memory sig2 = _createBatchSignature(ROBOT_ID, merkleRoot, 100, bytes32(0), 1);
        vm.prank(operator);
        vm.expectRevert(AttestationRegistry.RootAlreadyExists.selector);
        registry.submitBatch(ROBOT_ID, merkleRoot, 100, bytes32(0), sig2);
    }

    function test_SubmitBatch_RevertIfBatchTooLarge() public {
        bytes32 merkleRoot = keccak256("merkle_root");
        bytes memory sig = _createBatchSignature(ROBOT_ID, merkleRoot, 10001, bytes32(0), 0);

        vm.prank(operator);
        vm.expectRevert(AttestationRegistry.BatchTooLarge.selector);
        registry.submitBatch(ROBOT_ID, merkleRoot, 10001, bytes32(0), sig);
    }

    function test_SubmitBatch_RateLimited() public {
        bytes32 merkleRoot1 = keccak256("root1");
        bytes memory sig1 = _createBatchSignature(ROBOT_ID, merkleRoot1, 100, bytes32(0), 0);

        vm.prank(operator);
        registry.submitBatch(ROBOT_ID, merkleRoot1, 100, bytes32(0), sig1);

        // Try immediately again
        bytes32 merkleRoot2 = keccak256("root2");
        bytes memory sig2 = _createBatchSignature(ROBOT_ID, merkleRoot2, 100, bytes32(0), 1);

        vm.prank(operator);
        vm.expectRevert(AttestationRegistry.RateLimitExceeded.selector);
        registry.submitBatch(ROBOT_ID, merkleRoot2, 100, bytes32(0), sig2);
    }

    function test_SubmitBatch_RevertIfInvalidSignature() public {
        bytes32 merkleRoot = keccak256("merkle_root");

        // Wrong signer
        uint256 wrongKey = 0x9999999999999999999999999999999999999999999999999999999999999999;
        bytes memory wrongSig = _createSignatureWithKey(
            wrongKey,
            ROBOT_ID,
            merkleRoot,
            100,
            bytes32(0),
            0
        );

        vm.prank(operator);
        vm.expectRevert(AttestationRegistry.InvalidSignature.selector);
        registry.submitBatch(ROBOT_ID, merkleRoot, 100, bytes32(0), wrongSig);
    }

    // ============ Submit Single Attestation Tests ============

    function test_SubmitSingleAttestation() public {
        bytes32 actionHash = keccak256("action");
        bytes32 locationHash = keccak256("location");
        bytes32 sensorHash = keccak256("sensor");
        uint8 assuranceLevel = 3;

        bytes memory sig = _createSingleSignature(
            ROBOT_ID,
            actionHash,
            locationHash,
            sensorHash,
            assuranceLevel,
            0
        );

        vm.prank(operator);
        uint256 attestationId = registry.submitSingleAttestation(
            ROBOT_ID,
            actionHash,
            locationHash,
            sensorHash,
            assuranceLevel,
            sig
        );

        assertEq(attestationId, 1);

        AttestationRegistry.SingleAttestation memory a = registry.getSingleAttestation(attestationId);
        assertEq(a.robotId, ROBOT_ID);
        assertEq(a.actionHash, actionHash);
        assertEq(a.locationHash, locationHash);
        assertEq(a.sensorDataHash, sensorHash);
        assertEq(a.assuranceLevel, assuranceLevel);
    }

    function test_SubmitSingleAttestation_RevertIfInvalidAssuranceLevel() public {
        bytes32 actionHash = keccak256("action");
        bytes memory sig = _createSingleSignature(ROBOT_ID, actionHash, bytes32(0), bytes32(0), 0, 0);

        vm.prank(operator);
        vm.expectRevert(AttestationRegistry.InvalidAssuranceLevel.selector);
        registry.submitSingleAttestation(ROBOT_ID, actionHash, bytes32(0), bytes32(0), 0, sig);

        bytes memory sig2 = _createSingleSignature(ROBOT_ID, actionHash, bytes32(0), bytes32(0), 6, 0);
        vm.prank(operator);
        vm.expectRevert(AttestationRegistry.InvalidAssuranceLevel.selector);
        registry.submitSingleAttestation(ROBOT_ID, actionHash, bytes32(0), bytes32(0), 6, sig2);
    }

    function test_SubmitSingleAttestation_RevertIfInvalidActionHash() public {
        bytes memory sig = _createSingleSignature(ROBOT_ID, bytes32(0), bytes32(0), bytes32(0), 3, 0);

        vm.prank(operator);
        vm.expectRevert(AttestationRegistry.InvalidParameter.selector);
        registry.submitSingleAttestation(ROBOT_ID, bytes32(0), bytes32(0), bytes32(0), 3, sig);
    }

    // ============ Merkle Proof Verification Tests ============

    function test_VerifyAttestation() public {
        // Create a simple merkle tree with 4 leaves
        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = keccak256("attestation0");
        leaves[1] = keccak256("attestation1");
        leaves[2] = keccak256("attestation2");
        leaves[3] = keccak256("attestation3");

        bytes32 merkleRoot = _computeMerkleRoot(leaves);

        bytes memory sig = _createBatchSignature(ROBOT_ID, merkleRoot, 4, bytes32(0), 0);

        vm.prank(operator);
        uint256 batchId = registry.submitBatch(ROBOT_ID, merkleRoot, 4, bytes32(0), sig);

        // Create proof for leaf 0
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = leaves[1]; // Sibling
        proof[1] = _hashPair(leaves[2], leaves[3]); // Uncle

        bool valid = registry.verifyAttestation(batchId, leaves[0], proof);
        assertTrue(valid);
    }

    function test_VerifyAttestation_InvalidProof() public {
        bytes32 merkleRoot = keccak256("root");
        bytes memory sig = _createBatchSignature(ROBOT_ID, merkleRoot, 4, bytes32(0), 0);

        vm.prank(operator);
        uint256 batchId = registry.submitBatch(ROBOT_ID, merkleRoot, 4, bytes32(0), sig);

        bytes32[] memory badProof = new bytes32[](1);
        badProof[0] = keccak256("wrong");

        bool valid = registry.verifyAttestation(batchId, keccak256("attestation"), badProof);
        assertFalse(valid);
    }

    // ============ View Function Tests ============

    function test_GetRobotBatches() public {
        // Submit multiple batches
        for (uint256 i = 0; i < 3; i++) {
            bytes32 merkleRoot = keccak256(abi.encodePacked("root", i));
            bytes memory sig = _createBatchSignature(ROBOT_ID, merkleRoot, 100, bytes32(0), i);

            if (i > 0) vm.warp(block.timestamp + 2 minutes);

            vm.prank(operator);
            registry.submitBatch(ROBOT_ID, merkleRoot, 100, bytes32(0), sig);
        }

        uint256[] memory batches = registry.getRobotBatches(ROBOT_ID);
        assertEq(batches.length, 3);
        assertEq(batches[0], 1);
        assertEq(batches[1], 2);
        assertEq(batches[2], 3);
    }

    function test_GetRobotAttestations() public {
        // Submit multiple single attestations
        for (uint256 i = 0; i < 3; i++) {
            bytes32 actionHash = keccak256(abi.encodePacked("action", i));
            bytes memory sig = _createSingleSignature(ROBOT_ID, actionHash, bytes32(0), bytes32(0), 3, i);

            vm.prank(operator);
            registry.submitSingleAttestation(ROBOT_ID, actionHash, bytes32(0), bytes32(0), 3, sig);
        }

        uint256[] memory attestations = registry.getRobotAttestations(ROBOT_ID);
        assertEq(attestations.length, 3);
    }

    function test_GetRobotAttestationCount() public {
        // Submit batch
        bytes32 merkleRoot = keccak256("root");
        bytes memory batchSig = _createBatchSignature(ROBOT_ID, merkleRoot, 100, bytes32(0), 0);
        vm.prank(operator);
        registry.submitBatch(ROBOT_ID, merkleRoot, 100, bytes32(0), batchSig);

        // Submit single
        bytes32 actionHash = keccak256("action");
        bytes memory singleSig = _createSingleSignature(ROBOT_ID, actionHash, bytes32(0), bytes32(0), 3, 1);
        vm.prank(operator);
        registry.submitSingleAttestation(ROBOT_ID, actionHash, bytes32(0), bytes32(0), 3, singleSig);

        assertEq(registry.getRobotAttestationCount(ROBOT_ID), 2);
    }

    function test_IsValidRoot() public {
        bytes32 merkleRoot = keccak256("root");
        bytes memory sig = _createBatchSignature(ROBOT_ID, merkleRoot, 100, bytes32(0), 0);

        assertFalse(registry.isValidRoot(merkleRoot));

        vm.prank(operator);
        registry.submitBatch(ROBOT_ID, merkleRoot, 100, bytes32(0), sig);

        assertTrue(registry.isValidRoot(merkleRoot));
    }

    function test_GetNonce() public view {
        assertEq(registry.getNonce(ROBOT_ID), 0);
    }

    // ============ Admin Tests ============

    function test_SetTrustScoreConfig() public {
        AttestationRegistry.TrustScoreConfig memory newConfig = AttestationRegistry.TrustScoreConfig({
            longevityWeight: 200,
            activityWeight: 100,
            stakeWeight: 150,
            maxLongevityBonus: 2500,
            maxActivityBonus: 1000,
            maxStakeBonus: 1000
        });

        registry.setTrustScoreConfig(newConfig);

        (
            uint256 longevityWeight,
            uint256 activityWeight,
            uint256 stakeWeight,
            uint256 maxLongevityBonus,
            uint256 maxActivityBonus,
            uint256 maxStakeBonus
        ) = registry.trustScoreConfig();

        assertEq(longevityWeight, 200);
        assertEq(activityWeight, 100);
        assertEq(stakeWeight, 150);
        assertEq(maxLongevityBonus, 2500);
        assertEq(maxActivityBonus, 1000);
        assertEq(maxStakeBonus, 1000);
    }

    function test_SetTrustScoreConfig_RevertIfExceedsMax() public {
        AttestationRegistry.TrustScoreConfig memory badConfig = AttestationRegistry.TrustScoreConfig({
            longevityWeight: 100,
            activityWeight: 100,
            stakeWeight: 100,
            maxLongevityBonus: 3000,
            maxActivityBonus: 3000,
            maxStakeBonus: 3000 // Total: 9000, exceeds 5000 (MAX - BASE)
        });

        vm.expectRevert(AttestationRegistry.InvalidParameter.selector);
        registry.setTrustScoreConfig(badConfig);
    }

    function test_Pause_Unpause() public {
        registry.pause();
        assertTrue(registry.paused());

        bytes32 merkleRoot = keccak256("root");
        bytes memory sig = _createBatchSignature(ROBOT_ID, merkleRoot, 100, bytes32(0), 0);

        vm.prank(operator);
        vm.expectRevert();
        registry.submitBatch(ROBOT_ID, merkleRoot, 100, bytes32(0), sig);

        registry.unpause();
        assertFalse(registry.paused());
    }

    // ============ Helper Functions ============

    function _createBatchSignature(
        uint256 _robotId,
        bytes32 merkleRoot,
        uint256 attestationCount,
        bytes32 metadataHash,
        uint256 nonce
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                registry.BATCH_TYPEHASH(),
                _robotId,
                merkleRoot,
                attestationCount,
                metadataHash,
                nonce,
                block.chainid
            )
        );

        bytes32 digest = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", structHash)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(hardwarePrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _createSignatureWithKey(
        uint256 privateKey,
        uint256 _robotId,
        bytes32 merkleRoot,
        uint256 attestationCount,
        bytes32 metadataHash,
        uint256 nonce
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                registry.BATCH_TYPEHASH(),
                _robotId,
                merkleRoot,
                attestationCount,
                metadataHash,
                nonce,
                block.chainid
            )
        );

        bytes32 digest = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", structHash)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _createSingleSignature(
        uint256 _robotId,
        bytes32 actionHash,
        bytes32 locationHash,
        bytes32 sensorHash,
        uint8 assuranceLevel,
        uint256 nonce
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                registry.SINGLE_TYPEHASH(),
                _robotId,
                actionHash,
                locationHash,
                sensorHash,
                assuranceLevel,
                nonce,
                block.chainid
            )
        );

        bytes32 digest = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", structHash)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(hardwarePrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _computeMerkleRoot(bytes32[] memory leaves) internal pure returns (bytes32) {
        require(leaves.length == 4, "Fixed for 4 leaves");
        bytes32 hash01 = _hashPair(leaves[0], leaves[1]);
        bytes32 hash23 = _hashPair(leaves[2], leaves[3]);
        return _hashPair(hash01, hash23);
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a <= b
            ? keccak256(abi.encodePacked(a, b))
            : keccak256(abi.encodePacked(b, a));
    }
}
