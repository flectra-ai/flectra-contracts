// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {RobotID} from "../src/RobotID.sol";
import {FlectraStaking} from "../src/FlectraStaking.sol";
import {AttestationRegistry} from "../src/AttestationRegistry.sol";

/**
 * @title DeployFlectra
 * @notice Deployment script for Flectra Protocol contracts
 * @dev Deploy with: forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
 */
contract DeployFlectra is Script {
    // ============ Network Constants ============

    // Base Mainnet
    address constant USDC_BASE_MAINNET = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    uint256 constant BASE_MAINNET_CHAIN_ID = 8453;

    // Base Sepolia (testnet)
    address constant USDC_BASE_SEPOLIA = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    uint256 constant BASE_SEPOLIA_CHAIN_ID = 84532;

    // ============ Configuration ============

    // Minimum stake: 100 USDC (6 decimals)
    uint256 constant MIN_STAKE = 100 * 1e6;

    // Lock period: 7 days
    uint256 constant LOCK_PERIOD = 7 days;

    // ============ Deployment ============

    function run() external {
        // Load deployer private key
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Determine network configuration
        address usdc;
        string memory networkName;

        if (block.chainid == BASE_MAINNET_CHAIN_ID) {
            usdc = USDC_BASE_MAINNET;
            networkName = "Base Mainnet";
        } else if (block.chainid == BASE_SEPOLIA_CHAIN_ID) {
            usdc = USDC_BASE_SEPOLIA;
            networkName = "Base Sepolia";
        } else {
            // Local/fork - deploy mock USDC
            revert("Unsupported network. Use Base Mainnet or Base Sepolia.");
        }

        console.log("========================================");
        console.log("    FLECTRA PROTOCOL DEPLOYMENT");
        console.log("========================================");
        console.log("");
        console.log("Network:     ", networkName);
        console.log("Chain ID:    ", block.chainid);
        console.log("Deployer:    ", deployer);
        console.log("USDC:        ", usdc);
        console.log("Min Stake:   ", MIN_STAKE / 1e6, "USDC");
        console.log("Lock Period: ", LOCK_PERIOD / 1 days, "days");
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy RobotID
        console.log("Deploying RobotID...");
        RobotID robotId = new RobotID(MIN_STAKE);
        console.log("  RobotID deployed at:", address(robotId));

        // 2. Deploy FlectraStaking
        console.log("Deploying FlectraStaking...");
        FlectraStaking staking = new FlectraStaking(
            usdc,
            MIN_STAKE,
            LOCK_PERIOD,
            deployer // Protocol treasury (update after deployment)
        );
        console.log("  FlectraStaking deployed at:", address(staking));

        // 3. Deploy AttestationRegistry
        console.log("Deploying AttestationRegistry...");
        AttestationRegistry registry = new AttestationRegistry();
        console.log("  AttestationRegistry deployed at:", address(registry));

        // 4. Configure contract references
        console.log("");
        console.log("Configuring contract references...");

        robotId.setStakingContract(address(staking));
        console.log("  RobotID -> StakingContract set");

        robotId.setAttestationRegistry(address(registry));
        console.log("  RobotID -> AttestationRegistry set");

        staking.setRobotIdContract(address(robotId));
        console.log("  Staking -> RobotID set");

        registry.setRobotIdContract(address(robotId));
        console.log("  Registry -> RobotID set");

        vm.stopBroadcast();

        // Log deployment summary
        console.log("");
        console.log("========================================");
        console.log("         DEPLOYMENT COMPLETE");
        console.log("========================================");
        console.log("");
        console.log("Contract Addresses:");
        console.log("  RobotID:            ", address(robotId));
        console.log("  FlectraStaking:     ", address(staking));
        console.log("  AttestationRegistry:", address(registry));
        console.log("");
        console.log("Next Steps:");
        console.log("  1. Verify contracts on BaseScan");
        console.log("  2. Update protocol treasury address");
        console.log("  3. Add authorized slashers if needed");
        console.log("  4. Test registration flow");
        console.log("");
    }
}

/**
 * @title DeployLocal
 * @notice Local deployment with mock USDC for testing
 */
contract DeployLocal is Script {
    function run() external {
        vm.startBroadcast();

        // Deploy mock USDC for local testing
        MockUSDC usdc = new MockUSDC();
        console.log("Mock USDC deployed:", address(usdc));

        // Deploy protocol
        RobotID robotId = new RobotID(100 * 1e6);
        FlectraStaking staking = new FlectraStaking(
            address(usdc),
            100 * 1e6,
            1 days, // Shorter lock for testing
            msg.sender
        );
        AttestationRegistry registry = new AttestationRegistry();

        // Configure
        robotId.setStakingContract(address(staking));
        robotId.setAttestationRegistry(address(registry));
        staking.setRobotIdContract(address(robotId));
        registry.setRobotIdContract(address(robotId));

        vm.stopBroadcast();

        console.log("RobotID:", address(robotId));
        console.log("Staking:", address(staking));
        console.log("Registry:", address(registry));
    }
}

/**
 * @title MockUSDC
 * @notice Simple mock USDC for local testing
 */
contract MockUSDC {
    string public constant name = "USD Coin";
    string public constant symbol = "USDC";
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}
