// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ZK-JIT Liquidity Hook
 * @notice Privacy-preserving JIT liquidity with LP token management, profit hedging, and dynamic pricing
 * @dev Integrates Fhenix FHE, EigenLayer validation, ERC-6909 LP tokens, and dynamic fee structures
 */
contract ZKJITLiquidityHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

    enum CallbackType {
        AddToHook,
        RemoveFromHook,
        AddToPool,
        RemoveFromPool
    }

    // ============ LP Token Management Structures ============

    struct LPPosition {
        uint256 tokenId; // ERC-6909 token ID
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 token0Amount;
        uint128 token1Amount;
        uint256 lastFeeGrowth0; // For fee accrual tracking
        uint256 lastFeeGrowth1;
        uint256 uncollectedFees0;
        uint256 uncollectedFees1;
        bool isActive;
    }

    struct CallbackData {
        uint256 amountEach; // Amount of each token to add as liquidity
        Currency currency0;
        Currency currency1;
        address sender;
        CallbackType callbackType;
    }

    struct LPConfig {
        euint128 minSwapSize; // Encrypted minimum swap size to trigger JIT
        euint128 maxLiquidity; // Encrypted maximum liquidity to provide
        euint32 profitThresholdBps; // Encrypted profit threshold in basis points
        euint32 hedgePercentage; // Encrypted percentage to auto-hedge (0-100)
        bool isActive; // Public flag for LP participation
        bool autoHedgeEnabled; // Whether to automatically hedge profits
    }

    struct PendingJIT {
        uint256 swapId;
        address swapper;
        uint128 swapAmount;
        address tokenIn;
        address tokenOut;
        uint256 blockNumber;
        uint256 validatorConsensus; // Bitmap of validator approvals
        bool executed;
        bool zeroForOne; // Direction of the swap
        PoolKey poolKey; // Store the pool key for execution
        address[] eligibleLPs; // LPs that can participate in this JIT
        uint128[] liquidityContributions; // How much each LP will contribute
    }

    // JIT liquidity for a given range
    struct JITLiquidityPosition {
        uint256 swapId;
        int24 tickLower;
        int24 tickUpper;
        uint128 totalLiquidity;
        address[] participatingLPs;
        uint128[] lpContributions;
        bool isActive;
        uint256 timestamp;
    }

    // ============ Storage ============

    // LP Management
    mapping(PoolId => mapping(address => LPConfig)) public lpConfigs;
    mapping(PoolId => mapping(address => LPPosition[])) public lpPositions;
    mapping(PoolId => mapping(uint256 => address)) public tokenIdToLP; // tokenId -> LP address
    mapping(PoolId => address[]) public poolLPs;
    mapping(PoolId => mapping(address => bool)) public isLPRegistered;
    mapping(PoolId => mapping(address => uint256)) public lpProfits0; // Accumulated profits
    mapping(PoolId => mapping(address => uint256)) public lpProfits1;

    // JIT Operations
    mapping(uint256 => PendingJIT) public pendingJITs;
    mapping(uint256 => JITLiquidityPosition) public jitPositions;
    uint256 public nextSwapId;
    uint256 public nextTokenId = 1;

    // EigenLayer operator simulation
    mapping(address => bool) public authorizedOperators;
    mapping(address => uint256) public operatorStake;
    address[] public operators;

    // Constants
    uint256 private constant MIN_OPERATORS = 3;
    uint256 private constant CONSENSUS_THRESHOLD = 66; // 66% consensus needed
    uint256 private constant JIT_DELAY_BLOCKS = 1; // Reduced for demo
    int24 private constant TICK_RANGE = 60; // Range around current tick for JIT liquidity
    uint24 private constant BASE_DYNAMIC_FEE = 3000; // 0.3% base fee

    uint128 public movingAverageGasPrice;
    uint104 public movingAverageGasPriceCount;

    error MustUseDynamicFee();

    // FHE Constants
    euint128 private ENCRYPTED_ZERO;
    euint32 private ENCRYPTED_ZERO_32;

    // ============ Events ============

    event LPTokenMinted(address indexed lp, PoolId indexed poolId, uint256 tokenId, uint128 liquidity);
    event LPTokenBurned(address indexed lp, PoolId indexed poolId, uint256 tokenId, uint128 liquidity);
    event LiquidityAdded(
        address indexed lp, PoolId indexed poolId, int24 tickLower, int24 tickUpper, uint128 liquidity
    );
    event LiquidityRemoved(address indexed lp, PoolId indexed poolId, uint128 liquidity);
    event ProfitHedged(address indexed lp, PoolId indexed poolId, uint256 amount0, uint256 amount1);
    event JITMultiLPExecution(uint256 indexed swapId, address[] lps, uint128[] contributions);
    event LPConfigSet(PoolId indexed poolId, address indexed lp, bool isActive);
    event JITRequested(uint256 indexed swapId, PoolId indexed poolId, address indexed swapper, uint128 swapAmount);
    event JITExecuted(uint256 indexed swapId, PoolId indexed poolId, uint128 liquidityProvided);
    event OperatorVoted(uint256 indexed swapId, address indexed operator, bool approved);

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        updateMovingAverage();

        // Initialize FHE constants
        ENCRYPTED_ZERO = FHE.asEuint128(0);
        ENCRYPTED_ZERO_32 = FHE.asEuint32(0);

        // Grant contract access to constants
        FHE.allowThis(ENCRYPTED_ZERO);
        FHE.allowThis(ENCRYPTED_ZERO_32);
    }

    // ============ Hook Permissions ============

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true, // Validate dynamic fee usage
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // Intercept swaps for JIT logic
            afterSwap: true, // Execute JIT after swap completion
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true, // Modify swap behavior
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /**
     * @notice Initialize dynamic pricing for a pool
     */
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal pure override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();

        return this.beforeInitialize.selector;
    }

    // ============ LP Management Functions ============

    /**
     * @notice Configure LP's private JIT parameters and hedge settings using FHE
     */
    function configureLPSettings(
        PoolKey calldata poolKey,
        InEuint128 calldata minSwapSize,
        InEuint128 calldata maxLiquidity,
        InEuint32 calldata profitThreshold,
        InEuint32 calldata hedgePercentage,
        bool autoHedgeEnabled
    ) external {
        PoolId poolId = poolKey.toId();

        // Create encrypted values
        euint128 encMinSwap = FHE.asEuint128(minSwapSize);
        euint128 encMaxLiq = FHE.asEuint128(maxLiquidity);
        euint32 encProfit = FHE.asEuint32(profitThreshold);
        euint32 encHedge = FHE.asEuint32(hedgePercentage);

        // Store configuration
        lpConfigs[poolId][msg.sender] = LPConfig({
            minSwapSize: encMinSwap,
            maxLiquidity: encMaxLiq,
            profitThresholdBps: encProfit,
            hedgePercentage: encHedge,
            isActive: true,
            autoHedgeEnabled: autoHedgeEnabled
        });

        // Add LP to pool's LP list if not already registered
        if (!isLPRegistered[poolId][msg.sender]) {
            poolLPs[poolId].push(msg.sender);
            isLPRegistered[poolId][msg.sender] = true;
        }

        // Grant access permissions
        FHE.allowThis(encMinSwap);
        FHE.allowThis(encMaxLiq);
        FHE.allowThis(encProfit);
        FHE.allowThis(encHedge);
        FHE.allowSender(encMinSwap);
        FHE.allowSender(encMaxLiq);
        FHE.allowSender(encProfit);
        FHE.allowSender(encHedge);

        emit LPConfigSet(poolId, msg.sender, true);
    }

    /**
     * @notice Add liquidity and mint ERC-6909 LP token
     */
    function depositLiquidityToHook(
        PoolKey calldata poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidityDelta,
        uint128 amount0Max,
        uint128 amount1Max
    ) public returns (uint256 tokenId) {
        require(liquidityDelta > 0, "Invalid liquidity");

        PoolId poolId = poolKey.toId();

        // Create new token ID
        tokenId = nextTokenId++;

        // Store the position
        LPPosition memory newPosition = LPPosition({
            tokenId: tokenId,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidityDelta,
            token0Amount: amount0Max, // Simplified - in production would calculate exact amounts
            token1Amount: amount1Max,
            lastFeeGrowth0: 0,
            lastFeeGrowth1: 0,
            uncollectedFees0: 0,
            uncollectedFees1: 0,
            isActive: true
        });

        lpPositions[poolId][msg.sender].push(newPosition);
        tokenIdToLP[poolId][tokenId] = msg.sender;

        poolManager.unlock(abi.encode(CallbackData(amount0Max, poolKey.currency0, poolKey.currency1, msg.sender, CallbackType.AddToHook)));

        emit LPTokenMinted(msg.sender, poolId, tokenId, liquidityDelta);
        emit LiquidityAdded(msg.sender, poolId, tickLower, tickUpper, liquidityDelta);

        return tokenId;
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        CallbackData memory callbackData = abi.decode(data, (CallbackData));

        if (callbackData.callbackType == CallbackType.AddToHook) {
            // For deposits: LP provides tokens to hook
            callbackData.currency0.settle(poolManager, callbackData.sender, callbackData.amountEach, false);
            callbackData.currency1.settle(poolManager, callbackData.sender, callbackData.amountEach, false);

            // Mint ERC-6909 tokens (simplified)
            callbackData.currency0.take(poolManager, address(this), callbackData.amountEach, true);
            callbackData.currency1.take(poolManager, address(this), callbackData.amountEach, true);

            return "";
        } else if (callbackData.callbackType == CallbackType.RemoveFromHook) {
            // For withdrawals: hook provides tokens to LP
            // First settle from hook's balance to pool manager
            callbackData.currency0.settle(poolManager, address(this), callbackData.amountEach, false);
            callbackData.currency1.settle(poolManager, address(this), callbackData.amountEach, false);

            // Then take to LP
            callbackData.currency0.take(poolManager, callbackData.sender, callbackData.amountEach, true);
            callbackData.currency1.take(poolManager, callbackData.sender, callbackData.amountEach, true);

            return "";
        } else if (callbackData.callbackType == CallbackType.AddToPool) {
            // For adding liquidity to pool - simplified
            return "";
        } else if (callbackData.callbackType == CallbackType.RemoveFromPool) {
            // For removing liquidity from pool - simplified
            return "";
        } else {
            revert("Invalid callback type");
        }
    }

    /**
     * @notice Remove liquidity and burn ERC-6909 LP token
     */
    function removeLiquidityFromHook(PoolKey calldata poolKey, uint256 tokenId, uint128 liquidityDelta)
        external
        returns (uint128 amount0, uint128 amount1)
    {
        PoolId poolId = poolKey.toId();
        require(tokenIdToLP[poolId][tokenId] == msg.sender, "Not token owner");

        // Find and update the position
        LPPosition[] storage positions = lpPositions[poolId][msg.sender];
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].tokenId == tokenId) {
                require(positions[i].liquidity >= liquidityDelta, "Insufficient liquidity");

                // Calculate proportional amounts to return
                amount0 = uint128((uint256(positions[i].token0Amount) * liquidityDelta) / positions[i].liquidity);
                amount1 = uint128((uint256(positions[i].token1Amount) * liquidityDelta) / positions[i].liquidity);

                // Update position
                positions[i].liquidity -= liquidityDelta;
                positions[i].token0Amount -= amount0;
                positions[i].token1Amount -= amount1;

                if (positions[i].liquidity == 0) {
                    positions[i].isActive = false;
                }

                poolManager.unlock(
                    abi.encode(CallbackData(amount0, poolKey.currency0, poolKey.currency1, msg.sender, CallbackType.RemoveFromHook))
                );

                emit LPTokenBurned(msg.sender, poolId, tokenId, liquidityDelta);
                emit LiquidityRemoved(msg.sender, poolId, liquidityDelta);

                break;
            }
        }

        return (amount0, amount1);
    }

    /**
     * @notice Hedge LP profits - transfers profits back to LP wallet
     */
    function hedgeProfits(PoolKey calldata poolKey, uint256 hedgePercentage) public {
        require(hedgePercentage <= 100, "Invalid percentage");
        PoolId poolId = poolKey.toId();

        uint256 profit0 = lpProfits0[poolId][msg.sender];
        uint256 profit1 = lpProfits1[poolId][msg.sender];

        if (profit0 > 0 || profit1 > 0) {
            uint256 hedgeAmount0 = (profit0 * hedgePercentage) / 100;
            uint256 hedgeAmount1 = (profit1 * hedgePercentage) / 100;

            // Update tracked profits
            lpProfits0[poolId][msg.sender] -= hedgeAmount0;
            lpProfits1[poolId][msg.sender] -= hedgeAmount1;

            // Direct transfer from hook's accumulated reserves
            if (hedgeAmount0 > 0) {
                require(
                    IERC20(Currency.unwrap(poolKey.currency0)).balanceOf(address(this)) >= hedgeAmount0,
                    "Insufficient hook reserves for token0"
                );
                IERC20(Currency.unwrap(poolKey.currency0)).transfer(msg.sender, hedgeAmount0);
            }

            if (hedgeAmount1 > 0) {
                require(
                    IERC20(Currency.unwrap(poolKey.currency1)).balanceOf(address(this)) >= hedgeAmount1,
                    "Insufficient hook reserves for token1"
                );
                IERC20(Currency.unwrap(poolKey.currency1)).transfer(msg.sender, hedgeAmount1);
            }

            emit ProfitHedged(msg.sender, poolId, hedgeAmount0, hedgeAmount1);
        }
    }

    /**
     * @notice Auto-hedge profits based on LP configuration
     */
    function _autoHedgeProfits(PoolId poolId, address lp) private {
        LPConfig memory config = lpConfigs[poolId][lp];
        if (!config.autoHedgeEnabled) return;

        // In a real implementation, this would decrypt the hedge percentage
        // For demo purposes, assume 50% auto-hedge
        uint256 hedgePercentage = 50;

        uint256 profit0 = lpProfits0[poolId][lp];
        uint256 profit1 = lpProfits1[poolId][lp];

        if (profit0 > 0 || profit1 > 0) {
            uint256 hedgeAmount0 = (profit0 * hedgePercentage) / 100;
            uint256 hedgeAmount1 = (profit1 * hedgePercentage) / 100;

            // Update tracked profits
            lpProfits0[poolId][lp] -= hedgeAmount0;
            lpProfits1[poolId][lp] -= hedgeAmount1;

            // Note: In a real implementation, we'd need to handle the transfer
            // For demo purposes, we just emit the event
            emit ProfitHedged(lp, poolId, hedgeAmount0, hedgeAmount1);
        }
    }

    // ============ Dynamic Pricing Functions ============

    // Update our moving average gas price
    function updateMovingAverage() internal {
        uint128 gasPrice = uint128(tx.gasprice);

        // New Average = ((Old Average * # of Txns Tracked) + Current Gas Price) / (# of Txns Tracked + 1)
        movingAverageGasPrice =
            ((movingAverageGasPrice * movingAverageGasPriceCount) + gasPrice) / (movingAverageGasPriceCount + 1);

        movingAverageGasPriceCount++;
    }

    function getFee() internal view returns (uint24) {
        uint128 gasPrice = uint128(tx.gasprice);

        // if gasPrice > movingAverageGasPrice * 1.1, then half the fees
        if (gasPrice > (movingAverageGasPrice * 11) / 10) {
            return BASE_DYNAMIC_FEE / 2;
        }

        // if gasPrice < movingAverageGasPrice * 0.9, then double the fees
        if (gasPrice < (movingAverageGasPrice * 9) / 10) {
            return BASE_DYNAMIC_FEE * 2;
        }

        return BASE_DYNAMIC_FEE;
    }

    // ============ Multi-LP JIT Logic ============

    /**
     * @notice Evaluate which LPs want to participate in JIT for overlapping ranges
     */
    function _evaluateMultiLPJIT(PoolKey calldata key, uint128 swapAmount)
        private
        returns (address[] memory, uint128[] memory)
    {
        PoolId poolId = key.toId();
        address[] memory eligibleLPs = new address[](poolLPs[poolId].length);
        uint128[] memory contributions = new uint128[](poolLPs[poolId].length);
        uint256 eligibleCount = 0;

        euint128 encSwapAmount = FHE.asEuint128(swapAmount);
        FHE.allowThis(encSwapAmount);

        // Get current tick to check overlapping ranges
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);

        for (uint256 i = 0; i < poolLPs[poolId].length; i++) {
            address lp = poolLPs[poolId][i];
            LPConfig memory config = lpConfigs[poolId][lp];

            if (config.isActive) {
                // Check if LP has positions overlapping with current tick range
                bool hasOverlappingPosition = _hasOverlappingPosition(poolId, lp, currentTick);

                if (hasOverlappingPosition) {
                    // Private threshold check (simplified for demo)
                    if (swapAmount > 1000) {
                        // Demo threshold
                        eligibleLPs[eligibleCount] = lp;
                        // Calculate contribution based on LP's max liquidity and current exposure
                        contributions[eligibleCount] = _calculateLPContribution(poolId, lp, swapAmount);
                        eligibleCount++;
                    }
                }
            }
        }

        // Resize arrays to actual eligible count
        address[] memory finalLPs = new address[](eligibleCount);
        uint128[] memory finalContributions = new uint128[](eligibleCount);

        for (uint256 i = 0; i < eligibleCount; i++) {
            finalLPs[i] = eligibleLPs[i];
            finalContributions[i] = contributions[i];
        }

        return (finalLPs, finalContributions);
    }

    /**
     * @notice Check if LP has positions overlapping with current tick range
     */
    function _hasOverlappingPosition(PoolId poolId, address lp, int24 currentTick) private view returns (bool) {
        LPPosition[] memory positions = lpPositions[poolId][lp];

        int24 jitLower = currentTick - TICK_RANGE;
        int24 jitUpper = currentTick + TICK_RANGE;

        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].isActive) {
                // Check if position overlaps with JIT range
                if (positions[i].tickLower <= jitUpper && positions[i].tickUpper >= jitLower) {
                    return true;
                }
            }
        }

        return false;
    }

    /**
     * @notice Calculate how much an LP should contribute to JIT
     */
    function _calculateLPContribution(PoolId poolId, address lp, uint128 swapAmount) private view returns (uint128) {
        // Simplified calculation - in production would consider:
        // 1. LP's available liquidity
        // 2. LP's risk tolerance (from encrypted config)
        // 3. LP's current exposure
        // 4. Expected profitability

        LPPosition[] memory positions = lpPositions[poolId][lp];
        uint128 totalLiquidity = 0;

        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].isActive) {
                totalLiquidity += positions[i].liquidity;
            }
        }

        // Cap contribution at 10% of swap amount or 50% of LP's liquidity
        uint128 maxContribution = swapAmount / 10;
        uint128 lpCapacity = totalLiquidity / 2;

        return maxContribution < lpCapacity ? maxContribution : lpCapacity;
    }

    // ============ Hook Implementation ============

    /**
     * @notice Before swap hook - evaluates multi-LP JIT with dynamic pricing
     */
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint128 swapAmount =
            uint128(params.amountSpecified > 0 ? uint256(params.amountSpecified) : uint256(-params.amountSpecified));

        // Evaluate multi-LP JIT participation
        (address[] memory eligibleLPs, uint128[] memory contributions) = _evaluateMultiLPJIT(key, swapAmount);

        if (eligibleLPs.length > 0) {
            // Create pending multi-LP JIT request
            uint256 swapId = _createMultiLPJIT(key, sender, swapAmount, params, eligibleLPs, contributions);

            // Auto-execute for demo
            _autoExecuteMultiLPJIT(swapId);
        }

        uint24 dynamicFee = getFee();
        uint24 feeWithFlag = dynamicFee | LPFeeLibrary.OVERRIDE_FEE_FLAG;

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeWithFlag);
    }

    /**
     * @notice Create multi-LP JIT request
     */
    function _createMultiLPJIT(
        PoolKey calldata key,
        address swapper,
        uint128 swapAmount,
        SwapParams calldata params,
        address[] memory eligibleLPs,
        uint128[] memory contributions
    ) private returns (uint256) {
        uint256 swapId = ++nextSwapId;

        pendingJITs[swapId] = PendingJIT({
            swapId: swapId,
            swapper: swapper,
            swapAmount: swapAmount,
            tokenIn: params.zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1),
            tokenOut: params.zeroForOne ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0),
            blockNumber: block.number,
            validatorConsensus: 0,
            executed: false,
            zeroForOne: params.zeroForOne,
            poolKey: key,
            eligibleLPs: eligibleLPs,
            liquidityContributions: contributions
        });

        emit JITRequested(swapId, key.toId(), swapper, swapAmount);
        return swapId;
    }

    /**
     * @notice Auto-execute multi-LP JIT for demo
     */
    function _autoExecuteMultiLPJIT(uint256 swapId) private {
        PendingJIT storage jit = pendingJITs[swapId];
        require(!jit.executed, "Already executed");

        // Add multi-LP JIT liquidity
        _addMultiLPJITLiquidity(jit.poolKey, swapId, jit.eligibleLPs, jit.liquidityContributions);

        jit.executed = true;
        emit JITMultiLPExecution(swapId, jit.eligibleLPs, jit.liquidityContributions);
    }

    /**
     * @notice Add JIT liquidity from multiple LPs
     */
    function _addMultiLPJITLiquidity(
        PoolKey memory key,
        uint256 swapId,
        address[] memory lps,
        uint128[] memory contributions
    ) private {
        // Get current tick
        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());

        // Calculate tick range for liquidity
        int24 tickLower = ((currentTick - TICK_RANGE) / key.tickSpacing) * key.tickSpacing;
        int24 tickUpper = ((currentTick + TICK_RANGE) / key.tickSpacing) * key.tickSpacing;

        // Sum total liquidity contributions
        uint128 totalLiquidity = 0;
        for (uint256 i = 0; i < contributions.length; i++) {
            totalLiquidity += contributions[i];
        }

        if (totalLiquidity > 0) {
            // Store the multi-LP JIT position
            jitPositions[swapId] = JITLiquidityPosition({
                swapId: swapId,
                tickLower: tickLower,
                tickUpper: tickUpper,
                totalLiquidity: totalLiquidity,
                participatingLPs: lps,
                lpContributions: contributions,
                isActive: true,
                timestamp: block.timestamp
            });
        }
    }

    /**
     * @notice Simple profit calculation based on swap fees
     */
    function _calculateAndDistributeProfits(
        PoolKey memory key,
        uint256 swapId,
        address[] memory lps,
        uint128[] memory contributions
    ) internal {
        PoolId poolId = key.toId();
        JITLiquidityPosition storage position = jitPositions[swapId];
        if (!position.isActive) return;
        (uint256 feeGrowthGlobal0, uint256 feeGrowthGlobal1) = StateLibrary.getFeeGrowthGlobals(poolManager, poolId);
        uint128 totalLiquidity = position.totalLiquidity;
        if (totalLiquidity == 0) return;
        for (uint256 i = 0; i < lps.length; i++) {
            _distributeLPFees(
                poolId, lps[i], contributions[i], totalLiquidity, feeGrowthGlobal0, feeGrowthGlobal1, swapId
            );
        }
    }

    /**
     * @notice Helper function to distribute fees for a single LP
     */
    function _distributeLPFees(
        PoolId poolId,
        address lp,
        uint128 contribution,
        uint128 totalLiquidity,
        uint256 feeGrowthGlobal0,
        uint256 feeGrowthGlobal1,
        uint256 swapId
    ) private {
        LPPosition[] storage lpPositionsArray = lpPositions[poolId][lp];
        uint256 lpFees0 = 0;
        uint256 lpFees1 = 0;
        JITLiquidityPosition storage jitPos = jitPositions[swapId];
        for (uint256 j = 0; j < lpPositionsArray.length; j++) {
            LPPosition storage pos = lpPositionsArray[j];
            if (pos.isActive && pos.tickLower <= jitPos.tickUpper && pos.tickUpper >= jitPos.tickLower) {
                uint256 fees0 = ((feeGrowthGlobal0 - pos.lastFeeGrowth0) * pos.liquidity) / 1e18;
                uint256 fees1 = ((feeGrowthGlobal1 - pos.lastFeeGrowth1) * pos.liquidity) / 1e18;
                pos.uncollectedFees0 += fees0;
                pos.uncollectedFees1 += fees1;
                pos.lastFeeGrowth0 = feeGrowthGlobal0;
                pos.lastFeeGrowth1 = feeGrowthGlobal1;
                lpFees0 += (fees0 * contribution) / totalLiquidity;
                lpFees1 += (fees1 * contribution) / totalLiquidity;
            }
        }
        if (lpFees0 > 0 || lpFees1 > 0) {
            lpProfits0[poolId][lp] += lpFees0;
            lpProfits1[poolId][lp] += lpFees1;
            _autoHedgeProfits(poolId, lp);
        }
    }

    /**
     * @notice After swap hook - cleanup and finalize
     */
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        uint256 currentSwapId = nextSwapId;
        if (currentSwapId > 0) {
            JITLiquidityPosition storage position = jitPositions[currentSwapId];
            if (position.isActive) {
                _calculateAndDistributeProfits(key, currentSwapId, position.participatingLPs, position.lpContributions);
                _removeJITLiquidity(key, currentSwapId);
            }
        }
        updateMovingAverage();
        return (this.afterSwap.selector, 0);
    }

    /**
     * @notice Remove JIT liquidity after swap execution
     */
    function _removeJITLiquidity(PoolKey calldata key, uint256 swapId) private {
        JITLiquidityPosition storage position = jitPositions[swapId];
        if (position.isActive) {
            position.isActive = false;
            // Final profit distribution
            for (uint256 i = 0; i < position.participatingLPs.length; i++) {
                address lp = position.participatingLPs[i];
                uint128 contribution = position.lpContributions[i];
                lpProfits0[key.toId()][lp] += contribution / 20;
                lpProfits1[key.toId()][lp] += contribution / 20;
                _autoHedgeProfits(key.toId(), lp);
            }
        }
    }

    // ============ EigenLayer Operator Functions ============

    /**
     * @notice Register as an EigenLayer operator (simplified for hackathon)
     */
    function registerOperator() external payable {
        require(msg.value >= 1 ether, "Insufficient stake");
        require(!authorizedOperators[msg.sender], "Already registered");

        authorizedOperators[msg.sender] = true;
        operatorStake[msg.sender] = msg.value;
        operators.push(msg.sender);
    }

    /**
     * @notice Operator votes on JIT trigger validity
     */
    function operatorVote(uint256 swapId, bool approved) external {
        require(authorizedOperators[msg.sender], "Not authorized operator");
        require(!pendingJITs[swapId].executed, "Already executed");
        require(block.number >= pendingJITs[swapId].blockNumber + JIT_DELAY_BLOCKS, "Too early to vote");

        uint256 operatorIndex = _getOperatorIndex(msg.sender);
        if (approved) {
            pendingJITs[swapId].validatorConsensus |= (1 << operatorIndex);
        }

        emit OperatorVoted(swapId, msg.sender, approved);

        if (_hasConsensus(swapId)) {
            _executeJIT(swapId);
        }
    }

    /**
     * @notice Check if operator consensus is reached
     */
    function _hasConsensus(uint256 swapId) private view returns (bool) {
        uint256 approvals = _countBits(pendingJITs[swapId].validatorConsensus);
        uint256 totalOperators = operators.length;
        return totalOperators > 0 && (approvals * 100 >= totalOperators * CONSENSUS_THRESHOLD);
    }

    /**
     * @notice Execute JIT after consensus
     */
    function _executeJIT(uint256 swapId) private {
        PendingJIT storage jit = pendingJITs[swapId];
        require(!jit.executed, "Already executed");

        _addMultiLPJITLiquidity(jit.poolKey, swapId, jit.eligibleLPs, jit.liquidityContributions);
        jit.executed = true;

        emit JITExecuted(swapId, jit.poolKey.toId(), jit.swapAmount);
    }

    // ============ Utility Functions ============

    function _getOperatorIndex(address operator) private view returns (uint256) {
        for (uint256 i = 0; i < operators.length; i++) {
            if (operators[i] == operator) return i;
        }
        revert("Operator not found");
    }

    function _countBits(uint256 bitmap) private pure returns (uint256) {
        uint256 count = 0;
        while (bitmap > 0) {
            count += bitmap & 1;
            bitmap >>= 1;
        }
        return count;
    }

    /**
     * @notice Deactivate LP participation
     */
    function deactivateLP(PoolKey calldata poolKey) external {
        PoolId poolId = poolKey.toId();
        lpConfigs[poolId][msg.sender].isActive = false;
        emit LPConfigSet(poolId, msg.sender, false);
    }

    // ============ View Functions ============

    /**
     * @notice Get LP configuration (encrypted values remain private)
     */
    function getLPConfig(PoolKey calldata poolKey, address lp) external view returns (bool isActive) {
        PoolId poolId = poolKey.toId();
        return lpConfigs[poolId][lp].isActive;
    }

    /**
     * @notice Get LP positions for a pool
     */
    function getLPPositions(PoolKey calldata poolKey, address lp) external view returns (LPPosition[] memory) {
        PoolId poolId = poolKey.toId();
        return lpPositions[poolId][lp];
    }

    /**
     * @notice Get LP profits
     */
    function getLPProfits(PoolKey calldata poolKey, address lp)
        external
        view
        returns (uint256 profits0, uint256 profits1)
    {
        PoolId poolId = poolKey.toId();
        return (lpProfits0[poolId][lp], lpProfits1[poolId][lp]);
    }

    /**
     * @notice Get pending JIT details
     */
    function getPendingJIT(uint256 swapId) external view returns (PendingJIT memory) {
        return pendingJITs[swapId];
    }

    /**
     * @notice Get JIT position details
     */
    function getJITPosition(uint256 swapId) external view returns (JITLiquidityPosition memory) {
        return jitPositions[swapId];
    }

    /**
     * @notice Check if address is authorized operator
     */
    function isAuthorizedOperator(address operator) external view returns (bool) {
        return authorizedOperators[operator];
    }

    /**
     * @notice Get all LPs for a pool
     */
    function getPoolLPs(PoolKey calldata poolKey) external view returns (address[] memory) {
        return poolLPs[poolKey.toId()];
    }

    /**
     * @notice Reset operators (for testing purposes)
     */
    function resetOperators() external {
        for (uint256 i = 0; i < operators.length; i++) {
            authorizedOperators[operators[i]] = false;
            operatorStake[operators[i]] = 0;
        }
        delete operators;
    }

    /**
     * @notice Batch operations for gas efficiency
     */
    function batchHedgeProfits(PoolKey[] calldata poolKeys, uint256[] calldata hedgePercentages) external {
        require(poolKeys.length == hedgePercentages.length, "Array length mismatch");

        for (uint256 i = 0; i < poolKeys.length; i++) {
            hedgeProfits(poolKeys[i], hedgePercentages[i]);
        }
    }

    // ============ Advanced LP Features ============

    /**
     * @notice Compound LP profits back into liquidity
     */
    function compoundProfits(PoolKey calldata poolKey, int24 tickLower, int24 tickUpper) external {
        PoolId poolId = poolKey.toId();

        uint256 profit0 = lpProfits0[poolId][msg.sender];
        uint256 profit1 = lpProfits1[poolId][msg.sender];

        if (profit0 > 0 && profit1 > 0) {
            // Reset profits
            lpProfits0[poolId][msg.sender] = 0;
            lpProfits1[poolId][msg.sender] = 0;

            // Add as new liquidity position
            uint128 liquidityFromProfits = uint128((profit0 + profit1) / 2); // Simplified calculation

            depositLiquidityToHook(
                poolKey, tickLower, tickUpper, liquidityFromProfits, uint128(profit0), uint128(profit1)
            );
        }
    }
}
