# ZK-JIT Liquidity Hook

**Privacy-Preserving Multi-LP Just-In-Time Liquidity for Uniswap v4**

## Overview

The ZK-JIT Liquidity Hook enables multiple liquidity providers to coordinate Just-In-Time (JIT) liquidity operations while keeping their trading strategies completely private through Fully Homomorphic Encryption (FHE). This hook solves key limitations in current JIT systems by introducing multi-LP coordination, privacy-preserving strategy parameters, and automated risk management.

## Problem Statement

Current JIT liquidity solutions face several critical issues:

- **Strategy Exposure**: LP parameters are publicly visible, enabling MEV extraction and strategy copying
- **Single-LP Limitation**: Most JIT systems don't support coordination between multiple LPs
- **Static Fee Structures**: Fixed fees don't adapt to changing network conditions
- **Limited Risk Management**: No automated profit hedging or position management tools
- **Complex Integration**: Difficult for LPs to participate without technical expertise

## Solution Architecture

Our hook introduces a comprehensive solution with the following innovations:

### 🔒 Privacy-First Design
- **FHE Encryption**: All LP strategy parameters (thresholds, limits, hedge ratios) are encrypted using Fhenix FHE
- **Private Threshold Evaluation**: JIT participation decisions made on encrypted data
- **Strategy Protection**: Competitors cannot observe or copy LP strategies

### 👥 Multi-LP Coordination
- **Overlapping Range Detection**: Automatically identifies LPs with positions that overlap JIT ranges
- **Proportional Participation**: Calculates fair contribution amounts based on LP capacity
- **Coordinated Execution**: Multiple LPs participate in single JIT operation with shared profits

### ⚡ Dynamic Fee Pricing
- **Gas-Based Adjustment**: Fees automatically adjust based on network congestion
- **Incentive Alignment**: Lower fees during high gas periods encourage trading
- **LP Optimization**: Higher fees during low gas periods maximize LP returns

### 🛡️ Automated Risk Management
- **Auto-Hedging**: Configurable automatic profit hedging at custom thresholds
- **Profit Compounding**: Reinvest profits into new liquidity positions
- **Batch Operations**: Gas-efficient multi-pool operations

### 🎫 Internal LP Token System
- **ERC-6909 Style Tracking**: Internal token IDs for each liquidity position
- **Direct Token Management**: Bypass complex Uniswap v4 settlement flows
- **Fee Accrual Tracking**: Monitor uncollected fees per position

## Technical Architecture

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   Large Swap    │    │  ZK-JIT Hook     │    │  FHE Encrypted  │
│   Detected      │────│  Multi-LP        │────│  LP Strategies  │
│                 │    │  Coordinator     │    │                 │
└─────────────────┘    └──────────────────┘    └─────────────────┘
                                │
                                ▼
                       ┌──────────────────┐
                       │   JIT Liquidity  │
                       │   Coordination   │
                       │                  │
                       │  LP1 │ LP2 │ LP3 │
                       │  25% │ 40% │ 35% │
                       └──────────────────┘
```

## Core Features

### Privacy-Preserving LP Configuration
```solidity
struct LPConfig {
    euint128 minSwapSize;       // Encrypted minimum swap to trigger JIT
    euint128 maxLiquidity;      // Encrypted maximum liquidity to provide  
    euint32 profitThresholdBps; // Encrypted profit threshold (basis points)
    euint32 hedgePercentage;    // Encrypted auto-hedge percentage (0-100)
    bool isActive;              // Public participation flag
    bool autoHedgeEnabled;      // Auto-hedging toggle
}
```

### Multi-LP JIT Coordination
- **Range Overlap Detection**: Automatically identifies LPs with positions overlapping the JIT range
- **Private Threshold Checks**: Uses FHE to evaluate participation criteria without revealing thresholds
- **Proportional Contributions**: Calculates fair contribution amounts based on LP liquidity and capacity
- **Coordinated Profit Sharing**: Distributes JIT profits proportionally among participants

### Dynamic Fee Structure
- **Base Fee**: 0.3% (3000 basis points)
- **High Gas Periods**: 0.15% (incentivize trading during network congestion)  
- **Low Gas Periods**: 0.6% (maximize LP returns during quiet periods)
- **Real-time Adjustment**: Uses moving average gas price for smooth transitions

## Integration Details

### Fhenix FHE Integration
- **Encrypted Parameters**: LP strategies stored as `euint128` and `euint32` encrypted values
- **Private Computations**: Threshold evaluations performed on encrypted data
- **Access Control**: Proper FHE permissions granted to contract and LP addresses
- **Privacy Guarantee**: Only participation results (yes/no) are revealed, not the underlying parameters

### Simulated EigenLayer Validation
- **Operator Staking**: Operators stake ETH to participate in validation
- **Consensus Mechanism**: 66% stake-weighted consensus required for JIT approval
- **Economic Security**: Operators economically incentivized to validate legitimate JIT operations
- **Slashing Simulation**: Framework for penalizing malicious operators

## Usage Examples

### LP Configuration
```solidity
// Configure private JIT parameters
hook.configureLPSettings(
    poolKey,
    encryptedMinSwapSize,    // e.g., 1000 tokens
    encryptedMaxLiquidity,   // e.g., 50000 tokens  
    encryptedProfitThreshold, // e.g., 50 basis points
    encryptedHedgePercentage, // e.g., 25%
    true                     // Enable auto-hedging
);

// Deposit liquidity and receive internal LP token
uint256 tokenId = hook.depositLiquidityToHook(
    poolKey,
    tickLower,
    tickUpper, 
    liquidityAmount,
    token0Max,
    token1Max
);
```

### Profit Management
```solidity
// Manual profit hedging
hook.hedgeProfits(poolKey, 50); // Hedge 50% of profits

// Compound profits into new position
hook.compoundProfits(poolKey, newTickLower, newTickUpper);

// Batch operations across multiple pools
hook.batchHedgeProfits(poolKeys, hedgePercentages);
```

## Test Coverage

The test suite demonstrates all major features:

- ✅ **LP Token Management**: Internal ERC-6909-style position tracking
- ✅ **Multi-LP Coordination**: Multiple LPs participating in single JIT operation
- ✅ **Profit Hedging**: Manual and automatic profit hedging mechanisms
- ✅ **Dynamic Pricing**: Fee adjustment based on gas price conditions
- ✅ **Position Management**: Creating, modifying, and tracking multiple positions
- ✅ **FHE Privacy**: Encrypted strategy parameters with access control
- ✅ **Error Handling**: Comprehensive security checks and input validation
- ✅ **Batch Operations**: Gas-efficient multi-pool operations

## Running the Tests

```bash
# Install dependencies
forge install

# Run all tests with detailed output
forge test -vvv

# Run specific test scenarios
forge test --match-test testMultiLPJITCoordination -vvv
forge test --match-test testDynamicPricing -vvv
forge test --match-test testAutoHedging -vvv

# Run comprehensive demo
forge test --match-test testComprehensiveDemo -vvv
```

## File Structure

```
src/
├── ZKJITLiquidityHook.sol     # Main hook implementation

test/
├── ZKJITLiquidityTest.sol     # Comprehensive test suite

├── README.md                   # This file
├── foundry.toml               # Forge configuration
└── .gitignore                 # Git ignore rules
```

## Key Technical Innovations

### 1. **Internal Token System**
Instead of implementing full ERC-6909, we use an internal token tracking system that:
- Avoids Uniswap v4's complex currency settlement
- Provides ERC-6909-style unique token IDs per position
- Enables direct token transfers without settlement issues
- Maintains full position metadata and fee tracking

### 2. **FHE-Encrypted Strategy Parameters**
- All LP strategy parameters encrypted using Fhenix FHE
- Participation decisions made on encrypted data without decryption
- Competitors cannot observe or copy successful LP strategies
- Maintains privacy while enabling multi-LP coordination

### 3. **Multi-LP JIT Algorithm**
- Automatically detects LPs with overlapping position ranges
- Evaluates encrypted participation thresholds privately
- Calculates proportional contributions based on capacity
- Coordinates execution with fair profit distribution

### 4. **Gas-Responsive Dynamic Pricing**
- Maintains moving average of gas prices
- Automatically adjusts fees based on network conditions
- Incentivizes trading during congestion with lower fees
- Maximizes LP returns during quiet periods

## Limitations and Future Enhancements

### Current Limitations
- **FHE Performance**: Encryption operations add gas overhead
- **Simulated EigenLayer**: Full integration requires mainnet deployment
- **Demo Simplifications**: Some complex economic mechanisms simplified for hackathon

### Planned Enhancements
- **Cross-Chain JIT**: Coordinate JIT operations across multiple chains
- **Advanced MEV Protection**: Additional mechanisms for MEV resistance
- **LP Dashboard**: Frontend interface for easy LP management
- **Real-time Analytics**: Monitor JIT performance and profitability
- **Governance Integration**: DAO-based parameter adjustment

## Partner Integrations

- **[Fhenix Protocol](https://fhenix.io)**: Fully Homomorphic Encryption for private LP strategies
- **EigenLayer**: Decentralized operator validation system (simulated implementation)

## Security Considerations

### Access Control
- Token ownership verification for all position modifications
- Input validation on all user-provided parameters
- Protection against integer overflow/underflow

### Economic Security
- Operator staking requirements for validation participation
- Slashing mechanisms for malicious behavior
- Fair profit distribution algorithms

### Privacy Guarantees
- FHE encryption protects sensitive LP parameters
- Only participation decisions revealed, not underlying strategies
- Proper key management and access control

## License

MIT License - see LICENSE file for details

## Contributing

This project was built for the Uniswap Hook Incubator. Contributions welcome for:
- Enhanced MEV protection mechanisms
- Frontend dashboard development
- Cross-chain coordination features
- Additional FHE optimizations

## Acknowledgments

Built for the Uniswap v4 Hook Incubator program. Special thanks to:
- Uniswap Labs for the v4 architecture and hook system
- Fhenix Protocol for FHE integration support
- EigenLayer for the validation system inspiration

---

*Privacy-preserving DeFi infrastructure for the next generation of liquidity provision*