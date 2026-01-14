# Tempo Network Integration

This module contains contracts and utilities for integrating with Tempo Network's precompiles and TIP-20 token standard.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│                                    TEMPO NETWORK                                            │
├─────────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────────────────────┐   │
│  │                              PRECOMPILES (System Contracts)                          │   │
│  │                                                                                      │   │
│  │  ┌─────────────────────┐    ┌─────────────────────┐    ┌─────────────────────────┐   │   │
│  │  │   TIP403_REGISTRY   │    │   STABLECOIN_DEX    │    │     TIP_FEE_MANAGER     │   │   │
│  │  │  (0xfeEC...0403)    │    │    (0xDEc0...)      │    │      (0xfeEC...)        │   │   │
│  │  │                     │    │                     │    │                         │   │   │
│  │  │ • createPolicy()    │    │ • swapExactAmountIn │    │ • userTokens(addr)      │   │   │
│  │  │ • modifyBlacklist() │    │ • placeOrder()      │    │ • setUserToken()        │   │   │
│  │  │ • isAuthorized()    │    │ • fillOrders()      │    │                         │   │   │
│  │  └─────────────────────┘    └─────────────────────┘    └─────────────────────────┘   │   │
│  │            ▲                          ▲                           │                  │   │
│  └────────────│──────────────────────────│───────────────────────────│──────────────────┘   │
│               │                          │                           │                      │
│               │ (2) Check policy         │ (5) Swap TIP20→PATH_USD   │ (4) Get user's      │
│               │     on transfer          │                           │     gas token       │
│               │                          │                           ▼                      │
│  ┌────────────┴──────────────┐    ┌──────┴───────────────────────────────────────────────┐  │
│  │                           │    │                                                      │  │
│  │   FrxUSDPolicyAdminTempo  │    │        FraxOFTMintableAdapterUpgradeableTIP20        │  │
│  │      (Proxy Contract)     │    │                  (Proxy Contract)                    │  │
│  │                           │    │                                                      │  │
│  │  • policyId (BLACKLIST)   │    │  • innerToken (frxUSD TIP20)                         │  │
│  │  • freeze(account)        │    │  • endpoint (LayerZero)                              │  │
│  │  • thaw(account)          │    │                                                      │  │
│  │  • addFreezer(account)    │    │  _debit():                                           │  │
│  │                           │    │    (6) transferFrom(user → adapter)                  │  │
│  │  (1) Calls                │    │    (7) burn(amount)                                  │  │
│  │      modifyBlacklist()    │    │                                                      │  │
│  │      to freeze/thaw       │    │  _credit():                                          │  │
│  │                           │    │    (8) mint(to, amount)                              │  │
│  └───────────────────────────┘    │                                                      │  │
│               │                   │  _lzSend():                                          │  │
│               │                   │    (4) Check userTokens(msg.sender)                  │  │
│               │                   │    (5) If innerToken, swap to PATH_USD               │  │
│               │                   │    (9) Send message to LayerZero                     │  │
│               │                   └──────────────────────────────────────────────────────┘  │
│               │                                    │                                        │
│               ▼                                    ▼                                        │
│  ┌───────────────────────────────────────────────────────────────────────────────────────┐  │
│  │                                                                                       │  │
│  │                              frxUSD TIP20 Token (Precompile)                          │  │
│  │                                                                                       │  │
│  │  • transfer(to, amount)  ──────► Checks TIP403_REGISTRY.isAuthorized(policyId, user) │  │
│  │  • transferFrom(from, to, amount)           │                                        │  │
│  │  • mint(to, amount)                         │ If on BLACKLIST → revert PolicyForbids │  │
│  │  • burn(amount)                             │ If not on BLACKLIST → allow transfer   │  │
│  │  • changeTransferPolicyId(policyId)         │                                        │  │
│  │                                             ▼                                        │  │
│  └───────────────────────────────────────────────────────────────────────────────────────┘  │
│                                                                                             │
└─────────────────────────────────────────────────────────────────────────────────────────────┘
                                              │
                                              │ (9) LayerZero Message
                                              ▼
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│                              OTHER CHAIN (Ethereum, Fraxtal, etc.)                          │
│                                                                                             │
│                         FraxOFTMintableAdapterUpgradeable / Lockbox                         │
└─────────────────────────────────────────────────────────────────────────────────────────────┘
```

## Components

### FrxUSDPolicyAdminTempo

Admin contract for managing freeze/thaw operations via TIP-403 Registry.

- Creates a **BLACKLIST** policy on initialization
- **Freeze**: Adds account to blacklist → cannot send or receive tokens
- **Thaw**: Removes account from blacklist → can transfer normally
- Supports freezer roles for delegated freeze operations

### FraxOFTMintableAdapterUpgradeableTIP20

LayerZero OFT adapter for bridging TIP-20 tokens.

- **Send (Tempo → Other Chain)**: Burns tokens on Tempo, mints on destination
- **Receive (Other Chain → Tempo)**: Mints tokens on Tempo
- **Gas Payment**: Supports paying gas fees in the bridged token (swaps to PATH_USD via StablecoinDEX)

### Precompiles

| Precompile | Address | Purpose |
|------------|---------|---------|
| TIP403_REGISTRY | `0xfeEC...0403` | Transfer policy management (whitelist/blacklist) |
| STABLECOIN_DEX | `0xDEc0...` | Swap between TIP-20 stablecoins |
| TIP_FEE_MANAGER | `0xfeEC...` | Manage user's preferred gas token |
| TIP20_FACTORY | `0x20Fc...` | Create new TIP-20 tokens |
| PATH_USD | `0x20C0...` | Native gas token on Tempo |

## Flows

### Freeze/Thaw Flow

1. Owner/Freezer calls `FrxUSDPolicyAdminTempo.freeze(alice)`
2. PolicyAdmin calls `TIP403_REGISTRY.modifyPolicyBlacklist(policyId, alice, true)`
3. When alice tries `frxUSD.transfer()`, TIP20 checks `TIP403_REGISTRY.isAuthorized()`
4. Alice is on blacklist → **PolicyForbids** error

### Bridge Send Flow (Tempo → Other Chain)

1. User calls `adapter.send(dstEid, to, amount, options)`
2. `_debit()`: Pull frxUSD from user, burn it
3. `_lzSend()`: Check if user pays gas in frxUSD
4. If yes: Swap frxUSD → PATH_USD via StablecoinDEX
5. Send LayerZero message to destination chain

### Bridge Receive Flow (Other Chain → Tempo)

1. LayerZero delivers message to adapter
2. `_credit()`: Mint frxUSD to recipient
