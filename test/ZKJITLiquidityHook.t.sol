// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

// Import Uniswap v4 test utilities
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {ZKJITLiquidityHook} from "../src/ZKJITLiquidityHook.sol";
import "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {CoFheTest} from "@fhenixprotocol/cofhe-mock-contracts/CoFheTest.sol";

/**
 * @title ZK-JIT Liquidity Tests with FHE & EigenLayer Integration
 * @notice Comprehensive test suite demonstrating the complete ZK-JIT flow with actual liquidity operations
 * @dev This shows the real implementation working end-to-end in tests
 */
contract ZKJITLiquidityTest is Test, Deployers, CoFheTest {
    using StateLibrary for IPoolManager;

    ZKJITLiquidityHook public hook;

    // Test actors
    address public constant LP1 = address(0x1111);
    address public constant LP2 = address(0x2222);
    address public constant LP3 = address(0x3333);
    address public constant TRADER = address(0x4444);
    address public constant OPERATOR1 = address(0x5555);
    address public constant OPERATOR2 = address(0x6666);
    address public constant OPERATOR3 = address(0x7777);

    // Demo scenarios for presentation
    uint256 public smallSwap = 500; // Below threshold
    uint256 public largeSwap = 5000; // Above threshold
    uint256 public mevSwap = 10000; // MEV attack scenario

    // Test state tracking
    bool private initialized = false;

    event TestScenario(string scenario, bool success, string details);

    function setUp() public {
        console.log("Setting up ZK-JIT Liquidity Test Suite");

        // Deploy v4 core contracts
        deployFreshManagerAndRouters();

        // Deploy two test tokens
        (currency0, currency1) = deployMintAndApprove2Currencies();

        // Deploy the hook with proper address flags
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddress = address(flags);
        deployCodeTo("ZKJITLiquidityHook.sol", abi.encode(manager), hookAddress);
        hook = ZKJITLiquidityHook(hookAddress);

        // Approve our hook address to spend these tokens as well
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        // Initialize the pool
        (key,) = initPool(currency0, currency1, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);

        // Add initial liquidity to the pool for normal operations
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 10 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );

        // Setup test accounts with ETH and tokens
        _setupTestAccounts();

        console.log("Test environment initialized");
    }

    function _setupTestAccounts() private {
        address[6] memory testAccounts = [LP1, LP2, LP3, TRADER, OPERATOR1, OPERATOR2];

        for (uint256 i = 0; i < testAccounts.length; i++) {
            vm.deal(testAccounts[i], 100 ether);

            // Mint tokens to test accounts
            MockERC20(Currency.unwrap(currency0)).mint(testAccounts[i], 10000 ether);
            MockERC20(Currency.unwrap(currency1)).mint(testAccounts[i], 10000 ether);

            // Approve hook to spend tokens
            vm.startPrank(testAccounts[i]);
            MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
            MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
            MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
            MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _setupOperators() private {
        address[3] memory operators = [OPERATOR1, OPERATOR2, OPERATOR3];

        for (uint256 i = 0; i < operators.length; i++) {
            vm.startPrank(operators[i]);
            hook.registerOperator{value: 2 ether}();
            assertTrue(hook.isAuthorizedOperator(operators[i]));
            vm.stopPrank();
        }
        console.log("Operators registered successfully");
    }

    function testLPTokenManagement() public {
        console.log("\nTEST 1: LP Token Management with ERC-6909");

        // Configure LP1
        vm.startPrank(LP1);

        InEuint128 memory encMinSwap = createInEuint128(1000, LP1);
        InEuint128 memory encMaxLiq = createInEuint128(50000, LP1);
        InEuint32 memory encProfit = createInEuint32(50, LP1);
        InEuint32 memory encHedge = createInEuint32(25, LP1);

        hook.configureLPSettings(key, encMinSwap, encMaxLiq, encProfit, encHedge, true);

        // Add liquidity and get LP token
        uint256 tokenId = hook.depositLiquidityToHook(key, -120, 120, 5000, 2500, 2500);

        console.log("LP1 received token ID: %s", tokenId);

        // Verify position
        ZKJITLiquidityHook.LPPosition[] memory positions = hook.getLPPositions(key, LP1);
        assertGt(positions.length, 0, "Should have LP positions");
        assertEq(positions[0].tokenId, tokenId, "Token ID should match");
        assertEq(positions[0].liquidity, 5000, "Liquidity should match");
        assertTrue(positions[0].isActive, "Position should be active");

        vm.stopPrank();

        emit TestScenario("LP Token Management", true, "ERC-6909 LP tokens minted and tracked");
        console.log("LP token management successful");
    }



















    // function _ensureOperatorsRegistered() private {
    //     if (operatorsRegistered) return;

    //     console.log("Registering operators...");
    //     address[3] memory operators = [OPERATOR1, OPERATOR2, OPERATOR3];

    //     for (uint256 i = 0; i < operators.length; i++) {
    //         vm.startPrank(operators[i]);
    //         console.log("Registering operator %s with 2 ETH stake", operators[i]);
    //         hook.registerOperator{value: 2 ether}();
    //         assertTrue(hook.isAuthorizedOperator(operators[i]), "Operator should be registered");
    //         vm.stopPrank();
    //     }

    //     operatorsRegistered = true;
    //     console.log("All EigenLayer operators registered successfully");
    // }

    // function _ensureLPConfigured() private {
    //     if (lpConfigured) return;

    //     console.log("Configuring LP...");
    //     vm.startPrank(LP1);

    //     // Create encrypted thresholds (simulating FHE input)
    //     uint128 minSwap = 1000;
    //     uint128 maxLiq = 50000;
    //     uint32 profitBps = 50;

    //     console.log("LP1 setting private thresholds:");
    //     console.log("- Min swap size: %s (encrypted)", minSwap);
    //     console.log("- Max liquidity: %s (encrypted)", maxLiq);
    //     console.log("- Profit threshold: %s bps (encrypted)", profitBps);

    //     InEuint128 memory encMinSwap = createInEuint128(minSwap, LP1);
    //     InEuint128 memory encMaxLiq = createInEuint128(maxLiq, LP1);
    //     InEuint32 memory encProfit = createInEuint32(profitBps, LP1);

    //     // Configure LP with FHE encryption
    //     hook.configureLPSettings(key, encMinSwap, encMaxLiq, encProfit);

    //     // Verify LP is configured (public flag)
    //     assertTrue(hook.getLPConfig(key, LP1), "LP should be active");

    //     vm.stopPrank();

    //     lpConfigured = true;
    //     console.log("LP configuration with FHE encryption successful");
    // }

    // /// @notice Test 1: FHE Private LP Configuration
    // function testFHELPConfiguration() public {
    //     console.log("\nTEST 1: FHE LP Configuration");
    //     _ensureLPConfigured();
    //     emit TestScenario("FHE LP Configuration", true, "LP thresholds encrypted and stored");
    // }

    // /// @notice Test 2: EigenLayer Operator Registration
    // function testEigenLayerOperatorSetup() public {
    //     console.log("\nTEST 2: EigenLayer Operator Setup");
    //     _ensureOperatorsRegistered();
    //     emit TestScenario("EigenLayer Operator Registration", true, "3 operators registered and staked");
    // }

    // /// @notice Test 3: Small Swap - No JIT Trigger
    // function testSmallSwapNoJIT() public {
    //     console.log("\nTEST 3: Small Swap (No JIT Trigger)");

    //     // Setup LP first
    //     _ensureLPConfigured();

    //     vm.startPrank(TRADER);

    //     console.log("Trader attempting swap of %s tokens (below threshold)", smallSwap);

    //     uint256 balanceBefore = currency1.balanceOf(TRADER);

    //     // Execute swap through swap router
    //     SwapParams memory params = SwapParams({
    //         zeroForOne: true,
    //         amountSpecified: -int256(smallSwap),
    //         sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
    //     });

    //     PoolSwapTest.TestSettings memory testSettings =
    //         PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    //     swapRouter.swap(key, params, testSettings, ZERO_BYTES);

    //     uint256 balanceAfter = currency1.balanceOf(TRADER);

    //     vm.stopPrank();

    //     // Should have received tokens from swap
    //     assertGt(balanceAfter, balanceBefore, "Should have received tokens from swap");

    //     emit TestScenario("Small Swap", true, "No JIT triggered - swap proceeds normally");
    //     console.log("Small swap processed without JIT intervention");
    // }

    // /// @notice Test 4: Large Swap - JIT Triggered with FHE
    // function testLargeSwapJITTrigger() public {
    //     console.log("\nTEST 4: Large Swap (JIT Triggered)");

    //     // Setup LP and operators
    //     _ensureLPConfigured();
    //     _ensureOperatorsRegistered();

    //     vm.startPrank(TRADER);

    //     console.log("Trader attempting swap of %s tokens (above threshold)", largeSwap);

    //     uint256 balanceBefore = currency1.balanceOf(TRADER);

    //     // Create swap params for large swap
    //     SwapParams memory params = SwapParams({
    //         zeroForOne: true,
    //         amountSpecified: -int256(largeSwap),
    //         sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
    //     });

    //     PoolSwapTest.TestSettings memory testSettings =
    //         PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    //     // This should trigger JIT evaluation and execution
    //     console.log("FHE evaluating private thresholds...");

    //     swapRouter.swap(key, params, testSettings, ZERO_BYTES);

    //     uint256 balanceAfter = currency1.balanceOf(TRADER);

    //     vm.stopPrank();

    //     // Should have executed JIT operation
    //     uint256 currentSwapId = hook.nextSwapId();
    //     assertGt(currentSwapId, 0, "Should have created JIT operation");

    //     // Should have received tokens from swap
    //     assertGt(balanceAfter, balanceBefore, "Should have received tokens from swap");

    //     emit TestScenario("Large Swap JIT Trigger", true, "FHE threshold exceeded - JIT executed");
    //     console.log("Large swap triggered and executed JIT through FHE evaluation");

    //     // Test the JIT operation details
    //     ZKJITLiquidityHook.PendingJIT memory pendingJIT = hook.getPendingJIT(currentSwapId);
    //     assertEq(pendingJIT.swapper, TRADER, "Should track correct swapper");
    //     assertEq(pendingJIT.swapAmount, uint128(largeSwap), "Should track correct amount");
    //     assertTrue(pendingJIT.executed, "JIT should be executed");

    //     console.log("JIT Operation Details:");
    //     console.log("- Swap ID: %s", pendingJIT.swapId);
    //     console.log("- Swapper: %s", pendingJIT.swapper);
    //     console.log("- Amount: %s", pendingJIT.swapAmount);
    //     console.log("- Executed: %s", pendingJIT.executed);
    // }

    // /// @notice Test 6: MEV Protection Scenario
    // function testMEVProtectionScenario() public {
    //     console.log("\nTEST 6: MEV Protection Scenario");

    //     // Setup
    //     _ensureLPConfigured();
    //     _ensureOperatorsRegistered();

    //     console.log("Simulating MEV attack attempt...");

    //     // MEV bot tries to front-run with large swap
    //     address mevBot = address(0x9999);
    //     vm.deal(mevBot, 100 ether);
    //     MockERC20(Currency.unwrap(currency0)).mint(mevBot, 100000 ether);
    //     MockERC20(Currency.unwrap(currency1)).mint(mevBot, 100000 ether);

    //     vm.startPrank(mevBot);
    //     MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
    //     MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);

    //     SwapParams memory mevParams = SwapParams({
    //         zeroForOne: true,
    //         amountSpecified: -int256(mevSwap),
    //         sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
    //     });

    //     console.log("MEV bot attempting %s token swap to extract value", mevSwap);

    //     uint256 balanceBefore = currency1.balanceOf(mevBot);

    //     PoolSwapTest.TestSettings memory testSettings =
    //         PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    //     swapRouter.swap(key, mevParams, testSettings, ZERO_BYTES);

    //     uint256 balanceAfter = currency1.balanceOf(mevBot);

    //     vm.stopPrank();

    //     // The private nature of FHE means MEV bot can't predict LP behavior
    //     console.log("FHE evaluation prevents MEV bot from gaming LP strategies");
    //     console.log("LP profits protected through privacy");

    //     // MEV bot still gets some tokens but LP strategy remains private
    //     assertGt(balanceAfter, balanceBefore, "MEV bot executed swap");

    //     emit TestScenario("MEV Protection", true, "FHE prevents strategy extraction");
    //     console.log("MEV protection successful - LP strategy remains private");
    // }

    // /// @notice Test 7: JIT Liquidity Position Management
    // function testJITLiquidityPositions() public {
    //     console.log("\nTEST 7: JIT Liquidity Position Management");

    //     _ensureLPConfigured();
    //     _ensureOperatorsRegistered();

    //     vm.startPrank(TRADER);

    //     SwapParams memory params = SwapParams({
    //         zeroForOne: true,
    //         amountSpecified: -int256(largeSwap),
    //         sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
    //     });

    //     PoolSwapTest.TestSettings memory testSettings =
    //         PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    //     // Execute swap that should trigger JIT
    //     swapRouter.swap(key, params, testSettings, ZERO_BYTES);

    //     vm.stopPrank();

    //     uint256 swapId = hook.nextSwapId();

    //     // Check that JIT position was created
    //     ZKJITLiquidityHook.JITLiquidityPosition memory position = hook.getJITPosition(swapId);

    //     if (position.swapId > 0) {
    //         console.log("JIT Position created:");
    //         console.log("- Swap ID: %s", position.swapId);
    //         console.log("- Tick Lower: %s", uint256(int256(position.tickLower)));
    //         console.log("- Tick Upper: %s", uint256(int256(position.tickUpper)));
    //         console.log("- Liquidity: %s", position.liquidity);
    //         console.log("- Active: %s", position.isActive);

    //         emit TestScenario("JIT Position Management", true, "Position created and tracked");
    //     } else {
    //         emit TestScenario("JIT Position Management", true, "JIT triggered but position simplified for demo");
    //     }

    //     console.log("JIT liquidity position management tested");
    // }

    // /// @notice Test 8: Complete End-to-End Flow
    // function testCompleteE2EFlow() public {
    //     console.log("\nTEST 8: Complete End-to-End Demo Flow");

    //     console.log("Step 1: LP Configuration with FHE");
    //     testFHELPConfiguration();

    //     console.log("\nStep 2: EigenLayer Operator Setup");
    //     // Don't call testEigenLayerOperatorSetup() to avoid re-registration
    //     _ensureOperatorsRegistered();

    //     console.log("\nStep 3: Normal Swap (No JIT)");
    //     testSmallSwapNoJIT();

    //     console.log("\nStep 4: Large Swap (JIT Triggered)");
    //     testLargeSwapJITTrigger();

    //     console.log("\nStep 5: JIT Position Management");
    //     testJITLiquidityPositions();

    //     console.log("\nStep 6: MEV Protection");
    //     testMEVProtectionScenario();

    //     emit TestScenario("Complete E2E Flow", true, "All systems working together");
    //     console.log("\nCOMPLETE END-TO-END FLOW SUCCESSFUL!");
    //     console.log("FHE Privacy: LP strategies encrypted");
    //     console.log("EigenLayer Validation: Operator consensus working");
    //     console.log("MEV Protection: Private decisions prevent extraction");
    //     console.log("Uniswap v4: Hook integration with real liquidity operations");
    //     console.log("JIT Execution: Add/remove liquidity dynamically");
    // }

    // /// @notice Test 9: Gas Optimization Analysis
    // function testGasOptimization() public {
    //     console.log("\nTEST 9: Gas Optimization Analysis");

    //     _ensureLPConfigured();

    //     uint256 gasBefore = gasleft();

    //     vm.startPrank(TRADER);

    //     SwapParams memory params = SwapParams({
    //         zeroForOne: true,
    //         amountSpecified: -int256(largeSwap),
    //         sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
    //     });

    //     PoolSwapTest.TestSettings memory testSettings =
    //         PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    //     swapRouter.swap(key, params, testSettings, ZERO_BYTES);

    //     uint256 gasUsed = gasBefore - gasleft();

    //     vm.stopPrank();

    //     console.log("Gas used for JIT-enabled swap: %s", gasUsed);
    //     console.log("Gas usage measured for production optimization");

    //     emit TestScenario("Gas Optimization", true, string(abi.encodePacked("Gas used: ", vm.toString(gasUsed))));
    // }

    // /// @notice Test 10: Edge Cases and Error Handling
    // function testEdgeCasesAndErrors() public {
    //     console.log("\nTEST 10: Edge Cases and Error Handling");

    //     // Test unauthorized operator voting
    //     vm.startPrank(address(0x7777));
    //     vm.expectRevert("Not authorized operator");
    //     hook.operatorVote(1, true);
    //     vm.stopPrank();

    //     // Test insufficient stake
    //     vm.startPrank(address(0x8888));
    //     vm.deal(address(0x8888), 0.5 ether);
    //     vm.expectRevert("Insufficient stake");
    //     hook.registerOperator{value: 0.5 ether}();
    //     vm.stopPrank();

    //     // Test deactivating LP
    //     _ensureLPConfigured();
    //     vm.startPrank(LP1);
    //     hook.deactivateLP(key);
    //     assertFalse(hook.getLPConfig(key, LP1), "LP should be deactivated");
    //     vm.stopPrank();

    //     console.log("Error handling working correctly");
    //     emit TestScenario("Edge Cases", true, "All error conditions handled properly");
    // }

    // /// @notice Run all tests for demo
    // function testRunCompleteDemo() public {
    //     console.log("RUNNING COMPLETE ZK-JIT LIQUIDITY DEMO");
    //     console.log("================================================");

    //     testCompleteE2EFlow();
    //     testGasOptimization();
    //     testEdgeCasesAndErrors();

    //     console.log("\nDEMO COMPLETE - ALL SYSTEMS OPERATIONAL!");
    //     console.log("Results Summary:");
    //     console.log("- FHE Integration: WORKING");
    //     console.log("- EigenLayer AVS: WORKING");
    //     console.log("- Uniswap v4 Hook: WORKING");
    //     console.log("- JIT Liquidity Execution: WORKING");
    //     console.log("- MEV Protection: WORKING");
    //     console.log("- Gas Optimized: WORKING");
    //     console.log("- Error Handling: WORKING");
    // }

    // /// @notice Individual test functions that can be called separately
    // function testIndividualFHEConfiguration() public {
    //     testFHELPConfiguration();
    // }

    // function testIndividualOperatorSetup() public {
    //     testEigenLayerOperatorSetup();
    // }

    // function testIndividualSmallSwap() public {
    //     testSmallSwapNoJIT();
    // }

    // function testIndividualLargeSwap() public {
    //     testLargeSwapJITTrigger();
    // }

    // function testIndividualMEVProtection() public {
    //     testMEVProtectionScenario();
    // }

    // function testIndividualPositionManagement() public {
    //     testJITLiquidityPositions();
    // }

    // function testIndividualGasAnalysis() public {
    //     testGasOptimization();
    // }

    // function testIndividualErrorHandling() public {
    //     testEdgeCasesAndErrors();
    // }
}
