# ZK-JIT Liquidity Hook

## Overview

A privacy-preserving Just-In-Time (JIT) liquidity hook for Uniswap v4 that enables multiple liquidity providers to coordinate JIT operations while keeping their strategies private through Fully Homomorphic Encryption (FHE).

## Problem Statement

Current JIT liquidity solutions suffer from:
- **Strategy Exposure**: LP parameters are public, enabling MEV extraction
- **Single-LP Limitation**: Most JIT systems don't support multi-LP coordination
- **Static Pricing**: Fixed fees don't adapt to network conditions
- **Limited Risk Management**: No automated profit hedging or position management

## Solution

Our hook introduces:
- **🔒 Privacy-First JIT**: FHE encryption keeps LP thresholds and strategies private
- **👥 Multi-LP Coordination**: Multiple LPs can participate in single JIT operations with overlapping ranges
- **⚡ Dynamic Pricing**: Gas-price-based fee adjustment for optimal capital efficiency
- **🛡️ EigenLayer-Style Validation**: Stake-weighted operator consensus for JIT legitimacy
- **💰 Automated Risk Management**: Auto-hedging and profit compounding features
- **🎫 ERC-6909 LP Tokens**: Composable liquidity positions with fee tracking

## Key Features

### Privacy-Preserving Parameters
```solidity
struct LPConfig {
    euint128 minSwapSize;       // Encrypted minimum swap to trigger JIT
    euint128 maxLiquidity;      // Encrypted maximum liquidity to provide
    euint32 profitThresholdBps; // Encrypted profit threshold
    euint32 hedgePercentage;    // Encrypted auto-hedge percentage
    bool isActive;
    bool autoHedgeEnabled;
}
```

### Multi-LP JIT Coordination
- LPs with overlapping tick ranges automatically coordinate
- Private threshold evaluation prevents gaming
- Proportional profit distribution based on contributions

### Dynamic Fee Structure
- Base fee: 0.3%
- High gas periods: 0.15% (incentivize trading)
- Low gas periods: 0.6% (maximize LP returns)

### Automated Risk Management
- Auto-hedging at configurable profit thresholds
- Profit compounding into new liquidity positions
- Batch operations for gas efficiency

## Architecture

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   Trader        │    │  ZK-JIT Hook     │    │  EigenLayer     │
│                 │────│                  │────│  Operators      │
│  Large Swap     │    │  FHE Evaluation  │    │  Validation     │
└─────────────────┘    └──────────────────┘    └─────────────────┘
                                │
                                ▼
                       ┌──────────────────┐
                       │   Multi-LP       │
                       │   Coordination   │
                       │                  │
                       │  LP1 │ LP2 │ LP3 │
                       └──────────────────┘
```

## Technical Implementation

### Hook Permissions
- `beforeSwap`: Evaluate JIT opportunities with private thresholds
- `afterSwap`: Distribute profits and cleanup JIT positions
- `beforeInitialize`: Enforce dynamic fee requirement

### FHE Integration (Fhenix)
- Private LP configurations stored as encrypted values
- Threshold evaluations performed on encrypted data
- Only results (participate/don't participate) are revealed

### EigenLayer-Style Validation
- Operators stake ETH to participate in validation
- Stake-weighted consensus (66% threshold)
- Economic incentives align with protocol security

## Demo Scenarios

### 1. Small Swap (No JIT)
- Trader swaps 500 tokens
- Below encrypted thresholds
- Normal AMM execution

### 2. Large Swap (Multi-LP JIT)
- Trader swaps 5000 tokens
- Multiple LPs meet private thresholds
- Coordinated JIT execution with profit sharing

### 3. MEV Protection
- MEV bot attempts large arbitrage
- Private LP strategies prevent gaming
- Profits protected through FHE privacy

## Partner Integrations

- **Fhenix Protocol**: Fully Homomorphic Encryption for private LP parameters
- **EigenLayer**: Decentralized operator validation system (simulated)

*Note: No other partner integrations in current implementation*

## Installation & Testing

```bash
# Clone repository
git clone <repository-url>
cd zk-jit-liquidity-hook

# Install dependencies
forge install

# Run tests
forge test -vvv

# Run specific test scenarios
forge test --match-test testMultiLPOverlappingRanges -vvv
forge test --match-test testDynamicPricing -vvv
forge test --match-test testAutoHedging -vvv
```

## Test Coverage

- ✅ LP Token Management (ERC-6909)
- ✅ Multi-LP Coordination
- ✅ Profit Hedging & Auto-hedging
- ✅ Dynamic Pricing
- ✅ Position Management
- ✅ Profit Compounding
- ✅ Batch Operations
- ✅ FHE Integration

## Code Structure

```
src/
├── ZKJITLiquidityHook.sol     # Main hook implementation

test/
├── ZKJITLiquidityTest.sol     # Comprehensive test suite
└── mocks/                      # Mock contracts for testing
```

## Key Innovations

1. **Privacy-First Design**: First JIT hook to use FHE for strategy privacy
2. **Multi-LP Architecture**: Coordinate multiple LPs in single JIT operation
3. **Adaptive Pricing**: Dynamic fees based on network conditions
4. **Automated Risk Management**: Built-in hedging and compounding
5. **EigenLayer Integration**: Decentralized validation for JIT legitimacy

## Limitations & Future Work

- **FHE Performance**: Encryption operations add gas overhead
- **Operator Simulation**: Full EigenLayer integration requires mainnet deployment
- **MEV Resistance**: Additional mechanisms needed for complete MEV protection

## Demo Video

[Link to demo video showcasing multi-LP JIT coordination and privacy features]

## Contributing

This project was built for the Uniswap Hook Incubator. Future enhancements welcome:
- Full EigenLayer mainnet integration
- Advanced MEV protection mechanisms
- Frontend dashboard for LP management
- Cross-chain JIT coordination

## License

MIT License - see LICENSE file for details

---

*Built with ❤️ for the Uniswap Hook Incubator*