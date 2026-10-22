# Quickdraw

A duel that lives inside the token. Hold DRAW and your wallet stands on the street. Trading arms a draw, the block
picks two holders of similar size, and the bigger hand shoots first. Most of what the loser drops is burned, and the
winner takes ETH from the bounty.

Website: https://quickdrawprotocol.xyz

## Contracts

| File | Contract | Role |
|---|---|---|
| `src/QuickdrawToken.sol` | QuickdrawToken | the DRAW token, 100,000 supply minted once, with the launch-protection inflow budget |
| `src/QuickdrawHook.sol` | QuickdrawHook | the Uniswap v4 hook: the protected fee kernel and the game |
| `src/QuickdrawGame.sol` | QuickdrawGame | the game engine the hook runs: hands, draws, shields, floors |
| `src/QuickdrawNFT.sol` | QuickdrawNFT | a soulbound mirror of every hand |
| `src/QuickdrawRenderer.sol` | QuickdrawRenderer | the on-chain token art |
| `src/launch-protection/ProtectedNativeInitializerV1.sol` | ProtectedNativeInitializerV1 | opens the pool, locks its liquidity, checks the opening value and makes the initial buy |
| `src/launch-protection/LaunchProtectionModuleV1.sol` | LaunchProtectionModuleV1 | buyer authentication and the opening fee schedule |
| `src/ethereum-native30-v3/EthereumNativeFeeVaultV3.sol` | EthereumNativeFeeVaultV3 | the normal fee vault and the opening-tax vault |

The initializer, the protection module, the fee vault and `ProtectedLaunchTokenV1.sol` (used as a type) are
Programmable's launch-protection v1 sources, unchanged. The files under `lib/` are the exact Uniswap v4, solmate and
OpenZeppelin sources the contracts import.

## Launch protection

For the first 300 seconds after launch, every wallet may receive at most 2% of the supply and every authenticated buyer
may buy at most 2%, counted cumulatively. Buys during that window go through Programmable's router. The buy fee opens
at 99% and falls linearly to the normal fee over 30 seconds; the extra goes to the opening-tax vault, payable only to
Programmable's treasury. The pool opens only at a value of at least $15,000, checked against the Chainlink ETH/USD
feed.

For the same first 300 seconds every buy also pays a launch tax to the Quickdraw treasury: together with the opening
fee it comes to at least 30% of the buy on top of the normal fee (34.3% in all once the opening fee is under 30%).
Everyone pays it, the developer's initial buy and the team's buys included, it is booked in the normal fee vault's
creator ledger, and the opening fee keeps exactly its own rate and vault. Sells never pay it. The rule is the `LAUNCH
TAX` section of `QuickdrawHook.sol` (`LAUNCH_TAX_PPM`, event `LaunchTaxAccrued`).

## Build settings

solc 0.8.26, EVM cancun, optimizer 200 runs, via-IR, no metadata hash, no CBOR metadata. Import paths are in
`remappings.txt`.
