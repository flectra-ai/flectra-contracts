// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {RobotID} from "../src/RobotID.sol";

contract RobotIDTest is Test {
    RobotID public robotId;

    address public owner;
    address public operator;
    address public attacker;
    address public stakingContract;
    address public attestationRegistry;

    uint256 public constant MIN_STAKE = 100 * 1e6; // 100 USDC

    // Hardware key for testing
    uint256 public hardwarePrivateKey;
    address public hardwareAddress;

    event RobotRegistered(
        uint256 indexed tokenId,
        address indexed operator,
        bytes32 indexed hardwareHash,
        address hardwareAddress,
        uint256 stakeAmount
    );
    event RobotDeactivated(uint256 indexed tokenId, address indexed operator);
    event RobotReactivated(uint256 indexed tokenId, address indexed operator);
    event TrustScoreUpdated(uint256 indexed tokenId, uint256 oldScore, uint256 newScore);

    function setUp() public {
        owner = address(this);
        operator = makeAddr("operator");
        attacker = makeAddr("attacker");
        stakingContract = makeAddr("staking");
        attestationRegistry = makeAddr("registry");

        // Generate hardware key
        hardwarePrivateKey = 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef;
        hardwareAddress = vm.addr(hardwarePrivateKey);

        robotId = new RobotID(MIN_STAKE);
        robotId.setStakingContract(stakingContract);
        robotId.setAttestationRegistry(attestationRegistry);
    }

    // ============ Deployment Tests ============

    function test_Deployment() public view {
        assertEq(robotId.minStakeAmount(), MIN_STAKE);
        assertEq(robotId.owner(), owner);
        assertEq(robotId.name(), "Flectra Robot ID");
        assertEq(robotId.symbol(), "ROBOT");
        assertEq(robotId.stakingContract(), stakingContract);
        assertEq(robotId.attestationRegistry(), attestationRegistry);
    }

    function test_Constants() public view {
        assertEq(robotId.MAX_TRUST_SCORE(), 10_000);
        assertEq(robotId.INITIAL_TRUST_SCORE(), 5_000);
    }

    // ============ Registration Tests ============

    function test_RegisterRobot() public {
        bytes32 hardwareHash = keccak256("hardware1");
        uint256 stakeAmount = MIN_STAKE;

        (bytes memory signature, uint256 nonce) = _createRegistrationSignature(
            operator,
            hardwareHash
        );

        vm.prank(operator);
        uint256 tokenId = robotId.registerRobot(hardwareHash, signature, stakeAmount);

        assertEq(tokenId, 1);
        assertEq(robotId.ownerOf(tokenId), operator);
        assertEq(robotId.totalRobots(), 1);

        RobotID.Robot memory robot = robotId.getRobot(tokenId);
        assertEq(robot.operator, operator);
        assertEq(robot.hardwareHash, hardwareHash);
        assertEq(robot.hardwareAddress, hardwareAddress);
        assertEq(robot.stakeAmount, stakeAmount);
        assertEq(robot.trustScore, 5000);
        assertTrue(robot.active);
    }

    function test_RegisterRobot_EmitsEvent() public {
        bytes32 hardwareHash = keccak256("hardware1");

        (bytes memory signature,) = _createRegistrationSignature(operator, hardwareHash);

        vm.expectEmit(true, true, true, true);
        emit RobotRegistered(1, operator, hardwareHash, hardwareAddress, MIN_STAKE);

        vm.prank(operator);
        robotId.registerRobot(hardwareHash, signature, MIN_STAKE);
    }

    function test_RegisterRobot_RevertIfHardwareAlreadyRegistered() public {
        bytes32 hardwareHash = keccak256("hardware1");

        (bytes memory sig1,) = _createRegistrationSignature(operator, hardwareHash);
        vm.prank(operator);
        robotId.registerRobot(hardwareHash, sig1, MIN_STAKE);

        // Try to register same hardware again
        (bytes memory sig2,) = _createRegistrationSignature(attacker, hardwareHash);
        vm.prank(attacker);
        vm.expectRevert(RobotID.HardwareAlreadyRegistered.selector);
        robotId.registerRobot(hardwareHash, sig2, MIN_STAKE);
    }

    function test_RegisterRobot_RevertIfInsufficientStake() public {
        bytes32 hardwareHash = keccak256("hardware1");
        (bytes memory signature,) = _createRegistrationSignature(operator, hardwareHash);

        vm.prank(operator);
        vm.expectRevert(RobotID.InsufficientStake.selector);
        robotId.registerRobot(hardwareHash, signature, MIN_STAKE - 1);
    }

    function test_RegisterRobot_RevertIfInvalidHardwareHash() public {
        (bytes memory signature,) = _createRegistrationSignature(operator, bytes32(0));

        vm.prank(operator);
        vm.expectRevert(RobotID.InvalidHardwareHash.selector);
        robotId.registerRobot(bytes32(0), signature, MIN_STAKE);
    }

    function test_RegisterRobot_RevertIfPaused() public {
        robotId.pause();

        bytes32 hardwareHash = keccak256("hardware1");
        (bytes memory signature,) = _createRegistrationSignature(operator, hardwareHash);

        vm.prank(operator);
        vm.expectRevert();
        robotId.registerRobot(hardwareHash, signature, MIN_STAKE);
    }

    // ============ Deactivation Tests ============

    function test_DeactivateRobot() public {
        uint256 tokenId = _registerRobot(operator);

        vm.expectEmit(true, true, false, false);
        emit RobotDeactivated(tokenId, operator);

        vm.prank(operator);
        robotId.deactivateRobot(tokenId);

        RobotID.Robot memory robot = robotId.getRobot(tokenId);
        assertFalse(robot.active);
        assertFalse(robotId.isVerified(tokenId));
    }

    function test_DeactivateRobot_RevertIfNotOperator() public {
        uint256 tokenId = _registerRobot(operator);

        vm.prank(attacker);
        vm.expectRevert(RobotID.NotOperator.selector);
        robotId.deactivateRobot(tokenId);
    }

    function test_DeactivateRobot_RevertIfAlreadyDeactivated() public {
        uint256 tokenId = _registerRobot(operator);

        vm.prank(operator);
        robotId.deactivateRobot(tokenId);

        vm.prank(operator);
        vm.expectRevert(RobotID.RobotNotActive.selector);
        robotId.deactivateRobot(tokenId);
    }

    // ============ Reactivation Tests ============

    function test_ReactivateRobot() public {
        uint256 tokenId = _registerRobot(operator);

        vm.prank(operator);
        robotId.deactivateRobot(tokenId);

        vm.expectEmit(true, true, false, false);
        emit RobotReactivated(tokenId, operator);

        vm.prank(operator);
        robotId.reactivateRobot(tokenId);

        assertTrue(robotId.getRobot(tokenId).active);
    }

    function test_ReactivateRobot_RevertIfAlreadyActive() public {
        uint256 tokenId = _registerRobot(operator);

        vm.prank(operator);
        vm.expectRevert(RobotID.RobotAlreadyActive.selector);
        robotId.reactivateRobot(tokenId);
    }

    // ============ Trust Score Tests ============

    function test_UpdateTrustScore_FromRegistry() public {
        uint256 tokenId = _registerRobot(operator);

        vm.expectEmit(true, false, false, true);
        emit TrustScoreUpdated(tokenId, 5000, 7500);

        vm.prank(attestationRegistry);
        robotId.updateTrustScore(tokenId, 7500);

        assertEq(robotId.getRobot(tokenId).trustScore, 7500);
    }

    function test_UpdateTrustScore_FromOwner() public {
        uint256 tokenId = _registerRobot(operator);

        vm.prank(owner);
        robotId.updateTrustScore(tokenId, 8000);

        assertEq(robotId.getRobot(tokenId).trustScore, 8000);
    }

    function test_UpdateTrustScore_RevertIfNotAuthorized() public {
        uint256 tokenId = _registerRobot(operator);

        vm.prank(attacker);
        vm.expectRevert(RobotID.NotAuthorized.selector);
        robotId.updateTrustScore(tokenId, 7500);
    }

    function test_UpdateTrustScore_RevertIfInvalidScore() public {
        uint256 tokenId = _registerRobot(operator);

        vm.prank(attestationRegistry);
        vm.expectRevert(RobotID.InvalidTrustScore.selector);
        robotId.updateTrustScore(tokenId, 10001);
    }

    // ============ Stake Amount Tests ============

    function test_UpdateStakeAmount() public {
        uint256 tokenId = _registerRobot(operator);

        vm.prank(stakingContract);
        robotId.updateStakeAmount(tokenId, 200 * 1e6);

        assertEq(robotId.getRobot(tokenId).stakeAmount, 200 * 1e6);
    }

    function test_UpdateStakeAmount_RevertIfNotStakingContract() public {
        uint256 tokenId = _registerRobot(operator);

        vm.prank(attacker);
        vm.expectRevert(RobotID.NotAuthorized.selector);
        robotId.updateStakeAmount(tokenId, 200 * 1e6);
    }

    // ============ Attestation Count Tests ============

    function test_IncrementAttestationCount() public {
        uint256 tokenId = _registerRobot(operator);

        vm.prank(attestationRegistry);
        robotId.incrementAttestationCount(tokenId);

        assertEq(robotId.getRobot(tokenId).attestationCount, 1);

        vm.prank(attestationRegistry);
        robotId.incrementAttestationCount(tokenId);

        assertEq(robotId.getRobot(tokenId).attestationCount, 2);
    }

    function test_IncrementAttestationCount_RevertIfNotRegistry() public {
        uint256 tokenId = _registerRobot(operator);

        vm.prank(attacker);
        vm.expectRevert(RobotID.NotAuthorized.selector);
        robotId.incrementAttestationCount(tokenId);
    }

    // ============ Transfer Tests ============

    function test_TransferUpdatesOperator() public {
        uint256 tokenId = _registerRobot(operator);
        address newOwner = makeAddr("newOwner");

        vm.prank(operator);
        robotId.transferFrom(operator, newOwner, tokenId);

        assertEq(robotId.ownerOf(tokenId), newOwner);
        assertEq(robotId.getRobot(tokenId).operator, newOwner);
    }

    // ============ Verification Tests ============

    function test_IsVerified_True() public {
        uint256 tokenId = _registerRobot(operator);
        assertTrue(robotId.isVerified(tokenId));
    }

    function test_IsVerified_FalseIfDeactivated() public {
        uint256 tokenId = _registerRobot(operator);

        vm.prank(operator);
        robotId.deactivateRobot(tokenId);

        assertFalse(robotId.isVerified(tokenId));
    }

    function test_IsVerified_FalseIfInsufficientStake() public {
        uint256 tokenId = _registerRobot(operator);

        vm.prank(stakingContract);
        robotId.updateStakeAmount(tokenId, MIN_STAKE - 1);

        assertFalse(robotId.isVerified(tokenId));
    }

    function test_IsVerified_FalseIfTokenDoesNotExist() public view {
        assertFalse(robotId.isVerified(999));
    }

    // ============ Admin Tests ============

    function test_SetMinStakeAmount() public {
        uint256 newMin = 200 * 1e6;
        robotId.setMinStakeAmount(newMin);
        assertEq(robotId.minStakeAmount(), newMin);
    }

    function test_SetMinStakeAmount_RevertIfNotOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        robotId.setMinStakeAmount(200 * 1e6);
    }

    function test_SetStakingContract() public {
        address newStaking = makeAddr("newStaking");
        robotId.setStakingContract(newStaking);
        assertEq(robotId.stakingContract(), newStaking);
    }

    function test_SetStakingContract_RevertIfZeroAddress() public {
        vm.expectRevert(RobotID.InvalidAddress.selector);
        robotId.setStakingContract(address(0));
    }

    function test_SetAttestationRegistry() public {
        address newRegistry = makeAddr("newRegistry");
        robotId.setAttestationRegistry(newRegistry);
        assertEq(robotId.attestationRegistry(), newRegistry);
    }

    function test_Pause_Unpause() public {
        robotId.pause();
        assertTrue(robotId.paused());

        robotId.unpause();
        assertFalse(robotId.paused());
    }

    // ============ View Function Tests ============

    function test_GetOperator() public {
        uint256 tokenId = _registerRobot(operator);
        assertEq(robotId.getOperator(tokenId), operator);
    }

    function test_GetHardwareAddress() public {
        uint256 tokenId = _registerRobot(operator);
        assertEq(robotId.getHardwareAddress(tokenId), hardwareAddress);
    }

    function test_GetRobotByHardware() public {
        bytes32 hardwareHash = keccak256("unique_hardware");
        (bytes memory sig,) = _createRegistrationSignature(operator, hardwareHash);

        vm.prank(operator);
        uint256 tokenId = robotId.registerRobot(hardwareHash, sig, MIN_STAKE);

        assertEq(robotId.getRobotByHardware(hardwareHash), tokenId);
    }

    // ============ Fuzz Tests ============

    function testFuzz_RegisterWithValidStake(uint256 stakeAmount) public {
        vm.assume(stakeAmount >= MIN_STAKE && stakeAmount <= type(uint128).max);

        bytes32 hardwareHash = keccak256(abi.encodePacked("hardware", stakeAmount));
        (bytes memory sig,) = _createRegistrationSignature(operator, hardwareHash);

        vm.prank(operator);
        uint256 tokenId = robotId.registerRobot(hardwareHash, sig, stakeAmount);

        assertEq(robotId.getRobot(tokenId).stakeAmount, stakeAmount);
    }

    function testFuzz_UpdateTrustScore(uint256 score) public {
        vm.assume(score <= 10_000);
        uint256 tokenId = _registerRobot(operator);

        vm.prank(attestationRegistry);
        robotId.updateTrustScore(tokenId, score);

        assertEq(robotId.getRobot(tokenId).trustScore, score);
    }

    // ============ Helper Functions ============

    function _registerRobot(address _operator) internal returns (uint256 tokenId) {
        bytes32 hardwareHash = keccak256(abi.encodePacked("hardware", _operator, block.timestamp));
        (bytes memory sig,) = _createRegistrationSignature(_operator, hardwareHash);

        vm.prank(_operator);
        tokenId = robotId.registerRobot(hardwareHash, sig, MIN_STAKE);
    }

    function _createRegistrationSignature(
        address _operator,
        bytes32 _hardwareHash
    ) internal view returns (bytes memory signature, uint256 nonce) {
        nonce = robotId.registrationNonces(_operator);

        bytes32 structHash = keccak256(
            abi.encode(
                robotId.REGISTRATION_TYPEHASH(),
                _operator,
                _hardwareHash,
                block.chainid,
                nonce
            )
        );

        bytes32 digest = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", structHash)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(hardwarePrivateKey, digest);
        signature = abi.encodePacked(r, s, v);
    }
}
