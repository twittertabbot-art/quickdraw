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
| `src/base-custom-v1/BaseProtectedNativeInitializerV1.sol` | BaseProtectedNativeInitializerV1 | opens the pool, locks its liquidity, checks the sequencer and the opening value and makes the initial buy |
| `src/base-custom-v1/BaseLaunchProtectionModuleV1.sol` | BaseLaunchProtectionModuleV1 | buyer authentication and the opening fee schedule |
| `src/ethereum-native30-v3/EthereumNativeFeeVaultV3.sol` | EthereumNativeFeeVaultV3 | the normal fee vault and the opening-tax vault |

Quickdraw launches on Base (chain 8453). The initializer, the protection module, the fee vault and
`ProtectedLaunchTokenV1.sol` (used as a type) are Programmable's Base launch-protection v1 sources, unchanged
(`packages/launch/contracts/base-launch-protection-v1` in Programmable's launch client 4.2.0). The files under `lib/`
are the exact Uniswap v4, solmate and OpenZeppelin sources the contracts import.

## Launch protection

For the first 300 seconds after launch, every wallet may receive at most 2% of the supply and every authenticated
buyer may buy at most 2%, counted cumulatively. Buys during that window go through Programmable's Base trading route
(Universal Router 2.1.2). The buy fee opens at 99% and falls linearly to the normal fee over 30 seconds; the extra
goes to the opening-tax vault, payable only to Programmable's treasury. The pool opens only at a value of at least
$15,000, checked against the Chainlink ETH/USD feed on Base (an answer at most one hour old), and only while
Chainlink's Base sequencer uptime feed reports the sequencer up for more than an hour.

## Build settings

solc 0.8.26, EVM cancun, optimizer 200 runs, via-IR, no metadata hash, no CBOR metadata. Import paths are in
`remappings.txt`.
