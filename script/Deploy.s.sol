// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {RobotID} from "../src/RobotID.sol";
import {FlectraStaking} from "../src/FlectraStaking.sol";
import {AttestationRegistry} from "../src/AttestationRegistry.sol";

contract DeployFlectra is Script {
    // Base Mainnet USDC
    address constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    // Base Sepolia USDC (mock)
    address constant USDC_BASE_SEPOLIA = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    // Minimum stake: 100 USDC (6 decimals)
    uint256 constant MIN_STAKE = 100 * 1e6;

    // Lock period: 7 days
    uint256 constant LOCK_PERIOD = 7 days;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Determine USDC address based on chain
        address usdc = block.chainid == 8453 ? USDC_BASE : USDC_BASE_SEPOLIA;

        console.log("Deploying Flectra Protocol...");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("USDC:", usdc);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy RobotID
        RobotID robotId = new RobotID(MIN_STAKE);
        console.log("RobotID deployed:", address(robotId));

        // 2. Deploy FlectraStaking
        FlectraStaking staking = new FlectraStaking(
            usdc,
            MIN_STAKE,
            LOCK_PERIOD,
            deployer // Protocol treasury
        );
        console.log("FlectraStaking deployed:", address(staking));

        // 3. Deploy AttestationRegistry
        AttestationRegistry registry = new AttestationRegistry();
        console.log("AttestationRegistry deployed:", address(registry));

        // 4. Configure contracts
        robotId.setStakingContract(address(staking));
        robotId.setAttestationRegistry(address(registry));
        staking.setRobotIdContract(address(robotId));
        registry.setRobotIdContract(address(robotId));

        console.log("Contracts configured.");

        vm.stopBroadcast();

        // Log deployment summary
        console.log("\n========== DEPLOYMENT SUMMARY ==========");
        console.log("RobotID:            ", address(robotId));
        console.log("FlectraStaking:     ", address(staking));
        console.log("AttestationRegistry:", address(registry));
        console.log("=========================================\n");
    }
}
