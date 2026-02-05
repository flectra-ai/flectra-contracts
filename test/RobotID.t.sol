// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {RobotID} from "../src/RobotID.sol";

contract RobotIDTest is Test {
    RobotID public robotId;

    address public owner = address(this);
    address public operator = address(0x1);
    address public attacker = address(0x2);

    uint256 public constant MIN_STAKE = 100 * 1e6; // 100 USDC

    function setUp() public {
        robotId = new RobotID(MIN_STAKE);
    }

    function test_Deployment() public view {
        assertEq(robotId.minStakeAmount(), MIN_STAKE);
        assertEq(robotId.owner(), owner);
        assertEq(robotId.name(), "Flectra Robot ID");
        assertEq(robotId.symbol(), "ROBOT");
    }

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
        address stakingContract = address(0x123);
        robotId.setStakingContract(stakingContract);
        assertEq(robotId.stakingContract(), stakingContract);
    }

    function test_SetAttestationRegistry() public {
        address registry = address(0x456);
        robotId.setAttestationRegistry(registry);
        assertEq(robotId.attestationRegistry(), registry);
    }

    // Additional tests would go here:
    // - test_RegisterRobot
    // - test_DeactivateRobot
    // - test_ReactivateRobot
    // - test_UpdateTrustScore
    // - test_IncrementAttestationCount
    // etc.
}
